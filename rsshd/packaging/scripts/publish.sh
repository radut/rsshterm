#!/bin/sh
# rsshd's entry to the shared Pages site builder (packaging/site/build-site.sh), kept for the tests and local use:
# signs <dist-dir>/SHA256SUMS and lays out the site in <out-dir> with rsshd only (plus DESKTOP_DIST when set).
# Usage: publish.sh <dist-dir> <out-dir>   Env: see build-site.sh (RSSHD_VERSION, GPG_PRIVATE_KEY_ASC, ...)
set -eu
RSSHD_DIST=$(cd "$1" && pwd) exec sh "$(dirname "$0")/../../../packaging/site/build-site.sh" "$2"
