// Package screen is the GNU screen backend: sessions "rssh-<id>" in a socket directory of their own
// (SCREENDIR under the rsshd runtime directory), so the user's own screen sessions and ~/.screenrc are never
// touched. Screen has no user options, so the metadata lives in a small state file (state.go).
package screen

import (
	"bytes"
	"context"
	_ "embed"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/backend"
)

// Prefix is the screen session name prefix of managed sessions.
const Prefix = "rssh-"

// DefaultRC is the built-in screenrc (also shipped as /usr/share/rsshd/screenrc).
//
//go:embed screenrc
var DefaultRC string

var (
	idRE      = regexp.MustCompile(`^[0-9a-f]{8}$`)
	keyRE     = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	versionRE = regexp.MustCompile(`(?i)screen version (\S+)`)
)

// ValidID reports whether id has the form rsshd issues (8 lowercase hex).
func ValidID(id string) bool { return idRE.MatchString(id) }

// Screen drives the managed screen sessions of one user.
type Screen struct {
	Bin   string // screen binary; "" = "screen" from PATH
	Dir   string // SCREENDIR of the managed sessions (created 0700)
	RC    string // -c file; "" = DefaultRC written next to Dir
	State string // the metadata file

	mu  sync.Mutex       // the state file
	act sync.Map         // id -> seen: the last screen content hash, for output activity
	now func() time.Time // nil = time.Now
}

var _ backend.Backend = (*Screen)(nil)

// Name implements backend.Backend.
func (s *Screen) Name() string { return "screen" }

func (s *Screen) bin() string {
	if s.Bin == "" {
		return "screen"
	}
	return s.Bin
}

func (s *Screen) clock() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

// Error is a failed screen command.
type Error struct {
	Args []string
	Msg  string
}

func (e *Error) Error() string { return "screen " + strings.Join(e.Args, " ") + ": " + e.Msg }

// env is this process's environment without the variables of an enclosing screen or tmux, with SCREENDIR set
// to own (or left as the user has it when own is "").
func env(own string) []string {
	var out []string
	hasTerm, hasShell := false, false
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "STY", "WINDOW", "TMUX", "TMUX_PANE":
			continue
		case "SCREENDIR":
			if own != "" {
				continue
			}
		case "TERM":
			hasTerm = kv != "TERM="
		case "SHELL":
			hasShell = kv != "SHELL="
		}
		out = append(out, kv)
	}
	if own != "" {
		out = append(out, "SCREENDIR="+own)
	}
	if !hasTerm { // a service manager sets none; screen needs one to start
		out = append(out, "TERM=xterm-256color")
	}
	if !hasShell {
		if sh := loginShell(); sh != "" {
			out = append(out, "SHELL="+sh)
		}
	}
	return out
}

// run executes screen against the managed socket directory.
func (s *Screen) run(ctx context.Context, args ...string) (string, error) {
	return s.exec(ctx, s.Dir, "", args...)
}

// cmdTimeout bounds every screen command: a client waiting on a server that never answers fails with an error
// instead of hanging its caller.
const cmdTimeout = 30 * time.Second

func (s *Screen) exec(ctx context.Context, dir, cwd string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, cmdTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.bin(), args...)
	cmd.Env = env(dir)
	cmd.Dir = cwd
	cmd.WaitDelay = time.Second // a forked server still holding the output pipes does not block Wait
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String() + " " + stdout.String())
		if ctx.Err() != nil {
			msg = strings.TrimSpace("no answer: " + ctx.Err().Error() + " " + msg)
		}
		if msg == "" {
			msg = err.Error()
		}
		return stdout.String(), &Error{Args: args, Msg: msg}
	}
	return stdout.String(), nil
}

// Version implements backend.Backend: "4.09.01" from "Screen version 4.09.01 (GNU) 20-Aug-23". Some builds
// exit non-zero for -v, so the output decides.
func (s *Screen) Version(ctx context.Context) (string, error) {
	if _, err := exec.LookPath(s.bin()); err != nil {
		return "", fmt.Errorf("screen is not installed: %w", err)
	}
	out, err := s.exec(ctx, "", "", "-v")
	if v := ParseVersion(out); v != "" {
		return v, nil
	}
	var se *Error
	if errors.As(err, &se) {
		if v := ParseVersion(se.Msg); v != "" {
			return v, nil
		}
		return "", err
	}
	return "", fmt.Errorf("screen -v: unexpected output %q", strings.TrimSpace(out))
}

// ParseVersion extracts the version from `screen -v` output, "" when there is none.
func ParseVersion(out string) string {
	if m := versionRE.FindStringSubmatch(out); m != nil {
		return m[1]
	}
	return ""
}

// ensureDir creates the socket directory: screen refuses one that is not 0700 and owned by the user.
func (s *Screen) ensureDir() error {
	if s.Dir == "" || !filepath.IsAbs(s.Dir) {
		return fmt.Errorf("screen: socket directory %q must be an absolute path", s.Dir)
	}
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return fmt.Errorf("screen socket dir: %w", err)
	}
	if err := os.Chmod(s.Dir, 0o700); err != nil {
		return fmt.Errorf("screen socket dir: %w", err)
	}
	return nil
}

// workDir holds rsshd's own files (built-in screenrc, command and hardcopy temp files): a 0700 directory inside
// the socket directory, which screen ignores because it is not a socket.
func (s *Screen) workDir() (string, error) {
	if err := s.ensureDir(); err != nil {
		return "", err
	}
	d := filepath.Join(s.Dir, ".rsshd")
	if err := os.Mkdir(d, 0o700); err != nil && !os.IsExist(err) {
		return "", fmt.Errorf("screen work dir: %w", err)
	}
	return d, nil
}

// rcFile is the -c file: RC, or the built-in one written to the work directory.
func (s *Screen) rcFile() (string, error) {
	if s.RC != "" {
		return s.RC, nil
	}
	wd, err := s.workDir()
	if err != nil {
		return "", err
	}
	p := filepath.Join(wd, "screenrc")
	if b, err := os.ReadFile(p); err == nil && string(b) == DefaultRC {
		return p, nil
	}
	// A unique temp file: parallel creates may write it at the same time, and the rename is atomic.
	f, err := os.CreateTemp(wd, "screenrc-*")
	if err != nil {
		return "", fmt.Errorf("write screenrc: %w", err)
	}
	_, werr := f.WriteString(DefaultRC)
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Rename(f.Name(), p)
	}
	if werr != nil {
		_ = os.Remove(f.Name())
		return "", fmt.Errorf("write screenrc: %w", werr)
	}
	return p, nil
}

// loginShell is the user's shell from /etc/passwd, for a daemon started without SHELL.
func loginShell() string {
	b, err := os.ReadFile("/etc/passwd")
	if err != nil {
		return ""
	}
	uid := strconv.Itoa(os.Getuid())
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Split(line, ":")
		if len(f) == 7 && f[2] == uid {
			return f[6]
		}
	}
	return ""
}

func checkID(id string) error {
	if !ValidID(id) {
		return fmt.Errorf("session %q: %w", id, backend.ErrNotFound)
	}
	return nil
}

func notFound(id string) error { return fmt.Errorf("session %s: %w", id, backend.ErrNotFound) }
