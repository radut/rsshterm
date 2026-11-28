#!/bin/sh
# Builds the desktop executable `rsshterm` for this machine's architecture, release mode, Swift runtime linked in
# statically, and stages it (with any SwiftPM resource bundles) in <out>/<deb-arch>/ for package-linux.sh.
# CI: build:desktop-linux (image swift:6.4-noble). Run from the repo root.
#
# The package that declares the product is found by name (a Package.swift under desktop/ mentioning "rsshterm"),
# or given with DESKTOP_PACKAGE_DIR. Until the app exists (wave 2) there is none: then this writes <out>/SKIPPED and
# succeeds, and package-linux.sh skips too; a release tag refuses that (REQUIRE_PRODUCT=1).
#
# Usage: build-linux.sh <out-dir>     Env: RSSHTERM_VERSION (stamped into Sources/RSSHTermLinux/Version.swift)
set -eu
out=$1
mkdir -p "$out"
dir=${DESKTOP_PACKAGE_DIR:-}
if [ -z "$dir" ]; then
  for f in $(find desktop -name Package.swift -not -path '*/.build/*' 2>/dev/null | sort); do
    if grep -q '"rsshterm"' "$f"; then dir=$(dirname "$f"); break; fi
  done
fi
if [ -z "$dir" ] || ! (cd "$dir" && swift package dump-package 2>/dev/null | grep -q '"name" *: *"rsshterm"'); then
  [ "${REQUIRE_PRODUCT:-0}" = 1 ] && { echo "no SwiftPM product rsshterm under desktop/: nothing to release" >&2; exit 1; }
  echo "no SwiftPM product rsshterm under desktop/ yet (the app comes in wave 2): build skipped"
  echo "no product rsshterm" > "$out/SKIPPED"
  exit 0
fi
case $(uname -m) in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) echo "unsupported $(uname -m)" >&2; exit 1 ;; esac
# The version the app reports (and the updater compares): stamped from the tag before the build.
vfile=$dir/Sources/RSSHTermLinux/Version.swift
if [ -n "${RSSHTERM_VERSION:-}" ] && [ -f "$vfile" ]; then
  sed -i "s|^\(    public static let current = \)\".*\"\$|\1\"$RSSHTERM_VERSION\"|" "$vfile"
  grep -q "current = \"$RSSHTERM_VERSION\"" "$vfile" || { echo "could not stamp $RSSHTERM_VERSION into $vfile" >&2; exit 1; }
fi
echo "building rsshterm ${RSSHTERM_VERSION:-(unstamped)} in $dir for $arch"
(cd "$dir" && swift build -c release --product rsshterm --static-swift-stdlib)
bin=$(cd "$dir" && swift build -c release --show-bin-path)
stage=$out/$arch
rm -rf "$stage"; mkdir -p "$stage"
cp "$bin/rsshterm" "$stage/rsshterm"
for r in "$bin"/*.resources; do [ ! -d "$r" ] || cp -R "$r" "$stage/"; done
# Dynamic library products of the dependencies (RoyalVNCKit is `type: .dynamic`): beside the binary, which SwiftPM
# links with RUNPATH $ORIGIN, so the tarball, the .deb (/usr/lib/rsshterm) and the AppImage find them.
for l in "$bin"/lib*.so; do [ ! -f "$l" ] || cp "$l" "$stage/"; done
missing=$(ldd "$stage/rsshterm" 2>/dev/null | grep 'not found' || true)
[ -z "$missing" ] || { printf 'rsshterm needs libraries the stage lacks:\n%s\n' "$missing" >&2; exit 1; }
strip "$stage/rsshterm" 2>/dev/null || true
for l in "$stage"/lib*.so; do [ ! -f "$l" ] || strip --strip-unneeded "$l" 2>/dev/null || true; done
"$stage/rsshterm" --version 2>/dev/null || true
ls -la "$stage"
