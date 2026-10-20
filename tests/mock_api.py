#!/usr/bin/env python3
"""Offline mock of the compliance PR-check API and the GitHub REST API, for
the v1.7 test harness (tests/harness.test.sh). Not shipped with the action.

Usage: python3 mock_api.py <port_file> <log_dir>

Binds 127.0.0.1 on a free port and writes the port to <port_file>.

Compliance API routes (the scenario picks the behaviour; <run> keeps each
test's counters separate):
  POST /s/<scenario>/<run>/                      submit
  GET  /s/<scenario>/<run>/jobs/<job_id>         status
  POST /s/<scenario>/<run>/jobs/<job_id>/cancel  cancel

GitHub API routes (GITHUB_API_URL=http://127.0.0.1:<port>/gh):
  POST /gh/repos/<o>/<r>/issues/<n>/comments   create (repo "acme/readonly" is 403)
  GET  /gh/repos/<o>/<r>/issues/<n>/comments   list (per_page, page)
  POST /gh/graphql                              minimizeComment
  POST /gh/repos/<o>/<r>/check-runs             create

Every request is appended as one JSON line to <log_dir>/requests.jsonl.
"""

from __future__ import annotations

import json
import sys
import threading
from email.parser import BytesParser
from email.policy import HTTP
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

LOCK = threading.Lock()
COUNTS: dict[str, int] = {}
COMMENTS: dict[str, list[dict]] = {}
MINIMIZED: set[str] = set()
NEXT_ID = [100]
LOG_DIR = Path(".")

DROP = object()  # close the connection without a response

PENDING_QUEUED = {"status": "pending", "state": "queued", "queued_seconds": 3, "attempt": 0}
PENDING_RUNNING = {
    "status": "pending",
    "state": "running",
    "phase": "sweep",
    "queued_seconds": 4,
    "running_seconds": 20,
    "heartbeat_age_seconds": 4.7,
    "attempt": 1,
}
CHECK_RUN = {
    "name": "Compliance Check",
    "head_sha": "",
    "status": "completed",
    "conclusion": "failure",
    "output": {"title": "1 finding", "summary": "s", "text": "t"},
}


def success(verdict: str | None = "clean", **extra) -> dict:
    body: dict = {"status": "success", "result": f"## 🔒 Compliance Review\n\nverdict {verdict}\n"}
    if verdict is not None:
        body["overall_status"] = verdict
    body.update(extra)
    return body


def big_report(chars: int) -> str:
    lines = ["## 🔒 Compliance Review", "", "<details>", "<summary>Findings</summary>", "", "```python"]
    i = 0
    while sum(len(x) + 1 for x in lines) < chars:
        lines.append(f"finding line {i:06d} " + "x" * 80)
        i += 1
    lines += ["```", "</details>", "", "END OF REPORT"]
    return "\n".join(lines) + "\n"


def submit_scenario(scn: str, n: int, form: dict) -> tuple[int, dict, object]:
    job = {"job_id": f"job-{scn}-0001"}
    if scn == "submit_transient":
        if n == 1:
            return 0, {}, DROP
        if n == 2:
            return 502, {"Content-Type": "text/html"}, "<html>502 Bad Gateway</html>"
        if n == 3:
            return 503, {"Retry-After": "1"}, {"error": "compliance_api_disabled"}
        return 202, {}, job
    if scn == "submit_429":
        if n <= 2:
            return 429, {"Retry-After": "1"}, {"error": "rate_limited", "retry_after_seconds": 1}
        return 202, {}, job
    if scn == "submit_429_body_only":
        if n == 1:
            return 429, {}, {"error": "rate_limited", "retry_after_seconds": 2}
        return 202, {}, job
    if scn == "submit_429_forever":
        return 429, {"Retry-After": "1"}, {"error": "rate_limited", "retry_after_seconds": 1}
    if scn == "submit_down":
        return 503, {"Content-Type": "text/html"}, "<html>503</html>"
    if scn == "submit_413_source":
        return 413, {}, {"error": "source_too_large", "max_bytes": 104857600, "size_bytes": 2}
    if scn == "submit_413_diff":
        return 413, {}, {"error": "diff_too_large", "max_bytes": 5242880}
    if scn == "submit_413_nginx":
        return 413, {"Content-Type": "text/html"}, "<html>413 Request Entity Too Large</html>"
    if scn == "submit_401":
        return 401, {}, {"error": "unauthorized"}
    if scn == "submit_400":
        return 400, {}, {"error": "malformed_multipart", "detail": "the multipart body could not be parsed"}
    if scn == "submit_no_jobid":
        return 202, {}, {}
    if scn == "submit_bad_jobid":
        return 202, {}, {"job_id": "../../etc/passwd"}
    if scn == "frameworks_dropped":
        return 202, {}, {**job, "frameworks_accepted": ["hipaa"], "frameworks_dropped": ["hipaaa"]}
    if scn == "frameworks_none":
        return 202, {}, {**job, "frameworks_accepted": [], "frameworks_dropped": ["nope", {"requested": "x"}]}
    return 202, {}, job


