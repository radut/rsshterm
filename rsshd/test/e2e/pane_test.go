package e2e

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

// Session.pane and the pane event carry the foreground program, its arguments (secrets out) and its folder: what
// the app puts in the tab title.
func TestPaneInfo(t *testing.T) {
	e := newEnv(t, "")
	e.serve()
	c := e.rpc("pane")
	c.call("subscribe", map[string]any{"pane": true})

	id := c.call("create", map[string]any{"name": "logs", "cwd": "/tmp",
		"command":  "cd /var && bash -c 'sleep 30; true' job --password hunter2",
		"timeouts": map[string]any{"idle_s": 3600, "hard_s": 0}})["id"].(string)
	pane := c.waitPane(id, func(p map[string]any) bool { return p["command"] == "bash" }, 10*time.Second)
	if fmt.Sprint(pane["args"]) != "[-c sleep 30; true job --password •••]" || pane["cwd"] != "/var" {
		t.Fatalf("pane event %v", pane)
	}
	s := c.status(id)
	if p := s["pane"].(map[string]any); p["command"] != "bash" || p["cwd"] != "/var" {
		t.Fatalf("status pane %v", s["pane"])
	}
	b, _ := json.Marshal(s["pane"])
	t.Logf("pane         +%5.1fs  running: %s", c.elapsed(), b)

	idle := c.call("create", map[string]any{"cwd": "/usr", "timeouts": map[string]any{"idle_s": 3600, "hard_s": 0}})
	idleID := idle["id"].(string)
	p := c.waitPane(idleID, func(p map[string]any) bool { return p["cwd"] == "/usr" }, 10*time.Second)
	if p["command"] != "" {
		t.Fatalf("idle pane %v", p)
	}
	t.Logf("pane         +%5.1fs  idle: %v", c.elapsed(), p)

	// A client that subscribes without "pane" gets no pane events.
	quiet := e.rpc("quiet")
	quiet.call("subscribe", nil)
	c.call("close", map[string]any{"id": id})
	quiet.waitEvent(id, "closed", "reason", "closed", 5*time.Second, "pane")
	c.call("close", map[string]any{"id": idleID})
}

func (c *client) waitPane(id string, match func(map[string]any) bool, within time.Duration) map[string]any {
	c.t.Helper()
	deadline := time.After(within)
	for {
		select {
		case m, ok := <-c.events:
			if !ok {
				c.t.Fatal("rpc closed")
			}
			d := m["data"].(map[string]any)
			if m["event"] != "pane" || d["id"] != id {
				continue
			}
			if p := d["pane"].(map[string]any); match(p) {
				return p
			}
		case <-deadline:
			c.t.Fatalf("no matching pane event for %s within %v; status %v; screen %q", id, within, c.status(id), c.call("scrollback", map[string]any{"id": id})["data"])
			return nil
		}
	}
}
