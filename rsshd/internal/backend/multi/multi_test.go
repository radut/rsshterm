package multi

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/backend"
	"github.com/radut/rsshterm/rsshd/internal/backend/fake"
)

func pair(t *testing.T, def string) (*Multi, *fake.Backend, *fake.Backend) {
	t.Helper()
	tm, sc := fake.New(), fake.New()
	sc.Label = "screen"
	m, err := New(def, tm, sc)
	if err != nil {
		t.Fatal(err)
	}
	return m, tm, sc
}

func TestNew(t *testing.T) {
	m, _, _ := pair(t, "screen")
	if m.Name() != "screen" || strings.Join(m.Names(), ",") != "screen,tmux" {
		t.Fatalf("%s %v", m.Name(), m.Names())
	}
	if _, err := New("zellij", fake.New()); !errors.Is(err, ErrUnknown) {
		t.Fatal(err)
	}
	if v, err := m.Version(context.Background()); err != nil || v != "3.4" {
		t.Fatal(v, err)
	}
}

func TestCreateAndRoute(t *testing.T) {
	ctx := context.Background()
	m, tm, sc := pair(t, "tmux")
	a, err := m.Create(ctx, backend.CreateOpts{ID: "0000000a"})
	if err != nil || a.Backend != "tmux" {
		t.Fatal(a, err)
	}
	b, err := m.Create(ctx, backend.CreateOpts{ID: "0000000b", Backend: "screen"})
	if err != nil || b.Backend != "screen" {
		t.Fatal(b, err)
	}
	if _, ok := sc.Get("0000000b"); !ok {
		t.Fatal("screen session not in the screen backend")
	}
	l, err := m.List(ctx)
	if err != nil || len(l) != 2 {
		t.Fatalf("list %v %v", l, err)
	}
	// A fresh router (daemon restart) finds the owner without a cache.
	m2, _ := New("tmux", tm, sc)
	if _, err := m2.Meta(ctx, "0000000b", map[string]string{"k": "v"}); err != nil {
		t.Fatal(err)
	}
	if s, _ := sc.Get("0000000b"); s.Meta["k"] != "v" {
		t.Fatalf("meta went elsewhere: %+v", s)
	}
	if _, err := m2.Capture(ctx, "0000000b", 10); err != nil {
		t.Fatal(err)
	}
	if _, err := m2.Attach(ctx, "0000000a"); err != nil {
		t.Fatal(err)
	}
	if err := m2.Kill(ctx, "0000000b", time.Second); err != nil {
		t.Fatal(err)
	}
	if len(sc.KilledIDs()) != 1 || len(tm.KilledIDs()) != 0 {
		t.Fatalf("killed tmux %v screen %v", tm.KilledIDs(), sc.KilledIDs())
	}
	if err := m2.Kill(ctx, "0000ffff", time.Second); !errors.Is(err, backend.ErrNotFound) {
		t.Fatal(err)
	}
}

func TestCreateErrors(t *testing.T) {
	ctx := context.Background()
	m, _, sc := pair(t, "tmux")
	if _, err := m.Create(ctx, backend.CreateOpts{ID: "0000000a", Backend: "zellij"}); !errors.Is(err, ErrUnknown) ||
		!strings.Contains(err.Error(), "tmux, screen") {
		t.Fatal(err)
	}
	sc.Missing = true
	_, err := m.Create(ctx, backend.CreateOpts{ID: "0000000a", Backend: "screen"})
	if err == nil || !strings.Contains(err.Error(), `"screen" is not installed`) {
		t.Fatal(err)
	}
}

func TestMissingBackendIsSkipped(t *testing.T) {
	ctx := context.Background()
	m, tm, sc := pair(t, "tmux")
	if _, err := m.Create(ctx, backend.CreateOpts{ID: "0000000a"}); err != nil {
		t.Fatal(err)
	}
	sc.Missing = true
	sc.ListErr = errors.New("exec: screen: not found")
	if l, err := m.List(ctx); err != nil || len(l) != 1 {
		t.Fatalf("list %v %v", l, err)
	}
	if _, err := m.Foreign(ctx); err != nil {
		t.Fatal(err)
	}
	// An installed backend that fails fails the whole list (the watcher must not see its sessions as ended).
	tm.ListErr = errors.New("boom")
	if _, err := m.List(ctx); err == nil || !strings.Contains(err.Error(), "tmux: boom") {
		t.Fatal(err)
	}
}

func TestInstalledIsCached(t *testing.T) {
	ctx := context.Background()
	m, _, sc := pair(t, "tmux")
	now := time.Unix(1000, 0)
	m.now = func() time.Time { return now }
	sc.Missing = true
	if m.installed(ctx, sc) {
		t.Fatal("missing reported installed")
	}
	sc.Missing = false
	if m.installed(ctx, sc) {
		t.Fatal("cache not used")
	}
	now = now.Add(installedTTL + time.Second)
	if !m.installed(ctx, sc) {
		t.Fatal("cache not refreshed")
	}
}
