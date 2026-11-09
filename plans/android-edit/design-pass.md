# Android Edit · design-pass proposals (WS8, 2026-11-09)

**Owner approved 2026-11-09:** all three, as written. The Mac matches: a file picker for photos, and output-device latency for recording.

Three parity rows change what a screen looks like, so they wait for the owner. Each proposal reuses the existing Edit
design language: suite buttons and chips, the preview, and the bottom sheet. None adds a new screen.

## 1. Chroma key colour picker (eyedropper)

- **Where:** Effects → Mask → Chroma key, beside the two colour swatches (green, blue), as a third control "Pick from video".
- **What the user taps:**
  1. Tapping it pauses the preview and dims the sheet.
  2. A crosshair loupe follows the finger on the picture, showing the colour under it at about 4× and its hex.
  3. Lifting the finger sets the key colour (`chroma.color`) and returns to the sheet, with the swatch now that colour.
- **Cancel and undo:** a second tap on "Pick from video", or the back gesture, cancels. One pick is one undo step.
- **What it samples:** the frame at the playhead, before the clip's look, the same pixels the key compares.

## 2. Overlay photos (pick an image from the phone)

- **Where:** Overlay panel, a second import button under "Add a video from a link": "Add a photo".
- **What the user taps:**
  1. It opens the system photo picker (images only; no storage permission needed).
  2. The photo uploads as an editor upload asset, a progress line in the button, then lands as an image item on an overlay track at the playhead.
- **How it lands:**
  - Size and place: 3 s long, contain-fitted at 40 % scale, centred, selected.
  - Sheet: the Transform sheet opens, so it can be placed, keyframed, blended or animated straight away; those controls already work for images.
- **Limits:**
  - PNGs keep their transparency.
  - Very large photos are scaled to 2048 px on the long side before upload.

## 3. Recording over playback (hear the video while recording a voice-over)

- **Where:** Audio panel, "Record VO".
- **What the user taps:**
  1. The first time, a one-line choice under the button: "Play the video while recording" (on by default when wired headphones or Bluetooth are connected, off on the speaker so the mic doesn't pick it up).
  2. While recording, the preview plays from the playhead with the edit's sound in the headphones, and the timeline shows a red recording bar growing on the voice lane.
  3. "Stop recording" ends both. The take lands where recording started, as today.
- **Bluetooth delay:** latency is measured once per route (AudioManager output latency) and the take is shifted by it, so lip-sync holds.
- **Nothing changes in the edit format.**
