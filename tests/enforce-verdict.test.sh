#!/usr/bin/env bash
# Tests for scripts/enforce-verdict.sh and the verdict extraction in the
# poll step of action.yml. Run: bash tests/enforce-verdict.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/enforce-verdict.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# expect <name> <expected exit code> <file contents | __MISSING__> [expected output substring]
expect() {
  local name="$1" want="$2" content="$3" grep_for="${4:-}"
  local f="$WORK/overall_status.txt"
  rm -f "$f"
  if [ "$content" != "__MISSING__" ]; then
    printf '%s' "$content" > "$f"
  fi
  local out code
  out=$(bash "$SCRIPT" "$f" 2>&1); code=$?
  if [ "$code" -ne "$want" ]; then
    echo "FAIL  $name: exit $code, wanted $want"; echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$grep_for" ] && ! grep -qF -- "$grep_for" <<<"$out"; then
    echo "FAIL  $name: output lacks '$grep_for'"; echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL + 1)); return
  fi
  echo "ok    $name"
  PASS=$((PASS + 1))
}

# The four verdicts the API defines.
expect "clean passes"               0 $'clean\n'   "Verdict acceptable."
expect "warn passes"                0 $'warn\n'    "Verdict acceptable."
expect "fail fails"                 1 $'fail\n'    "::error::Compliance check did not pass (verdict: fail)"
expect "blocked fails"              1 $'blocked\n' "::error::Compliance check did not pass (verdict: blocked)"

# Fail closed on anything else.
expect "missing file fails"         1 "__MISSING__" "No compliance verdict was recorded"
expect "empty verdict fails"        1 ""            "no verdict"
expect "blank line fails"           1 $'\n'         "no verdict"
expect "old '?' placeholder fails"  1 $'?\n'        "Unknown compliance verdict '?'"
expect "unknown value fails"        1 $'pass\n'     "Unknown compliance verdict 'pass'"
expect "jq null fails"              1 $'null\n'     "Unknown compliance verdict 'null'"
expect "compliant is not a verdict" 1 $'compliant\n' "Unknown compliance verdict"

# Whitespace and case are tolerated, nothing more.
expect "CRLF clean passes"          0 $'clean\r\n'   "Verdict acceptable."
expect "padded upper WARN passes"   0 $'  WARN  \n'  "Verdict acceptable."
expect "Fail in caps still fails"   1 $'FAIL\n'      "verdict: fail"
expect "clean-ish suffix fails"     1 $'cleaner\n'   "Unknown compliance verdict 'cleaner'"
expect "trailing blank lines pass"  0 $'clean\n\n'   "Verdict acceptable."

# The whole file is the verdict, not its first line.
expect "clean then fail fails"      1 $'clean\nfail\n'         "Unknown compliance verdict"
expect "blank then clean fails"     1 $'\nclean\n'             "Unknown compliance verdict"
expect "clean CRLF blocked fails"   1 $'clean\r\nblocked\r\n'  "Unknown compliance verdict"

# The poll step's extraction: a success response with no overall_status must
# yield an empty verdict (it used to yield "?", which passed).
extract() { jq -r '.overall_status // ""' <<<"$1" > "$WORK/overall_status.txt"; }
check_extracted() {
  local name="$1" json="$2" want="$3"
  extract "$json"
  local code
  bash "$SCRIPT" "$WORK/overall_status.txt" >/dev/null 2>&1; code=$?
  if [ "$code" -eq "$want" ]; then echo "ok    $name"; PASS=$((PASS + 1))
  else echo "FAIL  $name: exit $code, wanted $want"; FAIL=$((FAIL + 1)); fi
}
check_extracted "real success, clean"        '{"status":"success","result":"x","overall_status":"clean"}' 0
check_extracted "real success, fail"         '{"status":"success","result":"x","overall_status":"fail"}' 1
check_extracted "mock success, no verdict"   '{"status":"success","result":"x"}' 1
check_extracted "null verdict"               '{"status":"success","result":"x","overall_status":null}' 1
check_extracted "newline inside verdict"     '{"status":"success","result":"x","overall_status":"clean\nfail"}' 1
check_extracted "NUL after verdict"          '{"status":"success","result":"x","overall_status":"clean\u0000"}' 1
check_extracted "false verdict"              '{"status":"success","result":"x","overall_status":false}' 1
check_extracted "numeric verdict"            '{"status":"success","result":"x","overall_status":1}' 1

# The poll script and action.yml must use this extraction and this script, so
# a revert to the old inline case (which only warned) or a "?"/"clean" default
# fails here.
ACTION="$HERE/../action.yml"
POLL="$HERE/../scripts/poll-job.sh"
pin() {
  local name="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then echo "ok    $name"; PASS=$((PASS + 1))
  else echo "FAIL  $name: ${file##*/} lacks: $needle"; FAIL=$((FAIL + 1)); fi
}
pin "poll-job.sh extracts with an empty default" "$POLL" \
  "jq -r '.overall_status // \"\"' \"\$RESP\" > \"\$OUT_DIR/overall_status.txt\""
pin "action.yml runs the poll script" "$ACTION" \
  'run: bash "${{ github.action_path }}/scripts/poll-job.sh"'
pin "action.yml enforces with the script" "$ACTION" \
  'run: bash "${{ github.action_path }}/scripts/enforce-verdict.sh" /tmp/overall_status.txt /tmp/outcome.txt /tmp/assessment.txt'
pin "action.yml defaults enforce to hard (v1.6 behaviour)" "$ACTION" \
  "    default: 'hard'"
if grep -qF "not failing the check" "$ACTION"; then
  echo "FAIL  action.yml still has a warn-only verdict branch"; FAIL=$((FAIL + 1))
else
  echo "ok    action.yml has no warn-only verdict branch"; PASS=$((PASS + 1))
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
