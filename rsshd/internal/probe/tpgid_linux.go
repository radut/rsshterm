package probe

import (
	"context"
	"fmt"
	"os"
	"strconv"
)

// ForegroundPgrp reads field 8 (tpgid) of /proc/<pid>/stat.
func ForegroundPgrp(_ context.Context, pid int) (int, error) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return 0, fmt.Errorf("read stat of %d: %w", pid, err)
	}
	return ParseStatTPGID(string(b))
}
