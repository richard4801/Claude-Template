#!/bin/bash
# Phase 2 (GPU pod): time SeedVR2 3B fp16 on a 5 s 432x768 (Standard 768P) portrait clip: 1080p, 2K, then 4K if time allows.
L=/workspace/seedvr2-measure; mkdir -p $L/out; cd $L
nohup python3 -m http.server 8888 --directory $L >/dev/null 2>&1 &
echo "measure started $(date -u +%FT%TZ)" > mstatus.txt
nvidia-smi > gpu.txt 2>&1
P=/workspace/venvs/seedvr2/bin/python
S=$(date +%s); DEADLINE=$((S + ${BUDGET_SEC:-1500}))
$P - <<'PY' > input.txt 2>&1
import cv2, numpy as np
w, h, fps, n = 432, 768, 24, 120
vw = cv2.VideoWriter("/workspace/seedvr2-measure/in.mp4", cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
rng = np.random.default_rng(1)
base = cv2.GaussianBlur(rng.integers(0, 255, (h, w, 3), dtype=np.uint8), (0, 0), 6)
for i in range(n):
    f = np.roll(base, i * 2, axis=1).copy()
    cv2.circle(f, (w // 2 + int(80 * np.sin(i / 12)), h // 2), 70, (40, 120, 220), -1)
    cv2.putText(f, f"MUSE {i:03d}", (40, 120), cv2.FONT_HERSHEY_SIMPLEX, 1.4, (255, 255, 255), 3)
    vw.write(f)
vw.release(); print("ok", w, h, fps, n)
PY
run() { # name short_side batch extra...
  local name=$1 res=$2 bs=$3; shift 3
  local left=$((DEADLINE - $(date +%s)))
  if [ $left -lt 120 ]; then echo "$name SKIPPED (budget)" >> results.txt; return 1; fi
  echo "running $name" > mstatus.txt
  local t0=$(date +%s.%N)
  timeout $left $P /workspace/SeedVR2/inference_cli.py $L/in.mp4 --output $L/out/$name.mp4 --model_dir /workspace/SeedVR2/models/SEEDVR2 \
    --dit_model seedvr2_ema_3b_fp16.safetensors --resolution $res --batch_size $bs "$@" > $name.log 2>&1
  local rc=$? t1=$(date +%s.%N)
  local wall=$(python3 -c "print(round($t1-$t0,1))")
  local dims=$($P -c "import cv2;c=cv2.VideoCapture('$L/out/$name.mp4');print(int(c.get(3)),int(c.get(4)),int(c.get(7)))" 2>/dev/null)
  echo "$name rc=$rc wall=${wall}s out=[$dims] clip=5.0s gpuSecPerSec=$(python3 -c "print(round($wall/5.0,2))")" >> results.txt
  nvidia-smi --query-gpu=memory.used --format=csv >> $name.log 2>&1
}
run p1080 1080 21
run p2k 1440 21 --vae_encode_tiled --vae_decode_tiled
run p4k 2160 9 --vae_encode_tiled --vae_decode_tiled
echo "DONE $(date -u +%FT%TZ)" > mstatus.txt
sleep infinity
