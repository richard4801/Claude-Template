"""Job model and the handler interface every job kind implements."""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from ..transfer import safe_name

VIDEO_EXT = (".mp4", ".mov", ".m4v", ".webm", ".mkv")
IMAGE_EXT = (".jpg", ".jpeg", ".png", ".webp")
AUDIO_EXT = (".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg")


class JobFailure(Exception):
    """A failure to report as `failed {error, retryable}`."""

    def __init__(self, message: str, retryable: bool):
        super().__init__(message)
        self.retryable = retryable


class JobCancelled(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass
class InputSpec:
    name: str
    url: str
    bytes: int | None = None
    sha256: str | None = None


@dataclass
class OutputSpec:
    name: str
    upload_url: str
    headers: dict[str, str] = field(default_factory=dict)


@dataclass
class Job:
    id: str
    kind: str
    params: dict[str, Any]
    inputs: list[InputSpec]
    outputs: list[OutputSpec]
    prompt: str | None = None
    seed: int | None = None
    steps: int | None = None

    @classmethod
    def from_dict(cls, d: dict) -> "Job":
        if not isinstance(d, dict) or not d.get("id"):
            raise JobFailure("job has no id", retryable=False)
        try:
            inputs = [
                InputSpec(
                    name=safe_name(i["name"]),
                    url=i["url"],
                    bytes=i.get("bytes", i.get("size")),
                    sha256=i.get("sha256"),
                )
                for i in d.get("inputs") or []
            ]
            outputs = []
            for o in d.get("outputs") or []:
                headers = dict(o.get("headers") or {})
                if o.get("contentType") and not any(k.lower() == "content-type" for k in headers):
                    headers["Content-Type"] = o["contentType"]
                outputs.append(OutputSpec(name=safe_name(o["name"]), upload_url=o["uploadUrl"], headers=headers))
        except (KeyError, TypeError, ValueError) as e:
            raise JobFailure(f"malformed job inputs/outputs: {e}", retryable=False) from None
        if len({i.name for i in inputs}) != len(inputs) or len({o.name for o in outputs}) != len(outputs):
            raise JobFailure("duplicate input or output names", retryable=False)
        params = d.get("params") or {}
        if not isinstance(params, dict):
            raise JobFailure("params must be an object", retryable=False)
        return cls(
            id=str(d["id"]),
            kind=str(d.get("kind", "")),
            params=params,
            inputs=inputs,
            outputs=outputs,
            prompt=d.get("prompt"),
            seed=d.get("seed"),
            steps=d.get("steps"),
        )

    def outputs_with(self, exts: tuple[str, ...]) -> list[OutputSpec]:
        return [o for o in self.outputs if o.name.lower().endswith(exts)]


@dataclass
class ProducedOutput:
    name: str
    path: Path
    width: int | None = None
    height: int | None = None
    fps: float | None = None
    duration_sec: float | None = None


class JobContext:
    """What a handler gets: the job, its downloaded inputs, progress and cancellation."""

    def __init__(
        self,
        job: Job,
        work_dir: Path,
        inputs: dict[str, Path],
        report: Callable[..., None],
        cancel_event: threading.Event,
        cancel_reason: Callable[[], str],
    ):
        self.job = job
        self.work_dir = work_dir
        self.inputs = inputs
        self.out_dir = work_dir / "out"
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.stats: dict[str, Any] = {}
        self.log = logging.getLogger(f"muse.job.{job.kind}")
        self._report = report
        self._cancel = cancel_event
        self._cancel_reason = cancel_reason

    def progress(self, step: int, total_steps: int, phase: str, eta_seconds: float | None = None, **extra) -> None:
        # Absent rather than null: the API validates these as optional numbers, totalSteps >= 1.
        payload = {"step": max(0, int(step)), "totalSteps": max(1, int(total_steps)), "phase": phase}
        if eta_seconds is not None:
            payload["etaSeconds"] = max(0, round(eta_seconds))
        payload.update({k: v for k, v in extra.items() if v is not None})
        self._report(**payload)

    @property
    def cancelled(self) -> bool:
        return self._cancel.is_set()

    def check_cancel(self) -> None:
        if self._cancel.is_set():
            raise JobCancelled(self._cancel_reason())

    def output_path(self, name: str) -> Path:
        return self.out_dir / safe_name(name)

    def inputs_with(self, exts: tuple[str, ...]) -> list[str]:
        return [i.name for i in self.job.inputs if i.name.lower().endswith(exts)]


class JobHandler:
    kind: str = ""
    capability: str = ""

    def availability(self) -> str | None:
        """None when this pod can run the kind, otherwise the reason it can't."""
        return None

    def prepare(self) -> None:
        """Optional warm-up at worker start (e.g. load the model once)."""

    def run(self, ctx: JobContext) -> list[ProducedOutput]:
        raise NotImplementedError


class DisabledHandler(JobHandler):
    """A kind this pod knows about but does not run. Jobs fail with retryable=false."""

    def __init__(self, kind: str, capability: str, reason: str):
        self.kind, self.capability, self.reason = kind, capability, reason

    def availability(self) -> str | None:
        return self.reason

    def run(self, ctx: JobContext) -> list[ProducedOutput]:
        raise JobFailure(self.reason, retryable=False)
