# MUSE for Mac

The native macOS studio app for MUSE: create original AI models from your own reference images, make outfit sets and photoshoots, and swap a model into real short clips. This build runs every screen and flow against a mock backend. It makes no GPU or RunPod calls.

- SwiftUI, macOS 14+, Observation (`@Observable`), no third-party dependencies.
- `MuseCore/`: a Swift package with all the pure logic (models, pricing, prompt engine, API protocol, in-process fake backend, URLSession HTTP client). It has no SwiftUI or AppKit, so it also builds and tests on Linux.
- `Muse/`: the app (screens, the four themes, menus, notifications, drag and drop).
- `project.yml`: the XcodeGen spec. The `.xcodeproj` is generated and isn't committed.

## Build and run on a Mac

```bash
brew install xcodegen          # once
cd mac
xcodegen generate              # writes Muse.xcodeproj
open Muse.xcodeproj            # then choose the "Muse" scheme and press ⌘R
```

You need Xcode 15.4 or later (CI uses Xcode 16 on macos-15). There's no signing team set, so Xcode signs locally with "Sign to Run Locally". From the command line:

```bash
xcodebuild -project Muse.xcodeproj -scheme Muse -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
codesign --force --deep --sign - build/Build/Products/Release/MUSE.app   # ad-hoc sign so it launches on Apple silicon
open build/Build/Products/Release/MUSE.app
```

The CI artifact (`MUSE-mac.zip` from the `mac` workflow) is ad-hoc signed but not notarised. After unzipping, right-click MUSE.app and choose Open the first time, or run `xattr -dr com.apple.quarantine MUSE.app`.

### Tests

```bash
cd mac/MuseCore
swift test
```

The pricing tests check every value against fixtures produced by running the prototype JavaScript (`Tests/MuseCoreTests/Fixtures/gen_desktop_fixture.js` regenerates them from `prototype/desktop/desktop.js`), plus the Android app's reference fixture. To also run the contract test against the real mock server:

```bash
(cd server/mock && PORT=8799 node server.js &)
cd mac/MuseCore && MUSE_MOCK_URL=http://localhost:8799 swift test
```

## Point the app at the mock server

By default the app uses the in-process fake backend (`FakeMuseAPI`), so it works with no server running. To use the shared Node mock server (`server/mock`, contract in `plans/api.md`):

1. Start it: `cd server/mock && node server.js` (it listens on `http://localhost:8787`, renders 24× faster than real time).
2. In the app, open **Settings → Developer**, choose **HTTP server**, check the base URL (default `http://localhost:8787`) and press **Reconnect**. **Test** checks the connection.

Settings → Developer also has **Fail next** (the next render fails at step 3 and is refunded, so you can see the failure card and notification) and **Reload**. The app allows plain HTTP to local addresses only (`NSAllowsLocalNetworking`). A remote server needs HTTPS.

## What's in the app

Every screen from the approved desktop prototype (`prototype/desktop`):

