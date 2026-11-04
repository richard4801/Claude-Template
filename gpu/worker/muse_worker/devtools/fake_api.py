"""A small in-process fake of the MUSE API's worker endpoints plus a presigned-URL blob store.

Used by the tests and `muse-worker --self-test`. It follows plans/backend.md "Worker protocol":
  POST /worker/v1/claim | /heartbeat | /jobs/{id}/progress | /jobs/{id}/done | /jobs/{id}/failed
plus GET /blobs/{key} (stands in for a presigned R2 GET) and PUT /uploads/{key} (presigned PUT,
answers with ETag = md5 of the body, like S3/R2).

Fault knobs: `fail_next[path_prefix] = [503, ...]`, `corrupt_blobs`, `bad_etags`,
`upload_delay`, `cancelled` (progress answers 409), `require_token`.

Run standalone for poking at the worker:  python -m muse_worker.devtools.fake_api --port 8787
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import uuid
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable


def _num(v, lo=None, integer=False):
    ok = isinstance(v, (int, float)) and not isinstance(v, bool) and (not integer or float(v).is_integer())
    return ok and (lo is None or v >= lo)


def validate(kind: str, body: dict) -> str | None:
    """The same shape checks as server/api/src/routes/worker.ts (zod): optional fields may be absent, never null."""
    if not isinstance(body, dict):
        return "body must be an object"
    if kind == "progress":
        if not _num(body.get("step"), 0, True) or not _num(body.get("totalSteps"), 1, True):
            return "step >= 0 and totalSteps >= 1 must be integers"
        if "etaSeconds" in body and not _num(body["etaSeconds"], 0):
            return "etaSeconds must be a non-negative number when present"
        if "take" in body and not _num(body["take"], 1, True):
            return "take must be an integer >= 1 when present"
        if "phase" in body and not (isinstance(body["phase"], str) and len(body["phase"]) <= 100):
            return "phase must be a string <= 100 chars"
    elif kind == "done":
        for o in body.get("outputs", []):
            if not isinstance(o.get("name"), str):
                return "output name must be a string"
            for k in ("bytes", "width", "height", "fps", "durationSec"):
                if k in o and not _num(o[k]):
                    return f"output {k} must be a number when present"
        if "gpuSeconds" in body and not _num(body["gpuSeconds"], 0):
            return "gpuSeconds must be a non-negative number"
    elif kind == "failed":
        if not isinstance(body.get("error"), str) or not isinstance(body.get("retryable"), bool):
            return "error must be a string and retryable a boolean"
    elif kind in ("heartbeat", "claim"):
        if "busy" in body and not isinstance(body["busy"], bool):
            return "busy must be a boolean"
    return None


class FakeApi:
    def __init__(self, token: str = "test-token", host: str = "127.0.0.1", port: int = 0):
        self.token = token
        self.require_token = True
        self.lock = threading.RLock()
        self.queue: list[dict] = []
        self.blobs: dict[str, bytes] = {}
        self.uploads: dict[str, bytes] = {}
        self.claims: list[dict] = []
        self.heartbeats: list[tuple[float, dict]] = []
        self.progress: list[tuple[float, str, dict]] = []
        self.done: dict[str, dict] = {}
        self.failed: dict[str, dict] = {}
        self.auth_failures = 0
        self.fail_next: dict[str, list[int]] = defaultdict(list)
        self.corrupt_blobs: set[str] = set()
        self.bad_etags = 0
        self.upload_delay = 0.0
        self.cancelled: set[str] = set()
        self.seen_headers: list[dict] = []
        self.validation_errors: list[tuple[str, str, dict]] = []
        api = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):  # quiet
                pass

            def _send(self, status: int, body: Any = None, headers: dict | None = None):
                data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
                self.send_response(status)
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                if body is not None and not isinstance(body, bytes):
                    self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if data:
                    self.wfile.write(data)

            def _body(self) -> bytes:
                n = int(self.headers.get("Content-Length") or 0)
                return self.rfile.read(n) if n else b""

            def _injected(self) -> int | None:
                with api.lock:
                    for prefix, statuses in api.fail_next.items():
                        if self.path.startswith(prefix) and statuses:
                            return statuses.pop(0)
                return None

            def do_POST(self):
                raw = self._body()
                with api.lock:
                    api.seen_headers.append(dict(self.headers))
                if api.require_token and self.headers.get("Authorization") != f"Bearer {api.token}":
                    with api.lock:
                        api.auth_failures += 1
                    return self._send(401, {"error": "unauthorized"})
                if (status := self._injected()) is not None:
                    return self._send(status, {"error": "injected"})
                try:
                    body = json.loads(raw or b"{}")
                except ValueError:
                    return self._send(400, {"error": "bad json"})
                now = time.monotonic()
                parts = self.path.strip("/").split("/")
                kind = parts[-1] if parts[:2] == ["worker", "v1"] else ""
                if (problem := validate(kind, body)) is not None:
                    with api.lock:
                        api.validation_errors.append((self.path, problem, body))
                    return self._send(400, {"error": problem})
                with api.lock:
                    if self.path == "/worker/v1/claim":
                        api.claims.append(body)
                        if not api.queue:
                            return self._send(204)
                        return self._send(200, {"job": api.queue.pop(0)})
                    if self.path == "/worker/v1/heartbeat":
                        api.heartbeats.append((now, body))
                        return self._send(200, {"ok": True})
                    if len(parts) == 5 and parts[:3] == ["worker", "v1", "jobs"]:
                        job_id, what = parts[3], parts[4]
                        if what == "progress":
                            if job_id in api.cancelled:
                                return self._send(409, {"error": "job cancelled"})
                            api.progress.append((now, job_id, body))
                            return self._send(200, {"ok": True})
                        if what == "done":
                            api.done[job_id] = body
                            return self._send(200, {"ok": True})
                        if what == "failed":
                            api.failed[job_id] = body
                            return self._send(200, {"ok": True})
                return self._send(404, {"error": "not found"})

            def do_GET(self):
                if (status := self._injected()) is not None:
                    return self._send(status, b"")
                key = self.path.split("?")[0].removeprefix("/blobs/")
                with api.lock:
                    data = api.blobs.get(key)
                    corrupt = key in api.corrupt_blobs
                if data is None:
                    return self._send(404, b"")
                if corrupt:
                    data = bytes([data[0] ^ 0xFF]) + data[1:]
                return self._send(200, data, {"Content-Type": "application/octet-stream"})

            def do_PUT(self):
                data = self._body()
                if api.upload_delay:
                    time.sleep(api.upload_delay)
                if (status := self._injected()) is not None:
                    return self._send(status, b"")
                key = self.path.split("?")[0].removeprefix("/uploads/")
                etag = hashlib.md5(data).hexdigest()
                with api.lock:
                    if api.bad_etags > 0:
                        api.bad_etags -= 1
                        etag = "0" * 32
                    api.uploads[key] = data
                return self._send(200, b"", {"ETag": f'"{etag}"'})

        self.server = ThreadingHTTPServer((host, port), Handler)
        self.server.daemon_threads = True
        self._thread = threading.Thread(target=self.server.serve_forever, name="fake-api", daemon=True)

    # -- lifecycle ------------------------------------------------------------------
    @property
    def url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    def start(self) -> "FakeApi":
        self._thread.start()
        return self

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()

    # -- helpers ----------------------------------------------------------------------
    def add_job(self, kind: str = "h3", params: dict | None = None, inputs: dict[str, bytes] | None = None,
                outputs: list[str] | None = None, prompt: str | None = "subject_definitions:\n<Subject 1> test",
                seed: int | None = 42, steps: int | None = 10, job_id: str | None = None,
                send_checksums: bool = True, wrong_sha: set[str] | None = None, **extra) -> dict:
        job_id = job_id or f"job_{uuid.uuid4().hex[:8]}"
        inputs = {"source.mp4": b"\x00FAKE-SOURCE" * 100, "face_front.jpg": b"\xff\xd8face" * 50,
                  "body_front.jpg": b"\xff\xd8body" * 50} if inputs is None else inputs
        outputs = ["take1.mp4"] if outputs is None else outputs
        job_inputs = []
        with self.lock:
            for name, data in inputs.items():
                key = f"{job_id}/in/{name}"
                self.blobs[key] = data
                spec = {"name": name, "url": f"{self.url}/blobs/{key}?X-Amz-Signature=secret"}
                if send_checksums:
                    sha = hashlib.sha256(data).hexdigest()
                    spec.update(bytes=len(data), sha256=("0" * 64 if name in (wrong_sha or set()) else sha))
                job_inputs.append(spec)
            job = {"id": job_id, "kind": kind, "params": params if params is not None else {"steps": steps or 10},
                   "inputs": job_inputs,
                   "outputs": [{"name": n, "uploadUrl": f"{self.url}/uploads/{job_id}/{n}?X-Amz-Signature=secret"}
                               for n in outputs],
                   "prompt": prompt, "seed": seed, "steps": steps, **extra}
            self.queue.append(job)
        return job

    def wait_for(self, pred: Callable[[], Any], timeout: float = 10.0, interval: float = 0.02) -> Any:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            with self.lock:
                v = pred()
            if v:
                return v
            time.sleep(interval)
        raise TimeoutError("condition not met in time")

    def progress_for(self, job_id: str) -> list[tuple[float, dict]]:
        with self.lock:
            return [(t, b) for t, j, b in self.progress if j == job_id]


def _main() -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Fake MUSE worker API")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--token", default="dry-run-token")
    ap.add_argument("--jobs", type=int, default=1, help="h3 jobs to enqueue")
    a = ap.parse_args()
    api = FakeApi(token=a.token, port=a.port).start()
    for _ in range(a.jobs):
        api.add_job(outputs=["take1.mp4", "take1.jpg"])
    print(f"fake API on {api.url} (token {a.token!r}), {a.jobs} job(s) queued. Ctrl-C to stop.", flush=True)
    try:
        while True:
            time.sleep(1)
            with api.lock:
                for jid, d in list(api.done.items()):
                    print("DONE", jid, json.dumps(d)[:300], flush=True)
                    api.done.pop(jid)
                for jid, d in list(api.failed.items()):
                    print("FAILED", jid, d, flush=True)
                    api.failed.pop(jid)
    except KeyboardInterrupt:
        api.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
