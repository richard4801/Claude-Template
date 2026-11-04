"""Real H3 Ref2VA backend: `pipeline/runpod/h3_ref2va_run.py` as a load-once, render-many object.

Same model files, VRAM config, reference layout (video_audio + images) and attention setup
as the tested script (plans/video-test-results.md Tests 7-10), plus:
  * the pipeline stays loaded between jobs;
  * a per-step callback (progress) and cancellation via `progress_bar_cmd`;
  * frame count trimmed down to n % 17 == 5 so H3 never pads past the end of the clip;
  * FlashAttention 3 via kernels-community/flash-attn3, loudly checked;
  * VRAM headroom 30 GB by default (the full 9.4 s clip OOMed with less).

Untested on a GPU as a module: only the original script has run on an H100.

Manual use on a pod (like the old script, but with this code path):
  python -m muse_worker.backends.diffsynth_h3 --inputs inputs --prompt-file prompt.txt --steps 10 --out outputs/h3.mp4
"""

from __future__ import annotations

import glob
import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Callable

from .. import media
from ..jobs.h3 import FPS, BackendUnavailable, RenderRequest, RenderResult, make_progress_cmd, trim_frames

log = logging.getLogger("muse.h3")

FA3_REPO = "kernels-community/flash-attn3"
FA_IMPLS = ("customized_fa_kernel", "flash_attention_3", "flash_attention_4")
OUTPUT_AUDIO_SR = 32000  # as in the tested script


def _dit_path(models: Path, variant: str):
    if variant == "bf16":
        shards = sorted(glob.glob(f"{models}/h3/Ref2VA/transformer/model*.safetensors"))
        return shards or None
    rel = {
        "pruned_fp8": "comfy/diffusion_models/minimax_h3_ref2va_pruned_fp8_scaled.safetensors",
        "int8": "comfy/diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors",
    }.get(variant)
    if rel is None:
        raise BackendUnavailable(f"unknown H3 variant {variant!r} (bf16, pruned_fp8, int8)")
    p = models / rel
    return str(p) if p.exists() else None


def required_files(models: Path, variant: str = "bf16") -> dict[str, bool]:
    return {
        f"transformer ({variant})": bool(_dit_path(models, variant)),
        "text encoder (nf4)": (models / "nf4/minimax-h3-text-encoder-nf4.safetensors").exists(),
        "video vae": (models / "h3/Ref2VA/video_vae/source/model.safetensors").exists(),
        "audio vae": (models / "h3/Ref2VA/audio_vae/model.safetensors").exists(),
        "processor": (models / "h3/Ref2VA/processor").is_dir() and any((models / "h3/Ref2VA/processor").iterdir()),
    }


