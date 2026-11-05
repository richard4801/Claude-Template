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

---

# Editor v2 (engine contract)

_Workstream 3, 2026-11-05. Phase 1 = the research's must-have tier (`plans/research/ai-video-suite-research.md` §1.2, roadmap E1–E3 + the cut list of E4). **Engines, data model and AI helpers only**; the screens wait for the owner's review of the Figma "Edit Suite" pages._ API: `plans/api.md` "Editor v2".

Everything still renders **on the device** (Android: Media3 Transformer `Composition`; Mac: `AVMutableComposition` + `AVVideoComposition` + `AVAudioMix`). The server validates and stores the project with the version, and runs the paid AI helpers (captions, silence/filler cuts, background removal, voice clean-up) as jobs whose results the **client** applies to the project. The server never encodes video.

**Reference implementation:** `server/api/src/editor/model.ts` (TypeScript). The Kotlin (`android/core/.../core/edit/`) and Swift (`mac/MuseCore/Sources/MuseCore/Edit/`) ports must give the same answers: every case in the shared fixtures `server/api/test/fixtures/editor/*.json` (copied byte-for-byte to `android/core/src/test/resources/editor/` and `mac/MuseCore/Tests/MuseCoreTests/Fixtures/editor/`; a server test fails if the copies drift) is checked by all three test suites. Regenerate with `npx tsx scripts/editor-fixtures.ts` in `server/api`.

## Backwards compatibility
- A v1 edit list (`version: 1`) stays valid everywhere and is still saved as before.
- `fromV1(v1, {width, height, fps, hasAudio})` turns it into a v2 project: one main track, one clip per v1 segment (same `inSec`/`outSec`/`speed`; a muted segment → `muted: true`), the v1 `mute` → project `mute`. Clients open old versions through it; saving always writes v2 once a v2-only feature is used (a v2 project that only uses v1 features may be saved as v1 with `toV1`, which returns null otherwise).

## Time model
- **Timeline seconds** (output time) start at 0. **Source seconds** are times inside an asset's file.
- **Main track**: clips play back to back. A clip's timeline length is `(outSec − inSec) / speed`. Clip *i* starts where clip *i−1* ends, **minus** clip *i*'s `transitionIn.durationSec` (transitions overlap the two clips). The project's duration = the end of the last main clip.
- **Other tracks**: every item has `startSec` (timeline) and its own length (video/audio: `(outSec−inSec)/speed`; image/text: `durationSec`). Items on one track never overlap (sorted by `startSec`); use more tracks to stack. Anything past the project's end is cut off. Later tracks draw on top of earlier tracks; the main track is always the bottom layer.
- Keyframe `t` is seconds from the item's own start on the timeline.

