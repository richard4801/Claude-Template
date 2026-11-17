# Her world: places, people and pets on the character page

_Plan with mockups only. Nothing is built until the owner approves the mockups in `plans/design/model-world/`. Written 2026-11-16._

## What the owner gets
Her page stops being a long list. It becomes her small world, split into five tabs: **Profile · Wardrobe · Places · People · Pets**. Each tab can stay empty until the owner wants it.

- **Places.** Her apartment, bedroom, gym, the café near the gym. Each place is a few photos. The owner can upload them, or generate them at random, from a description, or from a reference picture. A place has no required angles. Type `@cafe` in any prompt and that place's photo goes to the model as the background, so the café looks the same in every video.
- **People.** Her sister, brother or best friend. Each is a lighter character: about 3 photos and their own outfits, made with the same outfit tools as hers. Type `@mara` to put her sister in a Shot or Photo. In a two-person Swap, pick who in the clip becomes whom.
- **Pets.** A few photos and an @tag.

Every photo the app generates shows its price first and is made only after Approve.

## Mockups (Editorial light, Mac 1440×900 and Android phone)
| File | What it shows |
|---|---|
| `1-mac-her-page-profile.png` | Header (her photo, name, look) and the five tabs. The Profile tab holds her photos and her world in three rows. |
| `2-mac-places.png` | Grid of place folders, with Café by the gym open: photos, the `@cafe` tag, and the Add photo menu (Upload · random · from a description · from a reference), each with its price. |
| `3-mac-people.png` | People list and Mara's card: her base photos and a small wardrobe. |
| `4-mac-composer-mentions.png` | Typing `@` lists Her, Places, People and Pets. The chips sit in the prompt. "Images sent" shows people first, then the place, with "6 of 9". |
| `5-mac-two-person-swap.png` | Swap with two people found in the clip: 1 becomes Zelphira, 2 becomes Mara, each with an outfit. Both are swapped in one pass. |
| `6-mac-empty-states.png` | The empty Places, People and Pets tabs. |
| `7-android-places.png`, `8-android-add-photo.png` | Places tab on a phone, and the Add photo sheet. |

To rebuild them: `node plans/design/model-world/src/build.mjs`. The photos are stand-ins, cropped from the approved Suite stills and the Blender preview stills. Image generation was not available for the mockups (quota), so Mara is a mannequin. The app will show real photos. Four Phosphor icons are new (`at`, `paw-print`, `users`, `folder-simple`) and must be added to `design/icons/icons.txt`.

## What exists today (checked in the code)
- **Her page.**
  - Mac: `ProfileView` (mac/Muse/Views/ModelViews.swift:105). It is one scroll: the cover, Shot and Photo buttons, niche and notes, then the sheet, LoRA, Accounts, Outfits and Never add.
  - Android: `ProfileScreen.kt:101`, which shows the cover, the outfit strip, then LoRA and Accounts.
  - The tabs only regroup what is already there: Profile gets the sheet, about, LoRA and accounts; Wardrobe gets the existing outfit folders.
- **Data.**
  - `models` (db/schema.ts:118) has slots, look and neverAdd. `outfits` (:142) has angles and 3 faces.
  - The latest migration is `0039_pipeline_skill.sql`, so the next is **0040**.
- **Places already half-exist.**
  - `suite_locations` (suite/schema.ts:22, `suite/locations.ts`) is **studio-wide, one image per place**, up to 200.
  - The composer already has `@location`. Shot sends it as `references.images[] {role:"location"}` and words it "<Image N> is the location (Café): use only its place, layout and light." (plan.ts:452, prompts.ts `suite.shot.reference`).
  - **Gap:** Photo sends only the place's *name*, not its picture (SuitePhoto.swift:275). The scene wording `refs.scene` ("Use the place and background from image N.") already exists for Photo.
- **Mentions.**
  - The kinds are `character`, `outfit` and `location` (Composer.swift:283; Android PromptTokens.kt:85).
  - **Only one character per prompt**: a second one replaces the first, and Claude's drafts refuse it.
- **Two-person Swap already exists as Recast.**
  - `suite/recast.ts` replaces up to 4 people. Each one has `personHint` (left/right…), a face crop and their own outfit.
  - The Mac already has `RecastCastList` ("Who becomes whom") and `RecastFacePicker`.
  - Its "Becomes" menu lists only full characters.
