package screen

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/backend"
)

// RequireScreen skips without screen, or fails when RSSHD_REQUIRE_SCREEN=1 (CI and make rsshd-test).
func RequireScreen(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("screen"); err != nil {
		if os.Getenv("RSSHD_REQUIRE_SCREEN") == "1" {
			t.Fatal("screen not installed but RSSHD_REQUIRE_SCREEN=1")
		}
		t.Skip("screen not installed")
	}
}

// newScreen is an isolated setup. The directory is short: screen silently fails on a long socket path.
func newScreen(t *testing.T) *Screen {
	RequireScreen(t)
	d, err := os.MkdirTemp("", "rsc")
	if err != nil {
		t.Fatal(err)
	}
	s := &Screen{Dir: filepath.Join(d, "s"), State: filepath.Join(d, "state", "screen-sessions.json")}
	t.Cleanup(func() {
		l, _ := s.ls(context.Background(), s.Dir)
		for _, e := range l {
			_, _ = s.run(context.Background(), "-S", e.Target(), "-X", "quit")
		}
		os.RemoveAll(d)
	})
	return s
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(100 * time.Millisecond) {
		if cond() {
			return
		}
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestRealScreen(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	s := newScreen(t)
	ctx := context.Background()

	if v, err := s.Version(ctx); err != nil || v == "" {
		t.Fatalf("version %q %v", v, err)
	}
	if l, err := s.List(ctx); err != nil || len(l) != 0 {
		t.Fatalf("nothing yet: %v %v", l, err)
	}
	// $HOME, ^C and \ must reach the shell as typed: the command goes through the paste buffer, not stuff.
	sess, err := s.Create(ctx, backend.CreateOpts{ID: "0000aaaa", Cwd: os.TempDir(),
		Command: `echo "hello-$((40+2))" '^C\x' && pwd`, Meta: map[string]string{"name": "a | b", "idle_s": "60"}})
	if err != nil {
		t.Fatal(err)
	}
	if sess.Backend != "screen" || sess.PanePID <= 0 || sess.Meta["name"] != "a | b" || sess.Created.IsZero() ||
		sess.PaneCommand == "" {
		t.Fatalf("created %+v", sess)
	}
	for _, d := range []string{s.Dir, filepath.Join(s.Dir, ".rsshd")} {
		if fi, err := os.Stat(d); err != nil || fi.Mode().Perm() != 0o700 {
			t.Fatalf("%s: %v %v", d, fi, err)
		}
	}
	waitFor(t, "command output", func() bool {
		out, _ := s.Capture(ctx, "0000aaaa", 100)
		return strings.Contains(out, "hello-42 ^C\\x") && strings.Contains(out, filepath.Clean(os.TempDir()))
	})
	if left, _ := filepath.Glob(filepath.Join(s.Dir, ".rsshd", "cmd-*")); len(left) != 0 {
		t.Fatalf("command file left behind: %v", left)
	}
	m, err := s.Meta(ctx, "0000aaaa", map[string]string{"idle_s": "5"})
	if err != nil || m["idle_s"] != "5" || m["name"] != "a | b" {
		t.Fatalf("meta %v %v", m, err)
	}
	if _, err := s.Meta(ctx, "0000aaaa", map[string]string{"Bad-Key": "x"}); err == nil {
		t.Fatal("bad key accepted")
	}
	// A second Screen on the same files (a restarted daemon) sees the session and its metadata.
	s2 := &Screen{Dir: s.Dir, State: s.State}
	if l, err := s2.List(ctx); err != nil || len(l) != 1 || l[0].Meta["idle_s"] != "5" {
		t.Fatalf("after restart: %+v %v", l, err)
	}
	argv, err := s.Attach(ctx, "0000aaaa")
	if err != nil || argv[len(argv)-2] != "-x" || !strings.HasSuffix(argv[len(argv)-1], ".rssh-0000aaaa") ||
		!strings.Contains(strings.Join(argv, " "), "SCREENDIR="+s.Dir) {
		t.Fatalf("attach %v %v", argv, err)
	}
	for _, f := range []func() error{
		func() error { _, err := s.Attach(ctx, "0000ffff"); return err },
		func() error { _, err := s.Capture(ctx, "0000ffff", 10); return err },
		func() error { _, err := s.Meta(ctx, "0000ffff", nil); return err },
	} {
		if err := f(); !errors.Is(err, backend.ErrNotFound) {
			t.Fatalf("missing session: %v", err)
		}
	}
	// A busy foreground job: probes see it, Kill hangs it up and the session goes away.
	typeLine(t, s, "0000aaaa", "sleep 300")
	waitFor(t, "sleep in the foreground", func() bool {
		l, _ := s.List(ctx)
		return len(l) == 1 && l[0].PaneCommand == "sleep"
	})
	if err := s.Kill(ctx, "0000aaaa", 3*time.Second); err != nil {
		t.Fatal(err)
	}
	if l, _ := s.List(ctx); len(l) != 0 {
		t.Fatalf("still listed: %+v", l)
	}
	if st, _ := loadState(s.State); len(st.Sessions) != 0 {
		t.Fatalf("state kept: %+v", st.Sessions)
	}
	if err := s.Kill(ctx, "0000aaaa", time.Second); !errors.Is(err, backend.ErrNotFound) {
		t.Fatalf("kill twice: %v", err)
	}
	if _, err := s.Foreign(ctx); err != nil {
		t.Fatalf("foreign: %v", err)
	}
}

func typeLine(t *testing.T, s *Screen, id, line string) {
	t.Helper()
	e, err := s.find(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.typeCommand(context.Background(), e, line); err != nil {
		t.Fatal(err)
	}
}

// Output moves the activity clock; a silent session keeps it.
func TestActivity(t *testing.T) {
	s := newScreen(t)
	ctx := context.Background()
	clock := time.Now()
	s.now = func() time.Time { return clock }
	if _, err := s.Create(ctx, backend.CreateOpts{ID: "0000cccc"}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(500 * time.Millisecond) // the prompt is drawn
	first, _ := s.List(ctx)
	clock = clock.Add(time.Hour) // far beyond the tty times
	again, _ := s.List(ctx)
	if len(first) != 1 || len(again) != 1 || again[0].ActivityAt.After(clock.Add(-time.Minute)) {
		t.Fatalf("silent session got activity: %v -> %v", first, again)
	}
	typeLine(t, s, "0000cccc", "echo out")
	waitFor(t, "output seen as activity", func() bool {
		l, _ := s.List(ctx)
		return len(l) == 1 && l[0].ActivityAt.Equal(clock)
	})
}

// A shell that ignores SIGHUP still goes: quit after the grace period.
func TestKillAfterGrace(t *testing.T) {
	s := newScreen(t)
	ctx := context.Background()
	if _, err := s.Create(ctx, backend.CreateOpts{ID: "0000bbbb", Command: "trap '' HUP"}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	start := time.Now()
	if err := s.Kill(ctx, "0000bbbb", 500*time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) < 400*time.Millisecond {
		t.Fatal("did not wait for the grace period")
	}
	if l, _ := s.List(ctx); len(l) != 0 {
		t.Fatalf("still listed: %+v", l)
	}
}

// The user's own sessions are foreign, never managed.
func TestForeign(t *testing.T) {
	s := newScreen(t)
	user, err := os.MkdirTemp("", "rsu")
	if err != nil {
		t.Fatal(err)
	}
	_ = os.Chmod(user, 0o700)
	t.Setenv("SCREENDIR", user)
	t.Cleanup(func() {
		_ = exec.Command("screen", "-S", "mine", "-X", "quit").Run()
		os.RemoveAll(user)
	})
	if out, err := exec.Command("screen", "-dmS", "mine").CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	waitFor(t, "foreign session", func() bool {
		f, err := s.Foreign(context.Background())
		return err == nil && len(f) == 1 && f[0].Name == "mine" && f[0].Backend == "screen" &&
			f[0].Attach[0] == "screen" && strings.HasSuffix(f[0].Attach[2], ".mine")
	})
	if l, _ := s.List(context.Background()); len(l) != 0 {
		t.Fatalf("foreign session managed: %+v", l)
	}
}

// Parallel creates share the built-in screenrc: writing it must not race.
func TestParallelCreate(t *testing.T) {
	s := newScreen(t)
	ctx := context.Background()
	ids := []string{"000000d1", "000000d2", "000000d3", "000000d4"}
	errs := make(chan error, len(ids))
	for _, id := range ids {
		go func() { _, err := s.Create(ctx, backend.CreateOpts{ID: id}); errs <- err }()
	}
	for range ids {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	if l, err := s.List(ctx); err != nil || len(l) != len(ids) {
		t.Fatalf("list %d %v", len(l), err)
	}
	if left, _ := filepath.Glob(filepath.Join(s.Dir, ".rsshd", "screenrc-*")); len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}
}

// Queries to one session at once (parallel Lists each take a hardcopy of every session) all get their answer:
// screen replies through one fixed query socket per session, so unserialised they hang.
func TestParallelQueries(t *testing.T) {
	s := newScreen(t)
	ctx := context.Background()
	if _, err := s.Create(ctx, backend.CreateOpts{ID: "000000e1"}); err != nil {
		t.Fatal(err)
	}
	e, err := s.find(ctx, "000000e1")
	if err != nil {
		t.Fatal(err)
	}
	const workers, rounds = 6, 15
	errs := make(chan error, workers)
	for range workers {
		go func() {
			for range rounds {
				if err := s.barrier(ctx, e); err != nil {
					errs <- err
					return
				}
			}
			errs <- nil
		}()
	}
	for range workers {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
}
