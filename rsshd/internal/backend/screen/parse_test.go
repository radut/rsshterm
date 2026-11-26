package screen

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/backend"
)

func TestParseVersion(t *testing.T) {
	for in, want := range map[string]string{
		"Screen version 4.09.01 (GNU) 20-Aug-23\n":   "4.09.01",
		"Screen version 5.0.0 (build on 2024-08-29)": "5.0.0",
		"Screen version 4.00.03 (FAU) 23-Oct-06":     "4.00.03",
		"nonsense":                                   "",
	} {
		if got := ParseVersion(in); got != want {
			t.Errorf("%q -> %q, want %q", in, got, want)
		}
	}
}

func TestValidID(t *testing.T) {
	for id, want := range map[string]bool{"0123abcd": true, "0123ABCD": false, "../x": false, "": false} {
		if ValidID(id) != want {
			t.Errorf("%q", id)
		}
	}
}

func TestParseLS(t *testing.T) {
	out := strings.Join([]string{
		"There are screens on:",
		"\t4242.rssh-0123abcd\t(11/25/26 10:00:00)\t(Detached)",
		"\t4343.main\t(Attached)", // older screen: no date
		"\t4444.dev.box\t(11/25/26 10:00:00)\t(Multi, attached)",
		"\t4545.gone\t(Dead ???)",
		"\tnopid\t(Detached)",
		"\t4646.multi\t(Multi, detached)",
		"3 Sockets in /run/screen/S-u.",
		"",
	}, "\n")
	got := ParseLS(out)
	want := []Entry{{4242, "rssh-0123abcd", false}, {4343, "main", true}, {4444, "dev.box", true},
		{4646, "multi", false}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("%d: %+v, want %+v", i, got[i], want[i])
		}
	}
	if got[0].Target() != "4242.rssh-0123abcd" {
		t.Fatal(got[0].Target())
	}
	if len(ParseLS("No Sockets found in /tmp/x.\n")) != 0 {
		t.Fatal("no sockets")
	}
}

func TestLastLines(t *testing.T) {
	tests := []struct {
		in   string
		n    int
		want string
	}{
		{"a\nb\nc\n\n\n", 2, "b\nc\n"},
		{"a\nb\n", 5, "a\nb\n"},
		{"\n\n  \n", 5, ""},
		{"", 5, ""},
	}
	for _, tc := range tests {
		if got := LastLines(tc.in, tc.n); got != tc.want {
			t.Errorf("LastLines(%q, %d) = %q, want %q", tc.in, tc.n, got, tc.want)
		}
	}
}

func TestStateFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "st", "screen-sessions.json")
	d, err := loadState(p)
	if err != nil || len(d.Sessions) != 0 {
		t.Fatalf("missing file: %v %v", d, err)
	}
	now := time.Unix(1700000000, 0).UTC()
	d.Sessions["0123abcd"] = &stateEntry{Created: now, Meta: map[string]string{"name": "a | b"}}
	d.Sessions["bad id"] = &stateEntry{}
	if err := saveState(p, d); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(p)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v %v", fi.Mode(), err)
	}
	if di, _ := os.Stat(filepath.Dir(p)); di.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode %v", di.Mode())
	}
	d2, err := loadState(p)
	if err != nil || len(d2.Sessions) != 1 || d2.Sessions["0123abcd"].Meta["name"] != "a | b" ||
		!d2.Sessions["0123abcd"].Created.Equal(now) {
		t.Fatalf("round trip %+v %v", d2, err)
	}
	if left, _ := filepath.Glob(filepath.Join(filepath.Dir(p), ".screen-state-*")); len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}
	_ = os.WriteFile(p, []byte("{broken"), 0o600)
	if _, err := loadState(p); err == nil {
		t.Fatal("broken file must fail")
	}
}

func TestBadIDs(t *testing.T) {
	s := &Screen{Dir: "/nonexistent/x", State: filepath.Join(t.TempDir(), "st.json")}
	ctx := context.Background()
	if _, err := s.Create(ctx, backend.CreateOpts{ID: "bad"}); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
	if _, err := s.Create(ctx, backend.CreateOpts{ID: "0000aaaa", Meta: map[string]string{"Bad": "x"}}); err == nil {
		t.Fatal("bad meta key accepted")
	}
	if _, err := s.Attach(ctx, "../x"); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
	if _, err := s.Capture(ctx, "x", 1); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
	if err := s.Kill(ctx, "x", 0); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
	if _, err := s.Meta(ctx, "0000aaaa", nil); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
	if l, err := s.List(ctx); err != nil || len(l) != 0 {
		t.Fatalf("missing dir: %v %v", l, err)
	}
	if err := (&Screen{Dir: "rel"}).ensureDir(); err == nil {
		t.Fatal("relative dir accepted")
	}
}

func TestEnv(t *testing.T) {
	t.Setenv("STY", "1.x")
	t.Setenv("SCREENDIR", "/user/dir")
	t.Setenv("TERM", "")
	got := strings.Join(env("/own"), "\n")
	if strings.Contains(got, "STY=") || strings.Contains(got, "/user/dir") || !strings.Contains(got, "SCREENDIR=/own") ||
		!strings.Contains(got, "TERM=xterm-256color") {
		t.Fatalf("env(own): %s", got)
	}
	if got := strings.Join(env(""), "\n"); !strings.Contains(got, "SCREENDIR=/user/dir") {
		t.Fatalf("env(user): %s", got)
	}
}
