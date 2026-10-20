#!/usr/bin/env bash
# Post the result (or the give-up notice) as a PR comment (W19/F5).
#
# Env:
#   GITHUB_TOKEN        token for the comment (pull-requests: write)
#   REPO                owner/name
#   PR_NUMBER           the pull request number
#   GITHUB_API_URL      default https://api.github.com
#   GITHUB_GRAPHQL_URL  default $GITHUB_API_URL/graphql
#   OUT_DIR             state directory (default /tmp)
#   COMMENT_MAX_CHARS   size guard (default 60000; GitHub refuses > 65536)
#   UPLOAD_REPORT       "true" when the artifact step will upload the report
#   PREVIOUS_COMMENTS   "keep" (default) or "minimize"
#   COMMENT_KEY         groups comments for "minimize" (default: workflow,
#                       job and frameworks, so matrix jobs keep theirs)
#
# A comment over the guard is cut on a line boundary, open code fences and
# <details> blocks are closed, and a note points to the full report. The full
# report is staged in $OUT_DIR/compliance-report for the artifact step, and the
# artifact name is written to $GITHUB_OUTPUT as artifact-name.
#
# This step never decides the job: every failure is a warning and it exits 0.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

API="${GITHUB_API_URL:-https://api.github.com}"
API="${API%/}"
GRAPHQL="${GITHUB_GRAPHQL_URL:-$API/graphql}"
MAX="$(cc_int "${COMMENT_MAX_CHARS:-}" 60000)"
[ "$MAX" -gt 65000 ] && MAX=65000
[ "$MAX" -lt 1000 ] && MAX=1000

if [ ! -s "$OUT_DIR/api_response.md" ]; then
  if cc_decided; then
    cc_write_comment "$(head -n1 "$OUT_DIR/outcome.txt")" ""
  else
    cc_give_up action_error "No comment body was produced."
  fi
fi
[ -s "$OUT_DIR/report.md" ] || cp "$OUT_DIR/api_response.md" "$OUT_DIR/report.md"

# ── Stage the full report for the artifact step ───────────────────────────
JOB_ID=""
[ -s "$OUT_DIR/job_id.txt" ] && JOB_ID="$(head -n1 "$OUT_DIR/job_id.txt")"
SUFFIX="$(printf '%s' "$JOB_ID" | tr -cd 'A-Za-z0-9' | cut -c1-12)"
[ -z "$SUFFIX" ] && SUFFIX="a${GITHUB_RUN_ATTEMPT:-1}-$$-${RANDOM}"
ARTIFACT="compliance-report-pr${PR_NUMBER:-0}-${SUFFIX}"
ARTIFACT="$(printf '%s' "$ARTIFACT" | tr -c 'A-Za-z0-9._-' '-')"
STAGE="$OUT_DIR/compliance-report"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$OUT_DIR/report.md" "$STAGE/report.md"
[ -s "$OUT_DIR/result.json" ] && cp "$OUT_DIR/result.json" "$STAGE/result.json"
for f in outcome.txt overall_status.txt assessment.txt blocked_reason.txt job_id.txt; do
  [ -f "$OUT_DIR/$f" ] && cp "$OUT_DIR/$f" "$STAGE/$f"
done
[ -n "${GITHUB_OUTPUT:-}" ] && printf 'artifact-name=%s\n' "$ARTIFACT" >> "$GITHUB_OUTPUT"

# ── Build the comment body ────────────────────────────────────────────────
KEY="${COMMENT_KEY:-}"
if [ -z "$KEY" ]; then
  KEY="$(printf '%s\n%s\n%s' "${GITHUB_WORKFLOW:-}" "${GITHUB_JOB:-}" "${FRAMEWORKS:-}" | cksum | cut -d' ' -f1)"
fi
KEY="$(printf '%s' "$KEY" | tr -cd 'A-Za-z0-9._-')"
MARKER="<!-- pr-compliance-check key=${KEY} -->"
if [ "${UPLOAD_REPORT:-true}" = "true" ]; then
  WHERE="The full report is in the \`${ARTIFACT}\` artifact of this workflow run."
else
  WHERE="Set upload-report: true to keep the full report as a workflow artifact."
fi

