#!/usr/bin/env bash
# Offline harness for the v1.7 scripts: submit.sh, poll-job.sh, check-key.sh,
# post-comment.sh and enforce-verdict.sh, run against tests/mock_api.py.
# Needs python3, jq and curl; no network. Run: bash tests/harness.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
S="$ROOT/scripts"
WORK="$(mktemp -d)"
MOCK_PID=""
cleanup() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

python3 -I "$HERE/mock_api.py" "$WORK/port" "$WORK/log" &
MOCK_PID=$!
for _ in $(seq 1 50); do
  [ -s "$WORK/port" ] && break
  sleep 0.1
done
[ -s "$WORK/port" ] || { echo "mock server did not start"; exit 1; }
BASE="http://127.0.0.1:$(cat "$WORK/port")"
REQ="$WORK/log/requests.jsonl"

# Fast and deterministic: 1 s back-off, no jitter, no poll interval.
export CC_JITTER=0 CC_BACKOFF_BASE_SECONDS=1 CC_BACKOFF_CAP_SECONDS=1 POLL_INTERVAL_SECONDS=0
export COMPLIANCE_API_KEY="  harness-secret-key-$$
"
KEY_TRIMMED="harness-secret-key-$$"
export HEAD_SHA="0123456789abcdef"
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_GRAPHQL_URL ENFORCE FRAMEWORKS MAX_QUEUE_SECONDS POLL_TIMEOUT_SECONDS

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok    $1"; }
bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL  $1"
  [ -n "${2:-}" ] && [ -f "$2" ] && sed 's/^/      /' "$2" | tail -20
}
# check <name> <command...>: pass when the command succeeds.
check() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else bad "$name" "${LOGF:-}"; fi
}
eq() { [ "$1" = "$2" ] || { echo "      got '$1', wanted '$2'"; return 1; }; }
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
val() { head -n1 "$OUT/$1" 2>/dev/null | tr -d '\r'; }
n_requests() { grep -c "\"path\": \"$1" "$REQ" 2>/dev/null || true; }

RUN=0
new_run() {
  RUN=$((RUN + 1))
  OUT="$WORK/run$RUN"
  mkdir -p "$OUT"
  printf 'diff --git a/app.py b/app.py\n+print(1)\n' > "$OUT/pr.diff"
  echo "source" | gzip > "$OUT/source.tar.gz"
  printf '["first commit"]' > "$OUT/commit_messages.json"
  LOGF="$OUT/log.txt"
}
submit() { # <scenario>
  OUT_DIR="$OUT" COMPLIANCE_API_URL="$BASE/s/$1/r$RUN" bash "$S/submit.sh" > "$LOGF" 2>&1
}
poll() { # <scenario>; a 30 s poll-timeout keeps a regression from hanging the run
  OUT_DIR="$OUT" COMPLIANCE_API_URL="$BASE/s/$1/r$RUN" JOB_ID="${JOB_ID:-job-$1-0001}" \
    POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-30}" bash "$S/poll-job.sh" >> "$LOGF" 2>&1
}
enforce() { # <mode> -> prints the exit code; output in $OUT/enforce.log
  ENFORCE="$1" bash "$S/enforce-verdict.sh" "$OUT/overall_status.txt" "$OUT/outcome.txt" "$OUT/assessment.txt" > "$OUT/enforce.log" 2>&1
  echo $?
}
last_submit_form() { # <scenario> <field>
  grep "\"path\": \"/s/$1/r$RUN/\"" "$REQ" | tail -1 | jq -r --arg f "$2" '.form[$f] | if type == "object" then tojson else . end'
}
gave_up() { # <outcome>: outcome, blocked verdict and a comment that says so
  eq "$(val outcome.txt)" "$1" && eq "$(val overall_status.txt)" blocked &&
    has "$OUT/api_response.md" "Not analysed" && has "$OUT/api_response.md" "Outcome \`$1\`"
}
secs() { date +%s; }

echo "== submit"

