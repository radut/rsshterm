# rsshd protocol, version 1 (frozen)

The contract between the rSshTerm app and `rsshd`. It is frozen: a change that breaks a client needs protocol
version 2, negotiated by `hello`. Adding an optional field or a new op is not a break. Design and reasons:
`docs/session-daemon/design.md` §5 and §6.

## Channels

Everything goes over the SSH connection the app already has; rsshd opens no port. The daemon socket
(`$XDG_RUNTIME_DIR/rsshd/sock`, 0600 in a 0700 directory) only accepts connections from the same uid (peer
credentials).

| Channel | SSH request | What runs |
|---|---|---|
| control | `exec` **without** a PTY | `rsshd rpc`: JSON lines on stdin/stdout, bridged to the per-user daemon socket. Starts the daemon when it is not running. |
| terminal | `pty-req` + `exec` | `rsshd attach <id>`: execs `tmux -L rsshd attach -t rssh-<id>`, or `screen -x <pid>.rssh-<id>` for a screen session. A window-change on the channel resizes the session. |

Until the app can send `pty-req` + `exec`, it may open a PTY shell and type `exec rsshd attach <id>` followed by `\r`.

## Framing

One JSON object per line (`\n`), UTF-8, no pretty-printing. Every message carries `"v":1`.

```json
{"v":1,"id":7,"op":"list","args":{}}
{"v":1,"id":7,"ok":true,"result":{"sessions":[]}}
{"v":1,"id":7,"ok":false,"error":{"code":"not_found","message":"no session 3fa9c2d1"}}
{"v":1,"event":"expiring","data":{"id":"3fa9c2d1","reason":"idle","at":"2026-11-24T14:05:00Z","fg_command":"bash"}}
```

- `id` is chosen by the client (any integer); the reply carries the same `id`. Replies may come out of order.
- Events have no `id`; they arrive only on a connection that called `subscribe`.
- Unknown fields are ignored on both sides. Times are RFC 3339 UTC strings. Durations are integer seconds (`*_s`).
- A line longer than 1 MiB closes the connection.

## Error codes

| code | meaning |
|---|---|
| `bad_request` | the line is not JSON, or `args` do not match the op |
| `unsupported_version` | `v` or the `hello.proto` list has no version this daemon speaks |
| `unknown_op` | no such op |
| `not_found` | no managed session with that id |
| `backend_error` | tmux or screen failed (`message` has its stderr), or `create.backend` names a backend this daemon does not have or that is not installed on the host (`message` says which) |
| `not_implemented` | op exists in the protocol but not in this build (`adopt_candidates`, `adopt`, `push_register` in v1.0) |
| `no_reptyr`, `no_sudo`, `ptrace_denied`, `macos`, `not_owner`, `reptyr_failed` | `adopt` failures (phase 2) |

## Ops

| op | args | result |
|---|---|---|
| `hello` | `{client:"rSshTerm/1.x", proto:[1]}` | `{proto:1, version, backends:{tmux:"3.4", screen:"4.09.01"}, default_backend:"tmux", caps:{reptyr:"0.8.0"\|"", sudo_reptyr:bool, ptrace_scope:int, linger:bool, os:"linux"\|"darwin"}, missing:["reptyr", …]}` |
| `list` | `{include_foreign?:bool}` | `{sessions:[Session], foreign:[Foreign]}` |
| `create` | `{name?, backend?, cwd?, command?, cols?, rows?, timeouts?:{idle_s?, hard_s?, finish_work?, warn_lead_s?}}` | `{id, session:Session}` |
| `scrollback` | `{id, lines?:5000}` | `{id, data:"…"}`: the pane history with escape sequences (tmux `capture-pane -p -e -J -S -<lines>`); plain text for screen (`hardcopy -h`) |
| `set_timeouts` | `{id, idle_s?, hard_s?, finish_work?, warn_lead_s?}` | `{session:Session}`; deadlines recomputed at once, state back to `active` |
| `extend` | `{id, by_s?, which:"idle"\|"hard"\|"both"}` | `{session:Session}`; `by_s` defaults to the config (`extend_idle` for idle, `extend_hard` for hard) |
| `close` | `{id}` | `{id}`; SIGHUP to the pane's process groups, `kill-session` after 5 s |
| `status` | `{id}` | `{session:Session}` |
| `subscribe` | `{pane?:bool}` | `{}`; then events on this connection until it closes; `pane:true` adds the `pane` events |
| `health` | `{}` | `{version, uptime_s, backend:{name, version, server_pid}, sessions:int, last_error}` |
| `adopt_candidates`, `adopt`, `push_register` | see design §5.2 | `not_implemented` in v1.0 |

### Backends

