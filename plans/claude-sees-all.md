# Claude sees and sets everything on screen (owner complaint 2026-11-11)

Owner: "Claude still can't see clips added to swap or anywhere… can't see references added, can't use the Blender
direction setting under Rig to pin our blocking." Rule: anything she can see or set on screen, Claude can see and set
(spend, delete, post still go through the Approve card). Branch `claude/claude-sees-all`.

## Root cause
The shared Suite draft (`suite_assists`, PATCH /v1/suite/assist) only carried the prompt chips, rig and bar. The apps
never sent the input slots, Swap/Recast's clip, Extend's video, the Directed camera (Rig → Movement → Directed with the
Blender guides) or the pinned model, and the Mac synced only while the Suite chat panel was open. Camera-session Shot
drafts (sd_) had no shared draft at all, so no Suite tool could reach them.

## Audit: composer field → Claude (before → after this branch)
| Page / field | See before | Set before | After (server) | Needs app patch |
|---|---|---|---|---|
| Shot/Talking/UGC prompt, @model, outfit, rig, moves, bar | yes (when panel open) | yes | same; synced always (Mac patch) | Mac: sync without panel |
| Slot frames (start/middle/end) | no | no (sent images only) | in request + onScreen, suite_see {input} | yes (screen) |
| Slot references / videos / audio | no | images via set_sent_images | onScreen, watch / suite_see | yes (screen) |
| Swap: source clip (upload or link) | no | no | request.clipId + onScreen watch id; watch takes clip ids and /uploads/ links | yes (screen) |
| Swap: character, outfit, quality, keep audio | no (tool shot, empty) | no | from screen request; Claude's @model pick goes to the Swap panel (Mac) | yes |
| Recast: clip, cast | no | no (see only) | request.cast/clipId + onScreen | yes |
| Extend: video, direction | no | no | request.extend + onScreen watch | yes |
| Rig → Movement → Directed (Blender guides) | no ("preset") | server only, app ignored it | request.camera from screen; suite_set_draft directed; directed:null clears both | yes (held patch + this) |
| Pinned model / resolution | no | server only | sent both ways | yes (held patch + this) |
| Camera-session Shot draft (sd_) | not_found | no | any suite tool + images-sent tools take sd_/cs_ (own sa_sd_… draft); Camera page binds its session; open_page opens it | Mac: open sa_ in composer |
| Chat-attached image | path only | no | references/sent take any studio image | Mac: upload on attach → uploadId |
| Library still as reference | Take not found | url only | suite_add_reference takeId (+at), {url}, take id given as uploadId; sent images take a bare take id | no |
| see_photos | takes only | – | + upload ids and /uploads/ links; clearer not-found | no |
| Character page: outfit angles | assistId required | – | suite_see {outfitId} / {modelId} with no draft (labelled front, ¾, side, back, faces) | no |
| Character page: reorder outfit angles | – | no tool | NOT DONE (new tool, needs an owner yes: changes stored outfits) | – |
| Prompt over 2000 characters | bad_request | – | message says the limit and to shorten | no |
| Anything else on screen | – | – | ui_snapshot / ui_act (claude/ui-control, Mac queue) | yes |

## Server (this branch, tests in test/suite-screen.test.ts)
- `suite/screen.ts`: `screen` in the draft (request + inputs, lenient), `withScreen` (media from the screen, Claude's
  fields from the draft), `onScreen` view, `resolveAssist` (sa_ / sd_ / cs_ / cameraSessionId / chat page / latest chat).
- `suite/assist.ts`: requestOf uses the screen; view has `onScreen`; references take takes and links.
- `suite/mcpTools.ts`: no tool needs assistId; suite_see shows models/outfits without a draft and screen pictures.
- `claude/watch.ts`: watch takes /uploads/ links and keys, cs_ (guide clip), camera assets; see_photos takes uploads.
- `claude/sentTools.ts`, `images/sent.ts`, `claude/chatTools.ts` (open_page sd_/cs_).

## Apps (held patches; NOT compiled in this session: no Swift here)
- `plans/patches/claude-sees-all-mac.patch`, applied ON TOP of `plans/patches/mac-claude-held.patch`.
  SuiteScreen (MuseCore, tested), bridge sends `screen`, syncs whether or not a chat is open, Swap takes Claude's
  @model/outfit, SuiteAssistDraft.apply takes Directed and the pinned model ("Movement", "Model" in the toast),
  open_page suite with an sa_ id opens that shared draft, chat images are uploaded on attach (uploadId in Claude's line).
- `plans/patches/claude-sees-all-android.patch`: SuiteScreen.kt, ComposerDrafts directed/engineModel both ways,
  pushComposerToAssist sends `screen`. Android has no open_page handling yet (left for the Android one-Claude work).
