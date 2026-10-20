# shellcheck shell=bash
# Shared helpers for the Compliance Check scripts. Source it; do not run it.
#
# State files live in $OUT_DIR (default /tmp, the paths v1.6 used):
#   outcome.txt         one value from the outcome enum (README "Outcomes")
#   overall_status.txt  the verdict: clean | warn | fail | blocked
#   api_response.md     the PR comment body
#   assessment.txt      the server's assessment, when it sends one
#   blocked_reason.txt  the server's blocked_reason, when it sends one
#   job_id.txt          the server job id, once submitted
#   report.md           the full report for the workflow artifact
#
# A step that finds outcome.txt already written does nothing: an earlier step
# has decided the run (a give-up), and the comment and enforce steps report it.
#
# Every give-up writes an outcome, a "blocked" verdict and a comment, then
# exits 0. It never passes silently and never ends the step with a bare error;
# the enforce step decides the job from the outcome and the enforce mode.

OUT_DIR="${OUT_DIR:-/tmp}"

# Outcomes the server reports as a failed job's error_code (JobErrorCode).
CC_SERVER_ERROR_CODES="queue_expired worker_lost time_limit server_restart superseded cancelled pipeline_error job_store_unavailable"
# Why the server ended a run BLOCKED (BlockedReason).
CC_BLOCKED_REASONS="no_source source_refused budget_exceeded time_limit pipeline_error llm_unavailable llm_collapse interrupted framework_unrecognised"
# Outcomes the Action decides itself.
CC_ACTION_OUTCOMES="analysed blocked server_failed not_run_fork missing_api_key diff_too_large source_too_large auth_failed submit_rejected submit_failed rate_limited api_unreachable job_lost poll_timeout bad_response action_error"

# cc_in_list <word> <space-separated list>
cc_in_list() {
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# True once a step has recorded an outcome for this run.
cc_decided() {
  [ -s "$OUT_DIR/outcome.txt" ]
}

# Remove state left by an earlier run on the same runner (self-hosted runners
# keep /tmp between jobs).
cc_reset_state() {
  rm -f "$OUT_DIR/outcome.txt" "$OUT_DIR/overall_status.txt" "$OUT_DIR/api_response.md" \
    "$OUT_DIR/assessment.txt" "$OUT_DIR/blocked_reason.txt" "$OUT_DIR/job_id.txt" \
    "$OUT_DIR/report.md" "$OUT_DIR/result.json" "$OUT_DIR/check_run.json" \
    "$OUT_DIR/annotations.txt" "$OUT_DIR/submit_response.json" "$OUT_DIR/poll_response.json" \
    "$OUT_DIR/commit_messages.json" "$OUT_DIR/source.tar.gz" "$OUT_DIR/pr.diff"
  rm -rf "$OUT_DIR/compliance-report"
}

# Escape a message for a workflow command (::warning::, ::error::). Newlines
# become %0A, so server text can never start a second command on a new line.
cc_cmd_escape() {
  printf '%s' "$1" | sed -e 's/%/%25/g' | tr -d '\r' | awk 'BEGIN{ORS=""} NR>1{print "%0A"} {print}'
}

cc_warn() { printf '::warning::%s\n' "$(cc_cmd_escape "$1")"; }
cc_error() { printf '::error::%s\n' "$(cc_cmd_escape "$1")"; }
cc_notice() { printf '::notice::%s\n' "$(cc_cmd_escape "$1")"; }

# Print the head of a response body for diagnosis. Each line is indented, so
# nothing in it can be read as a workflow command.
cc_log_body() {
  [ -s "$1" ] || return 0
  head -c "${2:-2000}" "$1" | tr -d '\r' | sed 's/^/    | /'
  echo
}

# One line of server text, without backticks, for a Markdown comment.
cc_md_line() {
  printf '%s' "$1" | tr '\r\n`' '   ' | cut -c1-"${2:-500}"
}

# cc_int <value> <default>: the value when it is a non-negative integer.
cc_int() {
  case "$1" in
    '' | *[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

cc_min() { if [ "$1" -lt "$2" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# Strip CR/LF and surrounding blanks from the API key. A secret pasted with a
# trailing newline puts a bare LF inside the Authorization header, which ends
# the header block early and drops the multipart Content-Type (see v1.6).
cc_trim_key() {
  printf '%s' "$1" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Write the Authorization header to a private file and print its path. The
# key then never appears in a process listing (curl -H @file).
cc_auth_header_file() {
  local f
  f=$(mktemp)
  chmod 600 "$f"
  printf 'Authorization: Bearer %s\n' "$1" > "$f"
  printf '%s' "$f"
}

# Seconds to wait after a 429 or 503: the Retry-After header (delta-seconds),
# else the body's retry_after_seconds, else the default. Capped.
# cc_retry_after <headers file> <body file> <default> [cap]
cc_retry_after() {
  local hdrs="$1" body="$2" def="$3" cap="${4:-${CC_RETRY_AFTER_CAP_SECONDS:-300}}" ra=""
  if [ -f "$hdrs" ]; then
    ra=$(tr -d '\r' < "$hdrs" | awk -F': *' 'tolower($1) == "retry-after" { v = $2 } END { print v }')
  fi
  case "$ra" in
    '' | *[!0-9]*) ra=$(jq -r '.retry_after_seconds // empty | floor' "$body" 2>/dev/null || true) ;;
  esac
  case "$ra" in
    '' | *[!0-9]*) ra="$def" ;;
  esac
  [ "$ra" -lt 1 ] && ra=1
  cc_min "$ra" "$cap"
}

# Exponential back-off for the n-th consecutive transient error:
# base * 2^(n-1), capped, plus up to 2 s of jitter.
cc_backoff() {
  local n="$1" base="${CC_BACKOFF_BASE_SECONDS:-5}" cap="${CC_BACKOFF_CAP_SECONDS:-60}" s i=1
  s="$base"
  while [ "$i" -lt "$n" ] && [ "$s" -lt "$cap" ]; do
    s=$((s * 2))
    i=$((i + 1))
  done
  s=$(cc_min "$s" "$cap")
  if [ "${CC_JITTER:-1}" = "1" ] && [ "$cap" -gt 2 ]; then
    s=$((s + RANDOM % 3))
  fi
  printf '%s' "$s"
}

# Short, human explanation for an outcome. One place for the wording, shared
# by give-ups and by server failures.
cc_outcome_title() {
  case "$1" in
    not_run_fork) echo "the pull request comes from a fork, and the API key is not available to it" ;;
    missing_api_key) echo "the api-key input is empty" ;;
    diff_too_large) echo "the diff is over the 5 MB limit" ;;
    source_too_large) echo "the source archive is over the server's size limit" ;;
    auth_failed) echo "the compliance API rejected the API key" ;;
    submit_rejected) echo "the compliance API refused the submission" ;;
    submit_failed) echo "the compliance API could not be reached to submit the job" ;;
    rate_limited) echo "the compliance API kept rate-limiting the submission" ;;
    api_unreachable) echo "the compliance API stopped answering while the job ran" ;;
    job_lost) echo "the server no longer knows this job" ;;
    queue_expired) echo "the job waited too long in the server queue" ;;
    worker_lost) echo "the server worker stopped reporting progress" ;;
    poll_timeout) echo "no result within poll-timeout" ;;
    bad_response) echo "the compliance API sent a response the action does not understand" ;;
    action_error) echo "the action failed before it could finish" ;;
    time_limit) echo "the analysis hit the server's time limit" ;;
    server_restart) echo "the server restarted while the job ran" ;;
    superseded) echo "a newer push replaced this run" ;;
    cancelled) echo "the job was cancelled" ;;
    pipeline_error) echo "the analysis failed on the server" ;;
    job_store_unavailable) echo "the server's job store was unavailable" ;;
    *) echo "the analysis failed on the server" ;;
  esac
}

