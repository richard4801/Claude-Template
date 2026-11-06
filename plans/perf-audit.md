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
