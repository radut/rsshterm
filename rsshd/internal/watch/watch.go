// Package watch polls the backend, feeds each managed session's probe result to its timeout machine, persists
// the machine in the session's metadata, closes expired sessions and fans the events out to subscribers.
package watch

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/probe"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/timeout"
)

// Reasons of a closed event besides the timeout ones.
const (
	ReasonClosed = "closed" // the client asked
	ReasonExited = "exited" // the shell ended by itself
)

// EvPane is published when a session's foreground program, its arguments or its folder change (tab titles).
const EvPane timeout.EventKind = "pane"

// Event is a protocol event for one session.
type Event struct {
	ID string
	timeout.Event
	Pane probe.Pane // EvPane
}

// Info is everything known about one managed session.
type Info struct {
	Session backend.Session
	Machine timeout.Machine
	Policy  timeout.Policy
	Probe   probe.Result
}

type entry struct {
	info    Info
	closing bool
	tracked time.Time // when Track added it (wall clock); a poll that listed before then has not seen it yet
}

// Options configure a Watcher.
type Options struct {
	Backend    backend.Backend
	Prober     probe.Prober
	Defaults   timeout.Policy
	Interval   time.Duration
	CloseGrace time.Duration
	Log        *slog.Logger
	Now        func() time.Time // nil = time.Now
}

// Watcher owns the timeout state of all managed sessions.
type Watcher struct {
	o       Options
	mu      sync.Mutex
	entries map[string]*entry
	subs    map[chan Event]struct{}
	lastErr string
	kills   sync.WaitGroup
}

// New returns a Watcher; call Run to start polling.
func New(o Options) *Watcher {
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Log == nil {
		o.Log = slog.New(slog.DiscardHandler)
	}
	return &Watcher{o: o, entries: map[string]*entry{}, subs: map[chan Event]struct{}{}}
}

// Run polls until ctx ends, then waits for closes in progress.
func (w *Watcher) Run(ctx context.Context) {
	t := time.NewTicker(w.o.Interval)
	defer t.Stop()
	for {
		w.Tick(ctx)
		select {
		case <-ctx.Done():
			w.kills.Wait()
			return
		case <-t.C:
		}
	}
}

// LastError is the newest poll error, "" when the last poll worked.
func (w *Watcher) LastError() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.lastErr
}

// Tick runs one poll: list, probe, step, persist, close.
func (w *Watcher) Tick(ctx context.Context) {
	listedAt := time.Now()
	sessions, err := w.o.Backend.List(ctx)
	if err != nil {
		w.setErr(fmt.Errorf("list: %w", err))
		return
	}
	w.setErr(nil)
	probes := make(map[string]probe.Result, len(sessions))
	for _, s := range sessions {
		r, err := w.o.Prober.Probe(ctx, s)
		if err != nil {
			w.o.Log.Warn("probe failed", "id", s.ID, "err", err)
		}
		probes[s.ID] = r
	}
	now := w.o.Now()

	w.mu.Lock()
	var events []Event
	var persist []Info
	var toClose []string
	seen := map[string]bool{}
	for _, s := range sessions {
		seen[s.ID] = true
		e, ok := w.entries[s.ID]
		if !ok {
			m, p := timeout.FromMeta(s.Meta, w.o.Defaults, s.Created)
			e = &entry{info: Info{Machine: m, Policy: p}}
			w.entries[s.ID] = e
		}
		if !e.closing && !e.info.Probe.Pane.Equal(probes[s.ID].Pane) {
			events = append(events, Event{ID: s.ID, Event: timeout.Event{Kind: EvPane}, Pane: probes[s.ID].Pane})
		}
		e.info.Session, e.info.Probe = s, probes[s.ID]
		if e.closing {
			continue
		}
		m, evs := timeout.Step(e.info.Machine, e.info.Policy, probes[s.ID], now)
		if m != e.info.Machine {
			e.info.Machine = m
			persist = append(persist, e.info)
		}
		for _, ev := range evs {
			events = append(events, Event{ID: s.ID, Event: ev})
		}
		if m.State == timeout.Closed {
			e.closing = true
			toClose = append(toClose, s.ID)
		}
	}
	for id, e := range w.entries {
		if seen[id] || e.tracked.After(listedAt) {
			continue
		}
		delete(w.entries, id)
		if !e.closing {
			events = append(events, Event{ID: id, Event: timeout.Event{Kind: timeout.EvClosed, Reason: ReasonExited}})
		}
	}
	w.mu.Unlock()

	for _, info := range persist {
		w.persist(ctx, info)
	}
	w.publish(events...)
	for _, id := range toClose {
		w.kill(ctx, id)
	}
}

func (w *Watcher) setErr(err error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if err == nil {
		w.lastErr = ""
		return
	}
	w.lastErr = err.Error()
	w.o.Log.Error("poll failed", "err", err)
}

func (w *Watcher) persist(ctx context.Context, info Info) {
	if _, err := w.o.Backend.Meta(ctx, info.Session.ID, timeout.ToMeta(info.Machine, info.Policy)); err != nil &&
		!errors.Is(err, backend.ErrNotFound) {
		w.o.Log.Warn("persist failed", "id", info.Session.ID, "err", err)
	}
}

