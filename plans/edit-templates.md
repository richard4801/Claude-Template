# Edit templates: effects and transitions in one click (plan + design)

_Planning worker, 2026-11-14. Owner-approved goal: a template library in Edit for effects and transitions (not photo
presets, not caption/look kits). It works on any clip in one click on the Mac and Android. MUSE Claude can save new
templates into it. It starts with the 27 templates MUSE Claude already made (report ci_d4cc38758998).
This file is the plan and design only. The one piece of code is the intake in §1, on branch
`claude/template-pack-intake`._

Mockups are in `plans/design/edit-templates/` (built from `src/build.mjs` with the repo's fonts and Phosphor icons):
- `1-mac-library-effect-light.png`: Mac, theme A. The Templates panel, a live effect previewed on the selected clip, its settings, and "Apply to clip 12".
- `2-mac-library-transition-dark.png`: Mac, theme B. A finished-clip transition aimed at a cut, with its overlay shown on the timeline.
- `3-android-sheet-light.png`: Android. The bottom sheet grid, then the settings and "Apply to clip 3".
- `4-saving-and-states-light.png`: Save as template, Claude's "saved" chat card, and the loading, empty, older-app and offline states.

## 0. What I found

### Where the 27 live today
- **Edit `es_90f88fe3b4a9` ("Icon", revision 166)**, read through the owner MCP `get_edit`. It has 60 baked assets in
  the project, for example `glitchv4`, `fxwhite`, `fxneg06`, `cut6`, `strip227v4`, `band247v2`, `panels250v2`,
  `window457v4`, `split287`, `eye309v3`, `punch327`, `boom361`, `drop417b7`, `page340v3`, `frz08v27`, `stripes497v4`,
  `glass521v2`, `shatter561v1`, `covers561`, `white587`, `quiet589`, `big607v4`, `sigA`, `endcard2a/2b`, the
  `words*glass/frost/glitch` lyric sets and `glitchsfx1`.
  - They sit as plain video items on the extra tracks `video1`, `words1` and `mark1`. One uses `blend: add`.
  - The main track also has 7 live scale punch-ins (keyframes 1.35 → 1 over 0.27 s) and one `alphaMatte`.
  - In short, everything except the punch-ins was **baked into media** on the owner's Mac and dropped on top.
- **The pack itself** is only on the owner's Mac ("Icon storyboard/templates": README, templates.json, scripts,
  finals, previews). The server has never seen it.

### Gaps
- `report_gap` writes to `edit_gaps` (`src/editor/learnSchema.ts`, `Learning.addGap` in `src/editor/learn.ts`).
- The owner reads gaps through `GET /v1/learn/gaps`. A personal token can't reach `/v1`, and on MCP the only way in
  was `playbook_read`, which shows the **top 5**. So most of the 27 were unreadable.
- The 5 visible ones:
  - `other:local-subject-matte`
  - `other:audio-keyframes` (pack id `contained-sound-ending`)
  - `text:write-on-signature-end-card` (`storm-end-card`, `corner-signature`)
  - `other:voice-onsets`
  - `text:placed-lyrics` (`lyric-placed-art`, `title-behind-subject`)
- Example notes are cut to 200 characters, so the gaps can't carry the specs. The pack has to come over.

### Existing "templates" don't fit
| Thing | Table | What it holds | Why it can't hold these |
|---|---|---|---|
| `templates_manage` / `templates_list` | `templates` | AI photo prompt layers | Not Edit at all |
| `edit_kits` (StyleKit v1, `editor/kit.ts`) | `edit_kits` | One look, filter, adjust, transition, caption and text style, applied to the whole edit | No effects, keyframes, masks, blends, overlays, timing or per-clip use |
| Recipes (`learn.ts`, `recreate/assemble.ts`) | `edit_recipes` | A whole edit's structure | Builds a whole edit, not one effect on one clip |
| Content packs (`contentPacks.ts`) | catalog JSON | Looks, captions and transition presets (kind + length) | No effect kind, no multi-item preset |

### What the edit model can already do (shared `model.ts`; Kotlin and Swift ports)
- **Effects (one per item):** `glitch, vhs, film, blur, zoomBlur, mirror, pixelate, posterize, duotone, shake, flash, rain`.
- **18 transitions:** `fade, black, white, slide×4, zoom, zoomOut, whip, whipRight, spin, glitch, cover×4, splitFade`.
  - Each is just a kind and a length (0.1–2 s).
  - There is no mask or luma wipe.
