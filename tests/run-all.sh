#!/usr/bin/env bash
# Run every test, then shellcheck and actionlint when they are installed.
# Run: bash tests/run-all.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATUS=0

for t in enforce-verdict publish-check-run package-source action-yml harness; do
  echo "### $t"
  if ! bash "$HERE/$t.test.sh"; then
    STATUS=1
  fi
  echo
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "### shellcheck"
  shellcheck -x "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh || STATUS=1
fi
if command -v actionlint >/dev/null 2>&1; then
  echo "### actionlint"
  # actionlint checks workflows; the example workflow is the one we ship.
  actionlint "$ROOT"/examples/*.yml || STATUS=1
fi

[ "$STATUS" -eq 0 ] && echo "All tests passed." || echo "Some tests failed."
exit "$STATUS"
