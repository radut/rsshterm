#!/bin/sh
# SFTP integration test of RSSHRemote against a real OpenSSH server, all in docker:
#   apple/Packages/RSSHRemote/IntegrationTests/run.sh      (or `make test-remote-it` at the repo root)
# Builds a throwaway sshd image, starts it on a private network with a fresh key and password, then runs
# `swift test --filter SFTPIntegration` in swift:6.4-noble with RSSH_SFTP_IT_* set. Everything is removed afterwards.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
packages=$(cd "$here/../.." && pwd)
swift_image=${SWIFT_IMAGE:-swift:6.4-noble}
run_id=rssh-sftp-it-$$
work=$(mktemp -d)
cleanup() {
  docker rm -f "$run_id-sshd" >/dev/null 2>&1 || true
  docker network rm "$run_id" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

ssh-keygen -q -t ed25519 -N '' -C rssh-it -f "$work/id" >/dev/null
password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
docker build -q -t rssh-sftp-it-sshd "$here/sshd" >/dev/null
docker network create "$run_id" >/dev/null
docker run -d --name "$run_id-sshd" --network "$run_id" --network-alias sshd \
  -e AUTHORIZED_KEY="$(cat "$work/id.pub")" -e TESTER_PASSWORD="$password" rssh-sftp-it-sshd >/dev/null
docker run --rm --network "$run_id" -v "$packages:/src" -v rsshremote-build:/build -v "$work:/it:ro" \
  -w /src/RSSHRemote \
  -e RSSH_SFTP_IT_HOST=sshd -e RSSH_SFTP_IT_PORT=22 -e RSSH_SFTP_IT_USER=tester \
  -e RSSH_SFTP_IT_KEY=/it/id -e RSSH_SFTP_IT_PASSWORD="$password" \
  "$swift_image" sh -c 'for i in $(seq 1 30); do (exec 3<>/dev/tcp/sshd/22) 2>/dev/null && break; sleep 1; done;
    swift test --scratch-path /build --filter SFTPIntegration'