new_run
submit ok
check "submit: 202 writes job_id" eq "$(val job_id.txt)" "job-ok-0001"
check "submit: sends client_timeout 10800 by default" eq "$(last_submit_form ok client_timeout)" 10800
check "submit: sends max_queue 7200 by default" eq "$(last_submit_form ok max_queue)" 7200
check "submit: Authorization uses the trimmed key" eq "$(grep "/s/ok/r$RUN/" "$REQ" | tail -1 | jq -r '.headers.authorization')" "Bearer $KEY_TRIMMED"
check "submit: key only printed in ::add-mask::" eq "$(grep -F "$KEY_TRIMMED" "$LOGF" | grep -vc '^::add-mask::')" 0
check "submit: source archive uploaded as gzip" eq "$(last_submit_form ok source | jq -r .type)" application/gzip
check "submit: no outcome on success" test ! -s "$OUT/outcome.txt"

new_run
POLL_TIMEOUT_SECONDS=5400 PR_TITLE='@/etc/passwd;type=text/html' submit ok
check "submit: client_timeout follows poll-timeout" eq "$(last_submit_form ok client_timeout)" 5400
check "submit: max_queue = poll-timeout - 3600" eq "$(last_submit_form ok max_queue)" 1800
check "submit: a PR title starting with @ is sent as text" eq "$(last_submit_form ok pr_title)" '@/etc/passwd;type=text/html'

new_run
MAX_QUEUE_SECONDS=900 submit ok
check "submit: max-queue input is sent" eq "$(last_submit_form ok max_queue)" 900

new_run
submit submit_transient
check "submit: retries drop, 502, 503 then succeeds" eq "$(val job_id.txt)" "job-submit_transient-0001"
check "submit: four attempts" eq "$(n_requests "/s/submit_transient/r$RUN/")" 4

new_run
T0=$(secs)
submit submit_429
T1=$(secs)
check "submit: 429 then success" eq "$(val job_id.txt)" "job-submit_429-0001"
check "submit: honours Retry-After (2 x 1 s)" test $((T1 - T0)) -ge 2

new_run
T0=$(secs)
submit submit_429_body_only
T1=$(secs)
check "submit: 429 without header uses retry_after_seconds" test $((T1 - T0)) -ge 2

new_run
SUBMIT_MAX_ATTEMPTS=3 submit submit_429_forever
check "submit: endless 429 gives up as rate_limited" gave_up rate_limited
check "submit: rate_limited stops after 3 attempts" eq "$(n_requests "/s/submit_429_forever/r$RUN/")" 3

new_run
SUBMIT_MAX_ATTEMPTS=3 submit submit_down
check "submit: endless 503 gives up as submit_failed" gave_up submit_failed

new_run
submit submit_413_source
check "submit: 413 source_too_large" gave_up source_too_large
check "submit: 413 is not retried" eq "$(n_requests "/s/submit_413_source/r$RUN/")" 1
new_run
submit submit_413_diff
check "submit: 413 diff_too_large" gave_up diff_too_large
new_run
submit submit_413_nginx
check "submit: 413 from a proxy reads as source_too_large" gave_up source_too_large

new_run
submit submit_401
check "submit: 401 gives up as auth_failed" gave_up auth_failed
check "submit: 401 is not retried" eq "$(n_requests "/s/submit_401/r$RUN/")" 1

new_run
submit submit_400
check "submit: 400 gives up as submit_rejected" gave_up submit_rejected
check "submit: 400 comment names the server error" has "$OUT/api_response.md" "malformed_multipart"

new_run
SUBMIT_MAX_ATTEMPTS=2 submit submit_no_jobid
check "submit: 202 without job_id ends submit_failed" gave_up submit_failed
new_run
SUBMIT_MAX_ATTEMPTS=2 submit submit_bad_jobid
check "submit: unsafe job_id refused" gave_up submit_failed

new_run
SUBMIT_MAX_ATTEMPTS=2 OUT_DIR="$OUT" COMPLIANCE_API_URL="http://127.0.0.1:9/s/x/y" bash "$S/submit.sh" > "$LOGF" 2>&1
check "submit: connection refused ends submit_failed" gave_up submit_failed

new_run
FRAMEWORKS='["hipaa","hipaaa"]' submit frameworks_dropped
check "submit: dropped frameworks warn" has "$LOGF" "::warning::The compliance API did not recognise these frameworks and ignored them: hipaaa. It is checking: hipaa."
check "submit: frameworks sent as given" eq "$(last_submit_form frameworks_dropped frameworks)" '["hipaa","hipaaa"]'
new_run
FRAMEWORKS='["nope","x"]' submit frameworks_none
check "submit: no accepted frameworks warns about the default" has "$LOGF" "None of the requested frameworks were accepted"
new_run
FRAMEWORKS='hipaa' submit ok
check "submit: a non-JSON frameworks input warns" has "$LOGF" "::warning::The frameworks input is not a JSON array"
new_run
submit ok
check "submit: no frameworks warning without frameworks" hasnt "$LOGF" "::warning::"

