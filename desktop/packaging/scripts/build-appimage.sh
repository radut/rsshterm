#!/bin/sh
# Wraps the staged build of build-linux.sh (<build-dir>/<arch>/rsshterm, Swift runtime static) into an AppImage with
# GTK 4, libadwaita, VTE and their data (gsettings schemas, icons, pixbuf loaders) bundled, so it runs on distros
# without them: <out-dir>/rsshterm_<v>_linux_<arch>.AppImage. CI: build:desktop-linux-appimage (swift:6.4-noble with the
# GTK -dev packages, the libraries that get bundled). glibc is NOT bundled: the baseline is the build image's
# (Ubuntu 24.04: glibc 2.39), so the AppImage runs on distros with glibc >= 2.39.
#
# Tools: linuxdeploy (pinned release) + linuxdeploy-plugin-gtk (pinned commit), each checked against its sha256.
# Usage: build-appimage.sh <build-dir> <out-dir> <version>      Needs curl, file, a bundled-libs build environment.
set -eu
build=$1; out=$2; ver=$3
case $ver in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "bad version $ver" >&2; exit 1 ;; esac
case $(uname -m) in x86_64) arch=amd64; ld_arch=x86_64 ;; aarch64) arch=arm64; ld_arch=aarch64 ;; *) exit 1 ;; esac
if [ ! -x "$build/$arch/rsshterm" ]; then
  [ -f "$build/SKIPPED" ] && [ "${REQUIRE_PRODUCT:-0}" != 1 ] && { echo "build skipped: no AppImage"; exit 0; }
  echo "no $build/$arch/rsshterm" >&2; exit 1
fi
root=$(pwd)
LINUXDEPLOY_TAG=1-alpha-20251107-1
GTK_PLUGIN_COMMIT=7a3fbc31a9e5075073ff8790f26effbac5f84453
case $ld_arch in
  x86_64) ld_sha=c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d ;;
  aarch64) ld_sha=620095110d693282b8ebeb244a95b5e911cf8f65f76c88b4b47d16ae6346fcff ;;
esac
gtk_sha=b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT INT TERM
tools=$work/tools; mkdir -p "$tools"
curl -fsSL --retry 3 -o "$tools/linuxdeploy" \
  "https://github.com/linuxdeploy/linuxdeploy/releases/download/$LINUXDEPLOY_TAG/linuxdeploy-$ld_arch.AppImage"
curl -fsSL --retry 3 -o "$tools/linuxdeploy-plugin-gtk.sh" \
  "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/$GTK_PLUGIN_COMMIT/linuxdeploy-plugin-gtk.sh"
printf '%s  %s\n%s  %s\n' "$ld_sha" "$tools/linuxdeploy" "$gtk_sha" "$tools/linuxdeploy-plugin-gtk.sh" | sha256sum -c --quiet ||
  { echo "linuxdeploy or its GTK plugin does not match the pinned sha256" >&2; exit 1; }
chmod +x "$tools/linuxdeploy" "$tools/linuxdeploy-plugin-gtk.sh"

# AppDir: the binary (and any resource bundles) in usr/bin, the .desktop file and the icon.
# The dependencies' dynamic libraries that build-linux.sh staged beside the binary (libRoyalVNCKit.so) go to usr/lib,
# handed to linuxdeploy (which resolves their own dependencies and points the binary's RUNPATH at ../lib).
app=$work/AppDir; mkdir -p "$app/usr/bin" "$app/usr/lib"
cp -R "$build/$arch/." "$app/usr/bin/"
set --
for l in "$app"/usr/bin/lib*.so; do
  [ -f "$l" ] || continue
  mv "$l" "$app/usr/lib/"; set -- "$@" --library "$app/usr/lib/$(basename "$l")"
done
# FreeRDP 3 (RDP screens): named explicitly too, so the AppImage carries it to distros without FreeRDP 3.
# libusb-1.0 (pulled in by FreeRDP 3) is on the AppImage excludelist, yet Ubuntu 24.04 does not ship it by default.
for name in libfreerdp3.so.3 libfreerdp-client3.so.3 libwinpr3.so.3 libusb-1.0.so.0; do
  lib=$(ldconfig -p | awk -v n="$name" '$1 == n { print $NF; exit }')
  if [ -n "$lib" ]; then set -- "$@" --library "$lib"; else echo "warning: $name not found (freerdp3-dev missing?)" >&2; fi
done
mkdir -p "$out"; out=$(cd "$out" && pwd)
# No FUSE in containers: linuxdeploy (itself an AppImage) runs extracted. DEPLOY_GTK_VERSION picks GTK 4.
export APPIMAGE_EXTRACT_AND_RUN=1 DEPLOY_GTK_VERSION=4 NO_STRIP=1 ARCH="$ld_arch" VERSION="$ver"
export LDAI_OUTPUT="$out/rsshterm_${ver}_linux_${arch}.AppImage"
# Three steps: linuxdeploy bundles the libraries (and their Debian copyright files) into the AppDir; appimage-notices.sh
# adds our THIRD_PARTY_NOTICES, the licence texts, the package/source versions and the source offer, and fails on a
# bundled library with no known licence; then linuxdeploy packs the AppDir into the AppImage.
(cd "$work" && PATH=$tools:$PATH LD_LIBRARY_PATH="$app/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$tools/linuxdeploy" --appdir "$app" \
  --executable "$app/usr/bin/rsshterm" "$@" \
  --desktop-file "$root/desktop/linux/packaging/dev.rsshterm.RSSHTerm.desktop" \
  --icon-file "$root/desktop/linux/packaging/icons/hicolor/256x256/apps/dev.rsshterm.RSSHTerm.png" \
  --plugin gtk)
sh "$root/desktop/packaging/scripts/appimage-notices.sh" "$app" "$root"
(cd "$work" && PATH=$tools:$PATH LD_LIBRARY_PATH="$app/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$tools/linuxdeploy" --appdir "$app" --output appimage)
[ -s "$LDAI_OUTPUT" ] || { echo "linuxdeploy made no AppImage" >&2; exit 1; }
chmod 755 "$LDAI_OUTPUT"
ls -l "$LDAI_OUTPUT"