## Canvas and transforms
- `canvas { width, height, fps, background }` = the export size and frame rate (default: the main source's; 16–4096 px, 1–120 fps; `background` "#RRGGBB", default black).
- **Fit**: a video/image item (after its crop) is first fitted to the canvas keeping its aspect: `fit: "cover"` (fills the canvas, edges cut; default on the main track) or `"contain"` (whole picture visible; default elsewhere). That fitted size is scale 1.
- `transform { x, y, scale, rotation }`: `x`,`y` = the item's **centre** in canvas fractions (0,0 top-left; 1,1 bottom-right; default 0.5, 0.5), `scale` (0.05–10, default 1), `rotation` degrees clockwise (−3600…3600). Text items use the same transform (scale multiplies the font size).
- `crop { left, top, right, bottom }`: fractions of the source cut from each side (each 0–0.45).
- `opacity` 0–1 (default 1).

## Keyframes
`keyframes?: { x?, y?, scale?, rotation?, opacity?, volume? : Keyframe[] }`, `Keyframe { t, v, ease? }`, sorted by `t`, ≤ 100 per property, `t` within the item. A keyframed property replaces the static value. Before the first key → its value; after the last → the last value. Between key *k* and *k+1* the progress `p = (t−tₖ)/(tₖ₊₁−tₖ)` goes through key *k*'s `ease`:
`linear` p · `easeIn` p² · `easeOut` 1−(1−p)² · `easeInOut` p<0.5 ? 2p² : 1−(−2p+2)²/2 · `hold` 0 (jump at the next key). `volume` keyframes multiply the clip's volume (0–2).

## Tracks and items
```ts
EditProject { version: 2, sourceTakeId, canvas, assets: Asset[], tracks: Track[], mute?: boolean }
Asset   { id, kind: "video"|"image"|"audio", take?: string /* takeId */, upload?: string /* uploadId */, library?: string /* bundled key */,
          durationSec?, width?, height?, hasAudio?, url?: string /* a hint, never trusted */ }      // exactly one of take/upload/library
Track   { id, kind: "main"|"video"|"image"|"text"|"caption"|"music"|"voice"|"sfx", name?, muted?, hidden?, volume? /* 0–2 */,
          items: Item[], caption?: CaptionTrack /* kind "caption" */, duck?: Duck /* kind "music" */ }
```
Exactly one `main` track (first). `video` = overlay/PiP video, `image` = pictures/stickers, `text` = text and hooks, `caption` = auto-captions (no items, see below), `music`/`voice`/`sfx` = audio.

```ts
VideoClip  { id, asset, inSec, outSec, speed /* 0.25–4 */, startSec? /* not on main */, volume? /* 0–2, default 1 */, muted?,
             fadeInSec?, fadeOutSec? /* audio, 0–10 */, audioAsset? /* use this asset's sound (e.g. a cleaned voice) at the same source times */,
             fit?, transform?, crop?, opacity?, keyframes?, filter?: { id, amount /* 0–1 */ }, adjust?: Adjust,
             chroma?: { color, similarity /* 0–1, .4 */, smoothness /* 0–1, .08 */, spill /* 0–1, .5 */ },
             transitionIn?: { kind: TransitionKind, durationSec /* 0.1–2 */ } /* main track, clip ≥ 2 */ }
ImageItem  { id, asset, startSec, durationSec, fit?, transform?, crop?, opacity?, keyframes?, filter?, adjust?, animIn?, animOut? }
TextItem   { id, startSec, durationSec, text /* 1–500 chars, \n = new line */, style: TextStyle, transform?, opacity?, keyframes?, animIn?, animOut?, template? }
AudioClip  { id, asset, startSec, inSec, outSec, speed? /* 1 */, volume?, muted?, fadeInSec?, fadeOutSec?, keyframes? /* volume only */, beats?: number[] /* source s */ }
Anim       { kind: "none"|"fade"|"pop"|"slideUp"|"slideDown"|"zoom"|"typewriter", durationSec /* 0.1–2 */ }   // typewriter: text only
Adjust     { exposure?, contrast?, saturation?, temperature? }   // each −1…1, 0 = unchanged
```
- `speed` curves are not in phase 1 (constant speed per clip, pitch preserved, frames dropped back to the canvas fps when faster, as v1).
- `muted` / track `muted` / project `mute` silence a clip; `hidden` tracks don't draw.

## Look: filters and adjust → one colour matrix
All colour work is **one affine 3×4 RGB matrix** per item (so both platforms match exactly): `colorMatrix(adjust, filter)` in the reference. Built in this order on sRGB values 0–1, then clamped:
1. exposure e: × 2^e · 2. temperature k: R × (1+0.1k), B × (1−0.1k) · 3. contrast c: (v−0.5)(1+c)+0.5 · 4. saturation s: luma (Rec.709 0.2126/0.7152/0.0722) + (v−luma)(1+s) · 5. a filter's `tint { color, strength }`: v·(1−strength·a) + color·strength·a.
A filter preset (`filters.json`) is an `Adjust` (+ optional `tint`); with `amount` a it adds a × the preset's values to the item's own adjust (each clamped to ±1). Android: a custom `RgbMatrix`-style GL effect (the matrix has an offset column); Mac: `CIColorMatrix` (+ bias).
**Chroma key** (green screen and background-removal results), `chromaKey(r, g, b, chroma)` in the reference (fixture `functions.json` → `chroma`): d = distance between the pixel's and the key's (Cb, Cr) (BT.601); base = d − similarity; alpha = clamp(base / smoothness, 0, 1)^1.5; spill s = clamp(base / spill, 0, 1)^1.5 and colour = luma + (colour − luma)·s (Rec.709 luma), so edge pixels lose the key's tint. Platform: Android GL shader (`ChromaKeyEffect`), Mac a 32³ `CIColorCube` built from the same function.

## Transitions (main track)
`TransitionKind` = `fade` (cross-dissolve), `black` (dip to black), `white` (flash), `slideLeft`, `slideRight`, `slideUp`, `slideDown` (push), `zoom`. The two clips overlap for `durationSec` (≤ half of each clip's timeline length). At progress p (0→1, linear in time; `e` = easeInOut(p)):
| kind | outgoing A | incoming B (drawn on top) |
|---|---|---|
| fade | — | opacity p |
| black / white | opacity max(0, 1−2p) over the colour | opacity max(0, 2p−1) |
| slideLeft | dx −e | dx 1−e |
| slideRight | dx e | dx −(1−e) |
| slideUp | dy −e | dy 1−e |
| slideDown | dy e | dy −(1−e) |
| zoom | scale 1+0.25e, opacity 1−p | opacity p |
(dx, dy in canvas widths/heights.) Sound crossfades linearly over the overlap. `transitionState(kind, p)` in the reference returns these numbers.
**Android:** Media3's `Composition` can't crossfade inside one sequence, so the main track is laid out as **A/B roll**: clips alternate between two video sequences padded with gaps (`addGap`), and a `VideoCompositorSettings` whose `getOverlaySettings(inputId, timeUs)` animates alpha/position per frame does the transition. **Mac:** two alternating composition tracks with `AVMutableVideoCompositionLayerInstruction` opacity/transform ramps (or the custom compositor).

## Audio
- Gain of a clip at timeline t = track volume × clip volume × volume keyframe × fade-in/out ramps (linear over `fadeInSec`/`fadeOutSec`) × transition crossfade × **ducking**, 0 when muted.
- **Ducking** (`Duck { level /* 0.05–1, default 0.3 = gain while ducked */, fadeSec /* 0.05–2, .25 */, under: ("voice"|"speech")[] }` on a music track): music drops to `level` while anything in `under` is heard — `voice` = the voice-track items, `speech` = caption words on the timeline (word ranges joined across gaps < 0.4 s). Ramps start `fadeSec` before a region and end `fadeSec` after it.
- `audioEnvelope(project, trackId, itemId)` returns the clip's gain as piecewise-linear points over the timeline (Mac: `setVolumeRamp` between points; Android: an `AudioProcessor` that applies the envelope by presentation time). Fixture-checked.
- `beats` = beat marks on a music clip (source seconds), for snapping; detection is not in phase 1.

## Text, hooks and captions
- `TextStyle { font: "sans"|"serif"|"rounded"|"condensed"|"mono"|"marker", weight: 400|700|900, sizePct /* of canvas height, 0.015–0.25 */, color, align: "left"|"center"|"right", maxWidthPct /* 0.1–1, default 0.85 */, lineHeight /* 0.8–2, 1.15 */, letterSpacing? /* em, −0.1–0.5 */, uppercase?, stroke?: { color, widthPct /* of font size, 0–0.3 */ }, shadow?: { color, opacity, blurPct, dyPct }, background?: { color, opacity, paddingPct, radiusPct } }`. Fonts are bundled per platform (same family names, platform files).
- **Hook templates** (`hooks.json`): 10 ready text items (style + position + animations + placeholder text); choosing one copies its style into the item (`template` records the id).
- **Animations** `animIn`/`animOut` over their `durationSec` (p 0→1, e = easeOut): fade = opacity p; pop = scale 0.6→1.08 (at 70 %)→1 and opacity; slideUp/slideDown = y offset ∓0.05 → 0 and opacity; zoom = scale 1.3→1 and opacity; typewriter = the first ⌈p·n⌉ characters. Out = the same reversed. `animState(item, t)` in the reference.
- **Captions** (`track.kind = "caption"`): `CaptionTrack { asset, words: { text, startSec, endSec }[] /* SOURCE seconds of asset, ≤ 3000 */, style: CaptionStyle }`. Words are anchored to the source, so trimming/splitting/cutting the main track moves them: `captionWords(project)` maps each word through every main clip that uses `asset` (the word's midpoint must be inside the clip's kept part) to timeline times; words in cut parts disappear.
- `CaptionStyle = TextStyle fields + { preset: "plain"|"highlight"|"box"|"karaoke"|"pop"|"single", highlightColor, y /* centre, 0–1, default 0.72 */, wordsPerPage /* 1–8, 3 */, maxLines /* 1–2 */ }`.
- **Pages**: `captionPages(project)` groups timeline words: a new page when the page has `wordsPerPage` words (1 for `single`), when the gap to the next word > 0.6 s, or after a word ending in `.`, `!` or `?`. A page shows from its first word's start until the next page starts or its last word ends + 0.4 s, whichever is first. **Active word** at t = the last word in the page whose start ≤ t.
- Presets: `plain` (no highlight) · `highlight` (active word in highlightColor) · `box` (a rounded highlightColor box behind the active word) · `karaoke` (words up to the active one in highlightColor) · `pop` (active word highlightColor and scale 1.15) · `single` (one word per page, pop-in). `presets.json` gives each preset's default style.

## Editing helpers (pure, in all three languages)
`timeline(project)` (each main clip's timeline start/end, overlaps) · `durationSec` · `fromV1`/`toV1` · `applyCuts(project, assetId, cuts[{startSec,endSec}])` (removes those **source** ranges from every main clip of that asset: splits clips, drops pieces shorter than 0.1 s, keeps speeds/looks; transitions on removed edges become cuts) · `captionWords`/`captionPages` · `keyframeValue` · `transitionState` · `animState` · `colorMatrix` · `audioEnvelope` · `validate` (the rules below; returns the first problem with its field path).

## Rules (server rejects anything else with `bad_request` naming the field)
- JSON ≤ **256 KB**; `version` 2; `sourceTakeId` = the take in the URL; ids unique (≤ 64 chars).
- ≤ 16 tracks, ≤ 300 items per track, ≤ 600 items in all, ≤ 60 assets, ≤ 3000 caption words, one `main` track first with ≥ 1 clip; the main track's assets are `video`.
- Every item's `asset` exists in `assets` and has a suitable kind (video on main/video tracks, image on image tracks, audio **or video** on audio tracks).
- Clips: `0 ≤ inSec < outSec`, ≥ 0.1 s of source, `outSec ≤ asset.durationSec + 0.05` when the duration is known; speed 0.25–4; items on a non-main track sorted and not overlapping (0.001 s slack); ≥ 0.05 s long; transitions only on main clips after the first, ≤ half of both clips.
- Duration (main track) 0.5–600 s. Canvas 16–4096 px, fps 1–120. Colours `#RRGGBB`. Numbers in the ranges above.
- Saving a version also checks every `take` asset is a video/photo take of the studio and every `upload` asset is this studio's upload (`not_found`).

## Export
Same as v1: H.264 + AAC MP4 at the canvas size and fps (2K must work; Media3 encoder fallback may lower the size, the real size is sent). Progress 0–100 % with Cancel; the half-made file is deleted. Nothing is encoded on the server.

## Phase 1 limitations (agreed 2026-11-05)
- **Android** draws text, hooks and captions above every PiP/image layer, whatever the track order (they are composition-wide overlays).
- **Mac** plays volumes above 1× at 1× (`AVAudioMix` is 0–1; a boost needs an audio tap). Android applies up to 2× (clamped, no wrap).
- **Fonts** use system fallbacks until the Figma "Edit Suite" designs fix the families.
- Server AI helpers run on the mock until the owner tries the editor UI: `EDITOR_AI_PROVIDER` defaults to `mock` (free in production); set `auto` or `replicate` on Railway to turn the real helpers on.

## Not in phase 1
Speed curves, freeze frame, reverse, masks/blend modes, motion tracking, stabilization, reframe, LUT files (`.cube`), beat detection, TTS, stickers library, Lottie. The schema leaves room (`version`, unknown kinds rejected until added).
