---
name: muse-prompt-structure
description: Shot-by-shot prompt writing for MUSE's AI Suite (Shot, Photo, Swap/Edit, Storyboard, Recreate fills), built on the owner's Seedance/Higgsfield prompt structure. Use whenever a script, scene, idea, reference image or beat must become MUSE prompts plus a rig, when Claude sets up the Suite composer (suite_set_draft), or when the user asks for a "prompt structure", "shotlist prompts", "rig for this", "prompt + rig", or "режиссерские промпты". Each output is a prompt AND a rig, using only options that exist in MUSE's composer.
---

# MUSE Prompt Structure

This is the owner's Seedance prompt skeleton, tailored to MUSE's pipeline. The core idea is unchanged: one prompt is one clip, the clip is fully standalone, it's broken into timecoded shots, and continuity is kept in the words.

The big difference in MUSE: **the composer's rig writes the camera and look words for you.** MUSE compiles the rig (camera, lens, focal length, aperture, look, light, palette, angle, shot size, move) into the right camera wording for whichever video model runs the shot. So:
- **The prompt text** says who, where, what happens and what must hold.
- **The rig** says how it's shot.

Never fight the rig in the prompt. If the rig says Golden hour, don't write "overcast". If the move is Static, don't write "the camera pushes in".

## 1. Pick the tool first

