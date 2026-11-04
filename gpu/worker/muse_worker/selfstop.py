"""Dead-man's switch: the pod terminates itself when nobody is going to stop it.

The API's GPU controller normally terminates idle pods (IDLE_SHUTDOWN_SECONDS, 180 s by default). If the API is
down or unreachable (a host restart, a free-tier hiccup), that never happens and an H100 keeps billing ~$4/hour.
So the worker watches two clocks and, only while it has no job, terminates its own pod:

  * idle:        no job for SELF_STOP_IDLE_SECONDS (default 300) since the worker started or the last job ended
  * unreachable: no answer from the API for SELF_STOP_UNREACHABLE_SECONDS (default 600)

The decision is made on the worker's main thread, between claims, so it can never happen during a job or an upload.
Termination (not stop): models live on the network volume and outputs are already in R2, so the pod holds nothing.

How, in order (the first that succeeds wins):
  1. `runpodctl remove pod $RUNPOD_POD_ID` (runpodctl and a pod-scoped RUNPOD_API_KEY ship on every RunPod pod)
  2. `runpodctl pod delete $RUNPOD_POD_ID` (the newer runpodctl syntax)
  3. RunPod GraphQL `podTerminate` with RUNPOD_API_KEY from the pod's environment
  4. last resort, stop instead of terminate: `runpodctl stop pod …`, then GraphQL `podStop` (stops the GPU billing)

Set either timeout to 0 to turn that rule off; MUSE_SELF_STOP=0 turns the switch off. Off when RUNPOD_POD_ID is
unset (not on RunPod: a laptop, --dry-run, tests that don't ask for it).
"""

from __future__ import annotations

import json
import logging
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Callable

log = logging.getLogger("muse.selfstop")

_POD_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


@dataclass
class Decision:
    reason: str  # "idle" or "unreachable"
    seconds: float

    def describe(self) -> str:
        if self.reason == "idle":
            return f"no job for {self.seconds:.0f}s"
        return f"the API has not answered for {self.seconds:.0f}s"


