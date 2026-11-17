# Performance audit (WS2)

The performance pass across both apps (`plans/coordination.md`, "Added 2026-11-06", WS2), against `.claude/skills/muse-design-review/SKILL.md` §4: startup, scrolling, image sizes and duplicate requests. Each app has its own section.

## Mac

Scope: performance only, no visual changes. The AI Suite, composer, pickers, Edit suite, video editor and Photoshoot views were off limits (other sessions are rebuilding them). Their shared infrastructure was in scope: the live stream, request sharing, the image loader and the store's loading.

### Findings

Request counts come from MuseCore tests that run the app's loading call for call against a counting `URLProtocol`, with one 30 ms round trip per request (`PerfRequestTests`, `PerfHubTests`). The "before" numbers were first measured on the unchanged code, and the tests now replay both versions side by side. The setup is an owner with two models.

| Finding | Severity | Fix | Before → after |
|---|---|---|---|
| Up to five long-lived `GET /v1/events` connections: the store, the Edit suite, camera sessions, Claude Code and the Blender relay each opened their own and parsed every event. | High | `LiveEventHub` (MuseCore) keeps one connection per server and sign-in and fans it out. Each client's `events()` subscribes and maps the frames to its own events. It reconnects with the same back-off as before, and `reconnect(baseURL:)` restarts it on demand. | 5 → **1** connection for 5 listeners (test). A typical owner session (store, Claude Code, camera) goes from 3 to 1. |
| ⌘-Tab back to MUSE reloaded every list, even while the stream was fine (`resumeLive` on `didBecomeActive`). | High | `resumeLive(force:)` does nothing while the shared stream heard the server's 10 s keep-alive in the last 25 s. Wake and network change force a restart and catch-up. | 3 re-activations: 57 → **0** requests |
| Screens refetched lists the live stream already keeps current: Credit (`loadStudio`: 7 GETs for the owner), Templates, Posts, Members (+ wallet), Archived. | Medium | `Freshness` (MuseCore). A screen appearing refetches only when its list is over 60 s old. Every full reload marks the lists fresh. Sign-out, a server switch and Settings → Developer → Reload clear it. Members → Refresh still forces it. | Opening Credit, Templates, Posts and Members after launch: 11 → **0** requests |
| Launch loading ran one request after another: `loadStudio` made 7 sequential GETs, and `loadSocial` made 2 per model in a row, then posts, templates and the GPU state. | Medium | The independent loads now run side by side (`async let` and a task group). The request count is unchanged. | Full launch load: 20 requests either way, **510 ms → 96 ms** at 30 ms per round trip (about 17 → 4 round trips). With a real ~150 ms round trip to the hosted server, that's roughly 2.5 s → 0.6 s. The models list (Home) still arrives after `me` plus one parallel batch. |
| Identical GETs in flight were each sent, for example `loadStudio` from a `settings` event, a provider notice and Credit's `.task` at once. | Medium | `RequestCoalescer` in `HTTPMuseAPI`: identical GETs (same path and sign-in) in flight share one request and its error. This covers the suite's GETs too. `reload()` also joins a reload that is already running. | 3 concurrent studio loads: 21 → **7** requests |
| Slow-changing catalogs were refetched on every studio load: studio settings, image engine, image models and their collections, the suite catalog and the camera catalog. | Low | An opt-in `TTLCache` in `HTTPMuseAPI` (`cacheCatalogs: true`, which the app sets) keeps them for 5 minutes. They're dropped on any write, on `settings`, `notice`, `studio` and `suite` events, and on every stream (re)connect. A reply fetched across an invalidation is not stored. Off by default, so the contract tests are unchanged. | Studio load twice: 14 → **11** requests |
| Every live event re-rendered every view that reads jobs, takes, posts, accounts, members, the prompt library or the scripts. `AppStore.apply` passed each list `inout` for every event, and with `@Observable` an inout access counts as a change. That includes Claude's streaming deltas (several a second while Claude Code runs), camera messages and GPU ticks. | High | Each list is touched only by the event types that can change it. | Not measurable here. Instruments' SwiftUI template should show far fewer view body updates in Gallery, Queue and Home while Claude Code streams. |
| Images were decoded full size (`NSImage(data:)`, decoded on the main thread at first draw) into an **unbounded** dictionary that was never evicted. Local files and data URLs were read synchronously in `body`. | High | `ImageCache` was rewritten. It downsamples with ImageIO (`CGImageSourceCreateThumbnailAtIndex`, `ShouldCacheImmediately`) on a detached task, to the frame's pixel size in fixed buckets (128 to 3072 px). An `NSCache` holds the results with a 192 MB cost limit (800 items max) and gives way under memory pressure. A smaller decode stands in while a bigger one loads. The old entry points `image(for:)`, `load(_:)` and `put` keep their signatures for their callers. | Per gallery tile on a 2× screen, computed rather than measured: a 768×1344 take thumb goes from 4.1 MB to 1.35 MB decoded, and a 2K still from about 16 MB to 1.35 MB. The cache goes from unbounded to 192 MB. |
| When two views asked for the same http image at once, the second got `nil` and stayed a placeholder (`inflight` was a Set). | Medium (bug) | `ImageDataLoader` (MuseCore) gives one download per URL, and later askers join it. Decodes are shared per URL and size the same way. | 3 asks for one URL: 1 download, and every tile now gets the image (test) |
| Image bytes went through `URLSession.shared` (512 KB memory, 10 MB disk, so anything over about 0.5 MB is never stored) and were downloaded again on every launch. | Medium | `ImageDataLoader` has its own URLCache (16 MB memory, 512 MB disk in `~/Library/Caches/MUSE/images`) and follows the server's `cache-control` (files `private, max-age=3600`, assets 1 day). | A relaunch within the hour costs 0 image downloads instead of one per visible image. Verify with the "downloads" count in the readout. |
| Data-URL images (Claude chat images, inline thumbs) used the whole base64 string as the cache key, held in the dictionary, the in-flight table and each view's `.task` id. | Low | Keys longer than 512 bytes are shortened to the length, hash and tail. | Several MB per image → about 60 bytes |
| The Result screen's `TakePlayer` only paused when it went off screen, and kept the `AVPlayer` with its item and decoder buffers. | Medium | On disappear it now pauses, drops the item and releases the player, and `onAppear` makes a new one. `StageVideo` already released its looper. | Not measurable here |
| The Queue's finished list and the Posts list built every row (`VStack` in a `ScrollView`). | Low | `LazyVStack`, keyed by job and post ids. | Not measurable here |
| Startup and memory had no numbers. | — | `StartupMetrics` logs "first content shown N ms after process start" (the kernel's process start time, so it includes dyld) and emits Points of Interest signposts "launch" and "first content shown". `MemoryReport` reads `task_info` (footprint and resident). Settings → Developer → **Performance** shows start-up, memory, images in memory and downloads, live connections and listeners, and requests (sent, joined, served from the cache). | See "How to measure" |

Memory audit (static, the app can't run here):
- Long-lived tasks in the store, camera, Claude Code, the Blender relay, the warm-GPU ticker and the chat model all capture `[weak self]` or are cancelled by their service's `stop()`. The services are singletons. No retain cycles found.
- The live event buffers are bounded (256 / 512 / 128 newest).
- The hub drops its parser and channel with its last listener.

Left as is, and why:
- `loadSocial` still makes 2 requests per model (LoRA and accounts). Fewer requests needs a bulk server endpoint, which is a server change.
- `ClaudeCodeService.ranTurns` and `AppStore.toolRuns` grow by one small entry per turn or tool run in a session (kilobytes).
- `StageVideo` keeps looping while the window is minimised. SwiftUI doesn't call `onDisappear` there.
- The off-limits views (Suite, Edit, video editor, Photoshoot) were not audited. They do get the shared stream, request sharing and the new image loader.

### Tests

Tests are in `mac/MuseCore` and run with `swift test` (Linux, Swift 6.0.3):

| | Tests run | Skipped | Failures |
|---|---|---|---|
| Before | 447 | 23 | 0 |
| After | 460 | 23 | 0 |

The 13 new tests are in `PerfRequestTests` and `PerfHubTests`. They print `PERF before:` and `PERF after:` with the numbers above.

The SwiftUI and AppKit side (`Images.swift`, `PerfDiagnostics.swift`, the AppStore changes) only compiles on Mac CI. Linux builds have no streaming bytes API, so there `LiveEventHub.shared.canStream` is false, and the clients keep their polling fallback for tests.

### How to measure on a Mac

These can't be measured here.

- **Cold start:**
  1. Quit MUSE. For a cold start, reboot, or run `sudo purge` to drop the file cache.
  2. Run `log stream --predicate 'subsystem == "studio.muse.mac" AND category == "perf"' --style compact`.
  3. Launch MUSE signed in. The log line reads `first content shown N ms after process start (M models, T takes)`.

  The same number is shown in Settings → Developer → Performance → Start-up. In Instruments, the **App Launch** template shows the "launch" and "first content shown" events on the Points of Interest track. The target from the skill is under about 1.5 s. Record three launches and take the median.
- **Memory:** Settings → Developer → Performance → Memory shows the footprint, which is what Activity Monitor shows, and the resident size. Use this scenario:
  1. Launch.
  2. Note the number.
  3. Open Gallery and scroll to the end.
  4. Open five takes.
  5. Go back to Home.
  6. Note the number again, plus "Images in memory".

  For detail, use Instruments **Allocations** (with VM Tracker), or `footprint MUSE` / `vmmap --summary MUSE` in Terminal. Compare with the CI artifact from before this pass.
- **Scrolling:** use Instruments' **SwiftUI** template (View Body and View Properties) plus **Animation Hitches**. Scroll a Gallery with 200+ takes, and leave Claude Code streaming in the background to confirm the lists no longer re-render per event.
- **Network:** Settings → Developer → Performance shows "Live updates" (should read `1 · N`) and "Requests" (sent, joined, cache hits). For a wire view, use Proxyman or Charles, or `nettop -p MUSE`. ⌘-Tab away and back: no new requests while "Live updates" is 1.

## Android

Scope: performance only, no visual changes. The AI Suite (`ui/screens/suite/**`), the Edit suite and video editor (`ui/screens/edit/**`) and Photoshoot (`ShootScreen.kt`) were off limits, and their files are untouched. Their shared infrastructure was in scope: the HTTP layer, the repository's loading, the build (R8, resources, Baseline Profile) and the Compose compiler setup.

### Findings

Request counts come from `RequestCountTest`. It runs the real `MuseRepository` and `HttpMuseApi` against a local stand-in server with a fixed 40 ms per request, and an owner with three models. The "before" numbers were measured on the unchanged code (`d91b992`) with the same test.

| Finding | Severity | Fix | Before → after |
|---|---|---|---|
| The release build had R8 off (`isMinifyEnabled = false`): about 41 MB of raw dex in 4 files, plus Kotlin debug probes and unused resources. | High | R8 with `proguard-android-optimize.txt` plus `app/proguard-rules.pro` (keeps for the kotlinx.serialization models, the Retrofit service and suspend signatures, and the demo JSON read by absolute path), and `isShrinkResources = true`. | Release APK (unsigned) **31.9 MB → 20.4 MB**. The ~37 MB reported before was likely a debug build, which has no R8 and is unchanged. Dex 14.8 MB (40.7 MB raw) → **3.6 MB** (7.3 MB raw). `resources.arsc` 0.77 → 0.40 MB. |
| The launch load ran about 16 requests one after another: models, outfits, jobs, takes, balance, wallet, posts and settings, then LoRA and accounts per model, then the GPU state. | High | `MuseRepository.refresh()` runs them side by side (`coroutineScope` and `async`). The per-model LoRA and accounts follow the models as a second batch. Same requests, same error handling. | 16 requests either way. **1356 ms → 252 ms** at 40 ms per request (single runs, each the first test in a fresh JVM): about 16 round trips → 3. With a real ~150 ms round trip to Railway, roughly 2.4 s → 0.5 s before Home, Gallery and a model's profile have their data. |
| Identical GETs in flight were each sent, for example a reconnect catch-up racing a "Try again" tap, or two screens asking for one catalog. | Medium | `RequestCache` (`data/RequestCache.kt`) in `HttpMuseApi`. Identical reads in flight (same path and session token) share one request and its error. If the caller that started a request leaves its screen, the others ask again. | Two refreshes at once: **30 → 14** requests |
| Screens refetched catalogs every time they opened: Templates, the prompt library and each prompt's editor, the owner's studio settings and image engine, image models, the suite catalog, settings and locations. | Medium | The same `RequestCache` keeps catalogs in memory (5 min, templates 60 s), **only while the live stream is connected**. Writes, the matching live events (`settings`, `prompts`, `promptScript`, `template`, `suite`) and every stream (re)connect drop them. A reply fetched across an invalidation is not stored. Without a stream (tests, offline) every read goes to the server. Templates → Refresh still forces a fetch. | Templates ×2, prompt library ×2, settings and image engine ×2, suite catalog ×3 at once: **11 → 4** requests |
| Every return to the app (Activity `onStart`) restarted the live stream and refetched all lists (about 16 requests), including rotation and coming back from a share sheet or a post handoff. | Medium | `onBackground()` from `onStop`. A return within 30 s keeps the stream and the lists. A stream that dropped meanwhile reconnects by itself and catches up then. | A quick share or handoff round trip: about 16 → **0** requests (by construction, not measured) |
| None of the long lists were lazy: Gallery, Queue (all four theme layouts), Posts, Templates and the image-model catalog composed every row and loaded every thumbnail (`Column` + `verticalScroll`). | High | `LazyColumn` with stable keys (take, job, post and template ids, de-duplicated) and `contentType`, using the same padding and spacing. Posts' per-row menu state now follows its post (it was positional). | 1016 Roborazzi screenshots: identical pixels before and after. The 4 `template_use_prompt` shots differ only in the random seed text, which changes on every run. With 300 takes, Gallery composes about 6 rows instead of 100. |
| Home read the whole studio state in composition (`repo.state.collectAsState()` for the wallet, `repo.state.value` for the model cards), so it recomposed on every live event, render progress included. | Medium | The wallet and each model's card image are in `HomeState` (equal states are skipped), and the model cards are keyed. | Not measurable here (Layout Inspector recomposition counts on a device) |
| Compose treated many data classes as unstable (JSON fields, `File`, arrays) or unknown, so screens re-ran parts whose inputs hadn't changed. | Medium | `android/compose_stability.conf`: `kotlin.collections.*`, `studio.muse.app.data.*`, `studio.muse.core.**` and the kotlinx JSON types, all immutable. `-PcomposeReports=true` writes the compiler reports. | Clean compiles: unstable classes **116 → 55** (what's left: ViewModels, the Activity, platform engines), runtime-checked classes 112 → 13, skippable composables 782 → 814, unstable composable parameters 32 → 23 (ViewModels and players) |
| Video previews kept playing when scrolled off screen: `StageVideo` played whenever the app was resumed, and `TakeVideo` whenever its page was current. | Medium | Both play only while at least 20% is on screen (`Modifier.onVisibilityChanged`), as well as resumed and, for `TakeVideo`, on the current page. Players were already released on dispose. | Not measurable here |
| The launch path did disk and Keystore work on the main thread: deleting the old `sfx` cache dir in `AppContainer.create`, and the AES-GCM Keystore decrypt of the session token (a binder call) inside the prefs flow, which runs on `Dispatchers.Main`. | Medium | The delete runs on `Dispatchers.IO`. `DataStorePrefs.prefs` is `flowOn(Dispatchers.IO)`. | Not measurable here (Perfetto or StrictMode on a device) |
| Splash bug: `LaunchedEffect(Unit)` captured the first `next`, from before the saved session had loaded, so after 2.6 s a signed-in user could be sent to Welcome. | Low (bug) | `rememberUpdatedState(next)` | — |
| No Baseline Profile for the app's own code: only the libraries' profiles shipped. | Medium | `app/src/main/baseline-prof.txt` (wildcard rules for the start path: Application, container, data layer, `core`, theme, components, splash, Home, Gallery, Queue). AGP expands and R8-rewrites it into `assets/dexopt/baseline.prof` (19,836 rules in the release build), and `profileinstaller` (from Compose) installs it. | Not measurable here. A Macrobenchmark `BaselineProfileRule` on a device should replace the hand-written rules later. |
| There was no "fully drawn" signal for cold start. | — | `MainActivity` calls `reportFullyDrawn()` on the frame after the studio's lists load (or at once when signed out). | See "How to measure on a phone" |

Checked and left as is:
- **Images:** every network image goes through `RefImage` → Coil `AsyncImage`. That resolves the target size from the layout, so grids decode at tile size, not full resolution. Coil's default memory cache, disk cache and hardware bitmaps are on, and the bundled samples are 3 to 6 KB. What can't be fixed in the app is that model sheet slots and outfit fronts are full-size uploads, so a 150 dp card still downloads the whole file. Server-side thumbnail URLs are needed for that (a server change).
- **Native libraries:** about 20 KB per ABI (4 ABIs), so ABI splits aren't worth it.
- **`assets/previews` (10.7 MB, now more than half the APK):** the 40 move loops meet their spec (320×400, 204–253 KB each). They belong to the AI Suite (WS1), so they were not re-encoded here. Options for the owner:
  - re-encode them at a lower bitrate (about −4 MB);
  - deliver them on demand (Play Asset Delivery or the server).
- **`assets/hardware` (2.8 MB WebP, 1024 px):** already WebP. The suite decodes them with `inSampleSize` 2 to 8, so shrinking the files would change what the suite shows (owner: WS1). Re-encoding at quality 80 would save about 1 MB.
- **Fonts (32 TTFs, 1.2 MB compressed):** all used by the four themes. Subsetting them to Latin would save about 0.6 MB, but names in other scripts would fall back to the system font. That's a design call.
- **R8 warnings:** R8 in AGP 8.13 warns that it can't read Kotlin 2.4 metadata (159 warnings). Nothing here reads that metadata at run time (no kotlin-reflect), so it is harmless. It goes away with a newer AGP or R8.
- **The repository still makes 2 requests per model** (LoRA and accounts) on each load. Fewer requests needs a bulk server endpoint.
- **Splash: show until ready (owner approved 2026-11-06).** It used to hold for a fixed 2.6 s (tap skipped it), so the splash, not the network, set when Home appeared. Now it leaves as soon as the saved session has loaded (that decides Home or Welcome), with a 300 ms minimum so a fast launch doesn't flash it (`SplashScreen`, `SPLASH_MIN_MS` in `AuthScreens.kt`). Before → after: 2600 ms → about 300 ms from first frame to Home on a warm session read (measure on a phone with the cold-start steps below). The Mac app has no timed splash, so nothing changed there.

### Tests

From `android/`: `./gradlew :core:test :app:testDebugUnitTest` (run as `recordRoborazziDebug` to also write the screenshots).

| | core | app | Failures |
|---|---|---|---|
| Before (`d91b992`) | 105 | 1255 | — |
| After | 105 | 1260 | 0 |

The new tests are `RequestCountTest` (the numbers above; it prints `[requests] …`) and `RequestCacheTest` (4 tests: coalescing, errors shared, a cancelled caller, TTL and invalidation). The contract tests against `server/mock` and `server/api` (`HttpMuseApiTest`, `RealApiContractTest`, `SuiteHttpFirstRunTest`) pass unchanged.

An earlier draft cached catalogs without the live stream and broke two of them, because another client's change wasn't seen. That is why caching now needs a connected stream.

Release build: `./gradlew :app:assembleRelease` builds `app-release-unsigned.apk`, because no release signing is configured. Before shipping, smoke-test the R8 build on a phone:
1. Sign in.
2. Check that Home loads.
3. Open a take with video.
4. Open Templates and the owner's Settings → Prompts.
5. Turn on demo mode.

### How to measure on a phone

These can't be measured here (no device or emulator).

- **Cold start** (target under about 1.5 s on a mid phone):
  1. Install the release build: sign it with a debug key, or add a signing config.
  2. Run `adb shell am start -W -S studio.muse.app/.MainActivity`. `-S` force-stops the app first, so this is a cold start. **TotalTime** is the time to the first frame, which is the splash.
  3. Run `adb logcat -s ActivityTaskManager`. The line `Displayed studio.muse.app/.MainActivity: +N ms` is the same first frame. `Fully drawn studio.muse.app/.MainActivity: +N ms` comes when the studio's lists have loaded, which is when Home's content is ready.
  4. Run it 5 times and record the median of each. For the Baseline Profile's effect, compare with `adb shell cmd package compile -m verify -f studio.muse.app` (no profile) against a fresh install (profile applied), or `adb shell cmd package compile -m speed-profile -f studio.muse.app`.
- **Scrolling:** with Profile GPU Rendering (Developer options → "Profile HWUI rendering" → bars), or with `adb shell dumpsys gfxinfo studio.muse.app reset` then `adb shell dumpsys gfxinfo studio.muse.app` after scrolling Gallery or Queue with 200+ items. Read "Janky frames" and the 90th and 95th percentiles. Layout Inspector's recomposition counts show Home no longer recomposing on every live event while a render runs.
- **Network:** Android Studio's Network Inspector, or the server log. Expect one request per list at launch, and none when going to another app and back within 30 s.
- **APK:** run `apkanalyzer apk summary` or Build → Analyze APK on `app-release-unsigned.apk` (20.4 MB at this pass).

## Bundled media compression (AI suite, workstream 1, 2026-11-06)

The owner approved re-encoding the bundled previews and hardware renders, as suggested above. One script does it: `design/previews/source/compress_previews.py`. Run it after a render; it skips what is already compressed. Both apps bundle the same files: Android copies `design/previews` at build time (and keeps its own copy of `design/hardware` in `assets/hardware`), and the Mac app bundles both folders.

| What | Encoding | Before | After | Worst SSIM vs the original |
|---|---|---|---|---|
| 40 move loops (`moves/*.mp4`, 320×400, 2.5 s) | H.264 CRF 24, x264 veryslow, High@3.1, yuv420p, GOP 60, no audio, faststart | 8.36 MB (~740 kbps) | **1.22 MB** (~100 kbps) | 0.990 |
| 40 move posters (`moves/*`, 320×400) | JPEG → WebP q80, same size | 336 KB | **117 KB** | 0.992 |
| 20 angle stills (`angles/*`, 320×400) | JPEG → WebP q80 | 182 KB | **55 KB** | 0.991 |
| 18 lighting stills (`lighting/*`, 640×400) | JPEG → WebP q80 | 235 KB | **63 KB** | 0.992 |
| 26 Style stills (`genres/`, `eras/`, `tempos/`, 640×400) | unchanged JPEG | 1.09 MB | 1.09 MB | — |
| 44 hardware renders (`design/hardware`, Android `assets/hardware`, 1024²) | WebP → WebP q80, 1024 px kept | 2.66 MB | **1.94 MB** each copy | 0.969 at 1024 px, 0.987 at 512 px |
| **Android `assets/previews` + `assets/hardware`** | | **12.8 MB** | **4.5 MB** | |

- **No visible loss:**
  - Each group was compared side by side at display size: mid-motion frames of the fastest moves (whip pan, crash zoom, FPV, running handheld), the lowest-SSIM stills, and the lowest-SSIM hardware render (Sodium Decay) at 400–512 px.
  - None showed a difference, including the dark gradients where banding would show first.
  - SSIM is ffmpeg's `ssim` filter, over all channels.
- **Sizes:** the stills stay at their current size. That is about their largest display size at 2× (Mac tiles are about 150 pt tall; Android tiles are up to about 510 px on a 3× phone). The hardware renders stay at 1024 px because the camera bag and the drum wheels may show them larger than the composer does.
- **Why the Style stills stay JPEG:**
  - Their film grain and VHS lines are the point.
  - At WebP q80 they save only 0.26 MB (SSIM 0.960, and the scanlines soften when zoomed).
  - At q88 or higher, WebP is larger than the JPEG.
- **Why H.264, not HEVC:** at 320×400 the loops are already about 30 KB each. H.264 plays on every Android decoder and in AVPlayer with no fallback needed.
- **Paths:** the posters, angle and lighting stills are now `.webp`. This covers the manifest, the generated `server/api/src/suite/previews.data.ts`, both demo catalogs and the test fixtures. Android `BitmapFactory` and macOS ImageIO (11+) decode WebP.
- **Tests:**
  - The server previews test checks that every path exists and that every loop is under 80 KB.
  - The Android unit and screenshot tests and the Mac CI pass.

## Mac: idle and lag pass (owner report, build 704: "it lags", hot, fan on, stutter everywhere)

Scope: performance only, no behaviour or UI changes. Branch `claude/mac-perf`.

### Baseline (CI run 704, mac.yml)

| Check | Build 704 |
|---|---|
| Edit idle, 66-clip edit / 64 s real edit | 0 % / 0 % of one core |
| Edit paused while Claude's reply streams | **33 %** (single 8 s window; once 74 % against the 60 % limit under load) |
| Edit playback (real media / big edit) | 96 % / 103 % |
| App-wide idle per page, window hidden | not measured (new check below) |

### Top offenders found, and fixes

| # | Offender | Fix |
|---|---|---|
| 1 | Claude chat streaming: every token changed the transcript (whole `ClaudeChatView` body, `items` rebuilt 2–3×, leak-filter regexes over every message, the streaming reply's markdown re-parsed: O(L²) per reply) and published `ClaudeCodeService.orb` (every view observing the service re-rendered per token). | `ClaudeDeltaCoalescer` (MuseCore): text deltas are joined and applied at most every 80 ms, order kept (any other event lets the text out first). The orb skips a chunk pulse within 0.25 s of the last one while a turn runs (`ClaudeOrb.chunkChangesAnything`; the flash fades over 0.6 s, so nothing visible changes). `ChatTextCache` (MuseCore): leak filter and markdown results kept by text, bounded (`BoundedMemo`); never for the reply still streaming. `ClaudeChatModel.items` built once per transcript change. |
| 2a | Owner: "once the Claude panel is open it starts to lag immediately". Claude's orb (a Metal shader in a TimelineView) drew 12 fps in idle and 30 working, in the header, the UI overlay, every activity card and beside every streaming reply, each with its own clock; every orb observed the whole `ClaudeCodeService`. | Idle orb: one still frame, no clock (it draws only while a flash fades, then stops). Working: 20 fps (was 30); waiting and error 12. The small orbs beside a reply and on cards are still frames (`live: false`), so only the panel header's orb ever keeps a clock (the operating overlay's is still too). The orb state lives in its own `ClaudeOrbBox`: no longer `@Published` on the service, so neither re-renders the other. The shader draws in its own layer (`drawingGroup`). |
| 2 | Floating Claude panel open and idle: the living edge (with a 12 pt blur) redrew 12 times a second, and the panel's 32 pt shadow was cast by the whole panel, so it was worked out again on every edge frame and every streamed token. | The edge holds still in the idle state (glow 0.12, the breath on it couldn't be seen); any real activity restarts it. The shadow is cast by a plain shape behind the panel. The 24 pt header orb still runs at its designed 12 fps while visible (owner design, left as is). |
| 3 | Chat transcript: the scroll-follow bookkeeping (`lastFrame`, `followPending`, `scrollAgain`) was `@State`, written on every layout, so each layout re-ran the transcript body. | Kept in a reference held by `@State` (never drawn). |
| 4 | Suite Shot stage timeline and New Swap's clock and playhead: `TimelineView(.periodic(by: 0.25))` redrew 4 times a second forever, paused too. | `ViewerPlayback.clockRunning` (playing, seeking or loading) pauses them; `tick` redraws once when a seek lands or the item becomes ready. |
| 5 | Catch-up after every reconnect or wake (`reloadNow`, `loadStudio`) set every list even when equal; `@Observable` notifies on every set. Live events changed lists through `inout` (counts as a change) even when the event changed nothing. | `setIfChanged`: lists and values are set only when they differ; events apply to a copy. |
| 6 | `ClaudeCodeService.recheck()` on every app activation wrote 4 `@Published` values even when unchanged. | Only changes are set. |
| 7 | Recreate's Claude `/state` poll ran every 3 s while its panel was open, on any screen and with the window hidden. | Requests only while Recreate is on screen and the window can be seen; catches up within 3 s on return. |
| 8 | Recreate lanes: the playhead read the 30 fps clock in the same closure as all five lanes, so every lane was rebuilt 30 times a second while playing. | The playhead is its own view. |
| 9 | Recreate stills: `NSImage(data:)` decoded full size on the main thread, cached in an unbounded dictionary. | ImageIO downsample (≤ 2048 px, the player frame's cap) off the main thread into an `NSCache` (96 MB, 300 items). |
| 10 | Suite feed: on every job event, a linear take search per card. | Only while the viewer is open, through one id table. |
| 11 | Edit templates library: each tile read a remote video frame again every time it scrolled back in. | Stills cached by upload id (200). |
| 12 | Pickers and the tools browser: a 60 pt shadow over scrolling content, redone on every scroll frame. | Cast by an opaque shape behind (same picture). |
| 13 | Smaller: Edit bin searched the project's assets per tile on each scrub; Members built a `RelativeDateTimeFormatter` per row per render; Members, Photo presets and Learn history were eager stacks; chat video cards kept their `AVPlayer` forever. | Set built once; one static formatter; lazy stacks; the player is released off screen. |

Checked and fine: heartbeats (Claude Code, Blender relay, 20 s network calls), Edit presence (15 s), Edit's 30 Hz time observer (only fires while playing), the composer's re-pricing (300 ms debounce, cancelled by `.task(id:)`), image loader, lazy Library/Queue/Posts/feeds, the hover player (one at a time, torn down).

### New CI gate: Idle CPU check

`SnapshotRunner+IdleCPU.swift`, run right after sign-in (after the HDR and stream-close checks, which must come first), and the "Idle CPU check" step in `mac.yml` (`snapshots/idle-cpu-check.txt`):

- Home after launch, then Library, Queue, Models, Video suite Shot (demo draft), Photo composer, Edit home, Settings, the Claude panel open, and the window hidden.
- For each: settle, then the **median of six 2 s windows** of the process's CPU time (`getrusage`, every thread), plus the main run loop's **wake-ups per second** (`CFRunLoopObserver`, `.afterWaiting`).
- With the panel open, the orb and edge in the working state ("Claude panel open, Claude working", fails above 30 %), then after the turn (5 %). "Claude panel open, idle" fails above 5 %. Edit's big check already streams a real reply over an open edit (33 % in build 704, limit 60 %).
- Limits: 10 % after launch, 15 % per page, 5 % hidden. A page over its limit gets a 3 s `sample` and its heaviest main-thread frames printed.
- The Edit CPU gates (big edit, real media) now use the same median of 2 s windows (`cpuMedian`), so one busy moment on a loaded runner no longer fails them.

### Tests

MuseCore on Linux (Swift 6.0.3): 1046 tests, 0 failures (26 skipped). The 7 new ones are in `IdlePerfTests` (coalescer order and equivalence, the orb's chunk gap, the bounded memo, the cache matching the filter and parser).

### After (CI run 709 at a394792, all green)

| Check | Build 704 | Run 709 |
|---|---|---|
| Idle, every page (Home after launch, Library, Queue, Models, Video suite Shot, Photo composer, Edit home, Settings) | not measured | **0.0 %** median, 0.5–0.6 main run-loop wake-ups/s |
| Claude panel open, idle / after a turn | not measured | **0.0 % / 0.1 %** |
| Window hidden | not measured | **0.0 %** |
| Edit idle (big edit / real edit / after playback) | 0 % / 0 % / 0 % | 0 % / 0 % / 0 % |
| Edit paused while Claude's reply streams | 33 % (single window) | 37 % (median of 2 s windows) |
| Edit playback (big / real), playback while streaming | 103 % / 96 %, 113 % | 94 % / 97 %, 119 % |
| Filmstrips and waveforms after open | 27 s, 40 % average | 33 s, 43 % average |

"Claude panel open, Claude working" also read 0.0 %. That line sets the orb and edge to the working state but streams no reply text, so the integrator asked to confirm it really draws. The next commit logs the orb's state, its frame rate, whether the window counts as visible, and the orb frames drawn while measured. The streaming cost proper is "Edit paused while Claude's reply streams" (37 %); it shows the chat side isn't the dominant cost there now, and the Edit path is measured next.

### Edit while Claude patches (second commit)

Static read of the path: a patch from the live session lands in `showRemote` → `state.applyRemote` → `projectChanged`. That rebuilds the player item 120 ms later (debounced, keeping the playhead), and makes filmstrips and waveforms only for assets that have none yet (cached by asset id, so a patch doesn't regenerate them). The big edit check gains step 7, "Claude patches into the big edit": 20 patches at 2 a second (text changes and main-shot framing, alternately, through the fake session as `apply_edit_ops` sends them). Each must show within 2 s. The step logs the CPU median (fails above 80 %), the preview rebuilds it caused, the main thread's heaviest frames, and the idle CPU afterwards (fails above 25 %). Fixes on this path wait for those numbers.

### Run 718 (bundle 31): Claude's patches failed the new step, and the orb didn't tick on CI

- **Step 7 failed:** 20 patches at 2/s ran at a 91 % CPU median (windows 75 77 97 93 91), the slowest took 2.63 s to show, and there were 20 preview rebuilds. In the main-thread sample, about 2,990 of 3,185 samples were in SwiftUI's graph update. That means the whole editor was re-diffed per patch: one `EditSuiteState` value carries the project, so every view reading it updates. Smaller costs: `History.adoptRemote` re-encoded and diffed both projects through `JSONValue`, and `mirrorLive` reset the History list on every update.
- **Fixes:**
  - `RemoteChangeThrottle` (MuseCore): a change from the live session shows at once after a quiet moment. While changes keep coming, the newest is shown at most once a second; each carries the whole project, so nothing is lost. A held change is shown before any local edit or drag starts, so a local edit always lands on top of it.
  - `adoptRemote` skips the diff when there are no local undo or redo steps to carry over.
  - `liveHistory` is set only when it changes.
- **Coordinator's target, ≤ 1 s per patch (follow-up commit):**
  - The throttle's gap is 0.75 s.
  - Each clip's filmstrip and waveform on the timeline are Equatable views (`TimelineClipStrip`, `TimelineClipWave`): a patch re-diffs only the clips it changed, not every tile of every clip. Before, each block drew its strip inline, an `HStack` of image tiles, inside `TimelineCanvas`'s body.
  - The step now fails if a patch takes more than 1 s to show.
- **Orb:** run 718 logged state thinking, wants 20 fps, window visible, but only 1 frame drawn in 12 s. The `.animation` TimelineView schedule follows the display's refresh, which the headless runner doesn't have, so the 0.0 % for the working orb measured nothing. The orb and the edge now run on `OrbSchedule`, a plain timer (one frame and stop at 0 fps; at most 4 fps in the system's low-frequency mode), so CI measures the real cost.

### Run 722 (bundle 31 rebuilt): still failing, and the real cause

- **Step 7:** 83 % CPU, slowest patch 2.43 s to show, 20 rebuilds. The throttle never held anything back, and it couldn't. The step sends each patch only after the previous one shows, and Claude's real `apply_edit_ops` calls are sequential too, so holding a change only adds delay. **Removed.**
- **The sample** (`edit-big-patches-sample.txt`, 3,365 main-thread samples): about 2,500 are SwiftUI **layout**, not body evaluation. The path is `GeometryReaderLayout.placeSubviews` → `StackLayout.prioritize` → `lengthThatFits`, three levels deep (1,770 → 981 → 543 samples). On every change, the editor's nested flexible stacks (window → panel row → editor column → bin/preview/inspector) re-measured every panel at several sizes to work out who stretches. App code is a small share: `applyRemote` 72, `adoptRemote` 36 (it still diffs here, because the earlier Shape round trip leaves local undo steps), and `rowView` 31.
- **Fix:** every region of the editor gets its exact size from the window (`.frame(width:height:)` computed from the GeometryReader): top bar, panel row, media panel, preview, inspector, timeline, Claude panel, captions mode. They are the same sizes the stacks worked out before. A fixed frame answers sizing without measuring its content.
- **Orb:** the custom `TimelineSchedule` didn't tick on the runner either (still 1 frame in 12 s). The orb and the edge now redraw from a main-actor task (`OrbClock`) that bumps view state at the frame rate, the way every other view updates.
- **Gate (coordinator, after run 722):** "Claude patches show within 1 s" is a hard gate, since that's the lag the owner feels. "CPU while Claude patches the big edit" is INFO up to run 722's 83 % and fails above it, so it can't regress. A Canvas-drawn timeline lane is the next item.

### Run 728 (bundle 31 at c7cf2cc3)

- **Patch latency PASS:** slowest 0.84 s (was 2.43 s) thanks to the exact frames. **CPU still 85 %** (INFO limit 83 %); SwiftUI graph update is now about 53 % of the main thread (was about 75 %).
- **Edit paused while Claude's reply streams: 5 %** (was 26–46 %).
- **Orb:** the per-view `.task` clock didn't redraw on the runner either (1 frame). The one frame came from the orb's state change, published by `ClaudeOrbBox`. So the clock is now one shared `@Observable` `OrbTicker` whose `frame` goes up at the orb's rate (0 idle, 12 waiting/error, 20 working). It runs while the window can be seen, and only the views that read it (the live orb and the edge) redraw. The INFO line logs clock ticks and orb frames drawn.
- **Composer CUT in C at 1000×700:** theme C was shot while a demo render was still at 97 %; theme B was shot after it finished. My idle-check additions shifted review timing by about 20 s. In that state, the render card's "About a minute left · you can leave this screen" sat on one unconstrained line, wider than the portrait card, and pushed the whole page 38 pt past the window. This bug existed before; the queued line had the same problem. Both lines now wrap at the progress bar's 180 pt.
- **Timeline:** the Sound lane (one block per main clip, 66 on the owner's edit, no gestures) is now one Equatable Canvas, `TimelineSoundLane`, with the same drawing. Lanes with per-clip gestures (move, trim, keyframes, badges) need hit-testing done on a Mac with a profiler; that is the remaining CPU lever.
- **Coordinator, after run 728:** 85 % is accepted for this release (the show time went from 2.43 s to 0.84 s). The aim stays 83 %; step 7's CPU line is INFO up to 86 % (85 plus a point of noise) and fails above. The Canvas-drawn interactive timeline lanes are parked for a session on the owner's Mac with Instruments.

### Run 735 (bundle 35 at 9d1b8810)

- **Step 7:** shows within 0.82 s (PASS), CPU 78 % median, under the 83 % aim. Streaming in Edit 4 %.
- **Composer CUT, again:** it isn't the stage card. The title bar's "Rendering N %" indicator has a fixed 60 pt bar. With a render running, theme C's title bar needed more than 1000 pt and pushed the whole window's content past the right edge (theme dots, "Presets", the Rig panel and Generate all cut). This bug was already there. The bar, and the upload one, now give way in narrow windows (16–60 pt).
- **Orb: 0 clock ticks.** The "wants 20 fps" in the INFO line was worked out without Reduce Motion. Every clock tried (TimelineView ×2, per-view task, shared ticker) asks the orb for its rate with Reduce Motion, and Reduce Motion stops the orb, which is the likely explanation if the runner has it on. While review mode measures the working orb (forced visible), Reduce Motion is now ignored too. For people, Reduce Motion still holds the orb still. The INFO line logs the runner's Reduce Motion.

### Run 737 (bundle 35 at 604087c6)

- **The orb works.** "Reduce Motion true (overridden while measured), 106 clock ticks and 107 orb frames": Reduce Motion on the runner was the cause all along. "Claude panel open, Claude working" is 17.5 % (limit 30 %), 9.7 wake-ups/s.
- **Streaming in Edit 6 %; patch CPU median 69 %.** The slowest patch took 1.12 s to show (the hard gate is 1 s; runs 728 and 735 were 0.84 and 0.82 s), probably runner noise.
- **Composer CUT:** the title bar fits now, but the page was still about 7 pt wide, in `composer` and `composer_empty`, with a demo render card on the stage. The render card's contents (a fixed 180 pt progress bar and a caption up to 180 pt) sat in a ZStack with the card's picture inside a portrait card of about 160 pt. They set the card's width and pushed the page out. The card is now its picture, with everything written on it as an overlay, so it can't size the card. The bar and the captions can shrink (`maxWidth: 180`; captions wrap to two lines).

### Run 739 (bundle 35 at fcfcecc9)

- **All perf checks pass:** patches show within 0.81 s; patch CPU 79 % median; the orb drew 136 clock ticks and 136 frames; Claude working uses 10.2 %; idle after patches is 0 %.
- **Composer CUT, last cause:** the render card fits now. In the mid-render shot, though, the whole window's content (sidebar included) starts about 31 pt further right, and "MUSE Studio" sits on one line instead of two: the window content is wider than the window. The title bar's running-render indicator still had a minimum width even with the bar at 16 pt (padding, the truncated label, spacing), and theme C's title bar is right at 1000 pt. The indicator now uses `ViewThatFits`: label and bar, then the bar alone, then nothing. The stage card shows the render's progress anyway. `composer_empty` (no render running) was already fitting at 823.

### Final: bundle 38 (run 743, prod 3dc739f8 + perf through f33afc1 + Redo), green and READY

| Check | Build 704 | Run 743 |
|---|---|---|
| Idle, every main page, panel idle, window hidden | not measured | 0.0–0.1 % |
| Claude patches into the 66-clip edit: slowest to show | not measured (run 718: 2.63 s) | **0.86 s** (hard gate 1 s) |
| CPU while Claude patches (median) | not measured (run 718: 91 %) | 84 % (INFO, aim 83 %; windows 62 79 84 104 94) |
| Edit paused while Claude's reply streams | 33 % | 4–6 % (runs 735–739) |
| Claude panel open, Claude working (orb at 20 fps) | not measured | 8.8 % |
| Orb clock ticks / frames while working | — | 118 / 118 |
| Composer 1000×700 theme C, mid-render | CUT (title bar indicator) | FITS (Generate at x 834) |

Parked for a session on the owner's Mac with Instruments (coordinator): Canvas-drawn interactive timeline lanes (move, trim, keyframes, badges). That is the remaining lever for CPU while Claude patches. The late 104 % / 94 % windows come after the sample, while the player items rebuilt for the last patches decode.
