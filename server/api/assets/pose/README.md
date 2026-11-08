# Pose model (Recreate this edit, workstream 1)

`movenet-lightning.onnx`: MoveNet SinglePose Lightning (Google), fp32 ONNX, 9.4 MB.
- Source: https://huggingface.co/Xenova/movenet-singlepose-lightning (`onnx/model.onnx`)
- Licence: Apache-2.0
- sha256: `1ad4f8d6c2f776a9967db3993c9ca740bc350104f9d37c151dc183fc29a464ad`

Input: int32 `[1, 192, 192, 3]` RGB 0–255. Output: `[1, 1, 17, 3]` (y, x, score) in the input square.

The int8 export (`model_quantized.onnx`) scores near 0 on every point, so it isn't used.

Used by `src/recreate/pose.ts`. It runs in a child process, one job at a time, on at most 20 keyframes per reference. Peak RSS is about 125–160 MB, measured in `test/recreate-pose.test.ts` and logged as "recreate pose".
