# Edit parity: MUSE vs the leading mobile editors

_WS8, 2026-11-08. **For the owner to prioritise. Nothing in this document gets built until the owner has chosen.**_ New screens here also need design approval.

## Scope

- **Reference app:** CapCut, as the owner asked.
- **Also compared:** VN Video Editor, InShot, Adobe Premiere on iPhone (which replaced Rush in 2025) and Instagram Edits.
- **Sources:** public only: App Store listings, official help and feature pages, and reviews. Full inventory with links: the "Sources" section at the end. Where a source is thin, the row says so.
- **Rule:** MUSE rebuilds *functionality* in its own design. It never copies another product's assets, names or look.

## How to read this

**Android** is Android Edit after WS8's fixes (`plans/android-edit-audit.md`). **Mac** is the Mac Edit suite after WS9's fixes (`plans/mac-edit-audit.md`, 2026-11-08; Mac notes start with "Mac:"). Both use the same engine contract.

- **Has:** working end to end (project → preview → export).
- **Partial:** the engine or a basic version exists; something named is missing.
- **Missing:** not there.

**Size** is the build effort for Android, assuming the shared engine (`core/edit`, server `model.ts`) is extended where needed:

| Size | Effort | What it usually means |
|---|---|---|
| S | ≤ 1 day | UI on an engine that already exists |
| M | 2–4 days | a new action plus the engine, fixtures and the Mac port |
| L | 1–2 weeks | a new engine capability |
| XL | > 2 weeks, or needs a model or vendor decision | |

**Content** marks a feature whose value is a licensed or curated library (music, sound effects, stickers, fonts, effect/filter/template packs). Building the function is one decision. Licensing or making the content is a separate one, with its own cost. Those rows are listed again in the last section.

## 1. Timeline and clips

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Multi-track timeline (main + overlay, audio, text, captions) | Has | Has | — | |
| Magnetic main track (no gaps) | Has | Has | — | |
| Trim by dragging edges, frame-snapped | Has | Has | — | Main clips (WS8). Audio, text and overlay items have no handles yet: S. Mac: Every item has handles; the main-clip start trim was fixed in WS9. Android: Every item (wave 1). |
| Split at the playhead | Has | Has | — | One tap in the transport. Mac: S key, or the toolbar |
| Delete / ripple delete | Has | Has | — | Mac: ⌫; Ripple toggle |
| **Reorder clips (long-press and drag)** | Has | Has | S | Engine `moveMainClip` exists; there is no gesture. Mac: Drag a main clip (WS9). Android: Long-press a main clip and drag (wave 1). |
| **Move items in time** (text, music, overlays) | Has | Has | S | Engine `moveItem` exists; there is no gesture. Important for serious editing. Mac: Drag on its row; not between rows. Android: Long-press and drag; snaps to the playhead, edges and beats (wave 1). |
| Duplicate | Has | Missing | — | |
| Replace clip (keep edits) | Has | Has | S | Android: Overlay → Replace on the selected clip; its edits stay. Mac: Bin → take's menu → Replace the selected clip; its edits stay. |
| **Freeze frame** | Has | Has | M | A still item from the current frame. Android: `holdSec` hold clip; Edit → Freeze frame, length by slider or edges (wave 1). Mac: Timeline → Freeze frame at the playhead; length in Speed, or drag its edges (wave 1). |
| **Reverse** | Has | Has | L | Android: Speed → Reverse (main clips and video overlays). The server's free `reverse` helper (local ffmpeg, picture and sound, sources ≤ 60 s, reused per source) makes a reversed copy; the clip switches to it (`Asset.reverseOf`, `reverseClip`: in/out and any speed curve mirrored) and back instantly. Freeze frames can't be reversed. The timeline tile says "Reversed". Screenshot: android-edit/m8_reverse.png. Mac: Speed → Reverse: the server's reversed copy of the source (made once, free, up to 60 s), kept in the edit; toggling back is instant; background removal and a separate sound are turned off with a notice. |
| Slip edit | Has | Has | S | `trimClip` both ends at once. Android: Edit → Slip slider. Mac: Slip panel (the source moves, the length stays). |
| Snapping (to the playhead, edges, beats) | Has | Partial | S | Beats only. Mac: Beats only. Android: moving and trimming snap to the playhead, other items' edges and beats (within 10 dp). |
| Timeline zoom (pinch) | Has | Has | — | 8–480 dp/s. Mac: Slider and ± buttons, 12–400 pt/s |
| Frame-by-frame stepping buttons | Has | Has | S | Scrub is frame-exact; ±1 frame buttons would help. Mac: ← / → keys and ‹ › in the transport (wave 1). Android: ◀ ▶ in the transport (wave 1). |
| Crop / rotate | Has | Has | — | Crop added in WS8. Mac: Crop section added in WS9 |
| Mirror / flip | Has | Has | S | Transform `scaleX −1`; needs a contract field. Android: `transform.flipX/flipY`; Transform panel (wave 1). Mac: Transform → Mirror / Flip (wave 1). |
| Layers (overlay / PiP) | Has | Has | — | |
| Hide or mute tracks | Has | Has | S | Track headers are tablet-only; phone has none. Mac: And lock. Android: Edit → Tracks on the phone; headers on the tablet. |
| Adjustment layer | Has | Has | M | Android: Filters → "Add adjustment layer" at the playhead (3 s) on an "Adjustment" lane; a selected layer takes a filter preset, exposure, contrast, saturation, temperature, tint and strength, each with ◆ keyframes. It grades everything under it; text and captions stay on top (`AdjustItem` on an `adjust` track, `adjustLayerMatrix`; one composition-level matrix effect). No look, mask, highlights/shadows or transform on a layer. Server render: drawn over the joined picture, under the text (one colour run per stretch; keyed layers sampled every 0.1 s). Screenshot: android-edit/m5_adjust_layer.png. Mac: Video → Add adjustment layer (3 s at the playhead, on an "Adjustment" lane); the selected layer has a filter with its amount, exposure, contrast, saturation, temperature, tint and Strength, each with a ◆; one colour matrix over the whole picture before text and captions (text now always draws above pictures, as on Android). |
| Undo / redo (100 steps), shared history with Claude | Has | Has | — | Mac: ⌘Z / ⇧⌘Z |
| Drafts / autosave | Has | Has | — | Edit sessions and local drafts |
| Apply to all (looks, transitions) | Has | Partial | — | Mac: Transitions only; looks per clip |
| Extract frame as a photo | Has | Has | S | `FrameStill` exists. Android: Edit → Save frame as photo, rendered like the export (wave 1). Mac: Viewer → Save this frame as a picture (PNG, rendered like the export; wave 1). |
| Social safe-zone guides | Has | Has | — | |
| Teleprompter, in-app camera | Missing | Missing | L | Outside Edit; the camera lives in the Suite |

