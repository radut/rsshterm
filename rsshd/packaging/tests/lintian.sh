#!/bin/sh
# Lintian on the built .debs; any error or warning fails. Runs in debian:12 (CI job test:rsshd-lintian, or
# packaging/tests/run-docker.sh). Usage: lintian.sh <dir-with-debs>
set -eu
dir=${1:-dist}
export DEBIAN_FRONTEND=noninteractive
command -v lintian >/dev/null || { apt-get -qq update && apt-get -qq install -y --no-install-recommends lintian >/dev/null; }
lintian --version
# --suppress-tags: none yet; real suppressions live in packaging/deb/lintian-overrides (shipped in the .deb).
lintian --fail-on error,warning --display-info --tag-display-limit 0 "$dir"/*.deb
echo "lintian: OK"
