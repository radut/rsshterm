#!/bin/sh
# Starts the rsshterm AppImage on a distro WITHOUT GTK installed, to prove
# the bundle is complete: `--version`, then the GUI under Xvfb for a few seconds with a window on screen and no
# missing library. Installed besides the X server and D-Bus: a GTK 3 desktop's base, i.e. what AppImage's excludelist
# expects every desktop to have (fontconfig, freetype, harfbuzz, fribidi, Mesa's GL/EGL...), never GTK 4, libadwaita
# or VTE, which the AppImage must bring. Runs as root in ubuntu:24.04 or fedora (CI: build:desktop-linux-appimage-check). No FUSE: extract-and-run.
# Usage: appimage-run.sh <rsshterm_*.AppImage>
set -eu
img=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
# shellcheck disable=SC1091
. /etc/os-release
echo "== $PRETTY_NAME, glibc $(ldd --version 2>&1 | head -1 | awk '{print $NF}')"
if command -v apt-get >/dev/null 2>&1; then
  apt-get -qq update
  DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends xvfb xauth x11-utils dbus fonts-dejavu-core \
    libgtk-3-0t64 libegl1 libgl1 libgles2 libgbm1 libasound2t64 >/dev/null
else
  dnf -q -y install xorg-x11-server-Xvfb xorg-x11-xauth xwininfo dbus-daemon dejavu-sans-mono-fonts which \
    gtk3 mesa-libEGL mesa-libGL mesa-libGLES mesa-libgbm >/dev/null
fi
if ldconfig -p | grep -qE 'libgtk-4\.so|libadwaita-1\.so|libvte-2\.91-gtk4\.so'; then
  echo "FAIL: this image has GTK 4, libadwaita or VTE (gtk4) installed: the test would prove nothing" >&2; exit 1
fi
export APPIMAGE_EXTRACT_AND_RUN=1 RSSHTERM_NO_UPDATE_CHECK=1 HOME=/tmp/home XDG_RUNTIME_DIR=/tmp/run
# Xvfb has no GPU: the same software settings as desktop/linux/Dockerfile's smoke test.
export GTK_A11Y=none GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1 GDK_BACKEND=x11
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
"$img" --version
log=/tmp/appimage.log
# shellcheck disable=SC2016
xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- sh -c '
  "$0" > "$1" 2>&1 & pid=$!
  i=0; while [ $i -lt 30 ]; do
    if xwininfo -root -tree 2>/dev/null | grep -qi "rsshterm"; then echo "window up after $((i / 2)) s"; break; fi
    kill -0 $pid 2>/dev/null || { echo "rsshterm exited early" >&2; exit 1; }
    sleep 0.5; i=$((i + 1))
  done
  xwininfo -root -tree | grep -i "rsshterm" | head -3
  kill -0 $pid || exit 1
  kill $pid; wait $pid 2>/dev/null || true
  [ $i -lt 30 ]' "$img" "$log" || { echo "--- rsshterm output"; cat "$log"; exit 1; }
if grep -E 'cannot open shared object|error while loading|GLib-GIO-ERROR|Failed to load module' "$log"; then
  echo "FAIL: the AppImage misses a library or module" >&2; exit 1
fi
# The licences the AppImage must carry (appimage-notices.sh): our notices, the bundled libraries' copyright files,
# the LGPL texts and the source offer.
rm -rf /tmp/appimage-x; mkdir -p /tmp/appimage-x
(cd /tmp/appimage-x && "$img" --appimage-extract >/dev/null)
d=/tmp/appimage-x/squashfs-root/usr/share/doc/rsshterm
for f in THIRD_PARTY_NOTICES copyright bundled-libraries/LIBRARIES.txt bundled-libraries/SOURCE-OFFER.txt \
         bundled-libraries/common-licenses/LGPL-2.1 bundled-libraries/common-licenses/LGPL-3 \
         bundled-libraries/libgtk-4-1.copyright bundled-libraries/libvte-2.91-gtk4-0.copyright; do
  [ -s "$d/$f" ] || { echo "FAIL: the AppImage lacks usr/share/doc/rsshterm/$f" >&2; exit 1; }
done
grep -q 'Marcin Krzyzanowski' "$d/THIRD_PARTY_NOTICES" || { echo "FAIL: CryptoSwift acknowledgement missing" >&2; exit 1; }
echo "appimage-run: OK on $PRETTY_NAME"