## 2. Speed

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Constant speed 0.1–10×, pitch kept | Has | Has | — | |
| Speed curves (presets + custom graph) | Has | Has | — | |
| **Smooth slow-mo (frame interpolation)** | Has | Has | XL | Owner-approved 2026-11-09. Server job `slowmo` (paid, price on the button), 2× or 4×, 0.3–10 s from the playhead; `Asset.derivedFrom {op:"slowmo"}` plus `applySlowmo` split the clip (shared fixture). Android: Speed sheet, "Smooth slow motion" (x_slowmo). Mac: Speed panel → "Smooth slow motion" (2× / 4×, 1 / 2 / 4 s from the playhead) over the same job, the price confirmed first; the copy is reused, the slowed piece muted and selected (WS9). On macOS 15.4+ the Mac makes the copy itself with Apple's frame interpolation (free), uploads it and falls back to the job if that fails. |
| Speed on audio-only clips | Has | Has | M | Android: Speed panel on a selected music, voice or effect clip: 0.5–2×, pitch kept (contract: audio speed 0.5–2; beats map through clipTimeAt; server render uses atempo). Mac: Speed on a selected music, voice or effect clip: 0.5–2× (slider and 0.5× / 1× / 1.5× / 2×), pitch kept (spectral); beats, loops and beat marks go through clipTimeAt / clipSourceAt. |
| Set the duration (speed computed) | Has | Has | S | Android: Speed → Length slider. Mac: Speed → Length slider. |

## 3. Transitions

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Transitions (cut, fade, dip to black/white, slide, push, zoom, whip, spin, glitch) | Has | Has | — | 9 types, own design. Android: 7 more kinds (zoom out, whip right, cover left/right/up/down, split fade), contract 2026-11-09, as presets in Effects → More transitions. |
| Duration, apply to all | Has | Has | — | |
| More transition types | Has | Has | M each | Functional, but the value is in a curated set: **Content** Android: the seven kinds and 12 in-house presets under More transitions (content library, WS8). Mac: seven more kinds (zoom out, whip right, cover ×4, split fade) and 12 in-house presets as chips (content library, WS9). |
| Transitions on overlay tracks | Partial | Missing | M | Android: overlay clips fade / slide / zoom in and out through the same `animIn`/`animOut` (no cross-dissolve between overlays). |
| Clip in/out animations (video) | Has | Has | M | Text and images have them. Android: Transform → Animation in / out on any video clip, main or overlay (`animIn`/`animOut` on VideoClip; fade, pop, slide up/down, zoom). Mac: Animate panel on any video clip, main or overlay (`animIn`/`animOut`), preview and export. |

