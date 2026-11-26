package timeout

import (
	"reflect"
	"testing"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/probe"
)

var t0 = time.Date(2026, 11, 24, 12, 0, 0, 0, time.UTC)

func sec(n int) time.Time { return t0.Add(time.Duration(n) * time.Second) }

var pol = Policy{Idle: 60 * time.Second, Hard: 600 * time.Second, WarnLead: 10 * time.Second, FinishWork: true}

func kinds(evs []Event) []string {
	var out []string
	for _, e := range evs {
		switch e.Kind {
		case EvState:
			out = append(out, "state:"+string(e.State))
		default:
			out = append(out, string(e.Kind)+":"+e.Reason)
		}
	}
	return out
}

// One Step from a given machine: the transitions of design §6.2.
func TestStep(t *testing.T) {
	idleShell := func(act int) probe.Result { return probe.Result{ActivityAt: sec(act), FgCommand: "bash"} }
	job := func(act int) probe.Result {
		return probe.Result{ActivityAt: sec(act), FgRunning: true, FgCommand: "apt"}
	}
	htop := func(act int) probe.Result {
		return probe.Result{ActivityAt: sec(act), FgRunning: true, FgCommand: "htop", AltScreen: true}
	}
	warnIdle := Machine{State: WarningIdle, Created: t0, LastActivity: sec(0), CloseAt: sec(60)}
	waiting := Machine{State: WaitingForJob, Created: t0, LastActivity: sec(0)}
	warnHard := Machine{State: WarningHard, Created: t0, LastActivity: sec(500), CloseAt: sec(600)}
	noFinish := pol
	noFinish.FinishWork = false
	off := Policy{WarnLead: 10 * time.Second}

	tests := []struct {
		name      string
		m         Machine
		p         Policy
		o         probe.Result
		now       time.Time
		wantState State
		wantEv    []string
		wantClose time.Time
	}{
		{"fresh, before warn time", New(t0), pol, idleShell(0), sec(49), Active, nil, time.Time{}},
		{"idle shell reaches deadline-lead", New(t0), pol, idleShell(0), sec(50), WarningIdle,
			[]string{"state:warning_idle", "expiring:idle"}, sec(60)},
		{"output keeps it active", New(t0), pol, idleShell(45), sec(59), Active, nil, time.Time{}},
		{"silent job + finish work waits", New(t0), pol, job(0), sec(50), WaitingForJob,
			[]string{"state:waiting_for_job"}, time.Time{}},
		{"silent job, finish work off: warns", New(t0), noFinish, job(0), sec(50), WarningIdle,
			[]string{"state:warning_idle", "expiring:idle"}, sec(60)},
		{"waiting, job still running, silent", waiting, pol, job(0), sec(5000 - 4500), WaitingForJob, nil, time.Time{}},
		{"waiting, job output -> active", waiting, pol, job(70), sec(71), Active, []string{"state:active"}, time.Time{}},
		{"waiting, job ended -> warn lead later even with prompt output", waiting, pol, idleShell(80), sec(81),
			WarningIdle, []string{"state:warning_idle", "expiring:idle"}, sec(91)},
		{"warning idle, input -> active", warnIdle, pol, idleShell(55), sec(56), Active, []string{"state:active"},
			time.Time{}},
		{"warning idle, still quiet", warnIdle, pol, idleShell(0), sec(59), WarningIdle, nil, sec(60)},
		{"warning idle, close time -> closed", warnIdle, pol, idleShell(0), sec(60), Closed,
			[]string{"closed:idle"}, sec(60)},
		{"htop is never idle", New(t0), pol, htop(299), sec(300), Active, nil, time.Time{}},
		{"hard warning lead before hard", New(t0), pol, htop(589), sec(590), WarningHard,
			[]string{"state:warning_hard", "expiring:hard"}, sec(600)},
		{"hard warning from waiting", Machine{State: WaitingForJob, Created: t0, LastActivity: sec(100)}, pol,
			job(100), sec(595), WarningHard, []string{"state:warning_hard", "expiring:hard"}, sec(605)},
		{"warning hard ignores activity", warnHard, pol, htop(599), sec(599), WarningHard, nil, sec(600)},
		{"warning hard closes even when busy", warnHard, pol, htop(600), sec(600), Closed,
			[]string{"closed:hard"}, sec(600)},
		{"restart past hard deadline still warns first", Machine{State: Active, Created: t0, LastActivity: sec(0)},
			pol, htop(900), sec(900), WarningHard, []string{"state:warning_hard", "expiring:hard"}, sec(910)},
		{"restart past idle deadline still warns first", New(t0), pol, idleShell(0), sec(300), WarningIdle,
			[]string{"state:warning_idle", "expiring:idle"}, sec(310)},
		{"timeouts off: nothing ever", New(t0), off, idleShell(0), sec(1 << 20), Active, nil, time.Time{}},
		{"closed stays closed", Machine{State: Closed}, pol, idleShell(9), sec(9), Closed, nil, time.Time{}},
		{"extended idle holds", Machine{State: Active, Created: t0, IdleUntil: sec(200)}, pol, idleShell(0),
			sec(150), Active, nil, time.Time{}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, evs := Step(tc.m, tc.p, tc.o, tc.now)
			if got.State != tc.wantState {
				t.Fatalf("state %s, want %s", got.State, tc.wantState)
			}
			if k := kinds(evs); !reflect.DeepEqual(k, tc.wantEv) {
				t.Fatalf("events %v, want %v", k, tc.wantEv)
			}
			if !got.CloseAt.Equal(tc.wantClose) {
				t.Fatalf("close at %v, want %v", got.CloseAt, tc.wantClose)
			}
		})
	}
}

