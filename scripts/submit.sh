#!/usr/bin/env bash
# Submit the PR to the compliance API (W14).
#
# Env:
#   COMPLIANCE_API_KEY    the API key (required; masked, never printed)
#   COMPLIANCE_API_URL    base URL of the PR-check API
#   FRAMEWORKS            JSON array of frameworks, or empty
#   REPO_ID BASE_SHA HEAD_SHA PR_NUMBER PR_TITLE PR_AUTHOR   PR metadata
#   POLL_TIMEOUT_SECONDS  sent as client_timeout (default 10800)
#   MAX_QUEUE_SECONDS     sent as max_queue (default: poll timeout - 3600)
#   OUT_DIR               state directory (default /tmp)
#   README_FILE           project README to send as context (default README.md)
#   SUBMIT_MAX_ATTEMPTS   attempts before giving up (default 6)
#
# Retries with back-off on connection errors, 5xx, 404 and 408, and honours
# Retry-After on 429 and 503. Every response's HTTP status is checked. On
# success it writes job_id.txt. Any give-up writes an outcome and a comment
# (lib.sh) and exits 0; the enforce step decides the job.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

if cc_decided; then
  echo "Outcome already recorded ($(head -n1 "$OUT_DIR/outcome.txt")); not submitting."
  exit 0
fi

API="${COMPLIANCE_API_URL:-https://llm.ubicomply.ai/sast/api/v1/compliance/pr-check}"
API="${API%/}"
KEY="$(cc_trim_key "${COMPLIANCE_API_KEY:-}")"
if [ -z "$KEY" ]; then
  cc_give_up missing_api_key "The api-key input is empty after trimming whitespace."
  exit 0
fi
echo "::add-mask::$KEY"

DIFF_FILE="$OUT_DIR/pr.diff"
SOURCE_FILE="$OUT_DIR/source.tar.gz"
RESP="$OUT_DIR/submit_response.json"
HDRS="$(mktemp)"
AUTH="$(cc_auth_header_file "$KEY")"
trap 'rm -f "$AUTH" "$HDRS"' EXIT

for f in "$DIFF_FILE" "$SOURCE_FILE"; do
  if [ ! -s "$f" ]; then
    cc_give_up action_error "${f##*/} is missing or empty, so there is nothing to submit."
    exit 0
  fi
done

COMMIT_MESSAGES='[]'
[ -s "$OUT_DIR/commit_messages.json" ] && COMMIT_MESSAGES="$(cat "$OUT_DIR/commit_messages.json")"

README_FILE="${README_FILE:-README.md}"
README_ARG=()
[ -f "$README_FILE" ] && README_ARG=(-F "readme=@${README_FILE};type=text/plain")

FRAMEWORKS="${FRAMEWORKS:-}"
FRAMEWORKS_ARG=()
if [ -n "$FRAMEWORKS" ]; then
  if ! printf '%s' "$FRAMEWORKS" | jq -e 'type == "array"' >/dev/null 2>&1; then
    cc_warn "The frameworks input is not a JSON array (got: $(cc_md_line "$FRAMEWORKS" 200)). The server ignores it and runs its default framework. Use a value like [\"hipaa\"]."
  fi
  FRAMEWORKS_ARG=(--form-string "frameworks=$FRAMEWORKS")
fi

# The poll window, so the server can expire a job nobody will read (§3.6).
# The server clamps both values.
CLIENT_TIMEOUT="$(cc_int "${POLL_TIMEOUT_SECONDS:-}" 10800)"
DEFAULT_MAX_QUEUE=$((CLIENT_TIMEOUT - 3600))
[ "$DEFAULT_MAX_QUEUE" -lt 60 ] && DEFAULT_MAX_QUEUE=60
MAX_QUEUE="$(cc_int "${MAX_QUEUE_SECONDS:-}" "$DEFAULT_MAX_QUEUE")"

