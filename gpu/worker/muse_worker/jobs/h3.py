"""Job kind `h3`: MiniMax H3 Ref2VA character swap (plans/video-test-results.md, Tests 8-10).

Torch-free on purpose: the backend (real DiffSynth or fake) sits behind `H3Backend`,
so params, the frame rule, prompts, progress and ETA can be tested on CPU.
"""

from __future__ import annotations

import math
import secrets
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Protocol

from .. import media
from .base import IMAGE_EXT, VIDEO_EXT, JobContext, JobFailure, JobHandler, ProducedOutput
from .lipsync import LatentSync, lipsync_params

WIDTH, HEIGHT, FPS = 768, 1344, 24  # H3 native 768 short side, portrait
FIRST_SECONDS = 5.2
FIRST_FRAMES = 124  # 5.17 s, the tested length (124 % 17 == 5)
MAX_SECONDS = 15.0  # one H3 pass
MIN_FRAMES = 22  # smallest 17n+5 with n >= 1
STEPS_MIN, STEPS_MAX, STEPS_DEFAULT = 4, 30, 10
SECTION_ORDER = ("subject_definitions", "summary", "retention_analysis", "detailed_description")
# Measured: BF16 + FA3 on H100, 768x1344, 124 frames (Test 7).
SEC_PER_STEP_124 = 57.8
LIPSYNC_EST_S = 240.0  # LatentSync 3-6 min per clip (Test 4)


# -- pure helpers --------------------------------------------------------------
def trim_frames(n: int) -> int:
    """Largest frame count <= n with n % 17 == 5 (H3 rounds *up* otherwise, past the source's end)."""
    if n < MIN_FRAMES:
        raise JobFailure(f"source clip too short: {n} frames at {FPS} fps, need at least {MIN_FRAMES}", retryable=False)
    return n - ((n - 5) % 17)


def frames_for(use: str, available_frames: int, clip_seconds: float | None = None) -> int:
    cap = FIRST_FRAMES if use == "first" else int(MAX_SECONDS * FPS)
    if clip_seconds:
        cap = min(cap, int(math.floor(float(clip_seconds) * FPS + 1e-6)))
    return trim_frames(min(cap, available_frames))


def round_up_frames(n: int) -> int:
    """Smallest frame count >= n with n % 17 == 5."""
    return max(MIN_FRAMES, n + ((5 - n) % 17))


def frame_plan(use: str, available_frames: int, clip_seconds: float | None = None) -> tuple[int, int]:
    """(frames to render, frames to keep).

    "first" is a fixed 5.17 s sample, so it keeps the old trim-down rule. "full" keeps the whole clip:
    it renders up to the next valid count (the source is padded with its last frame) and the output is
    cut back to the source's real length, so a 6.2 s clip comes back 6.2 s, not 5.9 s.
    """
    if use == "first":
        n = frames_for(use, available_frames, clip_seconds)
        return n, n
    keep = min(int(MAX_SECONDS * FPS), available_frames)
    if clip_seconds:
        keep = min(keep, int(math.floor(float(clip_seconds) * FPS + 1e-6)))
    if keep < MIN_FRAMES:
        trim_frames(keep)  # raises the usual "too short" failure
    render = round_up_frames(keep)
    if render > int(MAX_SECONDS * FPS):  # don't go past one tested 15 s pass
        render = keep = trim_frames(keep)
    return render, keep


def build_prompt(sections: dict[str, Any]) -> str:
    """Join the structured H3 prompt (plans/prompt-system.md §2). Empty sections are dropped."""
    keys = [k for k in SECTION_ORDER if k in sections] + [k for k in sections if k not in SECTION_ORDER]
    parts = []
    for k in keys:
        v = sections.get(k)
        text = "\n".join(str(x) for x in v) if isinstance(v, list) else str(v or "")
        if text.strip():
            parts.append(f"{k}:\n{text.strip()}")
    return "\n\n".join(parts) + ("\n" if parts else "")


def _bool(v: Any, default: bool) -> bool:
    if v is None:
        return default
    if isinstance(v, bool):
        return v
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "yes", "on")
    return bool(v)


