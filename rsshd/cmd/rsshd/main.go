// Command rsshd is the per-user session daemon of rSshTerm: sessions live in tmux (or GNU screen) and survive the app being
// backgrounded or the network dropping. See PROTOCOL.md.
//
//	rsshd serve            run the daemon (systemd user unit, launchd agent, or started by rpc)
//	rsshd rpc              JSON lines on stdin/stdout for the app's exec channel; starts the daemon if needed
//	rsshd attach <id>      exec tmux attach (or screen -x) for the app's PTY channel
//	rsshd doctor [--json]  what is missing on this host (exit 1 when a required piece is missing)
//	rsshd version
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/radut/rsshterm/rsshd/internal/backend"
	"github.com/radut/rsshterm/rsshd/internal/config"
	"github.com/radut/rsshterm/rsshd/internal/daemon"
	"github.com/radut/rsshterm/rsshd/internal/doctor"
)

// version is set at build time: -ldflags "-X main.version=1.2.3".
var version = "dev"

const usage = `usage: rsshd <command>
  serve            run the daemon
  rpc              JSON lines on stdin/stdout (the app's control channel)
  attach <id>      attach this terminal to a session
  doctor [--json]  check what is missing on this host
  version          print the version
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	switch args[0] {
	case "version", "--version", "-v":
		fmt.Fprintln(stdout, "rsshd", version)
		return 0
	case "help", "--help", "-h":
		fmt.Fprint(stdout, usage)
		return 0
	}
	cfg, err := config.Load(config.FromOS())
	if err != nil {
		fmt.Fprintln(stderr, "rsshd:", err)
		return 2
	}
	switch args[0] {
	case "serve":
		return serve(cfg, stderr)
	case "rpc":
		return rpcBridge(cfg, stdin, stdout, stderr)
	case "attach":
		if len(args) != 2 {
			fmt.Fprintln(stderr, "usage: rsshd attach <id>")
			return 2
		}
		return attach(cfg, args[1], stderr)
	case "doctor":
		return doctorCmd(cfg, len(args) > 1 && args[1] == "--json", stdout, stderr)
	default:
		fmt.Fprintf(stderr, "rsshd: unknown command %q\n%s", args[0], usage)
		return 2
	}
}

func serve(cfg config.Config, stderr io.Writer) int {
	log := slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := daemon.Serve(ctx, cfg, version, log); err != nil {
		if errors.Is(err, daemon.ErrRunning) {
			log.Info("another rsshd already serves this user", "socket", cfg.Socket)
			return 0
		}
		log.Error("serve", "err", err)
		return 1
	}
	return 0
}

func rpcBridge(cfg config.Config, stdin io.Reader, stdout, stderr io.Writer) int {
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintln(stderr, "rsshd:", err)
		return 1
	}
	conn, err := daemon.Connect(cfg.Socket, func() error { return daemon.StartDetached(exe, nil) }, 5*time.Second)
	if err != nil {
		fmt.Fprintln(stderr, "rsshd:", err)
		return 1
	}
	if err := daemon.Bridge(conn, stdin, stdout); err != nil {
		fmt.Fprintln(stderr, "rsshd:", err)
		return 1
	}
	return 0
}

func attach(cfg config.Config, id string, stderr io.Writer) int {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	be, _, err := daemon.NewBackend(cfg)
	if err != nil {
		fmt.Fprintln(stderr, "rsshd:", err)
		return 1
	}
	argv, err := be.Attach(ctx, id)
	if err != nil {
		if errors.Is(err, backend.ErrNotFound) {
			fmt.Fprintf(stderr, "rsshd: no session %q\n", id)
		} else {
			fmt.Fprintln(stderr, "rsshd:", err)
		}
		return 1
	}
	bin := argv[0]
	if !strings.Contains(bin, "/") {
		if bin, err = exec.LookPath(bin); err != nil {
			fmt.Fprintln(stderr, "rsshd:", err)
			return 1
		}
	}
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "TMUX=") && !strings.HasPrefix(kv, "TMUX_PANE=") && !strings.HasPrefix(kv, "STY=") &&
			!strings.HasPrefix(kv, "WINDOW=") {
			env = append(env, kv)
		}
	}
	err = syscall.Exec(bin, argv, env)
	fmt.Fprintln(stderr, "rsshd: exec", argv[0]+":", err)
	return 1
}

func doctorCmd(cfg config.Config, asJSON bool, stdout, stderr io.Writer) int {
	r := doctor.Run(context.Background(), doctor.Local(cfg.Socket), false)
	if asJSON {
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(map[string]any{"version": version, "healthy": r.Healthy(), "missing": r.Missing(false),
			"report": r}); err != nil {
			fmt.Fprintln(stderr, "rsshd:", err)
			return 1
		}
	} else if err := doctor.Print(stdout, r); err != nil {
		fmt.Fprintln(stderr, "rsshd:", err)
		return 1
	}
	if !r.Healthy() {
		return 1
	}
	return 0
}
