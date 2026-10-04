#!/usr/bin/env bash
# Tests for scripts/publish-check-run.sh with a stubbed curl (no network).
# Run: bash tests/publish-check-run.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/publish-check-run.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Stub curl: records its argv and stdin, writes a canned response to the -o
# file and prints STUB_CODE as the -w output. STUB_FAIL=1 makes it exit 7.
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/argv.log"
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
cat > "$STUB_DIR/stdin.json"
[ "${STUB_FAIL:-0}" = "1" ] && exit 7
[ -n "$out" ] && printf '{"html_url":"https://github.example/check/1"}' > "$out"
printf '%s' "${STUB_CODE:-201}"
EOF
chmod +x "$WORK/bin/curl"

pass=0
fail=0
check() { # name, condition-result
  if [ "$2" = "0" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1"; fi
}

run() { # runs the script; stdout+stderr -> $WORK/out, exit code -> $WORK/rc
  rm -f "$WORK/argv.log" "$WORK/stdin.json"
  STUB_DIR="$WORK" PATH="$WORK/bin:$PATH" GITHUB_TOKEN="tok-SECRET-123" REPO="acme/app" \
    HEAD_SHA="headsha123" GITHUB_API_URL="https://api.test" \
    bash "$SCRIPT" "$@" > "$WORK/out" 2>&1
  echo $? > "$WORK/rc"
}

BODY='{"name":"Compliance Check","head_sha":"","status":"completed","conclusion":"failure","output":{"title":"t","summary":"s","text":"x"}}'
printf '%s' "$BODY" > "$WORK/check.json"

# 1. Success: posts to the check-runs endpoint, fills head_sha, exits 0.
STUB_CODE=201 run "$WORK/check.json" ""
check "201 exits 0" "$([ "$(cat "$WORK/rc")" = 0 ]; echo $?)"
check "201 reports publish" "$(grep -q 'Published the "Compliance Check" check (conclusion: failure)' "$WORK/out"; echo $?)"
check "posts to /repos/acme/app/check-runs" "$(grep -q 'https://api.test/repos/acme/app/check-runs' "$WORK/argv.log"; echo $?)"
check "empty head_sha filled from HEAD_SHA" "$([ "$(jq -r .head_sha "$WORK/stdin.json")" = headsha123 ]; echo $?)"
check "token never in argv" "$(! grep -q 'tok-SECRET-123' "$WORK/argv.log"; echo $?)"

# 2. A head_sha in the body is kept.
printf '%s' "${BODY/\"head_sha\":\"\"/\"head_sha\":\"bodysha\"}" > "$WORK/check2.json"
STUB_CODE=201 run "$WORK/check2.json" ""
check "body head_sha kept" "$([ "$(jq -r .head_sha "$WORK/stdin.json")" = bodysha ]; echo $?)"

# 3. Missing permission: warning, still exit 0.
STUB_CODE=403 run "$WORK/check.json" ""
check "403 exits 0" "$([ "$(cat "$WORK/rc")" = 0 ]; echo $?)"
check "403 warns about checks: write" "$(grep -q "::warning::.*checks: write" "$WORK/out"; echo $?)"

# 4. curl itself fails: warning, exit 0.
STUB_FAIL=1 run "$WORK/check.json" ""
check "curl failure exits 0" "$([ "$(cat "$WORK/rc")" = 0 ]; echo $?)"
check "curl failure warns HTTP 000" "$(grep -q '::warning::.*HTTP 000' "$WORK/out"; echo $?)"

# 5. Older server: no check-run file -> skip quietly, no API call.
run "$WORK/does-not-exist.json" ""
check "missing body exits 0" "$([ "$(cat "$WORK/rc")" = 0 ]; echo $?)"
check "missing body makes no API call" "$([ ! -f "$WORK/argv.log" ]; echo $?)"

# 6. Invalid JSON: warning, no API call.
printf '{not json' > "$WORK/bad.json"
run "$WORK/bad.json" ""
check "invalid JSON exits 0" "$([ "$(cat "$WORK/rc")" = 0 ]; echo $?)"
check "invalid JSON warns" "$(grep -q '::warning::.*not valid JSON' "$WORK/out"; echo $?)"
check "invalid JSON makes no API call" "$([ ! -f "$WORK/argv.log" ]; echo $?)"

# 7. Annotations: only the three annotation commands are printed.
cat > "$WORK/ann.txt" <<'EOF'
::error file=app/views.py,line=12::SQL built from input
::warning file=app/models.py,line=3::Weak hash
::notice::Coverage note
::add-mask::hide-this
::stop-commands::resume-token
::set-output name=x::y
plain text
EOF
run "" "$WORK/ann.txt"
check "annotations exit 0" "$([ "$(cat "$WORK/rc")" = 0 ]; echo $?)"
check "error annotation printed" "$(grep -qx '::error file=app/views.py,line=12::SQL built from input' "$WORK/out"; echo $?)"
check "warning annotation printed" "$(grep -qx '::warning file=app/models.py,line=3::Weak hash' "$WORK/out"; echo $?)"
check "notice annotation printed" "$(grep -qx '::notice::Coverage note' "$WORK/out"; echo $?)"
check "::add-mask:: dropped" "$(! grep -q '^::add-mask::' "$WORK/out"; echo $?)"
check "::stop-commands:: dropped" "$(! grep -q '^::stop-commands::' "$WORK/out"; echo $?)"
check "::set-output dropped" "$(! grep -q '^::set-output' "$WORK/out"; echo $?)"
check "counts reported" "$(grep -q 'printed 3, dropped 4' "$WORK/out"; echo $?)"

# 8. A CRLF annotations file must not leave a carriage return in the command.
printf '::error file=a.py,line=1::one\r\n::add-mask::x\r\n' > "$WORK/crlf.txt"
run "" "$WORK/crlf.txt"
# -x matches the whole line, so a leftover \r would fail it on Linux.
check "CRLF line printed without CR" "$(grep -qx '::error file=a.py,line=1::one' "$WORK/out"; echo $?)"
check "CRLF ::add-mask:: still dropped" "$(! grep -q '^::add-mask::' "$WORK/out"; echo $?)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
