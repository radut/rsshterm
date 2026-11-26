#!/bin/sh
# End-to-end smoke test of rsshterm under Xvfb, run inside the image from ../Dockerfile (make test-desktop-linux-app):
#   1. the sample vault (mock data: example.com hosts, users you/deploy/ci; Web Prod 1 is this container's sshd) is
#      imported with a master password;
#   2. rsshterm opens it with the device key, starts the agent and writes ssh_config;
#   3. keys typed with xdotool: Ctrl+Shift+T (new tab), Ctrl+Shift+E (split right), `echo ok`; output read back;
#   4. Ctrl+Shift+K host search, Enter: an SSH tab runs `ssh web-prod-1` through the agent; a remote echo comes back;
#   5. Keys and Preferences dialogs open (over D-Bus actions);
#   6. a refused login (Old Login as admin): the bar offers another login, ubuntu + the vault key works, Save stores it;
#   7. a new device (no device key): the master password prompt unlocks the vault.
# Screenshots go to $SHOTS (default ./out/screens). Exit 0 only when every step passed.
set -eu
cd "$(dirname "$0")/.."
SCRATCH="${SCRATCH:-/tmp/rsshterm-build}"
SHOTS="${SHOTS:-$PWD/out/screens}"
mkdir -p "$SHOTS"

W=/tmp/rsshterm-smoke
PASSWORD="smoke-test-master-password"

# Mock data only (screenshots end up in the repository): the desktop user is "you" on host "workstation" (docker
# --hostname), servers are *.example.com / *.example.org, the SSH login is "deploy" on this container's own sshd.
if [ "${SMOKE_PHASE:-}" != user ]; then
    echo "== build"
    swift build -c release --product rsshterm --scratch-path "$SCRATCH" 2>&1 | tail -1
    BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/rsshterm"
    "$BIN" --version

    echo "== demo users, sshd for deploy@web1.example.com:2222"
    uid="$(echo "${OWNER:-1000:1000}" | cut -d: -f1)"
    existing="$(getent passwd "$uid" | cut -d: -f1 || true)"
    if [ -n "$existing" ] && [ "$existing" != you ]; then
        usermod -l you -d /home/you -m -s /bin/bash "$existing"
    elif [ -z "$existing" ]; then
        useradd -m -u "$uid" -s /bin/bash you
    fi
    id deploy >/dev/null 2>&1 || useradd -m -s /bin/sh deploy
    passwd -d deploy >/dev/null 2>&1 || true
    grep -q web1.example.com /etc/hosts || echo "127.0.0.1 web1.example.com old.example.com" >> /etc/hosts
    # "Old Login" logs in as admin, which this sshd refuses; ubuntu has the vault key (Try Another Login).
    id ubuntu >/dev/null 2>&1 || useradd -m -N -s /bin/sh ubuntu
    passwd -d ubuntu >/dev/null 2>&1 || true
    mkdir -p "$W/run" && chown you "$W" "$W/run" && chmod 700 "$W/run"
    # The screenshots are taken as "you": in CI the checkout (and so $SHOTS) belongs to root, not to OWNER.
    chown -R you "$SHOTS"
    runuser -u you -- ssh-keygen -q -t ed25519 -N '' -C you@workstation -f "$W/key"
    for u in deploy ubuntu; do
        mkdir -p /home/$u/.ssh && cp "$W/key.pub" /home/$u/.ssh/authorized_keys
        chown -R $u /home/$u/.ssh && chmod 700 /home/$u/.ssh && chmod 600 /home/$u/.ssh/authorized_keys
    done
    ssh-keygen -A >/dev/null
    # The sshd's host keys, pinned in the sample vault (the file manager's SFTP checks them, as ssh does).
    KNOWN_HOSTS=""
    for t in ed25519 ecdsa rsa; do
        fp="$(ssh-keygen -lf /etc/ssh/ssh_host_${t}_key.pub | awk '{print $2}')"
        case $t in ed25519) kt=ssh-ed25519 ;; ecdsa) kt=ecdsa-sha2-nistp256 ;; rsa) kt=ssh-rsa ;; esac
        KNOWN_HOSTS="$KNOWN_HOSTS${KNOWN_HOSTS:+,}{\"host\":\"web1.example.com\",\"port\":2222,\"keyType\":\"$kt\",\"fingerprint\":\"$fp\"}"
    done
    mkdir -p /run/sshd
    /usr/sbin/sshd -p 2222 -o ListenAddress=127.0.0.1 -o PasswordAuthentication=no -o UsePAM=no -o PrintLastLog=no -o PrintMotd=no
    exec runuser -u you -- env -i PATH="$PATH" HOME=/home/you USER=you LOGNAME=you SHELL=/bin/bash LANG=C.UTF-8 \
        GTK_A11Y=none GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1 GDK_BACKEND=x11 \
        SMOKE_PHASE=user RSSHTERM_TEST_LOGIN_USER=ubuntu BIN="$BIN" SHOTS="$SHOTS" KNOWN_HOSTS="$KNOWN_HOSTS" VNC_PASSWORD="${VNC_PASSWORD:-}" RDP_PASSWORD="${RDP_PASSWORD:-}" sh "$0"
