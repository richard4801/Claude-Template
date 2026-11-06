# Part B restyle: screens for the owner's review (WS2, 2026-11-06)

Home, Library, Cast (a model's page), Settings, the Claude chat and Welcome, restyled against `plans/design-direction.md`.
`*_topbar_photo` and `*_suite_hub` show the shared top bar and section labels in sentence case ("Photo", "Recent photos").
Themes: `a` Editorial (light), `b` Camera Body (dark), `c` Soft Tactile, `d` Creator Pop. Demo data, no real people.

- `android/`: phone at 390 dp, from the Roborazzi screenshot tests (`./gradlew :app:recordRoborazziDebug`).
- `mac/` also has Queue, Models, LoRA, Prompts, Studio settings (`settings_studio`), Credit and Members.
- `mac/`: the window as Mac CI's runner shows it (1100 × 748, so the sidebar is in its compact icon form), from the review mode (`MUSE_SNAPSHOT_DIR`, see `mac/Muse/App/SnapshotRunner.swift`).

Not part of this restyle (other workstreams): the bottom bar and its labels (WS1), the AI Suite, composer, pickers and
Edit suite (WS4), the Photo tool (WS3). Labels such as "Shoot" on older takes come from the data. The caps still visible
inside the composer and the suite hub ("PHOTO", "STYLE", "TEST RENDERS · FREE") are hard-coded in WS4's files; WS4 is
clearing them in Part A.
