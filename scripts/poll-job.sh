#!/usr/bin/env bash
# Poll the compliance API until the job ends (W14, F3b).
#
# Env:
#   COMPLIANCE_API_KEY     the API key (masked, never printed)
#   COMPLIANCE_API_URL     base URL of the PR-check API
#   JOB_ID                 job to poll (default: $OUT_DIR/job_id.txt)
#   POLL_INTERVAL_SECONDS  seconds between polls while pending (default 5)
#   POLL_TIMEOUT_SECONDS   give up after this long (default 10800)
#   MAX_QUEUE_SECONDS      the max_queue sent on submit (default: timeout - 3600)
#   QUEUE_GIVE_UP_SECONDS  give up when queued longer than this
#                          (default MAX_QUEUE_SECONDS + 300; the server should
#                          expire the job first)
#   STALL_SECONDS          give up when the running job's heartbeat is older
#                          than this (default 1200; the server says
#                          worker_lost at 900)
#   POLL_MAX_TRANSIENT     consecutive transient errors before giving up (20)
#   OUT_DIR                state directory (default /tmp)
#
# Writes on a result: api_response.md, overall_status.txt, outcome.txt,
# assessment.txt, blocked_reason.txt, check_run.json, annotations.txt,
# report.md and result.json. On a server failure or a give-up it writes the
# outcome, a "blocked" verdict and a comment. It always exits 0 unless the
# state directory itself is unusable.
#
# Older servers send only {"status": "pending"} while a job runs. With no
# `state` field only poll-timeout applies, exactly as in v1.6.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

if cc_decided; then
  echo "Outcome already recorded ($(head -n1 "$OUT_DIR/outcome.txt")); not polling."
  exit 0
fi

API="${COMPLIANCE_API_URL:-https://llm.ubicomply.ai/sast/api/v1/compliance/pr-check}"
API="${API%/}"
KEY="$(cc_trim_key "${COMPLIANCE_API_KEY:-}")"
[ -n "$KEY" ] && echo "::add-mask::$KEY"

JOB_ID="${JOB_ID:-}"
[ -z "$JOB_ID" ] && [ -s "$OUT_DIR/job_id.txt" ] && JOB_ID="$(head -n1 "$OUT_DIR/job_id.txt")"
if [ -z "$JOB_ID" ]; then
  cc_give_up action_error "No job id was recorded by the submit step."
  exit 0
fi
printf '%s\n' "$JOB_ID" > "$OUT_DIR/job_id.txt"

INTERVAL="$(cc_int "${POLL_INTERVAL_SECONDS:-}" 5)"
TIMEOUT="$(cc_int "${POLL_TIMEOUT_SECONDS:-}" 10800)"
DEFAULT_MAX_QUEUE=$((TIMEOUT - 3600))
[ "$DEFAULT_MAX_QUEUE" -lt 60 ] && DEFAULT_MAX_QUEUE=60
MAX_QUEUE="$(cc_int "${MAX_QUEUE_SECONDS:-}" "$DEFAULT_MAX_QUEUE")"
QUEUE_LIMIT="$(cc_int "${QUEUE_GIVE_UP_SECONDS:-}" $((MAX_QUEUE + 300)))"
STALL="$(cc_int "${STALL_SECONDS:-}" 1200)"
MAX_TRANSIENT="$(cc_int "${POLL_MAX_TRANSIENT:-}" 20)"
# 404 right after submit can be the store catching up; later it means the
# job expired or was lost.
MAX_NOT_FOUND_EARLY="$(cc_int "${POLL_MAX_NOT_FOUND_EARLY:-}" 6)"
MAX_NOT_FOUND="$(cc_int "${POLL_MAX_NOT_FOUND:-}" 3)"

RESP="$OUT_DIR/poll_response.json"
HDRS="$(mktemp)"
AUTH="$(cc_auth_header_file "$KEY")"
trap 'rm -f "$AUTH" "$HDRS"' EXIT

START=$(date +%s)
DEADLINE=$((START + TIMEOUT))

# Sleep, but never past the deadline.
nap() {
  local left
  left=$((DEADLINE - $(date +%s)))
  [ "$left" -lt 0 ] && left=0
  sleep "$(cc_min "$1" "$left")"
}

# Best effort: tell the server nobody will read this job, so it stops using
# the shared GPU. Older servers answer 404 or 405; that is fine.
cancel_job() {
  local code
  code=$(curl -sS -X POST -H @"$AUTH" --connect-timeout 10 --max-time 15 \
    -o /dev/null -w '%{http_code}' "$API/jobs/$JOB_ID/cancel" 2>/dev/null) || code="000"
  echo "Asked the server to cancel job $JOB_ID (HTTP $code)."
}

# jq: a numeric field as a non-negative integer (floor), or nothing.
num() {
  jq -r "try (.$1 | tonumber | floor | if . < 0 then 0 else . end) catch empty" "$RESP" 2>/dev/null || true
}

