# 🔒 Compliance Check Action

**Status:** Pre-release / Beta (v1.7). Feedback welcome before General Availability.

Analyzes pull request diffs for compliance and posts the results as a PR comment.

📋 [View Release Notes](https://github.com/HIPAACKR/pr-compliance-check/releases/tag/v1.7)

## Supported frameworks & languages

Analysis support is currently tuned for the following application frameworks:

- Django (Python)
- Ruby on Rails
- Laravel (PHP)
- Express (Node.js)
- Swift
- Android
- Spring Boot (Java)
- .NET Core

Repos using other stacks are still scanned.

## Quick Start

Add this to `.github/workflows/compliance.yml` in your repository:

```yaml
name: Compliance Check
on:
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  pull-requests: write
  contents: read
  checks: write
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  compliance-check:
    runs-on: ubuntu-latest
    timeout-minutes: 210
    steps:
      - uses: HIPAACKR/pr-compliance-check@v1.7
        with:
          api-key: ${{ secrets.COMPLIANCE_API_KEY }}
          frameworks: '["hipaa"]'
```

Set `timeout-minutes` to `poll-timeout / 60 + 30` (210 with the default). The concurrency group stops the run for an older push when a new one arrives.

> **Note:** Only `"hipaa"` is fully supported in this release. Other compliance identifiers (e.g. `"cmmc"`, `"gdpr"`, `"pci-dss"`, `"soc2"`, `"cra"`, `"dpdp"`) are recognized for forward compatibility as those frameworks near release, but results for them should be treated as experimental/incomplete until announced as GA. Send one framework per job.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | ✅ | | Compliance API key. Masked in the log and sent only in a header file, never on a command line. |
| `github-token` | No | `${{ github.token }}` | Token for posting PR comments and the named check. |
| `frameworks` | No | | JSON array of compliance frameworks to map findings against, e.g. `["hipaa","cmmc"]`. Omit for CWE-only output. The action warns when the value is not a JSON array, and when the server reports frameworks it did not recognise. |
| `poll-interval` | No | `5` | Seconds between status polls. |
| `poll-timeout` | No | `10800` | Max seconds to wait for a result (3h). Also sent to the server as `client_timeout`, so it can expire a job nobody will read. The server job TTL (`COMPLIANCE_PR_JOB_TTL_SECONDS`, default 3h15m and never lower) must be ≥ this value. **The default drops to `5400` in a later release, once the server's run budget is live.** |
| `max-queue` | No | poll-timeout − 3600 | Max seconds the job may wait in the server queue before it starts. Sent as `max_queue`; the server clamps it. |
| `enforce` | No | `hard` | How the result decides the job: `hard`, `verdict-only` or `advisory`. See [Enforce modes](#enforce-modes). |
| `publish-check-run` | No | `true` | Also publish the result as a named **Compliance Check** check with inline annotations on the changed lines. Needs `checks: write`; without it the step only logs a warning. Set to `false` to keep just the PR comment. |
| `upload-report` | No | `true` | Upload the full report and the raw result as a workflow artifact. A cut PR comment points to it. |
| `previous-comments` | No | `keep` | `minimize` hides this job's earlier compliance comments on the PR as outdated. Off by default. |
| `source-excludes` | No | | Extra tar exclude globs for the uploaded source archive, comma- or newline-separated (e.g. `public/images/*,docs/*`). Use when a repo trips the 100 MB cap on assets the scanner doesn't need. Excluding paths hides them from your own compliance scan, so exclude assets, not code. Secret-bearing files are always left out (see below). |
| `max-file-bytes` | No | `2097152` | Any single tracked file larger than this is left out of the source archive. Oversized files aren't analyzable source; the usual culprit is a Figma-exported `.svg` carrying a base64 raster. Lockfiles are exempt. |

Every v1.6 input keeps its name and default.

## Outputs

| Output | Description |
|--------|-------------|
| `outcome` | What happened to the run. One value from the [outcome table](#outcomes). |
| `verdict` | `clean`, `warn`, `fail` or `blocked`. Empty when the run was skipped. |
| `assessment` | `complete`, `partial`, `not_assessed` or `nothing_to_assess` when the server sends it. Empty otherwise. |
| `job-id` | The compliance API job id, once submitted. |
| `report-artifact` | Name of the workflow artifact that holds the full report. |

## Enforce modes

| Mode | The job fails when | The named check |
|------|--------------------|-----------------|
| `hard` (default) | the verdict is `fail` or `blocked`; the verdict is missing or unknown; the run gave up (any outcome other than `analysed`); or the server says the run was not fully assessed (`assessment` is `partial`, `not_assessed` or an unknown value) | as the server sends it |
| `verdict-only` | the verdict is `fail` or `blocked`; the verdict is missing or unknown; the run gave up. The assessment is only reported. | a `failure` is shown as `neutral` |
| `advisory` | never. Every problem is a warning. | a `failure` is shown as `neutral` |

- A missing or unknown verdict always prints its own warning, separate from a `fail`. It means the server broke its contract, not that the code has a finding. Under `hard` and `verdict-only` it still fails the check (fail closed, as in v1.6).
- `nothing_to_assess` passes under `hard`: routing worked and no code-level control applies to the change.
- Servers without the `assessment` field (everything before the M1 server release) are judged on the verdict alone in every mode.
- An action error (git or checkout failing) fails the job in every mode, after a PR comment.

**Why `hard` is the default.** v1.6 failed the job on any verdict other than `clean` or `warn`, and published the named check exactly as the server sent it. `hard` does both. Its one extra rule, failing a run the server did not fully assess, keeps today's result for partial runs: the server reports them as `blocked` until its partial-verdict switch is flipped, and after that it reports them as `warn`, which `hard` still fails. `verdict-only` would change the named check from `failure` to `neutral`, and a repo that made **Compliance Check** a required check would then merge on a failing verdict.

Use `advisory` instead of `continue-on-error: true` for repos that should never block.

## Outcomes

The `outcome` output (and `/tmp/outcome.txt` on the runner) holds one value. The names are shared with the server: a failed job's `error_code` and a BLOCKED result's `blocked_reason` use the same words. Every outcome other than `analysed` and `skipped` comes with verdict `blocked` and a PR comment that says what happened and what to do.

**The server returned a result**

| Outcome | Meaning |
|---------|---------|
| `analysed` | The server returned a verdict of `clean`, `warn` or `fail`. The verdict decides. |
| `no_source` | BLOCKED: the server had no source archive to read. |
| `source_refused` | BLOCKED: the server refused the source archive (too big unpacked, too many files, unsafe paths). |
| `budget_exceeded` | BLOCKED: the run went past its time budget before every check ran. |
| `time_limit` | BLOCKED: the run hit the server's hard time limit. Also an `error_code`. |
| `pipeline_error` | BLOCKED: the analysis pipeline failed. Also an `error_code`. |
| `llm_unavailable` | BLOCKED: the model was not reachable when the run started. |
| `llm_collapse` | BLOCKED: too many model calls failed for the result to mean anything. |
| `interrupted` | BLOCKED: the run was interrupted. |
| `framework_unrecognised` | BLOCKED: none of the requested frameworks is known to the server. |
| `blocked` | BLOCKED with no reason, or one this version does not know. |

**The server reported a failed job (`error_code`)**

| Outcome | Meaning |
|---------|---------|
| `queue_expired` | The job waited longer than `max-queue` without starting. Also an action give-up when the server does not expire it first. |
| `worker_lost` | The server worker stopped reporting progress. Also an action give-up when the heartbeat is over 1,200 s old. |
| `server_restart` | A server deploy stopped the job. Re-run. |
| `superseded` | A newer push to the same PR replaced this job. See the newer check. |
| `cancelled` | The job was cancelled. |
| `job_store_unavailable` | The server's job store was down. |
| `server_failed` | The job failed with no `error_code`, or one this version does not know. |

**The action gave up**

| Outcome | Meaning |
|---------|---------|
| `not_run_fork` | Fork PR with an empty api-key. GitHub passes no secrets to fork workflows. |
| `missing_api_key` | Empty api-key on a PR from this repository. Dependabot PRs read Dependabot secrets. |
| `diff_too_large` | The diff is over 5 MB (checked before submit, or a server 413). |
| `source_too_large` | The source archive is over the 100 MB cap (checked before submit, or a server 413). |
| `auth_failed` | The API answered 401 or 403. |
| `submit_rejected` | The API refused the submission (400 or another 4xx). |
| `submit_failed` | Every submit attempt failed (connection errors, 5xx, 404, no job id). |
| `rate_limited` | Every submit attempt was answered 429. |
| `api_unreachable` | 20 polls in a row failed (connection errors, 5xx). The job may still finish on the server. |
| `bad_response` | 20 polls in a row got an answer the action does not understand. |
| `job_lost` | The server answered `job_not_found` 3 times after the job was seen (6 right after submit). |
| `poll_timeout` | No result within `poll-timeout`. |
| `action_error` | A step of the action failed before the run had an outcome. |

**No run**

| Outcome | Meaning |
|---------|---------|
| `skipped` | No substantive change (whitespace-only, metadata-only, net-empty). Nothing is submitted, no comment is posted and the check passes. |

When the action gives up on a job that may still be running (`poll_timeout`, `queue_expired`, `worker_lost`), it asks the server to cancel it, so the shared GPU is not spent on a result nobody reads.

## Retries

| Call | Retried | Not retried |
|------|---------|-------------|
| Submit | connection errors, 5xx, 404, 408, a 2xx without a job id: up to 6 attempts with back-off (5, 10, 20, 40, 60 s). 429 and 503 wait for `Retry-After` (capped at 300 s). | 400 and other 4xx (`submit_rejected`), 401/403 (`auth_failed`), 413 (`diff_too_large` or `source_too_large`) |
| Poll | connection errors, 5xx, HTML or unreadable 200s, unknown status values: up to 20 in a row with back-off. 429 waits for `Retry-After`. 404 up to 6 times right after submit, 3 times later. | 401/403 (`auth_failed`) |

Every response's HTTP status is checked. While the job runs the action reads `state`, `queued_seconds` and `heartbeat_age_seconds` (whole seconds, floored) and gives up early when the job sits in the queue past `max-queue` + 300 s or its heartbeat is older than 1,200 s. Servers that send only `{"status": "pending"}` are polled exactly as v1.6 did, until `poll-timeout`.

## Fork pull requests

GitHub does not pass repository secrets to `pull_request` workflows from forks, so `api-key` arrives empty. v1.6 stopped with a bare error. v1.7 records `not_run_fork`, sets the verdict to `blocked` and posts a comment saying so. It is never a silent pass. The job then follows `enforce`: it fails under `hard` and `verdict-only` and passes with a warning under `advisory`.

Fork PRs also get a read-only token, so the comment may not post. The action then writes the comment to the job summary and warns.

## What is uploaded

- The diff, the commit messages, the repo `README.md` (as context) and an archive of the **git-tracked** files at the PR head.
- Never uploaded, whatever the inputs say: `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks` and `*.keystore`, anywhere in the tree. They are listed in the log as left out.
- Left out as unreadable: compiled or packaged binaries by extension (`.jar`, `.zip`, `.so`, images, fonts, media…) and any file over `max-file-bytes`. Lockfiles are exempt from the size cap because the dependency check reads them: `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Gemfile.lock`, `composer.lock`, `poetry.lock`, `Pipfile.lock`, `Cargo.lock`, `go.sum`.
- The diff itself is sent whole. A PR that changes a `.env` file sends that change in the diff.

## Comment size and the full report

GitHub refuses comments over 65,536 characters. A comment over 60,000 characters is cut on a line boundary, any open code block or `<details>` section is closed, and a note names the report artifact. The artifact (`upload-report`) holds `report.md` (the server's `result_full` when it trimmed the comment itself, else the full result), `result.json` (the raw status response) and the outcome files.

## Setup

1. Obtain your API key from the UbiComply compliance team at https://ubicomply.ai/.
2. Add it as a repository secret:
   - `COMPLIANCE_API_KEY`
3. Copy the workflow file above into your repo.

That's it. Every PR will now be reviewed automatically.

## How It Works

0. Skips the analysis entirely, leaving the check green, when the PR changes no substantive content. Whitespace-only, blank-line-only, metadata-only (pure rename or mode change), and net-empty PRs all qualify; binary changes never do. Nothing is submitted and no comment is posted.
1. Collects the PR diff and full commit messages (subject + body).
2. Checks the API key. An empty key ends the run with a comment (`not_run_fork` or `missing_api_key`).
3. Packages the source for the agentic sweep (see [What is uploaded](#what-is-uploaded)). Source is never dropped by type. `.svg` in particular stays in scope unless it's oversized, since an SVG can carry `<script>`.
4. Submits to the UbiComply compliance analysis API, with `client_timeout` and `max_queue`. If `frameworks` is provided, findings are mapped to the requested compliance controls.
5. Polls until the analysis is complete, the server reports a failure, or the action gives up.
6. Posts the result, or what went wrong, as a PR comment. Uploads the full report as an artifact.
7. Publishes the same result as a named **Compliance Check** check, with the report in its details and up to 50 findings as inline annotations on the changed lines (`publish-check-run`). GitHub shows at most 10 error and 10 warning annotations per step inline; the rest are in the check's summary. Publishing never changes the verdict.
8. Decides the job per `enforce`. Under the default `hard`, it fails unless the verdict is `clean` or `warn` and the run was fully assessed.

## Migrating from v1.6

Change the pin to `@v1.7`. Nothing else is required: every input keeps its name and default, and the default `enforce: hard` fails exactly what v1.6 failed on today's server.

What changes:

1. **Give-ups comment.** A timeout, an unreachable API, a lost job, an oversized diff or archive and a missing key used to end with a bare error. Each now posts a comment, sets the `outcome` output and a `blocked` verdict. Under `hard` and `verdict-only` the job still fails; under `advisory` it passes with a warning.
2. **Transient errors are retried** on submit and poll (see [Retries](#retries)). v1.6 failed on the first 5xx or 404.
3. **Secret files are never uploaded.** `.env*`, keys and keystores are left out of the archive even without `source-excludes`.
4. **Large lockfiles are uploaded.** They no longer fall to `max-file-bytes`, so the archive may grow.
5. **Partial runs.** Once the server sends `assessment`, `hard` fails a run that was not fully assessed, also after the server starts reporting partial runs as `warn`. Use `verdict-only` to pass those on the verdict alone.
6. **Fork PRs** with no key get a `not_run_fork` comment instead of a bare error.
7. **New log steps**: "Check the API key", "Upload the full report", "Record the outcome". The artifact upload needs no extra permission.
8. **`continue-on-error` users**: switch to `enforce: advisory`. It keeps the comment and the outcome, and the named check shows `neutral` instead of `failure`.
9. **`poll-timeout`** stays `10800`. A later release lowers the default to `5400` once the server's run budget is live; set `timeout-minutes` to match when you change it.

## Disclaimer

Compliance Check Action is a developer productivity and risk-flagging tool. It does not constitute legal advice and does not guarantee HIPAA, CMMC, or any other compliance certification. Organizations remain responsible for their own compliance program, risk assessments, and legal review.
