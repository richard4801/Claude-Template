---
name: muse-edit-pipeline
version: 1
source: Icon edit es_90f88fe3b4a9 (rev 166, 124 trials, 2026-11-13/14), PIPELINE-BRIEF.md + PIPELINE-LOG.md
scope: Edit (beat-synced edits, effects, lyrics). Read this core at the start of every edit; open a page only when the step needs it.
---

# MUSE Edit Pipeline (core)

The Icon edit was never hard because of taste; the owner's taste is clear and fast. It was slow because every effect was built from zero, checked on stills instead of at speed, and kept in /tmp (wiped three times). This core fixes the order of work and the rules. Detail lives in the pages.

## Order of work (each step ends with its check)
0. **Sources.** Import packs + song; split packs into ~100 s parts. One permanent work folder: `<project>/work/`, never /tmp. Sweep every pack once for repeated frames, hidden cuts/dissolves, colour flashes on first frames. → page `sources`
1. **Song map.** `listen` in windows + `song_notes`: hits, bursts, silences, drop, bars. Never time from the picture. Word onsets from the voice with the beat cancelled. Lyric wording comes from the owner. → page `timing`
2. **Cut on the beat.** Every shot starts on a hit; length = gap to the next hit. Check the middle frame of every shot and the last 3 frames before a note cut, then `listen` the mix. **Owner checkpoint at speed, with sound, before any polish.**
3. **Reference + board.** Study the reference on full-resolution crops, never tile sheets. Name each device in plain words, map it to our song by time, one card per moment. **Owner checkpoint: keep / drop / change each card.**
4. **Build effects, card by card.** Read back the idea (timecode, what is on screen, strength and length of any effect word). Count notes → one stage per note. **Use a template first** (`edit_templates`, `edit_template_apply` with dryRun). Check on a sheet over flat colour before upload, then exact frames in MUSE. **Owner judges at speed**; A/B by undo/re-apply.
5. **Entrances.** Every new layer enters washed (2 frames; thin layers 3 frames at 0.9/0.65/0.35). Do it when the layer is built. → page `entrance-wash`
6. **Lyrics — earlier than you think** (they changed two finished transitions last time). Design sheet over real composited frames, owner approves, render as one see-through clip on its own top track. → page `lyrics`
7. **Signature, end card, sound.** Templates exist. → page `sound`
8. **Finish.** One full watch at speed, export, check the export.

## Rules that held (Icon edit; status in brackets)
- Never time from the picture. A shot starts on a hit; an action's *start* goes on the hit; a contact = lead-in ending on the hit + contact frame first. [proven]
- One stage per note: count the notes before choosing panels/steps. To give a shot time, take it from a neighbour; never move a hit. [proven]
- A window/strip/panel previews the shot it opens into, in place, unscaled; "open to full" is then a plain cut. [proven]
- Repeat the idea, vary the shape. One font for every title. [trial]
- Effects that read on stills can vanish at speed: punch-in ≥ 30 % over the whole short shot; a flash needs a shot of ~0.5 s+. [proven]
- Before building an effect to hide a weak cut, ask whether the shot should be there at all. [trial]
- Cut-outs: free first (Mac Vision lift), same speed as the shot, fix the mask before drawing on it, separate him with light not outlines. → page `cutouts` [proven]
- Stills prove placement, not feel. Feel is the owner's play at speed. [proven]

## Working with the owner
- Read the idea back with the timecode and what is on screen before building. For an effect word ("glitch", "negative"), state strength and length, start subtle, show one frame. [proven — 3 wrong builds came from skipping this]
- Say what a build leaves out. If a logged "works" was wrong, withdraw it in the log. Answer from the log, not memory.
- Lyric wording is the owner's. Never write lyrics from memory.
- Taste and reactions → page `house-style` (read it before proposing designs).

## Checking
Sheet over flat colour before upload; zoomed consecutive frames for flicker; original / composite / matte side by side at 2×; check a matte at the magnification it will be shown at; check the last frames of a move, not only the middle. Every build script carries a self-check (frame count, end geometry). → page `checking`

## Logging (required)
Log every attempt with `pipeline_log`: what you tried, worked/failed, why, settings, time. When the owner says the edit is done or it is exported, call `pipeline_propose`. Record the owner's reactions with `pipeline_taste`.

## Pages
`sources` · `timing` · `cutouts` · `hits` · `windows-panels` · `eye-lens` · `comic-page` · `entrance-wash` · `lyrics` · `sound` · `checking` · `muse-mechanics` · `shell` · `house-style`
