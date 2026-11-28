#!/bin/sh
# Job desktop:macos-dmg ("build dmg"), on the GitLab runner on the Mac (tag macos; docs/desktop/mac-dmg.md):
#
#   1. the App Store Connect key from the CI variables (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 file) into a job-local
#      ASC_DIR (0600), never ~/.appstoreconnect, which other projects share; removed on exit;
#   2. the notarized DMG: `make -C apple mac-dmg VERSION=<v>` (apple/scripts/mac-dmg.sh: Developer ID from the login
#      keychain, which the runner can use because it runs as a LaunchAgent in the logged-in user's GUI session);
#   3. its checks: the versioned name rsshterm_<v>_macos_universal.dmg, the sha256 of the file = result.env's;
#   4. the generic package registry desktop-macos/<v>/<name> (job token), read back and compared;
#   5. <out-env> (dotenv): MACOS_DMG_VERSION, MACOS_DMG_NAME, MACOS_DMG_SHA256 for desktop:macos-dmg-attach, which
#      starts the attach pipeline on main (desktop:macos-attach: re-signed SHA256SUMS + latest.json, Pages, releases).
#
# Usage: ci-macos-dmg.sh <X.Y.Z> <out-env>
# Env:   CI_API_V4_URL, CI_PROJECT_ID, CI_JOB_TOKEN, CI_PROJECT_DIR (GitLab), the three ASC_* variables;
#        MAC_DMG_BUILD (default: make -C apple mac-dmg), MAC_DMG_OUT (default apple/build/mac-dmg/<v>).
set -eu
ver=$1; env_out=$2
root=$(cd "$(dirname "$0")/../../.." && pwd)
die() { echo "ci-macos-dmg: $*" >&2; exit 1; }
case $ver in [0-9]*.[0-9]*.[0-9]*) ;; *) die "version must be X.Y.Z (got '$ver')" ;; esac
case $ver in *[!0-9.]*|*.*.*.*) die "version must be X.Y.Z (got '$ver')" ;; esac
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

# 1. The key, job-local.
if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ] || [ ! -r "${ASC_KEY_P8:-/nonexistent}" ]; then
  die "ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 (file) are not set: protected variables, so only a protected tag or main has them"
fi
asc=${CI_PROJECT_DIR:?}/.asc
trap 'rm -rf "$asc"' EXIT INT TERM
rm -rf "$asc"
(umask 077 && mkdir -p "$asc/private_keys" && cp "$ASC_KEY_P8" "$asc/private_keys/AuthKey_$ASC_KEY_ID.p8" &&
  printf 'ASC_KEY_ID=%s\nASC_ISSUER_ID=%s\n' "$ASC_KEY_ID" "$ASC_ISSUER_ID" > "$asc/asc.env")

# 2. The DMG.
out=${MAC_DMG_OUT:-$root/apple/build/mac-dmg/$ver}
name=rsshterm_${ver}_macos_universal.dmg
rm -f "$out/result.env"
# shellcheck disable=SC2086 # MAC_DMG_BUILD is a command line
VERSION=$ver OUT=$out ASC_DIR=$asc ${MAC_DMG_BUILD:-make -C "$root/apple" mac-dmg}

# 3. What it made.
[ -s "$out/result.env" ] || die "the build left no $out/result.env"
dmg=$(sed -n 's/^DMG=//p' "$out/result.env")
want=$(sed -n 's/^SHA256=//p' "$out/result.env")
[ "${dmg##*/}" = "$name" ] || die "the build made ${dmg##*/}, not $name"
[ -f "$dmg" ] || die "no file $dmg"
sum=$(sha "$dmg")
[ "$sum" = "$want" ] || die "$name has sha256 $sum, result.env says $want"

# 4. The registry, read back.
url="${CI_API_V4_URL:?}/projects/${CI_PROJECT_ID:?}/packages/generic/desktop-macos/$ver/$name"
curl --fail --silent --show-error --retry 2 --header "JOB-TOKEN: ${CI_JOB_TOKEN:?}" --upload-file "$dmg" "$url" >/dev/null
back=$(mktemp); trap 'rm -rf "$asc" "$back"' EXIT INT TERM
curl --fail --silent --show-error --retry 2 --header "JOB-TOKEN: $CI_JOB_TOKEN" -o "$back" "$url"
[ "$(sha "$back")" = "$sum" ] || die "the registry copy of $name differs from the build"

# 5. For the attach pipeline.
printf 'MACOS_DMG_VERSION=%s\nMACOS_DMG_NAME=%s\nMACOS_DMG_SHA256=%s\n' "$ver" "$name" "$sum" > "$env_out"
echo "ci-macos-dmg: desktop-macos/$ver/$name ($sum) uploaded; attach next"
