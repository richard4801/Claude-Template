# MUSE desktop (Mac) prototype

A clickable prototype of the Mac studio app. It uses the same four themes as the phone prototype (Editorial, Camera Body, Soft Tactile, Creator Pop), the same sample data, pricing maths, sounds and prompt engine (`plans/prompt-system.md`). The layout is built for a big window.

- Sidebar navigation and a title bar with search (⌘K command palette), a live job chip, a theme switcher and sound.
- **Video studio**: three columns. Source clip and clip checks on the left, a source → model preview with a timeline in the centre, and an inspector on the right (model, outfit, engine, steps 4–30 with live time and cost, takes, background, audio, lip sync, Generate).
- **Photoshoot**: a 4-shot canvas with Scene / Camera / Light / Prompt tabs.
- **Queue** as a table, with GPU status, today's spend against the cap, and a failed-job card.
- **Gallery** with Tests and Final tabs, multi-select and side-by-side **Compare**.
- **Models**, a profile with the character sheet, outfit sets and never-add list, and **New model** (Basics → Character sheet, bring your own images).
- Settings (theme previews, render defaults, costs and limits, notifications, About with the MiniMax H3 credit), Credits, and Sign in / Sign up.

Shortcuts: ⌘1–6 switch screens, ⌘N new video, ⌘↵ generate, ⌘, settings, ← → change steps in the video studio, Esc closes menus.

## Build

```bash
python3 prototype/desktop/build_desktop.py <imgs.json> <out.html> [desktop_thumbs.json]
```

`imgs.json` holds the base64 sample images and is not committed (some frames come from test footage). The theme tokens and icons come from `prototype/screens/gen.py`, and the sounds from `prototype/app/app.js`.
