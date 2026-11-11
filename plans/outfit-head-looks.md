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
