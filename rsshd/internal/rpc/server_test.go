package rpc

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend/fake"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend/multi"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/probe"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/timeout"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/watch"
)

var pol = timeout.Policy{Idle: time.Hour, Hard: 24 * time.Hour, WarnLead: 5 * time.Minute, FinishWork: true}

type client struct {
	t     *testing.T
	in    *io.PipeWriter
	lines chan map[string]any
	next  int64
	done  chan error
}

func start(t *testing.T) (*client, *fake.Backend, *watch.Watcher) {
	be := fake.New()
	c, w := startWith(t, be)
	return c, be, w
}

func startWith(t *testing.T, be backend.Backend) (*client, *watch.Watcher) {
	w := watch.New(watch.Options{Backend: be, Prober: probe.Local{TPGID: func(_ context.Context, pid int) (int, error) {
		return pid, nil
	}}, Defaults: pol, Interval: time.Hour})
	var n atomic.Int64
	srv := NewServer(Deps{Backend: be, Watcher: w, Defaults: pol, ExtendIdle: time.Hour, ExtendHard: 24 * time.Hour,
		Version: "1.0.0-test", Started: time.Now(),
		Hello: func(context.Context) HelloResult {
			return HelloResult{Backends: map[string]string{"tmux": "3.4"}, Caps: Caps{OS: "linux"}, Missing: []string{"reptyr"}}
		},
		ServerPID: func(context.Context) int { return 77 },
		NewID:     func() string { return fmt.Sprintf("%08x", n.Add(1)) },
	})
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	c := &client{t: t, in: inW, lines: make(chan map[string]any, 100), done: make(chan error, 1)}
	ctx, cancel := context.WithCancel(context.Background())
	go func() { c.done <- srv.Serve(ctx, inR, outW); outW.Close() }()
	go func() {
		sc := bufio.NewScanner(outR)
		for sc.Scan() {
			var m map[string]any
			if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
				t.Errorf("bad line %q", sc.Text())
			}
			c.lines <- m
		}
		close(c.lines)
	}()
	t.Cleanup(func() { inW.Close(); cancel() })
	return c, w
}

func (c *client) raw(line string) {
	if _, err := io.WriteString(c.in, line+"\n"); err != nil {
		c.t.Fatal(err)
	}
}

func (c *client) read() map[string]any {
	select {
	case m := <-c.lines:
		return m
	case <-time.After(5 * time.Second):
		c.t.Fatal("no reply")
		return nil
	}
}

func (c *client) call(op string, args any) map[string]any {
	c.t.Helper()
	c.next++
	b, _ := json.Marshal(map[string]any{"v": 1, "id": c.next, "op": op, "args": args})
	c.raw(string(b))
	for {
		m := c.read()
		if m["event"] != nil {
			continue
		}
		if m["v"] != 1.0 || m["id"] != float64(c.next) {
			c.t.Fatalf("reply %v to id %d", m, c.next)
		}
		return m
	}
}

func ok(t *testing.T, m map[string]any) map[string]any {
	t.Helper()
	if m["ok"] != true {
		t.Fatalf("not ok: %v", m)
	}
	r, _ := m["result"].(map[string]any)
	return r
}

func code(t *testing.T, m map[string]any) string {
	t.Helper()
	if m["ok"] != false {
		t.Fatalf("expected an error: %v", m)
	}
	return m["error"].(map[string]any)["code"].(string)
}

func TestHello(t *testing.T) {
	c, _, _ := start(t)
	r := ok(t, c.call("hello", map[string]any{"client": "rSshTerm/1.0", "proto": []int{1, 2}}))
	if r["proto"] != 1.0 || r["version"] != "1.0.0-test" || r["default_backend"] != "tmux" ||
		r["missing"].([]any)[0] != "reptyr" || r["caps"].(map[string]any)["os"] != "linux" {
		t.Fatalf("hello %v", r)
	}
	if got := code(t, c.call("hello", map[string]any{"proto": []int{2}})); got != CodeUnsupportedVer {
		t.Fatal(got)
	}
}

