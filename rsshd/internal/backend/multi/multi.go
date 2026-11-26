// Package multi puts several backends behind the one backend.Backend the daemon uses: create picks one by
// name (CreateOpts.Backend, "" = the default), list merges them, and every per-session call goes to the backend
// that holds the session. A backend that is not installed is left out, so a host with only screen (or only
// tmux) works.
package multi

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend"
)

// installedTTL is how long a Version probe is trusted; installing screen is picked up within it.
const installedTTL = 30 * time.Second

type probe struct {
	ok bool
	at time.Time
}

// Multi routes between backends. All methods are safe for concurrent use.
type Multi struct {
	def string
	bs  []backend.Backend // the default first

	mu    sync.Mutex
	owner map[string]string // session id -> backend name, learnt from Create and List
	inst  map[string]probe
	now   func() time.Time
}

var _ backend.Backend = (*Multi)(nil)

// New returns a Multi whose default is the backend named def; it must be one of bs.
func New(def string, bs ...backend.Backend) (*Multi, error) {
	m := &Multi{def: def, owner: map[string]string{}, inst: map[string]probe{}, now: time.Now}
	for _, b := range bs {
		if b.Name() == def {
			m.bs = append([]backend.Backend{b}, m.bs...)
		} else {
			m.bs = append(m.bs, b)
		}
	}
	if len(m.bs) == 0 || m.bs[0].Name() != def {
		return nil, fmt.Errorf("backend %q: %w", def, ErrUnknown)
	}
	return m, nil
}

// ErrUnknown is returned for a backend name this daemon does not have.
var ErrUnknown = errors.New("unknown backend")

// Name implements backend.Backend: the default backend's name.
func (m *Multi) Name() string { return m.def }

// Names lists every backend this daemon has, the default first.
func (m *Multi) Names() []string {
	out := make([]string, 0, len(m.bs))
	for _, b := range m.bs {
		out = append(out, b.Name())
	}
	return out
}

// Get returns the backend with this name.
func (m *Multi) Get(name string) (backend.Backend, bool) {
	for _, b := range m.bs {
		if b.Name() == name {
			return b, true
		}
	}
	return nil, false
}

// Version implements backend.Backend: the default backend's version.
func (m *Multi) Version(ctx context.Context) (string, error) { return m.bs[0].Version(ctx) }

func (m *Multi) installed(ctx context.Context, b backend.Backend) bool {
	m.mu.Lock()
	p, ok := m.inst[b.Name()]
	m.mu.Unlock()
	if ok && m.now().Sub(p.at) < installedTTL {
		return p.ok
	}
	_, err := b.Version(ctx)
	if ctx.Err() != nil {
		return true // cancelled, not absent: let the real call report it
	}
	m.mu.Lock()
	m.inst[b.Name()] = probe{ok: err == nil, at: m.now()}
	m.mu.Unlock()
	return err == nil
}

// Create implements backend.Backend.
func (m *Multi) Create(ctx context.Context, o backend.CreateOpts) (backend.Session, error) {
	name := o.Backend
	if name == "" {
		name = m.def
	}
	b, ok := m.Get(name)
	if !ok {
		return backend.Session{}, fmt.Errorf("%w %q: this daemon has %s", ErrUnknown, name, strings.Join(m.Names(), ", "))
	}
	if _, err := b.Version(ctx); err != nil {
		return backend.Session{}, fmt.Errorf("backend %q is not installed on this host (install %s): %w", name, name, err)
	}
	s, err := b.Create(ctx, o)
	if err == nil {
		m.setOwner(s.ID, name)
	}
	return s, err
}

func (m *Multi) setOwner(id, name string) {
	m.mu.Lock()
	m.owner[id] = name
	m.mu.Unlock()
}

// List implements backend.Backend. Any backend's failure fails the whole list, so the watcher never mistakes
// one backend's sessions for ended ones.
func (m *Multi) List(ctx context.Context) ([]backend.Session, error) {
	var all []backend.Session
	owner := map[string]string{}
	for _, b := range m.bs {
		if !m.installed(ctx, b) {
			continue
		}
		l, err := b.List(ctx)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", b.Name(), err)
		}
		for _, s := range l {
			owner[s.ID] = b.Name()
		}
		all = append(all, l...)
	}
	m.mu.Lock()
	m.owner = owner
	m.mu.Unlock()
	return all, nil
}

// Foreign implements backend.Backend: every installed backend's foreign sessions; a failing one is reported
// but does not hide the others.
func (m *Multi) Foreign(ctx context.Context) ([]backend.Foreign, error) {
	var all []backend.Foreign
	var errs []error
	for _, b := range m.bs {
		if !m.installed(ctx, b) {
			continue
		}
		l, err := b.Foreign(ctx)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", b.Name(), err))
		}
		all = append(all, l...)
	}
	return all, errors.Join(errs...)
}

// route calls f on the backend that holds id: the known owner first, then the others, skipping not-found.
func (m *Multi) route(ctx context.Context, id string, f func(backend.Backend) error) error {
	m.mu.Lock()
	known := m.owner[id]
	m.mu.Unlock()
	order := make([]backend.Backend, 0, len(m.bs))
	if b, ok := m.Get(known); ok {
		order = append(order, b)
	}
	for _, b := range m.bs {
		if b.Name() != known && m.installed(ctx, b) {
			order = append(order, b)
		}
	}
	err := fmt.Errorf("session %s: %w", id, backend.ErrNotFound)
	for _, b := range order {
		if err = f(b); !errors.Is(err, backend.ErrNotFound) {
			if err == nil {
				m.setOwner(id, b.Name())
			}
			return err
		}
	}
	return err
}

// Attach implements backend.Backend.
func (m *Multi) Attach(ctx context.Context, id string) (argv []string, err error) {
	err = m.route(ctx, id, func(b backend.Backend) (e error) { argv, e = b.Attach(ctx, id); return e })
	return argv, err
}

// Capture implements backend.Backend.
func (m *Multi) Capture(ctx context.Context, id string, lines int) (data string, err error) {
	err = m.route(ctx, id, func(b backend.Backend) (e error) { data, e = b.Capture(ctx, id, lines); return e })
	return data, err
}

// Kill implements backend.Backend.
func (m *Multi) Kill(ctx context.Context, id string, grace time.Duration) error {
	return m.route(ctx, id, func(b backend.Backend) error { return b.Kill(ctx, id, grace) })
}

// Meta implements backend.Backend.
func (m *Multi) Meta(ctx context.Context, id string, set map[string]string) (meta map[string]string, err error) {
	err = m.route(ctx, id, func(b backend.Backend) (e error) { meta, e = b.Meta(ctx, id, set); return e })
	return meta, err
}
