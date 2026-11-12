# New Swap screen and the take viewer (design only, 2026-11-12)

_A worker wrote this for the coordinator (session_01Py2rxnkmRGDuxPcwi3us6Q) on the branch `claude/design-swap-viewer`. It covers the owner's requests A (New Swap as its own screen) and B (one real viewer wherever a take or image is shown). This is a plan with mockups: no app code changes, and nothing is built until the owner approves. It follows `plans/design-direction.md` and the muse-design-review skill. The mockups use Camera Body (B) for the dark theme and Editorial (A) for the light one._

Mockups: `plans/design/swap-viewer/*.png`. To regenerate them:

```
PHOSPHOR=<npm pack @phosphor-icons/core@2.1.1, unpacked> python3 design/swap-viewer/render.py
```

The script uses Playwright and Chromium and reuses the tokens, fonts and icon helper from `design/direction/render.py`. The imagery is 9:16 crops of the Blender preview stills, stored in `design/swap-viewer/assets`.

| File | What it shows |
|---|---|
| `newswap-mac-empty-dark.png`, `newswap-mac-empty-light.png` | New Swap before a video is picked: the Library grid on the stage, Character already on |
| `newswap-mac-filled-dark.png`, `newswap-mac-filled-light.png` | A clip picked and trimmed, three switches on, priced |
| `newswap-mac-models-dark.png` | The model list open: Auto, then the models in groups, each with its price for this clip |
| `newswap-mac-states-dark.png` | The stage while the clip uploads, while generating, after a failure, and when done |
| `newswap-android-empty-dark.png`, `newswap-android-filled-light.png` | Android, phone width 390 |
| `viewer-mac-tiktok-dark.png` | A portrait take in the phone frame with the TikTok layout drawn over it, and the action rail beside it |
| `viewer-mac-reels-zones-light.png` | The same take with the Reels layout and safe zones on |
| `viewer-mac-clean-noframe-dark.png` | Clean, with no device frame: the portrait take in its own 9:16 frame, showing the seek readout "+3 s 0:07 / 0:10" |
| `viewer-mac-clean-phone-light.png` | Clean, inside the phone frame |
| `viewer-skins-dark.png`, `viewer-skins-light.png` | One take shown five ways: Clean, TikTok, Reels, Shorts, Facebook, with safe zones on |
| `viewer-mac-landscape-laptop-dark.png` | A landscape take in the laptop frame with the YouTube layout, and the actions in a row underneath |
| `viewer-android-dark.png` | The phone viewer: a double-tap on the right side skips forward (+6 s after two taps), with the time readout and the action row |

---

## 1. Inspiration (looked at 2026-11-12)

**Remix and edit flows**
- **Runway Edit Studio (Aleph 2.0):** you upload a clip first, the model changes only what you ask for, and "everything you didn't ask to change" is kept. We take the same order for New Swap: source first, then only the changes. Runway shows a preview of the change before the paid run. We don't (see open question 6).
  Sources: runway.com/news/introducing-aleph-2-and-edit-studio and help.runwayml.com/hc/en-us/articles/51683104370451
- **CapCut and Final Cut Pro trimming:** a filmstrip with two handles, where the dimmed area outside the handles is the part that's not used. We use this as the New Swap trimmer and drop today's two sliders ("Start" and "Length").

**Social preview and safe-zone tools.** These overlay a generic version of each platform's interface on a 9:16 frame, with a switch per platform. That's the model for "Preview as".
- Tella's "social safe zones" switch (Reels, TikTok, Shorts, LinkedIn): tella.com/help/editing/social-safe-zones
- Flixier: flixier.com/help/safe-zones-for-social-media
- Checker tools:
  - pallyy.com/tools/safe-zone-checker
  - bundle.social/tools/safe-zone-checker
  - upload-post.com/tools/safe-zone-checker
  - poster.ly/tools/safe-zone-checker
  - producthunt.com/products/overlaycheck
- The iOS app Previewly: apps.apple.com/app/id6748048131