@dataclass
class H3Params:
    prompt: str
    steps: int
    use: str
    seeds: list[int]
    takes: int
    keep_audio: bool
    audio_source: str  # "source" (mux the original clip's audio) or "model" (H3's decoded audio)
    clip_seconds: float | None
    lip_sync: bool
    source: str | None
    references: list[str] | None

    @classmethod
    def from_job(cls, job) -> "H3Params":
        p = job.params

        def bad(msg):
            return JobFailure(msg, retryable=False)

        prompt = job.prompt or p.get("prompt")
        sections = p.get("promptSections") or p.get("sections")
        if not (isinstance(prompt, str) and prompt.strip()) and isinstance(sections, dict):
            prompt = build_prompt(sections)
        if not (isinstance(prompt, str) and prompt.strip()):
            raise bad("no prompt: send `prompt` or `params.promptSections`")

        steps = p.get("steps", job.steps)
        steps = STEPS_DEFAULT if steps is None else steps
        if not isinstance(steps, int) or isinstance(steps, bool) or not STEPS_MIN <= steps <= STEPS_MAX:
            raise bad(f"steps must be an integer {STEPS_MIN}-{STEPS_MAX}, got {steps!r}")

        use = p.get("use", p.get("clipLength", "first"))
        if use not in ("first", "full"):
            raise bad(f"use must be 'first' or 'full', got {use!r}")

        takes = p.get("takes", 1)
        if not isinstance(takes, int) or isinstance(takes, bool) or not 1 <= takes <= 4:
            raise bad(f"takes must be 1-4, got {takes!r}")

        seeds = p.get("seeds")
        if seeds is not None:
            if not (isinstance(seeds, list) and len(seeds) >= takes and all(isinstance(s, int) for s in seeds)):
                raise bad("seeds must be a list of integers, one per take")
            seeds = seeds[:takes]
        else:
            seed = p.get("seed", job.seed)
            if seed is None:
                seed = secrets.randbelow(2**31)
            if not isinstance(seed, int) or isinstance(seed, bool):
                raise bad(f"seed must be an integer, got {seed!r}")
            seeds = [seed + i for i in range(takes)]

        clip_seconds = p.get("clipSeconds")
        if clip_seconds is not None and (not isinstance(clip_seconds, (int, float)) or clip_seconds <= 0):
            raise bad("clipSeconds must be a positive number")

        audio_source = p.get("audioSource", "source")
        if audio_source not in ("source", "model"):
            raise bad("audioSource must be 'source' or 'model'")

        refs = p.get("references")
        if refs is not None and not (isinstance(refs, list) and all(isinstance(r, str) for r in refs)):
            raise bad("references must be a list of input names")

        return cls(
            prompt=prompt, steps=steps, use=use, seeds=seeds, takes=takes,
            keep_audio=_bool(p.get("keepAudio"), True), audio_source=audio_source,
            clip_seconds=clip_seconds, lip_sync=_bool(p.get("lipSync"), False), source=p.get("source"),
            references=refs,
        )


# -- backend interface ------------------------------------------------------------
@dataclass
class RenderRequest:
    source: Path
    references: list[Path]
    prompt: str
    steps: int
    seed: int
    num_frames: int
    keep_audio: bool
    audio_source: str
    out_path: Path
    work_dir: Path
    width: int = WIDTH
    height: int = HEIGHT
    fps: int = FPS
    keep_frames: int | None = None  # cut the output back to this many frames (source was padded)


@dataclass
class RenderResult:
    path: Path
    width: int
    height: int
    fps: float
    duration_sec: float
    frames: int
    stats: dict[str, Any] = field(default_factory=dict)


class BackendUnavailable(Exception):
    """The backend can't run on this pod (missing FA3, weights, ...). Not retryable here."""


class H3Backend(Protocol):
    def availability(self) -> str | None: ...
    def ensure_loaded(self) -> None: ...
    def source_frames(self, path: Path) -> int: ...
    def pad_source(self, path: Path, out: Path, seconds: float) -> Path: ...
    def render(self, req: RenderRequest, on_step: Callable[[int, int], None],
               check_cancel: Callable[[], None]) -> RenderResult: ...
    def thumbnail(self, video: Path, out: Path) -> tuple[int, int]: ...


