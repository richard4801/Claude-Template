# UX audit 2 · Android + Mac (workstream 4, 2026-11-06)

The owner asked for a second full audit, to the standard of `plans/ux-audit.md`, of everything built since the first one and already in production:
- the video composer, every picker and the preset gallery;
- the rig-check row;
- the Claude chat;
- the Style tiles;
- the suite hub and results.

**How it was checked:**
- **Android:** at 360/390 dp and on an 840 dp tablet, with Roborazzi renders reviewed. Before and after images are in `plans/ux-audit-2/android/`.
- **Mac:** at 1000/1280/1440 px, from the SwiftUI code. Contrast was computed from the theme tokens, and anything that needs a real Mac is marked.
- **Themes:** all four.

**The audit was stopped early by the owner's new priority**, the whole-app design review (`plans/design-direction.md`). The findings below are folded into that work. The restyle won't undo these fixes; what's still open moves to it.

## Summary
| | Android | Mac |
|---|---|---|
| Findings | 22: high 4, med 10, low 8 | 40: high 5, med 16, low 19 |
| Fixed | **18** (all high and med) | **30** (4 of 5 high; the fifth is WS1's bottom bar) |
| Not fixed (with reason) | 2 low | 5 low |
| Logged for WS1 (bottom bar, pills, Extend & upscale) | 6 | 5 + the bottom-bar list B1–B5 |

**The owner's Mac bottom-bar bug ("Standar/d", "Speak/ing", "Engine · A…", "GENERATE…" with no price):**
- **Cause:** the window minimum is 1100 px and the composer card is capped at 960, so the bar always gets about 948–960 px. It needs 978–1207 px.
- **Fix:** WS1 has the fix order (B1 in the Mac section): Generate keeps its size and its price, pills become icon plus value, and pricing info becomes an ⓘ. That brings the bar down to about 640 px for a member and 700 for the owner.

**Not found on either app:** provider or model names visible to members.

**Tests:**
- Android: core 105 and app 1303, with 0 failures (including the new `AuditSuiteScreenshotTest`, 48 states).
- MuseCore: the new `UxAudit2Tests` run in Mac CI.

---

## Android

_For the parent to merge into `plans/ux-audit-2.md`._ Branch `claude/muse-prompt-scripts` from d75eea9. Same standard as `plans/ux-audit.md`. The work stopped early because priorities changed: everything found so far is listed, fixed or not.

**Scope:** the video composer (empty / filled / preset-collapsed, tool card and Change, chips, input slots, prompt box), every picker (Camera Setup / Angle / Movement / Directed, Style, Look, Lighting, References), the preset gallery, the rig-check row, the Claude chat (Edit-suite panel, phone sheet, Camera stage, Mac offline), the suite hub and the result screen. Code: `ui/screens/suite/**`, `ui/screens/claude/**`, `ui/screens/camera/**`.

**How it was checked:** the existing Roborazzi tests (`SuiteComposerScreenshotTest`, `SuiteComposerFollowupScreenshotTest`, `RigCheckRowScreenshotTest`, `claude/ClaudeChatScreenshotTest`, `SuiteScreenshotTest`, `camera/CameraScreenshotTest`, `SuiteInputSlotsScreenshotTest`) were recorded at 360, 390 and 840 dp in all four themes (A Editorial, B Camera Body, C Soft Tactile, D Creator Pop) and looked at as contact sheets. A new **`AuditSuiteScreenshotTest`** (kept in the repo; 12 cases × 4 themes = 48 renders, PNGs `app/build/outputs/roborazzi/audit2_<theme>_<screen>_<width>.png`) adds the states the others miss: the composer while the catalog loads and when it can't load (real API stand-in), the hub's error, the hub and a take's result at 840 dp, the result at 360 dp, the rig check at 360 dp, and the chat while it opens, when it couldn't open and Mac offline at 840 dp. The code was then read for tap targets, TalkBack labels and wording; contrast was computed from `Theme.kt`.

Severity: **high** = wrong or misleading, or something you can't reach. **med** = visible defect or missing state. **low** = polish / noise.

Owner: **A2** = this audit (fixed here) · **WS1** = workstream 1 (composer bottom bar, Settings sheet, Extend & upscale) · **WS-cam** = Camera Setup wheels (being replaced by the drum picker: blockers only).

### Summary
- **22 findings (owner A2)**: high 4, med 10, low 8. **Fixed 18** (all 4 high, all 10 med, 4 low), **not fixed 2** (low: A2-19, A2-20), **logged/kept 2** (low: A2-21 art, A2-22).
- **Logged for WS1: 6** (listed separately, not in the 22). Camera Setup wheels: no blockers.
- Member-visible provider/model names: **none found** (engine names only behind `owner` in the Settings sheet's Engine row, the wide bar's Engine pill and Engines (owner); `SuiteRules.memberSafe` strips catalog/estimate text for members).

### Findings (owner A2)

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

Count: 22 (high 4, med 10, low 8). Fixed 18; not fixed 2 (A2-19, A2-20); logged/kept 2 (A2-21, A2-22).

### Logged for WS1 (not edited here)
1. **med** · Wide bar (840 dp, all themes): the pill row scrolls under Generate with the last pill cut ("Speaking C…" / "Speaking Auto" clipped) and no scroll hint. `ComposerScreen.kt WideBar`. Suggest a `FlowRow` or the same right-edge fade as the chips (A2-07).
2. **med** · Phone and wide Generate: while the estimate loads (and in the catalog-error state) it shows "–" at 50 % alpha with no sign that it's loading; in C/D the dimmed white "–" on a light fill is unreadable. `RoundGenerate`, `WideGenerate`. Suggest a small spinner or "…" and a disabled colour, not alpha.
3. **low** · Settings sheet · 360 dp: "Cinema · Best camera work and …" ellipsised; the detail column could take 2 lines. `ComposerSheets.kt SettingsBody`.
4. **low** · Settings sheet footer blocker text uses `warn` (C 3.6:1); use `warnPillInk` like A2-13.
5. **low (noise)** · Phone bar in D: Quality and Settings buttons with 2 dp black borders next to the round Generate; consider 1.5 dp as for the chips (A2-18).
6. **info** · Character swap add-on pills include "Upscale" (Extend & upscale): not touched.

### Camera Setup wheels (WS-cam, blockers only)
No blockers. Noted for the drum picker: at 840 dp the wheels are wide flat cards with 62 dp previews, and side cards at 42 % alpha with captions cut at the edge.

### Files changed
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/suite/composer/ComposerScreen.kt` (A2-02, 04, 05, 06, 07, 08, 16, 18; bottom bar untouched)
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/suite/RigCheckRow.kt` (A2-09)
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/suite/SuiteHub.kt` (A2-01, 10, 11)
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/suite/SuiteResultScreen.kt` (A2-03, 12)
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/claude/ClaudeChat.kt` (A2-13, 14, 15; `ClaudeChatActions.retry` is a new optional parameter, backwards-compatible)
- `android/app/src/main/kotlin/studio/muse/app/ui/screens/camera/CameraEntry.kt` (A2-17)
- new test `android/app/src/test/kotlin/studio/muse/app/AuditSuiteScreenshotTest.kt`
- Kit.kt / Theme.kt: not changed.

### Tests
`./gradlew :core:test :app:testDebugUnitTest -Proborazzi.test.record=true` (counted from `build/test-results` XML): **core 105/105, app 1303/1303 passed** (0 failures, 0 errors, 0 skipped; app includes the 48 new `AuditSuiteScreenshotTest` renders). All changed screenshots re-recorded.

---

## Mac

_Branch `claude/muse-prompt-scripts` at d75eea9 (production). The parent merges this into `plans/ux-audit-2.md`. Same standard as `plans/ux-audit.md`._

**Scope:** everything built since the first audit: the video composer (empty, filled, preset-collapsed; tool card and Change; chips; slot cards; the token prompt; the bottom bar), every picker (Camera Setup/Angle/Movement/Directed, Style/Look/Lighting, References, the picker shell) and the preset gallery, the rig-check row (every state), the Claude chat (Edit suite panel, Camera stage's Direct with Claude, "Mac offline"), the Video suite hub and results, the sidebar's suite group.

**How:** no Swift toolchain here, so every view was read line by line and laid out by hand. Mac CI compiles it after the parent pushes. Widths:

| Window | Sidebar | Page content | Composer card (`maxWidth 960`, 32 px gutters) | Bottom bar inside (16 + 12 padding) |
|---|---|---|---|---|
| 1100 (window minimum, `MuseApp.swift:20`) | 72 (compact < 1240) | 1028 | **960** | 932 |
| 1240–1279 | 228 | 1012–1051 | **948–960** | 920–932 |
| 1280 | 228 | 1052 | **960** | 932 |
| 1440 | 228 | 1212 | **960** | 932 |

So the composer card is about **950–960 px at every window size**. That's the "~1000 px" the owner saw: the bottom-bar bug isn't tied to a small window, it happens everywhere. Contrast is the WCAG 2.x ratio of the `Theme.get` tokens, computed with the same formula as `MuseCore/Contrast.swift`; the new pairs are in `MuseCoreTests/UxAudit2Tests`. Themes: A Editorial, B Camera Body, C Soft Tactile, D Creator Pop. Pickers are always B.

**Mac?** = needs a real Mac to confirm the look or behaviour (yes / VoiceOver / no).
**Owner** = the workstream that owns the area: WS1 video suite (composer, pickers, hub, nav), WS2 camera/Directed + Claude chat, WS3 Edit suite + rig check. "FIXED" = fixed in this audit, in the owner's file.

### Summary

| | High | Med | Low | Total |
|---|---|---|---|---|
| Findings | 5 | 16 | 19 | **40** |
| FIXED | 4 | 15 | 11 | **30** |
| NOT FIXED (why given) | 0 | 0 | 5 | 5 |
| LOGGED for WS1 (bottom bar, design calls) | 1 | 1 | 3 | 5 (+ the bar list B1–B5 below) |

By owner (M2-11 and M2-34 are shared with WS2 and counted under WS1): WS1 34 (25 fixed, 5 logged, 4 not fixed), WS2 4 (all fixed), WS3 2 (1 fixed, 1 not fixed).

**Found nothing:** no provider or model names in member-visible text in scope. Tier names and details come from `server/api/src/suite/registry.ts` ("Quick preview", "Everyday quality"…). The Engine pill and the Engines sheet are owner-only (`store.isOwner`). Claude is named only in the owner-only chat. The pricing popover filters warnings through `SuiteText.isMemberSafe`. Esc closes every picker, the tool browser, the faces sheet and the engines sheet (`onExitCommand` / `.cancelAction`).

---

### Findings

| # | Screen · width/theme | Sev | What's wrong (before → after) | Where | Mac? | Owner | Status |
|---|---|---|---|---|---|---|---|
| M2-01 | Composer bottom bar · **every width** (bar 920–932 px) · all | high | The owner's bug. The pills, "How is this priced?" and Generate need about 978 px for a member with one take, 1071 with two takes ("GENERATE · 8 S · $0.64 · 2 TAKES" is ≈ 342 px at 9.3 px/char), and 1114–1207 px for the owner (plus "Engine · Auto", 128 px). The HStack squeezes every Text: pill labels without `lineLimit` wrap inside their 34 px frames ("Standar/d", "Speak/ing"), the Engine label truncates ("Engine · A…") and Generate (`lineLimit(1)`) truncates to "GENERATE…", so the price is lost. | `Composer/ComposerBottomBar.swift:17-43, 213-244, 391-399` | no | WS1 | **LOGGED for WS1** (fix list below) |
| M2-02 | Composer, typing `@` or `#` · all | high | The suggestion list (up to 15 rows × 40 px, dropping below the prompt box) was clipped by the card's `.clipShape`: only ≈ 3 rows showed, cut at the card's edge. It was also drawn *under* the rig-check row and the bottom bar (later siblings), whose pills took its clicks. → The card isn't clipped any more. Its fill, border and shadow are one rounded shape in `.background`, and the prompt area has `zIndex(1)`, so the list floats over the rest of the card and the presets (the card already had `zIndex(2)`). | `Composer/ComposerView.swift:212, 219-228` (was 216-220) | yes | WS1 | FIXED |
| M2-03 | Camera picker → Directed (663 px content) · Camera stage at 1100–1280 · all | high | `DirectedBody` had `minWidth 560` + a fixed 404 px chat = 964 px. In the picker's 663 px the HStack ran ≈ 150 px off **both** edges, clipped by the shell, so the chat was cut. In Camera stage (content − 290 sidebar = 737 at 1100, 761 at 1280) the chat ran 200–230 px off the right edge. → Centre `minWidth 340`. Chat `minWidth 300, idealWidth 404, maxWidth 404` (it takes ≈ 331 px in the picker, ≈ 368–380 at 1100–1280, 404 from 1440). The session strip is a `ViewThatFits`: one row, else id + title / view switch / meta + Re-render. | `Camera/DirectedViews.swift:27, 88-150`; `Camera/DirectChatPanel.swift:36-38` | yes | WS2 | FIXED (width). Height: M2-34 |
| M2-04 | Video suite hub · 1100–1440 · all | high | Recent takes, Camera stage and Cast shared the row as flexible + flexible + 260, so the 4 take tiles got 73 px (1100), 76 (1280) or 96 (1440). The fixed-size "WAITING TO START" tag (≈ 116 px) ran into the next tile, and Camera stage got half the row for one line of text. → Recent takes get the row (≈ 676 px, tiles at their 110 px). Camera stage moves under Cast in the 260 px column. The tag says "In line" (the picture already shows "Waiting to start" / "#2 in line"). | `Suite/SuiteHubView.swift:62-72, 193` | yes | WS1 | FIXED |
| M2-05 | Result pane "Ready", storyboard tags · **B** | high | Filled tags draw white text: on B's green #7BD88F that's **1.74:1**, on amber #F2A93B 2.0:1, on red #E5483B 3.95:1. → `SuiteTag` picks white or #111111, whichever reads (`Contrast.bestInk`, MuseCore, tested). The filled "Ready" uses `goodInk` (D's plain green #0E8A4F reaches only 4.41:1 with either ink). | `Suite/SuiteComponents.swift:35, 42-48, 207`; `Suite/StoryboardView.swift:214` | no | WS1 | FIXED + test |
| M2-06 | Composer prompt, after a theme switch · all | med | The NSTextView was only re-filled when the tokens changed, so a theme switch left the old theme's ink and chip plates. A → B: #141210 text on the #17191B card ≈ 1.1:1, invisible until you type. → The coordinator remembers the theme it drew (`shownTheme`) and redraws the text, the chips and the caret colour when it changes. | `Composer/PromptEditor.swift:400-408, 415, 449` | yes | WS1 | FIXED |
| M2-07 | Prompt chips' `@` / `#` · C, D | med | The sigil was the accent on the chip plate (surface2): C **3.25:1**, D **2.03:1** (pink on peach). → `link` (C 4.77, D 5.17; A/B unchanged). | `Composer/PromptEditor.swift:539-540` | no | WS1 | FIXED + test |
| M2-08 | Composer card · B, C, D | med | A square `Rectangle` border inside a rounded `clipShape`: the corners (radius 14 / 28 / 20) had no border, with visible gaps at all four corners. The 35 px / y 26 / 12 % shadow read as a heavy slab on the light themes. → A rounded border on the same shape. The shadow is radius 22, y 12, 8 %, and off in B, where it was never visible. | `Composer/ComposerView.swift:219-228` | yes | WS1 | FIXED |
| M2-09 | Composer chips row · all | med | 5 chips sat in a hidden horizontal `ScrollView`. With values set (each chip up to ≈ 294 px, its value capped at 190) the row overflows the 928 px body and the last chips were cut at the edge with no scroll bar. → `FlowLayout`: the chips wrap to a second line. | `Composer/ComposerView.swift:231-236` | yes | WS1 | FIXED |
| M2-10 | Hub mode tiles · 1100–1439 · all | med | 6 tiles in an adaptive grid (min 160) gave 5 + 1, a lone tile on row 2. At 1440 there were 6 tiles of ≈ 181 px where "Talking · lipsync" + "COMING SOON" truncated. → `SuiteLayout.balancedColumns` (MuseCore, tested): the fewest rows, then the fewest empty places, min 200 px. Now 3 + 3 at every width. Tiles get the theme's card radius like the composer card. | `Suite/SuiteHubView.swift:92-104, 116-118` | yes | WS1 | FIXED + test |
| M2-11 | Hub cast "Locked / Needs close-ups", result tags, Direct "● Live" · C, D | med | Outline-tag text in `good` / `warn`: D good 4.41:1 on white, C warn **3.61:1** on bg (4.09 on surface), D warn 4.46:1 on bg. → `goodInk` / `warnInk` (≥ 6.2:1 everywhere). | `Suite/SuiteHubView.swift:190, 238`; `Camera/DirectChatPanel.swift:52-54` | no | WS1 / WS2 | FIXED + test |
| M2-12 | Claude chat errors, failed tool chips, apply errors, Connections "Last error" · C, D | med | Errors were drawn in the accent: pink in D (**2.36:1** on white) and *green* in C (3.58:1; green for an error, too). → `rec` (red) in every theme (4.47–6.29:1). | `Claude/ClaudeChatView.swift:116, 252-254`; `Camera/DirectChatPanel.swift:86, 150-152, 177`; `Camera/DirectedViews.swift:76`; `Claude/ClaudeConnectionsSection.swift:115-117` | no | WS2 | FIXED + test |
| M2-13 | Claude chat composer (Edit panel, Camera stage) | med | Send (paper plane) and Stop were icon-only with `.help` but no VoiceOver label, so they read as "button". → "Send to Claude" / "Stop Claude", also on the API-key chat's Send. | `Claude/ClaudeChatView.swift:301, 311`; `Camera/DirectChatPanel.swift:229` | VoiceOver | WS2 | FIXED |
| M2-14 | Camera → Movement tiles (≈ 143 px) | med | The badge "BETTER DONE IN EDIT" is ≈ 148 px in the 127 px between the paddings. With no `lineLimit` it wrapped to 2 lines inside a 20 px capsule, so the text was clipped. → "Better in Edit" (≈ 116 px), `lineLimit(1)`, `minimumScaleFactor(0.8)`. VoiceOver still says "better done in Edit". | `Composer/CameraPicker.swift:478, 497-501` | yes | WS1 | FIXED |
| M2-15 | Look / Lighting / Style / Movement tiles | med | Noise: a picked tile had a 2 px amber outline **and** an amber check badge on the picture (and Movement added talk-safe / Edit badges on top). → The outline alone; the check badges are gone from option and move tiles (VoiceOver keeps ", selected" / ", in the prompt"). Wheels keep theirs (M2-35). | `Composer/PickerShell.swift:257-300`; `Composer/CameraPicker.swift:471-487` | no | WS1 | FIXED |
| M2-16 | Camera stage, Direct with Claude status rows · Mac app | med | The Blender row said "**Mac app offline**" on the Mac app itself, and the sidebar line said "Blender on Mac · offline". → On the Mac: "Relay off · turn it on in Connections" (`CameraStatus.blender(…, thisMac: true)`, default wording unchanged for other callers) and "Blender relay off". | `MuseCore/Camera/CameraText.swift:140-160`; `Camera/DirectChatPanel.swift:58`; `Camera/CameraEntry.swift:67` | no | WS2 | FIXED + test |
| M2-17 | Edit suite → Claude panel | med | Two stacked headers: the panel's (Claude badge · "Shared with Claude" · ✕ · Chat/History) and then the chat's own title row + rule with the edit's title. → The chat inside the panel has `showsHeader: false`. The streaming caret and Stop still show it's busy. | `Edit/EditSuiteClaude.swift:177-178` | yes | WS3 | FIXED |
| M2-18 | Camera → Movement · motion | med | Every visible move tile autoplays its loop (`autoplay: true`): 8–12 muted players at once, the busiest page in the app, even with Reduce motion on. → With Reduce motion the loops play only under the pointer. Default autoplay is a design call, **LOGGED for WS1**: suggest hover-only, or only the first row. | `Composer/PreviewView.swift:17-37` | yes | WS1 | FIXED (Reduce motion) / LOGGED |
| M2-19 | Composer slots, collapsed composer, preset tiles · C, D (B) | med | Blocky mix: empty slots, People, the clip, the filled character, the 3 shape tiles and preset tiles were square in every theme. Beside them, a filled `InputSlotTile` used `cardRadius` (28 px on a 104 px tile in C) inside a rounded card. → All of them use `imageRadius` (A 0, B 10, C 18, D 14). The preset tile's selection ring follows the radius and isn't clipped by the strip any more (inset 4 → 6 px). | `Composer/ComposerSlotViews.swift:55-66, 88-91, 114-133, 200-203, 307-313`; `Suite/InputSlotViews.swift:127`; `Composer/ComposerView.swift:150-185` | yes | WS1 | FIXED |
| M2-20 | Composer empty slot cards (Shot: 3 in a row) | med | Noise: each card had a dashed outline + a ringed "+" disc + a boxed "OPTIONAL" pill, i.e. 3 outlines per card and 9 in the row. → Dashed outline only: the disc is a plain surface2 fill and "OPTIONAL" a muted caption. | `Composer/ComposerSlotViews.swift:112-137` | yes | WS1 | FIXED |
| M2-21 | Composer prompt placeholder · A, C, D | low | A fixed #8C847A: 3.39 / 3.24 / 3.69:1 on the card. → `muted` (5.26–7.98:1). | `Composer/PromptEditor.swift:49` | no | WS1 | FIXED + test |
| M2-22 | Sidebar suite group "Soon" · all | low | `muted` at 70 % opacity: A 2.87, C 2.89, B 4.39, D (white on blue) 3.69:1. → Full `muted` / white. | `Suite/SuiteNav.swift:18` | no | WS1 | FIXED + test |
| M2-23 | Tool card row (Add to storyboard, Engines) | low | Bare SF Symbols as buttons: ≈ 16 × 16 px hit area. → 28 × 28 frame with `contentShape`. | `Composer/ComposerView.swift:341-352` | no | WS1 | FIXED |
| M2-24 | Filled CHARACTER slot | low | The photo button had no label (VoiceOver: "image"). The hidden ✕ in Swap stayed in the accessibility tree. → "Character: Noor. Change"; the ✕ is hidden from VoiceOver in Swap. | `Composer/ComposerSlotViews.swift:175-200` | VoiceOver | WS1 | FIXED |
| M2-25 | Hub recent take tiles | low | No VoiceOver label (the composer's identical row had one). → "Title, ready / rendering N percent / …". | `Suite/SuiteHubView.swift:176-190` | VoiceOver | WS1 | FIXED |
| M2-26 | Preset tiles (composer and Change) | low | A white "play" badge on every tile, but tiles are stills and nothing plays. → Removed. | `Composer/ComposerView.swift:173-185` | no | WS1 | FIXED |
| M2-27 | Camera → Movement header | low | "Tap to add to your prompt" on a Mac. → "Click…". | `Composer/CameraPicker.swift:415` | no | WS1 | FIXED |
| M2-28 | Picker shell left rail | low | The "has a value" dot's label sat inside the button label, so VoiceOver never read it. → The row reads "Lens, set" / "Directed, owner" (+ ", selected"). | `Composer/PickerShell.swift:178-188` | VoiceOver | WS1 | FIXED |
| M2-29 | Video suite loading · all | low | A bare spinner. → Spinner + "Loading the Video suite…". | `Suite/SuiteHubView.swift:32-37` | no | WS1 | FIXED |
| M2-30 | "Test renders · free" badge tooltip · members | low | The tooltip "(SUITE_MODE=mock)", server jargon, showed for members too. → Members: "Renders here are free test patterns for now"; the owner keeps the variable. | `Suite/SuiteComponents.swift:56-61` | no | WS1 | FIXED |
| M2-31 | Composer header "VIDEO SUITE" | low | A hidden back button with no tooltip or label. → `.help` + VoiceOver "Back to the Video suite". | `Composer/ComposerView.swift:65-70` | no | WS1 | FIXED |
| M2-32 | Pickers, tool browser (ZStack overlays) | low | They don't trap keyboard focus: Tab can reach the composer behind the dim (as M4-40). Esc does close them. | `PickerShell.swift:74-93`, `ComposerSlotViews.swift:322-335` | yes | WS1 | NOT FIXED: the focus order needs a Mac. Moving to a real sheet is a bigger change |
| M2-33 | Prompt chips · VoiceOver | low | Chips are `NSTextAttachment` images with no accessible text, so VoiceOver likely reads "attachment" / U+FFFC instead of "@Noor" or "#Dolly in". | `Composer/PromptEditor.swift:430-440` | VoiceOver | WS1 | NOT FIXED: needs a Mac to hear what is read. Suggest an attachment cell with `accessibilityLabel`, or a hidden text mirror |
| M2-34 | Camera picker → Directed · height | med | The 840 × 540 shell leaves ≈ 478 px for tabs (40) + session strip (40, or ≈ 110 in its 2-row form) + plan canvas (`minHeight 260`) + legend + timeline (≈ 120), which overflows vertically. The D6 body was designed full-screen. | `PickerShell.swift:86, 235-237`; `DirectedViews.swift:62-82` | yes | WS1 / WS2 | LOGGED: give this step "Open in Camera stage" (full page), or let the shell grow to ≈ 1000 × 680 for it |
| M2-35 | Camera → Setup / Angle wheels | low | Not blockers (the Setup wheels are being replaced by the drum picker): the chevrons are 18 × 18 px. The picked card has 3 marks (2 px outline + check badge + amber glow). Setup's 4 wheels need 661 px of the 663. | `Composer/CameraPicker.swift:86-151` | yes | WS1 | LOGGED for the drum picker: one mark (outline), ≥ 24 px chevrons |
| M2-36 | Style / Tempo tiles with no poster | low | The fallback "type" tile shows the name big on the gradient **and** again under it. | `Composer/PickerShell.swift:283-288, 300` | no | WS1 | NOT FIXED: only when a poster is missing (genres/tempos posters are bundled from `design/previews`) |
| M2-37 | Rig-check row | low | ✕ and "show fewer" are 20 × 22 px. All states were checked: none (takes no room), one, "+N", expanded, tip (link dot) vs warning (warn dot, ≥ 4.09:1 as a UI part), dismissed. The reason truncates with the whole line in the tooltip and in VoiceOver; the fix buttons are `fixedSize` so the reason gives way first. | `Suite/RigCheckRow.swift:256-270` | no | WS3 | NOT FIXED: 22 pt is the standard inline small-control height and matches the fix buttons |
| M2-38 | Empty slot card dashed outline · A, C | low | `muted` at 55 %: 2.2:1 against bg (WCAG 1.4.11 asks 3:1 for a control's boundary). | `Composer/ComposerSlotViews.swift:130` | no | WS1 | NOT FIXED: the "+" disc and the caps label identify the control. Raising it re-adds noise (M2-20) |
| M2-39 | Composer page · 720 px tall window | low | 178 px take tiles above the composer push its bottom bar (and Generate) below the fold on a 720 px window. | `Composer/ComposerView.swift:24-31, 104-110` | yes | WS1 | LOGGED: design call (smaller tiles or the row under the composer) |
| M2-40 | Hub "Recent takes" | low | With no suite jobs it falls back to *every* job, so photoshoots show as video takes. | `Suite/SuiteHubView.swift:145-148`; `App/AppStore+Suite.swift:422-425` | no | WS1 | LOGGED: product call (empty state vs fallback) |

"file:line" is the line after the fix unless "was" is given.

---

### For WS1 (do not edit here): the bottom bar, the Mac pills, Extend & upscale

**B1 · high · the owner's ~1000 px bug** (`ComposerBottomBar.swift:17-43`). Measured at a 932 px bar (1100/1280/1440 windows alike):

| Item | ≈ px |
|---|---|
| Quality "Standard ▾" | 112 |
| Shape "9:16" | 71 |
| Length "8s" | 58 |
| Sound "Sound On" | 104 |
| Speaking "Speaking Auto" | 135 |
| Takes "1 /4" | 69 |
| Engine "Engine · Auto" (owner) | 128 |
| gaps 8 × 8, Spacer min 8 | 72 |
| "How is this priced?" | 108 |
| Generate "GENERATE · 8 S · $0.64" / "… · 2 TAKES" | 249 / 342 |
| **Member total** | **978 / 1071** |
| **Owner total** | **1114 / 1207** |

Suggested fix, in order (each one alone isn't enough for the owner):
1. **Never squeeze Generate**: `GenerateButton` label `.fixedSize()` and the button `.layoutPriority(2)`. Every pill label gets `.lineLimit(1).fixedSize()` so pills don't wrap; whatever has to give, gives by the rules below.
2. **Drop the duplicated titles**: Sound and Speaking become icon + value ("🔈 On", "💬 Auto", ≈ 66 / 70 px), with the title in `.help` and in `.accessibilityLabel("Sound, On")`. That saves ≈ 100 px. (Today the pills have no VoiceOver label at all, only `.help`: B2.)
3. **Move "How is this priced?" off the bar**: an ⓘ button (24 px) right before Generate opening the same popover (it is already inside the Quality popover). That saves ≈ 90 px.
4. **Shorter Generate**: the server's `buttonLabel` repeats seconds and takes that the Length and Takes pills already show. On the bar, show "Generate · $0.64" (≈ 160 px, `GeneratePrice` can format it from `estimate`) and keep the full `priceLine` in the tooltip and VoiceOver.
5. **Owner's Engine pill icon-only** (server.rack + a dot when pinned, label in the tooltip and the popover title). The engine name is owner-only but was the longest pill.
6. **Fallback**: wrap the bar in `ViewThatFits`. If the full row still doesn't fit (Swap with add-on pills), put the pills in a `FlowLayout` row above a right-aligned Generate.

With 1–5 the member bar is ≈ 640 px and the owner's ≈ 700 px, inside 920 px with room for the add-on pills.

**B2 · med · VoiceOver**: pills only have `.help`, so VoiceOver reads the visible value ("On", "1 /4"). Add `"\(help), \(value)"` labels (`ComposerBottomBar.swift:227-244`). Takes reads "1 /4": say "1 take of up to 4".

**B3 · low · noise**: the bar has 6–7 bordered pills, plus bordered add-on pills, plus a 2 px ink border on the open one. Suggest borderless pills (fill `bg`, no stroke), a hover fill of `surface2`, and the ink border only while open. An add-on that is on has 3 marks (2 px accent border + checkmark icon + surface fill): keep the checkmark and a fill only (`:146-155`).

**B4 · low · "How is this priced?" underline** uses `t.line` (1.3–1.5:1 on the bar), so it doesn't read as a link. Use `link` text or an underline in `muted` (`:351`).

**B5 · low · Generate disabled state** is the CTA at 45 % opacity, with no reason shown on the bar when the price is "—". The problem line is above, but "—" alone looks broken: show "Generate · pricing…" while estimating (`GeneratePrice.unknown`).

**Extend & upscale** (in progress, not audited in depth): the Extend tool shows the coming-soon body (disabled slot row + "It will use the same composer…"). The Upscale add-on pill toasts "Upscale works on a finished take · generate it first" when there's no take: fine. Nothing else to log until it lands.

**Also LOGGED for WS1 above:** M2-18 (Movement autoplay default), M2-34 (Directed step height), M2-35 (wheels → drum picker), M2-39 (composer below the fold at 720 px), M2-40 (hub recent fallback).

---

### Tests

New `mac/MuseCore/Tests/MuseCoreTests/UxAudit2Tests.swift`, run in Mac CI:
- `testBestInkOnFills`: `Contrast.bestInk` picks dark ink on B's light fills and white on dark fills, and every tag fill passes 4.5:1.
- `testBalancedColumnsAvoidAnOrphanRow`: 6 tiles at 964/988 → 3, at 1148 (min 160) → 6, 7 tiles → 4, plus edge cases.
- `testBlenderRowOnThisMacSaysTheRelayIsOff`: the `thisMac` wording, with the old default unchanged.
- `testAuditTextPairsPassAA`: the changed pairs (sigil `link` on surface2, placeholder `muted`, chat errors `rec`, goodInk/warnInk tags, plain-muted "Soon") in all 4 themes, plus assertions that the old pairs failed.

The existing `CameraTests` still pass by construction (defaults unchanged).

### Swift spots least sure to compile (check first in CI)
1. `SuiteHubView.swift`: `.background(GeometryReader { … .preference(key: HubTilesWidthKey.self, …) })` + `.onPreferenceChange` writing `@State` (fine in Swift 5 mode, `SWIFT_VERSION 5.0`). `HubTilesWidthKey` uses `static let defaultValue`.
2. `SuiteComponents.swift` `SuiteTag.ink(on:)`: `NSColor(Color).usingColorSpace(.sRGB)` and its components (AppKit is imported in that file).
3. `DirectedViews.swift` `SessionStrip`: `ViewThatFits(in: .horizontal)` with two children, using `$model.viewMode` from `@Bindable` inside a computed property.
4. `ComposerView.swift` `ComposerCard`: `.background { RoundedRectangle….fill(…).shadow(…).overlay(…) }` (trailing-closure `background`, macOS 12+).
5. `PreviewView.swift`: `@Environment(\.accessibilityReduceMotion) private var` added to a view other files construct with the memberwise init (same pattern as its existing `@State private var`s).

### Needs a real Mac
M2-02 (the suggestion list floats over the bar and presets, and isn't cut by the ScrollView at the bottom of the page), M2-03 / M2-34 (Directed in the picker and Camera stage at 1100 / 1280), M2-04 / M2-10 (hub at 1100 / 1280 / 1440), M2-06 (switch theme with text in the prompt), M2-08 / M2-19 (corners in C/D), M2-09 (chips wrapping), M2-14, M2-18 (Reduce motion), M2-20, M2-32 / M2-33 (keyboard focus, VoiceOver on chips), and the VoiceOver labels M2-13, M2-24, M2-25, M2-28.
