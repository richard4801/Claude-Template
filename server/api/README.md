# MUSE API (`server/api`)

This is the real backend for the MUSE Android and Mac apps. It speaks the same contract as `server/mock` (`plans/api.md`), so the apps switch over by changing the base URL and signing in. The design and decisions are in `plans/backend.md`.

- **Stack:** Node 22, TypeScript, Fastify, Postgres (Drizzle, migrations in `drizzle/` run on start), Cloudflare R2 through the S3 API, and zod.
- **Accounts:** invite-only sign-in with argon2id passwords and revocable bearer sessions (only a hash of each token is stored).
- **Money:** per-user token wallets funded by the owner, a ledger, and caps. The balance is the real RunPod credit.
- **GPU controller** (`src/gpu/`):
  - `simulated` (the default, free): renders run 24× faster than real time, like the mock.
  - `runpod`: one pod per user on the shared network volume, warm-pod reuse, idle shutdown, and the worker protocol at `/worker/v1/*`.
  - **Keep add-on engine ready** (was Keep GPU warm; `src/services/warm.ts`, `POST /v1/gpu/warm`, **owner only**, members get `403 owner_only`): the owner holds a dedicated pod; its wall time is the "Add-on engine ready" ledger line, settled per minute, and renders on it aren't charged GPU time again. It turns off after `WARM_IDLE_MINUTES` without a render, at the `WARM_MAX_MINUTES` cap (extended once), or when the studio balance can't cover 10 more minutes.
  - **Studio balance** (`plans/api.md` "App clean-up" §4): the owner records top-ups (`POST /v1/studio/topups`); every engine's spending counts against them in this ledger. RunPod's own balance backs nothing (it's shown in owner Settings → Engines). Photos hold an estimate and settle to the exact Replicate cost (§3).
- **Image engine** (`src/images/`): `simulated` (the bundled reference stills), `fal` (fal.ai queue API) or `custom-http` (our small contract). It is chosen per studio in Settings.
- **Prompt engine** (`src/prompt/`): a port of `android/core` `PromptEngine.kt`, checked against the same fixtures.
- **Photo templates** (`src/templates/`, `plans/templates.md`): reusable looks with hidden prompt layers and a variation pool.
  - The server builds every template still's prompt (template layers + the model's identity, outfit and never-add + one draw per pool slot, or the user's direction in place of pose and angle + a new seed) and stores the exact prompt, seed and draws on the shot. Layers, pools, draws and full prompts go only to the template's owner; everyone else sees `Template: <name>`.
  - After-effects (`grade`, `grain`, `faceMotionBlur`) run on each still with **sharp** after the image engine. **Limitation:** there is no face detector yet; the face box for the motion blur is the upper-centre of the frame (x 28–72 %, y 6–40 %), which suits portrait phone photos and misses faces elsewhere.
  - The seven starter templates are added on start to every studio with an owner (keyed by slug, idempotent; a deleted starter comes back on the next start). Their covers are the bundled Sienna stills with the template's grade and after-effects, stored at `t/<studioId>/starter-<slug>.jpg`.
  - `/health` shows `build` (the git commit Railway or Koyeb built), `startedAt`, `migrations` `{applied, latest}` and `starters` `{studios, added}`.

## Run it on your computer

You need Node 22. Docker is optional.

```bash
cd server/api
npm install
```

**Quickest: no Docker.** This uses an embedded in-memory Postgres and local files, simulated GPU and images, and the same seed data as the mock:

```bash
DEV_MODE=true DEV_SEED=true BALANCE_MODE=simulated npm run dev
# → http://localhost:8787  (sign in as jen@studio.com / x)
```

**Like production, with Docker.** Postgres and MinIO stand in for R2:

```bash
docker compose up -d          # Postgres on :5432, MinIO on :9000 (console :9001), bucket "muse"
cp .env.example .env          # already points at both
npm run dev
```

**Tests.** The tests use the embedded Postgres, a stub S3 and a fake RunPod API, so no money is ever spent:

```bash
npm test                                                     # embedded Postgres
TEST_DATABASE_URL='postgres://muse:muse@localhost:5432/muse_test?sslmode=disable' npx vitest run --no-file-parallelism   # real Postgres, SSL off (it wipes that DB); also runs test/pg.test.ts's lock/retry tests
```

**The apps' contract tests against this server:**

```bash
# Android (from android/): starts this server instead of server/mock
MUSE_TEST_SERVER_CMD="cd ../../server/api && exec node --import tsx scripts/test-server.ts" ./gradlew :app:testDebugUnitTest --tests '*Http*'
# Mac (from mac/MuseCore/), with this server running:
(cd ../../server/api && PORT=8799 node --import tsx scripts/test-server.ts &) ; MUSE_MOCK_URL=http://127.0.0.1:8799 swift test --filter MockServerTests
```

**A GPU worker by hand** (no pod). Start the server with `GPU_MODE=runpod WORKER_TOKEN=some-dev-token`, then run the worker in dry-run mode:

```bash
cd gpu/worker && WORKER_TOKEN=some-dev-token POD_ID=dev python3.11 -m muse_worker --dry-run --api-url http://localhost:8787 --once
```

## Put it online

**Free setup (recommended): Koyeb + Neon + Cloudflare R2.** Follow [`server/DEPLOY-free.md`](../DEPLOY-free.md), click by click. In short:

| Koyeb setting | Value |
|---|---|
| Builder | **Dockerfile** |
| Work directory (build context) | `server/api` |
| Dockerfile location | `Dockerfile` (relative to the work directory). Without a work directory: `server/api/Dockerfile` plus the build argument `APP_DIR=server/api` |
| Exposed port | `8000`, HTTP, path `/` (the image sets `PORT=8000`) |
| Health check | HTTP on port `8000`, path `/health`, grace period 60 s |
| Instance | Free (512 MB, 0.1 vCPU), Frankfurt or Washington, D.C., **1 instance** |

How it's tuned for this setup:
- **Neon:** use the pooled connection string with `sslmode=require`. Start-up retries while a sleeping database wakes. The pool is small (5) and closes idle connections after 10 s. Migrations run in one transaction under an advisory lock.
- **Letting the database sleep:** `/health` doesn't touch the database (`/health?db=1` does). With nothing to do, the background loops look at the database only every `IDLE_POLL_SECONDS`, so Neon can suspend.
- **Server-sent events:** `/v1/events` sends a keep-alive comment every 15 s and is never buffered or compressed, so it streams through Koyeb's proxy.
- **Memory:** the image holds production dependencies only, with `NODE_OPTIONS=--max-old-space-size=384`. It idles at about 60 MB.
- **Scale-to-zero:** Koyeb's **free** instance always sleeps after 1 hour without traffic; this can't be turned off. Read [`DEPLOY-free.md`](../DEPLOY-free.md) for why that's safe here. On a paid instance, turn scale-to-zero off.

Build it yourself: `docker build -t muse-api server/api`, or from the repository root, `docker build -t muse-api -f server/api/Dockerfile --build-arg APP_DIR=server/api .`.

### Alternative: Railway + Cloudflare R2 (step by step)

Railway isn't free, but it still works: `railway.json` sets the Dockerfile, the health check and one replica.

You'll make three things: a **Cloudflare R2 bucket** (for photos and videos), a **Railway project** (it runs the API and its database), and the **first owner account**. Keys go into Railway's Variables page only: never paste them into chat, email or the code.

#### 1. Cloudflare R2 (storage)
1. Sign in at **dash.cloudflare.com**. In the left menu, click **R2 Object Storage**. If it asks, click **Purchase R2 Plan** to turn on R2; the free tier is enough to start.
2. Click **Create bucket**. Name it `muse-media`, leave **Location** on Automatic, and click **Create bucket**.
3. Back on the R2 overview page, copy your **Account ID** from the right-hand side. That's `R2_ACCOUNT_ID`.
4. Click **Manage API tokens** (on the right, under Account Details), then **Create API token**:
   - **Token name:** `muse-api`
   - **Permissions:** **Object Read & Write**
   - **Specify bucket(s):** **Apply to specific buckets only** → `muse-media`
   - **TTL:** Forever
   - Click **Create API Token**.
5. The next page shows the **Access Key ID** and the **Secret Access Key** once. Copy both into a safe place, such as your password manager. They are `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`.

Leave the bucket private. The API hands out short-lived links.

#### 2. Railway (the API and its database)
1. Sign in at **railway.com** with GitHub. Click **New Project** → **Deploy from GitHub repo**, and pick this repository. If Railway can't see it, click **Configure GitHub App** and allow the repo.
2. Railway creates a service from the repo. Open it, go to **Settings** → **Source** → **Root Directory**, and type `/server/api`. Railway then finds `Dockerfile` and `railway.json` there.
3. Add the database: on the project canvas, click **+ Create** (or **New**) → **Database** → **Add PostgreSQL**.
4. Open the API service → **Variables** → **New Variable**, and add these one by one:

   | Variable | Value |
   |---|---|
   | `DATABASE_URL` | click **Add Reference** and pick **Postgres → DATABASE_URL** (it shows as `${{Postgres.DATABASE_URL}}`) |
   | `R2_ACCOUNT_ID` | from step 1.3 |
   | `R2_ACCESS_KEY_ID` | from step 1.5 |
   | `R2_SECRET_ACCESS_KEY` | from step 1.5 |
   | `R2_BUCKET` | `muse-media` |
   | `RUNPOD_API_KEY` | RunPod → **Settings** → **API Keys** → **Create API Key** (Read/Write). The API reads the balance with it. |
   | `TZ` | your time zone, e.g. `Europe/London`, so "today" starts at your midnight |
   | `OWNER_INVITE_CODE` | make up a long code only you know, e.g. `jenne-studio-first-owner-2026` (see step 3) |
   | `OWNER_EMAIL` | the email you'll sign up with |
   | `STUDIO_NAME` | your studio's name, e.g. `Jenne Studio` |

   Leave `GPU_MODE` unset for now: renders stay simulated (free) until the GPU worker is ready.
5. Go to **Settings** → **Networking** → **Generate Domain**. Copy the address, e.g. `https://muse-api-production.up.railway.app`. Add one more variable, `PUBLIC_URL`, set to that address with no slash at the end.
6. Railway redeploys after each change. Open **Deployments** → the latest one → **View logs**, and wait for `MUSE API listening`. Open `<your address>/health` in a browser: it should say `"ok":true`.

#### 3. The first owner account
1. In the MUSE app, open Settings and set the server address to your Railway address.
2. Choose **Sign up**. Use the `OWNER_EMAIL` address, a password of 8 or more characters, and the `OWNER_INVITE_CODE` you made up. Tick both boxes. You're now the studio **owner**.
3. In Railway, delete the `OWNER_INVITE_CODE` variable. It only ever works once, but there's no reason to keep it.
4. **Inviting testers:** each code works once, for that email, for 14 days. There are two ways to make one:
   - **The API:** `POST /v1/invites {email}` as the owner. The app screen for this comes with Phase C.
   - **A terminal:** with the Railway CLI, run `railway ssh` (pick the API service), then `npm run invite -- tester@example.com`. The code is printed there.
   In the app, **Invite someone → Share** sends the invite's `shareText`: the download page (`<PUBLIC_URL>/get`), the code and the email.
5. **Giving testers credit:** the apps show dollars; the API counts whole tokens (1 token = `TOKEN_USD` = $0.01). Send credit to a tester with `POST /v1/wallets/transfer`. Record what you loaded first (`POST /v1/studio/topups {amountUsd, note}`); you can't send more than the studio balance has free.
6. **Publishing the apps** (see [App downloads](#app-downloads-and-invite-links)): upload the Android APK and the Mac zip once, and every invite link offers them.

#### App downloads and invite links

| Endpoint | Who | What |
|---|---|---|
| `GET /get` | anyone | A small mobile-friendly page: **Download for Android**, **Download for Mac**, and "Then sign up with the invite code you were sent". A button says "coming soon" until that build is uploaded. |
| `GET /download/android`, `GET /download/mac` | anyone | 302 to a 10-minute presigned R2 link for `releases/android/latest.apk` / `releases/mac/MUSE-mac.zip`, saved as `MUSE.apk` / `MUSE-mac.zip`. A friendly 404 page when there's no build. With local storage the file is served from `UPLOAD_DIR` (`data/uploads/releases/...`). |
| `PUT /v1/releases/android`, `PUT /v1/releases/mac` | owner | Uploads a new build. The body is the raw file (any content type, with a Content-Length, up to 1 GB); it streams straight to storage and replaces the previous build. → `{platform, key, bytes, filename, downloadUrl, pageUrl}` |

To publish a build, sign in as the owner to get a session token, then PUT the file:

```bash
API=https://angelic-elegance-production-c42b.up.railway.app
TOKEN=$(curl -s "$API/v1/auth/signin" -H 'content-type: application/json' \
  -d '{"email":"you@example.com","password":"…"}' | node -pe 'JSON.parse(require("fs").readFileSync(0)).token')
curl -fS -X PUT "$API/v1/releases/android" -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/vnd.android.package-archive' --data-binary @android/app/build/outputs/apk/release/app-release.apk
curl -fS -X PUT "$API/v1/releases/mac" -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/zip' --data-binary @MUSE-mac.zip
```

Then open `$API/get` on a phone to check. `POST /v1/invites` responses carry `shareText`: "You're invited to MUSE, the AI model studio. 1) Download: {PUBLIC_URL}/get 2) Sign up with this invite code: {code} (email: {email}). The code works once and expires in 14 days." Set `PUBLIC_URL` so the link is right.

#### 4. Turning on the real GPU (later, when you say go)
Set these variables:
- `GPU_MODE=runpod`
- `RUNPOD_NETWORK_VOLUME_ID`: RunPod → **Storage** → your volume's ID
- `RUNPOD_DATACENTER_ID`: the volume's data centre, e.g. `EU-RO-1`
- `RUNPOD_IMAGE`: the worker image from `gpu/`'s README
- optionally `RUNPOD_START_CMD`

Each user then gets their own H100 pod when they render. It shuts down 3 minutes after their last job. `MAX_GPUS` (default 3) caps how many pods run at once.

#### 5. Hosted photo models (optional)
For fal.ai: create a key at **fal.ai** → **Dashboard** → **Keys**, and add it as `FAL_KEY`. Then pick **fal** in the app's Settings → Image engine. The default model is `fal-ai/bytedance/seedream/v4/edit`; change it in the same place.

## All variables

| Variable | Default | What |
|---|---|---|
| `DATABASE_URL` | embedded (dev only) | Postgres connection string. **Required in production** (the server refuses to start without it). Neon: the pooled string with `sslmode=require` |
| `DATABASE_URL_UNPOOLED` | none | Optional direct Neon string, used only for start-up migrations |
| `DB_POOL_MAX`, `DB_IDLE_TIMEOUT_MS`, `DB_CONNECT_TIMEOUT_MS` | `5`, `10000`, `15000` | Pool size, how soon idle connections close (lets Neon sleep), and the connect timeout for a waking database |
| `DB_STARTUP_RETRY_SECONDS` | `90` | How long start-up waits for the database |
| `IDLE_POLL_SECONDS` | `600` | With nothing queued, no pod and no post due, the background loops read the database only this often. `0` = every tick |
| `PORT`, `HOST` | `8787` (`8000` in the Docker image), `0.0.0.0` | Koyeb's default port is 8000; Railway sets `PORT` |
| `PUBLIC_URL` | `http://localhost:PORT` | Public address; used for image links and given to GPU pods |
| `LOG_LEVEL` | `info` | Structured JSON logs. Auth headers, tokens and query strings are never logged |
| `TZ` | UTC | Day boundary for "today" and the daily caps |
| `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET` | none | Cloudflare R2. Setting `R2_BUCKET` switches storage to S3 |
| `S3_ENDPOINT`, `S3_FORCE_PATH_STYLE`, `STORAGE` | | MinIO or other S3. `STORAGE=local` uses disk (`UPLOAD_DIR`) |
| `DIRECT_UPLOAD_MAX_MB` | `50` | Largest multipart upload; bigger files use `/v1/uploads/presign` |
| `RUNPOD_API_KEY` | none | Balance (always read-only) and pods (in `runpod` mode). Never logged. Without it the balance says `unavailable` |
| `BALANCE_MODE` | `runpod` (`simulated` in dev) | `simulated` = a new studio starts with a dev opening top-up of `SIM_START_BALANCE` (dev and tests) |
| `TOKEN_USD` | `0.01` | Dollars per wallet token |
| `CAP_PER_JOB_USD`, `CAP_PER_DAY_USD`, `CAP_PER_USER_DAY_USD` | `5`, `15`, `10` | Default caps. The owner can change them in settings and per member |
| `RUNPOD_MIN_BALANCE_USD` | `2` | Unused since 2026-11-04 (nothing pauses on a provider balance) |
| `GPU_MODE` | `simulated` | `runpod` starts real pods |
| `RUNPOD_NETWORK_VOLUME_ID`, `RUNPOD_DATACENTER_ID`, `RUNPOD_IMAGE`, `RUNPOD_START_CMD`, `RUNPOD_CONTAINER_DISK_GB` | | Pod template |
| `GPU_TABLE` | H3 → H100s then H200s; Viggle → H200 NVL, H200 | GPU types per job kind (JSON), best first |
| `RUNPOD_WORKER_CAPABILITIES` | `h3,latentsync` | What the pod image can do; other jobs are refused at submit time |
| `MAX_GPUS`, `IDLE_SHUTDOWN_SECONDS` | `3`, `180` | Pod cap and idle shutdown |
| `WARM_IDLE_MINUTES`, `WARM_MAX_MINUTES` | `20`, `120` | Keep GPU warm: idle auto-off and the session cap (the owner can change both in studio settings) |
| `WARM_WARNING_MINUTES`, `WARM_MIN_CREDIT_MINUTES` | `5`, `10` | The warning before an idle or cap auto-off; the credit a warm GPU must still cover |
| `WORKER_HEARTBEAT_TIMEOUT_SEC`, `POD_BOOT_TIMEOUT_SEC` | `60`, `900` | Health checks |
| `GPU_HOURLY_USD` | `3.99` | Rate used when a pod doesn't report its own |
| `WORKER_TOKEN` | none | Optional static token for a hand-run dev worker |
| `IMAGE_PROVIDER`, `IMAGE_MODEL`, `IMAGE_CUSTOM_URL` | `replicate` with a Replicate token, else `simulated` | The default image engine (studios override it in Settings) |
| `REPLICATE_API_TOKEN` (+ the `REPLICATE_*` and `VIDEO_ENGINE_DEFAULT` settings in `plans/backend.md` "Replicate") | none | Hosted MiniMax H3 video (Draft / Standard / HD, the default engine) and FLUX.2 / Qwen photos. Needs `ffmpeg` (in the Docker image) |
| `FAL_KEY`, `FAL_COST_PER_IMAGE` | none, `0.03` | fal.ai |
| `OWNER_INVITE_CODE`, `OWNER_EMAIL`, `STUDIO_NAME` | | First owner without a terminal (see above) |
| `DEV_MODE`, `DEV_SEED` | off | Dev only: seed data, `/v1/dev/*`, sign-up without invite, simulated socials. **Never in production** |
| `SPEED`, `GEN_MS` | `24`, `1600` | Simulated render speed and image delay |

## What's real and what's still a stand-in
- **Real:**
  - accounts, invites, sessions, wallets, the ledger, caps and the owner-loaded studio balance
  - storage and presigned uploads
  - the prompt engine and pricing
  - the fal and custom-http image engines
  - the RunPod pod controller (tested against a fake RunPod API)
  - the worker protocol (tested with the Python worker in dry-run mode)
- **Simulated by default:** GPU renders and LoRA training (`GPU_MODE`), and images (`IMAGE_PROVIDER`).
- **Stubs:**
  - Social **connect** links the handle after a short delay; there are no platform developer apps yet.
  - Posts are scheduled in Postgres and handed off at their time. Stats read-back only exists in dev mode (made-up numbers).
  - Clip checks (people, watermark) use the app's metadata, so they're heuristic.
  - LoRA candidates from a real engine aren't auto-flagged yet.
- **One instance:** live events and the money lock are in memory. Run exactly one instance (Koyeb: scaling min = max = 1; Railway: `railway.json`). More instances would need Postgres LISTEN/NOTIFY and row locks.
