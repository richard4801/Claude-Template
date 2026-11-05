# Video suite UI (Phase 2 · workstream 1)

_Started 2026-11-05. Owner-approved designs. Backend: `plans/api.md` "AI suite" (live), `plans/ai-suite.md`. Build on **Android and Mac**._

## Spec sources (read these first)
- **Decisions and links:** `design/README.md` (8 decisions; they win over the mock-ups).
- **Screens:** `design/screens/ai-suite-desktop__D1…D10.jpg` (D3d = dark camera bag) and `design/screens/ai-suite-mobile__M1…M8.jpg` (M3d dark).
- **Exact copy, sizes and colours:** the generators, `design/source/ai_desktop.py`, `ai_mobile.py` and `base.py`.
- **Hardware renders:** `design/hardware/*.webp` (40) and `manifest.tsv`. Ship them in both apps under the name `hardware/<file>.webp`.
  - The API's camera catalog (`GET /v1/suite/camera`, also inside `GET /v1/suite/catalog`) tells you which render goes with which option: `render`, `name`, `caption` on bodies, lenses, looks, lighting and palettes, plus `optics` and `grips`.
  - `library` is the 16-move library, each move with a `tag` (ugc / cinematic / energy / subtle).
  - The apps never hard-code option lists. They draw what the catalog returns and keep a bundled copy only for demo mode.

| Screen | Desktop (Mac) | Mobile (Android) |
|---|---|---|
| Video suite hub: mode tiles, camera-stage card, recent takes | D1 | M1 |
| Shot builder: cast, scene (text / image / refs), references, and the **blurred-render result pane** (live job progress over the blurred source or character) | D2 | M2 |
| Camera bag · Preset: rig (body, lens, optics), light & look, move & angle. **Always dark** (decision 3) | D3, D3d, D4, D5 | M3, M3d, M4 |
| Camera bag · Directed (Blender) tab | D6 (workstream 2) | M5 (workstream 2) |
| Character swap + **Recast** (up to 4 people, `mode: "recast"`) | D7 | M6 |
| Storyboard: shots with one cast and a look lock; generate the ready shots | D8 | M7 |
| Owner Engines view: what each tier runs, compiled camera prompt, flags, cost | D9 | (owner sheet) |
| Result states: ready, rendering %, in line, failed, takes, Keep / Retake / Edit / Share | D10 | M8 |

## Rules (from `plans/coordination.md` and `design/README.md`)
- **Members never see provider or model names.** Only the owner's Engines view (D9) shows them; it uses the owner-only fields the API returns.
- **Quality ladder:** Draft / Standard / HD / Cinema everywhere, swap and Recast included. Add-ons stay add-ons.
- **Moves:** 16 in the library, UGC moves first, **at most two combined** ("Mix 2/2"). Intensity 0–100 %, Speed Slow / Normal / Fast.
- **Characters:** use the studio's real characters and their sheets, never "Sienna" or other placeholder names. In demo mode, use the demo studio's own models.
- **Prices:** every Generate shows the price from `POST /v1/suite/shots/estimate`, as `buttonLabel` / `priceLine`. A cap problem shows `message`. Claude never spends.
- **Suite off:** when `catalog.enabled == false` (server `SUITE_MODE=off`, the production default today):
  - **Owner:** a clear state, "Turn on the AI suite". It explains that the server variable `SUITE_MODE` must be set to `live` (real renders) or `mock` (free test renders) in Railway → Variables, with Copy for the variable name.
  - **Members:** "The AI suite isn't on yet · ask the studio owner".
  - `catalog.test == true` shows a small "Test renders · free" badge.
- **Demo mode** (Android Settings → Developer, Mac equivalent) must work end to end with no server. The fakes answer the suite endpoints: catalog, camera, estimate, shots, recast, settings, and simulated job progress through the existing fake job pipeline.
- **No UI sounds.** Use the existing four themes on Android, but the camera bag is always dark.
- **Labels:** keep the same wording as the API (`engineLabel` "Shot · HD · 1080p", "Recast · HD · 1080p", tier labels and details).

