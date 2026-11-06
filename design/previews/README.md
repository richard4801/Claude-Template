# Composer previews (Blender, free)

Preview loops and stills for the video composer's pickers (`plans/video-composer.md` "Assets needed"). There is one studio set and one grey mannequin; only the camera (moves, angles) or the lights (lighting) change.

- `moves/<id>.mp4` + `moves/<id>.jpg`: all 40 moves in `server/api/src/suite/camera.ts` `MOVES`.
  - 2.5 s (60 frames at 24 fps), 320×400.
  - H.264 under 300 KB, re-encoded at a lower bitrate until it fits.
  - The poster is frame 36.
- `lighting/<id>.jpg`: 640×400, one per `LIGHTING` option plus `auto`.
- `angles/<id>.jpg`: 320×400, one per `HEIGHTS` and `SHOT_SIZES` option.
- `manifest.tsv`: `id file poster seconds bytes`. The id is `<kind>/<option id>`.
- `source/render_previews.py` builds the set procedurally, saves it as `source/muse_preview_set.blend`, and renders everything with Cycles on the CPU. No GPU and no paid APIs.

## Render
Blender 4.2 LTS (download.blender.org), headless:
```bash
blender -b --factory-startup --python design/previews/source/render_previews.py
blender -b --factory-startup --python design/previews/source/render_previews.py -- --only moves --ids dolly_in,orbit_360 --samples 16
```
- About 2,400 frames for the moves plus 38 stills.
- At 24 samples, 320×400, expect roughly 20–40 min on a cloud CPU.
- `--only` and `--ids` re-render part of the set; the manifest keeps the other rows.

## Look
- **Moves and angles:** the default "moody" rig: a dark studio sweep, a soft warm key from front-left, a cool rim, and a warm pool on the wall. It is meant to sit with `design/hardware/*.webp`.
- **Lighting:** each option replaces the rig.
- **Status:** not rendered yet. Tune the light energies after the first look at the output.
