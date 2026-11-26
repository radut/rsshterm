package screen

import (
	"context"
	"hash/fnv"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/backend"
)

// Entry is one line of `screen -ls`.
type Entry struct {
	PID      int    // the screen server's pid
	Name     string // session name, e.g. "rssh-0123abcd"
	Attached bool
}

// Target is the exact session spec ("4242.rssh-0123abcd") for -S, -r and -x.
func (e Entry) Target() string { return strconv.Itoa(e.PID) + "." + e.Name }

// ParseLS parses `screen -ls` output. Its lines look like "\t4242.rssh-0123abcd\t(11/25/26 10:00:00)\t(Detached)";
// the date is missing in older versions, so only the first and the last field are read. Dead sessions are
// skipped.
func ParseLS(out string) []Entry {
	var res []Entry
	for _, line := range strings.Split(out, "\n") {
		if !strings.HasPrefix(line, "\t") {
			continue
		}
		f := strings.Split(strings.TrimSpace(line), "\t")
		pidS, name, ok := strings.Cut(f[0], ".")
		pid, err := strconv.Atoi(pidS)
		if !ok || err != nil || pid <= 0 || name == "" {
			continue
		}
		status := strings.ToLower(f[len(f)-1])
		if strings.Contains(status, "dead") {
			continue
		}
		res = append(res, Entry{PID: pid, Name: name,
			Attached: strings.Contains(status, "attached") && !strings.Contains(status, "detached")})
	}
	return res
}

// ls lists the sessions of a socket directory ("" = the user's own). screen exits non-zero when there are
// none (and, in some versions, when there are some), so the output decides; a missing directory or binary
// means no sessions.
func (s *Screen) ls(ctx context.Context, dir string) ([]Entry, error) {
	if _, err := exec.LookPath(s.bin()); err != nil {
		return nil, nil
	}
	if dir != "" {
		if _, err := os.Stat(dir); err != nil {
			return nil, nil
		}
	}
	out, err := s.exec(ctx, dir, "", "-ls")
	if err != nil {
		if se, ok := err.(*Error); ok {
			out += "\n" + se.Msg
			if ctx.Err() != nil {
				return nil, err
			}
		}
	}
	return ParseLS(out), nil
}

// find returns the managed session with this id.
func (s *Screen) find(ctx context.Context, id string) (Entry, error) {
	if err := checkID(id); err != nil {
		return Entry{}, err
	}
	all, err := s.ls(ctx, s.Dir)
	if err != nil {
		return Entry{}, err
	}
	for _, e := range all {
		if e.Name == Prefix+id {
			return e, nil
		}
	}
	return Entry{}, notFound(id)
}

// List implements backend.Backend.
func (s *Screen) List(ctx context.Context) ([]backend.Session, error) {
	entries, err := s.ls(ctx, s.Dir)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	st, serr := loadState(s.State)
	s.mu.Unlock()
	var res []backend.Session
	live := map[string]bool{}
	for _, e := range entries {
		id, ok := strings.CutPrefix(e.Name, Prefix)
		if !ok || !ValidID(id) {
			continue
		}
		live[id] = true
		sess := backend.Session{ID: id, Backend: "screen", Meta: map[string]string{}}
		if e.Attached {
			sess.AttachedClients = 1
		}
		if se := st.Sessions[id]; se != nil {
			sess.Created = se.Created
			for k, v := range se.Meta {
				sess.Meta[k] = v
			}
		}
		shells := children(e.PID)
		job := false
		if len(shells) > 0 {
			sess.PanePID = shells[0]
			sess.PaneCommand, job = foreground(ctx, shells[0])
		}
		sess.ActivityAt = s.activity(ctx, id, e, shells, job)
		res = append(res, sess)
	}
	s.forget(live)
	if serr == nil {
		s.prune(live)
	}
	return res, nil
}

// foreground is the name of the foreground process of the shell's tty (the shell's own name when none runs)
// and whether that is a job rather than the shell.
func foreground(ctx context.Context, shell int) (string, bool) {
	if tpgid, err := foregroundPgrp(ctx, shell); err == nil && tpgid > 0 && tpgid != shell {
		if c := comm(tpgid); c != "" {
			return c, true
		}
	}
	return comm(shell), false
}

