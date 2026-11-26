#!/bin/sh
# End-to-end test of the shared Pages site and desktop/install.sh with a THROWAWAY key (never the real one):
#   1. build-site.sh with an rsshd dist and a desktop dist -> one signed apt repo with both, signed latest.json
#   2a. an rsshd release without the update key keeps desktop and its manifest signature; a changed unsigned one fails
#   2. a "next desktop release" pipeline: fetch-release.sh takes rsshd back from the served site, the new site keeps it
#   3. desktop/install.sh: apt path, tarball path, macOS path (uname shim), uninstall; a tampered checksum is refused
# Fake packages (shell scripts) stand in for the real binaries, so this runs before the app exists.
# Runs as root in a clean debian/ubuntu container, from the repo root. Usage: site-install.sh [rsshd-dist-dir]
set -eu
root=$(pwd)
export DEBIAN_FRONTEND=noninteractive
# shellcheck disable=SC1091
. /etc/os-release
echo "== $PRETTY_NAME"
apt-get -qq update
apt-get -qq install -y --no-install-recommends gnupg gpgv reprepro python3 ca-certificates curl jq unzip openssl >/dev/null

t=$(mktemp -d); export GNUPGHOME="$t/gen"; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'rssh test <test@invalid>' rsa3072 sign 1d
gpg --batch --armor --export-secret-keys > "$t/secret.asc"
fpr=$(gpg --batch --with-colons --list-keys | awk -F: '/^fpr/{print $10; exit}')
gpg --batch --armor --export "$fpr" > "$t/public.asc"
gpgconf --kill gpg-agent; unset GNUPGHOME
export GPG_PRIVATE_KEY_ASC="$t/secret.asc" RSSHD_GPG_FINGERPRINT="$fpr" RSSHD_PUBLIC_KEY="$t/public.asc"
site=http://127.0.0.1:8766; export SITE_URL=$site
arch=$(dpkg --print-architecture)

fake_deb() {  # name version dir
  p=$t/pkg-$1-$2; mkdir -p "$p/DEBIAN" "$p/usr/bin"
  printf 'Package: %s\nVersion: %s\nSection: net\nPriority: optional\nArchitecture: %s\nMaintainer: test <test@invalid>\nDescription: fake %s\n' \
    "$1" "$2" "$arch" "$1" > "$p/DEBIAN/control"
  printf '#!/bin/sh\necho "%s %s"\n' "$1" "$2" > "$p/usr/bin/$1"; chmod 755 "$p/usr/bin/$1"
  dpkg-deb --root-owner-group -b "$p" "$3/${1}_${2}_$arch.deb" >/dev/null
}
desktop_dist() {  # version dir
  d=$2; top=rsshterm-$1-linux-$arch; mkdir -p "$d" "$t/tar-$1/$top/bin"
  fake_deb rsshterm "$1" "$d"
  printf '#!/bin/sh\necho "rsshterm %s"\n' "$1" > "$t/tar-$1/$top/bin/rsshterm"; chmod 755 "$t/tar-$1/$top/bin/rsshterm"
  tar -czf "$d/rsshterm_$1_linux_$arch.tar.gz" -C "$t/tar-$1" "$top"
  printf '#!/bin/sh\necho "rsshterm %s appimage"\n' "$1" > "$d/rsshterm_$1_linux_$arch.AppImage"
  echo 2026-11-26T10:00:00Z > "$d/PUBLISHED"
  python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("rSshTerm.app/Contents/MacOS/rSshTerm","#!/bin/sh\n"); z.writestr("rSshTerm.app/Contents/Info.plist","<plist/>")' \
    "$d/rsshterm_$1_macos_universal.zip"
  printf 'Release "%s"\nwith a second line\n' "$1" > "$d/NOTES"
  (cd "$d" && sha256sum -- * > SHA256SUMS)
}

# rsshd: the real snapshot dist when given, else a fake one.
if [ -n "${1:-}" ]; then
  cp -r "$1" "$t/rsshd"; rver=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$t/rsshd/metadata.json")
  rm -f "$t/rsshd/metadata.json" "$t/rsshd/SHA256SUMS.asc"
else
  rver=0.9.0; mkdir -p "$t/rsshd"; fake_deb rsshd "$rver" "$t/rsshd"
  for p in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do echo "$p" > "$t/rsshd/rsshd_${rver}_$p.tar.gz"; done
  (cd "$t/rsshd" && sha256sum -- * > SHA256SUMS)
