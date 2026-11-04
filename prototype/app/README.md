# MUSE clickable prototype

- **Live:** https://claude.ai/artifact/4fHUYgM9dRVaCMYcFefnAd (private; share it from the page's Share menu).
- **Build:** run `python3 build_proto.py` from a folder that also has `gen.py`, `base.css` and `themes.css` (in `../screens/`) plus `imgs.json`, which is not committed. It writes one self-contained `muse-prototype.html`.
- **Themes:** A Editorial, B Camera Body, C Soft Tactile, D Creator Pop. Switch them in Settings or from the side panel. The choice is saved in localStorage.
- **Per-theme layouts** for Profile, Video studio (steps control) and Queue, matching the moodboards in `../directions/`.
- **Motion:** each theme has its own screen transition (A fade-rise, B snap with shutter flash, C spring, D bounce), plus a sheet slide, button press scale, stickers popping in, confetti, and a live render countdown. Reduced motion is respected.
- **Sound:** UI sounds are synthesized with WebAudio, so there are no audio files. Each theme has its own set (A paper tick, B mechanical click, C soft pop, D bubbly pop). There is a toggle in Settings.
- Demo renders run 24× faster than the measured H100 times (57.8s per step).