fi

# From here on as "you" ($SHOTS was handed to it above).
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
export XDG_RUNTIME_DIR="$W/run" XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
export RSSHTERM_NO_UPDATE_CHECK=1 RSSHTERM_TEST_STATE="$W/state.json"
STATE="$W/state.json"

echo "== vault import (sample vault)"
PEM="$(awk '{printf "%s\\n", $0}' "$W/key")"
KEY_ID=6F2D3A52-9C4B-4E0B-8F3A-1D2C3B4A5E60
cat > "$W/seed.json" <<JSON
{"version":1,"groups":[{"id":"7A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D","name":"Production"}],"knownHosts":[$KNOWN_HOSTS],
 "credentials":[{"id":"$KEY_ID","label":"laptop key","kind":{"privateKey":{"pem":"$PEM"}}}],
 "servers":[{"id":"0B7E4C1A-2D3F-4A5B-9C8D-7E6F5A4B3C2D","name":"Web Prod 1","host":"web1.example.com","port":2222,
             "username":"deploy","credentialID":"$KEY_ID","groupID":"7A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"},
            {"id":"1C8F5D2B-3E4A-4B6C-8D9E-8F7A6B5C4D3E","name":"Backup NAS","host":"nas.example.org","port":22,
             "username":"admin"},
            {"id":"2D9A6E3C-4F5B-4C7D-9E0F-9A8B7C6D5E4F","name":"CI Runner","host":"ci.example.com","port":22,
             "username":"ci"},
            {"id":"5A2D9B6F-7C8E-4FA0-9B3C-2D1E0F9A8B7C","name":"Old Login","host":"old.example.com","port":2222,
             "username":"admin","credentialID":"$KEY_ID"}],
 "remoteDesktops":[{"id":"3E0B7F4D-5A6C-4D8E-9F1A-0B9C8D7E6F5A","name":"Lab Screen","kind":"vnc",
             "host":"screen.example.org","port":5900,"transport":"sshShared",
             "tunnelServerID":"0B7E4C1A-2D3F-4A5B-9C8D-7E6F5A4B3C2D","groupID":"7A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"},
            {"id":"4F1C8A5E-6B7D-4E9F-8A2B-1C0D9E8F7A6B","name":"Lab RDP","kind":"rdp","username":"rdp",
             "host":"rdp.example.org","port":3389,"transport":"sshShared",
             "tunnelServerID":"0B7E4C1A-2D3F-4A5B-9C8D-7E6F5A4B3C2D","groupID":"7A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"}]}
