# AI Suite design plan (2026-11-07, for owner review)

## The brief
The owner's words: "more work needs to be put in our UI… It needs proper planning. Look how other apps are doing it… Thought needs to be put in every feature design."

The owner's decisions:
- **Keep every in-depth control.** "How they are featured matters."
- **Mac first**, with the phone adapting from it.
- **Results in a feed beside the composer.**

Research: `plans/research/ai-suite-competitors.md`. It covers 16 products (Runway, Kling, Luma, Pika, Krea, Higgsfield, Google Flow, Midjourney, Freepik, Hailuo, Hedra, Captions, Arcads/Creatify, CapCut, Firefly), with sources.

## What's wrong today (confirmed in code and screenshots)
1. **Three ways to switch tool:**
   - an 8-item sub-list under "Video suite" in the sidebar;
   - the title switcher;
   - the hub page.

   On top of that, Create → "New video" duplicates Shot, and Templates is a separate sidebar item.
2. **Every tool is a page that stacks everything at once:** a presets strip, a big preview, setup rows, inputs, the prompt, and a pill bar. The page overflows a 13" screen and doesn't scroll.
3. **The preview is a placeholder until there's a take.** Results then replace it one at a time, so there's no history to compare, reuse or iterate on.
4. **Controls look equally important.** Rarely-changed settings get the same weight as the prompt and Generate.

## The principles we take from the best products
1. **One composer; tools are modes of it.** The mode changes only the inputs (Flow, Midjourney, Krea). Tools are not separate destinations; adding a nav item per tool is the anti-pattern (Krea, Kling, Pika).
2. **The prompt is the centre of the composer.** Characters and moves are words in the sentence: `@Zelphira`, `#Dolly in` (Kling, Flow, Higgsfield).
3. **Depth behind one click, never on the surface.**
   - Every rig control shows its value in one compact line and opens a full picker.
   - Nothing is removed: drums, grids, previews and Custom values are all kept, just not visible all at once (Higgsfield, Krea).
4. **Auto by default, with your own defaults.**
   - A whole rig can be saved as a preset.
   - Each model can carry its own default rig.
   - So you set it once, not on every shot (Higgsfield project style, Midjourney settings).
5. **Results are a working surface, not an endpoint.**
   - Every take lands in a feed with a fixed set of next actions.
   - Opening a take puts its exact prompt and rig back into the composer (Runway, Flow, Midjourney).
6. **Say why, not just no.**
   - A disabled control explains itself ("Set by your clip").
   - The rig check explains clashes.
   - The price is always on Generate (Firefly, Higgsfield).

## 1. Where things live (the whole app, Mac sidebar)
| Place | What's in it | Replaces |
|---|---|---|
| **Home** | What's happening: in progress, needs review, latest takes, balance | stays |
| **Create** | The composer plus the session feed: all eight tools | "Video suite", its 8 sub-items, the hub, Templates, Create → New video |
| **Library** | Every take and photo, filtered by type, model and tool; version stacks; collections | stays |
| **Models** | Your characters, each with images, outfits, voice, **default rig** and a **Use in Create** button | stays; gains the default rig |
| **Edit** | Timeline editor with Claude | stays |
| **Posts** (owner) | Scheduling and accounts | stays |
| Settings | Includes Members, Studio, Connections | Members moves in from the sidebar |

- **Queue merges into Create and Home.** Jobs in progress appear as live cards at the top of the feed, and Home shows a count.
- **Camera stage is no longer a destination.** It opens full-screen from a Shot ("Direct in 3D") or from a take.
- **New model** stays as the "+" in Models.

**Result:** the sidebar goes from about 17 rows to 6 or 7, with no nesting.

