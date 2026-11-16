# Hits: flash, negative, colour split, punch-in [trials 25, 26, 36, 37, 43, 51, 60–64]
- **White flash:** 3 falling grey frames laid on with blend `add`. Needs a shot of ~0.5 s or more. [25]
- **Negative / colour split:** the shot's own first 3 frames processed and laid opaque over themselves, so the shot runs on underneath with no jump. [25, 62] MUSE now has `difference` and `exclusion` blend modes (since 2026-11-16), so a live negative over the picture is possible inside MUSE — try that before baking.
- **Punch-in:** two scale keyframes in MUSE. 18 % over 4 frames was right on stills and invisible at speed → 35 % over the whole 0.3 s shot. Rule: ≥ 30 % over the whole short shot. [36, 37]
- **Effect words are ambiguous.** "Negative glitch" was built as a 3-frame flicker with big slices when the owner wanted a subtle RGB split. Name the effect, state strength and length, show one frame, start subtle. [60, 61, 63]
- Templates: `flash-white`, `hit-negative`, `hit-rgb-split`, `multi-hit-split`, `punch-in`, `punch-split`, `flash-punch`.