- **Members.**
  - Every member sees every model in the studio.
  - Archive is owner only.
  - Delete is allowed for the owner or the person who created it (`ownerOrCreator`, errors.ts:9).
- **Claude.**
  - `character_create/update`, `outfit_*` and `suite_rigs` (list_locations) are in appTools.ts.
  - Actions that need approval are in actions.ts.
  - `suite_set_draft` takes mentions.

## Decisions
### 1. A place is the existing location, extended (not a new system)
- Migration 0040 on `suite_locations`. Add these columns:
  - `model_id` (null = studio-wide, as today)
  - `tag` (unique per model, e.g. `cafe`)
  - `description`
  - `images jsonb[]` (up to 8, each with `source: upload|random|description|reference`)
  - `cover`
- The old `image` becomes `images[0]`, so nothing breaks.
- `@` lists her places first, then the studio's.
- **How a place is sent:**
  - One photo per place: the cover, or the one picked under "Images sent". It goes as the scene reference, with today's wording ("<Image N> is the location (Café by the gym): use only its place, layout and light."). Photo uses `refs.scene`.
  - The order inside each model's image budget stays identity first: her photos → her outfit → each person's photos → the place → other references.
  - When the budget is full, the place gives way first. It is then sent **in words** from its description ("Setting: corner café with a striped awning, wet cobbles, warm window light."), and the composer says so.
  - Models with no image input (Veo 3.1 Lite, LTX-2.3, Kling 3.0 · Higgsfield) always get the words.
- **Budget example.** MiniMax H3 takes 9 images: her 3 + outfit 1 + Mara 2 + café 1 = 7, so it fits. Kling O1 takes 4 in total, so with two people the café goes to words.
- **Watch the price.** MiniMax H3 · Higgsfield includes 5 images, and each extra image costs **$0.08 per take** (registry `includedImages`/`extraImageUsd`). Adding a place or a person can raise the price. The estimate on Generate already counts it and must show it.

### 2. People and pets reuse the character model, with a `kind`
Recommendation: **reuse `models`. Don't build a new "person" table.**
- **Why.**
  - Recast, outfits, sheet slots, `personImages()` image picking, never-add, permissions and Claude's tools all work on `models`.
  - A new table would mean a second outfit system and a second cast path.
- **Migration 0040 adds:**
  - `kind` (`model` | `person` | `pet`, default `model`)
  - `parent_model_id` (the character whose world they belong to)
  - `relation` ("sister", "best friend")
  - `tag`
- **"Lighter" means:**
  - 3 photos are enough: face, waist up and full body. 7 are allowed.
  - No LoRA and no accounts.
  - They don't appear in the Models list or on Home.
  - They do appear on her page, in `@`, and in the Recast "Becomes" menu.
- **Pets** use `kind: pet`: photos and a tag, no wardrobe, no never-add. They are worded as "her dog <Image N>" and never take a person's slot in Recast.
- **Permissions follow her:**
  - Like her, every member of the studio can see them.
  - Anyone in the studio can add.
  - The owner or the creator deletes.
  - Archiving her archives her people, pets and places with her.

### 3. Prompts with more than one person
- The composer's "one character" rule becomes **her plus up to 2 people (plus a pet)**. The cap is open question 4.
- The request gains `cast: [{modelId, outfitId}]`. The existing `modelId`/`outfitId` stay for the lead.
- A new owner-editable block `suite.shot.person` ("{name}, her {relation}, is the person shown in {refs}…") is added. The existing `suite.shot.lock` line ("never swap appearances, clothing or positions") then covers both people.
- Claude's drafts accept the same.

