# RunPod scripts from the video tests

These are the scripts that produced the results in `plans/video-test-results.md`. Each one includes the fixes for the setup problems we hit (see §5 of that file).

| File | What it does |
|---|---|
| `setup_h100.sh` | Installs DiffSynth-Studio, PyTorch 2.10 (cu130, falling back to cu126), torchcodec 0.10, comfy-kitchen and kernels, then downloads the H3 Ref2VA weights in parallel. |
| `h3_ref2va_run.py` | Runs the H3 Ref2VA character swap: `python h3_ref2va_run.py <bf16\|pruned_fp8\|int8> <steps> <save 0\|1>`. It expects `inputs/source.mp4`, the face close-ups and the outfit images. Edit the prompt for each character and outfit. |
| `bench_fa3.sh` | Speed benchmark with FlashAttention 3, loaded from `kernels-community/flash-attn3`. It aborts if FA3 is not active. |
| `latentsync_infer.sh` | Optional LatentSync 1.6 lip-sync pass. It runs in its own venv with torch 2.5.1. |

**Never commit or post test outputs made from third-party footage.** `test_outputs/` is git-ignored.
