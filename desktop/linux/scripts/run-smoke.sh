#!/bin/sh
# make test-desktop-linux-app: the app's image, unit tests and the Xvfb smoke test, with a TigerVNC container (the
# remote-desktop integration image) on a private network as screen.example.org and xrdp as rdp.example.org, with
# throwaway passwords, so the smoke test opens both screens through the app's SSH tunnel. Mock data only; everything
# is removed afterwards.
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
NET="rsshterm-smoke-$$"
VNC="$NET-vnc"
RDP="$NET-rdp"
PW="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)"
RDP_PW="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cleanup() {
    docker stop "$VNC" "$RDP" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build -q -t rsshterm-linux "$REPO/desktop/linux" >/dev/null || exit 1
docker build -q -t rsshrd-it-vnc "$REPO/apple/Packages/RSSHRemoteDesktop/test/docker/vnc" >/dev/null || exit 1
docker build -q -t rsshrd-it-xrdp "$REPO/apple/Packages/RSSHRemoteDesktop/test/docker/xrdp" >/dev/null || exit 1
docker network create "$NET" >/dev/null || exit 1
docker run -d --rm --name "$VNC" --network "$NET" --network-alias screen.example.org -e VNC_PASSWORD="$PW" \
    rsshrd-it-vnc >/dev/null || exit 1
docker run -d --rm --name "$RDP" --hostname lab-rdp --network "$NET" --network-alias rdp.example.org -e RDP_PASSWORD="$RDP_PW" \
    rsshrd-it-xrdp >/dev/null || exit 1

docker run --rm --network "$NET" --hostname workstation -v "$REPO:/src" -v "${BUILD_VOLUME:-rsshterm-linux-build}":/build \
    -w /src/desktop/linux -e SCRATCH=/build -e SHOTS=/src/docs/screens/desktop-linux \
    -e OWNER="$(id -u):$(id -g)" -e VNC_PASSWORD="$PW" -e RDP_PASSWORD="$RDP_PW" rsshterm-linux \
    sh -c 'packaging/validate.sh && swift test --scratch-path /build && scripts/smoke-test.sh'
