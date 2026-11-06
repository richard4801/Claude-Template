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
- **[core]** **Character sheet: generate, bring your own, or mix.** Each of the 6 slots can be generated or uploaded, and tapping a slot retakes or replaces it. Nothing is strictly required (missing face close-ups only show a warning).
- **[core]** **Outfit set generator:** Describe it / From a photo / My own set → front, ¾, side and back on one seed → Save. It's reachable from the profile, the video Outfit tool and the photoshoot Outfit tool.
- **[core]** **Templates library** (decided 2026-11-04): save any shot as a template (look + hidden prompt layers + cover image), apply it to any model, private/public toggle, different result every time (random seed + variation pool) unless the user adds direction, Shuffle, and a 7-style starter pack. Photos first; video templates and text-to-video later. See `plans/templates.md`.
- **[core]** **Prompt engine** behind every generator (see `plans/prompt-system.md`). Photoshoot has a Prompt tool (your direction, Lock look, final prompt by slot), and Scene accepts custom text.
- **[core]** **Identity LoRA** per model (photo + video), for a face *and physique* that stay consistent: generate 30 shots → the user keeps 20+ → train both (~$7.25 est.) → before/after, "Use in new renders" switch, versions. See `plans/lora-training.md`.
- **[later]** Logo/brand check on outfit images (tested: Nike socks and Crocs showed up), with the option to flag or remove.

## 2. New video (character swap)
- **[core]** Drag in or upload a source clip (from the phone camera roll on Android).
- **[core]** **Source clip check** before spending money:
  - one person
  - watermark detected? (tested: a TikTok watermark gets copied into the output)
  - resolution and frame rate
  - length up to 15s (tested: H3 does up to 15s in one pass with no stitch)
  - a warning if the performer's lip sync looks off (tested: the output copies the performer's mistakes)
- **[core]** Pick character → outfit → quality preset → Generate. Engine names are user-facing: **Standard** (H3) / **Fast · beta** (Viggle).
- **[core]** **Steps setting**, a slider or number field (decided 2026-11-04 after testing):
  - **Range 4–30, default and recommended: 10.** Max 30.
  - Tested on the same clip and seed: 10, 15 and 20 steps looked identical, and step count did not change the motion timing.
  - Show the estimated time and cost live next to the setting (H100 + FA3: ~58s per step for a 5s clip, so 10 steps ≈ 9.5 min ≈ $0.65).
  - Show a hint that going above 10 is rarely worth it.
- **[core]** **Engine choice:**
  - **H3 (multi-reference)**: identity from the full reference set.
  - **Viggle-Animate (experimental, behind a flag)**: fast and exact timing, but the face is less sharp and warps slightly. Identity comes from one repainted frame. Tested: ~95s per 5s clip on an H200 NVL.
  - See the test results file for the trade-offs.
- **[core]** Keep the original audio (default) or replace it.
- **[core]** The prompt is built automatically from the character, outfit, never-add list and preset. An advanced users' panel shows and edits it.
- **[core]** Number of takes (different seeds), compared side by side.
- **[later]** "Lock motion" for very fast dances. Candidates: Viggle + face fix (Option A), the pose ControlNet (FL2VA only), or someday our own trained add-on (Option B).

## 3. Background
- **[core]** **Replace background + Improve with AI** (planned 2026-11-04): reference photo + description; a deterministic prompt engine builds the H3 structure; a Claude scene-writer step (vision on one source frame) writes the scene and lighting. Gated on the first background-replacement test. See `plans/video-background-and-prompt-ai.md`.
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
- **[core]** **Token wallets** (decided 2026-11-04): everyone signs in with their own account and has their own token wallet (1 token = $0.01). The owner's RunPod account pays for all GPU work; the owner sends tokens to members and can take back unused ones, never more than the real RunPod balance allows. Each render charges the user's own wallet (a hold at start, settled to the actual cost, refunded on failure). The owner sees each member's balance and spend.
- **[core]** **Cost tracker**: per clip, per day and per month, the remaining RunPod balance, and a warning before a job would go over budget.
- **[core]** Safety limits: a spend cap per job and per day, and auto-shutdown of idle pods.
- **[later]** A fallback data centre or GPU when H100s are sold out.

