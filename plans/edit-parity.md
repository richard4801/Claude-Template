# Edit parity: MUSE vs the leading mobile editors

_WS8, 2026-11-08. **For the owner to prioritise. Nothing in this document gets built until the owner has chosen.**_ New screens here also need design approval.

## Scope

- **Reference app:** CapCut, as the owner asked.
- **Also compared:** VN Video Editor, InShot, Adobe Premiere on iPhone (which replaced Rush in 2025) and Instagram Edits.
- **Sources:** public only: App Store listings, official help and feature pages, and reviews. Full inventory with links: the "Sources" section at the end. Where a source is thin, the row says so.
- **Rule:** MUSE rebuilds *functionality* in its own design. It never copies another product's assets, names or look.

## How to read this

**MUSE status** is for Android Edit after WS8's fixes. The Mac has the same engine and is noted where it differs.

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

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Multi-track timeline (main + overlay, audio, text, captions) | Has | — | |
| Magnetic main track (no gaps) | Has | — | |
| Trim by dragging edges, frame-snapped | Has | — | Main clips (WS8). Audio, text and overlay items have no handles yet: S. |
| Split at the playhead | Has | — | One tap in the transport |
| Delete / ripple delete | Has | — | |
| **Reorder clips (long-press and drag)** | Missing | S | Engine `moveMainClip` exists; there is no gesture. |
| **Move items in time** (text, music, overlays) | Missing | S | Engine `moveItem` exists; there is no gesture. Important for serious editing. |
| Duplicate | Has | — | |
| Replace clip (keep edits) | Missing | S | |
| **Freeze frame** | Missing | M | A still item from the current frame |
| **Reverse** | Missing | L | Needs a reversed proxy render on the device |
| Slip edit | Missing | S | `trimClip` both ends at once |
| Snapping (to the playhead, edges, beats) | Partial | S | Beats only |
| Timeline zoom (pinch) | Has | — | 8–480 dp/s |
| Frame-by-frame stepping buttons | Missing | S | Scrub is frame-exact; ±1 frame buttons would help |
| Crop / rotate | Has | — | Crop added in WS8 |
| Mirror / flip | Missing | S | Transform `scaleX −1`; needs a contract field |
| Layers (overlay / PiP) | Has | — | |
| Hide or mute tracks | Partial | S | Track headers are tablet-only; phone has none |
| Adjustment layer | Missing | M | |
| Undo / redo (100 steps), shared history with Claude | Has | — | |
| Drafts / autosave | Has | — | Edit sessions and local drafts |
| Apply to all (looks, transitions) | Has | — | |
| Extract frame as a photo | Missing | S | `FrameStill` exists |
| Social safe-zone guides | Has | — | |
| Teleprompter, in-app camera | Missing | L | Outside Edit; the camera lives in the Suite |

## 2. Speed

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Constant speed 0.1–10×, pitch kept | Has | — | |
| Speed curves (presets + custom graph) | Has | — | |
| **Smooth slow-mo (frame interpolation)** | Missing | XL | Needs a model choice (server job like denoise, or on-device). The "Coming soon" switch was removed in WS8. |
| Speed on audio-only clips | Missing | M | The contract says audio plays at 1×; needs a contract change. |
| Set the duration (speed computed) | Missing | S | |

## 3. Transitions

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Transitions (cut, fade, dip to black/white, slide, push, zoom, whip, spin, glitch) | Has | — | 9 types, own design |
| Duration, apply to all | Has | — | |
| More transition types | Partial | M each | Functional, but the value is in a curated set: **Content** |
| Transitions on overlay tracks | Missing | M | |
| Clip in/out animations (video) | Missing | M | Text and images have them |

## 4. Text, captions and animation

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| **Add plain text** | Partial | S | Only through hook templates. "Add text" plus a style editor is needed. |
| **Text styling** (font, colour, stroke, shadow, background, spacing, size) | Partial | M | The model has all of it; the UI only edits the text itself. |
| Fonts library | Partial | M | Six bundled families. More fonts: **Content** (open licences, e.g. OFL, are an option). |
| Import own fonts | Missing | M | |
| Text templates / hooks | Has | — | 10 hooks; more is **Content** |
| In/out text animations | Partial | S | The model has 7 kinds; there is no picker |
| Loop animations | Missing | M | |
| Keyframed text | Partial | S | Engine yes; the Transform panel works on text, but there is no text selection on the phone timeline lane yet |
| Auto captions | Has | — | Server helper |
| Caption styles (word pop, karaoke, box, minimal, highlighter, neon) | Has | — | |
| Caption language choice | Missing | S | Server parameter |
| Translated / bilingual captions | Missing | M | Server job (LLM) |
| Edit caption text (fix a word) | Partial | S | You can cut words but not retype them |
| Filler and silence removal, edit by transcript | Has | — | |
| Text-to-speech voice-over | Missing | L | Needs a TTS vendor decision. Voices are **Content**. |
| Lyric captions | Missing | L | |

## 5. Audio

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Clip sound lane, detach / extract audio | Has | — | WS8 |
| Extract audio from another video | Missing | S | Add another take's sound only |
| Volume, mute, fade in/out | Has | — | |
| Volume keyframes | Partial | S | Engine has `volume` keys; no UI |
| Auto-ducking under voice and speech | Has | — | The research found no confirmed ducking in the other apps; MUSE leads here |
| Beat detection, beat marks, snap to beats | Has | — | |
| Manual beat marks (tap) | Missing | S | |
| Voice effects (warm, radio, phone, deep) | Has | — | 4 effects. More character voices: M. |
| Noise reduction, voice enhance | Has | — | |
| Vocal / instrumental separation | Missing | L | Server model |
| Volume normalisation | Missing | M | |
| Record voice-over | Has | — | In-app recorder (WS8) |
| Recording over playback (hear the video while recording) | Missing | S | Needs headphones handling |
| **Music library** | Missing | M (function) | **Content.** Licensing is the real cost. `add_music` refuses `library` today. |
| **Sound effects library** | Missing | M (function) | **Content** |
| AI music / generative SFX | Missing | XL | Model and vendor decision |
| Audio loop | Missing | S | |

