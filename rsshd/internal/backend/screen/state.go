package screen

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// GNU screen has no user options, so the metadata tmux keeps in @rssh_* options lives in one small JSON file
// (design §3: $XDG_STATE_HOME/rsshd/…). It is read and rewritten whole, atomically (temp file + rename), 0600.

const stateVersion = 1

type stateEntry struct {
	Created time.Time         `json:"created"`
	Meta    map[string]string `json:"meta"`
}

type stateDoc struct {
	Version  int                    `json:"version"`
	Sessions map[string]*stateEntry `json:"sessions"`
}

// loadState reads the file; a missing file is an empty state.
func loadState(path string) (stateDoc, error) {
	d := stateDoc{Version: stateVersion, Sessions: map[string]*stateEntry{}}
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return d, nil
	}
	if err != nil {
		return d, fmt.Errorf("read screen state: %w", err)
	}
	if err := json.Unmarshal(b, &d); err != nil {
		return stateDoc{Version: stateVersion, Sessions: map[string]*stateEntry{}},
			fmt.Errorf("screen state %s: %w", path, err)
	}
	if d.Sessions == nil {
		d.Sessions = map[string]*stateEntry{}
	}
	for id, e := range d.Sessions {
		if e == nil || !ValidID(id) {
			delete(d.Sessions, id)
		} else if e.Meta == nil {
			e.Meta = map[string]string{}
		}
	}
	return d, nil
}

// saveState writes the file atomically with mode 0600 in a 0700 directory.
func saveState(path string, d stateDoc) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("screen state dir: %w", err)
	}
	b, err := json.Marshal(d)
	if err != nil {
		return fmt.Errorf("encode screen state: %w", err)
	}
	f, err := os.CreateTemp(dir, ".screen-state-*")
	if err != nil {
		return fmt.Errorf("screen state temp file: %w", err)
	}
	tmp := f.Name()
	defer os.Remove(tmp) // after a successful rename this is a no-op
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return fmt.Errorf("chmod screen state: %w", err)
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return fmt.Errorf("write screen state: %w", err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return fmt.Errorf("sync screen state: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close screen state: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("replace screen state: %w", err)
	}
	return nil
}
