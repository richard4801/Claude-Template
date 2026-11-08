# Learning editor screens (spec for mocks, 2026-11-08, workstream 3)

These screens are where the owner sees and steers the studio's editing memory. They are built on the shipped server (plans/api.md "Learning editor", `/v1/learn/*`, owner only).
- **Mocks first:** WS2 (Mac) and WS4 (Android) make the mocks, and the owner approves them before anyone builds.
- **Who builds:** WS4 builds Android, next to its Recipe view; WS2 builds the Mac after Build → generate.
- **Design rules:** follow `plans/design-direction.md` and the `muse-design-review` skill: the roles, the type scale, Phosphor Regular, sentence case and one primary action per screen.

## Where it lives
- **Edit home.** Next to "Recreate an edit", two quiet buttons: **"Playbook"** and **"Recipes"**. They are text buttons with a Phosphor icon (`book-open-text`, `stack`), not filled.
  - Owner only. Members don't see them; the server answers them `403`.
- **Inside the editor (Mac).** The Claude panel gains a third tab, **"Playbook"**, after Chat and History. It is a read-only, compact list of the pinned rules with "Open playbook" at the bottom, so the owner sees what Claude is following while it edits.
  - On Android, the same list sits in the Claude sheet, behind a "Playbook" segment.
- **No new sidebar items.** The Mac sidebar and its Edit rail stay as WS2 laid them out.

## 1. Playbook
The rules Claude follows, in plain words. The owner reads, adds, edits, pins and deletes them.

**Layout:**
- **Title:** "Playbook" (`display`). Under it, one `caption` line in `ink2`: "Claude reads these before every edit."
- **Primary action:** "Add rule" (`action` fill, top right on Mac, bottom bar on phone). It is the only filled button.
- **Segments:** "Rules" · "Suggestions" · "History". This is a segmented control, not a menu, so the CI click-through can reach every segment.
- **Rules:**
  - Grouped by area, with section headings in `heading` / `ink`, only for areas that have rules, in this order: Captions, Text, Pacing, Transitions, Look, Motion, Speed, Timing, Sound, Shape, Other.
  - Pinned rules come first in each group.
  - Grouping is by space (`s5` between groups), not boxes.
- **A rule row:**
  - **Text:** the rule in `body` / `ink`, up to 3 lines with an ellipsis, plus a tooltip on the Mac.
  - **Second line:** `caption` / `ink2`, saying who wrote it and its evidence in words: "Yours", "From Claude · 3 corrections", "Learned · 2 posts". This is a value pair, so a middle dot is allowed.
  - **Trailing controls:**
    - Pin is an icon-only toggle (`push-pin`), with `accent` when pinned and `ink2` otherwise. Its label is "Pin rule" / "Unpin rule".
    - On the Mac, Edit (`pencil-simple`, label "Edit rule") and Delete (`trash`, label "Delete rule") show on hover and on keyboard focus.
    - On the phone, tap opens the editor and a long-press offers Delete.
    - No row menus.
  - **Claude's rules** sit unpinned until the owner pins them. There's no badge colour: the caption says "From Claude".
- **Rule editor:** a sheet on the phone, a popover-style panel on the Mac (not a phone sheet).
  - The text field shows a counter at 250+ characters ("280 / 300").
  - Area is a segmented list of the areas above.
  - Evidence is read-only, one `caption` line each: "Correction · Changed the look after Claude's “Look Film” · 2 days ago". Tapping a line opens that edit, when the take still exists.
  - "Add a note" is a quiet text button that adds a note to the evidence.
  - Buttons: "Save rule" (primary) and "Cancel". Delete is a quiet "Delete rule", red text only, at the bottom.
  - The delete confirmation reads "Delete this rule?", with "Delete rule" and "Keep".
- **Suggestions** (from `GET /v1/learn/lessons`):
  - One row per lesson, in words: "You changed the look after Claude's Look 4 times (1 undo)". The second line shows its 1–2 latest examples in `caption`.
  - Each row has a text button, "Make a rule". It opens the rule editor with the area preset, a draft the owner rewrites ("Leave the look as Claude sets it…" is NOT pre-written; the field starts empty with the placeholder "Say what Claude should do instead"), and the lesson's corrections attached as evidence.
  - Nothing becomes a rule without the owner.
- **History** (from `GET /v1/learn/corrections`): the latest corrections.
  - Each row has the plain words, the area as a chip-free `caption`, and a relative time.
  - Tapping a row opens the edit at that take.
  - The list is read-only.
- **States:**
  - **Loading:** three rows of skeleton lines.
  - **Empty Rules:** "No rules yet. Claude suggests some from the changes you make to its edits, and you can add your own." with "Add rule".
  - **Empty Suggestions:** "No suggestions yet. They appear after you change or undo a few of Claude's edits."
  - **Error:** "Couldn't load the playbook · check your connection" with "Try again".
  - **Full** (200 rules): "Add rule" is disabled, with the help text "The playbook holds 200 rules · delete some first".

## 2. Recipes
Every analysed reference and every finished edit, so the owner can find what worked.

**Layout:**
- **Title:** "Recipes" (`display`). No primary action of its own; "Recreate an edit" stays on Edit home.
- **Filter row:**
  - A search field ("Search recipes").
  - A segmented "All" · "References" · "Your edits".
  - Sort: a segmented "Newest" · "Most viewed". No menu.
  - The 8 most-used tags as chips; tapping a chip filters, and a second tap clears it. Chips use the `chip` radius and are toggled by `accent` outline/text, never a fill colour.
