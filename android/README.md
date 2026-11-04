# MUSE for Android

This is the native Kotlin and Jetpack Compose app, built from the approved web prototype (`prototype/app`). It has four themes (Editorial, Camera Body, Soft Tactile and Creator Pop), and each one has its own layouts, motion and sounds. It has no real GPU calls: debug builds run against an in-process fake backend by default, and can switch to the Node mock server.

## Build
Requirements: JDK 21 and the Android SDK (platform 36, build-tools 36). Put the SDK path in `local.properties` as `sdk.dir=/path/to/android-sdk`.

```sh
cd android
./gradlew assembleDebug          # → app/build/outputs/apk/debug/app-debug.apk
./gradlew :core:test             # prompt engine + pricing (checked against prototype/app/app.js)
./gradlew :app:testDebugUnitTest # fake backend, HTTP client vs server/mock (needs node), screenshot tests
./gradlew :app:recordRoborazziDebug --tests 'studio.muse.app.ScreenshotTest'   # PNGs → app/build/outputs/roborazzi/
```

The build pulls Maven Central artifacts through Google's mirror (`maven-central.storage-download.googleapis.com`), because Maven Central rate-limits shared IPs.

## Install
```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
The minimum version is Android 8.0 (API 26). On Android 13 and later, the app asks for notification permission the first time you tap Generate. It uses that permission to tell you when a render finishes or fails.

## Mock server
```sh
cd server/mock
node server.js                   # http://localhost:8787, renders 24× real time
SPEED=240 node server.js         # faster
node --test test.js              # server tests
```
To use the server from the app, open Settings → Developer and turn off "In-app mock". The default URL is `http://10.0.2.2:8787/`, which is the host machine as seen from the emulator. On a real device, set the URL to your computer's LAN IP, and add that IP to `res/xml/network_security_config.xml` (cleartext is only allowed for local hosts). The contract is in `plans/api.md`.

Developer settings also include "Fast · beta engine (Viggle)", which flags Fast · beta on or off, and "Next render fails", which demos the refund, Retry and failure notification.

## Identity LoRA and social accounts
- **Identity LoRA** (`plans/lora-training.md`): Profile → Identity LoRA. Build the 30-shot training set ($0.60), keep or drop shots (flagged ones start dropped, 20+ needed), then train both LoRAs ($6.65, blocked when the balance is too low). Training runs 120× faster in the demo and ends with a notification and a toast. When it's on, `PromptEngine` adds "+ LoRA sienna_v1 (photo)" to the identity layer and "with LoRA sienna_v1 video" to the H3 prompt.
- **Accounts and posting** (`plans/socials.md`): Profile → Accounts connects TikTok, Instagram, Facebook, YouTube and X per model (the mock signs in after a short delay). Result → Post picks accounts, caption, the "Mark as AI-generated" and "Paid partnership" toggles (both off until the user turns them on) and Now or Schedule. Stage 1: "Now" copies the caption and sends `ACTION_SEND` to the platform's app (or the chooser when it isn't installed); the mock has no video file, so the take's still is shared as a placeholder. "Schedule" sets an inexact local alarm whose notification opens the same handoff. Alarms don't survive a reboot. Posts lists Scheduled and Posted with stats.

## Layout
- `core/`: a pure Kotlin module (no Android) with `PromptEngine` (the layered prompt system in `plans/prompt-system.md`) and `Pricing` (steps 4–30, time and cost). Its tests use fixtures generated from the prototype's JS.
- `app/data/`: the `MuseApi` interface, `FakeMuseApi` (in-process), `HttpMuseApi` (Retrofit + OkHttp SSE), the repository, DataStore prefs and the cross-screen drafts.
- `app/ui/`: theme tokens and fonts (bundled in `res/font`, all OFL), the component kit, and one ViewModel with a StateFlow per screen.
- `app/platform/`: notifications, Photo Picker media reading, and per-theme UI sounds synthesised like the prototype's WebAudio.

The only bundled sample images are the character reference images. Source clips are never bundled, so clip thumbnails use neutral placeholders, or a frame from the user's own picked clip.
