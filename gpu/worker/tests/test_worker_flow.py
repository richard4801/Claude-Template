"""claim -> download -> run -> progress -> upload -> done/failed, against the fake API."""

import hashlib
import time

import pytest

from muse_worker.backends.fake_h3 import FakeH3Backend
from muse_worker.worker import EXIT_AUTH

from .conftest import TOKEN, make_worker, run_in_thread


class FakeOOM(Exception):
    pass


FakeOOM.__name__ = "OutOfMemoryError"


def test_happy_path(api, tmp_path):
    job = api.add_job(params={"steps": 10, "takes": 2, "keepAudio": True},
                      outputs=["take1.mp4", "take2.mp4", "take1.jpg", "take2.jpg"])
    backend = FakeH3Backend(step_seconds=0.02)
    w = make_worker(api, tmp_path, backend, max_jobs=1)
    assert w.run() == 0

    claim = api.claims[0]
    assert claim == {"podId": "pod-test", "gpu": "TEST GPU", "capabilities": ["h3"]}
    done = api.done[job["id"]]
    assert job["id"] not in api.failed
    assert sorted(o["name"] for o in done["outputs"]) == ["take1.jpg", "take1.mp4", "take2.jpg", "take2.mp4"]
    for o in done["outputs"]:
        blob = api.uploads[f"{job['id']}/{o['name']}"]
        assert o["bytes"] == len(blob) and o["sha256"] == hashlib.sha256(blob).hexdigest()
    mp4 = next(o for o in done["outputs"] if o["name"] == "take1.mp4")
    assert (mp4["width"], mp4["height"], mp4["fps"], mp4["durationSec"]) == (768, 1344, 24.0, round(124 / 24, 3))
    assert done["gpuSeconds"] > 0
    assert done["stats"]["seeds"] == [42, 43] and done["stats"]["frames"] == 124
    # the model was loaded once for both takes, and each take got its own seed
    assert backend.loads == 1 and [r.seed for r in backend.renders] == [42, 43]
    assert all(r.num_frames == 124 for r in backend.renders)
    # progress: well-formed, last word before done is the upload
    prog = [b for _, b in api.progress_for(job["id"])]
    assert prog and all({"step", "totalSteps", "phase"} <= set(b) for b in prog)
    assert all(b["etaSeconds"] >= 0 for b in prog if b["phase"] == "denoising")
    thumb = next(o for o in done["outputs"] if o["name"] == "take1.jpg")
    assert "fps" not in thumb and "durationSec" not in thumb  # absent, never null
    assert prog[-1]["phase"] == "uploading"
    # inputs/outputs are cleaned up after a successful job
    assert not any((tmp_path / "work").iterdir())


def test_progress_is_rate_limited_to_two_per_second(api, tmp_path):
    job = api.add_job(params={"steps": 30})
    w = make_worker(api, tmp_path, FakeH3Backend(step_seconds=0.05), max_jobs=1)  # 20 steps/s
    assert w.run() == 0
    times = [t for t, _ in api.progress_for(job["id"])]
    assert len(times) >= 3
    gaps = [b - a for a, b in zip(times, times[1:])]
    assert min(gaps) >= 0.45, gaps
    steps = [b["step"] for _, b in api.progress_for(job["id"]) if b["phase"] in ("denoising", "decoding")]
    assert steps == sorted(steps)  # coalesced, newest wins, never goes backwards


def test_every_step_reported_when_steps_are_slow(api, tmp_path):
    job = api.add_job(params={"steps": 4})
    w = make_worker(api, tmp_path, FakeH3Backend(step_seconds=0.6), max_jobs=1)
    assert w.run() == 0
    steps = [b["step"] for _, b in api.progress_for(job["id"]) if b["phase"] in ("denoising", "decoding")]
    assert steps[:3] == [1, 2, 3]  # one post per ~0.6 s step; the final one may be coalesced into "uploading"


def test_heartbeat_thread_reports_busy(api, tmp_path):
    api.add_job(params={"steps": 10})
    w = make_worker(api, tmp_path, FakeH3Backend(step_seconds=0.1), max_jobs=1, heartbeat_interval=0.1)
    assert w.run() == 0
    beats = [b for _, b in api.heartbeats]
    assert len(beats) >= 5
    assert all(b["podId"] == "pod-test" for b in beats)
    assert any(b["busy"] for b in beats) and beats[-1]["busy"] is False
    times = [t for t, _ in api.heartbeats]
    assert max(b - a for a, b in zip(times, times[1:])) < 1.0  # never starved by the "GPU"


