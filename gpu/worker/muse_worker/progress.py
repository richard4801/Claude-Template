"""Progress reporting off the GPU thread, coalesced to at most one post per interval."""

from __future__ import annotations

import logging
import threading
import time
from typing import Any, Callable

from .api import ApiError, JobGone

log = logging.getLogger("muse.progress")


class ProgressReporter:
    """`update()` never blocks. A sender thread posts the newest state, at most every `min_interval` s.

    If the API answers a progress post with 404/409/410, or with `{"cancel": true}`,
    `on_cancel` is called once so the job can stop at the next step.
    """

    def __init__(
        self,
        send: Callable[[dict], Any],
        min_interval: float = 0.5,
        on_cancel: Callable[[str], None] | None = None,
        clock: Callable[[], float] = time.monotonic,
    ):
        self._send = send
        self._interval = min_interval
        self._on_cancel = on_cancel
        self._clock = clock
        self._cond = threading.Condition()
        self._pending: dict | None = None
        self._last = float("-inf")
        self._closing = False
        self._flush = True
        self._cancelled = False
        self.sent = 0
        self._thread = threading.Thread(target=self._run, name="progress", daemon=True)
        self._thread.start()

    def update(self, **payload) -> None:
        with self._cond:
            if self._closing:
                return
            self._pending = payload
            self._cond.notify()

    def close(self, flush: bool = True, timeout: float = 5.0) -> None:
        with self._cond:
            if self._closing:
                return
            self._closing, self._flush = True, flush
            if not flush:
                self._pending = None
            self._cond.notify()
        self._thread.join(timeout)

    def _run(self) -> None:
        while True:
            with self._cond:
                while self._pending is None and not self._closing:
                    self._cond.wait()
                if self._pending is None:
                    return
                wait = self._last + self._interval - self._clock()
                if wait > 0:
                    self._cond.wait(wait)
                    continue  # pick up whatever is newest now
                payload, self._pending = self._pending, None
                self._last = self._clock()
            self._post(payload)

    def _post(self, payload: dict) -> None:
        try:
            resp = self._send(payload)
            self.sent += 1
            if isinstance(resp, dict) and resp.get("cancel"):
                self._cancel("api asked to cancel")
        except JobGone as e:
            self._cancel(str(e))
        except ApiError as e:
            log.debug("progress post failed (ignored): %s", e)
        except Exception:  # never let progress kill a render
            log.exception("progress post crashed (ignored)")

    def _cancel(self, why: str) -> None:
        if not self._cancelled and self._on_cancel:
            self._cancelled = True
            self._on_cancel(why)
