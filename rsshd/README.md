# rsshd

The per-user session daemon of rSshTerm. Sessions live in tmux (its own server, `tmux -L rsshd`) or, when the app
or the config asks for it, in GNU screen (its own socket directory), so they survive the app going to the
background, the network dropping, and rsshd itself restarting. rsshd names and lists the
sessions, enforces the timeouts and talks to the app over the SSH connection the app already has (no open port).

Design: `docs/session-daemon/design.md`. Wire contract: [PROTOCOL.md](PROTOCOL.md) (frozen, v1).

## Commands

| Command | What |
|---|---|
| `rsshd serve` | the daemon (run by the systemd user unit or launchd agent; `rsshd rpc` starts it when neither exists) |
| `rsshd rpc` | JSON lines on stdin/stdout for the app's exec channel, bridged to the daemon socket |
| `rsshd attach <id>` | execs `tmux attach` (or `screen -x`) for the app's PTY channel |
| `rsshd doctor [--json]` | what is missing: tmux, the service unit, the running daemon; optional screen, reptyr, sudo rule, linger. Exit 1 when a required piece is missing |
| `rsshd version` | |

## Configuration

`~/.config/rsshd/config.toml` (or `$XDG_CONFIG_HOME/rsshd/config.toml`). Every key is optional:

```toml
backend = "tmux"                        # default for create without a backend: "tmux" or "screen"
socket = "/run/user/1000/rsshd/sock"   # default $XDG_RUNTIME_DIR/rsshd/sock, else /tmp/rsshd-<uid>/sock
poll_interval = "5s"
close_grace = "5s"                      # SIGHUP, then kill-session after this
tmux_socket = "rsshd"                   # tmux -L name
tmux_conf = "/usr/share/rsshd/tmux.conf" # /dev/null when the file does not exist
screen_dir = "/run/user/1000/rsshd/screen"  # SCREENDIR of the managed screen sessions; default next to the socket
screen_rc = "/usr/share/rsshd/screenrc"     # built-in copy when the file does not exist
screen_state = "~/.local/state/rsshd/screen-sessions.json" # default $XDG_STATE_HOME/rsshd/…; must be absolute

[timeouts]
idle = "1h"          # 0 = off
hard = "24h"         # 0 = off
finish_work = true   # an idle session with a running job waits for the job
warn_lead = "5m"     # the expiring event comes this long before the close
extend_idle = "1h"   # what Extend adds
extend_hard = "24h"
```

## Layout

| Path | What |
|---|---|
| `cmd/rsshd` | the subcommands |
| `internal/backend` | the frozen `Backend` interface; `tmux/` and `screen/` implement it, `multi/` routes between them (create picks by name, list merges), `fake/` for tests |
| `internal/hangup` | SIGHUP to a window's process groups, shared by both backends |
| `internal/probe` | the frozen `Result`; foreground job via `/proc/<pid>/stat` (Linux) or `ps -o tpgid=` (macOS) |
| `internal/timeout` | the state machine of PROTOCOL.md, pure, table-tested |
| `internal/watch` | polls the backend, steps the machines, persists them as session metadata, closes, fans out events |
| `internal/rpc` | the protocol server |
| `internal/daemon` | socket (0700 dir, 0600 socket, per-user lock, peer uid check), serve, the `rpc` bridge |
| `internal/doctor` | the checks behind `rsshd doctor` and `hello.missing` |
| `test/e2e` | the real binary against real tmux and screen: finish-work, hard timeout on htop, output keeps a session alive, attach through a pty, restart |

## GNU screen

`create` with `"backend":"screen"` (or `backend = "screen"` in the config) puts the session in GNU screen;
`hello.backends.screen` has its version when it is installed. Screen is optional: the .deb only suggests it,
and `rsshd doctor` lists it as absent, never as missing.

- Sessions `rssh-<id>` live in their own socket directory (`SCREENDIR=<runtime dir>/rsshd/screen`, 0700; rsshd's own files in its `.rsshd/`, 0700), started
  with `screen -c <screenrc> -dmS`; the user's own `~/.screenrc` and sessions are never touched. The user's own
  sessions are listed as foreign (attach-only, `screen -x <pid>.<name>`).
- `screen_rc` (also built in): no status line, 10000 lines of scrollback, UTF-8, alternate screen, no flow control.
- Screen has no user options, so the metadata (timeouts, name) is a JSON file (`screen_state`, written atomically,
  0600 in a 0700 directory); entries of ended sessions are pruned.
- `rsshd attach <id>` execs `env SCREENDIR=… screen -x <pid>.rssh-<id>` (several clients may attach, like tmux).
- The initial command goes through screen's paste buffer (`readbuf` + `paste`), so it is typed byte for byte.
- `close`: SIGHUP to every window's process groups, `quit` after `close_grace`.

Gaps compared with tmux:

- **Activity**: screen reports none. rsshd takes the newest of the window ttys' access/modification times (input
  and output; the kernel updates them only every few seconds) and the time the visible screen content changed
  between two polls (output, at `poll_interval` resolution; a `hardcopy` per session per poll). Input that
  changes nothing on screen counts only through the coarse tty times. The prompt a finished job leaves is
  absorbed for two polls, so it never counts as activity.
- **`alt_screen`** is always false: screen does not expose it. Full-screen programs still redraw, so they are
  still never idle.
- **Size**: `screen -dm` cannot size a detached window; `cols`/`rows` are ignored and the window takes the size of
  the terminal on the first attach.
- **Scrollback** (`scrollback` op) is plain text: screen's `hardcopy -h` has no escape sequences.
- Foreground job and `fg_command` work as for tmux (the first window's shell, `/proc` or `ps`).
- The socket directory is in the runtime directory, which systemd removes at the last logout unless linger is on
  (`loginctl enable-linger`); the daemon's own socket has the same constraint.

## Tests

```
make rsshd-test     # in docker: gofmt, go vet, unit + tmux + screen tests, e2e (the GitLab job rsshd:test runs the same script)
make rsshd-build    # static binary in rsshd/dist/ (RSSHD_GOOS / RSSHD_GOARCH)
```

Locally with Go, tmux and screen installed: `cd rsshd && RSSHD_REQUIRE_TMUX=1 RSSHD_REQUIRE_SCREEN=1 go test ./...`
(without screen, its tests skip).
