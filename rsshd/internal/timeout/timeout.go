// Package timeout is the per-session timeout state machine of design §6.2 and PROTOCOL.md. It is pure: the
// watcher feeds it observations and the clock, and acts on the events it returns.
package timeout

import (
	"time"

	"github.com/radut/rsshterm/rsshd/internal/probe"
)

// State is a session's timeout state.
type State string

// States, as named in the protocol.
const (
	Active        State = "active"
	WaitingForJob State = "waiting_for_job"
	WarningIdle   State = "warning_idle"
	WarningHard   State = "warning_hard"
	Closed        State = "closed"
)

// Reasons carried by expiring and closed events.
const (
	ReasonIdle = "idle"
	ReasonHard = "hard"
)

// Policy is a session's timeout settings. Idle or Hard of 0 disables that timeout.
type Policy struct {
	Idle       time.Duration
	Hard       time.Duration
	WarnLead   time.Duration
	FinishWork bool
}

// Machine is one session's timeout state. It is a value: every operation returns a new one.
type Machine struct {
	State        State
	Created      time.Time
	LastActivity time.Time     // newest output or input seen
	IdleUntil    time.Time     // set by extend; the idle deadline is never earlier than this
	HardExtra    time.Duration // sum of hard extensions
	CloseAt      time.Time     // close time while in a warning state
}

// EventKind names an event of the protocol.
type EventKind string

// Event kinds.
const (
	EvState    EventKind = "state"
	EvExpiring EventKind = "expiring"
	EvClosed   EventKind = "closed"
)

// Event is something the client must hear about. The watcher adds the session id.
type Event struct {
	Kind      EventKind
	State     State     // EvState
	Reason    string    // EvExpiring, EvClosed
	At        time.Time // EvExpiring: when the session closes
	FgCommand string    // EvExpiring
}

// New returns the machine of a session created at t.
func New(created time.Time) Machine {
	return Machine{State: Active, Created: created, LastActivity: created}
}

// IdleDeadline is when an idle session closes; ok is false when the idle timeout is off.
func (m Machine) IdleDeadline(p Policy) (time.Time, bool) {
	if p.Idle <= 0 {
		return time.Time{}, false
	}
	d := m.LastActivity.Add(p.Idle)
	if m.IdleUntil.After(d) {
		d = m.IdleUntil
	}
	return d, true
}

// HardDeadline is when the session closes whatever it does; ok is false when the hard timeout is off.
func (m Machine) HardDeadline(p Policy) (time.Time, bool) {
	if p.Hard <= 0 {
		return time.Time{}, false
	}
	return m.Created.Add(p.Hard + m.HardExtra), true
}

// Deadlines reports the close times for the protocol: in a warning state the idle (or hard) deadline is the
// pending close time.
func (m Machine) Deadlines(p Policy) (idle, hard time.Time) {
	idle, _ = m.IdleDeadline(p)
	hard, _ = m.HardDeadline(p)
	switch m.State {
	case WarningIdle:
		idle = m.CloseAt
	case WarningHard:
		hard = m.CloseAt
	}
	return idle, hard
}

// Step advances the machine to now given what the probe saw.
func Step(m Machine, p Policy, o probe.Result, now time.Time) (Machine, []Event) {
	if m.State == Closed {
		return m, nil
	}
	newActivity := o.ActivityAt.After(m.LastActivity)
	if newActivity {
		m.LastActivity = o.ActivityAt
	}

	// The hard timeout wins over everything and ignores activity: it is the only way a busy session ends.
	if m.State == WarningHard {
		if !now.Before(m.CloseAt) {
			return closeNow(m, ReasonHard)
		}
		return m, nil
	}
	if hard, ok := m.HardDeadline(p); ok && !now.Before(hard.Add(-p.WarnLead)) {
		return warn(m, WarningHard, ReasonHard, later(hard, now.Add(p.WarnLead)), o.FgCommand)
	}

	switch m.State {
	case WarningIdle:
		if newActivity {
			return to(m, Active)
		}
		if !now.Before(m.CloseAt) {
			return closeNow(m, ReasonIdle)
		}
		return m, nil
	case WaitingForJob:
		// Job end first: the prompt the finished job leaves behind is not new activity.
		if !o.FgRunning {
			return warn(m, WarningIdle, ReasonIdle, now.Add(p.WarnLead), o.FgCommand)
		}
		if newActivity {
			return to(m, Active)
		}
		return m, nil
	}

	// Active.
	idle, ok := m.IdleDeadline(p)
	if !ok || now.Before(idle.Add(-p.WarnLead)) {
		return m, nil
	}
	if p.FinishWork && o.FgRunning {
		return to(m, WaitingForJob)
	}
	return warn(m, WarningIdle, ReasonIdle, later(idle, now.Add(p.WarnLead)), o.FgCommand)
}

// Which selects the timeout(s) Extend moves.
type Which string

// Extend targets.
const (
	ExtendIdle Which = "idle"
	ExtendHard Which = "hard"
	ExtendBoth Which = "both"
)

// Valid reports whether w is a known target.
func (w Which) Valid() bool { return w == ExtendIdle || w == ExtendHard || w == ExtendBoth }

// Extend moves the idle deadline to at least now+idleBy and/or the hard deadline by hardBy. A warning for the
// extended timeout is withdrawn (state active); a warning for the other one stays.
func Extend(m Machine, p Policy, w Which, idleBy, hardBy time.Duration, now time.Time) (Machine, []Event) {
	if m.State == Closed {
		return m, nil
	}
	idleToo := w == ExtendIdle || w == ExtendBoth
	hardToo := w == ExtendHard || w == ExtendBoth
	if idleToo {
		base := now
		if d, ok := m.IdleDeadline(p); ok && d.After(base) {
			base = d
		}
		m.IdleUntil = base.Add(idleBy)
	}
	if hardToo {
		m.HardExtra += hardBy
	}
	switch {
	case m.State == WarningIdle && idleToo, m.State == WarningHard && hardToo:
		return to(m, Active)
	case m.State == WaitingForJob && idleToo:
		return to(m, Active)
	}
	return m, nil
}

// Reset is applied after the policy changed: deadlines are recomputed from the stored times on the next Step,
// and any pending warning is withdrawn.
func Reset(m Machine) (Machine, []Event) {
	if m.State == Closed || m.State == Active {
		return m, nil
	}
	return to(m, Active)
}

// CloseRequested marks the machine closed by the client.
func CloseRequested(m Machine) Machine {
	m.State = Closed
	m.CloseAt = time.Time{}
	return m
}

func to(m Machine, s State) (Machine, []Event) {
	m.State = s
	m.CloseAt = time.Time{}
	return m, []Event{{Kind: EvState, State: s}}
}

func warn(m Machine, s State, reason string, at time.Time, fg string) (Machine, []Event) {
	m.State = s
	m.CloseAt = at
	return m, []Event{{Kind: EvState, State: s}, {Kind: EvExpiring, Reason: reason, At: at, FgCommand: fg}}
}

func closeNow(m Machine, reason string) (Machine, []Event) {
	m.State = Closed
	return m, []Event{{Kind: EvClosed, Reason: reason}}
}

func later(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}
