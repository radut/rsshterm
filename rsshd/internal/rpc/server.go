package rpc

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/backend"
	"github.com/radut/rsshterm/rsshd/internal/timeout"
	"github.com/radut/rsshterm/rsshd/internal/watch"
)

// Limits on client input.
const (
	maxNameLen     = 64
	maxCommandLen  = 4096
	maxTermSize    = 1000
	maxScrollback  = 100000
	maxTimeoutSecs = 365 * 24 * 3600
)

// Deps is what the server needs from the daemon.
type Deps struct {
	Backend    backend.Backend
	Watcher    *watch.Watcher
	Defaults   timeout.Policy
	ExtendIdle time.Duration
	ExtendHard time.Duration
	Version    string
	Started    time.Time
	Hello      func(ctx context.Context) HelloResult // capabilities; Proto and Version are filled in by the server
	ServerPID  func(ctx context.Context) int
	NewID      func() string // nil = 8 random hex
	Log        *slog.Logger
}

// Server answers requests on any number of connections.
type Server struct {
	d Deps
}

// NewServer returns a Server.
func NewServer(d Deps) *Server {
	if d.NewID == nil {
		d.NewID = randomID
	}
	if d.Log == nil {
		d.Log = slog.New(slog.DiscardHandler)
	}
	return &Server{d: d}
}

func randomID() string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

type conn struct {
	mu   sync.Mutex
	enc  *json.Encoder
	pane atomic.Bool // a subscribe asked for pane events
}

func (c *conn) send(v any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.enc.Encode(v)
}

// Serve reads requests from r and writes replies and events to w until r ends or ctx is done.
func (s *Server) Serve(ctx context.Context, r io.Reader, w io.Writer) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	c := &conn{enc: json.NewEncoder(w)}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), MaxLine)
	var wg sync.WaitGroup
	defer wg.Wait()
	var subOnce sync.Once
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			_ = c.send(Response{V: Version, OK: false, Error: errf(CodeBadRequest, "not a JSON object: "+err.Error())})
			continue
		}
		if req.Op == "subscribe" {
			if wantsPane(req.Args) {
				c.pane.Store(true)
			}
			subOnce.Do(func() {
				ch, unsub := s.d.Watcher.Subscribe()
				wg.Add(1)
				go func() {
					defer wg.Done()
					defer unsub()
					s.forward(ctx, c, ch)
				}()
			})
		}
		wg.Add(1)
		go func(req Request) {
			defer wg.Done()
			_ = c.send(s.handle(ctx, req))
		}(req)
	}
	cancel()
	if err := sc.Err(); err != nil {
		return fmt.Errorf("read request: %w", err)
	}
	return nil
}

// wantsPane reports whether subscribe's args ask for pane events ({"pane":true}); older clients get none.
func wantsPane(raw json.RawMessage) bool {
	var a struct {
		Pane bool `json:"pane"`
	}
	return len(raw) > 0 && json.Unmarshal(raw, &a) == nil && a.Pane
}

func (s *Server) forward(ctx context.Context, c *conn, ch <-chan watch.Event) {
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-ch:
			if !ok {
				return
			}
			if ev.Kind == watch.EvPane && !c.pane.Load() {
				continue
			}
			if err := c.send(EventJSON(ev)); err != nil {
				return
			}
		}
	}
}

// EventJSON converts a watcher event into its protocol line.
func EventJSON(ev watch.Event) EventMsg {
	switch ev.Kind {
	case timeout.EvExpiring:
		return EventMsg{V: Version, Event: string(ev.Kind), Data: map[string]any{"id": ev.ID, "reason": ev.Reason,
			"at": ev.At.UTC(), "fg_command": ev.FgCommand}}
	case timeout.EvClosed:
		return EventMsg{V: Version, Event: string(ev.Kind), Data: map[string]any{"id": ev.ID, "reason": ev.Reason}}
	case watch.EvPane:
		return EventMsg{V: Version, Event: string(ev.Kind), Data: map[string]any{"id": ev.ID, "pane": PaneOf(ev.Pane)}}
	default:
		return EventMsg{V: Version, Event: string(ev.Kind), Data: map[string]any{"id": ev.ID, "state": ev.State}}
	}
}

func (s *Server) handle(ctx context.Context, req Request) Response {
	res, err := s.dispatch(ctx, req)
	if err != nil {
		var e *Error
		if !errors.As(err, &e) {
			e = errf(CodeBackend, err.Error())
		}
		if errors.Is(err, backend.ErrNotFound) {
			e = errf(CodeNotFound, err.Error())
		}
		s.d.Log.Info("request failed", "op", req.Op, "code", e.Code)
		return Response{V: Version, ID: req.ID, OK: false, Error: e}
	}
	return Response{V: Version, ID: req.ID, OK: true, Result: res}
}

