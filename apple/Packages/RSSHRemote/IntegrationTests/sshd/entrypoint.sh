#!/bin/sh
# AUTHORIZED_KEY: the public key line that logs in as tester; TESTER_PASSWORD: tester's password.
set -eu
install -d -m 700 -o tester -g tester /home/tester/.ssh
printf '%s\n' "$AUTHORIZED_KEY" > /home/tester/.ssh/authorized_keys
chown tester:tester /home/tester/.ssh/authorized_keys
chmod 600 /home/tester/.ssh/authorized_keys
printf 'tester:%s\n' "$TESTER_PASSWORD" | chpasswd
ssh-keygen -A >/dev/null
exec /usr/sbin/sshd -D -e -o PasswordAuthentication=yes -o AllowTcpForwarding=yes