**Safe-zone numbers** vary from source to source, and the platforms publish them only for ads:
- reap.video/blog/short-form-video-safe-zones
- adaptlypost.com/blog/social-media-safe-zones-2026-complete-guide
- postiz.com/blog/vertical-video-dimensions

The common, conservative rule is to keep faces and text inside a centred box of about 850–900 × 1,100–1,400 px on a 1080 × 1920 frame. Our zones are labelled "approximate" in the app, and the numbers live in one table on the server (§B4), so they can change without an app update.

**Player shortcuts**
- **Final Cut Pro** (support.apple.com/guide/final-cut-pro/ver1632c98e/mac): J/K/L shuttle, and ← and → step one frame.
- **Frame.io player** (support.frame.io/articles/7785-keyboard-shortcuts): Space, J/K/L, and arrows to seek.
- **YouTube's web player** (from memory): ← and → jump 5 s, and J and L jump 10 s.

We follow the owner's ask (3 s, and 10 s with Shift). J/K/L keep their pro-editor meaning.

**Phone gestures.** The YouTube app is where double-tapping the left or right side to skip comes from. Taps accumulate (+10, +20…) and a ripple shows the side. In TikTok, a double-tap means Like and a long press brings up options or 2× speed. The owner said "TikTok style", which we read as the TikTok-like full-screen feel plus YouTube's double-tap skip (open question 3).

**Device frames.** Meta's device frames (facebook.design/devices) and the Apple Design Resources show what a believable device mockup looks like. We draw our own generic phone and laptop: a rounded body with an even bezel and a round camera dot, with no notch shapes or other brand details.

---

## A. New Swap as its own screen

### A1. What's wrong today (from `NewSwapPanel.swift` and `ComposerView`)
- The New Swap panel sits inside the Shot composer's right rail, so the composer's own parts still show:
  - a large empty prompt area with the hint "Write only the change in each switch";
  - the stage sized for Shot;
  - a big `cpu` icon on the model pill.
- The source buttons ("Upload…", "Paste link…", "Library…") are `.controlSize(.small)` in one HStack, so they truncate in a 360 pt rail.
- Character is off by default, but the owner's decision (new-swap.md, phase 2, answer 3) is "Character is her by default".
- The trimmer is two sliders with no picture of the clip.

### A2. Screen flow
```
Swap ▸ [Swap | New Swap (beta)]
   │
   ├─ Source (stage) ── Library grid ▸ pick ──┐
   │                  ├ Upload (file, or drop) ┤──▸ Clip on the stage + trimmer
   │                  └ Paste link ────────────┘        │
   ├─ Changes (rail): Background · Outfit · Character (on) · Look & light
   │                                                    │
   └─ Bottom bar: Clip sound · Model (Auto ▾) · why · price · Generate · $x
                                                        │
                    Generate ▸ stage shows "Generating" ▸ Done ▸ the viewer (B) opens the take
```
- **New Swap is its own view** (`NewSwapScreen`), not the composer with a panel. The composer, prompt editor, presets and Setup rows don't appear. The header switch stays where it is. Both drafts are kept when you switch, as today.
- **Order follows the owner's flow:** source, then trim, then switches, then model, then price, then Generate. Space does the grouping (stage on the left, changes on the right, action at the bottom). There are no numbered steps.

### A3. Layout (Mac, 1440 × 900; tokens from design-direction §2–4)

