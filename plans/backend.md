# MUSE backend (spec)

_Started 2026-11-04._ This is the real server that the Android and Mac apps talk to. It replaces the mock while keeping the same contract (`plans/api.md`), so the apps switch over by changing the base URL and signing in.

## Decisions (2026-11-04)
- **Users:** login for a small **invite-only** group, about 3 testers to start. They share one studio: the same models, outfits, gallery and posts. Every row is still scoped to a `studioId` and every action records its `userId`, so separate studios and client accounts (Phase 2) need no rebuild.
- **Balance:** this is the **real RunPod credit**, read from the RunPod API. There are no in-app payments yet. The server enforces the spend caps: per job, per day, and per user per day.
- **Photo model:** a **pluggable image engine**. The server exposes one image-generation interface with provider adapters. The engine is chosen per studio in the app's Settings, and a call can override it. Adapters:
  - `fal` (hosted models such as Seedream or Nano Banana; the model id is configurable)
  - `custom-http` (any endpoint that follows our small contract below)
  - `runpod-selfhosted` (later)
- **Hosting:** **Railway** runs the API and Postgres. **Cloudflare R2** (S3-compatible) holds uploads and renders. **RunPod** runs the GPU work: H3 on an H100 with a network volume, started on demand and shut down when idle.

## Parts
| Part | Where | What |
|---|---|---|
| API | `server/api/` (Node 22, TypeScript, Fastify, Postgres via Drizzle, S3 SDK for R2) | Auth and invites, studios, models/sheets, outfits, clips (+ checks), jobs/takes, shoots, LoRA, accounts/posts, balance/caps, SSE `/v1/events`, image engine |
| GPU controller | inside the API (`server/api/src/gpu/`) | Starts/stops the RunPod pod (GraphQL API) with the network volume, assigns jobs, tracks spend, shuts down idle pods (5 min), enforces caps, handles failures and refunds in the ledger |
| GPU worker | `gpu/worker/` (Python, runs on the pod) | Pulls jobs from the API, downloads inputs from R2, runs `pipeline/runpod/h3_ref2va_run.py` (FA3, 10 steps by default), reports step progress, uploads the result to R2, reports done or failed |
| Prompt engine | `server/api/src/prompt/` | A TypeScript port of the layered engine (`plans/prompt-system.md`), checked against the same fixtures as the Kotlin and Swift ports |

## Worker protocol (API ⇄ GPU worker)
The worker authenticates with `Authorization: Bearer <WORKER_TOKEN>` (per pod, issued at pod start).
- `POST /worker/v1/claim` `{podId, gpu, capabilities: ["h3","viggle","latentsync"]}` → `204` (nothing to do) or `{job: {id, kind: "h3"|"viggle"|"lipsync"|"lora-train", params, inputs: [{name, url /* presigned R2 GET */}], outputs: [{name, uploadUrl /* presigned R2 PUT */}], prompt, seed, steps}}`
- `POST /worker/v1/jobs/{id}/progress` `{step, totalSteps, phase, etaSeconds}`. Sent at most twice per second, and forwarded to the apps as `job` events.
- `POST /worker/v1/jobs/{id}/done` `{outputs: [{name, bytes, sha256, width, height, fps, durationSec}], gpuSeconds}`
- `POST /worker/v1/jobs/{id}/failed` `{error, retryable}`. The job is refunded in the ledger and the apps get a failed event.
- `POST /worker/v1/heartbeat` `{podId, busy}` every 15 s. If heartbeats stop for 60 s, the controller marks the job failed (retryable) and stops the pod.

## Image engine contract (`custom-http` adapter)
`POST <url>` `{prompt, negative?, referenceImages: [url], width, height, seed?, count}` → `{images: [{url}|{b64}], seed?, costUsd?}`. The `fal` adapter maps the same request to fal's queue API. Every call is recorded with its provider, model, prompt, seed and cost, so any image can be reproduced.

## Money
- **Ledger:** every charge and refund is a row (`studioId`, `userId`, `jobId`, `amountUsd`, `kind`). "Today" and "This month" come from the ledger. "Balance" comes from RunPod's `clientBalance`.
- **Estimates before a job:** the same pricing maths as the apps. **Actual cost after:** `gpuSeconds × hourly rate`, plus the pod's idle and startup share.
- **Caps:** per job ($5 default), per day ($15), per user per day ($10). A job that would go over a cap is refused before any GPU starts.

## Phases
1. **A. API foundation (now):**
   - auth with invites, Postgres schema and migrations, R2 storage with presigned uploads
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