// kill removes the session in the background; the closed event was already published by the machine (or by
// Close), and the entry disappears on the next poll.
func (w *Watcher) kill(ctx context.Context, id string) {
	w.kills.Add(1)
	go func() {
		defer w.kills.Done()
		kctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), w.o.CloseGrace+10*time.Second)
		defer cancel()
		if err := w.o.Backend.Kill(kctx, id, w.o.CloseGrace); err != nil && !errors.Is(err, backend.ErrNotFound) {
			w.o.Log.Error("close failed", "id", id, "err", err)
		}
	}()
}

// WaitCloses blocks until background closes are done (tests, shutdown).
func (w *Watcher) WaitCloses() { w.kills.Wait() }

// Track registers a session created by this daemon with its policy.
func (w *Watcher) Track(ctx context.Context, s backend.Session, p timeout.Policy) Info {
	// Created is taken now (tmux keeps whole seconds), so the hard deadline is exact. The activity clock stays
	// on the backend's whole seconds, so output later in the creation second still counts as new.
	m := timeout.New(w.o.Now())
	if !s.ActivityAt.IsZero() && s.ActivityAt.Before(m.LastActivity) {
		m.LastActivity = s.ActivityAt
	}
	info := Info{Session: s, Machine: m, Policy: p, Probe: probe.Result{ActivityAt: s.ActivityAt,
		FgCommand: s.PaneCommand, AltScreen: s.AltScreen}}
	w.mu.Lock()
	w.entries[s.ID] = &entry{info: info, tracked: time.Now()}
	w.mu.Unlock()
	w.persist(ctx, info)
	return info
}

// ErrNotFound is returned for an id the watcher does not manage.
var ErrNotFound = backend.ErrNotFound

func (w *Watcher) update(ctx context.Context, id string,
	f func(Info) (timeout.Machine, timeout.Policy, []timeout.Event)) (Info, error) {
	w.mu.Lock()
	e, ok := w.entries[id]
	if !ok || e.closing {
		w.mu.Unlock()
		return Info{}, fmt.Errorf("session %s: %w", id, ErrNotFound)
	}
	m, p, evs := f(e.info)
	e.info.Machine, e.info.Policy = m, p
	info := e.info
	w.mu.Unlock()
	w.persist(ctx, info)
	for _, ev := range evs {
		w.publish(Event{ID: id, Event: ev})
	}
	return info, nil
}

// SetPolicy replaces a live session's policy; pending warnings are withdrawn and the next poll re-evaluates.
func (w *Watcher) SetPolicy(ctx context.Context, id string, p timeout.Policy) (Info, error) {
	return w.update(ctx, id, func(i Info) (timeout.Machine, timeout.Policy, []timeout.Event) {
		m, evs := timeout.Reset(i.Machine)
		return m, p, evs
	})
}

// Extend moves a session's deadlines (timeout.Extend).
func (w *Watcher) Extend(ctx context.Context, id string, which timeout.Which, idleBy, hardBy time.Duration) (Info, error) {
	now := w.o.Now()
	return w.update(ctx, id, func(i Info) (timeout.Machine, timeout.Policy, []timeout.Event) {
		m, evs := timeout.Extend(i.Machine, i.Policy, which, idleBy, hardBy, now)
		return m, i.Policy, evs
	})
}

// Close ends a session at the client's request: closed event now, kill in the background.
func (w *Watcher) Close(ctx context.Context, id string) error {
	_, err := w.update(ctx, id, func(i Info) (timeout.Machine, timeout.Policy, []timeout.Event) {
		return timeout.CloseRequested(i.Machine), i.Policy,
			[]timeout.Event{{Kind: timeout.EvClosed, Reason: ReasonClosed}}
	})
	if err != nil {
		return err
	}
	w.mu.Lock()
	if e, ok := w.entries[id]; ok {
		e.closing = true
	}
	w.mu.Unlock()
	w.kill(ctx, id)
	return nil
}

// Get returns one session's info.
func (w *Watcher) Get(id string) (Info, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	e, ok := w.entries[id]
	if !ok || e.closing {
		return Info{}, false
	}
	return e.info, true
}

// All returns every live managed session.
func (w *Watcher) All() []Info {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := make([]Info, 0, len(w.entries))
	for _, e := range w.entries {
		if !e.closing {
			out = append(out, e.info)
		}
	}
	return out
}

// Subscribe returns a channel of events and a cancel function. A subscriber that does not keep up loses events
// rather than blocking the watcher.
func (w *Watcher) Subscribe() (<-chan Event, func()) {
	ch := make(chan Event, 64)
	w.mu.Lock()
	w.subs[ch] = struct{}{}
	w.mu.Unlock()
	var once sync.Once
	return ch, func() {
		once.Do(func() {
			w.mu.Lock()
			delete(w.subs, ch)
			w.mu.Unlock()
			close(ch)
		})
	}
}

func (w *Watcher) publish(events ...Event) {
	if len(events) == 0 {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, ev := range events {
		w.o.Log.Info("event", "id", ev.ID, "kind", ev.Kind, "state", ev.State, "reason", ev.Reason)
		for ch := range w.subs {
			select {
			case ch <- ev:
			default:
				w.o.Log.Warn("subscriber too slow, event dropped", "id", ev.ID, "kind", ev.Kind)
			}
		}
	}
}
