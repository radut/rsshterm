#!/bin/sh
# The .deb's maintainer scripts with update-alternatives replaced by a recorder (no system state changes): configure
# adds rsshterm as an x-terminal-emulator below GNOME Terminal, an upgrade's prerm keeps it, remove takes it out.
# Usage (repo root): sh desktop/packaging/tests/alternatives.sh
set -eu
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/update-alternatives" <<'REC'
#!/bin/sh
echo "$*" >> "$LOG"
REC
chmod +x "$t/update-alternatives"
export LOG="$t/log" PATH="$t:$PATH"
sh desktop/packaging/deb/postinst configure ""
sh desktop/packaging/deb/prerm upgrade 1.0.2
sh desktop/packaging/deb/prerm remove
expected='--install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/rsshterm 30
--remove x-terminal-emulator /usr/bin/rsshterm'
[ "$(cat "$LOG")" = "$expected" ] || { echo "alternatives: got:"; cat "$LOG"; exit 1; } >&2
prio=$(sed -n 's/.*rsshterm \([0-9]*\)$/\1/p' desktop/packaging/deb/postinst)
[ "$prio" -lt 40 ] || { echo "x-terminal-emulator priority $prio is not below GNOME Terminal (40)" >&2; exit 1; }
echo "alternatives: OK"
