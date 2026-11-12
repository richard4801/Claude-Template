# Platform preview moves into Edit (owner decision 2026-11-12)

The platform views (TikTok, Reels, Shorts, Facebook, YouTube and Clean) leave the take viewer and New Swap and go into
Edit, merged with Edit's safe-area guide. The owner already approved the idea. Worker branch: `claude/edit-platform-preview`.
Mac changes are in `plans/patches/edit-platform-preview-mac.patch`. Android comes after the Mac.

Mockups: `plans/design/edit-platform-preview/*.png`. To regenerate them, run
`PHOSPHOR=<unpacked @phosphor-icons/core 2.1.1> python3 design/edit-platform-preview/render.py`.

| File | What it shows |
|---|---|
| `edit-tiktok-dark.png`, `edit-tiktok-light.png` | TikTok view: the chrome over the edit, the red safe box, and a caption under TikTok's buttons with its warning line |
| `edit-clean-dark.png`, `edit-clean-light.png` | Clean view with Safe area off: nothing over the edit |
| `edit-clean-safe-dark.png` | Clean view with Safe area on: the red box that is safe on every app |
| `edit-youtube-landscape-dark.png` | A 16:9 project in YouTube view (the in-player chrome and its box) |

## Edit's viewer bar
- **View** is one segmented control:
  - portrait, square and 4:5 projects: Clean · TikTok · Reels · Shorts · Facebook;
  - 16:9 projects: Clean · YouTube · Facebook.
- **Safe area** is a switch, on by default. It works in every view:
  - In a platform view, it shows that app's red dashed box.
  - In Clean, it shows the box that is safe on every app (the largest inset of each side across TikTok, Reels, Shorts and Facebook).
  - Landscape views use their own boxes.
- The chrome is our own generic drawing, with no logos and no brand colours. It is the same art as before (`PhoneSkin`, moved out of `TakeViewer.swift`). Landscape views draw the app's in-player chrome over the edit (title row and bottom controls), not a whole web page, so the edit stays full size.
- The chrome fills the canvas exactly. The canvas is the output, so nothing is cropped.
- The choice is remembered per project, falling back to the device's last choice for a new project (MuseCore `EditPreviewPrefs`, in UserDefaults; the shared project contract is unchanged).
- When captions or text sit outside the box at any time in the edit, one line under the viewer says so: "Captions sit under TikTok's caption and buttons (0:01–0:09)." It comes with "Move into the safe area", which moves the caption position up, or moves the text item inside the box.

## Safe zones
- The table stays `GET /v1/preview/layouts` (`server/api/src/suite/previewLayouts.ts`). It gains an additive `landscape` map with YouTube and Facebook.
- MuseCore `PreviewLayouts` holds the defaults and merges the server's table over them, as before.

## Claude knows the view
- Edit's presence ping (`POST /v1/edit-sessions/:id/presence`) also carries `preview: {view, safeArea}`. It is sent at once when the view changes.
- `get_edit` returns `preview`, with the view, its safe box and an `unsafe` list (captions and text items outside the box, with their times).
- `apply_edit` adds `safeAreaWarnings` when a change leaves captions or text outside the box.
- The tool descriptions tell Claude to warn the person, in plain words, when that happens.

