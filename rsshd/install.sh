#!/bin/sh
# Installs rsshd, the session daemon of the rSshTerm app, for the user who runs it. Read it before you run it:
#
#   curl -fsSLO https://rssh-ea902a.gitlab.io/install.sh && less install.sh && sh install.sh
#
# Debian, Ubuntu, Raspberry Pi OS (amd64, arm64): adds the signed apt repo (key below, apt checks it through
#   Signed-By) and installs the package with sudo; later upgrades come with apt / unattended-upgrades.
# macOS and other Linux: downloads the tarball for this machine, checks the gpg signature of SHA256SUMS against the
#   key EMBEDDED below (never one fetched from the server), checks the checksum, installs to ~/.local/bin (no root).
# Then starts rsshd for this user only: a systemd user service on Linux, a launchd agent on macOS. On Linux it also
#   turns on linger for this user (loginctl enable-linger), so rsshd and its sessions keep running after the last
#   logout; without it systemd stops them when you disconnect. --no-linger leaves it off.
#
#   sh install.sh [--version X.Y.Z] [--tarball] [--no-start] [--no-linger] [--uninstall]
#
# Never pipe it into `sudo sh`: it asks sudo only for the apt steps.
set -eu

BASE_URL=${RSSHD_BASE_URL:-https://rssh-ea902a.gitlab.io}
FPR=3C2F847F5734F445076275DD5961ADF201732BAC
# Tests and private mirrors only: another trusted key (file) and its fingerprint. Set by you, never by the server.
KEY_FILE=${RSSHD_KEY_FILE:-}
[ -z "$KEY_FILE" ] || FPR=${RSSHD_KEY_FPR:?RSSHD_KEY_FILE needs RSSHD_KEY_FPR}
KEYRING=/usr/share/keyrings/rsshd-archive-keyring.asc
SOURCES=/etc/apt/sources.list.d/rsshd.sources
LABEL=dev.rssh.rsshd
BIN_DIR=$HOME/.local/bin

say() { printf 'rsshd: %s\n' "$*"; }
die() { printf 'rsshd: error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

version=; mode=auto; start=1; linger=1; action=install
while [ $# -gt 0 ]; do
  case $1 in
    --version) [ $# -ge 2 ] || die "--version needs a value"; version=$2; shift ;;
    --version=*) version=${1#*=} ;;
    --tarball) mode=tarball ;;
    --no-start) start=0 ;;
    --no-linger) linger=0 ;;
    --uninstall) action=uninstall ;;
    -h|--help) usage 0 ;;
    *) printf 'rsshd: unknown option %s\n' "$1" >&2; usage 2 ;;
  esac
  shift
done
case $version in ''|[0-9]*.[0-9]*.[0-9]*) ;; *) die "bad version: $version" ;; esac
case $version in *[!0-9A-Za-z.~+-]*) die "bad version: $version" ;; esac

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT INT TERM

