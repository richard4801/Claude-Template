# Recreate this edit, and an editor that learns (plan, 2026-11-08, for owner approval)

## The brief
The owner's request: "Imagine I see a tuff Edit online that I love. Can we create Muse in a way that AI can simply replicate that edit for us? Almost at 100%." Missing shots should be auto-generated with our model. And every edit should be "a learning process… it grows till the studio can boast of a professional editor that can handle almost anything."

The owner's decisions (2026-11-08):
- **Input:** paste a link or share from TikTok, respecting each platform's download rules.
- **Length:** short edits first, up to 60 s.
- **Missing shots:** auto-generated with our model, with the cost shown first.
- **Sound:** MUSE times the edit to the sound's beats, and the owner attaches the sound with TikTok's "Use this sound" when posting.

## What the owner sees
1. In Edit: **New edit → "Recreate an edit"**, then paste a link or drop or share a video.
2. A minute later, the reference appears **broken into its recipe**: a timeline of shots (cut points, length of each, shot type), beat marks, speed ramps, zooms and shakes, text and captions, transitions, the colour grade and the pacing. Each part shows its confidence.
3. **Cast:** choose which model plays the lead (and others).
4. **Fill:**
   - MUSE matches each slot to your existing takes where it can, and marks the rest **"to generate"** with the rig it worked out (angle, lens, move, light, pose).
   - Generate all the missing shots, or pick which ones. The total price is shown, and you approve it.
5. **Assemble:** MUSE builds the edit on the timeline with the cuts, ramps, text, transitions and Look, synced to the sound's beats.
6. **Compare:** the reference and your version play side by side in sync, with a "match" score per element. Any slot can be fixed or regenerated.
7. **Export** with the sound as a guide track, and a "post with Use this sound" reminder. Or export silent, timed for the sound.

## How it's built