def test_heartbeat_keeps_going_while_idle(api, tmp_path):
    w = make_worker(api, tmp_path, heartbeat_interval=0.05)
    t, out = run_in_thread(w)
    api.wait_for(lambda: len(api.heartbeats) >= 5)
    assert len(api.claims) >= 2  # 204s are polled again
    w.request_stop("test")
    t.join(5)
    assert out["code"] == 0 and not any(b["busy"] for _, b in api.heartbeats)


def test_input_checksum_mismatch_fails_not_retryable(api, tmp_path):
    job = api.add_job(wrong_sha={"face_front.jpg"})
    w = make_worker(api, tmp_path, max_jobs=1)
    assert w.run() == 0
    f = api.failed[job["id"]]
    assert f["retryable"] is False and "sha256" in f["error"]
    assert "secret" not in f["error"]  # presigned query strings never echoed


def test_corrupted_download_is_retried_then_fails(api, tmp_path):
    job = api.add_job()
    api.corrupt_blobs.add(f"{job['id']}/in/source.mp4")
    w = make_worker(api, tmp_path, max_jobs=1)
    assert w.run() == 0
    assert api.failed[job["id"]]["retryable"] is False


def test_transient_download_errors_are_retried(api, tmp_path):
    job = api.add_job()
    api.fail_next["/blobs/"] = [503, 500]
    w = make_worker(api, tmp_path, max_jobs=1)
    assert w.run() == 0
    assert job["id"] in api.done


def test_expired_download_url_fails_retryable(api, tmp_path):
    job = api.add_job()
    api.fail_next["/blobs/"] = [403]
    w = make_worker(api, tmp_path, max_jobs=1)
    assert w.run() == 0
    assert api.failed[job["id"]]["retryable"] is True


def test_upload_etag_mismatch_is_retried(api, tmp_path):
    job = api.add_job()
    api.bad_etags = 1
    w = make_worker(api, tmp_path, max_jobs=1)
    assert w.run() == 0
    assert job["id"] in api.done


def test_upload_keeps_failing_reports_retryable(api, tmp_path):
    job = api.add_job()
    api.bad_etags = 10
    w = make_worker(api, tmp_path, max_jobs=1)
    assert w.run() == 0
    f = api.failed[job["id"]]
    assert f["retryable"] is True and "upload" in f["error"]


def test_done_report_retries_through_api_errors(api, tmp_path):
    job = api.add_job()
    api.fail_next[f"/worker/v1/jobs/{job['id']}/done"] = [500, 502, 503]
    w = make_worker(api, tmp_path, max_jobs=1, report_deadline=30)
    assert w.run() == 0
    assert job["id"] in api.done


def test_claim_errors_back_off_and_recover(api, tmp_path):
    api.fail_next["/worker/v1/claim"] = [500, 503]
    job = api.add_job()
    w = make_worker(api, tmp_path, max_jobs=1)
    w.cfg.poll_interval = 0.01
    assert w.run() == 0
    assert job["id"] in api.done


@pytest.mark.parametrize("kind,error", [("viggle", "not enabled on this pod"), ("lipsync", "not enabled on this pod"),
                                        ("lora-train", "not enabled yet"), ("mystery", "unknown job kind")])
def test_disabled_and_unknown_kinds(api, tmp_path, kind, error):
    job = api.add_job(kind=kind)
    w = make_worker(api, tmp_path, max_jobs=1)
    assert w.run() == 0
    f = api.failed[job["id"]]
    assert f["retryable"] is False and error in f["error"]


def test_bad_params_fail_not_retryable(api, tmp_path):
    job = api.add_job(params={"steps": 50})
    w = make_worker(api, tmp_path, max_jobs=1)
    assert w.run() == 0
    assert api.failed[job["id"]] == {"error": "steps must be an integer 4-30, got 50", "retryable": False}


def test_missing_take_outputs(api, tmp_path):
    job = api.add_job(params={"takes": 2}, outputs=["take1.mp4"])
    assert make_worker(api, tmp_path, max_jobs=1).run() == 0
    assert api.failed[job["id"]]["retryable"] is False


def test_backend_crash_is_retryable(api, tmp_path):
    job = api.add_job()
    w = make_worker(api, tmp_path, FakeH3Backend(step_seconds=0.01, fail_at_step=3), max_jobs=1)
    assert w.run() == 0
    f = api.failed[job["id"]]
    assert f["retryable"] is True and "fake failure at step 3" in f["error"]