class DiffSynthH3Backend:
    def __init__(self, models_dir: str | Path = "/workspace/models", variant: str = "bf16",
                 vram_headroom_gb: float = 30.0, require_fa3: bool = True):
        self.models = Path(models_dir)
        self.variant = variant
        self.headroom = vram_headroom_gb
        self.require_fa3 = require_fa3
        self.pipe = None
        self.attention = "unknown"
        self.load_seconds: float | None = None
        self._lock = threading.Lock()
        self._load_error: BaseException | None = None
        self._torch = None

    @classmethod
    def from_env(cls) -> "DiffSynthH3Backend":
        return cls(
            models_dir=os.environ.get("MUSE_MODELS_DIR", "/workspace/models"),
            variant=os.environ.get("MUSE_H3_VARIANT", "bf16"),
            vram_headroom_gb=float(os.environ.get("VRAM_HEADROOM_GB", "30")),
            require_fa3=os.environ.get("MUSE_REQUIRE_FA3", "1") == "1",
        )

    # -- availability / loading -------------------------------------------------
    def availability(self) -> str | None:
        import importlib.util

        if importlib.util.find_spec("diffsynth") is None or importlib.util.find_spec("torch") is None:
            return "not enabled on this pod (DiffSynth/torch not installed)"
        missing = [k for k, ok in required_files(self.models, self.variant).items() if not ok]
        if missing:
            return f"not enabled on this pod (H3 weights missing in {self.models}: {', '.join(missing)})"
        return None

    def ensure_loaded(self) -> None:
        with self._lock:
            if self.pipe is not None:
                return
            if self._load_error is not None:
                raise BackendUnavailable(f"H3 failed to load earlier: {self._load_error}")
            try:
                self._load()
            except BackendUnavailable as e:
                self._load_error = e
                raise
            except Exception as e:  # keep the reason; every later job fails fast with it
                log.exception("H3 pipeline load failed")
                self._load_error = e
                raise BackendUnavailable(f"H3 pipeline load failed: {type(e).__name__}: {e}") from e

    @staticmethod
    def _probe_fa3_kernel() -> str | None:
        """DiffSynth swallows kernel load errors; load it ourselves first to log the real reason."""
        try:
            from kernels import get_kernel

            get_kernel(os.environ["DIFFSYNTH_FLASH_ATTN_KERNEL_REPO_ID"],
                       version=int(os.environ["DIFFSYNTH_FLASH_ATTN_KERNEL_VERSION"]))
            return None
        except Exception as e:
            return f"{type(e).__name__}: {e}"

    def _load(self) -> None:
        # Must be set before diffsynth is imported (it picks the attention backend at import time).
        os.environ.setdefault("DIFFSYNTH_FLASH_ATTN_KERNEL_REPO_ID", FA3_REPO)
        os.environ.setdefault("DIFFSYNTH_FLASH_ATTN_KERNEL_VERSION", "1")
        os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")
        # LD_LIBRARY_PATH (nvidia/cu13/lib) only works if set before the process starts: bootstrap.sh does it.
        t0 = time.time()
        import torch

        if not torch.cuda.is_available():
            raise BackendUnavailable("CUDA is not available on this pod")
        torch.backends.cuda.enable_cudnn_sdp(False)  # cu130 cuDNN SDPA has no engine for H3's masked attention
        kernel_err = self._probe_fa3_kernel()

        from diffsynth.core.attention.attention import ATTENTION_IMPLEMENTATION
        from diffsynth.pipelines.minimax_h3_audio_video import MiniMaxH3Pipeline, ModelConfig

        self.attention = ATTENTION_IMPLEMENTATION
        if ATTENTION_IMPLEMENTATION not in FA_IMPLS:
            banner = (
                "\n" + "!" * 78 +
                f"\n!! FLASHATTENTION 3 IS NOT ACTIVE (attention={ATTENTION_IMPLEMENTATION})."
                f"\n!! H3 would run ~1.63x slower (94.5 s/step instead of 57.8)."
                f"\n!! kernel {os.environ['DIFFSYNTH_FLASH_ATTN_KERNEL_REPO_ID']}: {kernel_err or 'loaded but not selected'}"
                + ("\n!! Refusing H3 jobs (set MUSE_REQUIRE_FA3=0 to run slowly anyway)." if self.require_fa3 else
                   "\n!! MUSE_REQUIRE_FA3=0: running anyway, SLOWLY.")
                + "\n" + "!" * 78
            )
            log.error(banner)
            if self.require_fa3:
                raise BackendUnavailable(f"FlashAttention 3 not active on this pod (attention={ATTENTION_IMPLEMENTATION}"
                                         f"{'; ' + kernel_err if kernel_err else ''})")
        else:
            log.info("attention implementation: %s (FlashAttention 3 kernel %s)", ATTENTION_IMPLEMENTATION,
                     os.environ["DIFFSYNTH_FLASH_ATTN_KERNEL_REPO_ID"])

        dit = _dit_path(self.models, self.variant)
        if not dit:
            raise BackendUnavailable(f"H3 {self.variant} transformer weights missing under {self.models}")
        bf16 = torch.bfloat16
        vram = dict(offload_dtype=bf16, offload_device="cpu", onload_dtype=bf16, onload_device="cpu",
                    preparing_dtype=bf16, preparing_device="cuda", computation_dtype=bf16, computation_device="cuda")
        total_gb = torch.cuda.mem_get_info("cuda")[1] / (1024 ** 3)
        m = self.models
        self.pipe = MiniMaxH3Pipeline.from_pretrained(
            torch_dtype=bf16, device="cuda",
            model_configs=[
                ModelConfig(path=dit, **vram),
                ModelConfig(path=f"{m}/nf4/minimax-h3-text-encoder-nf4.safetensors", **vram),
                ModelConfig(path=f"{m}/h3/Ref2VA/video_vae/source/model.safetensors", **vram),
                ModelConfig(path=f"{m}/h3/Ref2VA/audio_vae/model.safetensors", **vram),
            ],
            processor_config=ModelConfig(path=f"{m}/h3/Ref2VA/processor/"),
            vram_limit=total_gb - self.headroom,
        )
        self._torch = torch
        self.load_seconds = round(time.time() - t0, 1)
        log.info("H3 %s loaded in %.0fs on %s (%.0f GB, vram_limit %.0f GB)", self.variant, self.load_seconds,
                 torch.cuda.get_device_name(0), total_gb, total_gb - self.headroom)

    # -- per job --------------------------------------------------------------------
    def source_frames(self, path: Path) -> int:
        info = media.probe(path)
        if not info.duration_sec:
            raise BackendUnavailable(f"cannot read the duration of {path.name}")
        return int(info.duration_sec * FPS)

    def pad_source(self, path: Path, out: Path, seconds: float) -> Path:
        media.pad_video(path, out, seconds)
        return out

    def thumbnail(self, video: Path, out: Path) -> tuple[int, int]:
        info = media.thumbnail(video, out)
        return info.width or 0, info.height or 0

    def _read_source(self, req: RenderRequest):
        from diffsynth.utils.data.audio import read_audio
        from diffsynth.utils.data.audio_video import read_video_audio

        sr = self.pipe.audio_vae.sample_rate
        video, audio, audio_sr = read_video_audio(str(req.source), height=req.height, width=req.width,
                                                  num_frames=req.num_frames, fps=req.fps, audio_sample_rate=sr)
        n = trim_frames(len(video))  # frame resampling can return fewer frames than asked
        video = video[:n]
        if audio is None:
            # torchcodec sometimes returns no audio (0.17 always did): fall back to ffmpeg, as the script did.
            wav = req.work_dir / "source.wav"
            try:
                media.extract_audio_wav(req.source, wav)
                audio, audio_sr = read_audio(str(wav), duration=n / req.fps, resample=True, resample_rate=sr)
            except Exception as e:
                log.warning("source has no readable audio (%s); using silence", e)
                audio, audio_sr = self._torch.zeros(2, int(round(n / req.fps * sr))), sr
        else:
            audio = audio[..., : int(round(n / req.fps * audio_sr))]
        return video, audio, audio_sr, n

    def render(self, req: RenderRequest, on_step: Callable[[int, int], None],
               check_cancel: Callable[[], None]) -> RenderResult:
        from PIL import Image
        from diffsynth.utils.data.audio_video import write_video_audio

        if self.pipe is None:
            self.ensure_loaded()
        torch = self._torch
        video_ref, audio_ref, audio_sr, n = self._read_source(req)
        refs = [{"type": "video_audio", "video": video_ref, "audio": audio_ref, "sample_rate": audio_sr}]
        refs += [{"type": "image", "image": Image.open(p).convert("RGB")} for p in req.references]

        step_times: list[float] = []
        last = [time.time()]

        def timed_step(i: int, total: int) -> None:
            now = time.time()
            step_times.append(round(now - last[0], 1))
            last[0] = now
            log.info("STEP %d/%d %.1fs", i, total, step_times[-1])
            on_step(i, total)

        torch.cuda.reset_peak_memory_stats()
        t0 = time.time()
        video, audio = self.pipe(
            prompt=req.prompt, height=req.height, width=req.width, num_frames=n,
            num_inference_steps=req.steps, seed=req.seed, references=refs,
            progress_bar_cmd=make_progress_cmd(timed_step, check_cancel, torch.cuda.synchronize),
        )
        gen_s = time.time() - t0
        check_cancel()

        raw = req.work_dir / f"{req.out_path.stem}.raw.mp4"
        write_video_audio(video=video, audio=audio, output_path=str(raw), fps=req.fps,
                          audio_sample_rate=OUTPUT_AUDIO_SR)
        duration = len(video) / req.fps
        if req.keep_frames:
            duration = min(duration, req.keep_frames / req.fps)
        if not req.keep_audio:
            audio_from = None
        elif req.audio_source == "source":
            audio_from = req.source  # the original clip's sound, exactly
        else:
            audio_from = raw  # H3's own decoded audio (fully_copy)
        media.finalize_video(raw, req.out_path, audio_from=audio_from, duration_sec=duration)
        raw.unlink(missing_ok=True)
        info = media.probe(req.out_path)

        stats = dict(variant=self.variant, attention=self.attention, gpu=torch.cuda.get_device_name(0),
                     size=f"{req.width}x{req.height}", frames=n, steps=req.steps, gen_s=round(gen_s),
                     load_s=self.load_seconds, step_times_s=step_times,
                     peak_vram_gb=round(torch.cuda.max_memory_allocated() / 1e9, 1))
        log.info("STATS %s", json.dumps(stats))
        return RenderResult(path=req.out_path, width=info.width or req.width, height=info.height or req.height,
                            fps=info.fps or req.fps, duration_sec=info.duration_sec or round(duration, 3),
                            frames=len(video), stats=stats)


