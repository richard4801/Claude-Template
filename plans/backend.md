# MUSE backend (spec)

_Started 2026-11-04._ This is the real server that the Android and Mac apps talk to. It replaces the mock while keeping the same contract (`plans/api.md`), so the apps switch over by changing the base URL and signing in.

## Decisions (2026-11-04)
- **Users:** login for a small **invite-only** group, about 3 testers to start. They share one studio: the same models, outfits, gallery and posts. Every row is still scoped to a `studioId` and every action records its `userId`, so separate studios and client accounts (Phase 2) need no rebuild.
- **Balance:** this is the **real RunPod credit**, read from the RunPod API. There are no in-app payments yet. Each user has a **token wallet** funded by the owner (see Money). The server enforces the spend caps: per job, per day, and per user per day.
- **Photo model:** a **pluggable image engine**. The server exposes one image-generation interface with provider adapters. The engine is chosen per studio in the app's Settings, and a call can override it. Adapters:
  - `fal` (hosted models such as Seedream or Nano Banana; the model id is configurable)
  - `custom-http` (any endpoint that follows our small contract below)
  - `runpod-selfhosted` (later)
- **Hosting:** **Railway** runs the API and Postgres. **Cloudflare R2** (S3-compatible) holds uploads and renders. **RunPod** runs the GPU work: H3 on an H100 with a network volume, started on demand and shut down when idle.

## Parts
| Part | Where | What |
|---|---|---|
| API | `server/api/` (Node 22, TypeScript, Fastify, Postgres via Drizzle, S3 SDK for R2) | Auth and invites, studios, models/sheets, outfits, clips (+ checks), jobs/takes, shoots, LoRA, accounts/posts, balance/caps, SSE `/v1/events`, image engine |
| GPU controller | inside the API (`server/api/src/gpu/`) | One pod per user on the RunPod GraphQL API with the shared network volume, warm-pod reuse, up to `MAX_GPUS`, idle shutdown (3 min), heartbeats, warm-up charges and refunds in the ledger |
| GPU worker | `gpu/worker/` (Python, runs on the pod) | Pulls jobs from the API, downloads inputs from R2, runs `pipeline/runpod/h3_ref2va_run.py` (FA3, 10 steps by default), reports step progress, uploads the result to R2, reports done or failed |
| Prompt engine | `server/api/src/prompt/` | A TypeScript port of the layered engine (`plans/prompt-system.md`), checked against the same fixtures as the Kotlin and Swift ports |

## GPU controller (one GPU per user)
_Decided 2026-11-04. This replaced an earlier "fair queue, scale up after 60 s" design._
- **One pod per user.** When a user's job is waiting and they have no pod, the controller starts a dedicated pod for them right away (same owner RunPod key, same network volume). Their own jobs run on it in FIFO order, so different users never wait on each other.
- **Warm reuse.** If another user's pod is idle and warm (no job, model loaded) and has the right GPU type, the controller hands it to the new user instead of paying for a cold start. Each pod keeps an `assignedUserId` that can change while it's idle.
- **Cap.** At most `MAX_GPUS` pods (default 3; the owner can change it with `PATCH /v1/settings/studio {maxGpus}`). Over the cap, a job waits for the next free pod and reports `queuePosition` and `etaSeconds`.
- **Idle shutdown.** A pod is terminated `IDLE_SHUTDOWN_SECONDS` (default 180) after its last job. The models are on the network volume and outputs in R2, so nothing on the pod is kept, and a stopped pod would still bill for its disk.
- **GPU type per engine** (`GPU_TABLE`, best first; a pod only takes jobs its GPU is listed for):

  | Job | GPU types, in order |
  |---|---|
  | Standard (H3) | H100 80GB HBM3, H100 NVL, H100 PCIe, H200 NVL, H200 |
  | Fast · beta (Viggle) | H200 NVL, H200 (it peaked at 90.7 GB of VRAM in testing) |
  | LoRA training | H100 80GB HBM3, H100 NVL, H200 NVL, H200 |

  If no GPU in the list is available, the job stays queued, the owner's settings show `noGpu`, and the controller retries after 60 s.
