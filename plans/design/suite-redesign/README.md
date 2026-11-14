# AI Suite redesign — owner-approved 2026-11-14

Figma: https://www.figma.com/design/dtQbOisZjSmuVeU2JCrJuO (frames 4:46 Swap filled light, 4:386 Swap empty,
5:335 Swap filled dark, 7:479 Shot composer, 8:677 Suite home, 3:2 / 3:221 components A/B). Figma MCP quota is
exhausted; build from these PNGs plus this file.

Owner decisions:
1. Suite home main button OPENS Shot with the prompt carried over. It never starts a paid generation.
2. Keep stays above the video with Redo/Extend/Upscale/Split/Share, as the one highlighted action.
3. The three-step guide on the empty Swap screen shows only until the user's first Swap, then hides.
4. Dark Shot and Home are built from the Swap dark tokens (amber accent); no further Figma frames.
5. "Test renders" moves out of the top corner and next to Generate: the button reads "Test render · Free"
   when on and "Generate · $X" when off, so a click's cost is always visible.

Known flaws in the PNGs to fix in the build, not copy: the Swap clip should be larger on stage; the Shot
timeline must show the take's real length (8 s take, not 0:09); the dark search box keeps the ⌘K hint;
no extra empty space in the home quick prompt bar. Prices in the PNGs are samples: always show the real
estimate from the server.
