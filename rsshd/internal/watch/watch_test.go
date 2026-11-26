package watch

import (
	"context"
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/backend"
	"github.com/radut/rsshterm/rsshd/internal/backend/fake"
	"github.com/radut/rsshterm/rsshd/internal/probe"
	"github.com/radut/rsshterm/rsshd/internal/timeout"
)

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) Now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) Add(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// fgProbe reports a job running for the ids in running.
type fgProbe struct {
	mu      sync.Mutex
	running map[string]bool
}

func (p *fgProbe) set(id string, v bool) { p.mu.Lock(); p.running[id] = v; p.mu.Unlock() }
func (p *fgProbe) Probe(_ context.Context, s backend.Session) (probe.Result, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if s.PanePID < 0 {
		return probe.Result{}, errors.New("gone")
	}
	return probe.Result{ActivityAt: s.ActivityAt, FgRunning: p.running[s.ID], FgCommand: s.PaneCommand}, nil
}

var pol = timeout.Policy{Idle: 60 * time.Second, Hard: time.Hour, WarnLead: 10 * time.Second, FinishWork: true}

func setup(t *testing.T) (*Watcher, *fake.Backend, *clock, *fgProbe) {
	c := &clock{t: time.Date(2026, 11, 24, 12, 0, 0, 0, time.UTC)}
	be := fake.New()
	be.Now = c.Now
	pr := &fgProbe{running: map[string]bool{}}
	w := New(Options{Backend: be, Prober: pr, Defaults: pol, Interval: time.Millisecond, Now: c.Now})
	return w, be, c, pr
}

func drain(ch <-chan Event) []string {
	var out []string
	for {
		select {
		case e := <-ch:
			s := e.ID + " " + string(e.Kind)
			if e.Kind == timeout.EvState {
				s += ":" + string(e.State)
			} else {
				s += ":" + e.Reason
			}
			out = append(out, s)
		default:
			return out
		}
	}
}

func create(t *testing.T, w *Watcher, be *fake.Backend, id string) {
	s, err := be.Create(context.Background(), backend.CreateOpts{ID: id})
	if err != nil {
		t.Fatal(err)
	}
	w.Track(context.Background(), s, pol)
}

func TestFinishWorkThenClose(t *testing.T) {
	w, be, c, pr := setup(t)
	ctx := context.Background()
	ch, cancel := w.Subscribe()
	defer cancel()
	create(t, w, be, "0000aaaa")
	pr.set("0000aaaa", true)

	c.Add(55 * time.Second)
	w.Tick(ctx)
	c.Add(10 * time.Minute) // a long silent job: still waiting
	w.Tick(ctx)
	if got := drain(ch); !reflect.DeepEqual(got, []string{"0000aaaa state:waiting_for_job"}) {
		t.Fatalf("events %v", got)
	}
	if len(be.KilledIDs()) != 0 {
		t.Fatal("killed while the job runs")
	}
	pr.set("0000aaaa", false)
	w.Tick(ctx)
	c.Add(10 * time.Second)
	w.Tick(ctx)
	w.WaitCloses()
	want := []string{"0000aaaa state:warning_idle", "0000aaaa expiring:idle", "0000aaaa closed:idle"}
	if got := drain(ch); !reflect.DeepEqual(got, want) {
		t.Fatalf("events %v", got)
	}
	if !reflect.DeepEqual(be.KilledIDs(), []string{"0000aaaa"}) {
		t.Fatalf("killed %v", be.KilledIDs())
	}
	w.Tick(ctx) // gone from the backend: no second closed event
	if got := drain(ch); len(got) != 0 || len(w.All()) != 0 {
		t.Fatalf("after close: %v %v", got, w.All())
	}
}

func TestOutputKeepsActiveAndPersists(t *testing.T) {
	w, be, c, _ := setup(t)
	ctx := context.Background()
	ch, cancel := w.Subscribe()
	defer cancel()
	create(t, w, be, "0000bbbb")
	for i := 0; i < 20; i++ {
		c.Add(30 * time.Second)
		s, _ := be.Get("0000bbbb")
		s.ActivityAt = c.Now()
		be.Set(s)
		w.Tick(ctx)
	}
	if got := drain(ch); len(got) != 0 {
		t.Fatalf("events while output flows: %v", got)
	}
	info, ok := w.Get("0000bbbb")
	if !ok || info.Machine.State != timeout.Active || !info.Machine.LastActivity.Equal(c.Now()) {
		t.Fatalf("info %+v", info)
	}
	s, _ := be.Get("0000bbbb")
	if s.Meta[timeout.KeyState] != "active" || s.Meta[timeout.KeyIdle] != "60" {
		t.Fatalf("meta %v", s.Meta)
	}
}

func TestRestartResumesFromMeta(t *testing.T) {
	w, be, c, _ := setup(t)
	ctx := context.Background()
	create(t, w, be, "0000cccc")
	if _, err := w.Extend(ctx, "0000cccc", timeout.ExtendIdle, time.Hour, 0); err != nil {
		t.Fatal(err)
	}
	// A new daemon on the same backend.
	w2 := New(Options{Backend: be, Prober: &fgProbe{running: map[string]bool{}}, Defaults: timeout.Policy{},
		Interval: time.Millisecond, Now: c.Now})
	c.Add(30 * time.Minute)
	w2.Tick(ctx)
	info, ok := w2.Get("0000cccc")
	if !ok || info.Policy != pol || info.Machine.State != timeout.Active {
		t.Fatalf("resumed %+v", info)
	}
	idle, _ := info.Machine.Deadlines(info.Policy)
	if want := c.Now().Add(-30 * time.Minute).Add(time.Hour + time.Minute); !idle.Equal(want) {
		t.Fatalf("idle deadline %v, want %v", idle, want)
	}
}

func TestExitedCloseAndErrors(t *testing.T) {
	w, be, _, _ := setup(t)
	ctx := context.Background()
	ch, cancel := w.Subscribe()
	defer cancel()
	create(t, w, be, "0000dddd")
	create(t, w, be, "0000eeee")
	w.Tick(ctx)
	be.Remove("0000dddd")
	w.Tick(ctx)
	if err := w.Close(ctx, "0000eeee"); err != nil {
		t.Fatal(err)
	}
	w.WaitCloses()
	want := []string{"0000dddd closed:exited", "0000eeee closed:closed"}
	if got := drain(ch); !reflect.DeepEqual(got, want) {
		t.Fatalf("events %v", got)
	}
	if err := w.Close(ctx, "0000eeee"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("close twice: %v", err)
	}
	if _, err := w.SetPolicy(ctx, "nope", pol); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	if _, ok := w.Get("0000eeee"); ok {
		t.Fatal("closing session still visible")
	}
	be.ListErr = errors.New("tmux broke")
	w.Tick(ctx)
	if w.LastError() == "" {
		t.Fatal("poll error not kept")
	}
	be.ListErr = nil
	w.Tick(ctx)
	if w.LastError() != "" {
		t.Fatal("poll error not cleared")
	}
}

func TestSetPolicyWithdrawsWarning(t *testing.T) {
	w, be, c, _ := setup(t)
	ctx := context.Background()
	ch, cancel := w.Subscribe()
	create(t, w, be, "0000ffff")
	c.Add(55 * time.Second)
	w.Tick(ctx)
	p := pol
	p.Idle = time.Hour
	info, err := w.SetPolicy(ctx, "0000ffff", p)
	if err != nil || info.Machine.State != timeout.Active || info.Policy.Idle != time.Hour {
		t.Fatalf("%+v %v", info, err)
	}
	want := []string{"0000ffff state:warning_idle", "0000ffff expiring:idle", "0000ffff state:active"}
	if got := drain(ch); !reflect.DeepEqual(got, want) {
		t.Fatalf("events %v", got)
	}
	cancel()
	cancel() // idempotent
}

// A session created while a poll is listing must not be reported as exited.
func TestTrackDuringPoll(t *testing.T) {
	w, be, _, _ := setup(t)
	ch, cancel := w.Subscribe()
	defer cancel()
	s, _ := be.Create(context.Background(), backend.CreateOpts{ID: "00001111"})
	be.Remove("00001111") // the list will not contain it
	w.mu.Lock()
	w.entries["00001111"] = &entry{info: Info{Session: s}, tracked: time.Now().Add(time.Hour)}
	w.mu.Unlock()
	w.Tick(context.Background())
	if got := drain(ch); len(got) != 0 {
		t.Fatalf("events %v", got)
	}
}

func TestRunStops(t *testing.T) {
	w, be, _, _ := setup(t)
	create(t, w, be, "00002222")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	w.Run(ctx) // returns when ctx ends
	if len(w.All()) != 1 {
		t.Fatal("lost the session")
	}
}

func TestSlowSubscriberDoesNotBlock(t *testing.T) {
	w, _, _, _ := setup(t)
	_, cancel := w.Subscribe()
	defer cancel()
	for i := 0; i < 200; i++ {
		w.publish(Event{ID: "x", Event: timeout.Event{Kind: timeout.EvState, State: timeout.Active}})
	}
}

// paneProbe reports a fixed pane per session id.
type paneProbe struct {
	mu    sync.Mutex
	panes map[string]probe.Pane
}

func (p *paneProbe) set(id string, v probe.Pane) { p.mu.Lock(); p.panes[id] = v; p.mu.Unlock() }
func (p *paneProbe) Probe(_ context.Context, s backend.Session) (probe.Result, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return probe.Result{ActivityAt: s.ActivityAt, FgCommand: s.PaneCommand, Pane: p.panes[s.ID]}, nil
}

func TestPaneChangesArePublished(t *testing.T) {
	c := &clock{t: time.Date(2026, 11, 24, 12, 0, 0, 0, time.UTC)}
	be := fake.New()
	be.Now = c.Now
	pr := &paneProbe{panes: map[string]probe.Pane{}}
	w := New(Options{Backend: be, Prober: pr, Defaults: pol, Interval: time.Millisecond, Now: c.Now})
	create(t, w, be, "a")
	ch, cancel := w.Subscribe()
	defer cancel()

	pr.set("a", probe.Pane{Cwd: "/root"})
	w.Tick(context.Background())
	w.Tick(context.Background()) // unchanged: no second event
	pr.set("a", probe.Pane{Command: "vim", Args: []string{"/etc/hosts"}, Cwd: "/root"})
	w.Tick(context.Background())

	var panes []probe.Pane
	for done := false; !done; {
		select {
		case e := <-ch:
			if e.Kind == EvPane && e.ID == "a" {
				panes = append(panes, e.Pane)
			}
		default:
			done = true
		}
	}
	if len(panes) != 2 || panes[0].Cwd != "/root" || panes[1].Command != "vim" {
		t.Fatalf("pane events %+v", panes)
	}
	if info, _ := w.Get("a"); info.Probe.Pane.Command != "vim" {
		t.Fatalf("info %+v", info.Probe.Pane)
	}
}