new_run
COMPLIANCE_API_KEY=$' \n' submit ok
check "submit: empty key gives up as missing_api_key" gave_up missing_api_key
check "submit: empty key makes no request" eq "$(n_requests "/s/ok/r$RUN/")" 0

new_run
echo "not_run_fork" > "$OUT/outcome.txt"
submit ok
check "submit: does nothing once an outcome is recorded" eq "$(n_requests "/s/ok/r$RUN/")" 0

echo "== poll"

new_run
poll clean
check "poll: queued, running, success" eq "$(val outcome.txt)" analysed
check "poll: verdict clean" eq "$(val overall_status.txt)" clean
check "poll: assessment complete" eq "$(val assessment.txt)" complete
check "poll: logs state and phase" has "$LOGF" "state=running phase=sweep"
check "poll: heartbeat is floored (4.7 -> 4)" has "$LOGF" "heartbeat=4s"
check "poll: report staged" has "$OUT/report.md" "verdict clean"

new_run
poll transient_poll
check "poll: drop, 502, 503, HTML, no status, 504, then success" eq "$(val outcome.txt)" analysed
check "poll: seven polls" eq "$(n_requests "/s/transient_poll/r$RUN/jobs/")" 7
check "poll: response bodies are logged indented" has "$LOGF" "    | <html>502 Bad Gateway</html>"

new_run
T0=$(secs)
poll poll_429
T1=$(secs)
check "poll: 429 then success" eq "$(val outcome.txt)" analysed
check "poll: honours Retry-After on 429" test $((T1 - T0)) -ge 1

new_run
poll notfound_early
check "poll: 404 right after submit is tolerated" eq "$(val outcome.txt)" analysed

new_run
poll notfound_lost
check "poll: 404 after the job was seen ends job_lost" gave_up job_lost
check "poll: job_lost after three 404s" eq "$(n_requests "/s/notfound_lost/r$RUN/jobs/")" 4

new_run
QUEUE_GIVE_UP_SECONDS=250 poll queued_forever
check "poll: queued too long gives up as queue_expired" gave_up queue_expired
check "poll: queue_expired names the wait" has "$OUT/api_response.md" "waited 300s"
check "poll: queue_expired asks the server to cancel" eq "$(n_requests "/s/queued_forever/r$RUN/jobs/job-queued_forever-0001/cancel")" 1

new_run
poll queued_server_limit
check "poll: the server's echoed max_queue sets the queue limit" gave_up queue_expired
check "poll: echoed max_queue plus 300 s" has "$OUT/api_response.md" "waited 400s"

new_run
poll stale_heartbeat
check "poll: stale heartbeat gives up as worker_lost" gave_up worker_lost
check "poll: heartbeat age is floored (1300.9 -> 1300)" has "$OUT/api_response.md" "1300s ago"
check "poll: worker_lost asks the server to cancel" eq "$(n_requests "/s/stale_heartbeat/r$RUN/jobs/job-stale_heartbeat-0001/cancel")" 1

new_run
poll heartbeat_edge
check "poll: heartbeat 1199.99 is under the 1200 s limit" eq "$(val outcome.txt)" analysed

new_run
T0=$(secs)
POLL_TIMEOUT_SECONDS=2 POLL_INTERVAL_SECONDS=1 poll legacy_pending
T1=$(secs)
check "poll: old server pending until poll-timeout" gave_up poll_timeout
check "poll: poll_timeout respects the deadline" test $((T1 - T0)) -le 5
check "poll: poll_timeout comment names poll-timeout" has "$OUT/api_response.md" "poll-timeout"

new_run
poll legacy_then_success
check "poll: old server without new fields still succeeds" eq "$(val outcome.txt)" analysed
check "poll: no assessment from an old server" eq "$(val assessment.txt)" ""

new_run
poll failed_superseded
check "poll: failed superseded" gave_up superseded
check "poll: superseded comment points to the newer run" has "$OUT/api_response.md" "a newer push replaced this run"

new_run
poll failed_time_limit
check "poll: failed time_limit" gave_up time_limit
check "poll: time_limit keeps blocked_reason" eq "$(val blocked_reason.txt)" time_limit

