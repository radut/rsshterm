package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testEnv(t *testing.T) Env {
	d := t.TempDir()
	return Env{Home: d, ConfigHome: filepath.Join(d, "cfg"), RuntimeDir: filepath.Join(d, "run"), UID: 1000}
}

func TestDefaults(t *testing.T) {
	e := testEnv(t)
	c, err := Load(e) // no file
	if err != nil {
		t.Fatal(err)
	}
	p := c.Timeouts
	if p.Idle != time.Hour || p.Hard != 24*time.Hour || !p.FinishWork || p.WarnLead != 5*time.Minute ||
		c.ExtendIdle != time.Hour || c.ExtendHard != 24*time.Hour || c.Backend != "tmux" || c.TmuxSocket != "rsshd" {
		t.Fatalf("defaults %+v", c)
	}
	if c.Socket != filepath.Join(e.RuntimeDir, "rsshd", "sock") {
		t.Fatalf("socket %s", c.Socket)
	}
}

func TestPaths(t *testing.T) {
	e := Env{Home: "/h", UID: 42}
	if e.Path() != "/h/.config/rsshd/config.toml" {
		t.Fatal(e.Path())
	}
	if !strings.HasSuffix(e.DefaultSocket(), "/rsshd-42/sock") {
		t.Fatal(e.DefaultSocket())
	}
	if e.ScreenStatePath() != "/h/.local/state/rsshd/screen-sessions.json" ||
		(Env{StateHome: "/st"}).ScreenStatePath() != "/st/rsshd/screen-sessions.json" {
		t.Fatal(e.ScreenStatePath())
	}
	if FromOS().UID != os.Getuid() {
		t.Fatal("FromOS uid")
	}
}

func TestParse(t *testing.T) {
	e := testEnv(t)
	tests := []struct {
		name    string
		doc     string
		wantErr string
		check   func(Config) bool
	}{
		{"full", `
backend = "tmux"
socket = "/run/x/sock"
poll_interval = "250ms"
close_grace = "1s"
tmux_socket = "t1"
tmux_conf = "/dev/null"
[timeouts]
idle = "30m"
hard = "0s"
warn_lead = "1m"
finish_work = false
extend_idle = "2h"
extend_hard = "48h"
`, "", func(c Config) bool {
			return c.Socket == "/run/x/sock" && c.PollInterval == 250*time.Millisecond && c.CloseGrace == time.Second &&
				c.TmuxSocket == "t1" && c.Timeouts.Idle == 30*time.Minute && c.Timeouts.Hard == 0 &&
				c.Timeouts.WarnLead == time.Minute && !c.Timeouts.FinishWork && c.ExtendIdle == 2*time.Hour &&
				c.ExtendHard == 48*time.Hour
		}},
		{"partial keeps defaults", "[timeouts]\nidle = \"2h\"\n", "", func(c Config) bool {
			return c.Timeouts.Idle == 2*time.Hour && c.Timeouts.Hard == 24*time.Hour && c.Timeouts.FinishWork
		}},
		{"bad duration", "[timeouts]\nidle = \"soon\"\n", "timeouts.idle", nil},
		{"negative duration", "poll_interval = \"-1s\"\n", "poll_interval", nil},
		{"unknown key", "idle = \"1h\"\n", "unknown key", nil},
		{"bad toml", "backend = \n", "config", nil},
		{"screen", "backend = \"screen\"\n", "", func(c Config) bool {
			return c.Backend == "screen" && c.ScreenDir == filepath.Join(e.RuntimeDir, "rsshd", "screen") &&
				c.ScreenState == filepath.Join(e.Home, ".local", "state", "rsshd", "screen-sessions.json")
		}},
		{"screen follows the socket", "socket = \"/run/y/sock\"\n", "", func(c Config) bool {
			return c.ScreenDir == "/run/y/screen"
		}},
		{"screen paths", "screen_dir = \"/s/d\"\nscreen_rc = \"/s/rc\"\nscreen_state = \"/s/st.json\"\n", "",
			func(c Config) bool {
				return c.ScreenDir == "/s/d" && c.ScreenRC == "/s/rc" && c.ScreenState == "/s/st.json"
			}},
		{"unknown backend", "backend = \"zellij\"\n", "want \"tmux\" or \"screen\"", nil},
		{"relative screen dir", "screen_dir = \"s\"\n", "screen_dir", nil},
		{"relative screen state", "screen_state = \"s\"\n", "screen_state", nil},
		{"relative screen rc", "screen_rc = \"s\"\n", "screen_rc", nil},
		{"poll too fast", "poll_interval = \"1ms\"\n", "below 100ms", nil},
		{"relative socket", "socket = \"sock\"\n", "absolute", nil},
		{"empty tmux socket", "tmux_socket = \"\"\n", "tmux_socket", nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			c, err := Parse(e, tc.doc)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("err = %v, want %q", err, tc.wantErr)
				}
				return
			}
			if err != nil || !tc.check(c) {
				t.Fatalf("err %v config %+v", err, c)
			}
		})
	}
}

func TestLoadFile(t *testing.T) {
	e := testEnv(t)
	if err := os.MkdirAll(filepath.Dir(e.Path()), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(e.Path(), []byte("[timeouts]\nhard = \"2h\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := Load(e)
	if err != nil || c.Timeouts.Hard != 2*time.Hour {
		t.Fatalf("%v %+v", err, c)
	}
	if err := os.Chmod(e.Path(), 0); err == nil && os.Getuid() != 0 {
		if _, err := Load(e); err == nil {
			t.Fatal("unreadable file must fail")
		}
	}
}
