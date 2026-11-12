# Swap viewer fix (owner, build 582, 2026-11-12)

The owner installed build 582 (prod 31fe6868) and said: "It's terrible… That's not what I requested. It basically looks like nothing was done."

The Mac patch is `plans/patches/swap-viewer-fix-mac.patch`. It is made against prod 31fe6868 and touches no server code.

## What went wrong, and why
1. **A giant chevron and giant dots on the stage and in the Takes viewer.** The take viewer used SwiftUI `Menu`s whose labels held a Phosphor icon (`Ph`, a resizable image with a frame). On macOS a menu label drops the frame, so the icon draws at the size of the space it gets. The "Preview: Clean ▾" chevron filled the stage, and More's three dots grew huge.
2. **The take didn't show, the actions were cut and "Prev…" was truncated.**
   - Those huge labels took the height, so the media area got almost none.
   - On the stage, the viewer also sat inside the tool's 9:16 box (about 250 pt wide), where the action row couldn't fit.
   - The takes strip under it was cut to the same width.
3. **New Swap didn't match the approved mockup:**
   - The Library grid filled the stage.
   - The Changes column was plain switches with no state lines; Character was a large Her | Face swap segmented control plus a name menu.
   - The bottom bar was still the composer's.
4. **Process: it was visible before handover.** CI run 582's own screenshots (`mac_*_composer_feed_viewer_*`, `mac_a_suite_stage_photo`) show the giant chevron and dots. Nobody compared them with the mockups. From now on, the real views are rendered and placed beside the mockups before handover (§ Snapshot states).

Before and after evidence is in `plans/design/swap-viewer-fix/`:
- `before-newswap-empty.png`, `before-stage-viewer.png`: the approved mockup next to the owner's build 582.
- `before-feed-viewer.png`: the mockup next to CI run 582's own shot.

## The fix
**Take viewer (`Views/Viewer/TakeViewer.swift`)**
- **No `Menu` with an icon label anywhere.** More and the preview choices are buttons with popovers. Every icon has an explicit frame.
- **Layout:**
  - The preview bar has a fixed 32 pt height. When there's no room, it folds into a "Preview: Clean" button.
  - The action row is 40 pt. The media gets the rest (at least 160 pt), and the whole viewer clips.
- **Actions never cut:**
  - The row's labels give way in order: Split, Upscale, Extend, Redo.
  - At the narrowest, the row is Keep plus Upscale and Share as icons, and More holds Redo, Extend and Split.
  - Upscale uses the viewer's own button, Phosphor like the rest, instead of the shared button's SF Symbol.
- **Small panes (the stage, Compare):** the preview choice is a 28 pt icon on the media's corner, with a popover.

**Suite stage (`ComposerStage.swift`).** A finished take gets the whole stage width, and the viewer sizes it to its own shape. The takes strip is never narrower than 560 pt.

**New Swap (`NewSwapScreen.swift`, `NewSwapPanel.swift`), matched to `newswap-mac-empty` and `newswap-mac-filled`:**
- **Empty:** a centred drop zone with "Add the video to remix", one line, and three buttons: From the Library, Upload a file, Paste a link. Library opens a sheet (a 5-column grid of 9:16 tiles); it no longer fills the stage.
- **Filled:**
  - a source row with the name, length, size and Replace (a popover);
  - the clip in the viewer;
  - the filmstrip trimmer.
- **Changes column:**
  - Each change shows its name and a state line ("Kept from the clip", or what it does), with the switch on the right. Its one field sits on the field tone.
  - Character shows her chip (face, name, "Face and figure from her pictures", Change), with "Face swap from a photo instead" under it.
- **Bottom bar (new `NewSwapBar`):**
  - Left to right: Clip sound, the model (bordered, text and caret), and why Auto picked it (or what's missing).
  - Then "10 s, 1080p", and Generate · $x.
  - There is no quality pill and no "How is this priced?".

## Snapshot states (Mac CI, `SnapshotRunner.swift`, 4 themes at 1280 × 800 and 1000 × 700)
| State | What it shows |
|---|---|
| `stage_take` | A finished take on the Shot stage |
| `viewer_clean` | The Takes viewer, Clean |
| `viewer_tiktok` | The Takes viewer with the TikTok layout, phone frame and safe zones (YouTube in the laptop frame for a landscape take) |
| `newswap_empty` | New Swap before a video |
| `newswap_filled` | New Swap with the sample clip, Background and Look & light on |

The files are named `mac_<theme>_<state>_<w>x<h>.png` in the `mac-screenshots` artifact. Put them beside the mockups in `plans/design/swap-viewer/` before the build goes to the owner.

## Checks
- Every changed Swift file passes `swiftc -parse`.
- MuseCore is unchanged (890 tests, 0 failures earlier today).
- SwiftUI can't be type-checked or rendered on Linux. The Mac CI run is the first full build and the first real render.