fi
desktop_dist 1.0.0 "$t/d1"

uk=$root/desktop/packaging/scripts/update-key.sh
upub=$(sh "$uk" new "$t/update.pem" 2>/dev/null | sed 's/.*: //')

# 1. Both components, latest.json signed.
DESKTOP_UPDATE_SIGNING_KEY=$t/update.pem RSSHD_DIST=$t/rsshd RSSHD_VERSION=$rver DESKTOP_DIST=$t/d1 DESKTOP_VERSION=1.0.0 \
  sh "$root/packaging/site/build-site.sh" "$t/public"
for f in apt/dists/stable/InRelease install.sh "releases/$rver/SHA256SUMS.asc" homebrew/rsshd.rb desktop/install.sh \
         desktop/latest.json desktop/releases/1.0.0/SHA256SUMS.asc desktop/releases/latest/VERSION; do
  [ -s "$t/public/$f" ] || { echo "FAIL: site lacks $f" >&2; exit 1; }
done
jq -e --arg v 1.0.0 '.version == $v and .published == "2026-11-26T10:00:00Z" and (.notes | startswith("Release \"1.0.0\"\nwith"))' "$t/public/desktop/latest.json" >/dev/null
want=$(sha256sum "$t/d1/rsshterm_1.0.0_linux_$arch.tar.gz" | cut -d' ' -f1)
jq -e --arg a "linux-$arch" --arg s "$want" --arg u "$site/desktop/releases/1.0.0/rsshterm_1.0.0_linux_$arch.tar.gz" \
  '.assets[$a].sha256 == $s and .assets[$a].url == $u and (.assets["macos-universal"].url | endswith("_macos_universal.zip"))
   and (.assets[$a + "-appimage"].url | endswith(".AppImage"))' \
  "$t/public/desktop/latest.json" >/dev/null
grep -q '^Package: rsshd$' "$t/public/apt/dists/stable/main/binary-$arch/Packages"
grep -q '^Package: rsshterm$' "$t/public/apt/dists/stable/main/binary-$arch/Packages"
sh "$uk" verify "$upub" "$t/public/desktop/latest.json" "$t/public/desktop/latest.json.sig"
# The version-less lists (the GitHub release's stable names): signed, and each line is a versioned file renamed.
gpg --batch --quiet --dearmor --output "$t/trusted.gpg" "$t/public.asc"
for l in "releases/$rver/rsshd_SHA256SUMS" desktop/releases/1.0.0/rsshterm_SHA256SUMS; do
  gpgv --keyring "$t/trusted.gpg" "$t/public/$l.asc" "$t/public/$l" 2>/dev/null || { echo "FAIL: $l.asc" >&2; exit 1; }
done
grep -q "  rsshterm_linux_$arch.AppImage\$" "$t/public/desktop/releases/1.0.0/rsshterm_SHA256SUMS"
grep -q "  rsshd_linux_amd64.tar.gz\$" "$t/public/releases/$rver/rsshd_SHA256SUMS"
mkdir "$t/plain"; cp "$t/d1/rsshterm_1.0.0_${arch}.deb" "$t/plain/rsshterm_${arch}.deb"
(cd "$t/plain" && cp "$t/public/desktop/releases/1.0.0/rsshterm_SHA256SUMS" . && sha256sum --ignore-missing -c rsshterm_SHA256SUMS >/dev/null)
DRY_RUN=1 sh "$root/packaging/github/publish-release.sh" desktop 1.0.0 "$t/public" 2>&1 |
  grep -q "assets?name=rsshd_linux_amd64.tar.gz" || { echo "FAIL: GitHub dry run" >&2; exit 1; }
# Without PRODUCT_PAGE the root is the downloads landing, which also stays at /rsshd.html.
if ! grep -q 'rSshTerm downloads' "$t/public/rsshd.html" || ! cmp -s "$t/public/rsshd.html" "$t/public/index.html"; then
  echo "FAIL: rsshd.html / index.html landing" >&2; exit 1
fi
echo "site with both, signed manifest: OK"

