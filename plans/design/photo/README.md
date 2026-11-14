# Photo tab: design for the owner (2026-11-14)

Not built yet: app code waits for the owner's approval. Same suite style as plans/design/suite-redesign/ (theme A light,
theme B lifted dark; same header, tabs, stage + panel + bar).

Frames (PNG, deviceScaleFactor 2): `{a,b}-{empty,filled,results}-1152.png`, `{a,b}-results-1440.png`,
`{a,b}-{empty,filled,results}-phone.png` (390 wide), `{a,b}-presets-1152.png` (the preset picker open, a preset picked).
Source: `photo.html?theme=a|b&state=empty|filled|results|presets&layout=desk|phone`; render with
`node plans/design/photo/render.js` (writes fit-check.txt: every desktop frame fits 1152×720 and 1440×900 with no page scroll).

Decisions
1. Presets: a "Preset" chip in the bar (like Shot's pills), opening a small menu with search and thumbnails. No full row.
   A picked preset shows its name on the chip; the Rig rows lock to "From preset" (photo.ts: a preset carries its own
   camera and light, so the rig isn't added on top).
2. Stage: an empty state until this session makes photos (never an old result). Results: one photo large, the 4 as a
   thumbnail strip with "2 of 4", arrows; Keep is the one highlighted action, with Redo, Upscale, Use in Shot, Share.
3. Generate: the server's buttonLabel from POST /v1/suite/photos/estimate ("Generate · 4 photos · $X"; price here is a
   sample). Before it can price, the button reads "Generate · 4 photos" disabled with the reason beside it, never "—".
4. Inputs: every empty slot is a dashed box with a + and an ink label ("Add outfit", "Add product", "Add up to 3");
   the required one (Character) is underlined. References show their guide (Pose / Look / Scene) and "1 of 3".
5. Rig for stills only: Framing, Lens (focal + aperture), Light, Look (the grade; gradeLook on = "House grade").
   No camera move, tempo or length: the Photo API ignores them.
6. Count: a 1–4 segmented control in the bar (API count 1–4, default 4).
7. Prompt placeholder: "Describe the photo: the place, the pose, the mood. Use @ for a model." (no "she").
8. Phone: header and tabs, stage, panel scroll; prompt, pills and a full-width Generate stay fixed at the bottom.

Open questions for the owner
- Size/ratio: the Photo API has no aspect or size field (photos come out at the model's default). Add one (e.g.
  4:5, 1:1, 9:16) server-side first, or leave it out?
- Can Photo run with only a prompt (no character, no image)? The disabled reason assumes a character or a photo is needed.
- Model pill: show the picked image model (imageModel) or only "Auto"?
- "Use in Shot" on a result (start frame for a video): wanted?
