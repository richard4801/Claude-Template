#!/bin/bash
# Phase 1 (CPU pod): install SeedVR2 + weights on the network volume. No GPU needed.
L=/workspace/seedvr2-measure; mkdir -p $L; cd $L
nohup python3 -m http.server 8888 --directory $L >/dev/null 2>&1 &
echo "prep started $(date -u +%FT%TZ)" > status.txt
df -BG /workspace > df.txt 2>&1; du -sh /workspace/* > du.txt 2>&1
free=$(df -BG --output=avail /workspace | tail -1 | tr -dc 0-9)
if [ "${free:-0}" -lt 25 ]; then echo "LOWSPACE ${free}G" > status.txt; sleep infinity; fi
set -x
export UV_LINK_MODE=copy UV_CACHE_DIR=/tmp/uv-cache UV_PYTHON_INSTALL_DIR=/workspace/venvs/.uv-python HF_HOME=/workspace/hf-cache
curl -LsSf https://astral.sh/uv/install.sh | sh && export PATH=$HOME/.local/bin:$PATH
[ -d /workspace/SeedVR2/.git ] || git clone https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git /workspace/SeedVR2
git -C /workspace/SeedVR2 rev-parse HEAD > commit.txt
P=/workspace/venvs/seedvr2/bin/python
[ -x $P ] || uv venv --python 3.12 /workspace/venvs/seedvr2
uv pip install --python $P torch torchvision --index-url https://download.pytorch.org/whl/cu128 && \
uv pip install --python $P -r /workspace/SeedVR2/requirements.txt huggingface_hub hf_transfer || { echo "FAIL pip" > status.txt; sleep infinity; }
$P -c "import torch; print(torch.__version__)" > torch.txt 2>&1
mkdir -p /workspace/SeedVR2/models/SEEDVR2
HF_HUB_ENABLE_HF_TRANSFER=1 $P - <<'PY' || { echo "FAIL weights" > status.txt; sleep infinity; }
from huggingface_hub import hf_hub_download
for f in ["seedvr2_ema_3b_fp16.safetensors", "ema_vae_fp16.safetensors"]:
    print(hf_hub_download("numz/SeedVR2_comfyUI", f, local_dir="/workspace/SeedVR2/models/SEEDVR2"))
PY
ls -la /workspace/SeedVR2/models/SEEDVR2 > models.txt
df -BG /workspace > df_after.txt
echo "READY $(date -u +%FT%TZ)" > status.txt
sleep infinity