- **What the pod image can do** (`RUNPOD_WORKER_CAPABILITIES`, default `h3,latentsync`). Jobs that need something else are refused when they're submitted (`engine_unavailable`), so no GPU is started for them. Today that means Viggle (it needs an H200 image) and LoRA training (not wired yet). Lip sync is an h3 post-pass that needs `latentsync`, and those jobs only go to pods that advertise it.
- **Low RunPod balance.** When the RunPod balance can't cover the work in flight plus `RUNPOD_MIN_BALANCE_USD` (default $2), no new jobs start for anyone, including members who still have tokens. Waiting jobs show `blocked: "owner_balance_low"` with the phase "Paused: the studio's GPU credit is low". Owners get a `wallet` event with `notice: {code: "owner_balance_low", message: "RunPod balance low: top up to resume"}`. Jobs resume by themselves when the balance recovers, and a `owner_balance_ok` notice follows.
- **Heartbeats.** If a pod's heartbeats stop for 60 s, its job fails (retryable), the hold is released, and the pod is terminated. A pod that never reports in within `POD_BOOT_TIMEOUT_SEC` (15 min) is terminated.
- **Simulated mode** (`GPU_MODE=simulated`, the default) uses the same pod logic with free virtual pods, and renders at `SPEED`× real time like the mock.

## Worker protocol (API ⇄ GPU worker)
The worker authenticates with `Authorization: Bearer <WORKER_TOKEN>`. Each pod gets its own token, issued at pod start and passed in the pod's env together with `MUSE_API_URL` and `POD_ID`. The token dies with the pod. The optional static `WORKER_TOKEN` server variable lets a worker run by hand for dev; it may take anyone's job. Optional fields may be omitted; the API never requires `null`.
- `POST /worker/v1/claim` `{podId, gpu, capabilities: ["h3","latentsync","viggle","lora-train"]}` → `204` (nothing to do) or:
  ```
  {job: {id, kind: "h3"|"viggle"|"lora-train", prompt, seed, steps,
         params, inputs: [{name, url /* presigned R2 GET */, bytes, sha256}],
         outputs: [{name, uploadUrl /* presigned R2 PUT */, contentType}]}}
  ```
  - **Render (`h3`/`viggle`).** Inputs are `source.mp4` and then `image_1.jpg` to `image_n.jpg` (n ≤ 6). The order is face front, face profile, then the selected outfit set's front, ¾ and back if it has them, otherwise the body front, ¾ and back slots. That's the 5-image setup that was tested; 10 references are untested for VRAM and time. `<Image n>` in the prompt matches `image_n.jpg`.
  - `params` = `{engine, takes, seeds[], use, lengthSec, clipSeconds, keepAudio, audioMode, audioSource: "source", lipSync, background, backgroundMotion, lora, source: "source.mp4", references: ["image_1.jpg", …], referenceLabels, sourceInfo}`. Outputs are `take_1.mp4` … `take_n.mp4`.
  - **Lip sync** is `params.lipSync: true` on an h3 job (a post-pass), not a separate kind.
  - **`lora-train`.** Inputs are `train_01.jpg`… (the kept shots) plus `ref_<slot>.jpg`. `params` = `{token, version, rank, photoMinutes, videoMinutes, captions}`. Outputs are `lora_photo.safetensors` and `lora_video.safetensors`.
  - A worker that restarts mid-job gets the same job again on its next claim.
