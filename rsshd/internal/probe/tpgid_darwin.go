package probe

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
)

// ForegroundPgrp asks BSD ps for the tpgid keyword (macOS has no /proc).
func ForegroundPgrp(ctx context.Context, pid int) (int, error) {
	out, err := exec.CommandContext(ctx, "ps", "-o", "tpgid=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0, fmt.Errorf("ps tpgid of %d: %w", pid, err)
	}
	return ParsePSTPGID(string(out))
}
