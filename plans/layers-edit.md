# Layers in Edit: MUSE's answer to Higgsfield Miracle (design only)

_Written 2026-11-11 by a planning session for the coordinator. Nothing here is built, paid for or called. Prices were
read on the providers' public pages on 2026-11-11 (links in the table); each is marked **listed** (printed on the page)
or **estimated** (GPU seconds × the page's rate, or our own guess). The owner decides spend and order before any build._

## What Miracle showed (the demo, 2026-11-06, private beta)
1. Every video opens as **layers**: people, a tree, the background float apart.
2. **Move** a person to a new spot; box a tree and type "change tree" → a red maple.
3. A **"Fur length"** slider (82 → 17) on a dog: a generative change of shape.
4. **Compositing**: a race car's number 33 → 99, stuck to the door as it moves.
5. **Selective speed**: one skater at 26 % while everything else plays at 100 %.
6. **Relight** with a sun/time dial (2:24 PM → 8:55 PM).
7. **HDR recovery** of flat footage.
8. **"World knowledge"**: a Dubai skyline re-made for 2026 / 2008 / 1996.

Items 1, 4 and the colour side of 2 are mostly *tracking + compositing*: cheap, and we already own half of it.
Items 2 (move), 3, 5, 6, 7 and 8 are *generative video*: each run costs real money, quality varies, and several need
an "empty background" (clean plate) filled in behind whatever moved.

---

## Part 1 · For the owner (plain language)

### What MUSE already has (good news)
Edit already has **"Keep what you tapped"**: tap a person, pet or product and MUSE follows it through the clip
(the same tracking model family Miracle-style tools use, SAM 2). Today it does one thing with it: cut that one thing
out. All three apps (Mac, Android, the server's export) already know how to use such a cut-out on a clip. So "layers"
is mostly a new way of *using* a thing we already pay for, not a new machine.

### What you'd see in Edit (Phase 1, "Layers")
- A **Layers** button on a clip. Tap or draw a box round up to 5 things (her, the dog, the car, the sky…), name them,
  press **Find layers** (price on the button, e.g. "Find 3 layers · $0.30"). MUSE works for about a minute.
- The clip then shows a **layer list** (like Photoshop): Background, Her, Dog… Each layer has an eye (hide), and its own
  **colour, Look, brightness, blur**. "Make her coat navy" = pick her layer, pick the colour. Free and live after the
  one paid run; you can change it a hundred times.
- **Text behind her**: a title can sit *behind* a layer (she walks in front of the words), or **pinned to** a layer so it
  follows her / the car door around. That covers Miracle's "33 → 99" when the number is new text or a sticker on a
  flat surface (not a perfect repaint of the old number; that's Phase 2).
- **Background only** effects: blur, darken, swap a Look, put a different video or photo behind her.
- **Claude** can do all of it by words: "make her coat navy", "put the title behind her", "blur everything but the dog".
- Paid once per clip; the layers are kept with the clip for 30 days (re-opening is free), like captions today.

### Later phases
- **Phase 2 · "Change this" by words** (paid each time, price first, your go-ahead): box something, type "red maple",
  "remove the bin", "fur shorter". MUSE asks an AI video-edit model to repaint just that layer and keeps the rest of the
  frame untouched. Short clips only (most models stop at 5–10 s and 720p–1080p).
- **Phase 3 · Relight, one-thing slow-motion, era restyle, HDR**: wait. These are hard, costly and unreliable from the
  models we can buy today. If Higgsfield opens Miracle in its API (it says "coming soon to Higgsfield MCP"), MUSE can
  simply offer Miracle itself through your Higgsfield account; we'd build the screen, not the model. Decide then.

### Prices per clip (10 s vertical video, 1080×1920, 30 fps)
"Our cost" is what the provider charges MUSE; "Member pays" uses Edit's current rule: **cost × 2, at least $0.01**
(the same rule as today's cut-out; `EDITOR_MARKUP` = 2).

Read 2026-11-11. **L** = listed on the page; **E** = estimated (GPU time × the page's run time on the provider's own
sample, so a full 1080×1920 clip may take longer and cost more). Pages: replicate.com/pricing, fal.ai/pricing,
`https://fal.ai/models/<id>` (llms.txt), `https://replicate.com/<owner>/<model>`, muapi.ai/pricing,
higgsfield.ai/miracle, higgsfield.ai/pricing.

| What | Model · provider | Billed | Our cost (10 s clip) | Member pays (× 2) | L/E |
|---|---|---|---|---|---|
| **Find layers** (tracking, today's model) | meta/sam-2-video · Replicate (L40S $0.000975/s) | GPU-seconds | ≈ $0.04 per object pass; ≈ $0.05–0.15 for 3 objects | ≈ $0.10–0.30 | E |
| Find layers, newer, takes words ("the dog") | fal-ai/sam-3/video · fal | $0.005 per 16 frames | $0.09 | $0.19 | L |
| Same, SAM 3.1 | fal-ai/sam-3-1/video · fal | $0.01 per 16 frames | $0.19 | $0.38 | L |
| Depth (optional) | fal-ai/depth-anything-video · fal | $0.04 per s | $0.40 | $0.80 | L |
| Depth, cheaper | lucataco/depth-anything-video · Replicate (T4) | GPU-seconds | ≈ $0.04+ | ≈ $0.08+ | E |
| Soft person cut-out (hair) — today's | arielreplicate/robust_video_matting · Replicate | GPU-seconds | ≈ $0.08 | ≈ $0.16 | E |
| Person cut-out, alternative | veed/video-background-removal/fast · fal | per 30 frames | $0.08–0.12 | $0.16–0.24 | L |
| **Phase 2** remove a thing | fal-ai/void-video-inpainting · fal | per video | $0.05–0.15 | $0.10–0.30 | L |
| Phase 2 change a thing by words | wan-video/wan-2.7-videoedit · Replicate (2–10 s) | per output s $0.10 | $1.00 | $2.00 | L |
| Phase 2, 1080p | fal-ai/wan/v2.7/edit-video · fal | $0.15/s at 1080p | $1.50 | $3.00 | L |
| Phase 2, masked (720p max) | fal-ai/wan-vace-14b/inpainting · fal | $0.08 per 16 fps second | $0.80 (16 fps) – $1.50 (30 fps) | $1.60–3.00 | L |
| Phase 2, Kling | kwaivgi/kling-v4.0 · Replicate (3–30 s) | $0.141/s at 1080p | $1.41 | $2.82 | L |
| Phase 2, Kling O3 edit | fal-ai/kling-video/o3/standard/…/edit · fal (3–15 s) | $0.126/s | $1.26 | $2.52 | L |
| Phase 3 relight | minimax/h3-max/relight · fal (≤ 15 s) | $0.16/s at 1080p | $1.60 | $3.20 | L |
| Phase 3 relight, cheaper (low-res) | fal-ai/lightx/relight · fal | $0.10/s | $1.00 | $2.00 | L |
| Phase 3 restyle, cheapest | decart/lucy-restyle · fal | $0.01/s | $0.10 | $0.20 | L |
| Phase 3 restyle, top quality | runwayml/aleph-2 · Replicate (early access) | $0.336/s | $3.36 | $6.72 | L |
| Phase 3 restyle, Luma | luma/modify-video · Replicate | per output pixel | ≈ $11.80 at full 1080×1920 30 fps (≈ $4.20 at 720p) | ≈ $23.60 | L (computed) |
| Miracle itself | Higgsfield | — | **no public API, MCP or price** ("coming soon", partners only) | — | — |

Notes: fal's own SAM 2 video and BiRefNet video pages show "$0", which looks like a missing price; don't plan on
them. Many edit models stop at 720p or 5–10 s; Wan bills "video seconds" at 16 fps, so 30 fps costs about 2×. fal bills
Kling v4 edit on input + output length (≈ 2× Replicate's price for the same model). Muapi lists only a background
remover ($0.01/s, $0.10 per clip).

**Phase 1 in one line:** about **$0.10–0.30 a clip** for 3 layers (member price), **+$0.80** if depth is on. Phase 2
is about **$2–3 a 10 s run** (member price), and each "try again" costs the same again.

### Free vs paid, at a glance
| Thing | Free or paid |
|---|---|
| Finding the layers (tracking) | Paid once per clip |
| Depth ("what's in front") | Paid once per clip, optional (only needed for automatic "text behind" without tapping) |
| Recolour, Looks, blur, hide, text behind/pinned, background swap | **Free**, live, unlimited |
| Claude doing the above | Free (just chat) |
| Change/remove a thing by words (Phase 2) | Paid per run, price first |
| Relight, one-thing slow-mo, era restyle (Phase 3) | Paid, later, probably via Higgsfield |

### Build size (rough)
- **Phase 1**: server M (multi-object tracking job, storage, Claude ops), Mac M–L (layer list, per-layer looks, text
  behind), server export M, Android L (same screens + compositor). About 2–3 weeks of sessions, Mac first.
- **Phase 2**: M per app + server M (one masked-edit job, price, preview, accept/reject).
- **Phase 3**: unknown until Higgsfield says what it offers.

### What I need from you (questions)
1. **Spend**: are you happy for Phase 1 to use the per-clip prices above (member pays cost × 2)? Any cap per clip, e.g.
   "never more than $1 without asking"?
2. **Order**: Phase 1 first (cheap, reliable, mostly free to use), or do you want a Phase 2 "change this by words" test
   on one clip first, so you can judge the quality before we build screens?
3. **Apps**: Mac first, Android after (as with other Edit work)? Or both together?
4. **Depth**: include the optional depth step in Phase 1, or only tap-to-pick layers (cheaper, simpler)?
5. **Phase 3**: shall the coordinator ask Higgsfield (or watch their API/MCP) for Miracle access, and wait on relight /
   one-thing slow-mo until then?
6. **Longest clip** for layers: 30 s? 60 s? (Cost grows with length; today's cut-out stops at 120 s.)

---

## Part 2 · Technical design

### Today (as found, prod 327bb8a)
- `server/api/src/editor/providers.ts`: `EditorProvider.track(url, sec, points[])` runs `meta/sam-2-video` (pinned
  version) on Replicate with click coordinates/labels/frames, **one object id** (`click_object_ids` all `keep`),
  `mask_type: binary`, and returns a black/white mask video. `matte()` runs Robust Video Matting (person only).
  Rates: L40S $0.000975/GPU-s; estimate `GPU_SEC.track(d) = 15 + 3d` → a 10 s clip ≈ 45 GPU-s ≈ $0.044 cost, $0.088
  charged (× `EDITOR_MARKUP` 2, min $0.01). Settles on the real `metrics.predict_time`.
- `server/api/src/editor/service.ts`: job kinds `matte` / `cutout`; `options.points` (≤ 10, `{x,y,t,keep}` 0–1);
  `EDITOR_LIMITS.maxMatteSec` 120; estimate → hold → run → settle; reuse 30 days.
- Contract `server/api/src/editor/model.ts`: `VideoClip.alphaMatte?: { asset, invert? }` (a video asset, luma = alpha).
  Applied identically by: Mac `EditV2Compositor.matteImage` + `draw(…, matte:)` (stretched to the clip's frame,
  cropped with it); server `render.ts` (`format=gray[,negate]` as an extra alpha input; costs +1 in the layer budget);
  Android `CompositionEngine.kt`.
- **Drawing order rule** (model.ts ~l.987): text and captions are *always* above video/image tracks. So "text behind
  her" is impossible today without a contract change.
- Claude: `editor/mcpTools.ts` has the `matte` helper tool with `points` (estimate, then `confirm: true`).
- Higgsfield: `suite/providers.ts` `HiggsfieldProvider` (submit → status_url → download) is used only for video
  generation (`h3-hf`, MiniMax H3). Nothing for edit/segmentation. Not called for this plan.
- RunPod: `GPU_MODE=runpod` pods for H3/LatentSync, billed at `GPU_HOURLY_USD` (default $3.99/h ≈ $0.0011/s) plus pod
  start-up; designed for long generation jobs, not 45-second helpers.

### Key idea: a layer is a matted copy of the clip
Phase 1 needs almost no new rendering: a **layer = the same source clip, drawn again above the base, with
`alphaMatte` = that object's tracked mask**, carrying its own `look`/`adjust`/`filter`/`mask`/`opacity`. All three
renderers already do this. What is new:
1. **Multi-object tracking job** (one paid run → N mask videos).
2. A **contract addition** that groups those copies as layers of one clip and lets text sit between them.
3. UI to pick, name and style layers; Claude ops.

### Data model (additive; describe, don't change yet; merge only after Mac CI is green)
```ts
// Asset: unchanged kinds. Each layer's mask is a 'video' asset (grey, white = this object), like today's matte.
// Optional depth: one 'video' asset per clip, grey (white = near), same timing as the source.

type ClipLayer = {
  id: string;                 // 'l1'…
  name: string;               // "Her", "Dog" (user-editable)
  matte: string;              // asset id of the tracked mask video
  hidden?: boolean;
  look?: Look; adjust?: Adjust; filter?: FilterRef; opacity?: number; // same types as VideoClip
  blur?: number;              // 0–1, background-style blur on this layer only
  feather?: number;           // px edge softening of the matte (hair/edge cover)
  aboveText?: boolean;        // drawn after text/captions → "text behind her"
};
// VideoClip gains:
layers?: ClipLayer[];         // drawn in array order above the clip itself (the clip = "Background")
layerSource?: { job: string; objects: number; depth?: string };  // provenance for reuse/re-track
// TextItem / ImageItem gain:
pin?: { clip: string; layer: string; anchor: 'centroid' | 'top' | 'bbox'; offset?: {x:number;y:number} };
```
- **Why not separate tracks?** Layers must stay glued to the clip's trim, speed and position; separate tracks would
  drift on every edit. Inside the clip they inherit `inSec/outSec/speed/placement/keyframes` for free.
- `aboveText` is the one rule change: engines draw `layers` with `aboveText` after the text pass, clipped to the same
  clip placement. Validation: ≤ 5 layers per clip; matte assets must be `video`.
- `pin`: the server ships, per layer, a small **track file** (JSON: per-frame centroid + bbox, 0–1) computed from the
  mask when the job finishes (ffmpeg/sharp reads, cheap). Apps move the text by it; no mask decoding in the app for pins.
- Helper invalidation like `alphaMatte` today: reverse/slowmo/stabilize drop `layers` (frames no longer line up) and
  the UI offers "Find layers again"; `EditSuiteState+Keys` lists "layers" among what was dropped.

### Server
- **Job `layers`** (new kind beside `matte`): input `objects: [{name, points[] | box{x,y,w,h,t}}]` (≤ 5),
  optional `depth: boolean`. Runs SAM 2 video with **distinct `click_object_ids` per object** (the current Replicate
  model accepts several ids; check its schema at build time) → one mask video per object. If the chosen model returns a
  combined/coloured mask, split by colour with ffmpeg on the server *streaming* (no full-frame buffers in Node).
- Boxes: the Replicate SAM 2 video model takes clicks; a box becomes 3–5 positive clicks inside + negatives on the edge
  until a box-capable model (fal SAM 2/3 video) is wired. Text prompts ("the dog") need SAM 3 / Grounded-SAM: a nice
  extra for Claude; see the price table.
- Estimate: `GPU_SEC.layers(d, n)` measured on first runs (start with `15 + 3d + 1d·(n−1)`); settle on predict_time.
- Depth (optional): Video Depth Anything on Replicate/fal; stored as one asset. Used for automatic "behind" ordering of
  layers and for Phase 3 relight. Not needed for tap-picked layers.
- Track file per layer (centroid/bbox per frame) made after the masks arrive: ffmpeg `scale=160:-1,format=gray` piped
  frame by frame; memory stays small.
- **Railway (≈ 512 MB)**: the server only uploads, polls, downloads and stores. All model work stays on Replicate/fal.
  Mask videos are small (binary, x264). Export with N layers adds N alpha inputs to the ffmpeg graph: cap at 5 and
  count them in the existing layer budget (`render.ts` `cost()` +1 per layer); measure peak memory on a 1080p 10 s
  export with 5 layers before shipping.
- Reuse: same source + same objects within 30 days → no new charge (as today).
- **Phase 2 job `layerEdit`**: inputs = source window (≤ model cap), layer mask, prompt. Provider = a masked video-edit
  model (see table). Output replaces the frames only inside the (feathered) mask, composited by ffmpeg on the server so
  untouched pixels stay identical; result becomes a new helper asset (like slowmo), with "Undo / try again".

### Mac (first)
- `EditV2Compositor`: for each `layers[]` entry, a matte track like `matteTracks` today (one extra AVAsset track per
  layer), draw the source again with that matte and the layer's look/adjust over the base; `aboveText` layers in a
  second pass after text. Feather = CIMorphologyMinimum + Gaussian on the matte. Hold the 5-layer cap for decode cost.
- Edit UI: a **Layers** panel (list, eye, name, swatch), a pick mode on the preview (tap = point, drag = box, ⌥-tap =
  leave out), price on the button; per-layer Look/colour controls reuse the clip inspector.
- Pins: text inspector "Pin to…" picker.
- Snapshot tests: a probe like the oval check (layer recolour inside the mask only; text behind = text pixels hidden
  inside the mask).

### Android (after the Mac)
- `CompositionEngine.kt`: same pass with one extra decoder per layer (cap 3 on mid phones, 5 on flagships; preview may
  drop to half resolution with layers on). Same panel in `SuiteSheets`.

### Server export
- `render.ts`: per layer, `source()` the matte, `[clip][look][matte]alphamerge` overlay above the clip; layers with
  `aboveText` overlaid after the text step. Pixel tests mirror the Mac probe.

### Claude (tool ops)
- New tool `find_layers {itemId, objects:[{name, points|box|text}], depth?}` → estimate, then `confirm: true` (paid,
  owner approves in the app, as `matte` today).
- Free ops through the existing patch path: `set_layer {itemId, layer, look|adjust|filter|opacity|hidden|blur|name}`,
  `text_behind {textId, itemId, layer}`, `pin_text {textId, itemId, layer, anchor}`. "Make her coat navy" needs a coat
  layer (Claude asks to tap the coat, or uses a text prompt if SAM 3 is wired) then a hue/colour adjust on that layer.
- Claude sees layers via the existing frame/vision helpers (contact sheet with the masks outlined) to check its work.

### Phase 3 (hold)
- Relight, selective speed (needs inpainting the empty background where the slowed skater was), HDR recovery, era
  restyle: either a multi-step pipeline of costly models (each 5–10 s, 720p caps, quality drift), or Miracle via
  Higgsfield if it reaches the API. Our Higgsfield client already does submit/poll/download, so adding a Miracle
  endpoint would be small **if** it appears. Nothing in today's code or public docs suggests it is available yet.
- HDR recovery is not a gen-AI need for us: Mac HDR export is already researched in `plans/edit-xl-options.md` §6.

### Risks
- **Tracking drift / loss**: occlusion, fast motion, look-alikes (two dancers). Mitigation: "add a point" at the frame
  where it drifts (points carry `t`), re-run is charged again; show a mask preview strip before styling.
- **Hair and edges**: SAM 2 binary masks are hard-edged; recolouring hair or fur shows halos. Mitigation: feather;
  for people, combine with today's Robust Video Matting alpha (soft hair) where the layer is a person.
- **Cost on long clips**: linear in length × objects. Cap per clip (owner's answer), show price first, keep 120 s limit.
- **Railway memory**: model work never on Railway; export with many alpha inputs needs a measured cap.
- **Phase 2 quality/caps**: most video-edit models change things outside the mask, cap at 5–10 s / 720p, and may
  refuse real people. Compositing only inside the mask protects the rest; still preview before charging more.
- **Model churn / prices change**: versions are pinned (as today); prices re-read at build time.
- **Contract change**: `layers`/`aboveText`/`pin` touch the shared contract → server suite + Mac CI green before merge;
  Android tolerates unknown fields until it renders them (check the Android decoder ignores unknowns or ship together).

### Running SAM 2 / depth on our own RunPod GPU instead
- Our RunPod path bills `GPU_HOURLY_USD` (default **$3.99/h ≈ $0.0011/s**) per pod, plus boot and model-load time
  (minutes) and a network volume. Replicate's L40S is **$0.000975/s** with no idle cost, fal's H100 lists $4.50/h.
- Per second we are **not cheaper**, and a 45-second tracking job would pay several minutes of pod start each time.
  Owning the GPU only pays if a pod stays warm with steady volume (dozens of clips an hour), which MUSE doesn't have.
- **Recommendation:** run tracking and depth on Replicate/fal (Replicate first: it is already wired, versions pinned).
  Revisit RunPod only if layers become a daily, high-volume feature. Railway never runs the models (≈ 512 MB).

### Not in this plan
No detection-evasion tricks of any kind (declined items stay declined).

## Owner decisions (2026-11-11)
- Prices OK at the Edit markup (×2). Layer runs go ahead with the price shown; anything above $1 per clip asks first.
- Build Phase 1 Layers first (Mac, then server export, then Android). Phase 2 later; Phase 3 held until Higgsfield
  exposes Miracle (watch for API/MCP access).
- No depth in Phase 1.
- Longest clip for the Layers step: 60 s.
