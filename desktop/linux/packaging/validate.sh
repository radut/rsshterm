#!/bin/sh
# Checks the packaging files: desktop-file-validate, appstreamcli (no network), every icon size present and square.
set -eu
cd "$(dirname "$0")"
desktop-file-validate dev.rsshterm.RSSHTerm.desktop
appstreamcli validate --no-net dev.rsshterm.RSSHTerm.metainfo.xml
for size in 512 256 128 64 48 32 16; do
    f="icons/hicolor/${size}x${size}/apps/dev.rsshterm.RSSHTerm.png"
    test "$(identify -format '%wx%h' "$f")" = "${size}x${size}" || { echo "bad or missing $f"; exit 1; }
done
echo "packaging: ok"
