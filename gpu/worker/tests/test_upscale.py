"""Upscale job (SeedVR2): params, the output size rule, and a CPU run with the ffmpeg stand-in."""

import shlex
import threading
from pathlib import Path

import pytest

from muse_worker import media
from muse_worker.jobs.base import InputSpec, Job, JobContext, JobFailure, OutputSpec
from muse_worker.jobs.upscale import FakeSeedVR2, SeedVR2, UpscaleHandler, fit_size, upscale_params


def test_params_and_sizes():
    assert upscale_params({"size": "2k"}) == ("2k", 1440, 2560)
    assert upscale_params({"size": "4k", "width": 2160, "height": 3840}) == ("4k", 2160, 3840)
    with pytest.raises(JobFailure):
        upscale_params({"size": "8k"})
    with pytest.raises(JobFailure):
        upscale_params({"size": "2k", "width": 999})


def test_fit_keeps_aspect_and_turns_the_frame():
    assert fit_size(720, 1280, 1440, 2560) == (1440, 2560)  # 9:16 fills the 2K frame
    assert fit_size(1280, 720, 1440, 2560) == (2560, 1440)  # landscape: frame turned
    assert fit_size(1080, 1080, 1440, 2560) == (1440, 1440)  # square: limited by the short side
    w, h = fit_size(768, 1344, 1080, 1920)
    assert w % 2 == 0 and h % 2 == 0 and h <= 1920 and w <= 1080


def test_not_installed_is_reported(tmp_path):
    r = SeedVR2(root=tmp_path / "nope", python=tmp_path / "nopy")
    assert "SeedVR2 not installed" in r.availability()
    assert UpscaleHandler(r).availability() == r.availability()


@pytest.mark.skipif(not media.have_ffmpeg(), reason="ffmpeg missing")
def test_cpu_run_upscales_and_keeps_the_sound(tmp_path):
    src = tmp_path / "source.mp4"
    media.make_test_video(src, 180, 320, 24, 24, with_audio=True)
    job = Job(id="j1", kind="upscale", params={"size": "1080p", "width": 1080, "height": 1920, "source": "source.mp4"},
              inputs=[InputSpec("source.mp4", "http://x")], outputs=[OutputSpec("take_1.mp4", "http://y")])
    seen = []
    ctx = JobContext(job, tmp_path, {"source.mp4": src}, lambda **p: seen.append(p), threading.Event(), lambda: "")
    out = UpscaleHandler(FakeSeedVR2()).run(ctx)
    info = media.probe(out[0].path)
    assert (info.width, info.height) == (1080, 1920)
    assert info.has_audio
    assert ctx.stats["upscale"]["size"] == "1080p"
    assert seen and seen[-1]["phase"] == "finishing"


def test_default_command_matches_the_standalone_cli(tmp_path):
    # numz ComfyUI-SeedVR2_VideoUpscaler v2.5: positional input, --dit_model / --model_dir (not --video_path / --model).
    r = SeedVR2(root=tmp_path, python=tmp_path / "py", cmd=None)
    args = shlex.split(r.cmd.format(python=r.python, input="in.mp4", output="out.mp4", short_side=1440))
    assert args[1:3] == ["inference_cli.py", "in.mp4"]
    assert args[args.index("--resolution") + 1] == "1440"
    assert args[args.index("--dit_model") + 1] == "seedvr2_ema_3b_fp16.safetensors"
    assert "--video_path" not in args and "--model" not in args
    assert "SeedVR2 not installed" in r.availability()  # the checkout has no inference_cli.py
