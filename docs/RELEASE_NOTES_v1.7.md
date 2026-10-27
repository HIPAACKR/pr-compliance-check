# Compliance Check Action v1.7

v1.7 makes the action survive a busy or restarting server, and makes every run end with an answer on the PR. A run that cannot get a verdict now says why in a comment instead of ending on a bare error. It never passes silently.

## Upgrade

Change `@v1.6` to `@v1.7`. No input changes are needed. With the default settings, v1.7 fails the job in every case where v1.6 did.

```yaml
permissions:
  pull-requests: write
  contents: read
  checks: write   # for the named "Compliance Check" check run and inline annotations
steps:
  - uses: HIPAACKR/pr-compliance-check@v1.7
    with:
      api-key: ${{ secrets.COMPLIANCE_API_KEY }}
      frameworks: '["hipaa"]'
```

If you added `.env` or key files to `source-excludes`, you can keep them, but you no longer need to. v1.7 always leaves them out. Coming from v1.2 to v1.5: v1.6 already failed closed on a missing or unknown verdict, and v1.7 keeps that.

## Highlights

- **Retries.** Submit and poll retry connection errors, 5xx responses and a 404 right after submit, with back-off. A 429 or 503 waits for `Retry-After`. Every response's HTTP status is checked.
- **Every give-up comments.** Timeouts, an unreachable API, a lost job, an oversized diff or archive, a rejected key and a missing key each post a PR comment, set a `blocked` verdict and set the new `outcome` output.
- **Fork PRs.** A fork PR has no access to the API key. It now gets outcome `not_run_fork`, a comment and a `blocked` verdict instead of a bare error.
- **Fail fast.** When the server reports job state, the action stops when a job waits in the queue past its limit, or when its worker stops sending heartbeats, and asks the server to cancel the job. The queue limit is the server's own `max_queue` when the status carries it, otherwise the `max-queue` input. This saves runner minutes on a stuck job.
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
| `max-queue` | poll-timeout − 3600 | Max seconds the job may wait in the server queue. Sent as `max_queue`; the server clamps it. |
| `upload-report` | `true` | Upload the full report and raw result as a workflow artifact. |
| `previous-comments` | `keep` | `minimize` hides this job's earlier compliance comments as outdated. |

`poll-timeout` is now also sent as `client_timeout`, so the server can drop a job nobody will read. Its default stays `10800`. The hosted service now ends every run inside a fixed run budget, so `poll-timeout: 5400` is safe if you want shorter jobs. A later release will make 5400 the default.

Note on `verdict-only` and `advisory`: a neutral check satisfies a required status check. Use them only on repositories where "Compliance Check" is not a required check, or where you accept merges on a failing verdict.

## New outputs

`outcome`, `verdict`, `assessment`, `job-id`, `report-artifact`. The README lists every `outcome` value. The names are shared with the server's `error_code` and `blocked_reason`.

## Behaviour changes

1. Give-ups post a comment. Under `hard` and `verdict-only` the job still fails, as in v1.6. Under `advisory` it passes with a warning.
2. Under `hard`, a run the server marks `partial` or `not_assessed` fails even when the verdict alone would pass. Servers that do not send `assessment` are unaffected.
3. Secret-bearing files are never in the source archive. Large lockfiles now are.
4. Three new steps show in the log: "Check the API key", "Upload the full report" and "Record the outcome". A step that fails before the run has an outcome also posts an `action_error` comment.

## Server compatibility

v1.7 works with every server version. It reads these additive fields when they are present and ignores them when they are not: `state`, `phase`, `queued_seconds`, `running_seconds`, `heartbeat_age_seconds`, `client_timeout`, `max_queue`, `error_code`, `assessment`, `blocked_reason`, `result_full`, and `frameworks_accepted` / `frameworks_dropped` on the submit response. The hosted API sends them. With a server that sends only `{"status": "pending"}`, polling works exactly as in v1.6.

## Known limits

- Fork PRs get a read-only token, so the `not_run_fork` comment may not post. The action then writes it to the job summary.
- The diff is sent whole. A PR that changes a `.env` file sends that change in the diff, even though the file itself is left out of the archive.
- An action error (git or checkout failing) fails the job in every enforce mode.
