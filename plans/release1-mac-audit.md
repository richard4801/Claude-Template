# Release 1: Mac audit against the agreed plans (WS2, 2026-11-08)

Scope: `plans/ai-suite-design.md` (only what still applies to the current Suite: the owner kept it, the cinematic preview
was removed), `plans/edit-layout.md` (approved Edit layout), `plans/recreate-edit.md` (Recreate), plus coordination item 8
(the composer at about 1000 pt). Evidence is `file:line` on `claude/muse-mcp-bridge`; paths are under `mac/Muse/` unless
they say otherwise. Status: **done** (was already in the app), **fixed** (built or fixed in this pass), **remaining** (with
its owner).

## Coordination item 8: the composer at about 1000 pt

| Agreed | Status | Evidence |
|---|---|---|
| Pills shrink to icon plus value, never wrap ("Standar/d", "Speak/ing") | done before this pass, now checked at 1000 and 960 | `Views/Suite/Composer/ComposerBottomBar.swift` `pill()` lineLimit(1) + fixedSize; `listPill` icon + value |
| "Engine · A…" never cut | done (icon only when Auto and narrow; a pinned engine shows its whole name) | `ComposerBottomBar.swift` `enginePill(compact:)` |
| Generate keeps its price | fixed: a tier that drops Generate's middle words ("Generate · 4 photos · $0.24" → "Generate · $0.24") before the pills scroll; the full label stays tooltip and accessibility label | `ComposerBottomBar.swift` `body` (4 tiers), `GenerateButton.shortLabel` |
| The app could not be made 1000 pt wide | fixed: minimum window width 1100 → 960 (the old "_1000" shots were really 1100 wide) | `App/MuseApp.swift` `.frame(minWidth: 960…)` |
| CI catches it | fixed: fit check at 1000×700 and 960×640; CUT on a pill label drawn narrower than its text, a pill under the pricing link or Generate or off the window, Generate without a price, or a window not drawn at the asked width | `App/SnapshotRunner.swift` `fitCheck`, `composerBarLines` |

## AI Suite (`plans/ai-suite-design.md`), current Suite

