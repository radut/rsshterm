package probe

import (
	"fmt"
	"strconv"
	"strings"
)

// ParseStatTPGID extracts tpgid from a /proc/<pid>/stat line. The command name (field 2) is in parentheses and
// may itself contain spaces and ')', so the fields are counted from the last ')'.
func ParseStatTPGID(stat string) (int, error) {
	i := strings.LastIndexByte(stat, ')')
	if i < 0 {
		return 0, fmt.Errorf("stat: no command field in %q", stat)
	}
	// After ')': state(3) ppid(4) pgrp(5) session(6) tty_nr(7) tpgid(8).
	f := strings.Fields(stat[i+1:])
	if len(f) < 6 {
		return 0, fmt.Errorf("stat: %d fields after the command, want at least 6", len(f))
	}
	v, err := strconv.Atoi(f[5])
	if err != nil {
		return 0, fmt.Errorf("stat: tpgid %q: %w", f[5], err)
	}
	return v, nil
}

// ParsePSTPGID parses the output of `ps -o tpgid= -p <pid>`.
func ParsePSTPGID(out string) (int, error) {
	s := strings.TrimSpace(out)
	if s == "" {
		return 0, fmt.Errorf("ps: no such process")
	}
	v, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("ps: tpgid %q: %w", s, err)
	}
	return v, nil
}