JSON
RSSH_MASTER_PASSWORD="$PASSWORD" "$BIN" vault import "$W/seed.json" 2>&1 | grep -v "No keyring"
rm -f "$W/seed.json"
# The Include is already there (so tabs run plain `ssh <alias>` and no first-run question pops up).
printf 'Include ~/.config/rssh/ssh_config\nHost *\n    StrictHostKeyChecking accept-new\n\nHost staging\n    HostName staging.example.org\n    User deploy\n    ProxyJump web1.example.com\n' > "$HOME/.ssh/config"
printf 'Release notes for the demo.\n' > "$HOME/notes.txt"
chmod 600 "$HOME/.ssh/config"

echo "== display"
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
XVFB=$!
export DISPLAY=:99
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done 2>/dev/null || true
eval "$(dbus-launch --sh-syntax)"

fail() { echo "FAIL: $*"; import -window root "$SHOTS/../fail.png" 2>/dev/null || true; [ -f "$STATE" ] && cat "$STATE"; echo; grep -v "^0x" "$W/app.log" | head -60; kill "$APP" 2>/dev/null || true; kill "$XVFB" 2>/dev/null || true; exit 1; }

# wait_for <description> <grep -E pattern on the state file> [seconds]
wait_for() {
    i=0
    while [ $i -lt $((${3:-15} * 10)) ]; do
        [ -f "$STATE" ] && grep -Eq "$2" "$STATE" && { echo "ok: $1"; return 0; }
        sleep 0.1; i=$((i + 1))
    done
    fail "$1 (no match for $2)"
}

shot() {
    sleep 0.6
    # The visible top-level window's geometry, then a crop of the root window (no window manager here).
    wid="$(xdotool search --onlyvisible --name "${2:-rSshTerm\$}" | head -1)"
    geo="$(xdotool getwindowgeometry --shell "$wid")"
    eval "$geo"
    import -window root -crop "${WIDTH}x${HEIGHT}+${X}+${Y}" +repage "$SHOTS/$1.png" && echo "screenshot: $1.png"
}

keys() { xdotool key --clearmodifiers "$@"; sleep 0.4; }
typeline() { xdotool type --delay 40 "$1"; xdotool key Return; }
action() { gdbus call --session --dest dev.rsshterm.RSSHTerm --object-path /dev/rsshterm/RSSHTerm \
             --method org.gtk.Actions.Activate "$1" '[]' '{}' >/dev/null; }

start_app() {
    rm -f "$STATE"
    "$BIN" >"$W/app.log" 2>&1 &
    APP=$!
    wait_for "window open" '"tabs":[1-9]' 20
    xdotool search --sync --name 'rSshTerm$' windowfocus >/dev/null 2>&1 || true
    sleep 0.5
}

echo "== run 1: this device"
start_app
wait_for "vault opened with the device key" '"vault":"opened"'
grep -q 'Host web-prod-1' "$XDG_CONFIG_HOME/rssh/ssh_config" || fail "ssh_config has no web-prod-1"
SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/rssh/agent.sock" ssh-add -l | grep -q 'you@workstation' || fail "agent does not list the vault key"
echo "ok: agent lists the vault key"

keys ctrl+shift+t
wait_for "Ctrl+Shift+T opened a second tab" '"tabs":2'
keys ctrl+shift+e
wait_for "Ctrl+Shift+E split the tab" '"panes":\[1,2\]'
sleep 1
typeline 'echo ok'
wait_for "echo ok ran in the split pane" '"focusedText":"[^"]*\\nok\\n'
typeline 'echo "agent=$SSH_AUTH_SOCK term=$TERM_PROGRAM"'
wait_for "tab environment has the agent and TERM_PROGRAM" 'agent=[^ ]*agent.sock term=rSshTerm\\n'
shot main-split
keys ctrl+1
wait_for "Ctrl+1 selected tab 1" '"selected":0'
keys ctrl+2
wait_for "Ctrl+2 selected tab 2" '"selected":1'

