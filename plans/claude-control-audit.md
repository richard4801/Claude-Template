# One Claude · full-control audit (2026-11-11)

Owner rule (16:15): Claude has total control of the app and reports its own issues; the owner is not the tester.
Method: every Mac screen action (traced view → AppStore → MuseCore client → server route), checked against the one
registry (`claude/registry.ts`) and the owner's MCP tools. Keys, providers, prices, MCP tokens, top-ups and wallet
transfers stay owner-only in Settings and never go through Claude (rule, not a gap).

Gate column: none · spend · delete · post · settings. A gated tool never acts on Claude's word: without `confirm` it says
what would happen (and the price); with `confirm: true` it puts an approval card in the person's app.

## Status today

| Screen | Action | Tool today | Gate | Plan |
|---|---|---|---|---|
| Anywhere | open a page / take / character / edit / Suite tool / Recreate | `open_page`, `where_am_i` | none | ✓ |
| Anywhere | memory, other chats | `memory_*`, `chats_list`, `chat_read` | none | ✓ |
| Anywhere | watch a video | `watch`, `watch_closer` | none | ✓ |
| Anywhere | report what it couldn't do | `report_issue` (+ auto-captured tool errors) | none | ✓ Part A |
| Home / Queue | Run queue | GAP | spend | B2 `queue_run` |
| Queue | list jobs, watch progress | GAP | none | B1 `queue_list` |
| Queue | cancel / remove a job | GAP | delete | B2 `queue_cancel` |
| Queue | retry / run again | GAP | spend | B2 `queue_retry` |
| Queue | queued Suite shots: list / run / remove | GAP | none / spend / delete | B1 list, B2 run/remove |
| Suite | set up Shot, Talking, UGC, Storyboard, Swap/Recast, Extend, Photo | `suite_set_draft`, `suite_options`, `suite_cast`, `suite_see`, `suite_add_reference` | none | ✓ |
| Suite | price / Generate | `suite_estimate`, `suite_request_shot` | spend | ✓ |
| Suite | Upscale a take | GAP | spend | B2 `take_upscale` |
| Suite | Add shot to queue | GAP | none | B2 `suite_queue_add` |
| Suite | saved rigs: list / save / delete; locations | GAP | none / delete | B1 list; B3 save/delete |
| Suite | turn a Suite model on/off | GAP | settings | B3 (owner) |
| Cast | list characters (all people) | `list_characters` (owner MCP only) | none | B1 `characters_list` for everyone |
| Cast | create character, set sheet slots | GAP | none | B3 (needs uploads; app side) |
| Cast | fill missing angles / retake angle | GAP | spend | B2 `character_fill_angles` |
| Cast | Dress up / Enhance (estimate, start) | GAP | spend | B2 `character_dress_up`, `character_enhance` |
| Cast | tool run keep/reject/apply, retry, discard | GAP | none / spend / delete | B3 |
| Cast | archive / unarchive / duplicate / "never" list | GAP | none / settings | B3 |
| Cast | delete character | GAP | delete | B3 `character_delete` |
| Outfits | list / see | `suite_cast`, `suite_see` (in a Suite draft) | none | B1 `outfits_list` anywhere |
| Outfits | generate an outfit | GAP | spend | B2 `outfit_generate` |
| Outfits | save with a name / rename | GAP | none | B1 `outfit_rename` |
| Outfits | fill angles | GAP | spend | B2 `outfit_fill` |
| Outfits | delete | GAP | delete | B2 `outfit_delete` |
| Edit | every edit op, undo, frames, contact sheet, looks, captions, beats, versions, export | `open_edit`, `get_edit`, `apply_edit_ops`, `undo_edit`, `get_frame`, `get_contact_sheet`, `save_version`, `export_video`, … | none | ✓ (owner; editing is owner-only by design) |
| Edit | paid helpers: captions, fillers, cut-out, denoise | `auto_captions`, `cut_fillers`, `remove_background`, `denoise` | spend | ✓ |
| Edit | other helpers: reverse, stabilize, slow-mo, translate, separate stems | GAP | spend | B3 `edit_helper {feature}` via /v1/editor/jobs |
| Edit | style kits list / save / delete | GAP | none / delete | B3 |
| Recreate | analyse, recipe, briefs, match, fill, replace, apply | `analyze_reference`, `get_recipe`, `set_slot_briefs`, `match_slots`, `fill_slot`, `replace_slot`, `apply_recipe` | spend on fill | ✓ |
| Recreate | list references, retry analysis, export | GAP | none / spend | B1 list; B3 retry/export |
| Camera | sessions, cast, path, guides, shot draft | camera MCP tools (owner, Claude Code on the Mac) | none | ✓ |
| Camera | delete a session | GAP | delete | B3 |
| Library | find / filter takes | `list_takes` (edit-scoped, owner) | none | B1 `library_find` for everyone (query, character, status, date) |
| Library | collections: list / create / rename / add / remove | GAP | none | B1 `library_collections`, B1 `library_collect` |
| Library | delete a collection | GAP | delete | B2 |
| Library | approve / unapprove a take | GAP | none | B1 `take_status` |
| Library | discard a take | GAP | delete | B2 `take_discard` |
| Library | tag | no tag feature in the app (recipe tags only) | — | not a gap; ask owner if wanted |
| Library | save a take as a template | GAP | none | B3 |
| Templates | list / open | GAP | none | B1 `templates_list` |
| Templates | use (opens Photo with the preset) | `open_page` + `suite_set_draft` | none | ✓ (B1: templates_list returns the preset to set) |
| Templates | create / edit / duplicate / favourite / delete | GAP | none / delete | B3 |
| Posts | list scheduled / posted | GAP | none | B1 `posts_list` |
| Posts | schedule / post now (caption, hashtags) | GAP | post | B2 `post_schedule` |
| Posts | cancel a scheduled post | GAP | delete | B2 `post_cancel` |
| Posts | connect / disconnect an account | — | — | never through Claude (account credentials) |
| LoRA | build set / train / use | GAP | spend / settings | B3 (owner asks first: spend) |
| Settings | studio limits, editor helpers, strict links, image engine, engine defaults, members' caps, prompt library, prompt scripts | GAP | settings | B3 `studio_settings_get` (none) / `studio_settings_set` (settings, owner) |
| Settings | keys, providers, provider models, prices, MCP tokens, top-ups, credit transfers | — | — | never through Claude (owner rule) |
| Learn | playbook read / add | `playbook_read`, `playbook_add`, `memory_*` | none | ✓ (pin/delete stay the owner's by design) |
| Learn | recipes list / rename / tag / delete; gaps | GAP (`report_gap` writes gaps) | none / delete | B3 |
| Link import | import a public video link into the Library | GAP (`analyze_reference` takes links for Recreate only) | none | B3 `import_link` |
| Warm GPU | status / warm / off | GAP | spend | B3 (owner) |
| Mac files | read / write files on the person's Mac | Claude Code Bash/Read with the permission cards (one-Claude session, shipping) | ask each time | prompt guidance (below) |
| Blender | complex scene work | Blender MCP `execute_blender_code` (Mac) | none | prompt guidance (below) |

## The go-ahead for new gated tools (B2)

Today each place has its own approval (Suite assist `pending`, edit-session `pending`). New gated tools share one:
`claude_actions` rows (tool, args, summary, price, status) created by `confirm: true`, shown in the chat as a card
(`uiLine` name `approve`: "Delete 3 takes · Approve / Decline", "Post to TikTok Fri 18:00 · Approve"); the app calls
`POST /v1/claude/actions/:id {approve: true}` and the server runs the stored action as that person (their wallet,
their permissions). Server-side first; the Mac card is held on this branch for the coordinator's "go" (until then the
tool also says "Approve it in …" with the page to open, and the existing screen's own button still works).

## Scripts and Blender (guidance added to the one prompt)

- Bash on the person's Mac (Claude Code, with the permission card each time): batch file work (rename/convert/move
  exports), ffprobe/ffmpeg checks, reading a log or a project file the person points at. Never credential files,
  never sudo, deletes and network always ask.
- Blender Python (Blender MCP `execute_blender_code`): building and blocking scenes, many objects at once, procedural
  set dressing. Guides are still rendered with `render_camera_guides`.
- Prefer a MUSE tool when one exists; a script never replaces a gated MUSE action.

## Batches

- **B1 (no gate, server):** queue_list, characters_list, outfits_list, outfit_rename, library_find,
  library_collections, library_collect, take_status, templates_list, posts_list, recreate_list.
- **B2 (gated, server + held Mac card):** claude_actions + approve route; queue_run/cancel/retry, take_upscale,
  suite_queue_add, character_fill_angles, character_dress_up, character_enhance, outfit_generate, outfit_fill,
  outfit_delete, take_discard, collection delete, post_schedule, post_cancel.
- **B3:** the rest of the GAP rows above.
