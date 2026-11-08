# Android Edit audit

_WS8, 2026-11-08._ The owner tried Edit on a phone (a 15 s 9:16 take) and found it wasn't usable for serious editing.

This audit checks every control in the Android Edit screen, phone and tablet, end to end. For each one it asks:

- Does pressing it change the **project**?
- Does the change reach the **preview**? The preview is a CompositionPlayer built from `planRender(project)`, so anything that reaches the plan is shown.
- Does it reach the **export**? The export runs Media3 Transformer on the same plan, after `exportProject(project, settings)`.

Status is given **before** this work and **now**:

- **working**: changes the project, preview and export correctly.
- **broken**: it is there, but something in the chain doesn't happen.
- **placeholder**: it shows, but does nothing.

There are no placeholders left in Edit.

Tests are in `app/src/test/.../screens/edit/`:

- `EditTimelineTest` (**T**): timeline and sound.
- `EditAuditTest` (**A**): one test per panel. Each drives the editor's state machine, asserts the project, checks it is valid, and builds the render plan the preview and export use.
- `EditSuiteControllerTest` (**C**): the existing tests.

Rows that show "server" use a paid or free AI helper. Their results come back as project changes. They are tested against the demo backend's results, not the real models.

## A. Reported bugs (fixed first)

| # | What | Before | Now | Test |
|---|---|---|---|---|
| 1 | **Play icon on thumbnails.** Suite → Recent takes put it bottom-centre, over the label area. Other grids used five different sizes and styles. | broken | One `PlayBadge`: always centred on the poster, 28 dp on posters under 100 dp wide, 36 dp elsewhere. Now used in Suite recent takes, the composer's recent row, Result's take strip, the Library pager, the video stage clips and the clip placeholder. | screenshot `suite_*_hub` |
| 2 | **Timeline drag.** Inside the canvas, the pinch detector took the one-finger drag before the scrub detector saw it, so the timeline barely moved and a cut couldn't be placed. | broken | One gesture handler. One finger scrubs, two fingers pinch (zoom 8–480 dp/s around the playhead), and a tap selects. A fling coasts with Android's own decay. Vertical drags scroll the lanes when they don't all fit. | T |
| 2 | **Frame-accurate preview.** Seeks fired on every move and only for jumps over 0.05 s (more than one frame). | broken | The timeline draws from its own state every frame and reports to the editor about 30 times a second. The preview's seeks are conflated, so only the latest waits while a frame decodes. When the finger lifts, the playhead lands on the nearest frame (`snapFrame`) and the preview seeks there. Anything more than half a frame away is sought. The time reads in hundredths. | T `scrubPausesMovesThePlayheadAndEndsOnAFrame` |
| 2 | **Playback.** The timeline jumped in 50 ms steps while playing. | broken | It moves with the frame clock between the player's reports. | (visual) |
| 2 | **Start state.** At 0 the clip starts under the centre playhead, with an empty half screen to its left. | as designed but unclear | Kept, since scrubbing now works. The area before 0 and after the end is shaded, the ruler is pinned, and the playhead has a head. | screenshot `edit_*_take_start` |
| 2 | **Split at the playhead.** It was two taps deep (Edit → Split). | working, hard to reach | A Split button in the transport, one tap. The split lands on a frame. | T, A |
| 2 | **Select and trim.** You could tap to select, but there were no trim handles. | missing | The selected main clip shows handles at both edges. Dragging one trims the clip in or out, and the whole drag is one undo step. | T `selectThenTrimByTheEdgeIsOneUndoStep` |
| 2 | **Performance.** | — | One Canvas. Only on-screen frame tiles and waveform bars are drawn. Text layouts are cached (96). Gesture state is outside composition, so scrubbing redraws without recomposing. | — |
| 3 | **Clip's own sound.** It wasn't shown. | missing | A **Clip sound** lane under the video shows the real waveform (decoded on the phone by `WaveformDecoder`, peaks every 1/50 s). The waveform is scaled by the clip's volume and fades, with fade ramps drawn on it. A muted clip shows "Muted", a silent source shows "No sound", and a detached clip shows "Sound detached". Tapping the lane selects the clip and opens Audio. On tablet, the lane's header mutes the track. | T `theClipsSoundHasItsOwnLaneUnderTheVideo` |
| 3 | **Detach audio.** | missing | Audio → **Detach audio** moves the clip's sound to its own clip on a "Detached sound" lane (a voice track, so music ducks under it). It keeps the same source times, volume, fades and voice settings, and the video clip goes silent. It is refused, with a reason, for silent clips, muted clips and clips not at 1× (audio clips play at 1×). | T `detachAudio…`, `detachIsRefused…` |
| 3 | **Sound on/off.** | missing (only a volume slider) | Audio → **Sound** switch, for a clip or an audio clip. | T, A |
| 3 | **Music and voice-over lanes.** | working; the waveforms were invented | Real waveforms, item names on the lanes, and the beat marks. | — |