serve() {  # dir
  [ -z "${srv:-}" ] || { kill "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true; }
  (cd "$1" && exec python3 -m http.server 8766 --bind 127.0.0.1 >/dev/null 2>&1) & srv=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fs "$site/" >/dev/null 2>&1 && return; sleep 0.5; done
  echo "server did not start" >&2; exit 1
}
trap 'kill ${srv:-0} 2>/dev/null || true' EXIT
serve "$t/public"

# 2a. The next rsshd release (no update key in that job): desktop comes back from the site with its signature.
dver=$(sh "$root/packaging/site/fetch-release.sh" "$site" desktop "$t/fetched-desktop")
[ "$dver" = 1.0.0 ] && [ -s "$t/fetched-desktop/latest.json.sig" ]
RSSHD_DIST=$t/rsshd RSSHD_VERSION=$rver DESKTOP_DIST=$t/fetched-desktop DESKTOP_VERSION=$dver \
  sh "$root/packaging/site/build-site.sh" "$t/public-r"
grep -q '^Package: rsshterm$' "$t/public-r/apt/dists/stable/main/binary-$arch/Packages"
sh "$uk" verify "$upub" "$t/public-r/desktop/latest.json" "$t/public-r/desktop/latest.json.sig"
cmp "$t/public/desktop/latest.json" "$t/public-r/desktop/latest.json"
# A changed manifest without the key: refused when a signature is required.
if REQUIRE_UPDATE_SIGNATURE=1 DESKTOP_DIST=$t/d2-unsigned DESKTOP_VERSION=1.0.9 sh -c 'mkdir -p "$DESKTOP_DIST"; cp "$0"/* "$DESKTOP_DIST"/; exec sh "$1" "$2"' \
   "$t/d1" "$root/packaging/site/build-site.sh" "$t/public-u" 2>/dev/null; then
  echo "FAIL: unsigned latest.json published with REQUIRE_UPDATE_SIGNATURE=1" >&2; exit 1
fi

# 2b. The next desktop release: rsshd comes back from the served site, verified, and stays.
got=$(sh "$root/packaging/site/fetch-release.sh" "$site" rsshd "$t/fetched-rsshd")
[ "$got" = "$rver" ] || { echo "FAIL: fetched rsshd $got, want $rver" >&2; exit 1; }
[ -z "$(sh "$root/packaging/site/fetch-release.sh" "$site/nothing-here" desktop "$t/none")" ]
desktop_dist 1.1.0 "$t/d2"
# A demo static-sites checkout (the product page's one source): / becomes the product page, nothing else is lost.
mkdir -p "$t/static/sites/rssh/media"
printf '<!doctype html><link rel="canonical" href="https://example.com/">\n<h1>demo product page</h1>\n' \
  > "$t/static/sites/rssh/index.html"
echo demo > "$t/static/sites/rssh/style.css"; echo demo > "$t/static/sites/rssh/media/demo.png"
DESKTOP_UPDATE_SIGNING_KEY=$t/update.pem RSSHD_DIST=$t/fetched-rsshd RSSHD_VERSION=$got DESKTOP_DIST=$t/d2 DESKTOP_VERSION=1.1.0 \
  PRODUCT_PAGE=1 PRODUCT_PAGE_REQUIRED=1 STATIC_SITE_DIR=$t/static sh "$root/packaging/site/build-site.sh" "$t/public2"
grep -q 'demo product page' "$t/public2/index.html" || { echo "FAIL: / is not the product page" >&2; exit 1; }
for f in rsshd.html install.sh apt/dists/stable/InRelease desktop/latest.json desktop/latest.json.sig rssh-archive-keyring.asc \
         homebrew/rsshd.rb style.css media/demo.png .nojekyll media/ios-files.gif; do
  [ -e "$t/public2/$f" ] || { echo "FAIL: site with the product page lacks $f" >&2; exit 1; }
done
grep -q 'rSshTerm downloads' "$t/public2/rsshd.html"
# A page that would add a release path (here an installer, in a build without rsshd) is refused.
mkdir -p "$t/static-bad/sites/rssh"; cp "$t/static/sites/rssh/index.html" "$t/static-bad/sites/rssh/"
echo 'echo planted' > "$t/static-bad/sites/rssh/install.sh"
if DESKTOP_UPDATE_SIGNING_KEY=$t/update.pem DESKTOP_DIST=$t/d2 DESKTOP_VERSION=1.1.0 PRODUCT_PAGE=1 STATIC_SITE_DIR=$t/static-bad \
   sh "$root/packaging/site/build-site.sh" "$t/public-bad" 2>/dev/null; then echo "FAIL: page planted install.sh" >&2; exit 1; fi
# No page when it is required: nothing built; when it is not: a warning and the landing at /.
if RSSHD_DIST=$t/fetched-rsshd RSSHD_VERSION=$got PRODUCT_PAGE=1 PRODUCT_PAGE_REQUIRED=1 STATIC_SITE_DIR=$t/no-such-dir \
   sh "$root/packaging/site/build-site.sh" "$t/public-np" 2>/dev/null; then echo "FAIL: missing page accepted" >&2; exit 1; fi
RSSHD_DIST=$t/fetched-rsshd RSSHD_VERSION=$got PRODUCT_PAGE=1 STATIC_SITE_DIR=$t/no-such-dir \
  sh "$root/packaging/site/build-site.sh" "$t/public-np2" 2>/dev/null
grep -q 'rSshTerm downloads' "$t/public-np2/index.html"
echo "product page at /, release files kept: OK"
grep -q '^Package: rsshd$' "$t/public2/apt/dists/stable/main/binary-$arch/Packages"
grep -q '^Version: 1.1.0$' "$t/public2/apt/dists/stable/main/binary-$arch/Packages"
sh "$uk" verify "$upub" "$t/public2/desktop/latest.json" "$t/public2/desktop/latest.json.sig"
[ "$(cat "$t/public2/releases/latest/VERSION")" = "$rver" ] && [ -s "$t/public2/install.sh" ]
# A file changed on the site after signing is refused by fetch-release.
cp -r "$t/public" "$t/bad"; echo tampered >> "$t/bad/releases/$rver/SHA256SUMS"; serve "$t/bad"
if sh "$root/packaging/site/fetch-release.sh" "$site" rsshd "$t/x" 2>/dev/null; then echo "FAIL: tampered site accepted" >&2; exit 1; fi
echo "merge across releases: OK"
serve "$t/public2"

# 3. desktop/install.sh
export RSSHTERM_BASE_URL=$site RSSHTERM_KEY_FILE="$t/public.asc"
sh "$root/desktop/install.sh" > "$t/apt.log" 2>&1 || { cat "$t/apt.log"; exit 1; }
[ "$(rsshterm)" = "rsshterm 1.1.0" ]
grep -q "^Signed-By: /usr/share/keyrings/rsshd-archive-keyring.asc" /etc/apt/sources.list.d/rsshd.sources
sh "$root/desktop/install.sh" --uninstall >/dev/null 2>&1
[ ! -e /usr/bin/rsshterm ] && [ ! -e /etc/apt/sources.list.d/rsshd.sources ]
echo "install.sh apt: OK"

sh "$root/desktop/install.sh" --tarball > "$t/tar.log" 2>&1 || { cat "$t/tar.log"; exit 1; }
[ "$("$HOME/.local/bin/rsshterm")" = "rsshterm 1.1.0" ]
sh "$root/desktop/install.sh" --uninstall >/dev/null 2>&1; [ ! -e "$HOME/.local/opt/rsshterm" ]
echo "install.sh tarball: OK"

sh "$root/desktop/install.sh" --appimage > "$t/ai.log" 2>&1 || { cat "$t/ai.log"; exit 1; }
[ "$("$HOME/.local/bin/rsshterm.AppImage")" = "rsshterm 1.1.0 appimage" ]
sh "$root/desktop/install.sh" --uninstall >/dev/null 2>&1; [ ! -e "$HOME/.local/bin/rsshterm.AppImage" ]
echo "install.sh appimage: OK"

mkdir -p "$t/shim"
cat > "$t/shim/uname" <<'SHIM'
#!/bin/sh
case $1 in -s) echo Darwin ;; -m) echo arm64 ;; *) exec /bin/uname "$@" ;; esac
SHIM
chmod 755 "$t/shim/uname"
mkdir -p /Applications
PATH=$t/shim:$PATH sh "$root/desktop/install.sh" > "$t/mac.log" 2>&1 || { cat "$t/mac.log"; exit 1; }
[ -f /Applications/rSshTerm.app/Contents/Info.plist ]
PATH=$t/shim:$PATH sh "$root/desktop/install.sh" --uninstall >/dev/null; [ ! -e /Applications/rSshTerm.app ]
echo "install.sh macOS (shim): OK"

sed -i "s/\"sha256\": \"[0-9a-f]\{4\}/\"sha256\": \"0000/" "$t/public2/desktop/latest.json"
if sh "$root/desktop/install.sh" --tarball > "$t/tamper.log" 2>&1; then echo "FAIL: wrong checksum accepted" >&2; exit 1; fi
grep -q 'checksum mismatch' "$t/tamper.log" && [ ! -e "$HOME/.local/opt/rsshterm" ]
echo "install.sh tamper: refused OK"
echo "site-install: OK on $PRETTY_NAME"
