# Outfits: matching body angles, Head looks, accessories (owner, decided 2026-11-11)

## 1. Matching body angle per outfit picture (server-only fix, approved)
Today outfit generation sends the same identity photos (faces + ONE body photo, the front) to all four pictures.
Fix: each outfit picture gets the face angles plus the body photo of ITS angle: front→front, ¾→tq, side→side,
back→back (character sheet slots: face, faceTq, profile, front, tq, side, back). Confirm what goes out today first
(routes/index.ts POST /v1/outfits, identityRefs; the built-in model path makes a front shot then edits it, custom
models make four new shots at once). A missing slot falls back to the front body photo.

## 2. Head looks (new feature: design, then build)
- A Head look = her head with a hairstyle/headpiece, makeup and face accessories (glasses, earrings, piercings):
  FOUR pictures: face front, face ¾, face side, back of head.
- Own inventory on the character (not scattered among outfits). Reusable across outfits.
- Creating an outfit: choose her default head, one from the inventory, or generate a new one to match the outfit.
- Order: the head look is made FIRST, then the outfit uses its faces (never both at once: hair drifts between angles).
  Dress up (services/tools.ts) already makes outfit faces; reuse that machinery.
- A complete look = one Head look + one Outfit, saved as a pair.

## 3. Accessories (no third free-layering inventory: rejected, drift + photo limit)
- Face/head accessories and makeup are baked into the Head look; body accessories (shoes, bags, belts, necklaces,
  bracelets) into the Outfit.
- Input: product PHOTOS mostly (owner), description stays optional as today.
- Her "never add" list (e.g. no jewellery) must be overridden per look for the items that look carries.
- Photo budget for video models (H3: 9): 4 head pictures + 4 outfit angles = 8.

## Touches
Server (model, generation, swap/shot references use the look's head pictures), both apps (inventory, picker in the
outfit flow), shared contracts, a migration (next free: 0029). Needs designs for the owner before building.

## 4. Outfit section layout: folders, paging, full width (owner, 2026-11-11; approved, Mac and Android)
Owner: "The outfit section is getting too clustered … outfit sessions should be single folders, each holding the front
view only. You have to open any of the folders to see their full view … the right hand side is mostly empty … add a cap
to how many can stay on the section. Add the navigation like < X of X >." (Screenshot: Mac character page, outfits in
two columns of four-angle rows, five of them named "Product look".)
- Each outfit is ONE folder tile: its front picture, its name, and its date (so same-named outfits can be told apart).
  No ¾/side/back on the page.
- Clicking (Mac) / tapping (Android) a folder opens the outfit: all four angles large, plus its actions (rename, use,
  Dress up, Delete). Close returns to the same page of folders.
- Viewer (owner, 2026-11-11: "click an outfit to view … slide to the next image"): clicking any angle opens it full
  size; slide to the next/previous angle (swipe on Android and Mac trackpad, ‹ › buttons and ←/→ keys on the Mac),
  with "Front · 1 of 4" shown. Reuse the Mac ImageLightbox (it already has arrows) and Android's image viewer.
- Delete (owner, 2026-11-11; NEW: no delete exists today, server or apps): Delete in the open outfit and on the
  folder's menu (right-click on the Mac, long-press on Android) asks first: "Delete this outfit? Takes and photos already
  made with it are kept." Server: DELETE /v1/outfits/:id (owner and the outfit's maker; studio-scoped; 404 for another
  studio's), removes the outfit from drafts/templates that point at it (they fall back to no outfit) and keeps takes.
  A deleted outfit's generating job: refuse with "still being made" until it finishes. The page refills from the next
  page; if the last page empties, step back one page. Server test for the route (permissions, studio scope).
- 8 folders per page on the Mac (two rows of four). The grid fills the page's full width (tiles grow with the window;
  no empty right-hand side). Android: the same, fewer per row on a phone (2 per row, 8 per page).
- Pager under the grid: "‹  1 of 3  ›". Arrows disabled at the ends; hidden when there is only one page. Newest first;
  a new outfit appears on page 1. Keyboard ←/→ on the Mac only when no text box has the cursor (see EditShortcuts).
