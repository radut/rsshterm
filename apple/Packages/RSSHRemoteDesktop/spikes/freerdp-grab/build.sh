#!/bin/sh
# Builds grab against Ubuntu noble's libfreerdp3 (freerdp3-dev). Run in swift:6.4-noble or ubuntu:24.04.
set -eu
cd "$(dirname "$0")"
apt-get -qq update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends freerdp3-dev gcc pkg-config >/dev/null
gcc -O1 -Wall -o "${1:-/tmp/grab}" grab.c $(pkg-config --cflags --libs freerdp3 freerdp-client3 winpr3)
