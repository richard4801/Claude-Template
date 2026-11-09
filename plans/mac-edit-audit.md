# Mac Edit audit: does every control work end to end?

_WS9 (Mac Edit), 2026-11-08. Owner: "we can't perform serious edits if some things are just placeholders." Every control of the
Mac Edit suite (`mac/Muse/Views/Edit/**`, `mac/Muse/App/Edit/**`, `MuseCore/Edit/**`) was traced from the button to the
project (EditSuiteState), the live preview (EditV2Engine → EditV2Compositor), and the export (the same engine through
AVAssetExportSession, then the upload and the saved version)._

**Status per control**: **working** = changes the project, the preview and the export correctly; **fixed** = it was broken
or missing, and this branch fixes it; **placeholder** = shown but does nothing (fixed); **removed** = a placeholder for a feature that needs an owner decision (a
paid model or a vendor), taken out until it is built (owner, 2026-11-08).

**How it's proven**:
- **Project state**: `MuseCoreTests/Edit/EditSuiteControlsTests.swift` runs each control's own EditSuiteState call and checks
  the project it leaves, that it is still valid for the server, and that one undo restores it (24 tests, also run on Linux).
- **Preview and export**: Mac CI's new step **"Edit operations and export check"** (`SnapshotRunner+EditOps.swift`,
  `edit-ops-check.txt`) runs the operations through the real editor session on generated red/blue takes with a known tone,
  probes the live preview's frame after each one, then exports three short projects with the session's own Export and
  checks the files: length, size, frame rate, a pixel, the sound level at +6 dB and −12 dB, silence when muted, and the AI
  label on the saved version.
- **No crash**: the existing click-through ("Edit check") still presses every control.

## Top bar

| Control | Status | Notes |
|---|---|---|
| Close the editor | working | |
| Aspect ratio 9:16 / 1:1 / 4:5 / 16:9 | working | Canvas changes, clips re-framed on faces (Vision). Test + preview probe (square render). |
| Claude (owner) | not in scope | WS2 (Claude in the Suite). |
| Templates | working | Opens the media panel on Templates. |
| Hook ideas | working | Opens Captions & hooks. |
| Show inspector | working | |
| Export (⌘E) | working | See Export below. |

## Media panel

| Control | Status | Notes |
|---|---|---|
| Tabs (Takes, Uploads, Music, Text, Stickers, Templates) | working | |
| Takes: double-click → end, right-click → overlay | working | Preview probe: the added take shows. |
| **Uploads** | **fixed** | Only listed sounds; videos and pictures from the Mac couldn't come in at all. Now: Import video or picture (upload → add to the end / as overlay / picture at the playhead), and the list adds them again. Server: editor uploads accept PNG/JPEG/WebP/HEIC (≤ 30 MB). |
| Music: Import music, Import sound, Add as music / voice-over / sound effect | working | |
| Text: Add text, hooks | working | |
| **Stickers** | **fixed** (placeholder) | Was "Sticker packs are coming soon." Now imports your own pictures (PNG keeps transparency) onto the Stickers row and lists them. A sticker *library* is licensed content (parity doc, section B). |
| Templates: hook templates, caption styles | working | |
| **Import** (bottom) | **fixed** | Always imported a sound as a voice-over, whatever the tab. Now follows the tab: video/picture on Takes and Uploads, picture on Stickers, song on Music, voice-over elsewhere. |
| Record VO / Stop recording | working | Needs the microphone; adds to the Voice row. |
| Hide media | working | |

## Viewer

| Control | Status | Notes |
|---|---|---|
| Safe area Off / TikTok / Reels / Shorts | working | Guide only (never in the export). |
| **Fit · 100%** | **fixed** | Always said 100 % and "Actual" could only shrink the picture. Now "Fit · 43 %" (the real scale) and "Actual size · 100 %" (one canvas pixel per screen pixel, cropped to the viewer). |
| Back to the start, Play/Pause, Forward one second | working | |
| Mute the preview | working | Preview only, by design. |
| **Full screen** | **fixed** | Made the whole app window full screen. Now the preview alone fills the screen; Esc leaves, space or a click plays/pauses. |

## Timeline