| Area | Spec |
|---|---|
| Header | 64 pt high, gutter 32. `title` "Swap", 16 pt gap, the segmented switch (track `field`, the selected item `raised` with a `hairline` inset). "Takes" on the right is a quiet text button with a 18 pt icon. |
| Body | Padding 8/32/24. Stage column flexible, gap 32, rail 352 pt fixed. |
| Stage, empty | `heading` "Add the video to remix", then a `caption` line, then a segmented control **Library \| Upload \| Paste link** (Library selected; 28 pt items). The Library grid has 104 × 185 tiles (9:16), a 16 pt column gap and a 24 pt row gap. Each tile has its duration on a scrim tag, `micro`, and its name under it as a `caption`. "Search takes" sits on the right. **Drop target:** the whole stage. A drop shows a 2 pt `accent` inset outline and "Drop to use this video". |
| Stage, Upload tab | One centred line: "Drop a video here or" plus a `quiet` "Choose a file…" button. Below it, the formats and the size limit in a `caption`. |
| Stage, Paste link tab | A `field` input (36 pt, full stage width up to 560) and a "Use link" quiet button. Errors appear under it in `danger`, with how to fix them. |
| Stage, filled | A source row 32 pt high, 600 pt wide: the name (`label`), then the duration and size (`caption`), then a quiet "Replace ▾" menu (Library, Upload, Paste link). Then the clip at **its own shape**, 500 pt tall (fills the height left over; never letterboxed), radius `container`. It plays muted on hover, and Space plays it with the viewer's keys (§B3). Then the trimmer. |
| Trimmer | A 600 × 56 pt filmstrip of 12 frames. The part used is at full opacity with a 2 pt `accent` top and bottom edge and 8 pt `accent` handles. The rest is at 35 % opacity. Under it in a `caption`: "Uses 0:02–0:12 of 0:24, 10 s. Wan 2.7 Edit takes up to 10 s." The link "Use the whole clip" shows when the clip fits. Dragging the middle moves the window, and dragging a handle changes the length (clamped to the model's min and max). The length can't go past the model's maximum, and the price updates when you let go. ← and → nudge the focused handle by 0.1 s, or by 1 s with Shift. |
| Rail | `heading` "Changes", then a `caption` "Switch on what should change. Write only the change." Then four rows, 12 pt apart. |
| A switch row | 44 pt minimum. Name in `label`, a state line in `caption` (12/16): "Kept from the clip" when off, or what it does when on. A `.switch` toggle on the right (on = `accent`). When on, its **one field** sits 8 pt below. |
| Background | A segmented **Describe \| Photo**, then one field (Describe: a text input of 1–3 lines; Photo: a 36 pt row with a thumbnail, the name, "Change" and ✕, or "Pick a location or upload…"). |
| Outfit | A segmented **Her outfit \| Product photo \| Words**, then one field. Her outfit is a row of 56 pt front images of her outfits (the first 6, then "All outfits…"). |
| Character (on by default) | Her chip: a 36 pt face, her name, "Face and figure from her pictures", and a "Change" link. Under it, the quiet link "Face swap from a photo instead". Choosing that link turns the chip into an upload row, with the consent line from the current panel. |
| Look & light | One text field. |
| Rail footer | A `caption` at the bottom: "Kept from the clip: motion, camera, timing and sound." |
| Bottom bar | 72 pt high with a hairline on top. From left to right: "Clip sound" (a quiet toggle button, 16 pt icon); the **model pill** (text only, "Auto · Wan 2.7 Edit · Replicate ▾", with no `cpu` icon); the reason in one `caption` line, truncating at the end if it must (it's the only part allowed to truncate; the full reason is in the tooltip). Then a spacer, "10 s, 1080p" in a `caption`, and **Generate · $1.00** (`action` fill, 40 pt, never truncates). |
| Narrow windows (≤ 1100) | The reason line goes into the pill's tooltip. The pill shows "Auto · Wan 2.7 Edit". The rail narrows to 320. The trimmer's width follows the stage. |

**The model list** is a popover above the pill, 440 wide, `raised`, the `float` token (on dark, a hairline inset instead):
- Search at the top.
- "Auto" first, with its reason for the current switches.
- The groups follow the server's `route`:
  - **Edits the clip** (edit)
  - **Follows the clip as a reference** (reference)
  - **Uses frames from the clip** (frames)
  - **Words only** (text)
  - **Not available**, with the reason
- Each row shows "Model · Provider" (the server's label), the price for this clip on the right in tabular figures, and the limits or the adapted line in a `caption`.
- The pick Auto would make is marked "Auto picks this". The selected row has a 2 pt `accent` bar on its left.
- Every model is listed (phase 3 rule). Only a model that can't run at all is dimmed.
- A footer `caption` says "Prices are for this clip: 10 s at 1080p."

### A4. States

| State | Stage | Rail | Bottom bar |
|---|---|---|---|
| Empty | Library grid; Upload and Paste link tabs | Usable; Character on (her) | Auto (no model shown), "The model and price show once a video is added", Generate disabled (`field`/`ink2`) |
| Library loading | Skeleton tiles shaped like the grid | — | — |
| Library empty | "No finished videos yet. Upload one, or paste a link." with the Upload tab one click away | — | — |
| Clip uploading | A `field` skeleton at the clip's shape, "Uploading beach_walk.mp4" and a 2 pt progress line (allowed: it shows progress) | Usable | Generate disabled: "Waiting for the upload" |
| Link fetching | Same, "Fetching the video from the link" | | |
| Ready | Clip and trimmer | Each switch that's on shows its field; a missing value shows its one line in `caution` ("Describe the new place") | The price appears; Generate is on only when every switch that's on is complete and at least one is on ("Turn on a change" otherwise) |
| Pricing | The price is replaced by a 48 pt skeleton bar; Generate keeps its last price, disabled for under 1 s | | |
| Generating | The clip at 45 %, "Generating, about 2 min left", "Model · Provider", a 2 pt progress line; "Leaving is safe…"; Cancel | Read-only while running | Generate becomes "Generating…" |
| Failed | The clip at 25 %, "⚠ Wan 2.7 Edit stopped", what happened and "You weren't charged" when true; **Try again · $1.00** and "Pick another model" | Editable | Normal |
| Done | The take opens in the viewer (B) on the stage, with "Reuse settings" | Kept (so the next remix is one change away) | Normal |
| Offline | A banner under the header: "You're offline. Library and prices come back when you reconnect." Upload is queued | | Generate disabled |

### A5. Keyboard and touch
- **Mac:**
  - ⌘↩ generates (as today).
  - ⌘O opens Upload and ⌘L opens Paste link.
  - Space plays or pauses the clip, with the viewer's arrows when the stage has focus.
  - Tab moves through the switches; Space toggles one.
  - Esc closes the model list.
  - Every icon-only control has a tooltip.
- **Android:**
  - The same order in one scrolling column, with the bottom bar pinned (the model pill and "10 s, 1080p" on one line, then Generate at full width, 48 dp).
  - The clip sits at its shape, 300 dp tall, with its details beside it. "Trim" opens a full-width trimmer sheet (handles of 48 dp or more).
  - Empty state: one block with Library, Upload and Paste link (44–48 dp each).
  - The header switch reads "Swap | New" on a phone.
  - Back goes from the trimmer or a picker sheet to the screen, then out of Swap.

---

## B. One viewer everywhere

### B1. One component
`TakeViewer` (Mac SwiftUI and Android Compose) replaces each of these:
- `FeedViewer`
- the stage's `ready` view (`SuiteComponents`, the "Keep / Retake / Edit / Share" rows)
- `ComposerCompare`'s media
- the Library detail
- the New Swap source preview

Edit's program monitor keeps its own transport, but it follows the frame rule (B2).

The viewer takes three things:
- a take or image;
- a **context**, which sets the actions shown: `suite`, `library`, `compare` or `source` (no actions);
- the list it can step through.

### B2. Frame and preview
1. **No letterbox.** The frame is the media's own shape (`width/height` from the take; a 9:16 default only until the metadata loads). Portrait media sits in a portrait frame, and the space around it is `canvas`, never a black box. The frame is as tall as the viewer allows (Mac: the window height minus the header and the preview bar; phone: the full width).
2. **Preview bar** (Mac: centred above the media, 40 pt; phone: the device icon in the top bar opens a sheet):
   - Segmented **Clean | TikTok | Reels | Shorts | Facebook** for portrait (and 4:5 and 1:1). For landscape, it's **Clean | YouTube | Facebook**.
   - A switch, **Phone frame** (Laptop frame for landscape).
   - A switch, **Safe zones**.
   - Defaults: Clean, frame off, zones off. The choice is remembered per device, so whoever previews for TikTok keeps getting TikTok.
3. **Device frames** (drawn, not images; no brand shapes):
   - **Phone:** a 9:19.5 screen with an even bezel (3.5 % of the width), a corner radius of 13 % of the width, a round camera dot, and a #0A0A0A body with a 1 px `#3A3D40` edge so it reads on both themes.
   - **Laptop:** a 16:10 screen, a 1.8 % bezel, and a base 116 % as wide.
4. **Fit inside the device:**
   - The platform layouts **fill** the screen and crop the sides of a 9:16 video, as those apps do on tall phones. That crop is the real result, and seeing it is the point.
   - Clean inside a phone **fits** the video, with thin black bands above and below, as a phone's own player does.
5. **Skins.** A skin is generic overlay art drawn over the video, in white at 55–85 % opacity:
   - grey bars stand in for text; real glyphs are used only for buttons (Phosphor Regular);
   - no logos, platform colours, wordmarks or platform type.
   - Each skin has the following parts.

| Skin | Top | Right rail | Bottom left | Bottom nav |
|---|---|---|---|---|
| TikTok | two tab bars, centred; search | avatar, heart, comments, save, share, sound disc | name bar, 2 caption bars, sound line | 5 icons |
| Reels | title bar left, camera right | heart, comment, send, more, sound square | avatar, name, outline follow box, caption, sound | 5 icons |
| Shorts | search and more, right | thumbs up and down, comments, share, remix, sound square | avatar, name, filled subscribe pill, caption | 5 icons |
| Facebook | back, title bar, search, profile | thumbs up, comment, share, more | avatar, name, follow box, caption | 5 icons |
| YouTube (laptop) | menu, title bar, search field, bell, avatar | recommended list (6 grey rows) | title bar, channel row, subscribe pill, action pills | — |
| Facebook (laptop) | top bar | comments column | name, caption | — |

6. **Safe zones:** a diagonal hatch (white at 20 %) over the areas the app's interface covers, plus a dashed white box around the safe area. The proportions sit in one server table (`GET /v1/preview/layouts`), so they can be corrected without an app update:

| Skin | Top | Bottom | Right |
|---|---|---|---|
| TikTok | 11 % | 29 % | 17 % |
| Reels | 10 % | 30 % | 16 % |
| Shorts | 9 % | 30 % | 17 % |
| Facebook | 10 % | 28 % | 16 % |

   The tooltip says "Approximate. Each app moves its buttons now and then."

### B3. Playback without a scrubber
There's no scrubber, loading bar or play-button overlay at rest.
- **Loading:** the poster frame shows until the video is ready. Over 600 ms, a 16 pt ring (`ink` at 60 %) appears in the corner, never in the centre.
- **Mac:**

| Key | Action |
|---|---|
| Space, or click on the media | Play or pause |
| ← and → | Back or forward 3 s (⇧ for 10 s) |
| J, K, L | Shuttle back, pause, shuttle forward. Pressing J or L again goes 2× and then 4×. K with J or L steps one frame. |
| , and . | One frame back or forward (while paused) |
| Home and End | Start and end |
| M | Mute |
| F | Full screen |
| ↑ and ↓ | Previous and next take (this moves off ← and →, which now seek) |
| Esc | Close |

  The keys work only when the viewer has focus and no text field does, using the `EditShortcuts` focus rule from 5A.6.
- **Seek readout:** a scrim pill in the middle of the media, `micro`/`caption` in tabular figures: "+3 s  0:07 / 0:10". It shows on every seek, J/L shuttle or frame step, and fades after 800 ms (no movement; with reduce motion, it disappears without a fade). There is no progress hairline on hover either: it would be a loader bar (open question 4).
- **Phone:**
  - Tap plays or pauses. A pause glyph shows for 600 ms, and a paused video keeps a small play glyph in the corner.
  - Double-tap the **left or right third** to skip back or forward **3 s**. More taps add 3 s each (+6, +9…), with a side ripple and the "+6 s" count, then the readout.
  - The middle third does nothing on a double-tap (a Like makes no sense in MUSE).
  - Long press plays at 2× while held.
  - Swiping up or down moves to the next or previous take.
  - Back closes the viewer.
  - Haptic tick on each skip.

### B4. Where the take actions go (nothing truncates)
- **Order everywhere:**
  - **Keep** (the one `action` fill; it becomes "Kept" once kept)
  - Redo
  - Extend
  - Upscale
  - Split
  - Share
  - **More ▾**, which holds Vary, Reuse settings, Use as start frame, Compare, Open in Edit, Save to collection, Download and Delete
- Each is one short word, so the labels are never cut.
- **Mac, portrait or square media:** a **vertical rail** 176 pt wide beside the frame, 48 pt from it. Each button is 36 pt (Keep 40 pt) with a 18 pt icon and its label. Under the rail sit the details (`caption`): "9:16 · 10 s", the size and the price. The free space beside a tall frame is used, and the rail never shrinks the frame.
- **Mac, landscape media:** a **row** under the frame with the same buttons at 36 pt, centred.
  - Narrower than the row needs: labels drop from the right in this order: Split, Upscale, Extend, then Redo. Those buttons become 36 pt icon-only buttons with tooltips. Keep and Share always keep their labels.
  - Under 560 pt: everything after Keep moves into More.
- **Phone:** an action row below the media with six 60 dp columns (24 dp icon over a `micro` label); Keep is in `accent`. More is in the top bar (dots). With a platform skin on, the row stays below the media, so it never fights the skin's own rail.
- **Unavailable actions are hidden, not disabled.** Examples: Extend on a model with no route, or Upscale on a 4K take. The reason shows in More ("Upscale: already 4K").
- **Context:** in `compare` the rail shows only Keep and More. In `source` (New Swap) it shows none. In `library`, Redo becomes "Open in Suite".

### B5. States
- **Loading:** the poster frame, then the corner ring after 600 ms.
- **Rendering:** the take's poster, "Rendering, 40 %", and a 2 pt progress line at the bottom of the frame (progress is allowed). Actions are hidden except More → Cancel.
- **Failed:** what happened, the fix, and "You weren't charged"; "Try again · $x" (`action`) and "Pick another model".
- **Video won't play** (codec or network): "This video can't play here. Download it or open it in Edit." with those two buttons.
- **Photo:** no playback keys. Skins still apply for 4:5 and 9:16, and the device frame works the same way.

---

## Open questions for the owner
1. **Character on by default:** should it be her (the last model you used) even when you only want a new background on someone else's clip? Recommended: yes, as you asked, with her chip clearly shown so it's one click to switch off.
2. **"Split" on a take:** what should it do? (a) Split the take into shots at its cuts, (b) cut it at the current moment into two takes, or (c) open it in Edit at that moment. Recommended: **(c)**, since it's Edit's job and needs no new server work.
3. **Phone double-tap:** you said "TikTok style". In TikTok, a double-tap means Like. The skip-on-the-sides gesture comes from the YouTube app. OK to use the YouTube-style skip (3 s per tap) and long press for 2×?
4. **No progress line at all,** even on hover on the Mac? Recommended: none, only the readout while seeking, as you asked.
5. **Skins:** are TikTok, Reels, Shorts and Facebook for portrait, and YouTube and Facebook for landscape, the right set? Add LinkedIn or X? Should the last choice be remembered per device (recommended) or per take?
6. **A free one-frame preview of the change before Generate,** as Runway Edit Studio does? It would need a still-image edit model run (a few cents). Recommended: later, as a separate request.
7. **Seek step:** 3 s on both Mac and phone, or 5 s on the phone, where taps are coarser?

## For the builder (after approval)
- **Mac first:**
  - `NewSwapScreen` replaces the `NewSwapPanel`-in-composer path; `SwapVariantSwitch` is reused.
  - `TakeViewer` (with `PreviewSkin`, `DeviceFrame` and `SeekReadout`) replaces `FeedViewer`, the stage `ready` view and the Compare media.
- **Server:** `GET /v1/preview/layouts` (the safe-zone table) and nothing else; New Swap's routes exist already.
- **Android after the Mac is green,** with the same components in Compose.
