package probe

import (
	"context"
	"reflect"
	"testing"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend"
)

func TestParseCmdline(t *testing.T) {
	got := ParseCmdline([]byte("vim\x00/etc/nginx/nginx.conf\x00\x00"))
	if !reflect.DeepEqual(got, []string{"vim", "/etc/nginx/nginx.conf", ""}) {
		t.Fatalf("%q", got)
	}
	if got := ParseCmdline(nil); len(got) != 0 {
		t.Fatalf("%q", got)
	}
}

func TestParseLsofCwd(t *testing.T) {
	if got := ParseLsofCwd("p123\nfcwd\nn/Users/me/src\n"); got != "/Users/me/src" {
		t.Fatalf("%q", got)
	}
	if got := ParseLsofCwd(""); got != "" {
		t.Fatalf("%q", got)
	}
}

func TestProgramName(t *testing.T) {
	for in, want := range map[string]string{"/usr/bin/vim": "vim", "-bash": "bash", "htop": "htop", "": ""} {
		if got := ProgramName(in); got != want {
			t.Fatalf("%q: %q", in, got)
		}
	}
}

func TestSanitizeArgs(t *testing.T) {
	m := Mask
	tests := []struct {
		prog string
		in   []string
		want []string
	}{
		{"tail", []string{"-f", "/var/log/syslog", "--lines=50"}, []string{"-f", "/var/log/syslog", "--lines=50"}},
		{"tool", []string{"--password", "x", "--token=abc", "-password", "p"},
			[]string{"--password", m, "--token=" + m, "-password", m}},
		{"ssh", []string{"-p", "2222", "root@sv1"}, []string{"-p", "2222", "root@sv1"}},
		{"mysql", []string{"-u", "root", "-psecret", "-p"}, []string{"-u", "root", "-p" + m, "-p"}},
		{"sshpass", []string{"-p", "pw", "ssh", "h"}, []string{"-p", m, "ssh", "h"}},
		{"env", []string{"GITHUB_TOKEN=x", "PATH=/bin"}, []string{"GITHUB_TOKEN=" + m, "PATH=/bin"}},
		{"git", []string{"clone", "https://u:pw@example.com/r.git"}, []string{"clone", "https://u:" + m + "@example.com/r.git"}},
		{"curl", []string{"-H", "Authorization: Bearer abc"}, []string{"-H", "Authorization: " + m}},
		{"curl", []string{"-u", "admin:pw", "-H", "X-Api-Key: k1", "--user=a:b"},
			[]string{"-u", "admin:" + m, "-H", "X-Api-Key: " + m, "--user=a:" + m}},
		{"sudo", []string{"mysql", "-psecret"}, []string{"mysql", "-p" + m}},
		{"sudo", []string{"-u", "root", "env", "API_TOKEN=x", "sshpass", "-p", "pw", "ssh", "h"},
			[]string{"-u", "root", "env", "API_TOKEN=" + m, "sshpass", "-p", m, "ssh", "h"}},
		{"time", []string{"tool", "--password", "x"}, []string{"tool", "--password", m}},
		{"tool", []string{"--key-file", "/k"}, []string{"--key-file", "/k"}},
	}
	for _, tc := range tests {
		if got := SanitizeArgs(tc.prog, tc.in); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s %q: got %q want %q", tc.prog, tc.in, got, tc.want)
		}
	}
}

func TestSanitizeArgsCaps(t *testing.T) {
	long := make([]string, 100)
	for i := range long {
		long[i] = string(make([]byte, 1000))
	}
	got := SanitizeArgs("x", long)
	if len(got) != MaxArgs {
		t.Fatalf("%d args", len(got))
	}
	if len(got[0]) > MaxArgLen+len("…") {
		t.Fatalf("arg of %d bytes", len(got[0]))
	}
}

func TestLocalProbePane(t *testing.T) {
	s := backend.Session{ID: "a", PanePID: 100, PaneCommand: "bash"}
	procs := map[int]Process{
		100: {Argv: []string{"-bash"}, Cwd: "/root"},
		230: {Argv: []string{"/usr/bin/vim", "--cmd", "set pw", "/etc/hosts"}, Cwd: "/etc"},
		240: {Argv: []string{"mysql", "-psecret", "db"}, Cwd: "/srv"},
	}
	read := func(_ context.Context, pid int) (Process, error) { return procs[pid], nil }
	for _, tc := range []struct {
		tpgid int
		want  Pane
	}{
		{100, Pane{Cwd: "/root"}},
		{230, Pane{Command: "vim", Args: []string{"--cmd", "set pw", "/etc/hosts"}, Cwd: "/etc"}},
		{240, Pane{Command: "mysql", Args: []string{"-p" + Mask, "db"}, Cwd: "/srv"}},
	} {
		tpgid := tc.tpgid
		l := Local{TPGID: func(context.Context, int) (int, error) { return tpgid, nil }, ReadProcess: read}
		r, err := l.Probe(context.Background(), s)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(r.Pane, tc.want) {
			t.Fatalf("tpgid %d: %+v", tc.tpgid, r.Pane)
		}
	}
}

func TestLocalProbePaneLeaderGone(t *testing.T) {
	// The job's group leader exited (a pipeline's first command): fall back to the shell's folder, keep the
	// pane_current_command name.
	s := backend.Session{ID: "a", PanePID: 100, PaneCommand: "grep"}
	read := func(_ context.Context, pid int) (Process, error) {
		if pid == 100 {
			return Process{Argv: []string{"bash"}, Cwd: "/root"}, nil
		}
		return Process{}, context.DeadlineExceeded
	}
	l := Local{TPGID: func(context.Context, int) (int, error) { return 230, nil }, ReadProcess: read}
	r, err := l.Probe(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(r.Pane, Pane{Command: "grep", Cwd: "/root"}) {
		t.Fatalf("%+v", r.Pane)
	}
}

func TestPaneEqual(t *testing.T) {
	a := Pane{Command: "vim", Args: []string{"x"}, Cwd: "/"}
	if !a.Equal(Pane{Command: "vim", Args: []string{"x"}, Cwd: "/"}) || a.Equal(Pane{Command: "vim", Cwd: "/"}) {
		t.Fatal("Equal")
	}
}
