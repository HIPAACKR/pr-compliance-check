#!/usr/bin/env bash
# Refuse to run without an API key, and say why (W14).
#
# Env:
#   COMPLIANCE_API_KEY  the api-key input (masked, never printed)
#   IS_FORK             "true" when the PR head is in another repository
#   PR_AUTHOR           the PR author's login
#   OUT_DIR             state directory (default /tmp)
#
# GitHub does not pass repository secrets to pull_request workflows from
# forks, so the key arrives empty. v1.6 then stopped with a bare error. Now
# the run records `not_run_fork` (or `missing_api_key` for a PR from this
# repository), a comment says what happened, and the verdict is "blocked":
# never a silent pass. The enforce step decides the job per the enforce mode.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

cc_decided && exit 0

KEY="$(cc_trim_key "${COMPLIANCE_API_KEY:-}")"
if [ -n "$KEY" ]; then
  echo "::add-mask::$KEY"
  echo "API key present."
  exit 0
fi

if [ "${IS_FORK:-false}" = "true" ]; then
  cc_give_up not_run_fork "The api-key input is empty because this pull request comes from a fork."
elif [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
  cc_give_up missing_api_key "The api-key input is empty. Dependabot pull requests get Dependabot secrets, not Actions secrets."
else
  cc_give_up missing_api_key "The api-key input is empty after trimming whitespace."
fi
exit 0
