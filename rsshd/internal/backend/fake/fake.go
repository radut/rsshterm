// Package fake is an in-memory backend.Backend for tests.
package fake

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"sync"
	"time"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend"
)

// Backend keeps sessions in a map. Tests change sessions with Set.
type Backend struct {
	mu       sync.Mutex
	sessions map[string]backend.Session
	order    []string
	Killed   []string
	ListErr  error
	Now      func() time.Time
	Label    string // Name(); "" = "tmux"
	Missing  bool   // Version fails, as for a multiplexer that is not installed
}

var _ backend.Backend = (*Backend)(nil)

// New returns an empty fake.
func New() *Backend { return &Backend{sessions: map[string]backend.Session{}, Now: time.Now} }

// Name implements backend.Backend.
func (b *Backend) Name() string {
	if b.Label == "" {
		return "tmux"
	}
	return b.Label
}

// Version implements backend.Backend.
func (b *Backend) Version(context.Context) (string, error) {
	if b.Missing {
		return "", errors.New(b.Name() + " not found")
	}
	return "3.4", nil
}

// Create implements backend.Backend.
func (b *Backend) Create(_ context.Context, o backend.CreateOpts) (backend.Session, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.Now()
	s := backend.Session{ID: o.ID, Backend: b.Name(), Created: now, ActivityAt: now, PanePID: 100 + len(b.order),
		PaneCommand: "bash", Meta: maps.Clone(o.Meta)}
	if s.Meta == nil {
		s.Meta = map[string]string{}
	}
	b.sessions[o.ID] = s
	b.order = append(b.order, o.ID)
	return s, nil
}

// Set replaces a session's live fields (activity, pane command...), keeping its metadata.
func (b *Backend) Set(s backend.Session) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if old, ok := b.sessions[s.ID]; ok && s.Meta == nil {
		s.Meta = old.Meta
	}
	if _, ok := b.sessions[s.ID]; !ok {
		b.order = append(b.order, s.ID)
	}
	b.sessions[s.ID] = s
}

// Remove drops a session as if its shell exited.
func (b *Backend) Remove(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.sessions, id)
}

// Get returns a session.
func (b *Backend) Get(id string) (backend.Session, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	s, ok := b.sessions[id]
	return s, ok
}

// List implements backend.Backend.
func (b *Backend) List(context.Context) ([]backend.Session, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ListErr != nil {
		return nil, b.ListErr
	}
	var out []backend.Session
	for _, id := range b.order {
		if s, ok := b.sessions[id]; ok {
			s.Meta = maps.Clone(s.Meta)
			out = append(out, s)
		}
	}
	return out, nil
}

// Foreign implements backend.Backend.
func (b *Backend) Foreign(context.Context) ([]backend.Foreign, error) {
	return []backend.Foreign{{Name: "main", Backend: "tmux", Attach: []string{"tmux", "attach", "-t", "=main"}}}, nil
}

// Attach implements backend.Backend.
func (b *Backend) Attach(_ context.Context, id string) ([]string, error) {
	if _, ok := b.Get(id); !ok {
		return nil, fmt.Errorf("%s: %w", id, backend.ErrNotFound)
	}
	return []string{"tmux", "attach", "-t", "=rssh-" + id}, nil
}

// Capture implements backend.Backend.
func (b *Backend) Capture(_ context.Context, id string, lines int) (string, error) {
	if _, ok := b.Get(id); !ok {
		return "", fmt.Errorf("%s: %w", id, backend.ErrNotFound)
	}
	return fmt.Sprintf("history of %s (%d)\n", id, lines), nil
}

// Kill implements backend.Backend.
func (b *Backend) Kill(_ context.Context, id string, _ time.Duration) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, ok := b.sessions[id]; !ok {
		return fmt.Errorf("%s: %w", id, backend.ErrNotFound)
	}
	delete(b.sessions, id)
	b.Killed = append(b.Killed, id)
	return nil
}

// KilledIDs returns a copy of the killed ids.
func (b *Backend) KilledIDs() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.Killed...)
}

// Meta implements backend.Backend.
func (b *Backend) Meta(_ context.Context, id string, set map[string]string) (map[string]string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	s, ok := b.sessions[id]
	if !ok {
		return nil, fmt.Errorf("%s: %w", id, backend.ErrNotFound)
	}
	m := maps.Clone(s.Meta)
	if m == nil {
		m = map[string]string{}
	}
	maps.Copy(m, set)
	s.Meta = m
	b.sessions[id] = s
	return maps.Clone(m), nil
}