## 8. Results and export
- **[core]** Gallery per character, comparing takes side by side.
- **[core]** Separate **test** and **final** galleries, so test runs don't fill the main gallery.
- **[core]** Export in TikTok/Reels formats (9:16, 1080×1920).
- **[core]** **Social accounts per model** (TikTok, Instagram, Facebook, YouTube, X): connect, Post from a result (accounts, caption, *Mark as AI-generated* and *Paid partnership* toggles that are off by default and set only by the user, Now or Schedule), a Posts page with Scheduled/Posted and stats. Stage 1 hands off to each app; Stage 2 posts directly once each platform approves MUSE. See `plans/socials.md`.

## 9. Compliance (handled in the Terms, not in the UI)
_Decided 2026-11-04: consent and rights are **not** shown as in-app features. The app can't verify uploads, and visible consent screens make it feel like a legal tool._
- **[core]** **Sign-up attestation** (unticked by default, both required): "I'm 18 or older. I'll only upload clips and images I have the rights to use, and only create original characters." and "I'll label AI content when I post it."
- **[core]** **Terms of Service / Acceptable Use Policy** spell it out clearly (draft points):
  - The user confirms they own, or have written permission for, every clip, image and voice they upload, including from any performer who appears in it.
  - No real people's likeness without permission, and no public figures or lookalikes. Characters must be clearly adult (18+). No sexual content involving minors, ever.
  - The user is solely responsible for what they upload and publish. MUSE may remove content and suspend accounts on valid complaints (takedown process plus a contact address).
  - The user must label AI content on platforms (TikTok AI label) and disclose paid promotions (#ad / Branded content). No fake reviews.
  - The MiniMax H3 licence and acceptable use policy terms are passed through to users.
- **[core]** No automatic AI label or #ad. Labelling is the user's job (Terms + sign-up attestation). The Post sheet offers both labels as toggles, off by default (decided 2026-11-04).
- **[core]** "MiniMax H3" attribution in About/Settings (licence requirement).
- **[later]** Report / takedown flow for third parties.

## 10. Phase 2 (client subscription)
- **[later]** Client accounts and workspaces, with each client's characters and products.
- **[later]** Order flow: brief → choose a character → upload a script or clip → review → deliver.
- **[later]** Usage-based billing on top of the cost tracker.
- **[later]** Re-check the MiniMax licence for offering it as a service first.

## 10b. Parked until MUSE works end to end (decided 2026-11-04)
- **[idea]** **MUSE MCP connector**: a hosted MCP server on the MUSE backend so Claude (web, desktop, phone, Claude Code) can look things up, manage models, quote and start paid work (only on an approved quote, inside spend caps), and draft posts (confirm step), with changes showing live in the apps. Needs the backend on a public HTTPS host (Railway is the likely pick, ~$5/month).
- **[idea]** **HyperFrames editing**: a house editing style (captions, hook title, handle, end card) applied to approved takes as HyperFrames projects. Edited versions always need approval. Open/edit in HyperFrames Studio on the Mac and send back for a re-render. Waiting on the user's 2–3 reference videos for the style.

### Blackmagic Camera (parked 2026-11-06 by the owner)
Research: `plans/research/blackmagic-camera.md`. Since app version 3.4 (July 2026), the free Blackmagic Camera app (iOS and Android) can be remote-controlled over Blackmagic's Camera REST API with a notification WebSocket:
- Local network only, while the app is open, with no password.
- It covers record, settings, slate, presets and the clip list.
- It provides no clips, gyro data, preview or cloud API.

Ideas, best first:
1. A "Shoot for MUSE" preset for cleaner swap sources.
2. MUSE Looks as monitoring LUTs.
3. Read clip metadata on upload into the camera spec, with warnings.
4. Android auto-import from the app's folder.
5. Remote record and slate from MUSE.

Not possible: a tracked phone camera for Blender, or pulling from Blackmagic Cloud.

## 11. Prototype plan
1. List every screen for Mac and Android (Characters, New Video, Job status, Gallery, Export, Settings/Costs, Consent records).
2. Design wireframes, then a clickable prototype for both, mobile-first for Android.
3. Walk through 3 real tasks on the prototype: make a dance clip, make a talking clip with lip sync, re-use an outfit.
4. Fix the flows, then build.
