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
| `engine_unavailable` | 400 | the GPU image can't run this yet (Fast · beta, LoRA training, or lip sync without LatentSync) |
| `image_engine_failed` | 502 | the image engine failed (the charge is refunded) |
| `rate_limited` | 429 | too many sign-in or sign-up tries |

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
JobRequest { title, modelId, outfitId, clipId, engine: "h3"|"viggle", steps (4–30, default 10), use: "first"|"full",
             takes (1–4), keepAudio, lipSync, background: "keep"|"photo", backgroundMotion: "still"|"subtle"|"busy", clipSeconds?,
             queue?: boolean /* true = park it as "queued", not charged, until POST /v1/queue/run */ }
Job        { id, title, modelId, modelName, outfitId, request: JobRequest, state: "queued"|"running"|"done"|"failed",
             progress (0–100), take, step, totalSteps, phase /* "step 12/20 · ~6 min left" */, secondsLeft, totalSeconds,
             cost, refunded, error?, createdAt, finishedAt?, prompt /* exact H3 prompt */, seed, thumb: ImageRef,
             queuePosition?, etaSeconds? /* while waiting for a GPU */, blocked?: "owner_balance_low", warmupCost? /* GPU warm-up charged with it */ }
Take       { id, kind: "take"|"shot", jobId|null, index, of, title, label, engineLabel, cost, seed, status: "test"|"final", thumb, prompt, createdAt,
             videoUrl?, durationSec?, width?, height? /* real output: renders are 768×1344 */ }
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
ApiEvent   { type: "job"|"balance"|"model"|"outfit"|"lora"|"post"|"wallet", job?, balance?, model?, outfit?, lora?, post?, takes?: Take[],
             wallet?: Wallet, notice?: { code: "owner_balance_low"|"owner_balance_ok", message } }
             // balance and wallet events go only to the user they concern (and to owners, whose pool moved too).
// Model also carries optional { personality, notes }.
ConnectResponse { authUrl?: string /* real backend: open it for OAuth */, account?: Account /* mock: signed in already */ }
```

## Pricing (the same in every client and the server)

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
| `GET /v1/settings/image-engine` | → `{provider: "simulated"\|"fal"\|"custom-http", model, url?, available: {simulated, fal, "custom-http"}}` |
| `PATCH /v1/settings/image-engine` `{provider, model?, url?}` | → same. Per studio. `custom-http` is owner-only and needs an https URL. Shoots and outfit sets also take `imageEngine: {provider, model?}` to override it for one call. |
| `GET /v1/settings/studio` | → `{maxGpus, overheadPayer: "user"\|"owner", capPerJob, capPerDay, capPerUserDay, tokenUsd, minRunpodBalance, lowBalance, features: {standard, fastBeta, lipSync, loraTraining, replaceAudio: false, outputSize: {width: 768, height: 1344}, maxClipSec}, gpu}` |
| `PATCH /v1/settings/studio` `{maxGpus?, overheadPayer?, capPerJob?, capPerDay?, capPerUserDay?}` (owner) | → same |

"Replace audio" isn't wired on the GPU yet: `keepAudio: false` gives a silent take, and `features.replaceAudio` is false.

### Live events
`GET /v1/events` is a `text/event-stream`. Each message is `data: <ApiEvent JSON>`. While a job runs, `job` events arrive about every 250 ms (`progress`, `step`, `phase`, `secondsLeft`). `lora` events carry training progress (about every 250 ms) and the `building` → `review` change. `post` events carry `handoff`/`posted` changes. When the job finishes, a `job` event arrives with `state: "done"` and its new `takes`, or with `state: "failed"`, `error` and `refunded`. Each failure is followed by a `balance` event. Clients reconnect with backoff. The Android app turns finished and failed jobs into local notifications. A real backend can add FCM push behind the same events.

### Developer (mock, and the real API only with `DEV_MODE=true`)
| | |
|---|---|
| `POST /v1/dev/fail-next` `{failNext}` | The next job fails at step 3 and is refunded. |
| `POST /v1/dev/reset` | Restores the seed data. |
| `GET /health` | `{ok, speed}` |

## Notes for the real backend
- Run the H3 Ref2VA pipeline (`pipeline/runpod/h3_ref2va_run.py`) on a network-volume pod, map the denoising step callback to `step`, and shut the pod down when the queue is empty.
- Build the prompt with the layered engine (`plans/prompt-system.md`, implemented in `android/core/.../PromptEngine.kt`) and store the exact prompt, seed, steps and references on the job.
- Show "MiniMax H3" attribution and pass through its licence and acceptable use terms.
