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
      - uses: HIPAACKR/pr-compliance-check@v1.1
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
| `poll-timeout` | No | `2700` | Max seconds to wait for result. Large or security-sensitive PRs run a deeper agentic mini-scan (up to ~35 min). |
## Setup
1. Obtain your API key from the UbiComply compliance team.
2. Add it as a repository secret:
   - `COMPLIANCE_API_KEY`
3. Copy the workflow file above into your repo.
4. **Codebase-reuse / THOROUGH mode** requires a per-tenant PAT as `COMPLIANCE_API_KEY`. The shared global key resolves to a shared identity that the server refuses for codebase reuse. Use the per-tenant key minted at auth.ubicomply.ai, or a per-tenant key from the compliance team.
That's it — every PR will now be reviewed automatically.
## How It Works
1. Collects the PR diff and full commit messages (subject + body).
2. Submits them to the UbiComply compliance analysis API. If a `README.md` exists in the repo root, it is included as project context for the agent. If `frameworks` is provided, findings are mapped to the requested compliance controls.
3. Polls until the analysis is complete.
4. Posts the result as a comment on the PR.