- Sign in and sign up (Apple and Google buttons are mocked; sign-up needs both attestations, unticked by default).
- Sidebar with ⌘1–7, title bar with the ⌘K command palette, the live job chip, theme dots, sound and account menu.
- Home, Models, model profile (character sheet with Replace / Retake with AI, outfit sets, never-add list), New model (Basics → Character sheet: drop images, auto-sorted into slots, "Move to" another slot, optional "Fill missing angles").
- Video studio: source clip from drag and drop or the open panel (duration, size and fps read with AVFoundation, poster frame grabbed), clip checks, source → model preview, timeline, the inspector (model, outfit, engine, steps 4–30 with live time and cost, takes, background, audio, lip sync, prompt) and Generate. Generate is blocked when the clip fails its checks or the balance is too low.
- Photoshoot with the Scene / Camera / Light / Prompt inspector (direction, Lock look, final prompt by slot, Copy, Edit as text).
- Queue table with GPU status, today's spend against the cap, the failed-job card (Retry / Dismiss), and per-job menus.
- Gallery with Tests and Final, multi-select and side-by-side Compare; Result with Approve, Discard, Retake with changes, Export (saved to `~/Downloads/MUSE`, toast "Exported 1080×1920"; no label is added) and Post.
- **Identity LoRA** per model (`plans/lora-training.md`): profile card → Build training set ($0.60, 30 shots) → review grid (click to keep or drop; tattoo / ring / choker / face-drift shots are flagged and start dropped, and you can bring them back; 20+ kept to train) → Train both LoRAs ($6.65, blocked when the balance is too low) with photo and video progress bars and a notification → Done: before/after, "Use in new renders" (on by default), Retrain. While it's on, the prompt engine's identity layer adds "+ LoRA sienna_v1 (photo)" and the H3 prompt "LoRA sienna_v1 video" (in MuseCore, so the exact prompt saved with each job names the version).
- **Social accounts and posts** (`plans/socials.md`): an Accounts grid on the profile (TikTok, Instagram, Facebook, YouTube, X; Connect / Disconnect), a Post sheet from Result or a gallery tile (accounts, caption, "Mark as AI-generated" and "Paid partnership", both off unless you turn them on, Now or Schedule), and a Posts page (⌘7) with Scheduled / Posted and stats. This is stage 1: Post now saves the export and shows it in Finder, copies the caption, and opens each platform's upload page; Schedule posts a notification at that time, and clicking it does the same handoff. Result → ⋯ → Share… opens the system share sheet.
- Outfit set sheet (Describe it / From a photo / My own set), Settings (theme previews, render defaults, costs and limits, notifications, developer, About with the MiniMax H3 credit) and Credits.
- Native notifications (`UNUserNotificationCenter`, with `UNNotificationSound.default`) when a job finishes or fails, when a LoRA is trained, when the balance drops below $5, and for scheduled posts.
- Interface sounds: the prototype's synthesised per-theme sounds (`SND` in `prototype/app/app.js`), rendered to PCM by `MuseCore/SoundSynth.swift` (same oscillators, exponential pitch ramps and band-passed noise as the Android port, normalised to a peak of 0.7, 0.45 for ticks) and played through AVAudioEngine from buffers rendered once per theme. Taps, ticks, navigation, Generate, done and theme changes each have a sound; the Sound toggle in the title bar turns them off.
- Menu bar: File (⌘N new video, ⇧⌘N new model, ⌘O choose clip), Go (⌘1–7, ⌘K), Render (⌘↵ generate), Theme, and ⌘, for Settings. ← → change the steps in the video studio, and Esc closes overlays.

Four themes (Editorial, Camera Body, Soft Tactile, Creator Pop) change layout details as well as colours: corner shapes, borders, soft or offset shadows, the steps dial and viewfinder corners in Camera Body, the blue sidebar and stickers in Creator Pop. The Google Fonts are bundled in `Muse/Resources/Fonts` with their licences (SIL OFL; Permanent Marker is Apache 2.0).

The prototype's sample photos are not bundled (some come from test footage), so sample images are drawn as placeholder art. Images you upload and clips you drop in are shown as they are.

## Signing and notarisation (for distribution)

This build is unsigned. To ship it outside the App Store you need:

1. An Apple Developer Program membership and a **Developer ID Application** certificate in the build machine's keychain.
2. In `project.yml`, set `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE: Automatic` (or the certificate name in `CODE_SIGN_IDENTITY`) and `ENABLE_HARDENED_RUNTIME: YES`. Add an entitlements file if you turn on the App Sandbox (it then needs `com.apple.security.network.client` and `com.apple.security.files.user-selected.read-only`).
3. Archive and export with the Developer ID method (`xcodebuild archive` + `xcodebuild -exportArchive`).
4. Notarise and staple:

   ```bash
   xcrun notarytool store-credentials muse-notary --apple-id <id> --team-id <TEAM> --password <app-specific-password>
   ditto -c -k --keepParent MUSE.app MUSE.zip
   xcrun notarytool submit MUSE.zip --keychain-profile muse-notary --wait
   xcrun stapler staple MUSE.app
   ```

In CI, store the certificate (.p12) and the notary credentials as repository secrets and import them into a temporary keychain before archiving.
