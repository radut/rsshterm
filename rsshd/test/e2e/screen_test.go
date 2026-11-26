package e2e

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// requireScreen skips without GNU screen, or fails when RSSHD_REQUIRE_SCREEN=1 (make rsshd-test, CI).
func requireScreen(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("screen"); err != nil {
		if os.Getenv("RSSHD_REQUIRE_SCREEN") == "1" {
			t.Fatal("screen not installed but RSSHD_REQUIRE_SCREEN=1")
		}
		t.Skip("screen not installed")
	}
}

// screenDir is the daemon's SCREENDIR in this env (the default: next to the socket).
func (e *env) screenDir() string { return filepath.Join(e.dir, "run", "rsshd", "screen") }

// screenLS is `screen -ls` of the daemon's socket directory.
func (e *env) screenLS() string {
	cmd := exec.Command("screen", "-ls")
	cmd.Env = append(os.Environ(), "SCREENDIR="+e.screenDir())
	out, _ := cmd.CombinedOutput() // exit 1 when there are none
	return string(out)
}

func (e *env) quitScreens() {
	if _, err := os.Stat(e.screenDir()); err != nil {
		return
	}
	for _, line := range strings.Split(e.screenLS(), "\n") {
		if f := strings.Fields(line); len(f) > 0 && strings.Contains(f[0], ".rssh-") {
			cmd := exec.Command("screen", "-S", f[0], "-X", "quit")
			cmd.Env = append(os.Environ(), "SCREENDIR="+e.screenDir())
			_ = cmd.Run()
		}
	}
}

// waitScreenGone checks that the screen session itself is gone, not only hidden from list.
func (e *env) waitScreenGone(t *testing.T, id string) {
	t.Helper()
	waitFor(t, "screen session removed", func() bool { return !strings.Contains(e.screenLS(), ".rssh-"+id) })
	t.Logf("screen session rssh-%s is gone", id)
}

