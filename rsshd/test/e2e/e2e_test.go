// Package e2e drives the real rsshd binary against a real tmux, through `rsshd rpc` exactly as the app does.
// The scenarios are those of docs/session-daemon/poc/02-idle-foreground.sh (silent job, output loop, htop),
// now with the daemon's timeouts. Run in docker: make rsshd-test.
package e2e

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

var bin string // the rsshd binary built for this run

func TestMain(m *testing.M) {
	if _, err := exec.LookPath("tmux"); err != nil {
		if os.Getenv("RSSHD_REQUIRE_TMUX") == "1" {
			fmt.Println("tmux not installed but RSSHD_REQUIRE_TMUX=1")
			os.Exit(1)
		}
		fmt.Println("skip: tmux not installed")
		os.Exit(0)
	}
	d, err := os.MkdirTemp("", "rsshd-e2e-bin")
	if err != nil {
		panic(err)
	}
	bin = filepath.Join(d, "rsshd")
	out, err := exec.Command("go", "build", "-o", bin, "../../cmd/rsshd").CombinedOutput()
	if err != nil {
		fmt.Printf("build rsshd: %v\n%s", err, out)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(d)
	os.Exit(code)
}

// env is one isolated user setup: own config dir, runtime dir (socket) and tmux server.
type env struct {
	t        *testing.T
	dir      string
	vars     []string
	tmuxSock string
}

func newEnv(t *testing.T, config string) *env {
	d, err := os.MkdirTemp("", "rsshd-e2e") // short: unix socket paths are limited
	if err != nil {
		t.Fatal(err)
	}
	tmuxSock := fmt.Sprintf("rsshd-e2e-%d-%d", os.Getpid(), time.Now().UnixNano())
	e := &env{t: t, dir: d, tmuxSock: tmuxSock}
	cfg := filepath.Join(d, "cfg", "rsshd", "config.toml")
	if err := os.MkdirAll(filepath.Dir(cfg), 0o700); err != nil {
		t.Fatal(err)
	}
	doc := fmt.Sprintf("tmux_socket = %q\ntmux_conf = \"/dev/null\"\npoll_interval = \"200ms\"\nclose_grace = \"1s\"\n%s",
		tmuxSock, config)
	if err := os.WriteFile(cfg, []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	e.vars = append(os.Environ(), "XDG_CONFIG_HOME="+filepath.Join(d, "cfg"), "XDG_RUNTIME_DIR="+filepath.Join(d, "run"),
		"XDG_STATE_HOME="+filepath.Join(d, "state"), "SHELL=/bin/bash", "TERM=xterm-256color")
	t.Cleanup(func() {
		_ = exec.Command("tmux", "-L", tmuxSock, "kill-server").Run()
		e.quitScreens()
		os.RemoveAll(d)
	})
	return e
}

// serve starts `rsshd serve` as a child and returns a stop function.
func (e *env) serve() func() {
	cmd := exec.Command(bin, "serve")
	cmd.Env = e.vars
	logf, err := os.Create(filepath.Join(e.dir, "serve.log"))
	if err != nil {
		e.t.Fatal(err)
	}
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Start(); err != nil {
		e.t.Fatal(err)
	}
	var once sync.Once
	stop := func() {
		once.Do(func() {
			_ = cmd.Process.Signal(os.Interrupt)
			_ = cmd.Wait()
			logf.Close()
		})
	}
	e.t.Cleanup(stop)
	return stop
}

// client is one `rsshd rpc` process.
type client struct {
	t      *testing.T
	name   string
	start  time.Time
	stdin  io.WriteCloser
	mu     sync.Mutex
	next   int
	reply  map[int]chan map[string]any
	events chan map[string]any
	cmd    *exec.Cmd
}

func (e *env) rpc(name string) *client {
	cmd := exec.Command(bin, "rpc")
	cmd.Env = e.vars
	cmd.Stderr = os.Stderr
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		e.t.Fatal(err)
	}
	c := &client{t: e.t, name: name, start: time.Now(), stdin: stdin, reply: map[int]chan map[string]any{},
		events: make(chan map[string]any, 256), cmd: cmd}
	go func() {
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 0, 1<<16), 1<<22)
		for sc.Scan() {
			var m map[string]any
			if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
				e.t.Errorf("%s: bad line %q", name, sc.Text())
				continue
			}
			if m["event"] != nil {
				c.events <- m
				continue
			}
			c.mu.Lock()
			ch := c.reply[int(m["id"].(float64))]
			c.mu.Unlock()
			if ch != nil {
				ch <- m
			}
		}
		close(c.events)
	}()
	e.t.Cleanup(func() { stdin.Close(); _ = cmd.Wait() })
	return c
}

