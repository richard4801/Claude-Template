"""Real-backend checks that run without a GPU, and the LatentSync wrapper against a fake script."""

import os
import stat
import sys
import textwrap

import pytest

from muse_worker import media
from muse_worker.backends.diffsynth_h3 import DiffSynthH3Backend, required_files
from muse_worker.jobs import build_handlers
from muse_worker.jobs.h3 import H3Handler
from muse_worker.jobs.lipsync import LatentSync, LatentSyncHandler
from muse_worker.api import ApiClient
from muse_worker.backends.fake_h3 import FakeH3Backend
from muse_worker.worker import Worker

from .conftest import make_cfg


def test_diffsynth_backend_reports_why_it_is_off(tmp_path):
    b = DiffSynthH3Backend(models_dir=tmp_path)
    reason = b.availability()
    assert reason and reason.startswith("not enabled on this pod")


def test_required_weights_layout(tmp_path):
    assert not any(required_files(tmp_path).values())
    for rel in ["h3/Ref2VA/transformer/model-00001-of-00002.safetensors", "nf4/minimax-h3-text-encoder-nf4.safetensors",
                "h3/Ref2VA/video_vae/source/model.safetensors", "h3/Ref2VA/audio_vae/model.safetensors",
                "h3/Ref2VA/processor/config.json"]:
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_bytes(b"x")
    assert all(required_files(tmp_path).values())
    assert not required_files(tmp_path, "pruned_fp8")["transformer (pruned_fp8)"]


FAKE_INFERENCE = """
import argparse, shutil, sys, time
ap = argparse.ArgumentParser()
for a in ["--unet_config_path", "--inference_ckpt_path", "--inference_steps", "--guidance_scale",
          "--video_path", "--audio_path", "--video_out_path"]:
    ap.add_argument(a)
ap.add_argument("--enable_deepcache", action="store_true")
a = ap.parse_args()
for i in range(1, 6):
    sys.stderr.write(f"\\r 40%|####  | {i}/5 [00:01<00:01,  1.00it/s]"); sys.stderr.flush(); time.sleep(0.3)
shutil.copy(a.video_path, a.video_out_path)
"""


@pytest.fixture
def latentsync(tmp_path):
    root = tmp_path / "LatentSync"
    for rel in ["scripts/__init__.py", "checkpoints/latentsync_unet.pt", "configs/unet/stage2_512.yaml"]:
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text("")
    (root / "scripts/inference.py").write_text(textwrap.dedent(FAKE_INFERENCE))
    py = tmp_path / "venv/bin/python"
    py.parent.mkdir(parents=True)
    py.write_text(f"#!/bin/sh\nexec {sys.executable} \"$@\"\n")
    py.chmod(py.stat().st_mode | stat.S_IEXEC)
    return LatentSyncHandler(LatentSync(root=root, python=py))


@pytest.mark.skipif(not media.have_ffmpeg(), reason="needs ffmpeg")
def test_lipsync_wrapper_end_to_end(api, tmp_path, latentsync):
    clip = tmp_path / "clip.mp4"
    media.make_test_video(clip, 64, 112, 25, 25, with_audio=True)
    job = api.add_job(kind="lipsync", params={"guidance": 2.0}, inputs={"h3.mp4": clip.read_bytes()},
                      outputs=["lipsync.mp4"])
    assert latentsync.availability() is None
    cfg = make_cfg(api, tmp_path, max_jobs=1)
    handlers = [h for h in build_handlers(FakeH3Backend(), lipsync=False) if h.kind != "lipsync"] + [latentsync]
    w = Worker(cfg, ApiClient(cfg), handlers, install_signals=False)
    assert "latentsync" in w.capabilities()
    assert w.run() == 0
    done = api.done[job["id"]]
    assert done["outputs"][0]["name"] == "lipsync.mp4" and done["outputs"][0]["width"] == 64
    assert done["stats"]["lipsync"]["guidance"] == 2.0
    assert any(b.get("phase") == "lip sync" and b["totalSteps"] == 5 for _, b in api.progress_for(job["id"]))


def test_lipsync_off_without_install(tmp_path):
    h = LatentSyncHandler(LatentSync(root=tmp_path / "nope", python=tmp_path / "nope/python"))
    assert h.availability().startswith("not enabled on this pod")


def test_lipsync_bad_params(api, tmp_path, latentsync):
    job = api.add_job(kind="lipsync", params={"guidance": 9}, inputs={"h3.mp4": b"x"}, outputs=["o.mp4"])
    cfg = make_cfg(api, tmp_path, max_jobs=1)
    w = Worker(cfg, ApiClient(cfg), [latentsync], install_signals=False)
    assert w.run() == 0
    assert api.failed[job["id"]]["retryable"] is False


@pytest.mark.skipif(not media.have_ffmpeg(), reason="needs ffmpeg")
def test_h3_with_lip_sync_post_pass(api, tmp_path, latentsync):
    src = tmp_path / "src.mp4"
    media.make_test_video(src, 96, 168, 30, 200, with_audio=True)
    job = api.add_job(params={"steps": 4, "lipSync": True, "keepAudio": True},
                      inputs={"source.mp4": src.read_bytes(), "ref_face.jpg": b"\xff\xd8x"}, outputs=["take_1.mp4"])
    backend = FakeH3Backend(step_seconds=0.01, make_video=True)
    cfg = make_cfg(api, tmp_path, max_jobs=1)
    w = Worker(cfg, ApiClient(cfg), [H3Handler(backend, lipsync=latentsync.runner)], install_signals=False)
    assert w.run() == 0
    done = api.done[job["id"]]
    assert done["stats"]["takes"][0]["lipsync"]["steps"] == 20
    assert any(b.get("phase") == "lip sync" for _, b in api.progress_for(job["id"]))
    blob = api.uploads[f"{job['id']}/take_1.mp4"]
    out = tmp_path / "out.mp4"
    out.write_bytes(blob)
    assert media.probe(out).has_audio


def test_h3_lip_sync_requested_but_missing_fails_before_rendering(api, tmp_path):
    job = api.add_job(params={"steps": 4, "lipSync": True})
    backend = FakeH3Backend(step_seconds=0.01)
    cfg = make_cfg(api, tmp_path, max_jobs=1)
    w = Worker(cfg, ApiClient(cfg), build_handlers(backend, lipsync=False), install_signals=False)
    assert w.run() == 0
    f = api.failed[job["id"]]
    assert f["retryable"] is False and "lip sync requested" in f["error"]
    assert backend.renders == []