public_key() {
  if [ -n "$KEY_FILE" ]; then cat "$KEY_FILE"; return; fi
  cat <<'KEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBFx4FbQBEADaAST0LdsQrm8++i/1RSj49exAZDL35aEHpdlA/EBtNFEP0XnZ
eOr07VE+gjPB+Ct+dzrsvEpsHrgnnZZ846R8DDepy7vJsVDuhIkGTx8rbrUvtE+v
K+Qis59zUaU7BxQVRW7TA9vzFY8uxpOKy112UmaBN9r1eZnk1vkDuvRoJHw6Fgsi
wwFtdQt2hnO1G92m6Tv/LztLKaVl/DyDCVcML2kZkdc1YQPyIBc1e7o3to/ixUIF
4SyQqX5tQkJfVjFTbVavxlmRXe+PhQ3zD7IJRet6z5i73OPFdZt1tVmioqhfdzJ7
QLvS1Db74gdVkM2SAh6MMJ7OTA+o0Y3S25t+yFv42cm4JgORx+H0Hc3ijwE68SCR
TybGK6iVPN6qm+/gNgBJzSHJt3bupoaHb0lYp4NG4f8K9scOL5niYZfRZE4I9M+i
zkrJqiEuTzLIkRgSFUeI5TpFSkeF0Q63Au+VZCiLv8QvL6QKp3IeIQjMw72UTBBM
efPFVsTsqJ9IQGXoOI3/HyUgpalNAa/p8ixwSCosc1FiApIhF/ft2W2fQs5WhUbm
TLW+hRpPSFTpMfSIvNEc5J1TznYbO42IDN5Xz3+851cQATkB9Mb3J6bKYfUyHl5L
CDEHpoyltAJ/Xt1qYllwzp4ha3SRi8tCsv3wqFhPfHWu0afFYgixN2/UwQARAQAB
tCVSYWR1IFRvYWRlciA8cmFkdS5tLnRvYWRlckBnbWFpbC5jb20+iQI4BBMBAgAi
BQJceBW0AhsDBgsJCAcDAgYVCAIJCgsEFgIDAQIeAQIXgAAKCRBZYa3yAXMrrNkA
EAC5qFwi3n5AEtbOLmK4dNPCtvwEwWcYHZKynIeKDPvdFma8wFSLf9RjgT/asboR
UQREWiJXmuef7IDgNmLjbaPUE0oc3hyTMXBunslwnVMM/FDW4NylmXkAPhFNOqrc
/O0qeYxjqzqhYT7S2/c0PpJxRNnZYNOsgdXl5oceVvrIk7ulKgFanQdhe6YHG4V9
+W2QLd/FErN0c8RhMinAd4kGptddrv8eC7omIuxXNbGJ4+Qb1THceFVuG12LxNjH
xdiZOayHC3Rs2rSQ2M1LXlndCCwZ95BZeKoOqk2Ethy3yh9ShpSUgEW4VXCdvwwE
L/35ZjH7Xp3AfXBsj6/OWxBxyo8LL0xX8aEAO3iWqFTc5oAueZSBzK5Ff0KaaWgX
ffeMJusXvDQwSBUW+U3U5p9N67vaSoeGuGTtsnqpqS+EHTH7X1uE7PRLFgHEziV4
9mMe8KOA1XCT8P5uxKXFgpHpSMKfoEle64OW4Ou+7LvhpXEGi3ChSBwmVMGT6IEp
7bhiUj7iG9iXUksyRXkNwEudykbpQ4tV2Uf0+fFX+IMZxxUVQ7E/tnq5INphFnDr
RcqLCJqcricANuFQf3MKpKXxYglTFVWB1/Y2hyjxy54/rYnNDb387TWLey97Ot2y
JR2mfCAXBQmIA7qWVGsmPjPtIQPKONga9DYDns7R2KSt/7kCDQRceBW0ARAA1eiK
sHg3pu1PQA9R6ritXu2XMMaz96Nnm7fg+C+U5y8IV2RmbFNasluVHYJ9EoOLfJEY
2IWzWO1WUKxuMpfK7XQ6v63ESfacK/I2hy4t74YGaydvgEBbBgPyP2FlagfSirCV
FTFaVBpezyGnWAOhEqQESiz9lXYKkeQUGJ/VpHoGdJfRVhhX+U+Ig2tv973p0MdO
C8CdrGynZJBjn77z/nEkGIkEXIr0lV40zN21dHKDZKXFAby02c9/dnRGl66cB7i+
89BsPJLHCYotwVlhyt+mGLk6WeHbmRVBYgZPJxPMoPlbpemRrp/JDfdIYDHzi2Kn
WisAadqfWtoTw6tUm7OwhYlWUUz711UcLh27U4huKwEcUxQH3jo1Tnz0Osq5CJSs
tqMzoHOFcm9MqDUfwv+DKBFlav2PV8UuXTvqJWu1/K8G3+Sfr0r9NeGkRkTn8UXR
rK2/I/qcgLe7Upbo3fHccto0rQXxoH1LJrQ+t+EH+I4AX7ErWKDjsed3xxV1WoEb
ccKJ550nrnlFdihWJkz6xqQaZu3BNIeGw3GlJ7HW5oUMzWMyX+nESKUT2LDrIeMy
szKpzft5WB7brz5R6KRKj5x1+HK0ETZi1CBp0W9zGojfvhlv76twGyTmtAaAnyRK
6/fxFhZT1+0J20dS3wtYjgTTdUsOerVlgTETbYsAEQEAAYkCHwQYAQIACQUCXHgV
tAIbDAAKCRBZYa3yAXMrrIiqEACXnw6L4WifkTnQzg/x756egxq+JqbokI8HP9Ez
mrAEXThf22lnJ5wpCWuNTbMSAenfKnVIg/ngzHi/dFIpsvb0NcSPA9OFXmCsD/Ew
JlGB6TPVTLsEVMOqgAgFPd7FvWAbgdzKjb4pmw0ktuUmn8vIDeewVGT0eTRtdvi7
P7Fa/G9d3sxidYuznxpBrF0B9lW880C9ZZx4xJSFRGbOVPTclufBIWNW/p+7tYwj
jk2SHfIJ+ft8/3l9oz5Q5d5p1DZlH8VKwXo4KDPQLEo1sI2l2Zgobw637VYXLDAn
w7WbdyeVx0HCG09P5N1Jp/f6Ik2Ezh8MM58ghSOK9Rh2qFzKg9k97RVhPx9frnwn
S27FkGLX1VJWXnArrgI4Q55K7bLVrO3lJlHG0tF5W6x7IevS0H9kGDQ3HLLHUCEO
KLCYLc0Sus8bowpptbZBBQauIidUFXGT8bsbIa6Oi7uCh5bVrMbyCjvlraWUX9C7
BYytTV5nHGYFptkvUm2ded28kTx6KO9c+t5XH2HB+YiWW3nQCsBskAoEZdpfW+o4
LjwG12tVSfx6PO4nRMsynXfpVYd5P7TiTBc91BBVvnbQONTyhSFV6dBPeP/LmXkx
kDTXQw1r2pfGiREMSTmdQ62ZWJ+KsyE0Z30Yrtr03ta1Viqq5gAW/tQHOe9Yg48p
WBeX0w==
=ACLB
-----END PGP PUBLIC KEY BLOCK-----
KEY
}

