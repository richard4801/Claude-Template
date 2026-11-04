"""ffmpeg/ffprobe helpers (probe, audio mux, thumbnails, test clips)."""

from __future__ import annotations

import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


class MediaError(Exception):
    pass


@dataclass
class MediaInfo:
    width: int | None
    height: int | None
    fps: float | None
    duration_sec: float | None
    has_audio: bool


def have_ffmpeg() -> bool:
    return bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))


def _run(cmd: list[str], timeout: float = 600) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise MediaError(f"{cmd[0]} failed: {e}") from None
    if out.returncode != 0:
        raise MediaError(f"{cmd[0]} exited {out.returncode}: {out.stderr.strip()[-500:]}")
    return out.stdout


def _rate(s: str | None) -> float | None:
    if not s or s in ("0/0",):
        return None
    if "/" in s:
        n, d = s.split("/", 1)
        return round(float(n) / float(d), 3) if float(d) else None
    return float(s)


def probe(path: Path) -> MediaInfo:
    data = json.loads(_run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)], 60))
    streams = data.get("streams", [])
    v = next((s for s in streams if s.get("codec_type") == "video"), {})
    has_audio = any(s.get("codec_type") == "audio" for s in streams)
    dur = v.get("duration") or data.get("format", {}).get("duration")
    return MediaInfo(
        width=v.get("width"),
        height=v.get("height"),
        fps=_rate(v.get("avg_frame_rate") or v.get("r_frame_rate")),
        duration_sec=round(float(dur), 3) if dur else None,
        has_audio=has_audio,
    )


def finalize_video(raw: Path, out: Path, *, audio_from: Path | None, duration_sec: float) -> None:
    """Copy the rendered video stream and attach audio from `audio_from` (or none), web-ready."""
    cmd = ["ffmpeg", "-v", "error", "-y", "-i", str(raw)]
    if audio_from is not None:
        cmd += ["-i", str(audio_from), "-map", "0:v:0", "-map", "1:a:0?", "-c:a", "aac", "-b:a", "192k"]
    else:
        cmd += ["-map", "0:v:0", "-an"]
    cmd += ["-c:v", "copy", "-t", f"{duration_sec:.3f}", "-movflags", "+faststart", str(out)]
    _run(cmd)


def extract_audio_wav(src: Path, out: Path, sample_rate: int | None = None, channels: int = 2,
                      duration_sec: float | None = None) -> None:
    cmd = ["ffmpeg", "-v", "error", "-y", "-i", str(src), "-vn", "-ac", str(channels)]
    if sample_rate:
        cmd += ["-ar", str(sample_rate)]
    if duration_sec:
        cmd += ["-t", f"{duration_sec:.3f}"]
    _run(cmd + [str(out)])


def thumbnail(video: Path, out: Path) -> MediaInfo:
    _run(["ffmpeg", "-v", "error", "-y", "-i", str(video), "-frames:v", "1", "-q:v", "3", str(out)])
    return probe(out)


def make_test_video(out: Path, width: int, height: int, fps: int, frames: int, with_audio: bool) -> None:
    """A synthetic clip (test pattern + tone) for --dry-run outputs. No real footage."""
    cmd = ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=size={width}x{height}:rate={fps}"]
    if with_audio:
        cmd += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"]
    cmd += ["-frames:v", str(frames), "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
    if with_audio:
        cmd += ["-c:a", "aac", "-shortest"]
    _run(cmd + ["-movflags", "+faststart", str(out)])
