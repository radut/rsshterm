# rSshTerm desktop (Linux and macOS)

Both open as a terminal first (a local shell at launch, servers and the vault on demand) and can be the default
terminal: `docs/desktop/terminal-first.md`.

`Packages/RSSHDesktopCore` is the platform-neutral core both desktop apps build on; it shares models, the vault and
the agent protocol with the iOS app through `apple/Packages/RSSHKit`. No UI toolkit: `swift test` runs on Linux
(`make test-desktop-linux`, in `swift:6.4-noble`) and on macOS 15.

| Area | Types | Notes |
|---|---|---|
| Layout | `Session` → `Window` → `Tab` → `SplitNode` / `Pane` | immutable values, Codable for session restore; split in 4 directions, focus by direction or cycle, close collapses, resize, equalize, zoom, broadcast; `Window.applying(DesktopAction)` |
| Keys | `Keybindings`, `KeyChord`, `DesktopAction`, `KeybindingConfig` | defaults from `docs/research/desktop.md` (⌘ on macOS, Ctrl+Shift on Linux, ⌘/Ctrl+1..9 tabs, ⌘K / Ctrl+Shift+K host search); config overrides per action, `[]` unbinds |
| Host search | `HostSearchIndex`, `FuzzyMatcher` | ranks vault servers by name, host, user, group; `user@host`; result `openTab()` |
| Local PTY | `LocalPTY`, `PTYConfiguration`, `ShellEnvironment` | forkpty in C (`CRSSHPTY`), async output, write, resize, exit status; tabs get `TERM`, `COLORTERM`, `TERM_PROGRAM=rSshTerm`, `SSH_AUTH_SOCK` |
| SSH agent | `DesktopAgent`, `DesktopAgentKeys`, `AgentSocketPath` | the vault's keys on a 0600 socket in a 0700 dir; identities + sign (ed25519, ECDSA, RSA SHA-2) only; per-use confirm hook |
| ssh_config | `SSHConfigGenerator`, `SSHConfigWriter` | Host blocks for vault servers (see below) |
| Servers | `ServerListModel`, `ServerEditorModel`, `CredentialsModel`, `SSHConfigParser`, `SavingVaultDocument` | sidebar, editor, keys, ~/.ssh/config import; see `docs/desktop/servers-files.md` |
| Files | `FilePlaces`, `FileBrowserModel`, `CommanderModel`, `TransferCenter`, `RemoteEditSession` | two-pane commander over local + SFTP (RSSHRemote, jump hosts), F-keys, drag and drop, F4 edit with upload on save |
| Connect | `QuickConnectModel`, `NetworkScanModel`, `TCPPortProbe` | Quick Connect and network scan as on iOS |
| Updater | `UpdateChecker`, `UpdateService`, `UpdatePlanner`, `UpdateInstaller` | signed `latest.json` on Pages; triggers the upgrade; see `docs/desktop/update.md` |

## Apps

- macOS: target `rSshTermMac` in `apple/project.yml`, see `docs/desktop/mac.md`.

## `ssh host` in a local tab uses the vault key

Every local tab exports `SSH_AUTH_SOCK` pointing at the built-in agent:

- Linux: `$XDG_RUNTIME_DIR/rssh/agent.sock` (else `/tmp/rssh-<uid>/agent.sock`)
- macOS: `~/Library/Application Support/rSshTerm/agent.sock`

So `ssh` sees the vault's keys while the vault is unlocked (none while it is locked). With many keys a server may
cut the login off after a few wrong ones, so the app also writes `~/.config/rssh/ssh_config` (or
`$XDG_CONFIG_HOME/rssh/ssh_config`) on every vault change: one `Host` block per server, named after the server
(`Backup NAS` → `backup-nas`; its host name too when only one server has it), with `HostName`, `User`, `Port`,
`IdentityAgent` (the built-in agent, also outside the app's tabs) and `IdentityFile` = that server's public key in
`~/.config/rssh/keys/` with `IdentitiesOnly yes`, so ssh offers exactly the right key.

Add this once at the **top** of `~/.ssh/config` (before any `Host` or `Match` block, or it only applies inside it):

```text
Include ~/.config/rssh/ssh_config
```

Then `ssh backup-nas`, `scp`, `rsync`, `git` and editors' remote plugins use the vault. Your own `~/.ssh/config`
entries below the `Include` still apply for options the generated block does not set.
