#!/usr/bin/env bash
# Tests for scripts/package-source.sh against a throwaway git repo.
# Run: bash tests/package-source.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/package-source.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    echo "ok    $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL  $name"
    sed 's/^/      /' "$WORK/log" | tail -15
  fi
}

REPO="$WORK/repo"
OUT="$WORK/out"
mkdir -p "$REPO" "$OUT"
cd "$REPO" || exit 1
git init -q .
big() { mkdir -p "$(dirname "$1")"; head -c 3145728 /dev/zero | tr '\0' 'a' > "$1"; }
small() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${2:-x}" > "$1"; }

small app.py 'print("hi")'
small .env 'SECRET=1'
small config/.env.production 'SECRET=2'
small .env.example 'SECRET='
small .envrc 'use nix'
small env.example 'A='
small certs/server.pem 'pem'
small keys/ID.KEY 'key'
small store/a.p12 'p12'
small store/b.pfx 'pfx'
small store/c.jks 'jks'
small android/release.keystore 'ks'
small src/keyboard.py 'k = 1'
small yarn.lock 'lock'
small image.png 'png'
small docs/guide.md 'docs'
big big.svg
big package-lock.json
big sub/go.sum
big Cargo.lock
git add -A
git -c user.name=t -c user.email=t@example.com commit -qm init
small untracked.txt 'not tracked'

run() {
  rm -f "$OUT/outcome.txt" "$OUT/source.tar.gz"
  OUT_DIR="$OUT" bash "$SCRIPT" > "$WORK/log" 2>&1
  tar tzf "$OUT/source.tar.gz" 2>/dev/null | sed 's|^\./||' | sort > "$WORK/members"
}
in_archive() { grep -qx -- "$1" "$WORK/members"; }
not_in_archive() { ! grep -qx -- "$1" "$WORK/members"; }

SOURCE_EXCLUDES='docs/*' run
check "source kept" in_archive app.py
for f in .env config/.env.production .env.example certs/server.pem keys/ID.KEY store/a.p12 store/b.pfx store/c.jks android/release.keystore; do
  check "secret file left out: $f" not_in_archive "$f"
done
check "secret files are logged as left out" grep -q 'may hold secrets; never uploaded' "$WORK/log"
check "secret count reported" grep -q '9 file(s) that may hold secrets' "$WORK/log"
check ".envrc is not .env.*" in_archive .envrc
check "env.example kept" in_archive env.example
check "keyboard.py is not a key file" in_archive src/keyboard.py
check "oversized .svg dropped by the size cap" not_in_archive big.svg
check "oversized package-lock.json kept (lockfile)" in_archive package-lock.json
check "oversized go.sum kept (lockfile)" in_archive sub/go.sum
check "oversized Cargo.lock kept (lockfile)" in_archive Cargo.lock
check "yarn.lock kept" in_archive yarn.lock
check "binary .png dropped" not_in_archive image.png
check "user source-excludes still apply" not_in_archive docs/guide.md
check "untracked files never packaged" not_in_archive untracked.txt
check "no outcome on success" test ! -s "$OUT/outcome.txt"

# The secret excludes cannot be switched off by raising the cap.
MAX_FILE_BYTES=999999999 run
check "secret files left out at any max-file-bytes" not_in_archive .env
check "a raised cap keeps the .svg" in_archive big.svg

# A lowered cap still never drops a lockfile.
MAX_FILE_BYTES=1 run
check "max-file-bytes=1 keeps lockfiles" in_archive yarn.lock
check "max-file-bytes=1 drops ordinary files" not_in_archive app.py

# Over the archive cap: a give-up, not a bare error.
CC_ARCHIVE_CAP_BYTES=100 run
check "over the cap exits 0 with outcome source_too_large" test "$(head -n1 "$OUT/outcome.txt")" = source_too_large
check "over the cap writes a blocked verdict" test "$(head -n1 "$OUT/overall_status.txt")" = blocked
check "over the cap lists the largest members" grep -q 'Largest members still in the archive' "$WORK/log"

# Nothing to do once an outcome is recorded.
echo not_run_fork > "$OUT/outcome.txt"
rm -f "$OUT/source.tar.gz"
OUT_DIR="$OUT" bash "$SCRIPT" > "$WORK/log" 2>&1
check "skips after a give-up" test ! -f "$OUT/source.tar.gz"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
