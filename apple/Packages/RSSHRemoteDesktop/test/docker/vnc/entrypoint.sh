#!/bin/sh
# $VNC_PASSWORD is a throwaway per-run password from integration.sh.
set -eu
printf '%s\n' "$VNC_PASSWORD" | vncpasswd -f > /tmp/passwd
chmod 600 /tmp/passwd
Xvnc :1 -geometry 800x600 -depth 24 -rfbport 5900 -SecurityTypes VncAuth -PasswordFile /tmp/passwd \
     -localhost=0 -AlwaysShared -BlacklistThreshold=10000 &
# (Every connection arrives from sshd's address; the tests abort handshakes on purpose, which TigerVNC would
# otherwise blacklist after 5.)
sleep 1
# A new clipboard owner every 2 s, so Xvnc keeps sending the text to connected clients (ServerCutText).
( while true; do printf 'rSshTerm VNC clipboard' | DISPLAY=:1 timeout 2 xclip -quiet -selection clipboard || true; done ) \
  >/dev/null 2>&1 &
DISPLAY=:1 xterm -geometry 80x24+10+10 -e sh -c 'echo rSshTerm VNC test; sleep infinity' &
wait
