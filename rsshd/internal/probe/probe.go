// Package probe answers "is this session busy?": the newest activity, whether a foreground job runs, which
// command it is, and whether a full-screen program is drawing. The Result type is frozen (design §13).
package probe

import (
	"context"
	"fmt"
	"time"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend"
)

// Result is what the timeout state machine observes about one session at one moment.
type Result struct {
	ActivityAt time.Time // newest output or input
	FgRunning  bool      // the pane tty's foreground process group is not the shell
	FgCommand  string    // e.g. "apt"; the shell's name when nothing runs
	AltScreen  bool      // a full-screen program is drawing (htop)
	Pane       Pane      // the foreground program, its arguments (secrets out) and folder, for tab titles
}

// Prober turns a backend session into a Result.
type Prober interface {
	Probe(ctx context.Context, s backend.Session) (Result, error)
}

// TTYPgrpFunc returns the foreground process group of the controlling tty of pid.
type TTYPgrpFunc func(ctx context.Context, pid int) (int, error)

// Local probes processes on this machine: /proc on Linux, ps on macOS.
type Local struct {
	TPGID       TTYPgrpFunc     // nil = the OS default (ForegroundPgrp)
	ReadProcess ReadProcessFunc // nil = the OS default (ReadProcess)
}

// Probe implements Prober.
func (l Local) Probe(ctx context.Context, s backend.Session) (Result, error) {
	r := Result{ActivityAt: s.ActivityAt, FgCommand: s.PaneCommand, AltScreen: s.AltScreen}
	if s.PanePID <= 0 {
		return r, fmt.Errorf("session %s: no pane pid", s.ID)
	}
	f := l.TPGID
	if f == nil {
		f = ForegroundPgrp
	}
	tpgid, err := f(ctx, s.PanePID)
	if err != nil {
		return r, fmt.Errorf("session %s: %w", s.ID, err)
	}
	// The shell leads its own process group, so pgid == pid; any other foreground group is a job.
	r.FgRunning = tpgid > 0 && tpgid != s.PanePID
	r.Pane = l.pane(ctx, s, tpgid, r.FgRunning)
	return r, nil
}

// pane reads the foreground group's leader (its pid is the group id); a failed read never fails the probe. When
// the leader is gone (a pipeline whose first command ended), the pane keeps tmux's command name and the shell's
// folder.
func (l Local) pane(ctx context.Context, s backend.Session, tpgid int, running bool) Pane {
	read := l.ReadProcess
	if read == nil {
		read = ReadProcess
	}
	if running {
		if p, err := read(ctx, tpgid); err == nil && len(p.Argv) > 0 {
			return paneOf(p, true)
		}
	}
	shell, _ := read(ctx, s.PanePID)
	pane := Pane{Cwd: shell.Cwd}
	if running {
		pane.Command = ProgramName(s.PaneCommand)
	}
	return pane
}
