#!/usr/bin/env bash
# RSSHRDP on Apple (FreeRDP.xcframework) against a real xrdp, through a real OpenSSH tunnel:
#
#   this machine (docker)                         the Mac (no docker there)
#   ┌ sshd ──private net── xrdp ┐   <──SSH──      swift test (macOS slice)
#   └ on 127.0.0.1:port ────────┘ ssh -R to the   xcodebuild test on the iOS simulator (SIM=1, simulator slice)
#                                 Mac's 127.0.0.1
#
# The same tests as RDP=1 test/integration.sh on Linux (RDPIntegrationTests: certificate refused then pinned,
# frames, typing, server clipboard). Only sshd is published, key login only, with a throwaway key and password;
# xrdp stays on the private docker network and is reached through the tunnel, the way the app reaches it.
#
#   apple/Packages/RSSHRDP/test/apple-integration.sh
#     MAC_HOST=<user>@<mac>         the Mac (ssh, BatchMode; required: make test-rdp-apple-it passes the Makefile's)
#     MAC_DIR=~/git/projects/apple/rSSH   the checkout there to test (must hold FreeRDP.xcframework: fetch.sh)
#     RIG_HOST=<this machine's address as the Mac sees it>: connect there instead of through the reverse forward
#                                   (needs the published port open in this machine's firewall)
#     FILTER_TESTS=<regex>          only these tests (swift test --filter)
#     UI=1                          also the app's RDPViewerUITests on the simulator (direct to xrdp: a second
#                                   forward to the xrdp container); screenshots to SHOTS_OUT (default ./rdp-shots)
#     SIM=1                         also run the tests on the iOS simulator (SIM_NAME, SIM_OS as apple/Makefile)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="$HERE/../../RSSHRemoteDesktop/test/docker"
MAC_HOST="${MAC_HOST:?set MAC_HOST=<user>@<mac>, or run make test-rdp-apple-it}"
MAC_DIR="${MAC_DIR:-~/git/projects/apple/rSSH}"
RIG_HOST="${RIG_HOST:-}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$MAC_HOST")
RUN="rsshrdp-apple-it-$$"
NET="$RUN-net"
WORK="$(mktemp -d)"
MAC_KEY="/tmp/$RUN.key"