## 2. Create on the Mac (the core)
```
┌ sidebar ┐┌─────────── composer 400pt ───────────┐┌──────────── feed (fills) ─────────────┐
│ Home     ││ Shot ▾                       Presets  ││ Today                       Filter ▾  │
│ Create • ││ [Zelphira][Start][End +]  (inputs)   ││ ┌───────┐ ┌───────┐ ┌───────┐         │
│ Library  ││ ┌─────────────────────────────────┐  ││ │ 62% ▓ │ │ take  │ │ take  │  ...    │
│ Models   ││ │ @Zelphira walks out to the…      │  ││ └───────┘ └───────┘ └───────┘         │
│ Edit     ││ │ #Dolly in                        │  ││  in progress  9:16·10s  9:16·10s      │
│ Posts    ││ └─────────────────────────────────┘  ││ Yesterday                             │
│          ││ Camera   35mm film · Anamorphic   ›  ││ ┌───────┐ ┌───────┐ …                 │
│          ││ Angle    Eye level · Medium       ›  ││                                       │
│ Settings ││ Move     Dolly in                  › ││                                       │
│ $6.07    ││ Light    Window                    › ││                                       │
│          ││ Look     Golden warmth             › ││                                       │
│          ││ Style    UGC · Calm                › ││                                       │
│          ││ ⚠ Wide lens on a close-up  Fix       ││                                       │
│          ││ HD ▾  9:16 · 10 s · 1 take · Sound    ││                                       │
│          ││ [        Generate · $0.65          ]  ││                                       │
└──────────┘└───────────────────────────────────────┘└───────────────────────────────────────┘
```
**Composer column** (fixed width, scrolls if the window is short, so Generate is always reachable):
- **Header:**
  - The mode switch, "Shot ▾", opens a menu of the eight tools in three groups:
    - **Make:** Shot, Photo, Storyboard.
    - **From a clip:** Character swap, Recast, Extend & upscale.
    - **Performance:** Talking, UGC ad.
  - "Presets" opens a popover gallery of presets and templates. It is never a permanent strip.
- **Inputs:** small labelled tiles, only the ones this mode accepts. Each states its limit on hover.
- **Prompt:** the largest element. `@` inserts models, products and Library items; `#` inserts moves.
- **Rig:** six compact rows (Camera, Angle, Move, Light, Look, Style), each showing its value or "Auto".
  - Clicking a row opens the **rig panel** over the feed: the full pickers, including the approved drums for hardware, preview grids, intensity and Custom values. Nothing is cut.
  - Rows a mode doesn't use are hidden. Rows an input decides are shown greyed with the reason.
  - "Save rig…" sits at the bottom of the panel.
