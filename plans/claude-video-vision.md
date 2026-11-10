# Claude video vision (owner idea, after token reset)

Goal: Claude must not miss fast actions when studying a video in Edit (and generally).

## Decision (owner, Nov 9): on-demand, two stages. Stage 1 = items 1-3 (free). Stage 2 = item 4 only if Stage 1 still misses, run only when Claude is asked to study a clip, cached per clip. Any length: short clips full treatment; long videos overview first, then flip book on chosen parts. Starts after the Owner-bugs-first list.

## Plan, in order
1. **Motion-aware frame picking (free).** Server measures change between every frame
   (ffmpeg scene/motion score). Quiet stretches get few frames; fast stretches get every frame.
2. **Contact sheets (free).** Pack frames into timestamped grids (e.g. 4x4 per image) so Claude
   sees many frames per image at low cost, read in order like a flip book.
3. **"Look closer" tool for Claude.** Claude can ask for every frame of a short window
   (e.g. 00:04.0–00:05.5 at full fps) — the full flip book, only where it matters.
4. **Optional video-notes pass (paid, needs owner go + key).** A video-native model writes a
   timestamped action timeline once per clip at import; stored and given to Claude as notes.
   Claude's own frames stay the final word. Provider name never shown to members.

## Video uploads in Claude chat (owner, Nov 10)
Today the chat attach button takes images only (Mac ClaudeChatModel image-only picker; Android same). Stage 1 adds video: apps accept video files, upload to the server, server builds the motion-picked frames + contact sheets (+ the speech transcript) and hands them to Claude; the look-closer tool works on uploaded videos too.

## Why not every frame of the whole video
30 fps x 60 s = 1,800 images: per-request image limits, very high token cost, and neighbouring
frames are near-identical, which dilutes attention. Full frame rate is used only on windows.

## Open questions for owner
- Typical length of videos studied (15 s, 60 s, 10 min)?
- Paid notes pass: every clip, or only when Claude is asked about a video?
