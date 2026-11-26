package doctor

import (
	"bytes"
	"context"
	"errors"
	"os"
	"strings"
	"testing"
)

type fakeHost struct {
	paths  map[string]bool // LookPath
	files  map[string]bool // Exists
	sudoOK bool
	linger string
	dialOK bool
}

func (f fakeHost) host(goos string) Host {
	return Host{
		GOOS: goos, Home: "/home/u", User: "u", Socket: "/run/user/1/rsshd/sock", TmuxBin: "tmux",
		LookPath: func(n string) (string, error) {
			if f.paths[n] {
				return "/usr/bin/" + n, nil
			}
			return "", errors.New("not found")
		},
		Output: func(_ context.Context, name string, args ...string) (string, error) {
			switch {
			case strings.HasSuffix(name, "tmux"):
				return "tmux 3.4\n", nil
			case strings.HasSuffix(name, "screen"):
				return "Screen version 4.09.01 (GNU) 20-Aug-23\n", errors.New("exit 1") // some builds exit 1
			case strings.HasSuffix(name, "reptyr"):
				return "This is reptyr version 0.8.0.\n", nil
			case name == "sudo":
				if f.sudoOK {
					return "/usr/bin/reptyr -T 1\n", nil
				}
				return "", errors.New("exit 1")
			case name == "loginctl":
				return f.linger, nil
			}
			return "", errors.New("unexpected " + name)
		},
		ReadFile: func(p string) ([]byte, error) { return []byte("1\n"), nil },
		Exists:   func(p string) bool { return f.files[p] },
		Dial: func(string) error {
			if f.dialOK {
				return nil
			}
			return errors.New("refused")
		},
	}
}

func TestEverythingPresent(t *testing.T) {
	f := fakeHost{paths: map[string]bool{"tmux": true, "screen": true, "systemctl": true, "reptyr": true},
		files: map[string]bool{"/usr/lib/systemd/user/rsshd.service": true}, sudoOK: true, linger: "Linger=yes\n",
		dialOK: true}
	r := Run(context.Background(), f.host("linux"), false)
	if !r.Healthy() || len(r.Missing(false)) != 0 || r.TmuxVersion != "3.4" || r.ScreenVersion != "4.09.01" || r.Reptyr != "0.8.0" ||
		!r.SudoReptyr || !r.Linger || r.PtraceScope != 1 {
		t.Fatalf("%+v", r)
	}
	var b bytes.Buffer
	if err := Print(&b, r); err != nil || !strings.Contains(b.String(), "integration: ready") {
		t.Fatal(b.String())
	}
}

func TestNothingInstalled(t *testing.T) {
	f := fakeHost{paths: map[string]bool{"systemctl": true}}
	r := Run(context.Background(), f.host("linux"), false)
	want := []string{Tmux, Unit, Daemon}
	if got := r.Missing(true); strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("required missing %v", got)
	}
	if got := r.Missing(false); strings.Join(got, ",") != "tmux,screen,service-unit,daemon,reptyr,sudo-reptyr,linger" {
		t.Fatalf("all missing %v", got)
	}
	var b bytes.Buffer
	_ = Print(&b, r)
	out := b.String()
	for _, s := range []string{"MISSING tmux", "MISSING service-unit", "MISSING daemon", "absent  reptyr", "absent  screen",
		"fix: sudo apt install tmux", "missing tmux, service-unit, daemon"} {
		if !strings.Contains(out, s) {
			t.Errorf("output lacks %q:\n%s", s, out)
		}
	}
}

func TestNoSystemdAndSkipDaemon(t *testing.T) {
	f := fakeHost{paths: map[string]bool{"tmux": true}, files: map[string]bool{"/var/lib/systemd/linger/u": true}}
	r := Run(context.Background(), f.host("linux"), true)
	if !r.Healthy() || !r.Linger {
		t.Fatalf("%+v", r.Checks)
	}
	for _, c := range r.Checks {
		if c.Name == Daemon {
			t.Fatal("daemon checked with skipDaemon")
		}
	}
}

func TestDarwin(t *testing.T) {
	f := fakeHost{paths: map[string]bool{"tmux": true, "screen": true}, dialOK: true}
	r := Run(context.Background(), f.host("darwin"), false)
	if got := r.Missing(false); len(got) != 1 || got[0] != Unit {
		t.Fatalf("missing %v", got)
	}
	f.files = map[string]bool{"/home/u/Library/LaunchAgents/dev.rssh.rsshd.plist": true}
	if r := Run(context.Background(), f.host("darwin"), false); !r.Healthy() {
		t.Fatalf("%+v", r.Checks)
	}
	if !strings.Contains(installHint("darwin", "tmux"), "brew") {
		t.Fatal("hint")
	}
}

func TestTmuxBroken(t *testing.T) {
	h := fakeHost{paths: map[string]bool{"tmux": true}}.host("freebsd")
	h.Output = func(context.Context, string, ...string) (string, error) { return "", errors.New("boom") }
	r := Run(context.Background(), h, true)
	if r.Healthy() || !strings.Contains(r.Checks[0].Detail, "boom") {
		t.Fatalf("%+v", r.Checks)
	}
}

func TestScreenBroken(t *testing.T) {
	h := fakeHost{paths: map[string]bool{"tmux": true, "screen": true}}.host("linux")
	out := h.Output
	h.Output = func(ctx context.Context, name string, args ...string) (string, error) {
		if name == "screen" {
			return "", errors.New("boom")
		}
		return out(ctx, name, args...)
	}
	r := Run(context.Background(), h, true)
	if r.ScreenVersion != "" || !strings.Contains(r.Checks[1].Detail, "boom") || r.Checks[1].Required {
		t.Fatalf("%+v", r.Checks)
	}
}

func TestLocal(t *testing.T) {
	h := Local("/nonexistent/sock")
	if h.Dial(h.Socket) == nil || h.Exists("/nonexistent") || !h.Exists(os.TempDir()) {
		t.Fatal("local host helpers")
	}
	_ = Run(context.Background(), h, false) // must not panic on a real host
}

type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, errors.New("closed") }

func TestPrintError(t *testing.T) {
	if Print(failWriter{}, Report{}) == nil {
		t.Fatal("write error swallowed")
	}
}
