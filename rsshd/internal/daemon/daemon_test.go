package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gitlab.com/radutoader/projects/apple/rSSH/rsshd/internal/config"
)

// Short socket paths: unix socket paths are limited to ~104 bytes and t.TempDir() can be long.
func sockPath(t *testing.T) string {
	d, err := os.MkdirTemp("", "rsshd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return filepath.Join(d, "run", "sock")
}

func TestListenLockAndPerms(t *testing.T) {
	p := sockPath(t)
	ln, err := Listen(p)
	if err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(filepath.Dir(p))
	si, _ := os.Stat(p)
	if fi.Mode().Perm() != 0o700 || si.Mode().Perm() != 0o600 {
		t.Fatalf("dir %v sock %v", fi.Mode().Perm(), si.Mode().Perm())
	}
	if _, err := Listen(p); !errors.Is(err, ErrRunning) {
		t.Fatalf("second daemon: %v", err)
	}
	c, err := Dial(p, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	s, err := ln.AcceptUnix()
	if err != nil {
		t.Fatal(err)
	}
	if uid, err := PeerUID(s); err != nil || uid != os.Getuid() {
		t.Fatalf("peer uid %d %v", uid, err)
	}
	c.Close()
	s.Close()
	ln.Close()
	// Lock released and socket removed: a new daemon can start.
	ln2, err := Listen(p)
	if err != nil {
		t.Fatal(err)
	}
	ln2.Close()
}

func TestSecureDir(t *testing.T) {
	d := filepath.Join(t.TempDir(), "open")
	if err := os.Mkdir(d, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := secureDir(d); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(d); fi.Mode().Perm() != 0o700 {
		t.Fatalf("not tightened: %v", fi.Mode().Perm())
	}
	f := filepath.Join(t.TempDir(), "file")
	_ = os.WriteFile(f, nil, 0o600)
	if err := secureDir(f); err == nil {
		t.Fatal("a file accepted as socket dir")
	}
	if os.Getuid() != 0 {
		if err := secureDir("/"); err == nil {
			t.Fatal("root-owned dir accepted")
		}
	}
}

func TestConnectStartsDaemon(t *testing.T) {
	p := sockPath(t)
	if _, err := Connect(p, nil, time.Second); err == nil {
		t.Fatal("no daemon, no start: must fail")
	}
	if _, err := Connect(p, func() error { return errors.New("cannot exec") }, time.Second); err == nil {
		t.Fatal("start error swallowed")
	}
	if _, err := Connect(p, func() error { return nil }, 200*time.Millisecond); err == nil {
		t.Fatal("daemon never came up: must fail")
	}
	var ln *Listener
	c, err := Connect(p, func() error {
		var err error
		ln, err = Listen(p)
		return err
	}, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	c.Close()
	ln.Close()
	if err := StartDetached("/nonexistent/rsshd", nil); err == nil {
		t.Fatal("start of a missing binary")
	}
}

// The whole daemon on a real socket, spoken to through Bridge like `rsshd rpc` does.
func TestServeAndBridge(t *testing.T) {
	p := sockPath(t)
	c := config.Default(config.Env{Home: t.TempDir(), UID: os.Getuid()})
	c.Socket = p
	c.TmuxSocket = fmt.Sprintf("rsshd-dtest-%d", os.Getpid())
	c.PollInterval = 100 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, c, "9.9.9", slog.New(slog.DiscardHandler)) }()
	conn, err := Connect(p, nil, 0)
	for i := 0; err != nil && i < 50; i++ {
		time.Sleep(50 * time.Millisecond)
		conn, err = Connect(p, nil, 0)
	}
	if err != nil {
		t.Fatal(err)
	}
	in := strings.NewReader(`{"v":1,"id":1,"op":"hello","args":{"client":"test","proto":[1]}}` + "\n" +
		`{"v":1,"id":2,"op":"health"}` + "\n")
	pr, pw := io.Pipe()
	go func() { _ = Bridge(conn, in, pw); pw.Close() }()
	sc := bufio.NewScanner(pr)
	got := map[float64]map[string]any{}
	for sc.Scan() {
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			t.Fatal(err)
		}
		got[m["id"].(float64)] = m
	}
	if got[1]["ok"] != true || got[1]["result"].(map[string]any)["version"] != "9.9.9" {
		t.Fatalf("hello %v", got[1])
	}
	if got[2]["ok"] != true {
		t.Fatalf("health %v", got[2])
	}
	if _, err := Listen(p); !errors.Is(err, ErrRunning) {
		t.Fatalf("second daemon while serving: %v", err)
	}
	if err := Serve(ctx, c, "x", slog.New(slog.DiscardHandler)); !errors.Is(err, ErrRunning) {
		t.Fatalf("second Serve: %v", err)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Serve did not stop")
	}
	if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("socket left behind")
	}
}

func TestHello(t *testing.T) {
	c := config.Default(config.Env{Home: t.TempDir(), UID: os.Getuid()})
	h := Hello(context.Background(), c)
	if h.DefaultBackend != "tmux" || h.Caps.OS == "" || h.Missing == nil {
		t.Fatalf("%+v", h)
	}
}
