# MUSE for Android

This is the native Kotlin and Jetpack Compose app, built from the approved web prototype (`prototype/app`). It has four themes (Editorial, Camera Body, Soft Tactile and Creator Pop), and each one has its own layouts and motion. The app makes no UI sounds: the only sounds are notifications, which use the phone's default notification sound. Release and debug builds talk to the real MUSE API (`server/api`) at `https://angelic-elegance-production-c42b.up.railway.app/` (the `DEFAULT_SERVER_URL` BuildConfig field). Settings → Developer can point the app at another server, or turn on **Demo mode**: the in-app fake with the bundled sample studio and no server (off by default).

## Build
Requirements: JDK 21 and the Android SDK (platform 36, build-tools 36). Put the SDK path in `local.properties` as `sdk.dir=/path/to/android-sdk`.

```sh
cd android
./gradlew assembleDebug          # → app/build/outputs/apk/debug/app-debug.apk
./gradlew :core:test             # prompt engine + pricing (checked against prototype/app/app.js)
./gradlew :app:testDebugUnitTest # fake backend, HTTP client vs server/mock and vs server/api (needs node + `npm install` in server/api), screenshot tests
./gradlew :app:recordRoborazziDebug --tests 'studio.muse.app.ScreenshotTest'   # PNGs → app/build/outputs/roborazzi/
```

The build pulls Maven Central artifacts through Google's mirror (`maven-central.storage-download.googleapis.com`), because Maven Central rate-limits shared IPs.

## Install
```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
The minimum version is Android 8.0 (API 26). On Android 13 and later, the app asks for notification permission the first time you tap Generate. It uses that permission to tell you when a render finishes or fails, when an Identity LoRA is ready and when it's time to post. These notifications post even while the app is open, at high importance with the phone's default notification sound; Settings → Notifications opens the system page where you can change that.

## Accounts, tokens and the owner screens
- **Sign-up is invite-only.** The form has an **Invite code** field (`MUSE-XXXX-XXXX-XXXX`; the owner's first code, `OWNER_INVITE_CODE` on the server, is free text) and the two required attestation boxes. Every API error code has plain wording (`ErrorText.kt`); `unauthorized` and `account_disabled` send you back to sign-in.
- **Session:** the token is encrypted with an AES-GCM key in the Android Keystore before it goes into DataStore (`Prefs.kt`). On launch `GET /v1/auth/me` restores the session and the role. Sign out calls `POST /v1/auth/signout`.
- **My tokens** (Settings, or the balance pill on Home) reads `GET /v1/wallet`: a member sees tokens, their dollar value, holds and today/month spend; the owner sees the RunPod balance and what's available to send. A Generate a member can't afford says "Not enough tokens. Ask the studio owner for more." A `wallet` live event refreshes it and shows "You received 500 tokens from <studio>" (the event doesn't name the sender).
- **Queue:** waiting jobs show their place in line and ETA, `blocked: owner_balance_low` shows "Paused: the studio's GPU credit is low", and GPU warm-up is its own line on the cost.
- **Owner only** (Settings → Studio, shown when `role == owner`): **Members** (tokens, spend, last active; Send tokens / Take back with a note, daily cap, switch an account off), **Invite someone** (makes a code with Copy and Share, so no terminal is needed) and **Studio settings** (max GPUs, who pays GPU warm-up, caps, and the image engine: simulated, fal or a custom https engine).
- **Uploads:** when the server's `/health` says `storage: "s3"` (R2), files go `POST /v1/uploads/presign` → PUT straight to R2 → `POST /v1/uploads/{id}/confirm`; with `storage: "local"` (or the mock) they go as multipart. Either way a progress bar shows.
- **Takes** with a `videoUrl` play on the Result screen with Media3 (ExoPlayer), with the duration and size. Simulated renders have no video, so the still stays.

## Mock server
```sh
cd server/mock
node server.js                   # http://localhost:8787, renders 24× real time
SPEED=240 node server.js         # faster
node --test test.js              # server tests
```
To use a local server (the mock, or `server/api` with `DEV_MODE=true DEV_SEED=true BALANCE_MODE=simulated npm run dev`), open Settings → Developer and set the server URL to `http://10.0.2.2:8787/`, which is the host machine as seen from the emulator. "Use the MUSE server" there puts the default back. On a real device, set the URL to your computer's LAN IP, and add that IP to `res/xml/network_security_config.xml` (cleartext is only allowed for local hosts). The contract is in `plans/api.md`.

Developer settings also include "Fast · beta engine (Viggle)", which flags Fast · beta on or off, and "Next render fails", which demos the refund, Retry and failure notification.

## Identity LoRA and social accounts
- **Identity LoRA** (`plans/lora-training.md`): Profile → Identity LoRA. Build the 30-shot training set ($0.60), keep or drop shots (flagged ones start dropped, 20+ needed), then train both LoRAs ($6.65, blocked when the balance is too low). Training runs 120× faster in the demo and ends with a notification and a toast. When it's on, `PromptEngine` adds "+ LoRA sienna_v1 (photo)" to the identity layer and "with LoRA sienna_v1 video" to the H3 prompt.
- **Accounts and posting** (`plans/socials.md`): Profile → Accounts connects TikTok, Instagram, Facebook, YouTube and X per model (the mock signs in after a short delay). Result → Post picks accounts, caption, the "Mark as AI-generated" and "Paid partnership" toggles (both off until the user turns them on) and Now or Schedule. Stage 1: "Now" copies the caption and sends `ACTION_SEND` to the platform's app (or the chooser when it isn't installed); the mock has no video file, so the take's still is shared as a placeholder. "Schedule" sets an inexact local alarm whose notification opens the same handoff. Alarms don't survive a reboot. Posts lists Scheduled and Posted with stats.

## Layout
- `core/`: a pure Kotlin module (no Android) with `PromptEngine` (the layered prompt system in `plans/prompt-system.md`) and `Pricing` (steps 4–30, time and cost). Its tests use fixtures generated from the prototype's JS.
- `app/data/`: the `MuseApi` interface, `FakeMuseApi` (in-process), `HttpMuseApi` (Retrofit + OkHttp SSE), the repository, DataStore prefs and the cross-screen drafts.
- `app/ui/`: theme tokens and fonts (bundled in `res/font`, all OFL), the component kit, and one ViewModel with a StateFlow per screen.
- `app/platform/`: notifications, scheduled-post alarms, share handoff and Photo Picker media reading.

The only bundled sample images are the character reference images. Source clips are never bundled, so clip thumbnails use neutral placeholders, or a frame from the user's own picked clip.