- **Rig check:** one line when there's a clash, with its one-tap fix.
- **Footer:**
  - Quality (with the owner's engine inside it, not a separate pill).
  - One line of shape, length, takes and sound/speaking. Click it to change them.
  - **Generate · price**, full width.

**Feed:**
- **Grouping:** cards in a grid grouped by day, newest first. Jobs in progress sit at the top with live progress, and a failed or refused card says why.
- **Hover a card:** it plays muted and shows the prompt, rig and price.
- **Click a card:** it opens a large viewer over the feed. Arrow keys move through the feed.
- **Fixed actions on every take:**
  - Reuse settings
  - Vary
  - Extend
  - Upscale
  - Use as start frame
  - Use as reference
  - Open in Edit
  - Direct in 3D
  - Save to Library collection
  - Post
- **Filter:** by tool, model or status. This is the session view of Library.
- **Empty state:** one line ("Your takes appear here") plus three preset suggestions. No placeholder images.

**Window size:** this works at 1280×800. Below about 1100 pt wide, the feed drops to 2 columns. The composer never shrinks below 360 pt.

## 3. The rig panel (depth without bulk)
- Opens as a large panel over the feed, anchored to the composer. Esc or a click outside closes it, and choices apply instantly.
- Tabs follow the rows: **Camera** (the approved drums: body, lens, focal length, aperture) · Angle · Move · Light · Look · Style.
- **Move:**
  - Category chips plus search, over a grid of preview loops.
  - Picking a move inserts a `#chip` into the prompt.
  - At most 2 moves, each with intensity.
- **Light:** preview stills. **Look:** palettes and film stocks, plus "Grade the take with this look". **Style:** genre, era, tempo.
- **Saved rigs:** a strip of your saved rigs at the top of every tab, one click to apply. Each model's default rig is applied automatically when you @ that model, and can be undone.
- **Owner only:** a "Directed" tab with the raw fields.

## 4. Each tool: what it's for, inputs, rig, extras
| Tool | For | Inputs (required / optional) | Rig | Tool-specific controls | Notes |
|---|---|---|---|---|---|
| **Shot** | A video of your character from words | Character / Start frame, End frame (needs a start frame), References ≤9 | All six rows | Length, takes, sound, speaking | "Direct in 3D" opens Camera stage |
| **Photo** | Stills of your character | Character, Outfit / Product, References ≤3 | Camera, Angle, Light, Look, Style (no Move) | Count 1–4 | Templates are its presets |
| **Storyboard** | Several shots, one cast | Cast (1–3 characters) | Shared rig at the top; a per-scene Move override | Scene list: each scene is a prompt row with length and a move, plus "+ Add scene" | Results arrive as one grouped card, with "Open sequence in Edit" |
| **Character swap** | Your character into a real clip | Clip (3–30 s), Character | Look only; the rest says "Set by your clip" | Keep original audio, speaking, add-ons (Edit, Fast, Upscale) | Prompt hidden behind "Add direction" |
| **Recast** | Replace chosen people in a clip | Clip, then tap faces on the first frame and pick who replaces each | Look only | Per-person mapping list | Our differentiator; the face picker opens inline |
| **Extend & upscale** | Longer or sharper takes | A take (usually from a card's action) or an upload | Shot rig for Extend; none for Upscale | Extend after/before and length; Upscale 1080p/2K/4K | Mostly reached from the feed, so the mode is for uploads |
| **Talking** | Your character speaking | Character, Voice (record, upload or script) / Location | Camera, Angle, Light, Look; talk-safe moves only | Emotion tags, voice picker | Rig check enforces talk-safe moves |
| **UGC ad** | A product ad with your character | Character, Product / Reference ad | Style becomes Format (Unboxing, Review, Try-on…) | Script, variants (1–4) | Variants land as one grouped card |

## 5. Phone (Android), rebuilt rather than shrunk
- **Tabs:** Home · Create · Library · Models · You.
- **Create shows the feed full-screen.** A docked **composer bar** at the bottom holds the mode chip, the prompt and Generate · price.
  - Pulling it up gives the full composer as a sheet: inputs, rig rows and settings.
  - Each rig row opens a full-height picker, using the drums for hardware.
- **A feed card** opens the viewer, with the same action set as the sheet.
- **Edit on the phone** stays trim, sequence and captions; Camera stage stays Mac-only.

## 6. Redundancy removed (checklist)
- The sidebar "Video suite" and its 8 sub-items, the hub page, the Templates item and "New video" are all removed: Create plus the mode switch covers them.
- The permanent presets strip, "Hide presets" and "All templates" become one Presets button.
- The section headings "Setup" and "Inputs" are dropped. The labels on the rows and tiles are enough.
- The placeholder preview is gone. The feed is the preview.
- The separate engine pill moves inside Quality (owner only).
- The separate Queue page is folded into the feed and Home.
- The bottom bar's 7 pills become one summary line that opens a small settings popover.

## 7. Visual system for this (applies design-direction.md)
- **Composer:** text 13 pt and rows 32 pt.
- **Prompt:** 15 pt in a 120 pt box that grows to 240 pt.
- **One filled button per screen** (Generate).
- **Feed cards** use the media's own aspect with an 8 pt radius. Metadata appears on hover, not stacked under each card.
- **Surfaces separate by tone, not borders:** composer and feed sit on the same background, divided by one hairline.
- **Motion:** new cards fade in once, and nothing else animates by itself.

## 8. Build order (after owner approval of this plan, then of mocks)
1. **Mocks:** Mac Create in the empty, working and with-results states, the rig panel and two tools (Swap, Storyboard). Then the phone Create and composer sheet. Soft Tactile and Camera Body themes. **The owner approves.**
2. **The new navigation and Create shell on the Mac,** with the feed and the composer column (Shot and Photo first).
3. **The rig panel** (it reuses the existing pickers and drums), saved rigs and the model default rig. Saved rigs need a small server addition.
4. **The remaining tools** moved into modes, and the feed's action set.
5. **Android:** the same structure, rebuilt for the phone.
6. **Remove the old screens.** Each step ships only when green, with before/after screenshots.

## Open questions for the owner
1. **Home:** keep it as the dashboard, or make Create the screen the app opens on?
2. **Posts:** does it stay in the sidebar, or move under Library?
3. **Saved rigs:** should members also get saved rigs and model default rigs, or the owner only at first?