func TestStepDoesNotMutateInput(t *testing.T) {
	m := New(t0)
	before := m
	_, _ = Step(m, pol, probe.Result{ActivityAt: sec(30)}, sec(55))
	if m != before {
		t.Fatal("Step changed its input")
	}
}

func TestExpiringEventCarriesCloseTimeAndCommand(t *testing.T) {
	_, evs := Step(Machine{State: WaitingForJob, Created: t0}, pol, probe.Result{FgCommand: "bash"}, sec(70))
	e := evs[1]
	if e.Kind != EvExpiring || e.Reason != ReasonIdle || !e.At.Equal(sec(80)) || e.FgCommand != "bash" {
		t.Fatalf("event %+v", e)
	}
}

// A whole run: create -> idle -> finish work waits for the job -> job ends -> warning -> closed.
func TestScenarioFinishWork(t *testing.T) {
	m := New(t0)
	var all []string
	feed := func(o probe.Result, now time.Time) {
		var evs []Event
		m, evs = Step(m, pol, o, now)
		all = append(all, kinds(evs)...)
	}
	feed(probe.Result{ActivityAt: sec(1), FgRunning: true, FgCommand: "sleep"}, sec(5)) // job started
	feed(probe.Result{ActivityAt: sec(1), FgRunning: true, FgCommand: "sleep"}, sec(55))
	feed(probe.Result{ActivityAt: sec(1), FgRunning: true, FgCommand: "sleep"}, sec(200))
	feed(probe.Result{ActivityAt: sec(201), FgCommand: "bash"}, sec(202)) // job ended, prompt drawn
	feed(probe.Result{ActivityAt: sec(201), FgCommand: "bash"}, sec(211))
	feed(probe.Result{ActivityAt: sec(201), FgCommand: "bash"}, sec(212))
	want := []string{"state:waiting_for_job", "state:warning_idle", "expiring:idle", "closed:idle"}
	if !reflect.DeepEqual(all, want) || m.State != Closed {
		t.Fatalf("events %v state %s", all, m.State)
	}
}

