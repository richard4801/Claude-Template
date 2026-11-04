#!/bin/bash
cd /workspace/LatentSync && mkdir -p /workspace/out
for g in 1.5 2.0; do
  s=$(date +%s)
  python -m scripts.inference --unet_config_path configs/unet/stage2_512.yaml --inference_ckpt_path checkpoints/latentsync_unet.pt \
    --inference_steps 20 --guidance_scale $g --enable_deepcache --video_path /workspace/in/h3.mp4 --audio_path /workspace/in/audio.wav \
    --video_out_path /workspace/out/h3_lipsync_g$g.mp4 || exit 1
  echo "TIMING g=$g $(( $(date +%s) - s ))s"
done
echo ALL_DONE