## 4. Text, captions and animation

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| **Add plain text** | Has | Has | S | Only through hook templates. "Add text" plus a style editor is needed. Mac: Add text at the playhead. Android: Text → Add text at the playhead (wave 1). |
| **Text styling** (font, colour, stroke, shadow, background, spacing, size) | Has | Has | M | The model has all of it; the UI only edits the text itself. Mac: Font, colour, weight, size, align, outline colour and width, shadow, letter spacing, line height, box, upper case (wave 1). |
| Fonts library | Has | Has | M | Six bundled families plus nine OFL families from the content library (Inter, Montserrat, Roboto Condensed, Playfair Display, Unbounded, Rubik, JetBrains Mono, Caveat, Oswald), all with Cyrillic and Latin Extended; downloaded on first use, the bundled family stands in meanwhile; text and captions. Screenshot: android-edit/c_fonts.png. Mac: the nine content families (OFL) in the Text and caption font menus, loaded when used; the bundled fallback draws until then (WS9). |
| Import own fonts | Has | Has | M | Android: Text → Font → "Your font…" (system file picker, .ttf/.otf up to 10 MB, checked and named on the phone); each of the edit's fonts is a chip named from the file. Contract: a `font` asset (upload, optional `name`) and `TextStyle.fontAsset` on text items (captions keep the six families; `font` stays the fallback; kits drop it). Server: `purpose: "font"` presign, `/v1/editor/uploads/font-check`, saved edits check the file, the render draws with it. Screenshot: android-edit/m6_own_font.png. Mac: Text → Style → Font menu: the edit's own fonts and "Your font…" (a .ttf / .otf from this Mac, up to 10 MB, checked, named from the file); drawn as its own face (no weight), in the preview and the export. |
| Text templates / hooks | Has | Has | — | 10 hooks; more is **Content** |
| In/out text animations | Has | Has | S | The model has 7 kinds; there is no picker. Mac: Animate panel. Android: In / out picker with lengths (wave 1). |
| Loop animations | Has | Has | M | Android: Loop under Animation in / out (Text panel; Transform for overlays and photos): pulse, sway, float, spin, blink, with speed and amount (`animLoop`, `loopState`). Not on main clips. Mac: Animate → Loop (None, Pulse, Sway, Float, Spin, Blink) with Speed and Amount, on overlays, pictures and text; moving a clip to the main track drops it (shared fixtures). |
| Keyframed text | Has | Has | S | Engine yes; the Transform panel works on text, but there is no text selection on the phone timeline lane yet. Android: The Transform panel acts on the selected text (wave 1 fixed it moving the clip). |
| Auto captions | Has | Has | — | Server helper |
| Caption styles (word pop, karaoke, box, minimal, highlighter, neon) | Has | Has | — | |
| Caption language choice | Has | Missing | S | Server parameter. Android: Captions → Spoken language (Detect or one of 14), sent as the job's `options.language`. |
| Translated / bilingual captions | Has | Has | M | Owner-approved 2026-11-09. Server job `translate` (paid, Standard / Best quality, price on the button), words come back timed; `CaptionTrack.language` + `original` keep both languages, switchable (shared fixture `captionTranslate`). Android: Captions → Language (x_translate); the languages offered come from `features.translate.languages` (only what the export draws). Captions in other scripts (2026-11-09): ja/zh/th (and lo/km/my) pages join words without spaces and ar/he/fa/ur read right to left (`captionJoiner`, `isRtlLanguage`, shared fixture `captionScripts`); Android draws zh, ja, ko, ar, hi, th, ru correctly in the export and the preview (scripts_engine, scripts_preview). Not shown two at once. Mac: Captions → Translate…: on this Mac (Apple translation, free, macOS 15) or the server job (Standard / Best quality, the price first, the lines as shown); both keep the original, "Show <language>" switches back (WS9). |
| Edit caption text (fix a word) | Has | Has | S | You can cut words but not retype them. Mac: Double-click a word. Android: Captions → Words → Tap to fix text. |
| Filler and silence removal, edit by transcript | Has | Has | — | |
| Text-to-speech voice-over | Missing | Missing | L | Needs a TTS vendor decision. Voices are **Content**. |
| Lyric captions | Missing | Missing | L | |

