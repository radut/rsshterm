// Package config reads ~/.config/rsshd/config.toml. Every key is optional; a missing file means the defaults.
package config

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/BurntSushi/toml"

	"github.com/radut/rsshterm/rsshd/internal/timeout"
)

// Defaults agreed with the owner: idle 1 h, hard 1 day, finish work on, warning 5 min ahead,
// Extend = +1 h idle / +1 day hard.
const (
	DefaultIdle       = time.Hour
	DefaultHard       = 24 * time.Hour
	DefaultWarnLead   = 5 * time.Minute
	DefaultExtendIdle = time.Hour
	DefaultExtendHard = 24 * time.Hour
	DefaultPoll       = 5 * time.Second
	DefaultCloseGrace = 5 * time.Second
	DefaultTmuxSocket = "rsshd"
	DefaultTmuxConf   = "/usr/share/rsshd/tmux.conf"
	DefaultScreenRC   = "/usr/share/rsshd/screenrc"
)

// Backends are the multiplexers this build has; the first is the default.
var Backends = []string{"tmux", "screen"}

// Config is the daemon's settings after defaults and validation.
type Config struct {
	Backend      string        // the default for create without a backend: "tmux" or "screen"
	Socket       string        // unix socket path
	PollInterval time.Duration //
	CloseGrace   time.Duration // SIGHUP -> kill-session
	TmuxSocket   string        // tmux -L name
	TmuxConf     string        // tmux -f file; /dev/null when the file does not exist
	ScreenDir    string        // SCREENDIR of the managed screen sessions; default <socket dir>/screen
	ScreenRC     string        // screen -c file; "" = the built-in one
	ScreenState  string        // screen session metadata (JSON); default $XDG_STATE_HOME/rsshd/screen-sessions.json
	Timeouts     timeout.Policy
	ExtendIdle   time.Duration
	ExtendHard   time.Duration
}

type fileTimeouts struct {
	Idle       *string `toml:"idle"`
	Hard       *string `toml:"hard"`
	WarnLead   *string `toml:"warn_lead"`
	FinishWork *bool   `toml:"finish_work"`
	ExtendIdle *string `toml:"extend_idle"`
	ExtendHard *string `toml:"extend_hard"`
}

type file struct {
	Backend      *string      `toml:"backend"`
	Socket       *string      `toml:"socket"`
	PollInterval *string      `toml:"poll_interval"`
	CloseGrace   *string      `toml:"close_grace"`
	TmuxSocket   *string      `toml:"tmux_socket"`
	TmuxConf     *string      `toml:"tmux_conf"`
	ScreenDir    *string      `toml:"screen_dir"`
	ScreenRC     *string      `toml:"screen_rc"`
	ScreenState  *string      `toml:"screen_state"`
	Timeouts     fileTimeouts `toml:"timeouts"`
}

// Env is the part of the environment the config depends on (injected for tests).
type Env struct {
	Home       string
	ConfigHome string // XDG_CONFIG_HOME
	RuntimeDir string // XDG_RUNTIME_DIR
	StateHome  string // XDG_STATE_HOME
	UID        int
}

// FromOS reads the environment of this process.
func FromOS() Env {
	home, _ := os.UserHomeDir()
	return Env{Home: home, ConfigHome: os.Getenv("XDG_CONFIG_HOME"), RuntimeDir: os.Getenv("XDG_RUNTIME_DIR"),
		StateHome: os.Getenv("XDG_STATE_HOME"), UID: os.Getuid()}
}

// Path is the config file: $XDG_CONFIG_HOME/rsshd/config.toml, else ~/.config/rsshd/config.toml.
func (e Env) Path() string {
	base := e.ConfigHome
	if base == "" {
		base = filepath.Join(e.Home, ".config")
	}
	return filepath.Join(base, "rsshd", "config.toml")
}

// DefaultSocket is $XDG_RUNTIME_DIR/rsshd/sock, else /tmp/rsshd-<uid>/sock.
func (e Env) DefaultSocket() string {
	if e.RuntimeDir != "" {
		return filepath.Join(e.RuntimeDir, "rsshd", "sock")
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("rsshd-%d", e.UID), "sock")
}

// ScreenStatePath is $XDG_STATE_HOME/rsshd/screen-sessions.json, else ~/.local/state/rsshd/….
func (e Env) ScreenStatePath() string {
	base := e.StateHome
	if base == "" {
		base = filepath.Join(e.Home, ".local", "state")
	}
	return filepath.Join(base, "rsshd", "screen-sessions.json")
}

