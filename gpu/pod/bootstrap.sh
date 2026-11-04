#!/usr/bin/env bash
# MUSE GPU pod start script. Idempotent: on a prepared network volume it only checks and starts.
#
#   bash /workspace/muse/gpu/pod/bootstrap.sh            # check/create venv + weights, then run the worker
#   bash /workspace/muse/gpu/pod/bootstrap.sh --prepare  # one-time volume preparation, no worker
#   bash /workspace/muse/gpu/pod/bootstrap.sh --check    # report what is missing, change nothing
#
# Env (pod template): MUSE_API_URL, WORKER_TOKEN, POD_ID (defaults to RUNPOD_POD_ID).
# Optional: MUSE_VOLUME (/workspace), MUSE_H3_VARIANT (bf16), VRAM_HEADROOM_GB (30), MUSE_REQUIRE_FA3 (1),
#           HF_TOKEN (only if a download needs it), MUSE_LOG_LEVEL (INFO),
#           SELF_STOP_IDLE_SECONDS (300), SELF_STOP_UNREACHABLE_SECONDS (600), MUSE_SELF_STOP (1).
set -euo pipefail

MODE="${1:-start}"; MODE="${MODE#--}"
VOL="${MUSE_VOLUME:-/workspace}"
GPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # .../muse/gpu
VENV="${MUSE_VENV:-$VOL/venvs/muse-h3}"
MODELS="${MUSE_MODELS_DIR:-$VOL/models}"
KIT="$VOL/kit"
LOCK="$GPU_DIR/requirements.lock"
VARIANT="${MUSE_H3_VARIANT:-bf16}"
export HF_HOME="${HF_HOME:-$VOL/hf-cache}"        # FA3 kernel + hub cache survive pod restarts
export MUSE_MODELS_DIR="$MODELS" MUSE_H3_VARIANT="$VARIANT"
export VRAM_HEADROOM_GB="${VRAM_HEADROOM_GB:-30}"
export DIFFSYNTH_FLASH_ATTN_KERNEL_REPO_ID="${DIFFSYNTH_FLASH_ATTN_KERNEL_REPO_ID:-kernels-community/flash-attn3}"
export DIFFSYNTH_FLASH_ATTN_KERNEL_VERSION="${DIFFSYNTH_FLASH_ATTN_KERNEL_VERSION:-1}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export PYTHONUNBUFFERED=1

T0=$(date +%s)
log()  { echo "[bootstrap +$(( $(date +%s) - T0 ))s] $*"; }
die()  { echo "[bootstrap] FATAL: $*" >&2; exit 1; }
need() { [ "$MODE" = check ] && { log "MISSING: $*"; MISSING=1; return 1; } || return 0; }
MISSING=0

mkdir -p "$VOL/logs" "$HF_HOME"
[ -d "$VOL" ] || die "network volume not mounted at $VOL"

# --- 1. system packages (container disk is fresh on every pod start) -------------------------
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  if need "ffmpeg"; then
    log "installing ffmpeg (needed by torchcodec and for muxing; ~20-40 s)"
    apt-get -qq update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y ffmpeg >/dev/null
  fi
fi
PY=$(command -v python3.11 || true)
if [ -z "$PY" ]; then
  if need "python3.11"; then
    log "installing python3.11"
    apt-get -qq update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y python3.11 python3.11-venv >/dev/null
    PY=$(command -v python3.11)
  fi
fi

# --- 2. GPU / driver ----------------------------------------------------------------------
if [ "$MODE" = start ] || command -v nvidia-smi >/dev/null; then
  command -v nvidia-smi >/dev/null || die "no nvidia-smi: this is not a GPU pod"
  GPU=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)
  CUDA_DRV=$(nvidia-smi | sed -n 's/.*CUDA Version: *\([0-9][0-9]*\)\.\([0-9]*\).*/\1/p' | head -1)
  log "GPU: $GPU, driver CUDA ${CUDA_DRV:-?}"
  if [ -n "${CUDA_DRV:-}" ] && [ "$CUDA_DRV" -lt 13 ]; then
    die "driver supports CUDA $CUDA_DRV but the venv uses torch cu130. Pick an H100 with a CUDA 13 driver (RunPod 'CUDA version' filter >= 13.0)."
  fi
fi

# --- 3. venv on the volume (installs only when the lock changed) --------------------------
DS_URL=$(sed -n 's/^# muse:diffsynth \([^ ]*\) .*/\1/p' "$LOCK")
DS_REF=$(sed -n 's/^# muse:diffsynth [^ ]* \([0-9a-f]*\).*/\1/p' "$LOCK")
TC_PIN=$(sed -n 's/^# muse:pypi-only \(.*\)$/\1/p' "$LOCK")
WANT=$(cat "$LOCK" "$GPU_DIR/worker/pyproject.toml" | sha256sum | cut -c1-16)
STAMP="$VENV/.muse-installed"
if [ "$(cat "$STAMP" 2>/dev/null)" != "$WANT" ]; then
  if need "venv $VENV (or out of date with requirements.lock)"; then
    log "installing pinned packages into $VENV (first time ~5-10 min, ~12 GB)"
    [ -x "$VENV/bin/python" ] || "$PY" -m venv "$VENV"
    "$VENV/bin/python" -m pip install -q --upgrade pip
    "$VENV/bin/pip" install -q -r "$LOCK" --extra-index-url https://download.pytorch.org/whl/cu130
    "$VENV/bin/pip" install -q --no-deps --index-url https://pypi.org/simple "$TC_PIN"
    mkdir -p "$KIT"
    [ -d "$KIT/DiffSynth-Studio/.git" ] || git clone -q "$DS_URL" "$KIT/DiffSynth-Studio"
    git -C "$KIT/DiffSynth-Studio" fetch -q origin "$DS_REF" 2>/dev/null || git -C "$KIT/DiffSynth-Studio" fetch -q origin
    git -C "$KIT/DiffSynth-Studio" checkout -q "$DS_REF"
    "$VENV/bin/pip" install -q --no-deps -e "$KIT/DiffSynth-Studio"
    "$VENV/bin/pip" install -q --no-deps -e "$GPU_DIR/worker"
    echo "$WANT" > "$STAMP"
    log "venv ready"
  fi