- The cap is per page (8); outfits are not deleted or limited in number.
- Unfinished outfits: a folder whose front is still generating shows the progress; a set with missing angles (the
  screenshot's second "Product look" has two empty angles) shows a small "2 of 4 angles" note inside the folder, with
  a way to make the missing ones. Find out why that set has two empty angles (failed edits, not refunded?) before
  building that part.
- Owner's testing rule: the layout is checked by the owner by hand; automated tests only for the paging logic.

## 5. Naming and renaming outfits (owner, 2026-11-11; approved, Mac and Android)
Owner: "make sure outfits can be named before adding after creating. And can be renamed anytime. So we don't always end
up with the generic Product Look."
Today: no rename exists (no server route); POST /v1/outfits/:id/save takes no name; the Mac names an unnamed product-photo
outfit "Product look" and an own set "My set" (AppStore+Actions.swift ~567); check Android for the same.
- Server: PATCH /v1/outfits/:id { name } (1–80 chars, trimmed; owner or the outfit's maker; studio-scoped), and
  POST /v1/outfits/:id/save accepts an optional { name }. Emits the outfit event so both apps update live.
- Before adding (the preview step after the four pictures are made): a name field above "Add to her outfits", filled
  with a suggestion the person can change. The suggestion: what they typed (describe mode), else the product photo's
  file name, else "Outfit · 11 Nov". Never "Product look" / "My set" again.
- Rename anytime: in the open outfit (click the name to edit, Enter saves) and on the folder's menu (right-click on the
  Mac, long-press on Android) next to Delete.
- Same-named outfits are allowed but the folder always shows the date under the name (section 4).
- Optional, ASK the owner first (small spend per outfit): Claude suggests the name from the outfit's front picture
  (e.g. "Green halter mini skirt set"), using the vision helpers in server/api/src/suite/vision.ts.
- Server test for the rename route (permissions, studio scope, length); the rest the owner checks by hand.
- Build together with section 4 (same screens).

## 6. Outfit from her base photos, keeping chosen pieces (owner, 2026-11-11; approved)
Owner: "Allow me to control what base image I send … my model base is an underwear. I want her wearing a skirt with the
bra of that underwear … it won't overwrite the bra because of the skirt, right?" Today it can: base photos are identity
refs only; "Wearing:" is the whole outfit; the body-angle line says "not its clothes".
Decided: base = her base photos, chosen explicitly; "Keep from base" tick boxes Top · Bottom · Shoes · Accessories +
a note. Kept pieces → the front is an EDIT of her base front photo (keep X exactly, replace only the rest); ¾/side/back
are edits of that front + her base photo of the same angle. Nothing kept → as today. Built by the outfit-page session.
- Follow-up (owner, build 538): the base can't be seen or chosen. Decided: SEE + SWAP PER ANGLE; she has several base
  looks → "Start from": her profile photos or any of her outfits (an outfit is a base set); 4 base thumbnails, click
  one to swap that angle (her body shots, an outfit angle, an upload). Server base {source:'base'|'outfit', outfitId?,
  angles?}. Outfit-page session.

## 7. Outfits carry their own face close-ups; Dress up removed (owner, 2026-11-11; built on claude/outfit-faces)
Every outfit = 4 body angles + 3 face close-ups with its own hair, make-up and face accessories, made from her base face
photos and the outfit's front. Shots with an outfit send only the outfit's images. Dress up is removed. Spec, prices and
app design: `plans/outfit-faces.md`. (Whether §2 Head looks is still wanted on top of this is the owner's call.)

## §7 Partial results (owner 2026-11-12, branch claude/outfit-partial)
When making a set fails partway, the pictures already made are kept:
- New outfit (describe / product photo / Keep from base), My own set faces, Add face close-ups, Fill, and Redo all work this way. The outfit is saved with the missing pictures empty. The member pays only for what was made: each picture's cost is added on success, and the rest of the hold goes back. A picture the provider billed but that wasn't kept goes on studio overhead.
- If the front angle fails while making a new set, nothing can be built from it. The whole set fails and is refunded, as before.
- The outfit view gains `partial: { made, of: 7, missing: [front|tq|side|back|face|faceTq|profile], label: "N of 7 made · Redo the missing ones" }`. Each missing picture has POST /v1/outfits/:id/redo {angle}, priced with `dryRun: true`.
- Shots with a partial outfit send only the pictures that exist. The first outfit picture's sent-images "why" names what's missing.
- Character sheet fill (/v1/models/:id/fill-angles) already kept partial results (one try per angle). The LoRA training set now keeps the candidates made; training still needs LORA_MIN_KEEP.
- Unchanged on purpose: Enhance (a realism then upscale chain of one image, where a half result isn't useful) and the other single-image tools. Their failures are refunded, and the spend goes on overhead.
