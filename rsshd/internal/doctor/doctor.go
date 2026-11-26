// Package doctor finds what is missing on this host for rSshTerm's session daemon: the backend (tmux), the
// service unit, the running daemon, and the optional pieces (screen, reptyr, sudo rule, linger). `rsshd doctor` prints
// it and `hello` reports it, so the app can show "Integration missing: …".
package doctor

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Names of the checks (also the values of hello.missing).
const (
	Tmux        = "tmux"
	Screen      = "screen"
	Unit        = "service-unit"
	Daemon      = "daemon"
	Reptyr      = "reptyr"
	SudoReptyr  = "sudo-reptyr"
	Linger      = "linger"
	unitName    = "rsshd.service"
	launchdName = "dev.rssh.rsshd.plist"
)

// Check is one finding.
type Check struct {
	Name     string `json:"name"`
	OK       bool   `json:"ok"`
	Required bool   `json:"required"` // a missing required piece means the integration does not work
	Detail   string `json:"detail"`
	Fix      string `json:"fix,omitempty"`
}

// Report is the result of Run.
type Report struct {
	OS            string  `json:"os"`
	TmuxVersion   string  `json:"tmux_version"`
	ScreenVersion string  `json:"screen_version"`
	Reptyr        string  `json:"reptyr_version"`
	SudoReptyr    bool    `json:"sudo_reptyr"`
	PtraceScope   int     `json:"ptrace_scope"`
	Linger        bool    `json:"linger"`
	Checks        []Check `json:"checks"`
}

// Missing lists the checks that failed; with requiredOnly, only the required ones.
func (r Report) Missing(requiredOnly bool) []string {
	out := []string{}
	for _, c := range r.Checks {
		if !c.OK && (c.Required || !requiredOnly) {
			out = append(out, c.Name)
		}
	}
	return out
}

// Healthy reports whether every required check passed.
func (r Report) Healthy() bool { return len(r.Missing(true)) == 0 }

// Host is what the checks read; Local() is the real one, tests use fakes.
type Host struct {
	GOOS      string
	Home      string
	User      string
	Socket    string
	TmuxBin   string
	ScreenBin string
	LookPath  func(string) (string, error)
	Output    func(ctx context.Context, name string, args ...string) (string, error)
	ReadFile  func(string) ([]byte, error)
	Exists    func(string) bool
	Dial      func(path string) error
}

// Local returns the Host of this process.
func Local(socket string) Host {
	home, _ := os.UserHomeDir()
	user := os.Getenv("USER")
	if user == "" {
		user = strconv.Itoa(os.Getuid())
	}
	return Host{
		GOOS: runtime.GOOS, Home: home, User: user, Socket: socket, TmuxBin: "tmux", ScreenBin: "screen",
		LookPath: exec.LookPath,
		Output: func(ctx context.Context, name string, args ...string) (string, error) {
			out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
			return string(out), err
		},
		ReadFile: os.ReadFile,
		Exists:   func(p string) bool { _, err := os.Stat(p); return err == nil },
		Dial: func(path string) error {
			c, err := net.DialTimeout("unix", path, time.Second)
			if err != nil {
				return err
			}
			return c.Close()
		},
	}
}

var reptyrVersionRE = regexp.MustCompile(`(\d+\.\d+(\.\d+)?)`)

// Run performs every check. skipDaemon leaves out the socket check (hello runs inside the daemon).
func Run(ctx context.Context, h Host, skipDaemon bool) Report {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	r := Report{OS: h.GOOS, PtraceScope: -1}

	// tmux
	c := Check{Name: Tmux, Required: true, Fix: installHint(h.GOOS, "tmux")}
	if _, err := h.LookPath(h.TmuxBin); err != nil {
		c.Detail = "tmux is not installed"
	} else if out, err := h.Output(ctx, h.TmuxBin, "-V"); err != nil {
		c.Detail = "tmux -V failed: " + firstLine(out, err)
	} else {
		r.TmuxVersion = strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(out), "tmux "), "next-")
		c.OK, c.Detail, c.Fix = true, "tmux "+r.TmuxVersion, ""
	}
	r.Checks = append(r.Checks, c)

	r.Checks = append(r.Checks, screenCheck(ctx, h, &r))
	r.Checks = append(r.Checks, unitCheck(h))

	if !skipDaemon {
		c = Check{Name: Daemon, Required: true, Fix: "rsshd rpc starts it; or: systemctl --user enable --now rsshd"}
		if err := h.Dial(h.Socket); err != nil {
			c.Detail = "no daemon on " + h.Socket
		} else {
			c.OK, c.Detail, c.Fix = true, "listening on "+h.Socket, ""
		}
		r.Checks = append(r.Checks, c)
	}

	if h.GOOS == "linux" {
		if b, err := h.ReadFile("/proc/sys/kernel/yama/ptrace_scope"); err == nil {
			if v, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
				r.PtraceScope = v
			}
		}
		r.Checks = append(r.Checks, reptyrChecks(ctx, h, &r)...)
		r.Checks = append(r.Checks, lingerCheck(ctx, h, &r))
	}
	return r
}

