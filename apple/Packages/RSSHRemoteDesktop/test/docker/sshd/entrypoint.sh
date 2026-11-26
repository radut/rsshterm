#!/bin/sh
# The public key arrives in $AUTHORIZED_KEY (generated per run by integration.sh; it logs in nowhere else).
set -eu
printf '%s\n' "$AUTHORIZED_KEY" > /home/tunnel/.ssh/authorized_keys
chown tunnel:tunnel /home/tunnel/.ssh/authorized_keys
chmod 600 /home/tunnel/.ssh/authorized_keys
ssh-keygen -A >/dev/null
exec /usr/sbin/sshd -D -e
