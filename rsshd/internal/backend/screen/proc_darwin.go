package screen

import (
	"context"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/probe"
)

func psOut(args ...string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, _ := exec.CommandContext(ctx, args[0], args[1:]...).Output()
	return string(out)
}

// children returns the direct children of pid, lowest first (pgrep -P).
func children(pid int) []int {
	var out []int
	for _, f := range strings.Fields(psOut("pgrep", "-P", strconv.Itoa(pid))) {
		if v, err := strconv.Atoi(f); err == nil {
			out = append(out, v)
		}
	}
	sort.Ints(out)
	return out
}

// comm is the process name, "" when the process is gone.
func comm(pid int) string {
	c := strings.TrimSpace(psOut("ps", "-o", "comm=", "-p", strconv.Itoa(pid)))
	if i := strings.LastIndexByte(c, '/'); i >= 0 {
		c = c[i+1:]
	}
	return c
}

// ttyOf is the controlling terminal of pid ("/dev/ttys003"), "" when none.
func ttyOf(pid int) string {
	t := strings.TrimSpace(psOut("ps", "-o", "tty=", "-p", strconv.Itoa(pid)))
	if t == "" || t == "??" {
		return ""
	}
	return "/dev/" + t
}

// ttyTimes is the newest of the tty's access and modification times.
func ttyTimes(path string) time.Time {
	fi, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	t := fi.ModTime()
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		if a := time.Unix(st.Atimespec.Sec, st.Atimespec.Nsec); a.After(t) {
			t = a
		}
	}
	return t
}

var foregroundPgrp = probe.ForegroundPgrp
