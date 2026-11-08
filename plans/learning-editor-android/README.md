# Learning editor on Android: MOCKS for the owner's approval (WS4, 2026-11-08)

These follow WS3's spec, `plans/learning-editor-ui.md`, and the `muse-design-review` skill:
- the design-direction roles and type scale, and Phosphor Regular;
- sentence case;
- one primary action per screen;
- grouping by space, not boxes;
- no badges, stat heroes or icon circles.

The mocks are Compose code in the test source set (`app/src/test/.../mocks/`), so nothing ships before approval. Building them reuses the same composables on the `/v1/learn/*` data.

## Images (themes c Soft Tactile, a Editorial, b Camera Body, d Creator Pop)

- **`phone_playbook_<t>.png`** (390 dp), left to right:
  1. Edit home with the two quiet entries, "Playbook" and "Recipes";
  2. Rules: grouped by area, pinned first, the pin toggle, "Add rule" in the bottom bar;
  3. Suggestions, with "Make a rule";
  4. History;
  5. the rule editor sheet: text, area chips, evidence, "Add a note", "Save rule" / "Cancel", "Delete rule" in red text;
  6. "Delete this rule?";
  7. empty Rules.
- **`phone_recipes_<t>.png`**, left to right:
  1. Recipes: search, All / References / Your edits, Newest / Most viewed, tag chips (accent outline when on), a 2-column poster grid with a "15 s · 7 cuts" badge;
  2. loading skeleton;
  3. empty, with "Recreate an edit" as the one primary action;
  4. the detail of your edit: the shape of the edit as proportional bars with transition icons, the Look swatches, Performance as a quiet value list, tags with remove buttons and "+ Tag", closest recipes as "Very close" / "Close" / "Different", "Open edit", "Delete recipe";
  5. the detail of a reference, with "Use in Recreate" and no Performance;
  6. "Delete this recipe?" (it says the edit and its video stay).
- **`phone_recipe_detail_full_<t>.png`:** both details, the whole page.
- **`tablet_playbook_<t>.png`** (1280 × 800): a centred column, with "Add rule" top right.
- **`tablet_recipes_<t>.png`:** the grid with the selected recipe's detail in the right panel (`raised`). "Effects MUSE can't make yet" sits at the bottom of the grid.

The sample content is the demo studio's, and the numbers are illustrative.
