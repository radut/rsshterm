#!/bin/sh
# The desktop updater's Ed25519 key pair (docs/desktop/release.md "Update signing").
#
#   update-key.sh new <private.pem>    make a key: the PRIVATE key goes to <private.pem> (0600; store it in your secret store as
#                                      the CI variable DESKTOP_UPDATE_SIGNING_KEY, then delete the file), the public key is printed
#   update-key.sh pub <private.pem>    print the public key again: base64 of the raw 32 bytes, what the app embeds
#   update-key.sh sign <private.pem> <file>             print base64 of the raw 64-byte signature of <file>'s bytes
#   update-key.sh verify <public-b64> <file> <sig-file> exit 0 only if <sig-file> (base64) signs <file>
# Needs openssl 3.
set -eu
cmd=${1:-}; key=${2:-}
pub() { openssl pkey -in "$1" -pubout -outform DER | tail -c 32 | base64 | tr -d '\n'; echo; }
case $cmd in
  new)
    [ ! -e "$key" ] || { echo "$key exists: not overwritten" >&2; exit 1; }
    (umask 077; openssl genpkey -algorithm ed25519 -out "$key")
    echo "private key: $key (store it in your secret store for the CI variable DESKTOP_UPDATE_SIGNING_KEY, then delete this file)" >&2
    printf 'public key (embed in the app): '; pub "$key" ;;
  pub) pub "$key" ;;
  sign)
    t=$(mktemp); trap 'rm -f "$t"' EXIT
    openssl pkeyutl -sign -rawin -inkey "$key" -in "$3" -out "$t"
    [ "$(wc -c < "$t")" -eq 64 ] || { echo "not an Ed25519 signature" >&2; exit 1; }
    base64 < "$t" | tr -d '\n'; echo ;;
  verify)
    t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
    # SubjectPublicKeyInfo header of an Ed25519 key (30 2a 30 05 06 03 2b 65 70 03 21 00), then the raw 32 bytes.
    printf '\060\052\060\005\006\003\053\145\160\003\041\000' > "$t/pub.der"
    printf '%s' "$key" | base64 -d >> "$t/pub.der"
    base64 -d < "$4" > "$t/sig"
    openssl pkeyutl -verify -rawin -pubin -keyform DER -inkey "$t/pub.der" -in "$3" -sigfile "$t/sig" >/dev/null ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
