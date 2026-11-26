// Package tmux is the default backend: sessions "rssh-<id>" on a dedicated tmux server (tmux -L rsshd), so the
// user's own tmux server and config are never touched. Metadata lives in tmux user options "@rssh_<key>".
package tmux

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/hangup"
)

const (
	// Prefix is the tmux session name prefix of managed sessions.
	Prefix = "rssh-"
	optPfx = "@rssh_"
	sep    = "|"
)

var (
	idRE  = regexp.MustCompile(`^[0-9a-f]{8}$`)
	keyRE = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
)

// ValidID reports whether id has the form rsshd issues (8 lowercase hex).
func ValidID(id string) bool { return idRE.MatchString(id) }

// Tmux drives one tmux server.
type Tmux struct {
	Bin      string   // tmux binary; "" = "tmux" from PATH
	Socket   string   // -L name
	Conf     string   // -f file
	MetaKeys []string // keys Meta and List read back (values are stored URL-escaped)
}

var _ backend.Backend = (*Tmux)(nil)

// Name implements backend.Backend.
func (t *Tmux) Name() string { return "tmux" }

func (t *Tmux) bin() string {
	if t.Bin == "" {
		return "tmux"
	}
	return t.Bin
}

// run executes tmux against this server. Stderr goes into the error.
func (t *Tmux) run(ctx context.Context, args ...string) (string, error) {
	full := append([]string{"-L", t.Socket, "-f", t.Conf}, args...)
	return t.exec(ctx, full...)
}

func (t *Tmux) exec(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, t.bin(), args...)
	cmd.Env = cleanEnv()
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return stdout.String(), &Error{Args: args, Msg: msg}
	}
	return stdout.String(), nil
}

// Error is a failed tmux command.
type Error struct {
	Args []string
	Msg  string
}

func (e *Error) Error() string { return "tmux " + strings.Join(e.Args, " ") + ": " + e.Msg }

// noServer matches tmux's message when the server is not running (wording differs between versions).
func noServer(err error) bool {
	var te *Error
	if !errors.As(err, &te) {
		return false
	}
	return strings.Contains(te.Msg, "no server running") || strings.Contains(te.Msg, "error connecting to") ||
		strings.Contains(te.Msg, "No such file or directory")
}

func noSession(err error) bool {
	var te *Error
	return errors.As(err, &te) && (strings.Contains(te.Msg, "can't find session") ||
		strings.Contains(te.Msg, "can't find pane") || strings.Contains(te.Msg, "can't find window") || noServer(err))
}

// cleanEnv drops TMUX so a daemon started from inside tmux does not nest.
func cleanEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "TMUX=") && !strings.HasPrefix(kv, "TMUX_PANE=") {
			env = append(env, kv)
		}
	}
	return env
}

func sessTarget(id string) string { return "=" + Prefix + id }
func paneTarget(id string) string { return "=" + Prefix + id + ":" }

func checkID(id string) error {
	if !ValidID(id) {
		return fmt.Errorf("session %q: %w", id, backend.ErrNotFound)
	}
	return nil
}

// Version implements backend.Backend: "3.4" from "tmux 3.4".
func (t *Tmux) Version(ctx context.Context) (string, error) {
	out, err := t.exec(ctx, "-V")
	if err != nil {
		return "", err
	}
	return ParseVersion(out), nil
}

// ParseVersion turns "tmux 3.4\n" (or "tmux next-3.5") into "3.4".
func ParseVersion(out string) string {
	v := strings.TrimSpace(out)
	v = strings.TrimPrefix(v, "tmux ")
	return strings.TrimPrefix(v, "next-")
}

// ServerPID is the pid of the running tmux server, 0 when none runs.
func (t *Tmux) ServerPID(ctx context.Context) int {
	out, err := t.run(ctx, "display-message", "-p", "#{pid}")
	if err != nil {
		return 0
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(out))
	return pid
}

