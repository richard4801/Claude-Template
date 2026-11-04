"""LatentSync 1.6 lip sync in its own venv (torch 2.5.1), as in pipeline/runpod/latentsync_infer.sh.

Used two ways: as the job kind `lipsync`, and as the optional post-pass of an `h3` job
(`params.lipSync: true`, which the API sends for talking or singing clips).
Enabled only when the LatentSync checkout, checkpoint and venv exist on the volume.
Untested inside the worker; the shell script it wraps ran on an RTX 4090 (Test 4).
"""

from __future__ import annotations

import os
import re
import subprocess
import time
from collections import deque
from pathlib import Path
from typing import Callable

from .. import media
from .base import AUDIO_EXT, VIDEO_EXT, JobContext, JobFailure, JobHandler, ProducedOutput

_TQDM = re.compile(r"(\d+)/(\d+) \[")
GUIDANCE_DEFAULT, STEPS_DEFAULT = 1.5, 20  # tested range 1.5-2.0, 20 steps


def lipsync_params(p: dict, prefix: str = "") -> tuple[float, int]:
    """(guidance, steps). Standalone jobs use `guidance`/`steps`; inside an h3 job `lipSyncGuidance`/`lipSyncSteps`."""
    def num(key, default, lo, hi, integer=False):
        v = p.get(key)
        v = default if v is None else v
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not lo <= v <= hi or (integer and int(v) != v):
            raise JobFailure(f"{key} must be {'an integer ' if integer else ''}{lo}-{hi}, got {v!r}", retryable=False)
        return int(v) if integer else float(v)

    g, s = (f"{prefix}Guidance", f"{prefix}Steps") if prefix else ("guidance", "steps")
    return num(g, GUIDANCE_DEFAULT, 1.0, 3.0), num(s, STEPS_DEFAULT, 10, 50, integer=True)


class LatentSync:
    def __init__(self, root: str | Path | None = None, python: str | Path | None = None):
        self.root = Path(root or os.environ.get("LATENTSYNC_DIR", "/workspace/LatentSync"))
        self.python = Path(python or os.environ.get("LATENTSYNC_PYTHON", "/workspace/venvs/latentsync/bin/python"))

    def availability(self) -> str | None:
        need = [self.root / "scripts/inference.py", self.root / "checkpoints/latentsync_unet.pt",
                self.root / "configs/unet/stage2_512.yaml", self.python]
        missing = [str(p) for p in need if not p.exists()]
        return f"not enabled on this pod (LatentSync missing: {', '.join(missing)})" if missing else None

    def _env(self) -> dict[str, str]:
        env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "VIRTUAL_ENV", "PYTHONHOME")}
        # The H3 venv's cu13 libs (added by bootstrap.sh) must not leak into torch 2.5.1.
        env["LD_LIBRARY_PATH"] = os.environ.get("MUSE_ORIG_LD_LIBRARY_PATH", "")
        env["PATH"] = f"{self.python.parent}:{env.get('PATH', '')}"
        return env

    def run(self, video: Path, audio: Path, out: Path, guidance: float, steps: int,
            on_progress: Callable[[int, int, float | None], None], check_cancel: Callable[[], None]) -> float:
        """Lip-sync `video` to `audio` into `out`. Returns the seconds it took."""
        cmd = [str(self.python), "-m", "scripts.inference",
               "--unet_config_path", "configs/unet/stage2_512.yaml",
               "--inference_ckpt_path", "checkpoints/latentsync_unet.pt",
               "--inference_steps", str(steps), "--guidance_scale", str(guidance), "--enable_deepcache",
               "--video_path", str(video), "--audio_path", str(audio), "--video_out_path", str(out)]
        t0 = time.monotonic()
        tail: deque[str] = deque(maxlen=30)
        proc = subprocess.Popen(cmd, cwd=self.root, env=self._env(), stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, bufsize=0)
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
            raise JobFailure(f"LatentSync exited {code}: {' | '.join(list(tail)[-5:])[-400:]}", retryable=True)
        return time.monotonic() - t0


class LatentSyncHandler(JobHandler):
    kind = "lipsync"
    capability = "latentsync"

    def __init__(self, runner: LatentSync | None = None):
        self.runner = runner or LatentSync()

    def availability(self) -> str | None:
        return self.runner.availability()

    def run(self, ctx: JobContext) -> list[ProducedOutput]:
        p = ctx.job.params
        guidance, steps = lipsync_params(p)
        video_name = p.get("video") or next(iter(ctx.inputs_with(VIDEO_EXT)), None)
        if not video_name or video_name not in ctx.inputs:
            raise JobFailure("no video input for lip sync", retryable=False)
        outs = ctx.job.outputs_with(VIDEO_EXT)
        if not outs:
            raise JobFailure("lip sync needs one .mp4 output", retryable=False)
        audio_name = p.get("audio") or next(iter(ctx.inputs_with(AUDIO_EXT)), None)
        if audio_name:
            if audio_name not in ctx.inputs:
                raise JobFailure(f"audio input {audio_name!r} not found", retryable=False)
            audio = ctx.inputs[audio_name]
        else:  # re-sync to the clip's own audio
            audio = ctx.work_dir / "audio.wav"
            media.extract_audio_wav(ctx.inputs[video_name], audio, sample_rate=16000, channels=1)

        out = ctx.output_path(outs[0].name)
        ctx.progress(0, steps, "lip sync", 240)
        secs = self.runner.run(ctx.inputs[video_name], audio, out, guidance, steps,
                               lambda i, n, eta: ctx.progress(i, n, "lip sync", eta), ctx.check_cancel)
        info = media.probe(out)
        ctx.stats.update(lipsync={"guidance": guidance, "steps": steps, "seconds": round(secs)})
        return [ProducedOutput(outs[0].name, out, info.width, info.height, info.fps, info.duration_sec)]
