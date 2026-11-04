# Put the MUSE server online for free

You'll set up three free services, in this order:

| Service | What it does for MUSE |
|---|---|
| **Neon** | The database: accounts, wallets, jobs. |
| **Cloudflare R2** | File storage: photos, clips and finished videos. |
| **Koyeb** | Runs the MUSE server (the "API" the apps talk to). |

It takes about 30–45 minutes.

> **Keys and passwords go in one place only:** Koyeb's environment variable and secret fields. Never paste them into a chat (including this one), an email or the code. If a key leaks, delete it where you made it and make a new one.

Keep a note open while you work, such as a password manager entry. Each value you copy has a **name in bold capitals**, like **`DATABASE_URL`**. Koyeb needs exactly that name later.

---

## 1. Neon (the database)

1. Go to **neon.tech** and click **Sign up**. Signing up with GitHub is easiest.
2. Create a project:
   - **Project name:** `muse`
   - **Postgres version:** leave the default.
   - **Region:** pick the one closest to where the server will run (step 3). Choose **AWS Europe Central 1 (Frankfurt)** if you'll pick Koyeb **Frankfurt**, or **AWS US East 1 (N. Virginia)** if you'll pick Koyeb **Washington, D.C.** Close together means faster.
   - Click **Create project**.
3. On the project dashboard, click **Connect**. In the box that opens:
   - Make sure **Connection pooling** is **on**. The address then contains `-pooler`. "Pooled" means many short requests share a few database connections, which is what a web server wants.
   - Copy the whole connection string. It looks like
     `postgresql://neondb_owner:…@ep-something-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require&channel_binding=require`
   - This is **`DATABASE_URL`**. It contains the database password, so treat it like one.

Good to know: Neon's free plan puts the database to sleep after about 5 minutes with no activity, and wakes it on the next request. The first request after a sleep takes a moment longer. The server waits and retries, and it doesn't wake the database for health checks, so the free compute hours last.

---

## 2. Cloudflare R2 (file storage)

1. Sign in (or sign up) at **dash.cloudflare.com**.
2. In the left menu, click **R2 Object Storage**. If R2 isn't on yet, click **Purchase R2 Plan** or **Enable R2**.
   - **Cloudflare asks for a payment method even for the free tier** (10 GB of storage free each month). That's normal. You're charged only if you go over the free amounts.
3. Click **Create bucket**. A "bucket" is a folder in the cloud.
   - **Bucket name:** `muse-media`
   - **Location:** Automatic
   - Click **Create bucket**. Leave it **private**: the server hands out short-lived links.
4. Go back to the **R2 Object Storage** overview. On the right, under **Account Details**, copy the **Account ID**. This is **`R2_ACCOUNT_ID`**.
5. On the same page, click **Manage API tokens** (or **API Tokens**), then **Create API token** (the "Account API token" kind if it asks):
   - **Token name:** `muse-api`
   - **Permissions:** **Object Read & Write**
   - **Specify bucket(s):** **Apply to specific buckets only** → `muse-media`
   - **TTL:** Forever
   - Click **Create API Token**.
6. The next page shows two values **only once**. Copy both now:
   - **Access Key ID** → **`R2_ACCESS_KEY_ID`**
   - **Secret Access Key** → **`R2_SECRET_ACCESS_KEY`**

---

## 3. Koyeb (runs the server)

### 3a. Account and GitHub access
1. Go to **koyeb.com** and click **Sign up**. Choose **Continue with GitHub**.
2. When GitHub asks which repositories the **Koyeb** app may see, choose **Only select repositories** → **`richard4801/Claude-Template`** → **Install & Authorize**.
   - Already signed up without doing this? On GitHub, go to **Settings → Applications → Koyeb → Configure** and add the repository.

### 3b. Create the service
In the Koyeb control panel, click **Create Service** (or **Create Web Service**), then **GitHub**, and fill in the following. The wording can differ slightly; the values can't.

| Setting | Value |
|---|---|
| Repository | `richard4801/Claude-Template` |
| Branch | `claude/ecstatic-rubin-2egjfb` |
| Builder | **Dockerfile** |
| Work directory | click **Override** and type `server/api` (the folder the server is built from) |
| Dockerfile location | `Dockerfile` (leave the default; it's inside the work directory) |
| Entrypoint, Command, Target | leave empty |
| Instance | **Free** (512 MB memory, 0.1 vCPU) |
| Region | **Frankfurt** or **Washington, D.C.**, matching your Neon region |
| Scaling | **1** instance (minimum 1, maximum 1, if Koyeb shows both). Never more than one: the server keeps live updates in memory. |
| Exposed ports | port **`8000`**, protocol **HTTP**, path **`/`**. Turn on **Public** if there's a switch. |
| Health checks | protocol **HTTP**, port **`8000`**, path **`/health`**. Set the **grace period** to **60** seconds; the first start creates the database tables. |
| Service name | `muse-api` |

> **Scale-to-zero ("sleep"):** keep it **off**. On the **free** instance, though, Koyeb doesn't let you turn it off: the server sleeps after **1 hour with no traffic** and wakes in a few seconds on the next request. For MUSE that's fine:
> - An open app (live updates) and a running GPU (it reports in every 15 seconds) both count as traffic, so the server never sleeps while you're working or rendering.
> - Even if the server is asleep or down, a GPU pod shuts **itself** down after 5 idle minutes, so it can't run up a bill (see [`gpu/pod/README.md`](../gpu/pod/README.md), "Self-stop").
> - A scheduled post that falls due while the server sleeps is handed off on the next request.
>
> If you move to a paid instance later, set scale-to-zero **off** there.

### 3c. Environment variables
In the same form, find **Environment variables** (sometimes "Environment variables and files"). Add each row below. Use **exactly** these names.

For the rows marked **Secret**: change the type from **Plain text** to **Secret**, click **Create secret**, give it the same name, and paste the value there. Koyeb then hides the value.

| Name | Type | Value |
|---|---|---|
| `DATABASE_URL` | Secret | the Neon pooled string from step 1.3 |
| `R2_ACCOUNT_ID` | Plain | from step 2.4 |
| `R2_ACCESS_KEY_ID` | Secret | from step 2.6 |
| `R2_SECRET_ACCESS_KEY` | Secret | from step 2.6 |
| `R2_BUCKET` | Plain | `muse-media` |
| `RUNPOD_API_KEY` | Secret | RunPod → **Settings** → **API Keys** → **Create API Key** (Read/Write). The server reads your RunPod balance with it. |
| `OWNER_INVITE_CODE` | Secret | a long code you make up, 12+ characters, such as `jenne-studio-first-owner-2026` (used once, step 4) |
| `OWNER_EMAIL` | Plain | the email you'll sign in with |
| `STUDIO_NAME` | Plain | your studio's name, such as `Jenne Studio` |
| `TZ` | Plain | your time zone, such as `Europe/London`, so "today" and the daily limits start at your midnight |
| `GPU_MODE` | Plain | `simulated` (renders are pretend and free for now; see step 6) |
| `PUBLIC_URL` | Plain | leave it out for now; you add it in 3e |

### 3d. Deploy
Click **Deploy**. The first build takes 3–6 minutes. Open the service's **Logs** (or the deployment's **Build logs**, then **Runtime logs**) and wait for these lines:
- `database migrated`: the tables were created in Neon.
- `MUSE API listening on port 8000`

