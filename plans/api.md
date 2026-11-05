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
- **Upscale** (SeedVR2 on the add-on engine, not built yet): sizes 1080p = 1080×1920, 2K = 1440×2560, 4K = 2160×3840. Today `addons[upscale].available = false`, `comingSoon: true`, every size `available: false`, `price: null`. Apps show an "Upscale" entry on a **finished render take** (`kind: "take"` with a `videoUrl`) with the three sizes greyed and "Coming soon". `POST /v1/takes/{id}/upscale {size: "1080p"|"2k"|"4k"}` → `409 upscale_unavailable` ("Upscale is coming soon") until it ships; then it returns a `Job` (`request.engine: "upscale"`, `request.takeId`, `request.size`, `engineLabel: "Upscale · 2K"`) priced from measured times.
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
- Known defaults keep their tested inputs (FLUX.2 [pro] `safety_tolerance` 2 and "1 MP"/"2 MP"; Qwen `match_input_image`).

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

## Types

```ts
ImageRef   { asset?: string, url?: string }          // asset = bundled sample key ("g_front"); url = loadable image (relative "/uploads/x" is resolved against the base)
User       { id, studioName, email }
SheetSlot  { key: "face"|"profile"|"front"|"tq"|"side"|"back"|"faceTq" /* 2026-11-04 */, image: ImageRef|null, source: "upload"|"generated", busy: boolean }
Model      { id, name, age (18–70), niche, look, neverAdd: string[], slots: SheetSlot[7] /* 6 before 2026-11-04, see "Model tools" §1 */, outfitIds: string[],
             archived?: boolean, archivedAt?: number /* "Model tools" §7 */ }
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
Take       { id, kind: "take"|"shot", jobId|null, index, of, title, label, engineLabel, cost, seed, status: "test"|"final", thumb, prompt, createdAt,
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
ApiEvent   { type: "job"|"take"|"balance"|"wallet"|"model"|"outfit"|"lora"|"post"|"gpu"|"tool"|"template"|"clip"|"settings"|"member"|"invite"|"studio"|"account",
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
// Take (photoshoot stills) also carries: templateId?, templateName?, shuffleSeed?, variation?: VariationDraw (template owner only).
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
| `POST /v1/models/{id}/accounts/{platform}/connect` | → `ConnectResponse`. The real backend returns `{ authUrl }` (OAuth). The mock signs in after a short delay (≤ 0.9 s) and returns `{ account }`. Handles come from the model's name (`@demo.model`, `Demo model` on YouTube, `Demo model (Page)` on Facebook). |
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
| `PATCH /v1/settings/studio` `{maxGpus?, overheadPayer?, capPerJob?, capPerDay?, capPerUserDay?, warmGpuAllowed?, warmIdleMinutes? (5–120), warmMaxMinutes? (30–480)}` (owner) | → same |

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
| `take` `{take}` / `{op: "delete", id}` | Photoshoot and template-shoot stills, video takes when a job finishes, `PATCH /v1/takes/{id}`, `DELETE /v1/takes/{id}` | Everyone in the studio, each with the prompt *they* may see (a template's hidden layers only to its owner) |
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