new_run
poll failed_legacy
check "poll: failed without error_code is server_failed" gave_up server_failed
check "poll: server error text in the comment" has "$OUT/api_response.md" "boom"

new_run
poll failed_newcode
check "poll: unknown error_code is server_failed" gave_up server_failed

new_run
poll failed_injection
check "poll: server text cannot start a workflow command" eval "! grep -Eq '^::(add-mask|error)::(leak|pwned)' '$LOGF'"
check "poll: backticks stripped from server text" eval "[ \$(grep -c '^\`\`\`' '$OUT/api_response.md') -eq 2 ]"

new_run
poll pending_error_code
check "poll: a terminal error_code on a pending answer fails fast" gave_up worker_lost

new_run
POLL_MAX_TRANSIENT=3 poll bad_status
check "poll: unknown status repeated gives up as bad_response" gave_up bad_response

new_run
POLL_MAX_TRANSIENT=3 poll down
check "poll: endless 503 gives up as api_unreachable" gave_up api_unreachable

new_run
poll poll_401
check "poll: 401 gives up as auth_failed" gave_up auth_failed

new_run
poll blocked_budget
check "poll: blocked result records the blocked_reason as outcome" eq "$(val outcome.txt)" budget_exceeded
check "poll: blocked result keeps the server comment" has "$OUT/api_response.md" "verdict blocked"

new_run
poll blocked_newreason
check "poll: unknown blocked_reason records blocked" eq "$(val outcome.txt)" blocked

new_run
rm -f "$OUT/job_id.txt"
JOB_ID="" OUT_DIR="$OUT" COMPLIANCE_API_URL="$BASE/s/clean/r$RUN" bash "$S/poll-job.sh" > "$LOGF" 2>&1
check "poll: no job id is an action_error" gave_up action_error

new_run
poll fail
check "poll: check_run body saved" eq "$(jq -r .conclusion "$OUT/check_run.json")" failure
check "poll: annotations saved" has "$OUT/annotations.txt" "::error file=a.py,line=1::bad"

echo "== enforce"

new_run
poll clean
check "enforce: clean passes under hard" eq "$(enforce hard)" 0
check "enforce: clean passes under verdict-only" eq "$(enforce verdict-only)" 0
check "enforce: clean passes under advisory" eq "$(enforce advisory)" 0
check "enforce: unset mode is hard" eq "$(enforce '')" 0

new_run
poll fail
check "enforce: fail fails under hard" eq "$(enforce hard)" 1
check "enforce: fail fails under verdict-only" eq "$(enforce verdict-only)" 1
check "enforce: fail passes under advisory" eq "$(enforce advisory)" 0
check "enforce: advisory warns instead of erroring" has "$OUT/enforce.log" "::warning::Advisory mode: Compliance check did not pass (verdict: fail)"
check "enforce: advisory prints no ::error::" hasnt "$OUT/enforce.log" "::error::"

new_run
poll partial_warn
check "enforce: partial warn fails under hard (D1 c)" eq "$(enforce hard)" 1
check "enforce: partial says why" has "$OUT/enforce.log" "not fully assessed (assessment: partial), so the check cannot pass under enforce: hard"
check "enforce: partial warn passes under verdict-only" eq "$(enforce verdict-only)" 0
check "enforce: verdict-only notes the partial run" has "$OUT/enforce.log" "::notice::The run was not fully assessed"
check "enforce: partial warn passes under advisory" eq "$(enforce advisory)" 0

new_run
poll nothing
check "enforce: nothing_to_assess passes under hard" eq "$(enforce hard)" 0

new_run
poll weird_assessment
check "enforce: unknown assessment fails under hard" eq "$(enforce hard)" 1
check "enforce: unknown assessment passes under verdict-only" eq "$(enforce verdict-only)" 0

new_run
poll unknown_verdict
check "enforce: unknown verdict fails under hard (T04)" eq "$(enforce hard)" 1
check "enforce: unknown verdict has its own warning" has "$OUT/enforce.log" "::warning::Unknown verdict: the compliance API sent 'pass'"
check "enforce: unknown verdict fails under verdict-only" eq "$(enforce verdict-only)" 1
check "enforce: unknown verdict passes under advisory, with the warning" eq "$(enforce advisory)" 0
check "enforce: advisory still shows the unknown-verdict warning" has "$OUT/enforce.log" "::warning::Unknown verdict"

