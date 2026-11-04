# MUSE API (v1)

_Added 2026-11-04._ This is the contract between the apps and the backend. `server/mock` implements it today, with renders simulated 24× faster than real time and no GPU or RunPod calls. The Android client implements it in `android/app/.../data/HttpMuseApi.kt`. The real backend should implement the same contract and run the jobs on RunPod (MiniMax H3), because a phone can't hold the API key.

- Base URL: `http://<host>:8787/`. The Android emulator reaches the host at `http://10.0.2.2:8787/`.
- JSON bodies, UTF-8. Money is in US dollars as a number (`0.67`). Times are epoch milliseconds, and durations are seconds.
- Auth: `Authorization: Bearer <token>` from sign-in or sign-up. The mock accepts any token or none. The real API (`server/api`) needs a session for everything under `/v1` except sign-in and sign-up. `GET /v1/events` also accepts `?token=`.
- Errors use a non-2xx status and the body `{ "error": "Human message", "code": "machine_code" }`. Clients show `error` as-is.

| code | status | when |
|---|---|---|
| `bad_request` | 400 | invalid input (for example, steps outside 4–30) |
| `attestation_required` | 400 | sign-up without both attestations |
| `insufficient_balance` | 402 | the price is more than the balance |
| `over_job_limit` | 402 | the price is more than the per-job spend limit |
| `clip_failed_checks` | 422 | job for a clip whose checks failed |
| `not_found` | 404 | unknown id |
| `busy` | 409 | the LoRA is already building or training |
| `unauthorized` | 401 | no session, or it ended (real API) |
| `bad_credentials` | 401 | wrong email or password |
| `invite_required` / `invite_invalid` | 400 | sign-up without a valid invite code |
| `email_taken` | 409 | sign-up with an email that has an account |
| `account_disabled` / `owner_only` | 403 | switched off by the owner / owner-only endpoint |
| `insufficient_tokens` | 402 | a member's wallet can't cover the price (the owner gets `insufficient_balance`) |
| `over_user_day_limit` / `over_day_limit` | 402 | over the per-user or per-studio daily cap |
| `over_allocation` | 402 | the owner tried to send more tokens than the RunPod balance backs |
| `balance_unavailable` | 503 | RunPod can't be read, so tokens can't be sent |
| `engine_unavailable` | 400 | the GPU image can't run this yet (Fast · beta, LoRA training, or lip sync without LatentSync), or `engine: "replicate"` / image provider `replicate` while the server has no Replicate token |
| `image_engine_failed` | 502 | the image engine failed (the charge is refunded) |
| `provider_refused` | 422 | the hosted provider's safety filter refused the request: "Replicate's safety filter refused this photo" (photos; the charge is refunded). Video jobs fail with `Job.errorCode: "provider_refused"` and the message "Replicate's safety filter refused this clip" (the hold is refunded) |
| `provider_rate_limited` | 429 | photos only: Replicate stayed rate-limited for longer than `REPLICATE_IMAGE_MAX_WAIT_SEC` (default 120 s); the charge is refunded, try again in a minute. Video jobs never fail on a rate limit: they wait in line (see "Video engines") |
| `rate_limited` | 429 | too many sign-in or sign-up tries |
| `template_hidden` | 403 | saving a template from a shot made with someone else's template |
| `warm_not_allowed` | 403 | Keep GPU warm when the studio allows it for the owner only |
| `owner_balance_low` | 402 | Keep GPU warm while the studio's RunPod balance is below `RUNPOD_MIN_BALANCE_USD` |
| `no_gpu_free` / `no_gpu_available` | 409 / 503 | Keep GPU warm with every pod in use / no GPU free on RunPod |
| `not_warm` | 409 | Keep warm (`extend`) while the warm GPU is off |

## Types