func (c *client) call(op string, args any) map[string]any {
	c.t.Helper()
	c.mu.Lock()
	c.next++
	id := c.next
	ch := make(chan map[string]any, 1)
	c.reply[id] = ch
	c.mu.Unlock()
	b, _ := json.Marshal(map[string]any{"v": 1, "id": id, "op": op, "args": args})
	if _, err := c.stdin.Write(append(b, '\n')); err != nil {
		c.t.Fatal(err)
	}
	select {
	case m := <-ch:
		if m["ok"] != true {
			c.t.Fatalf("%s: %v", op, m)
		}
		r, _ := m["result"].(map[string]any)
		return r
	case <-time.After(15 * time.Second):
		c.t.Fatalf("%s: no reply", op)
		return nil
	}
}

func (c *client) status(id string) map[string]any {
	c.t.Helper()
	return c.call("status", map[string]any{"id": id})["session"].(map[string]any)
}

// waitEvent waits for an event about id; it fails on any event in forbid.
func (c *client) waitEvent(id, event, field, value string, within time.Duration, forbid ...string) map[string]any {
	c.t.Helper()
	deadline := time.After(within)
	for {
		select {
		case m, ok := <-c.events:
			if !ok {
				c.t.Fatal("rpc closed")
			}
			d := m["data"].(map[string]any)
			if d["id"] != id {
				continue
			}
			b, _ := json.Marshal(m)
			c.t.Logf("%-12s +%5.1fs  event %s", c.name, c.elapsed(), b)
			key := m["event"].(string) + ":" + fmt.Sprint(d["state"], d["reason"])
			for _, f := range forbid {
				if strings.Contains(key, f) {
					c.t.Fatalf("forbidden event %v", m)
				}
			}
			if m["event"] == event && d[field] == value {
				return m
			}
		case <-deadline:
			c.t.Fatalf("no %s %s=%s for %s within %v", event, field, value, id, within)
			return nil
		}
	}
}

func (c *client) elapsed() float64 { return time.Since(c.start).Seconds() }

func TestDaemon(t *testing.T) {
	e := newEnv(t, "")
	e.serve()

	t.Run("finish work waits for the running job, then closes", func(t *testing.T) {
		t.Parallel()
		c := e.rpc("finish-work")
		c.call("subscribe", nil)
		// idle 3 s with a 1 s warning: the idle timer runs out after ~2 s of silence. The job runs 8 s silently.
		r := c.call("create", map[string]any{"name": "apt", "command": "sleep 8; echo job-done",
			"timeouts": map[string]any{"idle_s": 3, "warn_lead_s": 1, "hard_s": 0}})
		id := r["id"].(string)
		t.Logf("finish-work  +%5.1fs  created %s", c.elapsed(), id)
		c.waitEvent(id, "state", "state", "waiting_for_job", 6*time.Second, "closed", "expiring")
		s := c.status(id)
		t.Logf("finish-work  +%5.1fs  waiting: fg_running=%v fg_command=%v", c.elapsed(), s["fg_running"], s["fg_command"])
		if s["fg_running"] != true || s["fg_command"] != "sleep" {
			t.Fatalf("job not seen: %v", s)
		}
		c.waitEvent(id, "expiring", "reason", "idle", 10*time.Second, "closed")
		jobDone := c.elapsed()
		if jobDone < 7.5 {
			t.Fatalf("warned at +%.1fs, before the 8 s job ended", jobDone)
		}
		sb := c.call("scrollback", map[string]any{"id": id})["data"].(string)
		if !strings.Contains(sb, "job-done") {
			t.Fatalf("job output missing from scrollback: %q", sb)
		}
		c.waitEvent(id, "closed", "reason", "idle", 4*time.Second)
		t.Logf("finish-work  +%5.1fs  closed after the job ended at ~+8s", c.elapsed())
		e.waitGone(t, id)
	})

	t.Run("hard timeout closes a full-screen program", func(t *testing.T) {
		t.Parallel()
		c := e.rpc("hard-htop")
		c.call("subscribe", nil)
		r := c.call("create", map[string]any{"name": "top", "command": "htop", "cols": 100, "rows": 30,
			"timeouts": map[string]any{"idle_s": 3600, "hard_s": 6, "warn_lead_s": 2}})
		id := r["id"].(string)
		t.Logf("hard-htop    +%5.1fs  created %s", c.elapsed(), id)
		waitFor(t, "htop on the alternate screen", func() bool {
			s := c.status(id)
			return s["alt_screen"] == true && s["fg_command"] == "htop" && s["fg_running"] == true
		})
		t.Logf("hard-htop    +%5.1fs  htop running, alt_screen=true", c.elapsed())
		exp := c.waitEvent(id, "expiring", "reason", "hard", 8*time.Second, "idle", "closed")
		t.Logf("hard-htop    +%5.1fs  expiring at %v", c.elapsed(), exp["data"].(map[string]any)["at"])
		c.waitEvent(id, "closed", "reason", "hard", 5*time.Second, "idle")
		if c.elapsed() < 6 {
			t.Fatalf("closed at +%.1fs, before the 6 s hard deadline", c.elapsed())
		}
		e.waitGone(t, id)
	})

	t.Run("output flowing is never idle", func(t *testing.T) {
		t.Parallel()
		c := e.rpc("output")
		c.call("subscribe", nil)
		r := c.call("create", map[string]any{"name": "logs", "command": "while true; do date; sleep 0.3; done",
			"timeouts": map[string]any{"idle_s": 3, "warn_lead_s": 1, "hard_s": 0}})
		id := r["id"].(string)
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			select {
			case m := <-c.events:
				if d := m["data"].(map[string]any); d["id"] == id {
					// Even waiting_for_job is wrong here: the loop's output must keep the idle clock at zero.
					t.Fatalf("event while output flows: %v", m)
				}
			case <-time.After(200 * time.Millisecond):
			}
		}
		s := c.status(id)
		t.Logf("output       +%5.1fs  10 s at idle_s=3: state=%v fg_running=%v, no events", c.elapsed(), s["state"],
			s["fg_running"])
		if s["state"] != "active" {
			t.Fatalf("state %v", s["state"])
		}
		c.call("close", map[string]any{"id": id})
		c.waitEvent(id, "closed", "reason", "closed", 3*time.Second)
		e.waitGone(t, id)
	})

	t.Run("silent shell without a job warns and closes", func(t *testing.T) {
		t.Parallel()
		c := e.rpc("idle")
		c.call("subscribe", nil)
		id := c.call("create", map[string]any{"timeouts": map[string]any{"idle_s": 3, "warn_lead_s": 1}})["id"].(string)
		c.waitEvent(id, "expiring", "reason", "idle", 8*time.Second, "waiting_for_job", "closed")
		c.waitEvent(id, "closed", "reason", "idle", 4*time.Second)
		t.Logf("idle         +%5.1fs  idle shell closed", c.elapsed())
	})

	t.Run("extend withdraws the warning", func(t *testing.T) {
		t.Parallel()
		c := e.rpc("extend")
		c.call("subscribe", nil)
		id := c.call("create", map[string]any{"timeouts": map[string]any{"idle_s": 3, "warn_lead_s": 2}})["id"].(string)
		c.waitEvent(id, "expiring", "reason", "idle", 8*time.Second, "closed")
		c.call("extend", map[string]any{"id": id, "which": "idle"}) // +1 h from the config default
		c.waitEvent(id, "state", "state", "active", 2*time.Second)
		time.Sleep(3 * time.Second)
		if s := c.status(id); s["state"] != "active" {
			t.Fatalf("after extend: %v", s)
		}
		t.Logf("extend       +%5.1fs  still active 3 s after the old close time", c.elapsed())
		c.call("close", map[string]any{"id": id})
	})
}