new_run
poll no_verdict
check "enforce: missing verdict fails under hard (T04)" eq "$(enforce hard)" 1
check "enforce: missing verdict has its own warning" has "$OUT/enforce.log" "::warning::Missing verdict"
check "enforce: missing verdict passes under advisory" eq "$(enforce advisory)" 0

new_run
POLL_TIMEOUT_SECONDS=1 POLL_INTERVAL_SECONDS=1 poll legacy_pending
check "enforce: a give-up fails under hard" eq "$(enforce hard)" 1
check "enforce: a give-up names the outcome" has "$OUT/enforce.log" "verdict: blocked, outcome: poll_timeout"
check "enforce: a give-up fails under verdict-only" eq "$(enforce verdict-only)" 1
check "enforce: a give-up passes under advisory" eq "$(enforce advisory)" 0

new_run
poll clean
check "enforce: unknown mode falls back to hard" eq "$(enforce strict)" 0
check "enforce: unknown mode warns" has "$OUT/enforce.log" "::warning::Unknown enforce mode 'strict'"
echo partial > "$OUT/assessment.txt"
check "enforce: fallback hard still checks the assessment" eq "$(enforce strict)" 1

echo "== fork and key"

new_run
OUT_DIR="$OUT" COMPLIANCE_API_KEY="" IS_FORK=true bash "$S/check-key.sh" > "$LOGF" 2>&1
check "key: fork with empty key is not_run_fork" gave_up not_run_fork
check "key: fork comment explains secrets" has "$OUT/api_response.md" "does not pass repository secrets to workflows from forks"
submit ok
check "key: submit skips after not_run_fork" eq "$(n_requests "/s/ok/r$RUN/")" 0
poll clean
check "key: poll skips after not_run_fork" eq "$(n_requests "/s/clean/r$RUN/")" 0
check "key: not_run_fork fails under hard" eq "$(enforce hard)" 1
check "key: not_run_fork passes under advisory" eq "$(enforce advisory)" 0

new_run
OUT_DIR="$OUT" COMPLIANCE_API_KEY="" IS_FORK=false PR_AUTHOR='dependabot[bot]' bash "$S/check-key.sh" > "$LOGF" 2>&1
check "key: Dependabot with empty key is missing_api_key" gave_up missing_api_key
check "key: Dependabot hint" has "$LOGF" "Dependabot secrets"

new_run
OUT_DIR="$OUT" IS_FORK=true bash "$S/check-key.sh" > "$LOGF" 2>&1
check "key: a fork with a key (pull_request_target) proceeds" test ! -s "$OUT/outcome.txt"

echo "== comment"

export GITHUB_API_URL="$BASE/gh" GITHUB_GRAPHQL_URL="$BASE/gh/graphql" GITHUB_TOKEN="gh-token-$$"
comment() { # <repo> <pr> [extra env assignments via env]
  : > "$OUT/github_output"
  : > "$OUT/summary.md"
  OUT_DIR="$OUT" REPO="$1" PR_NUMBER="$2" GITHUB_OUTPUT="$OUT/github_output" GITHUB_STEP_SUMMARY="$OUT/summary.md" \
    bash "$S/post-comment.sh" >> "$LOGF" 2>&1
  echo $?
}
posted_body() { # <repo/issues/n>: body of the last comment posted there
  grep "\"path\": \"/gh/repos/$1/comments\"" "$REQ" | grep '"POST"' | tail -1 | jq -r '.json.body'
}

new_run
poll oversized
check "comment: exits 0" eq "$(comment acme/app 7)" 0
posted_body acme/app/issues/7 > "$OUT/posted.md"
LEN=$(jq -Rs length < "$OUT/posted.md")
check "comment: oversized body is at most 60,000 characters" test "$LEN" -le 60000
check "comment: oversized body is cut with a note" has "$OUT/posted.md" "This comment was cut to fit the GitHub comment size limit"
check "comment: note names the artifact" has "$OUT/posted.md" "compliance-report-pr7-joboversized"
check "comment: cut closes the open code fence" eval "[ \$(( \$(grep -c '^\`\`\`' '$OUT/posted.md') % 2 )) -eq 0 ]"
check "comment: cut closes <details>" eq "$(grep -c '<details>' "$OUT/posted.md")" "$(grep -c '</details>' "$OUT/posted.md")"
check "comment: cut on a line boundary" eval "grep -Eq '^finding line [0-9]{6} x{80}\$' '$OUT/posted.md' && ! grep -Eq '^finding line [0-9]{6} x{1,79}\$' '$OUT/posted.md'"
check "comment: warning for the cut" has "$LOGF" "::warning::The compliance comment was"
check "comment: artifact name in GITHUB_OUTPUT" has "$OUT/github_output" "artifact-name=compliance-report-pr7-joboversized"
check "comment: artifact holds result_full" eq "$(jq -Rs length < "$OUT/compliance-report/report.md")" "$(jq -r '.result_full | length' "$OUT/result.json")"
check "comment: artifact holds the raw result" test -s "$OUT/compliance-report/result.json"
check "comment: artifact holds the outcome" eq "$(head -n1 "$OUT/compliance-report/outcome.txt")" analysed

