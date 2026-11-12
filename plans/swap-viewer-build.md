# New Swap screen and the take viewer: build (2026-11-12)

The design is `plans/swap-viewer-design.md` (on branch `claude/design-swap-viewer`, with the mockups). The owner approved it on 2026-11-12. The owner's answers:
- **Split** opens the take in Edit at the current moment.
- **No progress line** anywhere.
- **Skip** is 3 s.
- **Character** is on by default (her, figure lock), including for a background-only remix. Once switched off, it stays off.
- **Phone double-tap** skips YouTube-style.
- **Skins:** Clean, TikTok, Reels, Shorts and Facebook for portrait; Clean, YouTube and Facebook for landscape. Remembered per device.
- **No paid preview** for now.

## Server (this branch, `claude/swap-viewer`; not prod)
- `GET /v1/preview/layouts`: the safe zones per skin, for any signed-in person. The table is in `src/suite/previewLayouts.ts`; it is approximate and can change without an app update. The test is `test/preview-layouts.test.ts`.
- Checks run: `tsc` is clean. The full vitest run is green: 948 passed, 12 skipped, 123 files.

## Mac (`plans/patches/swap-viewer-mac.patch`)
Apply it **on top of** `plans/patches/new-swap-fix-mac.patch` (branch `claude/new-swap-fix` @595ff467). The patch reuses that patch's model popover, its Character default and its take actions.

**MuseCore**, `Suite/TakeViewerCore.swift`:
- skins and safe zones (defaults, plus the server's table merged over them);
- per-device prefs;
- frame maths (no letterbox; phone and laptop);
- keys and transport: Space; ← and → for 3 s, or 10 s with ⇧; J/K/L shuttle; , and . for one frame; ↑ and ↓ for the previous or next take;
- the seek readout "+3 s  0:07 / 0:10";
- the phone double-tap rule (for Android);
- actions per context and the order their labels give way (Split, Upscale, Extend, Redo; Keep and Share keep their labels);
- the New Swap trimmer maths;
- the `previewLayouts()` call.

Tests are in `TakeViewerTests` (12). **MuseCore on Linux (Swift 6.0.3): 890 tests, 0 failures.**

**App:**
- **`Views/Viewer/TakeViewer.swift`:** the one viewer. It has:
  - the media at its own shape;
  - Clean or a platform layout;
  - the phone or laptop frame and the safe zones;
  - no scrubber and no loader;
  - the readout while seeking;
  - Keep, Redo, Extend, Upscale, Split, Share and More, in a rail beside portrait media or a row under landscape media.
  
  It is used by:
  - the Suite stage (a finished take);
  - the Takes viewer (`FeedViewer`);
  - Compare (the Suite's and the Library's);
  - the Library take page (its actions stay in the inspector);
  - New Swap's source clip.
- **`Views/Suite/Composer/NewSwapScreen.swift`:** New Swap's own screen.
  - Before a video: Library, Upload or Paste link, or drop a file.
  - With a video: the clip in the viewer and a filmstrip trimmer under it.
  - The column holds only the four changes. The bottom bar has the model, the price and Generate, with no prompt box.
  - After Generate, the stage shows the take; "Back to the clip" returns to the video.
- **Split:** `openEdit(takeId:at:)` opens Edit, and Edit's playhead starts at that moment (`suite.editAt`).
- **`clipVideo` on the store:** the clip's playable file or take video.
- **Icons:** 9 Phosphor icons were added for the generic platform layouts. `design/icons/build.py` regenerated the Mac asset catalog and `PhosphorMap.swift`, and Android's `PhosphorIcons.kt`, which is additive only.
- **Checks:** every app file passes `swiftc -parse`. An independent review checked every symbol and SDK call against the codebase and the macOS 14 SDK. It found no compile errors and five runtime bugs, all fixed. SwiftUI can't be type-checked on Linux, so the Mac CI is the first full build.

## Not done here
- **Android** comes after the Mac is green: the same viewer and the New Swap screen in Compose. The double-tap rule is in MuseCore as the spec.
- **Snapshot or CI review states** for the new screen: the existing `stage carousel` probe is kept.