## 5. Audio

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Clip sound lane, detach / extract audio | Has | Partial | — | WS8. Mac: Sound lane with waveform and mute; no detach |
| Extract audio from another video | Has | Has | S | Add another take's sound only. Android: Overlay → Sound: another take's sound at the playhead. Mac: Bin → take's menu → Add its sound at the playhead (sound effects row). |
| Volume, mute, fade in/out | Has | Has | — | Mac: Up to +6 dB (fixed in WS9) |
| Volume keyframes | Has | Has | S | Engine has `volume` keys; no UI. Mac: ◆ next to Volume; the slider sets the key at the playhead (wave 1). Android: ◆ next to Volume; the slider sets the key at the playhead (wave 1). |
| Auto-ducking under voice and speech | Has | Has | — | The research found no confirmed ducking in the other apps; MUSE leads here |
| Beat detection, beat marks, snap to beats | Has | Has | — | |
| Manual beat marks (tap) | Has | Has | S | Android: Audio → Mark a beat here, Clear beat marks. Mac: Audio → Mark a beat here, Clear beat marks. |
| Voice effects (warm, radio, phone, deep) | Has | Has | — | 4 effects. More character voices: M. |
| Noise reduction, voice enhance | Has | Has | — | |
| Vocal / instrumental separation | Missing | Missing | L | Server model |
| Volume normalisation | Has | Has | M | Android: Audio → Even out volume: spoken clips (main and voice) brought to their median level from the decoded sound levels, 0.25×–2×, no clipping; music left to ducking. Mac: Audio → Even out volume, from the measured clip levels (same rules). |
| Record voice-over | Has | Has | — | In-app recorder (WS8). Mac: Mac microphone |
| Recording over playback (hear the video while recording) | Has | Has | S | Needs headphones handling. Android: Audio → Play the video while recording (on with headphones, off on the speaker); the take is moved earlier by the route's typical latency (Bluetooth 200 ms, wired 20 ms); a red bar on the ruler while recording. Mac: Record VO with "Play the video while recording" (on by default for headphones, Bluetooth or USB); the take lands where recording started, shifted by the output delay; a red bar grows on the voice row (design pass, owner-approved). |
| **Music library** | Missing | Missing | M (function) | **Content.** Licensing is the real cost. `add_music` refuses `library` today. |
| **Sound effects library** | Has | Has | M (function) | **Content**, built: 197 CC0 sounds (UI SFX in 5 styles, Kenney game sounds) from the content library (plans/edit-content-licences.md). Android: Audio → Sound effects: search, style chips, play preview, Add at the playhead on a sound-effects track (`content:<pack>/<item>` audio assets). Real-world recordings (applause, laughter) left out for now (coordinator). Screenshot: android-edit/c_sfx.png. Mac: Bin → Music → Sound effects, searchable by category, with a play preview; added at the playhead on the sound effects row (WS9). |
| ~~AI music~~ / generative SFX | Dropped | Dropped | XL | **AI music: dropped by the owner 2026-11-09** (no music job, no music UI on any platform). Generative SFX: not planned. |
| Audio loop | Has | Has | S | Android: Audio → Loop to the end. Mac: Audio → Loop to the end. |