- **Keyframes:**
  - Transform, opacity, volume.
  - Colour: exposure, contrast, saturation, temperature, tint.
  - Mask box.
  - Look: vignette, grain, leak.
  - Not keyframeable: effect amount, blur, chroma.
- **8 blends** on all renderers. Difference and exclusion are gated off; the apps don't have them.
- **Masks:** linear, mirror, circle, rect, heart, star, with feather and invert, and they can be keyframed.
- **Other:** chroma key, alphaMatte, layers and `text_behind`, freeze (`holdSec`), speed curves, adjustment layers
  (colour only), video and image overlay tracks.
- **Audio:**
  - Volume keyframes and ducking.
  - **No keyframeable filter.** Low-pass exists only inside the fixed radio and phone voice presets.
- **Where it renders:** Mac (Core Image kernels) and Android (one GLSL effect shader) draw all 12 effects.
  **The server ffmpeg render draws no `effect` at all, and drops it silently** (`test/render-coverage.test.ts` lists it
  as "the render follows (WS16)").
- **New values break old apps.** Kotlin and Swift decode effect ids, transition kinds and blends as closed enums, so an
  unknown value makes an older app refuse the whole project. That is why new values ship behind server gates.

## 1. Intake (built: branch `claude/template-pack-intake`)
New owner-only tools in one file, `src/editor/templatePacks.ts`. They are in the chat registry with `members: false`,
so they are also on MCP. They are free and render nothing.

| Tool | What it does |
|---|---|
| `gaps_list {kind?, query?, limit?}` | Every gap, most requested first, with all its examples. `query` matches key, what and notes. |
| `template_pack_send {pack, manifest?, files?, removeFiles?, media?}` | Stores the pack in parts that merge under the pack name. **Manifest:** templates.json, up to 256 KB. **Files:** `[{path, text}]` for the README, scripts and notes; text only; up to 40 per call, 300 per pack, 3 M characters. **Media:** `[{templateId, uploadId, role: preview\|final\|source\|overlay}]` for clips sent first with the existing `upload_local_file`; they must be finished uploads of this studio. Credential-looking values are replaced with `[redacted]`. Binary text and `..` paths are refused. The answer lists templates still missing a preview. |
| `template_pack_read {pack?, path?}` | Every pack's summary; or one pack's manifest, file list and media; or one file's text. |

- **Storage:** table `edit_template_packs`, migration `0037_template_packs.sql`. It is additive and uses `IF NOT EXISTS`.
- **Naming:** the tool is "send", not "submit": the MCP test bans names matching `generate|submit|run_job` (nothing that spends).
- **Tests:** `test/template-packs.test.ts` covers owner-only access, merging, previews, redaction, refusals, gaps_list
  past 5, and that the tools are on MCP.
- **After deploy, the owner says to MUSE Claude on the Mac:**
  > "Send the Icon storyboard template pack to the MUSE team with template_pack_send: the manifest, README and
  > scripts as files, then each preview and final with upload_local_file and add them as media."

  Then the coordinator reads it with `template_pack_read` and `gaps_list`. **The table in §4 is provisional until then.**

## 2. How a template is represented
A template is **one JSON spec** (`EditTemplate v1`) that the **server expands into ordinary edit ops** for a target:
a clip, a cut, or every beat cut.

### Why expand on the server
- The apps only ever receive normal project items, so a template needs **no new model code in Kotlin or Swift** unless
  it uses a new primitive.
- Undo is one history entry ("Applied Soft RGB glitch").
- Claude and both apps share one implementation.

There are three tiers, and the spec says which one it is.

| Tier | Template holds | Fits any clip and length? | App work |
|---|---|---|---|
| **1 Live** | Changes to the target (effect, look, adjust, filter, blend, mask, transform) plus keyframes in **normalised time** (0–1 of the target, or seconds from an anchor), plus added items (overlay copies of the next or previous clip with masks, a sound, text, a freeze), plus a transition | Yes. Times scale to the clip, settings come from sliders | None beyond the library UI |
| **2 Live + new primitive** | The same, but it uses a value the model lacks (an `invert` effect, a `stripes` mask shape, an audio low-pass keyframe…) | Yes | The primitive goes into model.ts, the fixtures, Kotlin, Swift, both shaders and ffmpeg, behind a gate. Older apps show "Needs update" |
| **3 Finished clip** | One or more media assets (uploads) plus placement: anchor (cut, in, out), offset, blend, fit, length fixed or stretched | Placement yes; the look is fixed (made at 16:9 1080p, fit or crop to the canvas) | None |