## Navigation (owned by workstream 1)
- **Rename:** "Video studio" becomes **Video suite**.
- **The Video suite group's modes:** Shot, Character swap (with Recast inside it), Storyboard, Talking · lipsync, UGC ad, Extend & upscale, Camera stage.
  - **Talking, UGC ad, Extend & upscale:** the API has no backend for these yet. Show them as tiles with a quiet "Coming soon" state, not a broken screen.
  - **Camera stage:** opens workstream 2's screen.
- **Edit** becomes top-level (workstream 3's screen).
- **Entry points for the other workstreams:** stubs with these exact paths and signatures. The other workstreams replace the files at merge; keep the stubs minimal.
  - **Android:**
    - `ui/screens/camera/CameraEntry.kt` (package `studio.muse.app.ui.screens.camera`): `@Composable fun CameraStageScreen()`, `@Composable fun DirectedModePanel(shotTitle: String, onApply: (cameraJson: String) -> Unit)` and `@Composable fun ConnectionsScreen(onBack: () -> Unit)`.
    - `ui/screens/edit/EditSuiteScreen.kt` (package `studio.muse.app.ui.screens.edit`): `@Composable fun EditSuiteScreen(takeId: String?, onBack: () -> Unit)`.
    - Routes: `Routes.CAMERA_STAGE = "camera-stage"`, `Routes.EDIT = "edit"`, `Routes.EDIT_TAKE = "edit/{id}"`.
    - `Routes.EDIT_VIDEO` keeps working: "Edit video" on a take opens `EditSuiteScreen(id)`.
    - **Settings:** an owner-only row "Connections" (subtitle "Claude & MCP · Blender relay") opens `ConnectionsScreen`. It is one additive line in Settings.
  - **Mac:**
    - `Muse/Views/Camera/CameraEntry.swift`: `struct CameraStageView: View { init() }`, `struct DirectedModePanel: View { init(shotTitle: String, onApply: @escaping (String) -> Void) }` and `struct ConnectionsView: View { init() }`.
    - `Muse/Views/Edit/EditSuiteView.swift`: `struct EditSuiteView: View { init(takeId: String? = nil) }`. It reads the AppStore from the environment.
    - **Settings:** an owner-only "Connections" row opens `ConnectionsView`.
    - The sidebar gets a top-level "Edit" item.

## Ownership (write only here; shared files with small additive blocks marked "AI suite (workstream 1)")
- **Android:**
  - `android/app/src/main/kotlin/studio/muse/app/ui/screens/suite/**`
  - navigation in `ui/MuseApp.kt` (routes, bottom bar and menu)
  - the two stub files above
  - suite data in new files under `data/` (e.g. `data/Suite.kt`, `data/FakeSuite.kt`), with additive lines in `MuseApi.kt` / `HttpMuseApi.kt` / `FakeMuseApi.kt` / `Models.kt`
  - assets: `app/src/main/assets/hardware/*.webp` (a Gradle copy from `design/hardware`, or committed copies)
  - tests: `app/src/test/kotlin/studio/muse/app/Suite*Test.kt`
- **Mac:**
  - `mac/Muse/Views/Suite/**`
  - the sidebar in `mac/Muse/Views/RootView.swift`
  - `mac/MuseCore/Sources/MuseCore/Suite/**` and its tests `mac/MuseCore/Tests/MuseCoreTests/Suite*`
  - `AppStore+Suite.swift`
  - additive lines in `MuseAPI.swift` / `HTTPMuseAPI.swift` / `FakeMuseAPI.swift` / `Models.swift`
  - the hardware renders bundled via `project.yml` (like `looks`)
  - the two stub files above

## Tests
- **Android:** unit tests plus **Roborazzi screenshots in all 4 themes at 390 dp and 360 dp** for the hub, Shot builder (idle and rendering), camera bag (rig and move tabs), swap / Recast, storyboard, result states, and suite off (owner and member).
  - Commands: `./gradlew :app:testDebugUnitTest` and `./gradlew :app:recordRoborazziDebug --tests 'studio.muse.app.Suite*'`.
  - The existing tests must stay green.
- **Mac:** `swift test` for MuseCore (decoding the real API's JSON for the catalog, estimate and job; the fake suite) plus the full app build. GitHub Actions `mac.yml` runs on every push that touches `mac/**`; it must be green.
