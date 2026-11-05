# MUSE design references (owner-approved 2026-11-05)

The owner reviewed and approved the AI Suite and Edit Suite designs ("They're good").
- **Figma (review copy, images):** https://www.figma.com/design/wsKNgWP5sBcx7pT6Nq4PXl (owner's second account; 5 sections, 35 screens).
- **Live review page:** https://claude.ai/artifact/GTVdhpSxZtzLfwHXn2Mz3t
- `screens/` — all 35 screens as JPGs (≤1600 px): `ai-suite-desktop__D1…D10` (D3d = dark camera bag), `ai-suite-mobile__M1…M8` (M3d dark), `edit-suite-desktop__E1…E4`, `edit-suite-mobile__EM1…EM5`, `hardware-library__H1…H6`. These are the spec for the UI build — match layout, hierarchy, wording and states.
- `hardware/` — the 40 photoreal hardware renders (no logos; WebP ≤1024 px) + `manifest.tsv` (name, group, spec caption, prompt line). Ship these in the apps for the camera bag.
- `source/` — the Python generators that produced the screens (HTML), for exact sizes, colours and copy.

## Decisions for the open design questions (defaults; owner may change later)
1. Hardware captions keep real model names as a "look" caption (e.g. "Alexa 35 look"); no logos on images.
2. One quality ladder everywhere: Draft / Standard / HD / Cinema (character swap and Recast included; add-ons stay add-ons).
3. The camera bag is always shown in the dark theme, whatever the app theme.
4. Navigation: "Video studio" becomes **Video suite** (modes: Shot, Character swap, Storyboard, Talking/lipsync, UGC ad, Extend & upscale, Camera stage); **Edit** becomes a top-level item.
5. Moves: 16-move library, UGC moves first, at most two combined.
6. Claude never spends: Directed mode and MCP only create drafts with a price; the owner taps Generate.
7. Use the studio's real characters and their sheets (no placeholder names; never "Sienna").
8. Members never see provider/model names; owner views may.
