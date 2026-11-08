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
| `over_allocation` | 402 | the owner tried to send more credit than the studio balance has free (top-ups − spending − credit already with members) |
| `balance_unavailable` | 503 | _retired 2026-11-04 (app clean-up): the studio balance is the server's own ledger, so it is always known_ |
| `engine_unavailable` | 400 | that option can't run right now ("Draft, Standard and HD aren't available right now", "Edit isn't available right now", "Fast · beta isn't available yet", lip sync, LoRA training) |
| `image_engine_failed` | 502 | making the photos failed: "Something went wrong making the photos · you weren't charged" (the hold is released) |
| `provider_refused` | 422 | the content filter refused it: "This photo was refused by the content filter · you weren't charged" (photos). Video jobs fail with `Job.errorCode: "provider_refused"` and "This clip was refused by the content filter · you weren't charged" |
| `provider_rate_limited` | 429 | photos only: busy for longer than `REPLICATE_IMAGE_MAX_WAIT_SEC` (120 s): "Busy right now · you weren't charged. Try again in a minute." Video jobs never fail on this: they wait in line |
| `provider_out_of_credit` | 503 | _added 2026-11-04._ An engine's own account refused for lack of credit: "Something went wrong · you weren't charged. The studio owner has been told." (photos). Video jobs fail with `Job.errorCode: "provider_out_of_credit"` and the same message. Owners get a `wallet` event with `notice.code: "provider_out_of_credit"` |
| `upscale_unavailable` | 409 | _added 2026-11-04._ `POST /v1/takes/{id}/upscale` while Upscale is coming soon: "Upscale is coming soon" |
| `rate_limited` | 429 | too many sign-in or sign-up tries |
| `template_hidden` | 403 | saving a template from a shot made with someone else's template |
| `warm_not_allowed` | 403 | _retired 2026-11-04:_ Keep add-on engine ready is owner-only, members get `owner_only` |
| `model_incompatible` | 400 | _added 2026-11-04._ owner picked a model that can't do that step ("Model tools" §2) |
| `model_archived` | 409 | _added 2026-11-04._ new work on an archived model ("Model tools" §7) |
| `owner_balance_low` | 402 | _retired 2026-11-04:_ nothing pauses or refuses on a provider's balance any more |
| `no_gpu_free` / `no_gpu_available` | 409 / 503 | Keep add-on engine ready with every add-on engine in use / none free right now (owner only) |
| `not_warm` | 409 | Keep ready (`extend`) while it's off (owner only) |

**Every message in `error` and `Job.error`/`Job.phase` is member-safe** (no GPU, warm-up, steps, start-up or provider names), see "App clean-up" below.

## App clean-up: provider-neutral MUSE (2026-11-04)
_Spec: `plans/app-cleanup.md`. This section wins where an older section below disagrees._ Members see results, time and price. Provider names (Replicate, RunPod, H3, Lite, SeedVR2), GPUs, warm-ups, steps and start-up appear **only in owner Settings → Engines**.

### 1. What members see (server strings, shown as-is)
`Job.phase` (the server writes it; apps show it next to time and price, e.g. "Rendering · about 2 min · $0.14"):

| when | `phase` |
|---|---|
| waiting, first in line | `"Waiting to start"` (+ `" · starts in ~3 min"` when known) |
| waiting behind others | `"#2 in line"` (+ `" · starts in ~3 min"`) |
| getting the engine ready / loading | `"Getting ready · ~4 min left"` |
| preparing a clip | `"Preparing the clip"` |
| busy, retrying | `"Waiting to start · retrying in 10s"` |
| rendering | `"Rendering · ~6 min left"` (several takes: `"take 2/3 · Rendering · ~6 min left"`) |
| lip sync pass | `"Lip sync · ~2 min left"` |
| finishing (trim, audio, upload) | `"Finishing"` |
| done / failed | `"Done"` / `"Failed"` |

`step`/`totalSteps` stay in the JSON for progress maths but are never shown. `Job.blocked` is never set any more (nothing pauses on a provider balance).

`Job.error` / API `error` (shown as-is):

| case | message |
|---|---|
| anything broke (engine error, disconnect, no output) | `"Something went wrong · you weren't charged"` |
| content filter | `"This clip was refused by the content filter · you weren't charged"` / `"This photo was refused by the content filter · you weren't charged"` |
| too long | `"This took too long and was stopped · you weren't charged"` |
| busy too long | `"Busy right now · you weren't charged. Try again in a minute."` |
| an engine's own account is out of credit | `"Something went wrong · you weren't charged. The studio owner has been told."` (`errorCode: "provider_out_of_credit"`) |
| owner short of studio balance | `"Not enough in the studio balance · add a top-up in Credits"` (`insufficient_balance`) |

`Job.errorCode` keeps its machine values (`provider_refused`, `provider_failed`, `provider_rate_limited`, `provider_timeout`) plus `provider_out_of_credit`; codes are never shown.

Labels: `Job.engineLabel` = `"Draft · 768P"`, `"Standard · 768P"`, `"HD · 2K"`, `"Edit"`, `"Fast · beta"` (later `"Upscale · 2K"`). `Take.label` = `"Draft"`, `"Standard"`, `"HD"`, `"Edit"`, `"Fast · beta"`. Photo shots have `engineLabel: ""` (the engine is never shown on a photo). Apps must not show `Job.warmupCost` to members.

### 2. Video options
`GET /v1/settings/studio` → `features.video`:
```ts
VideoFeatures { defaultEngine, defaultQuality: "draft", minSeconds: 4, maxSeconds: 15,
                options: RenderOption[],   // the Render picker, in order: draft, standard, hd  (no "exact" any more)
                addons: AddonOption[] }    // in order: edit, fast, upscale
RenderOption { id: "draft"|"standard"|"hd", label: "Draft"|"Standard"|"HD", detail: "Quick preview · 768P"|"768P"|"2K",
               engine: "replicate", quality, resolution: "768P"|"2K", pricePerSec, available }
AddonOption  { id: "edit"|"fast"|"upscale", label: "Edit"|"Fast · beta"|"Upscale", detail, available: boolean,
               comingSoon?: true /* upscale today */, sends?: Partial<JobRequest> /* edit, fast */, sizes?: UpscaleSize[] /* upscale */ }
UpscaleSize  { id: "1080p"|"2k"|"4k", label: "1080p"|"2K"|"4K", width: 1080|1440|2160, height: 1920|2560|3840,
               available: boolean /* false today */, price: number|null /* null until measured */ }
```
| id | label | detail | sends | price |
|---|---|---|---|---|
| `draft` (default) | Draft | Quick preview · 768P | `{engine: "replicate", quality: "draft"}` | $0.02 × D × takes |
| `standard` | Standard | 768P | `{engine: "replicate", quality: "standard"}` | $0.08 × D × takes |
| `hd` | HD | 2K | `{engine: "replicate", quality: "hd"}` | $0.13 × D × takes |
| `edit` | Edit | Swaps her into every frame of the whole clip | `{engine: "h3", use: "full", steps: 10}` | the Exact edit formula with steps 10 and the whole clip |
| `fast` | Fast · beta | Quicker and rougher · beta | `{engine: "viggle", use: "full"}` | the Fast · beta formula on the whole clip |
| `upscale` | Upscale | Sharper 1080p, 2K or 4K from a finished take | `POST /v1/takes/{id}/upscale {size}` | coming soon |

- **Render** = Draft / Standard / HD, one picker. **Add-ons** = Edit, Fast · beta (shown only when `available`), Upscale.
- **Edit** (was "Exact edit") always renders the whole clip with the default steps. Apps never show steps, "First 5.2s / Full", GPU start-up or Keep warm. Lip sync and "New background photo" stay Edit-only. The server still accepts `steps`/`use` from older clients.
- **Upscale** (SeedVR2 on the add-on engine, not built yet): sizes 1080p = 1080×1920, 2K = 1440×2560, 4K = 2160×3840. _2026-11-06:_ built. A size is `available` (with `price` = $ per output second) once it is priced in config `UPSCALE_PRICES` (measured: `{"2k": {"usdPerSec", "gpuSecPerSec"}}`) **and** the pods advertise `upscale`. Until then: `available: false`, `comingSoon: true`, `price: null`. Apps show an "Upscale" entry on a **finished render take** (`kind: "take"` with a `videoUrl`) with the three sizes greyed and "Coming soon". `POST /v1/takes/{id}/upscale {size: "1080p"|"2k"|"4k"}` → `409 upscale_unavailable` ("Upscale is coming soon") until it ships; once available it returns a `Job` (`request.engine: "upscale"`, `request.takeId`, `request.size`, `request.seconds`, `engineLabel: "Upscale · 2K"`), held at price × the take's seconds and settled at that quoted price; the result is a take labelled "Upscale · 2K". The worker gets `source.mp4` + `{size, width, height, seconds}` and uploads `take_1.mp4` (work kind `upscale`; gpu/worker registers it disabled until SeedVR2 is on the pod image).
- Price line under the picker: `"about $0.56 · 7 s"` as before; Edit and Fast use `"about $0.67"` (+ `" · 2 takes"`; no steps, no start-up). Generate button: unchanged from the fixtures (`"Generate · 7 s · $0.56"` for Render, `"Generate · 10 min · $0.67"` for Edit/Fast). Running, in the queue: `"<phase without its time> · about 2 min · $0.14"` (`"Rendering · about 2 min · $0.14"`, `"Waiting to start · $0.14"`, `"#2 in line · about 9 min · $0.14"`).

### 3. Photos: charged exactly what the engine charges (pass-through)
Fixed photo prices ($0.12 shoot, $0.08 outfit set, $0.02 an angle, $0.60 LoRA set) are **retired**. Every photo action holds an **estimate** at start and **settles to the exact cost** of the predictions it ran.

