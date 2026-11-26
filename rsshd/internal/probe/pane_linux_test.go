package probe

import (
	"context"
	"os/exec"
	"reflect"
	"testing"
	"time"
)

// A real child: its argv and folder come from /proc.
func TestReadProcessLinux(t *testing.T) {
	dir := t.TempDir()
	cmd := exec.Command("sleep", "30")
	cmd.Dir = dir
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	// Start returns before the child has exec'd: wait until /proc shows the new program.
	var p Process
	var err error
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if p, err = ReadProcess(context.Background(), cmd.Process.Pid); err == nil && len(p.Argv) > 0 && p.Argv[0] == "sleep" {
			break
		}
	}
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(p.Argv, []string{"sleep", "30"}) {
		t.Fatalf("argv %q", p.Argv)
	}
	if p.Cwd != dir {
		t.Fatalf("cwd %q want %q", p.Cwd, dir)
	}
	if _, err := ReadProcess(context.Background(), 1<<30); err == nil {
		t.Fatal("missing pid must fail")
	}
}