func TestScreen(t *testing.T) {
	requireScreen(t)
	e := newEnv(t, "")
	e.serve()

	t.Run("hello reports screen", func(t *testing.T) {
		c := e.rpc("screen-hello")
		h := c.call("hello", map[string]any{"client": "rSshTerm/test", "proto": []int{1}})
		if v, _ := h["backends"].(map[string]any)["screen"].(string); v == "" || h["default_backend"] != "tmux" {
			t.Fatalf("hello %v", h)
		}
		t.Logf("screen-hello  backends %v", h["backends"])
	})

	t.Run("create, attach through a pty, scrollback, close", func(t *testing.T) {
		t.Parallel()
		c := e.rpc("screen-attach")
		c.call("subscribe", nil)
		r := c.call("create", map[string]any{"backend": "screen", "name": "s1", "command": "echo created-$((6*7))"})
		id := r["id"].(string)
		if s := r["session"].(map[string]any); s["backend"] != "screen" || s["name"] != "s1" {
			t.Fatalf("created %v", s)
		}
		if !strings.Contains(e.screenLS(), ".rssh-"+id) {
			t.Fatalf("not in %s:\n%s", e.screenDir(), e.screenLS())
		}
		// rsshd attach <id> under a pty (script), type a line, detach with C-a d.
		att := exec.Command("script", "-qfec", bin+" attach "+id, "/dev/null")
		att.Env = e.vars
		in, _ := att.StdinPipe()
		att.Stdout, att.Stderr = io.Discard, io.Discard
		if err := att.Start(); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Second)
		_, _ = io.WriteString(in, "echo attached-$((40+2))\r")
		waitFor(t, "typed line in the scrollback", func() bool {
			sb := c.call("scrollback", map[string]any{"id": id})["data"].(string)
			return strings.Contains(sb, "attached-42") && strings.Contains(sb, "created-42")
		})
		_, _ = io.WriteString(in, "\x01d") // detach: the session stays
		done := make(chan error, 1)
		go func() { done <- att.Wait() }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			_ = att.Process.Kill()
			t.Fatal("attach did not end on detach")
		}
		if s := c.status(id); s["backend"] != "screen" || s["state"] != "active" {
			t.Fatalf("after detach %v", s)
		}
		t.Logf("screen-attach +%5.1fs  attached, typed, detached; session %s still active", c.elapsed(), id)
		c.call("close", map[string]any{"id": id})
		c.waitEvent(id, "closed", "reason", "closed", 3*time.Second)
		e.waitScreenGone(t, id)
	})

	t.Run("output flowing is never idle", func(t *testing.T) {
		t.Parallel()
		c := e.rpc("screen-output")
		c.call("subscribe", nil)
		r := c.call("create", map[string]any{"backend": "screen", "command": "while true; do date; sleep 0.3; done",
			"timeouts": map[string]any{"idle_s": 3, "warn_lead_s": 1, "hard_s": 0}})
		id := r["id"].(string)
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			select {
			case m := <-c.events:
				if d := m["data"].(map[string]any); d["id"] == id {
					t.Fatalf("event while output flows: %v", m)
				}
			case <-time.After(200 * time.Millisecond):
			}
		}
		if s := c.status(id); s["state"] != "active" {
			t.Fatalf("state %v", s["state"])
		}
		t.Logf("screen-output +%5.1fs  10 s at idle_s=3, no events", c.elapsed())
		c.call("close", map[string]any{"id": id})
		c.waitEvent(id, "closed", "reason", "closed", 3*time.Second)
		e.waitScreenGone(t, id)
	})

	t.Run("finish work waits for the job, then idle closes", func(t *testing.T) {
		t.Parallel()
		c := e.rpc("screen-job")
		c.call("subscribe", nil)
		id := c.call("create", map[string]any{"backend": "screen", "command": "sleep 8",
			"timeouts": map[string]any{"idle_s": 3, "warn_lead_s": 1, "hard_s": 0}})["id"].(string)
		c.waitEvent(id, "state", "state", "waiting_for_job", 8*time.Second, "closed", "expiring")
		if s := c.status(id); s["fg_running"] != true || s["fg_command"] != "sleep" {
			t.Fatalf("job not seen: %v", s)
		}
		c.waitEvent(id, "expiring", "reason", "idle", 12*time.Second, "closed")
		if c.elapsed() < 7.5 {
			t.Fatalf("warned at +%.1fs, before the 8 s job ended", c.elapsed())
		}
		// The prompt the job leaves is not activity: no way back to active.
		c.waitEvent(id, "closed", "reason", "idle", 4*time.Second, "state:active")
		t.Logf("screen-job    +%5.1fs  closed after the job ended", c.elapsed())
		e.waitScreenGone(t, id)
	})
}

// A daemon restart keeps screen sessions, their names and timeouts (state file).
func TestScreenRestartKeepsSessions(t *testing.T) {
	requireScreen(t)
	e := newEnv(t, "backend = \"screen\"\n[timeouts]\nidle = \"2h\"\n")
	stop := e.serve()
	c := e.rpc("screen-restart")
	id := c.call("create", map[string]any{"name": "keep me"})["id"].(string) // the default backend: screen
	c.call("set_timeouts", map[string]any{"id": id, "hard_s": 1234})
	stop()
	st, err := os.Stat(filepath.Join(e.dir, "state", "rsshd", "screen-sessions.json"))
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("state file %v %v", st, err)
	}
	e.serve()
	c2 := e.rpc("screen-restart-2")
	var s map[string]any
	waitFor(t, "session after restart", func() bool {
		for _, x := range c2.call("list", map[string]any{"include_foreign": true})["sessions"].([]any) {
			if m := x.(map[string]any); m["id"] == id {
				s = m
				return true
			}
		}
		return false
	})
	to := s["timeouts"].(map[string]any)
	if s["backend"] != "screen" || s["name"] != "keep me" || to["hard_s"] != 1234.0 || to["idle_s"] != 7200.0 ||
		s["state"] != "active" {
		t.Fatalf("after restart: %v", s)
	}
	t.Logf("screen-restart: session %s kept name and timeouts %v", id, to)
	c2.call("close", map[string]any{"id": id})
	e.waitScreenGone(t, id)
}
