# Claude in Edit: gaps from a real session (owner + in-app Claude, 2026-11-10)

Source: Claude's own report after the "phone frame / hand pop-out" edit (revision 25). Checked against the code.

| # | Claude's complaint | What the code says | Fix | Where |
|---|---|---|---|---|
| 1 | No beat times, only tempo | detect_beats computed the times but the tool returned only counts | DONE 2026-11-10: returns beatTimes and strongTimes | server |
| 2 | No documentation for edit ops | apply_edit_ops says "see plans/video-editor.md", which Claude can't read | Ship an accurate ops reference (masks, keyframes, chroma, blend, patch formats) as a tool Claude can read, generated from editor/model.ts + ops.ts | server |
| 3 | No chroma key | Clips HAVE chroma key (clip.chroma) but Claude wasn't told; IMAGES have none (the green-screen phone was an image) | Document it (item 2) + add chroma to image items | server doc; contract + both apps for images |
| 4 | No rounded-rectangle mask | Masks: linear, mirror, circle, rect, heart, star | Add corner radius to the rect mask | shared contract + Android + Mac + server render |
| 5 | Only still frames | get_frame and get_contact_sheet exist (every N s over the whole edit) | Contact sheet for a time range at fine steps (e.g. 2.2–3.0 s every 0.05 s) to check motion | server |
| 6 | Fixed layer order (main track at the bottom) | By design in v1 | Free layer order, or "main clip as overlay" | contract + both apps + render |
| 7 | No linked/grouped layers | None | Group items so one set of keyframes moves them all | contract + both apps + render |
| 8 | Can't hear audio | Claude can't take audio | Beat times (done) + waveform/energy summary per clip; strongest onset = "the drop" | server |
| 9 | Can't upload from the Mac | Claude can't reach files; the owner drags them in | Mac: a "let Claude pick from a folder" grant, or drop into chat adds to the edit's media | Mac app |
| 10 | No frame extension | None | Paid helper: AI outpaint/extend frame for objects leaving the shot (needs owner go + price) | server + provider |

Order after the token reset (after the Owner-bugs-first list): 2, 5, 8 (server-only, make Claude right first try), then 3–4
(chroma on images, rounded masks), then 6–7 (layer order, groups), then 9, then 10 (spend: ask first).