## Removed from the viewer
`TakeViewer` (Suite stage, Takes, Compare, Library, New Swap's source) loses:
- the preview bar and the compact "Preview:" menu;
- the skins;
- the phone and laptop frames;
- the safe zones;
- the `viewer.prefs` storage.

It stays a clean player: the media at its own shape, the keys and readout, and the action rail or row. `ViewerPrefs` and the phone and laptop frame maths are removed from MuseCore. `PreviewSkin`, `SafeZone` and `PreviewLayouts` stay, now used by Edit.

## Build (2026-11-12)

### Server (branch `claude/edit-platform-preview`, not prod)
- `src/editor/safeArea.ts`:
  - the box per view;
  - the caption and text estimate;
  - `previewView` for get_edit;
  - `newSafeIssues` for apply_edit_ops.
- `src/suite/previewLayouts.ts` adds `landscape` (YouTube, Facebook).
- `src/editor/sessions.ts`: presence keeps `preview`. Its `preview(id)` gives the freshest presence that sent one, and `applyClaude` adds `safeAreaWarnings`.
- `src/editor/mcpTools.ts`: get_edit returns `preview`, and both tool descriptions tell Claude to warn in one plain line.
- Tests:
  - `test/edit-safe-area.test.ts` is new;
  - `test/preview-layouts.test.ts` now checks `landscape`;
  - `test/editor-sessions.test.ts` checks that get_edit sees the view from presence.
- The change is additive. An older app sends no `preview`, and get_edit then says no app has reported its view.

### Mac (`plans/patches/edit-platform-preview-mac.patch`)
Apply it **on top of** `plans/patches/swap-viewer-fix-mac.patch` (branch `claude/swap-viewer-fix` @27fce1e5, in mac-bundle-8), which is on prod 31fe6868. It keeps that patch's fixes: the fixed-height action row, the More and Upscale popovers, the `.layoutPriority`/`.clipped()` layout, and the `stage_take` and `viewer_clean` states. It removes that patch's `ViewerPreviewButton`, the `skinPicker`/`frameToggle`/`zonesToggle` helpers, the `viewer_tiktok` state and the `viewerPrefs` helper.

**MuseCore**
- `Edit/EditPlatformPreview.swift`:
  - `EditPreview` (the view and the switch);
  - `EditSafeBox` (the box per view: every app's box in Clean, title-safe on 16:9);
  - `EditSafeCheck` (the issues, the warning line, and "Move into the safe area");
  - `EditPreviewPrefs` (per project, plus the device's last choice; up to 200 projects).
- `EditSuiteState`: `preview` replaces `safeArea` (the old enum `EditSuite.SafeArea` is gone).
- `TakeViewerCore`:
  - `ViewerPrefs` and the phone and laptop frame maths are removed;
  - `PreviewLayouts` gains `landscape` and `landscapeZone`.
- `EditPresence` carries `preview`.
- Tests: `EditPlatformPreviewTests` (5); `TakeViewerTests` is updated. **MuseCore on Linux (Swift 6.0.3): 909 tests, 0 failures.**

**App**
- `Views/Edit/EditPlatformChrome.swift`:
  - `PhoneChrome`, moved from the viewer's `PhoneSkin`;
  - `LandscapeChrome` (YouTube and Facebook in-player chrome);
  - `EditSafeBoxGuide` (the red dashed box).
- `Views/Edit/EditSuitePreview.swift`: the View picker, the Safe area switch, the chrome and the box, and the warning line with "Move into the safe area". The Captions page's preview uses the same box.
- `App/Edit/EditSuitePlatformPreview.swift`:
  - `setPreview` remembers the choice in UserDefaults (`edit.preview`) and pings presence at once;
  - the layouts come from the server;
  - the issues and `moveIntoSafeArea()` (one undoable change, labelled "Moved into the safe area").
- `EditSuiteLive`: the 30 s presence ping carries the view.
- `Views/Viewer/TakeViewer.swift` keeps only the clean player. These are removed:
  - the preview bar and menu;
  - the skins;
  - the phone and laptop frames;
  - the safe zones;
  - the `viewer.prefs` storage.
- `NewSwapScreen` drops `previewControls:`.
- **Snapshot states** (`SnapshotRunner.editLayoutShots`, 1440 × 900):
  - `mac_editpreview_b_tiktok.png` and `mac_editpreview_b_clean.png` (dark);
  - `mac_editpreview_a_tiktok.png` and `mac_editpreview_a_clean.png` (light);
  - FITS/CUT lines go to `fit-check.txt`. Review mode always starts in Clean and never saves the choice.
- Checks:
  - every changed app file passes `swiftc -parse`;
  - SwiftUI can't be type-checked on Linux, so the Mac CI is the first full build;
  - the patch applies cleanly on prod `31fe6868` with `swap-viewer-fix-mac.patch` applied.
- **Watch on CI:** at 1000 × 700 the five-way View control plus the switch may not fit in the viewer bar. That size only gives INFO lines, not CUT lines.

- "Move into the safe area" also narrows a text item's wrap width when the text is wider than the box (a long hook at 85 % on TikTok's 80 % box). A MuseCore test covers it.

### Android (`plans/patches/edit-platform-preview-android.patch`, on prod 767fabdc; the coordinator's go, 2026-11-12)
**Core** (`core/src/main/kotlin/studio/muse/core/edit/PlatformPreview.kt`) has the same rules as MuseCore and the server:
- `PreviewView`, `SafeZone` and `PreviewLayouts` (defaults, plus the server's table parsed and merged);
- `EditPreview`, `EditSafeBox`, `EditSafeCheck` (the issues, the line, and the fix) and `EditPreviewPrefs` (JSON).

Tests: `PlatformPreviewTest` (6), on the shared fixtures.

**App**
- `EditSuiteUi.preview` and `previewLayouts` replace `safeArea` (the `SafeArea` enum is gone).
- Actions: `PreviewOf`, `PreviewLayoutsOf` and `MoveIntoSafeArea` (one undo step).
- `onPreviewChanged`: the ViewModel remembers the choice per project in SharedPreferences (`edit-preview`). On load it restores the choice and fetches `GET /v1/preview/layouts` (`MuseApi.previewLayouts`, null on demo or offline).
- `EditPresence.preview` is sent every 30 s, and at once when the view changes, so Claude knows the view.
- `EditPlatformChrome.kt` has the same generic drawings as the Mac (`PhoneChrome`, `LandscapeChrome`, `SafeBoxGuide`, red `#FF5A5F`).
- **Phone:** the old safe-area chip, which cycled TikTok, Reels, Shorts and off, becomes a view chip. It opens a menu with the views and a Safe area switch.
- **Tablet:** "View" (segmented) plus the Safe area switch.
- **Both layouts:** a warning pill at the bottom of the stage with "Move into the safe area" (48 dp target).
- `EditAuditTest`: the view checks replace the old safe-area line.

**TakeViewer on Android:** nothing to remove. Android never got the viewer's skins, frames or safe zones (the swap-viewer work stopped at the Mac), so its viewer is already a clean player. When the Android TakeViewer is built, it must not get platform previews.