Tier 3 is how all 27 exist today. Each template can be promoted later, from tier 3 to tier 1 or 2, by saving a new
version under the same id.

### Spec sketch
Server type in `src/editor/templates.ts`; this is not an app contract.

```jsonc
{ "v": 1, "id": "soft-rgb-glitch", "name": "Soft RGB glitch", "kind": "effect", // effect | transition | text | sound
  "target": "clip",                     // clip | cut | edit
  "tier": 1, "requires": [],            // e.g. ["effect:invert"]: hidden or marked "Needs update" for apps without it
  "length": { "mode": "fixed", "sec": 0.3, "anchor": "in" },   // fit | fixed | stretch; anchor in | out | cut
  "params": [ { "key": "strength", "label": "Strength", "type": "number", "min": 0, "max": 1, "default": 0.3 },
              { "key": "sound", "label": "Add the glitch sound", "type": "bool", "default": true } ],
  "self": { "effect": { "id": "glitch", "amount": "$strength", "speed": 1.5 },
            "keyframes": { "scale": [ { "t": 0, "v": 1.08 }, { "t": 1, "v": 1, "ease": "easeOut" } ] } },
  "add": [ { "when": "$sound", "track": "sfx", "asset": { "upload": "up_d7376fe4514c" }, "at": { "anchor": "in" } } ],
  "preview": { "uploadId": "up_…", "poster": "up_…" },
  "source": { "pack": "icon-storyboard", "templateId": "glitch-soft", "by": "claude" } }
```

- **Clip copies.** `add` items can name the target's neighbours (`"asset": "$next"`, `"in": "$next.in - 0.3"`). This
  covers the playbook rule: a window, strip or panel previews the shot it opens into, in place and unscaled.
- **Time.** Keyframe `t` is normalised unless `"unit": "sec"`.
- **Storage.** Table `edit_templates`: id, studio, name, kind, target, tier, spec jsonb, preview upload, source, by,
  timestamps. Limit 500 per studio.
- **Media.** Assets inside a template are uploads. Applying one adds `{kind: video|audio, upload}` to the project's assets.

## 3. Tools for Claude, routes for the apps
Tool names avoid `templates_*`, which means photo presets. Each description says "Edit effects and transitions; for
photo presets use templates_manage" so Claude stops picking the wrong one, which is the confusion in ci_d4cc38758998.

| Tool | Does |
|---|---|
| `edit_templates {query?, kind?, target?}` | Lists the library, with tier, params, "needs update" and preview URLs. |
| `edit_template_save {name, kind, target, from?: {sessionId, itemIds, cutAt?}, spec?, previewUpload?}` | Saves from a selection or from a spec. From a selection, it takes the target's effect, look, adjust, blend, mask and keyframes (normalised) and the overlapping overlay and sfx items (as uploads, or as `$next`/`$prev` copies when they reuse a neighbour). It returns the spec, so Claude can add params. Saving the same name makes a new version. |
| `edit_template_apply {sessionId, templateId, target: {itemId} \| {cutAfter} \| {each: "beat-cut" \| "cut" \| "clip"}, params?, dryRun?}` | Expands to ops and applies them as one undoable change. With `dryRun` it returns the ops and a preview project patch without saving. |
| `edit_template_delete {templateId}` | Removes a template. Projects keep their items. |

- **Routes:** `GET/POST /v1/editor/templates`, `POST /v1/editor/templates/:id/apply` (`dryRun` for preview), and
  `DELETE /v1/editor/templates/:id`.
