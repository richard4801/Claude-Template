# SeedVR2 timing run, 2026-11-08 (owner-approved, $5 cap)

**Spent: about $0.91 in all** (RunPod billing hadn't posted yet; this is the per-hour rates × run times):
- CPU install pod: 11:28:35–11:35:11 UTC, $0.12/h → $0.013
- H100 80GB HBM3 (secure, US-CA-2, the only GPU in stock there): 11:35:12–11:48:38 UTC, $3.99/h → $0.893
- CPU pod to read the logs: 11:48:59–11:49:37 UTC, $0.06/h → $0.001
- No pods are left running. The install stays on `muse-models` (+7.3 GB, ~$0.51/month); `df` after: 28 GB free of 215.

**Setup:** numz ComfyUI-SeedVR2_VideoUpscaler at `4490bd1f`, torch 2.11.0+cu128, `seedvr2_ema_3b_fp16` + `ema_vae_fp16`,
SDPA attention (no flash-attn / sage installed), driver 595.91 / CUDA 13.2. Input: 5.0 s, 432 × 768 (Standard 768P),
24 fps, 120 frames. One CLI process per size, as a worker job runs it (`gpu/worker` `DEFAULT_CMD`).

| Size | Output | Wall (s) | GPU-s per output s | Start-up* | Encode | Upscale (DiT) | Decode | Post |
|---|---|---|---|---|---|---|---|---|
| 1080p (batch 21) | 1080 × 1920 × 120 | 193.6 | **38.7** | ~65 s (cold volume) | 19 s | 24 s | 38 s | 7 s |
| 2K (batch 21, tiled VAE) | 1440 × 2560 × 120 | 198.8 | **39.8** | ~20 s (warm) | 32 s | 29 s | 73 s | 21 s |
| 4K (batch 9, tiled VAE) | 2160 × 3840 × 120 | 383.6 | **76.7** | ~34 s (warm) | 75 s | 54 s | 171 s | 40 s |

\*Start-up = process start + reading the 7.3 GB of weights before phase 1. The first run read them cold from the
network volume; the later ones had them in the page cache. A fresh upscale pod always starts cold, so 2K and 4K would
take about 45 s more per job than measured here. All three were measured; nothing is estimated.

**Cost basis** at $3.99/h ($0.001108 per GPU-second), one job per pod start, cold weights:

| Size | Per job, 5 s take | Per output second at 5 s | Marginal GPU-s per output s | Suggested `gpuSecPerSec` |
|---|---|---|---|---|
| 1080p | ~194 s → $0.215 | $0.043 | ~26 | 26 |
| 2K | ~245 s → $0.271 | $0.054 | ~36 | 36 |
| 4K | ~430 s → $0.477 | $0.095 | ~70 | 70 |

- `UPSCALE_STARTUP_SEC` (60) is about the model load alone; pod start (image pull, worker start) comes on top.
- `usdPerSec` is the owner's call (cost basis above × margin). The marginal rates make longer takes cheaper per
  second, so pricing at the 5 s figure covers takes of 4 s and up.
- Decode is the biggest phase at every size. Untiled decode on an 80 GB card, flash-attn, or `--compile_vae` are the
  first things to try before lowering prices.