def make_progress_cmd(on_step: Callable[[int, int], None], check_cancel: Callable[[], None],
                      sync: Callable[[], None] | None = None):
    """A `progress_bar_cmd` for DiffSynth pipelines (they call it like tqdm around the denoise loop).

    Checks for cancellation before each step and reports (step, total) after each one.
    `sync` (torch.cuda.synchronize) makes the step timing real instead of queued kernels.
    """

    class _Steps:
        def __init__(self, iterable, *args, **kwargs):
            self.iterable = iterable

        def __len__(self):
            return len(self.iterable)

        def __iter__(self):
            total = len(self.iterable)
            for i, x in enumerate(self.iterable):
                check_cancel()
                yield x
                if sync:
                    sync()
                on_step(i + 1, total)

    return _Steps


class Eta:
    """Remaining-time estimate across takes: measured step time once known, else the benchmark."""

    def __init__(self, steps: int, takes: int, frames: int, sec_per_step_124: float = SEC_PER_STEP_124,
                 overhead_per_take: float = 60.0, clock: Callable[[], float] = time.monotonic):
        self.steps, self.takes = steps, takes
        self.est_step = sec_per_step_124 * frames / FIRST_FRAMES
        self.overhead = overhead_per_take  # reference encode + VAE decode + mux, refined after take 1
        self.clock = clock
        self.step_times: list[float] = []
        self._t_take = self._t_step = clock()

    def take_started(self) -> None:
        self._t_take = self._t_step = self.clock()

    def step_done(self) -> None:
        now = self.clock()
        self.step_times.append(now - self._t_step)
        self._t_step = now

    def take_done(self, steps_in_take: int) -> None:
        total = self.clock() - self._t_take
        stepped = sum(self.step_times[-steps_in_take:]) if steps_in_take else 0.0
        self.overhead = max(0.0, total - stepped)

    @property
    def sec_per_step(self) -> float:
        recent = self.step_times[-5:]
        return sum(recent) / len(recent) if recent else self.est_step

    def remaining(self, take_index: int, step: int) -> float:
        later_takes = self.takes - take_index - 1
        steps_left = (self.steps - step) + later_takes * self.steps
        return steps_left * self.sec_per_step + (later_takes + 0.5) * self.overhead


