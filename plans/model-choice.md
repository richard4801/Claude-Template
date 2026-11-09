# Model choice everywhere (WS13, 2026-11-08)

The owner asked: *"Anywhere I need to generate images or video, or work with a video or image model generally, it should allow me to pick the model I want to use."*

The server side is on branch `claude/muse-model-choice`. It has three parts:

- **One catalog:** `GET /v1/engines[?purpose=]`.
- **One override per endpoint:** `engineModel` (video and tools) or `imageModel` (images).
  - The override is checked against the purpose's candidates and is owner only.
  - The estimate is priced on the chosen model.
- **A studio default per purpose:** `GET/PATCH /v1/engines/defaults`.

The API contract is in `plans/api.md` → "Model choice (WS13)". The code is in `server/api/src/engines/` (`purposes.ts`, `service.ts`) and `src/routes/engines.ts`.

**How a model is picked for a run:**

1. The request's override, which must be a candidate (`400 engine_not_allowed` with `valid:[…]` otherwise; `403 owner_only` for members).
2. Otherwise, the studio default for the purpose, if it is still a candidate.
3. Otherwise, the built-in behaviour: the quality ladder, or the fixed model.

For ladder purposes, a studio default that can't make a particular shot (length, aspect ratio, inputs) falls back to the ladder. The estimate then carries a member-safe warning.

**Candidates** are:

- the built-in registry models of the right kind and capability that are enabled, licensed (acknowledged) and on a provider that is set up;
- plus the studio's enabled **custom (BYO) models** of the right kind.

Members see only the custom models the owner made available (`members:true`), by display name, with no provider.

## Inventory: every server path that runs an image or video model