```ts
ImageRef   { asset?: string, url?: string }          // asset = bundled sample key ("g_front"); url = loadable image (relative "/uploads/x" is resolved against the base)
User       { id, studioName, email }
SheetSlot  { key: "face"|"profile"|"front"|"tq"|"side"|"back", image: ImageRef|null, source: "upload"|"generated", busy: boolean }
Model      { id, name, age (18–70), niche, look, neverAdd: string[], slots: SheetSlot[6], outfitIds: string[] }
           // locked = all 6 slots filled. Missing face close-ups are only a warning, and saving is always allowed.
Outfit     { id, modelId, name, mode: "describe"|"photo"|"own", description, angles: (ImageRef|null)[4] /* front, ¾, side, back */,
             state: "generating"|"preview"|"ready", prompt }
ClipMeta   { name, durationSec, width, height, fps, people?, watermark?, talking? }
ClipCheck  { label, value, status: "good"|"bad"|"info", fix? }
Clip       { id, name, durationSec, width, height, fps, checks: ClipCheck[], thumb?: ImageRef }
JobRequest { title, modelId, outfitId, clipId, engine: "replicate"|"h3"|"viggle" /* default: features.video.defaultEngine */,
             quality?: "draft"|"standard"|"hd" /* engine "replicate" only; default "standard" */,
             steps (4–30, default 10; h3 only), use: "first"|"full" /* h3/viggle; replicate always renders the whole clip and stores "full" */,
             takes (1–4), keepAudio, lipSync /* h3 only */, background: "keep"|"photo" /* "photo" is h3 only */, backgroundMotion: "still"|"subtle"|"busy", clipSeconds?,
             queue?: boolean /* true = park it as "queued", not charged, until POST /v1/queue/run */ }
             // Clients should always send `engine`. The picker maps to it: Draft/Standard/HD = {engine:"replicate", quality},
             // Exact edit = {engine:"h3", steps}, Fast · beta = {engine:"viggle"}. See "Video engines and quality".
Job        { id, title, modelId, modelName, outfitId, request: JobRequest, state: "queued"|"running"|"done"|"failed",
             progress (0–100), take, step, totalSteps, phase /* "step 12/20 · ~6 min left" */, secondsLeft, totalSeconds,
             cost, refunded, error?, createdAt, finishedAt?, prompt /* exact H3 prompt */, seed, thumb: ImageRef,
             queuePosition?, etaSeconds? /* while waiting for a GPU, or in the Replicate line */, blocked?: "owner_balance_low", warmupCost? /* GPU warm-up charged with it */,
             engineLabel /* "Standard · 768P", "Draft · 768P", "HD · 2K", "Exact edit · 10 steps", "Fast · beta" */,
             errorCode?: "provider_refused"|"provider_failed"|"provider_rate_limited"|"provider_timeout" /* failed replicate jobs */,
             billedSeconds? /* replicate, done: output seconds Replicate billed, summed over takes */ }
Take       { id, kind: "take"|"shot", jobId|null, index, of, title, label, engineLabel, cost, seed, status: "test"|"final", thumb, prompt, createdAt,
             videoUrl?, durationSec?, width?, height? /* real output: Exact edit renders are 768×1344; Replicate 768P/2K sizes come from the file */ }
             // Takes: label = "Standard"|"Draft"|"HD" (replicate), "10 steps" (h3), "Fast · beta"; engineLabel = Job.engineLabel.
             // A replicate take's durationSec is the source clip's exact length (see "Video engines"), and its thumb is a frame of the take.
             // Shots: engineLabel = the image engine that made them ("FLUX.2 [pro] · Replicate", "Qwen edit · Replicate", "" for simulated).
Balance    { balance, month, today /* spent since local midnight */, perJobLimit, perDayLimit, videos,
             tokens, tokenUsd, role: "owner"|"member", heldUsd, perUserDayLimit, balanceSource: "runpod"|"simulated"|"unavailable"|"wallet",
             runpodBalance?, availableToSend? /* owner only */ }
             // Member: balance = their wallet in USD; today/month = their own spend. Owner: balance = what they can spend or send
             // (RunPod − members' unspent tokens − holds); today/month = the studio's spend.
Wallet     { userId, role, tokens, usd, heldTokens, heldUsd, todayUsd, monthUsd, tokenUsd, balanceSource, availableToSend?, runpodBalance?, membersUnspentUsd? }
Member     { id, email, role, tokens, usd, heldTokens, todayUsd, monthUsd, lastActiveAt?, disabled, capPerJob, capPerDay, createdAt }
Lora       { modelId, version /* 0 = never trained; the last ready version */, state: "none"|"building"|"review"|"training"|"ready"|"failed",
             use: boolean /* default true */,
             candidates: { id, image: ImageRef, label, flag?: "tattoo"|"ring"|"choker"|"face drift", keep: boolean /* false when flagged */ }[],
             progress (0–100, overall), photo: { state: "none"|"training"|"ready", progress }, video: { state: "none"|"waiting"|"training"|"ready", progress },
             cost /* spent so far */, trainedOn? /* shots kept for the last version */ }
             // The LoRA is applied when version ≥ 1 and use is true, also while a retrain is in review/training.
             // Token: first name, lower case, plus the version: "sienna_v2".
Platform   "tiktok"|"instagram"|"facebook"|"youtube"|"x"
Account    { modelId, platform: Platform, handle, connectedAt, canPostDirect: boolean /* false until that platform approves MUSE */ }
Post       { id, modelId, takeId, title, thumb: ImageRef, platforms: Platform[], caption, aiLabel: boolean, paidPartnership: boolean,
             when: "now"|ISO time, state: "scheduled"|"handoff"|"posted"|"failed", createdAt, postedAt?, stats?: { views, likes, comments } }
ApiEvent   { type: "job"|"balance"|"model"|"outfit"|"lora"|"post"|"wallet"|"gpu", job?, balance?, model?, outfit?, lora?, post?, takes?: Take[],
             wallet?: Wallet, notice?: { code: "owner_balance_low"|"owner_balance_ok", message },
             gpu?: WarmGpu, event?: "state"|"tick"|"warning" /* gpu events only */, warning?: WarmWarning }
             // balance, wallet and gpu events go only to the user they concern (balance/wallet also to owners, whose pool moved too).
WarmGpu    { state: "off"|"starting"|"warm"|"stopping",          // starting = the pod is booting (3–6 min); warm = ready, renders start at once
             startedAt: number|null, readyAt: number|null,          // epoch ms; null when off
             minutes: number /* whole minutes since startedAt */, costUsd: number /* "Warm GPU" charged so far, settled per minute */,
             ratePerHour: number /* the pod's $/h, ~3.99 */, busy: boolean /* a render is running on it */,
             autoOffAt: number|null /* the earliest idle or cap auto-off; null when off */, autoOffReason?: "idle"|"cap",
             warningAt?: number /* autoOffAt − 5 min: when the warning fires */,
             idleMinutes: number /* warmIdleMinutes */, maxMinutes: number /* the cap, including an extension */, canExtend: boolean,
             allowed: boolean /* this user may switch it on (studio warmGpuAllowed) */,
             lastOff?: { reason: WarmOffReason, at, minutes, costUsd }  /* state "off": how the last session ended (within the last hour) */ }
WarmOffReason "user"|"idle"|"cap"|"credit"|"owner_balance"|"gpu_lost"
WarmWarning { reason: "idle"|"cap", autoOffAt, message /* "Warm GPU turns off in 5 min (no renders)" */ }
// Job also carries warm?: true when it ran on its user's warm GPU: its GPU time is covered by the "Warm GPU" line,
// so its hold settles to $0 (or only the part that ran after the warm GPU went off).
// Model also carries optional { personality, notes }.
ConnectResponse { authUrl?: string /* real backend: open it for OAuth */, account?: Account /* mock: signed in already */ }

// ---- Photo templates (plans/templates.md) ----
Grade              "none"|"phone-natural"|"underexposed"|"moody-blue"|"golden"|"harsh-sun"|"faded"|"mono"
TemplateAfterEffects { faceMotionBlur?: number /* 0–1, 0 or absent = off */, blurAngle?: number /* degrees, 0 = sideways drag */,
                       grade?: Grade, grain?: number /* 0–1 */ }
                   // Applied by the server to each generated still after the image engine (an edit step, not prompt words).
TemplateLayers     { style?, scene?, camera?, light?, negative?, product? /* how a product photo is used */, afterEffects?: TemplateAfterEffects }
                   // All strings, each ≤ 600 chars. Never identity, outfit, never-add or seed: those come from the model being shot.
PoolSlot           "pose"|"bodyAngle"|"framing"|"expression"|"background"|"hands"|"timeOfDay"
VariationPool      { [slot in PoolSlot]?: string[] }              // ≤ 12 options per slot, each ≤ 200 chars
VariationDraw      { [slot in PoolSlot]?: string, direction?: string }  // what one shot drew; direction replaces pose + bodyAngle
Template           { id, name, tags: string[], visibility: "private"|"public", ownerId, ownerName, isOwner: boolean,
                     uses /* shoots made with it */, favourite: boolean /* mine */, cover: ImageRef|null, acceptsProduct: boolean,
                     starter?: string /* starter-pack slug */, createdFromShotId?, createdAt, updatedAt,
                     layers?: TemplateLayers, variationPool?: VariationPool          /* ONLY when isOwner */,
                     recent?: { id, thumb: ImageRef, createdAt }[]                  /* GET /v1/templates/{id} only: newest 6 shots */ }
TemplateDraft      { name, tags: string[], layers: TemplateLayers, variationPool: VariationPool, cover: ImageRef|null, fromShotId }
PromptSlotView     { layer: "identity"|"outfit"|"template"|"scene"|"camera"|"light"|"pose"|"direction"|"product"|"style"|"negative"|"seed",
                     text, locked?: true /* the one "Template: <name>" line non-owners see */ }
TemplatePrompt     { slots: PromptSlotView[], text, seed: number|null /* null = a new random seed at shoot time */, shuffleSeed,
                     variation?: VariationDraw /* owner only */ }
// Take (photoshoot stills) also carries: templateId?, templateName?, shuffleSeed?, variation?: VariationDraw (template owner only).
// For anyone but the template's owner a template shot's `prompt` is the public version: "Template: <name>" plus their own layers.
```

