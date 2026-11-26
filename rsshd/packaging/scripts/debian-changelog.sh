#!/bin/sh
# Writes the changelog the .deb must carry (lintian: no-changelog). A native version, so the name is changelog.gz.
# Usage: debian-changelog.sh <version> <out-dir>
set -eu
version=$1; out=$2
mkdir -p "$out"
# SOURCE_DATE_EPOCH keeps the file (and the .deb) reproducible; the commit time is a good default.
epoch=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}
date=$(date -u -d "@$epoch" -R 2>/dev/null || date -u -r "$epoch" '+%a, %d %b %Y %H:%M:%S +0000')
cat > "$out/changelog" <<CL
rsshd ($version) stable; urgency=medium

  * Release $version.

 -- Radu Toader <radu.m.toader@gmail.com>  $date
CL
gzip -9nf "$out/changelog"
