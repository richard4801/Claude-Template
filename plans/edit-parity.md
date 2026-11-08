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
| Replace clip (keep edits) | Missing | Missing | S | |
| **Freeze frame** | Has | Missing | M | A still item from the current frame. Android: `holdSec` hold clip; Edit → Freeze frame, length by slider or edges (wave 1). |
| **Reverse** | Missing | Missing | L | Needs a reversed proxy render on the device |
| Slip edit | Missing | Missing | S | `trimClip` both ends at once |
| Snapping (to the playhead, edges, beats) | Partial | Partial | S | Beats only. Mac: Beats only |
| Timeline zoom (pinch) | Has | Has | — | 8–480 dp/s. Mac: Slider and ± buttons, 12–400 pt/s |
| Frame-by-frame stepping buttons | Has | Has | S | Scrub is frame-exact; ±1 frame buttons would help. Mac: ← / → keys. Android: ◀ ▶ in the transport (wave 1). |
| Crop / rotate | Has | Has | — | Crop added in WS8. Mac: Crop section added in WS9 |
| Mirror / flip | Has | Missing | S | Transform `scaleX −1`; needs a contract field. Android: `transform.flipX/flipY`; Transform panel (wave 1). |
| Layers (overlay / PiP) | Has | Has | — | |
| Hide or mute tracks | Partial | Has | S | Track headers are tablet-only; phone has none. Mac: And lock |
| Adjustment layer | Missing | Missing | M | |
| Undo / redo (100 steps), shared history with Claude | Has | Has | — | Mac: ⌘Z / ⇧⌘Z |
| Drafts / autosave | Has | Has | — | Edit sessions and local drafts |
| Apply to all (looks, transitions) | Has | Partial | — | Mac: Transitions only; looks per clip |
| Extract frame as a photo | Has | Missing | S | `FrameStill` exists. Android: Edit → Save frame as photo, rendered like the export (wave 1). |
| Social safe-zone guides | Has | Has | — | |
| Teleprompter, in-app camera | Missing | Missing | L | Outside Edit; the camera lives in the Suite |

## 2. Speed

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Constant speed 0.1–10×, pitch kept | Has | Has | — | |
| Speed curves (presets + custom graph) | Has | Has | — | |
| **Smooth slow-mo (frame interpolation)** | Missing | Missing | XL | Needs a model choice (server job like denoise, or on-device). The "Coming soon" switch was removed in WS8. Mac: Still shows a disabled "Coming soon" switch; to remove to match Android |
| Speed on audio-only clips | Missing | Missing | M | The contract says audio plays at 1×; needs a contract change. |
| Set the duration (speed computed) | Missing | Missing | S | |

## 3. Transitions

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Transitions (cut, fade, dip to black/white, slide, push, zoom, whip, spin, glitch) | Has | Has | — | 9 types, own design |
| Duration, apply to all | Has | Has | — | |
| More transition types | Partial | Partial | M each | Functional, but the value is in a curated set: **Content** |
| Transitions on overlay tracks | Missing | Missing | M | |
| Clip in/out animations (video) | Missing | Missing | M | Text and images have them |

## 4. Text, captions and animation

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| **Add plain text** | Has | Has | S | Only through hook templates. "Add text" plus a style editor is needed. Mac: Add text at the playhead. Android: Text → Add text at the playhead (wave 1). |
| **Text styling** (font, colour, stroke, shadow, background, spacing, size) | Has | Partial | M | The model has all of it; the UI only edits the text itself. Mac: Font, colour, weight, size, align, outline, box, upper case; no outline colour, shadow or spacing. Android: Font, weight, size, colour, alignment, spacing, capitals, outline, shadow, box (wave 1). |
| Fonts library | Partial | Partial | M | Six bundled families. More fonts: **Content** (open licences, e.g. OFL, are an option). Mac: Same six families |
| Import own fonts | Missing | Missing | M | |
| Text templates / hooks | Has | Has | — | 10 hooks; more is **Content** |
| In/out text animations | Has | Has | S | The model has 7 kinds; there is no picker. Mac: Animate panel. Android: In / out picker with lengths (wave 1). |
| Loop animations | Missing | Missing | M | |
| Keyframed text | Has | Has | S | Engine yes; the Transform panel works on text, but there is no text selection on the phone timeline lane yet. Android: The Transform panel acts on the selected text (wave 1 fixed it moving the clip). |
| Auto captions | Has | Has | — | Server helper |
| Caption styles (word pop, karaoke, box, minimal, highlighter, neon) | Has | Has | — | |
| Caption language choice | Missing | Missing | S | Server parameter |
| Translated / bilingual captions | Missing | Partial | M | Server job (LLM). Mac: Translate on the Mac (macOS 15, on-device, WS9); not bilingual |
| Edit caption text (fix a word) | Partial | Has | S | You can cut words but not retype them. Mac: Double-click a word |
| Filler and silence removal, edit by transcript | Has | Has | — | |
| Text-to-speech voice-over | Missing | Missing | L | Needs a TTS vendor decision. Voices are **Content**. |
| Lyric captions | Missing | Missing | L | |

