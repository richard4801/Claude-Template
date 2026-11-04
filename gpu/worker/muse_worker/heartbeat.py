"""Heartbeat thread: `POST /worker/v1/heartbeat {podId, busy}` every 15 s.

If heartbeats stop for 60 s the controller fails the job (retryable) and stops the pod,
so this runs on its own thread and never waits on the GPU.
"""

from __future__ import annotations

import logging
import threading
from typing import Callable

from .api import ApiClient, ApiError, AuthError

log = logging.getLogger("muse.heartbeat")


class Heartbeat:
    def __init__(self, api: ApiClient, interval: float, status: Callable[[], dict]):
        self.api = api
        self.interval = interval
        self.status = status  # returns {"busy": bool, ...extra}
        self.sent = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="heartbeat", daemon=True)
        self._failing = False

    def start(self) -> None:
        self._thread.start()

    def _beat(self, **override) -> None:
        st = {**self.status(), **override}
        busy = bool(st.pop("busy", False))
        self.api.heartbeat(busy, **st)
        self.sent += 1

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self._beat()
                if self._failing:
                    log.info("heartbeat recovered")
                self._failing = False
            except AuthError as e:
                log.error("heartbeat rejected (check WORKER_TOKEN): %s", e)
                self._failing = True
            except ApiError as e:
                if not self._failing:
                    log.warning("heartbeat failed: %s", e)
                self._failing = True
            except Exception:
                log.exception("heartbeat crashed")
            self._stop.wait(self.interval)

    def stop(self, final: bool = True) -> None:
        self._stop.set()
        self._thread.join(5)
        if final:
            try:
                self._beat(busy=False, state="stopping")
            except Exception as e:  # best effort on the way out
                log.debug("final heartbeat failed: %s", e)
