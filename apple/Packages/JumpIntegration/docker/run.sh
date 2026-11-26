#!/usr/bin/env bash
# Jump host integration test: a jump server and a target server in docker. The target sits on an internal network
# the test container cannot reach, so the only way to it is through the jump server.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
apple=$(cd "$here/../../.." && pwd)
image=${SWIFT_IMAGE:-swift:6.4-noble}
tag="rssh-jump-it-$$"
# Fresh throwaway passwords per run, never printed.
jump_password=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
target_password=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')

cleanup() {
  docker rm -f "$tag-jump" "$tag-target" >/dev/null 2>&1 || true
  docker network rm "$tag-outer" "$tag-inner" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build -q -t rssh-jump-it-sshd "$here" >/dev/null
# Passed by name (-e NAME), so they never show in a process list.
export JUMP_PASSWORD="$jump_password" TARGET_PASSWORD="$target_password"
export RSSH_JUMP_IT_JUMP_PASSWORD="$jump_password" RSSH_JUMP_IT_TARGET_PASSWORD="$target_password"
docker network create "$tag-outer" >/dev/null
docker network create --internal "$tag-inner" >/dev/null
docker run -d --name "$tag-target" --network "$tag-inner" --network-alias target -e JUMP_PASSWORD -e TARGET_PASSWORD rssh-jump-it-sshd >/dev/null
docker run -d --name "$tag-jump" --network "$tag-outer" --network-alias jump -e JUMP_PASSWORD -e TARGET_PASSWORD rssh-jump-it-sshd >/dev/null
docker network connect "$tag-inner" "$tag-jump"

docker run --rm --network "$tag-outer" -v "$apple:/src" -v rssh-jump-it-build:/build -w /src/Packages/JumpIntegration \
  -e RSSH_JUMP_IT_HOST=jump -e RSSH_JUMP_IT_TARGET=target \
  -e RSSH_JUMP_IT_JUMP_PASSWORD -e RSSH_JUMP_IT_TARGET_PASSWORD \
  "$image" swift test --scratch-path /build
