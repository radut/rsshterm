package screen

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/hangup"
)

// Create implements backend.Backend. The state entry is written first, so a List running meanwhile never sees
// the session without its metadata. screen -dm cannot size a detached window: it starts 80x24 and takes the
// size of the terminal on the first attach (Cols and Rows are not applied).
func (s *Screen) Create(ctx context.Context, o backend.CreateOpts) (backend.Session, error) {
	if err := checkID(o.ID); err != nil {
		return backend.Session{}, err
	}
	for k := range o.Meta {
		if !keyRE.MatchString(k) {
			return backend.Session{}, fmt.Errorf("meta key %q: want [a-z][a-z0-9_]*", k)
		}
	}
	if err := s.ensureDir(); err != nil {
		return backend.Session{}, err
	}
	rc, err := s.rcFile()
	if err != nil {
		return backend.Session{}, err
	}
	if err := s.putState(o.ID, o.Meta, true); err != nil {
		return backend.Session{}, err
	}
	fail := func(err error) (backend.Session, error) {
		_, _ = s.run(context.WithoutCancel(ctx), "-S", Prefix+o.ID, "-X", "quit")
		s.dropState(o.ID)
		return backend.Session{}, err
	}
	if _, err := s.exec(ctx, s.Dir, o.Cwd, "-c", rc, "-dmS", Prefix+o.ID); err != nil {
		return fail(err)
	}
	e, err := s.waitUp(ctx, o.ID)
	if err != nil {
		return fail(err)
	}
	if o.Command != "" {
		if err := s.typeCommand(ctx, e, o.Command); err != nil {
			return fail(err)
		}
	}
	return s.get(ctx, o.ID)
}