class SelfStop:
    """Pure decision logic plus the termination call. Time comes from `clock` so tests can drive it."""

    def __init__(self, *, runpod_pod_id: str, idle_seconds: float, unreachable_seconds: float,
                 enabled: bool = True, runpodctl: str = "runpodctl", api_key: str = "",
                 graphql_url: str = "https://api.runpod.io/graphql", http_timeout: float = 20.0,
                 clock: Callable[[], float] = time.monotonic):
        self.pod_id = runpod_pod_id or ""
        self.idle_seconds = max(0.0, idle_seconds)
        self.unreachable_seconds = max(0.0, unreachable_seconds)
        self.runpodctl = runpodctl
        self.api_key = api_key or ""
        self.graphql_url = graphql_url
        self.http_timeout = http_timeout
        self.clock = clock
        self.attempts: list[str] = []  # what was tried, for logs and tests
        self.why_off = ""
        if not enabled:
            self.why_off = "MUSE_SELF_STOP=0"
        elif not self.pod_id:
            self.why_off = "RUNPOD_POD_ID is not set (not on RunPod)"
        elif not _POD_ID.match(self.pod_id):
            self.why_off = "RUNPOD_POD_ID does not look like a pod id"
        elif not self.idle_seconds and not self.unreachable_seconds:
            self.why_off = "both timeouts are 0"
        self.enabled = not self.why_off

    @classmethod
    def from_config(cls, cfg, clock: Callable[[], float] = time.monotonic) -> "SelfStop":
        return cls(runpod_pod_id=cfg.runpod_pod_id, idle_seconds=cfg.self_stop_idle_seconds,
                   unreachable_seconds=cfg.self_stop_unreachable_seconds, enabled=cfg.self_stop,
                   runpodctl=cfg.runpodctl, api_key=cfg.runpod_api_key, graphql_url=cfg.runpod_graphql_url,
                   clock=clock)

    def describe(self) -> str:
        if not self.enabled:
            return f"off ({self.why_off})"
        rules = []
        if self.idle_seconds:
            rules.append(f"after {self.idle_seconds:.0f}s without a job")
        if self.unreachable_seconds:
            rules.append(f"after {self.unreachable_seconds:.0f}s without reaching the API while idle")
        return f"on for RunPod pod {self.pod_id}: terminate " + " or ".join(rules)

    # -- decision ----------------------------------------------------------------------
    def check(self, *, busy: bool, idle_since: float, api_last_ok: float) -> Decision | None:
        """Whether to stop now. `busy` = a job (download, render, upload or report) is in progress."""
        if not self.enabled or busy:
            return None
        now = self.clock()
        idle_for = now - idle_since
        if self.idle_seconds and idle_for >= self.idle_seconds:
            return Decision("idle", idle_for)
        unreachable_for = now - api_last_ok
        if self.unreachable_seconds and unreachable_for >= self.unreachable_seconds:
            return Decision("unreachable", unreachable_for)
        return None

    # -- action ------------------------------------------------------------------------
    def terminate(self) -> str | None:
        """Ask RunPod to remove this pod. Returns the method that worked, or None if every one failed."""
        steps: list[tuple[str, Callable[[], bool]]] = []
        ctl = shutil.which(self.runpodctl) if self.runpodctl else None
        if ctl:
            steps += [("runpodctl remove pod", lambda: self._ctl(ctl, "remove", "pod", self.pod_id)),
                      ("runpodctl pod delete", lambda: self._ctl(ctl, "pod", "delete", self.pod_id))]
        else:
            log.warning("self-stop: runpodctl not found on PATH")
        if self.api_key:
            steps.append(("graphql podTerminate", lambda: self._graphql("podTerminate")))
        else:
            log.warning("self-stop: no RUNPOD_API_KEY in the environment; GraphQL fallback unavailable")
        # Last resort: a stopped pod no longer bills the GPU (only its small container disk).
        if ctl:
            steps.append(("runpodctl stop pod", lambda: self._ctl(ctl, "stop", "pod", self.pod_id)))
        if self.api_key:
            steps.append(("graphql podStop", lambda: self._graphql("podStop")))
        for name, fn in steps:
            self.attempts.append(name)
            try:
                if fn():
                    log.warning("self-stop: %s %s accepted", name, self.pod_id)
                    return name
            except Exception as e:  # never let a broken fallback hide the next one
                log.error("self-stop: %s raised %s: %s", name, type(e).__name__, e)
        log.error("self-stop: every way to terminate pod %s failed (tried %s)", self.pod_id, ", ".join(
            n for n, _ in steps) or "nothing")
        return None

    def _ctl(self, ctl: str, *args: str) -> bool:
        p = subprocess.run([ctl, *args], capture_output=True, text=True, timeout=60)
        out = (p.stdout + p.stderr).strip().replace("\n", " ")[:300]
        if p.returncode == 0:
            log.info("self-stop: runpodctl %s -> ok %s", " ".join(args), out)
            return True
        log.warning("self-stop: runpodctl %s -> exit %d %s", " ".join(args), p.returncode, out)
        return False

    def _graphql(self, mutation: str) -> bool:
        # The pod id is validated against _POD_ID, so it is safe inside a GraphQL string literal.
        query = f'mutation {{ {mutation}(input: {{podId: {json.dumps(self.pod_id)}}}) }}'
        if mutation == "podStop":
            query = f'mutation {{ podStop(input: {{podId: {json.dumps(self.pod_id)}}}) {{ id desiredStatus }} }}'
        req = urllib.request.Request(
            self.graphql_url, data=json.dumps({"query": query}).encode(), method="POST",
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {self.api_key}",
                     "User-Agent": "muse-worker-selfstop"})
        try:
            with urllib.request.urlopen(req, timeout=self.http_timeout) as r:
                status, body = r.status, r.read()
        except urllib.error.HTTPError as e:
            status, body = e.code, e.read() if e.fp else b""
        except (urllib.error.URLError, OSError) as e:
            log.warning("self-stop: GraphQL %s unreachable: %s", mutation, getattr(e, "reason", e))
            return False
        try:
            parsed = json.loads(body or b"{}")
        except ValueError:
            parsed = {}
        if 200 <= status < 300 and not parsed.get("errors"):
            return True
        errors = parsed.get("errors") if isinstance(parsed, dict) else None
        log.warning("self-stop: GraphQL %s -> HTTP %d %s", mutation, status, str(errors or body[:200])[:300])
        return False
