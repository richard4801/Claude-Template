# MUSE for Mac

The native macOS studio app for MUSE: create original AI models from your own reference images, make outfit sets and photoshoots, and swap a model into real short clips. It talks to the MUSE server (`server/api`) at `https://angelic-elegance-production-c42b.up.railway.app` by default: invite-only accounts, credit wallets, members and studio settings. Demo mode (Settings → Developer, or "Try demo mode" on the sign-in screen) runs everything in the app with no server.

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

`PhotoPricingTests` checks the photo estimates against `photo_pricing_fixture.json` (a byte-for-byte copy of Android's), and `MemberTextTests` that member-facing wording has no GPU, warm-up, steps, start-up or provider names.

Contract tests against a **local** real API (`WarmGpuApiTests`: Keep add-on engine ready on / Keep ready / off, owner only; `ApiServerTests`: invite → sign-up → me → wallet → send credit → a member's job charges their wallet → `insufficient_tokens` → take back, caps, switching a member off, sign-out, studio settings, the studio balance and top-ups, Engines for the owner only, presigned uploads). The owner helper records a top-up on the local server when the studio balance is short. They create accounts and move credit, so they only run against localhost, never the hosted server:

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
- **Credit** (was Credits, `GET /v1/wallet`): the app shows US dollars everywhere and never says "tokens". The API counts whole tokens of $0.01 (`TOKEN_USD`); the app shows its `usd` fields, and dollar amounts typed into Send / Take back are rounded to the nearest cent and converted to tokens on the wire. `insufficient_tokens` reads "Not enough credit. Ask the studio owner for more." A `wallet` event (the owner sent or took back credit) refreshes the balance and posts a notification ("You received $5.00"). The owner also sees the **studio balance** (what they've added with top-ups, minus everything spent), what's available to send and what members hold, and records top-ups in Credit (**Add top-up**: amount, note, paid on; "Added $20.00"). "Add your first top-up" shows until there is one.
- **Owner only:** **Members** in the sidebar (⌘8): balance and spend per person, **Send credit** and **Take back** (dollar amount and note), the daily cap, switch off/on, and **Invite someone** (`POST /v1/invites`; the code is shown once, **Copy** copies the code and **Share…** opens the share sheet with the server's `shareText`, or the same message built locally with the download link `{server}/get`). **Settings → Studio**: the spend caps. **Settings → Engines** (the only place provider names appear): each engine's status (Replicate, RunPod; key set, ready / out of credit), the add-on engine's max GPUs, who pays start-up, **Keep add-on engine ready** with its idle and time limits, the **image engine** (Replicate, built-in, fal.ai or a custom HTTPS endpoint) and the model credits (MiniMax H3, SeedVR2, LatentSync). When an engine's own account runs out of credit the job fails with a refund and the owner gets a notice that opens Engines.
- **Queue:** jobs show outcomes only: "Waiting to start", "#2 in line · about 9 min · $0.14", "Rendering · about 2 min · $0.14", "Waiting to start · $0.14". Failures read "Something went wrong · you weren't charged" (or the content-filter, too-long and busy wordings). Server text that names a GPU, steps or a provider (older servers) is replaced by these (`MemberText`).
- **Uploads** go through `POST /v1/uploads/presign` → PUT → confirm, with progress in the title bar. If the server has no presigned uploads (server/mock) or the PUT can't reach storage, the app falls back to the multipart upload. A dev server with local storage hands out links to itself (`/storage/local/…`), which works the same way.
- **Takes** with a `videoUrl` play in the Result view (AVKit), with the real length and size; Export downloads the .mp4 to `~/Downloads/MUSE`.

**Settings → Developer** switches between the MUSE server, another URL (a local `server/api` or `server/mock` at `http://localhost:8787`) and **Demo mode** (the in-process `FakeMuseAPI`, where you are the owner of a demo studio with two demo members). Each server keeps its own sign-in. **Test** checks `/health`. **Fail next** (demo, mock and dev servers) makes the next render fail at step 3 and refunds it. The app allows plain HTTP to local addresses only (`NSAllowsLocalNetworking`); a remote server needs HTTPS.

## What's in the app

Every screen from the approved desktop prototype (`prototype/desktop`):

- Sign in and sign up (sign-up needs an invite code on the server and both attestations, unticked by default; the Apple and Google buttons are mocked and only shown in demo mode).
- Sidebar with ⌘1–7, title bar with the ⌘K command palette, the live job chip, theme dots and account menu.
- Home, Models, model profile (character sheet with Replace / Retake with AI, outfit sets, never-add list), New model (Basics → Character sheet: drop images, auto-sorted into slots, "Move to" another slot, optional "Fill missing angles").
- Video studio: source clip from drag and drop or the open panel (duration, size and fps read with AVFoundation, poster frame grabbed), clip checks, source → model preview, timeline, the inspector (model, outfit, Render, Add-ons, takes, background, audio, lip sync, prompt) and Generate ("Generate · 7 s · $0.56", or "Generate · 10 min · $0.67" for Edit and Fast). Generate is blocked when the clip fails its checks or the balance is too low.
- **Render and Add-ons** (`plans/api.md` "App clean-up" §2): **Render** is Draft (quick preview · 768P, the default; the server's `features.video.defaultQuality` wins), Standard (768P) or HD (2K); **Add-ons** are **Edit** (swaps her into every frame of the whole clip), **Fast · beta** (shown only when the server offers it) and **Upscale** (1080p / 2K / 4K on a finished take; greyed "Coming soon" until the server ships it, `upscale_unavailable`). Every option renders the whole clip; steps and "First 5.2s" are gone. Each option shows its live price, and the line under the picker reads "about $0.14 · 7 s" for Draft (+ " · 2 takes"), "about $0.67" for Edit and Fast. Draft / Standard / HD bill per whole output second (the clip rounded up, 4–15 s, × $0.02 / $0.08 / $0.13, × takes); `ReplicateTests` checks every row of the shared `replicate_pricing_fixture.json`. Lip sync and the background photo are Edit only. Result shows **Upscale** with the three sizes on a finished render take.
- **Photo prices are estimates** ("Shoot 4 · about $0.46", "Generate 4 angles · about $0.19", "about $0.10" an angle, LoRA training set "about $3.03") from the server's `features.photo` (or the contract's defaults); the receipt shows the exact settled amount (the shoot result line, the gallery, Credit).
- **Video editor** (`plans/video-editor.md`): **Edit video** on any video take with a video (Result, the Gallery tile's menu). Trim (handles on the frame-thumbnail timeline, snapped to frames, times to 1/100 s), Split at the playhead, Delete a part, Speed 0.5×–2× per part or for the whole video (sound keeps its pitch), Mute the whole video or a part, Undo / Redo (100 steps), Reset, live preview. Keys: space play/pause, ←/→ one frame, S split, ⌫ delete, ⌘Z / ⇧⌘Z. Everything runs on the Mac with AVFoundation (AVMutableComposition, `scaleTimeRange`, AVAssetExportSession H.264/AAC at the source size and frame rate); Export shows progress with Cancel, uploads the .mp4 and a JPEG frame with presigned uploads, and saves a new **Edited** take linked to the original (`POST /v1/takes/{id}/versions` with the edit list). The original is kept, and opening an edited take re-opens its edit list on its source. Free. The edit-list math is in MuseCore (`VideoEdit.swift`, `VideoEditTests`).
- Photoshoot with the Scene / Camera / Light / Prompt inspector (direction, Lock look, final prompt by slot, Copy, Edit as text).
- Queue table with what's rendering or waiting, today's spend against the cap, the failed-job card (Retry / Dismiss), and per-job menus.
- Gallery with Tests and Final, multi-select and side-by-side Compare; Result with Approve, Discard, Retake with changes, Export (saved to `~/Downloads/MUSE`, toast "Exported 1080×1920"; no label is added) and Post.
- **Identity LoRA** per model (`plans/lora-training.md`): profile card → Build training set (about $3.03, 30 shots, an estimate) → review grid (click to keep or drop; tattoo / ring / choker / face-drift shots are flagged and start dropped, and you can bring them back; 20+ kept to train) → Train both LoRAs ($6.65, blocked when the balance is too low) with photo and video progress bars and a notification → Done: before/after, "Use in new renders" (on by default), Retrain. While it's on, the prompt engine's identity layer adds "+ LoRA demo_v1 (photo)" and the H3 prompt "LoRA demo_v1 video" (in MuseCore, so the exact prompt saved with each job names the version).
- **Social accounts and posts** (`plans/socials.md`): an Accounts grid on the profile (TikTok, Instagram, Facebook, YouTube, X; Connect / Disconnect), a Post sheet from Result or a gallery tile (accounts, caption, "Mark as AI-generated" and "Paid partnership", both off unless you turn them on, Now or Schedule), and a Posts page (⌘7) with Scheduled / Posted and stats. This is stage 1: Post now saves the export and shows it in Finder, copies the caption, and opens each platform's upload page; Schedule posts a notification at that time, and clicking it does the same handoff. Result → ⋯ → Share… opens the system share sheet.
- **Model tools** (`plans/api.md` "Model tools"):
  - **Character sheet has 7 images**, shown as two groups: face close-ups (Face · front, Face · ¾, Face · profile) and full body (front, ¾, side, back). The face ¾ slot is optional, like a missing face close-up.
  - **Enhance** (profile → Character sheet → Enhance): realism Off / Subtle / Balanced / Strong and upscale Off / 2× / 4× (either can be off, not both), the total estimate before you start ("6 images · about $0.26"), then review each image with a before/after slider: Keep, Reject or Retry one. Kept images replace their slots; the old sheet is saved as a previous version (**Versions**, restorable; restoring saves the current sheet first).
  - **Dress up** (profile → Dress up): drop one outfit-sheet photo and one button regenerates every sheet image in that outfit (full body gets the whole outfit, face close-ups the visible accessories). Engine **Option A / Option B / Both** (members see only these labels; the owner also sees the model behind each). Both shows the results side by side: keep A or B per image, or the whole set. The price shows first; the result is saved as a new outfit (with its face close-ups) and the original sheet is never changed.
  - **Image models** (owner only, Settings → Engines): the model for every image step (New shots, Edits, Enhance · realism / upscale, Dress up · Option A / B) with its price line and compatibility. **Change** opens a searchable catalog served by the server (Replicate collections or search; name, owner, description, runs, price line, compatible?), or paste owner/model; the advanced view shows how MUSE fills the model's inputs and lets the owner set extra inputs (never the safety checker). **Default** goes back to the contract's model. A small owner-only **Model** chooser on Shoot, Enhance and Dress up overrides it for one run (`models` in the request); members never see it.
  - **Archive** (owner, profile ⋯ → Archive model): she disappears from every list and picker; **Settings → Archived models** restores her. New work on an archived model reads "This model is archived · restore her in Settings → Archived models".
  - `ModelToolsTests` cover decoding every new shape, the any-model estimates (per unit, by time, unknown), labels and price lines, request encoding, and the demo flows (Enhance review → apply → restore, Dress up Both → whole-set pick → new outfit, discard and failure releasing the hold, archive, owner-only checks).
- **Photo templates** (`plans/templates.md`): **Templates** under Photoshoot in the sidebar (⇧⌘T): All / Mine / Public / Favourites, search by name or tag, tag chips, and cards with the cover, name, owner, uses and a Private/Public badge (star to favourite). The detail shows the cover, recent results and **Use**; the owner also gets Duplicate, Edit, Delete, the Public toggle and their own layers. **Use** opens the Photoshoot screen with the template inspector: model and outfit as usual, an optional **Direction** (it replaces the pose and angle draws), **Shuffle** (new variation draws), **Lock look** (off by default, so every shot gets a new seed), a product photo for templates that take one, and **Shoot** (about $0.46). In pro mode the prompt view comes from the server (`POST /v1/templates/{id}/prompt`): a template you don't own is one locked line, "Template: <name>", and its layers never reach this Mac. **Save as template** on any photo (Result, its ⋯ menu, a gallery tile) loads the server's draft; you name it, add tags, choose Private (default) or Public, and can edit the layers, after-effects (grade, face motion blur, grain) and the auto-suggested variation pool. A photo made with someone else's template can't be saved (`template_hidden`). Demo mode has the seven starter templates (placeholder covers) plus two public ones by the demo members.
- **Keep add-on engine ready** (was Keep GPU warm; `GET/POST /v1/gpu/warm`, owner only): a switch in Settings → Engines with the cost warning on every switch-on ("Keeps the add-on engine ready so Edit renders start right away. About $4/hour from the studio balance …"), its idle and time limits, and "Keep ready" when the 5-minute warning is due. While it's on, the owner sees a small indicator in the title bar ("Add-on engine ready · 42 min · $2.80 · Turn off"). Members never see a nudge, switch, bar, menu-bar item, notification or warning (the server answers them `owner_only`). Demo mode runs the same rules in `WarmGpuSim` (MuseCore).
- Outfit set sheet (Describe it / From a photo / My own set), Settings (theme previews, render defaults, costs and limits, Studio and Engines for the owner, notifications, developer, About), Credit and Members.
- Native notifications (`UNUserNotificationCenter`, with `UNNotificationSound.default`, also shown with sound while MUSE is in front) when a job finishes or fails, when a LoRA is trained, when the balance drops below $5, and for scheduled posts.
- No interface sounds. Only notifications make a sound (the standard macOS one), and they follow System Settings → Notifications; Settings → Notifications has a button that opens it.
- Menu bar: File (⌘N new video, ⇧⌘N new model, ⌘O choose clip), Go (⌘1–7, ⌘K), Render (⌘↵ generate), Theme, and ⌘, for Settings. Esc closes overlays.

Four themes (Editorial, Camera Body, Soft Tactile, Creator Pop) change layout details as well as colours: corner shapes, borders, soft or offset shadows, viewfinder corners in Camera Body, the blue sidebar and stickers in Creator Pop. The Google Fonts are bundled in `Muse/Resources/Fonts` with their licences (SIL OFL; Permanent Marker is Apache 2.0).

No sample photos are bundled. Demo mode has two neutral demo models ("Demo model", "Demo model B") whose stills are drawn as silhouette placeholders, and the sign-in splash is an abstract gradient with the MUSE wordmark (no person). Images you upload and clips you drop in are shown as they are.

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