## B. Every control

### Top bar, preview and transport (phone)

| Control | Before | Now | Test |
|---|---|---|---|
| Close | working | working | — |
| Claude (owner) | working | working | `EditSessionSyncTest` |
| Export (opens the export sheet) | working | working | A |
| Safe area chip (TikTok → Reels → Shorts → off; a guide only, never exported) | working | working | A `transport…` |
| Split at playhead | — | new, working | T, A |
| Play / Pause | working | working | A |
| History (owner, session) | working | working | `EditSessionSyncTest` |
| Undo / Redo | working | working | A `editPanel…` |
| Fullscreen | working | working | A |
| Timeline: drag, fling, pinch, tap, trim handles, ruler tap | broken | working | T |
| Timeline "+" (opens Overlay) | working | working | — |
| Tool row: Edit, Audio, Text, Captions, Effects, Filters, Overlay, Ratio | working | working | screenshots |

### Edit panel

| Control | Before | Now | Test |
|---|---|---|---|
| Split | working | working | A |
| Delete (selected item; the last main clip is refused) | working | working | A |
| Duplicate | working | working | A |
| Speed → / Transform → / Transition → | working | working | — |
| Ripple | working | working | A, C |
| Snap cuts to beats | working | working | A `musicVoiceOver…` |

### Speed

| Control | Before | Now | Test |
|---|---|---|---|
| Normal / Curve tabs, speed slider, 0.5×–3× chips | working | working | A |
| Curve presets (Montage, Hero, Bullet, Flash in / out, Custom) | working | working | A |
| Curve graph: drag points, double-tap to add | working | working | A |
| "Smooth slow-mo (AI) · Coming soon" switch | **placeholder** | **removed**. No frame-interpolation model has been chosen, so this is a parity item for the owner (`plans/edit-parity.md`). | A `noComingSoon…` |

### Transform, crop and keyframes

| Control | Before | Now | Test |
|---|---|---|---|
| Position x / y, Scale, Rotation sliders | working | working | A |
| ◆ keyframe per property, at the playhead | working | working | A |
| **Crop**: tablet toolbar "Crop" opened Transform, which had no crop | **broken** | Crop sliders for left, right, top and bottom (0–45 %) and Reset crop. They go into the plan's `look.crop`, so the GL Crop effect applies them in preview and export. | A `transformKeyframesAndCrop` |

### Audio

| Control | Before | Now | Test |
|---|---|---|---|
| Sound on/off | — | new, working | T, A |
| Detach audio | — | new, working | T |
| Volume (−24…+6 dB) | working | working | A |
| Fade in / Fade out | working | working | A (the envelope starts silent) |
| Auto-duck music, Attack / Release | working | working | A |
| Noise reduction (server) | working | working | A |
| Voice enhance, Voice effect chips | working | working | A |
| Beat markers (free server job), All / Strong, Snap | working | working | A |
| Music from uploads | working | working: the file is uploaded, then its waveform is decoded | A (`AddAudio`) |
| **Record VO** | **broken**. It fired the phone's "record sound" intent, which has no app behind it on most current phones ("No voice recorder on this phone"). | Records inside the editor with `MediaRecorder` (AAC). It asks for the microphone on first use (`RECORD_AUDIO` added). The button turns into "Stop recording", and the take lands on the Voice-over lane where recording started. | A (`AddAudio` at the recording's start) |

