#!/bin/sh
# Licence files of the AppImage, run by build-appimage.sh between linuxdeploy's deploy step and its packaging step.
# The AppImage redistributes Ubuntu's shared libraries (GTK 4, libadwaita, VTE, GLib, FreeRDP, libusb, ...; LGPL and
# others), so it must carry their notices, the licence texts and a way to get their source. Into the AppDir:
#
#   usr/share/doc/rsshterm/THIRD_PARTY_NOTICES      the generated list (packaging/licenses/generate.py): our Swift deps
#   usr/share/doc/rsshterm/copyright                 rSshTerm's own terms
#   usr/share/doc/rsshterm/bundled-libraries/
#     LIBRARIES.txt          every bundled .so -> Ubuntu binary package + version -> source package + version
#     <package>.copyright    that package's Debian copyright file
#     common-licenses/       the texts those files refer to (LGPL-2.1, LGPL-3, GPL-3, MPL, Apache-2.0, ...)
#     SOURCE-OFFER.txt       where the corresponding source is, and the written offer (LGPL-2.1 §6, LGPL-3 §4)
#
# FAILS when a bundled library belongs to no installed package (no licence known): add it to our own notices
# (packaging/licenses/manifest.toml) and to OWN_LIBS below, or stop bundling it. The libraries stay separate shared
# objects (dynamic linking): users can replace them after --appimage-extract.
#
# Usage: appimage-notices.sh <AppDir> <repo-root>          Needs dpkg-query (the Ubuntu build image).
set -eu
app=$1; root=$2
# Our own libraries (built from this repo and its Swift packages; covered by THIRD_PARTY_NOTICES).
OWN_LIBS="libRoyalVNCKit.so"
doc=$app/usr/share/doc/rsshterm
bl=$doc/bundled-libraries
mkdir -p "$bl/common-licenses"
cp "$root/desktop/packaging/THIRD_PARTY_NOTICES.appimage" "$doc/THIRD_PARTY_NOTICES"
cp "$root/desktop/packaging/deb/copyright" "$doc/copyright"
cp -L /usr/share/common-licenses/* "$bl/common-licenses/"
list=$bl/LIBRARIES.txt
{
  echo "Shared libraries bundled in this AppImage, from $(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release) ($(dpkg --print-architecture))."
  echo "library | binary package | version | source package | source version"
} > "$list"
missing=""
for f in $(find "$app/usr/lib" \( -type f -o -type l \) -name '*.so*' | sort); do
  base=$(basename "$f")
  case " $OWN_LIBS " in *" $base "*) continue ;; esac
  # dpkg -S with a glob: "pkg1, pkg2: /path"; keep lines whose path ends in exactly this name, prefer non -dev.
  owners=$(dpkg -S "*/$base" 2>/dev/null | awk -v b="$base" -F': ' '{ n = split($2, p, "/"); if (p[n] == b) print $1 }' \
    | tr ',' '\n' | sed 's/^ *//; s/:.*$//' | sort -u)
  pkg=$(printf '%s\n' "$owners" | grep -v -- '-dev$' | head -n 1)
  [ -n "$pkg" ] || pkg=$(printf '%s\n' "$owners" | head -n 1)
  if [ -z "$pkg" ]; then missing="$missing $base"; continue; fi
  copyright=/usr/share/doc/$pkg/copyright
  if [ ! -f "$copyright" ]; then missing="$missing $base($pkg: no copyright file)"; continue; fi
  [ -f "$bl/$pkg.copyright" ] || cp -L "$copyright" "$bl/$pkg.copyright"
  printf '%s | %s\n' "$base" "$(dpkg-query -W -f='${Package} | ${Version} | ${source:Package} | ${source:Version}' "$pkg")" >> "$list"
done
if [ -n "$missing" ]; then
  echo "bundled libraries with no known licence (no owning package):$missing" >&2
  exit 1
fi
cat > "$bl/SOURCE-OFFER.txt" <<'EOF'
Source code of the bundled libraries
====================================

This AppImage bundles, unmodified, the shared libraries listed in LIBRARIES.txt, taken from Ubuntu's binary
packages. Several are licensed under the GNU Lesser General Public License (LGPL-2.1 or LGPL-3, texts in
common-licenses/) or other licences that require the source code to be available; each package's licence is in
<package>.copyright.

1. Where the source is: every library comes from the Ubuntu source package and version named in LIBRARIES.txt.
   Ubuntu keeps those exact versions available, e.g. `apt-get source <source package>=<source version>` on Ubuntu,
   or https://launchpad.net/ubuntu/+source/<source package>/<source version>.

2. Written offer: for at least three years after we last distribute this version of the AppImage, we will give
   anyone who has received it a complete machine-readable copy of the corresponding source code of these libraries,
   for no more than our cost of physically performing the distribution. Ask through the support page of rSshTerm
   (https://radut.github.io/rsshterm/support.html), naming the AppImage version.

3. Replacing the libraries: rSshTerm uses these libraries as separate shared objects (dynamic linking). Run the
   AppImage with --appimage-extract, replace any library in squashfs-root/usr/lib, and start squashfs-root/AppRun.
   You may modify these libraries for your own use and reverse-engineer rSshTerm as far as needed to debug such
   modifications (LGPL-2.1 section 6, LGPL-3 section 4).
EOF
echo "AppImage notices: $(($(wc -l < "$list") - 2)) bundled libraries, $(find "$bl" -maxdepth 1 -name '*.copyright' | wc -l) copyright files"
