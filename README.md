<div align="center">

<img src="https://radut.github.io/rsshterm/media/icon.png" width="96" height="96" alt="rSshTerm icon">

# rSshTerm

**The SSH terminal that keeps your keys in one vault and your sessions on the server.**
**On your iPhone and iPad, and on your Linux and Mac desktop**, from the same Swift code and the same vault.

![iOS: coming soon](https://img.shields.io/badge/iOS-coming%20soon-8e8e93)
[![Linux: coming soon](https://img.shields.io/badge/Linux-coming%20soon-8e8e93)](#desktop-linux-and-macos)
[![macOS: in progress](https://img.shields.io/badge/macOS-in%20progress-8e8e93)](#desktop-linux-and-macos)
[![rSshD: server daemon](https://img.shields.io/badge/rSshD-apt%20·%20install.sh-6e56cf)](#rsshd-on-your-servers)
[![Swift 6](https://img.shields.io/badge/Swift-6-f05138)](https://radut.github.io/rsshterm)

[Website](https://radut.github.io/rsshterm/) · [Install](#install) · [Keyboard](#keyboard-shortcuts) · [Docs](#documentation)

<img src="https://radut.github.io/rsshterm/media/ios-keyboard.gif" width="220" alt="Terminal with the on-screen keyboard: key row pages (F-keys, symbols, navigation), sticky Ctrl, chips">&nbsp;
<img src="https://radut.github.io/rsshterm/media/ios-quick-connect.gif" width="220" alt="Quick Connect: hosts, user, key, save">&nbsp;
<img src="https://radut.github.io/rsshterm/media/ios-files.gif" width="220" alt="Files: browser, the session's folder, two-pane Commander">

<sub><b>iPhone &amp; iPad</b>: key row · Quick Connect · Files</sub>

<img src="https://radut.github.io/rsshterm/media/linux-splits.gif" width="330" alt="Desktop: splits, then one command broadcast to every pane">&nbsp;
<img src="https://radut.github.io/rsshterm/media/linux-jump.gif" width="330" alt="Desktop: the jump switcher over open shells and saved servers">

<sub><b>Linux &amp; macOS</b>: splits and broadcast · jump switcher</sub>

</div>

## Two apps, one vault

In your pocket and on your desk: the same servers, keys and sessions on the phone and the laptop. Start a shell on
one, pick it up on the other.

<table><tr>
<td width="50%" valign="top">
<img src="https://radut.github.io/rsshterm/media/ios-servers.png" width="200" alt="rSshTerm on iPhone: server list with folders">

**rSshTerm for iPhone &amp; iPad**

- Key row with symbol, navigation and F-key pages, sticky Ctrl/Alt
- Quick Connect and network scan: an address to a saved server in four taps
- SFTP and a two-pane Commander (phone, Files, S3, servers)
- Face ID, iCloud vault sync to your Mac
- Hardware keyboard shortcuts on iPad

Coming soon · iOS &amp; iPadOS 18+
</td>
<td width="50%" valign="top">
<img src="https://radut.github.io/rsshterm/media/mac-host-search.png" alt="rSshTerm on macOS: host search over the vault's servers">

**rSshTerm for Linux &amp; macOS**

- Tabs, splits and broadcast input to any set of panes
- Host search (<kbd>⌘K</kbd>) and the jump switcher (<kbd>⌘J</kbd>)
- Built-in agent: `ssh web1` in any local tab uses the vault key
- VNC and Apple Screen Sharing over the same SSH connection; RDP on Linux
- Touch ID on the Mac; signed self-update

Coming soon
</td>
</tr></table>

## Why rSshTerm

- **One vault, every device.** Passwords, keys and servers live in one AES-256-GCM vault. Each device opens it with
  its own key (Keychain, Secret Service); iCloud Keychain carries it to your other Apple devices, and a master
  password lets a brand-new laptop in once. Face ID / Touch ID guards it after that.
- **Sessions that wait for you.** rSshD on the server keeps every shell in tmux or screen. Close the app, lose the
  train's Wi-Fi, switch phones: you come back to the same screen, with idle and hard timeouts you choose.
- **A keyboard made for shells.** An extra key row with pages (symbols, navigation, F1–F16), a chip bar, sticky
  Ctrl/Alt, hold-to-repeat arrows and word editing that works the way a Mac or a Linux shell expects.
- **Files without a second app.** Browse any server over SFTP from inside its session, or open a two-pane Commander
  between the phone, the Files app, S3 and any server, with a transfer queue.
- **On the desktop: a real terminal.** Tabs, splits, broadcast input, a jump switcher and host search. `ssh web1` in
  any local tab just works: the built-in agent serves the vault's keys and writes the matching `ssh_config`.

## Features

### Terminal and keyboard (iOS)

<table><tr>
<td width="33%"><img src="https://radut.github.io/rsshterm/media/ios-terminal-jb.png" alt="Terminal with JetBrains Mono ligatures and Nerd Font icons"></td>
<td width="33%"><img src="https://radut.github.io/rsshterm/media/ios-themes.png" alt="Theme gallery"></td>
<td width="33%"><img src="https://radut.github.io/rsshterm/media/ios-fonts.png" alt="Bundled monospace fonts"></td>
</tr></table>

- SwiftTerm terminal, several sessions at once; the sessions drawer lists them per server.
- Key row: esc, ctrl, tab, arrows, and **⋯** pages for symbols, PgUp/PgDn/Home/End, F1–F16 and META.
- Chip bar: Paste, Esc, Tab, Shift, Ctrl, Alt, Ctrl+C/D/L, plus optional Ctrl+W/U/A/E.
- Word editing presets (Natural text editing or Linux), Option as Meta per side, hardware keyboard map.
- Bundled developer fonts with ligatures and Nerd Font symbols; light/dark theme pairs, per server.

### Servers, Quick Connect and network scan

<table><tr>
<td width="33%"><img src="https://radut.github.io/rsshterm/media/ios-servers.png" alt="Server list with folders"></td>
<td width="33%"><img src="https://radut.github.io/rsshterm/media/ios-quick-login.png" alt="Quick Connect login step"></td>
<td width="33%"><img src="https://radut.github.io/rsshterm/media/ios-scan.gif" alt="Network scan: hosts that answer SSH, then add them"></td>
</tr></table>

- Servers in folders, each with a password or a key; import PEM, PKCS#8, PuTTY and OpenSSH keys or generate ed25519.
- Quick Connect: paste one or many hosts, pick a user from your list, a key or a password, connect, save.
- Network scan: `192.0.2.0` means the whole /24; hosts that answer SSH get a checkbox and are added in one go.
- Jump hosts: a chain of vault servers or inline `user@host:port` (ProxyJump on the desktop).
- Host keys pinned on first use; SSH agent forwarding with a per-use prompt (Allow once / this session / Deny).

### Kept sessions with rSshD

<table><tr>
<td width="33%"><img src="https://radut.github.io/rsshterm/media/ios-sessions.gif" alt="Sessions drawer, rsshd status chip, resume picker"></td>
<td width="33%"><img src="https://radut.github.io/rsshterm/media/ios-session-daemon-status.png" alt="Server daemon sheet: rsshd, tmux, screen"></td>
<td width="33%"><img src="https://radut.github.io/rsshterm/media/ios-agent-forwarding-prompt.png" alt="Agent forwarding prompt"></td>
</tr></table>

- Connect and the app checks the server: a chip says `rsshd · tmux`, or why sessions are not kept.
- Resume any kept session, all of them at once, or start a new one; per-server choice (always ask / last / new).
- Idle and hard timeouts per session; "finish work" waits for the running job before closing.
- No rSshD yet? The app offers to install it (user tarball or apt) and shows the output live.

### Files and Commander

<table><tr>
<td width="50%"><img src="https://radut.github.io/rsshterm/media/ios-files.gif" alt="File browser and Commander"></td>
<td width="50%"><img src="https://radut.github.io/rsshterm/media/ios-commander.png" alt="Two-pane Commander: server and S3"></td>
</tr></table>

- One `FileSource` for local files, the Files app, SFTP and S3: copy or move between any two.
- From a terminal, the folder button opens the same server's files in the shell's current folder, on the same
  connection; upload, open, share, or add a second pane.
- Commander: F3 view, F4 edit, F5 copy, F6 move, F7 mkdir, F8 delete; streaming transfers with progress and cancel.

### Vault

<table><tr>
<td width="50%"><img src="https://radut.github.io/rsshterm/media/ios-account.png" alt="Account: vault unlocked, iCloud, master password"></td>
<td width="50%"><img src="https://radut.github.io/rsshterm/media/mac-unlock.png" alt="macOS: unlock the vault"></td>
</tr></table>

- The vault key is wrapped once per device, once by an iCloud Keychain key, and optionally by a master password
  (scrypt). Any one of them opens it; none of them leaves your devices in the clear.
- Stored on the device and in your private iCloud database (Apple devices) or Google Drive's hidden app folder
  (every platform). Saves never overwrite another device's newer copy.

### Desktop: Linux and macOS

<img src="https://radut.github.io/rsshterm/media/linux-splits.gif" alt="Linux: splits, then one command broadcast to every pane">

<table><tr>
<td width="50%"><img src="https://radut.github.io/rsshterm/media/linux-search.gif" alt="Linux: Ctrl+Shift+K host search opens an SSH tab"></td>
<td width="50%"><img src="https://radut.github.io/rsshterm/media/linux-jump.gif" alt="Linux: Ctrl+1..9 and the Ctrl+Shift+J jump switcher"></td>
</tr><tr>
<td width="50%"><img src="https://radut.github.io/rsshterm/media/mac-host-search.png" alt="macOS: host search"></td>
<td width="50%"><img src="https://radut.github.io/rsshterm/media/mac-settings.png" alt="macOS: settings"></td>
</tr></table>

- Local terminal tabs (Cmd/Ctrl+1…9), vertical and horizontal splits, zoom, equalize, broadcast input to all panes
  or a picked set; the session (tabs, splits, folders, SSH panes) comes back after a restart.
- Host search opens a server in a tab or a split; the jump switcher finds any open shell or starts a new one.
- The built-in SSH agent serves vault keys to every local shell, so plain `ssh web1` picks the right key.
- Touch ID on the Mac before keys are shown; Secret Service on Linux.
- Signed self-update from `latest.json` (tarball, AppImage, notarized Mac app); `.deb` installs update with apt.
- Servers, Quick Connect, network scan and files (browser and two-pane Commander), as on the phone.

### Broadcast input

Type once, run it on every server. <kbd>⌘⇧I</kbd> / <kbd>Ctrl+Shift+I</kbd> sends what you type to every pane,
<kbd>⌘⌥I</kbd> to this tab's panes, and <kbd>⌘⌥⇧I</kbd> / <kbd>Ctrl+Shift+Alt+I</kbd> opens the picker: presets (this tab,
all tabs of the window, visible panes, all windows) or the exact panes you tick, filtered by name or host. Receiving
panes wear a striped frame and the title says "broadcasting input" until you stop.

<img src="https://radut.github.io/rsshterm/screens/desktop-linux/broadcast.png" alt="Linux: one command typed once runs in every pane, striped frame on the receiving pane">

<table><tr>
<td width="50%"><img src="https://radut.github.io/rsshterm/screens/desktop-mac/broadcast-picker.png" alt="macOS: the broadcast picker with presets and pane checkboxes"></td>
<td width="50%"><img src="https://radut.github.io/rsshterm/screens/desktop-linux/broadcast-picker.png" alt="Linux: the broadcast picker"></td>
</tr></table>

### Remote desktop

VNC and Apple Screen Sharing on Linux and macOS, RDP on Linux, tunnelled over the SSH connection you already have (or
a separate one, or direct). A server can be SSH, RDP, VNC or several at once: tick them in the server editor (Open
As) and open the screen from the server's menu; a server with SSH off opens as its screen. A network scan adds a host
that answers on 22 and 3389 as one server with both. A screen for a host that is already saved is never merged
quietly: you are asked whether to add it to that server or keep a separate one. Saved credentials per screen, "Copy
from SSH", and a login sheet only when one is needed.

<table><tr>
<td width="50%"><img src="https://radut.github.io/rsshterm/screens/desktop-mac/remote-desktop.png" alt="macOS: a remote desktop pane"></td>
<td width="50%"><img src="https://radut.github.io/rsshterm/screens/desktop-linux/remote-desktop-rdp.png" alt="Linux: an RDP screen"></td>
</tr></table>

### Coming next

RDP on macOS and iOS, and the macOS app in the App Store.

## Install

### iPhone and iPad

rSshTerm for iPhone and iPad is **coming soon** to the App Store. Requires iOS & iPadOS 18+.

### Desktop: Linux and macOS

The Linux and macOS apps are **coming soon**.

### rSshD on your servers

Debian, Ubuntu, Raspberry Pi OS (signed apt repo plus a user service) and macOS (launchd agent):

```bash
curl -fsSLO https://rssh-ea902a.gitlab.io/install.sh && sh install.sh
```

`sh install.sh --uninstall` removes it; running tmux sessions are left alone. The app can also install it for you
from the Server daemon sheet.

## Keyboard shortcuts

### iPhone and iPad with a hardware keyboard

Natural text editing preset (Settings › Keyboard › Word Editing); the Linux preset sends the readline keys instead.

| Keys | Does | Sends |
|---|---|---|
| ⌥ ← / ⌥ → | word left / right | `ESC b` / `ESC f` |
| ⌘ ← / ⌘ → | start / end of line | `^A` / `^E` |
| ⌥ ⌫ | delete the word before the cursor | `ESC DEL` |
| ⌘ ⌫ | delete to the start of the line | `^U` |
| fn ⌫ or ⌦ | delete the character after the cursor | `ESC [3~` |
| ⌥ ⌦ | delete the word after the cursor | `ESC d` |
| ⌘ ⌦ | delete to the end of the line | `^K` |
| ⌃ ← / ⌃ → | word left / right (where inputrc maps it) | `ESC [1;5D` / `ESC [1;5C` |
| ⌃ ⌫ | delete the word before the cursor | `^W` (or `^H`) |

Commander: <kbd>Tab</kbd> switches panes; <kbd>F3</kbd> view, <kbd>F4</kbd> edit, <kbd>F5</kbd> copy,
<kbd>F6</kbd> move, <kbd>F7</kbd> new folder, <kbd>F8</kbd> delete (also <kbd>⌘3</kbd>…<kbd>⌘8</kbd>).

### Desktop

| Action | macOS | Linux |
|---|---|---|
| New tab / window | <kbd>⌘T</kbd> / <kbd>⌘N</kbd> | <kbd>Ctrl+Shift+T</kbd> / <kbd>Ctrl+Shift+N</kbd> |
| Go to tab 1…9 | <kbd>⌘1</kbd>…<kbd>⌘9</kbd> | <kbd>Ctrl+1</kbd>…<kbd>Ctrl+9</kbd> |
| Next / previous tab | <kbd>⌘⇧]</kbd> / <kbd>⌘⇧[</kbd>, <kbd>Ctrl+Tab</kbd> | <kbd>Ctrl+PgDn</kbd> / <kbd>Ctrl+PgUp</kbd>, <kbd>Ctrl+Tab</kbd> |
| Move tab left / right | <kbd>⌘⇧←</kbd> / <kbd>⌘⇧→</kbd> | <kbd>Ctrl+Shift+PgUp</kbd> / <kbd>Ctrl+Shift+PgDn</kbd> |
| Rename tab | <kbd>⌘R</kbd> | <kbd>Ctrl+Shift+R</kbd> |
| Split right / down | <kbd>⌘D</kbd> / <kbd>⌘⇧D</kbd> | <kbd>Ctrl+Shift+E</kbd> / <kbd>Ctrl+Shift+O</kbd> |
| Focus pane | <kbd>⌘⌥←↑↓→</kbd> | <kbd>Alt+←↑↓→</kbd> |
| Next / previous pane | <kbd>⌘]</kbd> / <kbd>⌘[</kbd> | <kbd>Ctrl+Shift+]</kbd> / <kbd>Ctrl+Shift+[</kbd> |
| Resize pane | <kbd>⌘⌃←↑↓→</kbd> | <kbd>Ctrl+Shift+Alt+←↑↓→</kbd> |
| Zoom pane / equalize | <kbd>⌘⇧↩</kbd> / <kbd>⌘⌃=</kbd> | <kbd>Ctrl+Shift+X</kbd> / <kbd>Ctrl+Shift+Alt+=</kbd> |
| Close pane | <kbd>⌘W</kbd> | <kbd>Ctrl+Shift+W</kbd> |
| Host search | <kbd>⌘K</kbd> | <kbd>Ctrl+Shift+K</kbd> |
| Jump switcher | <kbd>⌘J</kbd> | <kbd>Ctrl+Shift+J</kbd> |
| Broadcast input: all panes on / off | <kbd>⌘⇧I</kbd> | <kbd>Ctrl+Shift+I</kbd> |
| Broadcast input: this tab only | <kbd>⌘⌥I</kbd> | menu |
| Broadcast picker (presets, checkboxes) | <kbd>⌘⌥⇧I</kbd> | <kbd>Ctrl+Shift+Alt+I</kbd> |
| Copy / paste | <kbd>⌘C</kbd> / <kbd>⌘V</kbd> | <kbd>Ctrl+Shift+C</kbd> / <kbd>Ctrl+Shift+V</kbd> |

The bindings come from one table in the shared desktop core, so both apps stay in step.

[Website](https://radut.github.io/rsshterm/) · [Privacy](https://radut.github.io/rsshterm/privacy.html) ·
[Support](https://radut.github.io/rsshterm/support.html)

Every screenshot and animation here shows demo data only (example.com hosts and documentation addresses);.

### Licences and trademarks

rSshTerm and rSshD include open-source software, fonts and colour themes under their own licences: the list with the
full licence texts is in every app (Settings › About › Acknowledgements on iPhone and iPad, rSshTerm ›
Acknowledgements on the Mac, About › Legal on Linux) and in the `THIRD_PARTY_NOTICES` file of every package; it is
generated from one list in this repository (`packaging/licenses/manifest.toml`).

Apple, iPhone, iPad, Mac, macOS, iCloud, Face ID, Touch ID and App Store are trademarks of Apple Inc., registered in
the U.S. and other countries and regions. Swift is a trademark of Apple Inc. Google Drive is a trademark of Google LLC.
Ubuntu and Launchpad are trademarks of Canonical Ltd. Linux® is the registered trademark of Linus Torvalds in the U.S.
and other countries. Raspberry Pi is a trademark of Raspberry Pi Ltd. Other names are trademarks of their respective
owners; rSshTerm is not affiliated with or endorsed by any of them.
