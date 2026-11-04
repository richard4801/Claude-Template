#!/bin/bash
cd /workspace/kit
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export LD_LIBRARY_PATH=/usr/local/lib/python3.11/dist-packages/nvidia/cu13/lib:$LD_LIBRARY_PATH
export DIFFSYNTH_FLASH_ATTN_KERNEL_REPO_ID=kernels-community/flash-attn3 DIFFSYNTH_FLASH_ATTN_KERNEL_VERSION=1
A=$(python -c 'from diffsynth.core.attention.attention import ATTENTION_IMPLEMENTATION as A; print(A)' 2>/dev/null | tail -1); echo "ATTN_IMPL $A"; [ "$A" = torch ] && { echo "FA3 NOT ACTIVE - aborting"; exit 1; }
for v in bf16 pruned_fp8; do echo "=== $v + FA3"; python -u run_bench.py $v 3 0 2>&1 | grep --line-buffered -aE "^STEP|^STATS|Error|Traceback"; done
echo BENCH_DONE