FORWARD_PID=""
UI_FORWARD_PID=""
cleanup() {
    [ -n "$FORWARD_PID" ] && kill "$FORWARD_PID" 2>/dev/null
    [ -n "$UI_FORWARD_PID" ] && kill "$UI_FORWARD_PID" 2>/dev/null
    docker rm -f "$RUN-sshd" "$RUN-xrdp" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    "${SSH[@]}" "rm -f $MAC_KEY" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -C rsshrdp-apple-it -f "$WORK/id_ed25519"
RDP_PASSWORD="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

docker build -q -t rsshrd-it-sshd "$DOCKER/sshd" >/dev/null
docker build -q -t rsshrd-it-xrdp "$DOCKER/xrdp" >/dev/null
docker network create "$NET" >/dev/null
docker run -d --name "$RUN-sshd" --network "$NET" -p 127.0.0.1:0:22 \
    -e AUTHORIZED_KEY="$(cat "$WORK/id_ed25519.pub")" rsshrd-it-sshd >/dev/null
docker run -d --name "$RUN-xrdp" --network "$NET" --network-alias xrdp -e RDP_PASSWORD="$RDP_PASSWORD" \
    rsshrd-it-xrdp >/dev/null
SSH_PORT="$(docker port "$RUN-sshd" 22/tcp | head -n1 | sed 's/.*://')"
for _ in $(seq 1 30); do
    docker exec "$RUN-xrdp" sh -c 'exec 3<>/dev/tcp/127.0.0.1/3389' 2>/dev/null && break
    sleep 1
done
if [ -z "$RIG_HOST" ]; then
    # The Mac's 127.0.0.1:<port> leads to the rig's sshd, over this machine's ssh login to the Mac.
    LOCAL_PORT="$SSH_PORT"
    SSH_PORT=$((20000 + RANDOM % 20000))
    ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -N -R "127.0.0.1:$SSH_PORT:127.0.0.1:$LOCAL_PORT" "$MAC_HOST" &
    FORWARD_PID=$!
    RIG_HOST=127.0.0.1
    for _ in $(seq 1 20); do "${SSH[@]}" "nc -z 127.0.0.1 $SSH_PORT" 2>/dev/null && break; sleep 0.5; done
fi
echo "==> rig: sshd on $RIG_HOST:$SSH_PORT (as the Mac sees it), xrdp behind it"

"${SSH[@]}" "umask 077 && cat > $MAC_KEY" <"$WORK/id_ed25519"

VARS="RSSH_RD_IT_SSH_HOST=$RIG_HOST RSSH_RD_IT_SSH_PORT=$SSH_PORT RSSH_RD_IT_SSH_USER=tunnel RSSH_RD_IT_SSH_KEY=$MAC_KEY \
RSSH_RD_IT_RDP_HOST=xrdp RSSH_RD_IT_RDP_PORT=3389 RSSH_RD_IT_RDP_USER=rdp RSSH_RD_IT_RDP_PASSWORD=$RDP_PASSWORD \
WLOG_LEVEL=${WLOG_LEVEL:-ERROR}"
# The test lines and the issues, without the build chatter.
FILTER="grep -aE '${EXTRA_GREP:-✔}|✔|✘|recorded an issue|events:|\\[ERROR\\]|error:|Executed|TEST (SUCCEEDED|FAILED)|Build complete|\\*\\* '"

echo "==> macOS: swift test (FreeRDP.xcframework, macos slice)"
"${SSH[@]}" "export PATH=/opt/homebrew/bin:\$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer;
    cd $MAC_DIR/apple/Packages/RSSHRDP || exit 1; env $VARS swift test ${FILTER_TESTS:+--filter $FILTER_TESTS} >/tmp/$RUN-mac.log 2>&1; rc=\$?;
    $FILTER /tmp/$RUN-mac.log; rm -f /tmp/$RUN-mac.log; exit \$rc"

if [ "${SIM:-0}" = 1 ]; then
    SIM_NAME="${SIM_NAME:-iPhone 16 Pro}"
    SIM_OS="${SIM_OS:-18.0}"
    # xcodebuild hands TEST_RUNNER_<name> to the test process as <name>.
    RUNNER_VARS="$(for v in $VARS; do printf 'TEST_RUNNER_%s ' "$v"; done)"
    echo "==> iOS simulator: xcodebuild test (simulator slice) on $SIM_NAME, iOS $SIM_OS"
    "${SSH[@]}" "export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer;
        cd $MAC_DIR/apple/Packages/RSSHRDP || exit 1; env $RUNNER_VARS xcodebuild test -scheme RSSHRDP \
          -destination 'platform=iOS Simulator,name=$SIM_NAME,OS=$SIM_OS' -derivedDataPath /tmp/$RUN-dd \
          -skipPackagePluginValidation >/tmp/$RUN-sim.log 2>&1; rc=\$?;
        $FILTER /tmp/$RUN-sim.log;
        rm -rf /tmp/$RUN-dd /tmp/$RUN-sim.log; exit \$rc"
fi

if [ "${UI:-0}" = 1 ]; then
    SIM_NAME="${SIM_NAME:-iPhone 16 Pro}"
    SIM_OS="${SIM_OS:-18.0}"
    SHOTS_OUT="${SHOTS_OUT:-$PWD/rdp-shots}"
    # The app connects straight to xrdp (its "direct" transport): the Mac's 127.0.0.1:<port> -> the container.
    XRDP_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$RUN-xrdp")"
    RDP_PORT=$((20000 + RANDOM % 20000))
    ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -N -R "127.0.0.1:$RDP_PORT:$XRDP_IP:3389" "$MAC_HOST" &
    UI_FORWARD_PID=$!
    for _ in $(seq 1 20); do "${SSH[@]}" "nc -z 127.0.0.1 $RDP_PORT" 2>/dev/null && break; sleep 0.5; done
    echo "==> iOS app: RDPViewerUITests on $SIM_NAME, iOS $SIM_OS (xrdp at the Mac's 127.0.0.1:$RDP_PORT)"
    "${SSH[@]}" "export PATH=/opt/homebrew/bin:\$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer;
        cd $MAC_DIR/apple || exit 1; make gen >/dev/null || exit 1; rm -rf /tmp/$RUN-shots; mkdir -p /tmp/$RUN-shots;
        TEST_RUNNER_RSSH_UI_RDP='127.0.0.1:$RDP_PORT,rdp,$RDP_PASSWORD' TEST_RUNNER_RSSH_SHOT_DIR=/tmp/$RUN-shots \
          xcodebuild -project RSSH.xcodeproj -scheme RSSHUITests -only-testing:RSSHUITests/RDPViewerUITests \
          -destination 'platform=iOS Simulator,name=$SIM_NAME,OS=$SIM_OS' -derivedDataPath /tmp/$RUN-ui-dd test \
          >/tmp/$RUN-ui.log 2>&1; rc=\$?; $FILTER /tmp/$RUN-ui.log; rm -rf /tmp/$RUN-ui-dd /tmp/$RUN-ui.log; exit \$rc" \
        || ui_rc=$?
    mkdir -p "$SHOTS_OUT"
    scp -q -o BatchMode=yes "$MAC_HOST:/tmp/$RUN-shots/*.png" "$SHOTS_OUT/" && echo "==> screenshots in $SHOTS_OUT"
    "${SSH[@]}" "rm -rf /tmp/$RUN-shots"
    exit "${ui_rc:-0}"
fi
