#!/bin/bash
set -e
cd /workspace/kit
apt-get -qq update >/dev/null && apt-get -qq install -y ffmpeg >/dev/null
[ -d DiffSynth-Studio ] || git clone -q https://github.com/modelscope/DiffSynth-Studio.git
pip install -q -e "./DiffSynth-Studio[all]"
# Driver on H100 pods supports CUDA 13: try the cu130 build (needed for fast int8 kernels), fall back to cu126.
pip install -q 'torch==2.10.*' 'torchaudio==2.10.*' 'torchvision==0.25.*' --index-url https://download.pytorch.org/whl/cu130 \
  || pip install -q 'torch==2.10.*' 'torchaudio==2.10.*' 'torchvision==0.25.*' --index-url https://download.pytorch.org/whl/cu126
pip install -q "torchcodec==0.10.*" "huggingface_hub[hf_xet]" comfy-kitchen kernels || pip install -q 'torchcodec==0.10.*' "huggingface_hub[hf_xet]"
python -c 'import torch; assert torch.cuda.is_available(); from torchcodec.decoders import AudioDecoder; print("TORCH_OK", torch.__version__, torch.version.cuda)'
python -c 'import comfy_kitchen; print("KITCHEN_OK")' || echo KITCHEN_MISSING
M=/workspace/models
hf download MiniMaxAI/MiniMax-H3 --local-dir $M/h3 --include "Ref2VA/transformer/*" &
hf download MiniMaxAI/MiniMax-H3 --local-dir $M/h3 --include "Ref2VA/video_vae/source/*" &
hf download MiniMaxAI/MiniMax-H3 --local-dir $M/h3 --include "Ref2VA/audio_vae/*" &
hf download MiniMaxAI/MiniMax-H3 --local-dir $M/h3 --include "Ref2VA/processor/*" &
hf download DiffSynth-Studio/MiniMax-H3-NF4 minimax-h3-text-encoder-nf4.safetensors --local-dir $M/nf4 &
hf download Comfy-Org/MiniMax-H3 diffusion_models/minimax_h3_ref2va_pruned_fp8_scaled.safetensors --local-dir $M/comfy &
wait
echo "transformer shards: $(ls $M/h3/Ref2VA/transformer | grep -c safetensors)"; ls -la $M/comfy/diffusion_models
echo SETUP_DONE