// Create implements backend.Backend.
func (t *Tmux) Create(ctx context.Context, o backend.CreateOpts) (backend.Session, error) {
	if err := checkID(o.ID); err != nil {
		return backend.Session{}, err
	}
	cols, rows := o.Cols, o.Rows
	if cols <= 0 {
		cols = 80
	}
	if rows <= 0 {
		rows = 24
	}
	args := []string{"new-session", "-d", "-s", Prefix + o.ID, "-x", strconv.Itoa(cols), "-y", strconv.Itoa(rows)}
	if o.Cwd != "" {
		args = append(args, "-c", o.Cwd)
	}
	if _, err := t.run(ctx, args...); err != nil {
		return backend.Session{}, err
	}
	if len(o.Meta) > 0 {
		if _, err := t.Meta(ctx, o.ID, o.Meta); err != nil {
			_ = t.killSession(ctx, o.ID)
			return backend.Session{}, err
		}
	}
	if o.Command != "" {
		// Typed into the shell so the shell stays when the command ends; -l = literal, never a key name.
		if _, err := t.run(ctx, "send-keys", "-t", paneTarget(o.ID), "-l", o.Command); err != nil {
			return backend.Session{}, err
		}
		if _, err := t.run(ctx, "send-keys", "-t", paneTarget(o.ID), "Enter"); err != nil {
			return backend.Session{}, err
		}
	}
	return t.get(ctx, o.ID)
}

func (t *Tmux) get(ctx context.Context, id string) (backend.Session, error) {
	all, err := t.List(ctx)
	if err != nil {
		return backend.Session{}, err
	}
	for _, s := range all {
		if s.ID == id {
			return s, nil
		}
	}
	return backend.Session{}, fmt.Errorf("session %s: %w", id, backend.ErrNotFound)
}

// Fixed fields of the list format; pane_current_command goes last because it is free text.
var listFields = []string{"session_name", "session_created", "session_activity", "session_attached", "pane_pid",
	"alternate_on"}

func (t *Tmux) listFormat() string {
	var f []string
	for _, k := range listFields {
		f = append(f, "#{"+k+"}")
	}
	for _, k := range t.MetaKeys {
		f = append(f, "#{"+optPfx+k+"}")
	}
	return strings.Join(append(f, "#{pane_current_command}"), sep)
}

// List implements backend.Backend.
func (t *Tmux) List(ctx context.Context) ([]backend.Session, error) {
	out, err := t.run(ctx, "list-sessions", "-F", t.listFormat())
	if noServer(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	sessions, err := ParseList(out, t.MetaKeys)
	if err != nil {
		return nil, err
	}
	// Output in any window counts, not only the current one.
	wout, err := t.run(ctx, "list-windows", "-a", "-F", "#{session_name}"+sep+"#{window_activity}")
	if err != nil && !noServer(err) {
		return nil, err
	}
	act := ParseWindowActivity(wout)
	for i := range sessions {
		if a, ok := act[sessions[i].ID]; ok && a.After(sessions[i].ActivityAt) {
			sessions[i].ActivityAt = a
		}
	}
	return sessions, nil
}

// ParseList parses list-sessions output in listFormat order; sessions without the rssh- prefix are skipped.
func ParseList(out string, metaKeys []string) ([]backend.Session, error) {
	var res []backend.Session
	n := len(listFields) + len(metaKeys) + 1
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if line == "" {
			continue
		}
		f := strings.SplitN(line, sep, n)
		if len(f) != n {
			return nil, fmt.Errorf("tmux list-sessions: %d fields in %q, want %d", len(f), line, n)
		}
		id, ok := strings.CutPrefix(f[0], Prefix)
		if !ok || !ValidID(id) {
			continue
		}
		s := backend.Session{ID: id, Backend: "tmux", Created: unix(f[1]), ActivityAt: unix(f[2]),
			AttachedClients: atoi(f[3]), PanePID: atoi(f[4]), AltScreen: f[5] == "1", PaneCommand: f[n-1],
			Meta: map[string]string{}}
		for i, k := range metaKeys {
			if v := f[len(listFields)+i]; v != "" {
				s.Meta[k] = unescape(v)
			}
		}
		res = append(res, s)
	}
	return res, nil
}

// ParseWindowActivity returns the newest window_activity per managed session id.
func ParseWindowActivity(out string) map[string]time.Time {
	m := map[string]time.Time{}
	for _, line := range strings.Split(out, "\n") {
		name, ts, ok := strings.Cut(line, sep)
		if !ok {
			continue
		}
		id, ok := strings.CutPrefix(name, Prefix)
		if !ok {
			continue
		}
		if a := unix(ts); a.After(m[id]) {
			m[id] = a
		}
	}
	return m
}

// Foreign implements backend.Backend: the user's default tmux server (no -L, the user's own config).
func (t *Tmux) Foreign(ctx context.Context) ([]backend.Foreign, error) {
	out, err := t.exec(ctx, "list-sessions", "-F", "#{session_attached}"+sep+"#{session_name}")
	if noServer(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var res []backend.Foreign
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		att, name, ok := strings.Cut(line, sep)
		if !ok {
			continue
		}
		res = append(res, backend.Foreign{Name: name, Backend: "tmux", AttachedClients: atoi(att),
			Attach: []string{"tmux", "attach", "-t", "=" + name}})
	}
	return res, nil
}

