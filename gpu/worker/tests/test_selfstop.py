"""Dead-man's switch: the pod terminates itself when idle or cut off from the API, never mid-job.

runpodctl is a fake shell script that records its arguments; RunPod's GraphQL endpoint is FakeApi's /graphql.
Nothing here talks to RunPod.
"""

import os
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

from muse_worker.api import ApiClient
from muse_worker.backends.fake_h3 import FakeH3Backend
from muse_worker.config import Config
from muse_worker.jobs import build_handlers
from muse_worker.selfstop import SelfStop
from muse_worker.worker import EXIT_OK, EXIT_SELF_STOP, Worker

from .conftest import TOKEN, make_cfg, run_in_thread

RUNPOD_ID = "abc123xyz"
POD_DIR = Path(__file__).resolve().parents[2] / "pod"


def fake_runpodctl(tmp_path: Path, exit_code: int = 0) -> tuple[str, Path]:
    calls = tmp_path / "runpodctl-calls.txt"
    script = tmp_path / "runpodctl"
    script.write_text(f'#!/bin/sh\necho "$@" >> "{calls}"\necho "fake runpodctl $@"\nexit {exit_code}\n')
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return str(script), calls


def calls_of(path: Path) -> list[str]:
    return path.read_text().splitlines() if path.exists() else []


def selfstop_worker(api_url_cfg: Config, *, idle: float, unreachable: float, runpodctl: str = "",
                    api_key: str = "", graphql_url: str = "", backend=None, retry: float = 60.0) -> Worker:
    cfg = api_url_cfg
    cfg.runpod_pod_id = RUNPOD_ID
    cfg.self_stop_idle_seconds = idle
    cfg.self_stop_unreachable_seconds = unreachable
    cfg.self_stop_retry_seconds = retry
    cfg.runpodctl = runpodctl or "/nonexistent/runpodctl"
    cfg.runpod_api_key = api_key
    cfg.runpod_graphql_url = graphql_url or "http://127.0.0.1:9/graphql"
    return Worker(cfg, ApiClient(cfg), build_handlers(backend or FakeH3Backend(step_seconds=0.01), lipsync=False),
                  install_signals=False)


# -- decision logic (no threads, a fake clock) ------------------------------------------------

def test_decision_idle_and_unreachable_rules():
    now = [1000.0]
    s = SelfStop(runpod_pod_id=RUNPOD_ID, idle_seconds=300, unreachable_seconds=600, clock=lambda: now[0])
    assert s.enabled
    assert s.check(busy=False, idle_since=800, api_last_ok=1000) is None          # idle 200 s
    d = s.check(busy=False, idle_since=700, api_last_ok=1000)                      # idle 300 s
    assert d and d.reason == "idle"
    assert s.check(busy=True, idle_since=0, api_last_ok=0) is None                 # never while a job runs
    s2 = SelfStop(runpod_pod_id=RUNPOD_ID, idle_seconds=0, unreachable_seconds=600, clock=lambda: now[0])
    assert s2.check(busy=False, idle_since=0, api_last_ok=500) is None             # 500 s unreachable
    d = s2.check(busy=False, idle_since=0, api_last_ok=400)
    assert d and d.reason == "unreachable"
    assert s2.check(busy=True, idle_since=0, api_last_ok=0) is None


def test_off_when_not_on_runpod_or_disabled():
    assert not SelfStop(runpod_pod_id="", idle_seconds=300, unreachable_seconds=600).enabled
    assert not SelfStop(runpod_pod_id=RUNPOD_ID, idle_seconds=300, unreachable_seconds=600, enabled=False).enabled
    assert not SelfStop(runpod_pod_id=RUNPOD_ID, idle_seconds=0, unreachable_seconds=0).enabled
    assert not SelfStop(runpod_pod_id='x"}) { evil }', idle_seconds=300, unreachable_seconds=600).enabled
    cfg = Config.from_env({"MUSE_API_URL": "http://x", "WORKER_TOKEN": "t", "POD_ID": "pod_1"})
    assert cfg.runpod_pod_id == "" and not SelfStop.from_config(cfg).enabled  # POD_ID (the API's id) is not enough
    cfg = Config.from_env({"MUSE_API_URL": "http://x", "WORKER_TOKEN": "t", "POD_ID": "pod_1", "RUNPOD_POD_ID": "rp1",
                           "SELF_STOP_IDLE_SECONDS": "120", "SELF_STOP_UNREACHABLE_SECONDS": "0"})
    s = SelfStop.from_config(cfg)
    assert s.enabled and s.pod_id == "rp1" and s.idle_seconds == 120 and s.unreachable_seconds == 0