func decode(raw json.RawMessage, v any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	if err := json.Unmarshal(raw, v); err != nil {
		return errf(CodeBadRequest, "args: "+err.Error())
	}
	return nil
}

func (s *Server) dispatch(ctx context.Context, req Request) (any, error) {
	if req.V != Version {
		return nil, errf(CodeUnsupportedVer, fmt.Sprintf("v=%d; this daemon speaks v=%d", req.V, Version))
	}
	switch req.Op {
	case "hello":
		return s.hello(ctx, req.Args)
	case "list":
		return s.list(ctx, req.Args)
	case "create":
		return s.create(ctx, req.Args)
	case "scrollback":
		return s.scrollback(ctx, req.Args)
	case "set_timeouts":
		return s.setTimeouts(ctx, req.Args)
	case "extend":
		return s.extend(ctx, req.Args)
	case "close":
		return s.closeSession(ctx, req.Args)
	case "status":
		var a idArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		info, ok := s.d.Watcher.Get(a.ID)
		if !ok {
			return nil, notFound(a.ID)
		}
		return map[string]any{"session": SessionOf(info)}, nil
	case "subscribe":
		return struct{}{}, nil
	case "health":
		return s.health(ctx), nil
	case "adopt_candidates", "adopt", "push_register":
		return nil, errf(CodeNotImplemented, req.Op+" is not in this build (phase 2)")
	default:
		return nil, errf(CodeUnknownOp, fmt.Sprintf("unknown op %q", req.Op))
	}
}

func notFound(id string) error {
	return &Error{Code: CodeNotFound, Message: fmt.Sprintf("no session %q", id)}
}

func (s *Server) hello(ctx context.Context, raw json.RawMessage) (any, error) {
	var a helloArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	ok := len(a.Proto) == 0
	for _, p := range a.Proto {
		ok = ok || p == Version
	}
	if !ok {
		return nil, errf(CodeUnsupportedVer, fmt.Sprintf("client speaks %v; this daemon speaks [%d]", a.Proto, Version))
	}
	var h HelloResult
	if s.d.Hello != nil {
		h = s.d.Hello(ctx)
	}
	h.Proto, h.Version = Version, s.d.Version
	if h.DefaultBackend == "" {
		h.DefaultBackend = s.d.Backend.Name()
	}
	if h.Missing == nil {
		h.Missing = []string{}
	}
	s.d.Log.Info("hello", "client", a.Client)
	return h, nil
}

func (s *Server) list(ctx context.Context, raw json.RawMessage) (any, error) {
	var a listArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	sessions := []SessionJSON{}
	for _, info := range s.d.Watcher.All() {
		sessions = append(sessions, SessionOf(info))
	}
	sortSessions(sessions)
	foreign := []ForeignJSON{}
	if a.IncludeForeign {
		fs, err := s.d.Backend.Foreign(ctx)
		if err != nil {
			s.d.Log.Warn("foreign list failed", "err", err)
		}
		for _, f := range fs {
			foreign = append(foreign, ForeignJSON{Name: f.Name, Backend: f.Backend, AttachedClients: f.AttachedClients,
				Attach: f.Attach})
		}
	}
	return map[string]any{"sessions": sessions, "foreign": foreign}, nil
}

func secs(name string, v *int64, out *time.Duration) error {
	if v == nil {
		return nil
	}
	if *v < 0 || *v > maxTimeoutSecs {
		return errf(CodeBadRequest, fmt.Sprintf("%s must be between 0 and %d", name, maxTimeoutSecs))
	}
	*out = time.Duration(*v) * time.Second
	return nil
}

func applyTimeouts(p timeout.Policy, a *timeoutArgs) (timeout.Policy, error) {
	if a == nil {
		return p, nil
	}
	for _, f := range []struct {
		name string
		v    *int64
		out  *time.Duration
	}{{"idle_s", a.IdleS, &p.Idle}, {"hard_s", a.HardS, &p.Hard}, {"warn_lead_s", a.WarnLeadS, &p.WarnLead}} {
		if err := secs(f.name, f.v, f.out); err != nil {
			return p, err
		}
	}
	if a.FinishWork != nil {
		p.FinishWork = *a.FinishWork
	}
	return p, nil
}

