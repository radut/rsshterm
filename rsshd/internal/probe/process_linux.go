package probe

import (
	"context"
	"fmt"
	"os"
	"strconv"
)

// ReadProcess reads /proc/<pid>/cmdline and the /proc/<pid>/cwd link.
func ReadProcess(_ context.Context, pid int) (Process, error) {
	base := "/proc/" + strconv.Itoa(pid)
	b, err := os.ReadFile(base + "/cmdline")
	if err != nil {
		return Process{}, fmt.Errorf("read cmdline of %d: %w", pid, err)
	}
	cwd, _ := os.Readlink(base + "/cwd") // another user's process: no folder, still the command
	return Process{Argv: ParseCmdline(b), Cwd: cwd}, nil
}
