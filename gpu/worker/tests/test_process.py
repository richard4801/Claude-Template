"""The real process: SIGTERM handling, --dry-run against an API URL, token never logged."""

import os
import signal
import subprocess
import sys
import time

from .conftest import TOKEN, WORKER_DIR


def spawn(api, *args, **env):
    e = {**os.environ, "MUSE_API_URL": api.url, "WORKER_TOKEN": TOKEN, "POD_ID": "pod-proc",
         "MUSE_HEARTBEAT_INTERVAL": "0.2", "MUSE_POLL_INTERVAL": "0.1", "MUSE_LOG_LEVEL": "DEBUG", **env}
    return subprocess.Popen([sys.executable, "-m", "muse_worker", "--dry-run", *args], cwd=WORKER_DIR, env=e,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def test_dry_run_once_end_to_end(api, tmp_path):
    job = api.add_job(params={"steps": 10}, outputs=["take1.mp4", "take1.jpg"])
    p = spawn(api, "--once", "--step-seconds", "0.05", MUSE_WORK_DIR=str(tmp_path))
    out, _ = p.communicate(timeout=60)
    assert p.returncode == 0, out
    done = api.done[job["id"]]
    assert {o["name"] for o in done["outputs"]} == {"take1.mp4", "take1.jpg"}
    assert TOKEN not in out and "X-Amz-Signature" not in out


def test_sigterm_mid_render_reports_failed_and_exits_cleanly(api, tmp_path):
    job = api.add_job(params={"steps": 30})
    p = spawn(api, "--step-seconds", "0.5", "--no-fake-video", MUSE_WORK_DIR=str(tmp_path))
    api.wait_for(lambda: any(b.get("phase") == "denoising" for _, j, b in api.progress if j == job["id"]), 30)
    t0 = time.monotonic()
    p.send_signal(signal.SIGTERM)
    out, _ = p.communicate(timeout=30)
    assert p.returncode == 0, out
    assert time.monotonic() - t0 < 5
    assert api.failed[job["id"]]["retryable"] is True
    assert job["id"] not in api.done
    assert api.heartbeats[-1][1]["busy"] is False
    assert TOKEN not in out


def test_sigterm_during_upload_finishes_and_reports_done(api, tmp_path):
    job = api.add_job(params={"steps": 4})
    api.upload_delay = 1.5
    p = spawn(api, "--step-seconds", "0.05", "--no-fake-video", MUSE_WORK_DIR=str(tmp_path))
    api.wait_for(lambda: any(b.get("phase") == "uploading" for _, j, b in api.progress if j == job["id"]), 30)
    time.sleep(0.3)
    p.send_signal(signal.SIGTERM)
    out, _ = p.communicate(timeout=30)
    assert p.returncode == 0, out
    assert job["id"] in api.done and job["id"] not in api.failed


def test_missing_env_is_a_config_error(tmp_path):
    env = {k: v for k, v in os.environ.items() if k not in ("MUSE_API_URL", "WORKER_TOKEN", "POD_ID", "RUNPOD_POD_ID")}
    p = subprocess.run([sys.executable, "-m", "muse_worker"], cwd=WORKER_DIR, env=env, capture_output=True,
                       text=True, timeout=30)
    assert p.returncode == 2
    assert "MUSE_API_URL" in p.stdout and "WORKER_TOKEN" in p.stdout
