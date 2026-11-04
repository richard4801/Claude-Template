# Video Test Results (Nov 3–4, 2026)

All tests ran on rented RunPod GPUs and used one original AI influencer (honey-blonde, green eyes, freckles). The source clips came from a friend who agreed to their use for private testing. **Do not post any output made from the friend's footage without her written okay.**

## 1. Bottom line
- **MiniMax H3 (Ref2VA) is the winner.** It does a true swap: it keeps the real performer's motion, hands and timing, and puts our character into the clip. The result looks like a real phone video.
- **Quality bar:** the full model at **30 steps, 768×1344** (Test 2). This is good enough to post.
- **The open problem is speed.** The quality bar takes ~45 min for a 5–6s clip on one H100, but the target is **≤15 min per 5s clip (4 clips/hour/GPU)**.
- Shortcuts tested so far either broke faithfulness (Turbo) or barely helped (8-bit). See §4.
- **Lip sync:** this is solved as an optional add-on step (LatentSync). Only use it when the person in the source is talking or singing.

## 2. All tests

| # | Test | GPU | Size | Steps | Clip | Time | Cost | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | H3 NF4 (4-bit) | RTX 6000 Ada 48GB | 480×832 | 50 | 5.2s | 2h13m | $1.82 | True swap ✅. Face blurry/warped at 480p ❌. Friend's tattoos carried over ❌ |
| 2 | **H3 full BF16** | H100 80GB | 768×1344 | 30 | 5.9s | **46m** | ~$3.05 | **Best quality.** Sharp face, clean hands, real background kept, no tattoos ✅. Too slow ❌ |
| 3 | Wan2.2-Animate-2 Distilled | H100 | 720×1280 | 10 | 6.4s | 12.7m | ~$0.85 | Fast and sharp, but looks "AI-clean", broken mosaic background, outfit drifts after chunk join ❌ |
| 4 | LatentSync 1.6 (lip sync on Test 2) | RTX 4090 | 768×1344 | 20 | 5.9s | 3–6m | ~$0.56 | Works. Redraws only the mouth, no seams. Mouth slightly softer |
| 5 | H3 + Turbo LoRA (Ref2VA 4-step v0.1) | H100 | 768×1344 | 4 | **9.4s** | **13m** | ~$0.95 | 5× faster ✅. But it invented a different room, background slides/warps, dance drifts out of sync with the audio, weaker expressions ❌ |
| 6 | Speed benchmark, 3 steps each | H100 | 768×1344 | 3 | 5.2s | — | $1.34 | BF16 94.5 s/step · Pruned FP8 83.2 s/step (1.14×) · Int8 ConvRot 85.6 s/step (1.10×) |
| 7 | FlashAttention 3 benchmark | H100 | 768×1344 | 3 | 5.2s | — | _pending_ | _pending_ |

Spent on tests so far: **~$12.12** (plus Test 7). About $3 of that was lost to setup mistakes; the fixes are now written into the scripts (§5).

## 3. Findings

**Model choice**
- **H3 beats Wan** for UGC: Wan's character looks too clean and "AI", while H3 keeps the phone-camera realism.
- H3 works as **video editing**: the source clip is `<Video 1>`, our character is `<Image 1..N>`, and a structured prompt (`subject_definitions / summary / retention_analysis / detailed_description`) says what to keep and what to replace.
- **Resolution matters most for the face.** 480p gave a blurry, warping face. H3's native size is **768 short side**, which gives a sharp face.

**Prompting**
- **Tattoos and rings from the source performer carry over unless the prompt names and removes them.** Describe the source person *with* their tattoos and rings, then state "None of Subject 1's tattoos remain", "no rings, no choker", and "clean tattoo-free skin". This worked in Tests 2 and 5.
- **The outfit comes from the reference images.** A full-body front, three-quarter and back set transfers clothes reliably, including skin the source clip never shows.
- Pass the clip's audio as `video_audio` and mark it `fully_copy` so the original sound is kept.

**Inputs we need for each character/outfit**
- 2 face close-ups (front and profile). These are essential, because full-body shots alone leave the face too small.
- Full-body front, three-quarter, side and back in the outfit. Send separate images, not a character sheet.
- Prefer plain, unbranded clothing (the Nike socks and Crocs in Test 5 show logos).

**Source clips**
- The swap copies the performer's mouth faithfully, **including their mistakes**. In Test 2 the source lip sync was off, so the output was off too.
- **Good source = good result.** Performers should mouth or speak the words clearly.
- A static phone camera, one person, steady light and no watermark work best.

