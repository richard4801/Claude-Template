# Precise edit: change her outfit or background, keep her untouched (design only)

_Written 2026-11-12 by a planning session for the coordinator. Nothing here is built, paid for or called. Prices were
read on the providers' public pages on 2026-11-12 (links in §1). Each price is marked **L** (listed on the page) or
**E** (estimated: GPU seconds × the page's rate, or computed from a per-megapixel/per-frame rate). The owner approves
before any build. Builds on `plans/layers-edit.md` (tracking, mattes, Layers) and `editor/genjutsu.ts`._

## Owner request (2026-11-12)
> "We need an edit feature that lets us precisely change features on characters, for example outfit and background,
> while keeping the character in whatever motion they are. They won't be touched at all."

Owner decisions already made: two background modes (**Exact** and **Blended**, Claude suggests one); **Outfit** is
re-drawn by a model but mask-protected (face, hair, hands, skin, motion from the original frames); both live in Edit on
any clip as **Change outfit** and **Change background**, with a 3-frame preview and a price before running; Claude can
do it too (spend-gated Approve).

---

## Part 1 · For the owner (plain language)

### The honest headline
**No video AI model on the market today can change part of a video and promise to leave the rest pixel-for-pixel the
same.** Even the models that take a "mask" (a stencil of what to change) still re-draw the whole picture internally,
and the "kept" area comes back very slightly different. The edit models people talk about most (Kling O3, Seedance
2.5 edit, Runway Aleph, Luma Modify, Higgsfield Genjutsu) take no stencil at all: they re-draw the entire frame from
words and pictures.

So MUSE does the "untouched" part itself: after the model has worked, **MUSE pastes her original pixels back on top**,
using its own cut-out of her. That is what makes "she won't be touched" true, and it is our work, not the model's.

### What each mode does and costs (10 s clip, member price at today's Edit markup × 2)

| | **Exact background** | **Blended background** | **Change outfit** |
|---|---|---|---|
| What changes | Only the background. Her pixels are the original pixels. Optional colour match. | The whole scene is re-drawn around her and she is relit to match. | Only her clothes. Face, hair, hands, skin and motion are the original pixels. |
| Is she untouched? | **Yes, exactly.** | **No.** Her light and colour change on purpose; her face can drift slightly. Motion is kept. | **Yes outside the clothes**, with honest exceptions (see §6). |
| 720p | **≈ $0.10** | **≈ $2.10** | **≈ $4.55** |
| 1080p | **≈ $0.18** | **≈ $2.20** | **≈ $4.60** (new clothes drawn at 720p, sharpened up) |
| Asks first? (rule: above $1) | No (unless you ask for a moving AI background) | Yes, always | Yes, always |
| Longest clip | 60 s (same as Layers) | 10 s (30 s on the fallback model, higher price) | 15 s at first |
| Sound | Kept, untouched | Kept, untouched | Kept, untouched |

A new background from your Library (a photo, a location, a video) is free; an AI still costs what a Background plate
costs today; an AI **moving** background (a generated plate) adds about **$2.00**.

### The rule "ask above $1"
Every run shows its price on the button. **Any run whose member price is above $1.00 asks you first** (the same rule as
Layers: the app shows "This costs $4.55 · Run" and only runs on your tap; Claude's runs always wait for your Approve in
the app, whatever the price). Previews below $1 run straight away.

### Questions for you
1. **fal account.** The best outfit model (masked Wan VACE) is only on fal. MUSE uses fal today only with a member's own
   key. Do you want MUSE to have its own fal account (you add the key in Railway yourself; never in chat)? Without it,
   outfit uses the fallback model on Replicate, which is cheaper but less faithful (see §1).
2. **Outfit length.** Start at 15 s per outfit change? Longer clips cost more and need joins every ~8 s.
3. **Order.** Exact background first (cheap, reliable, mostly built: it reuses today's cut-out and Layers' background
   swap), then Outfit, then Blended? Or a one-clip paid quality test of Outfit and Blended first (≈ $7 total) before
   any screens are built?
4. **Mac first, Android after**, as with Layers?

---

## §1 Research: which hosted models can do this (read 2026-11-12)

"Mask" = the model takes a mask video and regenerates only the white region. "Re-render" = no mask; the whole frame is
re-drawn from a prompt plus pictures. Prices are provider cost per output second.

### Masked video inpainting (the only kind that respects a stencil)
| Model · provider | Mask? | Max length / resolution | $/s (720p / 1080p) | Source audio | Outfit pictures | Page |
|---|---|---|---|---|---|---|
| **Wan 2.2 VACE Fun A14B inpainting · fal** (`fal-ai/wan-22-vace-fun-a14b/inpainting`) | **Yes** (`mask_video_url`, or one mask image tracked) | 241 frames per run (~8 s at 30 fps, 15 s at 16 fps); **720p max** | $0.10 per 16-fps second (L) → ≈ $0.19 per real second at 30 fps (E) / no 1080p | Not returned | Yes (`ref_image_urls`) | fal.ai/models/fal-ai/wan-22-vace-fun-a14b/inpainting/llms.txt |
| Wan 2.1 VACE 14B inpainting · fal (`fal-ai/wan-vace-14b/inpainting`) | Yes | Same caps, 720p max | $0.08 per 16-fps second (L) | Not returned | Yes | fal.ai/models/fal-ai/wan-vace-14b/inpainting/llms.txt |
| VACE 14B · Replicate (`prunaai/vace-14b`) | Yes (`src_mask`) | 81 frames per run by default; 1280×720 / 720×1280 max | ≈ $0.71 per run (L, H100 time) → ≈ $0.26/s at 30 fps (E) | Not returned | Yes (`src_ref_images`) | replicate.com/prunaai/vace-14b |
| LTX-2.3 quality inpaint · fal (`fal-ai/ltx-2.3-quality/inpaint`) | Yes ("white regenerated, black preserved") | 481 frames, 1–60 fps; pixel cap not stated | $0.0024075/megapixel (L) → ≈ $0.053 / $0.12 at 24 fps (E) | Makes its own (`generate_audio`); source not kept | **No** (words only) | fal.ai/models/fal-ai/ltx-2.3-quality/inpaint/llms.txt |
| VOID video inpainting · fal | Yes, but **removes only** | 197 frames | $0.05–0.15 per video (L) | Not returned | No | fal.ai/models/fal-ai/void-video-inpainting/llms.txt |

### Re-render editors (no mask; the whole frame is re-drawn)
| Model · provider | Max length / resolution | $/s (720p / 1080p) | Source audio | Pictures | Page |
|---|---|---|---|---|---|
| **Wan 2.7 video edit · Replicate** (`wan-video/wan-2.7-videoedit`) | 2–10 s; 720p or 1080p | $0.10 / $0.10 (L, one tier) | **Kept** (`audio_setting: "origin"`) | 1 reference | replicate.com/wan-video/wan-2.7-videoedit |
| Wan 2.7 edit · fal | 2–10 s; 720p/1080p | $0.10 / $0.15 (L) | Kept ("origin") | 1 | fal.ai/models/fal-ai/wan/v2.7/edit-video/llms.txt |
| Kling O3 edit · fal (standard / pro) | 3–15 s input; output size not stated | $0.126 / $0.168 flat (L) | `keep_audio` (default on) | ≤ 4 | fal.ai/models/fal-ai/kling-video/o3/standard/video-to-video/edit/llms.txt |
| Kling O3 video edit · **Higgsfield** (`/kling-video/o3/video-edit`) | 3–15.5 s; std/pro/4k | **Not listed** (console only) | Not stated | ≤ 4 | docs.higgsfield.ai (kling-o3/video-edit) |
| Kling O1 edit · Replicate (`kwaivgi/kling-o1`, already in MUSE's registry) | 3–10 s | $0.168 (L) | `keep_audio` (default off) | ≤ 4 | replicate.com/kwaivgi/kling-o1 ("rather than relying on masking") |
| Kling 4.0 edit · Replicate / fal | 3–30 s; 720p/1080p | $0.094 / $0.141 (L), input billed too (≥ 2×) | Not stated | ≤ 10 | replicate.com/kwaivgi/kling-v4.0 |
| Seedance 2.5 edit · Replicate (`bytedance/seedance-2.5`) | 4–30 s; **480p/720p only** | $0.97 at 720p with video in (L) | New audio only | ≤ 30 | replicate.com/bytedance/seedance-2.5 |
| Seedance 2.5 video edit · **Higgsfield** | ≤ 30 s; 480p–1080p | Not listed | Not stated | ≤ 30 | docs.higgsfield.ai (seedance-2-5/video-edit) |
| Genjutsu object swap · Higgsfield (wired: `editor/genjutsu.ts`) | first 30 s, min 4 s; to 1080p | $0.3446 / $0.8346 (our table) | Not stated | 1–8 | docs.higgsfield.ai/docs/models/genjutsu/object-swap.md |
| Genjutsu restyle · Higgsfield (wired) | first 30 s | $0.681 / $1.632 | Kept | ≤ 5 | …/genjutsu/restyle.md |
| Runway Aleph 2 · Replicate (`runwayml/aleph-2`) | 2–30 s, < 16 MB | $0.336 / $0.336 (L) | Not stated | ≤ 5 keyframes | replicate.com/runwayml/aleph-2 |
| Runway Aleph 2 · Runway API | ≤ 30 s | $0.28 (L) | Not stated | ≤ 5 | docs.dev.runwayml.com/guides/pricing/ |
| Luma Modify (ray-2 / flash) · Luma or Replicate | 10–30 s | ray-2 $0.35 / ≈ $0.79 (E); flash $0.12 / ≈ $0.27; Replicate ≈ $0.42 / $0.95 (E) | Not stated | edited first frame | docs.lumalabs.ai/docs/modify-video ; replicate.com/luma/modify-video |
| Relight: lightx · fal | 49 frames default | $0.10 (L) | — | bg image | fal.ai/models/fal-ai/lightx/relight |
| Relight: Beeble SwitchX API | — | ≈ $0.10 / $0.30 at 30 fps (E) | Not stated | — | developer.beeble.ai/pricing |
| Muapi video edit (Kling O1, Seedance 2.5, Wan 2.2 "change attire", Aleph) | varies | per call, dynamic ($0.20–$4.25 base) | Kling O1 `keep_original_sound` | varies | muapi.ai/playground/group/video-edit/llms.txt |

Higgsfield's API has **no** outfit, background, relight or "Miracle" endpoint today (docs index checked). No hosted
model offers masked editing at 1080p.

### Cut-outs and clothing masks
| Tool · provider | Prompt | Output | Cost per 10 s 1080p | Page |
|---|---|---|---|---|
| **Robust Video Matting · Replicate** (wired, `matte`) | none (person) | **soft alpha** (hair) | ≈ $0.05–0.09 (E) | replicate.com/arielreplicate/robust_video_matting |
| VEED background removal · fal | none | soft alpha | $0.15–0.225 (L) | fal.ai/models/veed/video-background-removal |
| Muapi video-background-remover | none | alpha, keeps audio | $0.01 base (L) | muapi.ai |
| **SAM 2 video · Replicate** (wired, `track`) | taps | binary mask | ≈ $0.044 (E) | replicate.com/meta/sam-2-video |
| **SAM 3 video · fal** | **words** ("dress", "jacket"), taps, boxes | binary mask | $0.094 (L) | fal.ai/models/fal-ai/sam-3/video |
| SAM 3.1 video · fal | words, several objects | binary | $0.19 (L) | fal.ai/models/fal-ai/sam-3-1/video |
| SAM 3 video · Replicate (`lucataco/sam3-video`) | words | binary | ≈ $0.05–0.10 (E, L40S time not verified) | replicate.com/lucataco/sam3-video |

No hosted clothing-parsing video model exists (SCHP, segformer-clothes: weights only). SAM 3 with words is the only
hosted "find the jacket" option; it is binary, so its edges are softened with the person matte.

### Recommendations
| Mode | Default | Fallback | Why |
|---|---|---|---|
| **Exact background** | Robust Video Matting · Replicate (wired) + our composite | VEED video background removal · fal (better hair, 3×) | Cheap, soft hair edges, already in prod; her pixels are never sent to a generator. |
| **Blended background** | Wan 2.7 video edit · Replicate ($0.10/s, keeps sound, 1080p, 10 s) | Runway Aleph 2 · Replicate ($0.336/s, 30 s) for longer clips or when Wan fails; Kling O3 edit on Higgsfield once its price is read | Cheapest re-render with a background picture, on our main provider; Aleph is the strongest relight. |
| **Outfit** | Wan 2.2 VACE Fun inpainting · fal (mask + outfit pictures, 720p) + our composite | VACE 14B · Replicate (Pruna) if no fal account; last resort Wan 2.7 edit · Replicate (re-render) + our clothing-only composite | Only masked models keep her body where it is; the composite then makes everything outside the clothes exact. |
| Clothing mask | SAM 3 video by words (fal), or SAM 2 taps (Replicate, wired) when no fal account | painting in the app | |

---

## §2 Pipelines

Common to all three: **audio is never sent anywhere**. The final file is `ffmpeg -map 0:v(new) -map 1:a(source)
-c:a copy`, trimmed to the clip. Source fps and frame count are kept: models that return other fps are resampled to the
source timeline before compositing, and the composite is checked frame-count-exact.

### A. Exact background (her pixels are the original pixels)
1. **Matte** (provider): Robust Video Matting on the clip range → soft alpha video (today's `matte` job; reused free
   for 30 days if it already exists on this clip).
2. **New background** (no provider, or a generator): a Library photo/video/location; an AI still (today's Background
   plate job); or an AI moving plate (Wan 2.7 i2v from the still, ≈ $0.10/s, asks above $1).
3. **Light match** (our server, optional, never re-draws her): measure, per shot, the colour of the new background
   near her outline and of her own pixels (mean and spread in Lab on 160-px thumbnails, every 5th frame, smoothed over
   time) → a **grade** for her layer (white balance, exposure, contrast, saturation), plus an optional **edge light**
   (light wrap: the blurred background added in a thin band just inside her matte edge, 0–30 %). Both are
   parameters on the clip, not baked pixels, so they can be turned off or tuned for free.
4. **Composite**: non-destructive in the edit. The clip gets `alphaMatte` (exists today) and the new background goes
   below it (Layers' `layerBase` swap, or a clip on a lower track). Preview draws live on Mac/Android; export bakes it.
5. **Edges**: matte feather 0–4 px (`feather` from Layers), spill suppression (the old background's colour pulled out
   of semi-transparent hair pixels; only alpha < 1 pixels are touched, i.e. edges, never her solid pixels).
6. **Temporal**: the matte is a video model (temporally stable); the grade is smoothed (EMA over ~1 s, reset at cuts).
7. **Where**: matte on Replicate; grade measurement on Railway (thumbnails, streaming, tiny); composite in the apps
   (preview) and the existing server export (`render.ts`, one alpha input, already under the 512 MB budget: 197 MB at 0
   layers, 366 MB at 3 layers measured for Layers).

### B. Blended background (scene re-drawn, she is relit)
1. **Matte** (as A.1) — used for the preview and for the optional "Keep her face exact" step.
2. **Edit model** (provider): Wan 2.7 video edit with the clip, a prompt built by Claude ("Replace the background with
   the attached place; keep the woman's pose, face, hair, outfit and every movement exactly; relight her to the new
   light") and the background picture as reference. `audio_setting: "origin"`.
3. **Check** (our server, free): frame-difference of her matte region vs the source (motion check). If her outline
   moved more than a threshold (pose drift) on > 5 % of frames, the result is flagged "her movement changed" before
   it is saved, and the run can be retried on the fallback model.
4. **Optional "Keep her face exact"**: paste the original face (SAM 3 "face", feathered 6 px) over the result with the
   grade from A.3 so it sits in the new light. Off by default: in Blended, the relit face is the point.
5. **Audio**: Wan keeps it; we still remux the source to be bit-exact.
6. **Where**: model on Replicate; check and remux on Railway (streaming, low memory).

### C. Change outfit (only the clothes are re-drawn)
1. **Person matte** (Replicate RVM, as A.1): soft alpha, also used for edges.
2. **Clothing mask** (provider): SAM 3 video with words from the picked garment ("dress", "top and jeans") or taps
   (SAM 2, wired), or the member's painted mask (§4). Several garments = one mask (union).
3. **Protect mask** (provider + server): SAM 3 "face", "hair", "hands" (one SAM 3.1 run, several objects) → eroded 2 px.
4. **Edit mask** (our server, ffmpeg, streaming): `clothing ⊕ dilate(8–24 px, the "fit" setting) − protect`, then
   ∩ person matte for "Fitted" (outline stays) or not for "Loose" (the new garment may go past her old outline, e.g. a
   long skirt over jeans: then a band of background is also re-drawn). Shown to the member before paying (§4).
5. **Edit model** (provider): Wan 2.2 VACE Fun inpainting at 720p with `video_url`, `mask_video_url`, the outfit's
   pictures as `ref_image_urls` (MUSE outfit: front, ¾, side, back; product photo: one; words: none) and a prompt
   ("She wears <outfit description>; same pose and movement"). The model caps at 241 frames, so clips longer than
   ~8 s at 30 fps run in **windows of ≤ 241 frames with a 16-frame overlap**, each window after the first starting
   from the previous window's last frames (VACE's first-frame input) and cross-faded inside the mask over the overlap.
6. **Composite back** (our server): `out = source × (1 − m) + model × m`, where `m` = the edit mask feathered 3 px. So
   every pixel outside the mask is the source pixel, **bit-exact**. 1080p sources: the model's 720p clothing is
   scaled up (Lanczos + mild sharpen) inside the mask only; the face and everything else stay native 1080p.
7. **Temporal**: masks are video-tracked; the model is a video model; windows overlap; the mask feather is constant
   over time. A flicker check (mean change inside the mask between frames vs the source's own change) flags bad runs.
8. **Audio**: remux source.
9. **Where**: segmentation and VACE on fal/Replicate; mask maths and the composite on Railway as **streaming ffmpeg**
   (three inputs: source, model, mask; frames never held in Node). 720p 10 s fits easily; 1080p 15 s is the cap on
   Railway (measure peak before shipping, as Layers did; expected below the 366 MB Layers figure). Longer or 4K: the
   RunPod GPU worker (`RUNPOD_WORKER_CAPABILITIES` gets `composite`) — not needed for the first version.

### Fallback outfit path (no fal account)
VACE 14B on Replicate (Pruna) with the same mask and pictures, 81-frame windows (more joins). If that is down: Wan 2.7
video edit (re-render, 1080p, 10 s) with the outfit picture, then **only the clothing region** is taken from its output
(step 6, mask from a fresh SAM pass on the result ∩ the original clothing mask). Re-render models can shift her body a
little, so the server measures the overlap of new and old clothing masks; below 90 % the result is flagged "the new
clothes don't sit on her exactly" and not saved as a version unless the member keeps it.

---

## §3 Prices (10 s clip, 30 fps; today's Edit markup `EDITOR_MARKUP` = 2, minimum $0.01)

| Step | Model · provider | Cost 720p | Cost 1080p | L/E |
|---|---|---|---|---|
| Person matte | RVM · Replicate | $0.049 (GPU_SEC.matte 50 s × $0.000975) | ≈ $0.09 | E |
| Clothing mask (words) | SAM 3 video · fal | $0.094 | $0.094 | L |
| Clothing mask (taps) | SAM 2 · Replicate | $0.044 | $0.044 | E |
| Protect mask (face/hair/hands) | SAM 3.1 · fal | $0.19 | $0.19 | L |
| Outfit generation | Wan 2.2 VACE Fun · fal, 300 frames + 16 overlap ≈ 19.75 "16-fps seconds" × $0.10 | $1.98 | $1.98 (made at 720p) | E |
| Blended | Wan 2.7 edit · Replicate | $1.00 | $1.00 | L |
| Blended fallback | Aleph 2 · Replicate | $3.36 | $3.36 | L |
| AI moving background | Wan 2.7 i2v · Replicate | ≈ $1.00 | ≈ $1.00 | E |
| Light match, masks maths, composite, remux | our server | $0 | $0 | — |

**Member price per 10 s run (× 2):**
(Sum of the steps used by that mode × 2. Outfit taps 720p: 0.049 + 0.044 + 0.19 + 1.98 = $2.263 → $4.53.)

| Mode | 720p | 1080p | Asks first (> $1)? |
|---|---|---|---|
| Exact background (Library background) | **$0.10** | **$0.18** | No |
| Exact + AI moving background | $2.10 | $2.18 | Yes |
| Blended background (includes her matte for the motion check) | **$2.10** | **$2.18** | Yes |
| Blended, fallback (Aleph 2) | $6.82 | $6.90 | Yes |
| Change outfit (words mask, fal) | **$4.63** | **$4.71** | Yes |
| Change outfit (taps mask, cheaper) | **$4.53** | **$4.61** | Yes |
| Outfit fallback (Wan 2.7 edit + masks + composite) | $2.75 | $2.84 | Yes |
| **3-frame preview** — Exact | free once the matte exists (the matte is the $0.10–0.18 above, reused by the run) | | No |
| 3-frame preview — Outfit | ≈ $0.12 (3 masked image edits with the outfit pictures, MUSE's image model) + the masks (reused by the run) | | No |
| 3-frame preview — Blended | ≈ $0.08 (3 image edits) | | No |

Rule (same as Layers): **a run whose member price is above $1.00 needs the go-ahead** — the app sends `acceptUsd`,
otherwise the server answers 409 `price_confirm`; Claude's runs always need the owner's Approve in the app. A 24 fps
clip costs about 20 % less for Outfit. Prices are re-read at build time; model versions are pinned.

---

## §4 UX

### Flow (both apps)
1. Select a clip → **Change outfit** or **Change background** (in the clip's helper menu, beside Layers and Cut out).
2. **Background**: pick the mode (two segmented options, **Exact** / **Blended**, Claude's suggestion pre-selected with
   one line of why, e.g. "Exact: the new place has similar light, and her face stays exactly as filmed").
   Pick the new background: Library photo or video, Locations, "Describe" (AI still), or "Moving AI background".
   **Outfit**: pick from her MUSE outfits (each shows its 7 pictures' front image), a product photo (upload), or
   words. Then "What to change": chips found by SAM 3 words ("Top", "Jeans", "Jacket") or "Tap the clothes".
3. **Check the mask**: the clip scrubs with the mask tinted (changed area in the accent colour, protected areas
   outlined). Tools: **Add** brush, **Keep** brush, size slider, **Fit**: Fitted / Loose. A painted frame becomes extra
   points for the tracker and re-runs only the mask (cheap, price shown). Exact mode shows her cut-out instead
   (edge softness and spill sliders).
4. **Preview 3 frames** (start, middle, end; the member can drag any of the three markers): a strip of before/after
   pairs. Exact preview is live and free; Outfit/Blended previews are stills from an image model, labelled
   "Preview stills: the video run follows them closely but isn't identical".
5. **Price and run**: one primary button with the price ("Change outfit · $4.53"). Above $1 a confirm sheet repeats the
   price, the length and what stays untouched. The job runs in the queue (survives deploys like other paid jobs).
6. **Result**: a **new version** of the clip, saved to Library as "<take> · outfit: Linen set" / "· background: Lisbon
   street", linked to the original. In Edit the clip switches to it (derived asset, like slowmo/stabilize); a
   **Compare** toggle (hold to see the original) and a one-line honesty note when a check flagged something.
7. **Undo**: one Undo restores the original clip (history entry, as every helper); the paid result stays in Library
   for 30 days, so Redo is free. Exact background is non-destructive: changing the background later is free.

### Mac
Inspector panel on the right (no bottom sheets): sections Mode · New background/outfit · Mask · Preview · Run. Mask
painting on the viewer with the pointer; ⌥-drag = Keep brush, `[` `]` brush size, ⌘Z undo stroke. Tooltips on every
icon button. Preview strip under the viewer.

### Android
Full-height bottom sheet with steps as one scrolling page (not a wizard); mask painting on the preview with a finger,
two-finger pan/zoom, brush toggle Add/Keep; 48 dp targets; back closes the sheet and keeps the draft. Preview pairs
swipe horizontally.

### Text mockup (Mac inspector, Outfit)
```
┌ Change outfit ───────────────────────────────────────────┐
│ New outfit                                               │
│  [■ Linen set]  [□ Black slip]  [□ Upload product photo] │
│  or describe: [ cream linen shirt and wide trousers    ] │
│                                                          │
│ What changes                                             │
│  (Top ✓) (Jeans ✓) (Belt)        Tap the clothes         │
│  Fit   ( Fitted | Loose )                                │
│  Mask  [Add brush] [Keep brush]  size ──●──              │
│  Face, hair, hands and skin stay exactly as filmed.      │
│                                                          │
│ Preview                                                  │
│  0:01 [before|after]  0:05 [before|after]  0:09 [b|a]    │
│  Preview stills · $0.12                                  │
│                                                          │
│ 10.0 s · made at 720p, clothes sharpened to 1080p        │
│ Where she moves fast, clothing edges may look soft.      │
│                                                          │
│              [ Change outfit · $4.53 ]                   │
└──────────────────────────────────────────────────────────┘
```
Design rules (muse-design-review): one primary button with the price; no sparkle icons; plain verbs; "Model · Provider"
label from the server in the model line under Run (`Wan 2.2 VACE · fal`); designed loading (mask strip skeleton),
empty (no outfits yet → "Make an outfit" link), error ("The model refused this clip (real person). Nothing was
charged.") and offline states.

---

## §5 Claude tools

Both follow the existing paid-helper pattern (`editor/mcpTools.ts` line ~80: without `confirm` → estimate; with
`confirm: true` → the owner approves in the app; above $1 the approval card shows the price).

```ts
edit_change_background {
  sessionId, itemId,
  mode?: 'exact' | 'blended' | 'auto',          // auto = Claude's rule below, reason returned
  background: { asset?: string; locationId?: string; describe?: string; moving?: boolean },
  lightMatch?: { grade?: boolean; edgeLight?: number /*0–0.3*/ },   // exact only, free to change later
  keepFaceExact?: boolean,                      // blended only
  preview?: boolean,                            // returns 3 before/after frames (vision) + estimate; no run
  confirm?: boolean
} → { mode, reason, estimateUsd, previewFrames?, needsConfirmation?, jobId? }

edit_change_outfit {
  sessionId, itemId,
  outfit: { outfitId?: string; uploadId?: string; describe?: string },
  garments?: string[],                          // SAM 3 words: ["top", "jeans"]; default: all clothing
  points?: KeepPoint[],                         // taps, as matte/find_layers
  fit?: 'fitted' | 'loose',
  preview?: boolean, confirm?: boolean
} → { estimateUsd, maskSummary, previewFrames?, needsConfirmation?, jobId? }
```
Claude must preview first (it looks at the 3 frames with the existing frame/vision helpers), tell the owner in one line
what it saw, then ask with `confirm: true`. Results announce themselves like masks do today (`maskNotice.ts`:
"Changed the background of clip 2 (Exact)").

**How Claude picks Exact vs Blended** (stated in the reply, owner can override):
- **Exact** when: the owner's character must stay as filmed (default for MUSE models); the new background is a real
  photo/video/location; the light direction and colour are roughly similar (measured from both); the camera is still or
  slow; she is a large part of the frame; the clip is over 10 s; or the budget is small.
- **Blended** when: the light changes a lot (day→night, indoor→sunset, coloured neon); her feet, shadow or reflection
  must touch the new ground; the camera moves with parallax that a flat background would betray; or she is small in
  frame (light mismatch shows more than face drift).
- If unsure: Exact with light match, and offer Blended as "if it looks pasted on".

---

## §6 Risks: where "she won't be touched" can't be guaranteed, and what the UI says

| Case | Why | What MUSE does / says |
|---|---|---|
| Motion blur at clothing edges | a blurred sleeve mixes clothing and background/skin in one pixel; the mask must choose | feather band re-drawn; note "Where she moves fast, clothing edges may look soft." |
| Hair over clothes | hair strands lie on the jacket; SAM's binary mask either eats hair or leaves old fabric | hair is protected (soft matte); old fabric may show between strands → note "Fine hair over the clothes may keep a trace of the old colour." Paint tools to fix. |
| Transparent / sheer / lace fabric | skin shows through; the "clothes" region contains skin | skin inside the mask is re-drawn; note "Sheer fabric: skin under it is re-drawn too." |
| Short sleeves → long, or long → short | new garment covers skin, or skin must be invented | covering: fine. Uncovering: the model draws skin, so **not her original skin** → note before paying, "Her arms will be drawn by the model where the sleeves were." |
| Loose fit (long dress over jeans) | the outline changes, background behind is re-drawn | "Loose" setting says "The background next to her changes too." |
| Hands touching clothes | hands protected, clothes under fingers re-drawn; edge seams | protect mask dilated around hands; check frames in preview. |
| Blended mode | she is relit by design; the face may drift | mode description says so; optional "Keep her face exact". |
| Exact mode light mismatch | her original light doesn't match the new place | light match grade + edge light; Claude suggests Blended when the mismatch is large. |
| 1080p outfit | model caps at 720p | "Clothes made at 720p and sharpened"; face stays native. |
| Model refuses real people | provider safety filters | error without charge where the provider doesn't bill; otherwise the paid-poll rules apply. |
| Long clips | window joins every ~8 s | overlap and cross-fade; cap 15 s at first. |
| Tracking loss (turns, occlusion) | mask drifts | mask preview strip before paying; paint to fix. |
| Bit-exact claim | model outputs are never exact | **only our composite is exact**: outside the mask, pixels = source pixels (encoder aside: the final file is re-encoded once at high quality, like every Edit export). |

UI wording rule: say what is exact ("Face, hair, hands and skin stay exactly as filmed") and list only the exceptions
that apply to this clip (from the mask: hair over clothes detected, sleeves uncovered, fast motion measured).

---

## §7 Build outline (for after approval)
- Server: job kinds `bgswap` (exact: matte + grade params; blended: edit model) and `outfit` (masks, VACE windows,
  composite); contract: `VideoClip.lightMatch?: { grade: Adjust; edgeLight: number; spill: number }` (exact, live) and
  derived op `'outfit' | 'bgblend'` for baked results (versions); Claude tools above; `features` entries with prices.
- Apps: the two panels, mask paint, preview strip, compare; Mac first, Android after; Android must keep unknown
  fields until it renders `lightMatch`.
- Checks as usual (server suite, Mac CI for contract changes). A paid one-clip quality test needs the owner's go.

Not in this plan: any detection-evasion processing (declined items stay declined).
