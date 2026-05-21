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
      - uses: HIPAACKR/pr-compliance-check@v1
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
| `poll-timeout` | No | `1500` | Max seconds to wait for result |
## Setup
1. Obtain your API key from the UbiComply compliance team.
2. Add it as a repository secret:
   - `COMPLIANCE_API_KEY`
3. Copy the workflow file above into your repo.
That's it — every PR will now be reviewed automatically.
## How It Works
1. Collects the PR diff and full commit messages (subject + body).
2. Submits them to the UbiComply compliance analysis API. If a `README.md` exists in the repo root, it is included as project context for the agent. If `frameworks` is provided, findings are mapped to the requested compliance controls.
3. Polls until the analysis is complete.
4. Posts the result as a comment on the PR.
