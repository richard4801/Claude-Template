# Video editor (spec)

_Owner decision 2026-11-05._ A CapCut-style basic editor inside the apps. **v1 = Trim + Split + Speed + Mute.** Everything is done **on the device** (Android: Media3 ExoPlayer for the preview, Media3 Transformer for the export; Mac: AVFoundation). The server never encodes: it stores the file the device uploads and records the edit. It's free (no price, no hold, no ledger row). Members and owners get the same editor; nothing in it names an engine or model.

API: `plans/api.md` "Video editor: edited versions of a take".

## Where it opens
- Every **video** take (`kind: "take"`, or an edited version `kind: "edit"`): Result screen and Gallery → **Edit**.
- Opening an edited version re-opens its **edit list** on its **source** (the take named by `parentTakeId`), so earlier cuts can be changed or undone. If the source take was deleted, the version's own video is opened as a new source with a fresh edit list.
- Photos (`kind: "shot"`) have no Edit.

## The screen
```
┌──────────────────────────────────────────┐
│ ←  Edit video           ↶  ↷   Reset     │
│                                          │
│            [ live preview ]              │   plays the edit: kept segments in order, each at its speed, muted as set
│                                          │
│   ▶   0:03.40 / 0:08.25                  │   playhead time / output length (source times under the strip)
│ ┌[▓▓▓▓▓▓|▓▓▓▓▓▓▓▓▓|▓▓▓▓]┐                │   frame thumbnails; ┌ ┐ trim handles; | split marks; selected segment outlined
│ └──────────────▲─────────┘                │   ▲ playhead (drag or tap to seek)
│  In 0:00.50   Out 0:09.80   Kept 0:08.25 │
│                                          │
│ [Split] [Delete] [Speed 1×] [Mute ○]     │   Delete/Speed act on the selected segment (or all when "Whole video")
│ Speed: 0.5× 0.75× 1× 1.25× 1.5× 2×        │
│                                [Export]  │
└──────────────────────────────────────────┘
```
- **Trim:** drag the start/end handles; times are shown to 1/100 s and the handles snap to frames (1/fps). Trim is the first segment's `inSec` and the last segment's `outSec`.
- **Split:** splits the segment under the playhead at the playhead (both halves keep that segment's speed and mute). Not allowed within 0.1 s of a segment edge.
- **Delete:** removes the selected segment (cuts out a middle part). The last remaining segment can't be deleted.
- **Speed:** 0.5× / 0.75× / 1× / 1.25× / 1.5× / 2× for the selected segment, or for every segment with "Whole video".
- **Mute:** whole video on/off; also per segment (the segment's own switch) — a segment is silent when the whole video or that segment is muted.
- **Undo / Redo** (every change, up to 100 steps), **Reset** (back to the untouched source, itself undoable).
- **Preview** plays exactly what will be exported (deleted parts are skipped, speeds and mutes applied).
- **Export:** encodes on the device, shows progress (0–100 %) with **Cancel**, then uploads (progress) and saves a **new version** in the Gallery marked **"Edited"**, linked to the original. The original is never changed.

## Export (device)
- H.264 video + AAC audio in MP4. **Same resolution and frame rate as the source** (2K / 1440×2560 must work on a typical phone). If the phone's encoder can't do the size, the encoder falls back to the nearest size it can (Media3 encoder fallback), and the real size is what's sent as `width`/`height`.
- **Speed:** video timestamps are rescaled; faster parts drop frames back to the source frame rate (Media3 `FrameDropEffect`), slower parts show each source frame longer (no frames are invented), so the file never exceeds the source fps; audio is time-stretched with **pitch preserved** (Android: `EditedMediaItem.Builder.setSpeed(SpeedParameters(provider, shouldMaintainPitch = true))`, Sonic; the preview uses ExoPlayer `PlaybackParameters(speed, pitch = 1)`). Nothing is muted because of speed.
- **Mute:** a muted segment gets silence (the output keeps one audio track); with the whole video muted the output has no audio track. A source with no sound gives an output with no sound.
- Thumbnail: a JPEG frame of the output (≤ 720 px on the long side) made on the device and uploaded with it.
- Nothing is encoded on the server. If a client sends no thumbnail the server may grab a single frame (ffmpeg, no re-encode of the video); otherwise the version shows the source's thumbnail.

## Edit list (stored with the version)
```ts
EditSpeed  0.5 | 0.75 | 1 | 1.25 | 1.5 | 2
EditSegment { inSec: number, outSec: number, speed: EditSpeed, muted?: boolean }   // source seconds
EditList   { version: 1,
             sourceTakeId: string,                // the take whose video the segments cut (= the version's parentTakeId)
             sourceDurationSec: number,           // that video's length
             segments: EditSegment[],             // played in this order
             mute: boolean }                      // whole video silent
```
Rules (the server rejects anything else with `bad_request`):
- `version` = 1; `sourceTakeId` = the `{id}` in the URL.
- 1–**50** segments, in source order, not overlapping: `0 ≤ inSec < outSec ≤ sourceDurationSec (+0.05 s)`, `segments[i].inSec ≥ segments[i-1].outSec`.
- Each segment at least **0.1 s** of source; `speed` one of the six values.
- Output length = Σ (`outSec − inSec`) / `speed`, between **0.5 s** and **600 s**. The uploaded file's `durationSec` must be within max(0.5 s, 5 %) of it.
- The JSON is at most 16 KB.

Examples: a plain trim is one segment `{inSec: 0.5, outSec: 9.8, speed: 1}`; cutting out 3–4 s is `[{0,3,1},{4,10,1}]`; slow-motion middle is `[{0,2,1},{2,4,0.5},{4,10,1}]` (output 2 + 4 + 6 = 12 s).

## Limits (v1)
- Source: any finished video take (they are ≤ 15 s today; the editor itself takes up to 10 min).
- Output ≤ 600 s, ≤ 4096 px on a side, ≤ 2 GB (the presigned upload's limit).
- One export at a time per device; cancelling deletes the half-made file.

## Not in v1
Reorder, crop, text, music, filters, transitions, per-segment volume levels, keyframes. The edit list has a `version` so these can be added later.
