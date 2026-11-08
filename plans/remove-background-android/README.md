# Remove background on Android: alpha matte and tap to keep (WS4, 2026-11-08)

This is Android's side of workstream 1's contract (bed290b; plans/api.md "MatteResult", "KeepPoint", "VideoClip.alphaMatte").

- **Model (core):**
  - `VideoClip.alphaMatte {asset, invert?}` is read and written with the project, and checked like the server: "alphaMatte.asset: must be a video asset".
  - `PlannedClip.sourceUsAt(t)` maps timeline time to the clip's source time through trims and speed pieces. The matte is aligned with the source.
  - Tests: `AlphaMatteTest`.
- **Rendering:**
  - `platform/edit/AlphaMatteEffect.kt` is the first of the clip's effects, ahead of crop, look, mask and transform.
  - It decodes the matte video itself (MediaExtractor and MediaCodec, Y plane only), at the source time each frame shows, and uploads it as a luminance texture.
  - The matte's luma becomes the clip's alpha; `invert` flips it. The matte's rotation is undone in the shader.
  - With no readable matte, the clip shows unmatted.
  - Needs a real device to confirm: the presentation time the effect sees, which is taken to be the composition's (as `TransitionFxEffect` does), and matte rotation.
- **Editor:**
  - "Remove background" (the person) and "Tap what to keep instead" are in Effects → Mask & key.
  - A finished matte job sets `alphaMatte` on the original clip and drops its chroma key. The device then fetches the matte file and rebuilds the preview.
  - An older server's green composite still goes on a keyed overlay track.
- **Tap to keep:**
  - Pause and tap the picture: Keep or Leave out, 1–10 taps, with at least one keep.
  - Each tap records the clip's source time at the playhead.
  - The price comes from an estimate with the points: its own price, 15 + 3·d GPU seconds. It is shown on the "Cut out · about $…" button, so each press is one run.
  - On the phone the sheet is shorter and has no scrim while tapping, so the picture takes the taps.
- **Demo:**
  - FakeMuseApi returns `{asset, alpha: true, mode, points?}`.
  - It prices tap to keep separately.
  - It refuses bad taps with plain messages ("Tap at least one thing to keep").
- **Tests:**
  - `EditSuiteControllerTest.removeBackgroundSetsAnAlphaMatte`: the matte goes on the clip and the asset is fetched; the taps and their source time are sent, the price is shown, and the panel closes after the run.
  - Screenshots `edit_<t>_keep` and `edit_<t>_tablet_keep` (`tap_to_keep.png`: phone in theme c, tablet in theme b).