# -- the worker loop against the fake API -----------------------------------------------------

def test_idle_timeout_terminates_with_runpodctl_after_telling_the_api(api, tmp_path):
    ctl, calls = fake_runpodctl(tmp_path)
    w = selfstop_worker(make_cfg(api, tmp_path), idle=0.4, unreachable=0, runpodctl=ctl)
    t0 = time.monotonic()
    assert w.run() == EXIT_SELF_STOP
    assert 0.4 <= time.monotonic() - t0 < 5
    assert calls_of(calls) == [f"remove pod {RUNPOD_ID}"]
    assert w.self_stopped == "runpodctl remove pod"
    states = [b.get("state") for _, b in api.heartbeats]
    assert states[-1] == "self-stopping" and api.heartbeats[-1][1]["reason"] == "idle"
    assert "stopping" not in states  # the normal final "stopping" beat is skipped after a self-stop
    assert api.graphql == []


def test_never_mid_job_or_mid_upload(api, tmp_path):
    ctl, calls = fake_runpodctl(tmp_path)
    job = api.add_job(params={"steps": 10})
    api.upload_delay = 0.6  # the upload alone outlasts the idle timeout
    # 10 steps x 0.1 s + a slow upload: the job runs well past the 0.3 s idle timeout
    w = selfstop_worker(make_cfg(api, tmp_path), idle=0.3, unreachable=0.3, runpodctl=ctl,
                        backend=FakeH3Backend(step_seconds=0.1))
    t, out = run_in_thread(w)
    api.wait_for(lambda: job["id"] in api.done, 30)
    done_at = time.monotonic()
    assert calls_of(calls) == []  # nothing while the job ran or uploaded
    t.join(10)
    assert out["code"] == EXIT_SELF_STOP
    assert calls_of(calls) == [f"remove pod {RUNPOD_ID}"]
    assert job["id"] not in api.failed
    # the idle clock restarted when the job ended
    beats = [ts for ts, b in api.heartbeats if b.get("state") == "self-stopping"]
    assert beats and beats[0] - done_at >= 0.2


def test_unreachable_api_terminates_while_idle(tmp_path):
    # A port nothing listens on: every claim and heartbeat fails.
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    ctl, calls = fake_runpodctl(tmp_path)
    cfg = Config.from_env({"MUSE_API_URL": f"http://127.0.0.1:{port}", "WORKER_TOKEN": TOKEN, "POD_ID": "pod-x"},
                          heartbeat_interval=0.1, poll_interval=0.05, work_dir=tmp_path / "work")
    w = selfstop_worker(cfg, idle=0, unreachable=0.5, runpodctl=ctl)
    t, out = run_in_thread(w)
    t.join(20)
    assert out["code"] == EXIT_SELF_STOP
    assert calls_of(calls) == [f"remove pod {RUNPOD_ID}"]
    assert "unreachable" in w.stop_reason or "not answered" in w.stop_reason


def test_reachable_api_keeps_an_idle_pod_when_only_the_unreachable_rule_is_on(api, tmp_path):
    ctl, calls = fake_runpodctl(tmp_path)
    w = selfstop_worker(make_cfg(api, tmp_path), idle=0, unreachable=0.3, runpodctl=ctl)
    t, out = run_in_thread(w)
    time.sleep(1.0)
    w.request_stop("test over")
    t.join(10)
    assert out["code"] == EXIT_OK and calls_of(calls) == []


