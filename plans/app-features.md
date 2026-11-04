# App Features: Living List

_Started 2026-11-04. This is the running list of features for the studio apps, built up from what we learn in testing. **The prototype comes first** (screens and flows, no real backend), then the build._

Status tags: **[core]** needed for v1 · **[later]** after v1 · **[idea]** not decided · **(tested)** proven in our video tests

## 0. Platforms and structure
- **Mac app**: the main studio for creating, reviewing and exporting.
- **Android app**: fully responsive and optimised for phones, not a squeezed desktop layout. The main mobile jobs:
  - start and track jobs
  - upload clips straight from the camera roll
  - review and approve takes
  - export to TikTok
  - get notifications
- **Shared backend**: both apps talk to one small server/API, which runs the GPU jobs on RunPod. A phone can't hold the API key safely or manage pods itself.
- **Prototype first**: design every screen for both apps, test the flows, and only then build.

## 1. Characters
- **[core]** Character library: name, notes, niche, personality.
- **[core]** Reference set per character, with a **guided upload checklist** (tested):
  - 2 face close-ups (front and profile). The UI should insist on these; without them the face turns out blurry.
  - Full body front, three-quarter, side and back.
  - Warn when the user uploads a **character sheet** instead of separate images.
- **[core]** **Outfits** per character: each outfit is its own reference set. Pick the outfit per video (tested: the outfit transfers reliably).
- **[core]** "Never add" list per character: tattoos, rings, chokers, etc. These go into the prompt automatically (tested: necessary to stop features carrying over from the performer).
- **[later]** Character LoRA training button, for faces that stay consistent across many videos.
- **[later]** Logo/brand check on outfit images (tested: Nike socks and Crocs showed up), with the option to flag or remove.

## 2. New video (character swap)
- **[core]** Drag in or upload a source clip (from the phone camera roll on Android).
- **[core]** **Source clip check** before spending money:
  - one person
  - watermark detected? (tested: a TikTok watermark gets copied into the output)
  - resolution and frame rate
  - length up to 15s (tested: H3 does up to 15s in one pass with no stitch)
  - a warning if the performer's lip sync looks off (tested: the output copies the performer's mistakes)
- **[core]** Pick character → outfit → quality preset → Generate.
- **[core]** **Quality presets** (from tested speeds on an H100):
  - **Standard, 15 steps:** ~14.5 min per 5s. Slow content: talking, GRWM, products.
  - **Dance, 20 steps:** ~19 min per 5s. Fast moves keep their timing.
  - **Premium, 30 steps:** ~29 min per 5s. Hero content.
- **[core]** Keep the original audio (default) or replace it.
- **[core]** The prompt is built automatically from the character, outfit, never-add list and preset. An advanced users' panel shows and edits it.
- **[core]** Number of takes (different seeds), compared side by side.
- **[later]** "Lock motion" mode using the pose ControlNet, for exact timing on very fast dances (only available for the FL2VA mode).

## 3. Background
- **[core]** Keep the clip's real background (default, tested).
- **[later]** **New background from a photo**, with a motion level:
  - **Still**
  - **Subtly alive** (recommended for UGC)
  - **Busy** (people walking past, cars, waves)
  - Photo guide: vertical, same camera height, similar light.
- **[idea]** Composite mode: put the character over a real background photo for a 100% still background.

## 4. Lip sync and audio
- **[core]** **Lip sync toggle**, off by default. Use it only when the performer talks or sings (tested: it isn't needed for dance clips).
- **[later]** **Swap audio**: put a new script or voiceover on a finished clip. Film once, make several versions for different brands.
- **[idea]** Generate voice and mouth together with H3 for talking-to-camera videos (script plus a voice sample).

## 5. Fix-it tools (after generation)
- **[later]** **Region fix**: paint over a problem area (a leftover tattoo, a ring, a bad hand) and regenerate only that part.
- **[later]** Face sharpen pass.
- **[core]** **Upscale** from 768p to 1080p for posting.
- **[later]** Trim and fix the frame rate. LatentSync trims ~0.2s, so fix that automatically.

## 6. Insert object
- **[later]** Scene photo or clip → describe or upload the object (car, product) → preview the edited still → animate.

## 7. Jobs, GPU and cost
- **[core]** One-click run: start GPU → upload → generate → (lip sync) → (upscale) → download → **shut GPU down**.
- **[core]** **Network volume** with the models and environment, so pod setup takes 1–2 min instead of 10–15.
- **[core]** **Batch queue**: load the model once and run many clips back to back.
- **[later]** Parallel GPUs for busy periods: more clips per hour at the same cost per clip.
- **[core]** Live job status with a progress bar based on steps (example: "step 12/20 · ~6 min left"), plus **push notifications on Android** when a job finishes or fails.
- **[core]** **Cost tracker**: per clip, per day and per month, the remaining RunPod balance, and a warning before a job would go over budget.
- **[core]** Safety limits: a spend cap per job and per day, and auto-shutdown of idle pods.
- **[later]** A fallback data centre or GPU when H100s are sold out.

## 8. Results and export
- **[core]** Gallery per character, comparing takes side by side.
- **[core]** Separate **test** and **final** galleries, so test runs don't fill the main gallery.
- **[core]** Export in TikTok/Reels formats (9:16, 1080×1920).
- **[later]** Direct posting or scheduling to TikTok.

## 9. Compliance (built in, not optional)
- **[core]** **Consent record per source performer**: who they are, written okay, scope (test only or posting allowed). Block posting clips made from footage with no posting consent.
- **[core]** **AI label reminder on every export** (TikTok rule, and point 12 of the MiniMax licence).
- **[core]** **#ad / Branded-content reminder** for brand deals (FTC/ASA, and MiniMax point 8: no fake reviews).
- **[core]** "MiniMax H3" attribution shown in the UI (licence requirement for commercial products).
- **[core]** Characters must be clearly adult. No lookalikes of real people.

## 10. Phase 2 (client subscription)
- **[later]** Client accounts and workspaces, with each client's characters and products.
- **[later]** Order flow: brief → choose a character → upload a script or clip → review → deliver.
- **[later]** Usage-based billing on top of the cost tracker.
- **[later]** Re-check the MiniMax licence for offering it as a service first.

## 11. Prototype plan
1. List every screen for Mac and Android (Characters, New Video, Job status, Gallery, Export, Settings/Costs, Consent records).
2. Design wireframes, then a clickable prototype for both, mobile-first for Android.
3. Walk through 3 real tasks on the prototype: make a dance clip, make a talking clip with lip sync, re-use an outfit.
4. Fix the flows, then build.