# -- handler ----------------------------------------------------------------------
class H3Handler(JobHandler):
    kind = "h3"
    capability = "h3"

    def __init__(self, backend: H3Backend, sec_per_step_124: float = SEC_PER_STEP_124,
                 lipsync: LatentSync | None = None):
        self.backend = backend
        self.sec_per_step_124 = sec_per_step_124
        self.lipsync = lipsync

    def availability(self) -> str | None:
        return self.backend.availability()

    def prepare(self) -> None:
        self.backend.ensure_loaded()

    def _pick_inputs(self, ctx: JobContext, p: H3Params) -> tuple[Path, list[Path]]:
        names = [i.name for i in ctx.job.inputs]
        if p.source:
            src = p.source
        else:
            cands = [n for n in names if n.lower().startswith("source")] or ctx.inputs_with(VIDEO_EXT)
            if not cands:
                raise JobFailure("no source video among the inputs", retryable=False)
            src = cands[0]
        if src not in ctx.inputs:
            raise JobFailure(f"source input {src!r} not found", retryable=False)
        refs = p.references if p.references is not None else [n for n in ctx.inputs_with(IMAGE_EXT) if n != src]
        missing = [r for r in refs if r not in ctx.inputs]
        if missing:
            raise JobFailure(f"reference inputs not found: {missing}", retryable=False)
        if not refs:
            raise JobFailure("no reference images among the inputs", retryable=False)
        return ctx.inputs[src], [ctx.inputs[r] for r in refs]

    def run(self, ctx: JobContext) -> list[ProducedOutput]:
        p = H3Params.from_job(ctx.job)
        source, refs = self._pick_inputs(ctx, p)
        videos, images = ctx.job.outputs_with(VIDEO_EXT), ctx.job.outputs_with(IMAGE_EXT)
        if len(videos) < p.takes:
            raise JobFailure(f"{p.takes} take(s) need {p.takes} video output(s), got {len(videos)}", retryable=False)
        if p.lip_sync:  # check before spending GPU time on the render
            reason = self.lipsync.availability() if self.lipsync else "not enabled on this pod"
            if reason:
                raise JobFailure(f"lip sync requested but {reason}", retryable=False)
            ls_guidance, ls_steps = lipsync_params(ctx.job.params, prefix="lipSync")

        ctx.progress(0, p.steps, "loading", None, take=1, takes=p.takes)
        try:
            self.backend.ensure_loaded()
        except BackendUnavailable as e:
            raise JobFailure(str(e), retryable=False) from None
        ctx.check_cancel()

        frames, keep = frame_plan(p.use, self.backend.source_frames(source), p.clip_seconds)
        if frames > keep:
            source = self.backend.pad_source(source, ctx.work_dir / "source_padded.mp4", (frames - keep) / FPS + 0.5)
        eta = Eta(p.steps, p.takes, frames, self.sec_per_step_124,
                  overhead_per_take=60.0 + (LIPSYNC_EST_S if p.lip_sync else 0.0))
        ctx.log.info("h3 job %s: %d frames rendered, %d kept (%.2fs), %d steps, %d take(s), seeds %s, keepAudio=%s",
                     ctx.job.id, frames, keep, keep / FPS, p.steps, p.takes, p.seeds, p.keep_audio)
        ctx.stats.update(frames=frames, keptFrames=keep, steps=p.steps, seeds=p.seeds, takes=[])

        produced: list[ProducedOutput] = []
        for k in range(p.takes):
            ctx.check_cancel()
            eta.take_started()
            extra = {"take": k + 1, "takes": p.takes}
            ctx.progress(0, p.steps, "preparing", eta.remaining(k, 0), **extra)

            def on_step(i: int, total: int, k=k, extra=extra) -> None:
                eta.step_done()
                phase = "decoding" if i >= total else "denoising"
                ctx.progress(i, total, phase, eta.remaining(k, i), **extra)

            req = RenderRequest(
                source=source, references=refs, prompt=p.prompt, steps=p.steps, seed=p.seeds[k],
                num_frames=frames, keep_frames=keep if keep < frames else None, keep_audio=p.keep_audio, audio_source=p.audio_source,
                out_path=ctx.output_path(videos[k].name), work_dir=ctx.work_dir,
            )
            res = self.backend.render(req, on_step, ctx.check_cancel)
            if p.lip_sync:
                ctx.progress(p.steps, p.steps, "lip sync", eta.remaining(k, p.steps), **extra)
                res = self._lip_sync(ctx, req, res, ls_guidance, ls_steps, k)
            eta.take_done(p.steps)
            produced.append(ProducedOutput(videos[k].name, res.path, res.width, res.height, res.fps, res.duration_sec))
            if k < len(images):
                thumb = ctx.output_path(images[k].name)
                w, h = self.backend.thumbnail(res.path, thumb)
                produced.append(ProducedOutput(images[k].name, thumb, w, h))
            ctx.stats["takes"].append({"seed": p.seeds[k], **res.stats})
        return produced

    def _lip_sync(self, ctx: JobContext, req: RenderRequest, res: RenderResult, guidance: float, steps: int,
                  k: int) -> RenderResult:
        """LatentSync pass on a finished take, re-synced to the source clip's own audio.

        LatentSync resamples to 25 fps and trims ~0.2 s at the end (Test 4). The original audio is put
        back afterwards (or none, if keepAudio is off) at the lip-synced length.
        """
        wav = ctx.work_dir / f"lipsync_audio_{k + 1}.wav"
        media.extract_audio_wav(req.source, wav, sample_rate=16000, channels=1, duration_sec=res.duration_sec)
        synced = ctx.work_dir / f"lipsync_{k + 1}.mp4"
        secs = self.lipsync.run(res.path, wav, synced, guidance, steps, lambda i, n, eta: None, ctx.check_cancel)
        info = media.probe(synced)
        dur = min(info.duration_sec or res.duration_sec, res.duration_sec)
        media.finalize_video(synced, res.path, audio_from=req.source if req.keep_audio else None, duration_sec=dur)
        info = media.probe(res.path)
        stats = {**res.stats, "lipsync": {"guidance": guidance, "steps": steps, "seconds": round(secs)}}
        return RenderResult(path=res.path, width=info.width or res.width, height=info.height or res.height,
                            fps=info.fps or 25.0, duration_sec=info.duration_sec or dur, frames=res.frames,
                            stats=stats)