### 4. The two-person Swap: what is possible (web-checked 2026-11-16)
| Model in MUSE | Two people in one pass? | How | Source |
|---|---|---|---|
| **MiniMax H3 Max Recast · fal** | **Yes, documented** | One photo per new person. They replace people **left to right** in every shot, and the prompt can override who is who. No masks. Clip 5–30 s, no single shot over 15 s. Keeps cuts and sound. The maximum number of people is **not documented**: our `maxPeople: 4` has no source. | fal.ai/models/minimax/h3-max/recast/api |
| Kling O1 Edit · Replicate | Plausible, not documented | Each person is an "Element", named in the prompt as `@Element1` and `@Element2`. **4 references in total**, so 2 people at 2 photos each. Face crops are not documented. Clip 3–10 s. | replicate.com/kwaivgi/kling-o1/readme |
| Kling 4.0 · Replicate | Not documented | Edits `base_video` with `@image_N` in the prompt. Our `maxPeople: 3` has no source. | replicate.com/kwaivgi/kling-v4.0/readme |
| Wan 2.2 Animate Replace · Replicate | **No** | The README says the video "should contain one person". There is no way to choose which person. | replicate.com/wan-video/wan-2.2-animate-replace/readme |
| Genjutsu · Higgsfield, Seedance 2.5 edit | Possibly | Images are assigned to people only through the prompt. Untested. | docs.comfy.org (Genjutsu node); evolink.ai Seedance 2.5 docs |

- **Today:** two people in one pass with fal Recast. It is built and stays `preview`, and it **needs `FAL_KEY`**. Without fal, two people fall to Kling O1 or Kling 4.0, which are unverified.
- **Workaround: two passes, one person each.** Run Kling O1 with the face crop of one person, then again on the result for the other.
  - It works in principle, but costs double.
  - The second pass regenerates the first person too, so quality drifts.
  - People who cross or overlap can swap identities.
  - Hosted Wan Animate has no mask input, so it can't target one of two people.
  - **Recommendation:** don't build two-pass. Use fal Recast, and mark the Kling options "not tested" until the first real runs.
- **Not possible today:** more than one person with Wan Animate, or a reliable mapping when the two people swap sides mid-clip. With fal, say who is who in the prompt.
- **Work needed:** small. Let People (and their outfits) appear in the existing "Becomes" menu, add an `@mara` shortcut that prefills a cast row, add Android parity, and correct `maxPeople` after the first real runs.

### 5. Generating photos (priced first, Approve for spend)
These reuse the Photo engine (images/service.ts). The prices are today's config defaults; the app always shows the server's estimate.

| Action | What runs | Price per photo |
|---|---|---|
| A place, random view | Image edit with the place's own photos as references, prompt "another view of this place, no people" | about $0.03 |
| A place, from a description | Text to image, plus the place's photos if it has any | about $0.03 |
| A place, from a reference picture | Edit with the picture as reference, "rebuild as this place, no people" | about $0.03–0.04 |
| A person's base photos | From 1 upload: face, waist up and full body, made with the existing sheet fill | about $0.09 for 3 |
| A person's outfit | The existing outfit system with 3 slots (front, ¾, face) instead of 7 | about $0.09–0.15 |

- Nothing runs before **Approve**.
- Members pay from the studio balance as they do today.
- Mock or test mode is $0.

### 6. Claude
- **New app tools:**
  - `places_list` and `place_create` (name, tag, description, upload)
  - `person_create`, `pet_create`
  - `world_tag` (rename a tag)
- **Approval actions with the price shown:**
  - `place_generate_photo` (random, description or reference)
  - `person_fill_photos`
  - `person_outfit_make`
- **Changes to existing tools:**
  - `suite_set_draft` accepts `place`/`person`/`pet` mentions.
  - `suite_cast` lists people.
  - `suite_add_reference` can add a place.

## Phases (in order; sizes are rough working days for one worker per app)
**Phase 1: the page shell and Places.**
- **Server (2 d):**
  - Migration 0040 for places.
  - The location routes take `modelId`, `images`, `tag` and `description`.
  - Image budget order and the fallback to words.
  - Photo sends the place picture as `refs.scene`.
  - The 3 generate actions, with estimates.
  - Tests.
- **Mac (3 d):**
  - Tabs on `ProfileView`. Profile and Wardrobe only regroup what exists.
  - The Places tab and the Add photo menu.
  - `@` grouped by Her / Places.
- **Android (3 d):** the same, as in mockups 7 and 8.
- **Cost to run:** nothing extra per video, except where a place adds a paid image (MiniMax H3 · Higgsfield beyond 5 images: $0.08 per take). About $0.03 per generated place photo.

**Phase 2: People and their wardrobe.**
- **Server (3 d):**
  - `kind`, `parent_model_id`, `relation`, `tag`.
  - Lighter sheet rules.
  - `cast[]` in Shot and Photo.
  - The `suite.shot.person` block.
  - Outfits with 3 slots.
  - Claude tools.
