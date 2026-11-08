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

## Playback and shot progress (follow-up)

- **One playhead, both players:** the timecode, a frame back, play / pause and a frame forward sit under the players, and
  on a tablet a playhead line runs across the lanes. While playing, the selected shot follows the playhead.
- **Reference:** its video comes from the authenticated route (`GET …/video`, redirect or bytes; OkHttp drops the token
  on the redirect to storage). It is saved to the cache and played with Media3, kept on the shared playhead.
- **Your edit:** shot by shot, the take each shot comes from (a matched take, or the shot generated for it), cut at the
  reference's cuts and kept on the playhead, with the recipe's text on top. It is muted, so the reference's sound leads.
- **Shot progress:** a shot being made shows its job's progress from the studio's live jobs ("42%" and a bar). A job
  not listed yet (demo mode, or before its first event) shows a calm indeterminate state: a short segment drifting
  slowly, with no spinner and no made-up percentage.

New PNGs: `recreate_<theme>_waiting.png` and `_waiting_tablet.png` (indeterminate); the generating states show 42%.