def _cli() -> int:
    """Run one render without the API, from a folder laid out like the old script's `inputs/`."""
    import argparse

    from ..jobs.h3 import frame_plan

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--inputs", default="inputs", help="folder with source.mp4 and the reference images")
    ap.add_argument("--refs", nargs="*", default=["face_front.jpg", "face_side.jpg", "body_front.jpg",
                                                  "body_threequarter.jpg", "body_back.jpg"])
    ap.add_argument("--prompt-file", required=True)
    ap.add_argument("--variant", default="bf16", choices=["bf16", "pruned_fp8", "int8"])
    ap.add_argument("--steps", type=int, default=10)
    ap.add_argument("--use", default="first", choices=["first", "full"])
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--no-audio", action="store_true")
    ap.add_argument("--out", default="outputs/h3.mp4")
    a = ap.parse_args()
    logging.basicConfig(level="INFO", format="%(asctime)s %(levelname)s %(message)s")
    b = DiffSynthH3Backend.from_env()
    b.variant = a.variant
    b.ensure_loaded()
    src = Path(a.inputs) / "source.mp4"
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    req = RenderRequest(source=src, references=[Path(a.inputs) / r for r in a.refs],
                        prompt=Path(a.prompt_file).read_text(), steps=a.steps, seed=a.seed,
                        num_frames=frame_plan(a.use, b.source_frames(src))[0], keep_audio=not a.no_audio,
                        audio_source="source", out_path=out, work_dir=out.parent)
    res = b.render(req, lambda i, t: None, lambda: None)
    print("DONE", res.path, json.dumps(res.stats))
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