- **Mac (3 d):**
  - People tab and person card.
  - Composer: more than one person, "Images sent".
- **Android (3 d):** the same.
- **Cost to run:**
  - About $0.09 to set up a person.
  - About $0.09–0.15 per outfit.
  - Videos cost the same, except when extra images are billed (as above).

**Phase 3: Pets (1 d server, 1 d per app).** `kind: pet`, the Pets tab, and the `@` group. About $0.03 per generated photo.

**Phase 4: the two-person Swap (1 d server, 1–2 d per app).**
- People appear in the "Becomes" menu with their outfits, and `@` prefills cast rows.
- Android Recast parity.
- `maxPeople` is set from real runs.
- **Cost to run:** fal Recast at $0.30/s (768P) or $0.45/s (1080P). A 9 s clip is $2.70–4.05, charged only when the take finishes.

## Risks
- **Image budget.** Two people plus a place plus an outfit can overflow small models (Kling O1: 4). Identity always wins, and the place is described in words. The composer must show what dropped, or the café "won't look the same" and nobody will know why.
- **Hidden price rises.** Extra images on MiniMax H3 · Higgsfield cost $0.08 per take. The estimate must include them.
- **Places with people in them.** If an uploaded place photo shows a person, the model can copy them into the shot. Generated place photos must say "no people". Uploads get a soft warning when a face is detected (the existing vision check).
- **Two-person mapping.** fal maps left to right. People who swap sides, or appear in different shots, can be swapped. Say who is who in the prompt, and keep the face markers.
- **No fal key.** Without `FAL_KEY`, the only two-person options are the unverified Kling ones.
- **Migration.** Existing studio locations must stay usable: they become "Studio places" in `@`.

## Owner decisions (2026-11-16)
1. **A place is hers alone**, with "Copy to another model". The studio's existing locations stay shared, as "Studio places".
2. **People do not appear in the Models list.**
3. **No fal account.** The two-person Swap (phase 4) stays general across models and **defaults to Higgsfield Genjutsu**, which the owner says handles several people well. Nothing is built for it now; fal Recast stays as it is (no `FAL_KEY`).
4. **Her plus 1 person per Shot** to start.
5. **One photo per Generate click**, the price on the button ("Generate · $0.03"), Approve for spend, and never charged above the estimate.

## Phase 1 as built (server)
- Migration `0040_places.sql`: `suite_locations` gains `model_id`, `tag`, `description`, `images` (≤ 8, each with its `source`), `cover` and `updated_at`. The old `image` became `images[0]` and stays the cover for older apps.
- Routes (`/v1/suite/locations`): `GET ?modelId=` (hers first, then the studio's), `POST` (a studio place still needs a photo; hers may start empty), `GET/PATCH/DELETE /:id` (rename, tag, describe, cover), `POST /:id/images`, `DELETE /:id/images/:index`, `POST /:id/generate/estimate` and `/:id/generate` (`mode` random · description · reference, `maxUsd` = the price approved), `POST /:id/copy {modelId}`.
- Shot and Photo take `placeId`, and an `@tag` in the prompt picks the place too (hers first, then the studio's). Its cover goes after her images as the location (Shot) or scene (Photo) reference; with no room, or no photo, it is described in words and the estimate says so. Extra paid images (H3 · Higgsfield over 5) show in the estimate's notes.
- Claude: `places` (list, create, update, add_photo, copy; free), `place_make_photo` (Approve, priced) and `place_remove_photo` (Approve).

## Open questions for the owner (each with a recommended answer; answered above)
1. **Should a place belong to her alone, or be shared across models?** Recommended: hers alone, with "Copy to another model". The studio's current locations stay shared, as "Studio places".
2. **Should people (sister, friends) also show in the Models list?** Recommended: no. Show them only on her page, in `@`, and in Swap, so the Models list stays hers.
3. **Should we add the fal account (`FAL_KEY`) for the two-person Swap?** Recommended: yes. It is the only model documented to swap two people in one pass. Until then, the Kling options are labelled "not tested".
4. **How many people in one Shot?** Recommended: her plus 1 to start, and her plus 2 later, once we see how the image budget holds.
5. **How many photos per generate click?** Recommended: 1 per click, priced on the button ("Generate · $0.03"), so nothing is made in bulk by accident.
