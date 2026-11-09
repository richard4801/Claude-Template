# Edit content: sources and licences

_WS8, 2026-11-09. The owner approved "free/open libraries first": no paid library, no TTS vendor. Every file the apps
offer comes from a source below, and its licence was read at the source before use (not taken from a third-party
repackage). The catalog records each item's licence and attribution, and About → Licences lists them._

## Stickers: Twemoji

- **Source:** jdecked/twemoji v17.0.2, the maintained continuation of Twitter's Twemoji, fetched from jsDelivr's mirror of
  the GitHub tag (`cdn.jsdelivr.net/gh/jdecked/twemoji@17.0.2/assets/svg/`). The official npm package `@twemoji/api`
  (licence field "MIT AND CC-BY-4.0") points at the same files.
- **Licence:** graphics **CC BY 4.0** (the repo's `LICENSE-GRAPHICS`, read 2026-11-09); code MIT (not used).
- **Attribution required:** "Twemoji graphics by Twitter, Inc. and other contributors, licensed under CC BY 4.0
  (https://creativecommons.org/licenses/by/4.0/)". Shown in About → Licences. Our change: rasterized to PNG.
- **Not used:** `@twemoji/svg` on npm. It is a third-party repackage whose MIT licence can't relicense the artwork.
  OpenMoji was considered and not chosen: CC BY-SA 4.0 is share-alike, which is unclear for a member's exported video.
- **Names, categories and search words:** `emojibase-data` (MIT), with its tags derived from Unicode CLDR annotations
  (Unicode License v3, permissive). Only names, groups and tags are used.

## Sound effects

### uisfx (starter set)
- **Source:** npm `uisfx` 0.4.0 (github.com/romainsimon/uisfx).
- **Licence:** audio **CC0 1.0** (the package's `LICENSE-AUDIO`: "dedicated to the public domain under CC0 1.0
  Universal"); code MIT (not used).
- **Notes:** the sounds are synthesized from deterministic recipes, so no third-party recordings are inside. No
  attribution required; credited anyway in About → Licences.

### Kenney sound packs (via Net Forge)
- **Source:** npm `@netforge/asset-library-files` 0.2.0, `library/audio/sfx/`.
- **Licence:** audio **CC0 1.0**. The package's `NOTICE` names each pack and where its licence was checked: Kenney's
  Impact Sounds, Interface Sounds, RPG Audio, Sci-fi Sounds and Digital Audio, each archive's `License.txt` reading
  "Creative Commons Zero, CC0". kenney.nl itself was not reachable from this session, so the package's NOTICE is
  the record. The music file in that package ("Battle Theme A") is not used.
- **Not used:** freesound.org (per-file licences vary and need per-file checks; not reachable from here) and Sonniss
  GDC bundles (royalty-free, but redistribution as a library isn't allowed).

## Fonts (SIL Open Font License 1.1)

All from Google Fonts, as packaged in npm `@expo-google-fonts/<family>` 0.4.2 (licence field "MIT AND OFL-1.1"). Each
package's `LICENSE_FONT` was read: SIL OFL 1.1, with these copyright lines. OFL allows bundling and serving the fonts
and embedding them in rendered video. They may not be sold on their own, and a modified font may not use the
reserved name. We ship them unmodified.

| Family | Copyright line | Cyrillic | Latin Ext-A | Weights we ship |
|---|---|---|---|---|
| Inter | The Inter Project Authors | 100 % | 99 % | 400, 700, 900 |
| Montserrat | The Montserrat.Git Project Authors | 100 % | 100 % | 400, 700, 900 |
| Roboto Condensed | The Roboto Project Authors | 100 % | 100 % | 400, 700, 900 |
| Playfair Display | The Playfair Display Project Authors | 100 % | 100 % | 400, 700, 900 |
| Unbounded | The Unbounded Project Authors | 100 % | 100 % | 400, 700, 900 |
| Rubik | The Rubik Project Authors | 100 % | 98 % | 400, 700, 900 |
| JetBrains Mono | The JetBrains Mono Project Authors | 100 % | 98 % | 400, 700, 800 (as 900) |
| Caveat | The Caveat Project Authors | 100 % | 99 % | 400, 700 (700 as 900) |
| Oswald | The Oswald Project Authors | 100 % | 100 % | 400, 700 (700 as 900) |

- **How coverage was checked:** fontTools cmap. Cyrillic = U+0410–044F plus Ё/ё; Latin Extended-A = U+0100–017F.
- **The six current families have no Cyrillic** (Archivo/Figtree, Outfit, Instrument Serif, Barlow Condensed, the
  monos, Permanent Marker). WS16 found the same; the server falls back to DejaVu.
- **Rejected:** Anton and Bebas Neue, which have no Cyrillic.

## In-house packs

Looks (filters and effects), transition presets and caption templates are made by us from the existing engine (look
stack, adjust, LUT pack, caption styles). They are © MUSE, with no third-party content.

## Where the files live

`server/api/scripts/editor-content.ts` downloads the sources above at pinned versions and records each file's hash.
It rasterizes the stickers to 160 px PNG and converts the sounds to AAC (m4a, which both apps can play) into
`server/api/assets/content/`, with `catalog.json`. The server copies them into storage on start and serves the catalog.
The apps download each file on first use (nothing is bundled in the APK).
