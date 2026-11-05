# UX audit · Android + Mac (workstream 4, phase 2, 2026-11-05)

The owner asked for the whole app to be "properly optimised, clean even with the additions, no UI/UX issues". Every existing screen on both apps was checked: Android at **360 dp and 390 dp** phones (Roborazzi renders, looked at), Mac at **1280 px and 1440 px** windows (SwiftUI code read line by line; contrast computed from the theme tokens; items that need a real Mac to confirm are marked), each in all four themes (A Editorial, B Camera Body, C Soft Tactile, D Creator Pop). Checked: clipping, wrapping, overflow, empty/loading/error states, wording, member-visible provider/model names, accessibility (contrast, tap targets, TalkBack/VoiceOver labels), navigation dead ends and leftover demo content.

## Summary
| | Android | Mac |
|---|---|---|
| Findings in our screens (owner 4) | 42: high 12, med 17, low 13 | 43: high 5, med 18, low 20 |
| Fixed | **37** (all high and medium) | **39** (all high) |
| Not fixed | 5 low (listed, with why) | 4 (listed, with why) |
| Sent to workstream 1 (video suite, navigation) | 5 | 8 |
| Sent to workstream 2 (camera, Connections) | 0 | 2 |
| Sent to workstream 3 (Edit suite) | 0 | 2 |