// Attach implements backend.Backend. On Linux it runs the server's own binary (/proc/<pid>/exe), so a tmux
// upgraded under a running server still attaches (a newer client may refuse an older server).
func (t *Tmux) Attach(ctx context.Context, id string) ([]string, error) {
	if err := checkID(id); err != nil {
		return nil, err
	}
	if _, err := t.run(ctx, "has-session", "-t", sessTarget(id)); err != nil {
		if noSession(err) {
			return nil, fmt.Errorf("session %s: %w", id, backend.ErrNotFound)
		}
		return nil, err
	}
	bin := t.bin()
	if p, err := exec.LookPath(bin); err == nil {
		bin = p
	}
	if runtime.GOOS == "linux" {
		if pid := t.ServerPID(ctx); pid > 0 {
			exe := "/proc/" + strconv.Itoa(pid) + "/exe"
			if _, err := os.Stat(exe); err == nil {
				bin = exe
			}
		}
	}
	return []string{bin, "-L", t.Socket, "-f", t.Conf, "attach-session", "-t", sessTarget(id)}, nil
}

// Capture implements backend.Backend.
func (t *Tmux) Capture(ctx context.Context, id string, lines int) (string, error) {
	if err := checkID(id); err != nil {
		return "", err
	}
	if lines <= 0 {
		lines = 5000
	}
	out, err := t.run(ctx, "capture-pane", "-p", "-e", "-J", "-S", "-"+strconv.Itoa(lines), "-t", paneTarget(id))
	if noSession(err) {
		return "", fmt.Errorf("session %s: %w", id, backend.ErrNotFound)
	}
	return out, err
}

// Kill implements backend.Backend.
func (t *Tmux) Kill(ctx context.Context, id string, grace time.Duration) error {
	if err := checkID(id); err != nil {
		return err
	}
	out, err := t.run(ctx, "list-panes", "-s", "-t", sessTarget(id), "-F", "#{pane_pid}")
	if noSession(err) {
		return fmt.Errorf("session %s: %w", id, backend.ErrNotFound)
	}
	if err != nil {
		return err
	}
	var pids []int
	for _, f := range strings.Fields(out) {
		if pid := atoi(f); pid > 0 {
			pids = append(pids, pid)
		}
	}
	hangup.Shells(pids)
	deadline := time.Now().Add(grace)
	for time.Now().Before(deadline) {
		if _, err := t.run(ctx, "has-session", "-t", sessTarget(id)); err != nil {
			return nil // the shells exited and tmux removed the session
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	if err := t.killSession(ctx, id); err != nil && !noSession(err) {
		return err
	}
	return nil
}

func (t *Tmux) killSession(ctx context.Context, id string) error {
	_, err := t.run(ctx, "kill-session", "-t", sessTarget(id))
	return err
}

// Meta implements backend.Backend. Keys must be lowercase identifiers; values are stored URL-escaped so they
// never contain the list separator.
func (t *Tmux) Meta(ctx context.Context, id string, set map[string]string) (map[string]string, error) {
	if err := checkID(id); err != nil {
		return nil, err
	}
	if len(set) > 0 {
		var args []string
		for k, v := range set {
			if !keyRE.MatchString(k) {
				return nil, fmt.Errorf("meta key %q: want [a-z][a-z0-9_]*", k)
			}
			if len(args) > 0 {
				args = append(args, ";")
			}
			args = append(args, "set-option", "-t", paneTarget(id), optPfx+k, url.QueryEscape(v))
		}
		if _, err := t.run(ctx, args...); err != nil {
			if noSession(err) {
				return nil, fmt.Errorf("session %s: %w", id, backend.ErrNotFound)
			}
			return nil, err
		}
	}
	s, err := t.get(ctx, id)
	if err != nil {
		return nil, err
	}
	return s.Meta, nil
}

func unescape(v string) string {
	if u, err := url.QueryUnescape(v); err == nil {
		return u
	}
	return v
}

func atoi(s string) int {
	v, _ := strconv.Atoi(strings.TrimSpace(s))
	return v
}

func unix(s string) time.Time {
	v, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil || v <= 0 {
		return time.Time{}
	}
	return time.Unix(v, 0)
}
