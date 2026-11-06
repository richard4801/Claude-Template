# Part B restyle: screens for the owner's review (WS2, 2026-11-06)

Home, Library, Cast (a model's page), Settings, the Claude chat and Welcome, restyled against `plans/design-direction.md`.
Themes: `a` Editorial (light), `b` Camera Body (dark), `c` Soft Tactile, `d` Creator Pop. Demo data, no real people.

- `android/`: phone at 390 dp, from the Roborazzi screenshot tests (`./gradlew :app:recordRoborazziDebug`).
- `mac/`: 1440 × 900 window, from Mac CI's review mode (`MUSE_SNAPSHOT_DIR`, see `mac/Muse/App/SnapshotRunner.swift`).

Not part of this restyle (other workstreams): the bottom bar and its labels (WS1), the AI Suite, composer, pickers and
Edit suite (WS4), the Photo tool (WS3). Labels such as "Shoot" on older takes come from the data.
