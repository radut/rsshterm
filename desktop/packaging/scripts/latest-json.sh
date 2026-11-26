#!/bin/sh
# Writes desktop/latest.json, what the app's updater and desktop/install.sh read (schema: docs/desktop/release.md):
#
#   {"version": "1.2.3", "notes": "...", "assets": {
#     "linux-amd64": {"url": "<base>/rsshterm_1.2.3_linux_amd64.tar.gz", "sha256": "<hex>"}, ...}}
#
# One asset per line, so install.sh can read it with sed (no jq on a fresh machine). Platform keys come from the file
# names: rsshterm_<v>_linux_<amd64|arm64>.tar.gz -> linux-<arch>, rsshterm_<v>_linux_<arch>.AppImage ->
# linux-<arch>-appimage, rsshterm_<v>_macos_universal.zip -> macos-universal.
# Notes: the dist's NOTES file (the tag message), else empty. published: the dist's PUBLISHED (UTC ISO 8601), optional.
# Usage: latest-json.sh <version> <dist-dir> <base-url-of-the-release-dir>   Needs jq (for the notes text only).
set -eu
ver=$1; dist=$2; base=$3
case $ver in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "bad version $ver" >&2; exit 1 ;; esac
[ -f "$dist/SHA256SUMS" ] || { echo "no $dist/SHA256SUMS" >&2; exit 1; }
notes='""'
[ ! -f "$dist/NOTES" ] || notes=$(jq -Rs . < "$dist/NOTES")
# published: fixed per release (the dist's PUBLISHED file, written once by desktop:release), so a later rebuild of
# the site makes the same bytes and keeps the signature.
published=
if [ -f "$dist/PUBLISHED" ]; then
  p=$(tr -d ' \r\n' < "$dist/PUBLISHED")
  case $p in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) published=$(printf '\n  "published": "%s",' "$p") ;;
    *) echo "bad PUBLISHED: $p" >&2; exit 1 ;; esac
fi
printf '{\n  "version": "%s",%s\n  "notes": %s,\n  "assets": {' "$ver" "$published" "$notes"
sep=
while read -r sum file; do
  file=${file#\*}
  case $file in
    "rsshterm_${ver}_linux_"*.tar.gz) key=${file#"rsshterm_${ver}_linux_"}; key=linux-${key%.tar.gz} ;;
    "rsshterm_${ver}_linux_"*.AppImage) key=${file#"rsshterm_${ver}_linux_"}; key=linux-${key%.AppImage}-appimage ;;
    "rsshterm_${ver}_macos_universal.zip") key=macos-universal ;;
    *) continue ;;
  esac
  case $sum in *[!0-9a-f]*|'') echo "bad checksum for $file" >&2; exit 1 ;; esac
  printf '%s\n    "%s": {"url": "%s/%s", "sha256": "%s"}' "$sep" "$key" "$base" "$file" "$sum"
  sep=,
done < "$dist/SHA256SUMS"
printf '\n  }\n}\n'