## 5. Audio

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Clip sound lane, detach / extract audio | Has | Partial | — | WS8. Mac: Sound lane with waveform and mute; no detach |
| Extract audio from another video | Missing | Missing | S | Add another take's sound only |
| Volume, mute, fade in/out | Has | Has | — | Mac: Up to +6 dB (fixed in WS9) |
| Volume keyframes | Has | Partial | S | Engine has `volume` keys; no UI. Mac: Engine only. Android: ◆ next to Volume; the slider sets the key at the playhead (wave 1). |
| Auto-ducking under voice and speech | Has | Has | — | The research found no confirmed ducking in the other apps; MUSE leads here |
| Beat detection, beat marks, snap to beats | Has | Has | — | |
| Manual beat marks (tap) | Missing | Missing | S | |
| Voice effects (warm, radio, phone, deep) | Has | Has | — | 4 effects. More character voices: M. |
| Noise reduction, voice enhance | Has | Has | — | |
| Vocal / instrumental separation | Missing | Missing | L | Server model |
| Volume normalisation | Missing | Missing | M | |
| Record voice-over | Has | Has | — | In-app recorder (WS8). Mac: Mac microphone |
| Recording over playback (hear the video while recording) | Missing | Missing | S | Needs headphones handling |
| **Music library** | Missing | Missing | M (function) | **Content.** Licensing is the real cost. `add_music` refuses `library` today. |
| **Sound effects library** | Missing | Missing | M (function) | **Content** |
| AI music / generative SFX | Missing | Missing | XL | Model and vendor decision |
| Audio loop | Missing | Missing | S | |

## 6. Effects, filters and adjustments

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Looks / filters with intensity | Has | Has | — | 32 original looks. More is **Content**, which MUSE can make itself (`lookpack.ts`). |
| .cube LUT import | Has | Has | — | |
| Exposure, contrast, saturation, temperature, highlights, shadows, grain | Has | Has | — | |
| Tint | Missing | Missing | S | |
| Vignette, sharpen, halation, light leak, chromatic aberration | Partial | Partial | S | Engine `look` has them; there are no sliders. Mac: Engine only |
| Curves | Partial | Partial | M | Engine has curves; no editor. Mac: Engine only |
| HSL (per-hue) | Missing | Missing | L | New engine stage (all three platforms) |
| Auto adjust | Missing | Missing | M | |
| Video effects library (glitch, blur, retro, …) | Missing | Missing | L | **Content** plus GL effects |
| Body and face effects | Missing | Missing | XL | Segmentation and tracking; mostly **Content** |
| Adjustment keyframes | Missing | Missing | M | |
| AI restyle (generative) | Missing | Missing | XL | MUSE's Suite does generation. Re-styling an edit is a model question. |
| HDR editing / export | Missing | Missing | L | |

## 7. Keyframes

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Position, scale, rotation | Has | Has | — | Mac: Sliders set the key at the playhead once keyed (fixed in WS9) |
| Opacity | Has | Has | S | Engine yes; no button. Android: Transform → Opacity with ◆ (wave 1). |
| Volume | Partial | Partial | S | See Audio. Mac: Engine only |
| Look / adjust / mask / crop keyframes | Missing | Missing | M each | |
| Easing choice | Has | Has | S | Engine has 5 eases; the UI always uses ease-in-out. Mac: Linear, in-out, ease out, hold. Android: Linear, ease in, ease out, smooth, hold (wave 1). |
| Keyframe list / move / delete on the timeline | Missing | Partial | M | Engine has `remove_keyframe`. Mac: Delete at the playhead, previous / next key (WS9); no timeline list |

