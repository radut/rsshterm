#!/bin/sh
# What make rsshd-test and the GitLab job test:rsshd run inside the golang image (with tmux and screen installed).
# Fails when tmux or screen is missing instead of skipping (RSSHD_REQUIRE_TMUX=1, RSSHD_REQUIRE_SCREEN=1).
set -eu
cd "$(dirname "$0")/.."
export RSSHD_REQUIRE_TMUX=1 RSSHD_REQUIRE_SCREEN=1
echo "==> gofmt"
unformatted=$(gofmt -l .)
[ -z "$unformatted" ] || { echo "not gofmt-ed: $unformatted"; exit 1; }
echo "==> go vet"
go vet ./...
echo "==> unit, tmux and screen integration tests"
# shellcheck disable=SC2046
go test -race -count=1 -cover $(go list ./... | grep -v /test/e2e)
echo "==> e2e: the rsshd binary against real tmux and screen"
log=$(mktemp)
rc=0
go test -count=1 -v ./test/e2e/ >"$log" 2>&1 || rc=$?
# The scenario log (events with timings), without the noise of every subtest's PAUSE/CONT lines.
grep -vE '^=== (RUN|PAUSE|CONT|NAME)' "$log"
rm -f "$log"
exit "$rc"
