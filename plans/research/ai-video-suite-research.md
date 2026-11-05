# MUSE — AI Video Studio Research: CapCut-class editor, "our Higgsfield", and directed camera

*Research date: 2026-11-05. Prepared for the MUSE owner (Android + Mac apps, Node/TS server on Railway, Cloudflare R2, Replicate + own RunPod H100s).*

**How to read the confidence marks**

| Mark | Meaning |
|---|---|
| ✅ | Verified on a primary source in this session (vendor model page incl. live price JSON, official docs, model card, licence file, release notes). |
| ◐ | Secondary source (review, vendor blog/marketing, news, or the community "higgsfield-ai-prompt-skill" repo, which compiles Higgsfield CLI/MCP schemas as of 2026-09-26). Plausible, not independently confirmed. |
| ⚠ | Unverified, conflicting, my inference, or an estimate. Treat as a hypothesis to check in real use. |

Prices are list prices read from Replicate model pages (pricing JSON) and fal `llms.txt` pages on 2026-11-05 unless stated; they change often. Nothing was purchased, signed up for, or run — consistent with the owner's "no test spending" rule, every plan below assumes we wire things up and the owner validates with real use.

---

## Executive summary

1. **Higgsfield (Nov 2026) is a UX layer over other people's models, plus a Blender/MCP play.** Cinema Studio 4.0 is "the deepest cinematography control" surface and runs on **Seedance 2.5** (✅ Higgsfield help centre). Its "camera hardware" (4 bodies, 5 lens characters, 3 apertures, era, genre, tempo, 6 lighting presets, 50+ palettes, 30+ moves) is a set of **style/look tokens and opaque IDs passed to one model**, not a physical simulation — the 4.0 API even has no focal-length field (◐). Everything Higgsfield ships is buildable for MUSE from Replicate/fal/RunPod; the moat is presets, UX and the character pipeline, not models.
2. **Higgsfield already shipped the owner's Blender idea**: a Blender add-on (Scene Builder, Character Animation, Video-from-viewport via Seedance 2.5, phone-as-camera) and a **"Blender Bridge" MCP endpoint** so Claude can drive the open Blender scene (✅ Higgsfield blog, Oct 2026), plus a hosted "3D Jutsu" Blender 5.2 scene builder (◐). This validates the direction; MUSE's edge is doing it with *our* characters and model choice.
3. **Critical licence issue (✅ licence file):** the **MiniMax H3 open-weights Community Licence excludes the US, EU, UK and South Korea**, forbids using the weights *or their outputs* outside the "Applicable Territory", requires a visible "Powered by MiniMax H3"/"MiniMax H3" notice, and requires disclosing machine-generated content. MUSE's RunPod "Edit" (character swap) path may be unlicensed depending on where you operate and publish. Decide this first (apply via api@minimax.io/Comfy, move to hosted H3 on Replicate, or switch the swap path to Wan 2.2 Animate, Apache-2.0).
4. **Model landscape on Replicate (✅ prices):** MiniMax H3 $0.08/s (768P) / $0.13/s (2K); H3 Lite $0.0125–0.02/s; H3 Highspeed $0.03/s; **Kling 4.0** $0.157–0.235/s (30-s clips, start + middle + end keyframes, up to 10 images, reference videos "to take motion, camera work or style from"); Seedance 2.0 $0.04–1.25/s, Seedance 2.5 $0.10–0.97/s (720p max on Replicate); Veo 3.1 Lite $0.05–0.08/s; Wan 2.7/3.0 $0.035–0.28/s; LTX-2.3 Pro $0.08–0.32/s (only model with a `camera_motion` enum). **Sora 2 API was shut down on 2026-09-24** (✅ OpenAI deprecations) — remove it from any catalog.
5. **Editor:** Media3 1.11 (Aug 2026) + AVFoundation can natively cover most of CapCut's UGC must-haves: multi-track compositions, text/bitmap/Lottie overlays, time-varying transforms (keyframes), LUT/HSL/contrast, Gaussian blur, variable speed via `SpeedProvider`, chroma key/masks via custom GL/Core Image shaders (✅ Media3 docs). Known Android gaps: **crossfades are "not yet supported" in Compositions** and `CompositionPlayer` (preview) is still `@ExperimentalApi` (✅). AI pieces go server-side.
6. **Build the editor around what UGC creators use daily:** styled word-by-word auto-captions, hook text, music + voiceover + ducking, silence/filler-word jump cuts, templates, beat markers, green-screen/PiP. Effects/transitions breadth comes later.
7. **Camera control reality:** hosted frontier models accept camera direction only through (a) prompt vocabulary, (b) a **reference video** (Kling 4.0, Kling 3.0 Omni "feature" mode, MiniMax H3/H3 Max, Seedance 2.x), (c) **start/middle/end keyframes**. Geometric control (depth/pose/point-trajectory/camera-extrinsics) exists only on open weights (Wan VACE, Wan-Fun-Camera, Uni3C, ReCamMaster, Wan-Move, LTX-2.x IC-LoRAs) or fal endpoints for some of them — at visibly lower realism and 480–720p.
8. **Recommended Camera UX:** one **Camera** control with two modes — **Preset** (Rig: body/lens/focal/aperture/look · Move: library with intensity · Angle/shot size) compiled per target model into prompt fragments, parameters and (optionally) a pre-rendered greybox reference clip; and **Directed (Blender)** for full-clip previs: block each character's path, animate the camera, render greybox/depth/pose/track guides + keyframes + trajectories, and route to Kling 4.0, fal's H3 Max 3d-to-video, Seedance, or Wan VACE.
9. **Blender bridge architecture:** local Blender MCP (MIT "MCP for Blender" or Blender Lab's official GPL-3 server) on the owner's Mac + a **MUSE remote MCP server** on Railway (OAuth 2.1 per MCP spec 2026-07-28) exposing camera-session tools. Both entry points (Claude Desktop/Code with the owner's subscription, and in-app chat via the Claude API) share one `camera_session_id`. Blender Python never holds network credentials; the Mac app uploads renders to R2.
10. **Multi-character blocking is the weakest link.** No hosted model reliably follows multi-character Blender blocking; a community test found Seedance followed a staging map's orientation 6/12 times (chance) (◐), and community practice caps tracked characters at ~3 for Seedance (◐). Kling 4.0 allows up to 7 subjects (◐ press). Exact paths need open models (Wan-Move point trajectories, LTX-2.3 motion-track IC-LoRA, VACE pose/depth).
11. **Character consistency** = keyframe-first pipeline (7-image sheet → image-model keyframe → i2v/ref2v), per-model reference subsets, identity QA. Video LoRAs only on open models (Wan 2.2 via fal trainer $0.005/step; LTX-2.3 $0.0048/step; Replicate Wan 2.2 fast endpoints accept LoRA URLs). Hosted Kling/Seedance/H3/Veo accept no LoRAs.
12. **Compliance is now mandatory, not optional:** EU AI Act Art. 50 transparency duties apply from 2026-08-02; New York's synthetic-performer ad disclosure law applies from 2026-06-09 (original AI characters in ads are exactly this); FTC rule bans fake testimonials; TikTok/YouTube/Meta label realistic AI. Build disclosure + C2PA into export by default.
13. **Cost and plan:** a finished 10-s clip costs ≈ $0.20 (H3 Lite 768P) to $4.50 (Seedance 2.0 1080p) on Replicate vs ≈ $3.43–7.84 for a 10-s Cinema Studio 4.0 clip at Higgsfield credit prices (◐). Estimated MUSE running cost for ~100 finished 15-s videos/month: ≈ $0.6k (lean) to $1.3–2.0k (premium), excluding any always-on GPU. The combined roadmap is 18 phases / ≈ 31 agent-weeks; the first phase is guardrails (model registry, price/budget caps, mock providers, licence flags) so nothing costs money until the owner presses Generate.

---
## Part A (lead) — Higgsfield deep dive, feature map, and the MUSE Camera control

### A1. What Higgsfield is in November 2026

Higgsfield's homepage (✅ [higgsfield.ai](https://higgsfield.ai/)) currently leads with Seedance 2.5 ("the most advanced" model on the site), **Cinema Studio 4.0**, **AI Influencer Studio**, **Genjutsu** (video-to-video), **Shorts** (viral presets), a **Supercomputer agent**, **Higgsfield MCP for Claude**, Mangaka (comics), Playable (games), and "35+ frontier models" with "cinematic camera control". It is a credit-based aggregator: it resells Seedance, Kling, Veo, Wan, MiniMax, Grok, Gemini Omni, FLUX, GPT Image, Nano Banana, Seedream and its own "Soul"/"DoP" models (◐ reviews: [kristian-larsen.com](https://www.kristian-larsen.com/reviews/higgsfield-ai-review/), [gaga.art](https://gaga.art/blog/higgsfield-ai/); ◐ community model catalogue snapshot 2026-09-26 in [osidemedia/higgsfield-ai-prompt-skill](https://github.com/osidemedia/higgsfield-ai-prompt-skill)).

**Pricing (conflicting, ◐):** Plus ≈ $39/mo billed annually for 1,000 credits and Ultra $129/mo ($99 annual) for 3,000 credits (checked 2026-10-14 by [kristian-larsen.com](https://www.kristian-larsen.com/reviews/higgsfield-ai-review/)); Higgsfield's own guides price examples at **$49 per 1,000 credits ≈ $0.049/credit** ([Cinema Studio 4.0 guide](https://higgsfield.ai/blog/cinema-studio-4-0-complete-guide), [Genjutsu blog](https://higgsfield.ai/blog/higgsfield-genjutsu)); other reviewers list $15/200, $34/1,000, $84/3,000 ([creatify.ai](https://creatify.ai/blog/higgsfield-pricing-(2026)-plans-and-what-you-ll-actually-pay)). Some models are "unlimited" on some plans with throttling; unlimited does not apply via MCP/CLI/integrations (◐).

### A2. The "virtual cinema" — exactly what is selectable, per Cinema Studio version

Higgsfield has iterated Cinema Studio fast (2.0 → 2.5 → 3.0 → 3.5 → 4.0 within ~9 months); all versions coexist in a selector, and **vocabulary differs per version** (◐ community skill; ✅ help centre for the version summary: [How do I use Cinema Studio](https://higgsfield.ai/creator-hub/help-center/tools/how-do-i-use-cinema-studio)).

| Axis | 2.0 / 2.5 ("Optical Physics Engine", image-first) | 3.5 (video-first, "three pills": Genre / Style / Camera) | 4.0 (default; "Director's Panel"; **runs on Seedance 2.5**) |
|---|---|---|---|
| Camera body | 6 anonymised bodies: *Premium Large Format Digital, Classic 16mm Film, Modular 8K Digital, Full-Frame Cine Digital, Studio Digital S35, Grand Format 70mm Film* (◐; marketing called them "ARRI, RED, Panavision, Sony Venice, IMAX" ◐ [X post](https://x.com/rezkhere/status/2002064890698346907)) | *Clean Digital, Fine Film, Raw 16mm* (◐) | *Modern, 35mm Film, 8mm Film, DV Camcorder* (✅ [4.0 guide](https://higgsfield.ai/blog/cinema-studio-4-0-complete-guide)) |
| Lens | 10 "characters": Creative Tilt, Compact Anamorphic, Halation Diffusion, Extreme Macro, 70s Cinema Prime, Warm Cinema Prime, Swirl Bokeh Portrait, Vintage Prime, Classic Anamorphic, Clinical Sharp Prime (◐); 2.0 guide names "Cooke" as an example of lens character (✅ [2.0 guide](https://higgsfield.ai/blog/cinema-studio-guide)) | Vintage Haze, Warm Halation, Anamorphic, Extreme Macro, Clinical Sharp (◐) | Clean Sharp, Anamorphic, Vintage Anamorphic, Warm Vintage, Halation Vintage (+ Auto) (✅) |
| Focal length | 2.0 guide: 8 mm–50 mm (✅); 2.5 UI: 8 / 14 / 35 / 50 mm (◐) | 8 / 14 / 35 / 50 / 75 mm (◐) | **No focal-length field at the API** (◐ CLI schema); UI focal control unverified (⚠) |
| Aperture | f/1.4, f/4, f/11 (◐) | f/1.4, f/4, f/11 (◐) | f/1.4 "Wide Open", f/4 "Moderate", f/11 "Deep Focus" (✅) |
| Genre / era / pacing | 2.0: Action, Horror, Comedy, Western, Suspense, Intimate, Spectacle, Auto (✅) | General, Action, Horror, Comedy, Noir, Drama, Epic (◐) | Genre: General, Action, Epic, Drama, Comedy, Horror, Noir; Era: 1960s/80s/90s/2000s/2020s; Tempo: Auto, Chaotic, Dynamic, Calm, Single shot (✅) |
| Lighting | — (2.5 has a grading suite: temperature, contrast, saturation, sharpness, grain, highlights, exposure ✅ help centre) | 6 presets: Soft Cross, Contre Jour, Overhead Fall, Window, Practicals, Silhouette (◐) | Same 6 presets + custom colour/brightness/diffusion/angle (✅) |
| Colour | — | 8 palettes: Naturalistic Clean, Bleached Warm, Hyper Neon, Teal Orange Epic, Sodium Decay, Cold Steel, Bleach Bypass, Classic B&W (◐) | 50+ palette templates; "Change Color Palette" after generation (✅) |
| Camera move style | Director Panel: 18 moves — Static, Handheld, Zoom In/Out, Camera Follows, Pan L/R, Tilt Up/Down, Orbit Around, Dolly In/Out/Left/Right, Jib Up/Down, Drone Shot, 360 Roll, Auto (◐) | 9 "Camera MoveSet Styles": Classic Static, Silent Machine, One Take, Epic Scale, Intimate Observer, Impossible Camera, Documentary Snap, Raw Chaos, Dreamy Flow (◐) | "30+ presets" incl. POV, Robot Arm, Pan Left, Dolly In, Helicopter Shot (✅ names partial) |
| Speed ramp | 2.0: Slow-mo / linear / Speed Up (✅); 2.5: Linear, Slow Mo, Speed Up, Impact, Auto, **Custom curve** (◐) | (3.0: Auto, Slow-mo, Ramp Up, Flash In, Flash Out, Bullet Time, Hero Moment ◐) | Not listed (⚠) |
| Shots | 2.0: single, auto multi-shot, manual multi-shot; ≤6 shots, ≤12 s total, 1–12 s/shot, ≤3 characters (✅) | `multi_prompt`, auto/custom; ~4 cuts per generation observed (◐) | No multi-shot fields at API; cuts written in prompt; Tempo controls cut rate (◐/✅) |
| Output | 1080p (✅ 2.0) | 4–15 s; 480/720/1080p; AR Auto,16:9,9:16,4:3,3:4,1:1,21:9; Sound on/off; batch (◐) | Up to 30 s (web), 4–30 s (API); 480/720/1080p (API 480/720 per guide); AR incl. 9:16; audio on by default; bitrate standard/high; references ≤50 (API: 30 images, 10 videos, 10 audio) (✅/◐) |
| Characters | Soul Cast actors (≤3 per keyframe) (✅ help centre) | Elements: Characters, Locations, Props; Claude-powered "AI Director" splits a script into shots with camera parameters pre-filled (✅ help centre) | AI Cast + **Emotion Wheel** per `@character` (Hope, Anger, Joy, Trust, Fear, Surprise, Sadness, Disgust) (✅) |
| Post | Hero Frame first; start/end frames; Grid 2×2/3×3/4×4; "3D Mode" Gaussian-splat re-framing of a still (◐) | Per-shot settings strip | Edit Video (regional edits), Extend forward/back ("Sequel/Prequel") (✅) |

**What is *not* exposed:** frame rate, shutter angle (only a "Low Shutter" motion *effect* exists), ISO, white balance in Kelvin, lens distortion parameters, sensor size, focus distance/rack-focus timing. Frame rate "not stated" (✅ 4.0 guide).

**How choices become model inputs (best inference):**
- In 4.0 the API takes **opaque IDs** (`camera_model_id`, `camera_lens_id`, `camera_aperture_id`, `era_id`, `genre_id`, `pacing_id`, `light`, `color_palette`) and modes identical to Seedance 2.5 (`t2v`, `omni_reference`, `video_edit`, `video_extension`) (◐ CLI schema dump, 2026-09-26). Pricing depends on duration, mode, resolution and video references (◐).
- Higgsfield's own guidance: *settings set the technical direction, the prompt describes the scene*; keep the prompt consistent with settings (e.g. don't ask for rapid cuts with Tempo = Single shot) (✅ 4.0 guide). The community rule "everything in the settings strip is a UI control, never restate it in the prompt" (◐).
- ⚠ Inference: IDs are expanded server-side into prompt fragments/system instructions (and possibly reference images or LoRA-like adapters on their own "Soul Cinema" models) before calling Seedance 2.5. There is no evidence of physical lens/DOF simulation — 4.0 has no focal length at the API and lens "characters" are named by look ("Halation Vintage"), not by optics.
- The 2.x "Hero Frame first" flow (generate a still with the optical stack in an image model, then animate it) is the most controllable approach and the one MUSE already resembles (photoshoots → video).

**Seedance-specific craft Higgsfield users rely on (◐ community skill, aligned with ByteDance's Dreamina guidance):** map every reference explicitly ("Character A corresponds to @Image 1. Use only appearance, hairstyle and clothing."), add a non-interchange lock ("Do not interchange these characters' appearances, clothing, actions, positions…"), one primary camera move per shot ("One-Move Rule"), 1–2 action beats per 5 s, video reference for complex camera moves ("Match the camera movement from @Video1"), a separate video reference for character action vs camera ("dual video reference"), and **"prompt wins on action, reference wins on texture/world feel"**; a video reference cannot carry identity and cannot continue an action frame-accurately.

### A3. The motion library (camera moves and effects)

- **Higgsfield DoP** (their image-to-video model) offers categories *Effects, Basic Camera Control, Epic Camera Control, Catch the Pulse, New/Trending*, and **Mix** = combine two motion presets in one shot (✅ [Higgsfield help: DoP](https://higgsfield.ai/creator-hub/help-center/ai-models/how-do-i-use-dop); ✅ [Mix announcement](https://beta.higgsfield.ai/posts/3TrFMRKDWXQmFenbhsxnJy) with pairings like *Crane Overhead + Crash Zoom In*, *Snorricam + Low Shutter Strobe*). Intensity is a 0–1 slider per effect (◐ [clipia.ai](https://clipia.ai/en/video-models/higgsfield-dop)).
- Named camera moves (◐ community catalogue): **Dolly** In/Out/Left/Right, Dolly Zoom In/Out, Super Dolly In/Out · **Crane** Up/Down, Crane Over The Head, Levitation · **Orbit** 360 Orbit, Arc, Lazy Susan, Robo Arm · **Zoom** Crash Zoom In/Out · **Follow** FPV Drone, Action Run, Handheld, Head Tracking, Snorricam · **Specialty** Bullet Time, Dutch Angle, Fisheye, Whip Pan, Overhead · **Time** Hyperlapse, Timelapse Human/Landscape, Low Shutter · **Through-object** Through Object In/Out, Mouth In · **Vehicle** Car Chasing, Car Grip, Buckle Up. Angles: Low, High, Eye level, Bird's-eye, Worm's-eye, Ground level, Canted L/R, Static oblique, OTS, POV, Two-shot, Cowboy; shot sizes ELS→ECU + Insert.
- The same repo's live-catalogue pull (2026-07-18) found **~100 preset names expanded into ~1,900 per-model variants** (Kling/Higgsfield/Wan/MiniMax/Seedance families "with baked params"), skewed to viral VFX (Werewolf, Disintegration, Bullet Time White, Money Rain…) — and noted that **none of 13 community film/ad productions used a motion preset; serious work free-prompts camera language** (◐). Takeaway for MUSE: presets must be **per-model recipes**, and UGC presets matter more than VFX gimmicks.

### A4. Storyboards, multi-shot and full-clip choreography at Higgsfield

- **Popcorn**: storyboard/image-sequence generator with "visual memory" across frames, style locking from frame 1, re-render with consistent character; exports to animation (✅ [Higgsfield blog, 2026-06-30](https://higgsfield.ai/blog/how-to-keep-ai-persona-consistent-higgsfield-popcorn)). Frame count/references not stated.
- **Multi-shot in one generation**: Cinema Studio 2.0 manual multi-shot ≤6 shots/≤12 s (✅); 3.5 `multi_prompt` (◐); 4.0 relies on Seedance 2.5 writing cuts into the prompt (◐).
- **Choreography**: Higgsfield does **not** expose per-character paths or a timeline of positions in Cinema Studio. Blocking is done by (a) prose ("Character Anchor Block": identity, screen position, depth layer, frame occupancy, orientation, pose, gaze, contact points, state lock, expression — ◐ community), (b) start/end/multi-keyframe images, (c) `@Video` motion references (Genjutsu / Kling 3.0 Motion Control), and now (d) **Blender** via the add-on/Bridge (A6). Community testing of 2D staging diagrams with Seedance: orientation followed **6/12 times — chance** (◐); practical limit "≤3 tracked characters" (◐).

### A5. Characters, lipsync, UGC/ads, video-to-video

| Higgsfield feature | What it does (Nov 2026) | Routes to (best evidence) |
|---|---|---|
| **Soul / Soul 2.0 / Soul Cinema** | House image models for fashion/realistic stills; Soul Cinema is the CS 3.x image default (◐) | Higgsfield in-house (◐) |
| **Soul ID** | Train a reusable identity: 20+ portraits, ~3–5 min (◐ [academy](https://higgsfield.ai/academy/how-to-use/how-to-create-ai-influencer)); 5–20 photos/~10 min per another review (◐); usable via `@` in Cinema Studio | In-house fine-tune (⚠ likely LoRA/adapter) |
| **Soul Cast / AI Cast** | Generate AI actors from 8 parameter groups (genre, budget, era, 12 archetypes, identity, appearance, details, outfit), auto backstory/sheet (◐) | Nano Banana 2 (◐) |
| **AI Influencer Studio** | Menu-built influencer (19 settings), rebuilt 2026-10-03; then Soul ID for continuity (◐ [aiwiki](https://aiwiki.ai/wiki/higgsfield_ai_influencer/raw)) | Soul + Nano Banana (◐) |
| **Lipsync Studio / Speak / Talking Avatar** | Animate a still or re-sync a clip from audio; engines: Speak v2, lipsync-2, InfiniteTalk, Kling AI Avatar, Kling Lipsync, Veo 3 (◐ [hackceleration](https://hackceleration.com/labs/review/higgsfield)) | Third-party engines |
| **Audio** | Native-audio models; Seed Audio 1.0 scene audio; Qwen TTS; voice change; voice clone (◐) | ByteDance/Alibaba |
| **UGC Factory** | UGC avatar/ad videos, 40+ templates, 4 keyframes per generation, audio sync (✅ [Higgsfield blog](https://higgsfield.ai/blog/Higgsfield-UGC-Factory-Explained)) | Nano Banana keyframes + Veo 3 / Seedance / MiniMax (✅ blog); Kling Avatars 2.0 (◐ gaga) |
| **Marketing Studio / Click to Ad** | Product URL → ad; pulls name, description, ≤8 photos, colours, logo (✅ [academy](https://higgsfield.ai/academy/how-to-use/how-to-create-instant-ads)) | Sora 2 historically (◐) → now Seedance/Kling (⚠) |
| **Ad Multiplier** | Many edited variants of one 4–30 s ad (◐) | "Powered by Seedance 2.5" (◐) |
| **Draw-to-Video / Product Placement** | Sketch on a frame to place products/outfits (✅ [blog](https://higgsfield.ai/blog/Turn-Your-Sketch-Into-a-Cinema)) | Image edit + i2v (⚠) |
| **Genjutsu** (launched ~2026-08-31) | **Motion Transfer** (keep motion, camera, timing; rebuild cast/setting from ≤30 refs), **Object Swap**, Style option (20 looks), **Lite** (2026-10-20), Motion Library; source 4–30 s; ≤1080p (✅ [Genjutsu blog](https://higgsfield.ai/blog/higgsfield-genjutsu)) | Not disclosed |
| **Recast / Character Swap 2.0 / Face Swap** | Replace a character in any video (◐ apps list) | Not disclosed |
| **Motion Control** | Motion from a reference video onto your character (◐) | Kling 2.6/3.0 Motion Control (◐) |
| **Video Upscale** | 720p → 4K, ~20–30 credits, 3–18 min (◐) | Not disclosed (⚠ Topaz-class) |
| **Apps** (80+) | One-click recipes: Angles 2.0, Shots, Zooms, Transitions, Packshot, Giant Product, Billboard Ad, Outfit Swap, AI Stylist, Skin Enhancer, Talking Avatar, ASMR… (◐) | Mixed |
| **Shorts** | Short videos from viral presets (✅ homepage) | Mixed |

**Credit prices that matter (✅ Higgsfield pages, $49/1,000 credits):** Cinema Studio 4.0 with audio, 16:9 — 10 s: 30 cr (480p) / 70 cr (720p, ≈ $3.43) / 160 cr (1080p, ≈ $7.84); 30 s 1080p = 480 cr (≈ $23.5). Genjutsu 15 s: Motion Transfer 45/105/300 cr (≈ $2.21/$5.15/$14.70 at 480/720/1080p); Object Swap 48/112/320 cr; Lite 96/192 cr (720/1080p).

### A6. Higgsfield's 3D/Blender layer (the closest analogue to the owner's plan)

- **Higgsfield for Blender add-on** (✅ [Higgsfield blog](https://higgsfield.ai/blog/higgsfield-blender-plugin), page dated 2026-10-28; ◐ [Digital Production, 2026-09-23](https://digitalproduction.com/2026/09/23/higgsfield-brings-ai-generation-into-blender-oh-goodey/)): floating bar with **Scene Builder** (described set/layout/light as editable geometry), **3D Model** (Meshy), **Character Animation** (pre-rigged character + keyframed action from text), **Image** (Nano Banana 2, GPT Image, Seedream 5.0 Pro, Z-Image), **Video** ("generates video from the viewport using Seedance 2.5, with your scene as the starting point"), **Camera** (scene camera follows your phone's movement in real time), Asset library. Blender 5.1+, uses normal credits. It does **not** document what exactly is sent to Seedance (viewport render vs camera path vs depth) (✅ blog says not stated).
- **Blender Bridge MCP**: `https://bridge.higgsfield.ai/mcp`, added in Claude as a custom connector, lets an assistant "work with your open Blender scene" (build blockouts, invoke generation) (✅ blog). Digital Production flags repeatability/approval-boundary concerns and that inputs/outputs may be used for training under standard terms (◐).
- **3D Jutsu / Scene Builder 3D** via the Higgsfield MCP: private hosted **Blender 5.2** projects edited by an agent via `query_python`/`run_python` with revision guards, renders up to 8 PNG/MP4 per operation, GLB/.blend export; imports only curated catalogue assets (no user GLBs) (◐ community extraction of MCP tool schemas, 2026-09-26).

**Implication:** Higgsfield's Blender story is (1) Seedance 2.5 as the only video target, (2) their character models, (3) no documented per-character trajectory control. MUSE can match the plumbing with open tools and beat it on *our characters*, *model choice per shot*, and *depth/pose/trajectory guides* for open models.

### A7. Feature-by-feature: Higgsfield → buildable MUSE equivalent

Prices per second of output on Replicate unless noted (✅ pricing JSON 2026-11-05). "Gap" = cannot match today or only partially.

| Higgsfield | MUSE equivalent (route) | Price | Licence / terms | Gap? |
|---|---|---|---|---|
| Cinema Studio 4.0 (Seedance 2.5 + look presets) | **Shot generator + Camera presets**: compile preset → prompt/params per model; Seedance 2.5 (`bytedance/seedance-2.5`), Kling 4.0, MiniMax H3, Veo 3.1 Lite, Wan 3.0 | Seedance 2.5 720p $0.231/s (no video input) / $0.968/s (with video refs); Kling 4.0 1080p $0.235/s; H3 768P $0.08/s; Veo 3.1 Lite 1080p $0.08/s | Hosted provider terms | Seedance 2.5 1080p not on Replicate (480/720p only) → use Seedance 2.0 1080p ($0.45/s) or Kling 4.0 |
| Optical stack (body/lens/aperture/era/palette/lighting) | Preset compiler (prompt fragments + negative phrases) + optional **look LUT in our editor** + "hero frame" in image model (Nano Banana/FLUX.2/Qwen-Edit) | negligible (text) | — | No true optics; same as Higgsfield |
| Speed ramps (custom curve) | Editor speed curves (Media3 `SpeedProvider`, AVFoundation time scaling) applied after generation; generate at 24–30 fps, interpolate with RIFE for slow-mo | RunPod GPU time | RIFE MIT ✅ | None — better done in editor |
| DoP motion presets + Mix + intensity | **Camera Move library** (UGC-first), per-model recipes, intensity scales travel/speed; optional pre-rendered greybox reference clips (Kling 4.0/H3/Seedance) | — | — | VFX presets (Werewolf…) skipped (low UGC value) |
| Multi-shot / Popcorn storyboard | **Storyboard mode**: LLM shot list → keyframes (image models + char sheet) → per-shot generation; Kling 3.0 `multi_prompt` (≤6 shots), Wan 2.7 R2V `shot_type=multi`, PixVerse v6 multi-clip, Kling 4.0/Seedance cuts in prompt | Kling 3.0 std $0.168/s | — | — |
| Hero Frame / start-end / multi-keyframe | Kling 4.0 `start_image`+`middle_images`+`end_image`; H3/Veo/Wan 2.7/Seedance first+last | as above | — | — |
| 3D Mode (Gaussian splat reframing) | Not needed initially; use "Angles"-style image edit (Qwen-Edit-2511 multi-angle / `qwen/qwen-edit-multiangle`) for new angles of a hero frame | per image | Apache-2.0 (Qwen-Image-Edit weights) ◐ | Partial |
| Soul ID (trained identity) | **Character pack** (existing 7-image sheet + outfits) + optional **image LoRA** (FLUX.2 klein base LoRA on Replicate; Qwen image LoRA trainer) + optional **video LoRA** (Wan 2.2 / LTX-2.3 via fal trainers) | fal Wan 2.2 i2v trainer $0.005/step (1,000 steps ≈ $5); LTX-2.3 $0.0048/step | Wan Apache-2.0; LTX-2 Community (<$10M revenue) | Hosted frontier video models take no LoRA |
| Soul Cast / AI Influencer Studio | Already partially in MUSE (character creation); add parameter panel (archetype/era/budget/details/outfit) → Nano Banana/FLUX.2 sheet generation | image prices | — | — |
| Emotion Wheel | Per-character emotion tags compiled into prompt ("@Mia: hopeful → surprised at 3 s") | — | — | Same mechanism (prompt) |
| Lipsync Studio / Talking Avatar | `bytedance/omni-human-1.5` ($0.16/s), `kwaivgi/kling-avatar-v2` ($0.056–0.11/s), `kwaivgi/kling-lip-sync` ($0.014/s), `sync/lipsync-2-pro` ($0.083/s), `heygen/lipsync-precision` ($0.067/s), `wan-video/wan-2.2-s2v` ($0.02/s); open InfiniteTalk on H100 | see left | InfiniteTalk Apache-2.0 ✅; LatentSync Apache-2.0 ✅; MuseTalk MIT ✅ | — |
| Voice / TTS / voice change / clone | `minimax/speech-2.8-*` ($0.06–0.10 per 1k tokens, cloning), `elevenlabs/v3` ($0.10/1k chars), `elevenlabs/dubbing` ($0.037/s) | see left | Voice cloning only with documented consent | Voice *change* (speech-to-speech) not found on Replicate ⚠ |
| UGC Factory / Click to Ad / Ad Multiplier | **Product & Ad builder**: URL scrape → product refs → keyframes with our character → H3/Kling 4.0/Seedance ref2v → editor template | per model | Product images rights | — |
| Draw-to-Video / Product placement | Mask/sketch on keyframe → Qwen-Image-Edit-2511/Nano Banana → i2v; or video edit: Wan 2.7 VideoEdit ($0.10/s), Kling O1 ($0.084–0.168/s), Kling 4.0 `base_video` ($0.094–0.141/s) | see left | — | — |
| Genjutsu Motion Transfer | Kling 3.0 Motion Control ($0.07–0.12/s), Wan 2.2 Animate (animation $3/1,000 s runtime; replace $0.02–0.05/s), DreamActor M2 ($0.05/s), Kling 4.0 reference video | 15 s ≈ $0.30–1.80 vs Higgsfield $2.21–14.70 | Wan Animate Apache-2.0 ◐ | Multi-person mapping weak everywhere |
| Genjutsu Object Swap / Recast / Character Swap | MUSE "character swap" (exists) + Kling O1 / Kling 4.0 edit / Wan 2.7 VideoEdit / Runway Aleph 2 ($0.336/s) / Luma Modify ($0.019/M px) | see left | **H3 open-weights territory issue** (A-exec #3) | — |
| Restyle | Luma `modify-video`, Wan 2.7 VideoEdit, Kling O1 | see left | — | — |
| Edit Video / Extend (sequel/prequel) | Kling 4.0 `base_video`; Grok Imagine extension ($0.05/s, forward only); LTX-2.3 extend; Wan 2.7 i2v continuation | see left | — | Backward extension: Seedance 2.5 via BytePlus/Higgsfield; not exposed on Replicate's Seedance 2.5 page (⚠) |
| Video Upscale | `bytedance/video-upscaler` (Standard 1080p ≤30 fps $0.0069/s; Pro 4K $0.275/s), `topazlabs/video-upscale` (720→1080p30 ≈ $0.019/s; 4K30 ≈ $0.075/s), own SeedVR2 on H100 | see left | SeedVR Apache-2.0 ✅ | — |
| Shorts / viral presets / Apps | "Templates" = saved recipes (prompt + model + params + editor template) | — | — | Content library effort, not tech |
| Blender add-on + Bridge MCP | **MUSE Directed Camera** via local Blender MCP + MUSE remote MCP (Part C) | Claude tokens or owner's subscription | MCP for Blender MIT ✅; Blender Lab MCP GPL-3 ◐ | We don't offer phone-as-camera (could be added via ARKit/ARCore later) |
| Supercomputer agent / MCP for Claude | MUSE remote MCP (also lets the owner drive generation from Claude) | — | — | — |

### A8. The MUSE **Camera** control (owner's direction): one control, two modes

**Principle:** Camera is a single control on every video-generation surface (Shot, Storyboard, Ad builder, Swap). It produces a **CameraSpec** that a per-model compiler turns into what each model can actually consume. The user never sees model-specific plumbing.

```
CameraSpec {
  mode: "preset" | "directed",
  rig:   { body: "phone"|"cinema_digital"|"film_35"|"film_16"|"camcorder", lens: "clean"|"anamorphic"|"vintage"|"halation"|"macro",
           focal_mm: 14|20|26|35|50|75|85, aperture: "f1.4"|"f2.8"|"f4"|"f11", look: palette_id, lighting: preset_id },
  move:  { id: "dolly_in"|"orbit"|..., intensity: 0..1, speed: "slow"|"normal"|"fast", start_s, end_s, ease: "in_out"|... },
  angle: { height: "eye"|"low"|"high"|"overhead"|"ground", shot_size: "ECU".."ELS", dutch_deg: 0..25 },
  directed?: { camera_session_id, guide_assets: {...}, trajectories: {...}, keyframes: [...] }
}
```

**(a) Preset mode** (fast, cheap, works on Android and Mac without Blender)
1. **Rig** (hardware & look) — 5 bodies × 5 lens characters × focal × aperture × palette × lighting, defaulting to **Auto** like Higgsfield 3.5. UGC defaults matter most: *Phone (iPhone-like 24–26 mm, deep focus, slight HDR look)*, *Vlog cam*, *Creator studio (key + ring light)*, *Cinematic (Fine film, anamorphic-ish, f/2)*.
2. **Move** — UGC-first library (§C5): Static, Handheld UGC, Selfie walk-and-talk, Dolly-in (cinematic push), Dolly-out reveal, Orbit 90/180, Crane up, Tracking follow, FPV, Whip-pan (as editor transition), Dutch push, Rack focus, Crash zoom, Top-down; each with **intensity** (0–1 → travel distance/angle/shake amplitude) and **speed**. Allow **Mix** of two compatible moves only (Higgsfield's limit; reduces failures).
3. **Angle & framing** — eye/low/high/overhead/ground, shot size, Dutch.
4. **Compiler per target model** (data-driven JSON recipes, versioned):
   - prompt fragments in the model's preferred vocabulary (H3 has a camera-vocabulary prompt guide ◐; Seedance block grammar; Kling short imperative), negative phrases (e.g. "no zoom; physical dolly"), duration bounds (one primary move per 5–8 s);
   - parameters where they exist: LTX-2.3 `camera_motion` ∈ {dolly_in, dolly_out, dolly_left, dolly_right, jib_up, jib_down, static, focus_shift} (✅ Replicate schema); fal LTX-2 `camera_lora` (✅ fal);
   - **optional reference clip**: a pre-rendered greybox clip of that move (rendered once in Blender per aspect ratio/intensity, stored in R2) fed as `reference_videos` to Kling 4.0 / H3 / Seedance ("take camera work from @video_1") — this is the cheapest way to get Higgsfield-like precision without Blender per shot.
5. **Preview**: a looping greybox GIF per preset in the picker (pre-rendered; no 3D engine in the app).

**(b) Directed (Blender) mode** — the advanced mode of the same control, for a full clip
- The user (or Claude) blocks the **whole clip** in Blender on the owner's Mac: set, each character's proxy (scaled from the character's height), each character's path/poses over time, the camera rig and its path, cut points.
- Outputs (per camera session): greybox guide video, depth video, pose video, motion-track overlay video, `camera.json` (per-frame intrinsics/extrinsics), `characters.json` (per-character root path, facing, 2-D boxes, joints), start/middle/end keyframe stills, auto-written prose blocking, `.blend`.
- The app then **routes** to the best consumer: Kling 4.0 (reference video + keyframes + character refs), fal H3 Max 3d-to-video (greybox video + refs), Seedance 2.x (reference video + first frame), Wan VACE depth/pose (fal or H100) or Wan-Move/LTX motion-track (H100) when exact paths matter. Details, presets as Blender rigs, and the MCP architecture are in Part C.
- **Honest expectation:** hosted models treat guides as *strong suggestions* (fal: "camera and motion are close guidance, not exact"). Use Directed mode to get the *right shot faster* (fewer wrong-angle rerolls), not frame-accurate CG matching.
---

## Part 1 — A video editor "that rivals CapCut"

### 1.1 CapCut's feature set in 2026 (inventory)

Sources: App Store listing v20.0.0 (✅ [apps.apple.com](https://apps.apple.com/us/app/capcut-photo-video-editor/id1500855883)), CapCut tools directory and AI page (✅ [capcut.com/tools](https://www.capcut.com/tools), [capcut.com/resource/capcut-ai](https://www.capcut.com/resource/capcut-ai), [desktop editor](https://www.capcut.com/tools/desktop-video-editor)), CapCut help on Auto Cut (✅ [help](https://www.capcut.com/help/auto-cut-in-capcut)), filler words (✅ [tool page](https://www.capcut.com/tools/filler-words)), EditPilot (✅ [tool page](https://www.capcut.com/tools/edit-pilot)), March 2026 AI video maker announcement (◐ [press release](https://www.eznewswire.com/newsroom/capcut-unveils-next-generation-ai-video-suite-ultimate-creative-partner)), 2026 roundups (◐ [Pixflow](https://pixflow.net/blog/capcut-2026-update/), [AlternativeTo](https://alternativeto.net/news/2026/5/capcut-unveils-design-studio-2-0-with-infinite-canvas-ai-design-agent-and-pencil-prompting/)).

- **Editing core (✅):** trim/split/merge; multi-track timeline; speed 0.1×–100× plus **speed curves**; optical-flow smooth slow-mo; freeze; zoom animations; transitions; **keyframes "for all settings"**; chroma key; stabilization ("AI movement"); PiP/overlays; auto-reframe/aspect change keeping subjects; colour wheels/auto-adjust; colour match; remove flicker.
- **Text & captions (✅):** auto captions (speech recognition), subtitles editable on tracks, text templates, local font import, caption templates, transcript-based editing; **remove filler words**; translation of captions/speech/on-screen text (AI video translator).
- **Graphics (✅):** stickers (incl. AI stickers), hundreds of effects (glitch, blur, 3D), weekly trending filters, AI text presets.
- **Audio (✅):** millions of music clips/SFX; extract audio; TTS (many voices); custom AI voices; **voice changer**; voice enhancer; background-noise remover; vocal isolation / remove vocals; audio mixer; **beat-synced Auto Cut** ("cut on every beat vs strong beats"; "Rhythm"/beat marks).
- **Templates:** viral TikTok templates; Auto Cut from a script/beat; "long video to shorts" (✅ AI page).
- **AI generation (✅/◐):** script-to-video; AI writer; AI character (digital human lip-syncing a script); AI lip-sync generator; AI video generator / Video Studio with **Seedance 2.0/2.5, Sora 2, Kling 2.6, PixVerse, Veo 3.1** in the directory; EditPilot (agentic, text-directed timeline edits, PC); relight; background removal (auto + chroma); upscaler/enhancer; face swap; design studio (infinite canvas).
- **Export (✅):** custom resolution, **4K 60 fps, "smart HDR"**, direct sharing; desktop also exports many formats.
- **Pricing (✅ App Store IAP):** Standard $9.99/mo, Pro $19.99/mo, yearly $89.99; credit-metered AI features on Web/Desktop (◐).
- Items I could not confirm on an official CapCut page in 2026 (⚠ but long-standing CapCut features from prior knowledge): shape masks (linear/mirror/circle/rect/heart/star), blend modes, motion/camera tracking, body effects, retouch/beauty, named speed-curve presets (Montage, Hero, Bullet, Jump cut, Flash in/out).

### 1.2 Tiering for UGC/TikTok creators

| Tier | Features |
|---|---|
| **Must-have** (drives daily UGC output) | Multi-track timeline (main, overlay, text, audio); trim/split/ripple/reorder; **auto-captions with styled, animated word-by-word highlighting** and caption presets; text overlays/hooks with templates and animations; music + voiceover recording + volume/fades + **auto-ducking**; TTS voices; **silence and filler-word removal (jump cuts)**; constant speed + speed curves; basic transitions (cut, crossfade, zoom, slide/whip); 9:16 canvas, zoom/pan (Ken Burns), keyframes (position/scale/rotation/opacity); filters/LUTs + adjust; **green screen / background removal** (reaction & "greenscreen" formats); PiP (product, reaction); stickers/emoji/arrows; noise reduction/voice enhance; **beat markers / beat sync**; templates; export 1080p/4K at 30/60 fps |
| **Nice-to-have** | Masks + blend modes; motion tracking (pin text/sticker to a face/object); stabilization; auto-reframe; freeze frame; reverse; optical-flow slow-mo; effect library (shake, flash, glitch, zoom-punch); beauty/retouch; relight; colour match; voice changer/effects; AI upscaling; flicker removal; translation + dubbing with lip-sync; script-to-video; long-video-to-shorts; teleprompter; AI avatars |
| **Niche** | 3D/body effects, AI stickers/logo/design canvas, HDR export, multicam, keyframe graph editor curves, LUT authoring, cloud collaboration, chaptering, karaoke lyric styles |

### 1.3 What can be built natively vs server/AI (feasibility matrix)

Platform facts used below: Media3 `Composition` = sequences as tracks, overlays/PiP, background audio, composition-wide effects; **crossfading not yet supported** (✅ [Media3 Composition](https://developer.android.com/media/media3/transformer/composition)); effects run as GL shader chains, custom GL effects allowed, previewable in ExoPlayer (✅ [Transformations](https://developer.android.com/media/media3/transformer/transformations)); `androidx.media3.effect` ships `OverlayEffect`, `TextOverlay`, `BitmapOverlay`, `DrawableOverlay`, `CanvasOverlay`, `AlphaScale`, `Brightness`, `Contrast`, `HslAdjustment`, `RgbAdjustment`, `RgbFilter`, `SingleColorLut`, `GaussianBlur`, `Crop`, `Presentation`, `MatrixTransformation`/`GlMatrixTransformation` (per-frame), `TimestampWrapper`, `DefaultVideoCompositor`, `FrameDropEffect`, and variable speed through `EditedMediaItem.Builder#setSpeed(SpeedProvider)` (✅ [package summary](https://developer.android.com/reference/androidx/media3/effect/package-summary)); 1.9 added `CompositionPlayer` (experimental), `FrameExtractor`; 1.10 added `media3-effect-lottie`; 1.11 added pitch-preserving time-stretch (✅ [release notes](https://github.com/androidx/media/blob/release/RELEASENOTES.md)). ML Kit **Selfie segmentation** (beta, stream mode ≥20 fps) and **Subject segmentation** (beta, still images only) (✅ [selfie](https://developers.google.com/ml-kit/vision/selfie-segmentation), [subject](https://developers.google.com/ml-kit/vision/subject-segmentation)); ML Kit **GenAI Speech Recognition** is alpha (basic mode API 31+, advanced mode Pixel 10 only) (✅ [docs](https://developers.google.com/ml-kit/genai/speech-recognition/android)). On macOS: AVFoundation compositions with custom compositors, Core Image, Vision person segmentation (`VNGeneratePersonSegmentationRequest`, ◐ [docs](https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest)), and **SpeechAnalyzer/SpeechTranscriber** (iOS/macOS 26) with on-device long-form transcription, file input and per-run `audioTimeRange` timestamps (✅ [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/)).

| Feature | Tier | Android (Media3/GL/ML Kit) | macOS (AVFoundation/CI/Vision/Speech) | Server / AI (model · price · licence) |
|---|---|---|---|---|
| Multi-track timeline, preview | Must | `Composition` of `EditedMediaItemSequence`s; preview with `CompositionPlayer` (experimental) ✅ | `AVMutableComposition` + `AVVideoComposition` | — |
| Text/hook overlays, animations | Must | `TextOverlay`/`CanvasOverlay` with per-frame `OverlaySettings`; Lottie via `media3-effect-lottie` ✅ | Core Animation layer tool or custom compositor (Core Text) | — |
| Auto-captions (word timing) | Must | ML Kit GenAI SR is alpha → use **server**; or whisper.cpp on-device (MIT ✅) | **SpeechAnalyzer** on-device (macOS 26) ✅ | `victor-upmeet/whisperx` ≈ $0.022/run (word timestamps + diarization) ✅; `openai/whisper` ≈ $0.0005/run ✅; or faster-whisper/WhisperX on RunPod (MIT/BSD-2 ✅) |
| Styled caption presets (karaoke) | Must | Our renderer on `CanvasOverlay` | Our renderer | — |
| Music, VO record, fades, ducking | Must | Multiple audio sequences; custom `AudioProcessor` for gain envelopes/ducking ⚠ (build) | `AVMutableAudioMix` volume ramps; `AVAudioEngine` offline | Music gen: `google/lyria-3` $0.04/clip, `lyria-3-pro` $0.08/song, `elevenlabs/music` $0.0083/s, `minimax/music-2.6` $0.15/song ✅ |
| TTS | Must | Android `TextToSpeech.synthesizeToFile` (system voices) ◐ | `AVSpeechSynthesizer.write` ◐ | `minimax/speech-2.8-turbo` $0.06/1k tokens, `elevenlabs/v3` $0.10/1k chars ✅ |
| Silence / filler-word cut | Must | Apply cut list from transcript (trim items) | same | Word timestamps from WhisperX + LLM/regex for "um/uh/like" |
| Speed + speed curves | Must | `setSpeed(SpeedProvider)` ✅; pitch-preserving stretch (1.11) ✅ | `scaleTimeRange` per segment (piecewise curve) ◐ | Smooth slow-mo: RIFE on RunPod (MIT ✅) |
| Transitions | Must | **Crossfade unsupported in Composition** ✅ → overlap two sequences + custom `VideoCompositor`/alpha, or pre-render transition segments | `AVVideoCompositionLayerInstruction` opacity/transform ramps; custom compositor | — |
| Keyframes (pos/scale/rot/opacity) | Must | `MatrixTransformation` evaluated per presentation time; `AlphaScale` ✅ | custom compositor / layer instructions | — |
| Filters/LUTs/adjust | Must | `SingleColorLut`, `HslAdjustment`, `Contrast`, `Brightness`, `RgbAdjustment` ✅ | `CIColorCube`, `CIColorControls`, etc. | — |
| Green screen (chroma) | Must | custom `GlEffect` shader (build) | Core Image colour-cube chroma key (Apple sample) ◐ | — |
| Background removal (no green screen) | Must | ML Kit selfie segmentation (fast, hair edges weak) ✅ | Vision person segmentation (`.accurate` offline) ◐ | `arielreplicate/robust_video_matting` ≈ $0.058/run (**GPL-3.0** ✅), BiRefNet per frame (MIT ✅) / SAM 2 video `meta/sam-2-video` ≈ $0.037/run (Apache-2.0 ✅); MatAnyone is **non-commercial** (S-Lab) ✅ |
| PiP / overlays | Must | second sequence + `VideoCompositorSettings` (2×2/PiP demo) ✅ | layer instructions | — |
| Stickers/GIF/emoji | Must | `BitmapOverlay`/`DrawableOverlay`, Lottie ✅ | CALayer/Lottie-ios (Apache-2.0 ✅) | — |
| Noise reduction / voice enhance | Must | RNNoise (BSD ✅) on-device or server | `AVAudioEngine` + RNNoise | DeepFilterNet (MIT/Apache ✅) on RunPod; Demucs stems `ryan5453/demucs` ≈ $0.007/run (MIT ✅) |
| Beat markers / auto-cut to beat | Must | simple onset/spectral-flux detector (build) | same | librosa (ISC ✅) on server; avoid aubio (GPL-3 ✅) / Essentia (AGPL-3 ⚠) in-app |
| Templates | Must | JSON project templates with placeholders (our format) | same | — |
| Export 1080p/4K, 30/60 fps, HEVC | Must | Transformer (H.264/HEVC; default InAppMp4Muxer since 1.9) ✅ | `AVAssetWriter`/export presets (HEVC, ProRes) | — |
| Masks + blend modes | Nice | custom GL shaders | Core Image `CIBlendWithMask` etc. | — |
| Motion tracking (pin text to face) | Nice | ML Kit face detection per frame ⚠ | Vision face/object tracking | — |
| Stabilization | Nice | none built-in (OpenCV videostab Apache-2.0 on server ⚠) | Vision image registration ◐ | server OpenCV/ffmpeg `vidstab` (GPL build ⚠) |
| Auto-reframe 16:9→9:16 | Nice | face/subject boxes → crop path | Vision saliency | `luma/reframe-video` $0.06/s (720p out) ✅ |
| Freeze, reverse | Nice | freeze: image item from `FrameExtractor` ✅; reverse: server | `AVAssetReader` reverse | ffmpeg on server |
| Beauty/retouch, relight | Nice | — | — | MUSE "Enhance" on keyframes; video relight via Wan 2.7 VideoEdit ($0.10/s) / Kling O1 |
| Voice changer/effects | Nice | pitch via Sonic processor ⚠ | `AVAudioUnitTimePitch`, distortion/reverb | Character voice re-voice: ElevenLabs STS (not on Replicate ⚠) |
| Upscale | Nice | — | — | `bytedance/video-upscaler` from $0.0034/s ✅; `topazlabs/video-upscale` ≈ $0.0054–0.149/s ✅; own SeedVR2 (Apache-2.0 ✅) |
| Translate + dub + lipsync | Nice | — | — | `heygen/video-translate` $0.033–0.067/s ✅; `elevenlabs/dubbing` $0.037/s ✅; lipsync models in A7 |
| Script-to-video, long-to-shorts | Nice | — | — | LLM over transcript + our Shot generator |
| Smart HDR, multicam, design canvas | Niche | HDR tone-mapping supported in Composition ✅ | AVFoundation HDR | — |

**Avoid:** FFmpegKit — officially retired (✅ [repo](https://github.com/arthenica/ffmpeg-kit)); do not ship GPL components (RVM, aubio, GPL ffmpeg builds) inside the apps. Remotion is free only for companies ≤3 employees (✅ [licence](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md)) — fine for server-side template rendering now, but budget a company licence if MUSE grows.

### 1.4 Open-source building blocks and licences (checked from licence files ✅)

| Purpose | Library | Licence | Where |
|---|---|---|---|
| Android editing | AndroidX Media3 (Transformer/Effect/CompositionPlayer/Inspector/Muxer) | Apache-2.0 | App |
| Animated stickers/text | Lottie Android / iOS | Apache-2.0 | Apps |
| On-device ASR | whisper.cpp (MIT), WhisperKit (MIT), sherpa-onnx (Apache-2.0) | permissive | Apps |
| Server ASR | faster-whisper (MIT), WhisperX (BSD-2) | permissive | RunPod |
| Denoise / stems | RNNoise (BSD-3), DeepFilterNet (MIT/Apache), Demucs (MIT) | permissive | Apps/RunPod |
| Beat detection | librosa (ISC); avoid aubio (GPL-3) and Essentia (AGPL ⚠) | — | Server |
| Matting/segmentation | BiRefNet (MIT), SAM 2 (Apache-2.0); SAM 3 under Meta "SAM License" (custom); MatAnyone (non-commercial); RVM (GPL-3.0) | mixed | RunPod |
| Depth | Video-Depth-Anything **Small only** Apache-2.0 (Base/Large CC-BY-NC); Depth Anything V2 same split | mixed | RunPod |
| Interpolation | RIFE (MIT) | permissive | RunPod |
| Upscale | SeedVR/SeedVR2 (Apache-2.0) | permissive | RunPod |
| Provenance | c2pa-rs (MIT/Apache), c2pa-android, c2pa-swift | permissive | Apps/server |
| 3D preview (optional) | three.js (MIT), Filament (Apache-2.0) | permissive | Apps |
| Face identity metrics | InsightFace code MIT **but pretrained models non-commercial research only** ✅ | restricted | Avoid or license |

### 1.5 Editor roadmap (phases of ~1–2 weeks of agent work)

| Phase | Scope | Why first | Effort |
|---|---|---|---|
| **E1 Timeline v2 + Text + Captions** | Shared JSON project schema (tracks, items, keyframes, effects) used by both apps; text/hook overlays with 10 templates; auto-captions (server WhisperX on RunPod or Replicate; macOS SpeechAnalyzer offline option) with 6 styled caption presets (word highlight, pop, karaoke), caption editing; export 1080p | Captions + hooks are the #1 UGC need | 2 wk |
| **E2 Audio** | Music track, VO recording, volume envelopes, fades, auto-ducking under speech; TTS (MiniMax speech per character voice); denoise (DeepFilterNet server/RNNoise device); beat markers (librosa server) | Every UGC clip has music/VO | 1–2 wk |
| **E3 Overlays & look** | PiP/overlay track, stickers/Lottie, keyframes (pos/scale/rot/opacity) with ease curves, LUT filters + adjust, chroma key shader, basic transitions (Mac native; Android via overlapping-sequence compositor or pre-rendered transition segments) | Greenscreen/reaction/product formats | 2 wk |
| **E4 Pacing tools** | Speed curves (presets: montage/hero/bullet/flash), freeze frame, silence & filler-word removal from transcript, auto-cut to beat, smart reframe 16:9→9:16 | Retention editing | 1–2 wk |
| **E5 AI cleanup** | Background removal (server SAM 2/BiRefNet; device selfie seg preview), upscale (SeedVR2 own GPU / ByteDance upscaler), interpolation (RIFE), stabilization (server) | Quality polish | 2 wk |
| **E6 Translate & templates** | Dub/translate (ElevenLabs/HeyGen + lipsync), template library (trend formats), "long video to shorts" via transcript LLM | Scale output | 1–2 wk |
---

## Part 2 — An AI video creation suite "like Higgsfield, but ours"

### 2.1 Comparable suites (only what informs features)

- **CapCut/Dreamina** now embeds Seedance 2.0/2.5, Kling 2.6, Veo 3.1, PixVerse and an agentic EditPilot (✅ capcut.com/tools) — the editor and generator are converging; MUSE should hand generated shots straight into its own timeline.
- **Runway**: Gen-4.5, Aleph (in-context video editing; Aleph 2 on Replicate: 30-s clips, multi-shot edits, keyframe references, $0.336/s ✅ [Replicate](https://replicate.com/runwayml/aleph-2)), Act-Two performance capture (◐).
- **Kling**: 4.0 (2026-10-15 launch; 30-s single pass; "Omni Reference" up to 10 images, 5 videos, 7 subjects; better tracking/orbit moves) (◐ [Bernama press release](https://bernama.com/en/press/news.php?id=2622471)), motion control, avatar, lip-sync — all on Replicate (✅).
- **Intangible**: browser 3D scene/camera blocking, renders stills then animates with Luma/Kling/Seedance (◐ [intangible.ai](https://www.intangible.ai/enterprise/film)).
- **Mixar**: blockout → 5 keyframe poses → Seedance 2.5 with an adherence slider (◐ [mixar.app](https://www.mixar.app/blog/blender-blockout-to-video)).
- **Moonvalley Marey**: camera control (2D→3D) and trajectory control, licensed-data model (◐ [press, 2025](https://www.businesswire.com/news/home/20250708099256/en)); no public per-second API price found (⚠).
- **Hedra/Pika/Krea/OpenArt/Freepik**: talking characters, "swaps/additions", realtime/video LoRA, consistent characters and multi-model spaces — same building blocks as above; not verified in detail this session (⚠).

### 2.2 Feature → model map (Replicate first, fal where Replicate lacks it, RunPod open weights)

All prices ✅ from Replicate pricing JSON / fal `llms.txt` on 2026-11-05 unless marked. "Per s" = per second of output video.

| Feature | Best hosted options (price) | Open weights for our H100 (licence) | Notes |
|---|---|---|---|
| **Text-to-video** | MiniMax H3 $0.08/s 768P, $0.13/s 2K; H3 Lite $0.0125/s 480P, $0.02/s 768P; H3 Highspeed $0.03/s; Kling 4.0 $0.157/s 720p, $0.235/s 1080p; Kling 3.0 $0.168–0.42/s; Seedance 2.0 $0.08–1.00/s (no video in), Fast $0.07–0.15, Mini $0.04–0.09; Seedance 2.5 $0.103/s 480p, $0.231/s 720p; Veo 3.1 $0.20/s (no audio)/$0.40 (audio), Fast $0.10/$0.15, **Lite $0.05/s 720p, $0.08/s 1080p**; Wan 3.0 $0.035/0.07/0.14 (480/720/1080p), Prime 2×; Wan 2.7 $0.10/s; LTX-2.3 Pro $0.08/s 1080p…$0.32/s 4K; LTX-2.5 Fast $0.03–0.24/s; PixVerse v6 $0.05–0.23/s; Vidu Q3 Pro $0.07–0.16/s; Grok Imagine 1.5 $0.08/s; HappyHorse 1.1 $0.14–0.18/s; Gemini Omni 1.1 $0.05–0.45/s; Runway Gen-4.5 $0.12/s | Wan 2.2 A14B (Apache-2.0 ✅); LTX-2/2.3 (LTX-2 Community: free < $10M revenue, AUP requires disclosing machine-generated content and forbids non-consensual impersonation ✅); HunyuanVideo 1.5 (**licence excludes EU/UK/South Korea** ✅); MiniMax H3 open (**excludes US/EU/UK/KR** ✅) | Wan 3.0 weights not released as of Aug 2026 (◐ [Atlas Cloud](https://www.atlascloud.ai/id/blog/tips/is-wan-3.0-open-source), [EvoLink](https://evolink.ai/blog/wan-3-0-release)) |
| **Image-to-video (start/end)** | H3 first+last; Kling 4.0 start + **middle keyframes** + end; Veo 3.1 (`last_frame`); Seedance 2.x (`image` + `last_frame_image`); Wan 2.7 i2v (FLF, continuation) $0.10–0.15/s; Vidu Q3 start-end; LTX-2.3 | Wan 2.2 FLF2V (Apache-2.0); `wan-video/wan-2.2-i2v-fast` hosted $0.05–0.145/video with LoRA inputs ✅ | Keyframe-first is our consistency backbone |
| **Reference-to-video (character)** | H3 (≤9 images, ≤3 videos, ≤3 audio) ✅; Kling 4.0 (≤10 images total, videos 3–30 s) ✅; Kling 3.0 Omni (≤7 images, ≤4 with video) ✅; Seedance 2.0/2.5 (image/video/audio refs) ✅; Wan 2.7 R2V $0.10/s ✅; Grok Imagine R2V $0.05/s ✅; Veo 3.1 `reference_images` ✅ | H3 Ref2VA open (territory issue); Wan 2.1 Phantom/VACE refs (Apache-2.0 ◐) | Seedance may block realistic human faces unless registered via its asset system (◐ [apiyi docs](https://docs.apiyi.com/en/faq/seedance2-asset-face-reference)) ⚠ for AI faces on Replicate |
| **Character swap** (have) | Wan 2.2 Animate replace $0.02/s 480, $0.05/s 720 ✅; Kling O1 edit $0.084–0.168/s ✅; Kling 4.0 `base_video` $0.094–0.141/s ✅; Wan 2.7 VideoEdit $0.10/s ✅; Runway Aleph 2 $0.336/s ✅; Luma modify $0.019/M px ✅ | Wan 2.2 Animate (Apache-2.0 ◐) | Re-evaluate the RunPod H3 "Edit" path (licence) |
| **Motion transfer** (Genjutsu-like) | Kling 3.0 Motion Control $0.07/0.12/s ✅; DreamActor M2 $0.05/s ✅; Wan 2.2 Animate animation $3/1,000 s runtime ✅ | Wan 2.2 Animate; Uni3C human-motion branch (Apache-2.0 ✅) | Single performer works; groups weak |
| **Lipsync / talking** | Kling lip-sync $0.014/s; PixVerse lipsync $0.04/s; HeyGen lipsync-precision $0.067/s; sync lipsync-2-pro $0.083/s; sync react-1 $0.167/s; OmniHuman 1.5 $0.16/s; Kling Avatar v2 $0.056/0.11/s; HeyGen Avatar V $0.075/s; Wan 2.2 S2V $0.02/s; LTX audio-to-video $0.10/s; fal InfiniTalk $0.20/s ✅ | InfiniteTalk (Apache-2.0 ✅; slow, ~10+ min/clip per users ◐), LatentSync (Apache-2.0 ✅), MuseTalk (MIT ✅) | Lipsync is most reliable on 3–8 s MCU, locked camera, one face (◐) |
| **Camera motion** | Prompt vocab (all); LTX-2.3 `camera_motion` enum ✅; reference video for camera (Kling 4.0, Kling 3.0 Omni `feature`, H3, Seedance) ✅; fal LTX-2 camera LoRAs ✅ | LTX-2 camera LoRAs (dolly/jib/static), Wan2.2-Fun-Control-Camera, Uni3C, ReCamMaster, CameraCtrl (licences in Part C) | See Part C |
| **Multi-shot / storyboard** | Kling 3.0/Omni `multi_prompt` (≤6 shots, JSON) ✅; Wan 2.7 R2V `shot_type: multi` ✅; PixVerse v6 multi-clip ✅; Kling 4.0/Seedance/H3 cuts via prompt ◐ | — | Prefer generating shots separately + editor assembly for control |
| **Video extend** | Grok Imagine extension $0.05/s ✅; LTX-2.3 extend ✅; Wan 2.7 i2v continuation ✅; Kling 4.0 base video (3–30 s) | LTX-2 extend | Seams: "connect naturally, not identically" (◐ Seedance docs) |
| **Upscale / interpolation** | ByteDance video-upscaler (Std 720p ≤30 fps $0.0034/s … Pro 4K $0.275–0.55/s) ✅; Topaz (720p→1080p30 $0.019/s; 4K60 $0.149/s) ✅; FLUX video upscale $0.07–0.10 per MP·s ✅ (pricey); fal SeedVR $0.001/MP ✅ | SeedVR2 (Apache-2.0) — already run; RIFE (MIT) | Upscale only the final cut |
| **Sound / music** | Native audio in H3/Kling/Seedance/Veo/Wan 2.7/LTX; music: Lyria 3 $0.04/clip, Lyria 3 Pro $0.08/song, MiniMax music-2.6 $0.15, ElevenLabs music $0.0083/s, Stable Audio 2.5 $0.20 ✅; foley: HunyuanVideo-Foley ≈ $0.063/run ✅ | **MMAudio checkpoints are CC-BY-NC** (✅ README) — not for commercial use; HunyuanVideo-Foley licence excludes EU/UK/KR (✅) | Prefer native audio + licensed music |
| **Product placement / edit** | Kling 4.0/H3/Seedance with product image refs ("replace the perfume in [Video1] with the face cream from [Image1]" — Seedance doc pattern ✅ Replicate README); Wan 2.7 VideoEdit + reference image ✅; Kling O1 ✅ | VACE masks (Apache-2.0) | Packaging text rarely renders correctly — composite logos/text in editor |
| **TTS / voice** | MiniMax speech 2.8 (cloning) $0.06–0.10/1k tokens; ElevenLabs v3 $0.10/1k chars ✅ | Qwen3-TTS (hosted on Replicate; licence ⚠) | Consent records for any cloned voice |

### 2.3 Keeping OUR characters consistent everywhere

1. **Canonical Character Pack** (exists): 3 face close-ups + 4 full-body angles + outfits. Add metadata: height, build, signature features (the "seven-slot" description pattern ByteDance recommends: role, skin texture, facial details, eyes, hair, clothing, body/mood — ◐ community extraction of Dreamina guidance), voice ID, "do-not-change" list.
2. **Keyframe-first**: every video shot starts from a validated still generated *with the pack* (Nano Banana / Qwen-Image-Edit-2511 / FLUX.2 / Seedream) at the target framing and outfit, then i2v/ref2v. This is Higgsfield's "Hero Frame first" (✅ 2.0 guide) and the most reliable identity lock across models.
3. **Per-model reference subsets** (auto-selected by the app): H3 ≤9 images → 2 face + 2 body + outfit + keyframe; Kling 4.0 ≤10 total incl. keyframes; Kling 3.0 Omni ≤7 (≤4 with a video); Seedance: explicit role mapping per image + non-interchange lock. Never send the whole sheet as a grid (community: sheets "leak their staging/backdrop" ◐).
4. **LoRAs where possible**: image LoRA for keyframes (FLUX.2 klein base LoRA ✅ on Replicate; Qwen image LoRA trainer ✅); video LoRA only for open models — Wan 2.2 (fal i2v trainer $0.005/step ✅; Replicate `wan-2.2-i2v-fast`/`t2v-fast` accept `lora_weights_transformer` URLs ✅) and LTX-2.3 (fal trainer $0.0048/step ✅; fal LTX LoRA inference $0.002/MP ✅). ⚠ No evidence that Kling, Seedance, H3 (hosted) or Veo accept LoRAs.
5. **Identity QA**: score each output vs the pack (face-embedding similarity — avoid InsightFace pretrained models for commercial use ✅; alternatives need licence checks ⚠ — or a vision-LLM judge), flag drift, auto-suggest re-roll with a tighter keyframe. Keep characters ≥ medium shot when identity matters (faces degrade in wides ◐).
6. **Outfit/state = new asset** (community "untouched base" rule ◐): never regenerate the base face; new looks are new named assets.

### 2.4 Suite information architecture (for a UGC studio with original characters)

```
MUSE Studio
├── Cast            Characters (sheet, outfits, voice, LoRA status, consent & provenance record, "Powered by" flags)
├── Ideas           Hooks & scripts (LLM), UGC formats: talking-head, GRWM, review, unboxing, POV, skit, duet/reaction
├── Storyboard      Script → shot list → keyframes (pack-aware) → approve → batch generate → auto-assemble to Editor
├── Shot            One clip: mode {Text, Keyframes, References, Edit/Swap, Motion transfer, Extend}
│                   + Camera control (Preset | Directed) + Model picker (Auto/Draft/Final per cost) + Audio on/off
├── Camera Stage    Directed-mode sessions (Blender previs on the owner's Mac): status, guides, keyframes, chat
├── Talk            Script → voice (TTS/clone) → talking clip (avatar/lipsync) or re-dub an existing clip
├── Swap            Existing: character swap into a real clip (Draft/Standard/HD/Edit) + motion transfer
├── Product & Ads   Product refs or URL → ad templates (review, unboxing, before/after) with our characters
├── Finish          Upscale, interpolate, sound/music, captions → Editor
├── Editor          Timeline (Part 1)
└── Library/Queue   Jobs, takes, costs, versions, compare A/B, provenance (C2PA), disclosure status
```

Navigation principle: **Camera, Cast and Model picker are shared components** across Shot, Storyboard, Product & Ads and Swap, so a preset or a directed session can be reused anywhere.

### 2.5 Suite build plan (phases)

| Phase | Scope | Effort |
|---|---|---|
| **S1 Unified Shot generator** | Model registry (per-model capabilities, limits, price, licence/territory flags), adapters for H3/H3 Lite/Highspeed, Kling 4.0/3.0 Omni, Seedance 2.0/2.5, Veo 3.1 Lite, Wan 2.7/3.0, LTX-2.3; pack-aware reference selection; cost preview + budget caps; draft→final ladder (H3 Lite/Seedance Mini → H3/Kling 4.0) | 2 wk |
| **S2 Storyboard** | Script → shot list (LLM) → keyframes with the pack → per-shot generation → auto-assemble in Editor; Kling `multi_prompt` option | 2 wk |
| **S3 Talk** | Voices per character, TTS, talking-head (OmniHuman 1.5 / Kling Avatar v2 / InfiniteTalk on H100), re-dub with lipsync (Kling lip-sync cheap draft, sync-2-pro final) | 1–2 wk |
| **S4 Product & Ads** | URL scrape → product pack; 8 UGC ad templates; product placement via refs/edit models; logo/text composited in Editor | 1–2 wk |
| **S5 Motion & Swap 2.0** | Motion transfer (Kling 3.0 MC, Wan Animate), swap path licence fix, trend "motion library" | 1–2 wk |
| **S6 Identity & LoRA** | Identity QA scoring; optional Wan 2.2 / LTX-2.3 character LoRA training jobs (fal or RunPod) after licence decision | 2 wk |
---

## Part 3 — "Blender-style" camera direction for AI video

### 3.1 How creators direct camera with 3D in 2025–2026

The dominant pattern (◐ [CozyClay, Sep 2026](https://cozyclay.org/greybox-to-video/), [Mixar, Aug 2026](https://www.mixar.app/blog/blender-blockout-to-video), [Flick](https://flick.art/blog/blender-ai-filmmaking), [MoveSmith add-on](https://github.com/Guo-0111/movesmith-blender), [fal H3 Max 3D-to-video](https://fal.ai/h3-max-3d-to-video)):

1. **Block at real scale** with primitives/mannequins; silhouette and scale matter more than detail; no textures (photos/textured renders make the model preserve unwanted surfaces).
2. **Place and animate the camera** (lens, height, path). A few well-spaced keyframe poses communicate a move better than many near-identical frames (Mixar: "five poses is a complete move").
3. **Export guides**: flat-shaded greybox/clay playblast (no gizmos/grid/outlines), optional depth (normalised distance), first/last (and middle) frames.
4. **Generate with a short prompt** for materials/light/mood; camera and blocking come from the reference. **Iterate on the greybox, not the prompt.**
5. Per-model notes from 2026 practice: Seedance 2.5 takes a first frame + a reference clip (a white-model clip guides camera, pacing and blocking); Kling — first frame + simple moves, motion control for characters, and cuts may cause trimming; Veo — first/last frames only, expect drift on long moves; H3, Wan 3.0 (`reference_video`), LTX and fal render-to-real consume a reference clip (◐ CozyClay). Social posts describe "Claude → Blender (via an MCP bridge) → playblast → Seedance 2.5" chains (◐ [X post](https://x.com/JSFILMZ0412/status/2093663876692754713), unverified).

Local/open pipelines (ComfyUI) instead feed **depth/pose/edge** control videos to Wan VACE or LTX IC-LoRAs, or **camera trajectories** to Uni3C/Wan-Fun-Camera/ReCamMaster.

### 3.2 Which models actually accept guidance, and how

| Model (host) | Guidance it accepts | Limits (✅ schema/page) | Price | Fit |
|---|---|---|---|---|
| **Kling 4.0** (Replicate `kwaivgi/kling-v4.0`) | `reference_videos` "to take motion, camera work or style from"; `start_image` + **`middle_images`** (ordered keyframes) + `end_image`; `reference_images`; `base_video` to edit | videos 3–30 s, 700–4553 px/side, ≤300 MB; ≤10 images total; 720p/1080p; AR 16:9, 9:16, 1:1, 21:9 | $0.157/s 720p, $0.235/s 1080p; **with video input $0.094/$0.141/s** | ★ Best hosted target for Directed mode (greybox clip + keyframes + character refs) |
| **Kling 3.0 Omni** (`kwaivgi/kling-v3-omni-video`) | `reference_video` with `video_reference_type: "feature"` (style/camera reference) or `"base"` (edit); `multi_prompt` ≤6 shots | ref video 3–10 s, 720–2160 px; ≤4 images with a video; native audio mutually exclusive with reference video | $0.168–0.42/s | Good for camera transfer from greybox |
| **MiniMax H3 Max 3D-to-video** (fal `minimax/h3-max/3d-to-video`) | `video_url` = Blender render (Workbench/EEVEE); keeps "camera move, blocking, timing and cuts"; ≤8 reference images; scene-intent prompt | ≤15 s and ≤32 shots; 480p/768p/1080p; "camera and motion are close guidance, not exact" | $0.05/0.08/0.16 per s (5-s minimum) + ref tokens; ≈ $0.96 for 5 s 768p with own refs ✅ | ★ Purpose-built for Blender greybox → photoreal; supports cuts |
| **MiniMax H3** (Replicate) | `reference_video_urls` (≤3), images (≤9), audio (≤3), first/last frame; refs "guide character, motion, camera, style, voice, editing rhythm" | 4–15 s; 768P/2K | $0.08/s, $0.13/s | Good; same family as our current swap |
| **Seedance 2.0 / 2.5** (Replicate) | `reference_videos`, `reference_images`, `reference_audios`, first `image`, `last_frame_image` | 2.5 on Replicate: 480p/720p | 2.5 with video in: **$0.43/s 480p, $0.97/s 720p**; 2.0 with video in: $0.10–1.25/s | Strong interpreter of camera intent; "grasps the meaning" rather than copying (◐); expensive with video refs |
| **Wan 2.7 R2V** (Replicate) | `reference_videos` of the *character/object* (identity, not camera) | 720p/1080p | $0.10/s | Not a camera tool |
| **Veo 3.1 / Lite** | start + last frame, ref images | 4–8 s | Lite $0.05–0.08/s | Keyframe-only control |
| **LTX-2.3 Pro** (Replicate) | `camera_motion` ∈ {none, dolly_in, dolly_out, dolly_left, dolly_right, jib_up, jib_down, static, focus_shift}; retake; extend; audio-to-video | up to 4K/50 fps | $0.08/s 1080p | Only hosted model with a camera enum |
| **LTX-2 19B video-to-video** (fal) | IC-LoRA **depth / canny / pose** control videos (with built-in preprocessors) + `camera_lora` | — | $0.0018/MP (≈ $0.20 for 121 frames 720p) | Exact structure from depth/pose; LTX realism < Kling/Seedance |
| **Wan VACE 14B depth/pose** (fal `fal-ai/wan-vace-14b/depth`, `/pose`) | depth (or pose) video + `ref_image_urls` + first/last frame | 16 fps billing | $0.04/0.06/0.08 per video-second (480/580/720p) | Exact structure + our character refs; 720p max |
| **Open on H100** | Wan2.2-VACE-Fun-A14B (depth/pose/MLSD/canny/trajectory) ✅ HF; Wan2.2-Fun-A14B-Control-Camera (camera poses) ✅ HF; **Uni3C** (camera + human motion, Wan, ComfyUI built-in node, experimental) ✅; **ReCamMaster** (re-shoot an existing video along a new trajectory; Wan 2.1 1.3B, ≤81 frames, ≤1280×720 ◐); **Wan-Move** 14B 480P (point trajectories, Apache-2.0 ✅); **LTX-2.3 IC-LoRA Motion-Track** (coloured spline tracks) and Union Control ✅; CameraCtrl, GEN3C | 480–720p, ~5 s per pass | GPU time only | Precise but lower realism; use as a first stage, then refine/upscale or feed as reference to a hosted model |

Licences: VACE, VideoX-Fun, Wan 2.2, Uni3C, CameraCtrl, GEN3C (code), Wan-Move → Apache-2.0; ReCamMaster → MIT; LTX-2.x LoRAs → LTX-2 Community Licence (free under $10M annual revenue; AUP requires disclosing machine-generated content) (✅ licence files / model cards). GEN3C weights licence not checked (⚠).

### 3.3 Blunt limits — what will not work well (yet)

- **No hosted model reproduces a Blender camera path frame-accurately.** They interpret ("close guidance, not exact" — fal; Seedance "interprets rather than copies" — ◐). Expect framing/speed drift on long or compound moves; Veo drifts on long moves (◐).
- **Multi-character blocking** beyond 2–3 people, crossing paths, occlusion and "who is who" mapping are unreliable; staging diagrams tested at chance level with Seedance (◐ 6/12). Mitigate: keyframes that already contain the correct characters in the correct positions, explicit role mapping, ≤3 characters per shot, split complex blocking into shots.
- **Rack focus, whip pans, dolly-zoom, crash zoom** are hit-and-miss. LTX has `focus_shift`; otherwise do whip pans and zoom-punches as **editor transitions/effects**, and pull focus via start/end keyframes with baked DOF.
- **Lipsync + camera motion conflict**: talking shots should be locked-off/handheld-subtle MCU, 3–8 s (◐).
- **Greybox look can bleed** into photoreal output (CG feel) — keep guides flat grey, untextured, and always pair with photoreal keyframes/character refs (◐).
- **Depth/pose-controlled open models** (VACE, Wan-Fun, LTX IC-LoRA) give precise structure but 480–720p and visibly less realism; plan a second pass (Kling 4.0/H3 with the open-model output as reference video, or SeedVR2 upscale).
- **Video-reference pricing**: Seedance 2.5 with video references is 4× its no-video price ($0.97/s at 720p); Kling 4.0 is actually cheaper with video input.
- **Faces in wide shots** degrade; keep hero faces ≥ medium shot or fix in post (◐).
- **Content filters**: Seedance may reject realistic faces as references unless registered (◐); hosted moderation false positives on AI influencers are likely (⚠).

### 3.4 Owner addendum: Blender via an MCP bridge (no Blender inside the app)

#### 3.4.1 Building blocks

| Component | Choice | Facts |
|---|---|---|
| Local Blender MCP | **MCP for Blender** (formerly `blender-mcp`, ahujasid) — **MIT** ✅ | Blender add-on opens a **TCP socket server inside Blender (default `localhost:9876`)**; a separate MCP server (stdio, `uvx mcp-for-blender`) relays JSON commands `{type, params}` → `{status, result}`; tools: `execute_blender_code`, `look` (viewport/camera/multi-angle/animation strip/render), `get_scene_info`, `generate_3d`, asset search/import (Poly Haven, Sketchfab, Poly Pizza), status, telemetry controls; setup for Claude Desktop (`claude_desktop_config.json`) and Claude Code (`claude mcp add blender uvx mcp-for-blender`); **socket has no auth/encryption**; optional `BLENDER_MCP_SAFE_MODE=1` blocks file/network/subprocess code; minimal anonymous telemetry by default, `DISABLE_TELEMETRY=true` turns it off; run only one MCP server instance (✅ [README](https://github.com/ahujasid/blender-mcp)) |
| Alternative | **Blender Lab official MCP server** — GPL-3.0-or-later, Blender 5.1+, v1.0.0 2026-04-27, v1.0.3 2026-09-11, 26 tools incl. code exec, screenshots, Blender API/manual search, background-process (`_for_cli`) variants; "runs LLM-generated code without any guards", VM recommended; **same default port 9876 as the community add-on** (◐ [StraySpark comparison](https://www.strayspark.studio/blog/official-blender-mcp-server-comparison-2026)) | Prefer the official one if you want docs search + background renders; never run both on 9876 |
| Remote MUSE MCP | New Streamable-HTTP server in the existing Node/TS service on Railway | MCP spec 2026-07-28: stateless requests, Tasks extension for long-running ops, MCP Apps for inline UI (✅ [spec](https://modelcontextprotocol.io/specification/latest)); HTTP servers SHOULD implement OAuth 2.1 with **Protected Resource Metadata (RFC 9728)**, resource indicators, PKCE, audience-bound tokens; client registration via Client ID Metadata Documents (preferred), pre-registration, or (deprecated) DCR (✅ [authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)) |
| Claude entry (owner's subscription) | Claude Desktop / claude.ai custom connector (remote) + local stdio Blender MCP; Claude Code: `claude mcp add --transport http muse https://…/mcp` with OAuth via `/mcp` or a bearer header (✅ [Claude Code MCP docs](https://code.claude.com/docs/en/mcp)) | Claude custom connectors use OAuth; redirect `https://claude.ai/api/mcp/auth_callback` (◐ vendor docs) |
| In-app chat | Claude API (Messages) tool loop on our server, Opus 5.5 `claude-opus-5-5` at **$4 / $20 per MTok**, cache reads $0.20/MTok, 5-min cache write $5/MTok; Sonnet 5.5 $2/$10 (✅ [pricing](https://platform.claude.com/docs/en/about-claude/pricing)); MCP connector (`mcp_servers` + `mcp_toolset`, beta) can call our remote MUSE MCP directly (✅ [docs](https://platform.claude.com/docs/en/agents-and-tools/mcp-connector)) | Blender tools must run on the Mac → relayed (below) |
| Optional: route in-app chat into the owner's running Claude Code | **Claude Code "channels"** (research preview): an MCP server that pushes events into a running session and receives replies; Pro/Max individual accounts skip org gating; custom channels need `--dangerously-load-development-channels` during preview; events only while the session is open; channel servers negotiating protocol revision 2026-07-28 are not registered on the v2 runtime (✅ [channels docs](https://code.claude.com/docs/en/channels)) | Lets in-app messages use the owner's subscription instead of API tokens |

#### 3.4.2 Architecture (both entry points share one camera session)

```
                         ┌───────────────────────── Railway (Node/TS) ─────────────────────────┐
 Owner's Claude Desktop  │  MUSE API  ── camera_sessions (Postgres) ── R2 (guides, renders)   │
 / Claude Code  ──HTTPS──▶  MUSE MCP server (OAuth 2.1, Streamable HTTP)                        │
   (subscription)        │     tools: camera.* , cast.* , assets.*                              │
        │ stdio          │  Director service (Claude API tool loop, Opus 5.5)  ◀──HTTPS── MUSE  │
        ▼                │     tools: same camera.* in-process + blender.* (relayed) ── WS ──┐  │  Android/Mac chat
 MCP for Blender server  └──────────────────────────────────────────────────────────────────│──┘
        │ TCP localhost:9876                                                                 │
        ▼                                                                                    ▼
 Blender (owner's Mac) + MUSE add-on (rigs, presets, render passes, writes to session folder)
        ▲  localhost:9876 (relay)                    MUSE Mac app: WS relay for blender.* calls,
        └──────────────────────────────────────────  folder watcher → uploads renders to R2 → attach
```

- **Camera session** (`cs_<ulid>`): owner, title, aspect, fps, duration, target model(s), cast (character IDs), status (`drafting|blocking|rendering|ready|generating|done|failed`), revision, transcript (messages from any entry point), assets (typed), `camera.json`, `characters.json`, chosen preset(s), and generation jobs.
- **Entry point (b) — owner's Claude app/Code:** the owner says "Open camera session cs_… and block a 6-s walk-and-talk for Mia and Leo, orbit 90° at the end". Claude calls `camera.get_session`, `cast.get_character` (signed sheet URLs + height/proportions), drives Blender via `execute_blender_code` calling **MUSE add-on operators** (not free-form geometry code where avoidable), checks with `look`, then renders. Renders go to `~/MUSE/CameraSessions/<id>/out/`; the **Mac app** uploads them to R2 and calls `attach_asset` itself — Blender Python never needs network access or tokens (compatible with Safe Mode). Claude then calls `camera.update_camera_path`, `camera.update_blocking`, `camera.set_status("ready")`.
- **Entry point (a) — chat inside MUSE (Mac or Android):** the app posts to `/director/chat`; the server runs the Claude tool loop (holding the API key, budgets and logs). `camera.*` tools execute in-process; `blender.*` tools are **relayed over a WebSocket to the owner's Mac app**, which forwards them to `localhost:9876` and returns results/screenshots. If the Mac is offline, the session queues and the chat says so. Same transcript and assets as entry point (b).
- **Optional mode (c):** a small "MUSE channel" plugin for Claude Code subscribes to the session's chat stream and injects in-app messages into the owner's running Claude Code session (subscription-billed); replies flow back via the channel's reply tool into the session transcript. Research-preview risk; keep (a) as the default.
- **No spend by agents:** `camera.submit_generation` only creates a **draft job with a cost estimate**; actual generation requires the owner to tap "Generate" in the app (or an explicit, per-session spending allowance the owner sets).

#### 3.4.3 MUSE MCP tool surface (proposal)

| Tool | Purpose |
|---|---|
| `camera.list_sessions` / `camera.create_session` / `camera.get_session` | Discover/create/read sessions (spec, status, revision, transcript tail, assets) |
| `camera.post_message` | Append to the shared transcript (so the app shows what Claude did) |
| `cast.get_character` | Sheet image URLs (short-lived), height, build, outfit refs, voice, "do-not-change" notes |
| `camera.list_presets` / `camera.get_preset` | Rig/move/angle presets with parameters (§3.5) |
| `camera.get_target_spec` | What to render for a target model (fps, size, max duration, frame multiple, which guides) |
| `camera.update_camera_path` | Validate + store `camera.json` (schema below) |
| `camera.update_blocking` | Validate + store `characters.json` |
| `camera.attach_asset` | Register an uploaded asset (kind: `greybox`, `depth`, `pose`, `tracks`, `keyframe_start/mid/end`, `blend`, `preview`) — normally called by the Mac app watcher |
| `camera.set_status` | Workflow state |
| `camera.estimate_generation` / `camera.submit_generation(dry_run=true)` | Cost estimate + draft job; owner approval required to run |
| Resource `muse://camera-session/{id}` | Read-only snapshot for clients that prefer resources |

Auth scopes: `camera:read`, `camera:write`, `cast:read`, `assets:write`, `generate:estimate` (no `generate:run` for agents by default). Tokens audience-bound to the MUSE MCP URL; session IDs unguessable; every write checks the session owner.

#### 3.4.4 What Blender renders for each target model

| Target | Render | Notes |
|---|---|---|
| Kling 4.0 | `greybox.mp4` (Workbench, flat grey, no overlays) at target AR, 24 fps, ≥720 px short side, 3–30 s → `reference_videos`; keyframes: start/mid/end clay stills → restyled to photoreal with the character pack (Qwen-Image-Edit-2511/Nano Banana) → `start_image`/`middle_images`/`end_image`; pack images → `reference_images` (≤10 images total) | Prompt: "take camera work and blocking from @video_1; @image_n is Mia…" |
| H3 Max 3D-to-video (fal) | `greybox.mp4` ≤15 s, ≤32 shots (cuts via camera markers), Workbench/EEVEE; ≤8 reference images | Materials are not read; describe what proxies represent |
| MiniMax H3 / Seedance 2.x | `greybox.mp4` (+ first frame photoreal keyframe, + last frame) | Seedance: explicit reference roles; ≤3 tracked characters |
| Kling 3.0 Omni | `greybox.mp4` 3–10 s, 720–2160 px, `video_reference_type: feature` | No native audio with reference video |
| Wan VACE depth (fal/H100) | `depth.mp4`: normalised inverse depth (near = white), 16 fps (fal bills at 16 fps), 480–720p; or `pose.mp4` (OpenPose-style skeleton from rigged proxies); + ref images + first frame | Frame counts 4n+1 (e.g. 81) ⚠ verify per workflow |
| LTX-2 IC-LoRA (fal/H100) | `depth.mp4` / `canny.mp4` / `pose.mp4`, or `tracks.mp4` (coloured splines of each character's root path for Motion-Track IC-LoRA, reference at 0.5× resolution) | Frames 8n+1 (e.g. 121), sizes divisible by 32 ✅ |
| Wan-Move (H100) | `tracks.json` point trajectories (projected 2-D paths per character/limb) + first frame | 480P model |
| Uni3C / Wan-Fun-Camera / CameraCtrl / ReCamMaster (H100) | `camera.json` exported to CameraCtrl/RealEstate10K-style per-frame intrinsics + world-to-camera 3×4 matrices; Uni3C additionally a rendered point-cloud guidance video | Exact formats differ per repo ⚠ — implement exporters per model |
| Veo 3.1 / any FLF model | photoreal start + end keyframes only | Camera described in prompt |

**`camera.json` (per frame):** `t`, `frame`, position (Blender Z-up and OpenCV Y-down conversions), rotation quaternion, `focal_mm`, `sensor_mm`, `fx, fy, cx, cy`, `w2c[3x4]`, `focus_distance_m`, `fstop`, `roll_deg`; header with fps, resolution, AR, cut markers. **`characters.json`:** per character ID → per frame root position/facing, screen-space bbox, visibility/occlusion %, 2-D joints (for pose/track guides), and an auto-generated prose blocking line per beat ("Mia enters frame-left at 0.0 s, walks 2.1 m to the counter, turns to camera at 3.0 s").

**Mannequins:** proxy per character scaled to the character's height (from the pack), neutral grey; distinct silhouettes (hair/bag shapes) instead of colours to avoid colour bleed; optional textured 3D proxy from the full-body sheet via `tencent/hunyuan-3d-3.1` ($0.50/unit ✅) — check Hunyuan3D licence territory before use (⚠).

#### 3.4.5 Costs and latency (estimates ⚠)

- **In-app chat (API):** a scene-building session of ~12 tool steps with prompt caching ≈ 25k cached + 2k new input + 1.5k output tokens per step → ≈ $0.05/step on Opus 5.5 → **≈ $0.50–0.80 per directed shot**; preset-driven sessions (2–3 steps via add-on operators) ≈ $0.10–0.15; Sonnet 5.5 roughly half. 100 directed shots/month ≈ $15–80.
- **Owner's Claude app/Code:** subscription usage limits, no per-token cost to MUSE.
- **Latency:** Claude step 5–30 s; Workbench render of 6 s × 24 fps at 720×1280 on Apple silicon ≈ 10–60 s; upload a few seconds; hosted generation 1–6 min. A directed shot ≈ 3–10 min end-to-end.

#### 3.4.6 Security

- Keep the Blender socket on **localhost only**; never expose 9876; the Mac app is the only relay and only accepts relay calls for sessions owned by the logged-in owner.
- Prefer **operator allowlisting**: Claude calls `bpy.ops.muse.*` (build_stage, place_character, apply_preset, set_path, render_guides, export_json) — reject arbitrary code in in-app mode (check script AST against an allowlist) and enable Safe Mode in desktop mode; run Blender under a separate macOS user or VM if free-form code is allowed (the official server itself recommends a VM ◐).
- Disable asset downloaders you don't need (StraySpark reports 2026 CVEs against the community add-on incl. a Poly Haven path traversal ◐ unverified); `DISABLE_TELEMETRY=true`.
- Treat all text from MUSE (character names, user prompts) as **data** in tool results; never put tokens in Blender scripts; R2 uploads via the app with short-lived presigned URLs.
- Licence: Blender add-ons that use `bpy` are GPL territory if distributed; our add-on is for internal use on the owner's Mac (no distribution) — fine; if ever distributed, publish it GPL.

### 3.5 Presets as Blender camera rigs (tuned starting parameters ⚠ to tune in real use)

Units: metres, seconds; "eye" = character eye height (≈ 0.93 × height). Intensity `i` ∈ [0, 1] scales the bracketed ranges. Default 24 fps, 9:16 unless noted. Each preset also has a **prompt recipe** for Preset mode.

| Preset | Rig (Blender) | Lens / DOF | Path & timing | Model notes |
|---|---|---|---|---|
| **Locked UGC talking head** | Tripod empty, camera at eye, 0.8–1.0 m | 26 mm (phone), deep focus | static; optional micro-push 0.05–0.10 m over clip | Best for lipsync; any model |
| **Handheld UGC (friend-filmed)** | Camera parented to empty with **Noise** modifiers: location amp 0.008–0.015 m @ 1.5–3 Hz, rotation 0.4–1.2° @ 0.8–2 Hz; optional walk 0.3–0.6 m/s | 24–26 mm, f/8-ish | continuous; 1 small reframe | Prompt "handheld phone footage, subtle natural shake, not chaotic" |
| **Selfie walk-and-talk** | Camera 0.5–0.7 m in front of face, facing back, parented to character root; arm sway noise 0.01–0.02 m | 24 mm, slight wide distortion | character walks 1.0–1.3 m/s | Kling 4.0 ref video; H3 |
| **Cinematic dolly-in (push)** | Camera on straight rail toward eyes | 50 mm (35 mm for 9:16 wides), f/2 focus on eyes | 3.2 m → (3.2 − [0.8..2.0]·i) m over 5–7 s; ease-in-out | LTX `dolly_in`; one move per shot |
| **Dolly-out reveal** | Reverse rail | 35 mm | 1.6 → 3.5–5 m over 6 s; ease-out | — |
| **Orbit / arc** | Camera on circle (Follow Path) around pivot at chest; Track-To pivot | 35 mm | radius 1.8–2.6 m; arc 60° + 120°·i (360° = "bullet"); 15–30°/s; 10 % ease | Kling 4.0 handles orbit "smoother" (◐ press); avoid full 360° with faces |
| **Crane up (jib)** | Camera on vertical rail + Track-To subject | 24–35 mm | height 0.6 → 0.6 + [1.5..3.5]·i m at 2.5 m distance over 5–7 s; ease-out | LTX `jib_up` |
| **Tracking follow** | Camera parented to subject root offset (behind 2 m or side 1.5 m) with lag (Damped Track) | 35 mm | matches subject speed 1.2–1.5 m/s | Prompt "camera follows at constant distance" |
| **FPV** | Bezier path, speed 6–12 m/s, height 0.5–4 m, bank roll ∝ curvature (±20–35°), high-freq noise 0.003 m | 14–16 mm | 4–8 s | Works best without close faces |
| **Whip pan** | Yaw 70–110° in 0.25–0.35 s between two 0.8–1.5 s holds; motion blur shutter 0.5–1.0 | 35 mm | — | ⚠ Models smear: implement as **editor transition** between two generated shots |
| **Dutch push** | Roll 12°–20° (static or 0→15°) + slow push 0.5 m | 35 mm | 5–6 s | Prompt "canted angle" |
| **Rack focus** | Static or micro-push 0.1–0.15 m; focus distance animates fg (0.8 m) → subject (2.5 m) in 0.6–1.0 s at t=40 % | 85 mm, f/1.4 | — | LTX `focus_shift`; else start/end keyframes with baked DOF |
| **Crash zoom** | Focal 24 → 70 mm in 0.3 s (zoom, not dolly) | — | — | Usually better as editor zoom-punch effect |
| **Low-angle hero / top-down** | Camera height 0.3–0.5 m tilted up 15–25° / 3–4 m straight down | 24–35 mm | static or slow push | Angle presets combine with any move |

Hardware ("Rig") presets compile to prompt tokens + editor LUT: *Phone (UGC)* → "shot on a smartphone, deep focus, natural HDR"; *Cinema digital* → "clean digital cinema image, 35 mm lens, shallow depth of field"; *Film 35/16* → "35 mm film grain, halation" + editor grain/halation LUT; *Camcorder* → "DV camcorder look, interlaced texture" + editor effect; *Anamorphic* → "anamorphic lens, oval bokeh, horizontal flares" (letterbox only for 16:9).

### 3.6 Camera build plan

| Phase | Scope | Effort |
|---|---|---|
| **C1 Preset mode** | CameraSpec in the Shot generator; rig/move/angle pickers with preview GIFs; per-model recipe compiler (prompt fragments, LTX enum, Kling multi-prompt); library of pre-rendered greybox reference clips per move × AR (owner renders once in Blender, or Claude does via the bridge) | 1–2 wk |
| **C2 MUSE MCP + camera sessions** | Remote MCP server (OAuth 2.1 + PRM, PAT for Claude Code), session model, tools in §3.4.3, Mac app session panel + folder watcher → R2, transcript UI on Android/Mac | 2 wk |
| **C3 MUSE Blender add-on** | Operators: build stage (floor/walls/props), place character proxies from the pack, path tools, preset rigs (§3.5), render passes (greybox/depth/pose/tracks/keyframes), JSON exports; setup guide for Claude Desktop/Code + MCP for Blender | 1–2 wk |
| **C4 In-app Director chat** | Server Claude tool loop with caching and budgets, WS relay to Mac → localhost:9876, operator allowlist; optional Claude Code channel plugin | 2 wk |
| **C5 Guide-video routes** | Adapters: Kling 4.0 (refs + middle keyframes), fal H3 Max 3D-to-video, Seedance, Kling 3.0 Omni feature ref, fal Wan VACE depth/pose, fal LTX IC-LoRA; keyframe restyle step; then optional H100 open models (Wan-Move, LTX motion-track, Uni3C) | 2 wk |
---

## Part 4 — Combined phased roadmap, effort and running costs

**Working rules for every phase (owner: "no test spending from us")**
- Every provider adapter ships with a **mock provider** and **schema contract tests** generated from the provider's published input schema (Replicate model pages expose OpenAPI; fal exposes `llms.txt`) — free to run.
- Every generation path shows a **cost preview**, enforces **per-job and per-day caps**, and requires the owner's tap to run. Agents/Claude can only create *draft* jobs.
- First real runs are **owner "canaries"** (smallest resolution/duration); a feature is "done" when wired + contract-tested, then validated by the owner in real use.
- Model registry entries carry **licence/territory flags** that hide restricted routes until the owner acknowledges them.

| # | Phase | Contents | Effort (agent-weeks) | Depends on |
|---|---|---|---|---|
| P0 | **Guardrails & decisions** | Model registry (capabilities, limits, prices, licence/territory flags), cost estimator + caps, mock providers, provenance (C2PA manifest + AI-disclosure metadata on export), remove Sora 2; **decide the H3-open-weights swap path** (license/apply, or switch to hosted H3 / Wan 2.2 Animate) | 1 | — |
| P1 | **E1 Timeline v2 + text + captions** | Shared project schema, text/hook templates, WhisperX captions + styled presets, export | 2 | P0 |
| P2 | **S1 Unified Shot generator** | Adapters (H3 family, Kling 4.0/3.0 Omni, Seedance 2.0/2.5, Veo 3.1 Lite, Wan 2.7/3.0, LTX-2.3), pack-aware references, draft→final ladder | 2 | P0 |
| P3 | **C1 Camera presets** | CameraSpec, rig/move/angle pickers + previews, per-model recipe compiler, greybox reference-clip library | 1.5 | P2 |
| P4 | **E2 Audio** | Music, VO, ducking, TTS voices, denoise, beat markers | 1.5 | P1 |
| P5 | **E3 Overlays & look** | PiP, stickers/Lottie, keyframes, LUTs, chroma key, transitions | 2 | P1 |
| P6 | **S2 Storyboard** | Script → shot list → keyframes → batch → auto-assemble in editor | 2 | P2, P1 |
| P7 | **C2 MUSE MCP + camera sessions** | OAuth MCP server, session model/tools, Mac watcher → R2, transcript UI | 2 | P3 |
| P8 | **C3 MUSE Blender add-on** | Stage/proxy/path operators, preset rigs, guide renders, JSON exports, Claude Desktop/Code setup doc | 1.5 | P7 |
| P9 | **S3 Talk** | Character voices, talking head, re-dub/lipsync | 1.5 | P2 |
| P10 | **E4 Pacing** | Speed curves, freeze, silence/filler cut, beat auto-cut, reframe | 1.5 | P1, P4 |
| P11 | **C4 In-app Director chat** | Server Claude loop + caching + budgets, WS relay to Mac/Blender, allowlisted operators; optional Claude Code channel | 2 | P7, P8 |
| P12 | **S4 Product & Ads** | URL → product pack, UGC ad templates, placement/edit routes | 1.5 | P2, P6 |
| P13 | **C5 Guide-video routes** | Kling 4.0, fal H3 Max 3D-to-video, Seedance, Kling Omni, fal Wan VACE/LTX IC-LoRA; H100 open models (Wan-Move, LTX motion-track, Uni3C) as optional | 2 | P8 |
| P14 | **E5 AI cleanup** | Background removal, upscale, interpolation, stabilization | 2 | P1 |
| P15 | **S5 Motion & Swap 2.0** | Motion transfer, trend motion library, licence-clean swap | 1.5 | P0, P2 |
| P16 | **E6 Translate & templates** | Dub/translate + lipsync, template library, long-to-shorts | 1.5 | P4, P9 |
| P17 | **S6 Identity QA & video LoRA** | Identity scoring, optional Wan 2.2/LTX-2.3 character LoRAs | 2 | P2 |

**Total ≈ 31 agent-weeks** (≈ 7–8 months sequentially; phases on different surfaces can run in parallel — e.g. editor and suite tracks — bringing calendar time to ~4–5 months with two parallel agents ⚠).

### Running-cost model (estimates ⚠; list prices ✅ as cited above)

Assumptions: 100 finished 15-s videos/month; 3 shots × 5 s each; 3 draft takes + 1.5 final takes per shot; half the videos include talking/lipsync; one upscale pass on finals.

| Line item | Lean stack | Premium stack |
|---|---|---|
| Drafts (4,500 s) | H3 Lite 768P $0.02/s → **$90** | same → **$90** |
| Finals (2,250 s Lean / 3,000 s Premium) | H3 768P $0.08/s → **$180** | Kling 4.0 1080p $0.235/s → **$705** (Seedance 2.0 1080p $0.45/s → $1,350) |
| Keyframe images (~600) | ≈ $0.02–0.04/image ⚠ → **$12–24** | same |
| Lipsync/talking (750 s) | sync lipsync-2-pro $0.083/s → **$62** (Kling lip-sync $0.014/s → $11) | OmniHuman 1.5 $0.16/s → **$120** |
| Upscale (1,500 s) | Topaz 720p→1080p30 ≈ $0.019/s → **$28** | Topaz 4K30 ≈ $0.075/s → **$112** |
| Captions, TTS, music | **≈ $20** | **≈ $40** |
| Directed camera (30 shots/mo) | Kling 4.0 w/ video 1080p, 2 takes × 6 s → ≈ $51 + Claude ≈ $20 → **$71** | same + fal H3 Max → **≈ $100** |
| RunPod (SeedVR2, WhisperX, RIFE, swap) | serverless H100 $5.39/h × ~20 h → **$108** | ~30 h → **$162** |
| **Total / month** | **≈ $570–600** | **≈ $1.3–2.0k** |

Avoid an always-on H100 pod: $1.99–3.99/h × 730 h ≈ **$1.45–2.9k/month** by itself (✅ [RunPod pricing](https://www.runpod.io/pricing)). For reference, the same 100 videos made in Higgsfield Cinema Studio 4.0 at 720p (105 credits per 15 s × 1.5 takes) ≈ 15,750 credits ≈ $770 at $0.049/credit (◐), before lipsync/upscale/edits.

---

## Part 5 — Risks and unknowns

**Licences (highest priority)**
1. **MiniMax H3 open weights** (✅ [LICENSE](https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE)): territory excludes **US, EU, UK, South Korea**; no use of the works *or outputs* outside the Applicable Territory; commercial use > $20M revenue needs written authorization; must display "MiniMax H3" in the UI; AUP requires disclosure of machine-generated content and bans non-consensual impersonation; Hong Kong courts. Comfy sells commercial licences and says licences are "available globally" but excludes resale/API-aggregator use (✅ [Comfy FAQ](https://support.comfy.org/articles/6065098425-minimax-commercial-licensing-who-needs-a-license-and-how-to-get-one)). Hosted H3 on Replicate is governed by Replicate/MiniMax hosted terms instead (⚠ not reviewed).
2. Other territory-restricted weights: **HunyuanVideo 1.5** and **HunyuanVideo-Foley** ("does not apply in the European Union, United Kingdom and South Korea") (✅ licence files). Hunyuan3D (⚠ likely similar).
3. **Non-commercial weights**: MMAudio checkpoints (CC-BY-NC), MatAnyone (S-Lab NC), InsightFace pretrained models (non-commercial research), Video-Depth-Anything & Depth Anything V2 Base/Large (CC-BY-NC) (✅).
4. **Copyleft**: Robust Video Matting (GPL-3.0), aubio (GPL-3.0), Blender Lab MCP (GPL-3.0, ◐), Essentia (AGPL ⚠), GPL FFmpeg builds — keep out of shipped apps.
5. **LTX-2 Community Licence**: free < $10M annual revenue; AUP requires "expressly and intelligibly disclaiming" machine-generated content and forbids impersonation/deepfakes without consent (✅ [LICENSE-2](https://github.com/Lightricks/LTX-2/blob/main/LICENSE-2)).

**Model/platform churn**
6. Sora 2 API removed 2026-09-24 (✅). Wan 3.0 weights unreleased (◐). Media3 `CompositionPlayer` experimental (✅). Claude Code channels in research preview (✅). MCP spec moved to stateless 2026-07-28 and deprecated DCR (✅). Higgsfield itself changes UI vocabulary every version (◐) — keep presets data-driven.
7. Kling 4.0 is brand new (launched 2026-10-15 ◐); its Replicate adapter may change. Seedance 2.5 on Replicate is 480p/720p only (✅).

**Moderation and provider behaviour**
8. Hosted filters may block realistic faces as references (Seedance asset-registration flow ◐; Higgsfield shows "May contain protected content" for real faces/IP ✅ help centre). Original AI influencers are likely to hit false positives (⚠). Unknown whether moderated/failed runs are billed on Replicate (⚠ check before scaling).
9. Some outputs carry provider watermarks/provenance (Veo outputs SynthID ✅ Replicate page) — platforms may auto-label them.

**Likeness, consent, advertising law**
10. Characters must be *original*: document that sheets were not derived from real people's photos without consent; keep a provenance record per character (sources, models, dates). Character-swapping into **real clips** uses a real performer's body/performance and the clip's copyright — license source footage and get performer consent (⚠ legal review).
11. Voice cloning only with documented consent; never clone real people's voices for characters without it.
12. **EU AI Act Art. 50**: deployers must label deepfakes; providers must mark AI outputs machine-readably; applies from 2026-08-02; final Code of Practice reportedly published June 2026 (◐ [Commission page](https://digital-strategy.ec.europa.eu/en/policies/code-practice-ai-generated-content), [Jones Day](https://jonesday.com/en/insights/2026/01/european-commission-publishes-draft-code-of-practice-on-ai-labelling-and-transparency)).
13. **New York synthetic-performer ad disclosure** (GBL § 396-b) in force since 2026-06-09: ads featuring a digitally created human performer require disclosure (◐ [Cooley](https://www.cooley.com/news/insight/2026/2026-01-29-new-york-enacts-synthetic-performer-disclosure-law-for-advertisements-including-those-using-generative-ai), [Reed Smith](https://www.reedsmith.com/our-insights/blogs/viewpoints/102n129/fake-performer-real-penalty-what-advertisers-need-to-know-before-june-9/)).
14. **FTC**: the Consumer Reviews and Testimonials rule (16 CFR Part 465) bans testimonials misrepresenting the reviewer's existence or experience — an AI influencer "reviewing" a product as if a real customer is high-risk; plus the Endorsement Guides (◐ [Fenwick](https://www.fenwick.com/insights/publications/the-ftc-cracks-down-on-fake-reviews-with-new-rule)).
15. **Platform labels**: TikTok requires labelling realistic AI content and reads C2PA (◐ [billo.app](https://billo.app/blog/ai-labeling/)); YouTube requires "altered or synthetic" disclosure and made the label more prominent in May 2026 (◐ [ppc.land](https://ppc.land/youtube-shifts-generative-ai-labels-to-spots-viewers-will-actually-see/)); Meta shows "AI info" (◐). → Default every export to "AI-generated" metadata + C2PA manifest + an in-app reminder to toggle platform labels.

**Security and operations**
16. Blender MCP executes arbitrary Python; socket unauthenticated; community add-on CVEs reported (◐); official server recommends a VM (◐). Mitigate per §3.4.6.
17. MCP OAuth mistakes (token audience, scope) can expose sessions — follow the 2026-07-28 authorization spec; never pass tokens in query strings (✅ spec).
18. Data use: Higgsfield's standard terms allow training on inputs/outputs (◐); review Replicate/fal/MiniMax/ByteDance data terms for client material (⚠).

**Open unknowns to resolve in real use**
19. How faithfully Kling 4.0 / H3 Max / Seedance follow MUSE greybox clips with 2–3 characters (no measurements yet).
20. Whether hosted models accept AI-influencer face references without moderation friction.
21. Exact trajectory/camera file formats per open repo (Uni3C, ReCamMaster, Wan-Fun-Camera) — implement exporters against each repo's examples.
22. GEN3C and Hunyuan3D weight licences; Qwen3-TTS licence; whether Replicate offers speech-to-speech voice change.
23. CapCut features not confirmed on official 2026 pages (masks, blend modes, motion tracking, named speed-curve presets).

---
## Part 6 — Sources

All accessed 2026-11-05 unless noted. Replicate prices were read from each model page's pricing JSON.

**Higgsfield (official)**
- https://higgsfield.ai/ (homepage, product list)
- https://higgsfield.ai/blog/cinema-studio-4-0 · https://higgsfield.ai/blog/cinema-studio-4-0-complete-guide (options, credit table)
- https://higgsfield.ai/blog/cinema-studio-guide (Cinema Studio 2.0)
- https://higgsfield.ai/creator-hub/help-center/tools/how-do-i-use-cinema-studio (versions 2.5–4.0; 4.0 runs on Seedance 2.5; 3.5 Claude AI Director)
- https://higgsfield.ai/creator-hub/help-center/ai-models/how-do-i-use-dop · https://beta.higgsfield.ai/posts/3TrFMRKDWXQmFenbhsxnJy (DoP categories, Mix)
- https://higgsfield.ai/blog/how-to-keep-ai-persona-consistent-higgsfield-popcorn (Popcorn)
- https://higgsfield.ai/academy/how-to-use/how-to-create-ai-influencer (Soul ID; landing page in this session)
- https://higgsfield.ai/blog/Higgsfield-UGC-Factory-Explained (UGC Factory)
- https://higgsfield.ai/academy/how-to-use/how-to-create-instant-ads (Click to Ad)
- https://higgsfield.ai/blog/Turn-Your-Sketch-Into-a-Cinema (Draw-to-Video, product placement)
- https://higgsfield.ai/blog/higgsfield-genjutsu (Genjutsu, prices)
- https://higgsfield.ai/blog/higgsfield-blender-plugin (Blender add-on, Blender Bridge MCP)

**Higgsfield (secondary)**
- https://github.com/osidemedia/higgsfield-ai-prompt-skill (community skill v3.42.0, schema snapshots 2026-09-26: Cinema Studio 2.5–4.0 vocab, motion presets, Seedance 2.5 parameters, 3D Jutsu, audio, apps, models)
- https://www.kristian-larsen.com/reviews/higgsfield-ai-review/ · https://gaga.art/blog/higgsfield-ai/ · https://creatify.ai/blog/higgsfield-pricing-(2026)-plans-and-what-you-ll-actually-pay · https://hackceleration.com/labs/review/higgsfield · https://fluxnote.io/guides/higgsfield-ai-review
- https://digitalproduction.com/2026/09/23/higgsfield-brings-ai-generation-into-blender-oh-goodey/
- https://aiwiki.ai/wiki/higgsfield_ai_influencer/raw · https://thepostflow.com/?p=9466 (AI Influencer Studio rebuild)
- https://x.com/rezkhere/status/2002064890698346907 (marketing claim of camera brands) · https://clipia.ai/en/video-models/higgsfield-dop (intensity slider)
- https://www.creativeainews.com/blog/higgsfield-genjutsu-ai-video-motion-transfer-2026/

**CapCut**
- https://apps.apple.com/us/app/capcut-photo-video-editor/id1500855883
- https://www.capcut.com/tools · https://www.capcut.com/tools/desktop-video-editor · https://www.capcut.com/resource/capcut-ai
- https://www.capcut.com/help/auto-cut-in-capcut · https://www.capcut.com/tools/filler-words · https://www.capcut.com/tools/edit-pilot
- https://www.eznewswire.com/newsroom/capcut-unveils-next-generation-ai-video-suite-ultimate-creative-partner · https://pixflow.net/blog/capcut-2026-update/ · https://alternativeto.net/news/2026/5/capcut-unveils-design-studio-2-0-with-infinite-canvas-ai-design-agent-and-pencil-prompting/ · https://flowith.io/blog/capcut-desktop-pro-2026-professional-short-form-video-accessible-billion-creators

**Android / Apple platform**
- https://developer.android.com/media/media3/transformer/composition · https://developer.android.com/media/media3/transformer/transformations · https://developer.android.com/reference/androidx/media3/effect/package-summary
- https://github.com/androidx/media/blob/release/RELEASENOTES.md (1.8–1.11.1)
- https://developers.google.com/ml-kit/vision/selfie-segmentation · https://developers.google.com/ml-kit/vision/subject-segmentation · https://developers.google.com/ml-kit/genai/speech-recognition/android
- https://developer.apple.com/videos/play/wwdc2025/277/ (SpeechAnalyzer) · https://developer.apple.com/documentation/speech/speechanalyzer · https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest
- https://rohitraj.tech/en/notes/apple-speechanalyzer-vs-whisper-on-device-stt-2026 (benchmark, secondary)
- https://github.com/arthenica/ffmpeg-kit (retired)

**Replicate model pages (prices/schemas)**
- MiniMax: https://replicate.com/minimax · /minimax/h3 · /minimax/h3-lite · /minimax/h3-highspeed · /minimax/speech-2.8-turbo · /minimax/music-2.6
- Kling: https://replicate.com/kwaivgi/kling-v4.0 · /kwaivgi/kling-v3-video · /kwaivgi/kling-v3-omni-video · /kwaivgi/kling-o1 · /kwaivgi/kling-v2.6 · /kwaivgi/kling-v3-motion-control · /kwaivgi/kling-avatar-v2 · /kwaivgi/kling-lip-sync
- ByteDance: https://replicate.com/bytedance/seedance-2.0 · /seedance-2.0-fast · /seedance-2.0-mini · /seedance-2.5 · /seedance-1.5-pro · /omni-human-1.5 · /dreamactor-m2.0 · /latentsync · /video-upscaler
- Google: https://replicate.com/google/veo-3.1 · /veo-3.1-fast · /veo-3.1-lite · /gemini-omni-1.1 · /lyria-3 · /lyria-3-pro
- OpenAI: https://replicate.com/openai/sora-2 · /openai/sora-2-pro · /openai/whisper
- Wan/Alibaba: https://replicate.com/wan-video/wan-2.7-r2v · /wan-2.7-t2v · /wan-2.7-i2v · /wan-2.7-videoedit · /wan-2.2-animate-replace · /wan-2.2-animate-animation · /wan-2.2-s2v · /wan-2.2-i2v-fast · /wan-2.2-t2v-fast · /wan2.1-with-lora · /wan-2.6-i2v · https://replicate.com/alibaba/wan-3 · /alibaba/wan-3-prime · /alibaba/happyhorse-1.1
- Lightricks: https://replicate.com/lightricks/ltx-2.3-pro · /ltx-2.5-fast · /ltx-2-retake · /audio-to-video · /ltx-2-distilled
- Others: https://replicate.com/runwayml/aleph-2 · /runwayml/gen-4.5 · /luma/ray-3.2 · /luma/modify-video · /luma/reframe-video · /pixverse/pixverse-v6 · /pixverse/lipsync · /sync/lipsync-2-pro · /sync/react-1 · /heygen/avatar-v · /heygen/lipsync-precision · /heygen/video-translate · /elevenlabs/dubbing · /elevenlabs/music · /elevenlabs/v3 · /xai/grok-imagine-video-1.5 · /xai/grok-imagine-r2v · /xai/grok-imagine-video-extension · /vidu/q3-pro · /character-ai/ovi-i2v · /topazlabs/video-upscale · /black-forest-labs/flux-video-upscale · /tencent/hunyuanvideo-foley · /tencent/hunyuan-3d-3.1 · /stability-ai/stable-audio-2.5 · /zsxkib/mmaudio · /victor-upmeet/whisperx · /vaibhavs10/incredibly-fast-whisper · /arielreplicate/robust_video_matting · /meta/sam-2-video · /ryan5453/demucs · https://replicate.com/collections/remove-backgrounds

**fal**
- https://fal.ai/h3-max-3d-to-video · https://fal.ai/models/minimax/h3-max/3d-to-video/llms.txt
- https://fal.ai/models/fal-ai/wan-vace-14b/depth/llms.txt · https://fal.ai/models/fal-ai/ltx-2-19b/video-to-video/llms.txt · https://fal.ai/models/fal-ai/ltx-2-19b/image-to-video/lora/llms.txt
- https://fal.ai/models/fal-ai/wan-22-trainer/i2v-a14b/llms.txt · https://fal.ai/models/fal-ai/ltx23-video-trainer/llms.txt
- https://fal.ai/models/fal-ai/infinitalk/llms.txt · https://fal.ai/models/fal-ai/sync-lipsync/v2/pro/llms.txt · https://fal.ai/models/fal-ai/seedvr/upscale/video/llms.txt

**Open weights, licences, model cards**
- https://huggingface.co/MiniMaxAI/MiniMax-H3 (+ LICENSE) · https://comfyui-wiki.com/en/models/minimax/minimax-h3 · https://comfy.org/minimax/license.md · https://support.comfy.org/articles/6065098425-minimax-commercial-licensing-who-needs-a-license-and-how-to-get-one · https://wavespeed.ai/blog/minimax-h3/minimax-h3-community-license/
- https://huggingface.co/Lightricks/LTX-2 · https://huggingface.co/Lightricks/LTX-2.3 · https://github.com/Lightricks/LTX-2/blob/main/LICENSE-2 · https://huggingface.co/Lightricks/LTX-2-19b-IC-LoRA-Depth-Control · https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Right · https://huggingface.co/Lightricks/LTX-2.3-22b-IC-LoRA-Motion-Track-Control
- https://github.com/Wan-Video/Wan2.2 · https://huggingface.co/alibaba-pai/Wan2.2-VACE-Fun-A14B · https://huggingface.co/alibaba-pai/Wan2.2-Fun-A14B-Control-Camera · https://github.com/aigc-apps/VideoX-Fun · https://github.com/ali-vilab/VACE · https://huggingface.co/Ruihang/Wan-Move-14B-480P
- https://github.com/ewrfcas/Uni3C · https://docs.comfy.org/built-in-nodes/WanUni3CControlnetApply · https://github.com/KwaiVGI/ReCamMaster · https://learn.thinkdiffusion.com/how-recammaster-makes-pro-level-camera-moves-easy-for-everyone/ · https://github.com/hehao13/CameraCtrl · https://github.com/nv-tlabs/GEN3C
- https://github.com/Tencent-Hunyuan/HunyuanVideo-1.5 · https://github.com/Tencent-Hunyuan/HunyuanVideo-Foley (licence files)
- https://github.com/ByteDance-Seed/SeedVR · https://github.com/MeiGen-AI/InfiniteTalk · https://github.com/bytedance/LatentSync · https://github.com/TMElyralab/MuseTalk · https://github.com/hkchengrex/MMAudio · https://github.com/PeterL1n/RobustVideoMatting · https://github.com/facebookresearch/sam2 · https://github.com/facebookresearch/sam3 · https://github.com/pq-yang/MatAnyone · https://github.com/ZhengPeng7/BiRefNet · https://github.com/DepthAnything/Video-Depth-Anything · https://github.com/deepinsight/insightface
- https://github.com/m-bain/whisperX · https://github.com/SYSTRAN/faster-whisper · https://github.com/ggml-org/whisper.cpp · https://github.com/argmaxinc/WhisperKit · https://github.com/k2-fsa/sherpa-onnx · https://github.com/xiph/rnnoise · https://github.com/Rikorose/DeepFilterNet · https://github.com/facebookresearch/demucs · https://github.com/librosa/librosa · https://github.com/aubio/aubio · https://github.com/hzwer/ECCV2022-RIFE · https://github.com/airbnb/lottie-android · https://github.com/airbnb/lottie-ios · https://github.com/remotion-dev/remotion · https://github.com/mrdoob/three.js · https://github.com/google/filament · https://github.com/contentauth/c2pa-rs · https://github.com/contentauth/c2pa-android · https://github.com/contentauth/c2pa-ios

**Camera direction practice**
- https://cozyclay.org/greybox-to-video/ · https://www.mixar.app/blog/blender-blockout-to-video · https://flick.art/blog/blender-ai-filmmaking · https://github.com/Guo-0111/movesmith-blender · https://x.com/JSFILMZ0412/status/2093663876692754713 · https://www.intangible.ai/enterprise/film · https://www.businesswire.com/news/home/20250708099256/en (Moonvalley Marey) · https://docs.comfy.org/built-in-nodes/partner-node/video/kwai_vgi/kling-camera-controls

**Kling / Seedance / Wan / Sora news**
- https://bernama.com/en/press/news.php?id=2622471 · https://letsdatascience.com/news/kling-ai-opens-kling-40-to-all-users-d9dc6422 (Kling 4.0)
- https://seed.bytedance.com/en/seedance2_5 · https://ccstartup.com/blog/2026/06/23/bytedance-unveils-seedance-2-5-a-30-second-native-4k-ai-video-model-that-accepts-50-reference-inputs/ · https://docs.apiyi.com/en/faq/seedance2-asset-face-reference
- https://developers.openai.com/api/docs/deprecations (Sora 2 / Videos API removed 2026-09-24)
- https://www.atlascloud.ai/id/blog/tips/is-wan-3.0-open-source · https://evolink.ai/blog/wan-3-0-release

**Blender MCP, MCP, Claude**
- https://github.com/ahujasid/blender-mcp (README, LICENSE: MIT) · https://www.strayspark.studio/blog/official-blender-mcp-server-comparison-2026 (official Blender Lab server, secondary)
- https://modelcontextprotocol.io/specification/latest · https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization
- https://code.claude.com/docs/en/mcp · https://code.claude.com/docs/en/channels
- https://platform.claude.com/docs/en/about-claude/pricing · https://platform.claude.com/docs/en/agents-and-tools/mcp-connector
- https://sunpeak.ai/blogs/what-are-claude-connectors/ (custom connectors, secondary)

**Compliance**
- https://digital-strategy.ec.europa.eu/en/policies/code-practice-ai-generated-content · https://jonesday.com/en/insights/2026/01/european-commission-publishes-draft-code-of-practice-on-ai-labelling-and-transparency · https://techpolicy.press/what-the-eus-new-ai-code-of-practice-means-for-labeling-deepfakes
- https://www.cooley.com/news/insight/2026/2026-01-29-new-york-enacts-synthetic-performer-disclosure-law-for-advertisements-including-those-using-generative-ai · https://www.reedsmith.com/our-insights/blogs/viewpoints/102n129/fake-performer-real-penalty-what-advertisers-need-to-know-before-june-9/ · https://www.hunton.com/privacy-and-cybersecurity-law-blog/new-york-enacts-law-regulating-the-use-of-ai-generated-synthetic-performers-in-advertising
- https://www.fenwick.com/insights/publications/the-ftc-cracks-down-on-fake-reviews-with-new-rule · https://frostbrowntodd.com/ftcs-new-rule-on-consumer-reviews-ensuring-compliance-with-human-and-ai-generated-content
- https://billo.app/blog/ai-labeling/ · https://ppc.land/youtube-shifts-generative-ai-labels-to-spots-viewers-will-actually-see/ · https://www.maginative.com/article/tiktok-partners-with-c2pa-to-label-ai-generated-content-and-promote-media-literacy/

**Infrastructure**
- https://www.runpod.io/pricing
