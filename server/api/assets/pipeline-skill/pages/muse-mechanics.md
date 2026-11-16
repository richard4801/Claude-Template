# MUSE mechanics (verify when unsure — MUSE changes often)
Updated 2026-11-16 by the coordinator; items marked (changed) differ from what the Icon edit found.
- Patch shapes: new items need `speed`; overlay items inserted in time order; main clips take no `startSec` (append to lengthen); `add_music` needs `{upload, durationSec}` and moves the music track to the end; `keyframe` uses `t` (seconds from clip start) and `v`; x is the centre position, not an offset.
- Never probe `adjust` or `mask` with dummy values: they apply. [25]
- An overlay item needs ≥ 0.1 s of source; for a 1-frame flash hold the still 3 frames and set speed 3. [66]
- (changed) Asset list limit is now 400 (was 60). Still give a changed clip a new asset id or the app shows the old one.
- (changed) Uploads: up to 2 GB in 64 MB parts (was: stuck over ~75 MB). Re-verify on first big upload; splitting with a stream copy is the fallback.
- (changed) Imports from file or link: up to 60 min / 2 GB. Swap/Recast still take ≤ ~30 s at use.
- (changed) Blend modes: normal, multiply, screen, overlay, softLight, darken, lighten, add, **difference, exclusion**.
- (changed) Template library: `edit_templates` (list), `edit_template_apply` (with `dryRun` first; paid ones ask for Approve), `edit_template_save` (save a recipe from a selection or spec). Use a template before writing a new script; save a new proven recipe as a template (ask the owner first).
- (changed) `save_to_mac` saves a take/upload/outfit picture to the Mac at original quality for local work.
- `auto_captions` always draws its captions: read the times, then undo that entry. [89]
- 16 overlay tracks max; templates that need many copies say how many tracks they need.