func TestCreateListStatusScrollbackClose(t *testing.T) {
	c, be, _ := start(t)
	r := ok(t, c.call("create", map[string]any{"name": "build", "cols": 120, "rows": 40, "command": "make",
		"timeouts": map[string]any{"idle_s": 60, "finish_work": false}}))
	id := r["id"].(string)
	s := r["session"].(map[string]any)
	to := s["timeouts"].(map[string]any)
	if id != "00000001" || s["name"] != "build" || s["state"] != "active" || to["idle_s"] != 60.0 ||
		to["hard_s"] != 86400.0 || to["finish_work"] != false || to["warn_lead_s"] != 300.0 {
		t.Fatalf("create %v", r)
	}
	if s["deadlines"].(map[string]any)["idle"] == nil {
		t.Fatal("idle deadline missing")
	}
	ok(t, c.call("create", map[string]any{"timeouts": map[string]any{"idle_s": 0, "hard_s": 0}}))

	l := ok(t, c.call("list", map[string]any{"include_foreign": true}))
	sessions := l["sessions"].([]any)
	if len(sessions) != 2 || l["foreign"].([]any)[0].(map[string]any)["name"] != "main" {
		t.Fatalf("list %v", l)
	}
	second := sessions[1].(map[string]any)
	if len(second["deadlines"].(map[string]any)) != 0 {
		t.Fatalf("disabled timeouts must have no deadlines: %v", second)
	}
	if l := ok(t, c.call("list", nil)); len(l["foreign"].([]any)) != 0 {
		t.Fatal("foreign without include_foreign")
	}

	st := ok(t, c.call("status", map[string]any{"id": id}))
	if st["session"].(map[string]any)["id"] != id {
		t.Fatal(st)
	}
	sb := ok(t, c.call("scrollback", map[string]any{"id": id, "lines": 10}))
	if sb["data"] != "history of 00000001 (10)\n" {
		t.Fatal(sb)
	}
	ok(t, c.call("close", map[string]any{"id": id}))
	time.Sleep(50 * time.Millisecond)
	if _, alive := be.Get(id); alive {
		t.Fatal("not killed")
	}
	if got := code(t, c.call("status", map[string]any{"id": id})); got != CodeNotFound {
		t.Fatal(got)
	}
}

func TestSetTimeoutsAndExtend(t *testing.T) {
	c, _, _ := start(t)
	id := ok(t, c.call("create", nil))["id"].(string)
	r := ok(t, c.call("set_timeouts", map[string]any{"id": id, "idle_s": 120, "warn_lead_s": 30}))
	to := r["session"].(map[string]any)["timeouts"].(map[string]any)
	if to["idle_s"] != 120.0 || to["warn_lead_s"] != 30.0 || to["hard_s"] != 86400.0 {
		t.Fatal(to)
	}
	before := ok(t, c.call("status", map[string]any{"id": id}))["session"].(map[string]any)["deadlines"].(map[string]any)
	r = ok(t, c.call("extend", map[string]any{"id": id, "which": "hard"}))
	after := r["session"].(map[string]any)["deadlines"].(map[string]any)
	b, _ := time.Parse(time.RFC3339, before["hard"].(string))
	a, _ := time.Parse(time.RFC3339, after["hard"].(string))
	if a.Sub(b) != 24*time.Hour {
		t.Fatalf("hard moved %v", a.Sub(b))
	}
	ok(t, c.call("extend", map[string]any{"id": id, "by_s": 600}))
	if got := code(t, c.call("extend", map[string]any{"id": id, "which": "soon"})); got != CodeBadRequest {
		t.Fatal(got)
	}
	if got := code(t, c.call("extend", map[string]any{"id": "nope"})); got != CodeNotFound {
		t.Fatal(got)
	}
	if got := code(t, c.call("set_timeouts", map[string]any{"id": id, "idle_s": -1})); got != CodeBadRequest {
		t.Fatal(got)
	}
	if got := code(t, c.call("set_timeouts", map[string]any{"id": "nope"})); got != CodeNotFound {
		t.Fatal(got)
	}
}

// create.backend picks the multiplexer; unknown or missing ones are backend_error with a clear message.
func TestCreateBackend(t *testing.T) {
	tm, sc := fake.New(), fake.New()
	sc.Label = "screen"
	m, err := multi.New("tmux", tm, sc)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := startWith(t, m)
	r := ok(t, c.call("create", map[string]any{"backend": "screen", "name": "s"}))
	if s := r["session"].(map[string]any); s["backend"] != "screen" {
		t.Fatalf("session %v", s)
	}
	if _, found := sc.Get(r["id"].(string)); !found {
		t.Fatal("not created in screen")
	}
	if s := ok(t, c.call("create", nil))["session"].(map[string]any); s["backend"] != "tmux" {
		t.Fatalf("default %v", s)
	}
	m2 := c.call("create", map[string]any{"backend": "zellij"})
	if code(t, m2) != CodeBackend || !strings.Contains(fmt.Sprint(m2["error"]), "tmux, screen") {
		t.Fatal(m2)
	}
	sc.Missing = true
	m3 := c.call("create", map[string]any{"backend": "screen"})
	if code(t, m3) != CodeBackend || !strings.Contains(fmt.Sprint(m3["error"]), "not installed") {
		t.Fatal(m3)
	}
}

