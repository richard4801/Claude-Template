# MUSE design direction

_Workstream 4, 2026-11-06. Written for the owner's whole-app review ("professional and clean, like it was made by a professional", no AI slop, one pro icon set). Every session follows it with `.claude/skills/muse-design-review/SKILL.md`. Where an older plan or screen disagrees, this file wins._

MUSE is a studio tool for making AI models, photos and videos. Its references are pro creative software, not SaaS dashboards: Lightroom, Final Cut, Halide and Blackmagic Camera for the media-first layout and physical controls, and Linear for restraint in the chrome.

## 1. Three MUSE principles
1. **The frame is the hero.** Every screen leads with the picture: her sheet, the take, the shot being built. Chrome sits at the edges, in neutral tones, and steps back while media is on screen. We never decorate a frame: no viewfinder corner brackets, gradient washes, glows or text stamped over a photo, except one caption on a scrim where the picture needs a name.
2. **Talk like a camera crew.** Real units are the information: 35 mm, f/2.8, 8 s, 9:16, $0.64. Labels are plain nouns and verbs in sentence case. The price of the primary action is always on its button ("Generate · $0.64"). There is no AI-speak: no sparkles, "magic" or "unleash". The product is the AI; we don't need to announce it.
3. **Dial it in, don't fill a form.** Settings are physical choices you see before you pick them: the hardware on a drum, the light on the mannequin, the look on the street. Each control has one selection mark (the band, or one outline), and grouping is done with space, not boxes. Anything set to Auto stays quiet, and only choices you made speak.

## 2. Themes and colour roles
The four approved themes stay, and each keeps its personality. What changes is that every colour now has one **role**, and the roles are the same in all four. Components only use roles, never a literal colour.

| Role | Used for | A Editorial | B Camera Body | C Soft Tactile | D Creator Pop |
|---|---|---|---|---|---|
| `canvas` | screen background | #EFEBE3 | #0D0E0F | #E7E2D9 | #FFF6EC |
| `raised` | sheets, menus, the composer field | #F8F5EF | #17191B | #F3F0EA | #FFFFFF |
| `field` | inputs, segmented tracks, empty media | #E7E1D6 | #212427 | #EAE5DC | #FFEBD8 |
| `ink` | primary text, icons | #141210 | #ECEAE5 | #23262A | #111111 |
| `ink2` | secondary text, captions, inactive icons | #67605A | #A9A6A0 | #5E5C57 | #55504A |
| `hairline` | media edges, input borders only | #CFC7BA | #2C3033 | #D9D3C8 | #111111 (2 px, see D) |
| `accent` | the selection mark, focus ring, links | #B5121B | #F2A93B | #4E6B45 | #FF7EB6 fill · #1F4BFF link |
| `action` / `onAction` | the one primary button | #141210 / #F8F5EF | #F2A93B / #1A1205 | #4E6B45 / #FFFFFF | #FF7EB6 / #111111 |
| `positive` · `caution` · `danger` | state only, never decoration | #2F6B3A · #8A5200 · #B5121B | #7BD88F · #F2C14E · #FF6B5E | #4E6B45 · #7F5418 · #A8382F | #0E7A45 · #9A4D00 · #C8102E |

**Contrast, checked:**
- **Text:** `ink` on `canvas` is 11.8–17.7:1. `ink2` on `canvas`, `raised` and `field` is ≥ 4.8:1 in every theme. Every `onAction` on its `action` is ≥ 6.0:1. `positive`, `caution` and `danger` on `canvas` are ≥ 4.6:1.
- **Creator Pop's pink** is 2.2:1 on its canvas, so it is only ever a fill under `ink` text. In D, text links use the cobalt link colour, and the selection outline is `ink`.
- **Hairlines** are 1.1–1.5:1, which is below the 3:1 UI minimum. So a hairline never carries meaning on its own: a selected or required state always uses `accent` or `ink`.

**Rules:**
- `accent` appears once per region: it marks what is selected or focused. It is never a heading colour or decoration, and never a second filled button.
- Only one `action` fill is visible per screen (or per sheet).
- State colours appear only with state (an error, a warning, a ready badge).
- Creator Pop keeps its 2 px ink outline, but only on the primary action and the current selection. Everything else in D is a flat tonal fill like the other themes. Today every card and chip has the outline, and that is most of D's noise.

## 3. Type
At most **two families per theme**: one display face and one text face. Monospace is no longer a third face used for decoration. Numbers that line up (prices, timecode, mm, f-stops) use the text face's tabular figures.

| Theme | Display (titles only) | Text (everything else) | Dropped |
|---|---|---|---|
| A Editorial | Instrument Serif | Archivo | IBM Plex Mono |
| B Camera Body | Barlow Condensed | Barlow | JetBrains Mono |
| C Soft Tactile | Outfit | Outfit | DM Mono |
| D Creator Pop | Bricolage Grotesque | Figtree | Permanent Marker |

