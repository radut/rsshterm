#!/usr/bin/env bash
# Integration tests of RSSHRemoteDesktop against real servers, all in docker on a private network:
#
#   swift test container --SSH--> sshd (OpenSSH) --TCP--> vnc (TigerVNC, VNC password)
#                                                 --TCP--> xrdp (with RDP=1: the FreeRDP spike, docs/research)
#
# Only sshd is reachable from the test container's point of view as an SSH server; the screens are reached through
# its direct-tcpip channels, the way the app reaches them. A fresh ed25519 key and VNC password are made per run
# and thrown away. Usage: apple/Packages/RSSHRemoteDesktop/test/integration.sh [--filter <regex>]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
SWIFT_IMAGE="${SWIFT_IMAGE:-swift:6.4-noble}"
RUN="rsshrd-it-$$"
NET="$RUN-net"
WORK="$(mktemp -d)"

cleanup() {
    docker rm -f "$RUN-sshd" "$RUN-vnc" "$RUN-xrdp" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -C rsshrd-it -f "$WORK/id_ed25519"
chmod 644 "$WORK/id_ed25519"   # read by the container's root; the directory itself is private and removed after
VNC_PASSWORD="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)"
RDP_PASSWORD="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
RDP_ENV=()

docker build -q -t rsshrd-it-sshd "$HERE/docker/sshd" >/dev/null
docker build -q -t rsshrd-it-vnc "$HERE/docker/vnc" >/dev/null
docker network create "$NET" >/dev/null
docker run -d --name "$RUN-sshd" --network "$NET" --network-alias sshd \
    -e AUTHORIZED_KEY="$(cat "$WORK/id_ed25519.pub")" rsshrd-it-sshd >/dev/null
docker run -d --name "$RUN-vnc" --network "$NET" --network-alias vnc -e VNC_PASSWORD="$VNC_PASSWORD" \
    rsshrd-it-vnc >/dev/null
if [ "${RDP:-0}" = 1 ]; then
    docker build -q -t rsshrd-it-xrdp "$HERE/docker/xrdp" >/dev/null
    docker run -d --name "$RUN-xrdp" --network "$NET" --network-alias xrdp -e RDP_PASSWORD="$RDP_PASSWORD" \
        rsshrd-it-xrdp >/dev/null
    RDP_ENV=(-e RSSH_RD_IT_RDP_HOST=xrdp -e RSSH_RD_IT_RDP_PORT=3389 -e RSSH_RD_IT_RDP_USER=rdp
             -e RSSH_RD_IT_RDP_PASSWORD="$RDP_PASSWORD" -e RSSH_RD_IT_RDP_GRAB=/tmp/grab)
fi

# zlib for RoyalVNCKit; the build cache stays in a docker volume.
docker run --rm --network "$NET" \
    -v "$REPO:/src" -v rsshrd-it-build:/build -v rsshrdp-it-build:/build-rdp -v "$WORK:/it:ro" \
    -e RSSH_RD_IT_SSH_HOST=sshd -e RSSH_RD_IT_SSH_PORT=22 -e RSSH_RD_IT_SSH_USER=tunnel \
    -e RSSH_RD_IT_SSH_KEY=/it/id_ed25519 \
    -e RSSH_RD_IT_VNC_HOST=vnc -e RSSH_RD_IT_VNC_PORT=5900 -e RSSH_RD_IT_VNC_PASSWORD="$VNC_PASSWORD" \
    "${RDP_ENV[@]}" \
    -w /src/apple/Packages/RSSHRemoteDesktop "$SWIFT_IMAGE" bash -c '
      apt-get -qq update >/dev/null && apt-get -qq install -y zlib1g-dev >/dev/null
      # The FreeRDP spike binary, built against noble'"'"'s libfreerdp3.
      if [ -n "${RSSH_RD_IT_RDP_GRAB:-}" ]; then spikes/freerdp-grab/build.sh /tmp/grab >/tmp/grab-build.log 2>&1 || { tail -20 /tmp/grab-build.log; exit 1; }; fi
      # sshd and Xvnc start in a second or two; wait for both before the tests.
      for i in $(seq 1 30); do
        (exec 3<>/dev/tcp/sshd/22) 2>/dev/null && (exec 3<>/dev/tcp/vnc/5900) 2>/dev/null \
          && { [ -z "${RSSH_RD_IT_RDP_HOST:-}" ] || (exec 3<>/dev/tcp/xrdp/3389) 2>/dev/null; } && break; sleep 1
      done
      swift test --scratch-path /build "$@" || exit 1
      # RDP=1: RSSHRDP (libfreerdp3) through the same tunnel to xrdp.
      if [ -n "${RSSH_RD_IT_RDP_HOST:-}" ]; then
        apt-get -qq install -y freerdp3-dev >/dev/null
        cd ../RSSHRDP && swift test --scratch-path /build-rdp "$@"
      fi' bash "$@"
