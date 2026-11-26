package daemon

import (
	"fmt"
	"net"

	"golang.org/x/sys/unix"
)

// PeerUID returns the uid of the process on the other end of a unix socket (LOCAL_PEERCRED).
func PeerUID(c *net.UnixConn) (int, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return -1, fmt.Errorf("peer credentials: %w", err)
	}
	var cred *unix.Xucred
	var serr error
	if err := raw.Control(func(fd uintptr) {
		cred, serr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	}); err != nil {
		return -1, fmt.Errorf("peer credentials: %w", err)
	}
	if serr != nil {
		return -1, fmt.Errorf("peer credentials: %w", serr)
	}
	return int(cred.Uid), nil
}
