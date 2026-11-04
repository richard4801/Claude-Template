"""A stand-in for H3 with no torch: steps are sleeps, outputs are synthetic.

Used by the tests and by `--dry-run`. With `make_video=True` (and ffmpeg) it writes a real
768x1344 24 fps test-pattern MP4 of the right length, so the API can probe and store it.
"""

from __future__ import annotations

import hashlib
import threading
import time
from pathlib import Path
from typing import Callable

from .. import media
from ..jobs.h3 import FPS, HEIGHT, WIDTH, RenderRequest, RenderResult, make_progress_cmd


class FakeH3Backend:
    def __init__(self, step_seconds: float = 0.05, source_seconds: float = 10.0, make_video: bool = False,
                 load_seconds: float = 0.0, fail_at_step: int | None = None, error: BaseException | None = None,
                 unavailable: str | None = None):
        self.step_seconds = step_seconds
        self.source_seconds = source_seconds
        self.make_video = make_video and media.have_ffmpeg()
        self.load_seconds = load_seconds
        self.fail_at_step = fail_at_step
        self.error = error
        self.unavailable = unavailable
        self.loaded = False
        self.loads = 0
        self.renders: list[RenderRequest] = []
        self._lock = threading.Lock()

    def availability(self) -> str | None:
        return self.unavailable

    def ensure_loaded(self) -> None:
        with self._lock:
            if not self.loaded:
                time.sleep(self.load_seconds)
                self.loads += 1
                self.loaded = True

    def source_frames(self, path: Path) -> int:
        if self.make_video:
            try:
                d = media.probe(path).duration_sec
                if d:
                    return int(d * FPS)
            except media.MediaError:
                pass
        return int(self.source_seconds * FPS)

    def render(self, req: RenderRequest, on_step: Callable[[int, int], None],
               check_cancel: Callable[[], None]) -> RenderResult:
        self.renders.append(req)
        fail_at, error = self.fail_at_step, self.error

        def step(i: int, total: int) -> None:
            if fail_at is not None and i >= fail_at:
                raise error or RuntimeError(f"fake failure at step {i}")
            on_step(i, total)

        for _ in make_progress_cmd(step, check_cancel)(range(req.steps)):
            time.sleep(self.step_seconds)
        check_cancel()
        if self.make_video:
            media.make_test_video(req.out_path, WIDTH, HEIGHT, FPS, req.num_frames, req.keep_audio)
        else:
            seed = hashlib.sha256(f"{req.seed}:{req.prompt}:{req.num_frames}".encode()).digest()
            req.out_path.write_bytes(b"FAKEMP4" + seed * 64)
        return RenderResult(path=req.out_path, width=WIDTH, height=HEIGHT, fps=float(FPS),
                            duration_sec=round((req.keep_frames or req.num_frames) / FPS, 3), frames=req.keep_frames or req.num_frames,
                            stats={"attention": "fake", "steps": req.steps})

    def pad_source(self, path: Path, out: Path, seconds: float) -> Path:
        self.padded_seconds = seconds
        return path

    def thumbnail(self, video: Path, out: Path) -> tuple[int, int]:
        if self.make_video:
            info = media.thumbnail(video, out)
            return info.width or WIDTH, info.height or HEIGHT
        out.write_bytes(b"\xff\xd8FAKEJPEG\xff\xd9")
        return WIDTH, HEIGHT