write_result() {
  jq -r '.result // ""' "$RESP" > "$OUT_DIR/api_response.md"
  if [ ! -s "$OUT_DIR/api_response.md" ]; then
    printf '## 🔒 Compliance Review\n\nThe compliance API returned a result with no report text.\n' > "$OUT_DIR/api_response.md"
  fi
  # No "?" placeholder: an absent verdict stays empty, and the enforce step
  # fails the check on it (T04).
  jq -r '.overall_status // ""' "$RESP" > "$OUT_DIR/overall_status.txt"
  jq -r '.assessment // "" | strings' "$RESP" > "$OUT_DIR/assessment.txt" 2>/dev/null || : > "$OUT_DIR/assessment.txt"
  jq -r '.blocked_reason // "" | strings' "$RESP" > "$OUT_DIR/blocked_reason.txt" 2>/dev/null || : > "$OUT_DIR/blocked_reason.txt"
  # Named check + annotations (C2.9). Absent on older servers; the publish
  # step then skips.
  jq -c '.check_run // empty' "$RESP" > "$OUT_DIR/check_run.json" 2>/dev/null || : > "$OUT_DIR/check_run.json"
  jq -r '(.annotations // [])[]? | strings' "$RESP" > "$OUT_DIR/annotations.txt" 2>/dev/null || : > "$OUT_DIR/annotations.txt"
  # The full report for the artifact: result_full when the server trimmed
  # the comment (ACT-3), else the result itself.
  if [ "$(jq -r '(.result_full // "") | length' "$RESP" 2>/dev/null || echo 0)" != "0" ]; then
    jq -j '.result_full' "$RESP" > "$OUT_DIR/report.md"
  else
    cp "$OUT_DIR/api_response.md" "$OUT_DIR/report.md"
  fi
  cp "$RESP" "$OUT_DIR/result.json"

  local verdict reason outcome
  verdict=$(tr -d '\r' < "$OUT_DIR/overall_status.txt" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  reason=$(head -n1 "$OUT_DIR/blocked_reason.txt")
  outcome="analysed"
  if [ "$verdict" = "blocked" ]; then
    outcome="blocked"
    cc_in_list "$reason" "$CC_BLOCKED_REASONS" && outcome="$reason"
  fi
  printf '%s\n' "$outcome" > "$OUT_DIR/outcome.txt"
  echo "Got result ($(wc -c < "$OUT_DIR/api_response.md" | tr -d ' ') bytes); verdict: ${verdict:-<none>}; assessment: $(head -n1 "$OUT_DIR/assessment.txt" | grep . || echo '<none>'); outcome: $outcome"
}

# A failed job, from the server (status failed) or a terminal error_code.
write_failure() {
  local code err outcome
  code=$(jq -r '.error_code // empty | strings' "$RESP" 2>/dev/null || true)
  err=$(jq -r '.error // empty | tostring' "$RESP" 2>/dev/null || true)
  outcome="server_failed"
  cc_in_list "$code" "$CC_SERVER_ERROR_CODES" && outcome="$code"
  [ -n "$code" ] && [ "$outcome" != "$code" ] && echo "Server error_code '$(cc_md_line "$code" 60)' is not one this action knows; recording server_failed."
  printf '%s\n' "$outcome" > "$OUT_DIR/outcome.txt"
  echo "blocked" > "$OUT_DIR/overall_status.txt"
  jq -r '.blocked_reason // "" | strings' "$RESP" > "$OUT_DIR/blocked_reason.txt" 2>/dev/null || : > "$OUT_DIR/blocked_reason.txt"
  cc_write_comment "$outcome" "The analysis did not finish on the server." "${err:-unknown error}"
  cp "$RESP" "$OUT_DIR/result.json"
  cc_warn "Compliance analysis failed on the server ($outcome): $(cc_md_line "${err:-unknown error}" 300)"
}

ATTEMPT=0
TRANSIENT=0
NOT_FOUND=0
SEEN=0
LAST_KIND=api_unreachable
LAST=""
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  NOW=$(date +%s)
  if [ "$NOW" -ge "$DEADLINE" ]; then
    cancel_job
    cc_give_up poll_timeout "No result after ${TIMEOUT}s (poll-timeout). The job may still be queued or running on the server."
    exit 0
  fi

  CODE=$(curl -sS -H @"$AUTH" --connect-timeout 10 --max-time 30 \
    -D "$HDRS" -o "$RESP" -w '%{http_code}' \
    "$API/jobs/${JOB_ID}") || CODE="000"
  [ -f "$RESP" ] || : > "$RESP"

  KIND=""
  WAIT=""
  case "$CODE" in
    200)
      STATUS=$(jq -r 'if type == "object" then (.status // "" | strings) else "" end' "$RESP" 2>/dev/null || true)
      if [ -z "$STATUS" ]; then
        KIND=bad_response
        LAST="HTTP 200 without a status"
      fi
      ;;
    429)
      WAIT=$(cc_retry_after "$HDRS" "$RESP" 60)
      echo "Attempt $ATTEMPT - HTTP 429. Rate limited; waiting ${WAIT}s."
      nap "$WAIT"
      continue
      ;;
    404)
      NOT_FOUND=$((NOT_FOUND + 1))
      LIMIT="$MAX_NOT_FOUND"
      [ "$SEEN" = 0 ] && LIMIT="$MAX_NOT_FOUND_EARLY"
      echo "Attempt $ATTEMPT - HTTP 404 ($NOT_FOUND in a row)."
      if [ "$NOT_FOUND" -ge "$LIMIT" ]; then
        cc_give_up job_lost "The server answered job_not_found ${NOT_FOUND} times in a row for job ${JOB_ID}. It expired or was lost in a restart."
        exit 0
      fi
      nap "$(cc_backoff "$NOT_FOUND")"
      continue
      ;;
    401 | 403)
      cc_give_up auth_failed "The status request was answered HTTP ${CODE}."
      exit 0
      ;;
    000 | 408 | 5??)
      KIND=api_unreachable
      LAST="HTTP $CODE"
      [ "$CODE" = "000" ] && LAST="no response (connection error or timeout)"
      ;;
    *)
      KIND=bad_response
      LAST="HTTP $CODE"
      ;;
  esac

  if [ -z "$KIND" ]; then
    case "$STATUS" in
      success | failed | pending | running | queued) ;;
      *)
        KIND=bad_response
        LAST="unexpected status '$(cc_md_line "$STATUS" 40)'"
        ;;
    esac
  fi

  if [ -n "$KIND" ]; then
    TRANSIENT=$((TRANSIENT + 1))
    LAST_KIND="$KIND"
    echo "Attempt $ATTEMPT - ${LAST} ($TRANSIENT transient error(s) in a row)."
    [ "$CODE" != "000" ] && cc_log_body "$RESP" 500
    if [ "$TRANSIENT" -ge "$MAX_TRANSIENT" ]; then
      if [ "$LAST_KIND" = bad_response ]; then
        cc_give_up bad_response "${TRANSIENT} polls in a row got an answer the action does not understand. The last one: ${LAST}."
      else
        cc_give_up api_unreachable "${TRANSIENT} polls in a row failed. The last one got ${LAST}. The job may still finish on the server."
      fi
      exit 0
    fi
    WAIT=$(cc_backoff "$TRANSIENT")
    # A 503 (job store unavailable, API disabled) may say when to come back.
    [ "$CODE" = "503" ] && WAIT=$(cc_retry_after "$HDRS" "$RESP" "$WAIT")
    nap "$WAIT"
    continue
  fi

  TRANSIENT=0
  NOT_FOUND=0
  SEEN=1

  case "$STATUS" in
    success)
      echo "Attempt $ATTEMPT - HTTP 200 - status: success"
      write_result
      exit 0
      ;;
    failed)
      echo "Attempt $ATTEMPT - HTTP 200 - status: failed"
      write_failure
      exit 0
      ;;
  esac

  # Still running. v1.7 servers add state, ages and (rarely) an error_code;
  # older servers send only the status.
  STATE=$(jq -r '.state // "" | strings' "$RESP" 2>/dev/null || true)
  case "$STATUS" in running | queued) [ -z "$STATE" ] && STATE="$STATUS" ;; esac
  EC=$(jq -r '.error_code // "" | strings' "$RESP" 2>/dev/null || true)
  if [ -n "$EC" ] && cc_in_list "$EC" "$CC_SERVER_ERROR_CODES" && [ "$EC" != job_store_unavailable ]; then
    echo "Attempt $ATTEMPT - HTTP 200 - status: $STATUS with error_code $EC; treating the job as failed."
    write_failure
    exit 0
  fi
  HB=$(num heartbeat_age_seconds)
  QS=$(num queued_seconds)
  RS=$(num running_seconds)
  PHASE=$(jq -r '.phase // "" | strings' "$RESP" 2>/dev/null | cut -c1-40 || true)
  DETAIL=""
  [ -n "$STATE" ] && DETAIL="state=$(cc_md_line "$STATE" 20)"
  [ -n "$PHASE" ] && DETAIL="$DETAIL phase=$(cc_md_line "$PHASE" 40)"
  [ -n "$QS" ] && DETAIL="$DETAIL queued=${QS}s"
  [ -n "$RS" ] && DETAIL="$DETAIL running=${RS}s"
  [ -n "$HB" ] && DETAIL="$DETAIL heartbeat=${HB}s"
  echo "Attempt $ATTEMPT - HTTP 200 - status: $STATUS${DETAIL:+ ($DETAIL)}"

  if [ "$STATE" = queued ] && [ -n "$QS" ] && [ "$QS" -ge "$QUEUE_LIMIT" ]; then
    cancel_job
    cc_give_up queue_expired "The job waited ${QS}s in the server queue without starting (limit ${QUEUE_LIMIT}s)."
    exit 0
  fi
  if [ "$STATE" = running ] && [ -n "$HB" ] && [ "$HB" -ge "$STALL" ]; then
    cancel_job
    cc_give_up worker_lost "The server job stopped reporting progress ${HB}s ago (limit ${STALL}s)."
    exit 0
  fi

  nap "$INTERVAL"
done
