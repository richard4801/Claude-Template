# House style split (owner decision 2026-11-11)

Server commit aa4a87c2 (branch `claude/house-style-split`), merged into **`claude/server-bundle-2`** with outfit-faces
(already in prod cd34b11e) and swap-background @698778f (server only). In the bundle the Android prompt JSONs and the Mac
`prompt_scripts_fixture.json` are committed (regenerated once for all three), so the server suite is green. App code for
house style + swap background: `plans/patches/bundle-2-android.patch`, `plans/patches/bundle-2-mac.patch` (they replace
`house-style-split-*.patch` and `swap-background-apps.patch`).

Also in the bundle: a shoot scene typed as a sentence ("… at dusk.") no longer gives "Scene: … dusk.." (engine.ts
shootChoices drops its trailing full stop).

## What changed
- `style.house` (one block) → two owner-editable blocks in Settings → Prompts → Photo:
  - **Realism** `style.realism` (always on): "natural skin texture, true-to-life colour, no beauty filter, no AI gloss".
  - **Camera feel** `style.camera`: "realistic smartphone photo". Can be emptied.
- New prompt script **House style** (`style.house`, Settings → Prompts → Scripts): rule "Camera feel" fires only when
  `ownCamera` is off; rule "Realism" is locked. `{style}` in `shoot.style` / `template.style` = Camera feel + Realism.
- The shot "has its own camera" (Camera feel left out, its words stand) when:
  - Suite Photo rig (or its camera preset) sets a camera **body**, a **lens** character, a **look**, or a **palette** (grade).
    Focal length, aperture, shot size and light alone don't count.
  - A Photo preset (template) whose camera words aren't a phone's and name a film/cinema camera or lens, or whose style
    is cinematic (`templateOwnCamera`). Every starter template is a phone shot and keeps Camera feel.
  - NOT the old Photo tool's grade picker ("Warm film", "Muted"…): it isn't a rig, and counting it would change the
    prototype fixture and both apps' offline engines. Owner (2026-11-11): leave it as it is for now.
- Default grade "Phone-natural" (`shoot.default.grade`): with a camera of its own and no look/palette, no grade at all;
  the light line becomes `Light: {light}.` (new block `shoot.light.only`, rule `light.only` on input `noGrade`).
- Sheet fills, LoRA sets and outfit sets: always Realism + Camera feel (no rig there). The outfit edit / keep prompts
  have their own fixed "Realistic smartphone photo, natural skin texture." words (separate blocks, unchanged).
- Video Suite shots never used the house style (checked: suite/plan.ts builds from suite blocks only; test added).
- Migration: an owner's saved `style.house` is split on first read of her library: phrases about the phone
  (smartphone, phone, iPhone, mobile, selfie, camera roll, snapshot) → Camera feel, the rest → Realism, her words and
  order, same date and author; the old row is deleted. If every phrase was about the phone, Realism keeps its default.
- Previews: one sample set everywhere (her images 1–3, outfit 4, reference 5 guiding pose, look and scene;
  "Identity from 3 locked reference images"); `variants: [{id:'cinematic', label:'With a cinematic rig'}]`.

## App work (patches, untested here: no Android SDK / Swift toolchain in the session)
- Android: demo library builds the style from the two blocks (`FakePromptLibrary.houseStyle`); tests moved from
  `style.house` to `style.realism`; scripts count 15 (Dress up gone, House style added); collage sample line.
- Mac: `PromptEngine.cameraFeel` / `realism` (houseStyle = both), demo library entries `style.realism` + `style.camera`,
  `houseStyleText()` in the fake API, tests updated (fixture refIndex sample 5).
- UI to add later (both apps): show `variants` under the prompt preview ("With a cinematic rig").
