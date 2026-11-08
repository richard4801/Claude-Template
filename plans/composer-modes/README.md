# Composer modes (owner decision 2026-11-08)

The owner kept the current composer (the cinematic Suite stays off, its code untouched) with four changes, on Mac and Android:

1. Backspacing the prompt to empty unselects the preset (Shot leaves the preset view, its rows back on Auto; Photo drops its preset).
2. Presets are only in the page's presets strip (and its All templates), no longer in the title's dropdown.
3. The title's dropdown is a plain mode menu: Make (Shot, Photo, Talking, UGC ad), Work from a clip (Character swap, Recast, Extend & upscale), Plan (Storyboard, Camera stage, owner only). Text only.
4. Mac sidebar: the mode sub-items under Video suite are gone (Android has no such list).

Before / after, left / right in each image:

- `mac-menu-before-after.png`, `mac-menu-before-after-dark.png`: the big tool and preset browser, then the mode menu.
- `mac-sidebar-before-after.png`: prod 57d6073, then this change.
- `mac-shot-preset-backspaced.png`, `mac-photo-preset-backspaced.png`: a preset picked, then the prompt backspaced to empty.
- `android-menu-before-after.png`, `android-menu-before-after-dark.png`: phone (390) and tablet (840), the Tools sheet then the mode menu.
- `android-shot-preset-backspaced.png`: the Cinematic preset picked, then the prompt backspaced to empty.

Mac shots come from CI (window height clamped to 684 pt on the runner).
