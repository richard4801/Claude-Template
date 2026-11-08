"""Job kind `upscale`: SeedVR2 video upscaling of a finished take (plans/app-cleanup.md decision 6).

The API sends `source.mp4` plus `params {size, width, height, seconds}` (1080p = 1080x1920, 2K = 1440x2560,
4K = 2160x3840, portrait) and expects one `.mp4` output. The take keeps its aspect ratio and sound: SeedVR2 upscales,
then ffmpeg fits the result inside the size's frame (flipped for landscape sources) and puts the source audio back.

SeedVR2 runs in its own checkout and venv on the volume, like LatentSync. Enabled only when they exist.
⚠ The SeedVR2 command line is not verified on a pod yet: it is a template (env SEEDVR2_CMD) so it can be set
without a code change. `FakeSeedVR2` (ffmpeg lanczos) keeps the handler testable on CPU.
"""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import time
from collections import deque
from pathlib import Path
from typing import Callable

from .. import media
from .base import VIDEO_EXT, JobContext, JobFailure, JobHandler, ProducedOutput

SIZES = {"1080p": (1080, 1920), "2k": (1440, 2560), "4k": (2160, 3840)}
_TQDM = re.compile(r"(\d+)/(\d+) \[")
# The numz ComfyUI-SeedVR2_VideoUpscaler standalone CLI (v2.5): the input is positional, the weights live in
# models/SEEDVR2 under the checkout. Large frames tile the VAE so 2K/4K fit. Still unverified on a pod (timing run
# pending); override with SEEDVR2_CMD on the pod.
DEFAULT_CMD = ("{python} inference_cli.py {input} --output {output} --resolution {short_side} "
               "--dit_model seedvr2_ema_3b_fp16.safetensors --model_dir models/SEEDVR2 --batch_size 21 "
               "--vae_encode_tiled --vae_decode_tiled")


# -- pure helpers --------------------------------------------------------------
def upscale_params(p: dict) -> tuple[str, int, int]:
    """(size, width, height) of the target frame (portrait), checked against the known sizes."""
    size = p.get("size")
    if size not in SIZES:
        raise JobFailure(f"size must be one of {', '.join(SIZES)}, got {size!r}", retryable=False)
    w, h = SIZES[size]
    if p.get("width") not in (None, w) or p.get("height") not in (None, h):
        raise JobFailure(f"{size} is {w}x{h}, got {p.get('width')}x{p.get('height')}", retryable=False)
    return size, w, h


def fit_size(src_w: int, src_h: int, frame_w: int, frame_h: int) -> tuple[int, int]:
    """The largest even size with the source's aspect inside the frame (the frame turned to match the source)."""
    if src_w <= 0 or src_h <= 0:
        raise JobFailure("the source has no picture size", retryable=False)
    if src_w > src_h:
        frame_w, frame_h = max(frame_w, frame_h), min(frame_w, frame_h)
    scale = min(frame_w / src_w, frame_h / src_h)
    w, h = int(src_w * scale) // 2 * 2, int(src_h * scale) // 2 * 2
    return max(2, w), max(2, h)


