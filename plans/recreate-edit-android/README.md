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
- Recipes come from WS1's server (`plans/api.md` "Recreate this edit"): the video is uploaded with the editor's upload, `POST /v1/recreate/references {uploadId, name}` starts the analysis, and the app polls `GET …/{id}` (showing the server's step) until it is `ready` or `failed`.
- `core/.../edit/Recipe.kt` reads `muse.recipe/1` into the view: ids become words ("cu" → "Close-up", "zoom_in" → "Zoom in"), unknown transitions are flagged, unread caption words say so, and a read pose shows "Pose read". It is tested on the server's own fixture (`core/src/test/resources/recipe-v1.json`, a copy of `server/api/test/fixtures/recipe-v1.json` at WS1's f5c06d7).
- Claude's summary and the recipe's gaps ("Not recreated yet") show when present.
- Demo mode runs the same flow on FakeMuseApi with `FakeRecipes.cafeTrendJson()`, in the same schema.
- A server without these endpoints answers "This studio server can't read edits yet".

**Share → MUSE** (built):
- From another app's Share sheet, "Recreate in MUSE" takes either a link (TikTok, Instagram Reel or YouTube; the first link in the shared text) or a saved video, and opens Edit → Recreate with it.
- A link goes to `POST /v1/recreate/references {url}`. The server fetches it only within the platforms' rules (plans/research/platform-download-rules.md).
- When it can't use the link (private, downloads off, too big, blocked, too long), the screen shows the server's message and "Pick the saved video" as the one action. `share_link.png` shows fetching, and a link with downloads turned off.
- A saved video takes the usual upload path.

**Next phases** (not built): cast and fill, assemble, the side-by-side compare, .

**Images:**
- `phone_flow_c.png`: Edit home's entry, pick, analysing, recipe.
- `phone_recipe_all_themes.png`: the whole recipe page, themes c, b, a, d.
- `tablet_recipe_c.png`: the recipe at 1280 dp.