## Pricing (the same in every client and the server)

### Replicate (Draft / Standard / HD), the default
Billed per **output second**. `D` is the whole clip rounded **up** to whole seconds, between 4 and 15 (the output can't be fractional; see "Video engines" for how the take still keeps the exact clip length).

| quality | label | detail | `pricePerSec` (default) |
|---|---|---|---|
| `draft` | Draft | 768P · lite | $0.02 |
| `standard` | Standard (default) | 768P | $0.08 |
| `hd` | HD | 2K | $0.13 |

- `replicateSeconds(clipSeconds) = min(15, max(4, ceil(clipSeconds − 0.001)))`. With no clip length (the sample clip) `clipSeconds` = 9.4, so D = 10. Examples: 7.0 → 7, 7.04 → 8, 2.5 → 4, 14.97 → 15.
- `replicateCost = pricePerSec(quality) × D × takes`. The server's `features.video.options[].pricePerSec` is authoritative (it comes from config); clients use the defaults above until they've read it.
- Price line under the picker: `"about $0.56 · 7 s"`, and `" · 2 takes"` when takes > 1 (`"about $1.12 · 7 s · 2 takes"`). Money is `'$' + v.toFixed(2)` as elsewhere.
- Generate button: `"Generate · 7 s · $0.56"` (+ `" · 2 takes"`).
- Billing: the hold is `replicateCost` at job start; done settles to `pricePerSec × the seconds Replicate actually billed` (summed over takes, `metrics.video_output_duration_seconds`, D when Replicate doesn't report it); failed or cancelled refunds the hold in full.
- Ledger notes (owner's ledger): hold `"Video · Standard 768P · 7 s · hold"`, settle `"Video · Standard 768P · 7 s"` (takes > 1: `"Video · Standard 768P · 2 × 7 s"`). Draft reads `"Video · Draft 768P · …"`, HD `"Video · HD 2K · …"`.
- `cost` is computed in doubles exactly as `pricePerSec × D × takes`, left to right. The fixture `android/core/src/test/resources/replicate_pricing_fixture.json` (135 rows, generated with JavaScript's `toFixed`) lists `{quality, pricePerSec, clipSeconds /* null = sample */, takes, seconds, cost, costLabel, priceLine, genLabel}`; the server and both apps check against it. The 216-row `pricing_fixture.json` (Exact edit and Fast · beta) is unchanged.

### Exact edit (H3 on our RunPod GPU) and Fast · beta
These are measured on an H100 with FlashAttention 3 and billed at $3.99/h. The unit tests check them against `prototype/app/app.js`.

- `secPerLen(len) = 57.8 × (len / 5.2)^1.3` seconds per step.
- The rendered length is the first 5.2 s, or the whole clip (up to 15 s, the limit of a single H3 pass).
- H3, per take: `minutes = steps × secPerLen(len) / 60 + 0.5 (GPU start) + 4 (if lip sync)`, and `cost = minutes / 60 × 3.99`.
- Viggle (Fast · beta), per take: `minutes = 1.6 × len / 5.2`, and `cost = 0.13 × len / 5.2`.
- Takes run back to back, so time and cost are multiplied by `takes`.
- Fixed prices: a photoshoot (4 stills) is $0.12, an outfit set is $0.08 (free for "my own set"), and filling a missing character-sheet angle is $0.02 per angle.
- Billing: the price is held from the balance when a job starts, and refunded in full if the job fails.

## Endpoints

### Auth (stub)
| | |
|---|---|
| `POST /v1/auth/signin` `{email, password}` | → `{token, user}` |
| `POST /v1/auth/signup` `{studioName, email, password, inviteCode, attestAdultRightsOriginal, attestLabelAi}` | → `{token, user}`. Both attestations are required (`attestation_required`, checked first) and stored with a timestamp. There is no other consent endpoint, because consent lives in the Terms. The real API is invite-only: `inviteCode` is required (`invite_required`), except in its dev mode. `user` also carries `role`. |
| `POST /v1/auth/signout` | 204. Revokes this session. |
| `GET /v1/auth/me` | → `{id, email, studioName, role}` |
| `POST /v1/invites` `{email?, role?, days?}` (owner) | → `{code, id, email, role, expiresAt}`. The code is shown once. `npm run invite -- email` in `server/api` does the same from a shell. |
| `GET /v1/invites` (owner) | → invites without their codes |

### Models and character sheets
| | |
|---|---|
| `GET /v1/models` | → `Model[]` |
| `POST /v1/models` `{name, age, niche}` | → `Model` with 6 empty slots |
| `PUT /v1/models/{id}/slots/{slot}` `{image: ImageRef\|null, source}` | → `Model` |
| `POST /v1/models/{id}/fill-angles` | → `{model, cost}`. Missing slots come back `busy: true`. A `model` event follows when they're filled (`source: "generated"`). |

### Outfit sets
| | |
|---|---|
| `GET /v1/outfits` | → `Outfit[]` (includes unsaved previews) |
| `POST /v1/outfits` `{modelId, name, mode, description, images: ImageRef[]}` | → `Outfit` (`state: "generating"`). An `outfit` event follows with `state: "preview"` and four angles on one seed. |
| `POST /v1/outfits/{id}/save` | → `Outfit` (`state: "ready"`), attached to the model. Retake means another `POST /v1/outfits`. |

### Uploads
| | |
|---|---|
| `POST /v1/uploads/images` multipart `file` | → `ImageRef {url}` |
| `POST /v1/uploads/clips` multipart `meta` (ClipMeta JSON) + optional `file` | → `Clip` with checks: one person, no watermark, vertical and ≥720 wide, ≤15 s, plus whether the performer is talking. The client reads duration, size and fps from the file. The server detects people and watermarks (the mock takes them from `meta`). |
| `POST /v1/uploads/presign` `{kind: "image"\|"clip", contentType, bytes?}` | → `{uploadId, method: "PUT", url, headers, expiresAt}`. For large files: PUT the bytes straight to R2, then confirm. |
| `POST /v1/uploads/{uploadId}/confirm` `{meta?: ClipMeta}` | → `ImageRef` (image) or `Clip` (clip). `upload_missing` (409) if the PUT hasn't arrived. |
| `GET /uploads/{name}` | the stored file (the real API redirects to a short-lived R2 URL) |

### Jobs, takes and photoshoots
| | |
|---|---|
| `GET /v1/jobs` | → `Job[]`, newest first |
| `POST /v1/jobs` `JobRequest` | → `Job` (`running`). Charges the price. Rejects a failing clip, low balance and the per-job limit. |
| `DELETE /v1/jobs/{id}` | 204. Removes the job from the list and stops it if it's running. |
| `GET /v1/takes` | → `Take[]` (renders and photoshoot stills). `status: "final"` is the Final gallery, and everything else is Tests. |
| `PATCH /v1/takes/{id}` `{status: "test"\|"final"}` | → `Take` (Approve) |
| `DELETE /v1/takes/{id}` | 204 (Discard) |
| `POST /v1/shoots` `{modelId, outfitId, scene, prompt, seed?, count}` | → `Take[]` (`kind: "shot"`). Charges $0.12. |
| `POST /v1/shoots` with a template `{modelId, outfitId?, templateId, direction?, shuffleSeed?, lockSeed?, productImage?: ImageRef, count?}` | → `Take[]`, $0.12 as above. `scene`, `prompt` and `seed` are ignored: the server builds every still's prompt from the template layers + the model's identity, outfit and never-add + the draws (or `direction`) + a seed. See Templates below. |

### Identity LoRA (`plans/lora-training.md`)
| | |
|---|---|
| `GET /v1/models/{id}/lora` | → `Lora` |
| `POST /v1/models/{id}/lora/candidates` | → `Lora` (`building`, then `review` via a `lora` event). Generates 30 candidates. Charges $0.60. |
| `PATCH /v1/models/{id}/lora/candidates/{cid}` `{keep}` | → `Lora` |
| `POST /v1/models/{id}/lora/train` | → `Lora` (`training`). Needs 20+ kept (`bad_request`). Charges the photo + video training price, (25 + 75) min / 60 × $3.99 = $6.65, or `insufficient_balance`. The per-job render limit doesn't apply. Progress comes through `lora` events; at 100 the state is `ready` and `version` goes up by one. Works from `review` (first time or retrain). |
| `PATCH /v1/models/{id}/lora` `{use?, state?: "review"}` | → `Lora`. `use` switches it on or off for new renders. `state: "review"` on a `ready` LoRA is **Retrain**: back to the review grid with the same shots; the current version stays in use until the next one is ready. |

The mock runs LoRA training 5× faster than its render speed (120× real time by default, like the prototype).

### Social accounts and posts (`plans/socials.md`)
| | |
|---|---|
| `GET /v1/models/{id}/accounts` | → `Account[]` |
| `POST /v1/models/{id}/accounts/{platform}/connect` | → `ConnectResponse`. The real backend returns `{ authUrl }` (OAuth). The mock signs in after a short delay (≤ 0.9 s) and returns `{ account }`. Handles come from the model's name (`@sienna.vale`, `Sienna Vale` on YouTube, `Sienna Vale (Page)` on Facebook). |
| `DELETE /v1/models/{id}/accounts/{platform}` | 204 |
| `GET /v1/posts?state=&modelId=` | → `Post[]`, newest first. Both filters are optional. |
| `POST /v1/posts` `{modelId, takeId, platforms, caption, aiLabel, paidPartnership, when}` | → `Post`. `aiLabel` and `paidPartnership` default to false and are only ever set by the user. Only a JSON `true` turns a label on. Every platform must be connected for that model (`bad_request`). Stage 1: `when: "now"` returns `handoff` (the client opens each app); a scheduled post stays `scheduled` and turns `handoff` at its time (the client also sets a local notification). The mock then marks a handed-off post `posted` with stats after a moment (`post` event), standing in for the stats read-back. |
| `DELETE /v1/posts/{id}` | 204 (cancels a scheduled post) |

### Gaps found while building the Mac app
| | |
|---|---|
| `POST /v1/queue/run` | → `Job[]` it started. Starts `queued` jobs oldest first, charging each as it starts. Stops at the first one the balance can't cover (those stay queued); `insufficient_balance` if none could start. Jobs are queued with `JobRequest.queue: true`. |
| `PATCH /v1/models/{id}` `{name?, niche?, personality?, notes?, neverAdd?}` | → `Model`, plus a `model` event. Only the fields sent change. An empty name is `bad_request`. |
| `DELETE /v1/models/{id}` | 204. Also deletes her outfits, LoRAs and training set, linked accounts, and posts that haven't gone out. |

### Photo templates (`plans/templates.md`)
A template is a reusable look (style, scene, camera, light, grade, after-effects and a variation pool) applied to any model and outfit. Its `layers` and `variationPool` are **hidden**: only the owner ever receives them, from any endpoint. Everyone else gets the name, cover, tags, owner, visibility, uses and their favourite flag, and sees a template shot's prompt as one locked line.

| | |
|---|---|
| `GET /v1/templates?scope=all\|mine\|public\|favourites&q=&tag=` | → `Template[]`, newest first. `all` (default) = mine + the studio's public ones; `mine` = I own (private and public); `public` = the studio's public ones (mine included); `favourites` = my favourites I can still see. `q` matches name or a tag (case-insensitive substring); `tag` is one exact tag (case-insensitive). The owner's own come with `layers` and `variationPool`. |
| `GET /v1/templates/{id}` | → `Template` with `recent`. Someone else's private template is `not_found`. |
| `POST /v1/templates` `{name, tags?, visibility?, layers?, variationPool?, coverTakeId?}` | → `Template` (mine). `visibility` defaults to `private`. From scratch: an empty `variationPool` is auto-suggested from the layers. `coverTakeId` = a shot or take in the studio whose still becomes the cover. |
| `POST /v1/templates` `{fromShotId, name, tags?, visibility?, variationPool?}` | → `Template`. Copies that shot's exact layers (never identity, outfit, never-add or seed) and its still as the cover. A shot's own direction becomes the first `pose` option. `variationPool` (the creator's edits) replaces the suggestion. `template_hidden` (403) when the shot was made with someone else's template. |
| `POST /v1/templates/draft` `{fromShotId}` | → `TemplateDraft`: what "Save as template" would save (layers, the auto-suggested pool, the cover, a suggested name and tags), to show and edit before saving. Nothing is stored. `template_hidden` as above. |
| `PATCH /v1/templates/{id}` `{name?, tags?, visibility?, layers?, variationPool?}` | → `Template`. Owner only (`owner_only` 403 on someone else's public template; their private ones are `not_found`). |
| `DELETE /v1/templates/{id}` | 204. Owner only. Shots made with it keep their (public) prompt and `templateName`. |
| `POST /v1/templates/{id}/duplicate` | → `Template`: a private copy, "<name> copy". Owner only. |
| `POST /v1/templates/{id}/favourite` / `DELETE /v1/templates/{id}/favourite` | → `Template`. Per user; anyone who can see it. |
| `POST /v1/templates/{id}/prompt` `{modelId, outfitId?, direction?, shuffleSeed?, lockSeed?}` | → `TemplatePrompt`: the prompt the first still would get, for the prompt view. Non-owners get the locked `Template: <name>` line plus identity, outfit, their direction, never-add and seed; the owner gets every slot and the `variation` drawn. Free. |

How a template shoot works (`POST /v1/shoots` with `templateId`):
- **Seed:** a new random seed per still. `lockSeed: true` ("Lock look", off by default) uses one fixed seed for this template + model.
- **Variation:** each still draws one option from every non-empty pool slot, from a random generator seeded by `shuffleSeed` + the still's index. Without `shuffleSeed` the server picks one. The same `shuffleSeed` gives the same draws (so the prompt view matches the shoot); **Shuffle** in the apps is a new random `shuffleSeed` (0 – 2^31−1).
- **Direction:** a non-empty `direction` ("sitting on the steps, looking back over her shoulder") **replaces the `pose` and `bodyAngle` draws**; the other slots still draw. It's sanitised like any direction (it can't change identity or add never-add items).
- **Product:** `productImage` is sent to the image engine as an extra reference when the template `acceptsProduct` (its `layers.product` is set); otherwise it is ignored.
- **After-effects:** `layers.afterEffects` run on each still after generation (server-side, sharp): `grade` = a colour matrix, `grain` = soft-light noise, `faceMotionBlur` = a directional blur over the face box. The face box is the upper-centre of the frame for now (no face detector yet).
- **Stored on each shot:** the exact final prompt, the seed, `shuffleSeed`, the `variation` drawn and the layers. `uses` goes up by one per shoot.
- **Starter pack:** every studio has seven public starter templates owned by the studio owner (`starter`: `motion-blur-face`, `mirror-selfie`, `harsh-sun-close-up`, `moody-low-light`, `reflection`, `product-moment`, `candid-pov`). The server adds missing ones on start, and the owner can edit, hide or delete them like any other (a deleted starter comes back on the next start).

### Balance and wallets
| | |
|---|---|
| `GET /v1/balance` | → `Balance` |
| `POST /v1/balance/topup` `{amount, method: "card"\|"usdt"\|"virtual"}` | → `Balance`. In the mock, no payment is taken. The real API reads the RunPod balance, so this is `topup_unavailable` except in its dev mode (owner only). |
| `GET /v1/wallet` | → `Wallet` (mine) |
| `GET /v1/members` (owner) | → `Member[]` |
| `PATCH /v1/members/{id}` `{capPerJob?, capPerDay?, disabled?}` (owner) | → `Member`. `null` caps go back to the studio default. Disabling signs them out. |
| `POST /v1/wallets/transfer` `{toUserId, tokens, note?}` (owner) | → `{wallet, member}`. `over_allocation` beyond what the RunPod balance backs. |
| `POST /v1/wallets/reclaim` `{fromUserId, tokens, note?}` (owner) | → `{wallet, member}`. Only unused tokens (not ones held by running jobs). |
| `GET /v1/ledger?userId=&limit=` (owner) | → ledger rows, newest first |

### Settings (real API)
| | |
|---|---|
| `GET /v1/settings/image-engine` | → `{provider: "simulated"\|"fal"\|"custom-http"\|"replicate", model, editModel? /* replicate */, label, url?, available: {simulated, fal, "custom-http", replicate}}`. `label` is for display: "FLUX.2 [pro] · Replicate", "Simulated", the fal model id, "Custom". Default provider: `replicate` when the server has `REPLICATE_API_TOKEN`, else `IMAGE_PROVIDER` (simulated). A studio that saved a provider keeps it. |
| `PATCH /v1/settings/image-engine` `{provider, model?, url?}` | → same. Per studio. `custom-http` is owner-only and needs an https URL; `replicate` needs the server's token (`bad_request` otherwise). Shoots and outfit sets also take `imageEngine: {provider, model?}` to override it for one call. |
| `GET /v1/settings/studio` | → `{maxGpus, overheadPayer: "user"\|"owner", capPerJob, capPerDay, capPerUserDay, tokenUsd, minRunpodBalance, lowBalance, warmGpuAllowed: "owner"\|"everyone", warmIdleMinutes, warmMaxMinutes, features: {standard, fastBeta, lipSync, loraTraining, replaceAudio: false, outputSize: {width: 768, height: 1344}, maxClipSec, replicate, video: VideoFeatures}, gpu}`. `features.standard` still means "Exact edit (h3) can run"; `features.replicate` = the Replicate engine is set up. |
| `PATCH /v1/settings/studio` `{maxGpus?, overheadPayer?, capPerJob?, capPerDay?, capPerUserDay?, warmGpuAllowed?, warmIdleMinutes? (5–120), warmMaxMinutes? (30–480)}` (owner) | → same |

"Replace audio" isn't wired on the GPU yet: `keepAudio: false` gives a silent take, and `features.replaceAudio` is false.

### Video engines and quality (Replicate)
_Added 2026-11-04._ MiniMax H3 hosted on Replicate is the **default** video engine. Our own RunPod H3 stays as **Exact edit** (frame-by-frame, slower, needs a GPU start-up), Viggle stays **Fast · beta**.

**The picker** (video studio, Quality tool), in this order, default **Standard**:

| option `id` | label | detail line | sends | price |
|---|---|---|---|---|
| `draft` | Draft | 768P · lite | `{engine: "replicate", quality: "draft"}` | $0.02 × D |
| `standard` | Standard | 768P | `{engine: "replicate", quality: "standard"}` | $0.08 × D |
| `hd` | HD | 2K | `{engine: "replicate", quality: "hd"}` | $0.13 × D |
| `exact` | Exact edit | Frame-by-frame · slower · GPU start-up | `{engine: "h3", steps, use}` | GPU formula below |

(× takes in every row.) Fast · beta (`viggle`) is not in this picker; it stays behind its own flag as before.

**What the apps read:** `GET /v1/settings/studio` → `features.video`:
```ts
VideoFeatures { defaultEngine: "replicate"|"h3",      // "replicate" when the server has Replicate set up (VIDEO_ENGINE_DEFAULT), else "h3"
                defaultQuality: "draft"|"standard"|"hd", // "standard"
                minSeconds: 4, maxSeconds: 15,          // Replicate's output length range (D)
                options: VideoOption[] }                // picker order: draft, standard, hd, exact
VideoOption   { id: "draft"|"standard"|"hd"|"exact", label: "Draft"|"Standard"|"HD"|"Exact edit", detail,
                engine: "replicate"|"h3", quality?: "draft"|"standard"|"hd",
                resolution?: "768P"|"2K", pricePerSec?: number /* replicate options */, available: boolean }
```
`available: false` greys an option out (no Replicate token on the server, or no h3 on the GPU image). Clients that can't read settings use the table above with every option available.

**Per option, in the apps:**
- Draft / Standard / HD: whole clip only (no "First 5.2s" choice, no steps), takes 1–4, Keep audio on/off. Lip sync and "New background photo" are Exact edit only (the server refuses them on replicate with `bad_request`). No Keep GPU warm nudge, switch or cost warning for these: they don't use our GPU.
- Exact edit: everything as before: steps 4–30, First 5.2s / Full, lip sync, background photo, takes, and Keep GPU warm (the nudge and switch apply only while Exact edit is selected).

**How a replicate job runs (server):**
- `POST /v1/jobs` holds `replicateCost` (caps and balance as for any job) and the job joins the **Replicate line** (FIFO across the studio, `REPLICATE_MAX_CONCURRENT` = 1 at a time by default, because Replicate allows a burst of 1 and 6 starts per minute on a small balance). While waiting: `state: "running"`, `phase: "Waiting for Replicate · 2nd in line"`, `queuePosition`, `etaSeconds`. It isn't paused by a low RunPod balance (`blocked` never applies to it) and never starts a GPU.
- Phases while it runs: `"Preparing the clip"`, `"Rendering on Replicate"` (`"take 2/3 · Rendering on Replicate"` with several takes), `"Replicate is busy · retrying in 10s"` on a rate limit (it waits and retries, honouring Replicate's "resets in ~Ns" hint; it fails with `errorCode: "provider_rate_limited"` only after `REPLICATE_MAX_RATE_WAIT_SEC`, default 30 min), `"Finishing · exact length and audio"`. `progress` is an estimate; `totalSteps` = takes and `step` = takes finished.
- Length: the source is padded to D seconds (the last frame held, silence added), Replicate renders D seconds, and each take is trimmed back to the **exact** source length with a re-encode (not a keyframe cut). Keep audio on: the source's original audio is muxed back in; off: the take is silent.
- Inputs: `<Video 1>` = the padded source; `<Image 1>…<Image n>` (n ≤ 9) = the model's locked reference shots in a fixed order (face front, face profile, body front, body ¾, body back) and then the outfit set's angles (front, ¾, back, side). All are short-lived signed links (2 h); nothing is made public.
- Prompt: a short H3 prompt (about 230 words, four sections) built by the server: identity, outfit, never-add, captions removed, and "keep the exact framing and crop of <Video 1>". `Job.prompt` holds it. Replicate takes no seed, steps or LoRA; `Job.seed` is informational only.
- Done: one take per Replicate prediction (`take_n.mp4` + a thumbnail frame), the hold settles to the billed seconds (`billedSeconds` on the job). Failed (Replicate error, safety refusal, timeout) or cancelled (`DELETE /v1/jobs/{id}` cancels the prediction): `state: "failed"`, `refunded` = the hold, `errorCode` set, and `error` is a message to show as-is, e.g. "Replicate's safety filter refused this clip". If one take fails the whole job fails and is refunded.

**Photos on Replicate:** with provider `replicate`, new shots (photoshoots, template shoots, outfit set fronts, character-sheet fills) use FLUX.2 [pro] with the model's reference shots (≤ 6, face first) and the outfit/product photos; the other three outfit angles are edits of the generated front with Qwen-Image-Edit 2511. Prices to users are unchanged ($0.12 a shoot, $0.08 an outfit set, $0.02 an angle). Template after-effects still run on our side.

### Keep GPU warm (`plans/backend.md` "Keep GPU warm")
A user can keep a dedicated H100 warm so renders start at once instead of after the 3–6 min cold start. One warm GPU per user. The pod's whole wall time (boot included) is charged to the user who switched it on, as a "Warm GPU" ledger line (`kind: "warm"`) settled every minute (the last partial minute pro rata). Their renders on it aren't charged GPU time again (`Job.warm`). While it's warm the pool's 3-minute idle shutdown doesn't apply to it; these auto-off rules do:

| rule | default | |
|---|---|---|
| idle | `warmIdleMinutes` = 20 | no render on it for that long (counted from when it's ready or the last render ended) |
| cap | `warmMaxMinutes` = 120 | from `startedAt`; **Keep warm** extends it once by the same amount |
| credit | | the user's credit can't cover 10 more minutes |
| owner balance | `RUNPOD_MIN_BALANCE_USD` | the studio's RunPod balance drops below it |

A `warning` event goes out 5 minutes before an idle or cap auto-off. Off = the pod is terminated, or, when a render is still running on it or the user has renders waiting, it goes back to the normal pool (it stops 3 min after its last job, charged like any pod).

| | |
|---|---|
| `GET /v1/gpu/warm` | → `WarmGpu` (mine) |
| `POST /v1/gpu/warm` `{on: true}` | → `WarmGpu` (`starting`, or `warm` when it took over a ready pod). Takes the user's own pod if they have one, else an idle ready pod, else starts one. Idempotent while on. Errors: `warm_not_allowed` (403, the studio allows only the owner), `insufficient_tokens` / `insufficient_balance` (402, can't cover 10 minutes), `owner_balance_low` (402), `no_gpu_free` (409, all `maxGpus` pods are in use), `no_gpu_available` (503, RunPod has no H100/H200 right now). |
| `POST /v1/gpu/warm` `{on: false}` | → `WarmGpu` (`off`, `lastOff.reason: "user"`). Fine when already off. |
| `POST /v1/gpu/warm` `{extend: true}` | → `WarmGpu`. **Keep warm** (the warning's action): restarts the idle clock, and when the cap is the next auto-off (`autoOffReason: "cap"`) extends it once by `warmMaxMinutes` (`canExtend` turns false). `not_warm` (409) when off. |

Live: `gpu` events (to that user only) carry the full `WarmGpu` and `event`: `state` on every change (`starting` → `warm` → `stopping` → `off`, with `lastOff` on off), `tick` after each minute is settled (the bar's minutes and cost), and `warning` with `warning: WarmWarning` 5 min before an idle or cap auto-off.

Studio settings carry `warmGpuAllowed: "owner"|"everyone"` (default **everyone**), `warmIdleMinutes` (default 20) and `warmMaxMinutes` (default 120); the owner changes them with `PATCH /v1/settings/studio`.

The apps: **nudge** when creating starts (a clip picked or uploaded in the video studio, or Generate opened) and the user has no warm GPU: "Warm up a GPU now so your render starts right away? About $4/hour from your credit while it's on, and it turns off by itself after 20 min without renders." [Warm up] [Not now]. A manual **Keep GPU warm** switch shows the same cost warning on every switch-on. While on: a bar on every screen, "GPU warm · 42 min · $2.80 so far · Turn off" ("GPU starting… · Turn off" while `starting`).

### Live events
`GET /v1/events` is a `text/event-stream`. Each message is `data: <ApiEvent JSON>`. While a job runs, `job` events arrive about every 250 ms (`progress`, `step`, `phase`, `secondsLeft`). `lora` events carry training progress (about every 250 ms) and the `building` → `review` change. `post` events carry `handoff`/`posted` changes. When the job finishes, a `job` event arrives with `state: "done"` and its new `takes`, or with `state: "failed"`, `error` and `refunded`. Each failure is followed by a `balance` event. Clients reconnect with backoff. The Android app turns finished and failed jobs into local notifications. A real backend can add FCM push behind the same events.

### Developer (mock, and the real API only with `DEV_MODE=true`)
| | |
|---|---|
| `POST /v1/dev/fail-next` `{failNext}` | The next job fails at step 3 and is refunded. |
| `POST /v1/dev/reset` | Restores the seed data. |
| `GET /health` | `{ok, speed}` (real API also: `build`, `gpu`, `storage`, `imageEngine`, `videoEngine: "replicate"\|"h3"`) |

## Notes for the real backend
- Run the H3 Ref2VA pipeline (`pipeline/runpod/h3_ref2va_run.py`) on a network-volume pod, map the denoising step callback to `step`, and shut the pod down when the queue is empty.
- Build the prompt with the layered engine (`plans/prompt-system.md`, implemented in `android/core/.../PromptEngine.kt`) and store the exact prompt, seed, steps and references on the job.
- Show "MiniMax H3" attribution and pass through its licence and acceptable use terms (both the Replicate-hosted and the RunPod engine are MiniMax H3).
