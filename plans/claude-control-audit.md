# One Claude · full-control audit (2026-11-11) — ALL COVERED

Owner rule (16:15): Claude has total control of the app and reports its own issues; the owner is not the tester.
Method: every Mac screen action (traced view → AppStore → MuseCore client → server route), checked against the one
registry (`server/api/src/claude/registry.ts`) and the owner's MCP tools.

**Never through Claude (rule, not a gap):** keys, providers and provider models, prices/markup, MCP tokens, top-ups and
credit transfers, connecting social accounts. Owner-only screens stay owner-only (the tools are hidden from members and
the routes refuse them).

**How the tools work.** New tools call MUSE's own routes in-process AS the person (`claude/appCall.ts`: a one-time
grant, never a token), so permissions, member limits and the wallet are exactly the app's. Gate column: none · spend ·
delete · post · settings. A gated tool never acts on Claude's word: without `confirm` it says what would happen and the
price (from the screen's own estimate or `dryRun`); with `confirm: true` it stores the exact call and puts an Approve
card in the person's chat (`claude/actions.ts`, `/v1/claude/actions`). Only that person, once, within 30 minutes.

## Table

| Screen | Action | Tool | Gate |
|---|---|---|---|
| Anywhere | open a page / take / character / edit / Suite tool / Recreate | `open_page`, `where_am_i` | none |
| Anywhere | memory, other chats | `memory_read/add/suggest`, `chats_list`, `chat_read` | none |
| Anywhere | watch a video | `watch`, `watch_closer` | none |
| Anywhere | report what it couldn't do | `report_issue` (+ auto-captured tool errors) | none |
| Anywhere | hear about new tools | capability note per chat (`claude/capability.ts`) | — |
| Home / Queue | list jobs, progress | `queue_list` | none |
| Home / Queue | Run queue | `queue_run` | spend |
| Queue | cancel / remove a job | `queue_cancel` | delete |
| Queue | Run again (video job) | `job_retry` (photo: via the Suite) | spend |
| Queue | queued Suite shots: list / run / remove | `queue_list`, `suite_queue_run`, `suite_queue_remove` | none / spend / delete |
| Suite | set up any tool (Shot, Talking, UGC, Storyboard, Swap/Recast, Extend, Photo), images sent | `suite_*` tools | none |
| Suite | price / Generate | `suite_estimate`, `suite_request_shot` | spend |
| Suite | Add to queue | `suite_queue_add` | none |
| Suite | Upscale a take | `take_upscale` | spend |
| Suite | saved rigs: list / save / rename; locations list | `suite_rigs` | none |
| Suite | delete a rig or location | `suite_rig_delete` | delete |
| Suite | Suite models on/off | `settings_change` (owner) | settings |
| Cast | list / find characters | `characters_list` | none |
| Cast | new character, details, "never add" list | `character_create`, `character_update` | none |
| Cast | fill missing angles | `character_fill_angles` | spend |
| Cast | Dress up / Enhance | `character_dress_up`, `character_enhance` | spend |
| Cast | review a run: keep/reject, pick, apply | `tool_run` | none |
| Cast | retry one picture | `tool_run_retry` | spend |
| Cast | archive / restore (owner) | `character_archive` | none |
| Cast | delete a character, discard a run | on screen (owner or maker; the routes check) | — |
| Outfits | list / rename | `outfits_list`, `outfit_rename` | none |
| Outfits | make an outfit | `outfit_make` | spend |
| Outfits | fill angles | `outfit_fill` | spend |
| Outfits | delete | `outfit_delete` | delete |
| LoRA | status, prices, keep/drop training photos | `lora` | none |
| LoRA | build set / train / use on-off / retrain | `lora_action` | spend |
| Edit | every edit op, undo, frames, looks, captions, beats, versions, export | Edit tools (`open_edit`, `apply_edit_ops`, …) | none |
| Edit | AI helpers (captions, cuts, cut-out, denoise, reverse, stabilize, slow-mo, translate, separate) | `auto_captions`, `cut_fillers`, `remove_background`, `denoise`, `edit_helper`; `edit_jobs` to follow | spend |
| Edit | style kits: list / save / change; delete | `edit_kits`; `edit_kit_delete` | none; delete |
| Recreate | analyse, recipe, briefs, match, fill, replace, apply | Recreate tools | spend on fill |
| Recreate | list references; delete | `recreate_list`; `recreate_delete` | none; delete |
| Camera | sessions, cast, path, guides, shot draft | camera MCP tools (owner, Claude Code on the Mac) | none |
| Camera | delete a session | `camera_session_delete` (owner) | delete |
| Library | find / filter takes | `library_find` | none |
| Library | approve / unapprove | `take_status` | none |
| Library | collections: list / create / rename / add / remove; delete | `library_collections`, `library_collect`; `collection_delete` | none; delete |
| Library | discard a take | `take_discard` | delete |
| Library | tag | no tag feature in the app (recipe tags: `recipes`) | — |
| Templates | list / open; create / update / duplicate / favourite; delete | `templates_list`; `templates_manage`; `template_delete` | none; none; delete |
| Posts | list; schedule / post now; cancel | `posts_list`; `post_schedule`; `post_cancel` | none; post; delete |
| Link import | check / import / list; delete | `import_link`; `import_delete` | none; delete |
| Learn | playbook read / add | `playbook_read`, `playbook_add`, `memory_*` | none (pin/delete stay the owner's) |
| Learn | recipes list / open / rename / retag; delete | `recipes`; `recipe_delete` | none; delete |
| Settings | studio limits, image engine, editor helpers, Recreate links, Suite models, default models, models members see | `settings_read`, `settings_change` (owner) | settings |
| Warm GPU | status / off; on / keep warm | `warm_gpu`; `warm_gpu_on` (owner) | none; spend |
| Owner | Claude's reports | `claude_issues`, `claude_issue_mark` (MCP), `/v1/claude/issues` | none |
| Anywhere (fallback) | operate the MUSE window itself (see its controls, press, type, pick, toggle, scroll, menu, keys); never keys/providers/prices/sign-out/payments/delete confirmations | `ui_snapshot`, `ui_act`, `ui_wait` (claude/uiControl.ts; the person's own Mac, X-Muse-Caps: ui) | none (Esc stops; Settings → Claude toggle) |
| Mac files | read / write files on the person's Mac | Claude Code Bash/Read with the permission cards | asks each time |
| Blender | complex scene work | Blender MCP `execute_blender_code` | none |

## Scripts and Blender (in the one prompt)
- Bash on the person's Mac (Claude Code, with the permission card each time) only for jobs no MUSE tool covers: batch
  file work, ffprobe checks, reading a file the person points at. Never credential files, never sudo, never to get
  around a go-ahead.
- Blender Python through the Blender MCP for building/blocking scenes; guides still via `render_camera_guides`.

## Shipped
- Part A issues e6c9ba3e (0031) · B1 ff2d1bd8 · B2 eaa4f337 (0032) · delete ownership da798e70 · B3a 07a276b6 ·
  B3b 419891cb · B3c 469b1701 · capability note 6cc924ef (0033) · B3d (LoRA, warm GPU, rigs/locations, kits, job
  retry, Dress up/Enhance item retry with `dryRun`, LoRA `/estimate`).
- Held for the coordinator's "go": the Mac Approve card (local branch `claude/claude-issues-mac`; backup
  `plans/patches/mac-claude-approve-card.patch`). Until it ships, older apps show "Waiting for your go-ahead: …"
  without a button and Claude sends the person to the screen.
