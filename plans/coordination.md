# Parallel build coordination

_Started 2026-11-05._ Several Claude sessions build MUSE features at the same time. This file is the shared source of truth: **read it before you start, pull it often, and keep your own section current** (on your branch; the coordinator merges). Message the other sessions directly (`send_message` to their session ids, below) when something you do affects them. Everyone reports to the coordinator when done.

## Coordinator
- Session `session_01Py2rxp4dEicUCVHRmLavgE` (the owner's main session). It owns `claude/ecstatic-rubin-2egjfb` (the branch Railway deploys to production) and merges finished feature branches into it after review. Send it: blocking questions, contract changes, and your final report.

## Workstreams
| # | Workstream | Session | Branch | Owns (write) |
|---|---|---|---|---|
| 1 | **AI suite core** (video model registry, adapters, Shot API, Camera preset compiler, costs/caps, mocks) | `session_01Py2rxpmMTMha4CSFyx4bX3` | `claude/muse-suite-core` | `server/api/src/suite/**`, `server/api/src/routes/suite.ts`, `server/api/test/suite*.test.ts`, migration **0007**, `plans/ai-suite.md`, the "AI suite" section of `plans/api.md` |
| 2 | **MCP server + Blender bridge** (MUSE remote MCP, camera sessions, in-app "Direct with Claude" chat backend, Mac Blender relay, setup docs) | `session_01Py2rxpzK498R32918DPNY5` | `claude/muse-mcp-bridge` | `server/api/src/mcp/**`, `server/api/src/camera/**`, `server/api/src/routes/mcp.ts`, `server/api/src/routes/camera.ts`, `server/api/test/mcp*.test.ts`, `server/api/test/camera*.test.ts`, migration **0008**, `mac/MuseCore/Sources/MuseCore/Blender*.swift`, `mac/Muse/App/Blender*.swift`, `plans/mcp-bridge.md`, the "MCP & camera sessions" section of `plans/api.md` |
| 3 | **Editor engine v2** (multitrack edit list, text/captions/audio/keyframes/transitions, AI helpers: auto-captions, silence/filler cuts, background removal; Android + Mac composition engines) | `session_01Py2rxnDfuHM43WWEtDLf1v` | `claude/muse-editor-v2` | `server/api/src/editor/**`, `server/api/src/routes/editorAi.ts`, `server/api/test/editor*.test.ts`, migration **0009**, `android/core/src/main/kotlin/studio/muse/core/edit/**`, `android/app/src/main/kotlin/studio/muse/app/platform/edit/**`, `mac/MuseCore/Sources/MuseCore/Edit/**`, `mac/Muse/App/Edit/**`, `plans/video-editor.md` (v2 section), the "Editor v2" section of `plans/api.md` |
| 4 | **Prompt scripts** (every prompt becomes a script: inputs → rules → blocks; system sections separate from the user's own text; lip-sync fix: talking auto-detect + switch, strip/restore audio, beat-only audio) | `session_01Py2rxnSji59d98ivK5LDYD` | `claude/muse-prompt-scripts` | `server/api/src/prompt/**` (after the coordinator's image-refs/collage commit lands), `server/api/src/audio/**`, `server/api/test/prompt*.test.ts`, migration **0010**, the Prompts editor screens (`android/.../ui/screens/PromptScreens.kt`, `mac/Muse/Views/Prompt*.swift`), `plans/prompt-scripts.md`, the "Prompt scripts" section of `plans/api.md`. Workstream 1 builds suite prompts **through** this engine. |
| — | Coordinator's local agents | coordinator | `claude/ecstatic-rubin-2egjfb` | server image refs/collage (migration 0006), Android shoot references + Prompts editor, Figma designs |

**Shared files** (`server/api/src/app.ts`, `server/api/src/config.ts`, `server/api/src/db/schema.ts`, `plans/api.md`, `android/.../data/Models.kt`, `MuseApi.kt`, `HttpMuseApi.kt`, `mac/MuseCore/Sources/MuseCore/Models.swift`, `HTTPMuseAPI.swift`): keep edits **small and additive** (append, don't reorder or reformat), one clearly commented block per workstream, so merges stay trivial. Register routes with a single line in `app.ts`. Put new tables in your own schema file (e.g. `src/suite/schema.ts`) re-exported from `db/schema.ts` with one line.

## Rules for every session
- **No money.** No live Replicate predictions, no RunPod pods, no Anthropic API calls with the production key. Build against mock/fake providers; the owner tests with real use. Read-only GETs of public model pages/docs are fine.
- **Production is off-limits.** Don't push to `claude/ecstatic-rubin-2egjfb`; don't change Railway variables; against the live server only `GET /health`. Never print secrets.
- **UI waits for Figma.** The owner reviews the Figma designs (file `VX9cpCUtcf9ue8ZV0fCmLi`, pages "AI Suite —…", "Edit Suite —…") before UI is built. Build backends, engines, data models, APIs and tests now; only minimal, throwaway debug UI if you need it to test.
- **Licence:** the MiniMax H3 **open-weights** licence excludes the US/EU/UK/South Korea (incl. outputs) and requires a "Powered by MiniMax H3" notice. Do not build new features on the RunPod H3 open-weights path; hosted models (Replicate) are fine. The owner decides the existing "Edit" path.
- Member-facing data never names providers/models/GPUs (owner views may). AI-label switches stay user-controlled and off by default. Never use @vvspolly images.
- Read `plans/research/ai-video-suite-research.md` (the research), `plans/api.md`, `plans/backend.md` first.
- Commit in small logical commits; messages end with the session's attribution trailer; no model identifiers in messages. Run the server tests (`npm run build`, `npx vitest run`) / Android unit tests / MuseCore tests for what you touch before pushing to **your** branch. Rebase your branch on `origin/claude/ecstatic-rubin-2egjfb` regularly.
- You may spawn your own sub-agents for parts of your workstream; you remain responsible for their output and for this file's rules.

## Phase 2 · UI build (started 2026-11-05, designs approved)
The owner approved the designs. Spec: `design/README.md`, `design/screens/*.jpg` (35 screens), `design/hardware/*` (40 renders + manifest), `design/source/*.py` (exact copy/sizes). Build the real screens on **Android and Mac**, wired to the live APIs, with tests (Roborazzi all 4 themes on Android; MuseCore + Mac CI green). Each session restarts its own branch from `origin/claude/ecstatic-rubin-2egjfb` and keeps to its folders:
| # | UI area | Owns (write) |
|---|---|---|
| 1 | **Video suite**: hub (D1/M1), Shot builder (D2/M2), Camera bag Preset mode — rig, light & look, move & angle (D3–D5, D3d, M3/M3d/M4), Character swap + **Recast** (D7/M6), Storyboard (D8/M7), result states (D10/M8), owner engines view (D9); **navigation** ("Video suite" group with modes, Edit top-level) | Android `ui/screens/suite/**` + navigation (`ui/MuseApp.kt` routes/sidebar); Mac `Muse/Views/Suite/**` + sidebar (`RootView.swift`); MuseCore `Suite/**`; bundling `design/hardware` into both apps |
| 2 | **Directed (Blender) mode** inside the Camera control (D6/M5): blocking plan, keyframe timeline, guides, **Direct with Claude** chat; owner Settings → Connections (MCP tokens, Blender relay toggle) | Android `ui/screens/camera/**`; Mac `Muse/Views/Camera/**`, `Muse/App/Blender*.swift`; MuseCore `Camera/**` |
| 3 | **Edit suite** (E1–E4, EM1–EM5): timeline, inspector panels, captions & hooks, **Looks picker** (32 looks + .cube import), audio, export; replaces the v1 editor screens | Android `ui/screens/edit/**` (+ remove/redirect `VideoEditorScreen.kt`); Mac `Muse/Views/Edit/**` (+ `VideoEditorView.swift`); MuseCore `Edit/**` |
| 4 | **App-wide polish & UX audit** (the owner's "properly optimised, clean, no UI/UX issues"): first a written audit (`plans/ux-audit.md`) of every existing screen on both apps at phone 360 dp / 390 dp and Mac 1280 / 1440 px; then fixes in screens NOT owned by 1–3 (Home, Models/profile/sheet, Photoshoot, Templates, Gallery/Result, Queue, Posts, Credit/Members, Settings incl. Prompts) | those screens only |

Navigation entries for 2 and 3 are added by **1** (message them with what you need). Shared model/API files: small additive blocks only, as before. When a screen needs a route from another area, coordinate by `send_message`. Report to the coordinator when done; the coordinator merges.

## Phase 2 change (2026-11-05): composer-first video suite
The owner rejected the camera-bag page (hardware laid out as shelves). Hardware is a set of choices made **while creating**, like Higgsfield's Cinema Studio: one prompt-first composer, compact chips (Camera, Look, Lighting… each **Auto** by default) that open small pickers with the real renders. No camera-bag page, no technical numbers for members. Workstream 1 has **paused** D2/M2, D3–D5/M3–M4 and the camera-bag entry points; workstream 2's Directed panel becomes an option inside the Camera picker (sheet content unchanged). **Approved 2026-11-06** ("Yes. I love it"): spec `plans/video-composer.md`, mockups `design/screens/composer__*`. Workstream 1 builds the composer and pickers on both apps; workstream 2 renders the free Blender previews (moves, lighting, angles) into `design/previews/`.

## Phase 3 (2026-11-06): Claude in the Edit suite
Spec `plans/claude-editing.md`. Workstream 3: edit sessions plus the editing MCP tools (A), and the chat panel inside the Edit suite. Workstream 2: OAuth on `/mcp` for the claude.ai connector (B), the Mac chat on the owner's local Claude Code (C), the phone chat relayed to the Mac (D), and the shared chat component (E). Owner-only. The chat runs on the owner's Claude subscription; the API key is an opt-in fallback.

**Migration order (strict):** prod's last migration is 0010 (`when` 1793896375493). Reserved:
- 0011: workstream 2, OAuth and chat threads, `when` 1793929987100.
- 0012: workstream 3, edit sessions, `when` 1793929987200.
- 0013: workstream 1, suite locations, `when` 1793929987397.

`migrateWithLock` skips any migration whose `when` is ≤ the last one applied, so the coordinator merges them in that order. 0013 waits until 0011 and 0012 have landed.

### Queued (owner, 2026-11-08)
- **Edit: "find the action peaks" tool (free).** Server-side motion energy per frame (frame differencing / optical flow on a downscaled proxy) returns exact motion-peak times. It's exposed to Claude as an MCP tool so actions can be matched to beats frame-accurately. It comes after the Edit crash fix and the Edit redesign.
- **Remove background, fix 1:** use RVM's alpha output instead of a green composite plus chroma key, so green clothing and hair edges survive. Option 2 (tap what to keep, with SAM 2 tracking) waits for the owner's OK on price and mockup.

## Owner's standing rule for production pushes (2026-11-07)
The owner said: "Push anything that's green on all checks and that I've already approved in principle (fixes, approved designs). Still ask me for new features or anything that spends money."
- The coordinator pushes to `claude/ecstatic-rubin-2egjfb` without asking when:
  - all checks are green on the exact head: server tests, Android tests and Mac CI;
  - **and** the change is a fix, or matches a design the owner already approved.
- The coordinator asks first for:
  - new features or screens the owner hasn't seen;
  - anything that spends money;
  - design changes the owner hasn't approved.

## ▶ RESUMED (2026-11-06, owner chose "all four workstreams")
Production is at `daab63d` (the Higgsfield H3 provider). `SUITE_MODE=live`, and HF_CREDENTIALS is set on Railway. Items 5 (go live) and 13 (Higgsfield) are done. The first Higgsfield HD shot was refused by Higgsfield's NSFW check: the API has no moderation setting, and the job was not charged.

Assignments (each workstream branches from `claude/ecstatic-rubin-2egjfb` at `daab63d` or later, and merges back only after its tests pass):
- **WS1, suite core (`claude/muse-suite-core`):** 1 (finish Extend & upscale; rebase onto `daab63d` first), 8 (Mac pills), 10 (8 s/10 s length, `#token` leak, audio levelling), 12a (the "Rise to reveal" move, the "single shot" alias).
- **WS3, Edit suite (`claude/muse-editor-v2`):** 9 (the rig check: server rules plus the warning UI on both apps), including 12b (prompt vs. move).
- **WS4, polish:** 11 (drum-style wheels: a prototype for the owner first, then both apps), 12c (preview art for the Tempo, Genre and Era tiles).
- **WS2, MCP bridge (`claude/muse-mcp-bridge`):** 7 (`railway.json` migration), and getting 2–3 ready for the owner (the checklist is in `plans/claude-editing.md`). Item 6 (RunPod) waits for the owner's OK on spend.
- **Shared files:** WS1, WS3 and WS4 all touch the composer. Rig-check UI goes in its own file/component; wheels are confined to the picker files; WS1 owns the bottom bar.

### Added 2026-11-06 (owner): Photoshoot folds into the AI Suite, plus a whole-app professional review
- **Owner's decisions:**
  - Photoshoot is **removed fully** and becomes a **Photo** tool on the suite composer, with the full rig (camera, lens, focal length, aperture, angle, lighting, look, style).
  - Templates become Photo presets. Old shoots stay in the library.
  - Icons: **one professional set**, used everywhere.
  - The review is **split across sessions**.
- **Rules for every session:** load the skill `.claude/skills/muse-design-review/SKILL.md`. The direction lives in `plans/design-direction.md` (WS4 writes it first).
- **WS3:** the Photo tool. Server: a suite tool `photo` reusing the shoots pipeline, the rig compiled for stills (no movement or tempo), the rig-check subset. Both apps: the Photo tool card plus presets from the templates. Remove the Photoshoot entry points, with a redirect, and keep shoot history.
- **WS4:**
  1. Pause audit-2 and fold its findings in.
  2. Write `plans/design-direction.md` plus 3 key screens (Home, composer, a picker) for the owner to approve.
  3. Restyle **part A**: the AI Suite, pickers and Edit suite. Do the composer after WS1 and WS3 merge.
- **WS2:** a **performance pass** across both apps now (startup, scrolling, image sizes, duplicate requests). After the direction is approved, restyle **part B**: Home, Library, Cast and models, LoRA, Settings, onboarding, chat.

When resuming:
1. Finish and merge Extend and Upscale.
2. The owner's Mac first-run checklist (`plans/claude-editing.md`).
3. The real claude.ai connector handshake.
4. Real-device checks.
5. Go live with renders.
6. The owner-approved RunPod step for SeedVR2.
7. Migrate `railway.json` before 2026-12-01.
8. **Owner-seen bug (Mac composer, about 1000 px wide):** the bottom pills wrap their labels ("Standar/d", "Speak/ing"), "Engine · A…" is cut off, and Generate shows "GENERATE…" with no price. Make the pills shrink to icon plus value, and keep the price visible. Workstream 1.
9. **Rig check (owner asked, high priority):** the composer warns before Generate when choices clash with each other or with the prompt. Examples:
   - DV camcorder, phone or CCTV with f/1.4–2.8 or Rack focus: deep focus, so the pull won't show.
   - A wide lens (≤24 mm) with a close-up: it distorts.
   - Worm's-eye with a chest-up close-up.
   - Two opposing looks.
   - A prompt that describes a move or angle different from the chips.

   Show a one-line reason and a one-tap fix.
10. **Owner's first live shot (H3 Standard):**
   - It ran 10 s although 8 s was chosen.
   - The "#Rack focus" token text leaked into the prompt as well as the compiled line.
   - The audio came back very quiet (max about −50 dB), so add loudness levelling, or mark H3 sound as "faint".
11. **Wheels must feel like a real scroll (owner):** the current Setup wheels feel "blocky and noisy" (boxed cards, thick borders and a check badge on each). Rebuild them as a drum picker:
    - continuous momentum scroll with an eased snap;
    - curved 3D falloff (items scale, fade and tilt off-centre);
    - one fixed selection band across all wheels, with no per-card borders or badges;
    - only the centred item shows its name and caption, cross-faded;
    - a haptic tick per detent on the phone, and an optional click on the Mac;
    - unboxed hardware renders on dark.

    Prototype first for the owner to feel, then both apps.
12. **From the owner's balcony test (H3 HD, 2K, 10 s):** the look was excellent (35 mm film, contre-jour, Golden warmth).
    - Add a move "Rise to reveal": the camera starts below the subject's level (street or traffic) and rises up to find them. Today's "Crane up" starts at the subject and tilts down.
    - The rig check should flag "prompt says open on X / reveal" against a move that can't do that.
    - Tempo / Genre / Era tiles need preview art (they are text on dark).
    - In Style → Tempo, add "single shot" as a search alias for "One take".
13. **Higgsfield API as a provider (owner, 2026-11-06):** open.higgsfield.ai lists MiniMax H3 (text / image / reference to video) at **$0.065/s at 2K**. That is half of Replicate's and Fal's $0.13/s, priced "as of 16 Sep 2026" and shown against Fal, so treat it as their standing price. Clips are 1 / 5 / 10 / 15 s only.
    - Add `higgsfield` as a provider in the suite registry, with the same H3 model on more than one provider, and route each tier to the cheapest provider that supports its inputs (9 refs, frames, video reference).
    - Round lengths up to the allowed clip lengths, and show the price members actually pay.
    - Needs the owner's Higgsfield API key (request_credential, never in chat), their API docs and terms checked, and a mock adapter first.
    - **Docs read (2026-11-06):**
      - **Endpoints and auth:** `POST https://api.higgsfield.ai/minimax/h3/{text-to-video|image-to-video|reference-to-video}` with `Authorization: Key KEY_ID:KEY_SECRET`. SDK `@higgsfield/client` (server only). Polling statuses: queued, in_progress, nsfw (a refusal: refund), canceled, failed, completed (`video.url`).
      - **Reference to video:** `image_urls` ≤ 9, `video_urls` ≤ 3, `audio_urls` ≤ 3.
      - **Image to video:** `image_url` (first frame) plus an optional `end_image_url`.
      - **Common fields:** `duration` is an integer from 5 to 15; `resolution` is 2K only; `aspect_ratio` is auto, adaptive, 21:9, 16:9, 4:3, 1:1, 3:4 or 9:16; `aigc_watermark` defaults to false (keep false).
      - **Pricing (reference to video):** $0.13 per output second before discount (shown $0.065 now), plus **$0.08 for each reference image beyond the first 5**. MUSE's identity (5) plus outfit (4) means +$0.32. Price that exactly, and consider capping at 5 images on this provider.
      - **Mapping:** fits the HD tier, and could replace 768P Standard at about the same price.
      - **Docs:** `https://dash.higgsfield.ai/models/minimax/h3/<endpoint>/llms.txt`.
      - **Verified 2026-11-06 with the free estimate endpoint** (`POST https://api.higgsfield.ai/estimate/<model>`, which prices for this account without charging):
        - The owner's key gets a **15% discount, not 50%**. H3 2K 10 s costs $1.105 (list $1.30), 5 s costs $0.553.
        - With MUSE's usual 9 reference images, Higgsfield (about $1.38–1.42) costs **more** than Replicate ($1.30). It's only cheaper at ≤ 5 images.
        - **Update (same day): the owner claimed the max-discount set** (MiniMax H3, Seedance 2.5, and Marketing Studio as the image model, the only image model eligible). The estimate now confirms **H3 at 50%**: 2K 10 s costs **$0.65**, 5 s costs $0.325. Seedance 2.5 shows 30% in the console; its estimate returns only the token-pricing description. Kling 4.0 is also 30%. Qwen Image 3 is not eligible for the max discount but is usable at list price (from $0.040 per image, 1–3 references for edits).
        - **BUILT 2026-11-06 (coordinator):** `h3-hf` (provider `higgsfield`, adapter `hf-h3`) is first on the HD ladder. It handles text and reference shots; frame shots stay on Replicate H3. It is priced $0.065/s + $0.08 per reference image beyond 5. Out of credit, bad key or busy at start moves the shot to Replicate H3 2K and skips Higgsfield for 30 min. It is active only when `HF_CREDENTIALS` is set on Railway. Seedance 2.5 stays on Replicate ($0.23/s at 720p against Higgsfield's $0.32 after 30%). Tests: `test/suite-higgsfield.test.ts`.
        - **Worth building:** H3 on Higgsfield is cheaper than Replicate even with 9 references (about $0.81–0.97 against $1.30 for 2K 10 s) and half price with ≤ 5. Route HD (and possibly Standard) H3 shots to Higgsfield. Keep Replicate as the fallback.
        - The SDK setup and the example are in `server/api/examples/higgsfield/`. The API account has no credit yet.

## Status (each session updates its own line)
- 1 · Video composer follow-ups (2026-11-06) on `claude/muse-suite-core`: Recast tap-a-face (faceCrop + personHint), swap add-on pills, Era decade slider, UGC ad format wheel (`ugcFormats`, `camera.style.format`), @location (`/v1/suite/locations`, **migration 0013 after 0011/0012**), drag-to-reorder tokens, owner engine pin; catalog `tools` (Talking and UGC ad live, Extend coming soon); real Webcam/CCTV/Swirl/Tilt-shift renders; Blender previews bundled (`previews/`, catalog `preview` per move/light/angle); first-run HTTP checks on both apps. Server 359 green; Android 1305 green (release APK 30.7 MB, +9.5 MB previews); Mac CI green (run 42152398143). Next: Extend & upscale backend.
- 2 · MCP + Blender bridge: resumed 2026-11-06. Item 7 done: `server/api/README.md` "Railway: move off railway.json before 1 December 2026" (railway.json still valid today; the owner runs `railway config migrate` → plan → cutover → apply; set restart policy On Failure / 5 in the dashboard first: IaC has no key for it). Items 2–3: `plans/claude-editing.md` first-run checklist re-checked against the current apps and ready to hand over. Item 6 (RunPod SeedVR2) waits for the owner's OK on spend.
- 3 · Editor engine v2 / **Edit crash fixed, ready on `claude/muse-editor-v2`** (2026-11-07). Cause (owner's crash report): the waveform reader asked AVAssetReaderTrackOutput for 2 kHz mono LPCM, which raises an uncatchable ObjC exception on real 44.1/48 kHz AAC; it now decodes at the track's native rate and channels and down-mixes in Swift (MuseCore `EditSuite.Peaks`). Also: hardening against 0/NaN/inf/missing media facts on Mac and server, single-parse LUT cache with a byte-scanner .cube fast path (3.8 s → 0.7 s for all bundled LUTs), and a CI **Edit check** (real AAC 48 kHz stereo / 44.1 kHz mono fixtures, waveforms, every Edit path). Photo tool live (prod c4c7588). Server 401 green; Android 1529 green; Mac CI green (run 42355408773, MuseCore 512, Edit check ALL DONE).
- 4 · App-wide polish & UX audit (phase 2): **merged** into `claude/ecstatic-rubin-2egjfb` (merge 3103642, 2026-11-05). plans/ux-audit.md covers every Android and Mac screen at 360/390 dp and 1280/1440 px in all 4 themes. Our screens: Android 42 findings (37 fixed, all high/med), Mac 43 (39 fixed, all high). Workstream 1–3 findings sent to them; **workstreams 1–3: re-record your Roborazzi baselines after rebasing** (Kit.kt 48 dp targets, theme tokens, StudioParts ToolStrip). Owner decisions open: ToS/AUP links, a MUSE domain, Settings → Developer for members, Soft Tactile warning/accent contrast.
- Flow SSE test fix (session `session_01Py2rxp7ojBd6RjykjWHCgb`): **ready to merge** from `claude/serene-davinci-z8lpff` (commit b3badf8, rebased on aac7d49; test files only, no app code). Fixes "a video job streams step progress over SSE…" in `server/api/test/flow.test.ts`, which failed under CPU load. Cause: at SPEED 2400 the 2-take job lasts ~0.5 s and the simulated GPU samples progress every 250 ms, so a few ms of delay can skip the Rendering phase entirely (the event is never sent; the app is fine). The test now runs that one job at 480×, waits (bounded) for the Rendering event, and `sse()` in `test/helpers.ts` resolves once the server has subscribed the stream instead of after a fixed 50 ms. Server build + 316 tests green on aac7d49; the video test passed 8/8 with 8 busy loops on 4 cores and 6/6 alongside two parallel full runs. Same weakness, not yet seen failing: the LoRA training test in that file (~0.5 s job).

## Owner approval (2026-11-08): "I approve all"
This covers every open item at that point:
- **Mac Playbook and Recipes:** build directly to the approved Android design and its two notes. WS2.
- **Remove background, option 2:** SAM 2 tap-to-keep. Show the price per use and ask before each run. WS1 server, then the Edit UI (WS3 Mac, WS4 Android).
- **SeedVR2 on RunPod:** approved. Show the price per job, ask before each run, and cap spend (no warm idle workers). WS2.
- **Delete the cinematic Suite code** and the "Try the new Suite" switch. Mac WS2, Android WS4.
- **Still needs the owner's own action:**
  - typing "Go ahead and upload" in session_01Py2rxqFT9BvkxLttPb5c8Z;
  - a `MUSE_OWNER_TOKEN` GitHub secret for Mac auto-publish.

## SeedVR2 upscale priced (2026-11-08)
- **Measurement:** WS2 measured it for about $0.91 of the $5 cap. Details in gpu/pod/seedvr2/RESULTS.md.
- **Owner's choice:** cost × 2.
- **Railway UPSCALE_PRICES:**
  - 1080p: $0.086/s (26 GPU s/s);
  - 2K: $0.108/s (36 GPU s/s);
  - 4K: $0.19/s (70 GPU s/s).
- **A 5 s clip costs:** about $0.43, $0.54 or $0.95.
- **Availability:** a size is offered only when a pod advertises the "upscale" capability.
