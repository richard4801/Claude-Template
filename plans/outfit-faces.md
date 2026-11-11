# Outfits with their own face close-ups (owner, 2026-11-11)

Owner: "Outfits coming with face close-ups closes the gap… When we click on the outfits, the outfits come with full body
views and face close-up. This means the base face close-up or body isn't sent. Just the dressed version with its own face
close-up. This fixes the hair issue. Every outfit would come with its own hair, facial accessories and make-up. The dress
up feature is not needed at this point. It's redundant."

## Decided
- Every outfit = 7 pictures: Front, ¾, Side, Back (body) + Face front, Face ¾, Face side (close-ups with the outfit's
  hair, make-up and face accessories). Made ALWAYS, by every way of making an outfit (no tick box).
- The face close-ups are made from HER base face photos (one per angle; a missing ¾/side uses her face front) plus the
  outfit's front, so the likeness stays hers. Base images are used when MAKING the outfit, never when shooting with it.
- Shooting with an outfit (Photo, Video Suite, Recast/Swap fills, Claude) sends ONLY the outfit's images: its face
  close-ups and body angles. No outfit picked: nothing changes.
- My own set: no face upload boxes (owner said no). After upload MUSE makes the 3 face close-ups from the uploaded front
  plus her base face. Paid, price shown.
- Older outfits without faces: "Add face close-ups" (paid, price shown). Until then shots with that outfit send her base
  face front only, plus the outfit angles; the images-sent list says so.
- Per-picture Redo covers all 7.
- Dress up is removed (server, Claude, both apps, docs). Its outfits keep working (they already have faces).

## Price (tested defaults: one edit = $0.03)
| | Before | Now |
|---|---|---|
| New outfit (describe / product photo) | about $0.16 (1 new shot + 3 edits) | about $0.25 (+ 3 face edits = +$0.09) |
| Keep from base | 4 edits = $0.12 | 7 edits = $0.21 |
| My own set | free | 3 face edits = $0.09 |
| Add face close-ups (older outfit) | n/a | $0.09 |
| Redo one picture | n/a | one edit ($0.03); the front is a new shot (~$0.07) |
On a custom (provider) model each face is a new shot at that model's per-run price.

## Server (done on claude/outfit-faces)
- `POST /v1/outfits` makes `faces` after the 4 angles; `dryRun` → `{cost, bodyCost, faceCost, faces: 3, images}`.
- `POST /v1/outfits/:id/faces` (Add face close-ups) and `POST /v1/outfits/:id/redo {angle}` (front | tq | side | back |
  face | faceTq | profile), both with `dryRun` for the price; `/fill` unchanged for the apps.
- `features.photo.estimates.outfitSet` now includes the 3 faces; new `estimates.outfitFaces` (the 3 alone).
- New owner-editable prompt `outfit.face` (Settings → Prompts → Outfits → Face close-ups).
- References: images/identity.ts `outfitRefs` (Photo), services/jobs.ts `referencesFor` / `replicateReferencesFor`
  (Swap, Suite shots, Recast, the shot-fit plan). Order: face front, outfit front, face ¾, face profile, outfit ¾,
  side, back (cut from the end to the model's limit; GPU 6, hosted 9). The images-sent list's "why" names the outfit's
  face ("the outfit's face, front (its hair, make-up and accessories)") or, for an older outfit, "her base face, front ·
  this outfit has no face close-ups yet (Add face close-ups)".
- Dress up: routes answer 410 `dress_up_removed`; ToolService, Claude's `character_dress_up`, the `dress_up`
  images-sent page and the Dress up prompt group are gone. Claude gains `outfit_add_faces` and `outfit_redo`.

## Design (apps) — follows plans/design-direction.md and the muse-design-review skill
Open outfit (Mac floating panel 880 pt; Android full screen):
```
 Linen shirt                                       ×
 For Mia, made 11 Nov
 ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
 │Front │ │  ¾   │ │ Side │ │ Back │      body angles, as today
 └──────┘ └──────┘ └──────┘ └──────┘
 Front     ¾        Side     Back
 ┌──────┐ ┌──────┐ ┌──────┐
 │ face │ │ face │ │ face │               face close-ups, same column width, under the first three
 └──────┘ └──────┘ └──────┘
 Face front Face ¾  Face side
 Delete…                                     Use in Photo
```
- No section headers or boxes; the second row is grouped by space and its caption labels ("Face front …").
- Hover (Mac) on any of the 7 pictures shows one small icon button "Redo" (arrow.clockwise, tooltip "Redo · $0.03").
  Android: the full-size viewer's top bar has "Redo · $0.03" for the picture shown. Owner or the outfit's maker only.
  A picture being redone shows the skeleton in place.
- Viewer: the pager covers the 7 pictures in that order: "Face side · 7 of 7". Missing ones are skipped.
- Older outfit (no faces): the face row shows three empty tiles and one notice under it:
  "No face close-ups yet. Shots with this outfit use her base face." [Add face close-ups · $0.09]
- While the faces are being made: skeleton tiles in the face row.
- Folder tiles: unchanged (front only). "Making angles" also shows while faces are made.
- New outfit sheet: the Generate button carries the full price ("Make 7 pictures · $0.25"); My own set:
  "Use my images · $0.09" with the caption "MUSE makes her 3 face close-ups from your front". No face upload boxes.
- The preview step after generating shows the 7 pictures the same way (4 + 3).
- Dress up: its button on the open outfit, the profile entry and the Settings → Engines "Dress up · Option A/B" rows are
  removed in both apps.