`tmux` (the default) and `screen` (GNU screen). `hello.backends` lists the installed ones with their versions;
`default_backend` is what `create` uses without `backend` (config `backend`). `create.backend` picks one per
session; a name the daemon does not know, or a backend not installed on the host, is `backend_error`. Every
other op finds the session's backend by its id. `Session.backend` and `Foreign.backend` say which one holds it.
For screen, `alt_screen` is always `false`, `cols`/`rows` apply only from the first attach, and `scrollback`
has no escape sequences (rsshd/README.md, "GNU screen").

`command` in `create` is typed into the new shell once (the "initial session command"); it is never logged.
`timeouts` left out take the daemon's config defaults (idle 1 h, hard 1 day, finish_work on, warn lead 5 min).
`0` disables the idle or the hard timeout.

### Session

```json
{"id":"3fa9c2d1","name":"build","backend":"tmux","created":"…","last_activity":"…","attached_clients":1,
 "state":"active","deadlines":{"idle":"…","hard":"…"},"timeouts":{"idle_s":3600,"hard_s":86400,
 "finish_work":true,"warn_lead_s":300},"fg_running":false,"fg_command":"bash","alt_screen":false,
 "pane":{"command":"","args":[],"cwd":"/home/u/src"}}
```

`pane` is what a tab title shows (added in 1.x; older daemons leave it out): `command` is the foreground program
(the leader of the pane tty's foreground process group, without its folder) and `args` its arguments, both empty
while the shell waits at its prompt; `cwd` is that process's working directory (the shell's at the prompt).
Secrets are taken out before they leave the server: values of password/token/secret/key flags, `-p` of mysql and
sshpass, `NAME_TOKEN=` assignments, `user:pass` in URLs and `curl -u`, secret headers and Bearer/Basic
credentials become `•••`, also behind wrappers (`sudo`, `env`, `time`, ...). At most 32 arguments of 256 bytes.
Linux reads `/proc/<pid>/cmdline` and `/proc/<pid>/cwd`; macOS `ps -o args=` (split at spaces) and `lsof -d cwd`.

`deadlines.idle` is the time the session closes if nothing happens; it is absent when the idle timeout is off,
and it moves later with every output or input. `deadlines.hard` is absent when the hard timeout is off.

### Foreign

The user's own tmux sessions on the default tmux server and screen sessions in the user's own screen directory:
attach-only, no timeouts.
`{"name":"main","backend":"tmux","attached_clients":0,"attach":["tmux","attach","-t","main"]}`,
`{"name":"work","backend":"screen","attached_clients":0,"attach":["screen","-x","4242.work"]}`

## Events (after `subscribe`)

| event | data | when |
|---|---|---|
| `state` | `{id, state}` | any state change (`active`, `waiting_for_job`, `warning_idle`, `warning_hard`) |
| `expiring` | `{id, reason:"idle"\|"hard", at, fg_command}` | once on entering `warning_idle` / `warning_hard`; `at` is the close time |
| `closed` | `{id, reason:"idle"\|"hard"\|"closed"\|"exited"}` | the session is gone: timeout, `close`, or its shell exited |
| `pane` | `{id, pane:{command, args, cwd}}` | only after `subscribe {pane:true}`: the session's `pane` changed (seen at the next poll, `poll_interval`) |

## Timeout state machine

```
active ── idle deadline − lead reached ──┬─ finish_work and a foreground job runs ─> waiting_for_job
                                          └─ otherwise ─────────────────────────────> warning_idle (expiring idle)
waiting_for_job ── job ended ───────────> warning_idle (closes lead later; the prompt the job leaves is not activity)
waiting_for_job / warning_idle ── output or input ──> active
warning_idle ── close time reached ─────> closed (idle)
any state ── hard deadline − lead reached ──> warning_hard (expiring hard)
warning_hard ── hard deadline reached (even if busy) ──> closed (hard)
any warning ── extend ──> active
```

- Idle deadline = last output or input + `idle_s` (or the time `extend` set, if later). tmux records activity
  in whole seconds (screen: tty times and screen-content changes, see rsshd/README.md) and the daemon polls every `poll_interval` (5 s), so a deadline can be met up to that much
  early or late. Output from the
  session and keys from any client both count as activity, so a session that is still sending or receiving is
  never closed by the idle timeout; only the hard timeout can close a busy session, and it warns first.
- A foreground job runs when the pane tty's foreground process group differs from the shell
  (`/proc/<pid>/stat` field 8 on Linux, `ps -o tpgid=` on macOS). A full-screen program (htop) redraws, so it
  is never idle; only the hard timeout ends it.
- The warning comes `warn_lead_s` before the close (default 5 min). No answer = the session closes.
- `extend` default: +1 h idle, +1 day hard.
- All timeout state is stored in tmux user options (`@rssh_*`), or for screen in the state file
  (`$XDG_STATE_HOME/rsshd/screen-sessions.json`), so a daemon restart resumes where it was.
