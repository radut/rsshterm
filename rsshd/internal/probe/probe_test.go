package probe

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"runtime"
	"testing"
	"time"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend"
)

func TestParseStatTPGID(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    int
		wantErr bool
	}{
		{"bash", "4242 (bash) S 4241 4242 4242 34816 4250 4194560 1 2 3", 4250, false},
		{"space and paren in comm", "77 (my ) prog) R 1 77 77 34817 77 0", 77, false},
		{"no tty", "1 (init) S 0 1 1 0 -1 4194560", -1, false},
		{"truncated", "1 (init) S 0 1", 0, true},
		{"no comm", "garbage", 0, true},
		{"not a number", "1 (x) S 0 1 1 0 x", 0, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseStatTPGID(tc.in)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if got != tc.want {
				t.Fatalf("got %d, want %d", got, tc.want)
			}
		})
	}
}

func TestParsePSTPGID(t *testing.T) {
	if v, err := ParsePSTPGID("  4250\n"); err != nil || v != 4250 {
		t.Fatalf("got %d %v", v, err)
	}
	if _, err := ParsePSTPGID("\n"); err == nil {
		t.Fatal("empty output must fail")
	}
	if _, err := ParsePSTPGID("abc"); err == nil {
		t.Fatal("non-number must fail")
	}
}

func TestLocalProbe(t *testing.T) {
	at := time.Unix(1700000000, 0)
	s := backend.Session{ID: "a", PanePID: 100, PaneCommand: "htop", AltScreen: true, ActivityAt: at}
	tests := []struct {
		name    string
		tpgid   int
		err     error
		running bool
		wantErr bool
	}{
		{"shell in foreground", 100, nil, false, false},
		{"job in foreground", 230, nil, true, false},
		{"no tty", -1, nil, false, false},
		{"probe fails", 0, errors.New("gone"), false, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			l := Local{TPGID: func(context.Context, int) (int, error) { return tc.tpgid, tc.err }}
			r, err := l.Probe(context.Background(), s)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v", err)
			}
			if r.FgRunning != tc.running || r.FgCommand != "htop" || !r.AltScreen || !r.ActivityAt.Equal(at) {
				t.Fatalf("result %+v", r)
			}
		})
	}
	if _, err := (Local{}).Probe(context.Background(), backend.Session{ID: "x"}); err == nil {
		t.Fatal("no pane pid must fail")
	}
}

// The real OS probe on our own process: a test binary without a tty has tpgid -1 (Linux) or 0.
func TestForegroundPgrpSelf(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("unsupported OS")
	}
	if _, err := ForegroundPgrp(context.Background(), os.Getpid()); err != nil {
		t.Fatalf("own process: %v", err)
	}
	cmd := exec.Command("true")
	_ = cmd.Run()
	if _, err := ForegroundPgrp(context.Background(), cmd.Process.Pid); err == nil {
		t.Fatal("an exited process must fail")
	}
}