| Plan ref | Agreed | Status | Evidence | Owner |
|---|---|---|---|---|
| §2 header, principle 1 | Tools are modes of one composer; the title opens a grouped mode menu | done | `Views/Suite/SuiteNav.swift:27` | — |
| §2, principle 6 | The price always on Generate | done (now guarded by the fit check down to 960 pt) | `ComposerBottomBar.swift` `generateLabel` | — |
| §2 rig check, item 9 | One line on a clash with a one-tap fix | done | `Views/Suite/RigCheckRow.swift:10`, `ComposerView.swift` `toolControls` | — |
| Principle 4, approval "for everyone, from day one" | Saved rigs: save the rig under a name, apply in one click | fixed (Setup rail "Rigs" row: apply with Undo, "Save this rig…", delete own; owner deletes any) | `ComposerView.swift` `SetupRigsRow`; `App/AppStore+SuiteRigs.swift` `saveRig`, `applySavedRig`, `deleteSavedRig` | — |
| Refinement 3 | A model's default rig fills only Auto rows when she is @-mentioned, "Applied …'s rig · Undo"; nothing with two @ models | fixed | `AppStore+SuiteRigs.swift` `applyDefaultRigIfAny`; `ComposerView.swift` `.onChange(of: …characterId)` | — |
| §1 Models "default rig" | Set a model's default rig | fixed ("Make it <name>'s default" in the Rigs row while one character is in the prompt) | `AppStore+SuiteRigs.swift` `setDefaultRig(for:)` | — |
| Principle 5, refinement 6 | Reuse settings restores a take's exact prompt and rig | fixed (feed card menu, Compare, and "Retake with changes" on a Suite take) | `AppStore+SuiteRigs.swift` `reuseSettings`; `App/AppStore+Actions.swift` `retake` | — |
| §2 feed actions, refinement 8 | Vary, Use as start frame (up front) | fixed (hover buttons with tooltips, and the context menu) | `Views/Suite/Composer/ComposerFeed.swift` `FeedTakeCard` | — |
| §2 "Feed" | Results in a feed beside the composer: running and failed cards, takes newest first, pages, a status filter | fixed: header "Takes" puts the feed in the picture's place beside the rail and prompt bar; All / Rendering / Finished / Failed | `ComposerFeed.swift` `ComposerFeed`; `ComposerView.swift` `page()`, header | — |
| Refinement 1 | Compare two takes side by side | fixed: Compare on two cards opens them side by side over the composer, "Play both", Vary / Reuse settings under each | `ComposerFeed.swift` `ComposerCompare`; `AppStore+SuiteRigs.swift` `compareInSuite` | — |
| §2 feed actions | Extend, Open in Edit, Post on every take | fixed (context menu) | `ComposerFeed.swift` `FeedTakeCard.menu` | — |
| §2 feed actions | Upscale, Use as reference, Direct in 3D, Save to collection | remaining: Upscale and Direct in 3D are on the take's own page, not on the card; **Library collections** (server table and API, refinement 6) were never built | — | WS1 server (collections), WS2 Mac card actions after |
| §2 "Hover a card" / refinement 7 | Only the hovered card plays, muted | fixed (a muted looping player while hovered, released when the pointer leaves) | `ComposerFeed.swift` `FeedHoverPlayer`, `FeedTakeCard` | — |
| §2 "Click a card" | Opens a large viewer over the feed, arrow keys move through it | fixed (click: the take large over the feed, "N of M", ← →, Esc; its actions under it; double-click still opens the take's page) | `ComposerFeed.swift` `FeedViewer` | — |
| §2 filter | Filter by tool or model as well as status | fixed ("All tools ▾", "All models ▾" beside the status filter; the status filter has 12 pt around each label and becomes "All ▾" when narrow) | `ComposerFeed.swift` `FeedScopeMenu`, `FeedFilterSegments`, `FeedFilterMenu`; `AppStore+SuiteRigs.swift` `loadFeed` | — |
| §2 empty state | "Your takes appear here" plus three preset suggestions | fixed ("Or start from a preset" with three presets, or three photo presets on Photo; filtered and empty: "Show everything") | `ComposerFeed.swift` `empty`, `presetSuggestions` | — |
| Refinement 1 | A "Queued" group with Run · $cost | remaining: there is no "queued, waiting for Run" state for Suite jobs on the server; running jobs show as cards | — | coordinator to confirm it is still wanted, then WS1 |
| Principle 6 | Disabled rows explain themselves ("Set by your clip") | fixed (Swap and Recast show Camera, Light and Style greyed, "Set by your clip"; Extend "Set by your video"; rows a tool simply doesn't use stay hidden, as the plan says) | `ComposerView.swift` `ComposerRail.decidedBy`, `SetupChipRow(decided:)` | — |

Fit shots added: `composer_feed`, `composer_feed_viewer`, `composer_swap` and `composer_compare` at 1280×800 and 1000×700
in all four themes, with lines for the feed filter (inside the header, labels whole), the large viewer drawn, the greyed
"Set by your clip" rows, and two takes compared. Library collections and the "Queued · Run" group wait for the
coordinator's decision. Copy used (Android's WS4 had no labels for these yet on `claude/muse-prompt-scripts` @7028e66):
"Rigs", "Saved rigs", "None saved" / "N saved", "Save this rig…", "Name this rig", "Make it <name>'s default",
"Applied <rig>" / "Applied <name>'s rig" + Undo, "Takes" / "Photos" / "Hide takes", "All · Rendering · Finished · Failed",
"Your takes appear here", "Vary", "Reuse settings", "Use as start frame", "Compare", "Remove from compare",
"Pick a second take to compare", "Compare takes", "Play both", "Done", "Open in Edit", "Extend", "Post…", "Open",
"Ready for a variation: press Generate", "Start frame set from <take>", "Waiting to start", "Rendering · N%",
"Didn’t render", "All tools" / "All models" (menus titled "Tool" and "Model"), "Show everything", "Nothing made like
that yet", "Or start from a preset", "N of M", "Previous take", "Next take", "Close the viewer", "Set by your clip",
"Set by your video".

## Edit layout (`plans/edit-layout.md`), approved

| Plan ref | Agreed | Status | Evidence |
|---|---|---|---|
| Sidebar | The app sidebar is its 72 pt rail while Edit is open | done | `Views/RootView.swift:50` |
| Top bar | 56 pt: back, title over version line, aspect as one segmented control, Claude / Templates / Hook ideas quiet, Export the one primary; quiet ones go icon-only when tight | done | `Views/Edit/EditSuiteView.swift:296-341` |
| Top bar | Undo / redo only in the timeline | done (none in the top bar) | `Views/Edit/EditSuiteTimeline.swift` toolbar |
| Media | 304 pt, 72 pt tab rail with full words, two-column takes grid, Import / Record VO, "Hide media" | done | `EditSuiteView.swift:148`, `Views/Edit/EditSuiteBin.swift:6-22,76,108` |
| Viewer | "Safe area" as one segmented control, tabular timecode, 40 pt play, sound and full screen | done | `Views/Edit/EditSuitePreview.swift:5-29,82-96` |
| Inspector | 328 pt, sections as a 3 × 2 grid of labelled buttons, "Hide inspector" / "Show inspector", starts expanded | done | `EditSuiteView.swift:141,149,353`, `Views/Edit/EditSuiteInspector.swift:17-22` |
| Timeline | 268 pt; 48 pt toolbar with Split, Delete, Speed, Keyframe, Crop (labels when wide), Ripple, Cut silences, Snap to beat toggles, zoom; ruler; Video / Captions / Sound lanes with 176 pt headers; frames, words, waveform | done | `EditSuiteTimeline.swift:5-17,51-112,124-128,294,468-494` |
| Sizes | Under ~1180 pt the media panel collapses on its own, then the inspector | done (now reachable: the window opens down to 960) | `EditSuiteView.swift:151-154,226-233` |
| Everywhere | Type scale only, no monospace (tabular figures) | fixed: the captions mode still used monospace and an off-scale 12 pt | `Views/Edit/EditSuiteCaptions.swift` (estimate label, pause marks, timecode) |
| Verify | `editaudit` shots at three sizes, four themes, fit check with no CUT; walk ends ALL DONE | done (run 42480381888: 24 FITS edit lines, ALL DONE); this pass adds an INFO shot at 1000×700 | `App/SnapshotRunner.swift` `editLayoutShots` |

## Recreate (`plans/recreate-edit.md`)

Being built now by the Recreate agent, not touched here: paste a link, drag and drop, export with the guide sound and the
"Use this sound" reminder, Claude on Recreate, Compare playing the real edit.

Other gaps found (for the coordinator to assign; all in the Recreate files):

| Plan ref | Agreed | Status | Evidence | Owner |
|---|---|---|---|---|
| "What the owner sees" 3 | **Cast:** choose which model plays the lead (and others) | remaining: no picker; Recreate uses the current model (or the first character) for every generated shot | `App/AppStore+Recreate.swift:334` `recreateModelId` | Recreate agent (WS2 Recreate) |
| 4 "Fill" | Generate all missing shots, **or pick which ones** | partly: the confirmation lists every new shot with its price but none can be left out (only swapped for one of your takes) | `Views/Edit/RecreateView.swift:47-80` | Recreate agent |
| §4 "Fix this slot" | Re-pick **or regenerate** that slot | partly: "Fix shot N" and "Pick another take" re-pick; there is no "Generate this shot again" for a matched or made shot | `AppStore+Recreate.swift:530`, `Views/Edit/RecreateRecipe.swift:117-131` | Recreate agent |
| §1 storage | Reference kept privately, deleted after 30 days unless kept as a recipe source | not checked on the Mac (server rule) | — | WS1 server to confirm |

## Also seen (not in these plans)

- Settings → Models names engines and providers ("MiniMax H3", "SeedVR2", "Replicate", "RunPod"); it sits in the
  owner-only part of Settings, so members don't see it (`Views/StudioViews.swift:648-650`). No change.
- Reuse settings would have laid the model's default rig over the restored rig (the restored prompt's character
  triggers it); fixed: the restored character is skipped once (`AppStore+SuiteRigs.swift` `reuseSettings`,
  `ComposerView.swift` `.onChange(of: …characterId)`).
