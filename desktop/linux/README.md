# rSshTerm for Linux (`rsshterm`)

GTK4 + libadwaita + VTE through C interop (no Swift GTK wrapper), on `../Packages/RSSHDesktopCore` (layout, keys,
host search, jump switcher, agent, ssh_config, updater) and `apple/Packages/RSSHKit` (vault, stores, key stores).
Stack choice: `docs/research/desktop.md` §2.

| Target | What |
|---|---|
| `RSSHTermLinux` | the app's logic without GTK, unit-tested: `KeyTranslator` (GDK keyval/state → core `KeyChord`), `PaneDiff`, `SpawnPlanner`, `SSHInclude`, `AppSettings`, `VaultSession`, `KeyRow`, `HostSearchModel`, `UpdatePresenter`, `RSSHTermVersion` |
| `RSSHTermApp` (product `rsshterm`) | the UI: `AppController` (vault, agent, updates), `MainWindow` (AdwTabView + GtkPaned tree from the core `Window`), `TerminalPane` (VteTerminal), `PickerDialog` (host search, jump switcher), Keys, Preferences, `Gtk.swift` (casts, signals as closures, main-loop hops) |
| `CGtk` | system library: gtk4 + libadwaita-1 + vte-2.91-gtk4 headers |

## Build and test

```bash
make test-desktop-linux-app
```

That builds `Dockerfile` (`swift:6.4-noble` + the libraries + Xvfb, xdotool, ImageMagick, sshd), runs the unit
tests, then `scripts/smoke-test.sh`: the sample vault (Web Prod 1 = the container's own sshd as
`deploy@web1.example.com`, plus `nas.example.org` and `ci.example.com`) is imported for the demo user `you` on host
`workstation`, so screenshots carry mock data only; `rsshterm`
runs under Xvfb, and xdotool types Ctrl+Shift+T, Ctrl+Shift+E, `echo ok`, Ctrl+1/2, Ctrl+Shift+K + Enter (an SSH
tab logs in through the built-in agent and runs a remote command), Ctrl+Shift+R, Ctrl+Shift+J; Keys and
Preferences open over D-Bus actions; then a new device (device key removed) unlocks with the master password, and
opens without it on the next launch. The app writes its state (tabs, panes, terminal text) to
`$RSSHTERM_TEST_STATE` for the script to read. Screenshots: `docs/screens/desktop-linux/`.

Release build (the pipeline contract, packages `bin/rsshterm`; there are no resource bundles). Add
`--static-swift-stdlib`: without it the binary needs the Swift runtime from `/usr/lib/swift` (libswiftCore,
libFoundation, libdispatch, ...), which no distro package provides; with it (98 MB, checked) only libcurl and
libxml2 remain from the system:

```bash
swift build -c release --product rsshterm --static-swift-stdlib
```

Build deps (Ubuntu 24.04): `libgtk-4-dev libadwaita-1-dev libvte-2.91-gtk4-dev pkg-config` (+ the Swift toolchain).

Runtime deps of the `.deb` (Ubuntu 24.04 names): `libgtk-4-1 (>= 4.14)`, `libadwaita-1-0 (>= 1.5)`,
`libvte-2.91-gtk4-0 (>= 0.76)`, `openssh-client`, `libcurl4t64`, `libxml2` (Foundation); the Swift runtime too unless built with
`--static-swift-stdlib` (recommended). Recommends: `libsecret-tools`
(secret-tool: device key and Google tokens in the keyring, else an owner-only file), `pkexec` (updates through
apt), `xdg-utils` (Google sign-in opens the browser).

## What it does

- Tabs (AdwTabView): Ctrl+Shift+T new, Ctrl+1..9, Ctrl+PgUp/PgDn, Ctrl+Shift+PgUp/PgDn move, Ctrl+Shift+W close
  pane. Splits: Ctrl+Shift+E right, Ctrl+Shift+O down, Alt+arrows focus, Ctrl+Shift+Alt+arrows resize,
  Ctrl+Shift+X zoom, Ctrl+Shift+Alt+= equalize. All from the core `Keybindings`.
