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

## Looks (filters, 2026-11-05 · owner-approved "CapCut-grade filters")
Every video/image item may carry **`look`** (additive to `filter`/`adjust`; projects stay `version: 2`, older apps ignore nothing because they never wrote it):
```ts
Look { lut?: string /* "pack:<id>" = a bundled look, or the id of an Asset of kind "lut" (an imported .cube upload) */,
       strength?: number /* 0–1, LUT blended with the picture, default 1 */,
       curves?: { rgb?, r?, g?, b?: [x, y][] /* 2–16 points, x rising, 0–1 */ },
       lift?: 0–1 /* faded blacks */, sharpen?: 0–1, chromatic?: 0–1 /* chromatic aberration */,
       halation?: { amount 0–1, radius? 0.05–1 (0.5), threshold? 0–0.99 (0.7) },
       leak?: { kind: "warm"|"rose"|"amber"|"teal"|"rainbow", amount 0–1, angle? −360…360 (30) },
       vignette?: { amount −1…1 /* < 0 lightens */, size? 0–1 (0.45), softness? 0–1 (0.5) },
       grain?: { amount 0–1, size? 0.5–3 (1) } }
Asset.kind gains "lut" (must be an `upload`; the server parses it when the project is saved).
```
**Pipeline** (reference `server/api/src/editor/look.ts` → `renderLook`; per item, sRGB 0–1, clamped after each step):
1 sharpen: v + 1.5·s·(v − box(v, r)), r = max(1, round(0.0015·short side)) · 2 chromatic: R sampled at p + 0.006·c·(p − centre)·size, B at p − …, bilinear · 3 the colour matrix (`colorMatrix(adjust, filter)`) · 4 curves: master then the channel's own, monotone cubic (Fritsch–Carlson), flat outside the end points · 5 LUT: trilinear, `v + (lut(v) − v)·strength` · 6 lift: b + v(1 − b), b = 0.12·lift · 7 halation: highlights of box(v, r = max(1, round(0.04·radius·short))) above `threshold`, tinted (1, 0.35, 0.2)·amount, screened · 8 leak: `leakColor(u, v, t)` screened (a soft blob from the edge at `angle`, drifting 0.25·sin(0.6t) rad) · 9 vignette: m = smoothstep(size, size + max(0.05, softness), r), r = 1 at the corners; amount > 0: v·(1 − a·m); < 0: v + |a|·m·(1 − v) · 10 grain: mono, n = hash01(⌊x/cell⌋, ⌊y/cell⌋, frame) − 0.5 (lowbias32 integer hash), cell = max(1, round(short/1080·size)), v += 0.18·amount·n·(1 − |2·luma − 1|/2).
`frame` (grain, and `t = frame / canvas.fps` for the leak) is the **timeline** frame number, round(timeline seconds × canvas fps), on both platforms. Box blurs are separable, clamp-to-edge. The **GPU** versions (Android GlEffects, Mac Core Image) implement the same formulas; grain on the GPU may use a float hash (it is noise either way), everything else should match the CPU renderer within a few 1/255. Kotlin and Swift carry a CPU port of `renderLook` (fixture-checked) for **filter thumbnails** on the current frame (downscaled, ~96 px) and for tests.
**Look pack:** 32 original looks in 8 groups (natural, film, moody, warm, cool, B&W, vintage, cinematic), each a parametric grade (`server/api/src/editor/lookpack.ts`: white balance, saturation and hue changes that **leave skin hues mostly alone**, S-curve, split-toning, highlight roll-off, fade, mono) baked by `npx tsx scripts/editor-looks.ts` into **17³ .cube** files + `looks.json` in `server/api/assets/lookpack/looks/` (single copy: the Android app adds that folder as an assets dir → `assets/looks/…`, the Mac app bundles it as the `looks` resource folder, the server reads it for photos). No third-party LUTs. Choosing a look sets `look = { lut: "pack:<id>", strength: 1, …its default effects }` (from `looks.json`); the user can change any part after.
**Import:** the user's own .cube (3D, size 2–64, ≤ 12 MB; `TITLE`, `DOMAIN_MIN/MAX`, `LUT_3D_INPUT_RANGE` and comments understood; 1D LUTs refused): presign with `purpose: "lut"`, PUT, `POST /v1/editor/luts/validate` → `{size, title}` or the bad line; then add an asset `{id, kind: "lut", upload}` and `look.lut = <that id>`. The apps parse the same way (`parseCube`).
**Fixtures:** `looks.json` (curves, LUT samples incl. a bundled cube, hash, vignette, leak, radii, bad/good cubes, and full renders of a 24×16 test picture for 10 looks); validation cases for `look` in `validation.json`.
**Photos:** the same look on stills, server-side (sharp raw pixels → `renderLook`): `filter: Look` on `POST /v1/shoots` (also replaces a template's own look for those stills) and `afterEffects.look` on templates. Photos use bundled looks only.

## Edit suite additions (phase 2 · designs E1–E4, EM1–EM5)
Engine features the approved designs need, added to the same contract (project stays `version: 2`; reference `model.ts`, `audio.ts`, `look.ts`; fixtures updated; Kotlin and Swift ports must match):
- **Speed** 0.1–10× (was 0.25–4). **Speed curves** `speedCurve?: { preset: "montage"|"hero"|"bullet"|"flashIn"|"flashOut"|"custom", points: [x 0–1 of the kept source, speed 0.1–10][] }` (2–16 points, x from 0 to 1, rising). Speed at x = smoothstep between points in log speed (`curveSpeed`). Rendering and timing use **48 equal source pieces**, each at the curve's speed at its middle (`speedPieces`): engines render those pieces as constant-speed sub-clips (pitch kept). `clipLength`, `clipTimeAt` (captions, cuts) go through them; `applyCuts`/split keep the curve on each piece (`subCurve`, preset becomes custom). Presets: `SPEED_PRESETS`. The **"Smooth slow-mo" (AI, frame interpolation)** switch in EM4 is **not built yet** (no model chosen): it is **not shown** until it is built (owner, 2026-11-08: no placeholders; being priced as an XL item).
- **Transitions** add `whip` (cubic push with motion `blur`), `spin` (rotate 180° and scale through a hard switch at the middle), `glitch` (hard switch with jitter and `rgbSplit`). `LayerState` gains `rotation` (deg, clockwise), `blur` (0–1 → up to 4 % of the canvas along the move), `rgbSplit` (0–1 → R/B offset up to 2 %). UI names (`TRANSITION_LABELS`): Cut (none), X-fade = fade, Zoom, Whip, Slide = slideLeft, Flash = white, Glitch, Spin (+ Dip to black).
- **Masks** on video/image items: `mask?: { shape: "linear"|"mirror"|"circle"|"rect"|"heart"|"star", x?, y? (centre, item fractions, 0.5), width?, height? (0.5), rotation? (deg), feather? 0–1 (0.1), invert? }`, opacity `maskAlpha(mask, u, v)` multiplied into the item's alpha (after chroma key).
- **Adjust** gains `highlights`, `shadows` (−1…1): `toneAdjust` after the colour matrix, before the look's curves (bake it into the colour LUT with the rest). "Grain" in the Adjust panel edits `look.grain.amount`.
- **Captions** add presets `highlighter` (marker stripe behind the active word) and `neon` (glow); UI names (`CAPTION_STYLE_LABELS`): Word pop = pop, Karaoke, Bold box = box, Minimal = plain, Highlighter, Neon.
- **Ducking** gains `attackSec` (0.05–2) and `releaseSec` (0.05–3) (else `fadeSec` for both); "−12 dB" in the UI = `level` 10^(dB/20).
- **Voice**: `voiceEffect?: "none"|"warm"|"radio"|"phone"|"deep"`, `enhance?: boolean` on clips with sound → biquad chains (`voiceChain(clip, sampleRate)`, RBJ cookbook, fixture coefficients + impulse responses): Android an `AudioProcessor`, Mac an audio processing tap. **Noise reduction** = the `denoise` AI job (its voice stem becomes the clip's `audioAsset`).
- **Beats**: `beats`/`strongBeats` (source seconds) on music clips, from the free `beats` job (`detectBeats`, server ffmpeg decode, BPM). "Every beat / strong beats" chooses which marks show and snap; "Snap cuts to beats" snaps split/trim to the nearest mark.
- **Export**: shape 9:16 / 1:1 / 4:5 / 16:9 (canvas; re-framing keeps faces in view — Android ML Kit face detection / Mac Vision to set each clip's transform), 720p/1080p/4K, 24/30/60 fps, MP4 H.264 or HEVC, captions **burn in** or **.SRT** (`toSrt(project)`), and the **Disclosure** switch "Label as AI-generated" — **off by default**, per export (owner rule). "Content Credentials (C2PA)" joins it, also off by default, once signing is built; until then it is **not shown** (owner, 2026-11-08: no placeholders; the certificate is being priced as an XL item).

## Edit sessions and edit ops (Claude in the Edit suite, 2026-11-06)
_Spec: `plans/claude-editing.md` A. API: `plans/api.md` "Edit sessions". Reference: `server/api/src/editor/{sessions,ops,jsonpatch,mcpTools,frame}.ts`._
- An **edit session** is the live, revisioned copy of a take's EditProject v2 that the owner's apps and Claude share (owner only). Every change is stored as a **JSON Patch** (`jsonpatch.ts`: add/remove/replace; `diff` sorts object keys and replaces arrays whose length changed — fixture `jsonpatch.json`, the apps' ports must produce the same patches) together with its inverse, so every change is undoable by anyone.
- **Apps**: open the session for the take they edit (`POST /v1/edit-sessions`), send each local change (debounced ~0.5 s) as `{baseRevision, patch, label}`; on `409 stale_revision` fetch the session, re-diff the local state against it and resend (last writer wins per change). Remote changes arrive as `edit` events `{op: "patch", revision, baseRevision, patch, entry}` and are applied when `baseRevision` = the app's revision (else re-fetch). History entries carry `author` (`app:<device>` or `claude`) — Claude's show a **"Claude" badge** in the undo list; undoing any entry = `POST …/undo {entryId}`. Apps announce themselves (`…/presence` every 30 s, `canRender: true` when they can render frames), render frames Claude asks for (`op: "frame_request"` → upload a PNG of the exact frame, `POST …/frames/{requestId} {uploadId}`), handle `op: "app_request"` (`save` = render + save a version as today; `export` = the export sheet with the preset, the owner's AI-label/C2PA switches untouched) and answer paid helpers waiting for the owner (`op: "pending"` → a confirmation sheet with the estimate → `POST …/pending/{id} {approve}`).
- **Edit ops** (what Claude sends with `apply_edit_ops`; one call = one undoable change; the result must pass `validate`): `trim {clipId, inSec?, outSec?}` (source seconds) · `split {at}` (timeline seconds) · `delete {itemId, ripple?}` · `move {itemId, index}` (main clips) / `{itemId, startSec}` (others) · `speed {clipId, speed? , curve?: preset|{points}|null}` · `add_text {text, startSec?, durationSec?, template?, style?, transform?}` · `add_hook {template, text?, startSec?}` · `edit_text {itemId, text?, startSec?, durationSec?, style?, transform?}` · `caption_style {preset?, …style}` · `look {itemId|"all", look?: id|null, lut?, strength?, …effects}` · `adjust {itemId|"all", exposure?, contrast?, saturation?, temperature?, highlights?, shadows?}` · `transition {clipId|"all", kind|"cut", durationSec?}` · `mask {itemId, mask|null}` · `transform {itemId, transform}` · `keyframe {itemId, prop, t, v, ease?}` · `remove_keyframe {itemId, prop, t}` · `volume {itemId, volume?, fadeInSec?, fadeOutSec?, muted?}` · `duck {trackId?, enabled?, levelDb?, attackSec?, releaseSec?, under?}` · `voice {itemId, effect?, enhance?}` · `add_music {asset: {upload|take, durationSec}, startSec?, inSec?, outSec?}` (no music library yet: `library` is refused, 2026-11-08) · `ratio {ratio: "9:16"|"1:1"|"4:5"|"16:9"}` · `patch {patch}` (a raw JSON Patch, validated like the rest).
- **Claude's tools** (MCP, owner tokens / OAuth `edit:read`, `edit:write`): `list_takes`, `open_edit`, `get_edit`, `apply_edit_ops`, `undo_edit`, `list_looks`, `list_caption_styles`, `auto_captions`, `cut_silences` (free), `cut_fillers`, `remove_background`, `detect_beats` (free), `find_action_peaks` (free, read-only), `denoise`, `get_frame` (exact from an online app, else an approximate server render flagged `approximate: true`), `get_contact_sheet`, `save_version`, `export_video`. Paid helpers return an estimate, then with `confirm: true` wait for the owner's yes in the app; results are applied to the session as Claude's change when the job finishes. **Guardrails:** no posting, no deleting takes, no spend without the owner, ≤ 120 changes a minute, every call logged in the session history, every change undoable.
- A suite take graded with a look (`take.look`) opens with `look: {lut, strength: 1}` on its main clip.

## Phase 1 limitations (agreed 2026-11-05)
- **Android** draws text, hooks and captions above every PiP/image layer, whatever the track order (they are composition-wide overlays).
- **Mac** plays volumes above 1× at 1× (`AVAudioMix` is 0–1; a boost needs an audio tap). Android applies up to 2× (clamped, no wrap).
- **Fonts** use system fallbacks until the Figma "Edit Suite" designs fix the families.
- Server AI helpers run on the mock until the owner tries the editor UI: `EDITOR_AI_PROVIDER` defaults to `mock` (free in production); set `auto` or `replicate` on Railway to turn the real helpers on.

## Not in phase 1
Speed curves, freeze frame, reverse, masks/blend modes, motion tracking, stabilization, reframe, LUT files (`.cube`), beat detection, TTS, stickers library, Lottie. The schema leaves room (`version`, unknown kinds rejected until added).