- **The grid:** tiles of the picture plus a caption, no boxes. Adaptive columns, 160–200 pt on the Mac and 2 columns on the phone.
  - **Picture:** a reference's poster (`/v1/recreate/references/{id}/poster`) or the edited take's thumbnail, 9:16 with the `container` radius. When the poster has expired, `field` with a `film-strip` icon.
  - **On the picture:** a `micro` badge, bottom right: "12 s · 9 cuts".
  - **Under it:** the name (`label` / `ink`, 1 line), then one `caption` line: the summary, or, for edits, the views when posted ("1.2k views · 42% completion").
- **Recipe detail:** a right-hand panel on the Mac (it replaces the grid's right part at ≥ 1180 pt, otherwise a push); a push on the phone.
  - **Header:** the name (`title`), editable inline on the Mac with a pencil button labelled "Rename recipe"; the summary; origin in words ("Reference", "Your edit").
  - **Shape of the edit:** a strip of the slots as proportional bars on `field`, with the cuts as hairline gaps and transitions marked by their Phosphor icon. Under it, `caption` values: "9 shots · 27 cuts/min · 120 bpm · 3 text items". No numbers without units.
  - **Look:** the 5 grade swatches in a row (media, so no labels) plus the look name if any ("Golden warmth").
  - **Performance** (edits that were posted): 4–6 value pairs in a 2-column list: "Views 1.2k", "Likes 80", "Saves 12", "Avg watch 6.5 s", "Completion 42%", "Posts 1". Not a stat hero block. Fields that weren't reported are left out.
  - **Tags:** chips with an `x` (label "Remove tag …") and a "+ Tag" text button that opens an inline field. Lower case, as the server stores them.
  - **Closest recipes:** 3 small tiles with words for distance: "Very close" (< 0.3), "Close" (< 0.6), else "Different". Tapping one opens it.
  - **Actions:**
    - Primary: "Use in Recreate" for references whose video still exists, or "Open edit" for your edits.
    - Quiet: "Delete recipe", confirmed with "Delete this recipe?" / "Delete recipe" / "Keep". Deleting a recipe doesn't delete the reference or the take; the confirmation says so in one `caption` line.
- **States:**
  - **Loading:** a skeleton grid of 6 tiles.
  - **Empty:** "No recipes yet. Recreate an edit or finish one in Edit, and it's saved here." with the "Recreate an edit" button. This is the one place it's primary.
  - **No results:** "Nothing matches “dance”" with "Clear filters".
  - **Error:** as in the Playbook.

## 3. Gaps
- The bottom section of the Recipes page, `heading` "Effects MUSE can't make yet". Each row shows the effect and how often it was needed ("Unknown transition · 4 references", "Lens flare · asked once"), plus the latest example's note in `caption`.
- Read-only. This list tells us what to build next, so there's no voting UI.
- Hidden when empty.

## Copy (exact)
"Playbook", "Recipes", "Add rule", "Save rule", "Delete rule", "Delete this rule?", "Keep", "Pin rule", "Unpin rule", "Edit rule", "Make a rule", "Rules", "Suggestions", "History", "Search recipes", "All", "References", "Your edits", "Newest", "Most viewed", "Use in Recreate", "Open edit", "Delete recipe", "Delete this recipe?", "Rename recipe", "+ Tag", "Effects MUSE can't make yet", "Claude reads these before every edit."

- No exclamation marks.
- No "AI" sparkle. Claude is named only in this owner-only area.
- No model or provider names.

## Accessibility and the CI click-through
- Every icon-only control has the label listed above, plus a tooltip on the Mac.
- Segments and sort are segmented controls, not menus, because the click-through skips menus.
- The rule editor's Delete and the recipe's Delete open a confirmation. "Keep" must be reachable so the walk can back out.
- **Touch targets:** ≥ 48 dp on Android, ≥ 28 pt on Mac. Visible keyboard focus on the Mac. Reduce motion is respected (the 280 ms push becomes a cross-fade).

## Data
| UI | Endpoint |
|---|---|
| Rules list, add, edit, pin, delete | `GET/POST /v1/learn/playbook`, `PATCH/DELETE /v1/learn/playbook/{id}` |
| Suggestions | `GET /v1/learn/lessons` (a lesson with `ruleId` already has a rule: show "See rule" instead of "Make a rule") |
| History | `GET /v1/learn/corrections?limit=50` |
| Recipes grid, search, filters | `GET /v1/learn/recipes?q&tags&origin` (sort "Most viewed" in the app by `performance.views`); the tile uses `picture`, `durationSec`, `cuts`; the primary action needs `available` |
| Tag chips | `GET /v1/learn/tags?limit=8` |
| Recipe detail, rename, tags, delete | `GET/PATCH/DELETE /v1/learn/recipes/{id}` |
| Closest recipes | `GET /v1/learn/recipes/nearest?recipeId={id}&k=3` |
| Gaps | `GET /v1/learn/gaps?limit=10` (`references` / `asks` for the words) |
| Evidence and History taps | `takeExists` on corrections and on correction evidence in the playbook |
| Claude panel's Playbook tab | `GET /v1/learn/playbook` (pinned first; show the first 10) |

## Checked against the skill
- **One primary action per screen:** "Add rule" on the Playbook. The Recipes page has none in the normal state; the detail has its own.
- **Media leads the Recipes page:** posters, not cards.
- **Rule rows read as text first.**
- **Nothing on the slop list:**
  - no icons in circles;
  - no stat hero (performance is a quiet value list);
  - no ALL CAPS section labels;
  - no badges on every row ("From Claude" is words);
  - no cards in cards;
  - no shimmer except loading skeletons;
  - middle dots only in value pairs.
- **Tone, not shadow:** the detail panel is `raised` on `canvas`, and the rule editor floats with `float` on the phone only.