// waitUp waits for the new session's socket: screen -dm may return before the server listens.
func (s *Screen) waitUp(ctx context.Context, id string) (Entry, error) {
	deadline := time.Now().Add(5 * time.Second)
	for {
		e, err := s.find(ctx, id)
		if err == nil {
			return e, nil
		}
		if time.Now().After(deadline) {
			return Entry{}, fmt.Errorf("screen session %s did not start (socket directory %s): %w", id, s.Dir, err)
		}
		select {
		case <-ctx.Done():
			return Entry{}, ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// typeCommand types the command into the first window and presses Enter. It goes through screen's paste
// buffer (readbuf + paste), so it reaches the shell byte for byte: `stuff` would interpret ^X, \ and $VAR.
// The temp file is 0600 in the 0700 work directory and removed once screen has read it.
func (s *Screen) typeCommand(ctx context.Context, e Entry, command string) error {
	wd, err := s.workDir()
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(wd, "cmd-*")
	if err != nil {
		return fmt.Errorf("screen command file: %w", err)
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(command); err != nil {
		f.Close()
		return fmt.Errorf("screen command file: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("screen command file: %w", err)
	}
	t := e.Target()
	for _, args := range [][]string{{"readbuf", f.Name()}, {"paste", "."}, {"stuff", "\r"}} {
		if _, err := s.run(ctx, append([]string{"-S", t, "-p", "0", "-X"}, args...)...); err != nil {
			return err
		}
	}
	return s.barrier(ctx, e)
}

// queryLocks serialises the -Q queries of one session (socket path -> *sync.Mutex). Screen answers a query
// through a socket with a fixed name next to the session's ("<socket>-queryX"): two queries at once share it,
// and one of them waits forever for an answer that went to the other.
var queryLocks sync.Map

func (s *Screen) queryLock(e Entry) *sync.Mutex {
	mu, _ := queryLocks.LoadOrStore(filepath.Join(s.Dir, e.Target()), &sync.Mutex{})
	return mu.(*sync.Mutex)
}

// barrier returns once the server has processed every command sent before it: -Q waits for an answer, and a
// server handles its messages in order.
func (s *Screen) barrier(ctx context.Context, e Entry) error {
	mu := s.queryLock(e)
	mu.Lock()
	defer mu.Unlock()
	_, err := s.run(ctx, "-S", e.Target(), "-Q", "number")
	return err
}

func (s *Screen) get(ctx context.Context, id string) (backend.Session, error) {
	all, err := s.List(ctx)
	if err != nil {
		return backend.Session{}, err
	}
	for _, x := range all {
		if x.ID == id {
			return x, nil
		}
	}
	return backend.Session{}, notFound(id)
}

// Attach implements backend.Backend: screen -x (multi-display, like several tmux clients), with SCREENDIR set
// through env so the exec'ing caller needs no backend-specific environment.
func (s *Screen) Attach(ctx context.Context, id string) ([]string, error) {
	e, err := s.find(ctx, id)
	if err != nil {
		return nil, err
	}
	bin := s.bin()
	if p, err := exec.LookPath(bin); err == nil {
		bin = p
	}
	envBin := "env"
	if p, err := exec.LookPath(envBin); err == nil {
		envBin = p
	}
	return []string{envBin, "-u", "STY", "-u", "WINDOW", "SCREENDIR=" + s.Dir, bin, "-x", e.Target()}, nil
}

// hardcopy returns the current window's screen (with history when withHistory), as plain text: screen's
// hardcopy has no escape sequences.
func (s *Screen) hardcopy(ctx context.Context, e Entry, withHistory bool) (string, error) {
	wd, err := s.workDir()
	if err != nil {
		return "", err
	}
	f, err := os.CreateTemp(wd, "hardcopy-*")
	if err != nil {
		return "", fmt.Errorf("screen hardcopy file: %w", err)
	}
	name := f.Name()
	f.Close()
	defer os.Remove(name)
	args := []string{"-S", e.Target(), "-X", "hardcopy"}
	if withHistory {
		args = append(args, "-h")
	}
	if _, err := s.run(ctx, append(args, name)...); err != nil {
		return "", err
	}
	if err := s.barrier(ctx, e); err != nil {
		return "", err
	}
	b, err := os.ReadFile(name)
	if err != nil {
		return "", fmt.Errorf("read screen hardcopy: %w", err)
	}
	return string(b), nil
}

// Capture implements backend.Backend: the last `lines` lines of history and screen, without escape sequences
// (screen's hardcopy has none) and without the blank lines below the cursor.
func (s *Screen) Capture(ctx context.Context, id string, lines int) (string, error) {
	e, err := s.find(ctx, id)
	if err != nil {
		return "", err
	}
	if lines <= 0 {
		lines = 5000
	}
	data, err := s.hardcopy(ctx, e, true)
	if err != nil {
		return "", err
	}
	return LastLines(data, lines), nil
}

// LastLines trims trailing blank lines and keeps the last n lines, each ending in "\n".
func LastLines(data string, n int) string {
	ls := strings.Split(strings.TrimRight(data, "\n \t"), "\n")
	if len(ls) == 1 && ls[0] == "" {
		return ""
	}
	if len(ls) > n {
		ls = ls[len(ls)-n:]
	}
	return strings.Join(ls, "\n") + "\n"
}

// Kill implements backend.Backend: SIGHUP to every window's processes, then quit after grace.
func (s *Screen) Kill(ctx context.Context, id string, grace time.Duration) error {
	e, err := s.find(ctx, id)
	if err != nil {
		return err
	}
	defer queryLocks.Delete(filepath.Join(s.Dir, e.Target()))
	hangup.Shells(children(e.PID))
	deadline := time.Now().Add(grace)
	for time.Now().Before(deadline) {
		if _, err := s.find(ctx, id); err != nil {
			s.dropState(id)
			return nil // the shells exited and screen ended the session
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	if _, err := s.run(ctx, "-S", e.Target(), "-X", "quit"); err != nil {
		if _, ferr := s.find(ctx, id); ferr == nil {
			return err
		}
	}
	s.dropState(id)
	return nil
}

// Meta implements backend.Backend. Keys must be lowercase identifiers.
func (s *Screen) Meta(ctx context.Context, id string, set map[string]string) (map[string]string, error) {
	if _, err := s.find(ctx, id); err != nil {
		return nil, err
	}
	for k := range set {
		if !keyRE.MatchString(k) {
			return nil, fmt.Errorf("meta key %q: want [a-z][a-z0-9_]*", k)
		}
	}
	if len(set) > 0 {
		if err := s.putState(id, set, false); err != nil {
			return nil, err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	st, err := loadState(s.State)
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	if e := st.Sessions[id]; e != nil {
		for k, v := range e.Meta {
			out[k] = v
		}
	}
	return out, nil
}

// putState merges meta into the session's entry (a fresh entry when create).
func (s *Screen) putState(id string, meta map[string]string, create bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, err := loadState(s.State)
	if err != nil && !create {
		return err
	}
	e := st.Sessions[id]
	if e == nil || create {
		e = &stateEntry{Created: s.clock(), Meta: map[string]string{}}
		st.Sessions[id] = e
	}
	for k, v := range meta {
		e.Meta[k] = v
	}
	return saveState(s.State, st)
}

func (s *Screen) dropState(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, err := loadState(s.State)
	if err != nil || st.Sessions[id] == nil {
		return
	}
	delete(st.Sessions, id)
	_ = saveState(s.State, st)
}
