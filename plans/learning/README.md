# Playbook and Recipes: Mac screens (mock, for the owner's approval)

These mocks follow workstream 3's spec (`plans/learning-editor-ui.md` on `claude/muse-editor-v2`), `plans/design-direction.md` and the `muse-design-review` skill.
- **Setting:** inside the current Mac chrome (the top bar with search and theme dots, and the sidebar with Edit selected), as in `plans/recreate/built_*.png`.
- **How they're made:** `design/learning/render.py`, which reuses the tokens, fonts, Phosphor icons and Playwright set-up from `design/edit-layout/render.py`.
- **Themes and size:** `c` Soft Tactile, `a` Editorial, `b` Camera Body, `d` Creator Pop, all at 1280 × 800. The states sheet is 1280 × 880.
- **Pictures:** the Blender preview posters (mannequins), with no people. The data is made up but fits MUSE, and "Summer cut" is the Recreate fixture.

Regenerate with `PHOSPHOR=<unpacked @phosphor-icons/core 2.1.1> python3 design/learning/render.py` (add screen names to render only those).

## The images
- **`playbook_rules_*`: Playbook, Rules.**
  - **Top of the page:** the title "Playbook" with "Claude reads these before every edit." under it. "Add rule" is the only filled button, top right. Below sits the Rules · Suggestions · History segmented control.
  - **Groups:** the rules are grouped by area (Captions, Pacing, Look, with Sound below the fold). Groups are set apart by space, not boxes, and pinned rules come first.
  - **Who wrote each rule:** the line under each rule says "Yours", "From Claude · 3 corrections" or "Learned · 2 posts". There's no badge colour.
  - **Long rules:** the second Captions rule is 290 characters (the limit is 300) and stops at three lines with an ellipsis. The Mac tooltip shows the whole rule.
  - **Hover:** the "On calm songs…" row shows its hover state, a light tone with Edit and Delete next to the pin, and the "Edit rule" tooltip.
  - **Pins:** each row ends in the pin. It shows `accent` when pinned and `ink2` when not. In Creator Pop it shows `ink`, because pink fails as an icon colour.
- **`playbook_suggestions_*`: Suggestions.**
  - **Rows:** each row describes a lesson in words ("You changed the look after Claude's Look 4 times (1 undo)"). Under it, a caption names the latest one or two edits where it happened.
  - **Action:** each row has a quiet "Make a rule" text button.
- **`playbook_editor_*`: the rule editor.** I chose the **new rule from "Make a rule"** version.
  - **The panel:** a popover-style panel anchored to the first suggestion's "Make a rule". It is titled "New rule".
  - **Text field:** empty and focused, with the placeholder "Say what Claude should do instead". The field shows no counter, because the counter only appears from 250 characters.
  - **Area:** preset to Look.
  - **Evidence:** four read-only lines, such as "Correction · Changed the look after Claude's “Look Film” · 2 days ago", then "Add a note".
  - **Buttons:** "Cancel", and "Save rule" as the primary.
  - **Not shown:** "Delete rule" doesn't appear, because the rule is new.
- **`recipes_*`: Recipes.**
  - **Filter row:** the search field ("Search recipes"), All · References · Your edits, and Newest · Most viewed. Both are segmented controls, with no menus.
  - **Tags:** the eight most-used tags, with "dance" active. An active tag gets an accent outline and accent text, never a fill. In Creator Pop the outline and text are `ink`.
  - **Grid:** six 9:16 posters with a badge such as "15 s · 8 cuts". Under each is the name, then the summary for references or the views for posted edits ("1.2k views · 42% completion").
  - **Gaps:** below the grid, "Effects MUSE can't make yet" lists unknown transitions, lens flare and speed ramps, each with how often it came up and the latest example.
- **`recipes_detail_*`: the same page with the detail panel.** At 1280 pt, which is ≥ 1180, the detail is a right-hand panel on `raised`, and the grid drops to four columns. The selected tile, "Living room dance", has the selection outline. The panel shows:
  - **Header:** the name, a rename pencil ("Rename recipe"), a close button, the summary, and the origin "Your edit".
  - **Shape of the edit:** the shot bars on `field`, separated by hairline gaps, with transition icons above. Under it: "9 shots · 32 cuts/min · 120 bpm · 3 text items".
  - **Look:** five soft swatches ("Golden warmth": dark umber, tan, sand, cream and a dusty blue-grey). They are as muted as the approved Recreate swatches.
  - **Performance:** a quiet two-column value list (Views 1.2k, Likes 80, Saves 12, Avg watch 6.5 s, Completion 42%, Posts 1), not a stat block.
  - **Tags:** chips, each with an `x`, plus "+ Tag".
  - **Closest recipes:** three small tiles labelled "Very close", "Close" and "Different".
  - **Footer:** the primary "Open edit", with a quiet "Delete recipe" on the left.
