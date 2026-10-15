#!/usr/bin/env bash
# Decide the job from the compliance verdict (R&D plan T04).
#
# Usage: enforce-verdict.sh <overall_status.txt>
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
set -uo pipefail

FILE="${1:-}"

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "::error::No compliance verdict was recorded for this run, so the check cannot pass."
  exit 1
fi

# Drop CRs, trim surrounding whitespace and fold case; nothing else is
# normalised. The whole file is the verdict: a value with an inner newline
# ("clean\nfail") stays multi-line and matches nothing, and a NUL byte is
# turned into \001 so bash cannot silently drop it and leave "clean".
V=$(tr -d '\r' < "$FILE" | tr '\000' '\001' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
echo "Compliance verdict: ${V:-<none>}"

case "$V" in
  clean|warn)
    echo "Verdict acceptable."
    exit 0
    ;;
  fail|blocked)
    echo "::error::Compliance check did not pass (verdict: $V)"
    exit 1
    ;;
  "")
    echo "::error::The compliance API returned a result with no verdict (overall_status missing or empty), so the check cannot pass."
    exit 1
    ;;
  *)
    echo "::error::Unknown compliance verdict '$V'. Expected clean, warn, fail or blocked, so the check cannot pass."
    exit 1
    ;;
esac