**Scale** (sp on Android, pt on Mac; same steps in every theme):

| Token | Size / line height | Weight | Use |
|---|---|---|---|
| `display` | 28 / 32 | display face | one screen title, where the screen has one |
| `title` | 20 / 26 | 600 | sheet titles, panel titles |
| `heading` | 16 / 22 | 600 | section headings, card titles |
| `body` | 15 / 21 | 400 | running text, prompt |
| `label` | 14 / 18 | 500 | buttons, tabs, chip labels |
| `caption` | 13 / 18 | 400 | secondary lines, captions under tiles |
| `micro` | 11 / 14 | 500 | timecode, counts on media, badges |

**Rules:**
- Sentence case everywhere.
- ALL CAPS is allowed only in B Camera Body, for at most one hardware-style readout per screen (for example, the record-timer row), never above sections.
- No letter-spaced labels above every section: a section heading is `heading` in `ink`, or nothing at all when space already groups the content.
- No highlighted word inside a heading.

## 4. Space, radii and elevation
**Spacing:**
- **Grid:** 4/8. Tokens: `s1` 4 · `s2` 8 · `s3` 12 · `s4` 16 · `s5` 24 · `s6` 32 · `s7` 48.
- **Gutters:** 16 on a phone, 24 on a tablet, 32 on the Mac.
- **Grouping:** `s2` inside a group, `s5` between groups, `s6` between sections. Related things sit close and unrelated things far apart, and that spacing does the grouping that today is done with boxes.

**Radii by hierarchy:** container > control > chip.

| | A | B | C | D |
|---|---|---|---|---|
| container (sheets, media tiles) | 4 | 14 | 24 | 16 |
| control (buttons, fields, segmented) | 2 | 10 | 16 | 12 |
| chip / tag | 2 | 8 | 12 | 999 |

**Elevation:**
- Elevation comes from **tone, not shadow**: `canvas` → `raised` → `field`, with at most two levels on screen.
- Exactly one shadow token, `float`, used for things that float over content (sheets on the phone, menus, popovers, toasts). It has no glow.
- The dark theme (B) never uses a shadow.
- There are no cards inside cards. A tile is a picture plus its caption, not a box.

**Borders:** borders only where they mean something: media edges on light canvases, input fields, the selection outline, and D's primary action and selection.

## 5. Icons: one set
**Phosphor Icons**, the **Regular** weight only, at 16 / 20 / 24 (16 inline with text, 20 in controls, 24 in bars). It is MIT-licensed (© 2023 Phosphor Icons), and we use `@phosphor-icons/core` v2.1.1, which has 1,512 icons in six weights.
- **Why Phosphor:**
  - It's a single, consistently drawn line family that is large enough to cover a camera app (aperture, film strip, video camera, light bulbs, sliders, crop, timer, waveform).
  - The Regular weight sits well next to all four themes' type.
  - **SwiftUI:** an official, MIT-licensed SwiftUI package, `github.com/phosphor-icons/swift`. It supports macOS 10.15 and later.
  - **Compose:** only a community port, `com.adamglin:phosphor-icon:1.0.0` (adamglin0, MIT, Compose Multiplatform). It's listed among Phosphor's community projects.
  - **Lucide** (ISC, plus MIT for its Feather-derived icons) was the alternative. It was rejected because it has no official Compose or SwiftUI package (lucide.dev/packages lists none), and because Phosphor's camera and media vocabulary is broader. Checked 2026-11-06.
- **How we ship it:** we don't depend on a community Compose port. We **vendor the SVGs from the official core package** at a pinned version, so both apps draw the identical shapes from one source:
  - **Android:** a script converts the icons we use into VectorDrawables (`ic_ph_<name>.xml`).
  - **Mac:** the same SVGs go into the asset catalog as template images (`ph.<name>`).
  - The icon list lives in `design/icons/icons.txt`, and the licence file goes with it.
- **One semantic name per meaning**, used on both apps. For example: back `caret-left`, close `x`, more `dots-three`, add `plus`, camera `video-camera`, photo `camera`, lens `aperture`, light `lightbulb-filament`, look `palette`, style `film-strip`, references `images`, settings `sliders-horizontal`, sound `speaker-high`, speaking `microphone`, queue `stack`, gallery `squares-four`, model `user`, price `coins`, warning `warning`, play `play`, pause `pause`.
- **AI** has no icon. In particular, there is no sparkle on Generate or Auto. The Auto tile says "Auto" in text.
- **Not allowed:**
  - icons in coloured circles;
  - an icon next to every label (only where it helps scanning: tab bars, toolbars, icon-only buttons);
  - mixing in SF Symbols or Material icons.
