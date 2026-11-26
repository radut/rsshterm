package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func isolate(t *testing.T) string {
	d, err := os.MkdirTemp("", "rsshd-cmd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(d, "cfg"))
	t.Setenv("XDG_RUNTIME_DIR", filepath.Join(d, "run"))
	return d
}

func TestRunCommands(t *testing.T) {
	d := isolate(t)
	tests := []struct {
		args []string
		code int
		out  string
		err  string
	}{
		{nil, 2, "", "usage"},
		{[]string{"version"}, 0, "rsshd dev", ""},
		{[]string{"--help"}, 0, "attach <id>", ""},
		{[]string{"bogus"}, 2, "", "unknown command"},
		{[]string{"attach"}, 2, "", "usage: rsshd attach"},
		{[]string{"attach", "0000abcd"}, 1, "", "rsshd:"},
		{[]string{"doctor"}, 1, "MISSING daemon", ""},
	}
	for _, tc := range tests {
		var out, errb bytes.Buffer
		code := run(tc.args, strings.NewReader(""), &out, &errb)
		if code != tc.code || !strings.Contains(out.String(), tc.out) || !strings.Contains(errb.String(), tc.err) {
			t.Errorf("%v: code %d out %q err %q", tc.args, code, out.String(), errb.String())
		}
	}
	var out bytes.Buffer
	run([]string{"doctor", "--json"}, nil, &out, &out)
	var m map[string]any
	if err := json.Unmarshal(out.Bytes(), &m); err != nil || m["healthy"] != false {
		t.Fatalf("doctor --json: %v %s", err, out.String())
	}
	// A broken config stops every command but version.
	cfg := filepath.Join(d, "cfg", "rsshd", "config.toml")
	_ = os.MkdirAll(filepath.Dir(cfg), 0o700)
	_ = os.WriteFile(cfg, []byte("backend = \"zellij\"\n"), 0o600)
	var errb bytes.Buffer
	if code := run([]string{"doctor"}, nil, &out, &errb); code != 2 || !strings.Contains(errb.String(), "zellij") {
		t.Fatalf("bad config: %d %s", code, errb.String())
	}
}
