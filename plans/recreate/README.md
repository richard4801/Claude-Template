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
