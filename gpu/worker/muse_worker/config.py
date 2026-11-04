"""Worker settings, read from the environment (the pod template sets them)."""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping


class ConfigError(Exception):
    pass


def _float(env: Mapping[str, str], name: str, default: float) -> float:
    raw = env.get(name)
    if raw in (None, ""):
        return default
    try:
        return float(raw)
    except ValueError as e:
        raise ConfigError(f"{name} must be a number") from e


def detect_gpu_name() -> str:
    """GPU name for the claim call, without importing torch."""
    if shutil.which("nvidia-smi"):
        try:
            out = subprocess.run(
                ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                capture_output=True, text=True, timeout=15,
            )
            name = out.stdout.strip().splitlines()[0].strip() if out.stdout.strip() else ""
            if name:
                return name
        except (OSError, subprocess.SubprocessError, IndexError):
            pass
    return "unknown"


@dataclass
class Config:
    api_url: str
    token: str = field(repr=False)
    pod_id: str
    gpu_name: str = "unknown"
    heartbeat_interval: float = 15.0
    poll_interval: float = 5.0
    progress_interval: float = 0.5  # at most 2 progress posts per second
    http_timeout: float = 30.0
    shutdown_grace: float = 20.0  # how long SIGTERM waits for an upload in flight
    report_deadline: float = 300.0  # how long done/failed keep retrying through API outages
    transfer_attempts: int = 3
    work_dir: Path = Path("/tmp/muse-jobs")
    max_jobs: int | None = None
    keep_failed: bool = False
    preload: bool = True
    # Dead-man's switch (selfstop.py): terminate the pod when idle or cut off from the API.
    runpod_pod_id: str = ""  # RunPod's own id (RUNPOD_POD_ID), not the API's POD_ID
    self_stop: bool = True
    self_stop_idle_seconds: float = 300.0
    self_stop_unreachable_seconds: float = 600.0
    self_stop_retry_seconds: float = 60.0
    runpodctl: str = "runpodctl"
    runpod_api_key: str = field(default="", repr=False)
    runpod_graphql_url: str = "https://api.runpod.io/graphql"

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None, **overrides) -> "Config":
        env = os.environ if env is None else env
        api_url = overrides.pop("api_url", None) or env.get("MUSE_API_URL", "")
        token = overrides.pop("token", None) or env.get("WORKER_TOKEN", "")
        pod_id = overrides.pop("pod_id", None) or env.get("POD_ID") or env.get("RUNPOD_POD_ID", "")
        missing = [n for n, v in (("MUSE_API_URL", api_url), ("WORKER_TOKEN", token), ("POD_ID", pod_id)) if not v]
        if missing:
            raise ConfigError("missing required environment variable(s): " + ", ".join(missing))
        if not api_url.startswith(("http://", "https://")):
            raise ConfigError("MUSE_API_URL must start with http:// or https://")
        max_jobs = env.get("MUSE_MAX_JOBS")
        cfg = cls(
            api_url=api_url.rstrip("/"),
            token=token,
            pod_id=pod_id,
            gpu_name=env.get("MUSE_GPU_NAME", ""),
            heartbeat_interval=_float(env, "MUSE_HEARTBEAT_INTERVAL", 15.0),
            poll_interval=_float(env, "MUSE_POLL_INTERVAL", 5.0),
            progress_interval=_float(env, "MUSE_PROGRESS_INTERVAL", 0.5),
            http_timeout=_float(env, "MUSE_HTTP_TIMEOUT", 30.0),
            shutdown_grace=_float(env, "MUSE_SHUTDOWN_GRACE", 20.0),
            report_deadline=_float(env, "MUSE_REPORT_DEADLINE", 300.0),
            work_dir=Path(env.get("MUSE_WORK_DIR", "/tmp/muse-jobs")),
            max_jobs=int(max_jobs) if max_jobs else None,
            keep_failed=env.get("MUSE_KEEP_FAILED", "0") == "1",
            preload=env.get("MUSE_PRELOAD", "1") == "1",
            runpod_pod_id=env.get("RUNPOD_POD_ID", ""),
            self_stop=env.get("MUSE_SELF_STOP", "1") != "0",
            self_stop_idle_seconds=_float(env, "SELF_STOP_IDLE_SECONDS", 300.0),
            self_stop_unreachable_seconds=_float(env, "SELF_STOP_UNREACHABLE_SECONDS", 600.0),
            self_stop_retry_seconds=_float(env, "SELF_STOP_RETRY_SECONDS", 60.0),
            runpodctl=env.get("MUSE_RUNPODCTL", "runpodctl"),
            runpod_api_key=env.get("RUNPOD_API_KEY", ""),
            runpod_graphql_url=env.get("RUNPOD_GRAPHQL_URL", "https://api.runpod.io/graphql"),
        )
        for k, v in overrides.items():
            if v is not None:
                setattr(cfg, k, v)
        # Never go faster than the protocol allows.
        cfg.progress_interval = max(cfg.progress_interval, 0.5)
        return cfg