// Default returns the configuration with no file.
func Default(e Env) Config {
	conf := DefaultTmuxConf
	if _, err := os.Stat(conf); err != nil {
		conf = os.DevNull
	}
	rc := DefaultScreenRC
	if _, err := os.Stat(rc); err != nil {
		rc = ""
	}
	return Config{
		Backend: "tmux", Socket: e.DefaultSocket(), PollInterval: DefaultPoll, CloseGrace: DefaultCloseGrace,
		TmuxSocket: DefaultTmuxSocket, TmuxConf: conf, ScreenRC: rc, ScreenState: e.ScreenStatePath(),
		ScreenDir:  filepath.Join(filepath.Dir(e.DefaultSocket()), "screen"),
		Timeouts:   timeout.Policy{Idle: DefaultIdle, Hard: DefaultHard, WarnLead: DefaultWarnLead, FinishWork: true},
		ExtendIdle: DefaultExtendIdle, ExtendHard: DefaultExtendHard,
	}
}

// Load reads the file at e.Path(); a missing file is not an error.
func Load(e Env) (Config, error) {
	b, err := os.ReadFile(e.Path())
	if errors.Is(err, fs.ErrNotExist) {
		return Default(e), nil
	}
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	return Parse(e, string(b))
}

// Parse applies a TOML document on top of the defaults and validates the result.
func Parse(e Env, doc string) (Config, error) {
	var f file
	md, err := toml.Decode(doc, &f)
	if err != nil {
		return Config{}, fmt.Errorf("config %s: %w", e.Path(), err)
	}
	if und := md.Undecoded(); len(und) > 0 {
		return Config{}, fmt.Errorf("config %s: unknown key %q", e.Path(), und[0].String())
	}
	c := Default(e)
	setStr(&c.Backend, f.Backend)
	setStr(&c.Socket, f.Socket)
	if f.Socket != nil { // the screen sockets follow the daemon's socket unless set on their own
		c.ScreenDir = filepath.Join(filepath.Dir(c.Socket), "screen")
	}
	setStr(&c.ScreenDir, f.ScreenDir)
	setStr(&c.ScreenRC, f.ScreenRC)
	setStr(&c.ScreenState, f.ScreenState)
	setStr(&c.TmuxSocket, f.TmuxSocket)
	setStr(&c.TmuxConf, f.TmuxConf)
	if f.Timeouts.FinishWork != nil {
		c.Timeouts.FinishWork = *f.Timeouts.FinishWork
	}
	durs := []struct {
		key string
		in  *string
		out *time.Duration
	}{
		{"poll_interval", f.PollInterval, &c.PollInterval},
		{"close_grace", f.CloseGrace, &c.CloseGrace},
		{"timeouts.idle", f.Timeouts.Idle, &c.Timeouts.Idle},
		{"timeouts.hard", f.Timeouts.Hard, &c.Timeouts.Hard},
		{"timeouts.warn_lead", f.Timeouts.WarnLead, &c.Timeouts.WarnLead},
		{"timeouts.extend_idle", f.Timeouts.ExtendIdle, &c.ExtendIdle},
		{"timeouts.extend_hard", f.Timeouts.ExtendHard, &c.ExtendHard},
	}
	for _, d := range durs {
		if d.in == nil {
			continue
		}
		v, err := time.ParseDuration(*d.in)
		if err != nil || v < 0 {
			return Config{}, fmt.Errorf("config %s: %s = %q: want a duration like \"1h\" or \"90s\"", e.Path(), d.key, *d.in)
		}
		*d.out = v
	}
	return c, c.Validate()
}

// Validate rejects settings the daemon cannot run with.
func (c Config) Validate() error {
	switch {
	case !slices.Contains(Backends, c.Backend):
		return fmt.Errorf("config: backend %q: want \"tmux\" or \"screen\"", c.Backend)
	case c.PollInterval < 100*time.Millisecond:
		return fmt.Errorf("config: poll_interval %s is below 100ms", c.PollInterval)
	case c.Socket == "" || !filepath.IsAbs(c.Socket):
		return fmt.Errorf("config: socket %q must be an absolute path", c.Socket)
	case c.TmuxSocket == "":
		return errors.New("config: tmux_socket must not be empty")
	case !filepath.IsAbs(c.ScreenDir):
		return fmt.Errorf("config: screen_dir %q must be an absolute path", c.ScreenDir)
	case !filepath.IsAbs(c.ScreenState):
		return fmt.Errorf("config: screen_state %q must be an absolute path", c.ScreenState)
	case c.ScreenRC != "" && !filepath.IsAbs(c.ScreenRC):
		return fmt.Errorf("config: screen_rc %q must be an absolute path", c.ScreenRC)
	}
	return nil
}

func setStr(dst *string, v *string) {
	if v != nil {
		*dst = *v
	}
}
