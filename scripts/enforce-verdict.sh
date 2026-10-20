#!/usr/bin/env bash
# Decide the job from the compliance verdict (R&D plan T04, v1.7 enforce modes).
#
# Usage: enforce-verdict.sh <overall_status.txt> [outcome.txt] [assessment.txt]
# Env:   ENFORCE  hard (default) | verdict-only | advisory
#
# The compliance API reports one of four verdicts in `overall_status`:
#   clean, warn  -> the check passes
#   fail         -> the PR introduces findings that must block the merge
#   blocked      -> the analysis could not run; never a pass
#
# Anything else fails the check too: a missing file, an empty verdict (a
# success response with no `overall_status`), or a value outside the four.
# Earlier releases passed those with only a warning, so a server regression that
# dropped or renamed the verdict would have let every PR through.
#
# Enforce modes:
#   hard          fail on the verdict as above, and also when the server says
#                 the run was not fully assessed (`assessment` other than
#                 complete or nothing_to_assess). An absent assessment (older
#                 servers) is not checked.
#   verdict-only  fail on the verdict only; the assessment is reported.
#   advisory      never fail; every problem is a warning.
#
# With only the first argument and no ENFORCE this behaves exactly as v1.6.
set -uo pipefail

FILE="${1:-}"
OUTCOME_FILE="${2:-}"
ASSESSMENT_FILE="${3:-}"

MODE=$(printf '%s' "${ENFORCE:-hard}" | tr -d '\r\n' | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
case "$MODE" in
  hard | verdict-only | advisory) ;;
  "") MODE=hard ;;
  *)
    echo "::warning::Unknown enforce mode '$(printf '%s' "$MODE" | tr -cd 'A-Za-z0-9._-' | cut -c1-40)'. Expected hard, verdict-only or advisory; using hard."
    MODE=hard
    ;;
esac
echo "Enforce mode: $MODE"

# Read one value: drop CRs, trim surrounding whitespace and fold case; nothing
# else is normalised. The whole file is the value: a value with an inner
# newline ("clean\nfail") stays multi-line and matches nothing, and a NUL byte
# is turned into \001 so bash cannot silently drop it and leave "clean".
read_value() {
  tr -d '\r' < "$1" | tr '\000' '\001' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]'
}

# One printable line of a value, for messages.
show() {
  printf '%s' "$1" | tr '\n\001' '  ' | tr -cd '[:print:]' | cut -c1-60
}

OUTCOME=""
[ -n "$OUTCOME_FILE" ] && [ -f "$OUTCOME_FILE" ] && OUTCOME=$(read_value "$OUTCOME_FILE")
ASSESSMENT=""
[ -n "$ASSESSMENT_FILE" ] && [ -f "$ASSESSMENT_FILE" ] && ASSESSMENT=$(read_value "$ASSESSMENT_FILE")
[ -n "$OUTCOME" ] && echo "Outcome: $(show "$OUTCOME")"

PROBLEMS=0
# problem <message>: an error under hard and verdict-only, a warning under advisory.
problem() {
  PROBLEMS=$((PROBLEMS + 1))
  if [ "$MODE" = advisory ]; then
    echo "::warning::Advisory mode: $1"
  else
    echo "::error::$1"
  fi
}

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  problem "No compliance verdict was recorded for this run, so the check cannot pass."
  echo "::warning::No verdict file: the action did not reach the result step. This is an action or runner problem, not a finding in the code."
  V="__missing__"
else
  V=$(read_value "$FILE")
  echo "Compliance verdict: ${V:-<none>}"
  case "$V" in
    clean | warn)
      echo "Verdict acceptable."
      ;;
    fail | blocked)
      if [ "$V" = blocked ] && [ -n "$OUTCOME" ] && [ "$OUTCOME" != blocked ] && [ "$OUTCOME" != analysed ]; then
        problem "Compliance check did not pass (verdict: $V, outcome: $(show "$OUTCOME"))"
      else
        problem "Compliance check did not pass (verdict: $V)"
      fi
      ;;
    "")
      problem "The compliance API returned a result with no verdict (overall_status missing or empty), so the check cannot pass."
      echo "::warning::Missing verdict: the compliance API answered success without overall_status. This is a server contract problem, not a finding in the code. Report it to the compliance API team."
      ;;
    *)
      problem "Unknown compliance verdict '$(show "$V")'. Expected clean, warn, fail or blocked, so the check cannot pass."
      echo "::warning::Unknown verdict: the compliance API sent '$(show "$V")', which this action version does not know. If the server added a verdict, update the action; otherwise report it to the compliance API team."
      ;;
  esac
fi

# D1 option (c): under hard, a run that was not fully assessed does not pass,
# even when the verdict alone would.
if [ -n "$ASSESSMENT" ]; then
  echo "Assessment: $(show "$ASSESSMENT")"
  TAIL="."
  [ "$MODE" = hard ] && TAIL=", so the check cannot pass under enforce: hard."
  case "$ASSESSMENT" in
    complete | nothing_to_assess) ;;
    partial | not_assessed)
      if [ "$MODE" = verdict-only ]; then
        echo "::notice::The run was not fully assessed (assessment: $ASSESSMENT). enforce is verdict-only, so this does not fail the check."
      else
        problem "The compliance analysis was not fully assessed (assessment: $ASSESSMENT)${TAIL} The comment lists what was not checked."
      fi
      ;;
    *)
      if [ "$MODE" = verdict-only ]; then
        echo "::notice::Unknown assessment '$(show "$ASSESSMENT")'; enforce is verdict-only, so it is not checked."
      else
        problem "Unknown assessment '$(show "$ASSESSMENT")'. Expected complete, partial, not_assessed or nothing_to_assess${TAIL}"
      fi
      ;;
  esac
fi

if [ "$PROBLEMS" -eq 0 ]; then
  exit 0
fi
if [ "$MODE" = advisory ]; then
  echo "enforce is advisory: the check passes; see the warnings above."
  exit 0
fi
exit 1