# Cut on a line boundary so no line is split, then close what the cut left
# open. jq counts characters (code points), as GitHub does.
BODY_JSON="$(mktemp)"
trap 'rm -f "$BODY_JSON" "${HDR:-}" "${RESP:-}"' EXIT
jq -Rs --argjson max "$MAX" --arg marker "$MARKER" --arg where "$WHERE" '
  . as $text
  | ($text | length) as $total
  | if ($total + ($marker | length) + 1) <= $max then
      {body: ($text + "\n" + $marker), cut: false, total: $total, shown: $total}
    else
      ($max - ($marker | length) - 400) as $budget
      | ($text | split("\n")) as $lines
      | (reduce $lines[] as $l ({k: 0, n: 0, stop: false};
          if .stop then .
          else (.n + ($l | length) + 1) as $nn
            | if $nn > $budget then .stop = true else .k += 1 | .n = $nn end
          end)) as $acc
      | (if $acc.k == 0 then [($lines[0])[0:$budget]] else $lines[0:$acc.k] end) as $kept
      | ($kept | join("\n")) as $head
      | ([$kept[] | select(test("^\\s*(```|~~~)"))] | length) as $fences
      | ([$kept[] | [scan("<details[\\s>]")] | length] | add // 0) as $opened
      | ([$kept[] | [scan("</details>")] | length] | add // 0) as $closed
      | ((if $fences % 2 == 1 then ["```"] else [] end)
         + [range(0; ([$opened - $closed, 0] | max))] | map(if type == "number" then "</details>" else . end)) as $closers
      | {
          body: ($head + "\n" + ($closers | map(. + "\n") | join(""))
                 + "\n---\n_This comment was cut to fit the GitHub comment size limit ("
                 + ($head | length | tostring) + " of " + ($total | tostring)
                 + " characters shown). " + $where + "_\n" + $marker),
          cut: true, total: $total, shown: ($head | length)
        }
    end' < "$OUT_DIR/api_response.md" > "$BODY_JSON"

if [ "$(jq -r '.cut' "$BODY_JSON")" = "true" ]; then
  cc_warn "The compliance comment was $(jq -r '.total' "$BODY_JSON") characters; posted the first $(jq -r '.shown' "$BODY_JSON"). The full report is in the ${ARTIFACT} artifact."
fi

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  jq -r '.body' "$BODY_JSON" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
}

if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${REPO:-}" ] || [ -z "${PR_NUMBER:-}" ]; then
  cc_warn "GITHUB_TOKEN, REPO or PR_NUMBER is not set; the comment is in the job summary instead."
  summary
  exit 0
fi

# The token goes in a header file, not on the command line.
HDR="$(mktemp)"
RESP="$(mktemp)"
chmod 600 "$HDR"
printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$HDR"

CODE=$(jq -c '{body: .body}' "$BODY_JSON" | curl -sS -X POST \
  -H @"$HDR" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  --connect-timeout 10 --max-time 30 \
  -o "$RESP" -w '%{http_code}' \
  --data-binary @- \
  "${API}/repos/${REPO}/issues/${PR_NUMBER}/comments") || CODE="000"

case "$CODE" in
  201)
    echo "Posted the PR comment: $(jq -r '.html_url // .id // empty' "$RESP" 2>/dev/null || true)"
    ;;
  403 | 404)
    cc_warn "Could not post the PR comment (HTTP ${CODE}). Pull requests from forks get a read-only token, and the workflow needs 'pull-requests: write'. The comment is in the job summary instead."
    summary
    exit 0
    ;;
  *)
    cc_warn "Could not post the PR comment (HTTP ${CODE}). The comment is in the job summary instead."
    summary
    exit 0
    ;;
esac

# ── Optional: minimize this job's earlier comments ────────────────────────
[ "${PREVIOUS_COMMENTS:-keep}" = "minimize" ] || exit 0
NEW_ID="$(jq -r '.id // empty' "$RESP" 2>/dev/null || true)"
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"
QUERY='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){comments(last:100){nodes{id databaseId isMinimized viewerDidAuthor body}}}}}'
CODE=$(jq -nc --arg q "$QUERY" --arg o "$OWNER" --arg n "$NAME" --argjson num "$(cc_int "$PR_NUMBER" 0)" \
  '{query: $q, variables: {owner: $o, name: $n, number: $num}}' | curl -sS -X POST \
  -H @"$HDR" --connect-timeout 10 --max-time 30 \
  -o "$RESP" -w '%{http_code}' --data-binary @- "$GRAPHQL") || CODE="000"
if [ "$CODE" != "200" ] || jq -e '.errors' "$RESP" >/dev/null 2>&1; then
  cc_warn "Could not list earlier compliance comments to minimize them (HTTP ${CODE})."
  exit 0
fi
IDS=$(jq -r --arg m "$MARKER" --arg new "$NEW_ID" '
  .data.repository.pullRequest.comments.nodes[]?
  | select(.viewerDidAuthor == true and .isMinimized == false
           and ((.databaseId | tostring) != $new) and ((.body // "") | contains($m)))
  | .id' "$RESP" 2>/dev/null || true)
MUTATION='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}'
COUNT=0
FAILED=0
for id in $IDS; do
  CODE=$(jq -nc --arg q "$MUTATION" --arg id "$id" '{query: $q, variables: {id: $id}}' | curl -sS -X POST \
    -H @"$HDR" --connect-timeout 10 --max-time 30 \
    -o "$RESP" -w '%{http_code}' --data-binary @- "$GRAPHQL") || CODE="000"
  if [ "$CODE" = "200" ] && ! jq -e '.errors' "$RESP" >/dev/null 2>&1; then
    COUNT=$((COUNT + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done
echo "Minimized ${COUNT} earlier compliance comment(s)."
[ "$FAILED" -gt 0 ] && cc_warn "Could not minimize ${FAILED} earlier compliance comment(s)."
exit 0
