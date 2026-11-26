// Package daemon runs rsshd serve (socket, watcher, rpc) and the client side of `rsshd rpc`.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend/multi"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend/screen"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/backend/tmux"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/config"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/doctor"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/probe"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/rpc"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/timeout"
	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/watch"
)

// NewTmux returns the tmux backend the config describes.
func NewTmux(c config.Config) *tmux.Tmux {
	return &tmux.Tmux{Socket: c.TmuxSocket, Conf: c.TmuxConf, MetaKeys: append(append([]string{}, timeout.MetaKeys...), rpc.MetaName)}
}

// NewScreen returns the GNU screen backend the config describes.
func NewScreen(c config.Config) *screen.Screen {
	return &screen.Screen{Dir: c.ScreenDir, RC: c.ScreenRC, State: c.ScreenState}
}

// NewBackend returns every backend of this build behind one router; the config's backend is the default.
func NewBackend(c config.Config) (*multi.Multi, *tmux.Tmux, error) {
	t := NewTmux(c)
	m, err := multi.New(c.Backend, t, NewScreen(c))
	return m, t, err
}

// Serve runs the daemon until ctx ends.
func Serve(ctx context.Context, c config.Config, version string, log *slog.Logger) error {
	ln, err := Listen(c.Socket)
	if err != nil {
		return err
	}
	defer ln.Close()
	be, tm, err := NewBackend(c)
	if err != nil {
		return err
	}
	w := watch.New(watch.Options{Backend: be, Prober: probe.Local{}, Defaults: c.Timeouts, Interval: c.PollInterval,
		CloseGrace: c.CloseGrace, Log: log})
	srv := rpc.NewServer(rpc.Deps{
		Backend: be, Watcher: w, Defaults: c.Timeouts, ExtendIdle: c.ExtendIdle, ExtendHard: c.ExtendHard,
		Version: version, Started: time.Now(), Log: log, ServerPID: tm.ServerPID,
		Hello: func(ctx context.Context) rpc.HelloResult { return Hello(ctx, c) },
	})
	log.Info("rsshd serving", "socket", c.Socket, "backend", c.Backend, "tmux_socket", c.TmuxSocket,
		"screen_dir", c.ScreenDir, "version", version)

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); w.Run(ctx) }()
	go func() { <-ctx.Done(); _ = ln.UnixListener.Close() }()

	uid := os.Getuid()
	for {
		conn, err := ln.AcceptUnix()
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			if errors.Is(err, net.ErrClosed) {
				break
			}
			log.Error("accept", "err", err)
			continue
		}
		peer, err := PeerUID(conn)
		if err != nil || peer != uid {
			log.Warn("refused connection", "peer_uid", peer, "err", err)
			_ = conn.Close()
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer conn.Close()
			cctx, done := context.WithCancel(ctx)
			defer done()
			go func() { <-cctx.Done(); _ = conn.Close() }() // daemon stop unblocks the read
			if err := srv.Serve(cctx, conn, conn); err != nil && ctx.Err() == nil {
				log.Warn("connection ended", "err", err)
			}
		}()
	}
	cancel()
	wg.Wait()
	log.Info("rsshd stopped")
	return nil
}

// Hello builds the capability part of the hello reply from the doctor checks.
func Hello(ctx context.Context, c config.Config) rpc.HelloResult {
	r := doctor.Run(ctx, doctor.Local(c.Socket), true)
	backends := map[string]string{}
	if r.TmuxVersion != "" {
		backends["tmux"] = r.TmuxVersion
	}
	if r.ScreenVersion != "" {
		backends["screen"] = r.ScreenVersion
	}
	return rpc.HelloResult{Backends: backends, DefaultBackend: c.Backend,
		Caps: rpc.Caps{Reptyr: r.Reptyr, SudoReptyr: r.SudoReptyr, PtraceScope: r.PtraceScope, Linger: r.Linger,
			OS: r.OS},
		Missing: r.Missing(false)}
}

// StartDetached launches `<exe> serve` in its own session, detached from this terminal and SSH channel.
func StartDetached(exe string, extraEnv []string) error {
	null, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer null.Close()
	cmd := exec.Command(exe, "serve")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = null, null, null
	cmd.Env = append(os.Environ(), extraEnv...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start daemon: %w", err)
	}
	return cmd.Process.Release()
}

// Connect dials the daemon, starting it with start() when nothing answers.
func Connect(path string, start func() error, wait time.Duration) (*net.UnixConn, error) {
	c, err := Dial(path, time.Second)
	if err == nil {
		return c, nil
	}
	if errors.Is(err, ErrForeignPeer) {
		return nil, err // never start a second daemon next to a planted socket, never talk to it
	}
	if start == nil {
		return nil, fmt.Errorf("no rsshd on %s", path)
	}
	if err := start(); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(wait)
	for {
		c, err := Dial(path, time.Second)
		if err == nil {
			return c, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("rsshd did not come up on %s: %w", path, err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// Bridge copies in -> conn and conn -> out: the body of `rsshd rpc`. It returns when the daemon side ends,
// which happens after the client's EOF (replies in flight are delivered first) or when the daemon goes away.
func Bridge(conn *net.UnixConn, in io.Reader, out io.Writer) error {
	go func() {
		_, _ = io.Copy(conn, in)
		_ = conn.CloseWrite()
	}()
	_, err := io.Copy(out, conn)
	_ = conn.Close()
	if errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}
