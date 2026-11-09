# Suite stage fix (WS19, 2026-11-09)

The owner's report (Mac, AI Suite, Photo × 4): after Generate the stage stayed empty, with no generating state; the
result only showed up in the Gallery; several results didn't show as a set; leaving the page lost the result; and photo
runs never appeared in the Queue.

## Root cause

- **Photo wasn't a job.** `POST /v1/suite/photos` ran the whole shoot inside the request and answered with takes. Nothing
  was in `jobs`, so the Queue, the hub's `job` events and the stage had nothing to follow. The Mac stage hard-coded
  `nil` for Photo and opened the first still in the take viewer.
- **The stage followed session-only ids.** `suite.shotJobIds` / `swapJobIds` were in memory and shared across modes (one
  list for Shot, Talking, UGC ad and Extend), so a mode showed another mode's job and nothing survived a restart.
- **No starting state.** Between Generate and the job coming back, the stage showed the empty canvas or the previous job.

## Server

- Every photo run is now a `render` job with `request.engine = 'photo'` (`request.takes` = the count, `engineLabel`
  "Photo"). It's inserted once the price is held (no job when the bill refuses). It runs with phase
  "Making photo n of N" and progress per still (template shoots), and ends `done` with `stats.photo.takeIds`.
  `GET /v1/jobs` and `job` hub events carry these as `takeIds`. The stills stay jobless takes, so the Library is
  unchanged. The draft is kept on the job, so the feed's tool reads `photo`.
- `POST /v1/suite/photos` with `async: true` answers `{tool, takes: [], job}` as soon as the job is running.
  Without it, the call waits as before and answers `{tool, takes, job}`, so older apps (Android) keep working.
- Photo jobs never touch a GPU line: no `gpuState` is set, and cancel (Remove) skips the GPU. Photo jobs still
  running when the server starts are marked failed ("Interrupted").
- No migration: `jobs.kind` and `request` are text and jsonb.
- Test: `test/suite-photo.test.ts` "every photo run is a job".

## Mac

- `Job.takeIds`, `Job.isPhoto`, `Job.suiteTool` (from the draft, else the request).
  `MuseAPI.suiteStartPhotos` (HTTP with `async: true`; the fake runs the shoot in the background and emits the job's
  events).
- `AppStore.stageJob(tool)` returns the newest of three candidates: the job remembered for the mode
  (`rememberStage`, in `suite.stageJobs` and UserDefaults per server), my newest job tagged with that tool, and this
  session's shot or swap job. Every Generate path records it: Shot, Talking, UGC, Extend, Swap, Recast, Photo, a queued
  shot run, and Claude's approved render. A new generation replaces the stage.
- `ComposerMediaPane` shows "Starting…" while Generate is in flight, then `SuiteResultPane` for the mode's stage job:
  queued or rendering with progress (Photo shows its phase, not the video steps), then the result.
- Results with more than one item (Photo × 4, multi-take video) show as a carousel on the stage: previous and next,
  dots, and ← → once it has focus.
- Queue: photo rows read "4 photos" instead of "0 s". Review opens the stills. A failed photo run offers "Make again",
  which opens Photo. Retake on the stage runs the Photo composer again.
- Storyboard keeps its own per-shot result panes (`boardJob`), which already show generating and the result. It isn't
  persisted across a restart (the board itself isn't), so that part is unchanged.
- Upscale jobs show on the Extend & upscale stage.
- Check: `SnapshotRunner+SuiteStage.swift` writes `suite-stage-check.txt`, and Mac CI's "Suite stage check" step fails
  on any FAIL line. Photo × 4 covers generating, the job in the Queue while it runs, a carousel of 4, leaving and
  returning, a restart, and the Queue row. Shot covers generating, leaving and returning, and the Queue row.

## Android (later)

Same flow in `android/app/src/main/kotlin/studio/muse/app/`:

1. **Data** (`data/Photo.kt`, `HttpMuseApi.kt`, `FakeMuseApi.kt`): decode `job` on the photos result and `takeIds` on
   `Job`. Add `suiteStartPhotos(req): Job`, which posts `/v1/suite/photos` with `"async": true`. Add `Job.isPhoto`
   (`request.engine == "photo"`) and `Job.suiteTool` (draft's `tool`, else photo / upscale→extend / suite→shot).
   In the fake, insert a running photo job and emit job events, then finish it with `takeIds` and `takes` (copy the
   Mac fake, `FakeMuseAPI+Photo.swift`).
2. **Generate** (`ui/screens/suite/composer/PhotoTool.kt`, `ComposerScreen.kt`): Photo calls `suiteStartPhotos`,
   upserts the job and stops opening the first still. Every Generate path (shot, talking, UGC, extend, swap, recast,
   photo, queued run, Claude's approved render) records `stageJob[tool] = job.id` in the Suite state and in
   SharedPreferences, keyed per server.
3. **Stage** (`SuiteResultPane`, `StudioStage`): the stage job for a mode is the newest of three candidates: the
   remembered id, my newest job whose `suiteTool` is the mode, and the session job. Show "Starting…" while Generate is
   in flight, then queued or rendering with progress. For photo, show `phase` instead of the video step list.
   Show results with a `HorizontalPager` and dots when there is more than one: `takeIds` for photo jobs, the takes by
   `jobId` otherwise. Reset to page 0 when the job changes.
4. **Queue**: photo rows show "N photos" instead of seconds. Review opens the stills by `takeIds`. A failed photo row's
   retry opens Photo instead of re-posting `/v1/jobs`, and Retake on the stage re-runs the Photo composer.
5. **Tests**: a Robolectric/unit test on the fake for Photo × 4 (job running, then done with 4 `takeIds`; stage job per
   mode after clearing session state), and Roborazzi shots of the stage's generating state and the 4-item pager.
