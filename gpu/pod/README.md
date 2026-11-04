# MUSE GPU pod (RunPod H100 + network volume)

The pod runs one process, the **MUSE GPU worker** (`gpu/worker`, package `muse_worker`). It pulls jobs from the API (`plans/backend.md`, "Worker protocol"), renders them, uploads the results to R2 through presigned URLs, and reports `done` or `failed`. The H3 pipeline is loaded **once** per pod and reused for every job.

> **Status:** the worker logic is tested on CPU against a fake API. **Nothing GPU-side has run yet.** That includes the refactored H3 backend, `bootstrap.sh` on a real pod, the cold-start times below and the LatentSync wrapper. The first real run is the end-to-end test the user approves (Phase B in `plans/backend.md`).

## What lives where

| Path (on the volume) | What | Made by |
|---|---|---|
| `/workspace/muse/gpu/` | this folder (worker code, `requirements.lock`, `pod/bootstrap.sh`) | you, once (and on updates) |
| `/workspace/venvs/muse-h3/` | Python 3.11 venv: torch 2.10 cu130, torchcodec 0.10, DiffSynth deps, `kernels` | `bootstrap.sh` |
| `/workspace/kit/DiffSynth-Studio/` | DiffSynth-Studio at the commit pinned in `requirements.lock` | `bootstrap.sh` |
| `/workspace/models/` | H3 Ref2VA weights (same layout as `pipeline/runpod/setup_h100.sh`) | `bootstrap.sh` |
| `/workspace/hf-cache/` | Hugging Face cache (the FA3 kernel from `kernels-community/flash-attn3`) | first worker start |
| `/workspace/logs/worker-<pod>.log` | worker log (also on the pod's stdout) | worker |
| `/workspace/LatentSync/`, `/workspace/venvs/latentsync/` | optional lip sync (own venv, torch 2.5.1) | you, optional |

## One-time network-volume preparation

1. **Create the volume.** In the RunPod console, go to Storage, then Network Volume. Use about **150 GB** (H3 weights ~70 GB, venv ~12 GB, plus LatentSync and headroom) in a datacenter that has H100s. Pods can only attach volumes in their own datacenter.
2. **Start a cheap pod on it.** A CPU pod is enough, because `--prepare` needs no GPU. Use the same image as the template below and mount the volume at `/workspace`.
3. **Put the code on the volume**, and verify it, because silent transfer losses happened in the tests:
   ```bash
   # either clone the repo (private: use a fine-grained GitHub token)...
   git clone https://github.com/<owner>/<repo>.git /workspace/muse
   # ...or copy gpu/ from your machine, then compare checksums on both sides
   rsync -a gpu/ root@<pod>:/workspace/muse/gpu/
   (cd gpu && find . -type f ! -path '*/__pycache__/*' | sort | xargs md5sum) > /tmp/local.md5   # laptop
   (cd /workspace/muse/gpu && find . -type f ! -path '*/__pycache__/*' | sort | xargs md5sum) | diff - /tmp/local.md5  # pod (copy the file over first)
   ```
4. **Prepare:** `bash /workspace/muse/gpu/pod/bootstrap.sh --prepare`. This creates the venv from `requirements.lock` (~5–10 min), checks out DiffSynth at the pinned commit, and downloads the H3 weights (one `hf download` per pattern, ~5–20 min). It is idempotent: rerunning it resumes an interrupted download and skips what is already there. A volume made earlier with `setup_h100.sh` is reused; the files are verified with one more `hf download` pass.
5. **Check:** `bash /workspace/muse/gpu/pod/bootstrap.sh --check` should print `everything present`. **Terminate the pod.** An idle pod costs money; the volume costs ~$7–10/month at 150 GB.
6. **Optional, lip sync (LatentSync 1.6).** Untested in this form; it follows the tested setup:
   ```bash
   git clone https://github.com/bytedance/LatentSync.git /workspace/LatentSync
   python3.11 -m venv /workspace/venvs/latentsync
   /workspace/venvs/latentsync/bin/pip install -r /workspace/LatentSync/requirements.txt   # torch 2.5.1
   /workspace/venvs/latentsync/bin/huggingface-cli download ByteDance/LatentSync-1.6 --local-dir /workspace/LatentSync/checkpoints
   # do NOT upgrade huggingface_hub in this venv (breaks diffusers 0.32)
   ```
   The worker enables lip sync only when `scripts/inference.py`, `checkpoints/latentsync_unet.pt` and that venv's python exist. Lip sync then works both as the `lipsync` job kind and as the post-pass of an `h3` job with `params.lipSync: true`. Without it, such an h3 job fails up front (not retryable) instead of rendering without lip sync.

**Updating the worker later:** sync `gpu/` again. On the next start, `bootstrap.sh` reinstalls packages only if `requirements.lock` or `worker/pyproject.toml` changed. The worker itself is installed in editable mode, so code changes need no reinstall.

## Pod template (the API's GPU controller starts pods from this)

| Setting | Value |
|---|---|
| Image | a RunPod PyTorch image with **Python 3.11** on Ubuntu 22.04 (`runpod/pytorch:…-py3.11-…-ubuntu22.04`). The worker brings its own torch, so the image's torch version doesn't matter. |
| GPU | **H100 80 GB**, with a driver that supports **CUDA ≥ 13** (use RunPod's CUDA-version filter). `bootstrap.sh` refuses older drivers loudly. |
| Pod RAM | ≥ 120 GB. The pipeline keeps models on the CPU and moves them onto the GPU per stage (`onload_device="cpu"`, as tested). |
| Container disk | 30 GB (job scratch goes to `/tmp/muse-jobs` and is deleted after each job) |
| Network volume | the prepared volume, mounted at **`/workspace`** |
| Ports | none (the worker only makes outbound HTTPS calls) |
| Start command | `bash /workspace/muse/gpu/pod/bootstrap.sh` |

**Environment variables**

| Name | Required | Meaning |
|---|---|---|
| `MUSE_API_URL` | yes | API base URL, e.g. `https://muse-api-yourname.koyeb.app` |
| `WORKER_TOKEN` | yes | per-pod bearer token from the controller. Never logged. |
| `POD_ID` | no | defaults to RunPod's `RUNPOD_POD_ID` |
| `VRAM_HEADROOM_GB` | no | default **30** (`vram_limit = total − 30`; the 9.4 s clip OOMed at −5) |
| `MUSE_REQUIRE_FA3` | no | default `1`: H3 jobs fail (not retryable) if FlashAttention 3 isn't active, instead of running 1.63× slower. `0` runs anyway, with a big warning in the log. |
| `MUSE_H3_VARIANT` | no | `bf16` (default, tested) · `pruned_fp8` · `int8` |
| `MUSE_PRELOAD` | no | default `1`: load H3 at start, in the background, while already polling |
| `HF_TOKEN` | no | only if a weight download needs it |
| `MUSE_LOG_LEVEL` | no | `INFO` |
| `MUSE_HEARTBEAT_INTERVAL`, `MUSE_POLL_INTERVAL`, `MUSE_SHUTDOWN_GRACE` | no | 15 s, 5 s, 20 s |
| `SELF_STOP_IDLE_SECONDS` | no | default **300**: the pod terminates itself after this long without a job (see "Self-stop" below). The API sets it to `max(300, IDLE_SHUTDOWN_SECONDS + 120)`. `0` turns this rule off. |
| `SELF_STOP_UNREACHABLE_SECONDS` | no | default **600**: the pod terminates itself after this long without reaching the API, while idle. `0` turns this rule off. |
| `MUSE_SELF_STOP` | no | default `1`. `0` turns the self-stop off completely (e.g. to debug a pod by hand; then stop it yourself). |
| `RUNPOD_POD_ID`, `RUNPOD_API_KEY` | set by RunPod | the pod's own id and its pod-scoped API key; the self-stop uses them. Never logged. |

Exit codes: `0` normal or SIGTERM, `2` config error, `3` token rejected, `4` self-stopped (the pod asked RunPod to terminate it). `bootstrap.sh` runs the worker under `pod/supervise.sh`, which restarts it after a crash (up to 5 times), but never after 2, 3 or 4.

## Self-stop (dead-man's switch)

Normally the API's GPU controller terminates a pod `IDLE_SHUTDOWN_SECONDS` (180 s) after its last job. If the API is down or unreachable (a Koyeb restart, a free-tier hiccup, a network problem), nobody would stop the pod, and an H100 bills about **$4 an hour**. So the worker also watches the clock and terminates **its own** pod.

**When.** The worker checks between jobs, on its main thread, so never during a job, a download, a render or an upload. It stops the pod when either rule fires:

| Rule | Default | Clock starts |
|---|---|---|
| no job for `SELF_STOP_IDLE_SECONDS` | 300 s | when the worker starts, and again when each job ends |
| no answer from the API for `SELF_STOP_UNREACHABLE_SECONDS` | 600 s | at the last HTTP answer from the API (any status below 500; a proxy's 502/503 counts as no answer) |

The idle rule is set later than the API's own idle shutdown, so on a normal day the API stops the pod first and this never fires. When the API is unreachable no job can arrive either, so the idle rule usually fires first; the unreachable rule is the backstop for when the idle rule is turned off or set very long.

**How.**
1. It logs a `SELF-STOP:` warning that says which rule fired.
2. It stops its heartbeat thread and sends one last heartbeat, `state: "self-stopping"` (5 s timeout; it carries on if the API doesn't answer). On that heartbeat the API marks the pod stopped, settles its idle time and terminates it through the RunPod API as well.
3. It terminates the pod. Each method is tried in order until one works:
   1. `runpodctl remove pod $RUNPOD_POD_ID`. RunPod ships `runpodctl` and a pod-scoped API key on every pod.
   2. `runpodctl pod delete $RUNPOD_POD_ID`, the newer runpodctl syntax.
   3. The RunPod GraphQL `podTerminate` mutation, sent with `RUNPOD_API_KEY` from the pod's environment.
   4. As a last resort, **stop** instead of terminate: `runpodctl stop pod`, then GraphQL `podStop`. A stopped pod no longer bills the GPU.

   It terminates rather than stops because the models live on the network volume and outputs are already in R2. Nothing on the pod is worth keeping, and a stopped pod still bills its disk.
4. It exits with code 4. `supervise.sh` doesn't restart it: it waits for RunPod to remove the container, and asks again every 5 minutes in case the request was lost. It doesn't exit, because RunPod could restart an exited container and start a fresh, billing worker.

If every method fails, the worker logs `SELF-STOP FAILED`, keeps serving jobs, and tries again every `SELF_STOP_RETRY_SECONDS` (60 s). If the worker crash-loops (more than 5 crashes), `supervise.sh` terminates the pod the same way, since a crashing worker can't self-stop.

**Off** when `RUNPOD_POD_ID` is unset (not on RunPod: your laptop, `--dry-run`), with `MUSE_SELF_STOP=0`, or when both timeouts are 0. The worker logs `self-stop on …` or `self-stop off (…)` at start.

**Tested** on CPU in `worker/tests/test_selfstop.py`, with a fake `runpodctl` and a fake GraphQL endpoint, so no pod is touched. The tests cover the idle timeout, the unreachable timeout, never stopping mid-job or mid-upload, the GraphQL fallback, retrying when everything fails, and the supervisor not restarting after exit 4. **Not yet run on a real pod**, so the first real run should confirm that `runpodctl remove pod` works with the pod-scoped key.

## Cold start and per-job overhead (estimates, to be measured on the first real run)

| Stage | Estimate |
|---|---|
| RunPod schedules the pod and starts the image (usually cached on the host) | 0.5–1.5 min |
| `bootstrap.sh`: `apt install ffmpeg` (the container disk is fresh every start) + checks | 20–45 s |
| Python imports torch + DiffSynth from the network volume | 15–45 s |
| H3 load: BF16 transformer (~58 GB) + NF4 text encoder + VAEs read from the network volume | 1–4 min (depends on volume throughput) |
| **Pod start → first denoising step** | **~3–6 min** (≈ $0.20–0.40 at $3.99/h) |

The worker heartbeats and polls for jobs while H3 is still loading. A job claimed during the load shows the phase `loading`.

**Per job, beyond the steps** (57.8 s/step at 124 frames on H100 + FA3, so ~9.6 min at 10 steps): input download (~1–5 s), reference and text encoding (~0.5 min), VAE decode + MP4 write + audio mux (~0.5 min), upload (~2–10 s). That is **~1–1.5 min per take**, and it is measured on every job (`stats.takes[].gen_s`, `step_times_s`, `load_s` in the `done` report). The first job on a pod also waits for the model load above.

## Trying the worker without a GPU

```bash
cd gpu/worker
python3.11 -m muse_worker --self-test                    # fake API + fake H3, end to end, prints PASSED
WORKER_TOKEN=<token> python3.11 -m muse_worker --dry-run --api-url http://localhost:3000 --once
python3.11 -m muse_worker.devtools.fake_api --port 8787  # a fake API to point a worker at
python3.11 -m pytest -q                                  # tests (pip install pytest)
```
`--dry-run` claims real jobs from the given API, fakes 10 steps (0.5 s each; `--step-seconds`), and uploads a synthetic 768×1344 24 fps test-pattern MP4 (plus thumbnails for `.jpg` outputs) to the presigned URLs. It then reports `done`, exactly like the real worker.
