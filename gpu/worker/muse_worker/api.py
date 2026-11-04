"""HTTP client for the worker protocol (plans/backend.md, "Worker protocol").

Standard library only, so the loop and tests run without any GPU packages.
"""

from __future__ import annotations

import http.client
import json
import logging
import random
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from . import __version__
from .config import Config

log = logging.getLogger("muse.api")


class ApiError(Exception):
    def __init__(self, message: str, status: int | None = None, retryable: bool = True):
        super().__init__(message)
        self.status = status
        self.retryable = retryable


class AuthError(ApiError):
    """401/403: the token is wrong or revoked. Retrying won't help."""


class JobGone(ApiError):
    """404/409/410 on a job endpoint: the API cancelled or no longer knows the job."""


class ApiClient:
    def __init__(self, cfg: Config):
        self.base = cfg.api_url.rstrip("/")
        self.pod_id = cfg.pod_id
        self.timeout = cfg.http_timeout
        self._auth = "Bearer " + cfg.token

    # -- transport ---------------------------------------------------------
    def _request(self, path: str, payload: dict) -> tuple[int, Any]:
        req = urllib.request.Request(
            self.base + path,
            data=json.dumps(payload).encode(),
            method="POST",
            headers={
                "Authorization": self._auth,
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": f"muse-worker/{__version__}",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                status, body = resp.status, resp.read()
        except urllib.error.HTTPError as e:
            status = e.code
            try:
                body = e.read()
            except OSError:
                body = b""
        except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
            reason = getattr(e, "reason", e)
            raise ApiError(f"POST {path}: {reason}", retryable=True) from None
        parsed: Any = None
        if body and body.strip():
            try:
                parsed = json.loads(body)
            except ValueError:
                parsed = {"raw": body[:200].decode("utf-8", "replace")}
        return status, parsed

    def _call(self, path: str, payload: dict, *, job: bool = False) -> tuple[int, Any]:
        status, body = self._request(path, payload)
        if 200 <= status < 300:
            return status, body
        detail = ""
        if isinstance(body, dict):
            detail = str(body.get("error") or body.get("message") or body.get("raw") or "")[:200]
        msg = f"POST {path} -> HTTP {status}" + (f": {detail}" if detail else "")
        if status in (401, 403):
            raise AuthError(msg, status, retryable=False)
        if job and status in (404, 409, 410):
            raise JobGone(msg, status, retryable=False)
        raise ApiError(msg, status, retryable=status >= 500 or status in (408, 429))

    def _call_retrying(self, path: str, payload: dict, deadline_s: float, *, job: bool = False):
        delay, end = 1.0, time.monotonic() + deadline_s
        while True:
            try:
                return self._call(path, payload, job=job)
            except ApiError as e:
                if not e.retryable or time.monotonic() + delay > end:
                    raise
                log.warning("%s; retrying in %.0fs", e, delay)
                time.sleep(delay * (0.8 + 0.4 * random.random()))
                delay = min(delay * 2, 30.0)

    @staticmethod
    def _job_path(job_id: str, what: str) -> str:
        return f"/worker/v1/jobs/{urllib.parse.quote(str(job_id), safe='')}/{what}"

    # -- protocol ----------------------------------------------------------
    def claim(self, gpu: str, capabilities: list[str]) -> dict | None:
        status, body = self._call(
            "/worker/v1/claim", {"podId": self.pod_id, "gpu": gpu, "capabilities": capabilities}
        )
        if status == 204 or not isinstance(body, dict) or not body.get("job"):
            return None
        return body["job"]

    def heartbeat(self, busy: bool, **extra) -> None:
        self._call("/worker/v1/heartbeat", {"podId": self.pod_id, "busy": busy, **extra})

    def progress(self, job_id: str, payload: dict) -> Any:
        """Best effort, single attempt. Raises JobGone if the API dropped the job."""
        return self._call(self._job_path(job_id, "progress"), payload, job=True)[1]

    def done(self, job_id: str, payload: dict, deadline_s: float = 300.0) -> None:
        self._call_retrying(self._job_path(job_id, "done"), payload, deadline_s, job=True)

    def failed(self, job_id: str, error: str, retryable: bool, deadline_s: float = 300.0) -> None:
        self._call_retrying(
            self._job_path(job_id, "failed"), {"error": error, "retryable": retryable}, deadline_s, job=True
        )
