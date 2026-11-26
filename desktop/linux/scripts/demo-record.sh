#!/bin/sh
# Records the README/site demos of rsshterm under Xvfb, inside the image from ../Dockerfile.demo (make site-media-linux).
# Demo data only: a vault with example.com servers; web1.example.com is this container's own sshd (/etc/hosts).
# Clips (MP4, cropped to the window) and stills go to $OUT (default ./out/demo):
#   splits     Ctrl+Shift+E / Ctrl+Shift+O splits, Alt+arrows, broadcast input on and off (Ctrl+Shift+I)
#   search     Ctrl+Shift+K host search -> an SSH tab that logs in with the vault key through the built-in agent
#   jump       Ctrl+1..9 between tabs, Ctrl+Shift+J jump switcher
set -eu
cd "$(dirname "$0")/.."
SCRATCH="${SCRATCH:-/tmp/rsshterm-build}"
OUT="${OUT:-$PWD/out/demo}"
mkdir -p "$OUT"

command -v ffmpeg >/dev/null || { echo "ffmpeg missing: run it through make site-media-linux" >&2; exit 1; }

echo "== build"
swift build -c release --product rsshterm --scratch-path "$SCRATCH" 2>&1 | tail -1
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/rsshterm"

W=/tmp/rsshterm-demo
mkdir -p "$W/run" "$HOME/.ssh" "$HOME/projects/api" "$HOME/projects/site"
chmod 700 "$W/run" "$HOME/.ssh"
export XDG_RUNTIME_DIR="$W/run" XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export RSSHTERM_NO_UPDATE_CHECK=1 RSSHTERM_TEST_STATE="$W/state.json" SHELL=/bin/bash
STATE="$W/state.json"

# Prompts that read like a laptop and a server, not a container.
cat > "$HOME/.bashrc" <<'RC'
PS1='\[\e[1;32m\]dev@laptop\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]$ '
cd ~/projects 2>/dev/null
RC
cp "$HOME/.bashrc" "$HOME/.bash_profile"
touch "$HOME/projects/README.md" "$HOME/projects/Makefile"

echo "== sshd: web1.example.com -> 127.0.0.1:2222, user deploy"
grep -q web1.example.com /etc/hosts || echo "127.0.0.1 web1.example.com" >> /etc/hosts
id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy
passwd -d deploy >/dev/null 2>&1 || true
printf '%s\n' "PS1='\\[\\e[1;33m\\]deploy@web1\\[\\e[0m\\]:\\[\\e[1;34m\\]\\w\\[\\e[0m\\]\$ '" > /home/deploy/.bashrc
cp /home/deploy/.bashrc /home/deploy/.bash_profile
mkdir -p /home/deploy/app/releases /home/deploy/app/logs
ssh-keygen -q -t ed25519 -N '' -C laptop@rsshterm -f "$W/key"
mkdir -p /home/deploy/.ssh && cp "$W/key.pub" /home/deploy/.ssh/authorized_keys
chown -R deploy /home/deploy && chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys
ssh-keygen -A >/dev/null
mkdir -p /run/sshd
/usr/sbin/sshd -p 2222 -o ListenAddress=127.0.0.1 -o PasswordAuthentication=no -o UsePAM=no -o PrintMotd=no

echo "== demo vault"
PEM="$(awk '{printf "%s\\n", $0}' "$W/key")"
KEY_ID=6F2D3A52-9C4B-4E0B-8F3A-1D2C3B4A5E60
cat > "$W/seed.json" <<JSON
{"version":1,"groups":[],"knownHosts":[],
 "credentials":[{"id":"$KEY_ID","label":"laptop key","kind":{"privateKey":{"pem":"$PEM"}}}],
 "servers":[{"id":"0B7E4C1A-2D3F-4A5B-9C8D-7E6F5A4B3C2D","name":"Web 1","host":"web1.example.com","port":2222,
             "username":"deploy","credentialID":"$KEY_ID"},
            {"id":"1C8F5D2B-3E4A-4B6C-8D9E-8F7A6B5C4D3E","name":"Backup NAS","host":"nas.example.com","port":22,
             "username":"admin"},
            {"id":"3E0B7F4D-5A6C-4D8E-0F1A-0B9C8D7E6F5A","name":"Database","host":"db.example.com","port":22,
             "username":"postgres"},
            {"id":"2D9A6E3C-4F5B-4C7D-9E0F-9A8B7C6D5E4F","name":"Web 2","host":"web2.example.com","port":22,
             "username":"deploy"}]}
