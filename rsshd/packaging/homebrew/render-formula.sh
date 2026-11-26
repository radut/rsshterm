#!/bin/sh
# Renders rsshd.rb from the template with the checksums of a release.
# Usage: render-formula.sh <version> <SHA256SUMS> [base-url] > rsshd.rb
# Check SHA256SUMS.asc first (install.sh does it the same way): this script trusts the file it is given.
set -eu
version=$1; sums=$2; base=${3:-https://rssh-ea902a.gitlab.io}
sum() {
  s=$(awk -v f="rsshd_${version}_$1.tar.gz" '$2 == f { print $1 }' "$sums")
  case $s in *[!0-9a-f]*|'') echo "no sha256 for rsshd_${version}_$1.tar.gz in $sums" >&2; exit 1 ;; esac
  printf %s "$s"
}
arm=$(sum darwin_arm64); intel=$(sum darwin_amd64)
sed -e "s|@VERSION@|$version|g" -e "s|@BASE_URL@|$base|g" \
    -e "s|@SHA256_DARWIN_ARM64@|$arm|" -e "s|@SHA256_DARWIN_AMD64@|$intel|" \
    "$(dirname "$0")/rsshd.rb.tmpl"
