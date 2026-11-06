# UX audit 2 · Android (video suite, pickers, rig check, Claude chat) · 2026-11-06

_For the parent to merge into `plans/ux-audit-2.md`._ Branch `claude/muse-prompt-scripts` from d75eea9. Same standard as `plans/ux-audit.md`. The work stopped early because priorities changed: everything found so far is listed, fixed or not.

**Scope:** the video composer (empty / filled / preset-collapsed, tool card and Change, chips, input slots, prompt box), every picker (Camera Setup / Angle / Movement / Directed, Style, Look, Lighting, References), the preset gallery, the rig-check row, the Claude chat (Edit-suite panel, phone sheet, Camera stage, Mac offline), the suite hub and the result screen. Code: `ui/screens/suite/**`, `ui/screens/claude/**`, `ui/screens/camera/**`.

**How it was checked:** the existing Roborazzi tests (`SuiteComposerScreenshotTest`, `SuiteComposerFollowupScreenshotTest`, `RigCheckRowScreenshotTest`, `claude/ClaudeChatScreenshotTest`, `SuiteScreenshotTest`, `camera/CameraScreenshotTest`, `SuiteInputSlotsScreenshotTest`) were recorded at 360, 390 and 840 dp in all four themes (A Editorial, B Camera Body, C Soft Tactile, D Creator Pop) and looked at as contact sheets. A new **`AuditSuiteScreenshotTest`** (kept in the repo; 12 cases × 4 themes = 48 renders, PNGs `app/build/outputs/roborazzi/audit2_<theme>_<screen>_<width>.png`) adds the states the others miss: the composer while the catalog loads and when it can't load (real API stand-in), the hub's error, the hub and a take's result at 840 dp, the result at 360 dp, the rig check at 360 dp, and the chat while it opens, when it couldn't open and Mac offline at 840 dp. The code was then read for tap targets, TalkBack labels and wording; contrast was computed from `Theme.kt`.

Severity: **high** = wrong or misleading, or something you can't reach. **med** = visible defect or missing state. **low** = polish / noise.

Owner: **A2** = this audit (fixed here) · **WS1** = workstream 1 (composer bottom bar, Settings sheet, Extend & upscale) · **WS-cam** = Camera Setup wheels (being replaced by the drum picker: blockers only).