Red text that says `MUSE API cannot start: Bad configuration: …` names the variable that's wrong. Fix it in **Settings → Environment variables** and redeploy.

### 3e. Set `PUBLIC_URL`, then redeploy
1. On the service's overview page, copy its public address, such as `https://muse-api-yourname.koyeb.app`.
2. Go to **Settings → Environment variables**, add **`PUBLIC_URL`** (Plain) with that address. Leave off the slash at the end.
3. Click **Save and deploy** (or **Redeploy**). The server uses this address in image links and gives it to the GPU later.

---

## 4. Your owner account, then the testers

**You (the owner), once:**
1. Install the MUSE app. Open **Settings → Developer → Server URL** and enter your `https://….koyeb.app` address.
2. Choose **Sign up**:
   - **Email:** your `OWNER_EMAIL`
   - **Password:** 8+ characters. Make it a new one.
   - **Invite code:** your `OWNER_INVITE_CODE`
   - Tick both boxes, then sign up. You're now the studio **owner**.
3. In Koyeb, go to **Settings → Environment variables**, **delete `OWNER_INVITE_CODE`**, and redeploy. The code only works once anyway, but there's no reason to keep it.

**Inviting the two testers.** Each invite code works once, for one email address, for 14 days.
1. In Koyeb, open the service and go to the **Console** tab. It's a terminal inside the running server.
2. Type `npm run invite -- tester1@example.com` and press Enter. The code is printed, such as `MUSE-ABCD-EFGH-JKLM`. Do the same for the second tester.
   - No Console tab? Install the Koyeb CLI and run `koyeb instances exec <instance-id> -- npm run invite -- tester1@example.com`.
3. Send each tester their code (a code alone isn't a password). In the app, they set the same server URL and **Sign up** with that email and code.
4. To give testers tokens to render with: 1 token = $0.01, sent from your wallet. You can't hand out more than your RunPod balance covers.

---

## 5. Check that it works
1. In a browser, open `https://<your-app>.koyeb.app/health`. You should see `"ok":true`.
   - `"db":"unchecked"` is normal: the health check deliberately doesn't wake the database. To test the database too, open `…/health?db=1`. It should say `"db":true`; the first try after a sleep can take a few seconds.
2. In each app (Android and Mac): **Settings → Developer → Server URL** = your Koyeb address, then sign in.
3. Make a test render. With `GPU_MODE=simulated` it finishes quickly and costs nothing.

**If something's wrong:**
- `/health` doesn't load: check Koyeb's **Logs**. The service may still be starting or waking (wait 10 s and retry).
- Sign-in fails with a server error: open `/health?db=1`. If it says `"db":false`, `DATABASE_URL` is wrong. Copy the **pooled** string from Neon again.
- Uploads fail: check the four `R2_…` values and that the bucket is named exactly `muse-media`.

---

## 6. Later: real GPU renders (only when you say go; this costs money)
1. Prepare the RunPod network volume once. A **network volume** is a disk in RunPod's cloud that keeps the AI models between GPU sessions. Follow [`gpu/pod/README.md`](../gpu/pod/README.md), "One-time network-volume preparation".
2. In Koyeb, go to **Settings → Environment variables**, add these, and redeploy:

   | Name | Value |
   |---|---|
   | `GPU_MODE` | `runpod` (replaces `simulated`) |
   | `RUNPOD_NETWORK_VOLUME_ID` | RunPod → **Storage** → your volume's ID |
   | `RUNPOD_DATACENTER_ID` | the volume's data centre, such as `EU-RO-1` |
   | `RUNPOD_IMAGE` | the image from `gpu/pod/README.md`, "Pod template" |
   | `RUNPOD_START_CMD` | `bash /workspace/muse/gpu/pod/bootstrap.sh` |

3. Each render then starts an H100 GPU (about $4/hour). The server shuts it down 3 minutes after the last job. If the server can't, because it's asleep, down or unreachable, the GPU shuts **itself** down after 5 idle minutes.