- **Accessibility:** every icon-only button has an accessibility label, and on the Mac a tooltip.

## 6. Motion
Motion only **answers a user action or shows progress**.
- **Timing:**
  - 120 ms for a state change (toggle, selection);
  - 200 ms to enter or leave (menus, chips);
  - 280 ms for sheets and pushes.
- **Easing:** standard (fast out, slow in). There is no spring bounce, except the drum wheels' physics, which is a direct response to the finger.
- **Not allowed:**
  - fade-and-slide on every element;
  - hover glow on every card;
  - shimmer on anything that isn't loading;
  - ambient loops.
- **Previews:** move and preview loops play only for the tile under the pointer or in focus, and only one at a time.
- **Loading:** skeletons shaped like the content they replace (a grid of tiles, lines of text), not a centred spinner.
- **Reduce motion:** cross-fades replace movement, loops don't play, and the drums snap without momentum.

## 7. Copy
- **Tone:** plain verbs, sentence case, no exclamation marks, no marketing voice.
- **Buttons:**
  - Each button says what it does ("Generate · $0.64", "Save version", "Delete takes").
  - A confirmation names the action ("Delete 3 takes?" with "Delete takes" / "Keep").
  - Nothing is called "Submit" or "OK".
- **Names:** one name per thing everywhere (Shot, Take, Character, Cast, Preset, Look). The action label and its confirmation match ("Publish" → "Published").
- **Errors:** what happened, plus how to fix it. "Something went wrong" stays only as the last fallback, and always comes with "· you weren't charged" when that's true.
- **Meta lines:** at most one middle-dot line per item (for example "8 s · 9:16 · HD"), never chains of four or more.
- **Members:** never see model, provider or GPU names (owner views may).

## 8. Checked against the slop list (skill §1)
| Slop tell | Today | Decision |
|---|---|---|
| Mixed icon families | hand-drawn `Ic()` glyphs, SF Symbols and Material on the same screens | Phosphor Regular only (§5) |
| Sparkle for AI | ✨ on Generate and on the Auto tiles | removed; Auto is a word (§5) |
| Identical rounded cards with soft shadows | every tile and section boxed, shadows on light themes | tiles are picture plus caption; tone not shadow; one `float` shadow (§4) |
| Cards in cards | the shot preview in a card inside the composer card | the composer is one surface; the preview is media on canvas |
| Decorative frames | viewfinder corner brackets on hero photos | removed (principle 1) |
| ALL-CAPS tracked section labels | "RECENT TAKES", "CAMERA", "LENS"… | sentence-case headings or nothing (§3) |
| Monospace as decoration | mono caps on chips ("REFERENCES 0/6") | text face; tabular figures only for numbers |
| Pills and badges on everything | check badges, counts "5 / 11" on every wheel, "Optional" tags | one selection mark; counts only where they inform |
| Middle-dot chains | "Identity locked · 2 outfits · …" | at most one short meta line per item |
| More than 2 typefaces | three per theme (display, body, mono) | two (§3) |
| Equal weight, no primary | several filled buttons and accents per screen | one `action` per screen; `accent` only marks selection (§2) |
| Hover glows and fade-slide | glows on D's cards, staggered entrances | motion only on action or progress (§6) |
| Marketing copy | "Free" on Generate in demo | "Generate · $0.64" (or "Generate · demo") |

Kept on purpose, not by default: Instrument Serif titles in A (it's the theme's editorial voice), B's single hardware readout in caps, D's 2 px ink outline (restricted to the action and selection) and its pink.

## 9. Redesigned key screens (for the owner's approval)
`plans/design-direction/` holds three screens redesigned with these rules, in Camera Body (B, dark) and Editorial (A, light). Each is next to today's version.
- **Home** (phone 390): `home-b.png`, `home-a.png`
- **Composer** (phone 390, and Mac 1280): `composer-b.png`, `composer-a.png`, `composer-mac-b.png`
- **Picker** (Camera → Setup with the drum, phone 390): `picker-b.png`, `picker-a.png`. The camera bag is always dark (design/README decision 3), so in Editorial the sheet is dark too, with Editorial's type.
- **Today, for comparison:** `today.png` (Android, from the current screenshot tests).
- **Regenerate:** `python3 design/direction/render.py`, with `PHOSPHOR` pointing at an unpacked `@phosphor-icons/core` 2.1.1 (`npm pack @phosphor-icons/core`). The imagery is the Blender preview stills and the hardware renders, with no placeholders or people.

The rollout starts after the owner approves.
- **Part A (WS4):** AI Suite, pickers, Edit suite; the composer last, after WS1's bottom bar and WS3's Photo tool merge.
- **Part B (WS2):** Home, Library, Cast and models, LoRA, Settings, onboarding, chat.
