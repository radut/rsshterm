#!/bin/sh
# End-to-end test of the release path with a THROWAWAY key (never the real one): publish.sh signs SHA256SUMS and
# builds the apt repo, a local web server serves it, and apt installs rsshd from it through a deb822 source with
# Signed-By. Also checks that apt REFUSES the repo when Signed-By names another key.
# Runs as root in a clean debian/ubuntu container. Usage: apt-repo.sh <dist-dir>
# TEST_PASSPHRASE=1 gives the throwaway key a passphrase (a file, as the GitLab file variable gives it).
set -eu
dist=$(cd "${1:-dist}" && pwd)
here=$(cd "$(dirname "$0")/.." && pwd)
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
echo "== $PRETTY_NAME, passphrase=${TEST_PASSPHRASE:-0}"
apt-get -qq update
apt-get -qq install -y --no-install-recommends gnupg gpgv reprepro python3 ca-certificates curl >/dev/null

t=$(mktemp -d); export GNUPGHOME="$t/gen"; mkdir -m 700 "$GNUPGHOME"
if [ "${TEST_PASSPHRASE:-0}" = 1 ]; then
  (umask 077; echo 'throwaway test passphrase' > "$t/pass")
  gpg --batch --pinentry-mode loopback --passphrase-file "$t/pass" --quick-gen-key 'rsshd test <test@invalid>' rsa3072 sign 1d
  gpg --batch --pinentry-mode loopback --passphrase-file "$t/pass" --armor --export-secret-keys > "$t/secret.asc"
  export GPG_PASSPHRASE="$t/pass"
else
  gpg --batch --passphrase '' --quick-gen-key 'rsshd test <test@invalid>' rsa3072 sign 1d
  gpg --batch --armor --export-secret-keys > "$t/secret.asc"
  unset GPG_PASSPHRASE
fi
fpr=$(gpg --batch --with-colons --list-keys | awk -F: '/^fpr/{print $10; exit}')
gpg --batch --armor --export "$fpr" > "$t/public.asc"
gpgconf --kill gpg-agent; unset GNUPGHOME

# A copy of dist/: publish.sh writes SHA256SUMS.asc into it.
cp -r "$dist" "$t/dist"
ver=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$dist/metadata.json")
GPG_PRIVATE_KEY_ASC="$t/secret.asc" RSSHD_GPG_FINGERPRINT="$fpr" RSSHD_VERSION="$ver" \
  RSSHD_PUBLIC_KEY="$t/public.asc" sh "$here/scripts/publish.sh" "$t/dist" "$t/public"
[ -s "$t/public/apt/dists/stable/InRelease" ] && [ -s "$t/public/releases/latest/SHA256SUMS.asc" ]
grep -q '^Origin: rsshd' "$t/public/apt/dists/stable/Release"
if [ -e "$t/public/apt/conf" ] || [ -e "$t/public/apt/db" ]; then echo "FAIL: reprepro internals published" >&2; exit 1; fi

(cd "$t/public" && exec python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1) &
srv=$!; trap 'kill $srv 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do python3 -c 'import urllib.request;urllib.request.urlopen("http://127.0.0.1:8765/")' 2>/dev/null && break; sleep 0.5; done

# Wrong key first: apt must refuse the repo.
mkdir -p /etc/apt/keyrings
cp "$here/rssh-archive-keyring.asc" /etc/apt/keyrings/wrong.asc
cat > /etc/apt/sources.list.d/rsshd.sources <<SRC
Types: deb
URIs: http://127.0.0.1:8765/apt
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/wrong.asc
SRC
if apt-get update -o Dir::Etc::sourcelist=/dev/null 2>&1 | tee "$t/wrong.log" | grep -q 'NO_PUBKEY\|not signed\|is not signed'; then
  echo "wrong key: refused as expected"
else
  cat "$t/wrong.log"; echo "FAIL: apt accepted the repo with the wrong Signed-By key" >&2; exit 1
fi

cp "$t/public.asc" /etc/apt/keyrings/rsshd-test.asc
sed -i 's|/etc/apt/keyrings/wrong.asc|/etc/apt/keyrings/rsshd-test.asc|' /etc/apt/sources.list.d/rsshd.sources
apt-get update -o Dir::Etc::sourcelist=/dev/null 2>&1 | tail -3
apt-cache policy rsshd | sed -n 1,6p
apt-get -qq install -y rsshd >/dev/null
rsshd version

# install.sh, apt path: from scratch, trusting the throwaway key through the test override.
apt-get -qq purge -y rsshd >/dev/null; rm -f /etc/apt/sources.list.d/rsshd.sources /etc/apt/keyrings/*.asc
export RSSHD_BASE_URL=http://127.0.0.1:8765 RSSHD_KEY_FILE="$t/public.asc" RSSHD_KEY_FPR="$fpr"
sh "$here/../install.sh" --no-start > "$t/install-apt.log" 2>&1 || { cat "$t/install-apt.log"; exit 1; }
grep -q "^Signed-By: /usr/share/keyrings/rsshd-archive-keyring.asc" /etc/apt/sources.list.d/rsshd.sources
/usr/bin/rsshd version | grep -qF "$ver"
sh "$here/../install.sh" --uninstall > "$t/uninstall.log" 2>&1 || { cat "$t/uninstall.log"; exit 1; }
[ ! -e /usr/bin/rsshd ] && [ ! -e /etc/apt/sources.list.d/rsshd.sources ]

# install.sh, tarball path (macOS and non-apt Linux): signature + checksum, then ~/.local/bin and a user unit.
sh "$here/../install.sh" --tarball --no-start
"$HOME/.local/bin/rsshd" version | grep -qF "$ver"
grep -q "^ExecStart=$HOME/.local/bin/rsshd serve" "$HOME/.config/systemd/user/rsshd.service"
sh "$here/../install.sh" --uninstall > "$t/uninstall.log" 2>&1 || { cat "$t/uninstall.log"; exit 1; }
[ ! -e "$HOME/.local/bin/rsshd" ]

# Tampered checksum file: the signature no longer matches, nothing is installed.
sums=$t/public/releases/$ver/SHA256SUMS
cp "$sums" "$t/sums.orig"; sed -i '1y/0123456789abcdef/1234567890bcdefa/' "$sums"   # every hex digit to another
# A tamper that leaves the file unchanged would pass vacuously (a hash starting with the digit it was set to did).
if cmp -s "$sums" "$t/sums.orig"; then echo "FAIL: tamper left SHA256SUMS unchanged" >&2; exit 1; fi
if sh "$here/../install.sh" --tarball --no-start 2>"$t/tamper.log"; then echo "FAIL: tampered SHA256SUMS accepted" >&2; exit 1; fi
grep -q 'BAD or missing signature' "$t/tamper.log" && [ ! -e "$HOME/.local/bin/rsshd" ]
cp "$t/sums.orig" "$sums"
# Right key file but another fingerprint: refused too.
if RSSHD_KEY_FPR=3C2F847F5734F445076275DD5961ADF201732BAC sh "$here/../install.sh" --tarball --no-start 2>/dev/null; then
  echo "FAIL: signature by an unexpected key accepted" >&2; exit 1
fi
echo "install.sh: apt, tarball, uninstall, tamper and wrong-key checks OK"
echo "apt-repo: OK on $PRETTY_NAME (signed by throwaway $fpr)"