def status_scenario(scn: str, n: int) -> tuple[int, dict, object]:
    if scn == "clean":
        if n == 1:
            return 200, {}, PENDING_QUEUED
        if n == 2:
            return 200, {}, PENDING_RUNNING
        return 200, {}, success("clean", assessment="complete")
    if scn == "fail":
        return 200, {}, success(
            "fail",
            assessment="complete",
            check_run=CHECK_RUN,
            annotations=["::error file=a.py,line=1::bad", "::add-mask::nope"],
        )
    if scn == "blocked_budget":
        return 200, {}, success("blocked", assessment="partial", blocked_reason="budget_exceeded")
    if scn == "blocked_newreason":
        return 200, {}, success("blocked", blocked_reason="gremlins")
    if scn == "partial_warn":
        return 200, {}, success("warn", assessment="partial")
    if scn == "nothing":
        return 200, {}, success("clean", assessment="nothing_to_assess")
    if scn == "weird_assessment":
        return 200, {}, success("clean", assessment="mostly")
    if scn == "transient_poll":
        if n == 1:
            return 0, {}, DROP
        if n == 2:
            return 502, {"Content-Type": "text/html"}, "<html>502 Bad Gateway</html>"
        if n == 3:
            return 503, {"Retry-After": "1"}, {"error": "job_store_unavailable", "error_code": "job_store_unavailable"}
        if n == 4:
            return 200, {"Content-Type": "text/html"}, "<html>maintenance</html>"
        if n == 5:
            return 200, {}, {"foo": 1}
        if n == 6:
            return 504, {}, ""
        return 200, {}, success("clean", assessment="complete")
    if scn == "poll_429":
        if n == 1:
            return 429, {"Retry-After": "1"}, {"error": "rate_limited", "retry_after_seconds": 1}
        return 200, {}, success("warn", assessment="complete")
    if scn == "notfound_early":
        if n <= 2:
            return 404, {}, {"error": "job_not_found"}
        if n == 3:
            return 200, {}, PENDING_QUEUED
        return 200, {}, success("clean", assessment="complete")
    if scn == "notfound_lost":
        if n == 1:
            return 200, {}, PENDING_RUNNING
        return 404, {}, {"error": "job_not_found"}
    if scn == "queued_forever":
        return 200, {}, {**PENDING_QUEUED, "queued_seconds": 100 * n + 0.9}
    if scn == "queued_server_limit":
        # The server echoes its clamped max_queue (100 s): give up past 400 s.
        return 200, {}, {**PENDING_QUEUED, "queued_seconds": 100 * n + 0.9, "max_queue": 100}
    if scn == "stale_heartbeat":
        return 200, {}, {**PENDING_RUNNING, "heartbeat_age_seconds": 1300.9}
    if scn == "heartbeat_edge":
        if n == 1:
            return 200, {}, {**PENDING_RUNNING, "heartbeat_age_seconds": 1199.99}
        return 200, {}, success("clean", assessment="complete")
    if scn == "legacy_pending":
        return 200, {}, {"status": "pending"}
    if scn == "legacy_then_success":
        if n <= 2:
            return 200, {}, {"status": "pending"}
        return 200, {}, {"status": "success", "result": "## 🔒 Compliance Review\n\nold server\n", "overall_status": "clean"}
    if scn == "failed_superseded":
        return 200, {}, {"status": "failed", "error": "superseded by job job-x", "error_code": "superseded"}
    if scn == "failed_time_limit":
        return 200, {}, {
            "status": "failed",
            "error": "soft time limit reached",
            "error_code": "time_limit",
            "overall_status": "blocked",
            "blocked_reason": "time_limit",
        }
    if scn == "failed_legacy":
        return 200, {}, {"status": "failed", "error": "boom"}
    if scn == "failed_newcode":
        return 200, {}, {"status": "failed", "error": "boom", "error_code": "gpu_on_fire"}
    if scn == "failed_injection":
        return 200, {}, {
            "status": "failed",
            "error": "boom\n::add-mask::leak\n::error::pwned\n```\nfence",
            "error_code": "pipeline_error",
        }
    if scn == "pending_error_code":
        return 200, {}, {**PENDING_RUNNING, "error_code": "worker_lost"}
    if scn == "unknown_verdict":
        return 200, {}, success("pass", assessment="complete")
    if scn == "no_verdict":
        return 200, {}, success(None)
    if scn == "oversized":
        return 200, {}, success(
            "fail", assessment="complete", result=big_report(150_000), result_full=big_report(300_000)
        )
    if scn == "bad_status":
        return 200, {}, {"status": "exploded"}
    if scn == "poll_401":
        return 401, {}, {"error": "unauthorized"}
    if scn == "down":
        return 503, {"Content-Type": "text/html"}, "<html>503</html>"
    return 200, {}, success("clean", assessment="complete")


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-compliance/1.0"

    def log_message(self, *args) -> None:  # keep the harness output clean
        pass

    def _body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _record(self, body: bytes, form: dict | None) -> None:
        entry: dict = {
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
        }
        if form is not None:
            entry["form"] = form
        elif body:
            try:
                entry["json"] = json.loads(body)
            except ValueError:
                entry["raw"] = body[:200].decode("utf-8", "replace")
        with LOCK, open(LOG_DIR / "requests.jsonl", "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")

    def _send(self, code: int, headers: dict, body: object) -> None:
        if body is DROP:
            self.close_connection = True
            return
        data = body if isinstance(body, (bytes, str)) else json.dumps(body)
        if isinstance(data, str):
            data = data.encode("utf-8")
        self.send_response(code)
        if "Content-Type" not in headers:
            self.send_header("Content-Type", "application/json")
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    @staticmethod
    def _count(key: str) -> int:
        with LOCK:
            COUNTS[key] = COUNTS.get(key, 0) + 1
            return COUNTS[key]

    def _parse_form(self, body: bytes) -> dict | None:
        ctype = self.headers.get("Content-Type", "")
        if not ctype.startswith("multipart/form-data"):
            return None
        msg = BytesParser(policy=HTTP).parsebytes(b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + body)
        out: dict = {}
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            payload = part.get_payload(decode=True) or b""
            if part.get_filename():
                out[name] = {"filename": part.get_filename(), "size": len(payload), "type": part.get_content_type()}
            else:
                out[name] = payload.decode("utf-8", "replace")
        return out

    def do_GET(self) -> None:  # noqa: N802
        self._record(b"", None)
        parts = urlparse(self.path).path.strip("/").split("/")
        if parts[0] == "s" and len(parts) == 5 and parts[3] == "jobs":
            scn, run = parts[1], parts[2]
            n = self._count(f"status:{scn}:{run}")
            self._send(*status_scenario(scn, n))
            return
        if parts[0] == "gh" and parts[-1] == "comments":
            key = "/".join(parts[1:-1])
            qs = parse_qs(urlparse(self.path).query)
            per_page = int(qs.get("per_page", ["30"])[0])
            page = int(qs.get("page", ["1"])[0])
            with LOCK:
                items = list(COMMENTS.get(key, []))
            self._send(200, {}, items[(page - 1) * per_page : page * per_page])
            return
        self._send(404, {}, {"error": "no_route"})

    def do_POST(self) -> None:  # noqa: N802
        body = self._body()
        form = self._parse_form(body)
        self._record(body, form)
        parts = urlparse(self.path).path.strip("/").split("/")
        if parts[0] == "s" and len(parts) == 3:
            scn, run = parts[1], parts[2]
            n = self._count(f"submit:{scn}:{run}")
            self._send(*submit_scenario(scn, n, form or {}))
            return
        if parts[0] == "s" and len(parts) == 6 and parts[5] == "cancel":
            self._send(200, {}, {"job_id": parts[4], "cancelled": True, "status": "failed", "error_code": "cancelled"})
            return
        if parts[0] == "gh" and parts[-1] == "comments":
            key = "/".join(parts[1:-1])
            if key.startswith("repos/acme/readonly/"):
                self._send(403, {}, {"message": "Resource not accessible by integration"})
                return
            payload = json.loads(body or b"{}")
            with LOCK:
                NEXT_ID[0] += 1
                cid = NEXT_ID[0]
                item = {
                    "id": cid,
                    "node_id": f"IC_{cid}",
                    "user": {"login": payload.pop("_as", "github-actions[bot]")},
                    "body": payload.get("body", ""),
                }
                COMMENTS.setdefault(key, []).append(item)
            self._send(201, {}, item)
            return
        if parts[0] == "gh" and parts[-1] == "graphql":
            req = json.loads(body or b"{}")
            variables = req.get("variables") or {}
            if "minimizeComment" in req.get("query", ""):
                with LOCK:
                    MINIMIZED.add(variables.get("id"))
                self._send(200, {}, {"data": {"minimizeComment": {"minimizedComment": {"isMinimized": True}}}})
                return
            key = f"repos/{variables.get('owner')}/{variables.get('name')}/issues/{variables.get('number')}"
            with LOCK:
                nodes = [
                    {
                        "id": c["node_id"],
                        "databaseId": c["id"],
                        "isMinimized": c["node_id"] in MINIMIZED,
                        "viewerDidAuthor": c["user"]["login"] == "github-actions[bot]",
                        "body": c["body"],
                    }
                    for c in COMMENTS.get(key, [])
                ]
            self._send(200, {}, {"data": {"repository": {"pullRequest": {"comments": {"nodes": nodes}}}}})
            return
        if parts[0] == "gh" and parts[-1] == "check-runs":
            self._send(201, {}, {"html_url": "https://github.example/check/1"})
            return
        self._send(404, {}, {"error": "no_route"})


def main() -> None:
    global LOG_DIR
    port_file, log_dir = sys.argv[1], sys.argv[2]
    LOG_DIR = Path(log_dir)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    Path(port_file).write_text(str(server.server_address[1]), encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