// screenCheck is optional: GNU screen is the second backend, used only when the app or config asks for it.
func screenCheck(ctx context.Context, h Host, r *Report) Check {
	c := Check{Name: Screen, Fix: installHint(h.GOOS, "screen") + " (only for sessions with the screen backend)"}
	bin := h.ScreenBin
	if bin == "" {
		bin = "screen"
	}
	if _, err := h.LookPath(bin); err != nil {
		c.Detail = "screen is not installed"
		return c
	}
	out, err := h.Output(ctx, bin, "-v") // some builds exit 1 for -v: the output decides
	if m := screenVersionRE.FindStringSubmatch(out); m != nil {
		r.ScreenVersion = m[1]
		c.OK, c.Detail, c.Fix = true, "screen "+r.ScreenVersion, ""
		return c
	}
	c.Detail = "screen -v failed: " + firstLine(out, err)
	return c
}

var screenVersionRE = regexp.MustCompile(`(?i)screen version (\S+)`)

func unitCheck(h Host) Check {
	if h.GOOS == "darwin" {
		p := filepath.Join(h.Home, "Library", "LaunchAgents", launchdName)
		c := Check{Name: Unit, Required: true, Fix: "install rsshd with brew or install.sh (writes " + p + ")"}
		if h.Exists(p) {
			c.OK, c.Detail, c.Fix = true, p, ""
		} else {
			c.Detail = "launchd agent " + launchdName + " not installed"
		}
		return c
	}
	if _, err := h.LookPath("systemctl"); err != nil {
		// No systemd: rsshd rpc starts the daemon on demand, which is enough.
		return Check{Name: Unit, OK: true, Detail: "no systemd; the daemon starts on demand"}
	}
	dirs := []string{filepath.Join(h.Home, ".config", "systemd", "user"), "/etc/systemd/user",
		"/usr/local/lib/systemd/user", "/usr/lib/systemd/user", "/lib/systemd/user"}
	for _, d := range dirs {
		if p := filepath.Join(d, unitName); h.Exists(p) {
			return Check{Name: Unit, OK: true, Required: true, Detail: p}
		}
	}
	return Check{Name: Unit, Required: true, Detail: "systemd user unit " + unitName + " not installed",
		Fix: "install the rsshd package, or run install.sh"}
}

func reptyrChecks(ctx context.Context, h Host, r *Report) []Check {
	c := Check{Name: Reptyr, Fix: installHint(h.GOOS, "reptyr") + " (only needed to move running programs into rSshTerm)"}
	path, err := h.LookPath("reptyr")
	if err != nil {
		c.Detail = "reptyr is not installed"
		return []Check{c, {Name: SudoReptyr, Detail: "needs reptyr first"}}
	}
	out, _ := h.Output(ctx, path, "-v")
	r.Reptyr = reptyrVersionRE.FindString(out)
	c.OK, c.Detail, c.Fix = true, "reptyr "+r.Reptyr, ""
	s := Check{Name: SudoReptyr, Fix: "optional sudoers rule: <user> ALL=(root) NOPASSWD: " + path + " -T *"}
	if _, err := h.Output(ctx, "sudo", "-n", "-l", path, "-T", "1"); err != nil {
		s.Detail = "no passwordless sudo rule for reptyr"
	} else {
		r.SudoReptyr = true
		s.OK, s.Detail, s.Fix = true, "sudo -n reptyr allowed", ""
	}
	return []Check{c, s}
}

func lingerCheck(ctx context.Context, h Host, r *Report) Check {
	c := Check{Name: Linger, Fix: "loginctl enable-linger " + h.User + " (sessions then survive the last logout)"}
	if h.Exists("/var/lib/systemd/linger/" + h.User) {
		r.Linger = true
		c.OK, c.Detail, c.Fix = true, "linger enabled", ""
		return c
	}
	out, err := h.Output(ctx, "loginctl", "show-user", h.User, "-p", "Linger")
	if err == nil && strings.TrimSpace(out) == "Linger=yes" {
		r.Linger = true
		c.OK, c.Detail, c.Fix = true, "linger enabled", ""
		return c
	}
	c.Detail = "linger off"
	return c
}

func installHint(goos, pkg string) string {
	if goos == "darwin" {
		return "brew install " + pkg
	}
	return "sudo apt install " + pkg + " (or your distribution's package)"
}

func firstLine(out string, err error) string {
	if s := strings.TrimSpace(out); s != "" {
		return strings.SplitN(s, "\n", 2)[0]
	}
	return err.Error()
}

// Print writes the report for a human, one line per check.
func Print(w io.Writer, r Report) error {
	var errs []error
	p := func(format string, a ...any) {
		if _, err := fmt.Fprintf(w, format, a...); err != nil {
			errs = append(errs, err)
		}
	}
	for _, c := range r.Checks {
		mark := "ok     "
		switch {
		case !c.OK && c.Required:
			mark = "MISSING"
		case !c.OK:
			mark = "absent "
		}
		p("%s %-13s %s\n", mark, c.Name, c.Detail)
		if !c.OK && c.Fix != "" {
			p("        %-13s fix: %s\n", "", c.Fix)
		}
	}
	if r.Healthy() {
		p("rSshTerm session integration: ready\n")
	} else {
		p("rSshTerm session integration: missing %s\n", strings.Join(r.Missing(true), ", "))
	}
	return errors.Join(errs...)
}
