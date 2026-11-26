// Package rpc implements PROTOCOL.md: JSON lines between the app (through `rsshd rpc`) and the daemon.
package rpc

import (
	"encoding/json"
	"time"
)

// Version is the only protocol version this daemon speaks.
const Version = 1

// MaxLine is the longest accepted request line.
const MaxLine = 1 << 20

// Error codes (PROTOCOL.md).
const (
	CodeBadRequest     = "bad_request"
	CodeUnsupportedVer = "unsupported_version"
	CodeUnknownOp      = "unknown_op"
	CodeNotFound       = "not_found"
	CodeBackend        = "backend_error"
	CodeNotImplemented = "not_implemented"
)

// Request is one client line.
type Request struct {
	V    int             `json:"v"`
	ID   int64           `json:"id"`
	Op   string          `json:"op"`
	Args json.RawMessage `json:"args,omitempty"`
}

// Response is the reply to one request.
type Response struct {
	V      int    `json:"v"`
	ID     int64  `json:"id"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  *Error `json:"error,omitempty"`
}

// Error is a typed failure.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

func errf(code, msg string) *Error { return &Error{Code: code, Message: msg} }

// EventMsg is an unsolicited line.
type EventMsg struct {
	V     int    `json:"v"`
	Event string `json:"event"`
	Data  any    `json:"data"`
}

// TimeoutsJSON is a session's timeout settings in seconds.
type TimeoutsJSON struct {
	IdleS      int64 `json:"idle_s"`
	HardS      int64 `json:"hard_s"`
	FinishWork bool  `json:"finish_work"`
	WarnLeadS  int64 `json:"warn_lead_s"`
}

// DeadlinesJSON are the close times; absent when that timeout is off.
type DeadlinesJSON struct {
	Idle *time.Time `json:"idle,omitempty"`
	Hard *time.Time `json:"hard,omitempty"`
}

// SessionJSON is the Session object of the protocol.
type SessionJSON struct {
	ID              string        `json:"id"`
	Name            string        `json:"name"`
	Backend         string        `json:"backend"`
	Created         time.Time     `json:"created"`
	LastActivity    time.Time     `json:"last_activity"`
	AttachedClients int           `json:"attached_clients"`
	State           string        `json:"state"`
	Deadlines       DeadlinesJSON `json:"deadlines"`
	Timeouts        TimeoutsJSON  `json:"timeouts"`
	FgRunning       bool          `json:"fg_running"`
	FgCommand       string        `json:"fg_command"`
	AltScreen       bool          `json:"alt_screen"`
	Pane            PaneJSON      `json:"pane"`
}

// PaneJSON is the foreground program of a session for tab titles: command "" while the shell is at its prompt;
// args have secrets taken out.
type PaneJSON struct {
	Command string   `json:"command"`
	Args    []string `json:"args"`
	Cwd     string   `json:"cwd"`
}

// ForeignJSON is a session of the user's own multiplexer.
type ForeignJSON struct {
	Name            string   `json:"name"`
	Backend         string   `json:"backend"`
	AttachedClients int      `json:"attached_clients"`
	Attach          []string `json:"attach"`
}

// Caps are the host capabilities reported by hello.
type Caps struct {
	Reptyr      string `json:"reptyr"`
	SudoReptyr  bool   `json:"sudo_reptyr"`
	PtraceScope int    `json:"ptrace_scope"`
	Linger      bool   `json:"linger"`
	OS          string `json:"os"`
}

// HelloResult is the reply to hello.
type HelloResult struct {
	Proto          int               `json:"proto"`
	Version        string            `json:"version"`
	Backends       map[string]string `json:"backends"`
	DefaultBackend string            `json:"default_backend"`
	Caps           Caps              `json:"caps"`
	Missing        []string          `json:"missing"`
}

type helloArgs struct {
	Client string `json:"client"`
	Proto  []int  `json:"proto"`
}

type listArgs struct {
	IncludeForeign bool `json:"include_foreign"`
}

type timeoutArgs struct {
	IdleS      *int64 `json:"idle_s"`
	HardS      *int64 `json:"hard_s"`
	FinishWork *bool  `json:"finish_work"`
	WarnLeadS  *int64 `json:"warn_lead_s"`
}

type createArgs struct {
	Name     string       `json:"name"`
	Backend  string       `json:"backend"`
	Cwd      string       `json:"cwd"`
	Command  string       `json:"command"`
	Cols     int          `json:"cols"`
	Rows     int          `json:"rows"`
	Timeouts *timeoutArgs `json:"timeouts"`
}

type idArgs struct {
	ID string `json:"id"`
}

type scrollbackArgs struct {
	ID    string `json:"id"`
	Lines int    `json:"lines"`
}

type setTimeoutsArgs struct {
	ID string `json:"id"`
	timeoutArgs
}

type extendArgs struct {
	ID    string `json:"id"`
	ByS   *int64 `json:"by_s"`
	Which string `json:"which"`
}
