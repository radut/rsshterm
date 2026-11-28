#!/bin/sh
# shellcheck disable=SC2016,SC2034 # check() evals its single-quoted condition later, so its variables look unused
# Tests desktop/packaging/scripts/ci-macos-dmg.sh (job desktop:macos-dmg on the Mac runner) on Linux: a fake
# `make mac-dmg` (MAC_DMG_BUILD) and an in-memory generic package registry. Checks: the App Store Connect key from the
# CI variables lands in a job-local ASC_DIR (0600, never ~/.appstoreconnect), the build gets VERSION/OUT/ASC_DIR, the
# DMG goes to desktop-macos/<v>/<name> with the job token and is read back, the dotenv names it for the attach
# pipeline; a bad version, a DMG of another name, a checksum that does not match and a registry that returns other
# bytes all fail before anything is handed on.
# Run (repo root): sh desktop/packaging/tests/ci-macos-dmg-test.sh   Needs: python3, curl, sha256sum.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
script=$root/desktop/packaging/scripts/ci-macos-dmg.sh
work=$(mktemp -d)
pid=
cleanup() { [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT INT TERM
fails=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }

# The registry: PUT stores, GET returns (or other bytes when CORRUPT exists), every request logged with its token.
cat > "$work/registry.py" <<'PY'
import http.server, os, sys
store, log = {}, open(sys.argv[2], "a")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_PUT(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        store[self.path] = body
        log.write(f"PUT {self.path} {self.headers.get('JOB-TOKEN')}\n"); log.flush()
        self.send_response(201); self.end_headers(); self.wfile.write(b'{"message":"201 Created"}')
    def do_GET(self):
        log.write(f"GET {self.path} {self.headers.get('JOB-TOKEN')}\n"); log.flush()
        if self.path not in store:
            self.send_response(404); self.end_headers(); return
        body = b"tampered" if os.path.exists(sys.argv[3]) else store[self.path]
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_port))
srv.serve_forever()
PY
python3 "$work/registry.py" "$work/port" "$work/requests.log" "$work/CORRUPT" &
pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$work/port" ] && break; sleep 0.3; done
port=$(cat "$work/port")

# The fake builder: what mac-dmg.sh leaves in $OUT (the DMG + result.env), plus what it was given.
cat > "$work/fake-build.sh" <<'SH'
#!/bin/sh
set -eu
mkdir -p "$OUT"
name=${FAKE_NAME:-rsshterm_${VERSION}_macos_universal.dmg}
printf 'dmg %s\n' "$VERSION" > "$OUT/$name"
sum=${FAKE_SUM:-$(sha256sum "$OUT/$name" | awk '{print $1}')}
printf 'DMG=%s\nSHA256=%s\nVERSION=%s\n' "$OUT/$name" "$sum" "$VERSION" > "$OUT/result.env"
{ echo "VERSION=$VERSION"; echo "ASC_DIR=$ASC_DIR"; cat "$ASC_DIR/asc.env"; ls "$ASC_DIR/private_keys"
  stat -c %a "$ASC_DIR/private_keys"/*; } > "$FAKE_SEEN"
SH
chmod +x "$work/fake-build.sh"
echo "-----BEGIN PRIVATE KEY-----demo" > "$work/key.p8"

run() {  # version out-env [VAR=value...]
  v=$1; e=$2; shift 2
  env CI_API_V4_URL="http://127.0.0.1:$port/api/v4" CI_PROJECT_ID=42 CI_JOB_TOKEN=job-tok \
    CI_PROJECT_DIR="$work/proj" ASC_KEY_ID=KEYID123 ASC_ISSUER_ID=issuer-1 ASC_KEY_P8="$work/key.p8" \
    MAC_DMG_BUILD="$work/fake-build.sh" MAC_DMG_OUT="$work/out" FAKE_SEEN="$work/seen" "$@" \
    sh "$script" "$v" "$e"
}
mkdir -p "$work/proj"

# 1. The good path.
check "builds, uploads, writes the dotenv" 'run 1.2.3 "$work/dmg.env" > "$work/run1.log" 2>&1'
check "the build got VERSION" 'grep -qx "VERSION=1.2.3" "$work/seen"'
check "the key went to a job-local ASC_DIR" 'grep -qx "ASC_DIR=$work/proj/.asc" "$work/seen"'
check "asc.env has the key id and issuer" 'grep -qx "ASC_KEY_ID=KEYID123" "$work/seen" && grep -qx "ASC_ISSUER_ID=issuer-1" "$work/seen"'
check "AuthKey_<id>.p8, mode 600" 'grep -qx "AuthKey_KEYID123.p8" "$work/seen" && grep -qx 600 "$work/seen"'
check "uploaded with the job token" 'grep -qx "PUT /api/v4/projects/42/packages/generic/desktop-macos/1.2.3/rsshterm_1.2.3_macos_universal.dmg job-tok" "$work/requests.log"'
check "read back" 'grep -q "^GET /api/v4/projects/42/packages/generic/desktop-macos/1.2.3/rsshterm_1.2.3_macos_universal.dmg job-tok" "$work/requests.log"'
sum=$(printf 'dmg 1.2.3\n' | sha256sum | awk '{print $1}')
check "dotenv: version, name, sha256" 'grep -qx "MACOS_DMG_VERSION=1.2.3" "$work/dmg.env" && grep -qx "MACOS_DMG_NAME=rsshterm_1.2.3_macos_universal.dmg" "$work/dmg.env" && grep -qx "MACOS_DMG_SHA256=$sum" "$work/dmg.env"'
check "the job-local key is removed afterwards" '[ ! -e "$work/proj/.asc" ]'
check "the key never reaches the log" '! grep -q "BEGIN PRIVATE KEY" "$work/run1.log"'

# 2. Refusals: nothing uploaded, no dotenv.
: > "$work/requests.log"
check "refuses a bad version" '! run 1.2 "$work/bad1.env" >/dev/null 2>&1 && [ ! -e "$work/bad1.env" ]'
check "refuses a DMG of another name" '! run 1.2.4 "$work/bad2.env" FAKE_NAME=rsshterm_9.9.9_macos_universal.dmg >/dev/null 2>&1 && [ ! -e "$work/bad2.env" ]'
check "refuses a result.env checksum that does not match the file" '! run 1.2.5 "$work/bad3.env" FAKE_SUM=0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1 && [ ! -e "$work/bad3.env" ]'
check "nothing was uploaded by the refusals" '! grep -q "^PUT" "$work/requests.log"'
check "refuses without the App Store Connect key" '! run 1.2.6 "$work/bad4.env" ASC_KEY_P8= >/dev/null 2>&1 && [ ! -e "$work/bad4.env" ]'
touch "$work/CORRUPT"
check "refuses when the registry returns other bytes" '! run 1.2.7 "$work/bad5.env" >/dev/null 2>&1 && [ ! -e "$work/bad5.env" ]'
rm -f "$work/CORRUPT"

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck" 'shellcheck "$script" "$0"'
fi
[ "$fails" = 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "ci-macos-dmg: OK"