## 6. Effects, filters and adjustments

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Looks / filters with intensity | Has | — | 32 original looks. More is **Content**, which MUSE can make itself (`lookpack.ts`). |
| .cube LUT import | Has | — | |
| Exposure, contrast, saturation, temperature, highlights, shadows, grain | Has | — | |
| Tint | Missing | S | |
| Vignette, sharpen, halation, light leak, chromatic aberration | Partial | S | Engine `look` has them; there are no sliders |
| Curves | Partial | M | Engine has curves; no editor |
| HSL (per-hue) | Missing | L | New engine stage (all three platforms) |
| Auto adjust | Missing | M | |
| Video effects library (glitch, blur, retro, …) | Missing | L | **Content** plus GL effects |
| Body and face effects | Missing | XL | Segmentation and tracking; mostly **Content** |
| Adjustment keyframes | Missing | M | |
| AI restyle (generative) | Missing | XL | MUSE's Suite does generation. Re-styling an edit is a model question. |
| HDR editing / export | Missing | L | |

## 7. Keyframes

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Position, scale, rotation | Has | — | |
| Opacity | Partial | S | Engine yes; no button |
| Volume | Partial | S | See Audio |
| Look / adjust / mask / crop keyframes | Missing | M each | |
| Easing choice | Partial | S | Engine has 5 eases; the UI always uses ease-in-out |
| Keyframe list / move / delete on the timeline | Missing | M | Engine has `remove_keyframe` |

## 8. Masks, chroma key and background removal

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Shape masks (linear, mirror, circle, rectangle, heart, star), feather, size, invert | Has | — | |
| Mask position / rotation on the picture (drag) | Partial | S | Model yes; sliders only for size and feather |
| Custom / pen mask | Missing | L | |
| Chroma key (green / blue, strength, edge, spill) | Has | — | Controls added in WS8 |
| Chroma colour picker (eyedropper) | Missing | S | |
| Background removal, tap what to keep | Has | — | Server helper |
| Refine the cut-out with a brush | Missing | L | |
| Generative background replacement | Missing | XL | |

## 9. Overlays / PiP and blending

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Overlay video / PiP; add another take to the end | Has | — | Fixed in WS8 |
| Overlay photos / images | Partial | S | The model has image items; the phone can't pick a photo yet |
| Opacity | Partial | S | Model yes; no slider |
| **Blend modes** (multiply, screen, overlay, soft light, …) | Missing | M | New compositor mode (GL / Core Image) and a contract field |
| Move an overlay to the main track and back | Missing | S | |
| Split-screen layouts | Missing | M | |
| Motion tracking (text or sticker follows an object) | Missing | XL | Tracker model |

## 10. Canvas and ratio

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| 9:16, 1:1, 4:5, 16:9 | Has | — | |
| More ratios (4:3, 2.35:1) | Missing | S | |
| Background colour | Partial | S | `canvas.background` exists; no picker |
| Background blur fill | Missing | M | |
| Fit / fill per clip | Partial | S | Model `fit`; no toggle |
| Auto reframe (faces) | Partial | M | Re-centring on ratio change exists; face-aware reframe is in the spec but not on Android |

## 11. Stickers

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Sticker / GIF / emoji library | Missing | M (function) | **Content** |
| Own image or cut-out as a sticker | Missing | M | Uses the image items and the matte |
| Sticker animation and keyframes | Partial | — | Comes with image items |

## 12. Templates

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Template library (swap in your media) | Partial | L | "Recreate an edit" (recipes) is the MUSE take on this. A browsable library is **Content**. |
| Beat-synced auto-cut to a song | Missing | M | Beats engine exists |
| Save your own edit as a template / style kit | Missing | M | |

## 13. AI features

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| Auto captions, cut silences and fillers, denoise, background removal, beats | Has | — | |
| Claude edits the project (shared session) | Has | — | Others' "AI assistant" equivalent; MUSE's is deeper |
| Auto-edit / AutoCut from clips and music | Missing | L | Claude plus beats could drive it |
| Long video to shorts | Missing | L | |
| Stabilisation | Missing | L | Server or on-device |
| Enhance / upscale | Partial | — | The Suite has upscale for takes; not in Edit |
| Relight, retouch / beauty | Missing | XL | |
| Text-to-speech | Missing | L | See Text |
| Frame interpolation | Missing | XL | See Speed |

## 14. Export

| Feature | MUSE | Size | Notes |
|---|---|---|---|
| 720p / 1080p / 4K, 24/30/60 fps, H.264 / HEVC | Has | — | |
| Size estimate | Has | — | |
| Captions burnt in or .SRT | Has | — | |
| Label as AI-generated | Has | — | Sent with the version (fixed in WS8) |
| Content Credentials (C2PA) | Missing | L | Signing needs a certificate decision. The "Coming soon" switch was removed in WS8. |
| 2K, bitrate choice | Missing | S | |
| HDR export | Missing | L | |
| Share straight to TikTok / IG / Shorts | Partial | — | MUSE Socials (posting) |
| GIF / audio-only export | Missing | S each | No competitor confirmed either |
| Watermark | n/a | — | MUSE adds none |

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

- Smooth slow-mo (model).
- Music library (licensing).
- Stabilisation.
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