| Purpose | Path (endpoint → code) | Model(s) today (built-in default) | Candidates | Override and price |
|---|---|---|---|---|
| `shot` | `POST /v1/suite/shots(/estimate)` → `suite/service.ts` `plan` → `plan.ts pickModel` | Quality ladder (`DEFAULT_LADDER`, owner-reorderable); Draft starts with H3 Lite | Registry models with text, image or reference modes (H3, H3 Lite, H3 Highspeed, H3 on Higgsfield, Kling 4.0, Kling 3.0 Omni, Seedance 2.0/2.5, Veo 3.1 Lite, Wan 2.7, LTX-2.3), plus custom video models | `engineModel` (+`resolution`). Priced by `buildPlan` on that model × priceScale |
| `talking` | same, with an audio reference (or `draft.tool:'talking'`) | ladder | shot models that take reference audio (H3 family, Seedance) | same |
| `ugc` | same, `draft.tool:'ugc_ad'` | ladder | shot models that take reference images (+ custom models with images) | same |
| `storyboard` | same, `draft.tool:'storyboard'` (each board shot is a Suite shot) | ladder | = shot | same |
| `guide` | same, `camera.mode:'directed'` / `camera.guide` (Camera / Blender 3D guide) | ladder; `CAMERA_TARGETS` (H3 Max 3D-to-video for greybox) | H3 Max 3D, plus shot models that take a reference video (H3 family, Kling, Seedance) | same |
| `recast` | same, `mode:'recast'` → `recast.ts pickRecast` | `RECAST_LADDER` (Wan 2.2 Animate on Draft) | H3 Max Recast, Kling O1, Wan 2.2 Animate, Kling 4.0 | same (priced in `buildRecastPlan`) |
| `extend` | same, `mode:'extend'` → `extend.ts pickExtend` | `EXTEND_LADDER` (Wan 2.7 on Draft) | Wan 2.7, Seedance 2.5, Kling 4.0 | same (priced in `buildExtendPlan`) |
| `swap` | `POST /v1/suite/shots` `mode:'swap'`; `POST /v1/jobs` → `services/jobs.ts` → `services/replicateVideo.ts` | **Was hard-wired:** `REPLICATE_VIDEO_MODEL` (minimax/h3); Draft used `REPLICATE_VIDEO_DRAFT_MODEL` (h3-lite) at the config price | H3, H3 Lite, H3 Highspeed (hosted; same input schema), **Edit = H3 open weights on the RunPod worker** and **Fast · beta = Viggle** (both when the pods offer them) | `engineModel`. Hosted: the job stores `videoModel` + `swapEngine` and is priced at the registry $/s × priceScale at the quality's resolution (H3 Lite has no 2K, so it runs 768P; Highspeed sends no resolution). GPU: priced as Edit / Fast (`P.totalCost`). An explicit `engine:'h3'/'viggle'` keeps working; the studio Swap default applies to the hosted swap |
| `fill` | Recreate `POST /v1/recreate/references/:id/slots/:slotId/estimate` and `/fill` → `recreate/references.ts` | Swap fill: Edit first, then the hosted swap. Generate fill: a Suite shot (ladder) | Listing: swap engines ∪ shot models | `engineModel`: a swap engine swaps on it (Swap default otherwise), any other model generates (`method:'generate'`), checked by the Suite. Priced by the same quote the job uses |
| `plate` | Recreate "Use your own setting" background → `backgroundFor` / `backgroundImage` → `images.generate` | The image engine's new-shot model (FLUX.2 [pro] recipe) | Image models (below) | `imageModel` (else the Plate default). Priced on that model × `EDITOR_MARKUP` |
| `photo` | `POST /v1/suite/photos(/estimate)` → `routes/index.ts photoPlan` → shoot pipeline | The studio's shot step (Settings → Engines → Image models), default `REPLICATE_IMAGE_MODEL` | The studio's photo model, the config default, FLUX.2 pro/max/flex/dev, custom image models, **any Replicate `owner/name`** (checked against its schema when it runs) | `imageModel` (owner; as before), `engineModel` for custom models members may use, else the Photo default |
| `outfit` | `POST /v1/outfits` → `images.shotPlan` / `generate` (front + edits) | the studio's shot step (+ the edit step for the other angles) | image models (as photo, no custom) | `imageModel` (= the new-shot step), or the existing per-step `models:{shot,edit}`; else the Outfits default |
| `character` | `POST /v1/models/:id/fill-angles` (character sheet angles) | the studio's shot step | image models | `imageModel`, or `models:{shot}`; else the Character photos default |
| (model tools) | `/v1/models/:id/enhance` (realism + upscale) and dress-up (`services/tools.ts`) | per-step models: `realism`, `upscale`, `dressA`, `dressB` | any Replicate model compatible with the step (the existing image-models picker) | unchanged: `models:{realism, upscale, dressA, dressB}` (owner), plus the studio's per-step choice in Settings → Engines → Image models |
| (LoRA candidates) | LoRA training-set photos (`services/lora.ts`) | the studio's shot step | the studio's per-step choice | unchanged (Settings → Engines → Image models) |
| `upscale` | `POST /v1/takes/:id/upscale` → the add-on GPU | SeedVR2 (own GPU, `UPSCALE_PRICES`) | SeedVR2 only (no other video upscaler is wired) | `engineModel` (checked); priced per output second as before |
| `matte` | `POST /v1/editor/estimate` / `jobs` `kind:'matte'` → `editor/providers.ts` | Robust Video Matting (`EDITOR_MATTE_MODEL`) | the configured model only | `engineModel` (checked) |
| `track` | `kind:'matte'` with `options.points` | SAM 2 video (`EDITOR_TRACK_MODEL`) | the configured model only | `engineModel` (checked) |
| `captions` | `kind:'captions'` / `'cuts'` | WhisperX (`EDITOR_TRANSCRIBE_MODEL`) | the configured model only | `engineModel` (checked) |
| `denoise` | `kind:'denoise'` | Demucs (`EDITOR_SEPARATE_MODEL`) | the configured model only | `engineModel` (checked) |
| — | Higgsfield H3 fallback → Replicate H3 (`suite/runner.ts`) | automatic when Higgsfield refuses at start | — | not a choice: a provider fallback for the same model |
| — | `suite/assist.ts` prompt helpers, Recreate analysis (Claude) | language models | — | out of scope (not image or video models) |

## Gaps (not built here; each needs the owner's OK or another workstream)

- **Upscale and the editor helpers have one model each.** The picker shows that one model, and the override is checked. A second upscaler (for example a hosted video upscaler) or a second matting or transcription model needs a runner or input mapping and a verified price. Each is a registry entry plus its adapter. Nothing was added without a verified schema and price.
- **Custom (BYO) models** serve shot, storyboard, UGC (with images) and fill (video), and photo (image). BYO has no input mapping for swap, recast, extend, outfits, character photos or plates.
- **Recreate generate fills** use the Shot default (purpose `shot`). The `fill` default is listed but runs are decided by the Swap and Shot defaults.
- The **H3 open-weights "Edit" swap** is listed with its licence line (it excludes the US, EU, UK and South Korea). It is the existing Edit path, not a new feature on it. It appears only when the pods advertise `h3`.

## Tests

`server/api/test/model-choice.test.ts` (fakes only: mock Suite, simulated GPU, fake Replicate; it asserts that no prediction is created) covers:

- the catalog, per purpose and for members;
- for shot, recast, extend, guide, swap (Suite and `/v1/jobs`), photo, outfit, character, upscale and the editor helpers:
  - an override is accepted and priced on the chosen model;
  - a model of another purpose is refused with `valid`;
  - members get 403;
- studio defaults: set, priced, applied to members, refused, cleared, and the ladder fallback warning;
- a client can't smuggle `videoModel` into a job;
- `/v1/suite/catalog` `engines[].purposes`.
