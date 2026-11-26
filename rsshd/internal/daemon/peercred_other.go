//go:build !linux && !darwin

package daemon

import (
	"errors"
	"net"
)

// PeerUID is not implemented here, so every connection is refused.
func PeerUID(*net.UnixConn) (int, error) {
	return -1, errors.New("peer credentials: unsupported OS")
}