keys ctrl+shift+k
sleep 0.5
xdotool type --delay 60 "web"
shot host-search
keys Return
wait_for "host search opened an SSH tab" '"tabs":3'
wait_for "ssh logged in through the agent" '"focusedText":"[^"]*\$ ' 20
typeline 'echo remote-$((40+2)) $(whoami)'
wait_for "remote shell answered" 'remote-42 deploy\\n' 15
wait_for "the SSH tab is titled by its server, user@host under it" '"tabSubtitles":\[[^]]*"deploy@web1.example.com' 10
wait_for "the window title joins both lines" '"windowTitle":"Web Prod 1 — deploy@web1.example.com' 10
shot ssh-tab

action files-here
wait_for "Open File Manager Here: SFTP to the SSH tab's server" '"place":"Web Prod 1"' 30
wait_for "the server's home folder is listed" '"path":"\\/home\\/deploy"' 30
xdotool search --sync --onlyvisible --name '^Files$' windowfocus >/dev/null 2>&1 || true
sleep 0.5
keys Tab
keys Down
keys F5
wait_for "F5 copied notes.txt from this computer to the server" '"completed":1' 30
wait_for "the server pane lists the copy" '"left":\{"error":"","items":\["notes.txt"\]' 15
shot files-commander '^Files$'
xdotool search --onlyvisible --name '^Files$' windowunmap >/dev/null 2>&1 || true
xdotool search --onlyvisible --name 'rSshTerm$' windowfocus >/dev/null 2>&1 || true
sleep 0.5
wait_for "the sidebar lists the sample servers" '"sidebarServers":4'

action new-server
shot server-editor
keys Escape
action new-remote-desktop
shot remote-desktop-editor
keys Escape

if [ -n "${VNC_PASSWORD:-}" ]; then
    # The sample vault's "Lab Screen" (TigerVNC as screen.example.org) through Web Prod 1's SSH: no saved password,
    # so the login sheet asks; the typed one is saved once the screen opens.
    action open-first-remote-desktop
    sleep 2
    shot remote-desktop-login
    xdotool type --delay 40 "$VNC_PASSWORD"
    keys Return
    wait_for "the VNC screen opened through the SSH tunnel" '"screens":\["connected 800x600"\]' 40
    sleep 1
    shot remote-desktop
    keys ctrl+alt
    keys ctrl+shift+w
    wait_for "the screen pane closed" '"screens":\[\]' 10
else
    echo "skip: no VNC container (VNC_PASSWORD unset)"
fi

if [ -n "${RDP_PASSWORD:-}" ]; then
    # "Lab RDP" (xrdp as rdp.example.org) through the same sshd: the login sheet (user from the entry), then the
    # certificate question of the first connect (trusted: pinned in the entry), then the screen.
    action open-last-remote-desktop
    sleep 2
    xdotool type --delay 30 "$RDP_PASSWORD"
    keys Return
    wait_for "the RDP certificate is asked about on the first connect" '"screens":\["certificate-question"\]' 40
    sleep 1
    shot rdp-certificate
    keys Return
    wait_for "the RDP screen opened through the SSH tunnel with the pinned certificate" '"screens":\["connected [0-9]+x[0-9]+"\]' 60
    sleep 4
    shot remote-desktop-rdp
    keys ctrl+alt
    keys ctrl+shift+w
    wait_for "the RDP pane closed" '"screens":\[\]' 10
else
    echo "skip: no xrdp container (RDP_PASSWORD unset)"
fi
action import-ssh-config
shot import-ssh-config
keys Escape
action quick-connect
sleep 0.5
xdotool type --delay 40 "ci@ci.example.com"
keys Return
shot quick-connect
keys Escape

