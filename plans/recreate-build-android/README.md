# Recreate this edit, phases 2–3 on Android (built)

The owner-approved Mac Recipe and Compare design (`plans/recreate/built_*.png`), adapted to phone and tablet, on WS1's
server flow (`server/api/test/recreate-e2e.test.ts`): match → estimate → confirm → fill → poll → apply → compare.

- **Recipe:** shot tiles badged Yours / To generate / Generating, the selected shot (what happens, camera, speed, % sure)
  with how it will be made and its price, "Use one of my takes", then the whole edit and its Look.
- **Owner note 1, softened Look swatches:** `RecreateSwatches.soften` in core, the same rule as the Mac's (same output on
  the Mac's example; `RecreateTest`).
- **Owner note 2, the total beside Build:** in the top bar on a tablet, in the bottom bar on a phone. One confirmation
  lists each shot to generate with its price and length ("A 3 s shot, cut to 2.0 s") before anything is spent.
- **Generating:** "3 from your takes, 4 generating / The edit is built when they're ready." The fill is watched every
  3 s, then the edit is applied into an edit session and Compare opens.
- **Compare:** Overall, Cuts, Text, Speed, Look, Shots; Reference and Your edit side by side; each shot's score; Fix shot N
  (the weakest); Open in the editor.

Demo mode runs the same flow on FakeMuseApi and never spends (`RecreateBuildTest` checks the balance). Players show
stand-in tones from the softened Look (no pictures of anyone); with a server the reference shows its poster.

Files: `core/.../edit/Recreate.kt`, `app/.../edit/RecreateBuild.kt` (model), `RecreateBuildUi.kt` (screen),
`RecipeScreen.kt` (wiring), MuseApi / HttpMuseApi / FakeMuseApi (match, fill, estimate, fill slot, apply).

PNGs: `recreate_<theme>_<state>.png`, themes a–d; states recipe, confirm, generating, compare_phone, picker and the
`_tablet` versions (1280×800).
