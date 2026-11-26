#!/bin/sh
# Packs every staged build of build-linux.sh (<build-dir>/<arch>/) into
#   rsshterm_<v>_<arch>.deb (nfpm, desktop/packaging/nfpm.yaml) and rsshterm_<v>_linux_<arch>.tar.gz
#   (one top dir rsshterm-<v>-linux-<arch>/bin/rsshterm: what the app's updater unpacks; licences in share/doc/rsshterm/),
# plus SHA256SUMS over everything, in <dist-dir>. CI: desktop:linux-package (image goreleaser/nfpm + GNU tar). Repo root.
# A build that was skipped (<build-dir>/SKIPPED) is skipped here too, unless REQUIRE_PRODUCT=1.
#
# Usage: package-linux.sh <build-dir> <dist-dir> <version>
set -eu
build=$1; dist=$2; ver=$3
case $ver in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "bad version $ver" >&2; exit 1 ;; esac
if [ -f "$build/SKIPPED" ] && ! ls -d "$build"/amd64 "$build"/arm64 >/dev/null 2>&1; then
  [ "${REQUIRE_PRODUCT:-0}" = 1 ] && { echo "the build was skipped: nothing to release" >&2; exit 1; }
  echo "build skipped ($(cat "$build/SKIPPED")): nothing to package"; exit 0
fi
export DEB_MAINTAINER="${DEB_MAINTAINER:-rSshTerm <4960306+radut@users.noreply.github.com>}"
mkdir -p "$dist"
# Reproducible tarballs: fixed owner, order and time (the commit's).
epoch=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}
export SOURCE_DATE_EPOCH="$epoch"
# The icon tree goes into the deb as it is on disk: no group/other write bits from the checkout's umask.
chmod -R go-w desktop/linux/packaging/icons 2>/dev/null || true
for stage in "$build"/amd64/ "$build"/arm64/; do
  [ -d "$stage" ] || continue
  arch=$(basename "$stage")
  case $arch in amd64|arm64) ;; *) continue ;; esac
  [ -x "$stage/rsshterm" ] || { echo "$stage has no rsshterm" >&2; exit 1; }
  chmod -R go-w "$stage"
  # The updater's layout: ONE top directory, the executable in bin/ (resource bundles beside it).
  top=rsshterm-$ver-linux-$arch; rm -rf "$dist/.tar"; mkdir -p "$dist/.tar/$top"; cp -R "$stage" "$dist/.tar/$top/bin"
  # Licences: rSshTerm's terms and the third-party notices (packaging/licenses/generate.py), as in the .deb.
  mkdir -p "$dist/.tar/$top/share/doc/rsshterm"
  cp desktop/packaging/deb/copyright desktop/packaging/THIRD_PARTY_NOTICES "$dist/.tar/$top/share/doc/rsshterm/"
  (cd "$dist/.tar" && find "$top" | sort | tar -cf - --no-recursion --owner=0 --group=0 --numeric-owner \
      --mtime="@$epoch" -T -) | gzip -9n > "$dist/rsshterm_${ver}_linux_${arch}.tar.gz"
  rm -rf "$dist/.tar"
  # nfpm does not expand variables in contents[].src, so the config is filled in here.
  sed -e "s|\${RSSHTERM_VERSION}|$ver|; s|\${RSSHTERM_ARCH}|$arch|; s|\${DEB_MAINTAINER}|$DEB_MAINTAINER|" \
      -e "s|\${RSSHTERM_STAGE}|$(cd "$stage" && pwd)|" desktop/packaging/nfpm.yaml > "$dist/.nfpm.yaml"
  nfpm package --config "$dist/.nfpm.yaml" --packager deb --target "$dist/rsshterm_${ver}_${arch}.deb"
  rm -f "$dist/.nfpm.yaml"
done
# AppImages from build-appimage.sh (desktop:linux-appimage), when built.
for a in "$build"/appimage/*.AppImage; do [ ! -f "$a" ] || cp "$a" "$dist/"; done
[ -n "${RSSHTERM_NOTES:-}" ] && printf '%s\n' "$RSSHTERM_NOTES" > "$dist/NOTES"
(cd "$dist" && sha256sum -- * | grep -v ' SHA256SUMS' > SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS)
cat "$dist/SHA256SUMS"
