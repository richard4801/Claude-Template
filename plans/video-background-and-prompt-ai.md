# Video studio: background replacement + "Improve with AI" prompts (plan)

_Added 2026-11-04._ The goal is to let a user swap the clip's background (e.g. "resting on a luxury car at dusk") with proper lighting, without writing an H3 prompt. Status: **planned**. The first background-replacement render (the luxury-car test) decides the approach (see "Gate").

## User-facing (video studio)
- **Background:**
  - **Keep the room** (default)
  - **Replace**:
    - **Reference photo slot** (optional): a photo of the place or set, e.g. a car in a driveway.
    - **Describe it**: a short free-text box, e.g. "resting on a black luxury car at dusk, warm lights".
    - **Motion:** Still / Subtly alive / Busy (already in the features list).
- **Improve with AI:** a toggle, on by default. It turns the casual description into precise, lighting-matched wording.
- **Prompt view:**
  - Users never see the underlying prompt.
  - Pro mode shows the user's own layers.
  - Template layers stay hidden for non-owners (see `plans/templates.md`).

## Under the hood: two stages
1. **The prompt engine (deterministic script, already exists).** It builds the H3 structure:
   - `subject_definitions`, `summary`, `retention_analysis`, `detailed_description`
   - identity and outfit references, never-add
   - "remove on-screen text/captions"
   - background set to `replaced` (instead of `fully_preserved`)
   - **contact mapping**: the surface the performer touches becomes the new surface, e.g. counter → car roof

   Rules like these are free, instant and reliable.
2. **The scene writer (Claude, only when "Improve with AI" is on).** One server-side Messages API call with:
   - **Input:**
     - one mid-clip frame of the source (vision)
     - the background reference photo, if given
     - the user's description
     - a short system brief, cached, covering: our H3 format, the house style (phone-natural, no AI gloss), and lighting continuity (match the key-light direction and colour temperature seen on the performer's face, add a plausible rim/fill, reflections, contact shadows)
   - **Output:** structured output (`output_config.format`) with:
     - `scene` (setting, props)
     - `contact` (what the performer touches/leans on)
     - `lighting` (key / fill / rim / time of day / colour temperature)
     - `camera` (keep the source's framing and motion; no new moves)
     - `negatives`
     - `risk_notes` (e.g. "pose is seated, so 'resting on car' needs standing"; "caption text present")

   The prompt engine slots these into the structure. The model never writes the whole H3 prompt, so the structure stays correct.
   - **Model:** `claude-opus-5-5` (default, configurable via env `PROMPT_AI_MODEL`), adaptive thinking, effort `low`, with server-side `fallbacks: "default"` for refusals, and the `stop_reason` checked before use.
   - **Cost (Opus 5.5 at $4 / $20 per MTok):** about 3–4K input tokens (one frame, the cached brief, text) plus about 1–1.5K output tokens ≈ **$0.03–0.04 per video**. A cheaper `claude-haiku-5-5` would be ~$0.001 per video if quality holds; that's the owner's call after an A/B on a few clips.
   - **Key:** `ANTHROPIC_API_KEY` as a Railway secret variable (the owner adds it; never in chat or code).
   - **Logs:** every call records its input description, structured output, model and cost on the job, so results are reproducible.

## Gate: decided by the first background-replacement render
- **If H3 replaces the background cleanly** (stable, no sliding, hand sits on the new surface, caption gone): ship the plan above.
- **If H3 struggles:** switch "Replace" to **composite mode**:
  - Render the character on the original background as usual.
  - Matte the character with a video segmentation model.
  - Composite the character over the reference photo or a generated plate, with light-wrap and a colour match.
  - The scene writer then drives the plate generation instead.

## Later
- **A Claude skill** for power users who prefer crafting prompts in the Claude app, using the same brief as the scene writer.
- **Text-to-video** (no source clip) reuses the scene writer for the whole shot.
