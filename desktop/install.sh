#!/bin/sh
# Installs rSshTerm, the desktop SSH terminal.   curl -fsSL https://rssh-ea902a.gitlab.io/desktop/install.sh | sh
#
# Debian/Ubuntu: adds the signed rSshTerm apt repo (the key is embedded below; apt checks it) and runs
#   `apt-get install rsshterm` with sudo, so updates come with apt.
# Other Linux: the tarball from latest.json, checked against its sha256, into ~/.local/opt/rsshterm (no root).
# --appimage: the AppImage (GTK 4 bundled; glibc >= 2.39) to ~/.local/bin/rsshterm.AppImage; it updates itself.
# macOS: the notarized app (zip) from latest.json, checked against its sha256, into /Applications (or ~/Applications).
#
#   sh install.sh [--tarball|--appimage] [--uninstall]   RSSHTERM_BASE_URL: another site (tests, mirrors)
set -eu

BASE_URL=${RSSHTERM_BASE_URL:-https://rssh-ea902a.gitlab.io}
KEYRING=/usr/share/keyrings/rsshd-archive-keyring.asc   # shared with rsshd: one apt source, one Signed-By
SOURCES=/etc/apt/sources.list.d/rsshd.sources
OPT=$HOME/.local/opt/rsshterm; BIN=$HOME/.local/bin
APP=rSshTerm.app

say() { printf 'rsshterm: %s\n' "$*"; }
die() { printf 'rsshterm: error: %s\n' "$*" >&2; exit 1; }
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
fetch() { curl -fsSL --retry 2 -o "$2" "$1" || die "download failed: $1"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

mode=auto; action=install
for a in "$@"; do
  case $a in --tarball) mode=tarball ;; --appimage) mode=appimage ;; --uninstall) action=uninstall ;; *) sed -n '2,10p' "$0"; exit 2 ;; esac
done
os=$(uname -s); arch=$(uname -m)
case $arch in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT INT TERM

public_key() {  # RSSHTERM_KEY_FILE: tests and private mirrors only, set by you, never by the server
  if [ -n "${RSSHTERM_KEY_FILE:-}" ]; then cat "$RSSHTERM_KEY_FILE"; return; fi
  cat <<'KEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
WBeX0w==
=ACLB
-----END PGP PUBLIC KEY BLOCK-----
KEY
}

# latest.json -> "<url> <sha256>" of one platform (the file has one asset per line: desktop/packaging/scripts/latest-json.sh)
asset() {
  fetch "$BASE_URL/desktop/latest.json" "$tmp/latest.json"
  line=$(sed -n "s|.*\"$1\": *{\"url\": *\"\([^\"]*\)\", *\"sha256\": *\"\([0-9a-f]\{64\}\)\".*|\1 \2|p" "$tmp/latest.json")
  [ -n "$line" ] || die "no rSshTerm build for $1 yet ($BASE_URL/desktop/latest.json)"
  echo "$line"
}

download() {  # platform file -> verified $tmp/<file>
  a=$(asset "$1") || exit 1
  url=${a% *}; want=${a#* }
  case $url in "$BASE_URL"/*) ;; *) die "latest.json points outside $BASE_URL: $url" ;; esac
  say "downloading $url"; fetch "$url" "$tmp/$2"
  [ "$(sha256 "$tmp/$2")" = "$want" ] || die "$2: checksum mismatch, nothing installed"
  say "checksum OK"
}

install_apt() {
  if ! grep -qs "$BASE_URL/apt" "$SOURCES"; then
    say "adding the apt repo $BASE_URL/apt"
    public_key > "$tmp/key.asc"
    printf 'Types: deb\nURIs: %s/apt\nSuites: stable\nComponents: main\nSigned-By: %s\n' "$BASE_URL" "$KEYRING" > "$tmp/src"
    as_root install -D -m 644 "$tmp/key.asc" "$KEYRING"
    as_root install -m 644 "$tmp/src" "$SOURCES"
  fi
  as_root apt-get update -o Dir::Etc::sourcelist="$SOURCES" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
  as_root apt-get install -y rsshterm
  say "installed: rsshterm (updates come with apt)"
}

install_tarball() {
  download "linux-$arch" rsshterm.tar.gz
  mkdir "$tmp/x" && tar -xzf "$tmp/rsshterm.tar.gz" -C "$tmp/x"
  set -- "$tmp"/x/rsshterm-*/bin/rsshterm
  [ -x "$1" ] || die "the tarball has no rsshterm-*/bin/rsshterm"
  rm -rf "$OPT.new"; mkdir -p "$(dirname "$OPT")" "$BIN"; mv "${1%/bin/rsshterm}" "$OPT.new"
  rm -rf "$OPT"; mv "$OPT.new" "$OPT"; ln -sf "$OPT/bin/rsshterm" "$BIN/rsshterm"
  say "installed $OPT, command $BIN/rsshterm"
  case :$PATH: in *:"$BIN":*) ;; *) say "add $BIN to your PATH" ;; esac
}

install_appimage() {
  download "linux-$arch-appimage" rsshterm.AppImage
  mkdir -p "$BIN"; install -m 755 "$tmp/rsshterm.AppImage" "$BIN/rsshterm.AppImage.new"
  mv -f "$BIN/rsshterm.AppImage.new" "$BIN/rsshterm.AppImage"
  say "installed $BIN/rsshterm.AppImage (updates itself)"
  case :$PATH: in *:"$BIN":*) ;; *) say "add $BIN to your PATH" ;; esac
}

install_mac() {
  download macos-universal rsshterm.zip
  mkdir "$tmp/x"
  if command -v ditto >/dev/null 2>&1; then ditto -x -k "$tmp/rsshterm.zip" "$tmp/x"; else unzip -q "$tmp/rsshterm.zip" -d "$tmp/x"; fi
  [ -d "$tmp/x/$APP" ] || die "the zip has no $APP"
  dest=/Applications; [ -w "$dest" ] || dest=$HOME/Applications
  mkdir -p "$dest"; rm -rf "${dest:?}/$APP"; cp -R "$tmp/x/$APP" "$dest/"
  say "installed $dest/$APP (notarized; updates from the app)"
}

uninstall() {
  if [ "$os" = Darwin ]; then rm -rf "/Applications/$APP" "$HOME/Applications/$APP"; say "removed"; return; fi
  rm -rf "$OPT"; rm -f "$BIN/rsshterm" "$BIN/rsshterm.AppImage"
  if command -v dpkg >/dev/null 2>&1 && dpkg -s rsshterm >/dev/null 2>&1; then as_root apt-get remove -y rsshterm; fi
  # The apt source is shared with rsshd: it stays while rsshd is installed.
  if [ -e "$SOURCES" ] && ! dpkg -s rsshd >/dev/null 2>&1; then as_root rm -f "$SOURCES" "$KEYRING"; fi
  say "removed"
}

if [ "$action" = uninstall ]; then uninstall; exit 0; fi
case $os in
  Darwin) install_mac ;;
  Linux)
    if [ "$mode" = appimage ]; then install_appimage
    elif [ "$mode" = auto ] && command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then install_apt
    else install_tarball; fi ;;
  *) die "unsupported OS: $os" ;;
esac
