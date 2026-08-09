# 🔒 Compliance Check Action
Automatically analyzes pull request diffs for compliance and posts the results as a PR comment.
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
jobs:
  compliance-check:
    runs-on: ubuntu-latest
    steps:
      - uses: HIPAACKR/pr-compliance-check@v1.5
        with:
          api-key: ${{ secrets.COMPLIANCE_API_KEY }}
          frameworks: '["hipaa","cmmc"]'
```
## Inputs
| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | ✅ | — | Compliance API key |
| `github-token` | No | `${{ github.token }}` | Token for posting PR comments |
| `frameworks` | No | — | JSON array of compliance frameworks to map findings against, e.g. `["hipaa","cmmc"]`. Omit for CWE-only output. |
| `poll-interval` | No | `5` | Seconds between status polls |
| `source-excludes` | No | — | Extra tar exclude globs for the uploaded source archive, comma- or newline-separated (e.g. `public/images/*,docs/*`). Use when a repo trips the 100 MB cap on assets the scanner doesn't need. Excluding paths hides them from your own compliance scan — exclude assets, not code. |
| `max-file-bytes` | No | `2097152` | Any single tracked file larger than this is left out of the source archive. Oversized files aren't analyzable source; the usual culprit is a Figma-exported `.svg` carrying a base64 raster. Raise it if your repo has legitimately large source files. |
| `poll-timeout` | No | `10800` | Max seconds to wait for result (3h). Large or security-sensitive PRs run a deeper agentic sweep that can run well over an hour under shared-GPU contention. The server job TTL (`COMPLIANCE_PR_JOB_TTL_SECONDS`, default 2h) must be ≥ this value. |
## Setup
1. Obtain your API key from the UbiComply compliance team.
2. Add it as a repository secret:
   - `COMPLIANCE_API_KEY`
3. Copy the workflow file above into your repo.
4. **Codebase-reuse / THOROUGH mode** requires a per-tenant PAT as `COMPLIANCE_API_KEY`. The shared global key resolves to a shared identity that the server refuses for codebase reuse. Use the per-tenant key minted at auth.ubicomply.ai, or a per-tenant key from the compliance team.
That's it — every PR will now be reviewed automatically.
## How It Works
0. Skips the analysis entirely — leaving the check green — when the PR changes no substantive content. Whitespace-only, blank-line-only, metadata-only (pure rename or mode change), and net-empty PRs all qualify; binary changes never do. Nothing is submitted and no comment is posted.
1. Collects the PR diff and full commit messages (subject + body).
2. Packages the source for the agentic sweep. Only **git-tracked** files are uploaded, so build output and anything gitignored can never inflate the archive. Files a source scanner can't read are left out and listed in the log: compiled or packaged binaries by extension (`.jar`, `.zip`, `.so`, images, fonts, media…) and any single file over `max-file-bytes`. Source is never dropped by type — `.svg` in particular stays in scope unless it's oversized, since an SVG can carry `<script>`.
3. Submits them to the UbiComply compliance analysis API. If a `README.md` exists in the repo root, it is included as project context for the agent. If `frameworks` is provided, findings are mapped to the requested compliance controls.
4. Polls until the analysis is complete.
5. Posts the result as a comment on the PR.