`GET /v1/settings/studio` → `features.photo`:
```ts
PhotoPricing { perRun: 0.015, perInputMp: 0.015, perOutputMp: 0.015, perEdit: 0.03, refMp: 0.79, maxRefs: 6, loraShots: 30,
               estimates: { shoot: 0.4644, outfitSet: 0.1911, sheetAngle: 0.1011, loraSet: 3.033 } /* refs = maxRefs, shoot = 4 photos */ }
```
(The values come from server config: `REPLICATE_IMAGE_RUN_USD`, `REPLICATE_IMAGE_MP_USD`, `REPLICATE_IMAGE_EDIT_USD`, `REPLICATE_IMAGE_MAX_REFS`; `refMp` is a reference shrunk to fit 1024 px at 3:4 = 1024×768 ≈ 0.79 MP. These are Replicate's published prices for FLUX.2 [pro] (`run_count` $0.015, `image_input_megapixel_count` $0.015, `image_output_megapixel_count` $0.015) and Qwen-Image-Edit 2511 (`image_output_count` $0.03), checked 2026-11-04.)

**Estimate formula** (doubles, evaluated left to right; `refs` = references sent, capped at `maxRefs`):
- `newShot(outMp, refs) = perRun + perOutputMp * outMp + perInputMp * refMp * min(refs, maxRefs)`; `outMp` = 2 for shoots (1080×1920 asks for "2 MP"), 1 for everything else.
- `shoot(count, refs) = count * newShot(2, refs)` (count 1–4, default 4)
- `outfitSet(refs) = newShot(1, refs) + 3 * perEdit` (front is a new shot, ¾/side/back are edits of it); "my own set" = 0
- `sheetAngles(missing, refs) = missing * newShot(1, refs)`
- `loraSet(refs) = loraShots * newShot(1, refs)`
- Shown as `"about " + '$' + v.toFixed(2)`: shoot "about $0.46", outfit set "about $0.19", one angle "about $0.10", LoRA set "about $3.03". Apps use `refs = maxRefs` (or `features.photo.estimates`); the server holds with the real reference count.
- Fixture: `android/core/src/test/resources/photo_pricing_fixture.json` `{params, rows: [{kind: "shoot"|"outfitSet"|"sheetAngles"|"loraSet", count, refs, outMp, estimate, label}]}`; server, Android and Mac check against it.

**Exact cost of one prediction** (server):
1. If Replicate's prediction reports a dollar figure (`metrics.cost_usd` or `metrics.cost`), that.
2. Else Replicate's billing counts when present (`metrics.run_count`, `metrics.image_input_megapixel_count`, `metrics.image_output_megapixel_count`, `metrics.image_output_count`) × the prices above.
3. Else measured: FLUX.2 [pro] = `perRun + perInputMp × Σ(width×height/1e6 of each input image as sent) + perOutputMp × (width×height/1e6 of the image received)`; Qwen edit = `perEdit` per output image.
Worked example: a 4-photo shoot with 6 references of 768×1024 (0.786432 MP each) and outputs of 1088×1920 (2.08896 MP) costs per photo 0.015 + 0.015 × 4.718592 + 0.015 × 2.08896 = **$0.11711** and **$0.46845** for the shoot; the hold was $0.4644 ("about $0.46"), the settle row says $0.46845 and the member's wallet moves by 47 tokens (tokens round up to the cent).

**Billing:** start → `hold` (caps and wallet checked: `insufficient_tokens`/`insufficient_balance`, cap codes); done → `settle` to the exact sum (ledger `amountUsd` is exact; `tokens` = the exact amount rounded up to a whole token); failed → the hold is released in full (the member isn't charged) and anything the engine already billed for photos that were thrown away goes on a studio `overhead` row ("Photos that didn't finish"). Sheet fills settle to the angles that worked. `Take.cost` of a shot = that photo's exact cost; `Outfit.cost` (new, optional) and `Lora.cost` = the exact amount once settled. `POST /v1/models/{id}/fill-angles` → `{model, cost}` where `cost` is the estimate held. Ledger notes: `"Photoshoot · 4 photos"`, `"Outfit set"`, `"Character sheet · 2 angles"`, `"LoRA training set · 30 photos"` (`" · hold"` on the hold). Simulated engines settle to the estimate.

### 4. Studio balance (owner-loaded) replaces the RunPod balance
The owner loads money into MUSE by recording **top-ups**; every engine's spending is tracked against it in the server's ledger; members get credit from it as before. RunPod's own balance no longer backs anything, nothing pauses because a provider's balance is low, and there are no "Top up RunPod" or runpod.io links.
```ts
StudioBalance { balanceUsd /* toppedUpUsd − spentUsd */, toppedUpUsd, spentUsd /* all engines, all users, since `since` */,
                membersCreditUsd /* members' unspent credit, spendable + held */, heldUsd /* the owners' running holds */,
                availableUsd /* balanceUsd − membersCreditUsd − heldUsd: what the owner can spend or send; may be negative */,
                since /* epoch ms the studio ledger started */, needsFirstTopUp: boolean /* no top-up recorded yet */,
                topUps: TopUp[] /* newest first, ≤ 20 */ }
TopUp { id, amountUsd, note: string|null, paidAt /* epoch ms the owner says they paid */, createdAt, createdBy }
```
| | |
|---|---|
| `GET /v1/studio/balance` (owner) | → `StudioBalance` |
| `POST /v1/studio/topups` `{amountUsd /* 0 < x ≤ 10000 */, note? /* ≤ 200 */, paidAt? /* epoch ms, default now, not in the future */}` (owner) | → `StudioBalance`. Ledger row `kind: "topup"`, `amountUsd: +x`, note `"Added $20.00"` (+ `" · <note>"`). `balance` and `wallet` events follow. |
| `GET /v1/studio/topups?limit=` (owner) | → `TopUp[]`, newest first |
| `POST /v1/balance/topup` `{amount, note?}` | Kept as an alias of `POST /v1/studio/topups` for the owner (`method` ignored, returns `Balance`); members get `owner_only`. |

- `spentUsd` = Σ `amountUsd` of `settle`, `charge`, `overhead`, `warmup` and `warm` ledger rows since `since`.
- **Migration (chosen):** the opening balance is **$0**. `since` is set to the moment the migration ran, so earlier spending (already paid from RunPod) doesn't count; members keep their tokens, which shows as `availableUsd` below zero until the first top-up. Apps show "Add your first top-up" while `needsFirstTopUp`.
- `Balance` (owner): `balance` = `availableUsd`, `availableToSend` = `availableUsd`, `studioBalance` = `balanceUsd`, `needsFirstTopUp`, `balanceSource: "studio"`. `runpodBalance` is gone. Members: unchanged (`balanceSource: "wallet"`).
- `Wallet` (owner): `availableToSend`, `studioBalance`, `membersUnspentUsd`, `balanceSource: "studio"`.
- Owner jobs need `availableUsd ≥ price` (`insufficient_balance`). Transfers need `availableUsd ≥ amount` (`over_allocation`).
- If an engine's own account refuses for lack of credit (Replicate 402 or "insufficient credit", RunPod "insufficient balance" on start), the job fails at once with a full refund (`provider_out_of_credit`), and every owner gets a `wallet` event with `notice: {code: "provider_out_of_credit", engine: "replicate"|"runpod", message: "An engine is out of credit · see Settings → Engines"}`. Settings → Engines then shows that engine as `out_of_credit` until a job on it succeeds.
- `notice.code` `owner_balance_low` / `owner_balance_ok` are retired.

### 5. Owner Settings → Engines (the only place provider names appear)
`GET /v1/settings/studio` returns `engines` **for the owner only**:
```ts
Engines { list: EngineStatus[] /* replicate, runpod */,
          imageEngine: { provider, model, editModel?, label /* "FLUX.2 [pro] · Replicate" */ },
          addOn: { maxGpus, overheadPayer: "user"|"owner" /* "Who pays start-up" */, gpu: GpuStatus },
          keepReady: { idleMinutes, maxMinutes, ratePerHour } }
EngineStatus { id: "replicate"|"runpod", name: "Replicate"|"RunPod", usedFor: string /* "Draft, Standard and HD video · photos" | "Edit, Fast · beta, Upscale" */,
               keySet: boolean, status: "ready"|"no_key"|"simulated"|"out_of_credit"|"no_gpu", message?: string, outOfCreditAt?: number }
```
- Members' `GET /v1/settings/studio` = `{capPerJob, capPerDay, capPerUserDay, tokenUsd, features}` only. The owner also gets `maxGpus`, `overheadPayer`, `warmIdleMinutes`, `warmMaxMinutes`, `gpu` and `engines`. `minRunpodBalance`, `lowBalance` and `warmGpuAllowed` are gone (PATCH still accepts and ignores `warmGpuAllowed`).
- `PATCH /v1/settings/image-engine` is owner-only now (`owner_only`); `GET` stays for everyone but apps show it only in Engines.

### 6. Keep add-on engine ready (was "Keep GPU warm"): owner-only
- `GET/POST /v1/gpu/warm` (same body and `WarmGpu` shape) answer **`403 owner_only` for members**. `gpu` SSE events only ever go to the owner who switched it on.
- Owner UI: a switch **"Keep add-on engine ready"** in Settings → Engines, the same cost warning on every switch-on ("Keeps the add-on engine ready so Edit renders start right away. About $4/hour from the studio balance while it's on, and it turns off by itself after 20 min without renders."), idle/max minutes, and a small indicator only while it is on ("Add-on engine ready · 42 min · $2.80 · Turn off"). No nudge, no switch in the video studio, no bar, no ongoing notification or warnings for members.
- Auto-off rules unchanged (idle 20 min, cap 120 min + one extension, the owner's available balance can't cover 10 min, the pod lost); the RunPod-balance rule is gone (`lastOff.reason` is never `owner_balance` now). Warning text: `"Add-on engine turns off in 5 min (no renders)"`.
- Ledger notes (owner): `"Add-on engine ready · 12 min"`, `"Add-on start-up"`, `"Add-on idle"` (were "Warm GPU", "GPU warm-up", "GPU idle").

### 7. Strings the apps remove or rewrite
Keep GPU warm nudge/switch/bar/menu-bar flame/notification/5-minute warning/"Warm GPU turned off" toasts (members) → gone; "GPU warm-up $x" cost lines → gone; "Waiting for a GPU" → "Waiting to start"; "The GPU disconnected"/"the GPU stopped responding" → "Something went wrong · you weren't charged"; steps (10/15/30) and first 5.2 s/full → hidden; "RunPod balance", "Top up RunPod", runpod.io links, "Paused: the studio's GPU credit is low" → the studio balance; "#2 in the Replicate line" → "#2 in line"; "Exact edit" → "Edit"; the "Who pays GPU warm-up" setting → "Who pays start-up" in Engines.

## Model tools: image model catalog, Enhance, Dress up, archive (2026-11-04)
_Owner decisions 2026-11-04. This section wins where an older section disagrees._ Members never see a provider or model name here either: they get the owner's chosen defaults and neutral labels ("Option A", "Option B"). Model names, prices per unit and the catalog are **owner only**.

### 1. The character sheet has 7 images
`SheetSlot.key` gains **`"faceTq"`** (label "Face · ¾", a head-and-shoulders close-up turned three-quarters). `Model.slots` now has 7 entries in this order: `face, profile, front, tq, side, back, faceTq` (the new key is appended so clients that index by position keep working). Apps **show** them as two groups: face close-ups `face` (Face · front), `faceTq` (Face · ¾), `profile` (Face · profile); full body `front`, `tq`, `side`, `back`. Existing models get an empty `faceTq` slot (`source: "upload"`, `busy: false`). `PUT /v1/models/{id}/slots/faceTq` works like any slot; `fill-angles` fills it too. A missing face close-up stays a warning only.

### 2. Image steps and their models (owner: Settings → Engines → "Image models")
Every image-generation step runs on a configurable Replicate model. The owner can pick **any public Replicate model** for a step.

| `step` | label (owner) | used by | default model | price (Replicate, checked 2026-11-04) |
|---|---|---|---|---|
| `shot` | New shots | photoshoots, template shoots, outfit-set fronts, sheet fills, LoRA set | `black-forest-labs/flux-2-pro` | $0.015 per run + $0.015 per input MP + $0.015 per output MP |
| `edit` | Edits | outfit-set ¾ / side / back | `qwen/qwen-image-edit-2511` | $0.03 per output image |
| `realism` | Enhance · realism | Enhance step 1 | `black-forest-labs/flux-krea-dev` | $0.025 per output image |
| `upscale` | Enhance · upscale | Enhance step 2 | `philz1337x/clarity-upscaler` (community) | by time: $0.00115/s on A100 (40GB), typical run ≈ $0.018 |
| `dressA` | Dress up · Option A | Dress up | `qwen/qwen-image-edit-2511` | $0.03 per output image |
| `dressB` | Dress up · Option B | Dress up | `black-forest-labs/flux-2-pro` | the FLUX.2 [pro] formula |

```ts
ImageStep    "shot"|"edit"|"realism"|"upscale"|"dressA"|"dressB"
PriceInfo    { kind: "per-unit", units: { metric: string /* "image_output_count", "run_count", "image_input_megapixel_count", … */, usd: number, label: string /* "per output image" */ }[] }
           | { kind: "per-second", usdPerSecond: number, hardware: string|null /* "A100 (40GB)" */, typicalUsd: number|null /* the model page's typical run */ }
           | { kind: "unknown" }
             // + source: "model page" | "config"
CatalogModel { id /* "owner/name" */, owner, name, description /* ≤ 200 chars */, runCount, official: boolean, coverUrl: string|null,
               price: PriceInfo|null /* null = not fetched yet (search results until opened) */,
               priceLine: string /* "$0.025 per output image", "$0.015 per run + $0.015 per input MP + $0.015 per output MP",
                                    "by time · about $0.018 a run ($0.00115/s on A100 (40GB))", "price unknown" */,
               compatible: boolean|null /* null = schema not read yet */, reasons: string[] /* why not: "needs an input image", "needs mask" */,
               warnings: string[] /* compatible but: "no reference images · faces may drift", "no strength control" */ }
InputField   { name, type /* "string"|"integer"|"number"|"boolean"|"array"|"enum" */, required: boolean, default?: any, enum?: any[],
               minimum?: number, maximum?: number, maxItems?: number, description?: string /* ≤ 300 */, mappedAs?: MappedRole }
MappedRole   "prompt"|"image"|"images"|"aspectRatio"|"width"|"height"|"resolution"|"seed"|"strength"|"scale"|"outputFormat"|"outputQuality"|"count"
Mapping      { prompt?: string, image?: { field: string, array: boolean, max: number|null }, extraImageFields?: string[] /* image_2, image_3 … */,
               aspectRatio?: string, size?: { width: string, height: string }, resolution?: string, seed?: string,
               strength?: { field: string, min: number, max: number }, scale?: { field: string, kind: "number"|"enum", values?: string[] },
               outputFormat?: string, outputQuality?: string, count?: string }
StepModel    { step, label, model /* "owner/name" in use */, defaultModel, isDefault: boolean, name, official: boolean,
               price: PriceInfo, priceLine, compatible: boolean, reasons: string[], warnings: string[],
               mapping: Mapping, extra: Record<string, any> /* the owner's advanced inputs, sent on every run of this step */ }
```

| | |
|---|---|
| `GET /v1/image-models` (owner) | → `{ steps: StepModel[] }` in the order above |
| `PUT /v1/image-models/{step}` `{model: "owner/name", extra?: object}` (owner) | → `StepModel`. The server reads the model and its latest version's schema. `400 model_incompatible` ("This model can't do <label>: needs mask") when the step's required inputs can't be mapped; `404 not_found` for an unknown model. `extra` (≤ 4 KB JSON): every key must be an input of the model (`bad_request` otherwise); `disable_safety_checker` (and any `*safety_checker*` key) is refused; values override what the mapping would send. |
| `DELETE /v1/image-models/{step}` (owner) | → `StepModel` back on the default |
| `GET /v1/image-models/catalog?step=&q=&collection=` (owner) | → `{ step, collections: {slug, name}[], models: CatalogModel[], cachedAt }`. Without `q`: the models of the step's collections (below), most-run first, with compatibility for `step`. With `q`: Replicate's search (≤ 20 results; each result's schema and price are read, so `compatible` and `price` are filled). `collection` (a slug from `GET /v1/image-models/collections`) lists that collection instead. |
| `GET /v1/image-models/collections` (owner) | → `{slug, name, description}[]` (Replicate's collections) |
| `GET /v1/image-models/model?id=owner/name&step=` (owner) | → `CatalogModel & { mapping: Mapping, inputs: InputField[], version: string }`: one model, for "paste any owner/model" and the advanced view |

Collections per step: `shot` → `text-to-image`, `image-editing`; `edit`, `dressA`, `dressB` → `image-editing`; `realism` → `image-editing`, `text-to-image`; `upscale` → `super-resolution`, `ai-image-restoration`. Members get `403 owner_only` from every `/v1/image-models` endpoint.

**Per-run override (owner only):** `POST /v1/shoots`, `POST /v1/outfits`, `POST /v1/models/{id}/enhance`, `POST /v1/models/{id}/dress-up` (and their `/estimate`) accept `models?: { [step in ImageStep]?: "owner/name" }` for that one run. A member sending `models` gets `403 owner_only`. Owner apps show a small "Model" chooser on Shoot, Enhance and Dress up (opens the catalog for that step; "Default" clears it). Members never see it.

**Schema mapping (server):** for a chosen model the server reads `latest_version.openapi_schema.components.schemas.Input` (enums are resolved from `$ref`s) and `Output`, and maps:
- prompt: `prompt` (else `instruction`, `text`); image input: `image`, `input_image`, `input_images`, `images`, `image_input`, `image_url(s)`, `reference_images`, `init_image`, `img` (an array field with its `maxItems`, else a single field; extra single fields `image_2`, `image_3`… count as more images);
- size: `aspect_ratio` (the nearest enum value, or `match_input_image` for edits when offered) or `width`/`height` (clamped to min/max, multiples of 16), `resolution`/`megapixels` ("1 MP"/"2 MP", "1"/"2");
- `seed`; strength: `prompt_strength`, `strength`, `denoising_strength`, `creativity`; scale: `scale_factor`, `scale`, `upscale_factor` (enum values like "2x"/"4x" or numbers), `upscale`;
- `output_format` (jpg/jpeg when offered), `output_quality` 95, a count field (`num_outputs`, `num_images`, `max_images`) = 1;
- **never sent:** `disable_safety_checker` (or any safety-checker switch); it stays at the model's default.
- Not compatible when a required input has no default and isn't mapped, when the output isn't an image (URI or list of URIs), or the step needs what the model lacks: `edit`/`realism`/`upscale` need an image input; `shot`, `edit`, `realism`, `dressA/B` need a prompt; `dressA/B` need at least two images (an array or several image fields).
- Known defaults keep their tested inputs (FLUX.2 [pro] `safety_tolerance` (5 since 2026-11-05, see "Identity images, safety tolerance and reference sheets" §1) and "1 MP"/"2 MP"; Qwen `match_input_image`).

**Catalog caching:** collections and the step lists are cached 12 h (`REPLICATE_CATALOG_TTL_SEC` = 43200), a model's schema 6 h, a model's price 24 h. Every call uses the server's `REPLICATE_API_TOKEN`; Replicate's catalog reads are free.

### 3. Pricing: estimate, hold, exact settle (any model)
**Price source:** official models: the per-unit prices on the model's page (`https://replicate.com/<owner>/<name>`, the `billingConfig` of its pricing data: metric + price per unit, first tier). Community models are billed by time: the page's hardware price per second (`"$0.00115 per second"`, hardware "A100 (40GB)") and its typical cost per run. The two defaults on config prices (`shot`, `edit`) keep the config values of "App clean-up" §3.

**Estimate of one prediction** (`est`, doubles):
- per unit: Σ units × price, with units: `run_count` = 1, `image_output_count` = 1, `image_output_megapixel_count` = output MP (1, or 2 for shoots), `image_input_megapixel_count` = Σ input MP sent (0.79 per shrunk reference; an un-shrunk sheet image counts as 0.79 too for the estimate), any other metric = 1.
- by time: the typical run cost; × (scale/2)² for upscales (4× ≈ 4 × the 2× typical); without a typical figure, `REPLICATE_TIME_EST_SEC` (20) × the price per second.
- unknown: `REPLICATE_UNKNOWN_EST_USD` ($0.05) per prediction.

**Exact cost of one prediction:** 1) `metrics.cost_usd`/`metrics.cost` when reported; 2) per unit: the prediction's billing counts in `metrics` (same metric names) × price, else the measured units (input MP as sent, output MP as received, 1 run/image); 3) by time: `metrics.predict_time` × price per second; 4) unknown price: settles on the estimate and the server logs `"price unknown · settled on estimate"` with the model id (owner ledger note gets `" · estimated"`).

**Holds:** each action holds Σ estimates at start (caps and wallet as for photos), settles to Σ exact costs of what it kept, releases on failure (anything already billed goes on a studio `overhead` row, as for photos). Ledger notes: `"Enhance · 7 images"`, `"Dress up · 7 images"` (`" · 2 options"` for Both), `"Enhance · retry 1 image"`, `"Dress up · retry 1 image"` (`" · hold"` on holds).

### 4. Enhance (character sheet → Enhance)
`GET /v1/settings/studio` → `features.tools`:
```ts
ToolsFeatures { enhance: { available: boolean, realism: { id: "off"|"subtle"|"balanced"|"strong", label: "Off"|"Subtle"|"Balanced"|"Strong" }[] /* default "balanced" */,
                           upscale: { id: "off"|"2x"|"4x", label: "Off"|"2×"|"4×" }[] /* default "2x" */ },
                dressUp: { available: boolean, options: { id: "a"|"b"|"both", label: "Option A"|"Option B"|"Both", detail: string }[] /* default "a" */ } }
// details: a = "Keeps each photo closest", b = "Richer detail", both = "Makes both · pick per photo"
// owner only, extra: enhance.models / dressUp.models = { [step]: { model, name } } (the current defaults)
```
- `POST /v1/models/{id}/enhance/estimate` `{realism?, upscale?, slots?, models?}` → `{ images: 7, estimate: 0.301, label: "7 images · about $0.30", perImage: 0.043 }`
- `POST /v1/models/{id}/enhance` `{realism?: "balanced", upscale?: "2x", slots?: SlotKey[] /* default: every filled slot */, models?}` → `ToolRun` (`state: "running"`). `bad_request` when both steps are off or the sheet has no images.
- **Step 1 realism** (`realism` model, img2img): the slot image (original size, not shrunk) as `image`, `prompt_strength` Subtle 0.25 / Balanced 0.35 / Strong 0.5, **one seed and one prompt for every image**: `"candid smartphone photo, natural skin texture with visible pores and fine lines, true-to-life colour, soft natural light, no retouching, no beauty filter"`, aspect ratio nearest to the image. **Step 2 upscale** (`upscale` model) on step 1's output (or the original when realism is off): `scale_factor` 2 or 4, low creativity (clarity: `creativity` 0.2, `resemblance` 1.0; other models: their scale field only). Either step can be off.
- Images run one after another; `tool` SSE events carry progress (`phase: "Enhancing · 3 of 7"`).

### 5. Dress up (model profile and outfit screens)
- `POST /v1/models/{id}/dress-up/estimate` `{engine?: "a"|"b"|"both", models?}` → `{ images: 7, estimate, label: "7 images · about $0.21" }` (Both: `"7 images · 2 options · about $0.86"`)
- `POST /v1/models/{id}/dress-up` `{outfitImage: ImageRef /* one outfit-sheet photo: clothes + accessories */, name?: string /* ≤ 80 */, engine?: "a"|"b"|"both" /* default "a" */, models?}` → `ToolRun`. `bad_request` without `outfitImage` or when the sheet has no images.
- For each engine: the **full-body front first** (`[sheet front, outfit image]`), then every other filled slot with `[that sheet image, outfit image, the new front]` so prints, colours and details match. **One seed for the whole set.** Full-body angles get the whole outfit; face close-ups get only what shows at that distance (earrings, necklace, glasses, hat, hair pieces) and the top's neckline. Face, hair, body, pose, framing and background of each sheet image stay the same. Option A (`dressA`) gets `image: [...]`; Option B (`dressB`) gets `input_images: [...]` (whatever the mapping says for a swapped model).
- The original sheet is **never** changed.

### 6. Review and apply (both tools)
```ts
ToolRun  { id, kind: "enhance"|"dressup", modelId, state: "running"|"review"|"applied"|"failed"|"discarded",
           options: { realism?, upscale?, engine?: "a"|"b"|"both", name?, outfitImage?: ImageRef },
           engines: ("a"|"b")[] /* dressup: which options ran; enhance: ["a"] */,
           items: ToolItem[], estimate, cost /* exact, settled so far */, progress /* 0–100 */, phase /* member-safe */,
           error?, createdAt, finishedAt?, appliedAt?, outfitId? /* dressup, once applied */,
           models?: { [step]: string } /* owner only: the models used */ }
ToolItem { slot: SlotKey, label /* "Face · ¾" */, before: ImageRef|null, results: { a?: ImageRef|null, b?: ImageRef|null },
           state: "waiting"|"running"|"done"|"failed", decision: "pending"|"keep"|"reject", pick: "a"|"b"|null, cost, error? }
SheetVersion { id, createdAt, reason: "enhance"|"restore", slots: SheetSlot[] }
```
| | |
|---|---|
| `GET /v1/tool-runs?modelId=&kind=` | → `ToolRun[]`, newest first (≤ 20) |
| `GET /v1/tool-runs/{id}` | → `ToolRun` |
| `PATCH /v1/tool-runs/{id}/items/{slot}` `{decision: "keep"\|"reject", pick?: "a"\|"b"}` | → `ToolRun`. `keep` needs a result (`pick` defaults to the only option, `"a"`). Only in `review`. |
| `POST /v1/tool-runs/{id}/pick` `{pick: "a"\|"b"}` | → `ToolRun`: keeps that option for every item that has it (whole set). |
| `POST /v1/tool-runs/{id}/items/{slot}/retry` `{engine?: "a"\|"b"}` | → `ToolRun`. Runs that one image again (new seed) with its own hold → exact settle; the item goes `running`, then back to `done` with `decision: "pending"`. |
| `POST /v1/tool-runs/{id}/apply` `{name?}` | → `{ run, model, outfit? }`. **Enhance:** kept images replace their sheet slots (`source: "generated"`); the sheet as it was is saved first as a `SheetVersion` (`reason: "enhance"`). **Dress up:** a NEW outfit on the model (`mode: "dressup"`, `state: "ready"`, `name` = the body's name, else the run's name, else "Dressed look"), `angles` = the kept front / ¾ / side / back, `faces` = the kept face / face ¾ / profile (`null` where rejected or missing); attached to the model. Needs at least one kept item (`bad_request`). |
| `DELETE /v1/tool-runs/{id}` | 204. Discards the results (what ran was already paid for). A running run is stopped; images not made yet are released from the hold. |
| `GET /v1/models/{id}/sheet-versions` | → `SheetVersion[]`, newest first (the last 10 are kept) |
| `POST /v1/models/{id}/sheet-versions/{vid}/restore` | → `Model`. The current sheet is saved as a version (`reason: "restore"`) first. |

SSE: `{ type: "tool", tool: ToolRun }` on every change (to the studio). `Outfit` gains `mode: "dressup"` and `faces?: (ImageRef|null)[3] /* face, face ¾, profile */`. A dress-up outfit works everywhere an outfit does: photoshoots use its `faces` as the face references (before the model's own), and video renders use them in place of the model's face shots (Replicate: face, profile, face ¾, then the outfit's front, ¾, back, side; Edit: face, profile, then the outfit's front, ¾, back), so the accessories match.

### 7. Archive models (owner)
| | |
|---|---|
| `POST /v1/models/{id}/archive` (owner) | → `Model` with `archived: true`, `archivedAt`. A `model` event follows (clients drop her from lists). |
| `POST /v1/models/{id}/unarchive` (owner) | → `Model` (`archived: false`) |
| `GET /v1/models` | leaves archived models out (everyone) |
| `GET /v1/models?archived=true` (owner) | → only the archived ones (Settings → "Archived models"); members get `owner_only` |

- Archived models vanish from every list and picker (Home, models, video studio, shoots, templates' model choice); `GET /v1/outfits` leaves out their outfits. Their outfits, photos, renders, posts and ledger rows stay untouched, and finished takes stay in the gallery.
- New work on an archived model (jobs, shoots, outfit sets, fill-angles, LoRA, Enhance, Dress up) → `409 model_archived` ("This model is archived · restore her in Settings → Archived models").
- `Model` gains `archived: boolean` (false when absent) and `archivedAt?`.

## Shoot references and the prompt library (2026-11-05)
_Owner decisions 2026-11-05. This section wins where an older section disagrees._ Two things: (A) up to 3 **reference images** per photoshoot that guide pose, look or scene, and (B) an owner-editable **prompt library**: every prompt the server sends to a model is a named template with a default in code and an optional owner override. **The server now builds the photoshoot prompt** (it used to come from the apps' prompt engines), so an owner edit applies to every photo, every member and every app at once.

### 1. Reference images in photoshoots (up to 3)
```ts
ShootGuide  "pose" | "look" | "scene"     // labels: "Pose & framing", "Look & colour", "Scene"
ShootRef    { image: ImageRef, guides: ShootGuide[] /* 1–3, no repeats */ }
```
- `pose` = pose and framing; `look` = light, colour grade, grain and camera feel; `scene` = the place / background. There is **no outfit guide**. Her face and body always come from her own sheet (and the outfit's) references, never from a reference image: every reference line ends with "do not take the face, body, hair or clothes from image k".
- `POST /v1/shoots`, `POST /v1/shoots/preview` and template shoots accept `refs?: ShootRef[]` (≤ 3). `bad_request` for more than 3, a ref without an image, empty or unknown `guides`.
- The image is any `ImageRef` (apps upload it with `POST /v1/uploads/images` first). Members get the same feature; nothing about models is shown.
- **Order and limits.** The images sent to the shot model are: her identity/outfit references (_since 2026-11-05: face front, face ¾, one body image, outfit front, product; see "Identity images, safety tolerance and reference sheets" §2_; before: face front, profile, outfit front and ¾, product, body shots, outfit back and side; at most `REPLICATE_IMAGE_MAX_REFS` = 6 of them), **then the reference images** in the order given. The total is capped at the shot model's image limit: `REPLICATE_IMAGE_MAX_INPUTS` (8) for the default shot model and the simulated/other engines, the schema's limit (array `maxItems`, or the image fields) for any other model. Over the limit, identity references are dropped from the end (least important first), **never the face front**; if the model still can't take them all (a 1- or 2-image model), the last reference images are dropped (`refs[i].dropped: true` in the preview) and get no prompt line. A model with no image input gets no images and no reference lines.
- **Prompt lines.** One `reference` slot per sent reference image, after `direction`, made from the library (§2): its guide lines in the order pose, look, scene, then the guard line, joined by spaces, with `{refIndex}` = that image's 1-based position in the images sent. Default: `"Copy the pose and framing from image 7. Copy the light, colour grade and camera feel from image 7. Do not take the face, body, hair or clothes from image 7."`
- **Price.** The estimate counts every image sent: per shot `run + output MP × price + 0.79 MP × (images sent) × input-MP price` for the default shot model (any other model: its own estimate with `inMp = 0.79 × images sent`). The hold is `count ×` that; the settle is exact (the input megapixels really sent). `features.photo` gains `maxInputs: 8` and `references: { max: 3, guides: [{id: "pose", label: "Pose & framing"}, {id: "look", label: "Look & colour"}, {id: "scene", label: "Scene"}] }`.
- Each shot stores its refs (`Take.refs?: ShootRef[]` on photoshoot stills) so a template saved from it doesn't copy them.

### 2. The server builds the photoshoot prompt
`POST /v1/shoots` (no template), full body:
```ts
ShootRequest { modelId, outfitId?, count? /* 1–4, default 4 */,
  presets?: boolean            /* default true; false = only identity, outfit, direction, reference and seed lines */,
  scene?: string /* ≤ 200: the chip label ("Rooftop · golden hour") or the user's own words; default: the library's default scene */,
  camera?: { shot: "Close"|"Medium"|"Full"|"Wide", lens: number /* mm, 8–400 */, aperture: string /* "f/2.8", ≤ 10 */ } /* default Medium, 35, f/2.8 */,
  light?: string /* ≤ 80, default "Golden hour" */, grade?: string /* ≤ 80, default "Phone-natural" */,
  direction?: string /* ≤ 500 */, lockSeed?: boolean, refs?: ShootRef[],
  prompt?: string /* ≤ 4000: "Edit as text". Sent to the model EXACTLY; nothing is built. Reference images are still sent. */,
  seed?, imageEngine?, models? /* owner */ }
```
- Without `prompt` the server builds the prompt from the studio's prompt library: identity, outfit, scene, camera, light (+ grade), direction (sanitised as before: clauses that would change her identity or add a never-add item are dropped and listed in `removed`), reference lines, style, never-add, seed. Lock look = a fixed seed for this model (`seedFor(name)`, as the apps had). Scene is now used whole ("rooftop · golden hour"), as the apps sent it.
- **`POST /v1/shoots/preview`** takes the same body (template fields too) and costs nothing:
```ts
ShootPreview { slots: PromptSlotView[] /* layer: identity|outfit|scene|camera|light|direction|reference|style|negative|seed (+ template|pose|product for template shoots) */,
               text: string /* exactly what POST /v1/shoots will send (with "prompt": that text) */,
               seed: number|null, removed: string[],
               images: number /* images that will be sent */, refs: { index: number|null /* its image number, null = dropped */, guides: ShootGuide[], dropped?: true }[],
               estimate: number /* the whole shoot (count stills) */, estimateLabel: "about $0.27", edited: boolean /* true when "prompt" was sent */ }
```
  The owner and members both get the full built text for a normal shoot (the same as the apps showed before). With `templateId` the slots are the viewer's view of a template shoot (`/v1/templates/{id}/prompt` rules: one locked `Template: <name>` line for anyone but its maker) plus the reference lines. With `prompt` set, `text` is that prompt and `slots` is one `{layer: "custom", text}`.
- **Apps:** the Prompt tool's "Final prompt" box, Copy and "Edit as text" use the preview's `slots` / `text` (refetch, debounced ~300 ms, whenever a choice changes). Shoot sends the choices (no `prompt`) unless the user is on "Edit as text", in which case it sends `prompt` = their text. The Shoot button's price is `estimateLabel`. The apps' own prompt engines stay only as the demo/offline fallback (and are checked against the server's fixture, `android/core/src/test/resources/shoot_prompt_fixture.json`).

### 3. Prompt library (owner: Settings → Prompts)
Every prompt or prompt fragment the server sends to a model is a library entry: a default in code, plus an optional owner override per studio (`prompt_overrides` table). A saved override is used for every new photo, outfit set, sheet fill, Enhance, Dress up, template shoot, LoRA set and video render in the studio, for owners and members alike. Running work keeps the prompt it started with.
```ts
PromptGroup  "photoshoot"|"references"|"sheet"|"outfits"|"enhance"|"dressup"|"templates"|"video"|"lora"
             // labels: Photoshoot, References, Character sheet, Outfits, Enhance, Dress up, Templates, Video, LoRA
Placeholder  { name: string /* "look" */, description: string, required: boolean }
PromptEntry  { key: string, group: PromptGroup, title: string, description: string,
               kind: "text" | "list" /* comma-separated items */ | "lines" /* one item per line */,
               default: string, current: string, overridden: boolean, allowEmpty: boolean,
               placeholders: Placeholder[], updatedAt: number|null, updatedBy: string|null /* email */ }
```
| | |
|---|---|
| `GET /v1/prompts` (owner) | → `{ groups: {id: PromptGroup, label}[], prompts: PromptEntry[] }` in the order below |
| `PUT /v1/prompts/{key}` `{text}` (owner) | → `PromptEntry`. `400 prompt_invalid` (message shown as-is) for an unknown `{placeholder}`, a missing required one, empty text where `allowEmpty` is false, or text over 4000 characters. `404 not_found` for an unknown key. Saving the default text clears the override. |
| `DELETE /v1/prompts/{key}` (owner) | → `PromptEntry` back on its default ("Reset to default") |
| `POST /v1/prompts/preview` `{key, text?}` (owner) | → `{ key, text /* this entry rendered with sample values */, example /* the whole prompt it is part of, built with this text and the sample model "Demo model" */, sample: Record<string,string> /* the values used */ }`. `text` defaults to the saved one. Same `prompt_invalid` errors as PUT, so the editor can show them while typing. |

Members get `403 owner_only` from every `/v1/prompts` endpoint and never see this section. **Event:** `{ type: "prompts", prompt: PromptEntry }` to the studio's owners after every PUT and DELETE.

**Placeholder rules.** A placeholder is `{name}` with `name` = a letter then letters/digits. Every `{name}` in the text must be one of that entry's placeholders (`Unknown placeholder {foo} · this prompt can use {name}, {look}`); every `required` one must be present (`Keep {refIndex} · this prompt needs it`). Other braces are left alone. Values are inserted as-is; a placeholder that has nothing to say (no LoRA, no anchor) becomes empty. A line that renders empty is left out of the prompt.

**Keys** (group · key · placeholders, **required in bold** · what the default does):

| group | key | placeholders | default / use |
|---|---|---|---|
| photoshoot | `style.house` | | `realistic smartphone photo, natural skin texture, true-to-life colour, no beauty filter, no AI gloss`: the house style in every photo prompt |
| photoshoot | `never.base` (list) | | `logos, extra fingers, warped jewellery`: appended to every model's never-add list |
| photoshoot | `shoot.default.scene` | | `Rooftop · golden hour` (no scene sent) |
| photoshoot | `shoot.default.light` | | `Golden hour` |
| photoshoot | `shoot.default.grade` | | `Phone-natural` |
| photoshoot | `shoot.identity` | name, look, refCount, lora | `{name}: {look}. Identity from {refCount} locked reference images{lora}.` (`lora` = ` + LoRA demo_v2 (photo)` or empty). Used by shoots, templates, sheet fills, outfit sets, LoRA sets |
| photoshoot | `shoot.outfit.set` | **outfit** | `Wearing: {outfit} (outfit reference set).` |
| photoshoot | `shoot.outfit.described` | **outfit** | `Wearing: {outfit}.` (an outfit described in words, no photos yet) |
| photoshoot | `shoot.outfit.product` | outfit | `Wearing: the outfit from the product photo reference ({outfit}).` |
| photoshoot | `shoot.scene` | **scene** | `Scene: {scene}.` (lower case) |
| photoshoot | `shoot.camera` | shot, lens, aperture, lensNote | `Camera: {shot} shot, {lens}mm lens, {aperture}{lensNote}.` |
| photoshoot | `shoot.camera.wide` | | `, slight wide-angle distortion` (`lensNote` at ≤ 24 mm) |
| photoshoot | `shoot.camera.tele` | | `, compressed background, creamy bokeh` (`lensNote` at ≥ 85 mm) |
| photoshoot | `shoot.light` | light, grade | `Light: {light}; grade: {grade}.` |
| photoshoot | `shoot.direction` | **direction** | `Direction: {direction}` |
| photoshoot | `shoot.style` | **style** | `Style: {style}.` (`style` = the house style) |
| photoshoot | `shoot.never` | **never** | `Never add: {never}.` (her list + the base list) |
| photoshoot | `shoot.seed.locked` | | `Seed: locked (variations keep the same look).` |
| photoshoot | `shoot.seed.new` | | `Seed: new each shot.` |
| references | `refs.pose` | **refIndex** | `Copy the pose and framing from image {refIndex}.` |
| references | `refs.look` | **refIndex** | `Copy the light, colour grade and camera feel from image {refIndex}.` |
| references | `refs.scene` | **refIndex** | `Use the place and background from image {refIndex}.` |
| references | `refs.guard` | **refIndex** | `Do not take the face, body, hair or clothes from image {refIndex}.` |
| sheet | `sheet.task` | angle, framing | `Task: {angle} shot on a plain light-grey studio background, even soft light, neutral expression, {framing}.` |
| outfits | `outfit.task` | **angle** | `Task: {angle}, plain studio background.` |
| outfits | `outfit.never.extra` (list) | | `visible brand logos` (added to never-add for outfit sets) |
| outfits | `outfit.seed` | seed | `Seed: {seed} (shared by all four angles).` |
| outfits | `outfit.edit` | **angle** | `Show the same person in exactly the same outfit, on the same plain studio background, as a {angle}. Keep the face, hair, body and every detail of the clothes exactly the same. Realistic smartphone photo, natural skin texture.` (¾ / side / back as edits of the front) |
| enhance | `enhance.prompt` | | the Enhance realism prompt ("Model tools" §4) |
| dressup | `dress.body` | anchor | full-body Dress up prompt; `{anchor}` = ` ` + `dress.anchor` when the new front is sent too, else empty |
| dressup | `dress.closeup` | anchor | face close-up Dress up prompt |
| dressup | `dress.anchor` | | `The last image shows the same outfit already worn: match its colours, prints and details exactly.` |
| templates | `template.scene` | **scene** | `Scene: {scene}.` (template scene + drawn background / time of day) |
| templates | `template.camera` | **camera** | `Camera: {camera}.` |
| templates | `template.light` | **light** | `Light: {light}.` |
| templates | `template.pose` | **pose** | `Pose: {pose}.` |
| templates | `template.product` | **product** | `Product: {product}.` |
| templates | `template.product.none` | **product** | `Product: {product} (no product photo: a plausible unbranded product).` |
| templates | `template.style` | **style** | `Style: {style}.` (template style + house style) |
| templates | `template.locked` | **name** | `Template: {name}` (the line non-makers see) |
| templates | `template.seed.locked` | seed | `Seed: {seed} (locked look).` |
| templates | `template.seed.new` | seed | `Seed: {seed} (new each shot).` |
| video | `video.replicate.subjects` | **subject** | `subject_definitions` of the short Draft/Standard/HD prompt |
| video | `video.replicate.summary` | | its `summary` |
| video | `video.replicate.retention` | **reference** | its `retention_analysis` (`reference` = face/body/outfit image ranges and never-add) |
| video | `video.replicate.detailed` | faceRef | its `detailed_description` (the user's direction is appended) |
| video | `video.edit.subjects` | performer, setting, name, look, refs, lora, audio | `subject_definitions` of the structured Edit prompt |
| video | `video.edit.summary` | audioTag, background, audio | its `summary` |
| video | `video.edit.retention` | video, tattoos, clean, n, outfit, never, audio | its `retention_analysis` |
| video | `video.edit.detailed` | outfit | its `detailed_description` (direction appended) |
| lora | `lora.variations` (lines) | | the 10 variation lines the 30 LoRA candidates cycle through |
| lora | `lora.variation` | **variation** | `Variation: {variation}.` (added under the sheet prompt) |

Defaults reproduce the prompts exactly as they were before the library (the shared fixtures still pass). There is no "Improve with AI" or scene-writer prompt yet; when one is added it joins the library.

**Apps (owner only):** Settings → **Prompts**: the groups above, each entry with its title, a one-line preview of the current text and an "Edited" badge when overridden. The editor: the current text (multi-line), placeholder chips (tap inserts `{name}`; required ones marked), "Reset to default" (DELETE, after a confirm), a live preview (`POST /v1/prompts/preview`, debounced) showing `text` and `example`, the `prompt_invalid` message inline, and Save (PUT). Members never see the section.

## Identity images, safety tolerance and reference sheets (2026-11-05)
_Owner decisions 2026-11-05. This section wins where an older section disagrees._ Three changes to every photo step on Replicate (server only; members see no model or provider names, only fewer images and lower estimates).

### 1. Safety tolerance 5
`REPLICATE_IMAGE_SAFETY` now defaults to **5** (env override kept). It is sent as `safety_tolerance` to FLUX.2 models (the default shot model and any `black-forest-labs/flux-2*` chosen for a step) and to `black-forest-labs/flux-kontext*` when its schema has the field, clamped to the field's `minimum`/`maximum`, and to the lower limit a field's description states for requests with input images (Kontext: "2 is currently the maximum allowed when input images are used", so Kontext with images gets 2, without images 5). Other models keep their own default. `disable_safety_checker` (or any safety-checker switch) is still **never** sent.

### 2. Fewer identity images (default 3)
Photo steps (photoshoots, template shoots, outfit-set fronts, sheet fills, LoRA sets) used to send up to 6 of her sheet images. They now send her **identity images**, most important first:
1. **face front** (`face`; never dropped),
2. **face ¾** (`faceTq`; her `profile` when the ¾ is empty),
3. **ONE full-body image**: the slot she chose (`identityBodySlot`: `front` (default), `tq`, `side` or `back`; the next filled body slot when that one is empty),
then, beyond 3 (studio setting below): her profile (when the ¾ was sent), then her other body angles. A Dress up outfit's own face close-ups (`faces`) stand in for hers. After the person images: the **outfit's front** angle when the step wears an outfit (shoots with `outfitId`), a product photo (template shoots, outfit sets from photos), then the user's **reference images** (§"Shoot references" §1, same model-limit rules: identity images give way from the end, never the face front).

```ts
Model          { …, identityBodySlot: "front"|"tq"|"side"|"back" /* default "front"; in GET /v1/models, every model view and live `model` events */ }
StudioSettings { …, identityRefs: number /* owner view only: how many of her own images a photo step sends, 1–7, default 3 */ }
features.photo { …, identityRefs: number /* the same, for every member: the estimates below use it */ }
ShootPreview   { …, referenceSheet: boolean /* true: the shot model takes one image, the images go as one reference sheet (§3) */ }
```
| | |
|---|---|
| `PATCH /v1/models/{id}` `{identityBodySlot}` | The owner or the member who made her (`createdBy`); anyone else gets `403 owner_only`. Other values: `bad_request`. → `Model` + a `model` event. |
| `PATCH /v1/settings/studio` `{identityRefs}` (owner) | 1–7 (`bad_request` otherwise); → the studio settings + a `settings` event. |

- **Prompt:** "Identity from N locked reference images" counts the person images really sent (3 by default).
- **Estimates:** fewer input megapixels: `features.photo.estimates` use `refs = min(identityRefs, maxRefs)` (shoot "about $0.32", outfit set "about $0.16", one angle "about $0.07" with the default prices), and holds count the images really sent (e.g. a plain shoot with an outfit: face, face ¾, body, outfit front = 4).
- DB: `models.identity_body_slot` (text, null = front) and `studio_settings.identity_refs` (integer, null = 3), migration `0006_identity_refs`.

### 3. Reference sheet for one-image models
A shot model whose schema takes **one** input image (a single image field, no array, no `image_2`… fields, and no strength input; e.g. FLUX Kontext Pro/Max) can't take her identity images and the references separately. For a new shot (shoots, template shoots, outfit-set fronts, sheet fills, LoRA sets) with more than one image the server builds **one reference sheet** and sends it as the only input:
- one JPEG (quality 90, ≤ 2048 px on the long side, neutral background), panels in the order the images would have been sent: her face front **largest** (a 2×2 block, top left), then the other identity images, the outfit, the product photo, then each reference image; each panel has a small numbered label ("1 FACE", "2 FACE 3/4", "3 BODY", "4 OUTFIT", "5 REF: POSE & FRAMING"). The layout depends only on the number of panels, so the estimate's megapixels are the real ones. Stored once under `rx/` (same images → same sheet).
- the prompt starts with the library line **`refs.collage`** (group References, "Reference sheet"; placeholders `{person}` = "panel 1 shows" / "panels 1–3 show", `{panels}` = "; panel 4 shows the outfit to wear; panel 5 guides the pose & framing only"). Default: `The input image is a reference sheet of numbered panels ("image N" below means panel N): {person} the person (use her face, hair and body exactly){panels}; create one new photo, not a collage.` The reference lines keep their image numbers (= panel numbers).
- `POST /v1/shoots/preview` shows it: `referenceSheet: true`, `text` starts with that line and `slots` starts with `{layer: "sheet", text}`; `images` / `refs[].index` count panels.
- **Price:** the estimate uses the sheet's megapixels (one input of that size, not 0.79 MP per image); the settle uses the sheet as sent.
- Catalog (owner): such a model is compatible for `shot` with the warning **"1 image: MUSE sends a reference sheet"** (it used to say "takes 1 reference only"). An img2img model (single image + a strength input, e.g. FLUX Krea dev) still gets only the face front: a sheet would show through.

## Prompt scripts (2026-11-05)
_Workstream 4; design in `plans/prompt-scripts.md`. This section wins where an older section disagrees._ Every prompt is assembled by a **script** (typed inputs → rules → blocks); blocks are the prompt library entries (above), so `/v1/prompts` is unchanged and every saved override keeps working. New here: the owner's **rule** edits, talking detection and the "Performer is speaking" switch.

### 1. Clips and renders
```ts
Clip      { …, audio?: { kind: "speech"|"music"|"silence"|"none", speaking: boolean, detected: boolean } }
          // classified on upload (free); absent while still running (a second `clip` event brings it) or when it failed
JobRequest{ …, speaking?: boolean|null /* the studio's "Performer is speaking" switch; absent = the clip's detection */ }
Job.request { …, speaking: boolean, speakingSource: "switch"|"upload"|"detected"|"default" }   // resolved at creation
```
- **Apps:** the video studio shows a **"Performer is speaking"** switch (a small toggle near Keep audio), pre-set from `clip.audio.speaking` (off when unknown), and sends `speaking`. One-line hint under it: on = "She talks or sings: her lips follow the clip's sound"; off = "Her mouth follows the clip; she won't lip-sync to the music".
- **Server:** the switch is one input with two effects. Not speaking → the model gets the clip **without sound** and the prompt ends "<Subject 2>'s mouth follows <Video 1> exactly; she does not speak, sing or mouth words." (no "words being mouthed"); the clip's own sound is put back on the take (video stream-copied, never re-encoded). Speaking → the clip goes with its sound and the prompt ends "<Subject 2>'s mouth follows <Video 1> and is in sync with <Audio 1>'s speech." Both lines are owner-editable blocks (`video.mouth.speaking`, `video.mouth.silent`). Keep audio off still gives a silent take. Edit: only the prompt follows `speaking`.
- The clip's "Performer talking" check follows the detection (`Yes`/`No`). Upload meta `talking: true` still means "talking" (and wins); `false` now means "unknown".
- Video prompts end with the user's direction as its own line: `Direction from the user: <direction>` (it used to be appended to `detailed_description`).

### 2. Settings → Prompts → Scripts (owner)
```ts
InputDef    { name, label, description, type: "bool"|"enum"|"number"|"text"|"list", options?: {id,label}[], fields?: InputDef[], sample }
CondOp      "is"|"isNot"|"in"|"notIn"|"atLeast"|"atMost"|"has"|"hasNot"|"empty"|"notEmpty"
Cond        { input: string /* an input name, or "item.<field>" in a section that repeats per list item */, op: CondOp, value?: boolean|number|string|string[] }
Rule        { id: string /* [A-Za-z0-9._-]{1,60} */, label: string /* ≤ 120 */, target: string /* a place id */, when: Cond[] /* ≤ 8, all must hold */,
              block: string /* a library key from `blocks` */, optional?: true /* removed by Presets off */, locked?: true, enabled?: false }
ScriptView  { id, group: PromptGroup, title, description, format: "lines"|"sections",
              inputs: InputDef[], sections: {id, label, kind: "system"|"user", each?, heading?}[],
              values: {name, label, prefix?}[] /* placeholders chosen by rules */, targets: {id, label}[] /* where a rule can put its block: section ids and "@value" */,
              vars: {name, description, sample}[] /* values the code supplies */, blocks: string[] /* library keys usable here */,
              rules: Rule[] /* current */, defaultRules: Rule[], overridden: boolean, stale: boolean /* a saved list no longer fits: shown as reset */,
              updatedAt: number|null, updatedBy: string|null /* email */ }
```
| | |
|---|---|
| `GET /v1/prompt-scripts` (owner) | → `{ groups: {id, label}[], ops: {id: CondOp, label, types: InputType[]}[], scripts: ScriptView[] }` |
| `GET /v1/prompt-scripts/{id}` (owner) | → `ScriptView` |
| `PUT /v1/prompt-scripts/{id}` `{rules: Rule[]}` (owner) | the whole list, in order → `ScriptView`. `400 script_invalid` (the `error` text is shown as-is): unknown input/test/value, a block the script can't use, an unknown place, duplicate ids, a **locked** rule removed, switched off or changed (`"Who is who" is locked: only its text can be changed`). Saving the defaults clears the override. `404 not_found` for an unknown id. |
| `DELETE /v1/prompt-scripts/{id}` (owner) | → `ScriptView` on its defaults |
| `POST /v1/prompt-scripts/preview` `{id, inputs?, rules?, texts?: Record<key,string>, direction?}` (owner) | → `{ id, text, parts: {section, layer, kind, text, rules: string[]}[], fired: string[] /* rule ids that matched */, inputs }`: the script run with the sample values, `inputs` over the samples, unsaved `rules` (validated like PUT) and unsaved block `texts`. Default direction `"smiling, glancing at the camera"`. |

Members get `403 owner_only` from every endpoint. **Event:** `{ type: "promptScript", script: ScriptView }` to the studio's owners after PUT and DELETE. A saved edit applies to every new prompt in the studio (renders resolve their prompt at creation).

**Editor (Android + Mac, owner only):** Settings → Prompts gets a **Blocks | Scripts** switch. Scripts: grouped like blocks; each row shows the title, description and an "Edited" badge. The script screen: **Inputs** (label, type, description), **Rules** grouped by place (each as a sentence: "When Performer is speaking is no → Summary: Draft/Standard/HD · summary (not speaking)"; a lock icon on locked rules; a switch to turn a rule off; tap → edit), **Blocks** (tap → the existing block editor), **Preview** (a control per input pre-filled with its sample: switch / menu / number; shows `text` and which rules fired), "Reset to default" (DELETE after a confirm) and Save (PUT). The rule form: label, place (menu of `targets`), block (menu of `blocks` by title), conditions (input menu → test menu filtered by the input's type from `ops` → value: switch, menu of options, number or text), add/remove condition, delete (added rules only), move up/down. Show the `script_invalid` message inline.

## Video editor: edited versions of a take (2026-11-05)
_Owner decision 2026-11-05. Spec, UX and limits: `plans/video-editor.md`._ The apps trim, split, change speed and mute a video take **on the device** and upload the result. The server stores it as a **new take** (`kind: "edit"`) linked to the take it was cut from, with the **edit list** so it can be re-opened and changed. The server never encodes video. It is free: no price, hold or ledger row. Members and owners alike.

```ts
EditSpeed   0.5 | 0.75 | 1 | 1.25 | 1.5 | 2
EditSegment { inSec: number, outSec: number, speed: EditSpeed, muted?: boolean }   // seconds of the SOURCE video
EditList    { version: 1, sourceTakeId: string, sourceDurationSec: number, segments: EditSegment[] /* 1–50, in order */, mute: boolean }
// Take gains: kind "edit"; parentTakeId?: string (the source take); edits?: EditList; fps?: number.
// An edit take has videoUrl, durationSec, width, height of the uploaded file, label "Edited", cost 0, status "test",
// and copies title, engineLabel, seed, modelId and prompt (with the same template-prompt hiding) from its source.
```

| | |
|---|---|
| `POST /v1/takes/{id}/versions` `{uploadId, thumbUploadId?, thumb?: ImageRef, edits: EditList, durationSec, width, height, fps?}` | → `Take` (`kind: "edit"`, `parentTakeId: id`). `{id}` is the take whose video the edits cut (a `take`, or an `edit` when its own source is gone); `edits.sourceTakeId` must equal it. `uploadId` comes from `POST /v1/uploads/presign {kind: "clip", contentType: "video/mp4"}` + the PUT (no `/confirm`: confirming would add it to the clip library). Thumbnail: `thumbUploadId` (presigned `image`, PUT done) or `thumb` (an `ImageRef` from `POST /v1/uploads/images`); without one the take starts with the source's thumb and the server may replace it with a single frame (ffmpeg grab, no re-encode) and send a `take` event. A `take` event goes to everyone in the studio. |
| `GET /v1/takes/{id}/versions` | → `Take[]`, the edited versions whose `parentTakeId` is `{id}`, newest first. (`GET /v1/takes` also returns them, so clients can group versions under their source by `parentTakeId`.) |

- **Rules** (`bad_request` with the field named): `edits` as in `plans/video-editor.md` "Edit list": `version` 1; 1–50 segments in source order, not overlapping, each ≥ 0.1 s, `0 ≤ inSec < outSec ≤ sourceDurationSec + 0.05`; `speed` one of the six; output Σ(out−in)/speed between 0.5 and 600 s; `durationSec` within max(0.5 s, 5 %) of that; `width`/`height` 16–4096; `fps` 1–240; the JSON ≤ 16 KB. The source must be a video take of the studio (`not_found` otherwise, `bad_request` "Edit works on a video take" for a photo).
- **Uploads:** the upload must be this studio's, a video (`bad_request`), and the PUT must have arrived (`upload_missing`, 409). An upload already saved as a take → `upload_used` (409). The thumbnail upload must be this studio's image.
- **Visibility and ownership:** the same as every take: everyone in the studio sees, approves (`PATCH`) and discards (`DELETE`) versions. Deleting a source keeps its versions (their `parentTakeId` then names a take that's gone; apps re-open such a version on its own video). Deleting a version never touches its source.
- No model names, prices or engines in the editor; `engineLabel` is the source's ("HD · 2K").

## Editor v2 (2026-11-05, workstream 3)
_Spec, data model, rules and rendering: `plans/video-editor.md` "Editor v2 (engine contract)". Reference code: `server/api/src/editor/` (model, presets, cuts); shared fixtures `server/api/test/fixtures/editor/` (same files in the Android and Mac test resources)._ The apps still render everything on the device; the server checks and stores the **edit project** with a version, and runs the paid **AI helpers** as jobs whose results the app applies to its project. Nothing here encodes video. Members and owners alike; nothing member-facing names a provider or model.

```ts
EditProject  { version: 2, sourceTakeId, canvas: { width, height, fps, background? }, assets: Asset[], tracks: Track[], mute? }   // plans/video-editor.md
EditorJobKind "captions" | "cuts" | "matte" | "denoise" | "beats"
EditorSource { takeId } | { uploadId, durationSec }            // a video take of the studio, or a video/audio upload of the studio (+ its length)
EditorJob    { id, kind, state: "running"|"done"|"failed"|"cancelled", progress /* 0–100 */, phase /* "Listening", "Waiting"… */,
               source: EditorSource & { durationSec }, options, estimateUsd, costUsd, result?, error?, createdAt, finishedAt?,
               models?: string[] /* owners only */ }
CaptionsResult { language, words: { text, startSec, endSec, score? }[] /* SOURCE seconds */, durationSec, reused: boolean }
CutsResult     { cuts: { startSec, endSec, reason: "silence"|"filler"|"repeat", text? }[] /* source s */, savedSec, words, language, options, durationSec }
MatteResult    { asset: { kind: "video", upload | take, url?, durationSec }, alpha: true, mode: "person" | "tracked", points?: KeepPoint[] }   // workstream 1: an alpha matte
KeepPoint      { x: 0–1, y: 0–1 /* of the frame */, t: seconds into the source (default 0), keep: boolean (default true) }
DenoiseResult  { asset?: { kind: "audio", upload | take, url?, durationSec }, suggestion: { level: "none"|"light"|"strong", reason, confidence: number|null } }
```

| | |
|---|---|
| `POST /v1/takes/{id}/versions` with `edits: EditProject` | As in "Video editor", but `edits.version: 2`: checked by the v2 rules (JSON ≤ 256 KB; `durationSec` must match the project's duration within max(0.5 s, 5 %)); every `take`/`upload` asset must be this studio's (`not_found`) and of a fitting kind (`bad_request`). v1 lists are unchanged. |
| `POST /v1/takes/{id}/versions` `{…, aiLabel?: boolean}` | Edit suite export "Label as AI-generated" (default off): kept with the version and returned as `Take.aiLabel: true`; posting uses it for the platform's AI label. C2PA signing is not implemented yet. |
| `POST /v1/takes/{id}/versions` `{…, name?: string}` | Optional version name, 1–80 characters after trimming (the Edit suite's save, or the `name` in Claude's `save_version` request). Kept with the version and returned as `Take.name`. |
| `POST /v1/editor/validate` `{project}` | → `{ok: true, durationSec}` or `bad_request` naming the first broken field (`edits.tracks.2.items.0.speed: …`). Free. |
| `GET /v1/editor/features` | → `{paid: {available, reason?}, captions: {available, languages}, cuts: {available, defaults}, matte: {available, maxSec: 120}, denoise: {available}, beats, maxSourceSec: 600}`. `available` is false for the paid helpers while the owner has them switched off: hide them. |
| `GET /v1/editor/settings` · `PATCH {paidHelpers?: "on"\|"off", capPerDayUsd?: number\|null}` (owner) | → `{paidHelpers, capPerDayUsd, todayUsd, markup, provider}`. The owner's runtime switch for paid helpers (no redeploy) and the studio's daily spend cap on them (`null` = `EDITOR_CAP_PER_DAY_USD`, default $5). Members get `403`. |
| `GET /v1/editor/presets` | → `{filters, captionStyles, hooks}` (the same tables the apps carry). |
| `POST /v1/editor/uploads/presign` `{contentType: "audio/mp4"|"audio/mpeg"|"audio/wav"|…, bytes?}` | → `{uploadId, method: "PUT", url, headers, expiresAt, fileUrl}` for a voice-over or music file (≤ 200 MB), or a video (`video/mp4`, `video/quicktime`, ≤ 2 GB) for the media bin. Use `uploadId` as an audio `Asset.upload`. |
| `POST /v1/editor/estimate` `{kind, source, options?}` | → `{kind, usd, tokens, free, reusesTranscript, durationSec}`. Free. |
| `POST /v1/editor/jobs` `{kind, source, options?}` | → `EditorJob` (`running`). Holds the estimate (`insufficient_tokens`/`insufficient_balance`/cap errors as for renders, before anything starts), runs, then settles at the GPU time actually billed (at least $0.01), or releases the hold on failure/cancel. Progress and the result arrive as `editor` events. |
| `GET /v1/editor/jobs?kind=&takeId=&uploadId=&limit=` | → my `EditorJob[]`, newest first (≤ 100). |
| `GET /v1/editor/jobs/{id}` | → `EditorJob` (mine; owners see any in the studio). |
| `DELETE /v1/editor/jobs/{id}` | Running → `{state: "cancelling"}` (stops; the hold goes back; the job ends `cancelled`). Finished → `{state: "deleted"}` (forgotten; an `editor` event with `op: "delete"`). |

**Kinds and options**
- `captions` `{language?: "auto"|"en"|…}` → `CaptionsResult`. Word timestamps of the source's speech. Free (reused, cost 0) when the same video already has a transcript from the last 30 days in that language.
- `cuts` `{minSilenceSec? 0.25–5 (0.7), keepPadSec? 0–0.5 (0.12), fillers? (true), repeats? (false), extraFillers?: string[] ≤ 50, fromJobId?, silenceOnly?, noiseDb? −60…−10 (−35)}` → `CutsResult`: suggested source ranges to remove (silences longer than `minSilenceSec`, keeping `keepPadSec` of each side; "um/uh/er/ah/hmm…" + `extraFillers`; a word said twice in a row). Free when a transcript exists (`fromJobId`, or the newest one of that video); otherwise it transcribes first (priced like captions). **`silenceOnly: true`** is always free and needs no transcript: the server reads the audio level (ffmpeg `silencedetect`, analysis only, nothing encoded) and returns silence cuts only (`words: []`); quieter than `noiseDb` counts as silence. The app shows the cuts and applies the accepted ones with `applyCuts(project, assetId, cuts)`.
- `beats` (free; music or any video/audio, ≤ 10 min) → `{bpm, beats: number[], strong: number[] /* source s */, durationSec}`: beat marks for the music track (ffmpeg decode + onset/tempo analysis on the server; nothing encoded). The tempo is checked against half, double and 3:2 readings: if the points between the grid's beats are onsets too, the faster tempo wins, up to 180 bpm (`test/beats.test.ts`: click tracks at 60–180 bpm, off-beats, music).
- `matte` (video ≤ 120 s) → `MatteResult`, priced per second of video (workstream 1, 2026-11-08: fix 1 and option 2, approved by the owner):
  - **Coming soon while production runs the mock** (WS3, 2026-11-08): `GET /v1/editor/features` → `matte.available: false`, and matte estimates/jobs answer `400` "Background removal is coming soon". The mock's matte is all white (the clip unchanged), never the source. Dev and tests keep it available.
  - **The result is an alpha matte**: a grey video the same length as the source, white = keep. It is not a green composite, so green clothes and hair edges survive.
  - The app keeps the original clip and sets `alphaMatte: {asset}` on it, with the matte asset added to the project. A finished job in an edit session does this itself; `chroma` is removed.
  - Old clips with `chroma` keep working.
  - **`options.points: KeepPoint[]`** (1–10, at least one `keep`) is **tap to keep**. The owner taps what to keep (a pet, a product, one of two people) on one or more frames, and taps `keep: false` on what to leave out. That subject is tracked through the clip and comes back as the same kind of matte (`mode: "tracked"`).
  - Tap to keep has its own price: GPU 15 + 3·d seconds. Estimate it with the same `options`. It runs as an ordinary paid job: estimate → hold → settle at the billed time, or release on failure or cancel.
  - Points are checked (0–1, `t` inside the clip) before anything is held.
  - Owner views list the model; member views never name it.

**`VideoClip.alphaMatte {asset, invert?}`** (project model v2, workstream 1):
- `asset` is a video asset of the project, aligned with the clip's own asset (the same source times).
- Its luma is the clip's alpha: white = opaque. With `invert`, black is opaque.
- It is applied before the clip's look, mask and transform. Validation: the asset must exist and be a video.
- Apps render it: Mac (AVFoundation/Core Image `blendWithMask`, or a Metal pass) and Android (a luma-to-alpha shader on the matte's frame at the same time).
- An app that doesn't know the field shows the clip unmatted.
- `denoise` `{analyzeOnly?}`: `analyzeOnly: true` is free and needs a transcript → `{suggestion}` from how clearly the words were heard. Otherwise → the voice alone (music and noise removed) as an audio asset + the suggestion; the app sets it as the clip's `audioAsset`.
- **Estimates** (workstream 1, 2026-11-08):
  - The formula is GPU seconds × the GPU's $/s × `EDITOR_MARKUP` (2: the owner's choice, like Upscale), at least $0.01. Jobs settle the same way at the GPU seconds the provider billed.
  - GPU seconds: captions 8 + 0.15·d, matte 10 + 4·d, tap to keep 15 + 3·d, voice 5 + 0.3·d (d = media seconds).
  - The rates are checked on each model's page: captions $0.0014 (A100 80 GB), matte and tap to keep $0.000975 (L40S), voice $0.00115 (A100 40 GB).
- **The owner's controls:**
  - With paid helpers switched off (`PATCH /v1/editor/settings {paidHelpers: "off"}`), a new paid job gets `503 editor_paid_off`.
  - Past the day's cap (UTC, counting done jobs' charges plus running jobs' estimates), it gets `402 editor_daily_cap` ("Today's AI editing limit ($5.00) is reached · …").
  - Both apply to Claude's helpers too. Free work (reused transcripts, silence cuts, beats, the voice check) is never blocked.
- **Pinned versions:** each default model runs a pinned version (its latest on 2026-11-08), so a new upstream version can't change the output or the price. `EDITOR_*_VERSION` overrides one, and a newer upstream version is only logged. Jobs on the server run 2 at a time (others wait in `phase: "Waiting"`); after a restart running jobs end `failed` ("Interrupted · try again") and their holds go back.
- **Events:** `{type: "editor", editorJob: EditorJob}` to the job's user and the owners; `{type: "editor", op: "delete", id}` when one is removed.
- **Server config** (env, optional): `EDITOR_AI_PROVIDER` = `mock` (the default, production included, until the owner turns the helpers on; in production the mock is free: no hold, no charge) | `auto` (Replicate when `REPLICATE_API_TOKEN` is set, else the mock) | `replicate`; `EDITOR_TRANSCRIBE_MODEL`, `EDITOR_MATTE_MODEL`, `EDITOR_SEPARATE_MODEL` (defaults: a WhisperX transcription model, a robust video matting model with alpha-mask output, a stem separation model); `EDITOR_TRACK_MODEL` (default: a SAM 2 video segmentation model, for tap to keep); `EDITOR_*_VERSION` (pins; see above); `EDITOR_MARKUP` (2); `EDITOR_CAP_PER_DAY_USD` (5). Migration **0019** adds `studio_settings.editor_paid_off` and `editor_cap_per_day`; `EDITOR_*_USD_PER_SEC`. Inputs are renamed to the model's own field names from its published schema. Outputs are copied into storage byte for byte (`g/edit_*.mp4|mp3`) and recorded as studio uploads.

**Looks (filters, 2026-11-05)** — spec `plans/video-editor.md` "Looks". A `look` (LUT + curves + texture effects) on video/image items; asset kind `"lut"` for imported .cube files.

| | |
|---|---|
| `GET /v1/editor/looks` | → `{version: 1, cubeSize: 17, looks: {id, name, category: "natural"|"film"|"moody"|"warm"|"cool"|"bw"|"vintage"|"cinematic", file, look: Look}[]}` — the 32 bundled looks (the apps also ship them). |
| `GET /v1/editor/looks/{id}.cube` | → the baked 17³ .cube (text). |
| `POST /v1/editor/uploads/presign` `{purpose: "lut", contentType: "text/plain"|"application/octet-stream"|"application/x-cube", bytes? ≤ 12 MB}` | → the presigned PUT for a .cube. |
| `POST /v1/editor/luts/validate` `{uploadId}` | → `{uploadId, size, title}` once the PUT arrived; `bad_request` `.cube: line N: …` for an unusable file (1D, size outside 2–64, wrong count, bad numbers). Projects using it as an asset `{kind: "lut", upload}` are checked the same way when saved/validated. |
| `POST /v1/shoots` `{…, filter?: Look}` | The look is applied to every still on the server (bundled looks only: `lut: "pack:<id>"`); with a template it replaces the template's own look. `bad_request` `filter.<field>: …`. |
| Templates `layers.afterEffects.look?: Look` | Kept with the template and applied to its stills after the grade (bundled looks only). |

**Edit sessions (2026-11-06, Claude in the Edit suite)** — spec `plans/claude-editing.md` A, `plans/video-editor.md` "Edit sessions and edit ops". Owner only (`403 owner_only` for members). Migration 0012.

```ts
EditSession { id /* es_… */, takeId, baseVersionId?, revision, project: EditProject, durationSec, status: "open"|"closed", updatedBy /* "app:<device>"|"claude" */, updatedAt,
              pending: Pending[], online: {device, label, platform: "android"|"mac"|"other", canRender}[], requests: AppRequest[], history?: HistoryEntry[] /* newest first, ≤ 60 */ }
HistoryEntry { id, revision, author, byClaude, kind: "edit"|"undo"|"tool"|"reset", label, undoes?, undone, createdAt }
Pending      { id, kind: "captions"|"cuts"|"matte"|"denoise"|"beats", label, estimateUsd, status: "waiting"|"approved"|"declined"|"running"|"done"|"failed", jobId?, createdAt }
AppRequest   { id, kind: "save"|"export", name?, preset?, device, status: "sent"|"done"|"failed", versionId?, error?, at }
PatchOp      { op: "add"|"remove"|"replace", path /* JSON Pointer */, value? }
```
| | |
|---|---|
| `POST /v1/edit-sessions` `{takeId, project?, baseVersionId?, device?, fresh?}` | → `EditSession`: the take's open session, or a new one (from `project`, else the take's saved edit list, else untouched; a graded suite take starts with its look). |
| `GET /v1/edit-sessions?takeId=` · `GET /v1/edit-sessions/{id}` · `GET …/{id}/history?limit=` | Sessions, one session (with history), the history. |
| `POST …/{id}/patch` `{baseRevision, patch: PatchOp[], label, device}` | → `{revision, entry}`. `409 stale_revision` when the session moved on; `bad_request` with the field when the result breaks a rule. |
| `POST …/{id}/reset` `{baseRevision, project, device, label?}` | Replaces the whole project (undoable). |
| `POST …/{id}/undo` `{entryId, device}` | Applies that change's inverse as a new change; `409 already_undone` / `cannot_undo` (later changes touch the same parts). |
| `POST …/{id}/presence` `{device, label, platform, canRender}` (every 30 s) · `DELETE …/{id}/presence/{device}` | Which apps have the edit open (Claude's frames and save/export go to one of them, the Mac first). |
| `POST …/{id}/frames/{requestId}` `{uploadId}` | The app's answer to a `frame_request` (a PNG uploaded with the image presign). |
| `POST …/{id}/requests/{requestId}` `{status: "done"|"failed", versionId?, error?}` | The app's answer to an `app_request`. |
| `POST …/{id}/pending/{pendingId}` `{approve: boolean}` | The owner's answer to a paid helper Claude asked for (yes starts the job, holding the cost as usual). |
| `GET …/{id}/frame?t=&width=` | The approximate server frame (PNG) Claude sees when no app renders. |
| `POST …/{id}/close` | Closes it (the next open starts a new one). |

Events: `{type: "edit", sessionId, op: "patch", revision, baseRevision, patch, entry}` · `{op: "log", entry}` (Claude looked at something) · `{op: "pending", pending}` · `{op: "frame_request", requestId, t, width, revision, device}` · `{op: "app_request", request}` · `{op: "closed"}` — owners only.

## Types

```ts
ImageRef   { asset?: string, url?: string }          // asset = bundled sample key ("g_front"); url = loadable image (relative "/uploads/x" is resolved against the base)
User       { id, studioName, email }
SheetSlot  { key: "face"|"profile"|"front"|"tq"|"side"|"back"|"faceTq" /* 2026-11-04 */, image: ImageRef|null, source: "upload"|"generated", busy: boolean }
Model      { id, name, age (18–70), niche, look, neverAdd: string[], slots: SheetSlot[7] /* 6 before 2026-11-04, see "Model tools" §1 */, outfitIds: string[],
             archived?: boolean, archivedAt?: number /* "Model tools" §7 */,
             identityBodySlot: "front"|"tq"|"side"|"back" /* 2026-11-05: the one body image her photos send, default "front" */ }
           // locked = all 6 slots filled. Missing face close-ups are only a warning, and saving is always allowed.
Outfit     { id, modelId, name, mode: "describe"|"photo"|"own"|"dressup", description, angles: (ImageRef|null)[4] /* front, ¾, side, back */,
             faces?: (ImageRef|null)[3] /* dressup: face, face ¾, profile */,
             state: "generating"|"preview"|"ready", prompt }
ClipMeta   { name, durationSec, width, height, fps, people?, watermark?, talking? }
ClipCheck  { label, value, status: "good"|"bad"|"info", fix? }
Clip       { id, name, durationSec, width, height, fps, checks: ClipCheck[], thumb?: ImageRef }
JobRequest { title, modelId, outfitId, clipId, engine: "replicate"|"h3"|"viggle" /* default: features.video.defaultEngine */,
             quality?: "draft"|"standard"|"hd" /* engine "replicate" only; default "draft" (features.video.defaultQuality) */,
             steps (4–30, default 10; h3 only), use: "first"|"full" /* h3/viggle; replicate always renders the whole clip and stores "full" */,
             takes (1–4), keepAudio, lipSync /* h3 only */, background: "keep"|"photo" /* "photo" is h3 only */, backgroundMotion: "still"|"subtle"|"busy", clipSeconds?,
             queue?: boolean /* true = park it as "queued", not charged, until POST /v1/queue/run */ }
             // Clients should always send `engine`. The picker maps to it: Draft/Standard/HD = {engine:"replicate", quality},
             // Edit = {engine:"h3", use:"full", steps:10}, Fast · beta = {engine:"viggle", use:"full"}. See "App clean-up" §2.
Job        { id, title, modelId, modelName, outfitId, request: JobRequest, state: "queued"|"running"|"done"|"failed",
             progress (0–100), take, step, totalSteps, phase /* "step 12/20 · ~6 min left" */, secondsLeft, totalSeconds,
             cost, refunded, error?, createdAt, finishedAt?, prompt /* exact H3 prompt */, seed, thumb: ImageRef,
             queuePosition?, etaSeconds? /* while waiting in line */, blocked? /* never set since 2026-11-04 */, warmupCost? /* owner ledger only; never shown to members */,
             engineLabel /* "Draft · 768P", "Standard · 768P", "HD · 2K", "Edit", "Fast · beta" */,
             errorCode?: "provider_refused"|"provider_failed"|"provider_rate_limited"|"provider_timeout"|"provider_out_of_credit",
             billedSeconds? /* replicate, done: output seconds Replicate billed, summed over takes */ }
Take       { id, kind: "take"|"shot"|"edit" /* edit: 2026-11-05, "Video editor" */, jobId|null, index, of, title, label, engineLabel, cost, seed, status: "test"|"final", thumb, prompt, createdAt,
             videoUrl?, durationSec?, width?, height? /* real output: Exact edit renders are 768×1344; Replicate 768P/2K sizes come from the file */ }
             // Takes: label = "Standard"|"Draft"|"HD" (replicate), "Edit" (h3), "Fast · beta"; engineLabel = Job.engineLabel.
             // A replicate take's durationSec is the source clip's exact length (see "Video engines"), and its thumb is a frame of the take.
             // Shots: engineLabel = "" (2026-11-04: the engine is never shown on a photo); cost = that photo's exact cost.
Balance    { balance, month, today /* spent since local midnight */, perJobLimit, perDayLimit, videos,
             tokens, tokenUsd, role: "owner"|"member", heldUsd, perUserDayLimit, balanceSource: "studio"|"wallet",
             availableToSend?, studioBalance?, needsFirstTopUp? /* owner only */ }
             // Member: balance = their wallet in USD; today/month = their own spend. Owner: balance = StudioBalance.availableUsd
             // (top-ups − spending − members' unspent credit − holds; may be negative); today/month = the studio's spend.
Wallet     { userId, role, tokens, usd, heldTokens, heldUsd, todayUsd, monthUsd, tokenUsd, balanceSource, availableToSend?, studioBalance?, membersUnspentUsd? }
Member     { id, email, role, tokens, usd, heldTokens, todayUsd, monthUsd, lastActiveAt?, disabled, capPerJob, capPerDay, createdAt }
Lora       { modelId, version /* 0 = never trained; the last ready version */, state: "none"|"building"|"review"|"training"|"ready"|"failed",
             use: boolean /* default true */,
             candidates: { id, image: ImageRef, label, flag?: "tattoo"|"ring"|"choker"|"face drift", keep: boolean /* false when flagged */ }[],
             progress (0–100, overall), photo: { state: "none"|"training"|"ready", progress }, video: { state: "none"|"waiting"|"training"|"ready", progress },
             cost /* spent so far */, trainedOn? /* shots kept for the last version */ }
             // The LoRA is applied when version ≥ 1 and use is true, also while a retrain is in review/training.
             // Token: first name, lower case, plus the version: "demo_v2".
Platform   "tiktok"|"instagram"|"facebook"|"youtube"|"x"
Account    { modelId, platform: Platform, handle, connectedAt, canPostDirect: boolean /* false until that platform approves MUSE */ }
Post       { id, modelId, takeId, title, thumb: ImageRef, platforms: Platform[], caption, aiLabel: boolean, paidPartnership: boolean,
             when: "now"|ISO time, state: "scheduled"|"handoff"|"posted"|"failed", createdAt, postedAt?, stats?: { views, likes, comments } }
ApiEvent   { type: "job"|"take"|"balance"|"wallet"|"model"|"outfit"|"lora"|"post"|"gpu"|"tool"|"template"|"clip"|"settings"|"member"|"invite"|"studio"|"account"|"prompts"|"editor" /* "Editor v2" */|"edit" /* "Edit sessions" */,
             prompt?: PromptEntry /* "prompts", owners only (2026-11-05) */,
             op?: "delete"|"used" /* with id: remove that item */, id?, take?: Take, template?: Template, clip?: Clip, settings?: StudioSettings,
             imageEngine? /* owners */, imageModels? /* owners */, member?: Member /* owners */, invite? /* owners */, studioBalance?: StudioBalance /* owners */,
             account?: Account, modelId?, platform?,
             job?, tool?: ToolRun, balance?, model?, outfit?, lora?, post?, takes?: Take[],
             wallet?: Wallet, notice?: { code: "provider_out_of_credit", engine?: "replicate"|"runpod", message } /* owners only */,
             gpu?: WarmGpu, event?: "state"|"tick"|"warning" /* gpu events only */, warning?: WarmWarning }
             // balance, wallet and gpu events go only to the user they concern (balance/wallet also to owners, whose pool moved too).
WarmGpu    { state: "off"|"starting"|"warm"|"stopping",          // starting = the pod is booting (3–6 min); warm = ready, renders start at once
             startedAt: number|null, readyAt: number|null,          // epoch ms; null when off
             minutes: number /* whole minutes since startedAt */, costUsd: number /* "Warm GPU" charged so far, settled per minute */,
             ratePerHour: number /* the pod's $/h, ~3.99 */, busy: boolean /* a render is running on it */,
             autoOffAt: number|null /* the earliest idle or cap auto-off; null when off */, autoOffReason?: "idle"|"cap",
             warningAt?: number /* autoOffAt − 5 min: when the warning fires */,
             idleMinutes: number /* warmIdleMinutes */, maxMinutes: number /* the cap, including an extension */, canExtend: boolean,
             allowed: boolean /* true for the owner (members get 403 owner_only from /v1/gpu/warm) */,
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
// Take (photoshoot stills) also carries: templateId?, templateName?, shuffleSeed?, variation?: VariationDraw (template owner only),
//   refs?: ShootRef[] (2026-11-05, the reference images it was shot with).
// For anyone but the template's owner a template shot's `prompt` is the public version: "Template: <name>" plus their own layers.
```

## Pricing (the same in every client and the server)

### Replicate (Draft / Standard / HD), the default engine; Draft is the default quality
Billed per **output second**. `D` is the whole clip rounded **up** to whole seconds, between 4 and 15 (the output can't be fractional; see "Video engines" for how the take still keeps the exact clip length).

| quality | label | detail | `pricePerSec` (default) |
|---|---|---|---|
| `draft` | Draft (default) | 768P · lite | $0.02 |
| `standard` | Standard | 768P | $0.08 |
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
- Photo prices: _retired fixed prices ($0.12 / $0.08 / $0.02 / $0.60)._ Photos hold an estimate and settle to the exact engine cost, see "App clean-up" §3 and `photo_pricing_fixture.json`.
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
| `POST /v1/takes/{id}/versions`, `GET /v1/takes/{id}/versions` | Edited versions (on-device video editor), see "Video editor: edited versions of a take". |
| `POST /v1/shoots` `ShootRequest` | → `Take[]` (`kind: "shot"`). _2026-11-05: the server builds the prompt from the choices and the prompt library; `prompt` only for "Edit as text"; `refs` = up to 3 reference images. See "Shoot references and the prompt library"._ Holds the estimate, settles exactly. |
| `POST /v1/shoots/preview` `ShootRequest` | → `ShootPreview`: the final prompt, the images that will be sent and the price. Free. |
| `POST /v1/shoots` with a template `{modelId, outfitId?, templateId, direction?, shuffleSeed?, lockSeed?, productImage?: ImageRef, refs?: ShootRef[], count?}` | → `Take[]`, $0.12 as above. `scene`, `prompt` and `seed` are ignored: the server builds every still's prompt from the template layers + the model's identity, outfit and never-add + the draws (or `direction`) + a seed. See Templates below. |

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
| `POST /v1/models/{id}/accounts/{platform}/connect` | → `ConnectResponse`. The real backend returns `{ authUrl }` (OAuth). The mock signs in after a short delay (≤ 0.9 s) and returns `{ account }`. Handles come from the model's name (`@demo.model`, `Demo model` on YouTube, `Demo model (Page)` on Facebook). |
| `DELETE /v1/models/{id}/accounts/{platform}` | 204 |
| `GET /v1/posts?state=&modelId=` | → `Post[]`, newest first. Both filters are optional. |
| `POST /v1/posts` `{modelId, takeId, platforms, caption, aiLabel, paidPartnership, when}` | → `Post`. `aiLabel` and `paidPartnership` default to false and are only ever set by the user. Only a JSON `true` turns a label on. Every platform must be connected for that model (`bad_request`). Stage 1: `when: "now"` returns `handoff` (the client opens each app); a scheduled post stays `scheduled` and turns `handoff` at its time (the client also sets a local notification). The mock then marks a handed-off post `posted` with stats after a moment (`post` event), standing in for the stats read-back. |
| `DELETE /v1/posts/{id}` | 204 (cancels a scheduled post) |

### Gaps found while building the Mac app
| | |
|---|---|
| `POST /v1/queue/run` | → `Job[]` it started. Starts `queued` jobs oldest first, charging each as it starts. Stops at the first one the balance can't cover (those stay queued); `insufficient_balance` if none could start. Jobs are queued with `JobRequest.queue: true`. |
| `PATCH /v1/models/{id}` `{name?, niche?, personality?, notes?, neverAdd?, identityBodySlot?}` | → `Model`, plus a `model` event. Only the fields sent change. An empty name is `bad_request`. `identityBodySlot` (owner or her creator): see "Identity images, safety tolerance and reference sheets" §2. |
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
| `POST /v1/balance/topup` `{amount, note?}` (owner) | → `Balance`. Records a studio top-up (alias of `POST /v1/studio/topups`, "App clean-up" §4). Members get `owner_only`. |
| `GET /v1/studio/balance`, `POST /v1/studio/topups`, `GET /v1/studio/topups` (owner) | the studio balance and its top-ups, see "App clean-up" §4 |
| `GET /v1/wallet` | → `Wallet` (mine) |
| `GET /v1/members` (owner) | → `Member[]` |
| `PATCH /v1/members/{id}` `{capPerJob?, capPerDay?, disabled?}` (owner) | → `Member`. `null` caps go back to the studio default. Disabling signs them out. |
| `POST /v1/wallets/transfer` `{toUserId, tokens, note?}` (owner) | → `{wallet, member}`. `over_allocation` beyond the studio balance's `availableUsd`. |
| `POST /v1/wallets/reclaim` `{fromUserId, tokens, note?}` (owner) | → `{wallet, member}`. Only unused tokens (not ones held by running jobs). |
| `GET /v1/ledger?userId=&limit=` (owner) | → ledger rows, newest first |

### Settings (real API)
| | |
|---|---|
| `GET /v1/settings/image-engine` | → `{provider: "simulated"\|"fal"\|"custom-http"\|"replicate", model, editModel? /* replicate */, label, url?, available: {simulated, fal, "custom-http", replicate}}`. `label` is for display: "FLUX.2 [pro] · Replicate", "Simulated", the fal model id, "Custom". Default provider: `replicate` when the server has `REPLICATE_API_TOKEN`, else `IMAGE_PROVIDER` (simulated). A studio that saved a provider keeps it. |
| `PATCH /v1/settings/image-engine` `{provider, model?, url?}` (owner only since 2026-11-04) | → same. Per studio. `custom-http` is owner-only and needs an https URL; `replicate` needs the server's token (`bad_request` otherwise). Shoots and outfit sets also take `imageEngine: {provider, model?}` to override it for one call. |
| `GET /v1/settings/studio` | _2026-11-04: members get only `{capPerJob, capPerDay, capPerUserDay, tokenUsd, features}`; the owner also gets `engines`, and `minRunpodBalance`, `lowBalance`, `warmGpuAllowed` are gone ("App clean-up" §5)._ Before: → `{maxGpus, overheadPayer: "user"\|"owner", capPerJob, capPerDay, capPerUserDay, tokenUsd, minRunpodBalance, lowBalance, warmGpuAllowed: "owner"\|"everyone", warmIdleMinutes, warmMaxMinutes, features: {standard, fastBeta, lipSync, loraTraining, replaceAudio: false, outputSize: {width: 768, height: 1344}, maxClipSec, replicate, video: VideoFeatures}, gpu}`. `features.standard` still means "Exact edit (h3) can run"; `features.replicate` = the Replicate engine is set up. |
| `PATCH /v1/settings/studio` `{maxGpus?, overheadPayer?, capPerJob?, capPerDay?, capPerUserDay?, warmGpuAllowed?, warmIdleMinutes? (5–120), warmMaxMinutes? (30–480), identityRefs? (1–7, 2026-11-05)}` (owner) | → same |

"Replace audio" isn't wired on the GPU yet: `keepAudio: false` gives a silent take, and `features.replaceAudio` is false.

### Video engines and quality (Replicate)
_Added 2026-11-04._ MiniMax H3 hosted on Replicate is the **default** video engine. Our own RunPod H3 stays as **Exact edit** (frame-by-frame, slower, needs a GPU start-up), Viggle stays **Fast · beta**.

_2026-11-04: superseded by "App clean-up" §2: `options` = draft, standard, hd; Edit / Fast · beta / Upscale are `addons`; the detail lines and labels there are the ones to show._

**The picker** (video studio, Quality tool), in this order, default **Draft** (changed from Standard on 2026-11-04 at the owner's request):

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
                defaultQuality: "draft"|"standard"|"hd", // "draft" (VIDEO_QUALITY_DEFAULT); apps preselect it
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

**Photos on Replicate:** with provider `replicate`, new shots (photoshoots, template shoots, outfit set fronts, character-sheet fills) use FLUX.2 [pro] with the model's reference shots (≤ 6, face first) and the outfit/product photos; the other three outfit angles are edits of the generated front with Qwen-Image-Edit 2511. Users pay exactly what these cost (estimate held, exact settle: "App clean-up" §3). Template after-effects still run on our side.

### Keep GPU warm (`plans/backend.md` "Keep GPU warm")
_2026-11-04: now **"Keep add-on engine ready", owner-only** ("App clean-up" §6). Members get `403 owner_only`; the nudge, video-studio switch, bar, notification and warnings below are gone for members; the owner has the switch in Settings → Engines. `warmGpuAllowed` and the RunPod-balance auto-off are gone._

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
`GET /v1/events` is a `text/event-stream`. Each message is `data: <ApiEvent JSON>`. While a job runs, `job` events arrive about every 250 ms (`progress`, `step`, `phase`, `secondsLeft`). `lora` events carry training progress (about every 250 ms) and the `building` → `review` change. `post` events carry `handoff`/`posted` changes. When the job finishes, a `job` event arrives with `state: "done"` and its new `takes`, or with `state: "failed"`, `error` and `refunded`. Each failure is followed by a `balance` event. Clients reconnect with backoff.

_Added 2026-11-05 (every change is live, so a phone and a Mac on one studio stay in step within a second or two):_

| Event | When | Who gets it |
|---|---|---|
| `take` `{take}` / `{op: "delete", id}` | Photoshoot and template-shoot stills, video takes when a job finishes, a new edited version (`POST /v1/takes/{id}/versions`) and its server-made thumbnail, `PATCH /v1/takes/{id}`, `DELETE /v1/takes/{id}` | Everyone in the studio, each with the prompt *they* may see (a template's hidden layers only to its owner) |
| `job` `{op: "delete", id}` | `DELETE /v1/jobs/{id}` | Everyone |
| `model` `{model}` / `{op: "delete", id}` | Create, edit, sheet slot, fill-angles start and finish, archive/unarchive (`archived: true` → drop from lists), tool apply, version restore, delete (drop her outfits too) | Everyone |
| `outfit` `{outfit}` | Create (`generating`), the set (`preview`), save (`ready`), Dress up apply | Everyone |
| `tool` `{tool}` | Start, progress, review decisions, retry, apply, discard | Everyone; `models` (which image models ran) only to owners |
| `template` `{template}` / `{op: "delete", id}` | Create, edit, duplicate, delete, use count after a shoot | Everyone who can see it, each in their own view (layers and pool only to its maker); someone who can't see it (private, or just made private) gets a delete. A favourite only to that user. |
| `clip` `{clip}` | Clip upload or presigned confirm | Everyone |
| `lora` | Also candidate keep/unkeep and the `building` start | Everyone |
| `post` `{op: "delete", id}`, `account` `{modelId, account}` / `{op: "delete", modelId, platform}` | Post created/removed, account connected/disconnected | Everyone |
| `balance`, `wallet` | After every hold, settle, release, charge, refund, GPU line, transfer, reclaim, top-up, cap change | The user concerned (all their devices), and `balance` to every owner |
| `studio` `{studioBalance}` | Whenever the studio's money moves (top-up, any spend, transfer) | Owners only |
| `member` `{member}` | A member's wallet moved, `PATCH /v1/members/{id}`, someone joined | Owners only |
| `invite` `{invite}` / `{op: "used", id}` | Invite created / used | Owners only |
| `settings` `{settings}` | `PATCH /v1/settings/studio` | Everyone, in their role's view (members never get `engines`, GPU settings or tool models) |
| `settings` `{imageEngine}` / `{imageModels}` | Image engine or image model changes | Owners only |
| `prompts` `{prompt}` | `PUT` / `DELETE /v1/prompts/{key}` (2026-11-05) | Owners only |

Catch-up: events are not replayed. When the stream (re)connects, and when the app comes back to the foreground, the apps refetch takes, jobs, models, outfits, balance and templates, so nothing missed while offline is lost. The stream sends `retry: 3000` and a comment every 10 s; headers `Cache-Control: no-cache, no-store, no-transform` and `X-Accel-Buffering: no` keep proxies (Railway) from buffering it. The Android app turns finished and failed jobs into local notifications. A real backend can add FCM push behind the same events.

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

## AI suite (workstream 1, 2026-11-05)
_Spec: `plans/ai-suite.md`. Backend only; the UI waits for the owner's Figma review. Members never see providers, models or GPUs. Owner-only fields are marked (owner)._

**Modes.** `SUITE_MODE` is `off` (the production default), `mock` (the default elsewhere: the real plan and price, a test-pattern render, settles $0) or `live`. `catalog.enabled` and `catalog.test` show the mode to the apps.

### Types
```ts
ImageRef  { asset?, url? }                       // as everywhere
VideoRef  { key?: string /* our upload's storage key */, url?: string /* /uploads/... or https */, seconds?: number }
CameraSpec {
  mode?: "preset"|"directed" /* default preset; directed needs a guide-capable model */,
  preset?: "phone_ugc"|"talking_head"|"selfie_vlog"|"creator_studio"|"cinematic"|"product_hero"|"music_video"|"documentary"|"noir"|"fashion_editorial"|"y2k_camcorder",
  rig?: { body?, lens?, focalMm? /* 8–200 */, aperture?, look?, fps?: "24"|"25"|"30"|"48"|"60"|"slowmo", shutter?: "normal"|"low"|"narrow" },
  lighting?: { preset?, direction?: "front"|"left"|"right"|"back"|"top"|"below", temperatureK? /* 1800–12000 */, intensity?: "low"|"normal"|"high" },
  palette?: { preset?, colors?: string[] /* ≤ 5 "#rrggbb" */ },
  move?: Move, mix?: Move /* a second, compatible move */,
  angle?: { height?, shotSize?, dutchDeg? /* 0–30 */ },
  style?: { genre?, era?, tempo? },
  performance?: { emotion, to?, atS?, intensity? /* 0–1 */ },
  guide?: { video: VideoRef, use?: "camera"|"motion"|"blocking" /* blocking = camera + framing + blocking (full playblast) */, cameraSessionId?, keyframes?: { start?: url, middle?: url[] /* ≤ 8 */, end?: url /* "/uploads/<storage key>" (signed at run time, never expires) or https */ } }
}
CastMember { characterId, outfitId?, personIndex? /* 1–4: order of appearance, or left to right */,
  personHint?: "left"|"center"|"right"|"foreground"|"background"|"first"|"second"|"third"|"fourth", personNote? /* ≤ 80: "the woman in the red coat" */,
  faceCrop?: ImageRef /* who to replace, where the model takes one */, speaking?: boolean /* unset: one person → the clip's talking flag/detection; several → unknown (the mouth follows the clip) */ }
Move { id, intensity? /* 0–1, default 0.5 */, speed?: "slow"|"normal"|"fast", ease?: "linear"|"in"|"out"|"in_out", startS?, endS? }
// The ids of every option are in GET /v1/suite/camera. Unknown ids are bad_request.
ShotRequest {
  mode?: "text"|"image"|"reference"|"swap"|"recast" /* default: image with frames, reference with a character, else text */,
  cast?: CastMember[] /* recast: 1–4 people of the source clip (clipId) → studio characters */,
  title?, modelId? /* the character */, outfitId?, prompt /* ≤ 2000 */, direction?,
  frames?: { start?: ImageRef, middle?: ImageRef[] /* ≤ 8 */, end?: ImageRef },
  references?: { images?: { image: ImageRef, role?: "product"|"location"|"style"|"prop"|"person", label? }[] /* ≤ 6 */,
                 videos?: { video: VideoRef, use?: "camera"|"motion"|"style" }[] /* ≤ 3 */,
                 audio?: { audio: VideoRef } /* one track; speaking: sent as is; not speaking: only its instrumental (vocals removed, billed with the job; must be an upload) */ },
  duration? /* 2–30, default 5 */, aspectRatio?: "9:16"|"16:9"|"1:1"|"4:3"|"3:4"|"21:9" /* default 9:16 */,
  quality?: "draft"|"standard"|"hd"|"cinema" /* default draft */, takes? /* 1–4 */, audio? /* native sound, default true */,
  speaking? /* she speaks or sings on camera. Unset: the audio reference's talking flag (a clip upload), else its detection, else no.
               Off: the prompt says she "does not speak, sing or mouth words" (or moves to the beat of the instrumental); on: lip-sync to the audio, or "speaks the lines in quotes" with no audio sent */, seed?,
  camera?: CameraSpec, dryRun?: boolean,
  clipId?, keepAudio? /* swap */, engineModel?, resolution? /* (owner) bypass the ladder */
}
ShotEstimate { quality, label /* "Shot · HD · 2K" */, resolution, seconds /* what will render */, takes, mode, estimate, priceLine /* "about $0.78 · 6 s" */,
  buttonLabel /* "Generate · 6 s · $0.78" */, ok, code, message, caps: { perJob, perDay, spentToday, leftToday, ok, code, message },
  warnings: string[] /* e.g. "length set to 6 s", "one camera move per shot: … dropped", "the guide clip is not sent" */,
  rig: RigWarning[] /* the rig check (workstream 3): empty when nothing clashes; never changes ok */,
  camera: { moves: string[], guideUsed: boolean }, prompt, test, speaking: { speaking: boolean, source: "switch"|"upload"|"detected"|"default" },
  cast?: { characterId, outfitId?, who /* "the person on the left" */, speaking: "yes"|"no"|"unknown" }[], keepAudio? /* recast */,
  engine?, input?, tried? /* (owner): model, provider, ref, $/s, billed seconds, licence and notice; the inputs; the ladder steps tried */ }
// Rig check (workstream 3, plans/video-composer.md "Rig check"). A fix is a JSON Merge Patch (RFC 7386) over the ShotRequest:
// objects merge, a value replaces, null removes (only `camera.mix` is ever removed). Today every patch is under `camera`.
// Photo tool (workstream 3). Strict: unknown fields are refused.
PhotoRequest { modelId, outfitId?, prompt? /* the scene and what she does; #move tokens are ignored */, camera?: CameraSpec /* move, mix, tempo, fps, shutter ignored */,
  gradeLook? /* default true */, count? /* 1–4, default 4 */, presetId? /* a photo template */, productImage?: ImageRef, references?: { image: ImageRef, guides: ("pose"|"look"|"scene")[] }[] /* ≤ 3 */,
  seed?, lockSeed?, shuffleSeed?, title? }
PhotoEstimate { tool: "photo", count, perPhoto, estimate, priceLine /* "about $0.24 · 4 photos" */, buttonLabel /* "Generate · 4 photos · $0.24" */, ok: true,
  warnings: string[] /* "Movement doesn’t apply to photos", "The preset sets its own camera and light" */, rig: RigWarning[] /* the still rules only: deep_focus, wide_close, worm_close, look_clash, prompt_angle, prompt_size */,
  look: { id, kind, label, lut } | null, prompt? /* the still's prompt; absent with a preset */, preset?: { id, name } }
RigWarning { id: "deep_focus"|"wide_close"|"worm_close"|"look_clash"|"prompt_move"|"prompt_angle"|"prompt_size"|"no_reveal"|"talk_move",
  severity: "warn" /* won't come out as chosen */ | "tip" /* a taste clash */, reason /* one line, e.g. "DV camcorder keeps everything in focus, so the rack focus won’t show" */,
  fix: { label /* "Use Cinema camera" */, patch }, alt?: { label /* "Drop the rack focus" */, patch } }
```

### Endpoints
| | |
|---|---|
| `GET /v1/suite/catalog` | → the catalog: <ul><li>`{enabled, test, defaultQuality: "draft"}`</li><li>`tiers[]`: `{id, label, detail, available, resolution, fromPerSec, minSeconds, maxSeconds, canKeyframes, canReferences, canGuide, inputs}` (`minSeconds`–`maxSeconds` = the range of the composer's Length slider), plus `models[]` (owner; each `{model, name, resolution, inputs}`)</li><li>`inputs` = the input slots the tier takes (any of its usable models), member-safe: `{start, end, middle, images, videos, audio, framesWithRefs}`. Booleans, plus counts capped to what a shot request can carry (middle ≤ 8, images ≤ 6, videos ≤ 3, one audio). The apps show a slot only when it is on or its count is above 0. When `framesWithRefs` is false, adding a start or end frame means references are not sent. Uploads: images via `/v1/uploads/images` (→ `frames.*` / `references.images[].image`); videos and audio via `/v1/editor/uploads/presign` (→ `{key}` in `references.videos[].video` / `references.audio.audio`)</li><li>`tools`: `[{id, available, comingSoon?}]` for the composer's tools: shot, swap, recast and storyboard; talking (needs a tier that takes audio) and ugc_ad (needs reference images), which are shots; extend (no engine yet, `comingSoon`). The apps show "Coming soon" for a tool that isn't available.</li><li>`modes`, `aspectRatios`, `takesMax: 4`</li><li>`camera`: the same as `GET /v1/suite/camera`</li></ul> |
| `GET /v1/suite/camera` | → the Camera picker: `{presets, bodies, lenses, focalLengths, apertures, looks, frameRates, shutters, lighting, palettes, moves, heights, shotSizes, genres, eras, tempos, emotions, limits}`. Each option is `{id, label, description}`; moves also have `category`, `editorBetter` and `talkSafe`. Presets carry their `spec`. _Phase 2 (camera bag):_ options with a photoreal hardware render also carry `render` (file name in the apps' bundled `hardware/` folder, from `design/hardware`), `name` and `caption` ("Alexa 35 look · Super 35 · 4.6K"); `optics` (aperture, shutter renders), `grips` (render per move: dolly, jib, gimbal, FPV, slider) and `library` (the 16 featured moves, UGC first, each with `tag`: ugc / cinematic / energy / subtle). New ids: bodies `modular_8k`, `full_frame_cine`, `creator_cine`; lens `cine_zoom`; look `reversal_16`.<br>_Composer (2026-11-06, plans/video-composer.md "Catalogue"):_<ul><li>Every rig, light, colour, angle and style option has `visible`. False means it is not offered to members; owners and Directed mode keep it. A true duplicate also has `mergedInto` (the survivor's id): it still validates and **compiles as the survivor**. Merges: `super35`, `modular_8k`, `full_frame_cine` → `cinema_digital` ("Cinema camera"); `creator_cine` → `vlog` ("Creator camera"); lens `vintage` → `warm_vintage`. Hidden but compiling as themselves: lens `cine_zoom`, apertures f/1.2, 2, 4 and 8, and all `frameRates` and `shutters`.</li><li>`focals`: `[{mm, label, description, visible}]`. Visible: 14, 24, 35, 50, 85, 135. `focalLengths` stays the full list.</li><li>Composer previews (design/previews, bundled in the apps as `previews/`): moves, lighting, heights and shotSizes carry `preview: {video?, poster, seconds?}`, paths relative to that folder. Moves have an H.264 loop and a poster; lighting and angles have a still. `autoPreviews.lighting` is the Auto tile. A move without one (`motion_blur`) falls back to the drawn still. `ugcFormats` (unboxing, review, try_on, before_after, grwm, haul, tutorial, testimonial; the UGC ad tool's Style wheel), sent as `camera.style.format` and compiled into the Style words. Tempo `slow_motion`; move `motion_blur` ("Motion blur streaks"). Each move has `group`, one of `moveGroups` (Featured, UGC, Push, Pan & tilt, Orbit, Crane, Follow, Aerial, Special; Featured = `library`).</li><li>`palettes[]` and `looks[]` (film stocks) carry `swatches` (5 hex colours, darkest first) and `lut`: `"pack:<id>"` (a look-pack twin) or `"palette:<id>"` (generated from the swatches, file `assets/lookpack/palettes/<id>.cube`, listed in `palettes.json`).</li></ul> |
| `GET /v1/suite/locations` · `POST /v1/suite/locations {name, image}` · `DELETE /v1/suite/locations/{id}` | The studio's locations (composer `@location`, migration 0013): `[{id, name, image: ImageRef, createdAt}]`, newest first. Any member adds one (name 1–60, image an upload or https, at most 200 per studio). The person who added it or the owner deletes it (`403 forbidden` otherwise). In a shot, a location is a reference image: `references.images[] {image, role: "location", label: name}`, and the prompt text says its name. |
| `GET /v1/suite/targets` | → per quality, what a guide clip (Blender render) should be: `{quality, label, available, minSeconds, maxSeconds, guideSeconds: {min, max}, aspectRatios, shortSide, fps: 24, keyframes: {start, middle /* max count */, end}}`, plus `model`, `name` and `resolution` (owner). Only models that take a reference video count. |
| `POST /v1/suite/camera/compile` `{camera, quality?, duration?, engineModel? (owner)}` | → `{text, moves, guideUsed, warnings}`, plus `engine`, `params` and `avoid` (owner). This is what the camera becomes on that quality's first model. Free. |
| `POST /v1/suite/shots/estimate` `ShotRequest` | → `ShotEstimate`. Holds nothing and runs nothing. <ul><li>`400 nothing_fits` ("Draft can't make this shot · try another quality, a shorter length or fewer references"), with `tried` (owner).</li><li>`400 engine_unavailable` when the suite is off.</li><li>`403 owner_only` for `engineModel`/`resolution` from a member.</li></ul> |
| `POST /v1/suite/rig-check` `ShotRequest` | → `{rig: RigWarning[]}`. The rig check alone: no character, engine or price needed, so the composer can still warn when the estimate fails. Swap and recast return `[]`. Free, pure, no provider call. The speaking switch counts only when it is set (the estimate also uses the uploaded audio's talking flag). |
| `POST /v1/suite/photos/estimate` `PhotoRequest` | → `PhotoEstimate`. The Photo tool (workstream 3): Photoshoot on the composer. It runs the shoot pipeline (references, prompt library, image engines) with the composer's rig compiled for a still (`suite/photo.ts`). Movement, tempo, frame rate and shutter are dropped, with a note in `warnings`. Count and price are the same as a shoot (`count × perPhoto`). It holds nothing. A preset (`presetId`, a photo template) carries its own camera and light, so the rig isn't added on top. |
| `POST /v1/suite/photos` `PhotoRequest` | → `{tool: "photo", takes: Take[]}`. Holds `count × perPhoto` on the wallet (ledger line "Photo · N photos"), generates, grades each still with the Look chip (`gradeLook`, on by default; an editable look), and saves the stills as takes (`kind: "shot"`, titled "Photo · …"). `/v1/shoots` stays as it was for older clients, and old shoots stay in the library. |
| `POST /v1/suite/shots` `ShotRequest` | → `Job`: a render job, `request.engine: "suite"`, `engineLabel: "Shot · Standard · 768p"`. <ul><li>The same live `job`/`take`/`balance` events, `DELETE /v1/jobs/{id}` cancels, and failures refund in full (`provider_failed`/`provider_refused`/`provider_timeout`/`provider_out_of_credit`).</li><li>Takes have `label` = the tier ("Draft"…). They are the provider's file **as delivered** (no trim).</li><li>`dryRun: true` → `{dryRun: true, estimate}` and nothing is held.</li><li>`402 suite_over_job_limit` / `suite_over_day_limit`, then the wallet's own cap and balance codes.</li><li>`mode: "swap"` is the existing character swap: `POST /v1/jobs` with `engine: "replicate"`, Cinema → HD.</li></ul> |
| `GET /v1/suite/shots/{id}` | → `{job, warnings}`, plus `engine` and `runs` (owner) |
| `GET /v1/suite/settings` (owner) | → <ul><li>`{mode, caps: {perJob, perDay}, spentToday}`</li><li>`ladder`, `defaultLadder`</li><li>`models[]`: the registry, each with `enabled`, `blocked`, `blockedReason`, `needsAck`, `configured` and `priceScale`</li><li>`providers: {replicate, fal, runpod}`</li></ul> |
| `PATCH /v1/suite/settings` (owner) `{models?: {[id]: {enabled?, acknowledge?, priceScale? /* 0.5–3 */}}, ladder?: {[tier]: {model, resolution}[]} \| null, capPerJob? \| null, capPerDay? \| null}` | → the same. `409 model_blocked` for a model whose licence blocks new features, or one that was removed. |

**Extend (composer, 2026-11-06; suite/extend.ts):** `POST /v1/suite/shots[/estimate]` with `mode: "extend"` and `extend: {video: VideoRef, direction: "after" | "before" (default after), join?: true}`, plus `duration` (the new part), `prompt` (what happens next or before), `quality` and `takes`.
- **Source:** a take (`{key: take's stored video}`), clip or upload of this studio. Its length comes from the take or clip; for an upload, send `video.seconds`.
- **Model:** the tier's extend ladder picks the first model that can continue the clip:
  - Wan 2.7 `first_clip`: a true continuation, after only; it takes the last 10 s of a longer source.
  - Seedance 2.5: the clip as `[Video1]`, after or before; about 4× price with video.
  - A frame bridge on Kling 4.0: after starts on the source's last frame; before ends on its first frame.
- **The take:** source + extension joined into one clip (after), or extension + source (before), unless `join: false`. The new part alone is kept as output `extension_<n>.mp4`.
- **Labels:** `Extend · <Tier> · <res>`. `catalog.tools` lists `extend` as available when a tier can extend.

**Look grading (composer):** shot requests take `gradeLook` (default true). The estimate and the job's `request` carry `look: {id, kind: "palette" | "stock", label, lut}` for the take: the chosen palette, else the film stock, presets included. It is null when nothing was chosen, for Recast, or when `gradeLook` is false. The Edit suite opens the take with that LUT applied as a reversible Look; `"palette:<id>"` LUTs come from `assets/lookpack/palettes/`.

**Ledger notes:**
- Hold: `"Video · Shot · Draft · 768p · 5 s · 2 takes · hold"`
- Settle: `"Video · Shot Draft 768p · 2 × 5 s"` (+ `" · test render"` in mock mode)

**Recast** (2026-11-05, "same take, new cast"): `POST /v1/suite/shots[/estimate]` with `{mode: "recast", clipId, cast, quality?, keepAudio? /* default true */, prompt?, takes?}`.
- **What it keeps:** the clip's motion, camera, framing and (on models that keep them) cuts. The original sound is kept (put back by stream copy on models that drop it) unless `keepAudio: false`.
- **Delivery:** as the model made it, no trim.
- **The model** comes from its own recast ladder: the first that takes this many people and this clip length. `400 nothing_fits` otherwise ("try another quality, fewer people or a clip of 5–30 s").
- **Labels:** `engineLabel` "Recast · HD · 1080p", take `label` "HD", ledger "Video · Recast HD 1080p · 6 s".
- **Refused (400):** no `clipId`, no `cast`, two entries for the same person, a character with no sheet. More than 4 people is refused by the schema. Unknown clip or character → 404.
- **Prompt:** the prompt script `suite.recast` (owner-editable). Mouth wording per person comes only from its speaking rules.

**Prompts are prompt scripts** (2026-11-05, workstream 4's engine): `suite.shot` (the whole shot prompt; its `scene` section is the only one that sees the user's words, sanitised) and `suite.camera` (the Camera block per model family). Owner rule edits: `GET/PUT/DELETE /v1/prompt-scripts/suite.shot|suite.camera`. Mouth and speech wording comes only from the shot's audio rules (`audio.lipsync`, `audio.beat`, `suite.audio.dialogue`, `audio.silent`). The job's `request` also carries `speaking` and `speakingSource`. Camera-session Shot drafts are priced on their target model (`engineModel` + `resolution` from the session's `targetModel`), falling back to the Cinema ladder with a warning when the target can't make the shot.

**Prompt library:** group `suite` ("AI suite") with 32 entries:
- `suite.camera.*`: per-option wording as `id: wording` lines, and the per-model camera block formats.
- `suite.shot.*`: character, character in words, outfit, extra reference, lock, keyframes, scene (the user's words), guide, camera, avoid, footer, negative; `suite.audio.dialogue`.

### The new Suite's server pieces (build step 2, 2026-11-07; `plans/ai-suite-design.md`)
Migration **0014** (`suite_drafts_rigs`): `jobs.draft`, `takes.draft`, `models.default_rig` and the `suite_rigs` table. Code: `suite/drafts.ts`, `suite/rigs.ts`, `suite/feed.ts`; tests `test/suite-drafts.test.ts`.

**Types**
- `Rig`: the composer's rig rows by catalog id, with the same names as the clients' `ComposerSettings`. Every field is optional; a missing field is Auto.
  - Fields: `{body?, lens?, focalMm? /* 8–200 */, aperture?, height?, shotSize?, lighting?, palette?, stock?, gradeLook?, genre?, era?, tempo?, format?, moves?: {id, intensity? /* 0–1 */}[] /* ≤ 2 */}`.
  - Ids are checked against `GET /v1/suite/camera`; hidden and merged ids are accepted. Unknown ids and unknown fields → `400` ("rig.lens: unknown lens …").
- `Draft`: the composer's full draft, as the client sent it.
  - Fields: `{v /* default 1 */, tool: "shot" | "photo" | "storyboard" | "swap" | "recast" | "extend" | "upscale" | "talking" | "ugc", quality?, aspect?, duration?, takes?, count?, sound?, speaking? /* true, false or null = auto */, rig?, tokens?: unknown[] /* ≤ 400, chips with their keys */, slots?, …}`.
  - Extra fields are kept, up to 64 KB in total. The server reads only `tool` (the feed filter) and the bottom-bar values (the summary line); everything else is returned unchanged.
- `RigView`: `{id, name, rig: Rig, userId, mine, createdAt, updatedAt}`.
- `FeedItem`: one card in the takes rail.
  - Common: `{id, kind: "job" | "take" | "photo", status: "queued" | "running" | "failed" | "done", tool, jobId?, title, modelId?, modelName?, createdAt, poster?: ImageRef, aspect?, durationSec?, price, summary}`.
  - `job`: `progress`, `phase`, `secondsLeft` (running), `blocked`, `error` and `errorCode` (failed), `refunded`, `label`, `takes`.
  - `take` and `photo`: `takeId`, `label`, `videoUrl` (videos), `index`, `of`, `final`.
  - `summary` is the caption line, e.g. "9:16, 10 s, 1 take, sound on" or "9:16, 4 photos".

**Endpoints**
| | |
|---|---|
| `POST /v1/suite/shots`, `POST /v1/jobs`, `POST /v1/suite/photos` + `draft?: Draft` | The draft is stored with the job (shots, swaps) and copied onto each of its takes when it finishes. Photos store it on every still. `Job.draft` and `Take.draft` return it, so **Reuse settings** restores the composer exactly. A bad draft → `400 "Invalid draft: …"` before anything is held. Estimates ignore it. It never goes into `request`. |
| `GET /v1/suite/rigs` | → `RigView[]`. A member gets their own rigs; the owner gets every rig in the studio, theirs first (`mine`). Ordered by last change. |
| `POST /v1/suite/rigs {name, rig}` | → `RigView`. Name 1–60 characters, trimmed. At most 100 rigs per person (`409 too_many_rigs`). |
| `PATCH /v1/suite/rigs/{id} {name?, rig?}` | → `RigView`. Your own rig, or any rig in the studio for the owner. Anyone else's reads as `404`. `rig` replaces the whole rig. |
| `DELETE /v1/suite/rigs/{id}` | → `204`, with the same permissions as PATCH. |
| `PATCH /v1/models/{id} {defaultRig: Rig \| null}` | The model's **default rig**, returned as `Model.defaultRig`. `null` or `{}` clears it. Anyone in the studio can set it, like the model's other fields. |
| `GET /v1/suite/feed?tool=&model=&status=&cursor=&limit=&collection=` | → `{queued?: QueuedShot[], items: FeedItem[], nextCursor: string \| null}`. See below, and "Library collections and the Suite queue". |

**The feed (`GET /v1/suite/feed`)**
- **Order:** newest first.
  - Queued, running and failed jobs appear as one card each. A failed card says why.
  - Every finished video take and every photo is its own card. A done job's takes take its place.
  - Edited versions are not listed. Jobs deleted from Queue drop out with their takes.
- **Filters:** `tool` and `status` take comma lists (unknown values → `400`); `model` is a model id. Filters combine. Visibility is studio-wide, like `/v1/jobs` and `/v1/takes`.
- **Tool:** the draft's `tool` when there is one. Otherwise it comes from the request (a suite `mode` of extend or recast, else shot; `upscale`; the video studio's swap), and stills are `photo`.
- **Paging:** `limit` 1–60 (default 30). `nextCursor` is opaque; pass it back until it is `null`.
  - A page is two queries (jobs; takes with their job and model joined), keyset-paged on `(createdAt, id)` and merged. There are no per-item queries.
  - A job that finishes between two pages moves from its "running" card to its takes, which are newer, so those appear on the first page of a fresh load.
- **Member-safe:** no providers or model names. `label` is the tier label ("Shot · Draft · 768p"), as on the job.

**Model default rig (client rule, `plans/ai-suite-design.md` "Refinements" 3):**
- When a model is @-mentioned, the composer fills only the rig rows still on Auto from her `defaultRig`, then shows "Applied <name>'s rig · Undo".
- It never overwrites a row the user set. With two @ models in the prompt, nothing applies automatically.
- `moves` in a default rig are added as `#` chips only if the prompt has no move yet.

### Library collections and the Suite queue (build step 3, 2026-11-08; `plans/ai-suite-design.md` "Refinements" 1 and 6)
Migration **0020** (`library_collections_suite_queue`): the `library_collections`, `library_collection_items` and `suite_queue` tables. Code: `suite/collections.ts`, `suite/queue.ts`; tests `test/suite-library.test.ts`.

**Library collections.** Named groups of the studio's takes and photos (any `takes` row). Everyone in the studio sees them, like the library. The one who made a collection, or the owner, renames it, deletes it and changes what's in it; anyone else gets `403 not_yours`.

| Call | Notes |
|---|---|
| `GET /v1/library/collections` | → `Collection[]`, most recently changed first. |
| `POST /v1/library/collections {name, takeIds?}` | → `Collection & {takeIds}`. `name` is 1–60 characters. Up to 200 collections per studio (`409 too_many_collections`). |
| `GET /v1/library/collections/{id}` | → `Collection & {takeIds}` (newest added first). |
| `PATCH /v1/library/collections/{id} {name}` | Rename. |
| `DELETE /v1/library/collections/{id}` | → 204. The takes and photos stay in the library. |
| `POST /v1/library/collections/{id}/items {takeIds}` | Add (each once; up to 200 per call, 2,000 per collection: `409 collection_full`). An id that isn't the studio's → `400 takeIds: no take or photo …`. → `Collection & {takeIds}`. |
| `POST /v1/library/collections/{id}/items/remove {takeIds}` | Remove. → `Collection & {takeIds}`. |
| `GET /v1/library/takes/{takeId}/collections` | → `Collection[]` the take or photo is in (its detail sheet). |
| `GET /v1/suite/feed?collection={id}` | The feed of that collection: its takes and photos only (no pending jobs, no queue), with the usual filters and paging. An unknown collection → `400`. |

```
Collection { id, name, userId, mine, canEdit, count /* takes and photos that still exist */, cover: ImageRef | null /* the newest item's thumb */, createdAt, updatedAt }
```
Event `collection`: `{collection}` (created or changed) or `{deleted: id}`, to the whole studio.

**The Suite queue.** A shot saved to run later. Queuing checks the shot and prices it, but holds nothing. **Run · $cost** prices it again and goes through the normal estimate → confirm → hold path. Each member sees their own queue; the owner sees the studio's.

| Call | Notes |
|---|---|
| `POST /v1/suite/queue {…the body of POST /v1/suite/shots}` | Checked and priced like `…/shots/estimate` (same errors, `nothing_fits` included); nothing held. `queue` and `dryRun` are ignored. Up to 50 per member (`409 queue_full`). → `QueuedShot`. |
| `GET /v1/suite/queue` | → `QueuedShot[]`, newest first. |
| `POST /v1/suite/queue/{id}/estimate` | Today's price → `QueuedShot & {estimateView /* the shot estimate, as …/shots/estimate returns it */, changed}`. The stored price is updated. Show it, then confirm. |
| `POST /v1/suite/queue/{id}/run {confirm: true}` | Runs it exactly as `POST /v1/suite/shots` would (caps, hold, job); the queue entry is removed. → `{queuedId, job}`. `400` without `confirm: true`. |
| `DELETE /v1/suite/queue/{id}` | Discard → 204 (nothing was held). |

```
QueuedShot { id, kind: "queued", title, tool, modelId?, userId, mine, estimate, buttonLabel: "Run · $0.40", prompt?, draft?, createdAt }
```
- **In the feed:** the first page of `GET /v1/suite/feed` (no cursor, no collection) carries `queued: QueuedShot[]` above `items` (the "Queued" group), filtered by `tool`, `model` and `status` (`queued`).
- Event `queue`: `{item}` or `{removed, jobId?}`, only to the member who queued it and the owner.

### Images attached to Claude chat messages (workstream 1, owner-approved 2026-11-08)
Migration **0023** (`claude_messages.attachments`, `claude_turns.attachments`). Code: `camera/claudeAttachments.ts`; tests `test/claude-attachments.test.ts`.

- **Upload** with the normal flow (`POST /v1/uploads/presign {kind:"image"}` → PUT → `POST /v1/uploads/{uploadId}/confirm`). JPEG, PNG, WebP or HEIC/HEIF; ≤ 10 MB each.
- **Send** `POST /v1/claude/threads/{id}/messages {text, attachments?: [{uploadId}]}`: ≤ 4 a message; `text` may be empty when there are images. 400 for the count, type, size or an unreadable file; 404 for another studio's upload; 409 `upload_not_ready` before confirm. All or none: a refused message queues nothing.
- **Stored privately on the thread** under `ca/<threadId>/` (not served by `/uploads`), normalised: upright, long edge ≤ 2048 px, ≤ 5 MB (else JPEG), HEIC → JPEG (`heif-convert`, in the image). 415 `unsupported_image` if a HEIC can't be read.
- **Views**: messages and turns carry `attachments: [{id, uploadId, mimeType, bytes, width, height, url}]` (`url` signed, 1 h). The Mac downloads them on claim and lists the local paths with their uploadIds in the Claude Code prompt. A message typed on the Mac can send `{"type":"user", text, attachments:[{uploadId}]}`.
- **API fallback** `POST /v1/claude/threads/{id}/api-turn {text, attachments?}`: Recreate, Edit and Suite threads send them as image blocks with a line naming each uploadId; earlier attached images are replayed (the newest 8). Camera threads: 400 (text only).

**`suite_add_reference {assistId, uploadId, use: pose|style|location|outfit, label?, remove?}`** puts an image into the Suite draft as `draft.references[{uploadId, url, use, label?}]` (≤ 3; the same uploadId again changes its use). The url is a studio image under `u/` (HEIC copied as JPEG). The request sends them as `references.images[{image:{url}, role: use, label}]` after her own images; roles `pose` and `outfit` tell the engine to take only the pose or the clothes, never anyone's face or body. Her identity always comes from her own references; the plan still keeps at least one of hers when room is short, and `suite_estimate` notes any left out.

### Claude in the AI Suite (owner-approved 2026-11-08)

**Prompt structure.** The suite brief (`threadBrief('suite').prompt`) and the API loop's system prompt are the same text: the shot-designer rules plus §3–§7 of the owner's skill `.claude/skills/muse-prompt-structure/SKILL.md` (skeleton SUBJECT / LOCATION / ACTION + SHOT n / STYLE / CONSTRAINTS, the rig, lengths, consistency, output). The server reads its copy at `server/api/assets/skills/muse-prompt-structure.md` (the image has no `.claude`); a test fails if the copy and the repo skill differ, so edit the skill and copy it over.
Migration **0022** (`suite_assists`). Code: `suite/assist.ts`, `suite/mcpTools.ts`; tests `test/suite-assist.test.ts`.

The owner describes a shot in words. Claude sets up the composer (the @model, the prompt, the rig with only the options members see, the moves, quality, shape, length, takes) and explains its choices. It generates only after the owner approves the price in the app.

| Call | Notes |
|---|---|
| `POST /v1/suite/assist {draft?: Draft, fromJobId?}` | A shared composer draft: empty, the composer's current one, or a job's draft. → `Assist`. |
| `GET /v1/suite/assist/{id}` | → `Assist` (the user's own; the owner's for the owner). |
| `PATCH /v1/suite/assist/{id} {draft, baseRevision?}` | The owner's own composer edits, so Claude sees them. `409 stale` when Claude changed it since. |
| `POST /v1/suite/assist/{id}/pending/{pid} {approve: boolean}` | The owner's answer to Claude's Generate. → `Pending`. Yes prices it again and runs it exactly as `POST /v1/suite/shots` would (caps, hold, job; `jobId` on the pending). It never runs above the price the owner saw (`409 price_changed {totalUsd}`). |
| `POST /v1/claude/threads {contextKind: "suite", contextId: <assist id>}` | The Claude thread; `brief` names the tools and `assistId`. `api-turn` runs MUSE's loop with the Suite tools (the assist id filled in). |

```
Assist { id: "sa_…", userId, draft: Draft /* the Reuse-settings draft */, revision, request: ShotRequest /* what Generate sends */, warnings: RigWarning[], pending: Pending[], createdAt, updatedAt }
Pending { id: "sp_…", kind: "suite_request_shot", label: "Generate · 5 s · $0.40", estimateUsd, maxUsd, status: "waiting"|"declined"|"done"|"failed", jobId?, error?, createdAt }
```
- **Live:** event `suiteAssist {assist}` after every change (Claude's or a device's), to the draft's member and the owner. The composer applies `assist.draft` as Reuse settings does. Waiting `pending` items show as "Claude wants to generate · $x · Approve / Decline".
- **Claude's tools** (MCP, owner only):
  - `suite_options()`: the visible options with labels and descriptions, the visible focal steps and the bar's values. Hidden ones (for example f/4) aren't listed and are refused.
  - `suite_get_draft(assistId)`.
  - `suite_set_draft(assistId, {modelId?, outfitId?, prompt?, rig?, moves?, quality?, aspect?, duration?, takes?, sound?, speaking?})`. It is checked against `camera.ts` and returns the assist with the rig-check warnings.
  - `suite_estimate(assistId)`.
  - `suite_request_shot(assistId, confirm?)`: without `confirm` it gives the price; with it, a pending approval for the owner (`maxUsd` = that price).
  - `suite_feed(limit?, tool?)`.

## Recreate this edit (workstream 1, 2026-11-08; `plans/recreate-edit.md`)
A reference video (an upload, up to 60 s for now) is analysed into a versioned **recipe**. The analysis is free: ffmpeg, the beat detector and sharp on the server's CPU, one analysis at a time. Migration **0015** adds `recreate_references`. Code is in `src/recreate/` (`analyze.ts`, `signals.ts`, `frames.ts`, `text.ts`, `references.ts`); tests are `test/recreate.test.ts` (a synthetic reference) and `test/motion.test.ts`.

**Privacy and retention:**
- Each member sees their own references; the owner sees all of them. Another member's reference reads as `404`.
- The contact sheet is stored under `rx/`, which is not served by `/uploads/*`. It is served only by the authenticated route below.
- After **30 days**, unless `keep: true`, everything made from the reference's pixels is deleted: the video (its upload, or `rx/…/source.mp4` from a link), the contact sheet, the per-frame poses (`rx/…/poses.json`), the swap segments and the exports. A server timer runs this hourly. The row turns `expired` and leaves the lists, and the recipe JSON stays, since it holds no pixels. Background plates and the swapped takes are the studio's own and stay.
- `DELETE` removes everything at once.
- Pose keypoints are body points only; reference pixels are never stored in a recipe.

**Endpoints**
| | |
|---|---|
| `POST /v1/recreate/references {uploadId, name?, sourceUrl?}` | → `Reference` with `state: "analyzing"`. The upload must be a video of this studio, at most 60 s (`400 "References can be up to 60 s for now (this one is 62 s)"`). **`sourceUrl`** is set when the device fetched the video from a link (Release 1 fix: platforms block server addresses). The studio's link rules apply to it (`link_unsupported`), and so does the size cap (`link_too_big`). It's kept on the reference for caching and "Use this sound". The same link again from the same member → that member's reference, with `cached: true`. |
| `POST /v1/recreate/references {url, name?}` | A **public** TikTok, Instagram Reel or YouTube link (see "From a link" below). → `Reference` with `source: "link"`, `state: "analyzing"`, `phase: "Fetching the video"`. The same link again, from the same member, → that member's existing reference with `cached: true`. Refusals come before anything is downloaded (codes below). |
| `GET /v1/recreate/references` | → `Reference[]` without the recipe (with `slots`: the number of slots), newest first. |
| `GET /v1/recreate/references/{id}` | → `Reference` with its `recipe` once `ready`. |
| `PATCH /v1/recreate/references/{id} {keep?, name?}` | `keep: true` stops the 30-day deletion (`expiresAt: null`). |
| `DELETE /v1/recreate/references/{id}` | → `204`. The row and everything listed above are deleted. An analysis, link fetch or export still running when it is deleted removes its own files when it finishes. |
| `GET /v1/recreate/references/{id}/contact-sheet` | → the PNG: each slot's keyframe, labelled "2 · 1.5–2.7 s". Claude writes the shot briefs from it. |
| `GET /v1/recreate/references/{id}/video` | The reference video for the side-by-side player (authenticated): a `302` to a 1-hour link on S3, or the bytes on local storage. `404` once expired. |
| `GET /v1/recreate/references/{id}/poster` | → PNG: the first slot's keyframe (cropped from the contact sheet). |
| `GET /v1/recreate/references/{id}/slots/{slotId}/thumb` | → PNG: that slot's keyframe. |
| `GET /v1/recreate/references/{id}/fill` | → `{referenceId, slots: SlotFill[], applied?, match?}`, see below. |

**From a link** (migration **0018**, `src/recreate/links.ts`, `test/recreate-links.test.ts`). The owner chose to keep link fetching after reading the platforms' terms, and the risk is theirs (`plans/research/platform-download-rules.md`). Guardrails:
- **Public only.**
  - MUSE never uses sign-ins or cookies. yt-dlp runs with `--ignore-config --no-cookies --no-cookies-from-browser` and none of the server's environment.
  - YouTube needs a JavaScript runtime. yt-dlp gets the server's own Node (`--no-js-runtimes --js-runtimes node:<node>`; only deno is on by default) and the pinned `yt-dlp-ejs` 0.8.0 scripts. `--no-remote-components` means no code is fetched at run time.
  - Private, members-only, sign-in-walled and age-restricted videos are refused (`link_private`).
- **The creator's setting.** For TikTok, MUSE reads the video's public page. If the creator turned downloads off (`downloadSetting` ≠ 0, or an explicit false), the video is refused (`link_downloads_off`). A page MUSE can't read counts as a blocked fetch; a page that doesn't say is treated as allowed.
- **One fetch per link.**
  - The metadata is read once, and the download reuses it (`--load-info-json`). TikTok's page is the one extra read.
  - No lists, no live streams, no crawling. Platform requests run one at a time across the server.
  - A link is cached by its normalized form (`https`, no tracking parameters, short links resolved to the video's own link), per member.
- **Before the download:** duration ≤ 60 s (`too_long`, `400`) and size ≤ `RECREATE_LINK_MAX_MB` (80) (`link_too_big`). Both are checked again on the file.
- **Storage.** The file is stored privately at `rx/{studio}/{id}/source.mp4` (not served by `/uploads`) and deleted after 30 days like any reference. The metadata is deleted as soon as the file is stored.
- **Blocked** (a server address the platform blocks, 403, sign-in wall, rate limit, timeout, removed video): `link_blocked` (`502`) with the message "Couldn't fetch this link — save the video and drop the file in". The apps show it and offer the file drop. If the download itself is blocked, the reference turns `failed` with `errorCode: "link_blocked"`.
- **Codes:** `link_unsupported` · `link_private` · `link_downloads_off` · `link_too_big` (all `422`) · `link_blocked` (`502`) · `too_long` (`400`).

**Fetching on the device, and "Strict link rules"** (Release 1 fix, migration **0021**). Platforms answer server addresses with sign-in or bot checks (YouTube: "Sign in to confirm you're not a bot"), so the apps download the video themselves. Then they upload it with `sourceUrl`. The server fetch stays as a fallback.

| Call | Notes |
|---|---|
| `GET /v1/recreate/settings` | → `{strictLinks, platforms: ["tiktok","instagram","youtube"] \| ["any"], tiktokDownloadsOff: "refuse"\|"allow", maxSec: 60, maxMb, serverFetch, cookies: false, canEdit}`. These are the rules the apps apply on the device too. |
| `PATCH /v1/recreate/settings {strictLinks}` | Owner only (`403 owner_only`). **On (default):** only TikTok, Instagram Reels and YouTube; TikTok's "downloads off" is refused. **Off:** any public web link yt-dlp reads (platform `"other"`, tracking parameters removed), and TikTok's setting isn't refused. Either way: no cookies or logins, 60 s, and the size cap. Event `recreate` `{settings}`. |
| `POST /v1/recreate/links/check {url}` | Before a device downloads: → `{allowed: true, url /* normalized */, platform: "tiktok"\|"instagram"\|"youtube"\|"other", cached?: Reference}` or `{allowed: false, code, reason}`. `cached` is this member's live reference from that link: use it and skip the download. |

- **Public hosts only (strict off).** A link must be https/http on the standard ports, with a public host name. No addresses, no localhost or internal names, no user:password. On the server, the name must also resolve only to public addresses before yt-dlp runs.
- **Why a server fetch failed** is logged as `recreate link fetch failed {platform, step, code, failure}`. `failure` is one of `bot_check` · `login` · `rate_limited` · `forbidden` · `not_found` · `geo` · `timeout` · `private` · `age` · `too_big` · `unsupported` · `no_ytdlp` · `other`. The link itself is never logged.
- **Reference fields:** `source: "file" | "link"`, `sourceUrl?`, `errorCode?`. Claude's `analyze_reference` takes `url` as well as `uploadId`.
- **Config:** `RECREATE_LINKS` (default on), `YTDLP_PATH`, `RECREATE_LINK_MAX_MB`. The image pins yt-dlp 2026.10.26 and yt-dlp-ejs 0.8.0 from PyPI (both sha256-checked at build, unpacked to /opt/yt-dlp/lib) and adds python3, about +30 MB (an estimate: no Docker daemon was available to measure). CI never calls a platform; a fake yt-dlp replays `test/fixtures/links`.

**Export** (plan step 7, workstream 1, Release 1):

| | |
|---|---|
| `POST /v1/recreate/references/{id}/export {sessionId, sound?: "guide"\|"silent"}` | Renders the edit session's current revision, as long as the reference, at the canvas's size. `guide` (the default) uses the reference's own sound as the track; `silent` has no sound. → `Export` (`state: "rendering"`, or `"ready"` when that revision is already exported). A reference without sound gets `409 no_reference_sound` for a guide export; export it silent instead. Expired references leave the lists (`404`), so export before the 30 days are up, or keep the reference. |
| `GET /v1/recreate/references/{id}/export?sessionId&sound&revision?` | → `Export`. Polling, or wait for the live event `{type: "recreate", export: Export}`. |
| `GET /v1/recreate/references/{id}/export.mp4?sessionId&sound&revision?` | The file (authenticated, as an attachment): a `302` to a 1-hour link on S3, or the bytes. |

`Export {referenceId, sessionId, revision, sound, state: "none"|"rendering"|"ready"|"failed", url?, durationSec?, width?, height?, unsupported?, error?, useThisSound}`
`useThisSound {platform: "tiktok"|"instagram"|"youtube"|null, sourceUrl?, startAtSec: 0, durationSec, title: "Post with the original sound", steps: string[], note}`
- `useThisSound` is the reminder the apps show next to the export. For a link reference the steps name its platform's "Use this sound", "Use audio" or "Remix · Use sound"; for a file reference they are general.
- The note explains that the guide sound is only for timing, so post with the platform's own sound.
- Exports are stored privately under `rx/` and deleted with the reference.

**The built edit, rendered** (`src/editor/render.ts`, `renders.ts`; `test/render.test.ts`; for Compare on both apps):

| | |
|---|---|
| `POST /v1/edit-sessions/{id}/preview` (owner) | Renders the session's current revision as a preview: the longest side 720 px, 30 fps, with the project's sound. → `Preview` (`rendering`, or `ready` if this revision is done). Each revision is rendered once; a newer revision's preview replaces the older one when it is ready. |
| `GET /v1/edit-sessions/{id}/preview?revision?` | → `Preview` (`state: "none"` before any). Live event: `{type: "edit", sessionId, op: "render", render: Preview}`. |
| `GET /v1/edit-sessions/{id}/preview.mp4?revision?` | The file (authenticated): a `302` to a 1-hour link on S3, or the bytes. |

`Preview {sessionId, revision, state, url?, durationSec?, width?, height?, unsupported?, error?}`
- **Drawn:**
  - the main track: trims, speed and speed curves, cover/contain fit, transform and x/y/scale keyframes, and transitions (xfade);
  - the Look's LUT at its strength;
  - text items, in the apps' fonts (bundled in `assets/fonts`, OFL);
  - the clips' sound at their speed, plus music, voice and sfx clips.
- **Not drawn, and listed in `unsupported`:** rotation, opacity, crop, colour adjustments, filters, masks, chroma, background removal, overlays, captions, text animation, look details beyond the LUT, ducking and library music. Show "Preview of the cut" when the list isn't empty.
- **Frame-exact:** each clip gets exactly its frames on the timeline, so the cuts in a render match the edit.
- **Cost:** one render at a time on the server's CPU, with no GPU and no charge.

**Live event:** `{type: "recreate", reference}` (the `Reference` without its recipe, with `slots`: the count) goes to its member and the owner on create, on each analysis step, when it is ready or failed, and on `PATCH`. Migration **0016** adds `recreate_references.fill`.

**Fixture:** `server/api/test/fixtures/recipe-v1.json` is a `GET /v1/recreate/references/{id}` response from a real analysis of the test reference (with an example brief, words and summary), for the apps' fakes. A test fails if the API sends a field the fixture lacks.

`Reference`: `{id, name, state: "analyzing" | "ready" | "failed" | "expired", progress, phase, error?, durationSec, userId, keep, createdAt, expiresAt | null, videoUrl?, posterUrl?, recipe?}`.

**Recipe** (`schema: "muse.recipe/1"`; every element has a `confidence` from 0 to 1; times are seconds in the reference):
```
Recipe {
  schema, id, origin: "reference" | "edit", referenceId?, takeId?, versionId? /* origin "edit": workstream 3's recipeFromProject */,
  createdAt, analyzer: {version, tookMs}, summary?, tags?: string[],
  source: {durationSec, width, height, fps, aspect: "9:16", hasAudio},
  sound: {bpm, beats[], strong[], confidence} | null,
  pacing: {shots, avgShotSec, cutsPerMin, energy: {everySec, values[] /* 0–1 */}},
  slots: Slot[], transitions: Transition[], text: TextItem[],
  grade: {swatches: hex[5], contrast, saturation, warmth /* −1…1 */, look: {id, kind: "palette", label, distance} | null, grade: Grade, confidence},
  contactSheet: {url, times[], tiles: {slotId, x, y, w, h /* px in the sheet */}[]} | null,
  gaps: {key /* stable, e.g. "transition:unknown@2.40", "text:words", "pose" */, kind: "transition"|"effect"|"text"|"font"|"motion"|"other", what, atSec?, note}[]
}
Slot {
  id: "s1", index, startSec, endSec, durationSec, keyframeSec, confidence, thumbUrl?, fill?: {jobId},
  brief: {shotSize?, angle?, subject?, action?, location?, notes?} | null,
  rig: Rig | null,
  camera: {motion: "static"|"pan"|"tilt"|"zoom_in"|"zoom_out"|"shake"|"mixed", shake, keys: {t, x, y, scale}[], confidence},
  speed: {ramp: "none"|"speed_up"|"slow_down"|"freeze"|"mixed", curve: {t, speed}[], confidence, freeze?: {t, durationSec} /* where the longest hold is */},
  peaks: {t, strength}[],
  pose: {status: "pending"|"done"|"none", frameSec?, keypoints?: {name, x, y, score}[],
    track?: {frames, fps} /* every frame of the shot was read (keypoints only, stored privately next to the reference, deleted with it); used to match takes by movement */}
}
Transition { atSec, from, to, kind: "cut"|"flash"|"whip"|"zoom"|"fade"|"crossfade"|"glitch"|"unknown", durationSec, confidence }
// glitch: a burst of 3+ hard changes in under 0.6 s (the picture flickering between shots), or a cut with sideways jitter only around it (as the apps and the server render draw it). One that returns to the same shot has from = to (an effect inside the shot, logged as an editor gap).
TextItem { id, startSec, endSec, box: {x, y, w, h /* 0–1 */}, words: string | null, sizeFrac, color, fontId: "sans"|"serif"|"rounded"|"condensed"|"mono"|"marker" /* nearest editor font to the read words' shape; "sans" when unsure */, animIn: "cut"|"fade"|"typewriter"|null, animOut: "cut"|"fade"|null, animInSec?, animOutSec? /* how long the fade or typing takes */, confidence }
```
**Size caps** (a recipe stays under about 256 KB): speed curves at most 48 points and camera keys at most 64 per slot (thinned, ends kept), at most 100 text items. An `unknown` transition also adds a gap.

How each part is found:
- **Shots and cuts:**
  - A hard cut is a histogram jump plus a pixel jump at most 2 frames wide, so it is frame-accurate. A one-frame flash is `kind: "flash"`.
  - A gradual transition is a run of frames that keep changing a little and add up to a different picture: `fade` through black or white, otherwise `crossfade`. The shot boundary is its middle.
  - Whip and zoom transitions are told apart by fast camera motion or scale change across the cut.
- **Camera:**
  - Global motion is found by block matching on a 96 px proxy; scale is measured against the frame 6 back.
  - `keys` are the content's cumulative shift (`x`, `y`: + = right/down) and `scale` (> 1 = zooming in) from the slot's start, about 4 a second. The editor's transform keyframes can replay them.
  - Frames inside transitions are skipped.
  - `rig.moves` is the Suite move that recreates the slot, for example `pan_right` when the content slides left.
- **Speed:** from how much the picture changes per frame against the slot's median. This is a proxy for optical flow, so `confidence` is about 0.55.
- **Beats:** `detectBeats` on the audio. **Action peaks:** `find_action_peaks`'s detector.
- **Text:** caption-like regions (bands of sharp edges in near-white or near-black strokes), tracked at 6 fps for their box, size, colour and in/out times.
  - `words`: tesseract (English, in the API image) reads each item once, at its middle, from a frame up to 720 px wide: the box is cropped, scaled and cleaned up (the caption's fill kept as black on white), and up to three variants are tried until one reads with confidence ≥ 85. Words under 55 stay `null`, as do items past the first 20 and every item when `TESSERACT_PATH` is empty or tesseract is missing. Claude reads what is left from the contact sheet; the `text:words` gap says so.
- **Grade:** k-means of the keyframes gives 5 swatches. The Suite's `swatchGrade` turns them into the look pack's `Grade` (the palette→LUT path), and `look` is the nearest existing palette.
- **Pose:** MoveNet SinglePose Lightning (`assets/pose/`, Apache-2.0) gives 17 body keypoints at each slot's keyframe, 0–1 in the frame; points only, never pixels.
  - `status: "done"` when the mean score is ≥ 0.25, `"none"` when no person is found, and `"pending"` when the pose wasn't read.
  - It runs in a child process, one job at a time, and the model is loaded only for that job. At most 20 keyframes per reference.
  - The child's peak RSS is about 125–160 MB. It is logged ("recreate pose") and recorded in `analyzer.pose {frames, ms, peakRssMb}`.
  - When the container has less than `RECREATE_POSE_MIN_FREE_MB` (200) free, poses are skipped: `analyzer.pose {skipped: "memory"}`, the slots stay `pending`, and the `pose` gap says why.
  - `RECREATE_POSE=false` turns poses off.
  - The API image carries onnxruntime-node (CPU, this platform only, about 47 MB) and the 9.4 MB model.

## Learning editor (workstream 3, 2026-11-08; `plans/recreate-edit.md` §5)
The studio's editing memory, which Claude reads before every edit. The model doesn't change; MUSE's memory does. It is owner only: members get `403 owner_only`. Migration **0017** adds `edit_recipes`, `edit_corrections`, `playbook_rules`, `edit_gaps` and `edit_ops.meta`. Code: `src/editor/learn.ts`, `learnRoutes.ts`, `learnSchema.ts`. Tests: `test/learn.test.ts`.

**Recipe library.** Every analysed reference and every finished edit is kept as a recipe (`muse.recipe/1`).
- References are copied from `recreate_references` when ready, and the copy outlives the reference's 30 days.
- Finished edits are the studio's edited versions with a v2 project. `recipeFromProject` turns one into a recipe with `origin: "edit"`: main clips become slots (speed curves become ramps, transform keyframes become camera keys), `transitionIn` becomes transitions, text items become text, the look and adjustments become the grade, and the music clip's beats become the sound.
- The library syncs when it is read, so nothing else has to call it. Claude's `summary` and `tags` on a reference are refreshed on sync.
- **Tags** are derived (`reference` / `own-edit`; `slow-cuts`, `medium-cuts` or `fast-cuts`; `short`, `medium-length` or `long`; `tempo-slow`, `tempo-mid` or `tempo-fast`; `high-energy` / `calm`; `transition-<kind>`; `text`; `speed-ramps`; `look-<palette>`), plus Claude's tags and the owner's.
- **Features** (for nearest): `durationSec`, `shots`, `cutsPerMin`, `avgShotSec`, `bpm`, `energy`, `text`, `fancyTransitions`, `warmth`, `saturation`, `contrast`. **Distance** is the RMS of the scaled differences plus 0.5 × (1 − tag Jaccard).
- **Performance** comes from Posts through the recipe's `takeId`: `{posts, views, likes, comments, saves?, avgWatchSec?, completion?}`. `saves`, `watchTimeSec` and `completion` are read from `posts.stats` when the platforms report them.

**Corrections.** Every change in an edit session stores what it really touched in `edit_ops.meta.touched`: `"<itemId>/<key>"`, `"<itemId>/*"` when an item was added or removed, `"track:<id>/<key>"` and `"canvas/<key>"`.
- A correction is logged when the owner (any app, not Claude) changes something one of Claude's last 20 not-undone changes touched (same item, and the same key or the whole item), or undoes one of Claude's changes.
- A correction holds the area (captions, text, transition, look, motion, speed, timing, audio, pacing, ratio, other), plain words ("Changed the look after Claude's “…”"), Claude's label, before/after (short), and the recipe element from `edit_ops.meta.sources` (Recreate's apply passes `meta: {sources}` to `applyClaude`).
- A drag is one lesson: one correction per Claude change and area per minute.

**Playbook.** Plain-language rules (≤ 300 characters, ≤ 200 per studio). Each has an `area`, a `source` (`owner` / `claude` / `learned`), `pinned`, and `evidence[] {kind: correction|post|recipe|note, id?, note, at}`. The list is pinned first, then by most evidence, then newest. Claude's rules come in unpinned, and the owner pins, edits or deletes any rule.

**Gaps.** Recipe gaps are counted per studio by their key without `@time` (`transition:unknown`), once per recipe, keeping the last 5 examples. Claude or the owner can also log a gap directly. The list is most requested first.

| | |
|---|---|
| `GET /v1/learn/recipes?q&tags=a,b&origin&limit` | → `RecipeEntry[]` (no recipe body), newest first. `q` matches the name, summary and tags; `tags` must all be present. |
| `GET /v1/learn/recipes/{id}` | → `RecipeEntry` with `recipe`. |
| `GET /v1/learn/tags?limit` | → `{tag, count}[]`: the most used tags across the library (default 8, at most 30), ties alphabetical. For the Recipes filter chips. |
| `PATCH /v1/learn/recipes/{id} {name?, tags?}` · `DELETE …` | Rename or retag (lower-cased, unique; at most 30 tags of 32 characters). `DELETE` → `204`. |
| `GET /v1/learn/recipes/nearest?recipeId|referenceId|takeId&k&origin` | → `{recipeId, nearest: (RecipeEntry & {distance})[]}`, closest first. `404` when the recipe isn't in the library. |
| `GET /v1/learn/corrections?limit&sessionId&area` | → `Correction[]`, newest first. |
| `GET /v1/learn/lessons` | → `{area, claudeChange, count, undos, last, examples[], ids[], ruleId?}[]` (`ruleId`: a rule already cites one of its corrections as evidence): corrections grouped by area and Claude's change, the most frequent first. This is what Claude turns into rules. |
| `GET /v1/learn/playbook?area` · `POST {text, area?, evidence?, pinned?}` · `PATCH /{id} {text?, area?, evidence?, pinned?}` · `DELETE /{id}` | → `Rule` / `Rule[]`. A rule from `POST` has source `owner`. In `GET`, correction evidence also carries `takeId` and `takeExists` (open the edit only when it does). The list is full at 200 rules (`POST` → `400`). |
| `GET /v1/learn/gaps?limit` · `POST {key, kind?, what?, note?}` | → `Gap[]` / `Gap`. `key` looks like `"effect:lens-flare"`. |
| `GET /v1/learn/context?recipeId|referenceId|takeId&area` | → `{playbook: Rule[] (≤ 25), recipes /* the 3 nearest, or the latest own edits */, corrections (10), lessons (8), gaps (5)}`. This is what `playbook_read` returns. |

`RecipeEntry {id, origin, referenceId, takeId, name, summary, tags, features, durationSec, cuts, picture: {poster: path} | {thumb: ImageRef} | null, available, performance | null, createdAt, updatedAt, recipe?}` · `Correction {id, sessionId, takeId, takeExists, opId, claudeOpId, kind: "undo"|"change", area, what, context, createdAt}` · `Rule {id, text, area, source, pinned, evidence, createdAt, updatedAt}` · `Gap {key, kind, what, count, references, asks, examples, firstAt, lastAt}`.

For the screens (`plans/learning-editor-ui.md`, 2026-11-08):
- `picture`: a reference's poster path, or an edit's take thumbnail; `null` → the `field` placeholder.
- `durationSec` and `cuts` (shots − 1) are the tile badge ("12 s · 9 cuts").
- `available`: a reference whose video is still kept (state `ready`; "Use in Recreate"), or an edit whose take still exists ("Open edit").
- Gaps: `references` (recipes that needed it) + `asks` (logged directly) = `count`: "Unknown transition · 4 references", "Lens flare · asked once".
- Areas → screen headings: captions Captions, text Text, pacing Pacing, transition Transitions, look Look, motion Motion, speed Speed, timing Timing, audio Sound, ratio Shape, other Other.

**For WS1's MCP tools:**
- `playbook_read` → `learningOf(ctx).context(user, {recipeId?, referenceId?, takeId?, area?})`.
- `playbook_add` → `learningOf(ctx).addRule(user, {text, area?, evidence?}, 'claude')`.
- Optionally a gap tool → `addGap(user, {key, kind, what, note})`.

### Recreate this edit · slots and assembly (phase 3)
Code: `src/recreate/slots.ts` (briefs, matcher, fill request), `assemble.ts` (recipe → edit project), `mcpTools.ts`. Tests: `test/recreate-slots.test.ts`.

| | |
|---|---|
| `PUT /v1/recreate/references/{id}/briefs {slots: {s1: Brief}, summary?, tags?}` | `summary` (≤ 200 chars) and `tags` (≤ 20 short lowercase words) go on the recipe. `Brief {shotSize?, angle?, subject?, action?, location?, notes?}`. `shotSize` is a `SHOT_SIZES` id and `angle` a `HEIGHTS` id; unknown ids → `400`. Each brief is merged into the slot, and its framing and angle go into the slot's `rig`. |
| `POST /v1/recreate/references/{id}/briefs/estimate` | **"Write the shot briefs"** on the server (G8; for when the owner's Claude isn't there to read the contact sheet). → `{available, reason?, slots, estimateUsd, label: "Write the shot briefs · about $0.02", priceLine}`. Nothing is held. `available` is false (with `reason` to show) until the owner turns on Claude on the server (`PATCH /v1/claude/settings {apiFallback: true}`) and the server has a key. Free alternative: ask Claude on the Mac (`set_slot_briefs`). |
| `POST /v1/recreate/references/{id}/briefs/write {confirm: true}` | One Claude call reads the contact sheet and each shot's facts, and writes every shot's brief, the summary and tags (saved as `PUT …/briefs` would). → `{referenceId, written: ["s1", …], costUsd, reference}`. Charged the call's actual cost × `EDITOR_MARKUP` from the wallet. The price is held first; it counts in the AI editing day's spend and cap (`GET /v1/editor/settings`), but isn't listed in `/v1/editor/jobs`. `400` without `confirm: true` · `503 briefs_unavailable` (switched off, with the reason) · `503 editor_paid_off` · `402 editor_daily_cap` · `502 briefs_failed` (nothing charged). The model is set by `RECREATE_BRIEF_MODEL` (default Sonnet 5.5) and never named to members. |
| `POST /v1/recreate/references/{id}/match {modelId?, top?, minScore?, poses?: boolean}` | → `{slots: [{slotId, candidates: [{takeId, score, reasons}], suggested, suggestion: {takeId, score, reasons} | null, toGenerate}], assignment: {slotId: takeId}}`. `suggestion` is the suggested take's own score, which may rank below the top `candidates` because each take is used once. See the matcher below. **Movement** (`poses`, default true): for shots whose every frame was read, the best 8 takes on everything else are read too (10 fps, their first 6 s, cached per take; free CPU under the memory guard). Their per-frame poses are compared with the shot's: pose in the body's own frame, how much it moves, and how the body travels through the frame. That adds a strong term (weight 3) and the reason "moves alike (82%)". The first match on new takes takes a few seconds longer. |
| `POST /v1/recreate/references/{id}/slots/{slotId}/estimate {modelId, quality?, method?: "swap"\|"generate", keepBackground?: boolean, outfitId?}` | Nothing is held, cut or stored. **`method: "swap"`** (the default when the reference's video is still here and a swap engine is available; G2): the model is swapped into the reference's own segment of that shot, through the Suite's Edit job (Edit on our pods, else the hosted swap). → `{slotId, method: "swap", keepBackground, segment: {startSec, endSec}, baked: ["camera","speed","look"], request, estimate: {method, label, seconds, takes, estimate, priceLine, buttonLabel: "Swap in · 2.0 s · $0.41", ok, warnings}}`. The segment is the slot plus half of each neighbouring transition, widened evenly to the engine's minimum (4 s on the hosted swap). `keepBackground: false` = **"Use your own setting"** (Edit only). The background photo goes to the pod as the last reference image, labelled "background", after 5 of the model's references. Where it comes from:
  - `locationId` (one of the studio's `/v1/suite/locations`): free;
  - else a location whose name the brief's place mentions: free;
  - else a plate generated from the brief's setting with the Suite's image engine, at its cost × `EDITOR_MARKUP` (about $0.06). It is added to the same estimate and button and held, made and settled before the swap starts (`502 background_failed`, not charged). It is made once per slot and setting, then reused free.

  The response then has `background: {source: "location", locationId, name, matched, usd: 0} | {source: "generated", setting, usd, reused?}`, and the estimate has `swapUsd` and `backgroundUsd` when the plate is paid. **`method: "generate"`**: a new Suite shot from the brief → `{slotId, method: "generate", request: ShotRequest, promptFrom: "brief"\|"summary"\|"default", estimate: ShotEstimate, swapUnavailable?}`. Without a brief, the prompt comes from the reference's summary, else a neutral line (`promptFrom`): suggest writing a brief first. `swapUnavailable` says why the default fell back to generate. `409 swap_unavailable` when `method: "swap"` was asked for and can't run. |
| `POST /v1/recreate/references/{id}/slots/{slotId}/fill {…same body, maxUsd?}` | The caller has confirmed the price; send it as `maxUsd`. If Edit refuses at the last moment, the hosted swap (its own price, at least 4 s) only runs when it fits `maxUsd`. Otherwise `409 price_changed {totalUsd, estimate}`: show the new price, then fill again with it. Swap → `{slotId, method: "swap", segment, job}`. The segment is cut to a private clip under the reference (`rx/…`, deleted with it after 30 days). An ordinary Edit job runs on it, held and priced like any swap: video only (the edit uses the reference's sound), with the creator's burned-in captions removed in the prompt. If Edit isn't available, the hosted swap runs. Generate → `{slotId, method: "generate", job}`, an ordinary Suite shot. The slot records `fill: {jobId}`. |
| `POST /v1/recreate/references/{id}/apply {sessionId, baseRevision?, slots: {slotId: takeId \| jobId}, options?: {camera, speed, text, look}, device?}` | Builds the edit in an edit session (owner) as one undoable change labelled "Recreated “name”". → `{sessionId, revision, durationSec, missing, waiting, notes, label, match, sources}`. See below. |
| `POST /v1/recreate/references/{id}/slots/{slotId}/replace {sessionId, take: takeId \| jobId, baseRevision?, device?}` | **Fix this shot** (plan §4): the slot's clip in the edit built from this reference gets another take, or a finished fill job, in place, as one undoable change ("Replaced shot s2 in “name”"). Its place and length on the timeline, transition, ramp, camera keys and look stay, and the new take starts where its action peak lines up (slower if it is too short). A swapped take is baked instead (see below). The owner's other edits are kept. → `{sessionId, revision, slotId, itemId, takeId, inSec, label, baked?, note?}`. `409 not_built_here` (the edit wasn't built in that session), `409 slot_not_in_edit` (the shot's clip was deleted), `409 job_not_done`. Claude's tool: `replace_slot`. |

**The matcher** scores each of the studio's video takes against a slot, 0–1, with reasons:
- the length;
- the shape;
- the move, framing and angle from the take's draft;
- the lead model;
- kept takes first.

It suggests one take per slot, best first, using each take once. Slots where nothing scores `minScore` (default 0.6) are marked `toGenerate`. Claude or the owner makes the final choice.

**The fill request** builds a Suite shot for a slot:
- the brief becomes the prompt;
- the reference's shape;
- the slot's framing, angle and move;
- whole seconds, at least the tier's minimum, because the clip is cut back to the slot;
- `draft: {tool: "shot", recreate: {slotId}}`.


**Fill state** (`GET …/fill`; `match` keeps its last result, `fill` its jobs):
```
SlotFill { slotId, state: "empty"|"matched"|"to_generate"|"generating"|"ready", takeId?, jobId?, method?: "swap"|"generate", score?, estimate?: {amount, label}, reason?,
  fallback?: "generate", failedJobId? /* a swap that failed (refunded): offer generate, priced on its own */ }
```
- `ready`: the slot's fill job is done (its first take); `generating`: the job is still running; `matched`: the last match's suggestion; `to_generate`: nothing scored enough.
- `applied: {sessionId, revision, at, slots: {slotId: takeId}, sources, match, baked?: {slotId: ["camera","speed","look"]}}` after an apply.
- **Swapped slots are "baked" (G2):** the segment already carries the creator's zoom/shake, speed ramp and grade. So a slot filled by its own swap job gets none of them again. Its clip plays at 1× from the slot's moment in the segment, and keeps only the cut, its length and the transitions. Our editable text goes on top as usual. The apply response and `applied.baked` list those slots. The match score counts their ramp and grade as matched, and the shot as 0.95. `replace` with the slot's swap take bakes the clip (`baked` in the response); replacing a baked clip with an ordinary take brings the reference's camera keys, ramp and look back.

**Match score** (returned by apply as `match`, 0–1): `{overall, cuts, text, ramps, grade, shots, perSlot: [{slotId, score}]}`.
- `cuts`: each cut's distance from the reference's (exact = 1, two frames or more = 0), times the share of slots filled.
- `shots`: per slot, the matcher's score for its take, 0.85 for a shot generated for it, 0.6 for another take, 0 when empty.
- `text`: 1 for read words, 0.6 for "Text"; `ramps`: the share of ramped slots filled; `grade`: 1 − the Look's distance (0 when off or too far).
- `overall` = 0.25 cuts + 0.35 shots + 0.15 text + 0.1 ramps + 0.15 grade.

**Sources:** apply also returns `sources: {itemId: {recipeId, slotId?, transitionAt?, textId?}}`, which recipe element each item came from. They are stored in the op's `meta.sources` for workstream 3's corrections log.

**Applying a recipe:**
- **Values:** each slot's value is a take, or a finished job (its first take is used). A slot whose job hasn't finished is listed in `waiting`.
- **Timing:**
  - The cuts land on the reference's times. A clip with a transition in starts that much early, so each clip is lengthened by half of each neighbouring transition.
  - A take shorter than its slot plays slower to fill it.
- **Transitions:** crossfade → `fade`, fade → `black`, flash → `white`, whip → `whip`, zoom → `zoom`, glitch → `glitch`. Cuts and unknown transitions get none.
- **Speed ramps** become a custom `speedCurve`, and the source range is chosen so the clip still plays for exactly the slot's length.
- **Freezes** (`speed.freeze {t, durationSec}`, from the analysis): the clip plays at the editor's slowest, 0.1×, for the freeze's length at its moment, so the held frame barely moves. The editor has no speed 0. The cuts don't move. Only freezes without a known place are logged as a gap.
- **Action peaks** (plan §3, `options.peaks`, on by default): each take starts where its own strongest action peak, found free with `find_action_peaks`'s detector and cached per take, plays at the moment of the slot's strongest peak. The cuts don't move. A peak that would push the range past the take's end falls back to the next one, else the take starts at 0. A note says where each take starts.
- **Camera moves** become `x`, `y` and `scale` keyframes on a clip scaled up enough that the frame stays covered.
- **Text items** go on a text track. Text whose words weren't read says "Text". A fade or typewriter in and a fade out become the item's `animIn`/`animOut` (length 0.1–2 s), and the matched font its `style.font`.
- **The Look:** the nearest palette's LUT at 0.8, when its distance is under 0.4.
- **Missing slots** are left out and listed in `missing`.
- **Revision:** `baseRevision` must be current (`409` otherwise).
- **Who made it:** from the app it is the owner's change (a reset); from Claude's tool it is Claude's change.

**Claude's tools** (owner only; MCP, in the edit scopes):
- `analyze_reference(uploadId | url, name?)`: free; waits up to a minute; returns the summary, the playbook and `startFrom`.
- `get_recipe(referenceId, contactSheet?)`: returns the contact sheet as an image block.
- `set_slot_briefs(referenceId, slots)`.
- `match_slots(referenceId, modelId?, top?)`.
- `apply_recipe(referenceId, sessionId, slots, options?, baseRevision?)`.
- `fill_slot(referenceId, slotId, modelId, sessionId, quality?, method?, keepBackground?, outfitId?, locationId?, confirm?)`:
  - without `confirm`, it returns the price (`method` swap or generate);
  - with it, the owner is asked in the edit session (pending `kind: "recreate_fill"`), and their yes starts the job at that method and at most that price;
  - Claude then passes the job id to `apply_recipe`.
- `replace_slot(referenceId, slotId, sessionId, take, baseRevision?)`: "Fix this shot", as Claude's change.

- `playbook_read(recipeId?, referenceId?, takeId?, area?)` (edit:read): the learning editor's context (workstream 3, "Learning editor"). It holds the playbook (pinned first, ≤ 25), the 3 nearest proven recipes with their Posts performance, 10 corrections, 8 lessons and 5 gaps.
- `playbook_add(text, area?, evidence?)` (edit:write): Claude's rule arrives unpinned; the owner pins, edits or deletes it.
- `report_gap(key, kind, what, note?)` (edit:write): an effect, transition or font MUSE can't recreate yet, e.g. `effect:lens-flare`.

**Claude follows the playbook** (workstream 1, `src/recreate/playbook.ts`, `test/playbook.test.ts`):
- **Directives.** The owner's *pinned* rules that say one plain, checkable thing become directives. A rule with a qualifier, like "Never put text over her face", is never turned into a blanket ban; Claude gets it in `followYourself` and applies it itself.

  | Pinned rule (examples) | Directive |
  |---|---|
  | "No speed ramps", "Avoid slow-mo", "Keep normal speed" | no new speed curves |
  | "No camera moves", "No zooms", "Keep the camera still" | no new x/y/scale/rotation keyframes |
  | "No text", "Never use captions on my reels" | no new text or caption items |
  | "No looks", "No LUTs", "Keep the natural colours" | no new or changed looks |
  | "Hard cuts only", "No transitions" | no transitions |
  | "Keep transitions under 0.25 s" | transitions at most that long |
- **Every change of Claude's** (`applyClaude`: `apply_edit_ops`, `apply_recipe`, any patch) is checked against the directives, by what it adds or alters. A change that breaks one is refused with `409 playbook_rule`, which names the rule. Changes the owner makes in the apps are never checked.
- **`open_edit`** returns `playbook {note, enforced, followYourself, otherRules, lessons}`. `analyze_reference` returns it too, with `startFrom`.
- **`apply_recipe` / `POST …/apply`:**
  - The directives shape the plan: transitions dropped or shortened, no camera keyframes, no ramps, no text, no Look.
  - For Claude the rules win over its `options`; in the app the owner's explicit `options` win.
  - The response adds `playbook {followed, followYourself}` and `startedFrom {recipeId, name, distance, borrowed[]} | null`.
  - New body fields: `options.transitions`, and `startFrom: recipeId | false`.
- **Starting from a proven recipe.** The nearest of the studio's own posted edits (`origin: "edit"`, at least one post, distance ≤ 0.6) is the default start. When the reference's own look can't be mapped (distance ≥ 0.4), the start recipe's palette grades the edit.
- **Gaps.** What the editor can't rebuild is logged once per reference: `speed:freeze-frame` (only a freeze whose place is unknown), `effect:flash-in-shot` and `effect:glitch-in-shot`. Unknown transitions and unread words are already counted from the recipe's own gaps. Claude logs anything else with `report_gap`.

Applying a recipe stores `meta: {sources}` on the edit op, from Claude or from the app. The owner's later corrections to those items then carry `context.source`.

## MCP & camera sessions (2026-11-05)
_Workstream 2. Owner only: every endpoint below answers `owner_only` (403) to a member. Setup and architecture: `plans/mcp-bridge.md`; research: `plans/research/ai-video-suite-research.md` §3.4._ A **camera session** is the shared workspace of the Camera control's **Directed (Blender)** mode: the brief, the cast, how the camera and each character move over time, the guide renders from Blender, and a Shot **draft**. Three things write to the same session: the MUSE apps (REST below), the in-app "Direct with Claude" chat (server-side Claude with MUSE tools + Blender tools relayed to the owner's Mac), and the owner's own Claude app / Claude Code through the **MUSE MCP server** (`/mcp`). **Agents never spend:** the most any tool does is a Shot draft with a cost estimate; the owner presses Generate in the app.

```ts
CameraStatus  "drafting" | "blocking" | "rendering" | "ready" | "generating" | "done" | "failed"
Aspect        "9:16" | "16:9" | "1:1" | "4:5" | "21:9"
Vec3          [x, y, z]                       // metres, Blender world (Z up, character faces -Y at facingDeg 0)
CamKey        { t: number /* s */, position: Vec3, target?: Vec3 /* look-at */, focalMm?: number /* 8–300 */, rollDeg?: number, ease?: "linear"|"in"|"out"|"in_out" }
CharKey       { t: number, position: Vec3, facingDeg?: number, action?: string /* "walk", "turn to camera", ≤ 80 chars */ }
CameraPath    { keyframes: CamKey[] /* 1–64, t ascending, ≤ durationSec */, cuts?: number[], sensorMm?: number }
Blocking      { characters: { modelId: string, keyframes: CharKey[] /* 1–64 */, note?: string }[] }
CastMember    { modelId, name, role?: string, heightM?: number /* 1.2–2.2, default 1.68 */ }
AssetKind     "greybox" | "depth" | "pose" | "tracks" | "keyframe_start" | "keyframe_mid" | "keyframe_end" | "still" | "preview"
            | "camera_json" | "characters_json" | "blend"
CameraAsset   { id: "ca_…", kind: AssetKind, label?, state: "pending"|"ready", contentType, bytes?, source: "app"|"mcp"|"relay"|"chat",
                url?: string /* presigned GET, 1 h, ready only */, createdAt }
ShotDraft     { id: "sd_…", state: "draft", source: "suite"|"camera", prompt, targetModel, durationSec, aspect,
                estimate: { usd: number, tokens: number }, camera: CameraSpec, createdAt,
                request: ShotRequest /* the suite's ("AI suite"): camera.mode "directed", camera.guide.video.key = the newest greybox,
                                        keyframes = "/uploads/cam/<sessionId>/<assetId>.<ext>" (the suite signs them when the shot runs); the app POSTs it to /v1/suite/shots when the owner presses Generate */,
                warnings?: string[], jobId?: string /* linked render job */, linkedAt?: number }
CameraSpec    { mode: "directed", presets?: {rig?, move?, angle?}, directed: { cameraSessionId,
                guideAssets: Partial<Record<"greybox"|"depth"|"pose"|"tracks"|"keyframeStart"|"keyframeMid"|"keyframeEnd", assetId>>,
                trajectories: { camera?: assetId /* camera_json */, characters?: assetId /* characters_json */ },
                keyframes: CamKey[] } }   // the suite's Shot API owns the full CameraSpec; this is the directed part
CameraMessage { id, role: "user"|"assistant"|"tool", source: "app"|"chat"|"mcp", text, tool?: { name, ok: boolean, summary }, createdAt }
CameraSession { id: "cs_…" /* unguessable */, title, brief, status: CameraStatus, aspect, fps /* 12–60, 24 */, durationSec /* 1–30, 6 */,
                targetModel?: string, presets: { rig?, move?, angle?, intensity? /* 0–1 */ }, characters: CastMember[],
                cameraPath?: CameraPath, blocking?: Blocking, assets: CameraAsset[], shotDraft?: ShotDraft, camera: CameraSpec,
                revision: number /* +1 on every change */, relay: { online: boolean, blender: boolean }, createdAt, updatedAt,
                messages?: CameraMessage[] /* GET one: the last 50 */ }
BlenderCall   { id: "bc_…", sessionId, tool: BlenderTool, args: object, outDir: "CameraSessions/<sessionId>", createdAt, expiresAt }
```

| | |
|---|---|
| `POST /v1/camera-sessions` `{title?, brief?, aspect?, fps?, durationSec?, characters?: [{modelId, role?, heightM?}], presets?}` | → `CameraSession` (`drafting`). Characters must be the studio's, not archived. |
| `GET /v1/camera-sessions` | → `CameraSession[]` (no `messages`), newest first. |
| `GET /v1/camera-sessions/{id}` | → `CameraSession` with the last 50 `messages`. |
| `PATCH /v1/camera-sessions/{id}` `{title?, brief?, status?, aspect?, fps?, durationSec?, targetModel?, presets?, characters?, revision?}` | → `CameraSession`. With `revision`, a session changed since → `stale_revision` (409). |
| `DELETE /v1/camera-sessions/{id}` | → 204 (its files go too). |
| `GET /v1/camera-sessions/{id}/messages?before=<ms>&limit=` | → `CameraMessage[]`, oldest first. |
| `POST /v1/camera-sessions/{id}/messages` `{text}` | → `CameraMessage` (a note from the app; Claude reads it through `get_camera_session`). |
| `POST /v1/camera-sessions/{id}/assets[?source=relay]` `{kind, contentType, bytes?, label?}` | → `{asset, upload: {method: "PUT", url, headers, expiresAt}}` (presigned straight to R2, 1 h; video ≤ 1 GB, images ≤ 50 MB, JSON ≤ 20 MB, `.blend` ≤ 500 MB). |
| `POST /v1/camera-sessions/{id}/assets/{assetId}/confirm` | → `CameraAsset` `ready`. `upload_missing` (409) if the PUT hasn't arrived; `camera_json`/`characters_json` must parse as JSON (`bad_request`). The newest ready asset of a guide kind is the one the CameraSpec points at. |
| `DELETE /v1/camera-sessions/{id}/assets/{assetId}` | → 204. |
| `PUT /v1/camera-sessions/{id}/path` `{camera?: CameraPath, characters?: Blocking["characters"]}` | → `CameraSession` (status moves `drafting` → `blocking`). Every `modelId` must be in the cast. |
| `POST /v1/camera-sessions/{id}/shot-draft` `{prompt?, targetModel?, durationSec?}` | → `ShotDraft`. Estimate only: no hold, no ledger row, no provider call. With the AI suite merged it is `ctx.suite.estimate(ShotRequest)` (same as `POST /v1/suite/shots/estimate`); without it, a local draft priced from the target model's $/s. Ready guide videos and stills are also recorded in `uploads` (kind `output`), because the suite only takes references it knows. |
| `POST /v1/camera-sessions/{id}/shot-draft/job` `{jobId}` | → `CameraSession`. After the owner presses Generate (`POST /v1/suite/shots` with the draft's `request`), the app links the render job: status `generating`, then `done`/`failed` as the job ends (checked when the session is read). `no_draft` (409) without a draft; `bad_request` for a job of another studio. |
| `POST /v1/camera-sessions/{id}/chat` `{message}` | → `text/event-stream` of `ChatEvent` (below). One turn at a time per session (`chat_busy`, 409); `director_unavailable` (503) without `ANTHROPIC_API_KEY`. |
| `GET /v1/mcp/tokens` | → `[{id, name, prefix, createdAt, lastUsedAt?, expiresAt?}]` |
| `POST /v1/mcp/tokens` `{name, expiresDays?: 1–365}` | → `{id, name, prefix, token /* "muse_pat_…", shown once */, createdAt, expiresAt?}` |
| `DELETE /v1/mcp/tokens/{id}` | → 204 (revoked at once). |
| `POST /v1/blender/relay` `{online: boolean, blender: {connected: boolean, addonVersion?, protocol?}}` | Mac heartbeat (every 20 s; offline after 45 s). → `{ok: true, pending: BlenderCall[]}` |
| `GET /v1/blender/calls` | → `BlenderCall[]` waiting for a Mac (catch-up after reconnecting). |
| `POST /v1/blender/calls/{id}/claim` | → `BlenderCall` with a fresh `expiresAt` (5 min; 15 min for `blender_render_guides`). Only one Mac runs a call: `already_claimed` (409), `call_expired` (410). |
| `POST /v1/blender/calls/{id}/result` `{ok, result?: object, error?: string, assetIds?: string[]}` | → 204. Results ≤ 256 KB; images travel as session assets (`preview`), never inline. |

**ChatEvent** (one `data: <json>` per event): `{type: "text", delta}` · `{type: "tool", id, name, status: "running"|"done"|"error", summary?}` · `{type: "waiting", reason: "blender"}` (a Blender call is out to the Mac) · `{type: "message", message: CameraMessage}` · `{type: "done", stopReason, usage: {inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}}` · `{type: "error", code, error}`. The turn keeps running if the app disconnects; the transcript and `camera` events carry the result.

**Live events** (owners' devices only): `camera` `{op: "upsert", session}` (no messages) / `{op: "delete", id}` / `{op: "message", sessionId, message}` / `{op: "asset", sessionId, asset}`; `blender` `{op: "call", call: BlenderCall}` / `{op: "cancel", id}` / `{op: "relay", online, blender}`.

**Blender tools** (`BlenderTool`; relayed to the owner's Mac, which runs each as a fixed MUSE script through the Blender add-on's `execute_code`, or a native add-on command; arguments are data, never code; free-form Python is not offered in the in-app chat):

| Tool | Args | Does |
|---|---|---|
| `blender_status` | — | `{connected, addonVersion, scene}` (add-on `ping` + `get_scene_info`) |
| `blender_scene_info` | — | add-on `get_scene_info` |
| `blender_screenshot` | `{maxSize?: 256–1600}` | viewport PNG → uploaded as a `preview` asset → `{assetIds}`; the chat shows it to Claude as an image |
| `blender_setup_scene` | `{fps, durationSec, aspect, resolutionShort?: 480–1080, clear?: boolean}` | frame range, resolution, flat grey floor `MUSE_floor`; `clear` deletes only objects named `MUSE_*` |
| `blender_place_character` | `{modelId, label, heightM, position, facingDeg?}` | grey proxy `MUSE_char_<modelId>` scaled to the height |
| `blender_animate_character` | `{modelId, keyframes: CharKey[]}` | location/rotation keys on the proxy |
| `blender_add_prop` | `{id, shape: "box"|"cylinder"|"sphere"|"plane", size: Vec3, position, rotationDeg?: Vec3}` | `MUSE_prop_<id>` |
| `blender_set_camera` | `CameraPath` (`cuts` = hard cuts; two keys at the same `t` also cut) | camera `MUSE_camera` with keys (look-at via `target`), made the scene camera |
| `blender_render_guides` | `{passes: ("greybox"|"keyframes"|"camera_json"|"characters_json")[], resolutionShort?}` | Workbench flat-grey playblast `greybox.mp4`, start/mid/end stills, per-frame `camera.json` and `characters.json`, written to `~/MUSE/CameraSessions/<sessionId>/out/`; the Mac uploads each as a session asset → `{assetIds}` |

**MCP server** — `POST /mcp` (Streamable HTTP, JSON-RPC 2.0, JSON responses, stateless; `GET`/`DELETE /mcp` → 405). Auth: `Authorization: Bearer muse_pat_…` (owner personal access token) — a missing or bad token gets 401 with `WWW-Authenticate: Bearer resource_metadata="<base>/.well-known/oauth-protected-resource"`; a member's token is refused. Methods: `initialize` (protocol versions `2026-07-28`, `2025-11-25`, `2025-06-18`, `2025-03-26`), `ping`, `tools/list`, `tools/call`, `resources/list`, `resources/read` (`muse://camera-session/{id}`), notifications are accepted with 202. Tools: `list_characters`, `list_camera_sessions`, `create_camera_session`, `get_camera_session`, `update_camera_session`, `post_camera_message`, `attach_guide_media` (→ presigned PUT), `confirm_guide_media`, `set_camera_path`, `list_presets`, `create_shot_draft` (estimate only). Tool errors come back as `isError: true` results; protocol errors as JSON-RPC errors.

| code | status | when |
|---|---|---|
| `stale_revision` | 409 | `PATCH` with an old `revision` |
| `upload_missing` | 409 | confirm before the PUT arrived |
| `chat_busy` | 409 | a chat turn is already running on that session |
| `director_unavailable` | 503 | no `ANTHROPIC_API_KEY` on the server |
| `no_draft` | 409 | linking a job to a session without a Shot draft |
| `already_claimed` / `call_expired` | 409 / 410 | Blender call taken by another Mac / timed out (5 min) |

## Claude on the owner's plan: OAuth, chat threads, Mac runner (2026-11-06)
_Workstream 2. Spec: `plans/claude-editing.md` parts B–E. Owner only (members get `owner_only`)._

### OAuth 2.1 for `/mcp` (claude.ai custom connector, Claude Code)
- `GET /.well-known/oauth-protected-resource` (RFC 9728): `{resource: <base>/mcp, authorization_servers: [<base>], scopes_supported, bearer_methods_supported: ["header"]}`.
- `GET /.well-known/oauth-authorization-server` (RFC 8414): issuer `<base>`, `/oauth/authorize`, `/oauth/token`, `/oauth/register`, `/oauth/revoke`, `code_challenge_methods_supported: ["S256"]`, `grant_types_supported: ["authorization_code", "refresh_token"]`, `token_endpoint_auth_methods_supported: ["none"]`, `client_id_metadata_document_supported: true`.
- **Clients:**
  - **Client ID Metadata Document:** `client_id` is an https URL whose JSON lists `client_id` (equal to the URL) and `redirect_uris`. It is fetched with a 5 s timeout, at most 64 KB, public hosts only.
  - **Dynamic registration:** `POST /oauth/register` `{redirect_uris, client_name?}` → `{client_id, client_id_issued_at, redirect_uris, token_endpoint_auth_method: "none"}`.
  - **Allowed redirects:** `https://claude.ai/api/mcp/auth_callback`, `https://claude.com/api/mcp/auth_callback`, loopback `http://localhost:<port>/…` and `http://127.0.0.1:<port>/…` (Claude Code), plus `OAUTH_EXTRA_REDIRECTS`.
- **`GET /oauth/authorize`:**
  - Parameters: `response_type=code`, `client_id`, `redirect_uri`, `code_challenge` (S256 only), `state`, `scope?`, `resource` (must be `<base>/mcp`).
  - It shows MUSE's sign-in + consent page (owner email and password; the scopes in words).
  - `POST /oauth/authorize` → 302 `redirect_uri?code&state&iss`. A member gets the page "Only the studio owner can connect Claude".
  - Codes are single use, valid for 10 min, and bound to the client, redirect, challenge, resource and scopes.
- **`POST /oauth/token`** (form-encoded):
  - `grant_type=authorization_code` with `code`, `redirect_uri`, `client_id`, `code_verifier`, `resource`.
  - `grant_type=refresh_token` with `refresh_token`, `client_id`, `resource?`. Refresh tokens rotate; reusing a used one revokes the whole family.
  - → `{access_token: "muse_oat_…", token_type: "Bearer", expires_in: 3600, refresh_token: "muse_ort_…" /* 30 days */, scope}`.
  - Errors are RFC 6749 `{error, error_description}`.
- **`POST /oauth/revoke`** `token=` → 200.
- **Scopes:** `camera:read camera:write edit:read edit:write cast:read assets:write generate:estimate`. No `generate:run`. A missing `scope` means all of them.
  - `/mcp` accepts personal tokens (every scope) and OAuth access tokens whose audience is `<base>/mcp` (a token for another audience → 401).
  - `tools/list` shows only the tools the token's scopes allow. Calling another tool → `isError` `insufficient_scope`.
- **Owner grants:** `GET /v1/mcp/grants` → `[{id, clientName, clientId, scopes, createdAt, lastUsedAt?}]`; `DELETE /v1/mcp/grants/{id}` revokes that grant's tokens.
- **Mac app's own token:** `POST /v1/mcp/session-token` `{ttlMinutes?: 5–720, default 240}` → `{token: "muse_oat_…", expiresAt, mcpUrl}`, an owner access token with every scope for the local Claude Code's `--mcp-config`.

### Claude chat threads (one per camera or edit session; Mac runs Claude Code, the phone relays)
```ts
ClaudeThread  { id: "ct_…", contextKind: "camera"|"edit"|"recreate", contextId, claudeSessionId?: string /* Claude Code session for --resume, set by the Mac */, createdAt, updatedAt,
                brief?: { prompt, tools: string[], referenceId? | sessionId? } /* recreate and edit threads (workstream 1): what Claude on the Mac starts from */ }
ClaudeMessage { id, threadId, role: "user"|"assistant"|"tool", source: "mac"|"phone"|"api", text, turnId?,
                tool?: { id, name, ok?: boolean, summary?: string }, image?: { url } /* a frame Claude grabbed */, createdAt }
ClaudeTurn    { id: "tu_…", threadId, text, from: "phone"|"mac", state: "queued"|"running"|"done"|"failed"|"stopped", error?, createdAt, claimedAt?, finishedAt? }
ClaudeEvent   = { type: "user", text } | { type: "text", delta } | { type: "assistant", text }
              | { type: "tool", id, name, status: "running"|"done"|"error", summary?, input? }
              | { type: "image", data /* base64 ≤ 2 MB */, mimeType: "image/png"|"image/jpeg" }
              | { type: "done", ok: boolean, error?, model? /* owner only */ }
ClaudeStatus  { mac: { online: boolean, claudeCode: { installed: boolean, signedIn: boolean, version?, model? }, answeringTurn?: string },
                apiFallback: { available: boolean /* ANTHROPIC_API_KEY set */, enabled: boolean }, connectorUrl /* <base>/mcp */, openInClaudeUrl }
```
| | |
|---|---|
| `GET /v1/claude/status` | → `ClaudeStatus` |
| `PATCH /v1/claude/settings` `{apiFallback: boolean}` | → `ClaudeStatus`. The fallback is off by default and billed per use. |
| `POST /v1/claude/mac/heartbeat` `{claudeCode: {installed, signedIn, version?, model?}}` | From the Mac app, every 20 s. The Mac counts as offline after 45 s. → `{ok, pending: ClaudeTurn[]}` |
| `POST /v1/claude/threads` `{contextKind, contextId}` | Get or create. → `ClaudeThread`. A camera `contextId` must be one of the owner's sessions; a `recreate` one must be one of their references (`rx_…`), else `404`. Recreate and Edit threads carry a `brief`: the role, the MUSE MCP tools for that screen and the id they act on. The Mac seeds its Claude Code with it. |
| `GET /v1/claude/threads/{id}` | → `ClaudeThread & {messages: ClaudeMessage[] /* last 100, oldest first */, activeTurn?: ClaudeTurn}` |
| `PATCH /v1/claude/threads/{id}` `{claudeSessionId}` | The Mac stores Claude Code's session id. |
| `POST /v1/claude/threads/{id}/messages` `{text}` | From a device that can't run Claude (the phone).<ul><li>→ 202 `{message, turn}`: the turn is queued for the Mac, which gets a `claude` `{op: "turn"}` event.</li><li>`mac_offline` (409) with `{fallback: {openInClaudeUrl, apiFallback: boolean}}`.</li><li>`claude_busy` (409) while a turn on that thread is queued or running.</li></ul> |
| `GET /v1/claude/turns` | Queued turns for the Mac (catch-up). |
| `POST /v1/claude/turns/{id}/claim` | → `ClaudeTurn` (`running`). `already_claimed` (409), `turn_expired` (410). |
| `POST /v1/claude/turns/{id}/stop` | The phone's Stop. Emits `claude` `{op: "stop", turnId}`; the Mac interrupts and sends `done`. |
| `POST /v1/claude/threads/{id}/events` `{turnId?, events: ClaudeEvent[]}` | The Mac mirrors its local Claude Code stream (its own turns, without `turnId`, and claimed ones). `user`, `assistant`, `tool` and `image` events are stored as messages; `text` deltas are only relayed live. `done` ends the turn. ≤ 4 MB. |
| `POST /v1/claude/threads/{id}/api-turn` `{text}` | The fallback when it is on and the key is set. It streams `ChatEvent`s like the camera chat. Camera threads run the director. Recreate and Edit threads run MUSE's editor loop (workstream 1, `src/recreate/assistant.ts`) with the Recreate tools (plus open_edit, get_edit, apply_edit_ops, undo_edit, get_frame, list_takes) or the Edit tools. The thread's reference or session is filled in. Paid steps keep their approval: `fill_slot` and the paid helpers only price, or ask the owner in the app. Each turn rebuilds the conversation from the thread's text. |

**Timeouts:** a queued turn not claimed within 90 s fails with "Your Mac didn't pick this up". A running turn that sends nothing for 10 min fails.

**Live events** (owners' devices): `claude` with one of:
- `{op: "thread", thread}`
- `{op: "message", threadId, message}`
- `{op: "event", threadId, turnId?, event}` (streaming text and tool progress)
- `{op: "turn", turn}`
- `{op: "stop", turnId}`
- `{op: "status", status}`

| code | status | when |
|---|---|---|
| `mac_offline` | 409 | a phone message while the Mac with Claude Code isn't online and ready |
| `claude_busy` | 409 | a turn on that thread is already queued or running |
| `turn_expired` | 410 | claiming a turn that timed out |
| `fallback_off` | 409 | `api-turn` while the API fallback is off or no key is set |

## Bring your own provider (WS5, 2026-11-08, owner-approved)
In Settings, the owner adds an API key for a provider. MUSE lists that provider's models, the owner switches on the ones they want and names them, and enabled models appear in the AI Suite like built-in ones. Code: `server/api/src/byo/**`, routes `src/routes/providers.ts`, migration **0023_byo_providers**, tests `test/byo.test.ts` (recorded fixtures in `test/fixtures/byo`; no live provider calls).

**Providers.** Replicate and fal.ai, both of which publish machine-readable input schemas. Each provider is an adapter (`byo/adapters.ts` `ProviderAdapter`): validate a key, search models, read one model, start/get/cancel a run. More can be added later (e.g. OpenAI-compatible image endpoints) by implementing that interface.

**Keys.** A key is checked with one free read-only call before it is stored: Replicate `GET /v1/account`, fal `GET /v1/models/pricing`. It is stored AES-256-GCM encrypted with `PROVIDER_KEYS_SECRET` (32 bytes, 64 hex characters or base64), bound to its row. Without the secret, the server fails closed: 503 `provider_keys_unavailable`, and custom models don't run. A key is never returned, logged or printed; the API shows `keyLast4` and `status` only. Provider calls happen on the server only. A key is sent only to its provider's own host. A fal status URL on another host is replaced by the documented one.

**Reading a model** (`byo/classify.ts`). Each input field is matched to a role: prompt, negative prompt, start/end frame, reference images (a list, or one image for image models), duration (number, integer or string enum), aspect ratio, resolution, seed, sound switch, width/height. The kind (image or video) comes from fal's category, the output schema, then the inputs and description. A required field with no role and no default makes the model `needs_setup` until the owner gives it a fixed value (`fixedInputs`). Only fields in the schema are ever sent.

### Endpoints (owner only; members get 403 `owner_only`)
| | |
|---|---|
| `GET /v1/providers/kinds` | `{kinds:[{kind, label, keyHint, keyUrl}], keysReady}` |
| `GET /v1/providers` | `{providers: Provider[], keysReady}` |
| `POST /v1/providers {kind:'replicate'\|'fal', apiKey, label?}` | 201 `Provider`. Errors: 400 `invalid_key` (nothing stored), 502 `provider_unreachable`, 503 `provider_keys_unavailable`. At most 10 per studio. |
| `PATCH /v1/providers/:id {label?, apiKey?}` | `Provider`. A new key is validated again. |
| `DELETE /v1/providers/:id` | 204. Its models are removed and leave the Suite. |
| `GET /v1/providers/:id/models?q=&kind=image\|video&cursor=&limit=` | `{models: CatalogModel[], nextCursor}`. Cached for 10 min per query; limit ≤ 50. Replicate: search (or its text-to-video / image-to-video / text-to-image collections when `q` is empty). fal: model list with schemas plus prices. |
| `POST /v1/providers/:id/models {ref, displayName?}` | 201 `CustomModel`, added switched off. Adding the same ref again returns the existing model. |
| `GET /v1/providers/models` | `{models: CustomModel[]}` (all providers) |
| `PATCH /v1/providers/models/:id {enabled?, displayName?, members?, price?, priceScale?, kind?, fixedInputs?}` | `CustomModel`. `enabled:true` returns 409 `needs_setup` while `missing` isn't empty, and 400 `price_required` with no price. |
| `DELETE /v1/providers/models/:id` | 204 |

- `Provider` = `{id, kind, label, keyLast4:'…a1b2', status:'ok'|'invalid', checkedAt, createdAt, models:{added, enabled}}`. A key the provider refuses during a run sets `status:'invalid'`.
- `CatalogModel` = `{ref, name, description, kind:'image'|'video'|null, inputs: Inputs, missing:[field], ready, price: Price|null, added:{id, enabled}|null}`.
- `Inputs` = `{prompt, negativePrompt, startImage, endImage, referenceImages:n, duration:{min,max,allowed?}|null, aspectRatios:[], resolutions:[], seed}`.
- `Price` = `{basis:'per_run'|'per_second', costUsd, source:'provider'|'owner'}`.
- `CustomModel` = `{id:'c_…', providerId, providerKind, ref, providerName, displayName, kind, enabled, members, status:'ready'|'needs_setup', missing, inputs, fields, fixedInputs, price, priceScale, memberPrice:{basis, usd}|null, createdAt, updatedAt}`.

### Pricing and spend
- **Cost basis:** the provider's own price where it publishes one. fal publishes it (unit `second` → per second; `image`/`video`/`request` → per run). Replicate's API has no prices, so the owner enters a per-run (or per-second) estimate, editable any time; owner prices are capped at $50.
- **Member price:** cost × `priceScale`, the Suite's per-model markup (0.5–3, default 1), set on the custom model.
- **Video:** a per-second price is the model's `perSec`; a per-run price is a fixed amount per take (`extraPerTake`).
- **Photo:** priced per photo.
- **Spend:** every run goes through the normal Suite estimate → confirm → hold → settle, and the suite and wallet daily caps. Test mode (`SUITE_MODE=mock`) runs custom models on the test renderer and calls no provider.

### In the Suite
- **Catalog:** `GET /v1/suite/catalog` adds `custom: [{id, name, kind, price:{basis, usd}, inputs: InputSlots, minSeconds, maxSeconds, aspectRatios}]`. The owner sees every enabled model, plus `members` and `provider`. Members see only models marked `members: true`, by the owner's display name, with no provider, ref or field names.
- **Video:** `POST /v1/suite/shots/estimate` and `/v1/suite/shots` take `engineModel:'c_…'`. Members may pass it for a model available to them; built-in `engineModel`s stay owner-only. Custom models make plain shots: text, keyframe or reference, not swap, recast or extend. The owner can also put custom ids on the tier ladders in `/v1/suite/settings`.
- **Photo:** `POST /v1/suite/photos/estimate` and `/v1/suite/photos` take `engineModel:'c_…'` (an image model). It replaces the studio's image engine for that run. References go in the model's own image field, up to its limit.
