---
name: muse-design-review
description: MUSE's design review and anti-"AI slop" rules for the Android (Compose) and Mac (SwiftUI) apps. Load before building, changing or auditing any MUSE screen, icon, layout or UI copy, and before judging whether a screen looks professional.
---

# MUSE design review

The owner's bar: every screen should look like a professional design team built it, clean and calm, with nothing that reads as generated. MUSE is a studio tool for making AI models, photos and videos. Its references are pro creative software (Lightroom, Final Cut, Linear, Arc, Halide, Blackmagic Camera), not SaaS landing pages.

Read `plans/design-direction.md` first. It holds the tokens, the type scale, the icon set and the decisions. If it doesn't exist yet, writing it is the first job (see "Direction" below).

## 1. AI-slop tells: find them and remove them
Each of these is a default, not a choice. Remove it unless the direction file names it as deliberate.
- **Icons:**
  - Mixed icon families, stroke widths or sizes on one screen.
  - Emoji standing in for icons.
  - Sparkle ✨ or magic-wand icons for "AI".
  - Rocket, lightbulb or brain icons as decoration.
  - Icons inside coloured circles on every row.
  - An icon next to every single label.
  - Icons that don't mean the action (a generic "star" for presets).
- **Layout:**
  - Everything chopped into identical rounded cards with the same radius and the same soft grey shadow.
  - Cards inside cards.
  - Gradient washes or glows as decoration.
  - Hero "stat" blocks.
  - Centred everything.
  - Equal visual weight on every element, so there's no clear primary action.
- **Type:**
  - ALL-CAPS tracked labels above every section.
  - One word in a heading highlighted in a different colour or weight.
  - Monospace used for decoration.
  - More than 2 typefaces.
  - Sizes off the type scale.
- **Chrome:**
  - Middle-dot meta strings everywhere ("A · B · C").
  - "→" glued onto buttons.
  - Numbered 01/02/03 markers on things that aren't steps.
  - Dividers and borders that carry no information.
  - Pills and badges on everything.
- **Motion:**
  - Fade-and-slide on every element.
  - Hover glow on every card.
  - Shimmer on things that aren't loading.

  Motion should answer a user action or show progress.
- **Copy:**
  - Marketing voice inside a tool ("Unleash your creativity", "Magic", "Effortlessly").
  - Exclamation marks.
  - Vague errors ("Something went wrong").
  - Buttons named "Submit" or "OK".
  - Different names for the same thing on different screens.
  - Model or provider names shown to members (they never see them).
- **Placeholder residue:** lorem ipsum, "Coming soon" tiles that do nothing, dead buttons, grey boxes where images should be.

## 2. What professional looks like here
- **One primary action per screen,** visually obvious. Secondary actions are quieter (text or outline), not another filled button.
- **A clear hierarchy:** at a glance, the eye lands first on the content (the photo or video), then the primary action, then settings. Media is the hero; chrome recedes.
- **Spacing on a 4/8 grid** from tokens only. Related things sit close, unrelated things far apart, so grouping is done by space, not by boxes.
- **Radii by hierarchy:** containers > controls > chips. Not one radius on everything.
- **Contrast:**
  - Elevation by tone, not by shadow, on dark themes.
  - Text contrast at least 4.5:1, UI parts at least 3:1, in all 4 themes.
- **Icons:**
  - One family (from the direction file), one stroke weight, sized 16/20/24.
  - Every icon-only button has an accessibility label and a tooltip on the Mac.
- **Touch and pointer:** targets of 48 dp or more on Android and 28 pt or more on Mac. Visible keyboard focus on the Mac. Reduced motion respected.
- **States:** every screen has designed loading, empty, error and offline states.
  - Loading: skeletons shaped like the content, not spinners in the middle.
  - Empty: what this is, plus one action to start.
  - Error: what happened, plus how to fix it.
- **Text never wraps mid-word or truncates important values** (prices, durations). At narrow widths, controls shrink to icon plus value.
- **Platform feel:**
  - Mac uses Mac conventions: toolbar, sidebar, ⌘ shortcuts, hover states, no phone-style bottom sheets on desktop.
  - Android uses Material motion and back behaviour.

## 3. Copy rules
- **Tone:** plain verbs, sentence case, no filler, no exclamation marks.
- **Buttons:** start with a verb and say exactly what happens ("Generate · $0.65", "Save version").
- **Names:** the same name for the same thing everywhere. The action label and its confirmation match ("Publish" → "Published").
- **Confirmations:** name the action ("Delete 3 takes?" with the buttons "Delete takes" and "Keep").

## 4. Performance (also part of "optimised")
- **Scrolling:** smooth at 60/120 fps. Lazy lists with stable keys. No heavy work on the main thread.
- **Images and video:** sized to their display size. Thumbnails, not full renders, in grids. Previews pause off-screen.
- **Startup:** cold start under about 1.5 s to first content on a mid phone. Measure it and record the number.
- **Network:** no duplicate requests on recomposition or re-render. Cache catalogs.

## 5. How to audit a screen
1. Screenshot it: Roborazzi on Android at 360/390/840 dp, and the Mac snapshot or CI at 1000/1280/1440 px, in all 4 themes.
2. 2-second test: what does the eye hit first, and is it right?
3. Walk sections 1–4 above. Log each finding as `severity (blocker/high/med/low) · screen · what · fix`.
4. Fix, re-screenshot, and keep the before and after pair.
5. Never "fix" by adding decoration. Prefer removing.

## Direction (when `plans/design-direction.md` is missing)
Write it before touching screens:
- **Palette:** 4–6 named colours per theme, with roles.
- **Type:** 1–2 families, a scale with sizes, weights and line heights.
- **Spacing and radii:** the tokens.
- **Elevation:** the rules.
- **The icon set:** one professional line family; the owner chose "one pro set". Pick one that has both a Compose and a SwiftUI package with a compatible licence, such as Phosphor or Lucide, and record its licence.
- **Motion rules.**
- **Three principles that are specific to MUSE.**

Check the plan against section 1. If any part is a generic default, change it and say why. Show the owner 2–3 key screens redesigned (Home, the composer, a picker) as images before rolling it out app-wide.
