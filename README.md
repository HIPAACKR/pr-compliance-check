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
          api-url: ${{ secrets.COMPLIANCE_API_URL }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-url` | ✅ | — | Compliance API submission URL |
| `api-key` | ✅ | — | Compliance API key |
| `github-token` | No | `${{ github.token }}` | Token for posting PR comments |
| `status-url` | No | `<api-url>/status` | Compliance API polling URL |
| `poll-interval` | No | `5` | Seconds between status polls |
| `poll-timeout` | No | `1500` | Max seconds to wait for result |

## Setup

1. Obtain your API key and URLs from the compliance team.
2. Add them as repository secrets:
   - `COMPLIANCE_API_KEY`
   - `COMPLIANCE_API_URL`
   - `COMPLIANCE_STATUS_URL`
3. Copy the workflow file above into your repo.

That's it — every PR will now be reviewed automatically.

## How It Works

1. Collects the PR diff and commit messages.
2. Submits them to the compliance analysis API along with the project README for context.
3. Polls until the analysis is complete.
4. Posts the result as a comment on the PR.