func TestErrors(t *testing.T) {
	c, _, _ := start(t)
	tests := []struct {
		op   string
		args any
		want string
	}{
		{"teleport", nil, CodeUnknownOp},
		{"adopt", map[string]any{"pid": 1}, CodeNotImplemented},
		{"adopt_candidates", nil, CodeNotImplemented},
		{"create", map[string]any{"backend": "zellij"}, CodeBackend},
		{"create", map[string]any{"name": strings.Repeat("x", 65)}, CodeBadRequest},
		{"create", map[string]any{"command": strings.Repeat("x", 5000)}, CodeBadRequest},
		{"create", map[string]any{"cwd": "relative"}, CodeBadRequest},
		{"create", map[string]any{"cols": 5000}, CodeBadRequest},
		{"create", map[string]any{"timeouts": map[string]any{"hard_s": -5}}, CodeBadRequest},
		{"create", map[string]any{"cols": "wide"}, CodeBadRequest},
		{"scrollback", map[string]any{"id": "x", "lines": -1}, CodeBadRequest},
		{"scrollback", map[string]any{"id": "x"}, CodeNotFound},
		{"close", map[string]any{"id": "x"}, CodeNotFound},
		{"status", map[string]any{"id": 5}, CodeBadRequest},
		{"list", map[string]any{"include_foreign": "yes"}, CodeBadRequest},
		{"hello", map[string]any{"proto": "one"}, CodeBadRequest},
	}
	for _, tc := range tests {
		if got := code(t, c.call(tc.op, tc.args)); got != tc.want {
			t.Errorf("%s %v: %s, want %s", tc.op, tc.args, got, tc.want)
		}
	}
	c.raw(`{"v":2,"id":99,"op":"list"}`)
	if m := c.read(); m["error"].(map[string]any)["code"] != CodeUnsupportedVer {
		t.Fatal(m)
	}
	c.raw(`not json`)
	if m := c.read(); m["error"].(map[string]any)["code"] != CodeBadRequest {
		t.Fatal(m)
	}
	c.raw(``) // blank lines are ignored
	h := ok(t, c.call("health", nil))
	if h["version"] != "1.0.0-test" || h["backend"].(map[string]any)["server_pid"] != 77.0 {
		t.Fatal(h)
	}
}

func TestSubscribeStreamsEvents(t *testing.T) {
	c, _, _ := start(t)
	ok(t, c.call("subscribe", nil))
	id := ok(t, c.call("create", nil))["id"].(string)
	c.next++
	c.raw(fmt.Sprintf(`{"v":1,"id":%d,"op":"close","args":{"id":%q}}`, c.next, id))
	var gotReply, gotEvent bool
	for !(gotReply && gotEvent) {
		m := c.read()
		if m["event"] == "closed" {
			d := m["data"].(map[string]any)
			if d["id"] != id || d["reason"] != "closed" || m["v"] != 1.0 {
				t.Fatal(m)
			}
			gotEvent = true
		} else if m["id"] == float64(c.next) {
			gotReply = true
		}
	}
}

func TestEventJSON(t *testing.T) {
	at := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	b, _ := json.Marshal(EventJSON(watch.Event{ID: "a", Event: timeout.Event{Kind: timeout.EvExpiring, Reason: "idle",
		At: at, FgCommand: "apt"}}))
	if string(b) != `{"v":1,"event":"expiring","data":{"at":"2026-01-01T00:00:00Z","fg_command":"apt","id":"a","reason":"idle"}}` {
		t.Fatal(string(b))
	}
	b, _ = json.Marshal(EventJSON(watch.Event{ID: "a", Event: timeout.Event{Kind: timeout.EvState, State: "active"}}))
	if string(b) != `{"v":1,"event":"state","data":{"id":"a","state":"active"}}` {
		t.Fatal(string(b))
	}
}

func TestEventJSONPane(t *testing.T) {
	b, _ := json.Marshal(EventJSON(watch.Event{ID: "a", Event: timeout.Event{Kind: watch.EvPane},
		Pane: probe.Pane{Command: "vim", Args: []string{"/etc/hosts"}, Cwd: "/etc"}}))
	if string(b) != `{"v":1,"event":"pane","data":{"id":"a","pane":{"command":"vim","args":["/etc/hosts"],"cwd":"/etc"}}}` {
		t.Fatal(string(b))
	}
	b, _ = json.Marshal(PaneOf(probe.Pane{Cwd: "/"}))
	if string(b) != `{"command":"","args":[],"cwd":"/"}` {
		t.Fatal(string(b))
	}
}

func TestSessionHasPane(t *testing.T) {
	c, _, _ := start(t)
	id := ok(t, c.call("create", nil))["id"].(string)
	s := ok(t, c.call("status", map[string]any{"id": id}))["session"].(map[string]any)
	pane, isMap := s["pane"].(map[string]any)
	if !isMap {
		t.Fatalf("no pane in %v", s)
	}
	if _, has := pane["cwd"]; !has {
		t.Fatalf("pane %v", pane)
	}
}

func TestPaneEventsOnlyWhenAsked(t *testing.T) {
	if wantsPane(nil) || wantsPane([]byte(`{}`)) || !wantsPane([]byte(`{"pane":true}`)) || wantsPane([]byte(`x`)) {
		t.Fatal("wantsPane")
	}
}

func TestLineTooLong(t *testing.T) {
	c, _, _ := start(t)
	go func() { _, _ = io.WriteString(c.in, strings.Repeat("x", MaxLine+10)+"\n") }()
	select {
	case err := <-c.done:
		if err == nil {
			t.Fatal("an over-long line must end the connection with an error")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("connection not closed")
	}
}

func TestRandomID(t *testing.T) {
	a, b := randomID(), randomID()
	if len(a) != 8 || a == b {
		t.Fatal(a, b)
	}
}
