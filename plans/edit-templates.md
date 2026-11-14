# Edit templates: effects and transitions in one click (plan + design)

_Planning worker, 2026-11-14 (revised the same day once the pack arrived). Owner-approved goal:_
- _A template library in Edit for effects and transitions. It is not photo presets and not caption/look kits._
- _A template goes on any clip in one click, on the Mac and on Android._
- _MUSE Claude can save new templates into it._
- _It is seeded with the 27 templates MUSE Claude made (report ci_d4cc38758998)._

_This is a plan and design only. The one piece of code is the intake in §1, which is live on prod._

## Mockups
In `plans/design/edit-templates/`, rebuilt with `src/build.mjs` (the repo's fonts, Phosphor icons, no network).
- `1-mac-library-effect-light.png`: Mac, theme A. The library, with caption styles kept as one section, and **Window opens the next shot** previewed on the cut at 0:21.7. The panel shows shape, lead, white line and entrance wash, then "Apply to cut at 0:21.7".
- `2-mac-library-transition-dark.png`: Mac, theme B. A template that is **not ready** (Glass shatter): the reference clip plays, with the reason, and offers "Ask Claude to make it for this cut".
- `3-android-sheet-light.png`: Android. The bottom-sheet grid (Effects), then **RGB split hit** settings, then "Apply to the cut into clip 3".
- `4-saving-and-states-light.png`:
  - "Save as template" (Punch-in) and Claude's "saved" chat card.
  - Loading, empty, older app ("Negative hit needs the next MUSE update") and offline.

## Owner decisions (confirmed by the owner through the coordinator, 2026-11-14)
1. **Confirmed:** the new Templates library replaces Edit's current Templates bin tab (Mac `EditSuiteBin.swift:319`, caption styles today). Caption styles stay in it as one section and as the "Captions" filter.
2. **Confirmed:** finished-clip templates show from day one.
   - How it is built: the pack README says the finished clips contain the Icon edit's own film footage and are for reference only.
   - So on day one those tiles show as "Not ready": the reference clip plays, the reason is shown, and on the Mac there is "Ask Claude to make it for this cut". Claude adapts the pack's script to the person's shots.
   - They are not dropped onto other videos as they are. This follows the owner's answer; flagged to the coordinator in case the owner expected one-click Apply for those.
3. **Confirmed:** owner only for now, like the rest of Edit with Claude.

## 0. What the pack is
The coordinator confirmed it arrived. I read it with `template_pack_read` and `gaps_list` through the owner MCP; there were no DB reads.

**Pack `icon-storyboard` (`tp_42b9a9bc8571`):**
- **Manifest:** 27 templates.
- **Files:** 75 (README and scripts).
- **Media:** 54, of which 40 are previews and 14 are finals.
- **Missing previews:** `punch-in` and `contained-sound-ending`. Their tiles will use a live render.

**Each template's entry has:**
- what it does and its kind;
- its status, one of:
  - `generic`: the script works on any shot;
  - `native`: possible in MUSE by patch;
  - `bespoke`: works, but with this video's frames written into the script;
- the timing rule, the params a real template must expose, the layers from back to front, the scripts, the clip, the previews, and a "native" note saying what MUSE would need.

**Shared rules from the README:**
- Timing comes from the song: one stage per note, from `song_notes`.
- A window shows the shot it opens into, in place and unscaled, playing the 0.3 s before that shot's in-point.
- Every new layer enters washed toward white or deep blue for 2–3 frames: k 0.6, 0.3 (thin layers 0.9, 0.65, 0.35).
- Nine templates need a subject matte. The free Apple Vision lift was better than the paid run.

**The README's build order:**
1. The template store.
2. `window-open-next` with a shape list (covers 7 entries).
3. Text styles (frosted glass first).
4. Hit effects.
5. Local subject matte.
6. Audio keyframes.

**`gaps_list`:** 32 gaps, each asked for once. They match the pack. Extra ones not covered here:
- preview clip for Claude
- free track order
- edit-ops reference
- generative frame extend
- rounded-rect mask
- chroma key on images
- VFX overlays

**What the edit model already has** (shared `model.ts`, Kotlin and Swift ports):
- 12 effects, one per item.
- 18 transitions (kind + length only, no shapes).
- Keyframes on transform, opacity, volume, exposure/contrast/saturation/temperature/tint, the mask box (x, y, w, h, rotation, feather), vignette, grain and leak.
- 8 blends.
- Masks: linear, mirror, circle, rect, heart, star.
- `alphaMatte` (paid `remove_background`) and `text_behind` (paid).
- Freeze (`holdSec`).
- Video and image overlay tracks (16 tracks).
- `minItemSec` 0.05.

**What it lacks:**
- Keyframeable effect amount.
- Invert or difference in the apps.
- Text as a mask.
- Audio filter keyframes.
- Shape transitions.

**Two constraints:**
- **Server render.** The server's ffmpeg render **does not draw the `effect` field** and drops it silently.
- **Old apps.** Old apps decode effects, transitions and blends as closed enums, so new values need gates.

## 1. Intake (live on prod: `claude/template-pack-intake` 8f64eb1)
**Tools (owner only, free, MCP and chat):**
- `gaps_list {kind?, query?, limit?}`: every gap.
- `template_pack_send {pack, manifest?, files?, removeFiles?, media?}`: parts merge. Text files have credentials redacted. Media must be finished uploads of the studio.
- `template_pack_read {pack?, path?}`.

**Storage and tests:**
- Table `edit_template_packs`, migration 0037.
- Tests in `test/template-packs.test.ts`. The full suite passed: 1062 tests.

## 2. How a template is represented
A template is **one JSON spec** (`EditTemplate v1`). The **server expands it into ordinary edit ops** for a target: a clip, a cut, or each selected clip/cut/note.

**Why expand on the server:**
- The apps receive normal project items, so a template needs **no Kotlin or Swift model code** unless it uses a new primitive.
- Applying is one undoable change.
- Claude and both apps share one implementation.

**Levels**, which the spec states:

| Level | What it is | On any video? |
|---|---|---|
| **Live** | Changes to the target, plus keyframes in normalised time, plus added items. Added items can be **copies of the target's neighbours** (`$next`, `$prev`, with in-point maths), stills or sounds owned by the template, or text. Plus a transition. | Yes |
| **Live, paid matte** | Live, but it needs a subject matte. Today that is `remove_background` (priced on the Apply button). It becomes free once a local matte exists (P4). | Yes, at the matte's price |
| **Needs a new primitive** | Live once a missing value exists in model.ts and all three renderers, behind a gate. Older apps show "Needs update". | Yes, after the primitive |
| **Not ready (reference)** | Only the pack's reference clip. "Ask Claude to make it for this cut" has MUSE Claude on the Mac adapt the bespoke script to the person's shots and add the result as an overlay clip. That costs Claude time, not money. | Mac, per video, by Claude |

### Spec sketch
Server type in `src/editor/templates.ts`; it is not an app contract. This example is `window-open-next`.

```jsonc
{ "v": 1, "id": "window-open-next", "name": "Window opens the next shot", "kind": "transition", "target": "cut",
  "level": "live", "requires": [],                       // e.g. ["effect:invert"] → "Needs update" on older apps
  "params": [
    { "key": "shape", "type": "enum", "options": ["band", "column", "slats", "box"], "default": "box" },
    { "key": "lead", "label": "Opens before the cut", "type": "number", "unit": "s", "min": 0.1, "max": 1, "default": 0.3 },
    { "key": "line", "label": "White line", "type": "bool", "default": true },        // needs mask stroke (N2); hidden until then
    { "key": "wash", "label": "Entrance wash", "type": "enum", "options": ["white", "blue", "off"], "default": "white" } ],
  "add": [ { "track": "overlay", "asset": "$next", "in": "$next.in - $lead", "start": "$cut - $lead", "length": "$lead",
             "maskFrom": "shapes.$shape", "wash": "$wash" } ],
  "shapes": { "box": [ { "t": 0, "rect": [0.3, 0.24, 0.4, 0.3] } ], "band": [ … ], "slats": [ [ … ], [ … ], [ … ] ] },
  "preview": { "uploadId": "up_…" },
  "source": { "pack": "icon-storyboard", "templateId": "window-open-next", "by": "claude" } }
```

- **Shapes.** `.rects` files (`frame x y w h`) become hold-eased mask keyframes.
- **Slats.** One copy per slat, each on its own overlay track.
- **Entrance wash** is an expansion helper. It sets exposure keyframes (or temperature for blue) on an added item's first 2–3 frames with the README's k values.
- **Note times** come from `song_notes` / `detect_beats`, which already exist.
- **Storage.** Table `edit_templates`, migration 0038: id, studio, name, kind, target, level, spec jsonb, preview upload, source, by, version, timestamps.

## 3. Tools for Claude, routes for the apps
The names avoid `templates_*`, which means photo presets. Every description says "Edit effects and transitions; photo presets are templates_manage".

| Tool | Does |
|---|---|
| `edit_templates {query?, kind?, target?}` | The library, with level, params, "needs update" and previews. |
| `edit_template_save {name, kind, target, from?: {sessionId, itemIds, cutAt?}, spec?, previewUpload?}` | Saves from a selection or from a spec. From a selection it takes the target's effect, look, adjust, blend, mask and normalised keyframes, and the overlapping overlay and sfx items. Items that reuse a neighbour become `$next`/`$prev`. It returns the spec, so Claude can add params. Saving the same id makes a new version. |
| `edit_template_apply {sessionId, templateId, target: {itemId} \| {cutAfter} \| {each: "selected" \| "cut" \| "note-cut"}, params?, dryRun?}` | Expands and applies the template as one undoable change. `dryRun` returns ops plus a preview patch. Paid-matte templates go through the existing spend gate, with the price on the button. |
| `edit_template_delete {templateId}` | Removes a template. Edits keep their items. |

- **Routes:** `GET/POST /v1/editor/templates`, `POST /v1/editor/templates/:id/apply` (`dryRun` for the preview), `DELETE /v1/editor/templates/:id`.
- **Not-ready Ask Claude:** the Mac button opens the Claude chat with a prepared request (template id, the cut, the two shots). Claude reads the script with `template_pack_read`, adapts it, runs it locally, uploads, and adds the overlay.
- **Seeding:** Claude converts each pack template with `template_pack_read` → `edit_template_save`. Live specs go first (table below), the rest as "not ready" entries carrying their preview and reference clip.

## 4. The 27
Effort: **S** about a day (spec only), **M** 2–3 days (spec plus expansion logic), **L** a primitive across model + Kotlin + Swift + both shaders + ffmpeg + gate (about a week, one Mac CI run), **XL** a new subsystem.

**New primitives:**
- **N1:** `invert` and `rgbSplit {shiftPx}` effects, plus keyframeable effect amount.
- **N2:** mask stroke (white line).
- **N3:** free local subject matte with smoothing through time.
- **N4:** text as a mask over an overlay copy (frosted / negative letters).
- **N5:** `writeOn` text reveal.
- **N6:** audio `lowpassHz` keyframes.
- **N7:** image items down to 1 frame.
- **N8:** shatter transition.
- **N9:** tracked mask and anchors.

| # | id (pack status) | What it does | Level | Ops / primitive | Effort |
|---|---|---|---|---|---|
| 1 | `cutout-carry-over` (bespoke) | The subject keeps moving as a cut-out over the next shot for 9–15 frames | Live, paid matte | `$prev` overlay copy continuing past the cut, with `alphaMatte` (remove_background on that range), blue wash; free with N3 | M (+N3) |
| 2 | `flash-white` (generic) | 3-frame white flash on a hit | **Live** | Template-owned white still on an overlay, blend `add`, opacity keyframes 0.6 / 0.3 / 0.1 (hold) | S |
| 3 | `hit-negative` (generic) | First 3 frames as a negative with a colour split | Needs N1 | Split at in + 3 frames; `invert` + `rgbSplit` on the head piece | M after N1 |
| 4 | `hit-rgb-split` (generic) | Red/blue split, 28/16/8 px over 3 frames, on a cut | **Live** (close match), exact with N1 | Now: transition `glitch` 0.1 s at the cut. Exact: `rgbSplit` with amount keyframes | S / M |
| 5 | `multi-hit-split` (bespoke) | Split plus white lift on every cut of a burst | **Live** | #4 on each selected cut, plus exposure keyframes 0.6 / 0.3 / 0.1 | S |
| 6 | `punch-in` (native) | Scale 1.35 → 1.0 over a short shot | **Live** | Scale keyframes 0 → 1 normalised on each selected clip (the pack's `patch`) | S |
| 7 | `punch-split` (bespoke) | Punch plus split on a hit inside one shot | **Live** | `split` at the hit, #6 on the second piece, #4 on the new cut | S |
| 8 | `cover-freeze` (bespoke) | The cut-out moves over a flicking comic-page wall, title behind, panels open at the end | Live, paid matte (partial) | Freeze (`holdSec`); page stills as image items every 3 frames; title text; subject copy with `alphaMatte` graded by adjust + grain; end panels = #9. Light wrap is missing | L (+N3) |
| 9 | `window-open-next` (generic) | The next shot opens early as a band, column, slats or box, then cuts | **Live** | `$next` overlay copy, in = next.in − 0.3, rect mask keyframes from the shape (one copy per slat), wash; white line needs N2 | M (+N2 S) |
| 10 | `burst-out-card` (bespoke) | A card of the next shot arrives, the subject breaks out, the card opens | Live, paid matte | #9 card + the current subject (copy with `alphaMatte`) on a higher track; one stage per note | M |
| 11 | `band-behind-subject` (bespoke) | A band of the next shot opens behind the current subject | Live, paid matte | #9 band + the current subject copy above it | M |
| 12 | `panel-pile` (bespoke) | Tilted panels land one per note; the last is the next shot | **Live** | Overlay copies or stills, scale + rotation keyframes settling in 3 frames, one per note time; one track per panel (≤ 16) | M |
| 13 | `eye-window-zoom` (bespoke) | Pictures inside the mask's eye lens, then a zoom through it | Not ready | Needs N9 (tracked lens matte); the zoom itself is scale keyframes | XL |
| 14 | `comic-page-fly-in` (bespoke) | A page of live panels; the camera flies into one, which is the next shot | **Live** (heavy) | N overlay items in a grid; expansion computes identical camera keyframes so the target cell lands at native size | L |
| 15 | `subject-first-drop` (bespoke) | The next shot's subject arrives first, then its background as a band | Live, paid matte | Next subject copy with `alphaMatte` on the hit, then #9 band on the next note | M |
| 16 | `diagonal-stripe` (bespoke) | Tilted stripes with the next scene playing in them | **Live** | #9 with `maskRotation`, one stripe per note | S after #9 |
| 17 | `glass-shatter` (bespoke) | The frame breaks like glass and falls away | Not ready, then N8 | Ask Claude now; native shatter transition later | L |
| 18 | `one-frame-art` (bespoke) | One frame of art on each fast cut | Needs N7 | The person's stills as 1-frame image items at the hit times | S + gate |
| 19 | `white-out` (bespoke) | Lift to white, the next shot comes out of it | **Live** | Transition `white`; for different in and out frame counts, exposure keyframes on both sides | S |
| 20 | `background-glitch` (bespoke) | Only the background glitches; the subject stays clean; own sound | Live, paid matte | `glitch` effect on a 4–6 frame split piece + subject copy with `alphaMatte` above + the pack's sound on the sfx track. **Needs the server render to draw `effect`** | M |
| 21 | `title-behind-subject` (bespoke) | A big title behind the subject that glitches on the hit | Live, paid matte | Existing `text_behind` op + x/opacity jitter keyframes on the syllables; free with N3 | S |
| 22 | `lyric-negative-window` (bespoke) | Letters are windows showing the picture as a negative | Needs N4 + N1 | Overlay copy with `invert`, masked by the words; word times from voice onsets (gap) | L |
| 23 | `lyric-placed-art` (bespoke) | Lyrics placed by the shot: behind the head, on the road, down a tower | Not ready | Behind-subject parts work like #21; perspective and tracked anchors need N9. Per song, by Claude | XL |
| 24 | `lyric-frosted-glass-glitch` (bespoke) | Frosted-glass letters that break into a colour split on each syllable | Needs N4 + N1 | Overlay copy with `blur` + exposure lift, masked by the words; ring = text stroke; the glitch is N1 amount keyframes. **README: first text style to build** | L |
| 25 | `corner-signature` (bespoke) | A small signature mark, hidden over lettering | **Live** | Image item (the mark, from the pack) bottom right across the edit, split around the `hideOn` ranges | S |
| 26 | `storm-end-card` (bespoke) | Storm cloud, the mark signed on, a line, TM pops, lightning glitch | Live (close match), exact with N5 | Cloud as a template-owned background clip (generated, no film pixels: check the final); the mark image revealed by linear mask keyframes; line and TM as image items with pop; true pen write-on needs N5 | M (+N5 L) |
| 27 | `contained-sound-ending` (bespoke) | The song closes like a door: low-pass 1500 → 600 → 240 Hz, then a 3.6 s sink | Needs N6 | `lowpassHz` keyframes on the music item + squared volume keyframes | M after N6 |

**Count:**
- **Live now, free: 11.** #2, 4, 5, 6, 7, 9, 12, 14, 16, 19, 25.
- **Live now with the paid matte: 7.** #1, 8, 10, 11, 15, 20, 21. All 7 become free with N3.
- **Needs a primitive: 7.** #3, 17, 18, 22, 24, 26 (exact), 27.
- **Not ready, made by Claude per video: 2.** #13, 23.

Any one primitive unlocks several templates:
- **N1** unlocks #3, exact #4, #22 and #24.
- **N3** unlocks 7 templates for free (the README's #5).
- **N4** unlocks #22 and #24.

## 5. The Edit UI (mockups 1–4)
### Mac
- **Where it opens.** "Templates" in Edit's left rail opens the library.
- **What the library shows:**
  - Search, and the filters All, Transitions, Effects, Captions.
  - "Made by Claude", "Yours", and "Caption styles" (today's chips).
  - 16:10 tiles with name and timing.
  - Tiles that can't apply carry "Needs update" or "Not ready".
- **Selecting a tile:**
  - Hovering a tile plays its preview.
  - Selecting one previews it **on the real selection** (`dryRun`, nothing saved).
  - The inspector shows the description and origin, an "Applies to" row (clip or cut, with Change), the params (segmented controls, sliders, toggles) and the level line ("Live transition: uses the next clip itself, so it works on any video").
  - One primary button names the target ("Apply to cut at 0:21.7"). The secondary applies to every selected cut, or every cut on a note.
- **Paid-matte templates** carry the price on Apply ("Apply · $0.82") and go through the existing spend gate.
- **Not-ready templates** play the reference clip, say why, and offer "Ask Claude to make it for this cut".
- **Save as template** sits in the timeline toolbar. It opens a sheet with: name, what to keep (checkboxes from the selection), and Applies to (each selected clip, a cut, the whole edit).

### Android
- The same library as a bottom sheet: filters, then a 3-column grid.
- Tapping a tile previews it and opens its settings, with a full-width Apply.
- Not-ready templates show the reference only, without the Claude button.
- Save is in the clip's long-press menu.

### States
- **Loading:** skeletons.
- **Empty:** what a template is, plus "Save clip 12 as template".
- **Offline:** "Templates didn't load", with Try again.
- **Older app:** "Needs the next MUSE update".
- **Claude's card:** "Saved … as a template", with Open in Templates and Undo.

### Design review (muse-design-review)
- One action fill per screen; accent marks only the selection; one icon family; sentence case. There are no prices except paid-matte Apply buttons.
- Fix in the build:
  - The overlay label on the timeline must not truncate.
  - The Android sheet should stop at half height so the selected clip stays visible.
  - The tile art in the PNGs is a stand-in for the pack's real preview stills.

## 6. Phases (revised from the pack)
- **P0 (done).** Intake is live, and the pack is in.
- **P1, server only, no app update:**
  - The `edit_templates` table (0038), the spec, the expansion (`$next`/`$prev` copies, normalised keyframes, shapes, wash, note times, each-selected), `dryRun`, the 4 tools and the routes.
  - Seed the 11 free live templates and the 7 paid-matte ones; the rest as not-ready entries with previews.
  - **Fix the server render to draw `effect`.** Needed for #20 and every N1 template in server exports.
  - Claude can apply templates from chat as soon as P1 is live.
- **P2, apps:**
  - Templates library replacing the bin tab (caption styles inside), previews, `dryRun` preview, Apply, Save as template, states, and Ask Claude on the Mac.
  - One Mac bundle and one Android bundle. There is no contract change.
- **P3, primitives, one per Mac CI run, in this order:**
  1. N1: invert, rgbSplit, effect amount keyframes.
  2. N4: text as a mask.
  3. N2: mask stroke.
  4. N7: 1-frame image items.
  5. N6: audio low-pass keyframes.
  6. N5: write-on.
  7. N8: shatter.

  Each one is model.ts + fixtures + Kotlin + Swift + GLSL + Core Image + ffmpeg + a gate. Each moves its templates to Live.
- **P4.** Free local subject matte (Mac Vision, the pack's `subject_matte.swift` and `cutout_finish.swift` as reference; Android ML Kit), with smoothing through time. This makes the 7 paid-matte templates free. Separate plan.
- **P5, maybe.** Tracking and anchors (N9) for #13 and #23. Until then they stay as Claude-made per video.

## 7. Risks
- **Finished clips contain film pixels.** They are reference only. Shipping them as appliable overlays would put the Icon edit's footage into other videos. Hence "Not ready" plus "Ask Claude".
- **Bespoke scripts have this video's frames and coordinates written in.**
  - "Ask Claude to make it" is Claude adapting the script each time, so results vary.
  - It costs Claude time and tokens, and only works on the Mac.
  - The native primitives are the real fix.
- **Old apps refuse unknown values.** N1–N8 ship gated (pattern: `BLEND_NEXT_LIVE`). The server never puts a primitive into a project that an app in use can't read.
- **Server render drops `effect`.** Fix it in P1.
- **Track limit of 16.** Slats, panel piles and page fly-ins use one overlay track per simultaneous copy. Expansion refuses with a clear count ("Needs 6 free tracks; this edit has 3").
- **Paid matte.** It is priced and gated per apply. The README notes the free Mac lift beat the paid one, so P4 is worth doing early.
- **Word timing** for the lyric templates needs voice onsets (gap `voice-onsets`). Today it is a per-song analysis done by Claude.
- **Naming.** Photo `templates_*` stays separate, and the tool descriptions say so.
- **Pack content.**
  - Scripts are stored as text (credentials redacted) and never run on the server.
  - Media stays in uploads (R2).
  - Railway RAM is untouched: no rendering at apply time.