- Broadcast input (core `BroadcastState`): Ctrl+Shift+I toggles all panes of the window's tabs; Ctrl+Shift+Alt+I
  opens the picker (presets: this tab, all tabs, visible, all windows, same host, same server group; checkboxes,
  filter, Enter starts); Main Menu › Broadcast Input has every mode (current only, current tab, visible, toggle
  this session). Typing and paste reach every target (a multi-line paste into several panes asks first); receiving
  panes get red stripes (Preferences can hide them) and a badge that takes the pane out.
- Session restore (Preferences, on by default): windows, tabs, splits and their sizes, manual tab titles, SSH panes
  and each local shell's directory (OSC 7, else /proc/<pid>/cwd) in `$XDG_STATE_HOME/rssh/session.json`, saved a
  second after a layout change, every 5 s and on quit/SIGTERM; SSH panes restored before the vault opens wait for it. Ctrl+Shift+C/V copy/paste. Ctrl+Shift+R renames the tab (empty = automatic title; also in the tab
  context menu). Ctrl+Shift+J jump switcher: every open shell, then "New session on <server>".
- Packaging (desktop file, icons from the app logo, AppStream): `packaging/README.md`.
- Every pane is a VteTerminal spawning the core's plan: the login shell (`-bash`) with `SSH_AUTH_SOCK` = the
  built-in agent and `TERM_PROGRAM=rSshTerm`; an SSH pane runs `ssh <alias>` (or `ssh -F <generated config>
  <alias>` while ~/.ssh/config lacks the Include). A pane whose process fails stays open with its exit status.
- Vault: device key from the Secret Service (`secret-tool`), else an owner-only file (the app says so); a new
  device asks for the master password once and saves the vault with its own key; no vault yet → "Set Up" creates
  one with a master password. With `RSSH_GOOGLE_CLIENT_ID` (or `RSSH_GOOGLE_CLIENT_FILE`) set, the menu offers
  Google Drive sign-in and the vault is kept in Drive's appDataFolder, mirrored in
  `$XDG_DATA_HOME/rssh/vault.json`. Passphrase-protected keys are offered by the agent (RSSHKit bcrypt_pbkdf +
  AES-CTR/GCM). After unlock the agent gets the keys and `~/.config/rssh/ssh_config` is
  written; the app offers once to add the `Include` line to ~/.ssh/config. Lock Vault empties the agent.
- Host search (Ctrl+Shift+K): servers, then remote desktops (core RemoteDesktopSearch); Enter opens a tab,
  Shift+Enter a split.
- Tab titles (RSSHKit TabTitleSettings + core TabTitleContext): the tab strip shows a bold title and a smaller
  subtitle (default `{custom|server|user@host|host|title}` / `user@host · process args` or the folder), the window
  title joins both. Each pane's PaneTitleState comes from VTE (OSC 0/2 title, OSC 7 folder) and, for local tabs,
  the foreground process read once a second from VTE's PTY (`ForegroundProcess`); a renamed tab is `{custom}`.
  Preferences › Tab Titles: presets, templates with parse problems shown, One Line, live preview of sample tabs,
  placeholders that insert at the cursor, syntax and sources help, the bash/zsh/fish shell-integration snippets to
  copy, Reset.
- Servers sidebar (F9, on the RSSHDesktopCore models of `docs/desktop/servers-files.md`): search over name, host,
  user, folder, tags and notes; tag chips; folders (collapse, rename, delete); Enter / double-click connects,
  Shift+Enter in a split; right-click Connect, Split, Edit, Duplicate, Browse Files, Move to a folder, Delete; drag
  a server onto a folder (move) or onto a server (reorder). Toolbar: New Server, New Folder, Scan Network, Import
  ~/.ssh/config, Quick Connect, File Manager.