## Summary
- **22 findings (owner A2)**: high 4, med 11, low 7. **Fixed 17** (all 4 high, all 11 med... see table: 4 high + 10 med + 3 low), **not fixed 2** (low: A2-19, A2-20), **logged/kept 3** (A2-19's decision, A2-21 art, A2-22).
- **Logged for WS1: 6** (listed separately, not in the 22). Camera Setup wheels: no blockers.
- Member-visible provider/model names: **none found** (engine names only behind `owner` in the Settings sheet's Engine row, the wide bar's Engine pill and Engines (owner); `SuiteRules.memberSafe` strips catalog/estimate text for members).

## Findings (owner A2)

| # | Screen · width/theme | Sev | What was wrong | Where | Status | Before / after |
|---|---|---|---|---|---|---|
| A2-01 | Suite hub · catalog can't load · all | **high** | The error box showed only an icon and "Try again": the reason was never shown (`NoteBox` drops its text when it gets a `content`). "Try again" was 16 dp tall and in the accent (C 3.2:1, D 2.2:1). | `suite/SuiteHub.kt` (hub `NoteBox`) | **FIXED**: the reason and a 48 dp "Try again" in `Muse.link` both go in the content | `plans/ux-audit-2/android/A2-01-before.jpg` / `-after.jpg` |
| A2-02 | Composer · catalog loading / can't load · all | **high** | No loading or error state: a half-built composer with "START FROM A PRESET · 0 presets", "References 0/0", an empty preset row and nothing saying why. | `suite/composer/ComposerScreen.kt` (`PhoneComposer`, `WideComposer`) | **FIXED**: new `CatalogNote` in place of the preset row: "Loading presets and cameras…" or the reason + "Try again" (reloads the catalog); `ComposerUi.catalogNote` / `onRetryCatalog` | `A2-02-before.jpg` / `-after.jpg` |
| A2-03 | Take result · 840 dp all; 360 dp all | **high** | Tablet: `fillMaxWidth(.66f).widthIn(max = 280.dp)` doesn't cap (fill sets the min), so the player was ~550 × 980 dp and the takes strip sat under the Keep/Retake/Edit/Share row (you couldn't pick take 2). Phone: the strip was half under the action row (bottom padding 100 dp < 160 dp the row takes). | `suite/SuiteResultScreen.kt` | **FIXED**: player width = min(66 % of width, 300 dp, what fits above the strip); bottom padding 172 dp | `A2-03-before.jpg` / `-after.jpg` |
| A2-04 | Composer · empty · 360 dp all (390 too) | **high** | The empty "Your shot appears here" card (240 × 200 dp) pushed the preset gallery under the docked composer: preset names cut ("Phone UGC" half gone), the beginner path barely visible. | `ComposerScreen.kt` `RecentTakes` | **FIXED**: the empty card is as tall as a recent take (146 dp) and full width when there are no takes; all presets' names show | `A2-04-before.jpg` / `-after.jpg` |
| A2-05 | Composer · preset collapsed · 360/390 all | med | The picked preset ("Cinematic", 5th) was off-screen in the row, so nothing showed which one you chose; picking one also pushed the tiles ~28 dp down (the 48 dp "Clear" box grew the header). "Clear" was muted text with no TalkBack label. | `ComposerScreen.kt` `PresetRow` | **FIXED**: the row scrolls the picked tile into view; fixed 20 dp header with a `requiredHeight(48.dp)` "Clear" (link colour, "Clear preset"); tiles report `selected` | `A2-05-before.jpg` / `-after.jpg` |
| A2-06 | Composer chips · 840 dp all | med | Same class as the Mac's "Engine · A…": the chip row scrolled sideways with the last chip cut ("LIGHTI…") and values ellipsised at 26 chars ("35mm film, Anamorphic, 50…") while the card had room. | `ComposerScreen.kt` `ChipsRow` | **FIXED**: wide = `FlowRow` (all five chips show) and values up to 40 chars | `A2-06-before.jpg` / `-after.jpg` |
| A2-07 | Composer chips · 360 dp all | med | Only References and Style fit; Camera, Look and Lighting were hidden past the edge with nothing hinting the row scrolls. | `ComposerScreen.kt` `ChipsRow` | **FIXED**: a 28 dp fade at the right edge while there's more to scroll | `A2-07-before.jpg` / `-after.jpg` |
| A2-08 | Input slot cards · all, worst D | low (noise) | Each empty optional card stacked a dashed border, a boxed 8.5 sp "OPTIONAL" badge, a bordered circle "+", a mono caps label and a caption. Filled cards mixed styles ("Demo" bold body vs "START FRAME" mono caps on the photo). | `ComposerScreen.kt` `SlotCard` | **FIXED**: "Optional" is a plain 10.5 sp muted word (no box); on a photo every card's label is the same bold body style | in `A2-07-*` and `A2-04-*` |
| A2-09 | Rig-check row · all, worst D | low (noise) | The row was another outlined box (D: 2 dp black) between the outlined slot cards and the outlined bar. | `suite/RigCheckRow.kt:128` | **FIXED**: tinted panel, no outline | `A2-09-before.jpg` / `-after.jpg` |
| A2-10 | Suite hub · 840 dp all | med | Phone layout stretched: two 400 dp-wide mode tiles a row with 78 dp image strips ("blocky"). | `suite/SuiteHub.kt` | **FIXED**: three tiles a row from 600 dp (empty cells padded), column capped at 960 dp | `A2-10-before.jpg` / `-after.jpg` |
| A2-11 | Suite hub · 360 dp all | med | "Camera stage · Direct the camera in Blender · Directed mo…" ellipsised; the link-card icon box had square corners in the rounded themes (C, D); the bell did nothing when tapped (Home's bell is the real one); "All →" and the suite-off "Copy" were ~16 dp tap targets; recent tiles had no TalkBack label. | `suite/SuiteHub.kt` | **FIXED**: subtitle may wrap to 2 lines; icon box uses the theme radius; bell removed; 48 dp targets with labels ("All takes"); tiles read "<title>, <state>" | `A2-11-before.jpg` / `-after.jpg` |
| A2-12 | Take result · all | med | Keep / Retake / Edit / Share were ~36 dp tall (under 48 dp); takes in the strip didn't tell TalkBack which one is showing. | `SuiteResultScreen.kt` `Action`, `TakeThumb` | **FIXED**: 48 dp min height; `selected` on the shown take | – |
| A2-13 | Claude chat · error/notice text · C, D | med | Failed turn ("Claude couldn't finish this turn"), failed tool chips, notices and the load error were in the accent: Soft Tactile 3.2:1, Creator Pop pink 2.2:1 on the background (fails 4.5:1). | `claude/ClaudeChat.kt` | **FIXED**: `errorInk()` = the accent in A/B, the dark warning brown (`warnPillInk`, ≥ 8:1) in C/D | in `A2-14-*` |
| A2-14 | Claude chat · thread couldn't load · all | med | Only the error line, no way to retry; the header still said "On your Claude plan · answered by your Mac" with a green dot. | `claude/ClaudeChat.kt` | **FIXED**: "Try again" button (new optional `ClaudeChatActions.retry`, wired to `store.load()`); header says "Connecting…" / "Not connected" (grey) until there is a plan status | `A2-14-before.jpg` / `-after.jpg` |
| A2-15 | Claude chat · Mac offline · all | med | "Open in Claude" / "Use the studio API key" were 44 dp tall; "Add MUSE in Connections →" was an 18 dp text link with no role; the notice's tap-to-dismiss had no label. | `claude/ClaudeChat.kt` `ChatBtn`, `OfflineCard` | **FIXED**: 48 dp buttons; the link and the notice are 48 dp rows with role Button (notice reads "…. Dismiss") | `A2-15-before.jpg` / `-after.jpg` |
| A2-16 | Composer · preset collapsed · 840 dp | low | The summary "Draft · 8 s · film look, shallow focus, slo…" was cut beside Generate. | `ComposerScreen.kt` `CollapsedBody` | **FIXED**: up to 2 lines, 300 dp wide, right-aligned | – |
| A2-17 | Camera stage / Directed panel · 360 dp all | med | Session chips cut titles mid-word ("Kitchen dance · in", `take(18)`): same class as "Standar/d". | `camera/CameraEntry.kt:177` | **FIXED**: whole titles in a row that scrolls | `A2-17-before.jpg` / `-after.jpg` |
| A2-18 | Composer chips · D | low (noise) | 2 dp black borders on every chip, beside the 2 dp slot cards, bar buttons and the 2.5 dp card. | `ComposerScreen.kt` `ChipsRow` | **FIXED**: 1.5 dp in D (the card keeps its weight) | in `A2-06-after` |
| A2-19 | All pickers · selected card | low (noise) | A picked card shows both a 2 dp accent outline and a check badge. One is enough (suggest: keep the outline, drop the badge, or the reverse). | `composer/PickerShell.kt` `CheckBadge`, `picked` | **NOT FIXED**: shared with the Camera wheels being replaced; decide with the drum picker | – |
| A2-20 | Claude chat · tablet (840 dp, full screen) | low | Transcript lines run the full 800 dp (long, hard-to-read lines); the panel version (380 dp) is fine. | `claude/ClaudeChat.kt` `ClaudeChatContent` | **NOT FIXED**: stopped early. Suggest `widthIn(max = 640.dp)` centred for the transcript | – |
| A2-21 | Hub mode tiles · all | low | Shot and Storyboard use near-identical café stills; Movement's featured tiles are all the same mannequin still. Repetition reads as noise. | `SuiteHub.kt SUITE_MODES`, preview data | **LOGGED** (art, not code): give Storyboard a distinct still; move loops will fix Movement | – |
| A2-22 | Chat · Mac offline | low | "Your Mac is offline" appears twice (header status and the card title). | `ClaudeChat.kt` | Kept: the card stands alone when scrolled; noted only | – |

Count: 22 (high 4, med 11, low 7). Fixed 17; not fixed 2 (A2-19, A2-20); logged/kept 3 (A2-21, A2-22 and A2-19's decision).

## Logged for WS1 (not edited here)
1. **med** · Wide bar (840 dp, all themes): the pill row scrolls under Generate with the last pill cut ("Speaking C…" / "Speaking Auto" clipped) and no scroll hint. `ComposerScreen.kt WideBar`. Suggest a `FlowRow` or the same right-edge fade as the chips (A2-07).
2. **med** · Phone and wide Generate: while the estimate loads (and in the catalog-error state) it shows "–" at 50 % alpha with no sign that it's loading; in C/D the dimmed white "–" on a light fill is unreadable. `RoundGenerate`, `WideGenerate`. Suggest a small spinner or "…" and a disabled colour, not alpha.
3. **low** · Settings sheet · 360 dp: "Cinema · Best camera work and …" ellipsised; the detail column could take 2 lines. `ComposerSheets.kt SettingsBody`.
4. **low** · Settings sheet footer blocker text uses `warn` (C 3.6:1); use `warnPillInk` like A2-13.
5. **low (noise)** · Phone bar in D: Quality and Settings buttons with 2 dp black borders next to the round Generate; consider 1.5 dp as for the chips (A2-18).
6. **info** · Character swap add-on pills include "Upscale" (Extend & upscale): not touched.

## Camera Setup wheels (WS-cam, blockers only)
No blockers. Noted for the drum picker: at 840 dp the wheels are wide flat cards with 62 dp previews, and side cards at 42 % alpha with captions cut at the edge.

## Files changed
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/suite/composer/ComposerScreen.kt` (A2-02, 04, 05, 06, 07, 08, 16, 18; bottom bar untouched)
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/suite/RigCheckRow.kt` (A2-09)
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/suite/SuiteHub.kt` (A2-01, 10, 11)
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/suite/SuiteResultScreen.kt` (A2-03, 12)
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/claude/ClaudeChat.kt` (A2-13, 14, 15; `ClaudeChatActions.retry` is a new optional parameter, backwards-compatible)
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/camera/CameraEntry.kt` (A2-17)
- new test `android/app/src/test/kotlin/studio/muse/app/AuditSuiteScreenshotTest.kt`
- Kit.kt / Theme.kt: not changed.

## Tests
`./gradlew :core:test :app:testDebugUnitTest -Proborazzi.test.record=true` (counted from `build/test-results` XML): **core 105/105, app 1303/1303 passed** (0 failures, 0 errors, 0 skipped; app includes the 48 new `AuditSuiteScreenshotTest` renders). All changed screenshots re-recorded.
