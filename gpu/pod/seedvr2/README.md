# SeedVR2 timing run (owner-approved, $5 cap; not run yet)

Prices for Upscale (`UPSCALE_PRICES`, plans/api.md) come from measured GPU seconds per output second. This is the run
that measures them. It spends money, so it starts only with the owner's own go-ahead.

1. **Install (CPU pod, cents):** a CPU pod in the volume's datacenter (`muse-models`, US-CA-2) with the volume at
   `/workspace`, port `8888/http`, start command running `prep.sh`. It stops if the volume has < 25 GB free, then
   installs the CLI (`/workspace/SeedVR2`, commit recorded), a venv (`/workspace/venvs/seedvr2`, torch cu128) and the
   3B fp16 weights (~18 GB in all). Progress: `https://<pod>-8888.proxy.runpod.net/status.txt`. Terminate it at `READY`.
2. **Measure (GPU pod):** the cheapest GPU in stock there (only H100, $3.99/h on 2026-11-08), same volume and port,
   env `BUDGET_SEC` = what's left of the cap in seconds, start command running `measure.sh`. It times 1080p, then 2K,
   then 4K only if time is left, on a 5 s 432 × 768 clip (Standard 768P), and writes `results.txt`
   (`gpuSecPerSec` = wall time ÷ 5 s, model load included, as each job loads it). Terminate the pod at `DONE` or at
   the deadline. 4K not measured → estimate it from the 1080p→2K scaling and label it estimated.
3. **Price:** `UPSCALE_PRICES = {"<size>": {"usdPerSec": gpuSecPerSec × $/GPU-second × margin, "gpuSecPerSec": …}}`.
   Upscale runs one job per pod start with no warm idle worker, so add the start-up seconds the controller logs.

Leaving the install on the volume costs about $1.30 a month (18 GB); delete `/workspace/SeedVR2`,
`/workspace/venvs/seedvr2` and `/workspace/hf-cache` to drop it.
