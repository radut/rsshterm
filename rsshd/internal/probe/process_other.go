//go:build !linux && !darwin

package probe

import (
	"context"
	"errors"
)

// ReadProcess is not available on this OS.
func ReadProcess(context.Context, int) (Process, error) {
	return Process{}, errors.New("read process: unsupported OS")
}
