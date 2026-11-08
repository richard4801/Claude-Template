---
name: seedance-prompt-structure
description: Reusable prompt-writing structure for cinematic AI video (Seedance 2.0 and similar). Use this skill whenever the user wants to turn a script, scene, story idea, or beat into shot-by-shot video prompts, or asks for a "prompt structure", "prompt template", "shotlist prompts", "режиссерские промпты", "структура промптов", or wants to start a NEW video/ad/film and needs prompts written. Each prompt targets ~15s and is fully standalone (Style Prefix baked in). Follow the exact prompt skeleton (SUBJECT, LOCATION, optional LAYOUT/@scheme, ACTION with timecoded SHOTs, CAMERA, STYLE 60:30:10, CONSTRAINTS) and the consistency rules below.
---

# Seedance Prompt Structure

A framework for writing shot-by-shot prompts for ANY story. Each prompt = one ~15s clip that works standalone (the Style Prefix is baked in). Longer scenes split into Na/Nb/Nc under the same scene number.

## 1. Global Style Prefix (write once, prepend to EVERY prompt)

```
Style: 8K cinematic. Photorealistic — no 3D render, no game engine, no game-cutscene aesthetic.
Cinematography: naturalistic master cinematography.
Lighting: Natural light only — contre-jour backlight, camera on shadow side, atmospheric haze. Key light from sky and windows only.
Color: 60:30:10 — dominant / secondary / accent.
Camera: Physical cine lens. 180° shutter motion blur.
Skin: Pore-level realism — vellus hair, asymmetric moles, capillary flush, pore-shadow matching on-set light.
Acting: top-tier cinematic — micro-pauses before reactions, precise eye-line, wet living eyes with catch-lights, visible breath and chest rise.
Physics: Gravity and inertia respected — mass has real weight, correct contact shadows. No floating props.
Composition: Rule of thirds + golden ratio. Every person moving from frame one.
Continuity: Characters, props, environment identical across every cut. No identity drift.
Technical: 24fps smooth motion. 8K detail. No jitter.
Audio: Environmental SFX only. No music. No subtitles.
```
If the user supplied a custom prefix, use theirs verbatim instead.

## 2. Asset Registry (Seedance Elements)

Every recurring person/prop/location/effect gets an `@tag`. The tag MUST match the Element name in Seedance exactly. Define: `@hero`, `@hero-alt`, `@rival`, `@prop`, `@location`, `@effect`/`@scheme`.

## 3. The Prompt Skeleton (exact order)

```
[FULL STYLE PREFIX — verbatim]

SUBJECT — Who/what is in this shot, each @tag "matches input 100%". One line on the goal + emotional beat. WB <temp>. MULTISHOT.

LOCATION — @location is a STYLE REFERENCE ONLY, not a fixed keyframe. Mood/architecture/light. The model may freely extend the world; the subject moves through space — NOT pinned to the input frame. Do not reproduce the reference 1:1.

[LAYOUT — optional: use @scheme (aerial layout) as a positional reference so recurring elements stay in consistent places.]

ACTION — one line of intent, then break 15s into shots:
SHOT 1 (0:00–0:0X) — blocking, gesture, eye-line, the beat. Hard cut.
SHOT 2 (0:0X–0:0Y) — next beat. Hard cut.
SHOT 3 (...) — final beat.

CAMERA — per shot: angle, height, lens feel, movement, motivation.

STYLE — Dominant 60% / Secondary 30% / Accent 10% for THIS shot. WB <temp>. Reinforce lighting (sun/window position, haze).

CONSTRAINTS — hard rules: 16:9, NO/USE slow-motion, camera behavior, legibility, scale locks, continuity must-holds, NO eye glow.
```

## 4. Consistency Rules

- One prompt = ~15s; fill all 15s, no dead air. Split long scenes into Na/Nb/Nc.
- Generalize physics (describe broadly, real weight/gravity) — exact km/h & degrees break physics.
- Camera is intentional: angle + height + movement + WHY. Mix locked-off, handheld+shake+dutch, FPV drone, super-macro, crane, continuous one-take.
- Slow-motion is opt-in: default NO slow-mo; call SPEED-RAMPING on specific beats and ramp back.
- Location = reference, not keyframe; subject travels through space; don't reproduce input 1:1.
- Use @scheme for anything that must stay in the same place across scenes.
- Continuity carried inside SUBJECT/ACTION language, never a separate visible block.
- Avoid named IP / real people / brands; use generic descriptors.
- Tag scale when it matters ("small 0.33L can", "human-scale 1.85m"); repeat "normal size, NOT oversized" in CONSTRAINTS if needed.
- Acting in specifics: "eyes widen, lips part, a half-beat pause" — not "he's surprised".

## 5. Blank Fill-in Template

```
[STYLE PREFIX]

SUBJECT — @____ (matches input 100%) ... WB 6500K. MULTISHOT — <beat>.
LOCATION — @____ STYLE REFERENCE ONLY, not a fixed keyframe. <mood/light>. Model extends the world; subject moves through space.
ACTION — <intent>.
SHOT 1 (0:00–0:0_) — <beat>. Hard cut.
SHOT 2 (0:0_–0:0_) — <beat>. Hard cut.
SHOT 3 (0:0_–0:15) — <beat>. Hard cut.
CAMERA — SHOT 1: <angle/height/lens/move + why>. SHOT 2: <...>. SHOT 3: <...>.
STYLE — Dominant <…> 60% / Secondary <…> 30% / Accent <…> 10%. WB 6500K.
CONSTRAINTS — 16:9. <slow-mo?> <camera> <scale/legibility> <continuity> NO eye glow.
```

## 6. Output

When given a script/idea: read it as a director, define the Asset Registry, number scenes, decide how many ~15s prompts each scene needs, then write each prompt with the skeleton. Deliver as a single self-contained editable HTML shotlist (collapsible Style Prefix block, per-scene checkbox saved to localStorage, a Copy button per prompt) when the user wants a shotlist; otherwise output the prompts as copy-ready blocks.