func (s *Server) create(ctx context.Context, raw json.RawMessage) (any, error) {
	var a createArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if err := s.checkBackend(a.Backend); err != nil {
		return nil, err
	}
	switch {
	case len(a.Name) > maxNameLen:
		return nil, errf(CodeBadRequest, fmt.Sprintf("name longer than %d bytes", maxNameLen))
	case len(a.Command) > maxCommandLen:
		return nil, errf(CodeBadRequest, fmt.Sprintf("command longer than %d bytes", maxCommandLen))
	case a.Cwd != "" && !filepath.IsAbs(a.Cwd):
		return nil, errf(CodeBadRequest, "cwd must be an absolute path")
	case a.Cols < 0 || a.Cols > maxTermSize || a.Rows < 0 || a.Rows > maxTermSize:
		return nil, errf(CodeBadRequest, fmt.Sprintf("cols and rows must be between 0 and %d", maxTermSize))
	}
	p, err := applyTimeouts(s.d.Defaults, a.Timeouts)
	if err != nil {
		return nil, err
	}
	id := s.d.NewID()
	meta := timeout.ToMeta(timeout.New(time.Now()), p)
	meta[MetaName] = a.Name
	sess, err := s.d.Backend.Create(ctx, backend.CreateOpts{ID: id, Backend: a.Backend, Cwd: a.Cwd, Command: a.Command, Cols: a.Cols,
		Rows: a.Rows, Meta: meta})
	if err != nil {
		return nil, err
	}
	if sess.Meta == nil {
		sess.Meta = map[string]string{MetaName: a.Name}
	}
	info := s.d.Watcher.Track(ctx, sess, p)
	s.d.Log.Info("created", "id", id) // never the command
	return map[string]any{"id": id, "session": SessionOf(info)}, nil
}

// checkBackend rejects a backend name this daemon does not have (backend_error, as for one not installed).
func (s *Server) checkBackend(name string) error {
	if name == "" {
		return nil
	}
	names := []string{s.d.Backend.Name()}
	if m, ok := s.d.Backend.(interface{ Names() []string }); ok {
		names = m.Names()
	}
	if !slices.Contains(names, name) {
		return errf(CodeBackend, fmt.Sprintf("unknown backend %q; this daemon has %s", name, strings.Join(names, ", ")))
	}
	return nil
}

func (s *Server) scrollback(ctx context.Context, raw json.RawMessage) (any, error) {
	var a scrollbackArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if a.Lines < 0 || a.Lines > maxScrollback {
		return nil, errf(CodeBadRequest, fmt.Sprintf("lines must be between 0 and %d", maxScrollback))
	}
	if a.Lines == 0 {
		a.Lines = 5000
	}
	if _, ok := s.d.Watcher.Get(a.ID); !ok {
		return nil, notFound(a.ID)
	}
	data, err := s.d.Backend.Capture(ctx, a.ID, a.Lines)
	if err != nil {
		return nil, err
	}
	return map[string]any{"id": a.ID, "data": data}, nil
}

func (s *Server) setTimeouts(ctx context.Context, raw json.RawMessage) (any, error) {
	var a setTimeoutsArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	cur, ok := s.d.Watcher.Get(a.ID)
	if !ok {
		return nil, notFound(a.ID)
	}
	p, err := applyTimeouts(cur.Policy, &a.timeoutArgs)
	if err != nil {
		return nil, err
	}
	info, err := s.d.Watcher.SetPolicy(ctx, a.ID, p)
	if err != nil {
		return nil, err
	}
	return map[string]any{"session": SessionOf(info)}, nil
}

func (s *Server) extend(ctx context.Context, raw json.RawMessage) (any, error) {
	var a extendArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	w := timeout.Which(a.Which)
	if a.Which == "" {
		w = timeout.ExtendBoth
	}
	if !w.Valid() {
		return nil, errf(CodeBadRequest, `which must be "idle", "hard" or "both"`)
	}
	idleBy, hardBy := s.d.ExtendIdle, s.d.ExtendHard
	if a.ByS != nil {
		var by time.Duration
		if err := secs("by_s", a.ByS, &by); err != nil {
			return nil, err
		}
		idleBy, hardBy = by, by
	}
	info, err := s.d.Watcher.Extend(ctx, a.ID, w, idleBy, hardBy)
	if err != nil {
		return nil, err
	}
	return map[string]any{"session": SessionOf(info)}, nil
}

func (s *Server) closeSession(ctx context.Context, raw json.RawMessage) (any, error) {
	var a idArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if err := s.d.Watcher.Close(ctx, a.ID); err != nil {
		return nil, err
	}
	return map[string]any{"id": a.ID}, nil
}

func (s *Server) health(ctx context.Context) map[string]any {
	ver, _ := s.d.Backend.Version(ctx)
	pid := 0
	if s.d.ServerPID != nil {
		pid = s.d.ServerPID(ctx)
	}
	return map[string]any{
		"version":    s.d.Version,
		"uptime_s":   int64(time.Since(s.d.Started) / time.Second),
		"backend":    map[string]any{"name": s.d.Backend.Name(), "version": ver, "server_pid": pid},
		"sessions":   len(s.d.Watcher.All()),
		"last_error": s.d.Watcher.LastError(),
	}
}
