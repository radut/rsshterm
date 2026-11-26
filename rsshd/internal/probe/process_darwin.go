package probe

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// ReadProcess asks ps for the command line (split at spaces: macOS ps cannot show argv boundaries) and lsof for
// the working directory.
func ReadProcess(ctx context.Context, pid int) (Process, error) {
	out, err := exec.CommandContext(ctx, "ps", "-ww", "-o", "args=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return Process{}, fmt.Errorf("ps args of %d: %w", pid, err)
	}
	argv := strings.Fields(string(out))
	if len(argv) == 0 {
		return Process{}, fmt.Errorf("ps args of %d: empty", pid)
	}
	cwdOut, _ := exec.CommandContext(ctx, "lsof", "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn").Output()
	return Process{Argv: argv, Cwd: ParseLsofCwd(string(cwdOut))}, nil
}