JSON
RSSH_MASTER_PASSWORD="demo-master-password" "$BIN" vault import "$W/seed.json" 2>&1 | grep -v "No keyring" || true
rm -f "$W/seed.json"
printf 'Include ~/.config/rssh/ssh_config\nHost *\n    StrictHostKeyChecking accept-new\n' > "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

echo "== display"
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
XVFB=$!
export DISPLAY=:99
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done 2>/dev/null || true
eval "$(dbus-launch --sh-syntax)"

fail() { echo "FAIL: $*"; tail -20 "$W/app.log"; kill "$XVFB" 2>/dev/null || true; exit 1; }
wait_for() {
    i=0
    while [ $i -lt $((${3:-15} * 10)) ]; do
        [ -f "$STATE" ] && grep -Eq "$2" "$STATE" && return 0
        sleep 0.1; i=$((i + 1))
    done
    fail "$1 (no match for $2)"
}
keys() { xdotool key --clearmodifiers "$@"; sleep 0.7; }
typeline() { xdotool type --delay 70 "$1"; sleep 0.2; xdotool key Return; sleep 0.8; }

geometry() {
    wid="$(xdotool search --onlyvisible --name '^rSshTerm' | head -1)"
    eval "$(xdotool getwindowgeometry --shell "$wid")"
    # even sizes for x264
    CROP="$((WIDTH / 2 * 2))x$((HEIGHT / 2 * 2))+${X}+${Y}"
}
REC=""
record() { # record <name>
    geometry
    w=${CROP%%x*}; rest=${CROP#*x}; h=${rest%%+*}; off=${rest#*+}; x=${off%%+*}; y=${off#*+}
    ffmpeg -loglevel error -y -f x11grab -framerate 20 -video_size "${w}x${h}" -i ":99.0+${x},${y}" \
        -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p "$OUT/$1.mp4" &
    REC=$!
    sleep 1
}
stop() { sleep 1.2; kill -INT "$REC"; wait "$REC" 2>/dev/null || true; echo "clip: $1.mp4"; }
still() { geometry; import -window root -crop "$CROP" +repage "$OUT/$1.png" && echo "still: $1.png"; }

rm -f "$STATE"
"$BIN" >"$W/app.log" 2>&1 &
APP=$!
wait_for "window open" '"tabs":1' 30
wait_for "vault opened" '"vault":"opened"' 30
xdotool search --sync --name '^rSshTerm' windowfocus >/dev/null 2>&1 || true
xdotool mousemove 1279 799   # the pointer out of the window
sleep 1.5

echo "== clip: splits + broadcast"
record splits
typeline 'ls'
keys ctrl+shift+e
wait_for "split right" '"panes":\[2\]'
typeline 'cd api && git status -sb 2>/dev/null || echo "api: clean"'
keys ctrl+shift+o
wait_for "split down" '"panes":\[3\]'
typeline 'echo "third pane"'
keys alt+Left
keys ctrl+shift+i
wait_for "broadcast on" '"broadcast":"allTabs"'
typeline 'echo typed once, runs in every pane'
still splits-broadcast
keys ctrl+shift+i
wait_for "broadcast off" '"broadcast":"currentOnly"'
sleep 2.5
stop splits

echo "== clip: host search -> SSH tab"
record search
keys ctrl+shift+k
xdotool type --delay 120 "web"
sleep 1
still host-search
keys Return
wait_for "ssh tab" '"tabs":2'
wait_for "ssh logged in" '"focusedText":"[^"]*deploy@web1' 20
sleep 0.5
typeline 'ls app'
still ssh-tab
stop search

echo "== clip: tabs + jump switcher"
keys ctrl+shift+t
wait_for "third tab" '"tabs":3'
typeline 'echo "tab 3"'
record jump
keys ctrl+1
keys ctrl+2
keys ctrl+3
keys ctrl+shift+j
xdotool type --delay 120 "web1"
sleep 1
still jump-switcher
keys Return
wait_for "jumped" '"selected":1'
sleep 0.8
stop jump

kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null || true
kill "$XVFB" 2>/dev/null || true
if [ -n "${OWNER:-}" ]; then chown -R "$OWNER" "$OUT"; fi
echo "DEMO OK"
