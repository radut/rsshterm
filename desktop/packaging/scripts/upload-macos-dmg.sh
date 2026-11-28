#!/bin/sh
# Hands a notarized DMG from the Mac to the pipeline (docs/desktop/mac-dmg.md): uploads it to the generic package
# registry as desktop-macos/<v>/<name> and writes its sha256 into desktop/packaging/macos-dmg.sha256. Commit that pin
# to main: release:desktop-mac-dmg then adds the DMG to the published release (or a desktop-v<v> tag takes it), signing
# the checksum lists and latest.json in CI. Nothing is signed here; a pipeline takes only the bytes git pins.
#
# Usage: upload-macos-dmg.sh <rsshterm_X.Y.Z_macos_universal.dmg>   Needs glab (logged in), curl, sha256sum.
# Env:   GITLAB_PROJECT (default: the project of the origin remote)
set -eu
dmg=$1
name=${dmg##*/}
case $name in rsshterm_[0-9]*.[0-9]*.[0-9]*_macos_universal.dmg) ;; *) echo "not a release DMG name: $name" >&2; exit 2 ;; esac
ver=${name#rsshterm_}; ver=${ver%_macos_universal.dmg}
case $ver in *[!0-9.]*) echo "bad version in $name" >&2; exit 2 ;; esac
root=$(cd "$(dirname "$0")/../../.." && pwd)
project=${GITLAB_PROJECT:-$(git -C "$root" remote get-url origin | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')}
[ -n "$project" ] || { echo "no GitLab project: set GITLAB_PROJECT" >&2; exit 2; }
enc=$(printf %s "$project" | sed 's|/|%2F|g')
sum=$(sha256sum "$dmg" | awk '{print $1}')
path="projects/$enc/packages/generic/desktop-macos/$ver/$name"

glab api --method PUT -H "Content-Type: application/octet-stream" --input "$dmg" "$path" >/dev/null
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT INT TERM
glab api "$path" > "$work/back"
[ "$(sha256sum "$work/back" | awk '{print $1}')" = "$sum" ] || { echo "the registry copy differs from $dmg" >&2; exit 1; }
printf '%s  %s\n' "$sum" "$name" > "$root/desktop/packaging/macos-dmg.sha256"
echo "uploaded desktop-macos/$ver/$name ($sum); pin written: desktop/packaging/macos-dmg.sha256"
