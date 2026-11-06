# Icons

MUSE uses one icon set: **Phosphor Icons, Regular**, from `@phosphor-icons/core` 2.1.1 (MIT, `LICENSE`). The reasons and the usage rules are in `plans/design-direction.md` §5.

- `icons.txt`: every icon in use, plus the old Android names and the SF Symbol names that map to Phosphor names.
- `phosphor/`: the vendored Regular SVGs (one filled path in a 256 box each).
- `build.py`: regenerates `android/.../ui/theme/PhosphorIcons.kt`, `mac/Muse/Resources/Phosphor.xcassets` and `mac/Muse/Theme/PhosphorMap.swift`.

To add an icon, put its Phosphor name in `icons.txt` and run the build from the repo root:

    npm pack @phosphor-icons/core@2.1.1 && tar xzf phosphor-icons-core-2.1.1.tgz   # once, anywhere outside the repo
    PHOSPHOR=/path/to/package python3 design/icons/build.py

Without `PHOSPHOR`, the build regenerates from the SVGs already in `phosphor/`.