| Tool | Use when | Prompt focus |
|---|---|---|
| **Shot** (video) | A new clip of a model | Full skeleton (§3) |
| **Photo** | A still or a photoshoot set | SUBJECT, POSE, LOCATION, WARDROBE, CONSTRAINTS. No ACTION timeline, no move. |
| **Swap** | Put a model into an existing clip, or change its background; keep the motion | A SHORT prompt: only what changes (see §7a; New Swap's toggles: §7b). MUSE's swap scripts already say what to keep (motion, timing, camera, framing, figure). Her figure always comes from her own images or her outfit's pictures (see Figure lock). No camera words: the source clip has the camera. |
| **Storyboard** | Several connected shots | One §3 prompt per scene, sharing the Style Prefix and the @tags |
| **Recreate fill** | A missing shot of a reference edit | The slot brief is the ACTION. Keep it to that shot's length and framing. |

## Figure lock (owner rule, every mode)

Her figure never changes: not with the outfit, not with a reference image or reference video, not between shots.
- Her body shape and proportions (legs, thighs, hips, waist, bust, arms) always come from her own images. With an
  outfit chosen, the outfit set's four angles (front, ¾, side, back) show her true figure in those clothes; MUSE sends
  them as her body references.
- From a reference video (Swap, Recreate) or a pose/style reference image, take only the motion, pose, expressions,
  camera, setting and light. Never the body shape, height or proportions of the person in it. Say so in the prompt:
  "her exact figure and proportions from her images, unchanged; only the motion from <Video 1>".
- Never describe her body as smaller, slimmer, taller or different from her references, and never copy a body
  description from a reference. Her character's description (her look) carries any body notes; repeat them, don't
  invent new ones.

## 2. Style Prefix (optional, owner-editable)

Use the owner's prefix when they supply one. Otherwise, start from this MUSE default.

**Lines that must never contradict the rig:**
- Lighting and colour: they're the rig's Light and Palette rows, so don't restate them here.
- Lens and shutter: the rig's Camera, Lens, Focal and Aperture rows.

**The default prefix:**

```
Style: Photorealistic, cinematic. No 3D render, no game-engine look, no CGI sheen.
Skin: Pore-level realism. Natural texture, vellus hair, real catch-lights in wet, living eyes. No plastic smoothing.
Acting: Specific and human. Micro-pauses before reactions, precise eye-line, visible breath.
Physics: Real weight and inertia, correct contact shadows, nothing floating.
Continuity: The person, her figure, wardrobe, props and setting stay identical across every cut. No identity or body drift.
Audio: Environmental sound only. No music, no subtitles, no on-screen text.
```

The owner's Seedance prefix lines are kept as options:
- "Natural light only, contre-jour backlight, haze": set **Light → Contre-jour** in the rig instead.
- "60:30:10 colour": use the STYLE line in §3 plus a matching **Palette** row.
- "24fps, 180° shutter": set **Frame rate → 24** and **Shutter → Normal**, video only.

## 3. The prompt skeleton (exact order)

```
[STYLE PREFIX]

SUBJECT — @ModelName (matches her references 100%: face, figure and body proportions, skin, hair). <one line: the goal + the emotional beat>. WARDROBE: <exact outfit, or "her saved outfit @OutfitName">. MULTISHOT if more than one shot.

LOCATION — <place, materials, time of day, weather>. Style reference only, not a fixed keyframe. She moves through the space; don't reproduce any reference 1:1. (Or @LocationName for a saved studio location.)

ACTION — <one line of intent>.
SHOT 1 (0:00–0:0X) — <blocking, gesture, eye-line, the beat>. Hard cut.
SHOT 2 (0:0X–0:0Y) — <next beat>. Hard cut.
SHOT 3 (0:0Y–0:END) — <final beat>.

STYLE — Dominant <colour> 60% / Secondary <colour> 30% / Accent <colour> 10%.

CONSTRAINTS — <aspect>, <slow-mo: NO unless a SPEED-RAMP beat is named>, <hands and feet anatomically correct>, <scale locks>, <continuity must-holds>, NO eye glow, NO text, NO watermark, NO logos.
```

Then the **RIG** block, always alongside the prompt (§4).

## 4. The rig: only what MUSE's composer has

Pick from these exactly. Anything else isn't in the composer, and the server refuses it.

**Camera:**
- Phone
- Creator camera
- Cinema camera
- 35mm film
- 16mm film
- Super 8
- Large format 65mm
- DV camcorder
- Webcam
- CCTV

**Lens:**
- Clean sharp
- Warm vintage
- Anamorphic
- Vintage anamorphic
- Halation
- Swirl bokeh
- Macro
- Tilt-shift
- Fisheye

**Focal length:** 14mm (ultra-wide) · 24mm (wide) · 35mm (everyday) · 50mm (natural) · 85mm (portrait) · 135mm (telephoto).

**Aperture:** **f/1.4 · f/2.8 · f/5.6 · f/11 only.**
- f/1.4: dreamy, very shallow. Avoid for full-body or seated full shots, where hands and feet go soft.
- f/2.8: soft background, subject sharp. The best default for portraits and fashion.
- f/5.6: natural; most of the scene is sharp, including rock and texture.
- f/11: everything sharp.

**Look:**
- Clean digital
- Phone HDR
- Portrait negative film
- Tungsten cinema stock
- Slide film
- Black & white film
- Bleach bypass
- Cross-processed
- 16mm reversal
- Faded print

**Light:**
- Natural
- Window light
- Soft cross
- Contre-jour
- Overhead fall
- Practicals
- Silhouette
- Golden hour
- Blue hour
- Ring light
- Studio three-point
- Neon night
- Harsh noon sun
- Overcast
- Candle / firelight
- Moonlight
- On-camera flash

**Palette:**
- Naturalistic
- Bleached warm
- Hyper neon
- Teal & orange
- Sodium decay
- Cold steel
- Bleach bypass
- Classic B&W
- Pastel dream
- Muted earth
- Golden warmth
- Moody blue
- Vintage fade
- High key
- Low key noir
- Cyber magenta
- Forest green
- Desert sand
- Clean commercial
- Retro 80s
- 90s mall
- Y2K gloss
- Candy pop
- Autumn
- Winter frost

**Angle / height:** Eye level · Shoulder level · Hip level · Low angle · High angle · Overhead · Worm's-eye · Ground level.

**Shot size:**
- Extreme wide
- Wide
- Full body
- Cowboy
- Medium
- Medium close-up
- Close-up
- Extreme close-up
- Insert
- Over the shoulder
- POV
- Two-shot

**Move (video only):**
- Locked-off
- Handheld
- Selfie
- Follow
- Micro push
- Dolly in
- Dolly out
- Orbit / arc
- Crane up
- Tracking
- FPV fly-through
- Whip pan
- Crash zoom
- Handheld run
- Rack focus
- Dutch push

**Frame rate (video):** 24 · 25 · 30 · 48 · 60 · Slow motion.

**Presets** are good starting points; change rows after applying one:
- Phone UGC
- Talking head
- Selfie vlog
- Creator studio
- Cinematic
- Product hero
- Music video
- Documentary
- Noir
- Fashion editorial
- Y2K camcorder

### Rig rules (the rig check warns about these)
- **One move per shot of 5 s or less;** at most two moves in a 15 s clip. Fast moves smear faces.
- DV camcorder, Phone, Webcam and CCTV have deep focus, so f/1.4 or a rack focus won't show.
- A wide lens (24mm or wider) on a close-up distorts the face. Use 50–85mm for faces.
- Worm's-eye with a chest-up close-up reads badly.
- Talking or lip-sync shots use Locked-off or a Micro push only.
- Photos ignore Move, Frame rate and Shutter.

## 5. Lengths and formats (MUSE's engines)
- **Clip length:** most video engines do **4–15 s**; a few go to 30 s. Fill the whole length with no dead air. For a longer scene, split it into Na/Nb/Nc prompts and join them in Edit.
- **Aspect:** default **9:16** (TikTok, Reels, Shorts) unless the owner says otherwise. Say the aspect in CONSTRAINTS and set it in the composer.
- **Slow motion:** off by default. Name a SPEED-RAMP beat ("SHOT 2: speed-ramp into the hair flip, back to real time on the landing"), or ramp it later in Edit, which is often cleaner.
- **Text, captions and logos:** never in the generation. Add them in Edit, where they stay sharp and editable.

## 6. Consistency rules (kept from the original)
- One prompt is one clip, standalone, with the prefix included.
- Describe physics broadly ("real weight, she catches herself on the rail"); exact speeds and angles break it.
- The camera is a choice: set it in the rig, and in ACTION say *why* it moves ("push in as she realises").
- Location is a reference, not a keyframe. Use @LocationName for a saved place that must repeat.
- Keep continuity inside SUBJECT and ACTION ("the same black slip dress, now wet at the hem").
- No real people, brands or named IP. Use generic descriptions.
- Lock the scale when it matters ("a small 0.33 L can, normal size, NOT oversized").
- Acting in specifics: "eyes widen, lips part, a half-beat pause", not "she's surprised".
- **Hands and feet:** describe the pose of the fingers and the feet when they're visible. That's where generations drift most.
- **Identity:** describe wardrobe, pose and expression, never the model's face. Her references carry the face.

## 7. Output
- **For one shot or photo:** the prompt block plus a **RIG** table (row → choice, one-line reason), then the "Avoid" line.
- **For a script:** define the @tags, number the scenes, decide how many ~15 s prompts each needs, and write each with the skeleton and its rig. Give it as copy-ready blocks, or, if the owner wants a shotlist, as one self-contained HTML page with a collapsible prefix, a checkbox per scene and a Copy button per prompt.
- **When Claude drives the composer** (`suite_set_draft`): put the prompt text in `prompt` and set every rig row by its option id from `suite_options()`. Explain the choices in two or three lines. Then call `suite_request_shot` without confirm to show the price; with `confirm: true` it asks the owner in the app, and nothing runs until they approve.

## 7a. Swap: short prompts (owner rule, 2026-11-12)

In Swap the prompt is **only the change**. MUSE's own swap prompt (Settings → Prompts → Scripts, video.replicate / video.edit) already tells the model to keep the motion, timing, camera, framing and crop of the clip, and her figure. Don't repeat any of that, and never write a full §3 skeleton for Swap.
- **Background** (Swap panel → Background):
  - *Keep*: the room stays. Leave the prompt empty, or note a small direction ("she smiles more at the end").
  - *Describe it*: write only the new place, plus at most a few words of light or mood. Example: "a rooftop at golden hour, city lights behind her". Auto runs Genjutsu Light (same moves, new scene).
  - *New photo*: pick a location or upload a picture. The prompt can stay empty.
  - If the person asks for a new place while Background is Keep, set background to describe with `suite_set_draft` (MUSE also warns about this).
- **Outfit**: pick it in the Swap panel. Never describe the clothes in the prompt: the outfit's 7 pictures (body angles and face close-ups with its hair, make-up and accessories) are what the model gets.
- **Character**: pick her in the Swap panel. Never describe her face or body; her images carry them.
- **Length**: Genjutsu Light uses the first 15 s of the clip, and full Genjutsu up to 30 s. For a longer clip, trim it in Edit first.
- **Price**: Higgsfield bills the clip's own seconds as well as the new video, so a 10 s swap at 720p is about 20 billed seconds. Always show `suite_request_shot` without confirm first.
- Before writing, look: `suite_get_draft` shows onScreen settings (background, its picture, outfit, character), and `watch` the clip when you need to know what's in it.

## 7b. New Swap (beta): toggles, only the change (owner, 2026-11-12)

Swap's header has a switch, **Swap | New Swap (beta)**. New Swap starts from the video (upload, link or Library), with no model picked first. Then the person turns on what should change. Everything left off is kept from the clip.
- **You write only the change, one short phrase per toggle.** MUSE builds the prompt from the toggles (script `suite.remix`): the task line, the figure lock, one block per toggle, the keep line, then the person's words. Never write a skeleton, a keep list or camera words.
- **Toggles** (`suite_set_draft` with `swapVariant: "new"`, then `clipId` and `remix`; a toggle set to `null` is switched off):
  - **Background**: `{mode: "describe", words: "a rooftop at golden hour"}`, or `{mode: "photo", image, name}` for a location or upload.
  - **Outfit**: `{kind: "outfit", outfitId}` for one of her outfits (its pictures are sent; never describe the clothes), `{kind: "product", image}`, or `{kind: "words", words: "a black linen two-piece"}`.
  - **Character**: `{kind: "model", modelId}` (her, the default). Her face, hair and skin come from her images, and her body only from her outfit's angles or her body shots. From the clip the model takes **only the motion and facial gestures**, never the body, face or figure of the person in it. MUSE puts this figure lock in every New Swap prompt. `{kind: "face", image}` is the optional **face swap** (face only). Use it only when the person asks for it; it is off by default.
  - **Look & light**: `{words: "night, neon, teal grade"}` (time of day, light, colour grade).
- **Put each change in its own toggle.** A new place goes in Background, not in Look & light. Clothes go in Outfit, and never in her words.
- **Model**: leave `engineModel` empty for Auto. Auto picks Wan 2.7 Edit for Background or Look, Kling O1 for Outfit, and Genjutsu Light (≤ 15 s, else Genjutsu) when her Character is on. Tell the person Auto's one-line reason. Any video model can be picked (owner rule: every model in every mode). `suite_remix_models` lists them all, defaults first, each with what it does for these toggles ("prompt" = by instruction only; "adapted" = MUSE sends the clip as a reference video, as frames, or not at all, and its `notes` say exactly what). It also gives each model's limits, whether it has had a test run in MUSE, and its price for this clip. When you pick an adapted model, tell the person what MUSE will do.
- **Length**: a clip longer than the model takes is **never cut silently**. `suite_estimate` shows `remix.trim.needed` and the maximum. Ask which part to use, then set `range: [from, to]`, or let the person use the trimmer.
- **Price**: the clip's own seconds can be billed too (Genjutsu Light: output plus input). Always show `suite_request_shot` without `confirm` first. With `confirm`, the owner gets Approve in the app; nothing runs before that.

## 8. Worked example: a seated editorial photo

**Prompt (Photo):**

```
SUBJECT — @Zelphira (matches her references 100%). Calm, composed editorial portrait. WARDROBE: black silk-chiffon maxi slip dress, thin straps, deep V, high leg slit; barefoot; white seashell anklet.
POSE — Seated sideways on a rock ledge, body three-quarters to frame left. Right knee drawn up, both hands loosely clasped around its front, fingers interlaced. Left leg tucked down, bare foot flat on the rock, toes relaxed. Head turned to frame left, chin slightly lifted, unsmiling, lips softly closed. Long straight dark hair down her back and over her right shoulder.
LOCATION — Pale grey weathered coastal limestone boulders, with warm ochre and rust patches on the rocks behind, under a soft blue sky.
STYLE — Dominant pale stone grey 60% / Secondary sky blue 30% / Accent black dress 10%.
CONSTRAINTS — 9:16, full body head to feet. Hands and feet anatomically correct. No shoes, no other jewellery, no text, no watermark, no people behind her.
```

**RIG:**

| Row | Choice | Why |
|---|---|---|
| Camera | Cinema camera | Clean, rich skin |
| Lens | Clean sharp | Crisp rock texture |
| Focal | 50mm | Natural proportions, full body |
| Aperture | f/5.6 | Sharp from head to toe |
| Look | Clean digital | True-to-life |
| Light | Natural | Soft high daylight |
| Palette | Naturalistic | No heavy grade |
| Height | Hip level | Slightly low, flattering |
| Shot size | Full body | Head to feet |

**A more cinematic version:** the Fashion editorial preset (Large format 65mm, Halation, 85mm, Portrait negative film, Golden hour, Golden warmth), with Aperture changed to f/2.8 and Height to Low angle.