**Found nothing on either app:** provider/model/GPU names in member-facing text (only owner Settings → Engines, the model catalog and the owner's model chooser name them, as allowed); "Sienna" anywhere; demo names or sample clips reaching a signed-in real studio.

**The main fixes, both apps:** fake actions removed ("Save as preset" on Photoshoot, "Report a problem" on Result, Android's fake profile menu items); demo-only content no longer shown to real studios (LoRA sample pictures and "the demo runs faster"); a shared contrast fix (Editorial muted grey #67605A, a link colour that passes 4.5:1 in every theme); missing empty, loading and error states (Home, Gallery, Queue, Credit's Recent spend, Shoot with no ready model); screen-reader labels on icon-only buttons and on/off state on custom switches; layout fixes at 360 dp (prices cut on buttons) and at 1280 px (Posts accounts grid, profile header, Settings list unreadable in Creator Pop); Android Download now saves the real file; the Mac About panel no longer names the video model.

**Decisions for the owner** (not fixed): Terms of Service / Acceptable Use links (no URLs yet); the server address shows the hosting company's domain (needs a MUSE domain); whether members should see Settings → Developer; Soft Tactile's warning colour and white-on-accent text are under 4.5:1 on both apps (changing them changes the theme).

**Tests:** Android `:core:test` 90/90 and `:app:testDebugUnitTest` 651/651 (including the new `AuditScreenshotTest`: 42 screens × 4 themes at 360 dp, with a new member's empty studio, a load that never answers and an unreachable server); MuseCore `UxPolishTests` (WCAG contrast of every theme's text pairs, demo-only LoRA line) run in Mac CI.

---

## Android

_For the parent to merge into `plans/ux-audit.md`._ Scope: every screen in `android/app/src/main/kotlin/studio/muse/app/ui/screens/*.kt` and the navigation in `ui/MuseApp.kt`, at phone widths **360 dp** (new `AuditScreenshotTest`) and **390 dp** (the existing `ScreenshotTest`), in all four themes (A Editorial, B Camera Body, C Soft Tactile, D Creator Pop).

### How it was checked
- `app/src/test/kotlin/studio/muse/app/AuditScreenshotTest.kt` (kept in the repo, 42 screens × 4 themes = 168 renders, ~3 min): every top-level screen at 360 × 780 dp, plus the states a real studio hits that the demo never shows. A stand-in for the real API (the new optional `httpFactory` on `AppContainer`) gives a **new member's empty studio**, a **first load that never answers** and an **unreachable server**. PNGs: `app/build/outputs/roborazzi/audit360_<theme>_<screen>.png`.
- Every PNG was looked at as a 4-theme contact sheet, before and after the fixes. Then the code was read for wording, demo leaks, dead handlers, semantics and tap targets. Contrast was computed from `Theme.kt`.
- The Mac audit's cross-platform items (parent message) are folded in and marked **[Mac]**.

Severity: **high** = wrong or misleading for real users (fake success, demo content, broken flow). **med** = visible defect or missing state. **low** = polish.

### Owner 4: our screens (all fixed unless marked)

| # | Screen · width/theme | Sev | What was wrong | Where | Status |
|---|---|---|---|---|---|
| 1 | Photoshoot · all | high | With no ready model, Shoot and "Change model" toasted the demo's names: "Only Demo model is ready · Noor needs close-ups" | ShootScreen.kt:151, 188 (before) | **FIXED**: neutral `NO_READY_MODEL` toast; "Change model" opens the Model tool |
| 2 | Photoshoot · Model tool | high | Tapping a ready model did nothing (only drafts reacted), so you couldn't switch models | ShootScreen.kt:269 (before) | **FIXED**: `ShootViewModel.model(id)` selects her and her first outfit. The strip now scrolls |
| 3 | Photoshoot · empty studio, 360 all themes | med | No models: a blank canvas and a live "Shoot 4 · about $0.46" | ShootScreen.kt | **FIXED**: `NoModelNote` ("No models yet…" + New model, or "Finish character sheet" for drafts), CTA dimmed with no price |
| 4 | Photoshoot ⋯ **[Mac]** | high | "Save as preset" only toasted "Saved as preset …" and saved nothing | ShootScreen.kt:186 (before) | **FIXED**: removed (as on the Mac) |
| 5 | Photoshoot · B **[Mac]** | low | Made-up "· 4300K" readout on the canvas | ShootScreen.kt:207 | **FIXED**: removed |
| 6 | Result · all | high | Download and the side "Export" only toasted "Exported 1080×1920"; nothing was saved | ResultGalleryScreens.kt:103 (before) | **FIXED**: new `platform/Downloads.kt` saves the take's video or photo to Downloads/MUSE (Android 10+; opens it on 8–9). Demo takes say "Demo takes have no file to download". The side button is now "Download" |
| 7 | Result ⋯ **[Mac]** | high | "Report a problem" toasted "Thanks · report sent with the prompt and seed" and sent nothing | ResultGalleryScreens.kt:177 (before) | **FIXED**: removed (as on the Mac) |
| 8 | Profile ⋯ (Common) | high | Fake items: "Duplicate model" ("Model duplicated", nothing made), "Share profile card", and "Delete model" saying "Delete is disabled in this demo" to real users. Also "Edit character sheet" and "Character sheet" did the same thing | Common.kt:84–100 (before) | **FIXED**: only real actions are left. Archive (owner, reversible) is the way to remove a model. `profileMenu` keeps its signature |
| 9 | Profile · A/B | med | "Identity locked · 7/6": the sheet has had 7 slots since faceTq | ProfileScreen.kt:154, 204 (before) | **FIXED**: /7 |
| 10 | Profile · A (Editorial) | med | No back button (dead end without the system gesture) | ProfileScreen.kt:144 (before) | **FIXED**: back button before the wordmark |
| 11 | Profile · model gone | med | A blank screen with no way back when her id no longer resolves (archived elsewhere) | ProfileScreen.kt:115 (before) | **FIXED**: top bar + "This model isn't here any more…" + Back |
| 12 | Profile · 360 all | low | LoRA tile cut "Not trained · locks f…" | LoraScreen.kt:94, 320 | **FIXED**: "Not trained yet"; the tile line may use 2 lines |
| 13 | Identity LoRA (real API) **[Mac]** | high | The bundled sample stills ("hero", "face", "c_face") were shown as *her* hero and as the "References only / With LoRA" comparison for every real model | LoraScreen.kt:142–183, 277–290 (before) | **FIXED**: the hero uses her own cover or face photo. The comparison is demo-only; real studios get her photo with "LoRA vN ready" |
| 14 | Identity LoRA (real API) **[Mac]** | high | "~N min left · demo runs 120× faster" shown to everyone | LoraScreen.kt:273 (before) | **FIXED**: the suffix shows in Demo mode only |
| 15 | Identity LoRA | low | "6 reference shots" (the sheet has 7) and "freckles" (the demo character's trait) | LoraScreen.kt:183, 288 (before) | **FIXED**: real count, neutral wording |
| 16 | New model step 1 (real API) | high | A blank name silently created a model called "Noor Ellis" (a demo character). The name field's placeholder was also "Noor Ellis" | CreateModelScreens.kt:72, 145 (before) | **FIXED**: a name is required ("Give her a name first", CTA dimmed, double tap ignored). Placeholder: "Her name" |
| 17 | Character sheet · 360 all | med | Slot captions were cut: "Face · front ·" lost its "filled in" | CreateModelScreens.kt:201 | **FIXED**: caption may wrap to 2 lines |
| 18 | Home · C (Soft Tactile) | high | "Good evening, Jenne": the studio name's first word was used as the person's name, so every member was greeted as the owner. A blank studio name fell back to "Jenne" | HomeScreen.kt:54, 63, 98 (before) | **FIXED**: "Good morning/afternoon/evening" with no name |
| 19 | Home · real API, empty | med | A new studio showed "All models · 0 models" and nothing else | HomeScreen.kt | **FIXED**: "No models yet" card with New model |
| 20 | Home · loading / server unreachable | med | Both looked like an empty studio. Errors were only a toast | HomeScreen.kt | **FIXED**: "Loading your models…"; the error note + Try again (`repo.refresh()`) |
| 21 | Home | low | "1 models", "1 outfits"; "ready to shoot" sticker (D) on a draft model | HomeScreen.kt | **FIXED**: `plural()`, sticker only when locked |
| 22 | Gallery · all | med | The top-right grid button did nothing | ResultGalleryScreens.kt:228 (before) | **FIXED**: removed |
| 23 | Gallery · loading / error | med | "No test renders yet…" while still loading or when the server was unreachable | ResultGalleryScreens.kt | **FIXED**: "Loading your renders…"; error note + Try again |
| 24 | Gallery **[Mac]** | – | Tests tab's empty text reusing the Final tab's | ResultGalleryScreens.kt | Checked: Android already uses separate texts ("No test renders yet…" / "Nothing approved yet…") |
| 25 | Gallery · TalkBack | low | Tiles had no label | ResultGalleryScreens.kt | **FIXED**: each tile reads "<title> · <label>" |
| 26 | Settings · member | med | The "Next render fails (test)" switch (and its "fail at step 3" toast) was shown on the real server | SettingsScreens.kt:115 (before) | **FIXED**: Demo mode only. Toast: "Next render will fail partway" |
| 27 | Settings · empty studio | low | "Model's accounts" with no model (from the "Demo model"/"Model" fallbacks) | SettingsScreens.kt | **FIXED**: row hidden until there's a model |
| 28 | Settings · theme cards | med | The previews always showed the bundled "Demo model" | SettingsScreens.kt:215 | **FIXED**: they show the studio's first ready model, the sample only in Demo mode (unnamed "Your model" otherwise) |
| 29 | Credit (owner) · 360 A/D | med | "SEND CRE…" cut. KPI labels "STUDIO TODAY" / "THIS MONTH" wrapped to 2 lines in 3-up tiles | TokensScreen.kt:151–158 | **FIXED**: no icon on Send credit, wider weight. KPIs "Today" / "Month" (like the Queue) |
| 30 | All CTAs · 360 A (and D) | high | Prices at the end of buttons were cut: "BUILD TRAINING SET · ABOUT $…", "ENHANCE · 7 IMAGES · ABOUT $…", "GENERATE OUTFIT SET · ABOUT …" | Kit.kt `Cta` | **FIXED**: new `FitText`, one line that shrinks to at most 75% before it would cut. Affects every `Cta` app-wide (also the video suite's "Generate · 7 s · $0.56"); no API change |
| 31 | Post · no account picked | low | CTA "Post to … accounts" | SocialScreens.kt:295 | **FIXED**: "Pick an account to post" |
| 32 | Posts **[Mac]** · 360 | – | Posts/accounts row clipping | SocialScreens.kt PostRow | Checked (new `posts_posted` render, long title, 5-digit stats): the title ellipsizes, badges and the stats line fit or wrap. Nothing to fix |
| 33 | Templates ⋯ | low | "Make one from a photo" only toasted instructions | TemplateScreens.kt:117 | **FIXED**: opens the Gallery with the hint |
| 34 | All top bars · TalkBack (Common) | high | Icon-only buttons (`TbBtn`: back, ⋯, bell, +, user, credit) had no `contentDescription`, so TalkBack said "button" or nothing | Kit.kt `TbBtn`, `MoreMenu` | **FIXED**: label from the icon ("Back", "More options", "Notifications", …), overridable with `label =` |
| 35 | All top bars · tap target (Common) | med | `TbBtn` was 44 dp, under the 48 dp minimum | Kit.kt `TbBtn`, `TopBar` | **FIXED**: 48 dp touch box (icon unchanged); `TopBar` spacers 48 so titles stay centred |
| 36 | Everything tappable (Common) | med | `Modifier.press` had no role, so TalkBack didn't announce rows, cards and chips as buttons | Kit.kt:121 | **FIXED**: `role = Role.Button` |
| 37 | Editorial (A) contrast **[Mac]** | med | muted #6E675E is 4.29:1 on surface2 | Theme.kt:104 | **FIXED**: #67605A (the Mac's value), 4.75:1 on surface2 |
| 38 | Soft Tactile (C) contrast | med | Text links ("Templates", "Reset", "Remove", "See all", "+ Connect…") in accent #6E8465 are 3.16:1 on the background | Theme.kt, 7 screen files | **FIXED**: new `Muse.link` (C: #4E6B45, 4.9:1, the Mac's link colour; D: cobalt; A/B: accent) used for link text in Auth, Shoot, Social, Lora, Settings, Templates, WarmGpu |
| 39 | Soft Tactile (C) contrast | low | warn #9A6B2A as text is 3.61:1 on bg; white on the accent fill (selected chip) is 4.08:1 | Theme.kt:118 | **NOT FIXED**: kept equal to the Mac palette (the Mac kept these). Needs a two-app palette decision |
| 40 | Result · B | low | The viewfinder's top-left corner overlaps the back chevron | ResultGalleryScreens.kt `Viewfinder()` | **NOT FIXED**: cosmetic, theme-specific; needs a design call on the inset |
| 41 | Small text links | low | "Reset", "Remove", "Templates" text buttons have 4–8 dp padding (under 48 dp) | Shoot/Template screens | **NOT FIXED**: enlarging them changes the approved dense layouts. Suggest `minimumInteractiveComponentSize()` in a later pass |
| 42 | Home bell | low | The bell only toasts the running render / "No new notifications" (there's no inbox) | HomeScreen.kt | **NOT FIXED**: honest as is. An inbox is a feature, not a fix |
| 43 | Theme A buttons | low | `Cta` is uppercase but `Cta2` isn't, so pairs read "Discard / APPROVE" | Kit.kt | **NOT FIXED**: theme-wide typographic choice from the prototype; flag for design |
| 46 | Result · real video, 390 all | med | The side actions (Retry/Download/Edit/Post) sat on top of the player's seek bar and settings gear | ResultGalleryScreens.kt side-action column | **FIXED**: lifted to 96 dp from the bottom when the take has a video |
| 44 | Member-facing provider/model names | – | grep of member-visible strings: none. Model names appear only behind owner checks (OwnerModelLine, Settings footer, Engines, Image models, catalog) | – | Checked, OK |
| 45 | "Sienna" / placeholder characters | – | grep: no "Sienna" anywhere in Android. Remaining sample data is Demo-mode only (FakeMuseApi, SampleData), plus the Welcome screen's brand art | – | Checked, OK after 13/16/18/28 |

Count (owner 4): **42 findings: 37 fixed, 5 not fixed** (all low; #39 needs a palette decision for both apps), plus 4 checks with nothing to fix (#24, #32, #44, #45). By severity: **high 12** (all fixed), **med 17** (all fixed), **low 13** (8 fixed, 5 not fixed).

### For other workstreams (not touched; please forward)

**Workstream 1 (video suite + navigation)**
1. **med** · Photoshoot/any 6-tool strip, 360 dp, A and B: `ToolStrip` gives each tool a fixed 62 dp (6 × 62 + 32 > 360), so "LIGHT" and "PROMPT" run together and "Prompt" touches the edge. `StudioParts.kt:80` (and D at :71, 54 dp + unbounded label). Suggest `Modifier.weight(1f)` per tool when `tools.size > 5`. Visible in `audit360_a_shoot.png`, `audit360_b_shoot.png`.
2. **high** · `VideoScreens.kt:324` "Save as preset" only toasts "Saved as preset …" (fake; the Mac removed it).
3. **med** · `VideoScreens.kt:437` "Replace audio" toast "Pick a track or voiceover (demo)" is shown to real users.
4. **low** · `VideoScreens.kt:323` "Show prompt" puts the prompt in a toast (3 s, unreadable). A sheet or the Photoshoot-style prompt box would be better.
5. **med** · `MuseApp.kt` `TabBar`: the centre "+" has no TalkBack label (it uses `press` with an icon only); tab items are 60 × ~44 dp. Suggest `semantics { contentDescription = "Create" }` on the + box. (`press` now adds Role.Button app-wide.)
6. **info** · Kit changes that reach your screens: `Cta` text now shrinks before it would be cut (`FitText`); `TbBtn` is 48 dp with an automatic TalkBack label; `TopBar` side spacers are 48 dp. Re-record your Roborazzi PNGs.

**Workstream 2 (camera / Directed, Connections)**: no Android screens yet under `ui/screens/camera/**`. Nothing to report. The Kit changes above apply.

**Workstream 3 (Edit suite)**: `VideoEditorScreen.kt` wasn't changed. Its top bar picks up the `TbBtn` labels and 48 dp target. Nothing else found in this pass. The v1 editor is being replaced.

### Tests
`./gradlew :core:test :app:testDebugUnitTest -Proborazzi.test.record=true`: **core 90/90, app 651/651 passed** (0 failures, 0 skipped; app = 483 before + 168 audit renders). After the last small Result change, `ScreenshotTest` was re-run: 360/360 passed. Baseline before any change: core 90, app 483, all green.

---

## Mac

_2026-11-05, branch `claude/muse-prompt-scripts` from d4cabc8. The parent merges this into `plans/ux-audit.md`._

**How:** every Mac screen read in code (`mac/Muse/Views/*.swift`, `mac/Muse/App/*.swift`, `mac/Muse/Theme/*`, MuseCore strings), laid out by hand at a **1280 px** and a **1440 px** window (content width = window − 228 px sidebar; the sidebar goes compact, 72 px, below 1240 px; the window's minimum is 1100 × 720) in all four themes (A Editorial, B Camera Body, C Soft Tactile, D Creator Pop). Contrast = WCAG 2.x ratio of the theme tokens (`Theme.get`), now also checked in `MuseCoreTests/UxPolishTests`. Wording compared with `android/.../ui/screens/*.kt`. No Swift toolchain here: nothing was run; **"Mac?" = needs a real Mac to confirm the look**.

**Owner:** 4 = this workstream (Home, Models/profile/sheets, Photoshoot, Templates, Gallery/Result, Queue, Posts, Credit/Members, Settings incl. Prompts + Scripts, Auth & sheets, shared components) · 1 = video suite + sidebar/navigation · 2 = camera/Directed, Connections, Blender · 3 = Edit suite.

**Totals:** 55 findings. Owner 4: 43 (high 5, med 18, low 20) → 37 FIXED, 6 NOT FIXED. Owner 1: 8 (high 1, med 4, low 3). Owner 2: 2 (med 1, low 1). Owner 3: 2 (med 1, low 1). (Owner 4's count includes 2 in `StudioViews.swift`, which stayed untouched because that file is reserved for workstream 1.)

### Owner 4 · findings and fixes

| # | Screen · width/theme | Sev | What's wrong | Where | Mac? | Status |
|---|---|---|---|---|---|---|
| M4-01 | Settings (all sections) · all widths · **D** | high | The section list reused the sidebar's `NavRow`, whose Creator Pop colours are white text for the blue sidebar: on the cream page every section except the selected one was white on cream (≈1.1:1), i.e. invisible. | `Views/SettingsViews.swift:15` | yes | FIXED: own `SettingsNavRow` drawn for the page (ink/muted text, yellow selected row in D, accent bar in A/B), `.isSelected` trait. |
| M4-02 | Identity LoRA · training · all | high | "~N min left · **the demo runs faster**" shown to every real studio (demo leftover). | `Views/LoraPostViews.swift:266` | no | FIXED: `LoraPricing.timeLeftLine(progress:demo:)` (MuseCore) adds the demo note only in demo mode; test. |
| M4-03 | Identity LoRA · ready · all | med | The "References only / With LoRA" comparison always showed the demo's sample art (`c_face`, `face`) and claimed "same prompt and seed", for real models too. | `Views/LoraPostViews.swift:175` | no | FIXED: demo keeps the comparison; a real studio sees her own kept training shots ("Trained on these N shots"). Android has the same leak (`LoraScreen.kt:285`). |
| M4-04 | Identity LoRA · not trained · all | low | The intro grid always showed the demo sample silhouettes. | `Views/LoraPostViews.swift:203` | no | FIXED: her own sheet images (faded); sample art only in demo mode, else neutral placeholders. |
| M4-05 | Posts · 1280 and 1440 · all | high | Five account cards in one `HStack`: ≈186 px each at 1280 (≈218 at 1440) left ~25 px for "Instagram / Not connected" next to the Connect button → clipped/truncated. Nothing said whose accounts they are (it silently uses the studio's selected model). | `Views/LoraPostViews.swift:483` | yes | FIXED: adaptive grid (min 230 px, wraps to 4+1 / 3+2) under a "NAME'S ACCOUNTS" label. |
| M4-06 | Model profile · 1280 (≈652 px column) and 1440 · all, worst A/B (uppercase H2) | med | "Character sheet" header carried the hint, Versions, Upload images, Enhance and Dress up on one line (~820 px needed) → buttons squeezed/truncated, the hint wrapped into a tall column. | `Views/ModelViews.swift:162` | yes | FIXED: header keeps "Versions"; hint + action buttons on their own row. |
| M4-07 | Home "Your models", Models · 1280 (5 columns ≈185 px) · all | med | Draft model card: "Draft ·" + the fixed-size "needs face close-ups" pill ≈184 px in a ≈157 px text area → clipped by the card shape. | `Views/HomeViews.swift:226` | yes | FIXED: `ViewThatFits` drops the "Draft ·" prefix when the row doesn't fit. |
| M4-08 | Home KPIs · all | low | "This month" hint said "N renders" with the all-time count of every take (photos too). | `Views/HomeViews.swift:88` | no | FIXED: "N takes this month" (since the 1st). |
| M4-09 | Home "Latest takes" · all | low | No empty state: a new studio saw a section header over nothing. | `Views/HomeViews.swift:135` | no | FIXED: note "No takes yet. Finished videos and photoshoots show up here." |
| M4-10 | Photoshoot ⋯ menu · all | med | "Save as preset" saved nothing; it only showed "Saved as preset". | `Views/ShootView.swift:122` (was) | no | FIXED: item removed. Android has the same fake (`ShootScreen.kt:186`, `VideoScreens.kt:324`). |
| M4-11 | Photoshoot model row · B | low | Camera Body readout always said "· 4300K" (made-up colour temperature). | `Views/ShootView.swift:178` | no | FIXED: lens · aperture only, one line. Android `ShootScreen.kt:207` same. |
| M4-12 | Photoshoot model row · 1280 (canvas ≈644 px) · all, worst B | med | Outfit segmented control: with 4+ outfits each segment truncates ("Gre…", "Cry…"); with the B readout the row overflows. | `Views/ShootView.swift:164` | yes | FIXED: 4+ outfits use a native menu picker; 1–3 keep the segmented control. |
| M4-13 | Result ⋯ menu · all | med | "Report a problem" only showed "Thanks, we'll look at this take"; nothing is sent. | `Views/QueueGalleryViews.swift:324` (was) | no | FIXED: removed. Android's toast even says "report sent" (`ResultGalleryScreens.kt:177`). |
| M4-14 | Result · all | med | "Post to **her's** accounts" when the take's model is gone. | `Views/QueueGalleryViews.swift:369` | no | FIXED: "Post to Noor's accounts", else "Post". |
| M4-15 | Result + export toast · all | med | Button "Export 1080×1920" and toast "Exported 1080×1920": renders are 768×1344 (HD 2K) and photos aren't 9:16 at all. | `Views/QueueGalleryViews.swift:361`, `App/AppStore+Actions.swift:284` | no | FIXED: "Export" (help: "Save it to Downloads › MUSE"); toast "Saved to Downloads › MUSE" / "Couldn't save it to Downloads". |
| M4-16 | Result Discard, Gallery "Delete take" · all | med | Deleting a take (server delete, no undo) happened on one click. | `App/AppStore+Actions.swift:256` | no | FIXED: confirmation alert ("Delete …? This can't be undone."), like Delete model. |
| M4-17 | Gallery · Tests tab · all | med | Empty Tests tab said "Nothing approved yet. Approve a take to move it here." | `Views/QueueGalleryViews.swift:184` | no | FIXED: Tests → "No test renders yet. Make a video or a photoshoot." (Android's wording). |
| M4-18 | Queue "Finished" · all | low | Labelled "Last 7 days" but lists every finished job; no empty state. | `Views/QueueGalleryViews.swift:70` | no | FIXED: "N jobs" + note "Nothing finished yet…". |
| M4-19 | Queue row ⋯ "Copy prompt" · all | low | With no prompt it put "(no prompt saved for this job)" on the clipboard. | `Views/QueueGalleryViews.swift:151` | no | FIXED: toast "No prompt was saved for this job" instead. |
| M4-20 | Template detail · 1280/1440 · all | med | Public/uses/product/tag pills in one `HStack` inside a 460 px column: 3+ tags overflow. | `Views/TemplateViews.swift:196` | yes | FIXED: `FlowLayout` wraps them. |
| M4-21 | Templates · Favourites empty · all | low | "Tap the star…" on a Mac. | `Views/TemplateViews.swift:86` | no | FIXED: "Click the star…". |
| M4-22 | Every link (`LinkText`) · **C** | high | Soft Tactile links were the accent #6E8465 on bg: **3.16:1** (fails AA). | `Theme/Components.swift:339`, `Theme/Theme.swift:57` | no | FIXED: `Theme.link` (C uses its darker green #4E6B45, 4.6–5.3:1; D keeps blue 5.2–6.0:1). Test. |
| M4-23 | "Edited" pill, AI pill, chips that are on · **C** | med | White on accent #6E8465: **4.08:1**. | `Theme/Components.swift:362,400` | no | FIXED: `Theme.accentFill` (C = its CTA green, 5.55:1). Test. |
| M4-24 | `.good` pills (Locked, Public, Keep, Compatible…) · A, C, D | med | Green text on its 18 % tint: A 3.9–4.5, C 3.7–4.1, D 3.3–3.5 :1. | `Theme/Components.swift:361` | no | FIXED: `Theme.goodInk` (darker greens, ≥4.58:1 on every surface). Test. |
| M4-25 | Muted text on surface2 (field previews, notes) · **A** | low | Editorial muted #6E675E on surface2: 4.29:1. | `Theme/Theme.swift:73` | no | FIXED: muted #67605A (4.75–5.68:1). Android `Theme.kt:104` has the old value. Test. |
| M4-26 | Shared controls · all | med | Icon-only buttons with a tooltip but no VoiceOver label: sheet close ✕ (`IconButton`), ⋯ (`MoreMenu`), chip ✕, − / + steppers, reference ✕, gallery select circle, favourite star, rule condition ⊖. | `Theme/Components.swift:302,322,432,578`; `ShootView.swift:53`; `QueueGalleryViews.swift:238`; `TemplateViews.swift:161`; `PromptScriptViews.swift:470` | VoiceOver | FIXED: `.accessibilityLabel` on each. |
| M4-27 | All switches (`MToggle`), sign-up attestations · all | med | Custom toggles were plain buttons to VoiceOver (no on/off state). | `Theme/Components.swift:545`, `Views/AuthAndSheets.swift:96` | VoiceOver | FIXED: `.isToggle` trait + On/Off value (macOS 14 API). |
| M4-28 | Character sheet tiles (profile, new model) · all | med | Replace / Retake with AI / Remove only appear on hover: no keyboard or VoiceOver path except the context menu. | `Views/ModelViews.swift:48` | VoiceOver | FIXED: tile is one accessibility element with named actions. |
| M4-29 | Template card · all | low | VoiceOver read only "Public"; "Use" is hover-only. | `Views/TemplateViews.swift:108` | VoiceOver | FIXED: label "Name, public template" + "Use" action. |
| M4-30 | Template editor, Enhance, Dress up, Previous versions, Model catalog, Rule editor · all | med | Esc did nothing (only palette/outfit/post closed): keyboard dead end. | `App/Support.swift:205`, `PromptScriptViews.swift:424` | yes | FIXED: Esc closes the topmost overlay; the rule editor's Cancel is the cancel action. |
| M4-31 | Sign in / sign up · all | low | Busy button read just "…". | `Views/AuthAndSheets.swift:103` | no | FIXED: "Signing in…", "Creating account…", "Checking your session…". |
| M4-32 | macOS "About MUSE" panel · everyone | high | Copyright line "Video model: MiniMax H3." = a model/provider name every member sees. | `mac/project.yml:43` | no | FIXED: "MUSE AI model studio." (Android shows the H3 licence line to the owner only.) |
| M4-33 | Settings → Render defaults · all | low | "Export size 1080×1920 · 9:16" is not what Export does. | `Views/SettingsViews.swift:78` | no | FIXED: "9:16 · as rendered" + hint. |
| M4-34 | Settings → About · all | med | "Terms of Service" / "Acceptable Use Policy" rows only toast "…opens on the MUSE website"; nothing opens. Sign-in has the same unlinked sentence. | `Views/SettingsViews.swift:159-160`, `AuthAndSheets.swift:126` | no | NOT FIXED: no Terms/AUP URL exists; owner to supply the links (then `NSWorkspace.shared.open`). |
| M4-35 | Model profile with no models · all | low | "No model yet." with no way forward. | `Views/ModelViews.swift:111` | no | FIXED: hint + "New model" button. |
| M4-36 | Photoshoot canvas · all | low | Model thumbnail button had only a tooltip; finished shot tiles read "AI". | `Views/ShootView.swift:141,193` | VoiceOver | FIXED: labels "Model: Noor. Change model", "Shot 1…4". |
| M4-37 | Sign in, Settings → Developer · members | low | The server host shown is `…up.railway.app` (hosting company in the address). | `AuthAndSheets.swift:113`, `SettingsViews.swift:129`, `AppStore.swift:44` | no | NOT FIXED: needs a MUSE domain (owner). |
| M4-38 | Credit · members and owner | low | "Recent spend" lists every job ever plus a "Photos" row even with 0 photos. | `Views/StudioViews.swift:34-40` | no | FIXED: the newest 20 renders, a Photos row only with photos ("1 photo"/"N photos"), an empty state (workstream 1 confirmed the Credit screen is ours). |
| M4-39 | Settings → Studio / Engines notes · owner | low | "…come with the MUSE server (server/api)" — repo jargon in the UI. | `Views/StudioViews.swift:421,507` | no | FIXED: "They come with the full MUSE server." |
| M4-40 | Overlay sheets (outfit set, post, template editor, tools) · all | low | They are ZStack overlays, not modal windows: Tab can move keyboard focus to controls behind the dimmed backdrop. | `RootView.swift:16-25` + each sheet | yes | NOT FIXED: needs a Mac to see the focus order; moving to `.sheet` is a bigger change. |
| M4-41 | Settings → Developer, offline note · members | low | Members see "server/api", "server/mock", "dev servers", "Fail the next render". | `Views/SettingsViews.swift:127-153` | no | NOT FIXED: product call (hide Developer from members, or keep for support). |
| M4-42 | Dress up sheet · members | low | Section titled "Engine" over "Option A / Option B" (provider-neutral wording asks for options). | `Views/ToolViews.swift:463` | no | FIXED: "Options". |
| M4-43 | Text field placeholders · A | low | Placeholder = muted × 0.8 → 3.4:1 on surface. | `Theme/Components.swift:714` | no | FIXED indirectly (darker muted → 3.9:1); still below 4.5, acceptable for placeholders. |

**Checked with no finding:** the 6-column Gallery/Home grids (≈150 px tiles at 1280) and the fixed-column Queue/Credit/Members tables (≥350 px left for names even at the 1100 px minimum); member-visible provider/model/GPU words (only owner Settings → Engines, the model catalog and the owner's "Model" chooser name Replicate/models, as allowed); no "Sienna" anywhere in `mac/`; demo names are "Demo model"/"Demo model B" and appear only via `FakeMuseAPI`; the sample clip and SSO buttons are gated by `isDemo`; the real API path never falls back to `FakeMuseAPI` once signed in (`makeAPI` only picks the fake for an invalid URL, which then shows "Demo mode"); `currentModel`/`profileModel` fall back to the first real model, so the `m_demo` default id never reaches a server screen.

### Owner 1 · video suite, sidebar, title bar (not changed here)
| # | Screen · width/theme | Sev | What's wrong | Where | Mac? |
|---|---|---|---|---|---|
| O1-1 | Toast action ("Review", "Credit", "Open queue") · A, B, C | high | Action text is the accent on the ink-coloured toast: A 2.7:1, **B 1.7:1** (amber on the light toast), C 3.7:1. | `Views/RootView.swift:405` | no |
| O1-2 | Video studio · 1280 / 1100–1239 | med | Side columns 280 + 344 px leave the centre (source → model preview) ≈428 px at 1280 and ≈404 px in a compact-sidebar window. | `Views/StudioView.swift:13-23` | yes |
| O1-3 | Video studio ⋯ | med | "Save as preset" only toasts a hard-coded "Dance · Draft" preset. | `Views/StudioView.swift:49` | no |
| O1-4 | Sidebar / Go menu / ⌘3 | med | Still "Video studio"; the approved design (decision 4) is **Video suite** with modes, and Edit top-level. | `App/AppStore.swift:31` | no |
| O1-5 | Title bar · all | med | Account menu (person icon) and theme dots have tooltips but no VoiceOver labels. | `Views/RootView.swift:122,203` | VoiceOver |
| O1-6 | Sidebar · D; balance box · C | low | "CREATE"/"STUDIO" white 75 % on blue 4.0:1; Soft Tactile balance box captions white 75 % on green 3.9:1. | `Views/RootView.swift:241,249,356,360` | no |
| O1-7 | Offline banner · members | low | Sends members to "Settings → Developer". | `Views/RootView.swift:54` | no |
| O1-8 | Title bar · 1100–1280 with upload + render + add-on indicator on | low | 420 px search field + right cluster can crowd; check it compresses gracefully. | `Views/RootView.swift:149` | yes |

### Owner 2 · camera/Directed, Connections, Blender
| # | Screen | Sev | What's wrong | Where | Mac? |
|---|---|---|---|---|---|
| O2-1 | (unreachable) Blender relay | med | `BlenderRelayDebugView` is never placed in any screen, so the owner can't switch the relay on from the Mac app. | `App/BlenderRelayDebugView.swift:4` | no |
| O2-2 | Blender relay view | low | Unthemed (system font, `.secondary`, a plain `Toggle`) once it is placed; use the theme components (`OptionRow` + `MToggle`, `Muted`). | `App/BlenderRelayDebugView.swift:9-23` | yes |

### Owner 3 · Edit suite
| # | Screen | Sev | What's wrong | Where | Mac? |
|---|---|---|---|---|---|
| O3-1 | Video editor toolbar/transport | med | Undo, redo, previous/next frame, play/pause are icon-only with `.help` but no `.accessibilityLabel`. | `Views/VideoEditorView.swift:66,70,110,112,114` | VoiceOver |
| O3-2 | Video editor · 1280 | low | 300 px inspector + timeline; confirm the player and timeline at 1280 and in a compact-sidebar window. | `Views/VideoEditorView.swift:32` | yes |

### Notes for the Android half (same issue there)
"Save as preset" fakes (Shoot, Video), "Report a problem" toast that claims a report was sent, the LoRA "References only / With LoRA" sample art for real models, the B "4300K" readout, and the Editorial muted token #6E675E (4.29:1 on surface2; Mac now #67605A).