else
  log "venv up to date ($VENV)"
fi

# torch cu130 ships its CUDA libs here; must be on the path before Python starts.
export MUSE_ORIG_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
CU13="$VENV/lib/python3.11/site-packages/nvidia/cu13/lib"
[ -d "$CU13" ] && export LD_LIBRARY_PATH="$CU13${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# --- 4. H3 weights (one `hf download` per pattern: --include takes only one) ---------------
weights_ok() {
  ls "$MODELS"/h3/Ref2VA/transformer/model*.safetensors >/dev/null 2>&1 \
    && [ -f "$MODELS/h3/Ref2VA/video_vae/source/model.safetensors" ] \
    && [ -f "$MODELS/h3/Ref2VA/audio_vae/model.safetensors" ] \
    && [ -n "$(ls -A "$MODELS/h3/Ref2VA/processor" 2>/dev/null)" ] \
    && [ -f "$MODELS/nf4/minimax-h3-text-encoder-nf4.safetensors" ] \
    && { [ "$VARIANT" != pruned_fp8 ] || [ -f "$MODELS/comfy/diffusion_models/minimax_h3_ref2va_pruned_fp8_scaled.safetensors" ]; } \
    && [ -f "$MODELS/.muse-h3-complete" ]
}
if weights_ok; then
  log "H3 weights present ($MODELS, $(du -sh "$MODELS" 2>/dev/null | cut -f1))"
elif need "H3 weights in $MODELS"; then
  log "==== H3 WEIGHTS MISSING OR UNVERIFIED in $MODELS: downloading (~70 GB; 5-20 min, resumes if interrupted) ===="
  HF="$VENV/bin/hf"
  dl() { log "hf download $*"; "$HF" download "$@" >/dev/null || { log "download FAILED: $*"; return 1; }; }
  pids=()
  dl MiniMaxAI/MiniMax-H3 --local-dir "$MODELS/h3" --include "Ref2VA/transformer/*" & pids+=($!)
  dl MiniMaxAI/MiniMax-H3 --local-dir "$MODELS/h3" --include "Ref2VA/video_vae/source/*" & pids+=($!)
  dl MiniMaxAI/MiniMax-H3 --local-dir "$MODELS/h3" --include "Ref2VA/audio_vae/*" & pids+=($!)
  dl MiniMaxAI/MiniMax-H3 --local-dir "$MODELS/h3" --include "Ref2VA/processor/*" & pids+=($!)
  dl DiffSynth-Studio/MiniMax-H3-NF4 minimax-h3-text-encoder-nf4.safetensors --local-dir "$MODELS/nf4" & pids+=($!)
  if [ "$VARIANT" = pruned_fp8 ]; then
    dl Comfy-Org/MiniMax-H3 diffusion_models/minimax_h3_ref2va_pruned_fp8_scaled.safetensors --local-dir "$MODELS/comfy" & pids+=($!)
  fi
  fail=0; for p in "${pids[@]}"; do wait "$p" || fail=1; done
  [ "$fail" = 0 ] || die "weight download failed (see above); rerun to resume"
  touch "$MODELS/.muse-h3-complete"
  weights_ok || die "weights still incomplete after download"
  log "H3 weights ready: $(ls "$MODELS"/h3/Ref2VA/transformer/ | grep -c safetensors) transformer shards, $(du -sh "$MODELS" | cut -f1)"
fi

# --- 5. quick import check -----------------------------------------------------------------
if [ "$MODE" != check ] && command -v nvidia-smi >/dev/null; then
  "$VENV/bin/python" - <<'EOF' || die "venv import check failed"
import torch
from torchcodec.decoders import AudioDecoder  # noqa: F401  (0.17 breaks audio silently; 0.10 is pinned)
import diffsynth, kernels, muse_worker  # noqa: F401
assert torch.cuda.is_available(), "CUDA not available"
print(f"[bootstrap] imports ok: torch {torch.__version__} cuda {torch.version.cuda}, muse_worker {muse_worker.__version__}")
EOF
fi

case "$MODE" in
  check)   [ "$MISSING" = 0 ] && log "everything present" || log "something is missing (see above)"; exit "$MISSING" ;;
  prepare) log "volume prepared in $(( $(date +%s) - T0 ))s; not starting the worker"; exit 0 ;;
esac

# --- 6. run the worker under supervise.sh ---------------------------------------------------
# Restarts after a crash; never after SIGTERM, a config/token problem (exit 2/3) or a deliberate self-stop (exit 4,
# the dead-man's switch in muse_worker/selfstop.py). See supervise.sh for the exit codes.
export POD_ID="${POD_ID:-${RUNPOD_POD_ID:-}}"
[ -n "${MUSE_API_URL:-}" ] && [ -n "${WORKER_TOKEN:-}" ] && [ -n "$POD_ID" ] \
  || die "MUSE_API_URL, WORKER_TOKEN and POD_ID (or RUNPOD_POD_ID) must be set"
LOGFILE="$VOL/logs/worker-$POD_ID.log"
log "starting worker (log also in $LOGFILE); bootstrap took $(( $(date +%s) - T0 ))s"
exec bash "$GPU_DIR/pod/supervise.sh" "$LOGFILE" "$VENV/bin/python" -m muse_worker