## 6. Effects, filters and adjustments

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Looks / filters with intensity | Has | Has | — | 32 original looks. More is **Content**, which MUSE can make itself (`lookpack.ts`). Android: 12 more in-house looks from the content library (Filters → More looks; effects, HSL and curves on the pack grades), 10 caption templates (Captions → Style → Templates) and 12 transition presets (Effects → More transitions). Mac: plus the 12 in-house looks and 10 caption templates of the content library as chips (WS9). |
| .cube LUT import | Has | Has | — | |
| Exposure, contrast, saturation, temperature, highlights, shadows, grain | Has | Has | — | |
| Tint | Has | Has | S | Android: Filters → Adjust → Tint (`adjust.tint`, green ↔ magenta, after temperature in the colour matrix). Mac: Adjust → Tint under Temperature (`adjust.tint`; fixtures pass on the Mac). |
| Vignette, sharpen, halation, light leak, chromatic aberration | Has | Has | S | Engine `look` has them; there are no sliders. Android: Filters → Adjust: vignette, sharpen, fade, glow, light leak, colour fringe, grain. Mac: Look sliders: vignette, sharpen, fade, colour fringe, glow, light leak. |
| Curves | Has | Has | M | Engine has curves; no editor. Android: Filters → Adjust → Curves: All / Red / Green / Blue; drag to move, touch the line to add, tap a point to remove (`look.curves`). Mac: Adjust → Curves: All / Red / Green / Blue; drag to move, click the line to add, click a point to remove (`look.curves`). |
| HSL (per-hue) | Has | Has | L | Android: Filters → Adjust → HSL: 8 colour dots (red…magenta), then hue, saturation and luminance for the picked band, and Reset HSL. Contract: `look.hsl` (look step 4b, after the curves and before the LUT; `hslFn`, `hueWeights`), baked into the look's one LUT; kits carry it with the look. Server render: curves + HSL + LUT baked into one .cube (curves are drawn there now too). Screenshot: android-edit/m7_hsl.png. Mac: Adjust → HSL: eight colour dots pick the band; Hue, Saturation, Luminance; Reset HSL; baked into the look's colour cube after the curves (preview and export). |
| Auto adjust | Has | Has | M | Android: Filters → Adjust → Auto adjust: the frame under the playhead → exposure, contrast, saturation, temperature and tint (core `autoAdjust`). Mac: Adjust → Auto adjust from the clip's source frame under the playhead (same numbers as Android's `autoAdjust`). |
| Video effects library (glitch, blur, retro, …) | Missing | Missing | L | **Content** plus GL effects |
| Body and face effects | Missing | Missing | XL | Segmentation and tracking; mostly **Content** |
| Adjustment keyframes | Has | Has | M | Android: ◆ beside Exposure, Contrast, Saturation, Temperature and Tint in Filters → Adjust (KfProp exposure…tint, `adjustAt`; the colour matrix runs per frame). Highlights, shadows and look effects are not keyframable yet. Mac: ◆ beside Exposure, Contrast, Saturation, Temperature and Tint; a keyed slider sets its key at the playhead (shared fixtures). |
| AI restyle (generative) | Missing | Missing | XL | MUSE's Suite does generation. Re-styling an edit is a model question. |
| HDR editing / export | Missing | Partial | L | Mac: HDR footage keeps its highlights through the edit when exporting HDR (extended-range colour; LUT looks still clip at white); the preview stays SDR (WS9, XL owner-approved). |

## 7. Keyframes

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Position, scale, rotation | Has | Has | — | Mac: Sliders set the key at the playhead once keyed (fixed in WS9) |
| Opacity | Has | Has | S | Engine yes; no button. Android: Transform → Opacity with ◆ (wave 1). |
| Volume | Has | Has | S | See Audio. Android: volume keyframes with easing (wave 1). Mac: See Audio (wave 1) |
| Look / adjust / mask / crop keyframes | Partial | Partial | M each | Android: adjust (colour keys), mask (x, y, size, rotation, feather; Effects → Mask ◆) and the finishing look (vignette, grain, light leak; Filters → Adjust ◆) keyframe; `maskAt` / `lookAt`. Crop keyframes deferred: Media3 crops are static per clip (scale / x / y keys cover push-ins). Mac: adjust (colour ◆ in Adjust), mask (◆ beside Feather, Size, Rotation, Position X and Y) and the finishing look (◆ beside Vignette, Grain, Light leak), the same `maskAt` / `lookAt` (shared fixtures); crop deferred as on Android. |
| Easing choice | Has | Has | S | Engine has 5 eases; the UI always uses ease-in-out. Mac: Linear, in-out, ease out, hold. Android: Linear, ease in, ease out, smooth, hold (wave 1). |
| Keyframe list / move / delete on the timeline | Has | Has | M | Engine has `remove_keyframe`. Android: the selected item's ◆ on its timeline lane, dragged to move; Transform → Previous / Next keyframe, Remove keyframes here. Mac: the selected item's ◆ on its timeline block, dragged to move every property's key at that time; previous / next key, delete at the playhead. |

## 8. Masks, chroma key and background removal

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Shape masks (linear, mirror, circle, rectangle, heart, star), feather, size, invert | Has | Has | — | |
| Mask position / rotation on the picture (drag) | Has | Partial | S | Model yes; sliders only for size and feather. Mac: Sliders for position (WS9), size, rotation; no drag on the picture. Android: Mask position x/y and rotation sliders. |
| Custom / pen mask | Missing | Missing | L | |
| Chroma key (green / blue, strength, edge, spill) | Has | Has | — | Controls added in WS8. Mac: Softness and spill added in WS9 |
| Chroma colour picker (eyedropper) | Has | Has | S | Android: Effects → Mask & key → Pick from video: a loupe of the source pixels under the finger; lifting sets the key colour (owner-approved design pass). Mac: Mask → Chroma key → Pick from video: a crosshair and the colour under it with its hex on the preview; a click keys out that colour from the clip's own frame (before its look), Esc cancels (design pass, owner-approved). |
| Background removal, tap what to keep | Has | Has | — | Server helper |
| Refine the cut-out with a brush | Missing | Missing | L | |
| Generative background replacement | Missing | Missing | XL | |

