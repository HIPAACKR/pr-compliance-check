#!/usr/bin/env bash
# Publish the compliance result as a named GitHub check with annotations
# (gap doc C2.9).
#
# Usage: publish-check-run.sh <check_run.json> <annotations.txt>
# Env:   GITHUB_TOKEN  token for the Checks API (needs `checks: write`)
#        REPO          owner/name
#        HEAD_SHA      the PR head commit, used when the body has no head_sha
#        GITHUB_API_URL  optional, defaults to https://api.github.com
#
# Both inputs come from the compliance API's job result. Either may be missing
# or empty (an older server, or a failed analysis); that is not an error.
#
# This step must never decide the job's outcome: the verdict is enforced by
# the next step. Every failure here is reported as a ::warning:: and the
# script exits 0.
set -uo pipefail

CHECK_FILE="${1:-}"
ANNOTATIONS_FILE="${2:-}"
API="${GITHUB_API_URL:-https://api.github.com}"

# ── Annotations ───────────────────────────────────────────────────────────
# The lines are GitHub workflow commands; printing them is what creates the
# annotations. Only the three annotation commands are printed. The server
# filters too, but anything else (::add-mask::, ::stop-commands::, ...) is
# dropped here as well, so a result can never run another command.
if [ -n "$ANNOTATIONS_FILE" ] && [ -s "$ANNOTATIONS_FILE" ]; then
  printed=0
  dropped=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "::error "* | "::error::"* | "::warning "* | "::warning::"* | "::notice "* | "::notice::"*)
        printf '%s\n' "$line"
        printed=$((printed + 1))
        ;;
      "") ;;
      *) dropped=$((dropped + 1)) ;;
    esac
  # tr drops CRs, so a CRLF file never leaves a stray \r inside a command.
  done < <(tr -d '\r' < "$ANNOTATIONS_FILE")
  echo "Annotations: printed ${printed}, dropped ${dropped} non-annotation line(s)."
fi

# ── Check run ─────────────────────────────────────────────────────────────
if [ -z "$CHECK_FILE" ] || [ ! -s "$CHECK_FILE" ]; then
  echo "No check-run body in the result (older server or failed analysis); skipping the named check."
  exit 0
fi

if ! BODY=$(jq -c --arg sha "${HEAD_SHA:-}" \
    'if (.head_sha // "") == "" then .head_sha = $sha else . end' "$CHECK_FILE" 2>/dev/null); then
  echo "::warning::The check-run body from the compliance API was not valid JSON; skipping the named check."
  exit 0
fi

if [ "$(jq -r '.head_sha // ""' <<<"$BODY")" = "" ]; then
  echo "::warning::No commit SHA for the check run; skipping the named check."
  exit 0
fi

if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${REPO:-}" ]; then
  echo "::warning::GITHUB_TOKEN or REPO is not set; skipping the named check."
  exit 0
fi

# The token goes in a header file, not on the command line, so it never shows
# up in a process listing.
HEADERS=$(mktemp)
RESPONSE=$(mktemp)
trap 'rm -f "$HEADERS" "$RESPONSE"' EXIT
chmod 600 "$HEADERS"
printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$HEADERS"

HTTP_CODE=$(curl -sS -X POST \
  -H @"$HEADERS" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  --max-time 30 \
  -o "$RESPONSE" \
  -w "%{http_code}" \
  --data-binary @- \
  "${API}/repos/${REPO}/check-runs" <<<"$BODY") || HTTP_CODE="000"

case "$HTTP_CODE" in
  201)
    URL=$(jq -r '.html_url // empty' "$RESPONSE" 2>/dev/null || true)
    echo "Published the \"$(jq -r '.name' <<<"$BODY")\" check (conclusion: $(jq -r '.conclusion' <<<"$BODY"))${URL:+: $URL}"
    ;;
  403 | 404)
    echo "::warning::Could not publish the named check (HTTP ${HTTP_CODE}). Add 'checks: write' to the workflow's permissions, or set publish-check-run: false. The PR comment and the verdict are unaffected."
    ;;
  *)
    echo "::warning::Could not publish the named check (HTTP ${HTTP_CODE}). The PR comment and the verdict are unaffected."
    ;;
esac
exit 0
