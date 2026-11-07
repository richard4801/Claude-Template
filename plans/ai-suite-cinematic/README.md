# Cinematic AI Suite mocks (owner direction 2026-11-07), for approval

These mocks follow the owner's brief, relayed by the coordinator: "a real sleek design", in a dark, moody, image-led cinematic direction (Higgsfield is the reference for the feel, not something to copy).
- The app around the Suite stays exactly as it is today: the top bar, and the sidebar with Video suite and its tools, Templates, Queue and Library.
- Only the Suite pages change.

The mocks are rendered by `design/direction/cinematic.py`. File names are `<screen>-<width>-<theme>.png`:
- All four themes (a Editorial, b Camera Body, c Soft Tactile, d Creator Pop): every Mac screen at 1440 × 900, plus the phone at 390.
- Soft Tactile (the owner's theme) also at 1280 × 800.

Each image includes the existing sidebar, so the fit with the shell is visible.

- `themes-shot-1440.png` puts the Shot screen side by side in the four themes.
- `overview-<theme>.png` shows every screen of one theme on one page.

## It comes from the theme, not a separate skin (owner: "make sure it doesn't clash with our existing theme")
The Suite is each theme's own "dark room". Every colour is a darker or lighter shade of that theme's tokens, so no new hues are added. The derivation is `room()` in `design/direction/cinematic.py`.
- **Editorial:** its ink black, warmed a touch by its red. Red marks selection, and Generate is red with cream text.
- **Camera Body:** its own dark, with amber.
- **Soft Tactile:** a deep olive charcoal mixed from its ink and its sage. The sage is lifted for the selection mark and Generate, with ink text.
- **Creator Pop:** its ink deepened with its cobalt, with the pink as the mark and on Generate, and ink text.
- **Glass and text:** the dock's glass is tinted with the theme's surface colour, and text on the stage is the theme's light surface colour.
- **Fonts, radii and accent** are the theme's own. The room's corner follows the theme's container radius, capped at 20: Editorial stays nearly square.
- **The edge:** the sidebar and top bar stay exactly in their theme. The Suite is a rounded room set 8 pt into the shell, with a hairline of its own light, and a soft inner shadow along its top and left edges, so the transition is intentional rather than a hard seam.
- **Pickers** use the same room tone, so the pickers and the stage match. The drums inside keep the camera-bag palette.

### Contrast, checked per theme (WCAG: text 4.5:1, marks 3:1)
| Theme | Stage tone | Text on stage | Muted text | Generate label | Selection mark | Warning |
|---|---|---|---|---|---|---|
| Editorial (a) | #1C1211 | 16.9:1 | 7.4:1 | 6.3:1 | 3.8:1 | 8.9:1 |
| Camera Body (b) | #0D0E0F | 16.1:1 | 7.0:1 | 9.3:1 | 9.7:1 | 11.5:1 |
| Soft Tactile (c) | #202721 | 13.4:1 | 6.4:1 | 6.3:1 | 5.6:1 | 7.4:1 |
| Creator Pop (d) | #0F1634 | 17.7:1 | 7.8:1 | 8.0:1 | 7.5:1 | 8.7:1 |


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
- **The Suite is each theme's dark room** (see above), with a faint static grain.
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