### 1. Getting the reference
- **Mac:** paste a link. MUSE fetches the video only when the platform permits it (we verify each platform's mechanism and terms before building). Otherwise it asks you to drop in the saved file.
- **Phone:** use TikTok's Share → Save video, then pick it, or Share → MUSE (a share target). Instagram and others work by saving or screen-recording, then picking the file.
- **Respect the creator:** if a platform says downloads are off for a video, MUSE doesn't use it.
- **Storage:** the reference is stored privately in the studio, used only for analysis, never posted or used as footage. It's deleted after 30 days unless kept as a recipe source.

### 2. Analysis: the reference becomes an **edit recipe**. Server-side, mostly free.
| Element | How | Notes |
|---|---|---|
| Cuts | Scene-change detection (ffmpeg scene score plus histogram), frame-accurate | Also catches flash frames |
| Beats | Existing `detect_beats` on its audio | Tempo, beats, strong beats |
| Action peaks | The queued motion-peaks tool (frame-difference energy) | Which actions land on beats |
| Speed ramps | Optical-flow speed per shot | Ramps and freezes |
| Zoom, shake, push | Camera-motion estimate (global motion between frames) | Becomes keyframed transforms |
| Text and captions | Text detection on keyframes, plus timing by text-region change | Content, position, size, style, animation in/out; fonts matched to the nearest we have |
| Transitions | Classify the frames around each cut (cut, whip, flash, zoom, fade, glitch) | Unknown ones are flagged |
| Grade | Palette and tone curve from the shots, turned into a Look | Uses the existing palette-to-LUT path |
| Shot content | Claude reads a contact sheet: shot size, angle, subject action, pose, location | This gives each slot its brief |
| Pose (per slot) | Pose skeleton extraction (body keypoints only, never their image) | Guides the generation |

**Output:** a `recipe` JSON (versioned schema). It holds slots (start, end, shot brief, rig, pose skeleton, move, speed curve, transform keys), text items, transitions, the grade, a beat map and the sound reference.

### 3. Rebuilding with our content
- **Matching:** each slot is scored against your takes (shot size, angle, motion, length). Claude makes the final choice and explains it.
- **Generating missing shots:**
  - Each slot's brief, rig and pose skeleton feed a Suite Shot with the chosen model, at the right length and aspect.
  - Pose is guided by the skeleton, never the reference's pixels.
  - Generation runs as normal Suite jobs, with the price and a confirmation first.
- **Assembly:** applied with the existing edit ops (trim, split, speed, transform and keyframes, transitions, add text, caption style, look, ratio, volume, music), so everything stays editable and undoable.
- **Timing:** cuts and action peaks snap to the sound's beat map.

### 4. Review and the match score
- The two videos play side by side in sync.
- The score is per element (cuts, text, ramps, grade, shots).
- "Fix this slot" re-picks or regenerates that slot.

### 5. The learning editor (studio memory)
Claude's model doesn't change. MUSE's memory does, and Claude reads it on every edit.
1. **Recipe library:** every analysed reference and every finished edit is saved as a recipe, with searchable tags (energy, genre, transitions, pacing). New edits start from the closest proven recipe.
2. **Corrections:** every change the owner makes after Claude's edits (undo, a moved caption, a changed transition) is logged as a lesson tied to the context it happened in.
3. **Performance:** posted edits are linked to their stats via Posts (views, watch time, saves, completion), so MUSE learns which hooks, pacing and lengths work for this studio.
4. **Studio editing playbook:** the lessons are written in plain language ("Captions above the chin", "First cut by 0.8 s", "No glitch transitions") with the evidence for each. Claude gets the playbook plus the most relevant recipes and lessons before every edit. The owner can read, edit, pin or delete any rule.
5. **Gaps:** when a recipe needs something the editor can't do (an unknown transition or effect), it's logged. A list of the most-requested missing effects tells us what to build next.

### 6. Cost
- **Analysis:** free (server CPU), plus Claude's reading of the contact sheet on the owner's plan, or a few cents on the API fallback.
- **Generation:** the normal Suite prices per missing shot. A 60 s edit with 6 generated shots costs about $4–8 on HD Higgsfield, shown before you approve.

### 7. Expected match
| Element | Target |
|---|---|
| Cut timing and beat sync | ~95% (frame-accurate) |
| Pacing and structure | ~95% |
| Text timing and placement | ~90% (nearest font when we lack the exact one) |
| Speed ramps, zooms, shakes | 85–90% |
| Grade | 80–90% |
| Common transitions | High; custom VFX low until we build them |
| Generated shots | A close match on pose, framing and move; not pixel-identical |

## Build order (each phase ships when green; anything new is approved by the owner)
0. **Prerequisites (already queued):** the Edit crash fix with full control vetting, the Edit redesign, and the motion-peaks tool.
1. **Analysis service and recipe schema, plus a "Recipe view" in Edit.** Paste or drop in a reference and see its recipe.
2. **Assembly from your own takes,** with the side-by-side compare and match score.
3. **Missing-shot generation:** slot briefs, then Suite jobs with pose guidance.
4. **Getting references in:** link fetching where permitted, and the phone share target.
5. **The learning editor:** the recipe library, corrections log, playbook (owner-editable), performance linkage and gap list.
6. **Claude tools:** `analyze_reference`, `get_recipe`, `apply_recipe`, `fill_slot`, `playbook_read`, `playbook_add`, so Claude can run the whole flow from chat.

## Open items to verify before phase 4
- Each platform's download-permission mechanism and terms for programmatic fetching (TikTok, Instagram, YouTube Shorts).
- The share-target behaviour on Android and iOS-to-Mac.

## APPROVED by the owner (2026-11-08): "Approved, build both" (this plan and the Edit layout in plans/edit-layout.md)
Assignments:
- **WS1, server:**
  - the motion-peaks tool;
  - the analysis service and the `recipe` schema (cuts, beats, peaks, ramps, camera motion, text, transitions, grade, contact-sheet shot briefs, pose skeletons);
  - the slot matcher;
  - the MCP tools `analyze_reference`, `get_recipe`, `apply_recipe`, `fill_slot`, `playbook_read`, `playbook_add`.
- **WS3, after the Edit crash fix and click-through ship:** the learning editor's storage and APIs:
  - the recipe library;
  - the corrections log, captured from edit ops after Claude's;
  - the playbook (owner-editable);
  - the performance link via Posts;
  - the gap list.
- **WS2:** the Edit layout build. Then the Mac Recipe view and side-by-side compare inside the new layout.
- **WS4:**
  - Android: the Edit layout port, then the Recipe view;
  - the phone share target (step 5, after the platform-rules check).
- **Coordinator:** verify each platform's download-permission mechanism and terms before step 5.

## Mac Recreate screens APPROVED by the owner (2026-11-08): "Approve with your two notes"
Mocks: plans/recreate/ on claude/muse-mcp-bridge @4c2f3f9 (Recipe and Compare). The notes:
1. The Look swatches are never garish: they show the grade's real colours, softened for display.
2. The total cost ("N from your takes, M to generate · $X in all") is always visible next to "Build the edit", which still confirms before spending.

## Android Playbook and Recipes mocks APPROVED (2026-11-08): "Approve with my 2 notes"
1. Real thumbnails from the owner's own videos, never sample people.
2. Suggestion copy is plain, for example "You changed Claude's look 4 times".

## Link fetching: the owner chose "Keep link fetching" (2026-11-08)
See plans/research/platform-download-rules.md for the guardrails.
