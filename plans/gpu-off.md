# Switching off MUSE's own GPU (RunPod)

Owner, 2026-11-17: "I need to stop using RunPod so they don't continue to charge me monthly."

## How to switch it off

In the server's settings (Railway variables), do either of these:

- set `GPU_MODE` to `off`, or
- delete `RUNPOD_API_KEY`.

Either one works. After that the server never contacts RunPod again: it doesn't start GPUs, check your balance, or look
at pods or storage.

## What stops working, and what to use instead

| Feature | What happens now | Use instead |
|---|---|---|
| **Edit** swap (MiniMax H3 open weights on our GPU) | Refused with "This needs MUSE's own GPU, which is switched off · pick a hosted model". It is no longer offered in the pickers. | Draft, Standard or HD swap (MiniMax H3 on Replicate or Higgsfield), or Genjutsu (Higgsfield). |
| **Fast · beta** swap (Viggle) | Same refusal, hidden from the pickers. | Same as above. |
| **Lip sync** (only worked with Edit) | Same refusal; the switch shows as unavailable. | The hosted swaps keep the clip's mouth movement from the prompt. There is no separate lip-sync pass. |
| **Upscale** a finished video (SeedVR2) | Same refusal, hidden from the pickers. Upscale was not switched on yet anyway. | Nothing for video for now. Photo upscaling (Enhance) still works on Replicate. |
| **LoRA training** (and building a training set) | Same refusal, before anything is charged. | Nothing for now. A LoRA you already trained only ever worked with Edit, so it goes unused too. |
| **Keep GPU warm** (screen and Claude's warm_gpu_on) | Turning it on is refused. The status shows it is off and can't be turned on. | Not needed: hosted models don't need warming. |
| **Settings → Engines → RunPod** | Shows **off**, "RunPod is switched off". It no longer shows a balance. | – |
| **Auto** (when no model is picked) | It never picks a GPU model. If your saved default was Edit or Fast, Auto uses the hosted default instead. | – |

In practice, only **Edit** (with lip sync) was switched on for the live server. Fast, Upscale and LoRA training were
never enabled on the GPU image, so switching off loses Edit and nothing else in daily use.

**Unchanged:** Draft, Standard and HD video, every AI Suite model (Replicate, fal, Higgsfield, Muapi and your own keys),
photos, outfits, Enhance, Recreate, the editor's helpers (captions, cut-outs, clean-up), and Claude.

## Jobs already waiting when you switch

When the server starts with the GPU off, any job still waiting for (or running on) the GPU is marked failed. Its money
goes back to the person who started it, with the same message. Any GPU that MUSE still thought was running is marked
stopped. Hosted jobs aren't touched.

## Two steps on RunPod's own site (MUSE can't do these for you)

1. **Delete the network volume (the storage).** This is very likely the monthly charge: RunPod bills storage every month
   even when no GPU runs. Deleting it removes the model files stored there for good. Switching it back on later would
   mean setting that storage up again.
2. **Check that no pod is still running**, then cancel or empty the account.

## Switching it back on later

Set `GPU_MODE=runpod` and put back `RUNPOD_API_KEY`, plus a new network volume (`RUNPOD_NETWORK_VOLUME_ID`) set up with the
models (pipeline/runpod/README.md). Everything above comes back on its own.

## For developers

- `GPU_MODE` takes `off`. `runpod` without a key is treated as `off` (`src/app.ts`). The controller is `OffGpu`
  (`src/gpu/pool.ts`): it never creates a pod, fails any GPU job it finds in the line, and `retire()` runs at boot.
- `JobService.capabilities()` is empty, so `features()`, the swap engines (`ModelChoice.swapUsable`), SeedVR2
  (`toolEngines`) and Recreate's engine list drop the GPU models. Refusals use `gpuOffError()` (`src/gpu/controller.ts`),
  `400 engine_unavailable`. They come before any hold, in `jobs.create`, `requireCapabilities`, the Suite swap estimate,
  LoRA build and train, Upscale, warm on and extend, `warm_gpu_on`, and `ModelChoice.check` for a GPU model picked by name.
- `Money.runpodBalance` returns `{source:'unavailable', reason:'RunPod is switched off'}` with no call.
  The Engines block has `status:'off'`.
- `h3-open` in the Suite registry (provider `runpod`) was already never available (`providers.runpod: false`).
- Tests: `test/gpu-off.test.ts`.
- Apps: the Mac and Android apps read availability from `features` and `/v1/engines`, so they need no change. Small
  polish only: both show the Engines status as the raw word "off", because their label lists have no case for it. Both
  still show a "Warm up" button, and tapping it shows the server's message. Neither reads the new `unavailable` field on
  `/v1/gpu/warm`.
