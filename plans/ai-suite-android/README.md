# AI suite plan in the current Android Suite (Release 1)

The approved plans/ai-suite-design.md features, in the current composer's style (as the Mac's 9d1ff33):

- **Reuse settings:** every Shot and Photo request now carries the composer's `draft` (ComposerDrafts, the Mac's JSON),
  so a take's prompt with its chips, rig and bar values come back exactly, from either app.
- **Take actions** (take screen): Keep, **Vary**, Edit, Extend, Upscale, Share in the row (Vary replaces Retake there:
  it fills the composer and nothing renders until Generate shows the price). Under More: Use as start frame, Reuse
  settings, Compare, Retake now.
- **Saved rigs:** a Rigs row in the composer's settings opens the Rigs sheet: apply (with Undo on the row), delete your
  own, save the composer's rig under a name, and "Make it <name>'s default" with one @character.
- **A model's default rig:** when the prompt's one @character changes to someone with a default rig, it fills only the
  rows still on Auto, with Undo.
- **Results feed:** "Takes" in the composer's top bar: All / Rendering / Finished / Failed, live progress, older pages.
- **Compare:** the square on a finished card (or Compare on a take) marks it; two play side by side over the composer,
  with Play both and Reuse settings under each.

PNGs: `suiteplan_<theme>_<state>_<width>.png` (rigs, rig_applied, feed, compare, take; 360 and 840 dp).