### Text and captions

| Control | Before | Now | Test |
|---|---|---|---|
| Hook templates (add at the playhead), text field for the selected text | working | working | A |
| Auto-captions (server) | working | working | A |
| Caption styles, Word-by-word highlight, Position | working | working | A |
| Font, Text and highlight colours | working | working | A |
| Words per caption | working | working | A |
| Words tab: tap a word to cut it, Remove fillers | working | working | A, C |
| Cut silences (free server job) | working | working | A |

### Effects

| Control | Before | Now | Test |
|---|---|---|---|
| Transitions: Cut, X-fade, Zoom, Whip, Slide, Flash, Glitch, Spin, Dip to black; Duration; Apply to all cuts | working | working | A |
| Mask shapes, Feather, Size, Invert | working | working | A |
| **Chroma key** | **placeholder**. It showed a colour and "Off" with no way to turn it on, although the engine renders it (`ChromaKeyEffect`). | An on/off switch, Green screen / Blue screen, Strength, Edge softness and Spill. | A `masksAndChromaKey` |
| Remove background, Tap what to keep (server) | working. While the server says it's unavailable it reads as a plain line, not a button. | working | C |

### Filters

| Control | Before | Now | Test |
|---|---|---|---|
| Look categories, 32 looks with thumbnails, Original | working | working | A |
| Intensity, Apply to all clips | working | working | A |
| .cube import | working | working | C |
| Adjust: Exposure, Contrast, Saturation, Temperature, Highlights, Shadows, Grain | working | working | A |

### Overlay and ratio

| Control | Before | Now | Test |
|---|---|---|---|
| **Overlay (PiP)** | **broken**. A take added during editing never had its file fetched (files were fetched only when the editor opened), so it was dropped from the preview and the export. | The take's file is fetched as soon as it is added, then the preview is rebuilt. | A `overlay…` |
| **Add to end** | **missing**, although the panel's copy promised it | Adds the take, whole, as a new clip at the end of the video. | A `overlay…` |
| Music from uploads | working | working | — |
| Ratio 9:16 / 1:1 / 4:5 / 16:9 | working | working | A |

### Export

| Control | Before | Now | Test |
|---|---|---|---|
| Shape, Resolution 720p/1080p/4K, FPS, H.264/HEVC | working | working | A `exportSettings…` |
| Captions: Burn in / .SRT file | working | working (.SRT goes to Downloads/MUSE with "Export") | A |
| **Label as AI-generated** | **broken**. The switch was never sent with the saved version. | It is sent as `aiLabel: true` with the version (`POST /v1/takes/{id}/versions`). It is never sent when off. | A `savingAVersion…` |
| "Content Credentials (C2PA) · Coming soon" | **placeholder** | **removed**. Signing isn't built. It is a parity item for the owner. | A |
| Save to Library / Export (also to the phone) / Cancel | working | working | C (demo save), A |

### Tablet only

| Control | Before | Now | Test |
|---|---|---|---|
| Shape segmented, Hook ideas, Show/Hide inspector, Export | working | working | screenshots |
| Safe area segmented, Go to start / end, Play, History, Fullscreen | working | working | — |
| Toolbar: Split, Delete, Speed, Keyframe, Undo/Redo, Ripple, Cut silences, Snap to beat, Add, Zoom −/+ | working | working | A |
| Toolbar **Crop** | **broken** (no crop control) | opens Transform with Crop | A |
| Track headers: mute (sound lanes, including Clip sound) and hide (picture lanes) | working | working; the Clip sound lane now carries the main track's mute | T |

## What the tests can't cover

Robolectric has no hardware codecs, so these have no automated test:

- Media3 Transformer encoding.
- MediaCodec waveform decoding.
- The microphone.

The export test therefore checks everything up to the encoder:

- `exportProject`, then the render plan.
- Canvas, fps, captions burnt in or not.
- The saved version's request, with `aiLabel`.

On a phone, check scrubbing smoothness, the waveform and recording a voice-over by hand.
