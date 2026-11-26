package tmux

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/backend"
)

func TestParseVersion(t *testing.T) {
	for in, want := range map[string]string{"tmux 3.4\n": "3.4", "tmux next-3.5": "3.5", "tmux 3.3a": "3.3a"} {
		if got := ParseVersion(in); got != want {
			t.Errorf("%q -> %q, want %q", in, got, want)
		}
	}
}

func TestValidID(t *testing.T) {
	for id, want := range map[string]bool{"0123abcd": true, "0123ABCD": false, "abc": false, "../../x1": false,
		"0123abcde": false} {
		if ValidID(id) != want {
			t.Errorf("%q", id)
		}
	}
}

func TestParseList(t *testing.T) {
	out := strings.Join([]string{
		"rssh-0123abcd|1700000000|1700000050|1|4242|0|my%20build|60|bash",
		"rssh-deadbeef|1700000001|1700000002|0|4343|1||0|htop|with|bars",
		"main|1700000001|1700000002|0|1|0||0|bash", // the user's session on the same server: skipped
		"rssh-nothex!|1|1|0|1|0||0|bash",
		"",
	}, "\n")
	got, err := ParseList(out, []string{"name", "idle_s"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d sessions", len(got))
	}
	a, b := got[0], got[1]
	if a.ID != "0123abcd" || a.PanePID != 4242 || a.AttachedClients != 1 || a.AltScreen || a.PaneCommand != "bash" ||
		a.Meta["name"] != "my build" || a.Meta["idle_s"] != "60" || a.ActivityAt.Unix() != 1700000050 ||
		a.Created.Unix() != 1700000000 {
		t.Fatalf("a = %+v", a)
	}
	if b.PaneCommand != "htop|with|bars" || !b.AltScreen || len(b.Meta) != 1 {
		t.Fatalf("b = %+v", b)
	}
	if _, err := ParseList("rssh-0123abcd|1|2", nil); err == nil {
		t.Fatal("short line must fail")
	}
}

func TestParseWindowActivity(t *testing.T) {
	m := ParseWindowActivity("rssh-a|10\nrssh-a|30\nrssh-a|20\nmain|99\nbroken\n")
	if m["a"].Unix() != 30 || len(m) != 1 {
		t.Fatalf("%v", m)
	}
}

func TestErrorClassification(t *testing.T) {
	ns := &Error{Msg: "no server running on /tmp/tmux-0/x"}
	if !noServer(ns) || !noSession(fmt.Errorf("w: %w", ns)) {
		t.Fatal("no server")
	}
	if !noSession(&Error{Msg: "can't find session: =rssh-x"}) || noSession(errors.New("other")) || noServer(nil) {
		t.Fatal("no session")
	}
	if !strings.Contains((&Error{Args: []string{"a"}, Msg: "m"}).Error(), "tmux a: m") {
		t.Fatal("Error()")
	}
}

func TestBadIDs(t *testing.T) {
	tm := &Tmux{Socket: "x", Conf: os.DevNull}
	ctx := context.Background()
	if _, err := tm.Create(ctx, backend.CreateOpts{ID: "bad"}); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
	if _, err := tm.Attach(ctx, "../x"); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
	if _, err := tm.Capture(ctx, "x", 1); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
	if err := tm.Kill(ctx, "x", 0); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
	if _, err := tm.Meta(ctx, "x", nil); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
}

// RequireTmux skips without tmux, or fails when RSSHD_REQUIRE_TMUX=1 (CI and make rsshd-test).
func RequireTmux(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("tmux"); err != nil {
		if os.Getenv("RSSHD_REQUIRE_TMUX") == "1" {
			t.Fatal("tmux not installed but RSSHD_REQUIRE_TMUX=1")
		}
		t.Skip("tmux not installed")
	}
}

func newServer(t *testing.T) *Tmux {
	RequireTmux(t)
	tm := &Tmux{Socket: fmt.Sprintf("rsshd-test-%d-%d", os.Getpid(), time.Now().UnixNano()), Conf: os.DevNull,
		MetaKeys: []string{"name", "idle_s"}}
	t.Cleanup(func() { _, _ = tm.run(context.Background(), "kill-server") })
	return tm
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

func TestRealTmux(t *testing.T) {
	tm := newServer(t)
	ctx := context.Background()

	if v, err := tm.Version(ctx); err != nil || v == "" {
		t.Fatalf("version %q %v", v, err)
	}
	if l, err := tm.List(ctx); err != nil || len(l) != 0 {
		t.Fatalf("no server yet: %v %v", l, err)
	}
	if tm.ServerPID(ctx) != 0 {
		t.Fatal("server pid without server")
	}
	s, err := tm.Create(ctx, backend.CreateOpts{ID: "0000aaaa", Cols: 100, Rows: 30, Cwd: os.TempDir(),
		Command: "echo hello-$((40+2))", Meta: map[string]string{"name": "a | b", "idle_s": "60"}})
	if err != nil {
		t.Fatal(err)
	}
	if s.PanePID <= 0 || s.Meta["name"] != "a | b" || s.Created.IsZero() {
		t.Fatalf("created %+v", s)
	}
	waitFor(t, "command output", func() bool {
		out, _ := tm.Capture(ctx, "0000aaaa", 100)
		return strings.Contains(out, "hello-42")
	})
	m, err := tm.Meta(ctx, "0000aaaa", map[string]string{"idle_s": "5"})
	if err != nil || m["idle_s"] != "5" || m["name"] != "a | b" {
		t.Fatalf("meta %v %v", m, err)
	}
	if _, err := tm.Meta(ctx, "0000aaaa", map[string]string{"Bad-Key": "x"}); err == nil {
		t.Fatal("bad key accepted")
	}
	argv, err := tm.Attach(ctx, "0000aaaa")
	if err != nil || argv[len(argv)-1] != "=rssh-0000aaaa" {
		t.Fatalf("attach %v %v", argv, err)
	}
	if _, err := tm.Attach(ctx, "0000ffff"); !errors.Is(err, backend.ErrNotFound) {
		t.Fatalf("attach missing: %v", err)
	}
	if _, err := tm.Capture(ctx, "0000ffff", 10); !errors.Is(err, backend.ErrNotFound) {
		t.Fatalf("capture missing: %v", err)
	}
	if tm.ServerPID(ctx) <= 0 {
		t.Fatal("server pid")
	}
	// A busy foreground job: Kill hangs it up and the session goes away.
	if _, err := tm.run(ctx, "send-keys", "-t", paneTarget("0000aaaa"), "sleep 300", "Enter"); err != nil {
		t.Fatal(err)
	}
	if err := tm.Kill(ctx, "0000aaaa", 3*time.Second); err != nil {
		t.Fatal(err)
	}
	if l, _ := tm.List(ctx); len(l) != 0 {
		t.Fatalf("still listed: %+v", l)
	}
	if err := tm.Kill(ctx, "0000aaaa", time.Second); !errors.Is(err, backend.ErrNotFound) {
		t.Fatalf("kill twice: %v", err)
	}
	if _, err := tm.Foreign(ctx); err != nil {
		t.Fatalf("foreign: %v", err)
	}
}

// A shell that ignores SIGHUP still goes: kill-session after the grace period.
func TestKillAfterGrace(t *testing.T) {
	tm := newServer(t)
	ctx := context.Background()
	if _, err := tm.Create(ctx, backend.CreateOpts{ID: "0000bbbb"}); err != nil {
		t.Fatal(err)
	}
	if _, err := tm.run(ctx, "send-keys", "-t", paneTarget("0000bbbb"), "trap '' HUP", "Enter"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	start := time.Now()
	if err := tm.Kill(ctx, "0000bbbb", 500*time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) < 400*time.Millisecond {
		t.Fatal("did not wait for the grace period")
	}
	if l, _ := tm.List(ctx); len(l) != 0 {
		t.Fatalf("still listed: %+v", l)
	}
}
