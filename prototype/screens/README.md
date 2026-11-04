# MUSE app screens: 18 screens × 4 themes

- **Figma:** https://www.figma.com/design/VX9cpCUtcf9ue8ZV0fCmLi. Page "01 · App screens" has 4 rows (A Editorial, B Camera Body, C Soft Tactile, D Creator Pop). Page "00 · Directions" has the moodboards.
- **Source:** `gen.py` builds one HTML file per theme from shared markup, `base.css` holds the shared layout and `themes.css` holds the per-theme styling. The screens were imported into Figma with the html-to-Figma importer, one frame per `.screen`.
- **Images:** run `gen.py` with an `imgs.json` of base64 images next to it. That file is not committed; it holds the character references and frames from the test videos.
- **Screens:** Splash, Welcome, Sign in, Create account, Home, Model profile, Create (Basics / Look / Identity), Photoshoot (Camera sheet), Video (Source clip / Direct with steps / Background), Render queue, Result, Gallery, Settings (theme switcher), Credits & billing.
