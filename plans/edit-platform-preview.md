# Platform preview moves into Edit (owner decision 2026-11-12)

The platform views (TikTok, Reels, Shorts, Facebook, YouTube and Clean) leave the take viewer and New Swap and go into
Edit, merged with Edit's safe-area guide. The owner already approved the idea. Worker branch: `claude/edit-platform-preview`.
Mac changes are in `plans/patches/edit-platform-preview-mac.patch`. Android comes after the Mac.

Mockups: `plans/design/edit-platform-preview/*.png`. To regenerate them, run
`PHOSPHOR=<unpacked @phosphor-icons/core 2.1.1> python3 design/edit-platform-preview/render.py`.

| File | What it shows |
|---|---|
| `edit-tiktok-dark.png`, `edit-tiktok-light.png` | TikTok view: the chrome over the edit, the red safe box, and a caption under TikTok's buttons with its warning line |
| `edit-clean-dark.png`, `edit-clean-light.png` | Clean view with Safe area off: nothing over the edit |
| `edit-clean-safe-dark.png` | Clean view with Safe area on: the red box that is safe on every app |
| `edit-youtube-landscape-dark.png` | A 16:9 project in YouTube view (the in-player chrome and its box) |

## Edit's viewer bar
- **View** is one segmented control:
  - portrait, square and 4:5 projects: Clean · TikTok · Reels · Shorts · Facebook;
  - 16:9 projects: Clean · YouTube · Facebook.
- **Safe area** is a switch, on by default. It works in every view:
  - In a platform view, it shows that app's red dashed box.
  - In Clean, it shows the box that is safe on every app (the largest inset of each side across TikTok, Reels, Shorts and Facebook).
  - Landscape views use their own boxes.
- The chrome is our own generic drawing, with no logos and no brand colours. It is the same art as before (`PhoneSkin`, moved out of `TakeViewer.swift`). Landscape views draw the app's in-player chrome over the edit (title row and bottom controls), not a whole web page, so the edit stays full size.
- The chrome fills the canvas exactly. The canvas is the output, so nothing is cropped.
- The choice is remembered per project, falling back to the device's last choice for a new project (MuseCore `EditPreviewPrefs`, in UserDefaults; the shared project contract is unchanged).
- When captions or text sit outside the box at any time in the edit, one line under the viewer says so: "Captions sit under TikTok's caption and buttons (0:01–0:09)." It comes with "Move into the safe area", which moves the caption position up, or moves the text item inside the box.

## Safe zones
- The table stays `GET /v1/preview/layouts` (`server/api/src/suite/previewLayouts.ts`). It gains an additive `landscape` map with YouTube and Facebook.
- MuseCore `PreviewLayouts` holds the defaults and merges the server's table over them, as before.

## Claude knows the view
- Edit's presence ping (`POST /v1/edit-sessions/:id/presence`) also carries `preview: {view, safeArea}`. It is sent at once when the view changes.
- `get_edit` returns `preview`, with the view, its safe box and an `unsafe` list (captions and text items outside the box, with their times).
- `apply_edit` adds `safeAreaWarnings` when a change leaves captions or text outside the box.
- The tool descriptions tell Claude to warn the person, in plain words, when that happens.

## Removed from the viewer
`TakeViewer` (Suite stage, Takes, Compare, Library, New Swap's source) loses:
- the preview bar and the compact "Preview:" menu;
- the skins;
- the phone and laptop frames;
- the safe zones;
- the `viewer.prefs` storage.

It stays a clean player: the media at its own shape, the keys and readout, and the action rail or row. `ViewerPrefs` and the phone and laptop frame maths are removed from MuseCore. `PreviewSkin`, `SafeZone` and `PreviewLayouts` stay, now used by Edit.
