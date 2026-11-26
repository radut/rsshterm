#!/bin/sh
# The Linux icons from the one app logo (the iOS/Mac AppIcon, 1024 px): hicolor 512/256/128/64/48/32/16 PNGs, also
# used for the AppImage. A new logo: replace apple/RSSH/Assets.xcassets/AppIcon.appiconset/AppIcon.png and run this
# (ImageMagick); the PNGs are committed so package builds need no image tools.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../../../apple/RSSH/Assets.xcassets/AppIcon.appiconset/AppIcon.png}"
test -s "$src" || { echo "no logo at $src"; exit 1; }
for size in 512 256 128 64 48 32 16; do
    dir="$here/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$dir"
    convert "$src" -filter Lanczos -resize "${size}x${size}" -strip "PNG32:$dir/dev.rsshterm.RSSHTerm.png"
done
echo "icons: $(ls "$here"/icons/hicolor | tr '\n' ' ')"
