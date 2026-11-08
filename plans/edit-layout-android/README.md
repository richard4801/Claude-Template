# Edit layout on Android (WS4, 2026-11-08)

WS2's approved Mac layout (`plans/edit-layout.md`), ported to Android. The vocabulary was agreed with WS2.

## Tablet (720 dp and wider, portrait included): `EditTablet.kt`

- **Top bar (56 dp):**
  - On the left: Back, then the title (`heading`) over its status line.
  - In the centre: the shape as one segmented control (9:16 · 1:1 · 4:5 · 16:9).
  - On the right: Claude (owner), Hook ideas, "Show inspector" while it is hidden, and Export as the one primary.
- **Viewer:**
  - "Safe area" as one segmented control (Off · TikTok · Reels · Shorts).
  - The picture on the dark stage.
  - The transport under it: tabular time; Go to start, Play (40 dp, round) and Go to end; History (sessions); Fullscreen.
- **Inspector (368 dp):**
  - "Inspector", with "Hide inspector" beside it.
  - The six sections as a 3 × 2 grid of labelled buttons: Captions, Text, Video (looks, adjust), Audio, Speed, Animate (transitions, effects).
  - Then that section's settings, scrolling.
  - Other panels (clip tools, keyframes, export, history) show their own title and Done.
- **Timeline:**
  - A toolbar: Split, Delete, Speed, Keyframe, Crop (labelled at 1200 dp and wider, else the icon with the label read out), Undo / Redo, Ripple and Snap to beat as toggles, Add, and zoom.
  - Named track headers: Video, Captions, Music, Voice-over, Sound effects, Text, Overlay.
  - Taller lanes, a tabular "0:02" ruler, and no monospace.

## Phone

- One column as before: the title over its status line, tabular time, and tool labels at `micro` 11 in full words.
- The ruler and the timeline's chips no longer use monospace.

## Not on Android (vs the Mac mock): follow-ups, built only if the owner asks

- **No media bin.** Android has no library panel: takes and overlays come in through the timeline's Add.
- **No mute or visibility controls on the track headers.** The Android editor has no such actions yet; they come when it does.

## Images (left before, right after)

- `tablet_<theme>_before_after.png`: 1280 × 800.
- `tablet_portrait_<theme>_before_after.png`: 800 × 1280.
- `phone_<theme>_before_after.png`: 390.
- `tablet_c_captions_and_hidden_inspector.png`: the Captions section, and the inspector hidden.
