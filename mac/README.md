# MUSE for Mac

The native macOS studio app for MUSE: create original AI models from your own reference images, make outfit sets and photoshoots, and swap a model into real short clips. It talks to the MUSE server (`server/api`) at `https://angelic-elegance-production-c42b.up.railway.app` by default: invite-only accounts, credit wallets, members and studio settings. Renders there are simulated until the server's GPU mode is switched on. Demo mode (Settings → Developer, or "Try demo mode" on the sign-in screen) runs everything in the app with no server.

- SwiftUI, macOS 14+, Observation (`@Observable`), no third-party dependencies.
- `MuseCore/`: a Swift package with all the pure logic (models, pricing, prompt engine, API protocol, in-process fake backend, URLSession HTTP client with presigned uploads). It has no SwiftUI or AppKit, so it also builds and tests on Linux.
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

The pricing tests check every value against fixtures produced by running the prototype JavaScript (`Tests/MuseCoreTests/Fixtures/gen_desktop_fixture.js` regenerates them from `prototype/desktop/desktop.js`), plus the Android app's reference fixture.

Contract tests against a **local** real API (`WarmGpuApiTests`: Keep GPU warm on / Keep warm / off, the owner-only setting and the credit floor; `ApiServerTests`: invite → sign-up → me → wallet → send credit → a member's job charges their wallet → `insufficient_tokens` → take back, caps, switching a member off, sign-out, studio settings, presigned uploads). They create accounts and move credit, so they only run against localhost, never the hosted server:

```bash
(cd server/api && npm ci && PORT=8798 PUBLIC_URL=http://127.0.0.1:8798 node --import tsx scripts/test-server.ts &)
cd mac/MuseCore && MUSE_API_URL=http://127.0.0.1:8798 swift test
```

The older contract test against the Node mock server (`MockServerTests`) also passes against `server/api`:

```bash
(cd server/mock && PORT=8799 node server.js &)
cd mac/MuseCore && MUSE_MOCK_URL=http://localhost:8799 swift test
```

CI (`.github/workflows/mac.yml`) starts both on the runner and runs everything.

## Servers, accounts and credit

- **MUSE server (default).** Sign up needs an **invite code** from the studio owner plus the two attestations; sign in with email and password. With **Remember me** (on by default) the session token is stored in the login **Keychain** (one item per server) and the email is pre-filled next time; with it off, the token stays in memory and quitting signs out. MUSE never stores the password: the fields use the username / password / new-password content types, so macOS Passwords and iCloud Keychain offer to save and AutoFill it. Password fields have a show/hide eye. On launch `GET /v1/auth/me` restores the session; Sign out calls `POST /v1/auth/signout`. API error codes get MUSE's own wording (`invite_required`, `invite_invalid`, `email_taken`, `bad_credentials`, `account_disabled`, `rate_limited`; `unauthorized` sends you back to sign-in).
- **Credit** (was Credits, `GET /v1/wallet`): the app shows US dollars everywhere and never says "tokens". The API counts whole tokens of $0.01 (`TOKEN_USD`); the app shows its `usd` fields, and dollar amounts typed into Send / Take back are rounded to the nearest cent and converted to tokens on the wire. `insufficient_tokens` reads "Not enough credit. Ask the studio owner for more." A `wallet` event (the owner sent or took back credit) refreshes the balance and posts a notification ("You received $5.00"). The owner also sees the RunPod balance, what's available to send and what members hold.
- **Owner only:** **Members** in the sidebar (⌘8): balance and spend per person, **Send credit** and **Take back** (dollar amount and note), the daily cap, switch off/on, and **Invite someone** (`POST /v1/invites`; the code is shown once, **Copy** copies the code and **Share…** opens the share sheet with the server's `shareText`, or the same message built locally with the download link `{server}/get`). **Settings → Studio**: max GPUs, who pays GPU warm-up, the spend caps and the **image engine** (built-in, fal.ai or a custom HTTPS endpoint).
- **Queue:** waiting jobs show their place in line and ETA; "Paused: the studio's GPU credit is low" when the owner's RunPod balance is low; GPU warm-up is its own cost line.
- **Uploads** go through `POST /v1/uploads/presign` → PUT → confirm, with progress in the title bar. If the server has no presigned uploads (server/mock) or the PUT can't reach storage, the app falls back to the multipart upload. A dev server with local storage hands out links to itself (`/storage/local/…`), which works the same way.
- **Takes** with a `videoUrl` play in the Result view (AVKit), with the real length and size; Export downloads the .mp4 to `~/Downloads/MUSE`.

**Settings → Developer** switches between the MUSE server, another URL (a local `server/api` or `server/mock` at `http://localhost:8787`) and **Demo mode** (the in-process `FakeMuseAPI`, where you are the owner of a demo studio with two demo members). Each server keeps its own sign-in. **Test** checks `/health`. **Fail next** (demo, mock and dev servers) makes the next render fail at step 3 and refunds it. The app allows plain HTTP to local addresses only (`NSAllowsLocalNetworking`); a remote server needs HTTPS.

## What's in the app

Every screen from the approved desktop prototype (`prototype/desktop`):

- Sign in and sign up (sign-up needs an invite code on the server and both attestations, unticked by default; the Apple and Google buttons are mocked and only shown in demo mode).
- Sidebar with ⌘1–7, title bar with the ⌘K command palette, the live job chip, theme dots and account menu.
- Home, Models, model profile (character sheet with Replace / Retake with AI, outfit sets, never-add list), New model (Basics → Character sheet: drop images, auto-sorted into slots, "Move to" another slot, optional "Fill missing angles").
- Video studio: source clip from drag and drop or the open panel (duration, size and fps read with AVFoundation, poster frame grabbed), clip checks, source → model preview, timeline, the inspector (model, outfit, engine, steps 4–30 with live time and cost, takes, background, audio, lip sync, prompt) and Generate. Generate is blocked when the clip fails its checks or the balance is too low.
- Photoshoot with the Scene / Camera / Light / Prompt inspector (direction, Lock look, final prompt by slot, Copy, Edit as text).
- Queue table with GPU status, today's spend against the cap, the failed-job card (Retry / Dismiss), and per-job menus.
- Gallery with Tests and Final, multi-select and side-by-side Compare; Result with Approve, Discard, Retake with changes, Export (saved to `~/Downloads/MUSE`, toast "Exported 1080×1920"; no label is added) and Post.
- **Identity LoRA** per model (`plans/lora-training.md`): profile card → Build training set ($0.60, 30 shots) → review grid (click to keep or drop; tattoo / ring / choker / face-drift shots are flagged and start dropped, and you can bring them back; 20+ kept to train) → Train both LoRAs ($6.65, blocked when the balance is too low) with photo and video progress bars and a notification → Done: before/after, "Use in new renders" (on by default), Retrain. While it's on, the prompt engine's identity layer adds "+ LoRA sienna_v1 (photo)" and the H3 prompt "LoRA sienna_v1 video" (in MuseCore, so the exact prompt saved with each job names the version).
- **Social accounts and posts** (`plans/socials.md`): an Accounts grid on the profile (TikTok, Instagram, Facebook, YouTube, X; Connect / Disconnect), a Post sheet from Result or a gallery tile (accounts, caption, "Mark as AI-generated" and "Paid partnership", both off unless you turn them on, Now or Schedule), and a Posts page (⌘7) with Scheduled / Posted and stats. This is stage 1: Post now saves the export and shows it in Finder, copies the caption, and opens each platform's upload page; Schedule posts a notification at that time, and clicking it does the same handoff. Result → ⋯ → Share… opens the system share sheet.
- **Photo templates** (`plans/templates.md`): **Templates** under Photoshoot in the sidebar (⇧⌘T): All / Mine / Public / Favourites, search by name or tag, tag chips, and cards with the cover, name, owner, uses and a Private/Public badge (star to favourite). The detail shows the cover, recent results and **Use**; the owner also gets Duplicate, Edit, Delete, the Public toggle and their own layers. **Use** opens the Photoshoot screen with the template inspector: model and outfit as usual, an optional **Direction** (it replaces the pose and angle draws), **Shuffle** (new variation draws), **Lock look** (off by default, so every shot gets a new seed), a product photo for templates that take one, and **Shoot** ($0.12). In pro mode the prompt view comes from the server (`POST /v1/templates/{id}/prompt`): a template you don't own is one locked line, "Template: <name>", and its layers never reach this Mac. **Save as template** on any photo (Result, its ⋯ menu, a gallery tile) loads the server's draft; you name it, add tags, choose Private (default) or Public, and can edit the layers, after-effects (grade, face motion blur, grain) and the auto-suggested variation pool. A photo made with someone else's template can't be saved (`template_hidden`). Demo mode has the seven starter templates (covers from the bundled Sienna photos) plus two public ones by the demo members.
- **Keep GPU warm** (`plans/backend.md`, `GET/POST /v1/gpu/warm` and `gpu` events in `plans/api.md`): a dedicated H100 so renders start at once instead of after the 3–6 min cold start, billed by the minute from your credit (about $4/hour, boot included; renders on it aren't charged again and show "warm GPU" in the queue). When creating starts (you pick or drop a clip in the video studio, or press Generate) and no warm GPU is running for you, MUSE asks every time: "Warm up a GPU now so your render starts right away? …" [Warm up] [Not now]; Generate goes ahead after either answer. There's also a **Keep GPU warm** switch in the video studio (above Generate), in the title bar, in Render and in ⌘K; every switch-on shows the same cost warning, with no "don't ask again". While it's on: a bar under the title bar on every screen ("GPU warm · 42 min · $2.80 so far · Turn off", or "GPU starting…" while the pod boots), a live indicator with the switch in the title bar, and a flame in the macOS menu bar with Keep warm / Turn off. Five minutes before an idle (20 min without renders) or time-limit (2 h) auto-off, a banner and a notification offer **Keep warm** (it extends the time limit once). Auto-offs (idle, time limit, low credit, the studio's GPU credit, a lost GPU) are told with a toast and a notification. The owner chooses who can use it in **Settings → Studio** (everyone by default). Demo mode runs the same rules in `WarmGpuSim` (MuseCore), with a sped-up boot.
- Outfit set sheet (Describe it / From a photo / My own set), Settings (theme previews, render defaults, costs and limits, Studio for the owner, notifications, developer, About with the MiniMax H3 credit), Credit and Members.
- Native notifications (`UNUserNotificationCenter`, with `UNNotificationSound.default`, also shown with sound while MUSE is in front) when a job finishes or fails, when a LoRA is trained, when the balance drops below $5, for scheduled posts, and for the warm GPU's 5-minute warning (with a **Keep warm** button) and auto-off.
- No interface sounds. Only notifications make a sound (the standard macOS one), and they follow System Settings → Notifications; Settings → Notifications has a button that opens it.
- Menu bar: File (⌘N new video, ⇧⌘N new model, ⌘O choose clip), Go (⌘1–7, ⌘K), Render (⌘↵ generate), Theme, and ⌘, for Settings. ← → change the steps in the video studio, and Esc closes overlays.

Four themes (Editorial, Camera Body, Soft Tactile, Creator Pop) change layout details as well as colours: corner shapes, borders, soft or offset shadows, the steps dial and viewfinder corners in Camera Body, the blue sidebar and stickers in Creator Pop. The Google Fonts are bundled in `Muse/Resources/Fonts` with their licences (SIL OFL; Permanent Marker is Apache 2.0).

The Sienna sample photos are bundled in `Muse/Resources/Samples`; other sample images are drawn as placeholder art. Images you upload and clips you drop in are shown as they are.

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
