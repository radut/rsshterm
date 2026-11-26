package daemon

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// ErrRunning means another daemon already serves the socket.
var ErrRunning = errors.New("rsshd is already running")

// Listener is the daemon's socket plus the lock that makes it the only daemon of this user.
type Listener struct {
	*net.UnixListener
	lock *os.File
	path string
}

// Close closes the socket, removes it and releases the lock.
func (l *Listener) Close() error {
	err := l.UnixListener.Close()
	_ = l.lock.Close()
	return err
}

// secureDir creates dir 0700 or checks that an existing one belongs to us and is closed to others.
func secureDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("socket dir: %w", err)
	}
	fi, err := os.Lstat(dir)
	if err != nil {
		return fmt.Errorf("socket dir: %w", err)
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	switch {
	case !fi.IsDir():
		return fmt.Errorf("socket dir %s is not a directory", dir)
	case ok && int(st.Uid) != os.Getuid():
		return fmt.Errorf("socket dir %s belongs to uid %d, not to us (%d)", dir, st.Uid, os.Getuid())
	case fi.Mode().Perm()&0o077 != 0:
		if err := os.Chmod(dir, 0o700); err != nil {
			return fmt.Errorf("socket dir %s is open to others (%v): %w", dir, fi.Mode().Perm(), err)
		}
	}
	return nil
}

// Listen takes the per-user lock and listens on path (0600 in a 0700 dir).
func Listen(path string) (*Listener, error) {
	if err := secureDir(filepath.Dir(path)); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("lock: %w", err)
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = lock.Close()
		return nil, ErrRunning
	}
	// We hold the lock, so a leftover socket is stale.
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		_ = lock.Close()
		return nil, fmt.Errorf("remove stale socket: %w", err)
	}
	old := syscall.Umask(0o177)
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	syscall.Umask(old)
	if err != nil {
		_ = lock.Close()
		return nil, fmt.Errorf("listen %s: %w", path, err)
	}
	ln.SetUnlinkOnClose(true)
	return &Listener{UnixListener: ln, lock: lock, path: path}, nil
}

// Dial connects to the daemon socket and checks that the daemon runs as us: on the /tmp fallback path another
// user could have planted a socket.
func Dial(path string, timeout time.Duration) (*net.UnixConn, error) {
	c, err := net.DialTimeout("unix", path, timeout)
	if err != nil {
		return nil, err
	}
	uc := c.(*net.UnixConn)
	if err := checkPeer(uc); err != nil {
		_ = uc.Close()
		return nil, err
	}
	return uc, nil
}

// ErrForeignPeer means the socket is served by another uid.
var ErrForeignPeer = errors.New("rsshd socket is served by another user")

func checkPeer(c *net.UnixConn) error {
	uid, err := PeerUID(c)
	if err != nil {
		return err
	}
	if uid != os.Getuid() {
		return fmt.Errorf("%w (uid %d)", ErrForeignPeer, uid)
	}
	return nil
}
