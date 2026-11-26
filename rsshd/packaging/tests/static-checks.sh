#!/bin/sh
# Fast checks of the packaging files (no build): shellcheck, the key embedded in install.sh is the committed one,
# the plist and the formula template parse. Usage (from rsshd/): sh packaging/tests/static-checks.sh
set -eu
cd "$(dirname "$0")/../.."
shellcheck -e SC1091 install.sh packaging/scripts/*.sh packaging/tests/*.sh packaging/homebrew/*.sh \
  packaging/deb/postinst packaging/deb/prerm
emb=$(mktemp); trap 'rm -f "$emb"' EXIT
sed -n "/^  cat <<'KEY'$/,/^KEY$/p" install.sh | sed '1d;$d' > "$emb"
sed '/^$/{$d}' packaging/rssh-archive-keyring.asc | diff -u - "$emb" ||
  { echo "install.sh embeds another key than packaging/rssh-archive-keyring.asc" >&2; exit 1; }
grep -q '^FPR=3C2F847F5734F445076275DD5961ADF201732BAC$' install.sh
python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); assert d["Label"]=="dev.rssh.rsshd", d' \
  packaging/launchd/dev.rssh.rsshd.plist
echo "static checks: OK"
