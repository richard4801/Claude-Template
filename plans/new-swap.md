# New Swap (beta): remix any video with toggles (design only, phase 1)

_Written 2026-11-12 by a worker for the coordinator (session_01Py2rxnkmRGDuxPcwi3us6Q). Nothing is built, called or
paid for. Prices come from `server/api/src/suite/registry.ts` (our table) and `plans/precise-edit.md` §1 (providers'
pages, read 2026-11-12). They are provider cost; members pay cost × the model's `priceScale` (default 1). Marked
**L** for listed and **E** for estimated. The owner approves this before any build._

## The owner's request (2026-11-12)
> "Remix an original video by re-uploading, pasting or selecting from Library without picking a model. Then I can
> toggle background change, outfit change, character change etc. (then I'll be prompted to add a character reference,
> or pick my model if that's the case). When any change is toggled, we don't need a complex prompt. Just the change we
> want from the toggle."

Decisions already made (coordinator brief): the old Swap stays as it is, with a header switch **Swap · New Swap
(beta)**; the name stays "Swap"; four toggles in v1; every change is redrawn by the model (no cut-out or composite);
MUSE writes the prompt from the toggles; the owner can pick any video model that takes a source video, and Auto
suggests one and says why; Claude can read and set everything, but a run needs Approve.

---

## Phase 3 (2026-11-12): every model on every mode, and Wan 3.0

**The owner's rule** (via the coordinator): "Every model in our app should be available on every mode. Doesn't matter. The only difference is that the default models are mostly on top of the list. We should be able to pick other models freely."
- No model is greyed out or refused in any picker.
- When a picked model can't take an input natively, MUSE adapts and says exactly what it did.
- A model is refused only when nothing at all can be sent, and then the reason is said.

### New Swap
Every video model is listed. Auto's order comes first, then the other edit models, then the ones MUSE adapts. Each model has a **route** (`suite/remix.ts` `routeOf`):

| Route | Models | What MUSE sends | The line shown (example) |
|---|---|---|---|
| edit | Wan 2.7 Edit, Kling O1/4.0, Seedance 2.5, Genjutsu (Light), H3 Max Recast, Wan 2.2 Animate | the clip itself | (none, or "has no Background control: MUSE asks for it in words") |
| reference | MiniMax H3 family (Replicate and Higgsfield), Wan 3.0 / Prime, Kling 3.0 Omni, Wan 2.7 | the clip as a reference video | "MiniMax H3 can't edit a video: MUSE sends your clip as a reference video, so the motion and framing follow it closely but not exactly" |
| frames | Veo 3.1 Lite, LTX-2.3, image-only models, BYO models with a start image or references | first/last frame, or 3 stills as references | "Veo 3.1 Lite can't take a video: MUSE sends 2 frames from your clip (the first, the last); the motion follows your words, so it will be approximate" |
| text | words-only models | words only | "… takes only words: your clip and pictures aren't sent, so the result won't follow the clip's motion" |

- **The v1 rule "Genjutsu/H3 need Character on" is dropped.** With Character off, MUSE sends a still of the clip's person: "Genjutsu Light puts a person from pictures into the clip: MUSE sends a still of the person from your clip so they stay themselves (their look may drift)".
- **Pictures that don't fit** are described in words.
- **Toggles a model has no control for** are asked for in words.
- **The runner extracts the frames and stills** from the trimmed part of the clip (`frameAt`). The clip's sound is put back on every route.
- **What still refuses:** a model whose provider isn't set up, one that is switched off, or an unknown id. The model pill shows these with the reason, as "unavailable".

### Every other mode (server)
- **Lists:** `GET /v1/engines?purpose=` gives every video model for every video purpose.
  - Order: the default first, then the ones made for it (`fit: "native"`), then the rest (`fit: "adapted"` with a one-line `fitNote`).
  - Image purposes already listed every image model.
  - Tools (matte, track, captions, noise, upscale) stay per job: a matte model can't caption.
- **Swap (classic)** on a non-swap model, or a **one-person Recast** on a non-Recast model, runs as a New Swap on that model with her as Character, and the warnings say so.
  - **A Recast with several people** on a model that can't tell people apart is the one refusal left there ("…can't tell several people in a clip apart · recast one person with it, or pick a Recast model"). Nothing coherent can be sent.
  - **The classic `/v1/jobs` swap pipeline** has no adapter: a picked non-swap model is told to generate from the AI suite's Swap.
- **Extend** on a model without its own extend: a frame bridge (its start frame), else the clip as a reference video, with "…has no extend of its own: MUSE continues from your clip's last frame, so the join may show". An edit-only or words-only model is refused with that reason.
- **Shot, Talking, UGC ad, Storyboard and Guide** on any model use the shot planner's existing "adapt, don't block". A model that only edits an existing video is refused: "edits an existing video: it can't make a shot from words or pictures · use it in Swap → New Swap".
- **Recreate fills:** a non-swap model asked to swap generates the slot on that model instead of being refused.
- **Studio defaults:** any video model can be the default for any video purpose.

### Wan 3.0 and Wan 3.0 Prime (built in, Higgsfield)
- **Registry:** `wan-3.0` and `wan-3.0-prime`, refs `alibaba/wan-3.0[-prime]/{text,image,reference}-to-video`, adapter `hf-wan3`.
  - Inputs: image_url / end_image_url for i2v; image_urls ≤ 10, video_urls ≤ 5 and audio_urls ≤ 5 for ref2v.
  - 2–30 s; 480p, 720p and 1080p.
- **Price: not available from here.** Higgsfield publishes no rate, and this session has no working Higgsfield key (the proxy's credential got "Invalid credentials"; the rules say no keys). So they are **priced live**: `livePrice`.
  - Each plan calls Higgsfield's free `POST /estimate/{ref}` with the server's own key, for that exact request (length, resolution, sound, the kind of input). The result is cached 10 minutes.
  - No quote means no run: "Wan 3.0 · Higgsfield has no price right now · try again in a minute, or pick another model".
  - The pickers show "Priced by the provider when you pick it".
- **They appear in every video picker,** but only once the server's Higgsfield key is set (as for all Higgsfield models).
- **In New Swap they take the clip as a reference video** (no video-edit endpoint).

### Apps (patches)
**Mac** (`plans/patches/new-swap-mac.patch`; MuseCore on Linux: 877 tests, 0 failures):
- `EngineCatalog.engines(for:)` no longer filters by purpose. It lists every model of the kind: default, then native, then adapted, MUSE's before the owner's providers.
- The `EngineEntry` model gains `fit`, `fitNote` and `livePrice`.
- The owner's model list (`EngineList`) shows the adapted line and "Priced by the provider when you pick it".
- `ComposerModelPicker.supports` no longer narrows Talking or UGC ad to models with a voice or picture slot. Those models come first; the rest follow with "Takes no voice track: MUSE writes the words to say in the prompt" or "Takes no product photo: MUSE describes the product in words".
- New Swap's model pill no longer greys a model for what it's made for (`pickable` = it can run), and shows each one's adapted line.

**Android** (`plans/patches/new-swap-android.patch`, which replaces the earlier fixtures-only patch and still holds the two regenerated demo files):
- `ModelPicker.groups` no longer filters by purpose: natives first, then adapted with a line.
- `SuiteCatalogEngine` gains `fit`, `fitNote` and `livePrice`.
- The model row shows the adapted line.
- `ModelChoiceTest` is updated.
- There is no Android SDK in this container, so the Android unit tests were not run here. Android's New Swap panel is still the next job, after Mac is green.

---

## Build (phase 2, 2026-11-12) — owner answers and what was built

**Owner answers (via the coordinator):**
1. **Wan 2.7 Edit is Auto's default for Background and Look & light.** Every other model stays pickable. Its one paid test is prepared but **not run** (below).
2. **A clip longer than the model takes is trimmed by the person first.** It is never cut silently. A trimmer (start and length) picks the part, and the price follows it.
3. **Character is her by default, under a strict figure lock.** Her face, hair and skin come only from her images, and her body only from her outfit's angles or her body shots. From the clip the model takes only the motion and facial gestures, never the body, face or figure of the person in it. Every remix prompt carries a figure-lock line, including the same-person and face-swap versions. **Someone else's photo is an optional face swap (face only).** It is clearly labelled and off by default.
4. **Mac first, Android after** Mac is green.

**Changes from the phase-1 design:**
- **Every New Swap model runs on the suite runner** (`suite/remix.ts` builds the plan, like Recast), Genjutsu included. A new `hf-genjutsu` input adapter writes the prompt in plain words ("image 1"). Paid-job recovery is the suite runner's own. The runner's Higgsfield → Replicate H3 move now applies only to the H3 adapter (`hf-h3`), so a Genjutsu remix never silently becomes another model.
- **The person's words sit in one line, `CHANGE: Background: … Outfit: … Look & light: …`.** Each toggle's own block says "as written under CHANGE". The reason: the prompt engine lets only one user section see user words, and keeps owner-editable system blocks free of them.
- **The Library pick copies a finished take to a clip** (`POST /v1/clips/from-take`), so deleting either one never touches the other. `GET /v1/clips/{id}` lets the app show a clip Claude picked.
- **H3 swap models are not New Swap models in v1.** They need a person picture and use reference video, not edit. Use the current Swap for them.

### Server (branch `claude/new-swap`)
| Piece | Where |
|---|---|
| Edit capabilities per model (`edit`: source seconds, max pictures, keeps sound, tested, what each toggle can do, needs her) | `suite/registry.ts` (Wan 2.7 Edit new; Kling O1, Kling 4.0, Seedance 2.5, Genjutsu, Genjutsu Light, H3 Max Recast, Wan 2.2 Animate) |
| Request: `mode: "remix"`, `remix {background, outfit, character, look}`, `range [from, to]` | `suite/plan.ts` (`RemixSchema`) |
| Auto order and reason, support check, pictures (one per toggle, then fill), trimmer, prompt, price | `suite/remix.ts` |
| Script `suite.remix` (Settings → Prompts → Scripts, "Swap · New Swap (beta)") and its 14 blocks | `suite/scripts.ts`, `suite/prompts.ts` |
| Planner hook, estimate's `remix` block, refusals (`remix_empty`, `remix_incomplete`, `remix_unsupported`, `remix_trim_needed`, `remix_too_short`), model pill | `suite/service.ts`, `POST /v1/suite/remix/models` |
| Trimmed part sent, clip's sound put back by stream copy | `suite/runner.ts`, `suite/extendMedia.ts` (`cutRange`) |
| Wan 2.7 Edit / Genjutsu / Seedance remix inputs | `suite/inputs.ts` |
| Library → clip; one clip by id | `routes/index.ts` (`POST /v1/clips/from-take`, `GET /v1/clips/:id`) |
| Claude: `suite_set_draft` `swapVariant`, `clipId`, `remix` (a toggle set to null turns it off), `range`; `suite_remix_models`; the estimate and Approve for New Swap; screen sync of the toggles | `suite/assist.ts`, `suite/mcpTools.ts`, `suite/screen.ts`, `suite/drafts.ts` (tool `remix`) |
| Skill §7b (both copies, identical) | `.claude/skills/muse-prompt-structure/SKILL.md`, `server/api/assets/skills/muse-prompt-structure.md` |
| Tests | `test/new-swap.test.ts` (16: unit and API on the mock provider), plus updated `suite-assist`, `claude-sessions` |

### Mac (`plans/patches/new-swap-mac.patch`, for the next Mac bundle)
- **MuseCore** `Suite/NewSwap.swift`: the draft, the request, what's missing, the kept line, Claude's sync, and the estimate and model-pill views. Also `remix`/`range` on `ShotRequest`, `remix` on `ShotEstimate`, `remix` as a draft tool, and demo-mode pricing. Tests are in `NewSwapTests` (7). **MuseCore was built and its whole suite run on Linux with Swift 6.0.3: 876 tests, 0 failures.**
- **App:**
  - `AppStore+NewSwap.swift`: the switch, estimate, generate, pictures, Library and trimmer.
  - `NewSwapPanel.swift`: the header switch, the panel, the trimmer, the Library picker and the model pill.
  - Changes in `ComposerView`, `ComposerBottomBar`, `SuiteClaudeBridge` and `AppStore+Suite`.
  - The app files pass `swiftc -parse`. SwiftUI can't be type-checked on Linux, so the Mac CI is their first full build.
- **The Mac prompt-scripts fixture** (`MuseCoreTests/Fixtures/prompt_scripts_fixture.json`) is in the same patch.

### Android (after Mac is green)
`plans/patches/new-swap-android.patch` (phase 3: also the picker changes) holds the regenerated demo copies, `prompt_library.json` and `prompt_scripts.json`.
**The server's fixture tests need these two patches applied** (Mac and Android). On `claude/new-swap` alone, `prompts.test.ts` and `prompt-scripts-fixture.test.ts` (3 tests) fail. Merge the server branch together with both patches. With them applied, `tsc` is clean and the full vitest is green. The Android panel itself is the next job.

### Wan 2.7 Edit's paid test (prepared, NOT run; needs the owner's OK)
One run, about **$1.00** (10 s × $0.10, 1080p, provider cost = member price at priceScale 1). The request, sent from the app as the owner on one of the owner's clips of 10 s or less:
```json
POST /v1/suite/shots
{ "mode": "remix", "clipId": "<the owner's clip, 2–10 s>", "engineModel": "wan-2.7-edit", "resolution": "1080p", "keepAudio": true,
  "remix": { "background": { "mode": "describe", "words": "a rooftop at golden hour, city lights behind her" } } }
```
Check after the run:
1. Replicate bills only the output seconds. If the input seconds are billed too, the registry price changes.
2. The clip's motion, face and figure are kept and only the place changed.
3. The sound is the clip's own.
4. Then set `edit.tested: true` for `wan-2.7-edit`, so the picker drops "not tested yet".

Seedance 2.5 in remix mode (`tested: false`) also needs one approved test before anyone relies on it; until then the picker says "not tested yet". Genjutsu, Genjutsu Light, Kling O1, Kling 4.0, H3 Max Recast and Wan 2.2 Animate are marked tested because they ran in Swap or Recast with the same input fields. Genjutsu now runs New Swap through the suite runner, though: its first New Swap run is worth watching.

---

## Part 1 · For the owner (plain language)

**What changes for you.** In Swap, a small switch at the top says **Swap | New Swap (beta)**. Old Swap is exactly as
today. New Swap starts with the video, not with a model:

1. **Add the video.** Upload it, paste a link, or pick it from your Library.
2. **Turn on what should change.** There are four switches: **Background**, **Outfit**, **Character** and **Look &
   light**. Each one you turn on opens one short box, and nothing else. Anything you leave off stays as it is in the clip.
3. **MUSE picks a model** and tells you why in one line, for example "Wan 2.7 Edit: background only, keeps the sound,
   1080p". You can pick any other video model that takes a video instead. Each model shows its limits (length,
   resolution, whether the sound is kept) and the true price, including the seconds of your clip that the provider
   also charges for.
4. **Generate.** The button shows the price.

**You never write a long prompt.** You only type the change, such as "a rooftop at golden hour" or "soft window light,
warm grade". MUSE adds the "keep everything else" lines itself. You can edit those lines in Settings → Prompts →
Scripts → **Swap · New Swap**.

**What a 10-second clip costs** (details in §8):

| Change | Model MUSE would suggest | Price |
|---|---|---|
| Background only | Wan 2.7 Edit · Replicate, 1080p | **≈ $1.00** |
| Her (character + outfit), with or without a new background | Genjutsu Light · Higgsfield, 720p | **$2.00** |
| Outfit only, or Look & light only | Kling O1 Edit · Replicate, 720p | **$1.26** |

**Honest limits.** These models redraw the whole picture, so nothing comes back pixel-identical, even the parts you
left switched off. Motion and timing are kept well; small changes to faces, hands and the parts you kept are possible.
That is the trade the owner chose ("nothing special"). The exact, untouched route is the parked Precise Edit plan.

### Questions for you
1. **Which model is first for Background only?** Wan 2.7 Edit (cheap, 1080p, keeps sound, 10 s maximum) or Kling O1
   Edit (already in MUSE, 10 s, a little dearer)? Wan 2.7 Edit isn't in MUSE yet: adding it is a small server job on
   Replicate, which is already connected. **Recommended: add Wan 2.7 Edit and make it first.**
2. **Clips over 10–15 s.** Most edit models stop at 10 or 15 s. Should New Swap offer to **use the first N seconds**
   (what Genjutsu does today), or ask you to trim in Edit first? **Recommended: use the first N seconds, shown on the
   price line ("uses 0:00–0:10 of 0:24").**
3. **Someone else's photo as Character.** The rule that her figure comes from her own images can't apply to a stranger.
   Is it OK that MUSE takes that person's face and figure from the one photo, and says so? **Recommended: yes.**
4. **Android at the same time as Mac,** or Mac first? **Recommended: same time.** It's one sheet on each, and most of
   the work is on the server.

---

## §1 Screen flow

### States
`empty` (no video) → `video picked` (toggles off; Generate disabled: "Turn on a change") → `toggles set` (each turned-on
toggle complete or showing its one missing thing) → `priced` → `running` (same queue and feed as today) → `take` (the
feed shows it, with "Reuse settings").

### Rules
- **No model or character is needed to start.** Character is asked for only when the Character toggle is on. Outfit
  "one of her outfits" asks for her only if Character is off, because the outfit belongs to a model.
- **One field per toggle.** Each toggle opens a single compact row with a segmented choice (when it has one) and one
  input. No other settings appear.
- **Anything not toggled is kept.** The source card says so under the toggles: "Kept from the clip: motion, camera,
  sound and everything you didn't switch on."
- **The model pill** in the bottom bar reads "Auto · Wan 2.7 Edit · Replicate" with a one-line why under the price.
  Opening it lists every source-video model with its limits and its price **for these toggles on this clip**. A model
  that can't do a toggle combination isn't hidden; it's greyed with the reason, e.g. "Takes 1 picture: your outfit has 7".
- **Header switch.** "Swap | New Swap (beta)" is a two-item segmented control at the top of the Swap screen. It is
  remembered per device (a per-viewer convenience) and stored in the draft, so Claude knows which one is on screen.
  Switching keeps both drafts: nothing is lost going back and forth.
- **Sound** is a bottom-bar pill as today ("Clip sound On/Off"). On by default; MUSE puts the clip's sound back by
  stream copy whatever the model returns (as the Genjutsu path does today).

### Mac (SwiftUI): text mockup
The Mac composer keeps its layout: the stage (media) on the left, the panel on the right, the bottom bar with pills and
Generate. New Swap changes only the right panel's content and the source on the stage.

```
┌─ Swap ──────────────────────────────────────────── [ Swap | New Swap (beta) ] ─┐
│                                                                               │
│  ┌──────────────────────────────┐   Source                                    │
│  │                              │   beach_walk.mp4  0:24  1080×1920   Replace │
│  │       (clip, playing)        │   Uses 0:00–0:10 with Wan 2.7 Edit          │
│  │                              │                                             │
│  │                              │   Background                         [ on ] │
│  │                              │     ( Describe | New photo )                │
│  │                              │     [ a rooftop at golden hour, city… ]     │
│  │                              │                                             │
│  │                              │   Outfit                             [ off ]│
│  │                              │   Character                          [ off ]│
│  │                              │   Look & light                       [ on ] │
│  │                              │     [ warmer, soft window light       ]     │
│  └──────────────────────────────┘                                             │
│                                     Kept from the clip: motion, camera, sound │
│                                     and everything you didn't switch on.      │
│                                                                               │
│ ─────────────────────────────────────────────────────────────────────────────│
│  Sound On   Auto · Wan 2.7 Edit · Replicate        $1.00   [ Generate · $1.00 ]│
│             Background and light only: keeps the sound, 1080p                  │
└───────────────────────────────────────────────────────────────────────────────┘
```

Empty state (no video yet). The stage is the drop target. One primary action:

```
│  ┌──────────────────────────────┐   Remix a video                             │
│  │                              │   Add the video you want to change. Then    │
│  │   Drop a video here          │   switch on what should change.             │
│  │   [ Upload ]  Paste link  Library │                                        │
│  └──────────────────────────────┘                                             │
```

Each toggle's row when it's on:

```
Background     ( Describe | New photo )
               Describe  → [ the new place, in a few words            ]
               New photo → [ Locations ▾ ]  or  Upload…   (thumbnail, name, ✕)

Outfit         ( Her outfit | Product photo | Words )
               Her outfit    → outfit grid of the chosen model (front image each). Needs her: "Pick her first" link
                               if Character is off and no model is chosen.
               Product photo → Upload…  (one picture)
               Words         → [ e.g. a black linen two-piece           ]

Character      ( Her | Someone else )
               Her          → model picker (faces). Shows "Sends 7 outfit pictures" when Outfit = Her outfit.
               Someone else → Upload a reference photo…  "Their face and figure come from this photo."

Look & light   [ time of day, light, colour grade, e.g. "night, neon, teal grade" ]
```

Mac conventions: a toolbar segmented control for the switch, toggles are standard `Toggle` switches, tooltips on every
icon-only button, ⌘↩ to Generate as today, drag-and-drop of a file or a link onto the stage.

### Android (Compose): text mockup
Same order as a vertical sheet over the clip. The bottom bar is pinned. 48 dp targets.

```
┌──────────────────────────────────┐
│ ←  Swap        [Swap|New (beta)] │
│ ┌──────────────────────────────┐ │
│ │        (clip, 9:16)          │ │
│ │                              │ │
│ └──────────────────────────────┘ │
│ beach_walk.mp4  0:24      Replace │
│ Uses 0:00–0:10                    │
│                                  │
│ Background                 [●  ] │
│  [Describe][New photo]           │
│  ┌────────────────────────────┐  │
│  │ a rooftop at golden hour…  │  │
│  └────────────────────────────┘  │
│ Outfit                     [  ○] │
│ Character                  [  ○] │
│ Look & light               [●  ] │
│  ┌────────────────────────────┐  │
│  │ warmer, soft window light  │  │
│  └────────────────────────────┘  │
│ Kept: motion, camera, sound and  │
│ everything you didn't switch on. │
├──────────────────────────────────┤
│ Sound On  Auto · Wan 2.7 Edit  ▾ │
│ [      Generate · $1.00       ]  │
└──────────────────────────────────┘
```

On a narrow phone the header switch shortens to "Swap | New". Back goes from a toggle's picker sheet to the panel,
then out of Swap. Empty state: the clip area shows "Add a video" with Upload, Paste link and Library (the existing
clip sheet, `ComposerSheets.kt`, reused).

Design-review checks (muse-design-review): one primary action (Generate); no icons inside circles, no sparkles; plain
sentence-case copy; the model always shown as the server's "Model · Provider" label; prices never truncated; designed
empty, loading (skeleton for the source card while the clip uploads), error ("This clip is 3 s; Kling O1 needs at
least 3 s. Pick a longer clip.") and offline states.

---

## §2 Toggle → prompt block

### How the prompt is built
A new script **`video.remix`** in Settings → Prompts → Scripts (`prompt/scripts/defs.ts`), in the same format as
`video.replicate` and `video.edit`. Its sections, in order:

1. **Head** (one line, always): `Edit <Video 1>. Change only what is listed below.`
2. **One block per toggle that is on**, each owner-editable, with the user's words put in as `{words}`.
3. **Keep lines** (always): one line naming what stays, built from the toggles that are **off**.
4. **Never-add** (`never.base`, as everywhere).

Each model then gets the prompt in its own dialect, the same way the current code does it: H3 and Kling take
`<Image n>` and `<Video 1>` tokens; Genjutsu takes "image n" and "the source video" (`genjutsuInput` already rewrites
these); Wan 2.7 Edit takes plain words plus one reference.

### Blocks (defaults; owner-editable)
| Block id | Used when | Default text |
|---|---|---|
| `remix.head` | always | `Edit <Video 1>. Change only what is listed below; everything else stays exactly as in the video.` |
| `remix.background.describe` | Background = Describe | `BACKGROUND: replace the place with {words}. Same camera, framing and timing; the person and their movement stay where they are.` |
| `remix.background.photo` | Background = New photo | `BACKGROUND: replace the place with the place in <Image {n}>. Same camera, framing and timing.` |
| `remix.outfit.set` | Outfit = Her outfit | `OUTFIT: she wears the outfit shown in <Image {a}>–<Image {b}> (front, ¾, side, back and close-ups), exactly, including its hair, make-up and accessories.` |
| `remix.outfit.product` | Outfit = Product photo | `OUTFIT: the person wears the garment in <Image {n}>, fitted to their body and movement.` |
| `remix.outfit.words` | Outfit = Words | `OUTFIT: the person wears {words}.` |
| `remix.character.model` | Character = Her | `PERSON: the person in <Video 1> becomes {name} from <Image 1>–<Image {k}>: her face, hair, skin and exact figure and proportions from her images, unchanged. Only the motion and expressions come from <Video 1>.` (the Figure lock rule) |
| `remix.character.photo` | Character = Someone else | `PERSON: the person in <Video 1> becomes the person in <Image {n}>: their face, hair and figure from that photo. Only the motion and expressions come from <Video 1>.` |
| `remix.look` | Look & light on | `LOOK & LIGHT: {words}. Relight the whole scene to match; do not change anything else.` |
| `remix.keep` | always | `KEEP: {kept}; the motion, timing, camera moves, framing and crop; any on-screen text is removed.` where `{kept}` lists the toggles that are off: "the same person", "their outfit", "the background", "the light and colour". |

A **Look & light** block on its own with Background off still says "relight"; the keep line holds the place. If the
member's words contain place words (`placeWords`) while Background is off, the existing warning and fix are reused:
"Your look words describe a new place. Turn on Background?"

### Examples
**A. Background only (Describe "a rooftop at golden hour, city lights behind her")**, on Wan 2.7 Edit:
```
Edit the video. Change only what is listed below; everything else stays exactly as in the video.
BACKGROUND: replace the place with a rooftop at golden hour, city lights behind her. Same camera, framing and timing; the person and their movement stay where they are.
KEEP: the same person, their outfit, the light and colour; the motion, timing, camera moves, framing and crop; any on-screen text is removed.
Never add: logos, extra fingers, warped jewellery.
```

**B. Character = Her (Lena) + Outfit = Her outfit "Linen set" + Background = New photo (Lisbon street)**, on
Genjutsu Light (8 pictures: face front, face profile, outfit front, ¾, side, back, outfit face close-up, background):
```
Edit the source video. Change only what is listed below; everything else stays exactly as in the video.
PERSON: the person in the source video becomes Lena from image 1–image 2: her face, hair, skin and exact figure and proportions from her images, unchanged. Only the motion and expressions come from the source video.
OUTFIT: she wears the outfit shown in image 3–image 7 (front, ¾, side, back and close-ups), exactly, including its hair, make-up and accessories.
BACKGROUND: replace the place with the place in image 8. Same camera, framing and timing.
KEEP: the light and colour; the motion, timing, camera moves, framing and crop; any on-screen text is removed.
Never add: logos, extra fingers, warped jewellery.
```

**C. Outfit = Product photo + Look & light "night, neon, teal grade"**, on Kling O1 Edit:
```
Edit <Video 1>. Change only what is listed below; everything else stays exactly as in the video.
OUTFIT: the person wears the garment in <Image 1>, fitted to their body and movement.
LOOK & LIGHT: night, neon, teal grade. Relight the whole scene to match; do not change anything else.
KEEP: the same person, the background; the motion, timing, camera moves, framing and crop; any on-screen text is removed.
Never add: logos, extra fingers, warped jewellery.
```

### Pictures sent (order and caps)
Character pictures first (face front, face profile; with Outfit = Her outfit, her body comes from the outfit's angles
as today's figure lock does), then outfit pictures (the outfit's 7 pictures), then the product photo or the someone-else
photo, then the background photo last. If a model takes fewer, MUSE trims from the least needed (the outfit's face
close-ups first, then the ¾ and side) and the sent-images row says what was left out, as `images/sent.ts` does today.
Members can still change the list (Sent images: replace, add, drop).

---

## §3 Models per toggle combination

What each model is for here (sources: `registry.ts`, `SWAP_ENGINES`, precise-edit §1). "In MUSE" means it's in the
registry now; **new** means it needs an entry; BYO means owner-added models (their declared inputs decide).

| Model · provider | In MUSE | Source length | Resolution | Pictures | Sound kept | $/s (720p / 1080p) |
|---|---|---|---|---|---|---|
| Genjutsu Light · Higgsfield | yes (swap) | 4–15 s (first 15) | 480p–1080p, 9:16 | 1–8 | MUSE puts it back | $0.20 / $0.40 (output + input billed) **L** |
| Genjutsu · Higgsfield | yes (swap) | 4–30 s | 480p–1080p, 9:16 | 1–8 | MUSE puts it back | $0.3446 / $0.8346 **L** |
| Genjutsu Object swap · Higgsfield | yes (Edit helper) | 4–30 s | 480p–1080p | 1–8 | MUSE puts it back | $0.3446 / $0.8346 **L** |
| Genjutsu Restyle · Higgsfield | yes (Edit helper) | 4–30 s | 480p–1080p | ≤ 5 + preset | yes | $0.681 / $1.632 **L** |
| MiniMax H3 / H3 Lite · Replicate | yes (swap) | 5–15 s | 768P / 2K | ≤ 9 | new audio (MUSE puts it back) | $0.08 (768P) / $0.13 (2K) **L** |
| MiniMax H3 · Higgsfield | yes (swap) | 5–15 s | 2K | 5 incl., +$0.08 each | MUSE puts it back | $0.065 (2K) **L** |
| H3 Max Recast · fal | yes (recast) | 5–30 s (15 per shot) | 768P / 1080P | 1 per person | yes | $0.30 / $0.45 **L** |
| Kling O1 Edit · Replicate | yes (recast) | 3–10 s | 720p / 1080p | ≤ 4 | `keep_audio` | $0.126 / $0.168 (with video) **L** |
| Kling O3 Edit · fal / Higgsfield | **new** (or BYO) | 3–15 s | std / pro | ≤ 4 | `keep_audio` | $0.126 / $0.168 (fal) **L**; Higgsfield not listed |
| Wan 2.7 Edit · Replicate | **new** | 2–10 s | 720p / 1080p | 1 | yes (`origin`) | $0.10 / $0.10 **L** |
| Seedance 2.5 Edit · Replicate | yes (as 2.5; edit **new**) | 4–30 s | 480p / 720p | ≤ 30 | new audio only | $0.43 (480p) / $0.97 (720p) with video **L** |
| Runway Aleph 2 · Replicate | **new** | 2–30 s, < 16 MB | to 1080p | ≤ 5 keyframes | not stated | $0.336 **L** |
| Wan 2.2 Animate Replace · Replicate | yes (recast) | 1–30 s | 480p / 720p | 1 | yes | $0.02 / $0.05 **L** |
| Wan VACE · fal / Replicate | BYO only (v1) | ~8 s per window | 720p max | several | no | ≈ $0.19 per real second at 30 fps **E** |
| BYO video models with a video input | as added | declared | declared | declared | declared | declared |

### Which models can do which combination
✓ = designed for it, ○ = can do it with the prompt (instruction editors redraw everything; works, less reliable),
✗ = can't (greyed in the picker with the reason).

| Toggles on | Genjutsu / Light | Object swap | Restyle | H3 family | H3 Max Recast | Kling O1/O3 Edit | Wan 2.7 Edit | Seedance 2.5 Edit | Aleph 2 | Wan Animate | **Auto picks** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Background | ✗ ¹ | ✗ | ✗ | ✗ ¹ | ✗ | ✓ | ✓ | ✓ | ✓ | ✗ | **Wan 2.7 Edit** (≤ 10 s), else Kling O1 (≤ 10 s), else Aleph 2 (≤ 30 s) |
| Outfit | ✗ ¹ | ○ ² | ✗ | ✗ ¹ | ✗ | ✓ (≤ 4 pics) | ○ (1 pic) | ✓ (all 7) | ○ | ✗ | **Kling O1** (4 body angles), else Seedance 2.5 Edit when all 7 pictures matter |
| Character | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ | ○ | ✓ | ○ | ✓ | **today's Swap Auto** (studio Swap default; else the Recast ladder) |
| Character + Outfit | ✓ | ✗ | ✗ | ✓ | ✓ (1 pic) | ✓ (4) | ✗ | ✓ | ✗ | ✗ | **Genjutsu Light** (≤ 15 s) / **Genjutsu** (≤ 30 s) |
| Character + Background (± Outfit) | ✓ | ✗ | ✗ | ○ | ✗ | ○ | ✗ | ✓ | ✗ | ✗ | **Genjutsu Light** (today's Auto rule) |
| Look & light | ✗ ¹ | ✗ | ○ ³ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ (best relight) | ✗ | **Wan 2.7 Edit**, else Aleph 2 |
| Background + Look | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✗ | **Wan 2.7 Edit** |
| Outfit + Background (± Look), same person | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ (4 pics) | ○ | ✓ | ○ | ✗ | **Kling O1**, else Seedance 2.5 Edit |
| All four | ✓ | ✗ | ✗ | ○ | ✗ | ○ | ✗ | ✓ | ✗ | ✗ | **Genjutsu** / Light |

¹ Genjutsu and the H3 swap prompts put a new person into the clip from pictures: with Character off they would need a
picture of the clip's own person. v1 doesn't do that (it would invent an identity from a frame grab). Marked "needs
Character on".
² Object swap is "an object becomes the one in the pictures"; clothes aren't named in Higgsfield's docs. Allowed for the
owner's test, marked "not tested on clothes".
³ Restyle needs one of Higgsfield's presets; Look & light words go in its prompt. Allowed, marked "uses a preset".

**Auto's why line** is chosen by the server from the combination, e.g. "Background only: Wan 2.7 Edit keeps the sound
and goes to 1080p (10 s maximum)" or "Her + outfit + new place: Genjutsu Light (same moves, new look; first 15 s)". If
the first choice can't take this clip (length, provider off, out of credit) Auto falls to the next one and says so.
Auto never picks a model above the studio's per-job cap; it says "cheapest that fits: … over your cap".

**Length.** The picker shows each model's "Uses 0:00–0:NN of 0:24". By default, a model that stops short of the clip
uses the first N seconds (owner question 2).

---

## §4 How old and new Swap share code

Server (one path, one queue):
- **New internal tool id `remix`** (drafts `TOOLS`, `ShotRequest.mode`), shown as "Swap" everywhere. Old Swap keeps
  `swap` and `recast` untouched. Nothing in `swapRequest`, `swapEstimate` or `video.replicate` / `video.edit` changes.
- **Shared**: clip resolution and checks (`clips`, `imports`, uploads), images-sent (`images/sent.ts`,
  `jobs.swapReferences` ordering for her and her outfit's 7 pictures), the figure lock, `genjutsuInput`, the Higgsfield
  and Replicate lines with paid-poll recovery (`hf-job-lost`), sound put-back by stream copy, queue, feed, "Reuse
  settings", spend caps, `price_confirm`.
- **When Character is on and the picked model is a swap engine** (Genjutsu, Light, H3 family), the remix is run
  **through the existing swap job** (`jobs.create` with `swapEngine`), with the `video.remix` prompt in place of the
  swap script's text. This reuses the proven Genjutsu path, including paid-job recovery.
- **Every other model** (Kling O1/O3, Wan 2.7 Edit, Seedance Edit, Aleph, BYO) runs through the **suite runner** like
  Recast does today (`suite/recast.ts` pattern): a new `suite/remix.ts` builds the `ShotPlan` (kind `edit`, the source
  video as `<Video 1>`, the pictures, `billedSeconds` with the video input).
- **Registry**: a new mode flag `modes.edit` and an `edit` block on each model (`sourceSeconds`, `maxImages`,
  `keepsAudio`, `combos` it supports). Adapters: Kling O1 (`kling-o1`, exists; add `keep_audio`, prompt-only edit),
  Wan 2.7 Edit (`wan-2.7`, new ref `wan-video/wan-2.7-videoedit`), Seedance 2.5 (`seedance`, video input exists),
  Aleph 2 (new adapter, small), Kling O3 (fal adapter or BYO). Genjutsu Object swap and Restyle are reused from
  `editor/genjutsu.ts` as remix runners (same input builder, same prices).

Apps:
- **One Swap screen, two panels.** The header switch picks the panel. The stage, bottom bar, price/Generate, feed,
  clip picker (upload / paste link / Library) and model pill are shared. Mac: `ComposerView` with a new
  `RemixPanel.swift`; `SwapDraft` gains nothing, a new `RemixDraft` sits beside it in `AppStore+Suite.swift`. Android:
  a new `RemixPanel.kt` in `suite/composer/`, a `RemixDraft` in `SuiteModel.kt`, the clip sheet in `ComposerSheets.kt`
  reused.
- **Model pill** (`OwnerModelPill` / `ModelPicker.kt`) gets purpose `remix`; the server returns the list with each
  model's support for the current toggles, its limits and its price for this clip.

---

## §5 API changes

1. **`POST /v1/suite/shots`** (and `dryRun`) accepts `mode: "remix"` with:
   ```jsonc
   {
     "mode": "remix",
     "clipId": "clip_…",                       // the source (required)
     "remix": {
       "background": { "mode": "describe", "words": "a rooftop at golden hour" }
                   | { "mode": "photo", "image": { "asset": "…" } | { "url": "…" }, "name": "Lisbon street" },
       "outfit":     { "kind": "outfit", "outfitId": "of_…" }
                   | { "kind": "product", "image": { … } } | { "kind": "words", "words": "…" },
       "character":  { "kind": "model", "modelId": "md_…" } | { "kind": "photo", "image": { … } },
       "look":       { "words": "night, neon, teal grade" }
     },                                          // a toggle absent = kept from the clip
     "engineModel": "wan-2.7-edit",             // optional; absent = Auto
     "resolution": "1080p", "keepAudio": true, "takes": 1,
     "useSeconds": [0, 10]                      // optional; default: from 0 to the model's maximum
   }
   ```
   Errors are plain and specific: `remix_empty` ("Turn on a change"), `remix_incomplete` ("Background · Describe:
   write the new place"), `remix_unsupported` ("Wan 2.7 Edit takes 1 picture: your outfit has 7. Pick Kling O1 or
   Seedance 2.5 Edit"), `remix_needs_model` ("Her outfit: pick her first"), the existing `price_confirm`, caps and
   `engine_unavailable`.
2. **The estimate** returns `{ engine: { model, label: "Model · Provider", source: "auto" | "picked", why }, uses:
   { from: 0, to: 10, of: 24 }, billedSeconds: { output: 10, input: 10 }, estimate, priceLine, sentImages, prompt
   (the built prompt, read-only preview), warnings, fixes }`.
3. **`GET /v1/engines?purpose=remix&clipId=…&toggles=background,look`** (the model pill): every source-video model
   with `limits` (source seconds, resolutions, max pictures, sound kept), `supports: "yes" | "prompt" | "no"` + `reason`,
   and the price for this clip. Members see the same list (4c: model choice for everyone).
4. **`POST /v1/clips/from-asset`** `{ asset }` → a clip from a Library video (server-side copy, no re-upload), so
   "pick from Library" works for finished takes and exports and not only for imported clips. (If an equivalent already
   exists in the apps' Library picker, reuse it; to verify at build time.)
5. **Drafts** (`suite/drafts.ts`): tool `remix` with the `remix` object and the header choice (`swapVariant: "classic" |
   "remix"`), stored with the job for "Reuse settings".
6. **Prompts**: script `video.remix` (blocks in §2) in `prompt/scripts/defs.ts`; the Settings preview renders example
   A–C. Regenerate the fixtures (`gen-shoot-fixture.ts`, `gen-prompt-scripts.ts`) as the checks require.
7. **No migration needed.** Drafts and job requests are JSON.

---

## §6 Claude tools

- **`suite_get_draft`** / screen sync (`suite/screen.ts`): for tool `remix`, `screenSettings` reports
  `variant: "new swap"`, the source (name, length, `suite_see {input}` for the clip), each toggle (on/off, its choice,
  words, picture name with its input number) and the model (Auto + why, or the picked one).
- **`suite_set_draft`** gains `swapVariant` (`classic` | `remix`) and `remix` (the same object as the API; a toggle set
  to `null` switches it off). `clipId` sets the source. The owner sees it live, as today.
- **`suite_estimate`** prices the remix (shows the built prompt, why, uses-seconds and the billed seconds).
- **`suite_request_shot`** without `confirm` returns the price; with `confirm` it queues an **Approve** card in the app.
  Nothing runs without the owner's tap (unchanged rule).
- **`suite_models`** with `purpose: "remix"` returns the §5.3 list, so Claude can explain "why this model".
- **Skill update** (`.claude/skills/muse-prompt-structure/SKILL.md` and the server copy, kept identical): a **§7b New
  Swap** section: "write only the change for each toggle; never a full skeleton; never describe her or her outfit;
  turn on the toggle instead of describing a change in another toggle's box; say which model Auto picked and why."
- `assist.ts` intent: when the person asks "change the background of this video" while New Swap is on, Claude switches
  Background on with `describe` instead of writing it in Look & light (the same fix pattern as `background:describe`).

---

## §7 Build order (after approval)

1. Server: registry `edit` blocks + Wan 2.7 Edit entry; `suite/remix.ts` (plan + prompt + Auto); `video.remix` script;
   estimate and engines endpoints; drafts; screen sync; Claude tools; tests in the mock provider (no spend). One owner-
   approved paid test per new adapter (≈ $1 each), not before.
2. Mac panel + switch (one mac-bundle branch, by the bundle integrator).
3. Android panel + switch (android bundle).
4. Skill §7b, both copies.

---

## §8 Prices: a 10 s clip on three representative models

Provider cost = member price at `priceScale` 1. The source seconds billed are shown because three of these providers
charge for the input video too.

| Model · provider | Toggles it suits | Resolution | Billing | Output s | Input s billed | **10 s clip** |
|---|---|---|---|---|---|---|
| **Wan 2.7 Edit · Replicate** | Background, Look & light (± a product photo) | 1080p (same price at 720p) | $0.10 per output second **L** | 10 | 0 ⁴ | **$1.00** |
| **Genjutsu Light · Higgsfield** | Character (+ Outfit, + Background) | 720p | $0.10 per second of output **and** input **L** | 10 | 10 | **$2.00** (1080p $4.00; 480p $1.00) |
| **Kling O1 Edit · Replicate** | Outfit (4 pictures), Look & light, Background | 720p | $0.126 per output second with a video in **L** (input priced into the rate) | 10 | in the rate | **$1.26** (1080p $1.68) |

For comparison (same 10 s clip): Genjutsu 720p $3.45 (billed per source second, first 30 s); H3 Max Recast · fal
768P $3.00; Runway Aleph 2 $3.36; Seedance 2.5 Edit 720p $9.68 (480p $4.30); Wan 2.2 Animate 720p $0.50; H3 ·
Higgsfield 2K $0.65 + $0.08 per picture past 5.

⁴ Replicate's Wan 2.7 Edit page lists one per-second price and no input charge (precise-edit §1); confirm on the first
test run's invoice line before showing it as final.

Clips above a model's maximum use the first N seconds, so a 24 s clip on Wan 2.7 Edit is still priced at 10 s and the
picker says "Uses 0:00–0:10 of 0:24".

---

## §9 Risks

1. **Everything is redrawn.** Kept parts drift (faces, hands, text, small objects). The UI says it once, in the help
   text, and the precise route stays parked. Mitigation: the keep line, and Auto preferring models that keep the most.
2. **Character off on swap engines.** Genjutsu and H3 need a person picture; v1 refuses those combos (greyed with the
   reason) rather than inventing one from a frame grab.
3. **Outfit with 7 pictures on 4-picture models.** Kling O1/O3 get 4 (front, ¾, side, back); the face close-ups are
   left out and said so in Sent images. Hair and make-up from the close-ups may not carry. Seedance takes all 7 but is
   ~8× the price and 720p at most.
4. **Instruction editors ignore a toggle** (e.g. change the outfit and also the background). Not detectable cheaply in
   v1. The feed's "Reuse settings" and a retry on another model are the fix. A later check could compare frames.
5. **Length caps (10–15 s)** surprise owners with longer clips. Shown on the price line before running.
6. **New adapters are untested** (Wan 2.7 Edit, Aleph 2, Kling O3, Seedance edit mode). Each needs one paid test,
   owner-approved; until then they show "not tested yet" in the picker.
7. **Price drift.** Higgsfield's Kling O3 and Seedance edit prices aren't published; they stay BYO-priced or hidden
   until read. Prices are re-read at build time; model versions are pinned.
8. **Someone else's photo.** Consent and likeness: the screen says "Use a photo of someone who agreed to this", the
   same as the studio's existing reference-photo wording. Figure lock doesn't apply to them (owner question 3).
9. **Prompt edits by the owner** (Settings → Scripts) can break the keep lines. The preview shows examples A–C live,
   and "Reset to default" exists per block.
10. **Two Swaps confuse members.** The switch is labelled "(beta)" and remembered. Once New Swap is approved, the owner
    decides whether old Swap goes away.
11. **Railway 512 MB.** The sound put-back is stream copy (low memory), as today; no compositing is added.
12. **Content filters.** Refusals on edit models follow today's messages (`REFUSED_CLIP` / `REFUSED_PAID`); paid-job
    recovery covers both lines.