- Server editor: name, host, port, user, folder, login (saved password/key or a new password), Jump Through (saved
  servers or user@host:port, reorder, remove), agent forwarding, rSshD sessions, per-server theme, font and size
  (SSH tabs use them), tags, notes; "discard changes?" on close.
- Keys and Passwords: generate ed25519, import a key file (passphrase asked when encrypted), add a password, rename,
  delete (refused while a server uses it), copy public key, show private after the master password.
- Import ~/.ssh/config (checkboxes, "already saved", ProxyJump as the jump chain, unencrypted IdentityFile keys
  imported as logins), Quick Connect (hosts → user → login → one tab per host running OpenSSH → Save to), Scan
  Network (range, ports, results with checkboxes, Add (N)).
- Remote desktops (docs/desktop/remote-desktop.md; RSSHRemoteDesktop: RSSHTunnel + RSSHVNC on RoyalVNCKit): entries
  in the sidebar's folders (New Remote Desktop…, Connect / Split / Edit / Delete), an editor (kind, host/port as the
  SSH server sees it, route: through an SSH server / own SSH connection / direct with the "not encrypted" or
  "exposed port" warning, user + password with Copy from SSH, ask every time, clipboard opt-in). Connect follows
  RemoteDesktopConnectPlan: a confirm for direct, the login sheet only when needed (pick a saved password, type one
  with Save to Vault once it works, or continue without), then the screen as a pane/tab: progress and error cards
  (Retry, Edit, Open Terminal on the SSH server), Fit / 1:1, pointer and wheel, the keyboard grabbed while the
  picture has focus (badge; Ctrl+Alt releases), ⋯ Send Ctrl+Alt+Del / Reconnect / Disconnect, and a paste button
  that types the clipboard when the entry allows it (RoyalVNCKit has no Linux pasteboard). Linux terminals run
  OpenSSH, so "through an SSH server" opens its own Citadel connection (the server's login, jump hosts and pinned
  host keys). RDP entries open through RSSHRDP (libfreerdp3) the same way: the certificate is asked about on the first connect and pinned in the entry; a changed one is refused with a card whose "Trust New…" needs a destructive confirm; with the clipboard opt-in, text copied on either side reaches the other.
- File manager (two panes, any place: this computer or any server over SFTP through its jump chain with pinned
  host keys): Midnight Commander keys (F3 view, F4 edit, F5 copy, F6 move, Shift+F6 rename, F7 folder, F8 delete,
  Tab, Ctrl+U swap, Alt+= same folder, Insert/Space mark) plus Backspace, Delete, F2, Ctrl+R/A/H, Ctrl+Shift+N; the
  button bar; drop files from the desktop onto a pane (upload), drag rows to the other pane (Shift = move) and
  local files out to the desktop; the transfers panel (progress, cancel, retry, Replace/Skip/Keep Both + apply to
  all); F4 opens a copy in the default text editor (the text/plain handler, never by the server's file type; else
  $VISUAL/$EDITOR in a tab) and uploads it on every save, with a conflict question when the server's copy changed.
  "Open File Manager Here" (terminal right-click or the menu): this computer at the shell's directory, or the SSH
  tab's server at the remote shell's OSC 7 directory.
- Keys: name, type, fingerprint, copy public key; the private key only after the master password.
- Help › Check for Updates, plus a check 10 s after launch and hourly (the core schedule makes it daily); notes
  shown, Install runs the core installer (apt through pkexec, or the tarball swap) and restarts.
- Preferences: font, style (follow system / light / dark), scrollback, automatic updates
  (`$XDG_CONFIG_HOME/rssh/desktop.json`).
- `rsshterm vault import <vault.json>`: creates this device's vault from a plaintext vault document (master
  password from `RSSH_MASTER_PASSWORD` or asked); refuses when a vault exists.

App id and program name `dev.rsshterm.RSSHTerm` (WM_CLASS too, also inside an AppImage; single instance through D-Bus; actions `app.keys`, `app.preferences`,
`app.check-updates`, ... can be activated with `gdbus`).