// A daemon restart keeps sessions and their timeouts (all state is in tmux options).
func TestRestartKeepsSessions(t *testing.T) {
	e := newEnv(t, "[timeouts]\nidle = \"2h\"\n")
	stop := e.serve()
	c := e.rpc("restart")
	id := c.call("create", map[string]any{"name": "keep me"})["id"].(string)
	c.call("set_timeouts", map[string]any{"id": id, "hard_s": 1234})
	stop()
	e.serve()
	c2 := e.rpc("restart-2")
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
	if s["name"] != "keep me" || to["hard_s"] != 1234.0 || to["idle_s"] != 7200.0 || s["state"] != "active" {
		t.Fatalf("after restart: %v", s)
	}
	t.Logf("restart: session %s kept name and timeouts %v", id, to)
}

// rpc with no daemon running starts one (the install.sh case without a service unit).
func TestRPCStartsDaemon(t *testing.T) {
	e := newEnv(t, "")
	c := e.rpc("autostart")
	h := c.call("hello", map[string]any{"client": "rSshTerm/test", "proto": []int{1}})
	if h["proto"] != 1.0 || h["backends"].(map[string]any)["tmux"] == nil {
		t.Fatalf("hello %v", h)
	}
	t.Logf("autostart: hello %v", h)
	t.Cleanup(func() { _ = exec.Command("pkill", "-f", bin+" serve").Run() })

	var doc map[string]any
	cmd := exec.Command(bin, "doctor", "--json")
	cmd.Env = e.vars
	out, _ := cmd.Output() // exit 1 when the service unit is missing, as in this container
	if err := json.Unmarshal(out, &doc); err != nil {
		t.Fatalf("doctor --json: %v %s", err, out)
	}
	for _, m := range doc["missing"].([]any) {
		if m == "daemon" || m == "tmux" {
			t.Fatalf("doctor says %v is missing: %s", m, out)
		}
	}
	att := exec.Command(bin, "attach", "0000dead")
	att.Env = e.vars
	if b, err := att.CombinedOutput(); err == nil || !strings.Contains(string(b), "no session") {
		t.Fatalf("attach unknown: %v %s", err, b)
	}
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(200 * time.Millisecond) {
		if cond() {
			return
		}
	}
	t.Fatalf("timed out waiting for %s", what)
}

// waitGone checks that the tmux session itself is gone, not only hidden from list.
func (e *env) waitGone(t *testing.T, id string) {
	t.Helper()
	waitFor(t, "tmux session removed", func() bool {
		return exec.Command("tmux", "-L", e.tmuxSock, "has-session", "-t", "=rssh-"+id).Run() != nil
	})
	t.Logf("tmux session rssh-%s is gone", id)
}
