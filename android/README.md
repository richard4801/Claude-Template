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

## Accounts, credit and the owner screens
- **Sign-up is invite-only.** The form has an **Invite code** field (`MUSE-XXXX-XXXX-XXXX`; the owner's first code, `OWNER_INVITE_CODE` on the server, is free text) and the two required attestation boxes. Every API error code has plain wording (`ErrorText.kt`); `unauthorized` and `account_disabled` send you back to sign-in.
- **Session:** the token is encrypted with an AES-GCM key in the Android Keystore before it goes into DataStore (`Prefs.kt`). On launch `GET /v1/auth/me` restores the session and the role. Sign out calls `POST /v1/auth/signout`.
- **Sign in:** every password field has an eye to show or hide it (hidden by default). **Remember me** (on by default) keeps the session and the email across restarts; off keeps the token in memory only, so closing the app signs you out, and the email isn't saved. The app never stores the password: the fields are tagged for Android autofill (`ContentType.Username`/`Password`, sign-up `NewPassword`) and a successful sign-in calls `AutofillManager.commit()`, so the phone's password manager offers to save and fill it.
- **Money is shown in US dollars everywhere** ("Credit", "Balance"); the word "tokens" never appears. The API still counts whole tokens (`TOKEN_USD` = $0.01): the app shows the API's `usd` fields, and Send / Take back amounts typed in dollars (`5`, `5.50`) are rounded to the nearest cent and converted to tokens (`data/Credit.kt`). Server messages that still count tokens are reworded in dollars (`ErrorText.kt`).
- **Credit** (Settings, or the balance pill on Home) reads `GET /v1/wallet`: a member sees their balance, holds and today/month spend; the owner sees the RunPod balance and what's available to send. A Generate a member can't afford says "Not enough credit. Ask the studio owner for more." A `wallet` live event refreshes it and shows "You received $5.00 from <studio>" (the event doesn't name the sender).
- **Queue:** waiting jobs show their place in line and ETA, `blocked: owner_balance_low` shows "Paused: the studio's GPU credit is low", and GPU warm-up is its own line on the cost.
- **Owner only** (Settings → Studio, shown when `role == owner`): **Members** (balance, spend, last active; Send credit / Take back in dollars with a note, daily cap, switch an account off), **Invite someone** (makes a code: **Share** sends the server's `shareText` with the download link `<server>/get`, the code and the email, or builds the same text for an older server; **Copy** copies the code only) and **Studio settings** (max GPUs, who pays GPU warm-up, caps, and the image engine: simulated, fal or a custom https engine).
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

## Video studio stage (owner request 2026-11-05)
- **New video** starts empty on a server: a dashed "Choose a clip · up to 15s works best · 9:16 · one person" area. "Use the sample clip" and "Preview: what a failing clip looks like" are demo mode's only. Without a clip the Video studio's canvas shows an empty "No clip yet" placeholder.
- **The canvas is the live output.** Generate keeps you in the Video studio (a toast offers the queue). While the render started there for this clip, model and outfit runs, the canvas shows the clip's first frame (or the model) blurred and softly moving with "Waiting to start" / "#2 in line · about 9 min" / "Rendering · about 2 min", a progress bar, the percent and the price. When it's ready the take plays (muted loop, unmute top right, take switcher 1 · 2 · 3) with **Open**, **Edit video** and **Generate again**; a failed render shows its member-safe reason and **Try again**. The state comes from the live job and take events (`ui/screens/StudioStage.kt`, `StudioStageTest`); picking another clip, model or outfit puts the source and target back.
- Screenshots: `./gradlew :app:recordRoborazziDebug --tests 'studio.muse.app.StudioStageScreenshotTest'` → `stage_<theme>_<state>_<390|360>.png` (idle, queued, rendering, ready, failed, source_empty, direct_empty).

## Identity LoRA and social accounts
- **Identity LoRA** (`plans/lora-training.md`): Profile → Identity LoRA. Build the 30-shot training set ($0.60), keep or drop shots (flagged ones start dropped, 20+ needed), then train both LoRAs ($6.65, blocked when the balance is too low). Training runs 120× faster in the demo and ends with a notification and a toast. When it's on, `PromptEngine` adds "+ LoRA demo_v1 (photo)" to the identity layer and "with LoRA demo_v1 video" to the H3 prompt.
- **Accounts and posting** (`plans/socials.md`): Profile → Accounts connects TikTok, Instagram, Facebook, YouTube and X per model (the mock signs in after a short delay). Result → Post picks accounts, caption, the "Mark as AI-generated" and "Paid partnership" toggles (both off until the user turns them on) and Now or Schedule. Stage 1: "Now" copies the caption and sends `ACTION_SEND` to the platform's app (or the chooser when it isn't installed); the mock has no video file, so the take's still is shared as a placeholder. "Schedule" sets an inexact local alarm whose notification opens the same handoff. Alarms don't survive a reboot. Posts lists Scheduled and Posted with stats.

## Photo templates (`plans/templates.md`)
- **Photoshoot → Templates** (the "Templates" link in the top bar, the menu, or the strip on the Model tool) opens the library: All / Mine / Public / Favourites, search by name or tag, tag chips, and cards with the cover, name, owner, uses and a Private/Public badge. The list is `GET /v1/templates?scope=all`; tabs, search and tags filter it on the phone.
- **Template detail:** the cover, recent results, Favourite and **Use template**. The owner also gets the Public toggle, Duplicate, Edit (name, tags, layers, colour grade, variation pool) and Delete, plus a read-only view of the prompt layers. Everyone else sees a note that the look stays with its maker.
- **Using a template:** pick the model and outfit, an optional product photo (Product moment), an optional **Direction** ("how should she be placed?", which replaces the pose and angle draws), **Lock look** (off by default), **Shuffle** (a new `shuffleSeed`) and **Shoot 4 · $0.12**. The app sends only the template id and these choices; the server builds the prompt. **Show prompt** asks the server (`POST /v1/templates/{id}/prompt`): for someone else's template the hidden layers come back as one locked "Template: <name>" line.
- **Save as template** (Result → ⋯ or "Save look" on any photo): name, tags, Private (default) or Public, and the auto-suggested variation pool, editable before saving (`POST /v1/templates/draft`, then `POST /v1/templates {fromShotId}`). A photo made with someone else's template can't be saved (`template_hidden`).
- Demo mode has the seven starters (owned by you) and two public templates from "Maya", so both views can be tried without a server.

## Shoot references and the prompt library (`plans/api.md`, 2026-11-05)
- **The server builds the photoshoot prompt.** Shoot sends the choices (scene, camera, light, grade, direction, Presets, Lock look, references) and sends `prompt` only while "Edit as text" is on (exactly as written). The Final prompt box, Copy, Edit as text and the Shoot price come from `POST /v1/shoots/preview`, refetched about 300 ms after any change and after a `prompts` event. The app's own `PromptEngine` is only the fallback while the preview loads or when the server can't be reached (a note says so), and it is checked against the server's `core/src/test/resources/shoot_prompt_fixture.json`.
- **References** (Photoshoot → Scene, and Use template): up to 3 photos from the Photo Picker, uploaded first. Each has three chips, **Pose & framing**, **Look & colour** and **Scene** (a new one starts on the first guide the others don't use; at least one stays on), Remove, and a badge from the preview: "Image n" (its number in the prompt lines) or "Not sent" when the shot can't take another image. They go as `refs` on shoots and template shoots; her face, body and outfit always come from her own references. The price counts every image sent.
- **Settings → Prompts** (owners only): every prompt the server sends to a model, grouped, with an "Edited" badge. The editor has the current text, placeholder chips (tap to add, * = needed), the server's `prompt_invalid` message inline, a live preview (`POST /v1/prompts/preview`: the line and the whole prompt for the sample model), **Save** (`PUT`), **Undo changes** and **Reset to default** (`DELETE`, after a confirm). Saves from another device arrive as `prompts` events. Demo mode uses the server's entries and defaults from `app/src/main/resources/prompt_library.json`, and its shoot preview follows edits of the house style, the never-add base list and the reference lines.

## Keep GPU warm (`plans/backend.md`)
- **Nudge:** when creating starts (a clip picked or uploaded in New video, or the Video studio opened) and no GPU is warm for you, MUSE asks: "Warm up a GPU now so your render starts right away? About $4/hour from your credit while it's on, and it turns off by itself after 20 min without renders." **Warm up** / **Not now**. Once per creating flow: going from New video to the Video studio doesn't ask again; the next time you start creating, it does (`data/WarmUi.kt`).
- **Switch:** "Keep GPU warm" in the Video studio. Every switch-on shows the same cost warning to confirm (no "don't ask again"); switching off is immediate. Members see it dimmed when the owner keeps it to themselves (Studio settings → Who can keep a GPU warm).
- **While it's on:** a bar above every screen, "GPU warm · 42 min · $2.80 so far · Turn off" ("Starting… · 2 min · …" while the pod boots, 3–6 min), updated live; an ongoing, silent notification with a running clock and **Turn off** (its own "Warm GPU" channel); and the 5-minute warning before an idle or time-limit auto-off, as a notification and an in-app banner, both with **Keep warm**. When it turns itself off, a toast says why and what it cost.
- The ongoing notification is posted by the app, not a foreground service: if Android kills the app it stays until the app runs again (the GPU itself is managed by the server either way). Demo mode simulates it ($3.99/h from the demo balance).

## Layout
- `core/`: a pure Kotlin module (no Android) with `PromptEngine` (the layered prompt system in `plans/prompt-system.md`) and `Pricing` (steps 4–30, time and cost). Its tests use fixtures generated from the prototype's JS.
- `app/data/`: the `MuseApi` interface, `FakeMuseApi` (in-process), `HttpMuseApi` (Retrofit + OkHttp SSE), the repository, DataStore prefs and the cross-screen drafts.
- `app/ui/`: theme tokens and fonts (bundled in `res/font`, all OFL), the component kit, and one ViewModel with a StateFlow per screen.
- `app/platform/`: notifications, scheduled-post alarms, share handoff and Photo Picker media reading.

The only bundled sample images are the character reference images. Source clips are never bundled, so clip thumbnails use neutral placeholders, or a frame from the user's own picked clip.