- **`claude_playbook_tab_*`: the editor's Claude panel, with the Playbook tab.**
  - **Tabs:** Chat · History · Playbook, with Playbook selected.
  - **The list:** the pinned rules, compact (caption size, two lines at most), under small area labels.
  - **Footer:** a quiet "Open playbook" link with the book icon.
- **`states_*`: the states sheet.** Small frames of each state:
  - **Playbook:** loading as three skeleton rows, empty Rules (with "Add rule"), empty Suggestions, the error with "Try again", and full at 200 rules (Add rule disabled, with "The playbook holds 200 rules · delete some first").
  - **History:** the read-only History list.
  - **Recipes:** loading as skeleton tiles, empty (the one place "Recreate an edit" is primary), and no results ("Nothing matches “dance”" with "Clear filters").
  - **Confirmations:** "Delete this rule?" and "Delete this recipe?", each with "Keep". The recipe one adds a caption line: "The reference and the take stay."

## Where I interpreted or departed from the spec
1. **The editor sits over Suggestions, not Rules.** The brief said "over Rules", but "Make a rule" only exists on the Suggestions segment, so the panel is anchored there. If you edit an existing rule, the same panel opens from the row's pencil over Rules, with the counter and "Delete rule".
2. **"Save rule" shows as disabled** (40% opacity), because the field starts empty and an empty rule can't be saved. It becomes the normal filled button as soon as you type.
3. **The Area control is a segmented control on two rows.** Eleven areas don't fit one row of a 520 pt panel. It is still a segmented control with one selection, not a menu, so the click-through can still reach every area.
4. **The panel is titled "New rule".** The spec gives no title. When you edit a rule, I'd use "Edit rule", which matches the button label.
5. **Small additions to the chrome:**
   - a back button ("Back to Edit") next to each page title;
   - a close button ("Close recipe") in the detail panel;
   - the caption "Claude reads these before every edit." repeated at the top of the Claude panel's Playbook tab;
   - small area labels in that tab, so the compact list still reads by area.
6. **"Delete recipe" uses red text**, matching the rule editor's "Delete rule", which the spec makes red. It stays quiet: text only, no fill.
7. **The confirmations use a filled red destructive button**, which is the Mac alert convention. That is the one fill on that sheet.
8. **The Claude panel has no sparkle.** The built panel header uses `ClaudeBadge`, which has a sparkle icon. The direction file bans sparkles for AI, so the mock shows only "Shared with Claude". I suggest dropping the sparkle from the badge.

## Open questions for the owner
- **Pin colour in Soft Tactile.** The pinned (`accent` green) and unpinned (`ink2` grey) pins are hard to tell apart at a glance, because the two colours are close in tone. Should a pinned pin use Phosphor's Fill weight? That would be the one exception to "Regular only", and it is the usual Mac convention.
- **Which editor to approve.** The new-rule editor, shown here, or should I also mock the edit-an-existing-rule variant, with "280 / 300" and "Delete rule"?

## Built (Mac CI run 42480381888, demo mode, 1280 × 800)
`built_<screen>_<theme>.png`, from the app's own review mode (`SnapshotRunner.learnShots`):
- `playbook`: Rules, grouped by area, pinned first, "Add rule" top right.
- `playbook_editor`: the rule editor on the long learned rule (counter "271 / 300", evidence, "Add a note", "Delete rule").
- `suggestions`: the lessons in plain words ("You changed Claude's look 4 times") with "Make a rule".
- `recipes`: the grid with search, the two segmented filters and the top tags; "Effects MUSE can't make yet" below the fold.
- `recipe_detail`: "Living room dance" in the right-hand panel.
- `claude_tab`: the editor's Claude panel on its Playbook tab.

Pictures: demo mode has no video files, so edits show the bundled Blender mannequin stills and references show `field` with the film-strip icon. With a server, edits show their take's thumbnail and references their poster.
