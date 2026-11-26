// Package backend is the frozen contract between the daemon and a terminal multiplexer (tmux, GNU screen).
// A backend holds the processes and the scrollback; the daemon holds none of them, so it can restart freely.
package backend

import (
	"context"
	"errors"
	"time"
)

// ErrNotFound is returned (wrapped) when no managed session has the given id.
var ErrNotFound = errors.New("session not found")

// Session is one managed session as the backend sees it right now.
type Session struct {
	ID              string            // rsshd id (8 hex); the multiplexer session is "rssh-<ID>"
	Backend         string            // "tmux" or "screen"
	Created         time.Time         //
	ActivityAt      time.Time         // newest output or input in any window (1 s resolution in tmux)
	AttachedClients int               //
	PanePID         int               // the active pane's first process (the shell)
	PaneCommand     string            // pane_current_command, e.g. "apt"
	AltScreen       bool              // alternate_on: a full-screen program (htop, vim) is drawing
	Meta            map[string]string // rsshd metadata (tmux: user options without the "@rssh_" prefix)
}

// Foreign is a session of the user's own multiplexer server: listed so the app can attach, never managed.
type Foreign struct {
	Name            string
	Backend         string
	AttachedClients int
	Attach          []string // argv that attaches it
}

// CreateOpts describes a new session. Command is typed into the shell once and never logged.
type CreateOpts struct {
	ID      string
	Backend string // "" = the default; only a multi-backend (internal/backend/multi) looks at it
	Cwd     string
	Command string
	Cols    int
	Rows    int
	Meta    map[string]string
}

// Backend is implemented once per multiplexer. All methods are safe for concurrent use.
type Backend interface {
	// Name is the protocol name ("tmux", "screen").
	Name() string
	// Version is the multiplexer's version string ("3.4"), or an error when it is not installed.
	Version(ctx context.Context) (string, error)
	// Create starts a detached session and stores opts.Meta with it.
	Create(ctx context.Context, opts CreateOpts) (Session, error)
	// List returns the managed sessions. A server that is not running means no sessions, not an error.
	List(ctx context.Context) ([]Session, error)
	// Foreign lists the user's own sessions on the multiplexer's default server (attach-only).
	Foreign(ctx context.Context) ([]Foreign, error)
	// Attach returns the argv that attaches a terminal to the session (the caller execs it).
	Attach(ctx context.Context, id string) ([]string, error)
	// Capture returns the last `lines` lines of history with escape sequences, joined wrapped lines.
	Capture(ctx context.Context, id string, lines int) (string, error)
	// Kill sends SIGHUP to the session's process groups, waits up to grace for them to exit, then removes it.
	Kill(ctx context.Context, id string, grace time.Duration) error
	// Meta stores the given keys (when set is non-empty) and returns all of the session's metadata.
	Meta(ctx context.Context, id string, set map[string]string) (map[string]string, error)
}