- `POST /worker/v1/jobs/{id}/progress` `{step, totalSteps, phase?, etaSeconds?, take?, takes?}` → `204`. Sent at most twice a second and forwarded to the apps as `job` events. **Cancellation:** if the job was deleted or has ended, the answer is `409 {code: "job_cancelled"}`; stop at the next step.
- `POST /worker/v1/jobs/{id}/done` `{outputs: [{name, bytes?, sha256?, width?, height?, fps?, durationSec?, contentType?}], gpuSeconds, stats?: {load_s, gen_s, step_times_s, peak_vram_gb, attention}}`. The API checks that each reported output exists in R2 (`400 output_missing` otherwise). It stores `stats` on the job, and stores each take's real `width`, `height` and `durationSec`. Renders are always 768×1344, and `use: "full"` is capped at 15 s and trimmed to 17n+5 frames, so `durationSec` here is the truth.
- `POST /worker/v1/jobs/{id}/failed` `{error, retryable}`. The hold is released in full, and the apps get a failed event and then a balance event.
- `POST /worker/v1/heartbeat` `{podId, busy, jobId?, state?: "idle"|"loading"|<phase>|"stopping"}` every 15 s.
- **Billing.** `gpuSeconds` is wall time from claim to done, including the model load on a pod's first job. The job is charged `(gpuSeconds − stats.load_s) × the pod's $/h`, and `load_s` goes on the pod's "GPU warm-up" line, so the load isn't counted twice.

## Image engine contract (`custom-http` adapter)
`POST <url>` `{prompt, negative?, referenceImages: [url], width, height, seed?, count}` → `{images: [{url}|{b64}], seed?, costUsd?}`. The `fal` adapter maps the same request to fal's queue API. Every call is recorded with its provider, model, prompt, seed and cost, so any image can be reproduced.

## Money
_Decided 2026-11-04: per-user token wallets, funded by the owner._
- **Roles.** The `owner` is the user whose RunPod account pays for all GPU work. `member`s are the testers the owner invites.
- **Tokens.** Every user has a token wallet. 1 token = $0.01 (`TOKEN_USD`), stored as whole tokens. API responses show both `tokens` and `usd`.
- **Funding.**
  - The owner **sends** tokens to a member with `POST /v1/wallets/transfer {toUserId, tokens, note}`.
  - The owner **takes back** unused tokens with `POST /v1/wallets/reclaim {fromUserId, tokens, note}`. Tokens held by running jobs can't be reclaimed.
  - Every movement is a ledger row recording whose wallet moved (`userId`), who did it (`actorId`), when, and why (`note`).
- **Allocation can't exceed real money.** The owner's "available to send" = RunPod `clientBalance` − every member's unspent tokens (spendable + held) − the owners' holds. A transfer beyond that is refused (`over_allocation`). If RunPod can't be read, transfers are refused (`balance_unavailable`).
- **Jobs charge the requester's own wallet:**
  - **Start.** The estimated price is held. If the wallet can't cover it, the job is refused before any GPU starts: `insufficient_tokens` for a member, `insufficient_balance` for the owner.
  - **Done.** The hold settles to the actual cost: `(gpuSeconds − load_s) × the pod's $/h`. A member pays at most the hold plus what's in their wallet; anything beyond that goes to studio overhead.
  - **Failed or cancelled.** The hold is released in full.
  - **Owner's jobs.** They draw on the owner's wallet, which is the RunPod balance minus members' unspent tokens.
  - **Fixed-price work** (photoshoot $0.12, outfit set $0.08, sheet angle $0.02 each, LoRA set $0.60) is charged at once and refunded if the image engine fails.
- **GPU warm-up.** Start-up, model load and idle time on a user's own pod are charged to that user's tokens as a separate "GPU warm-up" ledger line (`kind: "warmup"`). The line is attached to the job and shown as the job's `warmupCost`. The owner can switch this to "owner pays overhead" (`PATCH /v1/settings/studio {overheadPayer: "owner"}`); the default is "user".
- **Caps.**
  - Per job: $5. This doesn't apply to LoRA training.
  - Per user per day: $10. The owner can override it per member with `PATCH /v1/members/{id} {capPerJob, capPerDay}`.
  - Per studio per day: $15.
  - The defaults come from env and can be changed in `PATCH /v1/settings/studio`.
  - Today's spend counts running holds too. A job over a cap is refused before any GPU starts (`over_job_limit`, `over_user_day_limit`, `over_day_limit`).
- **Ledger kinds:**
  - `transfer`, `reclaim`
  - `hold`, `release`, `settle`
  - `charge`, `warmup`, `overhead`
  - `topup` (dev only)

  "Today" and "this month" are sums of the `settle`, `charge`, `warmup` and `overhead` rows.