def test_fallback_to_graphql_when_runpodctl_fails(api, tmp_path):
    ctl, calls = fake_runpodctl(tmp_path, exit_code=1)
    w = selfstop_worker(make_cfg(api, tmp_path), idle=0.2, unreachable=0, runpodctl=ctl,
                        api_key="rp-pod-scoped-key", graphql_url=f"{api.url}/graphql")
    assert w.run() == EXIT_SELF_STOP
    assert calls_of(calls) == [f"remove pod {RUNPOD_ID}", f"pod delete {RUNPOD_ID}"]
    assert w.self_stopped == "graphql podTerminate"
    headers, body = api.graphql[0]
    assert headers.get("Authorization") == "Bearer rp-pod-scoped-key"
    assert body["query"] == f'mutation {{ podTerminate(input: {{podId: "{RUNPOD_ID}"}}) }}'


def test_graphql_only_when_runpodctl_is_missing(api, tmp_path):
    w = selfstop_worker(make_cfg(api, tmp_path), idle=0.2, unreachable=0, runpodctl="",
                        api_key="k", graphql_url=f"{api.url}/graphql")
    assert w.run() == EXIT_SELF_STOP and w.self_stopped == "graphql podTerminate"


def test_everything_fails_keeps_serving_and_retries(api, tmp_path):
    ctl, calls = fake_runpodctl(tmp_path, exit_code=1)
    api.graphql_errors = [{"message": "nope"}]
    w = selfstop_worker(make_cfg(api, tmp_path), idle=0.2, unreachable=0, runpodctl=ctl, api_key="k",
                        graphql_url=f"{api.url}/graphql", retry=0.5)
    t, out = run_in_thread(w)
    api.wait_for(lambda: len(api.graphql) >= 4, 10)  # terminate+stop, twice: it tried again after the retry delay
    job = api.add_job(params={"steps": 4})  # and it still serves jobs in between
    api.wait_for(lambda: job["id"] in api.done, 20)
    api.graphql_errors = None  # RunPod recovers: the next try works
    t.join(10)
    assert out["code"] == EXIT_SELF_STOP and w.self_stopped == "graphql podTerminate"
    assert f"stop pod {RUNPOD_ID}" in calls_of(calls)  # the last-resort stop was tried too
    assert any("podStop" in b["query"] for _, b in api.graphql)


# -- bootstrap's supervisor -------------------------------------------------------------------

def run_supervise(tmp_path: Path, exit_code: int, **env) -> tuple[subprocess.CompletedProcess, int]:
    counter = tmp_path / "starts"
    worker = tmp_path / "fake-worker.sh"
    worker.write_text(f'#!/bin/sh\necho start >> "{counter}"\nexit {exit_code}\n')
    worker.chmod(0o755)
    e = {**os.environ, "MUSE_RESTART_DELAY_SECONDS": "0", "MUSE_SELF_STOP_LINGER_SECONDS": "2", **env}
    p = subprocess.run(["bash", str(POD_DIR / "supervise.sh"), str(tmp_path / "w.log"), str(worker)], env=e,
                       capture_output=True, text=True, timeout=60)
    return p, len(counter.read_text().splitlines())


@pytest.mark.skipif(sys.platform == "win32", reason="bash")
def test_supervisor_does_not_restart_after_self_stop(tmp_path):
    p, starts = run_supervise(tmp_path, EXIT_SELF_STOP)
    assert starts == 1, p.stdout
    assert "SELF-STOPPED" in p.stdout and p.returncode == 0


@pytest.mark.skipif(sys.platform == "win32", reason="bash")
def test_supervisor_still_restarts_after_a_crash(tmp_path):
    p, starts = run_supervise(tmp_path, 1, RUNPOD_POD_ID="")
    assert starts == 6 and p.returncode == 1, p.stdout


@pytest.mark.skipif(sys.platform == "win32", reason="bash")
def test_supervisor_terminates_the_pod_after_a_crash_loop(tmp_path):
    ctl, calls = fake_runpodctl(tmp_path)
    p, starts = run_supervise(tmp_path, 1, RUNPOD_POD_ID=RUNPOD_ID, PATH=f"{Path(ctl).parent}:{os.environ['PATH']}")
    assert starts == 6
    assert calls_of(calls)[0] == f"remove pod {RUNPOD_ID}", p.stdout
