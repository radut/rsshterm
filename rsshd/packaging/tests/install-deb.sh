#!/bin/sh
# Installs the built .deb for this machine's architecture in a clean Debian/Ubuntu container and checks what it put
# where, that it started nothing, and that it removes cleanly. Usage: install-deb.sh <dir-with-debs>
set -eu
dir=${1:-dist}
export DEBIAN_FRONTEND=noninteractive
# shellcheck source=/dev/null
. /etc/os-release
arch=$(dpkg --print-architecture)
deb=
for f in "$dir"/rsshd_*_"$arch".deb; do [ -f "$f" ] && deb=$f; done
[ -n "$deb" ] || { echo "no rsshd_*_$arch.deb in $dir" >&2; exit 1; }
echo "== $PRETTY_NAME ($arch): $deb"

apt-get -qq update
apt-get -qq install -y --no-install-recommends "./$deb" >/dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }
dpkg -s rsshd | grep -q '^Status: install ok installed' || fail "rsshd not installed"
command -v tmux >/dev/null || fail "dependency tmux not installed"
! dpkg -s screen >/dev/null 2>&1 || fail "screen pulled in: it must stay a Suggests, not a Depends"
/usr/bin/rsshd version | grep -q "^rsshd " || fail "rsshd version"
want_version=$(dpkg-query -W -f='${Version}' rsshd)
/usr/bin/rsshd version | grep -qF "$want_version" || fail "binary version differs from package version $want_version"
for f in /usr/lib/systemd/user/rsshd.service /etc/apt/apt.conf.d/52rsshd-unattended \
         /usr/share/keyrings/rsshd-archive-keyring.asc /usr/share/doc/rsshd/copyright /usr/share/rsshd/screenrc; do
  [ -f "$f" ] || fail "missing $f"
done
# Third-party notices are in the package (minimal Ubuntu images drop /usr/share/doc/* except copyright on install).
dpkg-deb -c "$deb" | grep -q '/usr/share/doc/rsshd/THIRD_PARTY_NOTICES$' || fail "the .deb lacks THIRD_PARTY_NOTICES"
grep -q '^KillMode=process' /usr/lib/systemd/user/rsshd.service || fail "unit must keep tmux on restart"
# Nothing enabled or started for anyone: no wants symlink anywhere, no process.
[ -z "$(find /etc/systemd /usr/lib/systemd -path '*wants*' -name 'rsshd*' 2>/dev/null)" ] || fail "unit enabled globally"
for c in /proc/[0-9]*/comm; do [ "$(cat "$c" 2>/dev/null)" != rsshd ] || fail "rsshd is running after install"; done

# Upgrade path: reinstalling the same package runs postinst with a previous version, which must not fail
# without systemd user managers.
apt-get -qq install -y --reinstall "./$deb" >/dev/null

apt-get -qq remove -y rsshd >/dev/null
[ ! -e /usr/bin/rsshd ] || fail "binary left after remove"
apt-get -qq purge -y rsshd >/dev/null
[ ! -e /etc/apt/apt.conf.d/52rsshd-unattended ] || fail "conffile left after purge"
echo "install-deb: OK on $PRETTY_NAME"