- **Who:** owner tools (Edit is the owner's). Members can list and apply only if the owner turns that on later.
- **Seeding:** once the pack is in, Claude converts each template with `template_pack_read` then `edit_template_save`.
  - It starts as tier 3 with the pack's final clip, then a tier 1 spec wherever §4 says one is possible now.
  - The owner checks each in the app. This costs Claude tokens, nothing else.

## 4. The 27 (provisional: matched from the Icon edit's assets and the visible gaps; confirm against templates.json)
Tier 1 = possible now with expansion, tier 2 = needs the primitive named, tier 3 = finished clip only.

| # | Template (asset in the Icon edit) | Today | Plan | Needs |
|---|---|---|---|---|
| 1 | Soft RGB glitch + sound (`glitchv4`, `glitchsfx1`) | baked | **1** | effect `glitch` at 0.3, sfx item |
| 2 | White flash (`fxwhite`, add blend) | baked | **1** | transition `white` 0.1 s, or an exposure keyframe |
| 3 | Negative hit (`fxneg06`) | baked | 2 | effect `invert` |
| 4 | Beat punch-in (scale 1.35 → 1, 0.27 s) | live | **1** | keyframes, already used |
| 5 | Cut-out hit (`cut6`) | baked | 3, then 1 | subject matte; free Mac lift (gap `local-subject-matte`) |
| 6 | Strip into next shot (`strip227/377`) | baked | **1** | `$next` overlay copy + rect mask |
| 7 | Band preview (`band247`) | baked | **1** | same as 6 |
| 8 | Window into next shot (`window457`) | baked | **1** | same as 6 |
| 9 | Panels (`panels250`) | baked | **1** | 3 overlay copies with rect masks |
| 10 | Split on the beat (`split287/441/460/470`) | baked | **1** | overlay copies, rect masks, transform |
| 11 | Eye reveal (`eye309/587`) | baked | 1 if a circle or ellipse | keyframed circle mask; confirm the shape |
| 12 | Boom (`boom361`) | baked | 1, provisional | zoomBlur + shake + scale keyframes; confirm |
| 13 | Drop hit (`drop417`) | baked | 1, provisional | flash + scale; confirm |
| 14 | Page turn (`page340/521`) | baked | 3 | a page curl needs a mesh warp (not planned) |
| 15 | Freeze cut-out (`frz08` + alphaMatte `bg19`) | baked | 3, then 1 | freeze + matte (same gap as 5) |
| 16 | Stripes wipe (`stripes497`) | baked | 2 | mask shape `stripes` (count, angle, progress) |
| 17 | Glass panel (`glass521`) | baked | 1, approximate | overlay copy with blur effect + rect mask + exposure |
| 18 | Shatter (`shatter561`) | baked | 3 | needs a shard mesh |
| 19 | Album covers (`covers561`, 3×) | baked | **1** | freeze-frame overlay items + rotation keyframes + pop |
| 20 | White-out (`white587`) | baked | **1** | transition `white` / exposure keyframes |
| 21 | Quiet beat (`quiet589`) | baked | 1, provisional | saturation + vignette keyframes; confirm |
| 22 | Big type (`big607`) | baked | 1, provisional | text item + pop and zoom anim; confirm the font |
| 23 | Corner signature, auto-hide (`sigA`) | baked | **1** | image item (the mark) on chosen ranges |
| 24 | Storm end card, write-on (`endcard2a/2b`) | baked | 3, then 2 | text `writeOn` anim (stroke reveal); gap `write-on-signature-end-card` |
| 25 | Glass, frost and glitch lyrics (`words*`) | baked per song | 3 per song; the style becomes 2 | caption style `glass`; word times (gap `voice-onsets`) |
| 26 | Title behind subject (`words269`) | baked | **1** (paid matte) | existing `text_behind`; free with the Mac matte |
| 27 | Contained sound ending (low-pass 1500 → 240 Hz, 3.6 s sink) | ffmpeg | 2 | audio `lowpass` keyframes in all three renderers |

The count: 15 can be live now (tier 1, 5 of them provisional), 5 need a new primitive, and 7 stay finished clips at
first. **Every one can be in the library on day one as tier 3**, because each has a final clip.

## 5. The Edit UI (mockups 1–4)

### Mac
- **Where it opens.** "Templates" in Edit's left rail opens the library panel.
- **Panel contents:**
  - Search and filters: All, Transitions, Effects, Text. Sound templates show under Effects.
  - A "Made by Claude" group, plus "Yours" for ones the owner saved.
  - 16:10 tiles with name and length.
- **Selecting a tile:**
  - Hovering a tile plays its muted preview.
  - Selecting one plays a **preview on the real selection** in the viewer ("Preview, not applied yet"). This uses
    `dryRun` ops on an in-memory copy, so nothing is saved.
  - The inspector shows the name, where it came from, an "Applies to" row (clip or cut, with Change), its settings
    (sliders and toggles from `params`), and what kind it is ("Live effect…" or "Finished overlay clip…").
  - The one primary button names the target: "Apply to clip 12" or "Apply to cut at 0:18.0". The secondary is
    "Apply on every beat cut".
- **Picking a target.** Transitions aim at a cut. Clicking a cut on the timeline selects it, and the accent box marks it.
- **Saving.** "Save as template" sits in the timeline toolbar. It opens a sheet: name, what to keep (checkboxes built
  from the selection), and Applies to (a clip, a cut, the whole edit).
- **Older app.** Tiles a build can't play are marked "Needs update", and the inspector explains why.

### Android
- The same library as a bottom sheet over Edit: filters, a 3-column grid.
- Tapping a tile previews it in the viewer and opens its settings with a full-width "Apply to clip 3".
- Saving is from the clip's long-press menu.

### Copy and states (mockup 4)
- **Loading:** skeleton tiles.
- **Empty:** what a template is, plus one action, "Save clip 12 as template".
- **Offline:** "Templates didn't load", with Try again; templates used on this device still work.
- **Older app:** "Needs the next MUSE update".
- **Claude's card:** "I saved … as a template", with "Open in Templates" and "Undo".

### Design review against muse-design-review
- One action fill per screen.
- Accent is used only for the selection: the tile outline and the cut box.
- No icons on rows, one Phosphor family, sentence case.
- Prices are not involved (templates are free; a template that uses `text_behind` shows its matte price on its Apply
  button: "Apply · $0.82").
- Known flaws to fix in the build:
  - The viewer's preview badge should be quieter.
  - The page-turn tile art is a placeholder for the real preview clip.
  - The Android sheet hides the timeline. It should stop at half height so the selected clip stays visible.

## 6. Phases
- **P0 (built, waiting to deploy).** Intake (§1), then the owner asks MUSE Claude to send the pack. The coordinator
  replaces §4 with the real list.
- **P1 server.**
  - `edit_templates` table (migration 0038).
  - Spec validation and expansion to ops (`src/editor/templates.ts`, pure and unit-tested against the fixtures).
  - The 4 tools and the routes, `dryRun`, and the "needs update" check from `requires` against the app build the
    request sends.
  - Seed the 27 as tier 3, with tier 1 specs where §4 allows.
  - **Also fix the server render dropping `effect`.** Otherwise a server export of a templated edit loses its effects.
    If the apps export locally, this only affects server renders, but it still has to be fixed before tier 1 ships.
- **P2 apps (one Mac bundle, one Android bundle).**
  - The Templates panel or sheet, hover and tap previews, preview-before-apply (apply the `dryRun` patch to the local
    copy), Apply, Save as template, and the states.
  - There are no model changes, so no contract change.
- **P3 primitives, one at a time, in order of gap count.**
  - `invert` effect, `stripes` mask shape, audio `lowpass` keyframes, the `glass` caption style, `writeOn` text anim.
  - Each one touches model.ts + fixtures + Kotlin + Swift + GLSL + Core Image + ffmpeg + a gate, and merges only after
    the Mac CI is green.
  - The matching templates then move from tier 3 to tier 2.
- **P4.** Free on-device subject matte (Mac Vision, Android ML Kit) turns templates 5, 15 and 26 into free tier 1.
  That is a separate plan.

## 7. Risks
- **Old apps refuse unknown enum values.** Tier 2 has to be gated. The server never puts a primitive into a project
  unless every app the studio uses can read it (same pattern as `BLEND_NEXT_LIVE`).
- **Tier 3 looks fixed.**
  - The clips are 16:9 1080p. On 9:16 they are cropped (fit rules in the spec), and lengths can't stretch without
    looking wrong. The UI says so.
  - The library is the first step, not the end state.
- **Server render gap on `effect`.** See P1.
- **Name confusion with photo `templates_*`.** Handled with distinct names and descriptions, and the sidebar
  "Templates" (photo) stays separate. See question 1.
- **Pack content.**
  - Scripts are stored as text with credentials redacted. They are never run on the server.
  - The pack's Python and headless-Chrome scripts are the team's reference for building the primitives, not runtime code.
- **Storage.** Previews and finals are uploads (R2), not Railway disk. The 512 MB RAM is not touched: no rendering at
  apply time.
- **Expansion edge cases.**
  - Clips shorter than a fixed-length template: refused, with "Clip 3 is 0.2 s; this needs 0.3 s".
  - Cuts that already have a transition: it is replaced, and Undo brings it back.
  - A missing `$next`, at the last clip: refused with a clear error.

## 8. Questions for the owner
1. Edit's left rail already has a "Templates" item (Mac `EditSuiteBin.swift:319`; today it holds caption styles). Should the new
   library **replace it**, with kits as a filter? (Recommended: yes, one place.) Or should it sit beside it as
   "Effects"?
2. Should finished-clip (tier 3) templates show in the library from day one? They fit placement but not the look of
   every clip. (Recommended: yes, marked "Finished clip".)
3. Should members see and apply templates, or only the owner? (Recommended: owner only for now, like the rest of Edit
   with Claude.)