def test_out_of_memory_is_not_retryable(api, tmp_path):
    job = api.add_job()
    backend = FakeH3Backend(step_seconds=0.01, fail_at_step=2, error=FakeOOM("CUDA out of memory"))
    assert make_worker(api, tmp_path, backend, max_jobs=1).run() == 0
    f = api.failed[job["id"]]
    assert f["retryable"] is False and "out of memory" in f["error"]


def test_backend_unavailable_fails_every_job_not_retryable(api, tmp_path):
    job = api.add_job()
    backend = FakeH3Backend(unavailable="not enabled on this pod (H3 weights missing)")
    w = make_worker(api, tmp_path, backend, max_jobs=1)
    assert w.capabilities() == []
    assert w.run() == 0
    assert api.failed[job["id"]]["retryable"] is False


def test_api_cancel_stops_render_without_report(api, tmp_path):
    job = api.add_job(params={"steps": 30})
    backend = FakeH3Backend(step_seconds=0.1)
    w = make_worker(api, tmp_path, backend, max_jobs=1)
    t, out = run_in_thread(w)
    api.wait_for(lambda: any(b.get("phase") == "denoising" for _, j, b in api.progress if j == job["id"]))
    api.cancelled.add(job["id"])
    t.join(10)
    assert out["code"] == 0
    assert job["id"] not in api.done and job["id"] not in api.failed


def test_stop_during_render_reports_retryable_failure(api, tmp_path):
    job = api.add_job(params={"steps": 30})
    w = make_worker(api, tmp_path, FakeH3Backend(step_seconds=0.2))
    t, out = run_in_thread(w)
    api.wait_for(lambda: any(b.get("phase") == "denoising" for _, j, b in api.progress if j == job["id"]))
    w.request_stop("SIGTERM")
    t.join(10)
    assert out["code"] == 0
    f = api.failed[job["id"]]
    assert f["retryable"] is True and "shutting down" in f["error"]
    assert job["id"] not in api.done


def test_stop_during_upload_finishes_the_upload(api, tmp_path):
    job = api.add_job()
    api.upload_delay = 1.0
    w = make_worker(api, tmp_path)
    t, out = run_in_thread(w)
    api.wait_for(lambda: any(b.get("phase") == "uploading" for _, j, b in api.progress if j == job["id"]))
    time.sleep(0.2)
    w.request_stop("SIGTERM")
    t.join(10)
    assert out["code"] == 0
    assert job["id"] in api.done and job["id"] not in api.failed


def test_wrong_token_exits_and_never_sends_it_elsewhere(api, tmp_path):
    w = make_worker(api, tmp_path)
    api.token = "a-different-token"
    assert w.run() == EXIT_AUTH
    assert api.auth_failures >= 1
    assert all(h.get("Authorization") == f"Bearer {TOKEN}" for h in api.seen_headers)


def test_job_shaped_like_server_api_payload(api, tmp_path):
    """Mirrors payload() in server/api/src/routes/worker.ts as of 2026-11-04."""
    inputs = {"source.mp4": b"src" * 100, **{f"ref_{k}.jpg": b"\xff\xd8" + k.encode() for k in
                                              ["face", "profile", "front", "tq", "side", "back"]},
              **{f"outfit_{i}.jpg": b"\xff\xd8o" for i in range(1, 5)}}
    params = {"engine": "h3", "takes": 2, "seeds": [1234, 1235], "use": "full", "lengthSec": 9.4, "clipSeconds": 9.4,
              "keepAudio": True, "audioMode": "fully_copy", "lipSync": False, "background": "keep",
              "backgroundMotion": "subtle", "lora": None, "width": None, "height": None, "fps": None}
    job = api.add_job(params=params, inputs=inputs, outputs=["take_1.mp4", "take_2.mp4"], send_checksums=False,
                      steps=10, seed=1234)
    backend = FakeH3Backend(step_seconds=0.01)
    assert make_worker(api, tmp_path, backend, max_jobs=1).run() == 0
    assert job["id"] in api.done, api.failed
    r = backend.renders[0]
    assert r.num_frames == 226 and r.keep_frames == 225  # 9.4 s: render 226, keep all 225 (was cut to 209)
    assert [x.seed for x in backend.renders] == [1234, 1235]
    assert [p.name for p in r.references] == [n for n in inputs if n != "source.mp4"]  # inputs order = <Image N>
