# Video composer (spec, 2026-11-05)

Replaces the camera-bag screens (D2–D5, M2–M4). The owner rejected laying hardware out as shelves: "overwhelming for first-timers… they're features, something you set up or select when creating a video". This follows a teardown of Higgsfield's Cinema Studio 4.0 and its other tools (about 350 screenshots, logged out, nothing generated). The aim is not to copy Higgsfield but to use what has been proven to keep a deep tool calm. Research notes are in the coordinator's scratchpad (`hf/cinema-report.md`, `hf/products-report.md`). The key facts are repeated here, so this file stands alone.

## Decisions (the owner said "just handle it")
1. **One composer shell, tools are presets of it.** Shot, Character swap, Recast, Talking, UGC ad, Storyboard and Extend & upscale are the same composer with a different **tool card**, slots and defaults. The hub tiles open the shell on that tool, and **Change** on the tool card switches tool without leaving the page. This is Higgsfield's pattern (Genjutsu, Intone, Upscale… are deep links into one panel).
2. **Keep every piece of hardware that visibly changes the result, and merge only true duplicates** (the owner: "if they really do something, don't cut them; keep it less overwhelming"). See "Catalogue" below. Wheels showing three cards keep 10 bodies as calm as Higgsfield's 4.
3. **Style chip: yes.** It covers Genre, Era and Tempo, which our catalogue already has (Higgsfield calls this "Film setup").
4. **Ready-made combos: yes, as the beginner path.** "Start from a preset" opens a gallery of looping tiles. Picking one collapses the composer to *character + photo/clip + shape + Generate*, with a link to "Edit settings".
5. **Inputs follow the model.** A slot (start frame, end frame, references, motion clip, audio) is shown only when the engine behind the chosen quality accepts it. A dependent slot is shown greyed until its prerequisite exists (end frame needs a start frame). Every slot states its limit. Members choose a quality, not a model; the owner can also pin an engine.

## Composer anatomy
Prompt-first. A composer left entirely on defaults is a complete, one-tap state.

