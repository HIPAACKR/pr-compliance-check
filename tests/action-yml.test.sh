#!/usr/bin/env bash
# Static checks on action.yml: every v1.6 input keeps its default, the new
# inputs default to v1.6 behaviour, step references and scripts resolve, and
# the API key only ever reaches a step through env.
# Needs python3 with PyYAML; skips (exit 0) without it.
# Run: bash tests/action-yml.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "skip  action.yml checks (PyYAML not installed)"
  exit 0
fi

python3 - "$ROOT" <<'PY'
import os
import re
import subprocess
import sys

import yaml

root = sys.argv[1]
with open(os.path.join(root, "action.yml"), encoding="utf-8") as fh:
    text = fh.read()
action = yaml.safe_load(text)
passed = failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"ok    {name}")
    else:
        failed += 1
        print(f"FAIL  {name} {detail}")


inputs = action["inputs"]
v16 = {
    "api-key": None,
    "github-token": "${{ github.token }}",
    "frameworks": "",
    "poll-interval": "5",
    "source-excludes": "",
    "max-file-bytes": "2097152",
    "publish-check-run": "true",
    "poll-timeout": "10800",
}
for name, default in v16.items():
    check(f"v1.6 input kept: {name}", name in inputs)
    if name in inputs:
        check(f"v1.6 default kept: {name}", inputs[name].get("default") == default, repr(inputs[name].get("default")))
check("api-key still required", inputs["api-key"].get("required") is True)
new = {"enforce": "hard", "max-queue": "", "upload-report": "true", "previous-comments": "keep"}
for name, default in new.items():
    check(f"new input {name} defaults to {default!r}", inputs.get(name, {}).get("default") == default)

steps = action["runs"]["steps"]
ids = {s.get("id") for s in steps if s.get("id")}
refs = set(re.findall(r"steps\.([A-Za-z0-9_-]+)\.outputs", text))
check("every steps.<id> reference resolves", refs <= ids, str(refs - ids))

for s in steps:
    if "run" in s:
        check(f"step '{s['name']}' sets shell: bash", s.get("shell") == "bash")
        for script in re.findall(r"scripts/([A-Za-z0-9_.-]+\.sh)", s["run"]):
            check(f"script exists: {script}", os.path.isfile(os.path.join(root, "scripts", script)))
        check(f"step '{s['name']}' never puts the api-key in run", "inputs.api-key" not in s["run"])
        body = s["run"].replace("${{ github.action_path }}", root)
        body = re.sub(r"\$\{\{[^}]*\}\}", "x", body)
        syntax = subprocess.run(["bash", "-n"], input=body, text=True, capture_output=True)
        check(f"step '{s['name']}' run block parses (bash -n)", syntax.returncode == 0, syntax.stderr.strip())
key_envs = [k for s in steps for k, v in (s.get("env") or {}).items() if "inputs.api-key" in str(v)]
check("api-key only reaches steps as COMPLIANCE_API_KEY", key_envs and set(key_envs) == {"COMPLIANCE_API_KEY"}, str(key_envs))

api_steps = [s for s in steps if "COMPLIANCE_API_KEY" in (s.get("env") or {}) and "run" in s and ("submit.sh" in s["run"] or "poll-job.sh" in s["run"])]
check("submit and poll steps pin COMPLIANCE_API_URL", len(api_steps) == 2 and all((s.get("env") or {}).get("COMPLIANCE_API_URL", "").startswith("https://llm.ubicomply.ai/") for s in api_steps))

names = [s["name"] for s in steps]
check("enforce is the last step", names[-1] == "Enforce compliance verdict")
order = ["Check the API key", "Package source for the agentic sweep", "Submit diff to compliance API", "Poll for result", "Post comment on PR"]
check("give-up capable steps run in order", [n for n in names if n in order] == order)

outputs = action.get("outputs", {})
for name in ("outcome", "verdict", "assessment", "job-id", "report-artifact"):
    check(f"output {name} declared", name in outputs)

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
