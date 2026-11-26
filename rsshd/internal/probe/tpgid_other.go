//go:build !linux && !darwin

package probe

import (
	"context"
	"errors"
)

// ForegroundPgrp is not available on this OS.
func ForegroundPgrp(context.Context, int) (int, error) {
	return 0, errors.New("foreground process group: unsupported OS")
}
