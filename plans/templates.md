# Templates (spec)

_Decided 2026-11-04._ A template is a reusable **look**: a camera style, scene, light, grade and after-effects, plus the hidden prompt layers behind them. It is applied to **any** model and outfit, and the library grows every time someone saves a shoot they like. Photo templates come first. Video templates and text-to-video from the character sheet follow after the first real GPU render.

## What a template stores
- **Name, cover image, tags/group** (e.g. "Faceless", "Golden hour", "Product moment").
- **Hidden prompt layers:**
  - style
  - scene
  - camera (shot, lens, angle, framing)
  - light and grade
  - after-effects: face motion blur, colour grade/LUT, grain
  - negative additions
  - a **variation pool** (see below)
- **Not stored:** identity, outfit, never-add or seed. Those always come from the model being shot, so a template works on any model.
- **Owner, visibility** (`private` | `public`), created-from shot id, and usage count.

## Visibility
- **Private:** only the creator sees and uses it.
- **Public:** everyone in the studio can see and use it. The creator can switch it either way at any time. (Later, once there are client studios, "public" could also mean a platform-wide gallery. That's a separate decision.)

## Prompts stay underneath
- **Creating a template:** the creator sees the full prompt (its layers) and can edit it.
- **Using a template:** users never see the template's prompt layers. In the prompt view (pro mode), the template shows as one locked line, "Template: Mirror selfie", while their own layers (identity, outfit, their direction) stay visible.
- The server keeps the template layers and builds the final prompt on its side. The apps only send the template id plus the user's choices, so the hidden layers are never sent to other users' devices.

## Every shot is different
Templates must **not** reproduce the same picture. Each shot:
1. uses a **new random seed** ("Lock look" is off by default for templates), and
2. draws one option at random from each slot in the template's **variation pool**:
   - pose
   - body angle
   - framing / crop
   - expression
   - background detail
   - hand placement
   - time-of-day nuance (within the template's light)

   This gives the same *style* but a different *moment* every time.
3. **Optional "Direction" box:** if the user writes how the character should be placed ("sitting on the steps, looking back over her shoulder"), it **replaces** the pose and angle draws. The rest of the template still applies.
4. A **Shuffle** button re-rolls the variation draws without changing the template.

## Creating a template
- **From a shot:** any photo you like → **Save as template**. This captures the exact layers that made it plus the image as the cover. You name it and set private (default) or public.
- **From scratch** (pro): start from the layer editor.
- **The variation pool** is auto-suggested from the template's style (e.g. a mirror selfie suggests phone-covers-face / phone-low / three-quarter turn). The creator can edit it.
- **After-effects** that image models do badly, like deliberate face blur or a precise colour grade, are applied **after generation** as an edit step, not via the prompt.

## Starter pack (public, studio-wide, our own recreations)
Based on the style references the owner shared, recreated with our own models. No third-party photos are used as references or covers.
1. **Motion-blur face:** a sharp background with the face dragged by motion (applied as an after-effect).
2. **Mirror selfie:** the phone covers the face, a candid room, and a slightly underexposed grade.
3. **Harsh-sun close-up:** an extreme crop with hard shadows and visible skin texture.
4. **Moody low-light:** underexposed with a blue/purple grade and soft grain.
5. **Reflection:** the subject plus a mirrored surface (a car roof, glass or water) used as a second image.
6. **Product moment:** a product as the hero with a hand or person partly in frame. It takes an optional product photo.
7. **Candid POV:** off-centre framing, hands entering the frame, a phone-camera look.

## Library
- **Tabs:** All / Mine / Public / Favourites.
- **Search** by name or tag, plus tag chips.
- **Cards** show the cover, name, owner, uses, and a private/public badge.
- **Template detail:** the cover, a few recent results, and **Use** / Duplicate / Edit (owner only) / Delete (owner only) / visibility toggle (owner only).

## API (additions to `plans/api.md`)
| | |
|---|---|
| `GET /v1/templates?scope=all\|mine\|public\|favourites&q=&tag=` | List templates without hidden layers; the owner's own get `layers` |
| `GET /v1/templates/{id}` | Template detail (layers only for the owner) |
| `POST /v1/templates` `{name, tags, visibility, layers, variationPool, coverTakeId? \| fromShotId}` | Create; `fromShotId` copies that shot's exact layers and image |
| `PATCH /v1/templates/{id}` `{name?, tags?, visibility?, layers?, variationPool?}` | Owner only |
| `DELETE /v1/templates/{id}` | Owner only |
| `POST /v1/templates/{id}/favourite` / `DELETE …/favourite` | Per user |
| `POST /v1/shoots` gains `templateId`, `direction?`, `shuffleSeed?` | The server builds the prompt (template layers + identity/outfit/never-add + variation draws or direction + new seed) and records which variation options were drawn on the shot |

## Later
- **Video templates:** the same model, plus motion and camera-move layers, applied to H3 renders.
- **Text-to-video:** no source clip, just a description plus the character-sheet references (needs one test of H3's text/image-to-video variants first).