# -- runners -------------------------------------------------------------------
class SeedVR2:
    def __init__(self, root: str | Path | None = None, python: str | Path | None = None, cmd: str | None = None):
        self.root = Path(root or os.environ.get("SEEDVR2_DIR", "/workspace/SeedVR2"))
        self.python = Path(python or os.environ.get("SEEDVR2_PYTHON", "/workspace/venvs/seedvr2/bin/python"))
        self.cmd = cmd or os.environ.get("SEEDVR2_CMD", DEFAULT_CMD)

    def availability(self) -> str | None:
        need = [self.root, self.python, self.root / "inference_cli.py"]
        missing = [str(p) for p in need if not p.exists()]
        return f"SeedVR2 not installed on this pod yet (missing: {', '.join(missing)})" if missing else None

    def _env(self) -> dict[str, str]:
        env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "VIRTUAL_ENV", "PYTHONHOME")}
        env["LD_LIBRARY_PATH"] = os.environ.get("MUSE_ORIG_LD_LIBRARY_PATH", "")
        env["PATH"] = f"{self.python.parent}:{env.get('PATH', '')}"
        return env

    def run(self, src: Path, out: Path, short_side: int, on_progress: Callable[[int, int, float | None], None],
            check_cancel: Callable[[], None]) -> float:
        """Upscale `src` so its short side is about `short_side`, into `out`. Returns the seconds it took."""
        cmd = shlex.split(self.cmd.format(python=self.python, input=src, output=out, short_side=short_side))
        t0 = time.monotonic()
        tail: deque[str] = deque(maxlen=30)
        proc = subprocess.Popen(cmd, cwd=self.root, env=self._env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
        buf = b""
        try:
            while True:
                check_cancel()
                chunk = proc.stdout.read(4096)
                if not chunk:
                    break
                buf += chunk
                *lines, buf = re.split(rb"[\r\n]", buf)
                for raw in lines:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line:
                        continue
                    tail.append(line)
                    if m := _TQDM.search(line):
                        i, n = int(m.group(1)), int(m.group(2))
                        el = time.monotonic() - t0
                        on_progress(i, n, el / i * (n - i) if i else None)
            code = proc.wait()
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
        if code != 0 or not out.exists():
            raise JobFailure(f"SeedVR2 exited {code}: {' | '.join(list(tail)[-5:])[-400:]}", retryable=True)
        return time.monotonic() - t0


class FakeSeedVR2(SeedVR2):
    """CPU stand-in for tests and dry runs: a lanczos scale with ffmpeg (no model)."""

    def availability(self) -> str | None:
        return None if media.have_ffmpeg() else "ffmpeg missing"

    def run(self, src, out, short_side, on_progress, check_cancel) -> float:
        t0 = time.monotonic()
        info = media.probe(src)
        w, h = fit_size(info.width or 0, info.height or 0, short_side, short_side * 2)
        media._run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-vf", f"scale={w}:{h}:flags=lanczos",
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "16", "-pix_fmt", "yuv420p", "-an", str(out)])
        on_progress(1, 1, 0)
        return time.monotonic() - t0


# -- handler -------------------------------------------------------------------
class UpscaleHandler(JobHandler):
    kind = "upscale"
    capability = "upscale"

    def __init__(self, runner: SeedVR2 | None = None):
        self.runner = runner or SeedVR2()

    def availability(self) -> str | None:
        return self.runner.availability()

    def run(self, ctx: JobContext) -> list[ProducedOutput]:
        size, frame_w, frame_h = upscale_params(ctx.job.params)
        name = ctx.job.params.get("source") or next(iter(ctx.inputs_with(VIDEO_EXT)), None)
        if not name or name not in ctx.inputs:
            raise JobFailure("no source video to upscale", retryable=False)
        outs = ctx.job.outputs_with(VIDEO_EXT)
        if not outs:
            raise JobFailure("upscale needs one .mp4 output", retryable=False)
        src = ctx.inputs[name]
        info = media.probe(src)
        w, h = fit_size(info.width or 0, info.height or 0, frame_w, frame_h)
        raw = ctx.work_dir / "upscaled_raw.mp4"
        ctx.progress(0, 1, "upscaling", None)
        secs = self.runner.run(src, raw, min(w, h), lambda i, n, eta: ctx.progress(i, n, "upscaling", eta), ctx.check_cancel)
        ctx.check_cancel()
        # Exact frame size, the source's sound back, web-ready.
        out = ctx.output_path(outs[0].name)
        cmd = ["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-i", str(src), "-map", "0:v:0", "-map", "1:a:0?",
               "-vf", f"scale={w}:{h}:flags=lanczos", "-c:v", "libx264", "-preset", "medium", "-crf", "16", "-pix_fmt", "yuv420p",
               "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", str(out)]
        ctx.progress(1, 1, "finishing", 0)
        media._run(cmd)
        res = media.probe(out)
        ctx.stats.update(upscale={"size": size, "width": w, "height": h, "seconds": round(secs)})
        return [ProducedOutput(outs[0].name, out, res.width, res.height, res.fps, res.duration_sec)]
