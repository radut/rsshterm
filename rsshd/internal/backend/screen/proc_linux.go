package screen

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/probe"
)

// children returns the direct children of pid, lowest first: the screen server's window processes (shells).
func children(pid int) []int {
	p := strconv.Itoa(pid)
	var out []int
	if b, err := os.ReadFile("/proc/" + p + "/task/" + p + "/children"); err == nil {
		for _, f := range strings.Fields(string(b)) {
			if v, err := strconv.Atoi(f); err == nil {
				out = append(out, v)
			}
		}
	} else {
		out = scanChildren(pid)
	}
	sort.Ints(out)
	return out
}

// scanChildren is the fallback for kernels without /proc/<pid>/task/<pid>/children.
func scanChildren(pid int) []int {
	dirs, _ := filepath.Glob("/proc/[0-9]*/stat")
	var out []int
	for _, d := range dirs {
		b, err := os.ReadFile(d)
		if err != nil {
			continue
		}
		if ppid, ok := parsePPID(string(b)); ok && ppid == pid {
			if v, err := strconv.Atoi(filepath.Base(filepath.Dir(d))); err == nil {
				out = append(out, v)
			}
		}
	}
	return out
}

// parsePPID reads field 4 of a /proc/<pid>/stat line (counted from the last ')', as probe does).
func parsePPID(stat string) (int, bool) {
	i := strings.LastIndexByte(stat, ')')
	if i < 0 {
		return 0, false
	}
	f := strings.Fields(stat[i+1:])
	if len(f) < 2 {
		return 0, false
	}
	v, err := strconv.Atoi(f[1])
	return v, err == nil
}

// comm is the process name ("htop"), "" when the process is gone.
func comm(pid int) string {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/comm")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// ttyOf is the terminal device of pid's stdin/stdout/stderr ("/dev/pts/3"), "" when none.
func ttyOf(pid int) string {
	for _, fd := range []string{"0", "1", "2"} {
		if l, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/fd/" + fd); err == nil && strings.HasPrefix(l, "/dev/") {
			return l
		}
	}
	return ""
}

// ttyTimes is the newest of the tty's access (input read) and modification (output written) times. The kernel
// updates them with a few seconds' granularity, like `w` shows idle time.
func ttyTimes(path string) time.Time {
	fi, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	t := fi.ModTime()
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		if a := time.Unix(st.Atim.Sec, st.Atim.Nsec); a.After(t) {
			t = a
		}
	}
	return t
}

var foregroundPgrp = probe.ForegroundPgrp
