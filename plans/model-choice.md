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

## One model, several providers (owner 2026-11-14, branch claude/model-resolutions)

"I should have options. Right now I'm tied to using a certain model for a certain quality." Server only; the installed
apps keep working unchanged.

- **Registry** (`server/api/src/suite/registry.ts`): a spec may be a ROUTE of another model (`family`). Routes:
  `h3-hf` (MiniMax H3 2K, now also image-to-video), `seedance-2.5-hf` (480p/720p/1080p), `seedance-2.0-hf` (480p–4K),
  `kling-v3-omni-hf` (Higgsfield "Kling O3", 720p/1080p/4K), `wan-2.7-hf` (720p/1080p). New model `kling-v3`
  (Kling 3.0, Higgsfield only, std/pro/4K endpoints via `refByResolution`). Request fields from
  `assets/higgsfield/catalog.json`. Higgsfield routes without a verified plan rate are `livePrice` (free /estimate).
- **Routing** (`suite/routes.ts`): the pickers list the head once; `resolutions[]` is the union of its routes, each on the
  cheapest route that makes it. At plan time every route that can make the shot at that resolution and length is priced
  (live quotes included) and the cheapest runs (`plan.routes`, owner `engine.routes`). A route that refuses at start (no
  credit, bad key, busy, down) hands the shot to another route at the same resolution (runner, generalised from h3-hf);
  the quoted price stands.
- **Contract additions** (additive): every video entry's `resolutions[]` item has `provider`, `providerName`,
  `modelLabel` ("Seedance 2.5 · Higgsfield") and `livePrice` (perSec 0 = priced when planned); members with provider
  names off get none of them. A multi-provider entry's label is "Seedance 2.5 · Replicate + Higgsfield"
  (`provider` "replicate+higgsfield"). `GET /v1/engines?purpose=…&resolution=1080p` adds `resolutionFit {asked, has,
  resolution, note}` per model (a resolution never forces a model). Owner estimate `engine`: `family`, `providerName`,
  `routes[{model, provider, providerName, estimate, chosen}]`. Old ids (`h3-hf`) resolve as their model everywhere
  (engineModel, studio defaults, ladders). Classic Swap: `h3` at HD runs on Higgsfield (`swapRoute`) when it can.
- **Not merged**: New Swap's model list (`/v1/suite/remix/models`) still shows MiniMax H3 per provider and leaves the
  new routes out (it prices one resolution per entry).
- **App follow-up (not built)**: show `resolutions[i].modelLabel` in the pill and chips instead of the entry label;
  Android: show live-priced chips ("priced at Generate") instead of hiding perSec 0; Mac `snapResolution`: nearest
  resolution before the ladder's, with `resolutionFit.note`.

### REVERSED (owner 2026-11-15, branch claude/model-per-provider): each provider stands on its own
"Why do we have Higgsfield + Replicate? They should stand on their own! Higgsfield has 480p."
- One picker entry per provider again: `seedance-2.5` = Seedance 2.5 · Replicate (480p/720p), `seedance-2.5-hf` =
  Seedance 2.5 · Higgsfield (480p/720p/1080p), likewise `seedance-2.0(-hf)`, `kling-v3-omni(-hf)`, `wan-2.7(-hf)`,
  `h3` / `h3-hf`; `kling-v3` is Higgsfield only. Each has only its own resolutions and price; a pick never moves to the
  other provider (no cheapest-route switching; ladders and engineModel run exactly the spec named).
- Higgsfield prices: every resolution chip is quoted live (free /estimate, 2.5 s budget); no quote back in time →
  `perSec` 0 with `livePrice` → the apps show "priced at Generate" (app patches on claude/model-picker-patches).
- No silent fallback: a provider that refuses at start fails the job, refunded, e.g. "Higgsfield is out of credit ·
  you weren't charged · pick MiniMax H3 · Replicate". Opt-in per studio: PATCH /v1/suite/settings
  `{providerFallback: true}` (stored as `suite_settings.models._providerFallback`, no migration; GET shows it), which
  restores the same-resolution move (suite shots and the classic Higgsfield swap).