| Control | Status | Notes |
|---|---|---|
| Split (S) | working | Main clip or the selected item; snaps to beats when on. Test + preview. |
| Delete (⌫), Ripple | working | Ripple pulls the other rows with a deleted main clip. |
| Speed | working | Opens the Speed panel. |
| **Keyframe** | **fixed** | Added a *scale* key only. Now keys position, scale, rotation and opacity at the playhead (one undo step). |
| **Crop** | **fixed** | Opened the Video tab, which had no crop. The Video tab now has a Crop section (each side 0–45 %, Reset). Disabled for text. |
| Undo / Redo (⌘Z, ⇧⌘Z) | working | 100 steps; drags are one step. |
| Cut silences | working | Free; transcript pauses first, else the silence job. |
| Snap to beat | working | |
| Zoom −, slider, + | working | |
| Row: mute / hide / lock | working | Hidden rows leave the render plan (preview probe: black), muted rows lose their sound. |
| Ruler drag, click to seek and select | working | |
| Drag a block (text, overlay, sticker, sound) | working | |
| **Drag a main clip** | **fixed** | Main clips couldn't be reordered at all. Now drag a clip over the others to move it (preview probe: the order changes). |
| **Trim handles** | **fixed** | The start handle of a main clip measured each drag event from the already-trimmed clip, so the trim ran away (a 1 s drag cut several seconds). Trims now measure from where the drag began. |
| Transition diamond | working | Selects the clip and opens Video. |
| Make captions (empty Captions row) | working | AI helper (priced; asks first). |

## Inspector

### Captions
| Control | Status | Notes |
|---|---|---|
| Make captions | working | |
| 8 style tiles | working | Neon's glow now follows the highlight colour. |
| Font, Text / Highlight / Outline colour, Size, Position, Word-by-word, Upper case | working | Test: every one reaches the caption track. |
| Edit the words | working | Opens Captions & hooks. |

### Text
| Control | Status | Notes |
|---|---|---|
| Add text at the playhead, Hook ideas, text field + Apply | working | Preview probe: the text shows. |
| Font, colour, weight, size, align, outline, background box + colour, upper case | working | |
| **Duration** | **fixed** | Could run a text into the next one on its row; the project then broke the server's rules and Export was blocked with a cryptic message. Every change is now checked first: one that would make the project invalid is refused with the reason ("That doesn't fit there · it would overlap the next item on its row"). |

### Video
| Control | Status | Notes |
|---|---|---|
| **Position X/Y, Scale, Rotation, Opacity** | **fixed** | Once a property had keyframes the slider changed the ignored static value: it moved and the picture didn't. Sliders now show the value at the playhead and set a key there. Preview probes: scale, opacity, fade-in by keys. |
| **Keyframe diamonds** | **fixed** | Could only add. Now add, or remove the key at the playhead; Previous key / Next key move the playhead. |
| Ease | working | Shown when there are keys. |
| Looks (32), Intensity, .cube import | working | Preview probe: colour changes. |
| Adjust: Exposure, Contrast, Saturation, Temperature, Highlights, Shadows, Grain | working | Preview probe: exposure. |
| Mask shapes, Feather, Size, Rotation, Invert | working | Preview probes: inside/outside, inverted. |
| **Mask position** | **fixed** (missing) | The mask could only be centred: Position X / Y. |
| Chroma key on/off, key colour, Strength | working | |
| **Chroma Softness, Spill** | **fixed** (missing) | In the engine, no control. |
| Remove background, Pick what to keep | working | Paid AI helper; asks with the price. |
| Transitions (8 + Dip to black), Duration, Apply to all cuts | working | Preview probe: cross-dissolve mixes the two clips. |

### Audio
| Control | Status | Notes |
|---|---|---|
| **Volume** (−30 … +6 dB) | **fixed** | Anything above 0 dB played and exported at 0 dB (AVAudioMix stops at 1×). The gain above 1× now goes through the lane's audio tap. Export check: +6 dB doubles the level, −12 dB is a quarter. |
| Fade in / out, Mute | working | Export check: muted is silent. |
| Noise reduction | working | Paid AI helper. |
| Voice enhance, Voice effect | working | Audio tap (preview and export). |
| Auto-duck, Attack, Release, Duck to | working | Test: the music dips under the voice-over. |
| Detect beats, Every / Strong beats, Snap cuts to beats | working | |

