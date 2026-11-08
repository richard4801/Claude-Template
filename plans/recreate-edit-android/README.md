# Recreate this edit, phase 1 on Android: the Recipe view (WS4, 2026-11-08)

Per plans/recreate-edit.md (APPROVED), build phase 1: pick a reference and see its recipe.

**Flow.** Edit home → "Recreate an edit" → pick a saved video (up to 60 s) → the analysis steps → the recipe.

**The recipe** shows each element's confidence. Anything under 60% is marked "Check".
- The reference: its length, shot count and tempo.
- A timeline strip: the shots in proportion, beat marks (strong beats taller) and the transitions.
- Shots: size and angle, time and length, the brief, and the move, ramp or zoom.
- Text: the words, time, position, animation and nearest style.
- Transitions, with any unrecognised ones flagged.
- The grade: its swatches; it becomes a Look.
- Pacing: average shot, cuts per minute and cuts on the beat.
- The sound, with the "Use this sound" reminder.
- On a tablet, the lower sections sit side by side in a centred column of 880 dp at most.

**Data.**
- `core/.../edit/Recipe.kt` holds the model and a lenient reader that follows the plan's field list.
- WS1 owns the server `recipe` schema. When it lands, only `RecipeJson` and the screen's source change.
- Until then the recipe is a stand-in (`FakeRecipes.cafeTrend()`), and the entry shows **in demo mode only**, so nobody sees a made-up recipe for their own video.

**Next phases** (not built): cast and fill, assemble, the side-by-side compare, and the phone share target (waiting on the platform-rules check).

**Images:**
- `phone_flow_c.png`: Edit home's entry, pick, analysing, recipe.
- `phone_recipe_all_themes.png`: the whole recipe page, themes c, b, a, d.
- `tablet_recipe_c.png`: the recipe at 1280 dp.
