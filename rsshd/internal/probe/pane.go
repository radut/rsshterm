package probe

import (
	"bytes"
	"context"
	"strings"
)

// Pane is what a tab title needs from a session: the foreground program (empty while the shell waits at its
// prompt), its arguments with secrets taken out, and its working directory.
type Pane struct {
	Command string
	Args    []string
	Cwd     string
}

// Equal reports whether two panes show the same thing.
func (p Pane) Equal(o Pane) bool {
	if p.Command != o.Command || p.Cwd != o.Cwd || len(p.Args) != len(o.Args) {
		return false
	}
	for i := range p.Args {
		if p.Args[i] != o.Args[i] {
			return false
		}
	}
	return true
}

// Process is one process as the OS reports it.
type Process struct {
	Argv []string
	Cwd  string
}

// ReadProcessFunc reads a process's argv and working directory.
type ReadProcessFunc func(ctx context.Context, pid int) (Process, error)

// ParseCmdline splits /proc/<pid>/cmdline (NUL-terminated arguments).
func ParseCmdline(b []byte) []string {
	b = bytes.TrimSuffix(b, []byte{0})
	if len(b) == 0 {
		return nil
	}
	return strings.Split(string(b), "\x00")
}

// ParseLsofCwd reads the name field of `lsof -a -p <pid> -d cwd -Fn`.
func ParseLsofCwd(out string) string {
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "n") {
			return line[1:]
		}
	}
	return ""
}

// ProgramName is argv[0] without its folder and a login shell's leading "-".
func ProgramName(argv0 string) string {
	if i := strings.LastIndexByte(argv0, '/'); i >= 0 {
		argv0 = argv0[i+1:]
	}
	return strings.TrimPrefix(argv0, "-")
}

// paneOf turns the foreground process into a Pane. running=false: the shell is at its prompt.
func paneOf(p Process, running bool) Pane {
	if !running || len(p.Argv) == 0 {
		return Pane{Cwd: p.Cwd}
	}
	name := ProgramName(p.Argv[0])
	return Pane{Command: name, Args: SanitizeArgs(name, p.Argv[1:]), Cwd: p.Cwd}
}
