package timeout

import (
	"strconv"
	"time"
)

// Meta keys (stored by the backend as tmux user options "@rssh_<key>"), so a daemon restart resumes the machine.
const (
	KeyIdle      = "idle_s"
	KeyHard      = "hard_s"
	KeyFinish    = "finish_work"
	KeyLead      = "warn_lead_s"
	KeyState     = "state"
	KeyCreated   = "created_ms"
	KeyLast      = "last_ms"
	KeyIdleUntil = "idle_until_ms"
	KeyHardExtra = "hard_extra_s"
	KeyCloseAt   = "close_at_ms"
)

// MetaKeys lists every key ToMeta writes.
var MetaKeys = []string{KeyIdle, KeyHard, KeyFinish, KeyLead, KeyState, KeyCreated, KeyLast, KeyIdleUntil,
	KeyHardExtra, KeyCloseAt}

// ToMeta encodes a machine and its policy as string metadata.
func ToMeta(m Machine, p Policy) map[string]string {
	return map[string]string{
		KeyIdle:      strconv.FormatInt(int64(p.Idle/time.Second), 10),
		KeyHard:      strconv.FormatInt(int64(p.Hard/time.Second), 10),
		KeyFinish:    strconv.FormatBool(p.FinishWork),
		KeyLead:      strconv.FormatInt(int64(p.WarnLead/time.Second), 10),
		KeyState:     string(m.State),
		KeyCreated:   ms(m.Created),
		KeyLast:      ms(m.LastActivity),
		KeyIdleUntil: ms(m.IdleUntil),
		KeyHardExtra: strconv.FormatInt(int64(m.HardExtra/time.Second), 10),
		KeyCloseAt:   ms(m.CloseAt),
	}
}

// FromMeta decodes what ToMeta wrote. Missing or malformed keys fall back to def (policy) and created (times),
// so a session created by an older daemon, or by hand, still gets the default timeouts.
func FromMeta(meta map[string]string, def Policy, created time.Time) (Machine, Policy) {
	p := Policy{
		Idle:       secs(meta[KeyIdle], def.Idle),
		Hard:       secs(meta[KeyHard], def.Hard),
		WarnLead:   secs(meta[KeyLead], def.WarnLead),
		FinishWork: def.FinishWork,
	}
	if b, err := strconv.ParseBool(meta[KeyFinish]); err == nil {
		p.FinishWork = b
	}
	m := New(at(meta[KeyCreated], created))
	m.LastActivity = at(meta[KeyLast], m.Created)
	m.IdleUntil = at(meta[KeyIdleUntil], time.Time{})
	m.HardExtra = secs(meta[KeyHardExtra], 0)
	switch s := State(meta[KeyState]); s {
	case WaitingForJob, WarningIdle, WarningHard:
		m.State = s
		m.CloseAt = at(meta[KeyCloseAt], time.Time{})
		if s != WaitingForJob && m.CloseAt.IsZero() {
			m.State = Active // a warning without its close time: start over, it warns again
		}
	}
	return m, p
}

func ms(t time.Time) string {
	if t.IsZero() {
		return "0"
	}
	return strconv.FormatInt(t.UnixMilli(), 10)
}

func at(s string, def time.Time) time.Time {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v <= 0 {
		return def
	}
	return time.UnixMilli(v)
}

func secs(s string, def time.Duration) time.Duration {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v < 0 {
		return def
	}
	return time.Duration(v) * time.Second
}
