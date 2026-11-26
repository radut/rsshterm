# One OpenSSH server for the jump host integration test: users "jump" and "target", password logins. The passwords
# come from the environment at start (fresh per run, from run.sh), so the image holds none; host keys are made at
# start too, so every container is its own machine.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server \
 && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd \
 && useradd -m -s /bin/bash jump && useradd -m -s /bin/bash target \
 && rm -f /etc/ssh/ssh_host_* \
 && printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication no\nAllowTcpForwarding yes\n' > /etc/ssh/sshd_config.d/it.conf
EXPOSE 22
CMD ["/bin/sh", "-c", "printf 'jump:%s\\ntarget:%s\\n' \"$JUMP_PASSWORD\" \"$TARGET_PASSWORD\" | chpasswd && ssh-keygen -A && exec /usr/sbin/sshd -D -e"]