## 9. Overlays / PiP and blending

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Overlay video / PiP; add another take to the end | Has | Has | — | Fixed in WS8 |
| Overlay photos / images | Has | Has | S | Android: Overlay → Add a photo: the system photo picker, ≤ 2048 px, PNG transparency kept; placed at the playhead, 3 s, 40 %, Transform open. Mac: Import picture (WS9); photos over 2048 px go up at 2048 px (PNGs keep transparency) and land selected with the Video tab open (design pass). |
| Opacity | Has | Has | S | Model yes; no slider. Android: Transform → Opacity with ◆ (wave 1). |
| **Blend modes** (multiply, screen, overlay, soft light, …) | Has | Has | M | New compositor mode (GL / Core Image) and a contract field. Android: Transform → Blend on overlays, drawn by MUSE's own compositor program in preview and export (wave 1). Mac: Video → Blend on overlays, a Core Image kernel with the reference formulas (wave 1). |
| Move an overlay to the main track and back | Has | Has | S | Android: Edit → Move to main track / Move to an overlay track (app op; no contract change). On the main track the clip fills the frame (overlay placing, opacity, blend, mask and key dropped); off it, it plays at the same time, full frame. Mac: Transform → Move to main track / Move to an overlay track (same rules). |
| Split-screen layouts | Has | Has | M | Android: Overlay → Split screen: side by side, top and bottom, three rows, grid of four; the clips on screen at the playhead get crop, fit and transform (no contract change). Mac: Split screen panel: side by side, top and bottom, three rows, grid of four. |
| Motion tracking (text or sticker follows an object) | Missing | Missing | XL | Tracker model |

## 10. Canvas and ratio

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| 9:16, 1:1, 4:5, 16:9 | Has | Has | — | |
| More ratios (4:3, 2.35:1) | Has | Has | S | Android: Ratio and Export shapes; the canvas is free-size in the contract. 2.35:1 at 4K is capped at 4096 px wide. Mac: Ratio and Export shapes; 2.35:1 is 4096 × 1744 at 4K. |
| Background colour | Has | Has | S | `canvas.background` exists; no picker. Mac: Video → Background colour on main clips (wave 1). Android: Ratio → Background (wave 1). |
| Background blur fill | Has | Has | M | Android: Ratio → Blur of the clip (`canvas.fill`, wave 1). Mac: Video → Background: Blur (wave 1). |
| Fit / fill per clip | Has | Has | S | Model `fit`; no toggle. Mac: Transform → Frame: Fill / Fit (wave 1). Android: Ratio → This clip: Fill the frame / Whole picture (wave 1). |
| Auto reframe (faces) | Has | Has | M | Owner-approved 2026-11-09. Android: Follow faces (ML Kit on the phone, 5 samples a second → smoothed x keyframes, `Reframe` in core; x_reframe). Mac: Vision faces on a ratio change; and Transform → "Follow faces": Vision finds the main face 5×/s on this Mac and the clip gets x keyframes that keep it centred without showing an edge, with the same smoothing, dead zone and thinning as Android (Reframe.kt) (WS9, XL owner-approved). |

## 11. Stickers

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Sticker / GIF / emoji library | Has | Has | M (function) | **Content**, built: 1,899 Twemoji stickers (CC BY 4.0, attributed) as 160 px PNG. Android: Overlay → Stickers: search (names and CLDR words), category chips, a tap places it at the playhead (3 s, 30 %) like a photo, so it keyframes, animates and blends. No GIFs. Screenshot: android-edit/c_stickers.png. Mac: Bin → Stickers, the Twemoji set (CC BY 4.0), searchable by category; a click places one at the playhead. Licences in Settings → About (WS9). |
| Own image or cut-out as a sticker | Partial | Partial | M | Uses the image items and the matte. Android: own pictures through Overlay → Add a photo (an image item: transform, keyframes, animations, blend); a cut-out isn't a sticker yet (background removal runs on videos). Mac: Own pictures (WS9); a cut-out isn't a sticker yet |
| Sticker animation and keyframes | Has | Has | — | Comes with image items. Android: animation in / out / loop and transform keyframes on image items (wave 1, M) |

