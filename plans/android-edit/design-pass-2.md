# Android Edit · design-pass 2 proposals (WS8, 2026-11-09)

**Owner approved 2026-11-09:** proposals 1–7, as written. Order: effects library, cut to the music, pen mask, save as template, find shorts, brush refine (after the server's image cut-out), upscale in Export. Proposal 8 (teleprompter) was added afterwards and isn't approved yet.

Seven parity rows change what a screen looks like, so they wait for the owner. Each proposal uses the existing Edit
design language: suite buttons, chips, sliders, the preview and the bottom sheet. None adds a new top-level screen.
Prices are what members pay (the owner's markup is already in the server's estimate). Every paid helper shows its price
on the button and runs only on a tap. The Mac follows the same design with Mac controls (WS9).

## 1. Pen mask (custom shape)

- **Where:** Effects → Mask, a seventh shape chip "Pen" after Linear, Mirror, Circle, Rectangle, Heart and Star.
- **What the user taps:**
  1. Tap points on the picture to make a closed shape: up to 32 points, with a straight line between them. Tap the first point to close it.
  2. Drag a point to move it. Long-press a point to delete it. Drag along an edge to bend it (a quadratic curve).
- **Existing controls:** Feather, Invert, and the mask's x, y, size and rotation keyframes (◆) work on the pen shape as on the others.
- **Contract:** `Mask.shape = "pen"` with `points: [x, y, cx?, cy?][]` in the clip's frame.
- **Rendering:** the export and the Mac draw it as a path.
- **Cost:** none.

## 2. Brush to refine a cut-out

- **Where:** Effects → Remove background, after a cut-out has been made, a button "Refine edges".
- **What the user taps:**
  1. The preview pauses on the playhead frame with the cut-out shown over a checkerboard.
  2. Two brushes: "Keep" (paint back what was lost) and "Remove" (paint away what stayed), with a size slider. Undo works per stroke.
  3. "Done" re-runs the cut-out with the strokes as hints (the matte helper's keep/remove points, as with Tap to keep), so the fix follows the subject through the clip.
- **Cost:** the matte helper's price again, on the button ("Refine · $0.0x"); the same price as Tap to keep.

## 3. Auto-edit from clips and music

- **Where:** Edit panel, a button "Cut to the music", shown when there are two or more clips and a song on the music track.
- **What the user taps:**
  1. It finds the beats (the free beats helper) and makes a first cut.
  2. Clips are placed in order, each cut lands on a strong beat, and each clip is trimmed to its liveliest part (motion and faces found on the phone).
  3. The sheet shows "Pace: Relaxed / Normal / Fast", which changes how many beats each cut spans and re-cuts straight away.
- **Undo:** it's one undo step, and the original order is kept, so trying another pace is free.
- **Cost:** none (beats are free; the rest runs on the phone).

## 4. Long video to shorts

- **Where:** on a take over 60 s, the Edit panel offers "Find shorts".
- **What the user taps:**
  1. Pick 1–5 shorts and a length (15, 30 or 60 s).
  2. Claude reads the transcript (the captions job, if there isn't one yet) and picks the strongest self-contained moments. Each comes back as a card with its first line, its length and a one-line reason.
  3. "Make these" turns each chosen card into its own new edit (9:16, auto-reframed on faces, captions on). They open as drafts in the edit list.
- **Cost:** the transcript (the captions price per minute, as now) plus Claude's pick, shown together on the button before it runs, e.g. "Find shorts · $0.12" for a 10-minute video.

## 5. Video effects library (in-house shaders)

- **Where:** Effects, a new "Effects" row of chips with live thumbnails, like Looks. An effect sits on a clip (or on an adjustment layer for a stretch of the timeline) with one Amount slider, and some have a Speed slider.
- **Contract:** `effect: {id, amount, speed?}`, rendered as GL shaders on Android, Metal on the Mac, and ffmpeg filters on the server.
- **The first set (made in-house, no licences):**
  - Glitch (block shift + RGB split).
  - VHS (scanlines, chroma bleed, tracking wobble).
  - Retro film (grain, gate weave, dust).
  - Blur (gaussian).
  - Zoom blur.
  - Mirror (2- and 4-way).
  - Pixelate.
  - Posterise.
  - Duotone (two colours).
  - Shake.
  - Flash (a white pulse on the beat).
  - Rain on glass.
- **Rollout:** more effects can follow in content-pack updates without an app release, as long as they are built from these shader blocks.
- **Cost:** none.

## 6. Upscale in Edit

- **Where:** Export sheet, a "Sharper" row under Resolution: "Upscale to 1080p / 2K / 4K before export". It's offered only for sizes the server prices (`UPSCALE_PRICES`) and runs as the Suite's upscale on the finished edit.
- **What the user taps:**
  1. Pick the size; the button reads "Export · upscale $x.xx".
  2. The edit renders, then upscales, and the progress shows both steps.
- **Cost:** the Suite's upscale price per output second for the chosen size, times the edit's length. With the configured example of $0.05 per second at 1080p, a 30 s edit costs $1.50. The real figure comes from the server's estimate.

## 7. Save the whole edit as a template

- **Where:** the edit's ⋯ menu, "Save as template", next to Style kits.
- **What it keeps:** a template stores the whole timeline structure without the member's media: clip slots (their lengths, speeds, transitions, looks, effects), text with placeholder words, caption style, music (if from their files), and ratio.
- **Using it:** the Templates sheet on New edit lists them. Picking one asks for media for each slot in order ("Slot 1 · 2.4 s"), and auto-fit trims each pick to its slot. It's the same flow as Recreate's slot fill, so members already know it.
- **Sharing:** templates are shared within the studio.
- **Cost:** none.

## 8. Teleprompter / record in Edit

- **Where:** Overlay panel, "Record a clip" under "Add a photo". The camera itself stays the Suite's; this opens it from Edit and comes back.
- **What the user taps:**
  1. The front camera opens full screen with an optional script scrolling over the top third. The script comes from the edit's text, the captions, or typed in, and the user can change its speed and size.
  2. Recording is a big round button with a 3-2-1 count-in. The take shows a red timer while it records.
  3. "Use this take" uploads it and adds it at the playhead, as a main clip, or as an overlay when the user started from the Overlay panel. Retake throws it away.
- **Under the hood:** the script scrolls at a steady words-per-minute that the user sets (130 by default), and pauses when they tap the screen.
- **Cost:** none (the upload is ordinary storage).
