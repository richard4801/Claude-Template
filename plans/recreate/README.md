# Recreate this edit: Mac screens (mock, for the owner's approval)

Inside the approved Edit layout (`plans/edit-layout.md`). Data is workstream 1's real analysis of the test reference
(`server/api/test/fixtures/recipe-v1.json`); footage is the Blender preview posters. Made by `design/recreate/render.py`.
Themes: `c` Soft Tactile, `a` Editorial, `b` Camera Body, `d` Creator Pop; 1280 × 800.

- **Getting there**: Edit home → **Recreate an edit** → drop a video (or paste a link once the platform rules are checked).
  While it's analysed (about a minute) the screen shows the steps as they finish ("Finding the cuts", "Reading the text"…).
- **`recipe_*`: Recipe**.
  - The reference plays on the left. Under it are lanes for its shots (thumbnail, number, and whether it comes from your
    takes or will be generated), text, transitions and beats.
  - The panel on the right describes the selected shot: what happens in it, the camera and speed, how sure the analysis is,
    and how it will be made ("To generate $0.64" with "Use one of my takes").
  - Below that: the whole edit's summary, pacing, beats and Look, and the total ("1 from your takes, 2 to generate ·
    $1.28 in all. You approve before anything is made.").
  - **Build the edit** is the one primary. It asks before spending.
- **`compare_*`: Compare**, after building.
  - The reference and your edit play side by side, in sync.
  - The match per element is shown above them (overall, cuts, text, speed, look, shots), and each shot's score is on its
    tile.
  - **Fix shot 2** re-picks or regenerates the weakest shot. Export stays the one primary.
- Anything the editor can't do yet shows in the panel as "Not supported yet", with the moment it happens.

## Release 1 on the Mac (built, demo mode, Mac CI run 42492773570)
- **Paste a link** (`built_link_c`): the start page takes a TikTok, Instagram Reel or YouTube link (field, ⌘V, or dropped),
  as well as a dropped or chosen file anywhere on the page. Each refusal shows the server's words, with "Choose the file" beside it.
  A link whose download is blocked later shows the same and a drop zone.
- **Cast** (`built_cast_c`): the lead at the top of the Recipe panel; the new shots are priced and made with her, and
  Build's confirmation names her (`built_confirm_*`).
- **How each shot is made**: "Swap into the reference shot" (default; keeps its camera, speed and look) or "Generate a
  new shot", with "Keep the reference's setting". A failed swap is offered as generate, priced on its own.
- **Write the shot briefs** (`built_briefs_c`, `built_briefs_confirm_c`): under "Not described yet", priced and confirmed first.
- **Claude** (`built_claude_c`): the editor's chat beside Recreate, on a "recreate" thread (falls back to the edit
  session's), with Explain shot N / Fix the weakest shot / Analyse a new video. A paid step Claude asks for waits for Allow.
- **Compare** (`built_compare_*`, `built_compare_playing_c`, `built_compare_frame_c`): "Your edit" plays the built edit:
  the server's preview when it has one ("Preview of the cut" if it leaves something out), else rendered on the Mac with
  the editor's engine. Swapped shots are noted as "Already in the shot".
- **Fix shot N** (`built_fix_c`): another take, or the shot made again (priced, confirmed), swapped into the edit as one undo step.
- **Export** (`built_export_c`): the primary after Build; the reference's sound as a guide track or silent, with the
  "Post with the original sound" steps. The server export when there is one, else made on the Mac.
