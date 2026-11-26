# OpenSSH server for the tunnel tests: user "tunnel", key login only, TCP forwarding on (the default).
FROM ubuntu:24.04
RUN apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash tunnel && passwd -l tunnel \
    && mkdir -p /run/sshd /home/tunnel/.ssh && chmod 700 /home/tunnel/.ssh && chown tunnel:tunnel /home/tunnel/.ssh \
    && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nAllowTcpForwarding yes\nLogLevel VERBOSE\n' \
       > /etc/ssh/sshd_config.d/tunnel.conf
COPY entrypoint.sh /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