### Speed
| Control | Status | Notes |
|---|---|---|
| Constant / Curve, Speed slider, 0.25×–4× chips, curve editor, presets | working | Preview probe: 2× halves the length. |
| Smooth slow-mo (AI frame interpolation) | **removed** | Was a disabled "Coming soon" switch. Removed (owner: no placeholders); comes back when a frame-interpolation model is chosen (XL, being priced). |

### Animate
| Control | Status | Notes |
|---|---|---|
| In / Out chips, Duration (text, hooks, stickers) | working | |

## Captions & hooks

| Control | Status | Notes |
|---|---|---|
| Transcript: click to seek, ⇧-click to pick, double-click to fix, ⌫ / Cut N words | working | Cuts the video (jump cuts). |
| Remove fillers, Cut silences | working | Free. |
| **Translate…** | **fixed** (placeholder) | Was disabled "Coming soon". Now translates every caption sentence on the Mac with Apple's on-device translation (macOS 15+; free), keeping each sentence's timing; undo brings the original back. |
| Caption style, hook templates, play, Transcript / Timeline, Done | working | |

## Export sheet

| Control | Status | Notes |
|---|---|---|
| Shape | working | |
| Resolution, Frame rate, Format | working | Export check: 720 × 1280 at 30 fps, 3 s. |
| **Captions: .SRT file** | **fixed** | With "Save to Library" the captions went nowhere (not burnt in, no file). The Library's video now always has them burnt in; the .srt goes next to an exported file. |
| **Label as AI-generated** | **fixed** | Did nothing (the message said the label would come when posting, but nothing kept it). It's now saved with the version (`aiLabel`, which the server already accepted), and posting that version starts with the AI label on. |
| Content Credentials (C2PA) | **removed** | Was a "Coming soon" switch. Removed (owner: no placeholders); comes back with signing (certificate, XL, being priced). |
| Save to Library, Export, progress, Cancel | working | Export check runs the real path (render → upload → version). |

## Keyboard

Space (play), ← / → (one frame), S (split), ⌫ (delete), J / K / L (shuttle; reverse steps back 0.5 s because composed
items can't play backwards), ⌘Z / ⇧⌘Z, ⌘E: working. Desktop shortcuts the leading editors also have (I/O marks, ⌘B,
copy/paste/duplicate, nudge, zoom to fit…) are listed in `plans/edit-parity.md` (section B) and wait for the owner's priorities.

## Parity wave 1 (owner, 2026-11-08: build every functional parity row, in waves)

Green in Mac CI run 42541190202 (MuseCore tests, build, click-through, Edit operations and export check with pixel probes).

| Feature | Where on the Mac | Proven by |
|---|---|---|
| Reorder clips, move items, trim handles on every item | Drag on the timeline | EditSuiteControlsTests; ops check (reorder) |
| Add text, style editor (outline colour and width, shadow, letter spacing, line height), animation picker | Text and Animate panels | EditSuiteControlsTests |
| Opacity and volume keyframes, easing | Transform panel ◆; Audio ◆ next to Volume | EditSuiteControlsTests; ops check (fade-in by keys, volume keys) |
| Freeze frame (`holdSec`) | Timeline → Freeze frame; length in Speed or by dragging its edges | Fixtures (wave1.hold) + tests; ops check (held frame, +1 s) |
| Mirror (`flipX` / `flipY`) | Transform → Mirror / Flip | Fixtures (wave1.corners); ops check |
| Extract frame | Viewer → Save this frame as a picture | Ops check (PNG of the edit) |
| ±1 frame | ‹ › in the transport, ← / → | |
| Blend modes (`blend`) | Video → Blend on overlays (Core Image kernel, reference formulas) | Fixtures (wave1.blend); ops check (multiply, screen) |
| Background colour / blur fill (`canvas.fill`), Fill / Fit | Video → Background; Transform → Frame | Fixtures (wave1.blurFill); ops check (blur and colour at the corner) |

The contract (server `model.ts`, ops, fixtures) is WS8's 60bff55; the Mac port is byte-identical on the fixtures.

## Left for the owner

1. **Smooth slow-mo**: pick a frame-interpolation model (paid) or accept a free non-AI "frame blending" mode instead (switch removed until then).
2. **C2PA**: a signing certificate/vendor (switch removed until then).
3. **Sticker and music libraries**: licensed content (parity doc, licensing section).
