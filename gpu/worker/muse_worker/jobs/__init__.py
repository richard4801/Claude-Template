"""Job handlers by kind. `h3` is the main engine; the others are optional or not built yet."""

from __future__ import annotations

from .base import DisabledHandler, JobHandler
from .h3 import H3Backend, H3Handler
from .lipsync import LatentSync, LatentSyncHandler
from .upscale import SeedVR2, UpscaleHandler

NOT_ON_POD = "not enabled on this pod"


def build_handlers(h3_backend: H3Backend, *, lipsync: bool = True) -> list[JobHandler]:
    ls = LatentSync() if lipsync else None  # also the optional post-pass of h3 jobs (params.lipSync)
    return [
        H3Handler(h3_backend, lipsync=ls),
        LatentSyncHandler(ls) if ls else DisabledHandler("lipsync", "latentsync", NOT_ON_POD),
        # Viggle-Animate needs >80 GB VRAM (H200 NVL) and its own diffusers pin: not on the H100 pod.
        DisabledHandler("viggle", "viggle", NOT_ON_POD),
        DisabledHandler("lora-train", "lora-train", "not enabled yet"),
        # Upscale (SeedVR2): enabled only when its checkout and venv are on the volume (jobs/upscale.py).
        UpscaleHandler(SeedVR2()),
    ]