as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else die "this step needs root and sudo is missing: $*"; fi
}

fetch() {  # url file
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"
  else die "needs curl or wget"; fi || die "download failed: $1"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

detect() {
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case $(uname -m) in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "no rsshd build for $(uname -m) (amd64 and arm64 only)" ;;
  esac
  case $os in linux|darwin) ;; *) die "unsupported OS: $os" ;; esac
  if [ "$mode" = auto ]; then
    mode=tarball
    if [ "$os" = linux ] && command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
      case $(dpkg --print-architecture) in amd64|arm64) mode=apt ;; esac
    fi
  fi
}

# Linger keeps this user's systemd manager (and so rsshd and its tmux) running with nobody logged in. loginctl lets a
# user set their own linger on most systems; otherwise sudo, but only without a prompt (sudo -n: the apt step's
# cached sudo, never a new password prompt in the tarball path, which promises no root).
enable_linger() {  # Linux only
  user=$(id -un)
  if [ "$linger" = 0 ]; then say "linger left off (--no-linger). To keep sessions after you log out: loginctl enable-linger $user"; return; fi
  if ! command -v loginctl >/dev/null 2>&1; then say "no loginctl here (no systemd): linger does not apply"; return; fi
  if [ "$(loginctl show-user "$user" --property=Linger --value 2>/dev/null)" = yes ]; then say "linger already on for $user"; return; fi
  if loginctl enable-linger "$user" 2>/dev/null \
    || { [ "$(id -u)" = 0 ] && loginctl enable-linger "$user"; } 2>/dev/null \
    || { command -v sudo >/dev/null 2>&1 && sudo -n loginctl enable-linger "$user"; } 2>/dev/null; then
    say "linger on for $user: rsshd and its sessions keep running after you log out (undo: loginctl disable-linger $user)"
  else
    say "could not turn on linger. To keep sessions after you log out: sudo loginctl enable-linger $user"
  fi
}