func TestExtend(t *testing.T) {
	warnIdle := Machine{State: WarningIdle, Created: t0, LastActivity: sec(0), CloseAt: sec(60)}
	warnHard := Machine{State: WarningHard, Created: t0, LastActivity: sec(0), CloseAt: sec(600)}
	h, d := time.Hour, 24*time.Hour
	tests := []struct {
		name      string
		m         Machine
		w         Which
		wantState State
		wantEv    []string
		idle      time.Time
		hard      time.Time
	}{
		{"idle warning + extend idle", warnIdle, ExtendIdle, Active, []string{"state:active"}, sec(60).Add(h),
			sec(600)},
		{"idle warning + extend hard keeps warning", warnIdle, ExtendHard, WarningIdle, nil, sec(60),
			sec(600).Add(d)},
		{"hard warning + extend hard", warnHard, ExtendHard, Active, []string{"state:active"}, sec(60),
			sec(600).Add(d)},
		{"hard warning + extend idle keeps warning", warnHard, ExtendIdle, WarningHard, nil, sec(60).Add(h),
			sec(600)},
		{"both", warnHard, ExtendBoth, Active, []string{"state:active"}, sec(60).Add(h), sec(600).Add(d)},
		{"waiting + extend idle", Machine{State: WaitingForJob, Created: t0, LastActivity: t0}, ExtendIdle, Active,
			[]string{"state:active"}, sec(60).Add(h), sec(600)},
		{"closed ignores", Machine{State: Closed, Created: t0, LastActivity: t0}, ExtendBoth, Closed, nil, sec(60), sec(600)},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, evs := Extend(tc.m, pol, tc.w, h, d, sec(55))
			if got.State != tc.wantState || !reflect.DeepEqual(kinds(evs), tc.wantEv) {
				t.Fatalf("state %s events %v", got.State, kinds(evs))
			}
			idle, hard := got.Deadlines(pol)
			if !idle.Equal(tc.idle) || !hard.Equal(tc.hard) {
				t.Fatalf("deadlines idle %v hard %v, want %v %v", idle, hard, tc.idle, tc.hard)
			}
		})
	}
	if !ExtendIdle.Valid() || !ExtendBoth.Valid() || Which("x").Valid() {
		t.Fatal("Valid")
	}
}

func TestResetAndClose(t *testing.T) {
	m, evs := Reset(Machine{State: WarningIdle, CloseAt: sec(5)})
	if m.State != Active || !m.CloseAt.IsZero() || len(evs) != 1 {
		t.Fatalf("reset %+v %v", m, evs)
	}
	if _, evs := Reset(New(t0)); evs != nil {
		t.Fatal("active reset must be silent")
	}
	if _, evs := Reset(Machine{State: Closed}); evs != nil {
		t.Fatal("closed reset must be silent")
	}
	if CloseRequested(New(t0)).State != Closed {
		t.Fatal("CloseRequested")
	}
}

func TestDeadlinesOff(t *testing.T) {
	idle, hard := New(t0).Deadlines(Policy{})
	if !idle.IsZero() || !hard.IsZero() {
		t.Fatal("disabled timeouts must have no deadlines")
	}
}

func TestMetaRoundTrip(t *testing.T) {
	p := Policy{Idle: 2 * time.Second, Hard: 30 * time.Second, WarnLead: time.Second, FinishWork: false}
	m := Machine{State: WarningHard, Created: sec(1), LastActivity: sec(7), IdleUntil: sec(9),
		HardExtra: time.Hour, CloseAt: sec(31)}
	gm, gp := FromMeta(ToMeta(m, p), pol, t0)
	if !gm.Created.Equal(m.Created) || !gm.LastActivity.Equal(m.LastActivity) || !gm.IdleUntil.Equal(m.IdleUntil) ||
		!gm.CloseAt.Equal(m.CloseAt) || gm.State != m.State || gm.HardExtra != m.HardExtra || gp != p {
		t.Fatalf("round trip: %+v %+v", gm, gp)
	}
	for _, k := range MetaKeys {
		if _, ok := ToMeta(m, p)[k]; !ok {
			t.Fatalf("key %s missing", k)
		}
	}
}

func TestFromMetaDefaults(t *testing.T) {
	m, p := FromMeta(map[string]string{KeyIdle: "x", KeyState: "warning_idle"}, pol, t0)
	if p != pol || m.State != Active || !m.Created.Equal(t0) || !m.LastActivity.Equal(t0) {
		t.Fatalf("defaults: %+v %+v", m, p)
	}
	m, _ = FromMeta(map[string]string{KeyState: "waiting_for_job"}, pol, t0)
	if m.State != WaitingForJob {
		t.Fatalf("waiting kept: %s", m.State)
	}
}