**Lip sync**
- **LatentSync 1.6** needs ~18GB of VRAM (a 4090 is fine) and takes ~3–6 min per clip.
- Use guidance 1.5–2.0. It is **optional**: use it only for talking or singing clips, and skip it for dance clips.
- It also allows **swapping in new audio** (a different script or voiceover) on a finished clip.
- It resamples to 25fps and trims ~0.2s at the end. Fix this in production.

**Long clips**
- H3 does up to **15s in one pass**, so there are no stitches.
- Wan works in ~3.4s chunks, and the chunk joins drift (the outfit texture changed).

**Turbo LoRA (lightx2v Ref2VA 4-step v0.1)**
- Must be loaded at **strength alpha/rank = 8/128 = 0.0625**. DiffSynth's default 1.0 produces pure noise.
- At 4 steps, the source video becomes loose inspiration rather than an exact copy. **This is not good enough for production.** Re-check if a Ref2VA Turbo v1.0 is released.

**"Pruned" H3**
- It only replaces the timestep-embedding/adaLN projections with a lookup table. The drawing layers (attention and FFN) are intact.
- **Quality should be about the same as full.** It mostly saves memory (43GB vs 58GB) and download size, **not time**.

**8-bit (FP8 / Int8 ConvRot)**
- These compute in 8-bit via `comfy-kitchen`, but give only 10–14% speed-up. **Most of each step is attention, not the linear layers.**

## 4. Speed: where we are

| Setup (5.2s clip, 768×1344, H100) | s/step | 20 steps | 30 steps |
|---|---|---|---|
| BF16, PyTorch fallback attention | 94.5 | ~32 min | ~47 min |
| Pruned FP8 | 83.2 | ~28 min | ~42 min |
| Int8 ConvRot | 85.6 | ~29 min | ~43 min |
| BF16 + FlashAttention 3 | _pending_ | | |

Remaining speed levers, roughly best first:
1. **FlashAttention 3** (Test 7).
2. **Fewer steps (15–20).** This needs a quality run to check that timing stays exact.
3. **A faster GPU (B200).** About 2× faster at ~$6–9/hr.
4. **Several GPUs in parallel.** This gives more clips per hour at the same cost per clip.
5. A future Ref2VA Turbo v1.0.

## 5. Setup gotchas (already built into the scripts)
- `pip install -e DiffSynth-Studio[all]` pulls a CUDA-13 PyTorch build. On pods with a CUDA 12.4 driver, pin `torch==2.10.*` with the cu126 build. H100 pods have a CUDA-13 driver, so the cu130 build works there.
- Use **torchcodec 0.10** with torch 2.10. 0.17 fails to load, and the clip audio then silently comes back empty.
- With the cu130 build:
  - Disable cuDNN SDPA (`torch.backends.cuda.enable_cudnn_sdp(False)`), because it has no engine for H3's attention.
  - Add `nvidia/cu13/lib` to `LD_LIBRARY_PATH`.
- `hf download --include` takes **one** pattern. Later patterns are treated as filenames and silently skipped, so run one download per pattern.
- **Full 9.4s clip at 768:** leave ~30GB of VRAM headroom (`vram_limit = total − 30`). With the default −5 it runs out of memory.
- **LatentSync** needs its own venv (torch 2.5.1). Don't upgrade `huggingface_hub` there, because it breaks `diffusers 0.32`.
- **Verify uploads to the pod with checksums.** The first uploads were sometimes lost silently.
- **Delete the pod right after downloading results.** An idle H100 costs ~$4/hr.

## 6. Cost model (for planning)
- **H100: ~$3.99/hr** (cheaper listings sell out). RTX 4090: ~$0.34–0.89/hr. RTX 6000 Ada: ~$0.74/hr.
- **Setup:** setup on a fresh pod takes ~10–15 min (~$0.70–1.00). **A saved network volume** with the models and environment (~$5–7/month for 100GB) brings this down to ~1–2 min. Do this once production starts.
- **Per 5s clip at the quality bar today:** ~$3. At 15 min per clip it would be ~$1. Add ~$0.05–0.10 when lip sync is used.

## 7. Next steps
1. Finish the FlashAttention 3 benchmark and fill in §4.
2. Run one quality test with the fastest setup at **15–20 steps** on the dancing clip. Check that the background stays put, the timing matches the audio, and the expressions are clean.
3. Test a **new background** from a photo (location photo, vertical, same camera height and similar light).
4. Then lock the settings, set up the network volume, and build the automation (§5 of the main plan).
