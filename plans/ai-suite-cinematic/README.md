# Cinematic AI Suite mocks (owner direction 2026-11-07), for approval

These mocks follow the owner's brief, relayed by the coordinator: "a real sleek design", in a dark, moody, image-led cinematic direction (Higgsfield is the reference for the feel, not something to copy).
- The app around the Suite stays exactly as it is today: the top bar, and the sidebar with Video suite and its tools, Templates, Queue and Library.
- Only the Suite pages change.

The mocks are rendered by `design/direction/cinematic.py`. File names are `<screen>-<width>-<theme>.png`:
- Mac at 1440 × 900 and 1280 × 800.
- Phone at 390.
- Theme `c` is Soft Tactile (the owner's) and `b` is Camera Body.

`overview-c.png` and `overview-b.png` show every screen on one page.

## Screens
1. **`1-shot`: the working state.**
   - **Stage:** the latest take, large and centred, with a vignette. Its colours spill into the UI as an ambient glow (a blurred copy behind everything).
   - **Floating glass dock:**
     - the input tiles (64 pt);
     - the prompt with the `@Zelphira` and `#Dolly in` chips;
     - the rig check, "A 24 mm lens on a close-up stretches the face", with Fix;
     - six tall image chips: Camera (body render), Lens (lens render), Light (lighting still), Look (still with a swatch strip), Style (genre still) and Move (loop poster). Lens shows the selection glow;
     - pills for quality, shape, length, sound and takes;
     - **Generate · $0.65** in the accent colour with a soft glow.
   - **Takes rail:** a running take at 62 % with an accent progress bar, then the takes. The take on the stage has the accent ring. The hovered take is lifted and shows its four actions plus More (28 pt).
2. **`2-empty`: before the first take.**
   - The stage is an empty cinematic frame: dark, with corner marks, a faint warm light leak and one line, "Your first take plays here".
   - The rig chips all read Auto, with the aperture mark.
   - Generate shows no price.
3. **`3-rig-style`: the Style picker** as a dark glass modal over the Suite.
   - Genre is an arc carousel (Epic in the centre, with the glow ring), with the era ruler (2010s) and the tempo choices (Slow) under it.
   - The rig tabs and the saved rigs sit at the top.
4. **`4-rig-camera`: the Camera picker** with the approved drums, exactly as the app draws them.
5. **`5-photo`: Photo mode.**
   - The stage shows the latest set: the picked photo large, with the other three beside it.
   - The dock has the photo inputs and five chips (no Move), with Generate · 4 photos · $0.46.
   - The rail is a two-column photo grid.
6. **`p1-shot` (phone):** the stage, a filmstrip of takes under it, and the glass dock. The chips scroll sideways, and Generate is full width.

## How it is built
- **The Suite is always dark:** near-black #0C0B0A with a faint static grain, whatever the app theme, like the camera bag.
- **Accent:** Camera Body uses its amber. Soft Tactile uses its moss lifted to #7FA36F so it reads on the dark (white text on the dark is well above AA, and the Generate label is dark on the accent).
- **Selection** is one kind of mark everywhere: an accent ring plus glow on the selected chip, take, genre and tempo.
- **Type:** sentence case, three sizes (17, 13 and 11) plus 15 for the prompt. No caps or mono.
- **Imagery is ours only:** the Blender preview stills (the café street at dusk, the mannequin set), the move loop posters, the hardware renders and the app's drums. There's no Higgsfield branding or assets.
- **Kept from the approved plan (function):**
  - tools as modes ("Shot ▾");
  - rig depth one click away (each chip opens its picker);
  - the rig check;
  - Generate pinned with its price;
  - takes with four actions plus More;
  - Presets and saved rigs.
- **Motion** (not visible in stills): cards lift on hover, the chip glow ring fades in, the stage cross-fades when the take changes, and only the hovered take plays. All of it is off under Reduce Motion.

## Slop check
- **No filler:** every chip opens its picker, every pill changes its setting, and there are no stats or decorative badges.
- **One filled button per screen** (Generate). Everything else is glass, ghost or outline.
- **The middle dot appears only in "Generate · price".** Values use commas ("Anamorphic, 24 mm"; "Epic, 2010s, slow").

## Known limits
- The preview stills are at most 640 px wide, so the large stage is slightly soft. Real takes will be sharp.
- The drums' labels read "35mm film" (the app's current label), while the chips read "35 mm film". They will be aligned when this is built.