- **Tool card** (top left of the composer): a looping thumbnail, the tool name, a one-line tagline and **Change**. Change opens the tool and preset browser.
- **Prompt box.** It has a placeholder per tool and engine, e.g. "Describe the scene · type @ for your characters, # for a camera move".
  - `@` inserts a character, outfit or location chip.
  - `#` inserts a camera-move chip.
  - Chips are inline tokens that can be reordered and removed. At most 2 moves (the server's `canMix` rule).
- **Setting chips above the prompt**, each a tiny visual, a mono label and a value; every value starts as **Auto**:
  1. References `0/9`. The max comes from the engine's `refs.images`.
  2. Style.
  3. Camera.
  4. Look.
  5. Lighting.

  After a choice, a chip shows only the non-Auto values ("Camera · 35mm film, Anamorphic"), truncated with "…".
- **Slot cards beside the prompt.** They are square, with "+" and a caps label, plus an `Optional` pill where it applies. The slot list depends on the tool:
  - **CHARACTER:** your models, with an outfit picker inside.
  - **START FRAME** (Optional).
  - **END FRAME** (Optional; greyed until a start frame exists).
  - Swap: **CLIP**.
  - Talking: **AUDIO**.
  - UGC ad: **PRODUCT**.

  Captions state the limits, e.g. "Up to 9 images", "Clip 3–30 s", "The first frame sets the shape".
- **Bottom bar.**
  - **Desktop:** pills for Quality (Draft / Standard / HD / Cinema), Shape, Length (a slider within the engine's range), Sound, Speaking (the talking switch, Auto by default) and Takes 1–4, then **Generate** with the live price ("Generate · $0.16"). Each pill opens a small list with a check, or a slider, and has a one-word tooltip.
  - **Phone:** Quality, a **Settings** icon and a round **Generate** button showing the price. Shape, length, sound, speaking and takes live in the Settings sheet.
- **Price:**
  - Live on the button.
  - "—" until it can be computed.
  - A "~" prefix with "How is this priced?" for estimates.
  - "Free" for test renders.

## The picker shell (one shell, learnt once)
- **Desktop:** a centred modal (about 820×520) over a dimmed page, with a title, **Reset all** and ×. Sub-steps sit in a left rail; a dot marks a step that has a value. Choices apply instantly, with no OK button.
- **Phone:** a bottom sheet (about 85% height) with a grab handle, title, Reset all and ×. Sub-steps become a segmented control at the top, and choices apply instantly.
- **First tile of every grid:** "Auto". "Create your own" comes last in the reading order (custom palette or light, later).
- **Previews:** shown instead of specs. Hardware shows product photos; moves and lighting show short loops with the same subject in every clip; palettes show a still with a swatch strip.
  - Desktop plays a preview on hover.
  - Phone autoplays muted previews while they're on screen, battery-aware, and falls back to stills on low-power mode.

## Camera picker
Tabs: **Setup · Angle · Movement · Directed** (Directed is owner-only and is workstream 2's `DirectedModePanel` as sheet content).

- **Setup:** four "wheels" for Camera, Lens, Focal length and Aperture.
  - Each wheel shows exactly 3 cards: previous, selected (centred, outlined) and next, dimmed. Auto is the default centre card and uses a plain icon.
  - Each card is a render plus a name plus a 3–5-word "what it does" ("Grain, halation, organic colour").
  - Desktop shows the 4 wheels side by side, scrolled with the wheel, drag, ↑/↓ or chevrons.
  - Phone shows 4 stacked horizontal snap rows, each centring its selection with 3 cards visible.
- **Angle:** Height (eye, shoulder, low, high, overhead, worm's-eye, ground, hip) and Framing (extreme wide → extreme close-up, over the shoulder, POV, two-shot) as two wheels, illustrated with simple framing diagrams.
- **Movement:**
  - **Layout:** category chips (Featured, UGC, Push, Pan & tilt, Orbit, Crane, Follow, Aerial, Special) plus search, over a grid of looping previews (4 columns on desktop, 2 on phone).
  - **Tap a move:** inserts a `#move` chip into the prompt and closes the picker. Tapping the chip in the prompt opens intensity (subtle → strong) and Remove.
  - **Badges:** a "Talk-safe" badge appears when Speaking is on, and moves marked `editorBetter` say "Better done in Edit".
  - **Limit:** up to 2 moves combined.

## Catalogue (what stays, what merges)
Everything stays in the API, so old ids keep working: merged ids map to their survivor on the server. Members see only the visible options. The rule is to keep an option when a video model renders it visibly differently from its neighbours; options whose model wording means the same thing are merged.

| Group | Members see | Merged / hidden (why) |
|---|---|---|
| Camera (10) | Phone, Creator camera, Cinema camera, Large format 65mm, 35mm film, 16mm film, Super 8, DV camcorder, Webcam, CCTV | Super 35 + Modular 8K + Full-frame cine + Cinema digital → **Cinema camera** (all compile to "clean digital cinema"; models don't render sensor brands differently). Vlog + Creator cine → **Creator camera**. |
| Lens (9) | Clean sharp, Warm vintage, Anamorphic, Vintage anamorphic, Halation, Swirl bokeh, Macro, Tilt-shift, Fisheye | Vintage → Warm vintage (same effect). Cine zoom → removed (zooms are moves). |
| Focal length (6) | 14 ultra-wide, 24 wide, 35, 50 natural, 85 portrait, 135 telephoto | 8/18/26/65/100 mm fall into the same wording buckets as their neighbours. |
| Aperture (4) | f/1.4 Dreamy blur, f/2.8 Soft background, f/5.6 Natural, f/11 Everything sharp | f/1.2, 2, 4 and 8 sit between visible steps. |
| Frame rate / shutter | hidden for members | Models output their own frame rate, so "60 fps" in a prompt does nothing visible. **Slow motion** moves to Style → Tempo; "Motion blur streaks" becomes a Special move. Directed mode and owners keep the raw fields. |
| Style | Genre (12), Era (8, decade slider), Tempo (Auto, One take, Calm, Steady, Dynamic, Chaotic, Slow motion) | — |
| Look | **Palette** (28) and **Film stock** (10) tabs; a toggle "Grade the take with this look" (on by default) | — |
| Lighting (17) | Auto + all 17 setups | — |

**Look is MUSE's edge.** A prompt can only nudge colour, but we also own 32 real LUT looks. When "Grade the take with this look" is on, the matching LUT is applied after the render as an editable, reversible Look in the Edit suite. Colour then comes out exact, for free. Palettes without a LUT twin get one made from their swatches.

## Tools on the shell (slots and defaults)

| Tool | Required slots | Optional | Chips shown | Notes |
|---|---|---|---|---|
| Shot (default) | — (prompt or a slot) | Character, Start/End frame, References | all five | |
| Character swap | Clip (3–30 s), Character | — | Look only (camera and light come from the clip) | Prompt behind a toggle (off by default); Speaking switch; add-ons Edit / Fast / Upscale as pills |
| Recast | Clip, 1–4 People | — | — | Tap a face on the first frame, then pick who replaces them. **Higgsfield has no per-person mapping; this is our differentiator.** |
| Talking | Character, Audio (record / upload) | Location image | Camera (talk-safe moves only), Look, Lighting | |
| UGC ad | Character, Product | Reference ad | Style shows a UGC format wheel (Unboxing, Review, Try-on, Before/after, GRWM, Haul, Tutorial, Testimonial) | |
| Storyboard | Scenes (numbered rows, "+ Add scene") | — | shared Style / Look across scenes | |
| Extend & upscale | Video | — | — | Extend: After / Before. Upscale: 1080p / 2K / 4K |

## Presets (beginner path)
- **Before anything is typed:** under the empty composer, a "Start from a preset" row of looping tiles with big names: Phone UGC, Talking head, Selfie vlog, Creator studio, Cinematic, Product hero, Music video, Documentary, Noir, Fashion editorial and Y2K camcorder (the server's `PRESETS`), plus UGC-ad formats.
- **Picking a preset:**
  - The tool card becomes the preset.
  - The composer shows only CHARACTER (or PHOTO/CLIP for that preset), Shape tiles (9:16 · 1:1 · 16:9) and Generate · price.
  - **Edit settings** reopens the full composer with the preset's values in the chips.

## Assets needed (no money)
- **Hardware renders.** We have 10 bodies, 8 lenses, an iris, 6 lights and 6 palettes. New stills are needed for Webcam, CCTV, Swirl bokeh and Tilt-shift, made the same way as the existing 40.
- **Movement loops:** 37 moves × ~2.5 s at 320×400, rendered **in Blender, headless, in a cloud session** (no GPU spend). They use a neutral mannequin on a simple set with the same subject and set in every clip.
- **Lighting:** 17 stills or slow loops of the same mannequin under each setup, also from Blender.
- **Palette tiles:** one neutral scene still graded per palette, with a 10-swatch strip drawn in code.
- **Angle/framing:** line diagrams drawn in code.
- **Style cards:** stills (Blender or existing renders) with big type.

## Build notes
- **Server:**
  - The catalogue gains `visible: boolean` and `mergedInto?: string` per option, plus the focal/aperture subsets above.
  - `GET /v1/suite/catalog` returns, per quality tier, `accepts: { startFrame, endFrame, refs: {images, videos, audios}, audio, maxSeconds, minSeconds }` from the registry, so clients can show or hide slots without knowing engines.
  - Look grading: suite results carry `look: { id, lut }`. The Edit suite opens with that Look applied (reversible).
- **Clients:**
  - Android: `ui/screens/suite/composer/**`. Mac: `Muse/Views/Suite/Composer/**`.
  - Reuse `SuiteCamera.kt` / MuseCore `CameraPickers` (options with render, name and caption; Auto by default).
  - The paused D2–D5/M2–M4 screens are replaced, not patched.
- **Tests:** Roborazzi for the composer (empty, filled, preset-collapsed) and every picker on phone (360/390) and tablet in all 4 themes; MuseCore tests for the chip summaries and slot visibility rules.
