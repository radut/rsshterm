#!/bin/sh
# Fast checks of the desktop packaging (no build): shellcheck, the key embedded in desktop/install.sh is the committed
# one, nfpm.yaml and the .desktop file parse. Usage (repo root): sh desktop/packaging/tests/static-checks.sh
set -eu
shellcheck desktop/install.sh desktop/packaging/scripts/*.sh desktop/packaging/tests/*.sh packaging/site/*.sh \
  packaging/launchpad/*.sh
emb=$(mktemp); trap 'rm -f "$emb"' EXIT
sed -n "/^  cat <<'KEY'$/,/^KEY$/p" desktop/install.sh | sed '1d;$d' > "$emb"
sed '/^$/{$d}' rsshd/packaging/rssh-archive-keyring.asc | diff -u - "$emb" ||
  { echo "desktop/install.sh embeds another key than rsshd/packaging/rssh-archive-keyring.asc" >&2; exit 1; }
python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert d["name"]=="rsshterm", d' desktop/packaging/nfpm.yaml
grep -q '^Exec=rsshterm$' desktop/linux/packaging/dev.rsshterm.RSSHTerm.desktop
[ -s desktop/linux/packaging/icons/hicolor/256x256/apps/dev.rsshterm.RSSHTerm.png ]
echo "desktop static checks: OK"
