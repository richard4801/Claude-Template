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

## Stage 1 server: BUILT (2026-11-11)
- `watch` and `watch_closer` in the one-Claude registry (server/api/src/claude/watch.ts), every page, owner and members,
  studio-scoped. Ids: take (Suite feed / Library / list_takes / edited version), Suite job with one take, imported clip,
  uploaded video (chat attachment uploadId). The open take on the page is filled in.
- watch: length, fps, size, sound (present, level, how much is in the voice range; not words), hard cuts, and up to 3
  JPEG contact sheets (4 across, ≤ 48 frames) picked by motion: start/end, both sides of every cut, motion peaks, then
  equal steps of motion (half per video, half per shot) with a floor for still stretches. Cached (16 videos).
- watch_closer: every frame of a window ≤ 30 s (≤ 16 frames, else an even run), 400 px tiles; one frame at 1024 px.
- Memory: one watch at a time (own queue), streamed 64-px motion pass, ffmpeg 2 threads, stills via a temp dir.
- suite_feed: takeId + watch:true on video takes, and a Library collection filter. Prompts: "watch before judging".
- Chat attachments: a video upload (contentType video/*, ≤ 500 MB) is accepted as an attachment, kept as the upload
  (not copied), never sent as an image; Claude's line says "Attached video: uploadId … call watch first".
## App follow-ups (not built)
- Mac + Android chat attach button: accept video files (mp4/mov), upload as kind "clip" with contentType video/*,
  confirm, then send {uploadId} in attachments as today. Show a video chip (poster + length) instead of an image thumb.
  The 4-per-message limit counts videos too. attachment views carry video: true and mimeType video/*:
  the Mac must not hand a video to Claude Code as an image (Claude Code calls watch over MCP instead).
- Mac Claude Code path: the per-turn line must name attached videos ("call watch {id: uploadId}"), as the API path does.