keys ctrl+shift+r
xdotool key ctrl+a
xdotool type --delay 40 "build box"
keys Return
wait_for "Ctrl+Shift+R renamed the tab" '"tabTitles":\[[^]]*"build box"'
keys ctrl+1
wait_for "back on tab 1" '"selected":0'
keys ctrl+shift+j
xdotool type --delay 60 "web1"
shot jump-switcher
keys Return
wait_for "Ctrl+Shift+J jumped to the SSH pane" '"selected":2'

keys ctrl+2
wait_for "on the split tab" '"selected":1'
keys ctrl+shift+i
wait_for "Ctrl+Shift+I broadcasts to all tabs" '"broadcast":"allTabs"'
typeline 'echo bc-$((6*7))'
# focusedText + both entries of "texts": three outputs when the other pane got the input too
i=0; while [ "$(grep -o 'bc-42\\n' "$STATE" | wc -l)" -lt 3 ]; do i=$((i+1)); [ $i -gt 100 ] && fail "broadcast did not reach the other pane"; sleep 0.1; done
echo "ok: both panes of the split got the broadcast"
shot broadcast
keys ctrl+shift+alt+i
shot broadcast-picker
keys Escape
keys ctrl+shift+i
wait_for "Ctrl+Shift+I again: current pane only" '"broadcast":"currentOnly"'

action keys
shot keys
keys Escape
action preferences
shot preferences
keys Escape
action tab-titles
shot tab-titles
keys Escape
action check-updates
sleep 1
keys Escape

echo "== another login after a refused one"
keys ctrl+shift+k
sleep 0.5
xdotool type --delay 60 "old login"
keys Return
wait_for "the refused login offers another" '"loginBars":\["The server refused the login' 20
shot login-refused
# RSSHTERM_TEST_LOGIN_USER answers the picker (ubuntu + the vault key) three seconds after it opens.
action try-another-login
sleep 1
shot login-picker
wait_for "ubuntu with the vault key logged in; Save is offered" '"loginBars":\["Save ubuntu \+ key laptop key for Old Login\?"' 30
wait_for "the same tab runs the new login" 'Connecting again' 5
shot login-save
action save-login
wait_for "Save stored ubuntu on the server" '"serverUsers":\[[^]]*"ubuntu"' 15
keys ctrl+shift+w
wait_for "the Old Login tab closed" '"tabs":3' 10

keys ctrl+1
wait_for "tab 1 again" '"selected":0'
typeline 'sleep 4'
wait_for "the subtitle shows the running command (foreground process)" '"tabSubtitles":\["[^"]*sleep 4' 4
sleep 4
typeline 'cd /tmp'
sleep 6 # the session is saved every 5 s (directories) and a second after a layout change
grep -q '"directory":"/tmp"' "$XDG_STATE_HOME/rssh/session.json" || fail "session did not record /tmp"
echo "ok: session saved with the shell's directory"
kill "$APP"; wait "$APP" 2>/dev/null || true

echo "== run 2: a new device (no device key)"
rm -rf "$XDG_DATA_HOME/rssh/secrets"
start_app
wait_for "new device asks for the master password" '"vault":"locked"'
wait_for "session restored: 3 tabs, the renamed one included" '"tabTitles":\[[^]]*"build box"'
wait_for "restored local tab opened in /tmp" '"focusedText":"[^"]*:\\/tmp\$ '
shot unlock
xdotool type --delay 30 "$PASSWORD"
keys Return
wait_for "master password unlocked the vault" '"vault":"opened"' 30
keys ctrl+3
wait_for "restored SSH tab logged in after the unlock" '"focusedText":"[^"]*\$ ' 20
shot unlocked
kill "$APP"; wait "$APP" 2>/dev/null || true

echo "== run 3: the new device opens with its own key"
start_app
wait_for "opened without a password" '"vault":"opened"'
kill "$APP"; wait "$APP" 2>/dev/null || true
kill "$XVFB" 2>/dev/null || true
echo "PASS: rsshterm tabs, split, local and SSH terminals, host search, jump, rename, broadcast, keys, preferences, unlock, session restore"