start_user_service() {  # unit name; Linux only
  enable_linger
  if [ "$start" = 0 ]; then say "not started (--no-start). Start it: systemctl --user enable --now $1"; return; fi
  # Not under `sudo sh`: that would enable root's service, not the caller's.
  if [ -z "${SUDO_USER:-}" ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable --now "$1"
    say "started for $(id -un): systemctl --user status $1"
  else
    say "no systemd user session here. Each user who wants it runs: systemctl --user enable --now $1"
  fi
}

install_apt() {
  say "adding the rSshTerm apt repo $BASE_URL/apt (key $FPR)"
  public_key > "$tmp/key.asc"
  as_root install -d -m 755 "$(dirname "$KEYRING")"
  as_root install -m 644 "$tmp/key.asc" "$KEYRING"
  cat > "$tmp/rsshd.sources" <<SRC
Types: deb
URIs: $BASE_URL/apt
Suites: stable
Components: main
Signed-By: $KEYRING
SRC
  as_root install -m 644 "$tmp/rsshd.sources" "$SOURCES"
  # Refresh only this source: quick, and someone else's broken repo cannot stop the install.
  as_root apt-get update -o Dir::Etc::sourcelist="$SOURCES" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
  if [ -n "$version" ]; then as_root apt-get install -y "rsshd=$version"; else as_root apt-get install -y rsshd; fi
  say "installed $(rsshd version 2>/dev/null || echo rsshd)"
  start_user_service rsshd.service
}

verify_download() {  # name; in $tmp
  command -v gpg >/dev/null 2>&1 || die "gpg is needed to check the download (macOS: brew install gnupg)"
  mkdir -m 700 "$tmp/gnupg"
  public_key > "$tmp/key.asc"
  GNUPGHOME=$tmp/gnupg gpg --batch --quiet --import "$tmp/key.asc" 2>/dev/null
  GNUPGHOME=$tmp/gnupg gpg --batch --status-fd 1 --verify "$tmp/SHA256SUMS.asc" "$tmp/SHA256SUMS" \
    > "$tmp/status" 2>/dev/null || die "SHA256SUMS: BAD or missing signature, nothing installed"
  grep -q "^\[GNUPG:\] VALIDSIG .*$FPR" "$tmp/status" || die "SHA256SUMS is not signed by $FPR, nothing installed"
  want=$(awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
  [ -n "$want" ] || die "$1 is not listed in SHA256SUMS"
  got=$(sha256 "$tmp/$1")
  [ "$got" = "$want" ] || die "$1: checksum mismatch, nothing installed"
  say "signature ($FPR) and checksum OK"
}

install_tarball() {
  if [ -z "$version" ]; then
    fetch "$BASE_URL/releases/latest/VERSION" "$tmp/VERSION"
    version=$(tr -d ' \r\n' < "$tmp/VERSION")
    case $version in [0-9]*.[0-9]*.[0-9]*) ;; *) die "bad VERSION from $BASE_URL" ;; esac
    case $version in *[!0-9A-Za-z.~+-]*) die "bad VERSION from $BASE_URL" ;; esac
  fi
  name=rsshd_${version}_${os}_${arch}.tar.gz
  url=$BASE_URL/releases/$version
  say "downloading $name"
  fetch "$url/$name" "$tmp/$name"
  fetch "$url/SHA256SUMS" "$tmp/SHA256SUMS"
  fetch "$url/SHA256SUMS.asc" "$tmp/SHA256SUMS.asc"
  verify_download "$name"
  mkdir "$tmp/x" && tar -xzf "$tmp/$name" -C "$tmp/x"
  mkdir -p "$BIN_DIR"
  install -m 755 "$tmp/x/rsshd" "$BIN_DIR/rsshd.new" && mv -f "$BIN_DIR/rsshd.new" "$BIN_DIR/rsshd"
  say "installed $("$BIN_DIR/rsshd" version 2>/dev/null || echo rsshd) to $BIN_DIR/rsshd"
  case :$PATH: in *:"$BIN_DIR":*) ;; *) say "add $BIN_DIR to your PATH" ;; esac

  if [ "$os" = darwin ]; then
    xattr -d com.apple.quarantine "$BIN_DIR/rsshd" 2>/dev/null || true
    agents=$HOME/Library/LaunchAgents; mkdir -p "$agents"
    sed "s|/usr/local/bin/rsshd|$BIN_DIR/rsshd|" "$tmp/x/$LABEL.plist" > "$agents/$LABEL.plist"
    if [ "$start" = 1 ]; then
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$agents/$LABEL.plist"
      say "started: launchd agent $LABEL ($agents/$LABEL.plist)"
    else
      say "not started (--no-start). Start it: launchctl bootstrap gui/$(id -u) $agents/$LABEL.plist"
    fi
  else
    units=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user; mkdir -p "$units"
    sed "s|^ExecStart=/usr/bin/rsshd|ExecStart=$BIN_DIR/rsshd|" "$tmp/x/rsshd.service" > "$units/rsshd.service"
    start_user_service rsshd.service
  fi
}

uninstall() {
  if [ "$os" = darwin ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$BIN_DIR/rsshd"
  else
    units=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    if [ -f "$units/rsshd.service" ]; then
      systemctl --user disable --now rsshd.service 2>/dev/null || true
      rm -f "$units/rsshd.service"
      systemctl --user daemon-reload 2>/dev/null || true
    fi
    rm -f "$BIN_DIR/rsshd"
    if command -v dpkg >/dev/null 2>&1 && dpkg -s rsshd >/dev/null 2>&1; then as_root apt-get remove -y rsshd; fi
    if [ -e "$SOURCES" ] || [ -e "$KEYRING" ]; then as_root rm -f "$SOURCES" "$KEYRING"; fi
  fi
  say "removed. Sessions still running in tmux are left alone: tmux -L rsshd ls"
}

detect
if [ "$action" = uninstall ]; then uninstall; exit 0; fi
case $mode in
  apt) install_apt ;;
  tarball) install_tarball ;;
esac