- **`GET /v1/balance`** stays for the apps. For a member, `balance` is their wallet in USD. For the owner, `balance` is what they can spend or send, with `runpodBalance` and `availableToSend` next to it. Both get `tokens`, `role` and `balanceSource` (`runpod` | `simulated` | `unavailable`). RunPod is read with `myself { clientBalance currentSpendPerHr }`, and the result is cached for 30 s. The key is never logged.

## Phases
1. **A. API foundation (now):**
   - auth with invites, Postgres schema and migrations, R2 storage with presigned uploads (built 2026-11-04 in `server/api/`, see its README)
   - every endpoint in `plans/api.md` against the database, SSE, the ledger and caps
   - the image engine with the `fal` and `custom-http` adapters
   - a **simulated GPU worker** so everything runs end to end for free
   - Dockerfile and Railway setup, tests
2. **B. Real GPU (now, in parallel):** the Python worker plus the RunPod controller. Then one end-to-end H3 render on a 5 s Sienna clip (about $0.70) once the user says go.
3. **C. Apps:** sign-in against the real API, the default base URL set to the Railway host, the image-engine picker in Settings, and push notifications (FCM; APNs once there's an Apple Developer account).
4. **D. Later:** LoRA training on the GPU (ai-toolkit), social OAuth (each platform needs a developer app), lip sync and upscale passes.

## Accounts the owner creates (keys go in Railway's variables, never in chat)
- **Railway:** the project with Postgres. The API reads `DATABASE_URL`.
- **Cloudflare R2:** a bucket plus an API token. The API reads `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` and `R2_BUCKET`.
- **RunPod:** already exists. The API reads `RUNPOD_API_KEY` and the network volume id.
- **fal.ai** (if hosted images are used): `FAL_KEY`.

## Keep GPU warm (decided 2026-11-04)
A manual switch for sessions where many renders happen back to back, so they start instantly instead of waiting the 3–6 min cold start.
- **Where:** a "Keep GPU warm" switch in the video studio, and in the Mac title bar.
  - The owner decides whether members may use it: studio setting `warmGpuAllowed: owner | everyone`, **default everyone** (decided 2026-11-04 for the test phase).
- **Nudge when creating starts:** when a user starts making something (uploads or picks a clip in the video studio, or opens Generate) and no warm GPU is running for them, MUSE shows a prompt: "Warm up a GPU now so your render starts right away? About $4/hour from your credit while it's on, and it turns off by itself after 20 min without renders." [Warm up] [Not now]. The nudge appears every time creating starts, never mid-flow.
- **Manual switch:** users can also switch it on themselves at any time. **Every** switch-on shows the same cost warning to confirm. There is no "don't ask again".
- **Effect:** starts (or claims) a dedicated H100 for the user who switched it on and keeps H3 loaded. That user's jobs go to it first.
- **Notice:** while it's on, a persistent bar on every screen ("GPU warm · 42 min · $2.80 so far · Turn off"), plus an ongoing notification on Android and a menu-bar/title-bar indicator on the Mac.
- **Billing:** the pod's whole wall time is charged to the user who turned it on (a "Warm GPU" ledger line, settled per minute). Their render jobs on it aren't charged twice.
- **Auto-off:** any of these turns it off.
  - **Idle:** `warmIdleMinutes` (default 20) without a job.
  - **Session cap:** `warmMaxMinutes` (default 120); "Keep warm" extends it once by the same amount.
  - **Credit:** the user's credit can't cover 10 more minutes.
  - **Owner balance:** the owner's RunPod balance is below `RUNPOD_MIN_BALANCE_USD`.
  - **Warnings:** a warning 5 minutes before an idle or cap auto-off, with a "Keep warm" action.
  - **Backstop:** the pod's own self-stop still applies if the API is unreachable.
- **API:**
  - `POST /v1/gpu/warm {on: true|false}` → `{state, startedAt, minutes, costUsd, autoOffAt, reason?}`
  - `GET /v1/gpu/warm`
  - SSE `gpu` events for the bar and the warnings
