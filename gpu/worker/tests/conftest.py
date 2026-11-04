from __future__ import annotations

import threading
from pathlib import Path

import pytest

from muse_worker.api import ApiClient
from muse_worker.backends.fake_h3 import FakeH3Backend
from muse_worker.config import Config
from muse_worker.devtools.fake_api import FakeApi
from muse_worker.jobs import build_handlers
from muse_worker.log import add_secret
from muse_worker.worker import Worker

TOKEN = "s3cret-worker-token-abc123"
WORKER_DIR = Path(__file__).resolve().parents[1]


@pytest.fixture
def api():
    with FakeApi(token=TOKEN) as a:
        yield a
        assert a.validation_errors == [], a.validation_errors  # every payload matched the API's schemas


def make_cfg(api: FakeApi, tmp_path: Path, **kw) -> Config:
    cfg = Config.from_env({"MUSE_API_URL": api.url, "WORKER_TOKEN": TOKEN, "POD_ID": "pod-test"},
                          heartbeat_interval=kw.pop("heartbeat_interval", 0.1), poll_interval=0.05,
                          work_dir=tmp_path / "work", report_deadline=kw.pop("report_deadline", 5.0), **kw)
    cfg.gpu_name = "TEST GPU"
    add_secret(cfg.token)
    return cfg


def make_worker(api: FakeApi, tmp_path: Path, backend: FakeH3Backend | None = None, **kw) -> Worker:
    cfg = make_cfg(api, tmp_path, **kw)
    backend = backend or FakeH3Backend(step_seconds=0.01)
    return Worker(cfg, ApiClient(cfg), build_handlers(backend, lipsync=False), install_signals=False)


def run_in_thread(worker: Worker) -> tuple[threading.Thread, dict]:
    out: dict = {}
    t = threading.Thread(target=lambda: out.setdefault("code", worker.run()), daemon=True)
    t.start()
    return t, out