## 12. Templates

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Template library (swap in your media) | Partial | Partial | L | "Recreate an edit" (recipes) is the MUSE take on this. A browsable library is **Content**. Mac: Recreate an edit |
| Beat-synced auto-cut to a song | Has | Has | M | Beats engine exists. Android: Audio → Cut clips to the beat: each main clip ends on the beat nearest to its end (the latest its source can reach). Mac: Audio → Cut clips to the beat (same rule). |
| Save your own edit as a template / style kit | Partial | Partial | M | Android: style kits (Edit → Style kits: save this edit's look, colour, transition, caption and text styles and background by name; apply to another edit; `/v1/editor/kits`, shared `kit.ts`). A template that swaps in new media is still the recipes / Recreate path. Mac: Video → Style kits: Save style, Apply, delete (asks first); the same kit engine (fixtures match). |

## 13. AI features

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Auto captions, cut silences and fillers, denoise, background removal, beats | Has | Has | — | |
| Claude edits the project (shared session) | Has | Has | — | Others' "AI assistant" equivalent; MUSE's is deeper |
| Auto-edit / AutoCut from clips and music | Missing | Missing | L | Claude plus beats could drive it |
| Long video to shorts | Missing | Missing | L | |
| Stabilisation | Has | Has | L | Owner-approved 2026-11-09. Server job `stabilize` (free, up to 3 min); `Asset.derivedFrom {op:"stabilize"}` is the same length, so the clip only switches asset (shared fixture). Android: Speed sheet, "Stabilise". Mac: Speed panel → "Stabilise" over the same job; only the last helper step switches off ("Turn off Reverse first"); background removal is dropped and the notice says so (WS9). |
| Enhance / upscale | Partial | Partial | — | The Suite has upscale for takes; not in Edit |
| Relight, retouch / beauty | Missing | Missing | XL | |
| Text-to-speech | Missing | Missing | L | See Text |
| Frame interpolation | Has | Has | XL | See Speed (smooth slow motion) |

## 14. Export

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| 720p / 1080p / 4K, 24/30/60 fps, H.264 / HEVC | Has | Has | — | Mac: Export check in Mac CI (WS9) |
| Size estimate | Has | Has | — | |
| Captions burnt in or .SRT | Has | Has | — | Mac: Save to Library always burns them in (WS9) |
| Label as AI-generated | Has | Has | — | Sent with the version (fixed in WS8). Mac: Sent with the version (WS9) |
| Content Credentials (C2PA) | Missing | Missing | L | Signing needs a certificate decision. The "Coming soon" switch was removed in WS8. Mac: The "Coming soon" switch was removed (WS9) |
| 2K, bitrate choice | Has | Has | S | Android: 2K, and Smaller file / Recommended / Higher quality bitrate (0.6× / 1× / 1.6× of ~0.12 bit per pixel per frame). Mac: 2K, and Smaller file / Recommended / Higher quality (reader → writer export at the bitrate). |
| HDR export | Missing | Has | L | Mac: Export → "HDR (HLG)": HEVC Main 10, BT.2020 / HLG, through the reader → writer path; checked in CI (codec, tags, picture) (WS9, XL owner-approved, Mac first). |
| Share straight to TikTok / IG / Shorts | Partial | Partial | — | MUSE Socials (posting) |
| GIF / audio-only export | Has | Has | S each | No competitor confirmed either. Android: Export → Sound only (.m4a, AAC 192 kbit/s, into Music/MUSE) and GIF (loops, 15 fps, 480 px short side, up to 30 s, into Pictures/MUSE); both saved to the phone only, not as versions. Mac: Export → Format: Sound only (.m4a, AAC 192 kbit/s) and GIF (loops, 15 fps, 480 px, up to 30 s), saved to a file you pick. |
| Watermark | n/a | n/a | — | MUSE adds none |

## 15. Desktop only (Mac)

What a desktop editor is expected to have beyond the mobile apps (keyboard, pointer, precision). Status from `plans/mac-edit-audit.md`; Size is the Mac effort.

| Feature | Mac | Size | Notes |
|---|---|---|---|
| Space play / pause | Has | — | |
| J / K / L shuttle (1×, 2×, 4×) | Partial | S | Forward works; reverse steps back 0.5 s (a composed edit can't play backwards in AVFoundation). |
| ← / → one frame | Has | — | |
| ⇧← / ⇧→ one second, Home / End | Missing | S | |
| ↑ / ↓ previous / next edit point | Missing | S | |
| Split at the playhead | Has | — | S (leading editors also take ⌘B). |
| Trim to the playhead (delete left / right of it, ripple) | Missing | S | |
| In / Out marks (I / O), play the range | Missing | S | |
| Copy / paste / duplicate (⌘C ⌘V ⌘D), select all | Missing | S | |
| Undo / redo (⌘Z ⇧⌘Z), 100 steps | Has | — | |
| Timeline zoom (⌘+ ⌘−, zoom to fit) | Partial | S | Slider and buttons; no shortcuts, no zoom to fit. |
| Timeline follows the playhead while playing | Missing | S | |
| Markers (M) | Missing | S | |
| Multi-track timeline (video, overlays, text, captions, stickers, music, voice, sfx) | Has | — | |
| Precision trim handles, one undo step per drag | Has | — | Fixed 2026-11-08 (start trim ran away). |
| Snap to clip edges / playhead | Missing | S | Snaps to beats only. |
| Roll / slip / slide edits | Missing | M | |
| Numeric timecode entry (go to, set duration) | Missing | S | |
| Drag clips between rows, multi-select | Missing | M | Rows: same row only; main clips reorder (fixed). |
| Track lock / hide / mute | Has | — | |
| Resize track height, rename / delete tracks | Missing | S | |
| Keyframes with ease, previous / next key | Has | — | Fixed 2026-11-08 (sliders on keyed properties). |
| On-canvas transform (drag / scale / rotate in the viewer) | Missing | M | Inspector sliders only. |
| Full-screen preview | Has | — | Fixed 2026-11-08. |
| Actual-size / fit viewer zoom | Has | — | Fixed 2026-11-08. |
| Import from Finder (video, picture, sound, .cube) | Has | — | Pictures and videos fixed 2026-11-08. Drag-and-drop from Finder: missing. |
| Export to a file with format, size, fps, codec, .srt | Has | — | |
| Export queue / keep editing while exporting | Missing | M | Export blocks the editor with a progress sheet. |

## Content: needs licensing or production, separate from building the function

Each of these needs its own decision: license (cost, terms per region), commission, or make it in-house.

| Library | Function size | Note |
|---|---|---|
| Music library | M | `add_music` with `library` is refused today. The largest licensing cost. |
| Sound effects library | M | Could start with an owned or royalty-free pack |
| Stickers / GIFs / emoji | M | Emoji can use an open set (e.g. a permissive-licence emoji font) |
| Fonts | M | Open-licence (OFL) families avoid fees |
| More transitions, effects, filters | M–L | MUSE can make these itself; looks already are |
| Text / caption / hook templates | S each | Made in-house |
| Edit templates | L | Recreate's recipes could seed them |
| TTS voices | L | Comes with the TTS vendor |

## Suggested first wave, for the owner to accept or change

All are functional, with no content cost, and use engines that already exist:

1. **Move items in time and reorder clips** (S + S). Without these, multi-track editing is still awkward.
2. **Text: add text + style editor + animation picker** (S + M + S).
3. **Opacity, volume keyframes and easing in the UI** (S each).
4. **Freeze frame, mirror, extract frame, ±1-frame buttons** (M, S, S, S).
5. **Blend modes** (M) and **background colour / blur fill** (S, M).
6. **Trim handles on audio, text and overlay items** (S).

Bigger bets, each needing a decision:

- Music library (licensing).
- Motion tracking.
- C2PA (certificate).

## Sources

The full inventory with every link is in WS8's research notes, on request. The main sources:

- **CapCut:** apps.apple.com/us/app/id1500855883 · capcut.com/resource/capcut-ai · capcut.com/help/export-videos-in-capcut · capcut.com/help/bilingual-subtitles · capcut.com/resource/voice-isolator · capcut.com/create/blend-modes-creative-video-photo-effects
- **VN:** apps.apple.com/app/id1343581380
- **InShot:** apps.apple.com/app/id997362197
- **Premiere on iPhone:** apps.apple.com/app/id6742757464 · helpx.adobe.com/premiere/mobile/get-started.html
- **Edits:** apps.apple.com/app/id6738967378
- **Reviews:**
  - videomaker.com (Premiere for iPhone review)
  - vidpros.com/capcut-pro-vs-free
  - bigvu.tv (CapCut free vs Pro, 2026)
  - socialmediatoday.com (Edits keyframes)
  - petapixel.com (Edits Restyle)

CapCut's free/paid split is contradictory across sources (its own pages vs reviews), so this document does not rely on it.

## Owner's decision (2026-11-08)
- **Build ALL functional rows, in waves, on Android and Mac:** every Missing/Partial row that needs no licensed content. Wave 1 is the suggested list above; then the rest, in size order. XL rows that need a model or vendor choice are researched and priced, and brought back to the owner before any spend.
- **Content:** free/open libraries first: open-licence fonts (OFL), royalty-free sound effects, an open emoji set, plus effects, filters, transitions and caption templates made in-house. No paid music library and no TTS vendor for now.