new_run
poll clean
comment acme/app 8 > /dev/null
posted_body acme/app/issues/8 > "$OUT/posted.md"
check "comment: small body posted whole" has "$OUT/posted.md" "verdict clean"
check "comment: small body is not cut" hasnt "$OUT/posted.md" "was cut"
check "comment: carries the hidden marker" has "$OUT/posted.md" "<!-- pr-compliance-check key="
check "comment: token never in argv or log" hasnt "$LOGF" "gh-token-$$"

new_run
POLL_TIMEOUT_SECONDS=1 POLL_INTERVAL_SECONDS=1 poll legacy_pending
comment acme/app 9 > /dev/null
posted_body acme/app/issues/9 > "$OUT/posted.md"
check "comment: a give-up is posted" has "$OUT/posted.md" "Not analysed: no result within poll-timeout"
check "comment: give-up comment says it is not a verdict" has "$OUT/posted.md" "This is not a compliance verdict."
check "comment: give-up artifact name falls back to the job id" has "$OUT/github_output" "artifact-name=compliance-report-pr9-joblegacypen"

new_run
OUT_DIR="$OUT" COMPLIANCE_API_KEY="" IS_FORK=true bash "$S/check-key.sh" > "$LOGF" 2>&1
check "comment: read-only token (fork) still exits 0" eq "$(comment acme/readonly 3)" 0
check "comment: read-only token warns" has "$LOGF" "::warning::Could not post the PR comment (HTTP 403)"
check "comment: read-only token puts the comment in the job summary" has "$OUT/summary.md" "Not analysed"
check "comment: no job id gives a random artifact suffix" grep -Eq 'artifact-name=compliance-report-pr3-a1-[0-9]+-[0-9]+' "$OUT/github_output"

# previous-comments: minimize. Seed: two earlier bot comments with this job's
# key, one bot comment with another key (a matrix sibling) and one human
# comment that quotes the marker.
new_run
poll clean
KEYED="<!-- pr-compliance-check key=k1 -->"
seed() { curl -sS -o /dev/null -X POST --data-binary "$1" "$BASE/gh/repos/acme/app/issues/11/comments"; }
seed "$(jq -nc --arg b "old 1
$KEYED" '{body: $b}')"
seed "$(jq -nc --arg b "old 2
$KEYED" '{body: $b}')"
seed "$(jq -nc '{body: "sibling\n<!-- pr-compliance-check key=k2 -->"}')"
seed "$(jq -nc --arg b "quoted
$KEYED" '{body: $b, _as: "octocat"}')"
BEFORE=$(grep -c 'minimizeComment(input' "$REQ" || true)
COMMENT_KEY=k1 PREVIOUS_COMMENTS=minimize comment acme/app 11 > /dev/null
AFTER=$(grep -c 'minimizeComment(input' "$REQ" || true)
check "comment: minimize hides the two earlier comments of this job" eq "$((AFTER - BEFORE))" 2
check "comment: minimize reports the count" has "$LOGF" "Minimized 2 earlier compliance comment(s)."
COMMENT_KEY=k1 PREVIOUS_COMMENTS=minimize comment acme/app 11 > /dev/null
AFTER2=$(grep -c 'minimizeComment(input' "$REQ" || true)
check "comment: minimize skips comments already hidden" eq "$((AFTER2 - AFTER))" 1
COMMENT_KEY=k1 comment acme/app 11 > /dev/null
AFTER3=$(grep -c 'minimizeComment(input' "$REQ" || true)
check "comment: keep (default) minimizes nothing" eq "$((AFTER3 - AFTER2))" 0

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
