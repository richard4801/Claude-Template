# Learning editor on Android, as built (WS4, 2026-11-08)

Built from the owner-approved mocks (one folder up), with the owner's two notes:
1. Pictures are the owner's own: an edit's take thumbnail, or a reference's poster (fetched by the API layer from the authenticated `/v1/recreate/references/{id}/poster`). With neither, a plain tinted tile with no figure and no icon. These screenshots use soft colour fields as stand-ins for the owner's frames. "Day in my life" shows the tinted tile of a reference whose poster has expired.
2. Plain suggestion copy: "You changed Claude's look 4 times", "You undid Claude's transitions 2 times", with no "(1 undo)".

Data comes from `/v1/learn` (owner only; Edit home shows "Playbook" and "Recipes" to the owner). Demo mode runs on FakeMuseApi.
- Code: `ui/screens/edit/learn/`.
- Tests: `LearnModelTest` walks rules (add, note, pin, make from a suggestion, delete) and recipes (filter, sort, rename, tag, open, delete) against demo's API. `LearnScreenshotTest` renders every state in all 4 themes, on phone and tablet.

Images (themes c, a, b, d):
- `phone_playbook_<t>.png`: Edit home, Rules, Suggestions, History, edit rule, add rule (from a suggestion), "Delete this rule?".
- `phone_recipes_<t>.png`: the grid, your-edit detail, reference detail, "Delete this recipe?".
- `phone_states_<t>.png`: Playbook empty, loading and error; Recipes loading, empty and no results.
- `tablet_playbook_<t>.png`, `tablet_recipes_<t>.png`.
