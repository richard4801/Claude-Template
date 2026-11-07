# Create mocks (AI Suite plan, build step 1), for the owner's approval

Rendered by `design/direction/create.py` from `plans/ai-suite-design.md` (approved 2026-11-07, with its refinements).
File names are `<screen>-<width>-<theme>.png`, with theme `c` = Soft Tactile and `b` = Camera Body.
`overview-c.png` and `overview-b.png` show every screen on one page.

## Mac (1440 × 900 and 1280 × 800)
1. **`1-empty`**: a new member with a model and no takes.
   - The rig rows read Auto.
   - Generate stays dimmed until there's a prompt.
   - The feed shows one line and three text-only preset suggestions.
2. **`2-working`**: a Shot drafted with `@Zelphira` and `#Dolly in`, with a rig check line and its Fix.
   - The feed has a Queued group with **Run · $1.30**, one take rendering at 62 %, and today's takes.
3. **`3a-results-hover`**: two days of takes.
   - The hovered card plays, and shows its prompt, its specs and the four actions plus More, with a tooltip.
   - Its ring is the select mark used for Compare.
4. **`3b-viewer`**: the viewer over the feed.
   - Shows the take, Reuse settings, the four actions plus More, the prompt and rig, specs and price, and "3 of 13" for the arrow keys.
5. **`4a-rig-camera`**: the rig panel over the feed on Camera.
   - The approved drums exactly as the app draws them.
   - Saved rigs and "Save rig…" at the top.
6. **`4b-rig-move`**: the Move tab.
   - Categories, search, and the loop posters.
   - The chosen move is marked "In the prompt", with its intensity and "1 of 2 moves".
7. **`5-photo-presets`**: Photo mode with the Presets popover open (text only, plus "Save current as preset").
8. **`6a-storyboard`**: the scene list over the feed (prompt, length and own move per scene).
   - The column keeps the cast, the shared rig and Generate · 3 shots.
9. **`6b-recast`**: the first frame over the feed with the face picker and the "Who replaces whom" list.
   - The column keeps the clip, Look, "Add direction" and Generate.

## Phone (390)
- **`p1-feed`**: the feed, the docked composer bar (prompt, mode, Generate · price) and the tabs Create · Library · Models · You.
- **`p2-composer-sheet`**: the composer pulled up, with 48 dp rows and Generate pinned.
- **`p3-rig-camera`**: the Camera picker sheet with the drums.

## Slop and redundancy review (muse-design-review §1, design-direction §7)
- **One filled button per screen: Generate.**
  - Run · $cost, Reuse settings and the take actions are outlined or quiet.
  - On p3, Done is the sheet's only filled button.
- **No icon per row.**
  - The rig rows are label, value and chevron.
  - Icons stay where they mean an action: the sidebar destinations and the take actions, each with a tooltip.
- **One name for each thing:** Create, Library, Models, Edit, Posts; "Generate · price"; "Use as start frame" everywhere.
- **Middle dots only in "Generate · price" and "Run · $cost".**
  - Value lists use commas ("9:16, 10 s, 1 take, sound on"; "35 mm film, anamorphic").
- **Redundancy removed against today's app:**
  - No hub, no tool sub-list, no Templates item, no "New video" and no permanent presets strip.
  - No "Setup" or "Inputs" headings and no placeholder preview.
  - The Move row only summarises the `#chips`.
  - Recast's four clip-set rows became one line: "Camera, angle, move and light come from your clip."
  - Storyboard has no prompt box, because the scenes are the prompts.
- **Cut while reviewing:**
  - Optional notes under the phone input tiles (the + already says it).
  - An "Applied Zelphira's rig · Undo" line. The rule stays, but showing it on top of a rig check would put two notices on one screen.
  - Stills in the Presets popover (owner fix A1).
- **Imagery is real studio material only:**
  - the Blender preview stills (the café street, the mannequin lighting set);
  - the move loop posters;
  - the hardware renders inside the drums, cropped from the Android RigDrum screenshot test.

  There are no stock photos or placeholder people.

## Known limits of the mocks
- The preview stills are at most 640 px wide, so the viewer's large picture is slightly soft. Real takes will be sharp.
- The drum labels read "35mm film" (the app's current label) while the rows read "35 mm film". The rows follow the server captions, and the drum label will be aligned when it's built.
