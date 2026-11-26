package rpc

import (
	"sort"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/probe"
	"github.com/radut/rsshterm/rsshd/internal/watch"
)

// MetaName is the metadata key of the session's display name.
const MetaName = "name"

// SessionOf converts watcher info into the protocol's Session object.
func SessionOf(i watch.Info) SessionJSON {
	idle, hard := i.Machine.Deadlines(i.Policy)
	last := i.Machine.LastActivity
	if i.Probe.ActivityAt.After(last) {
		last = i.Probe.ActivityAt
	}
	return SessionJSON{
		ID:              i.Session.ID,
		Name:            i.Session.Meta[MetaName],
		Backend:         i.Session.Backend,
		Created:         i.Machine.Created.UTC(),
		LastActivity:    last.UTC(),
		AttachedClients: i.Session.AttachedClients,
		State:           string(i.Machine.State),
		Deadlines:       DeadlinesJSON{Idle: utcPtr(idle), Hard: utcPtr(hard)},
		Timeouts: TimeoutsJSON{IdleS: int64(i.Policy.Idle / time.Second), HardS: int64(i.Policy.Hard / time.Second),
			FinishWork: i.Policy.FinishWork, WarnLeadS: int64(i.Policy.WarnLead / time.Second)},
		FgRunning: i.Probe.FgRunning,
		FgCommand: i.Probe.FgCommand,
		AltScreen: i.Probe.AltScreen,
		Pane:      PaneOf(i.Probe.Pane),
	}
}

// PaneOf converts a probed pane into its protocol object (args never null).
func PaneOf(p probe.Pane) PaneJSON {
	args := p.Args
	if args == nil {
		args = []string{}
	}
	return PaneJSON{Command: p.Command, Args: args, Cwd: p.Cwd}
}

func utcPtr(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	u := t.UTC()
	return &u
}

func sortSessions(s []SessionJSON) {
	sort.Slice(s, func(a, b int) bool {
		if !s[a].Created.Equal(s[b].Created) {
			return s[a].Created.Before(s[b].Created)
		}
		return s[a].ID < s[b].ID
	})
}
