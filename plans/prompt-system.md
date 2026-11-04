# Prompt System (spec)

_Added 2026-11-04._ Every generator in the app (character sheet, outfit set, photoshoot, video) builds its prompt with **one engine**. Users never write prompts from scratch: their choices fill slots in a template. Power users can see and edit the final text.

## 1. Layers (merged top to bottom)
| Layer | Source | Example |
|---|---|---|
| **Identity** | Model profile: look settings and locked references | "Sienna Vale: young woman, long wavy honey-blonde hair with brown roots, green eyes, light freckles, tanned skin. Identity from 6 locked reference images." |
| **Outfit** | The selected outfit set (front, ¾, side, back) | "Wearing: green set (outfit reference set)." |
| **Task** | Which generator is running | Photoshoot / identity shot / outfit angle / video swap |
| **Scene** | Scene chip **or** custom text | "Scene: sunlit rooftop bar, string lights." |
| **Camera** | Shot, lens, aperture (with lens-aware wording) | "Medium shot, 85mm, f/2.8, compressed background, creamy bokeh." |
| **Light & grade** | Light chip and grade chip | "Golden hour; grade: phone-natural." |
| **Direction** | The user's free text | "Laughing mid-step, holding an iced coffee." |
| **House style** | Global, editable in settings | "Realistic smartphone photo, natural skin texture, true-to-life colour, no beauty filter, no AI gloss." |
| **Never add** | Model's never-add list plus global defaults | "Tattoos, rings, necklaces, logos, extra fingers, warped jewellery." |
| **Seed** | "Lock look" toggle | Same seed so retakes stay consistent, or a new seed each time |

Rules:
- Empty slots are dropped, never sent as blanks.
- User direction can add detail but never overrides identity or never-add.
- Every render saves its exact prompt, seed, model, steps and references, so any result can be reproduced or tweaked later ("Retake with changes").

## 2. Templates per generator
- **Character sheet shot**: identity + task ("{angle} shot on a plain light-grey studio background, even soft light, neutral expression, full body / head-and-shoulders") + house style + never add. Angles: face front, face profile, body front, ¾, side, back.
- **Outfit set**: identity (locked references) + outfit (description, or the uploaded product photo as a reference image) + task ("{angle}, plain studio background") + never add, especially logos. Four angles, same seed across all four.
- **Photoshoot**: all layers above.
- **Video swap (H3 Ref2VA)**: the structured format proven in testing: `subject_definitions` / `summary` / `retention_analysis` / `detailed_description`. It describes the source performer *with* their tattoos and rings so they can be removed, then states "None of Subject 1's tattoos remain" and the outfit from the reference images. Audio is `fully_copy` when kept. Steps default to 10.

## 3. Bring-your-own
- Any slot (identity shot, outfit angle) accepts an upload instead of a generation, and the two can be mixed. Uploads are labelled **yours** and generations **AI**.
- Nothing is strictly required. Missing face close-ups show a warning but saving is allowed.

## 4. In the app
- Photoshoot → **Prompt** tool: "Your direction" box, Lock look toggle, the final prompt broken down by slot, Copy, and Edit as text (pro mode).
- Scene → chips **or** "Describe your own".
- Video studio → Quality → "Show the prompt" (pro mode) shows the structured H3 prompt.