## 8. Masks, chroma key and background removal

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Shape masks (linear, mirror, circle, rectangle, heart, star), feather, size, invert | Has | Has | — | |
| Mask position / rotation on the picture (drag) | Partial | Partial | S | Model yes; sliders only for size and feather. Mac: Sliders for position (WS9), size, rotation; no drag on the picture |
| Custom / pen mask | Missing | Missing | L | |
| Chroma key (green / blue, strength, edge, spill) | Has | Has | — | Controls added in WS8. Mac: Softness and spill added in WS9 |
| Chroma colour picker (eyedropper) | Missing | Missing | S | Mac: Colour swatch only |
| Background removal, tap what to keep | Has | Has | — | Server helper |
| Refine the cut-out with a brush | Missing | Missing | L | |
| Generative background replacement | Missing | Missing | XL | |

## 9. Overlays / PiP and blending

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Overlay video / PiP; add another take to the end | Has | Has | — | Fixed in WS8 |
| Overlay photos / images | Partial | Has | S | The model has image items; the phone can't pick a photo yet. Mac: Import picture (WS9) |
| Opacity | Has | Has | S | Model yes; no slider. Android: Transform → Opacity with ◆ (wave 1). |
| **Blend modes** (multiply, screen, overlay, soft light, …) | Partial | Missing | M | New compositor mode (GL / Core Image) and a contract field. Android: Contract and reference done (wave 1); Android rendering needs a custom compositor (L), no control until then. |
| Move an overlay to the main track and back | Missing | Missing | S | |
| Split-screen layouts | Missing | Missing | M | |
| Motion tracking (text or sticker follows an object) | Missing | Missing | XL | Tracker model |

## 10. Canvas and ratio

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| 9:16, 1:1, 4:5, 16:9 | Has | Has | — | |
| More ratios (4:3, 2.35:1) | Missing | Missing | S | |
| Background colour | Has | Partial | S | `canvas.background` exists; no picker. Mac: Engine only. Android: Ratio → Background (wave 1). |
| Background blur fill | Has | Missing | M | Android: Ratio → Blur of the clip (`canvas.fill`, wave 1). |
| Fit / fill per clip | Has | Partial | S | Model `fit`; no toggle. Mac: Engine only. Android: Ratio → This clip: Fill the frame / Whole picture (wave 1). |
| Auto reframe (faces) | Partial | Has | M | Re-centring on ratio change exists; face-aware reframe is in the spec but not on Android. Mac: Vision faces on a ratio change |

## 11. Stickers

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Sticker / GIF / emoji library | Missing | Missing | M (function) | **Content** |
| Own image or cut-out as a sticker | Missing | Partial | M | Uses the image items and the matte. Mac: Own pictures (WS9); a cut-out isn't a sticker yet |
| Sticker animation and keyframes | Partial | Has | — | Comes with image items |

## 12. Templates

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Template library (swap in your media) | Partial | Partial | L | "Recreate an edit" (recipes) is the MUSE take on this. A browsable library is **Content**. Mac: Recreate an edit |
| Beat-synced auto-cut to a song | Missing | Missing | M | Beats engine exists |
| Save your own edit as a template / style kit | Missing | Missing | M | |

## 13. AI features

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| Auto captions, cut silences and fillers, denoise, background removal, beats | Has | Has | — | |
| Claude edits the project (shared session) | Has | Has | — | Others' "AI assistant" equivalent; MUSE's is deeper |
| Auto-edit / AutoCut from clips and music | Missing | Missing | L | Claude plus beats could drive it |
| Long video to shorts | Missing | Missing | L | |
| Stabilisation | Missing | Missing | L | Server or on-device |
| Enhance / upscale | Partial | Partial | — | The Suite has upscale for takes; not in Edit |
| Relight, retouch / beauty | Missing | Missing | XL | |
| Text-to-speech | Missing | Missing | L | See Text |
| Frame interpolation | Missing | Missing | XL | See Speed |

## 14. Export

| Feature | Android | Mac | Size | Notes |
|---|---|---|---|---|
| 720p / 1080p / 4K, 24/30/60 fps, H.264 / HEVC | Has | Has | — | Mac: Export check in Mac CI (WS9) |
| Size estimate | Has | Has | — | |
| Captions burnt in or .SRT | Has | Has | — | Mac: Save to Library always burns them in (WS9) |
| Label as AI-generated | Has | Has | — | Sent with the version (fixed in WS8). Mac: Sent with the version (WS9) |
| Content Credentials (C2PA) | Missing | Missing | L | Signing needs a certificate decision. The "Coming soon" switch was removed in WS8. Mac: Still a "Coming soon" switch; to remove to match Android |
| 2K, bitrate choice | Missing | Missing | S | |
| HDR export | Missing | Missing | L | |
| Share straight to TikTok / IG / Shorts | Partial | Partial | — | MUSE Socials (posting) |
| GIF / audio-only export | Missing | Missing | S each | No competitor confirmed either |
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
