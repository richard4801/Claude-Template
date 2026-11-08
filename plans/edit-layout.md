# Edit suite layout (Mac): audit and proposal

_WS2, 2026-11-08. Owner: "Right now it's just too cramped. With letters cutting off. It needs to be properly designed… Optimize
the page and sizing." The clean app style of `plans/design-direction.md`, not the cinematic one. **For the owner's approval
before building.**_

Images in `plans/edit-layout/`:
- **Before**: `before_<theme>_<size>.png`, from Mac CI's review mode (`SnapshotRunner.editLayoutShots`) on a real 15 s take with
  sound, at 1280 × 800, 1440 × 900 and 1470 × 882 (a 13" MacBook Air's default 1470 × 956 screen less the menu bar and Dock).
  The CI runner's screen is 768 pt tall, so these come out 684 pt tall; the widths, which cause the cramping, are exact.
- **After** (mock, `design/edit-layout/render.py`): `after_<theme>_1280x800.png`, `after_<theme>_1470x882.png` and
  `after_<theme>_1280x800_collapsed.png` (inspector and media hidden).
- Themes: `c` Soft Tactile (first), `a` Editorial, `b` Camera Body, `d` Creator Pop.

## Audit (today, `before_*`)

Why it is cramped: the full app sidebar (≈228 pt), the media bin (220–300 pt) and the inspector (300–360 pt) are all fixed
widths beside the viewer, so at 1280 pt the viewer and the inspector's controls get what's left.

| # | Where | What | Size |
|---|---|---|---|
| 1 | Inspector tabs | Six text tabs in 300 pt break mid-word: "Captio/ns", "Vide/o", "Audi/o", "Spee/d"; "Anim" is cut | all, even 1470 |
| 2 | Top bar | Title truncates ("Living room da…") | 1280, 1440 |
| 3 | Media bin tabs | Six icon tabs with 9–10 pt labels; "Templ." truncated; targets ≈ 36 × 40 | all |
| 4 | Media bin | "From the AI suite" wraps; take captions truncate ("Living room d…"); one tile per row | all |
| 5 | Inspector | Style tiles cut off at the bottom edge; the panel scrolls in a short area | all |
| 6 | Track header | "Vi…" (Video) truncated; three 14 pt icons crowd the name | all |
| 7 | Timeline clip | The clip's name is monospaced and clipped ("iving room dance") | all |
| 8 | Timeline | One track and a large empty area; the captions and sound aren't shown as tracks | all |
| 9 | Timeline toolbar | Split, delete, speed, keyframe and crop are 20 pt icons with no label; undo and redo appear twice (top bar and timeline) | all |
| 10 | Viewer | Safe-area chips are three small boxed buttons; "Fit · 100%" and the timecode in monospace | all |
| 11 | App sidebar | Stays in its full width with the suite's sub-list, taking 228 pt from the editor | 1280, 1440, 1470 |
| 12 | Type | Sizes from 9 to 13 pt off the scale; mono used as decoration | all |

## Proposal (`after_*`)

- **App sidebar** goes to its 72 pt icon rail while Edit is open (the compact form it already has under 1240 pt).
- **Top bar (56 pt)**:
  - On the left: back, then the title in full (`heading`) over its version line (`caption`, ink2).
  - In the centre: the aspect ratio as one segmented control.
  - On the right: Claude, Templates and Hook ideas as quiet buttons, then **Export** as the one primary.
  - Undo and redo move to the timeline only.
- **Media (304 pt, collapsible)**:
  - A 72 pt tab rail with icon and label: Takes, Uploads, Music, Text, Stickers, Templates (11 pt `micro`, full words).
  - A panel with a heading, a two-column grid of takes (picture, name, duration in tabular figures), and Import / Record VO.
  - "Hide media" (≪) collapses it.
- **Viewer** (flexible, ≥ 560 pt at 1280):
  - The frame on the viewer tone, with "Safe area: Off · TikTok · Reels · Shorts" as one segmented control.
  - Below it: the timecode (tabular), back / play / forward (play is 40 pt), sound and full screen.
- **Inspector (328 pt, collapsible)**:
  - Its sections as a 3 × 2 grid of labelled buttons (Captions, Text, Video, Audio, Speed, Animate), so no tab ever breaks.
  - Then the section's settings, grouped by space with `heading` titles, scrolling inside the panel.
  - "Hide inspector" in its header collapses it.
  - When hidden, "Show inspector" appears in the top bar. It starts expanded (WS3's click-through walks it).
- **Timeline (268 pt)**:
  - A 48 pt toolbar:
    - Split, Delete, Speed, Keyframe and Crop show icon and label at ≥ 1440 pt, and icon with tooltip at 1280.
    - Undo / Redo.
    - Ripple, Cut silences and Snap to beat as toggles.
    - Zoom.
  - A time ruler in tabular figures.
  - Three tracks with 176 pt headers (Video, Captions, Sound) showing name, mute and visibility in full.
  - The video track shows frames, captions show their words, and sound shows its waveform.
- **Everywhere**:
  - The type scale only: `heading` 16, `label` 14, `caption` 13, `micro` 11.
  - Sentence case; no monospace (tabular figures for time); Phosphor Regular 18–20 pt.
  - Targets 32 pt (28 pt minimum).
  - Spacing on the 4/8 grid (16 pt panel padding).
  - Panels separated by 1 pt hairlines on the canvas tone, no boxes.
- **Sizes**:
  - At 1280 × 800 every label above fits in full.
  - At 1470 × 882 the viewer and toolbar labels get the extra room.
  - Under ~1180 pt the media panel collapses on its own, then the inspector.

## Building it (after approval)

- Files: `mac/Muse/Views/Edit/**` and `mac/Muse/App/Edit/**` (WS3 hands them over once their crash fix and click-through
  ship; agreed 2026-11-08). Layout containers and sizing only; behaviour stays.
- Keep for WS3's click-through (`SnapshotRunner+Edit.swift`):
  - the accessibility label **"Timeline ruler"**;
  - a label on every control;
  - these labels unchanged: "Import", ".cube import", "Import music", "Import sound", "Record a voice-over", "Stop recording
    the voice-over", "Record VO", "Back", "Close editor", "Translate…";
  - the sheet close labels "Close", "Cancel", "Use the latest", "Keep this device's changes", "Done";
  - buttons or segmented controls rather than menus;
  - the inspector expanded by default, its toggle labelled "Show inspector" / "Hide inspector".
- Verify with the review mode's `editaudit` shots at the three sizes, all four themes, and the scroll and fit checks.