# What the developer should do next.
cc_outcome_next() {
  case "$1" in
    not_run_fork) echo "GitHub does not pass repository secrets to workflows from forks. A maintainer can push the branch to this repository and run the check there." ;;
    missing_api_key) echo "Add the COMPLIANCE_API_KEY secret and pass it as api-key. Dependabot pull requests read Dependabot secrets, so add it there too." ;;
    diff_too_large) echo "Split the pull request into smaller changes." ;;
    source_too_large) echo "Set source-excludes or lower max-file-bytes. The job log lists the largest files." ;;
    auth_failed) echo "Check the COMPLIANCE_API_KEY secret. If it is correct, contact support." ;;
    submit_rejected) echo "Re-run the workflow. If it repeats, contact support with the job log." ;;
    superseded) echo "See the check for the newer commit." ;;
    cancelled) echo "Re-run the workflow to analyse this commit." ;;
    *) echo "Re-run the workflow. If it repeats, contact support." ;;
  esac
}

# cc_write_comment <outcome> <detail> [server error text]
# Writes the "not analysed" comment to api_response.md and report.md.
cc_write_comment() {
  local outcome="$1" detail="$2" server_err="${3:-}" title job sha
  title=$(cc_outcome_title "$outcome")
  job=""
  [ -s "$OUT_DIR/job_id.txt" ] && job=$(head -n1 "$OUT_DIR/job_id.txt")
  sha="${HEAD_SHA:-}"
  sha="${sha:0:7}"
  {
    printf '## 🔒 Compliance Review\n\n'
    printf '❌ **Not analysed: %s.**\n\n' "$title"
    [ -n "$detail" ] && printf '%s\n\n' "$detail"
    if [ -n "$server_err" ]; then
      printf 'Server message:\n\n```\n%s\n```\n\n' "$(printf '%s' "$server_err" | tr -d '`' | head -c 2000)"
    fi
    printf '%s\n\n' "$(cc_outcome_next "$outcome")"
    printf 'This is not a compliance verdict.\n\n'
    printf '<sub>Outcome `%s`' "$outcome"
    [ -n "$job" ] && printf ', job `%s`' "$job"
    [ -n "$sha" ] && printf ', commit `%s`' "$sha"
    printf '.</sub>\n'
  } > "$OUT_DIR/api_response.md"
  cp "$OUT_DIR/api_response.md" "$OUT_DIR/report.md"
  return 0
}

# cc_give_up <outcome> <detail> [server error text]
# Record a run that ends without a verdict from the server.
cc_give_up() {
  local outcome="$1" detail="$2" server_err="${3:-}"
  printf '%s\n' "$outcome" > "$OUT_DIR/outcome.txt"
  echo "blocked" > "$OUT_DIR/overall_status.txt"
  cc_write_comment "$outcome" "$detail" "$server_err"
  cc_warn "Compliance check not analysed ($outcome): $(cc_outcome_title "$outcome"). $detail"
  return 0
}