// settlePolls is how many polls after a foreground job ends absorb the prompt it leaves behind.
const settlePolls = 2

// seen is what the previous polls observed of a session.
type seen struct {
	hash     uint64    // the visible screen content
	changed  time.Time // when the content last changed; zero until a change was seen
	job      bool      // a foreground job ran
	settle   int       // polls left that absorb the prompt of a job that just ended
	ttyFloor time.Time // tty times up to this are that prompt, not activity
}

// activity is the newest output or input: the window ttys' times (input and output, coarse: the kernel updates
// them every few seconds) and the time the visible screen content last changed between two polls (output, at
// poll resolution). Screen reports neither itself.
//
// The prompt a finished job leaves is not activity (PROTOCOL.md): tmux stamps it with the job's end, so the
// timeout machine sees both in one poll. Here the prompt may only show a poll later, so the content change
// and the tty write of the polls right after a job ended are absorbed.
func (s *Screen) activity(ctx context.Context, id string, e Entry, shells []int, job bool) time.Time {
	var tty time.Time
	for _, pid := range shells {
		if p := ttyOf(pid); p != "" {
			if t := ttyTimes(p); t.After(tty) {
				tty = t
			}
		}
	}
	var cur seen
	v, known := s.act.Load(id)
	if known {
		cur = v.(seen)
	}
	if known && cur.job && !job {
		cur.settle = settlePolls
	}
	cur.job = job
	data, err := s.hardcopy(ctx, e, false)
	if err == nil {
		h := fnv.New64a()
		_, _ = h.Write([]byte(data))
		changed := known && cur.hash != h.Sum64()
		cur.hash = h.Sum64()
		if changed && cur.settle == 0 {
			cur.changed = s.clock()
		}
	}
	if cur.settle > 0 {
		cur.settle--
		if tty.After(cur.ttyFloor) {
			cur.ttyFloor = tty
		}
	}
	s.act.Store(id, cur)
	at := cur.changed
	if tty.After(cur.ttyFloor) && tty.After(at) {
		at = tty
	}
	return at
}

// forget drops the content hashes of sessions that are gone.
func (s *Screen) forget(live map[string]bool) {
	s.act.Range(func(k, _ any) bool {
		if !live[k.(string)] {
			s.act.Delete(k)
		}
		return true
	})
}

// pruneAfter keeps a state entry this long without a listed session, so a session being created (state is
// written first) is not pruned by a concurrent List.
const pruneAfter = time.Minute

// prune removes state entries of sessions that ended.
func (s *Screen) prune(live map[string]bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, err := loadState(s.State)
	if err != nil {
		return
	}
	changed := false
	for id, e := range st.Sessions {
		if !live[id] && s.clock().Sub(e.Created) > pruneAfter {
			delete(st.Sessions, id)
			changed = true
		}
	}
	if changed {
		_ = saveState(s.State, st)
	}
}

// Foreign implements backend.Backend: the user's own screen sessions (their SCREENDIR, attach-only).
func (s *Screen) Foreign(ctx context.Context) ([]backend.Foreign, error) {
	if s.userDirIsOurs() {
		return nil, nil
	}
	entries, err := s.ls(ctx, "")
	if err != nil {
		return nil, err
	}
	var res []backend.Foreign
	for _, e := range entries {
		f := backend.Foreign{Name: e.Name, Backend: "screen", Attach: []string{"screen", "-x", e.Target()}}
		if e.Attached {
			f.AttachedClients = 1
		}
		res = append(res, f)
	}
	return res, nil
}

// userDirIsOurs reports whether the user's SCREENDIR is rsshd's own directory (then nothing is foreign).
func (s *Screen) userDirIsOurs() bool {
	if v := os.Getenv("SCREENDIR"); v != "" {
		return filepath.Clean(v) == filepath.Clean(s.Dir)
	}
	return false
}
