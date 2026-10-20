# Compliance Check Action v1.7

v1.7 makes the action survive a busy or restarting server, and makes every run end with an answer on the PR. A run that cannot get a verdict now says why in a comment instead of ending on a bare error. It never passes silently.

Upgrade: change `@v1.6` to `@v1.7`. No input changes are needed. The default behaviour fails exactly what v1.6 failed on today's server.

## Highlights

- **Retries.** Submit and poll retry connection errors, 5xx responses and a 404 right after submit, with back-off. A 429 or 503 waits for `Retry-After`. Every response's HTTP status is checked.
- **Every give-up comments.** Timeouts, an unreachable API, a lost job, an oversized diff or archive, a rejected key and a missing key each post a PR comment, set a `blocked` verdict and set the new `outcome` output.
- **Fork PRs.** A fork PR has no access to the API key. It now gets outcome `not_run_fork`, a comment and a `blocked` verdict instead of a bare error.
- **Fail fast.** On servers that report job state, the action stops when a job waits in the queue past `max-queue`, or when its worker stops sending heartbeats, and asks the server to cancel the job.
- **Enforce modes.** New input `enforce`: `hard` (default), `verdict-only` or `advisory`.
- **Comment size guard.** Comments over 60,000 characters are cut on a line boundary with a note. The full report is uploaded as a workflow artifact.
- **No secret files in the upload.** `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks` and `*.keystore` are always left out of the source archive.
- **Lockfiles are uploaded** whatever their size, so the dependency check can read them.
- **Frameworks warnings.** The action warns when `frameworks` is not a JSON array, and when the server reports frameworks it did not recognise.
- **Safer submit.** Text fields are sent with `--form-string`, so a PR title starting with `@` can no longer make curl upload a local file. The API key goes in a header file, never on a command line.

## New inputs

| Input | Default | What it does |
|-------|---------|--------------|
| `enforce` | `hard` | `hard` fails on a non-passing, missing or unknown verdict, on a give-up, and on a run the server did not fully assess. `verdict-only` fails on the verdict only and shows a failing named check as neutral. `advisory` never fails and shows a failing named check as neutral. |
| `max-queue` | poll-timeout − 3600 | Max seconds the job may wait in the server queue. Sent as `max_queue`. |
| `upload-report` | `true` | Upload the full report and raw result as a workflow artifact. |
| `previous-comments` | `keep` | `minimize` hides this job's earlier compliance comments as outdated. |

`poll-timeout` is now also sent as `client_timeout`. Its default stays `10800`. It drops to `5400` in a later release, once the server's run budget is live.

## New outputs

`outcome`, `verdict`, `assessment`, `job-id`, `report-artifact`. The README lists every `outcome` value. The names are shared with the server's `error_code` and `blocked_reason`.

## Behaviour changes

1. Give-ups post a comment. Under `hard` and `verdict-only` the job still fails, as in v1.6. Under `advisory` it passes with a warning.
2. Under `hard`, a run the server marks `partial` or `not_assessed` fails even when the verdict alone would pass. Servers that do not send `assessment` are unaffected.
3. Secret-bearing files are never in the source archive. Large lockfiles now are.
4. Three new steps show in the log: "Check the API key", "Upload the full report" and "Record the outcome". A step that fails before the run has an outcome also posts an `action_error` comment.

## Server compatibility

v1.7 works with every server version. It reads these additive fields when they are present and ignores them when they are not: `state`, `phase`, `queued_seconds`, `running_seconds`, `heartbeat_age_seconds`, `error_code`, `assessment`, `blocked_reason`, `result_full`, and `frameworks_accepted` / `frameworks_dropped` on the submit response. With a server that sends only `{"status": "pending"}`, polling works exactly as in v1.6.

## Known limits

- Fork PRs get a read-only token, so the `not_run_fork` comment may not post. The action then writes it to the job summary.
- The diff is sent whole. A PR that changes a `.env` file sends that change in the diff, even though the file itself is left out of the archive.
- An action error (git or checkout failing) fails the job in every enforce mode.
