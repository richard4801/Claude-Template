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
- **The splash holds for 2.6 s** before Home (tap skips it). That is a design choice, not load time. Home's data is ready about 0.5 s after launch (see above), so the splash, not the network, sets when Home appears.

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
