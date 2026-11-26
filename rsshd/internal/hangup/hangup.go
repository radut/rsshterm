// Package hangup ends the processes of a multiplexer window the way a closing terminal would.
package hangup

import (
	"context"
	"syscall"

	"github.com/radut/rsshterm/rsshd/internal/probe"
)

// Shells sends SIGHUP to each shell's foreground process group, to the shell's own group and to the shell,
// then SIGCONT so a stopped job sees the hangup. The daemon's own process group is never signalled.
func Shells(pids []int) {
	own := syscall.Getpgrp()
	for _, pid := range pids {
		if tpgid, err := probe.ForegroundPgrp(context.Background(), pid); err == nil && tpgid > 1 && tpgid != own {
			_ = syscall.Kill(-tpgid, syscall.SIGHUP)
		}
		if pgid, err := syscall.Getpgid(pid); err == nil && pgid > 1 && pgid != own {
			_ = syscall.Kill(-pgid, syscall.SIGHUP)
		}
		_ = syscall.Kill(pid, syscall.SIGHUP)
		_ = syscall.Kill(pid, syscall.SIGCONT)
	}
}