MAX_ATTEMPTS="$(cc_int "${SUBMIT_MAX_ATTEMPTS:-}" 6)"
TRANSIENT=0
LIMITED=0
ATTEMPT=0
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  # Text fields use --form-string: with -F a PR title that starts with "@" or
  # "<" would make curl upload a local file, and ";type=" would be parsed.
  CODE=$(curl -sS -X POST \
    -H @"$AUTH" \
    -F "diff=@${DIFF_FILE};type=text/plain" \
    -F "source=@${SOURCE_FILE};type=application/gzip" \
    ${README_ARG[@]+"${README_ARG[@]}"} \
    --form-string "commit_messages=$COMMIT_MESSAGES" \
    ${FRAMEWORKS_ARG[@]+"${FRAMEWORKS_ARG[@]}"} \
    --form-string "repo_id=${REPO_ID:-}" \
    --form-string "base_sha=${BASE_SHA:-}" \
    --form-string "head_sha=${HEAD_SHA:-}" \
    --form-string "pr_number=${PR_NUMBER:-}" \
    --form-string "pr_title=${PR_TITLE:-}" \
    --form-string "pr_author=${PR_AUTHOR:-}" \
    --form-string "client_timeout=$CLIENT_TIMEOUT" \
    --form-string "max_queue=$MAX_QUEUE" \
    --connect-timeout 30 \
    --max-time "$(cc_int "${SUBMIT_MAX_TIME:-}" 300)" \
    -D "$HDRS" \
    -o "$RESP" \
    -w '%{http_code}' \
    "$API/") || CODE="000"
  [ -f "$RESP" ] || : > "$RESP"
  echo "Submit attempt $ATTEMPT - HTTP: $CODE"

  WAIT=""
  case "$CODE" in
    2??)
      JOB_ID=$(jq -r '.job_id // empty' "$RESP" 2>/dev/null || true)
      if printf '%s' "$JOB_ID" | grep -Eq '^[A-Za-z0-9._-]{1,128}$'; then
        break
      fi
      echo "HTTP $CODE without a usable job_id:"
      cc_log_body "$RESP"
      TRANSIENT=$((TRANSIENT + 1))
      LAST="HTTP $CODE without a job id"
      ;;
    429)
      LIMITED=$((LIMITED + 1))
      WAIT=$(cc_retry_after "$HDRS" "$RESP" 60)
      LAST="HTTP 429"
      ;;
    413)
      ERR=$(jq -r '.error // empty' "$RESP" 2>/dev/null || true)
      if [ "$ERR" = "diff_too_large" ]; then
        cc_give_up diff_too_large "The server refused the diff as too large (HTTP 413)."
      else
        SIZE=$(wc -c < "$SOURCE_FILE" | tr -d ' ')
        MAXB=$(jq -r '.max_bytes // empty' "$RESP" 2>/dev/null || true)
        cc_give_up source_too_large "The server refused the upload as too large (HTTP 413${ERR:+, $ERR}). The source archive is ${SIZE} bytes${MAXB:+; the server limit is ${MAXB} bytes}."
      fi
      exit 0
      ;;
    401 | 403)
      cc_give_up auth_failed "The submit request was answered HTTP ${CODE}."
      exit 0
      ;;
    404 | 408 | 000 | 5??)
      TRANSIENT=$((TRANSIENT + 1))
      LAST="HTTP $CODE"
      [ "$CODE" = "000" ] && LAST="no response (connection error or timeout)"
      if [ "$CODE" = "503" ]; then
        WAIT=$(cc_retry_after "$HDRS" "$RESP" "$(cc_backoff "$TRANSIENT")")
      fi
      [ "$CODE" != "000" ] && cc_log_body "$RESP" 500
      ;;
    *)
      ERR=$(jq -r '.error // empty' "$RESP" 2>/dev/null || true)
      DETAIL=$(jq -r '.detail // empty' "$RESP" 2>/dev/null || true)
      cc_log_body "$RESP"
      cc_give_up submit_rejected "The submit request was answered HTTP ${CODE}${ERR:+ ($(cc_md_line "$ERR" 100))}.${DETAIL:+ $(cc_md_line "$DETAIL" 300)}"
      exit 0
      ;;
  esac

  if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
    if [ "$CODE" = "429" ]; then
      cc_give_up rate_limited "The submit request was rate-limited (HTTP 429) on ${LIMITED} of ${ATTEMPT} attempts."
    else
      cc_give_up submit_failed "${ATTEMPT} submit attempts failed. The last one got ${LAST}."
    fi
    exit 0
  fi
  [ -z "$WAIT" ] && WAIT=$(cc_backoff "$TRANSIENT")
  echo "Retrying the submit in ${WAIT}s (${LAST})."
  sleep "$WAIT"
done

printf '%s\n' "$JOB_ID" > "$OUT_DIR/job_id.txt"
echo "Submitted job: $JOB_ID (client_timeout=${CLIENT_TIMEOUT}s, max_queue=${MAX_QUEUE}s)"

# Frameworks the server did not recognise (COV-5, additive). Absent on older
# servers, which drop unknown frameworks without saying so.
LIST='if type == "array" then map(if type == "string" then . elif type == "object" then (.requested // .framework // .name // .value // tojson) else tojson end) | join(", ") else "" end'
DROPPED=$(jq -r "(.frameworks_dropped // []) | $LIST" "$RESP" 2>/dev/null || true)
ACCEPTED=$(jq -r "if has(\"frameworks_accepted\") then ((.frameworks_accepted // []) | $LIST) else \"-\" end" "$RESP" 2>/dev/null || echo "-")
if [ -n "$DROPPED" ]; then
  MSG="The compliance API did not recognise these frameworks and ignored them: ${DROPPED}."
  case "$ACCEPTED" in
    -) ;;
    '') MSG="$MSG None of the requested frameworks were accepted, so the server ran its default framework." ;;
    *) MSG="$MSG It is checking: ${ACCEPTED}." ;;
  esac
  cc_warn "$MSG"
elif [ -n "$FRAMEWORKS" ] && [ "$ACCEPTED" = "" ]; then
  cc_warn "The compliance API accepted none of the requested frameworks (${FRAMEWORKS}), so it ran its default framework."
fi
exit 0
