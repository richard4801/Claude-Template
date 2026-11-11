# Video Studio (Suite) redesign on the Mac — proposal for the owner (2026-11-11)

APPROVED by the owner on 2026-11-11 (decisions below). Built on the Mac, waiting for the Mac build slot. The mockups are in `design/studio-redesign/` (dark theme, the app's
own colours, type and icons, real preview stills). To redraw them: `NODE_PATH=$(npm root -g) node design/studio-redesign/render.mjs`.

## What you said
"Too crowded. The content viewer is too big. The pages need proper optimisation; right now it's rough." You also said the
prompt shrinks to one line. That prompt fix is separate and already done (Part A, below). It doesn't wait for this design.

## What changes, in plain words
1. **The picture gets smaller and sits in the middle.** Today it fills every free pixel. Now it's sized to its shape
   (16:9, 9:16 …) and stops at about half the page height. Under it go the take's name, its length and shape, and four
   quiet buttons: Download, Open in Edit, Reuse settings, More. Under those is a strip of this draft's takes (the newest
   one still rendering shows its percentage). Click a take to show it. (Mock 1)
2. **One column on the right, in two folding groups.**
   - **Setup:** Camera, Light, Look, Style, Move. The header sums it up ("3 set, 2 on Auto"). Rows still on Auto are
     greyed, so the choices you made stand out. Click "Setup" to fold it away. Saving and loading rigs moves into
     the "…" menu next to the header, so the separate Rigs row goes.
   - **Inputs:** one row of tiles (Character, Start frame, End frame, …), each with its name under it, plus a
     References line.
   - The **Settings** row (shape, length, takes) leaves this column and becomes small buttons in the prompt bar, next to
     Model, Quality and Sound. Everything that changes the price now sits next to Generate.
3. **The prompt bar sits at the bottom and grows upwards** as you write (Part A). The page above gives up height, so
   Generate never moves off screen. Its row of buttons reads Model · Quality · Shape · Length · Takes · Sound, then the
   price help and **Generate · $price**, which is the only filled button on the page.
4. **With Claude open (Mock 2):** the app's sidebar shrinks to icons and the right column narrows to 264 pt. The
   picture shrinks to fit. Nothing gets squeezed and nothing wraps. A **Setup** button in the header hides the column
   if you want more room.
5. **On a smaller window (Mock 3, a 13" MacBook Air at 1280 × 800 with Claude open):** the right column turns into a row
   of compact buttons just above the prompt ("Camera 35 mm film ▾", "Light Golden hour ▾", the input thumbnails, "+").
   Each one opens the same picker as before. The picture shrinks first. The prompt in this mock has grown to five lines.
6. **Every tool uses the same frame (Mock 4):** Shot, Photo, Talking, UGC, Swap, Recast, Storyboard and Extend all have
   the same parts in the same places: the title (switches tool), Presets and Takes at top right, the picture in the
   middle, Setup and Inputs on the right, the prompt bar at the bottom.
   - **Photo** shows its 4 photos side by side instead of one big frame.
   - **Swap and Recast** don't show the Setup rows they can't use. They show one line instead: "Camera, light and
     style come from your clip".
   - **Extend** gets a Forward/Backward choice in the right column.
   - **Storyboard** keeps its shot list where the picture goes, with the same right column for the selected shot.
7. **Takes and Presets are pages in the same frame (Mock 5).**
   - **Takes:** a grid with filters (All tools, Shot, Photo, Swap) and "Newest first". The right column shows the
     chosen take's settings, its prompt and two actions: **Reuse settings** and **Open in Edit**.
   - **Presets:** the same layout, with each preset's still and one line saying what it sets up.
8. **Less clutter overall.**
   - No "Setup" or "Inputs" boxes inside boxes, and only three text sizes on the page.
   - Spacing does the grouping, on the 4/8 grid.
   - No icon on every row.
   - The only coloured things are Generate and the selection outline.

## Mockups
| File | What it shows |
|---|---|
| `design/studio-redesign/01-shot-14in.png` | Shot on a 14" MacBook Pro (1512 × 982), Claude closed |
| `design/studio-redesign/02-shot-claude-open.png` | The same with the Claude panel open (icon sidebar, narrower column) |
| `design/studio-redesign/03-small-window-claude-open.png` | 1280 × 800 with Claude open: Setup becomes a row of buttons, prompt grown to 5 lines |
| `design/studio-redesign/04-every-tool-same-frame.png` | Photo, Talking, Character swap and Extend in the same frame |
| `design/studio-redesign/05-takes.png` | The Takes page |

## Questions for you
1. **Picture size:** is "about half the page height" right, or do you want it a bit bigger (about 60%) when Claude is
   closed?
2. **Settings in the prompt bar:** OK to move Shape, Length and Takes out of the right column and into the prompt bar,
   next to Generate?
3. **Small windows:** below about 1100 pt of free width, should Setup turn into the row of buttons above the prompt
   (Mock 3)? Or should it stay a column that you open with the Setup button?
4. **Takes strip:** keep the strip of this draft's takes under the picture? Or show just the current take and leave
   the rest to the Takes page?
5. **Android:** after the Mac is approved and built, should the tablet layout get the same treatment? The phone already
   follows the order shown here.

## Owner's decisions (2026-11-11, relayed by the coordinator)
1. The picture stops at about **50%** of the page height.
2. **Shape, Length and Takes move into the prompt bar**, next to Generate.
3. **Small windows:** Setup becomes a row of buttons above the prompt (mock 3).
4. **Keep the takes strip** under the picture.
5. **Android tablet later**, after the Mac.

## What was built (Mac, held for the Mac build slot)
- `ComposerStage.swift` (new):
  - The stage: the picture is aspect-fit and capped at 50% of the page height, centred, with the takes strip under it
    (this tool's last 8 takes; click one to show it, click the newest to go back; "All takes" opens the feed).
  - `RailSection`: folding Setup and Inputs headers with their summaries.
  - `ComposerSetupStrip` and `SetupStripButton`: the Setup row of buttons for small windows, plus an "Inputs" popover.
- `ComposerView.swift`:
  - The column is 280 pt (264 when narrow). Below 900 pt of composer width, or when the header's new Setup button hides
    the column, the strip shows instead.
  - The Settings row is gone (the bar shows Shape, Length and Takes again). Rigs moved into the "…" on the Setup header.
  - A picked take is cleared when the tool changes or Generate is pressed.
- `RootView.swift`: on the Suite page with Claude open, the sidebar becomes the icon rail.
- Not built: the viewer's own action row from the mock. The result pane's existing actions stay.
- Fold states and Setup hidden are remembered (UserDefaults).

## Part A (already done, waiting for the Mac build slot)
The prompt box in every Suite tool now:
- grows smoothly with the text, a line at a time;
- is never shorter than two lines and grows to about 40% of the window's height, then scrolls;
- keeps @ and # chips inline;
- grows upwards, so Generate stays on screen;
- has an expand button that opens a full-size editor (⌘Return or Done closes it).

Extend's prompt grows the same way, up to 12 lines.

Android checked: its prompt box already grows (2 lines minimum, up to 4–5 lines, then scrolls), so it doesn't need
the fix.

## Build notes (after the yes)
- Mac only, in `mac/Muse/Views/Suite/Composer/*`: `ComposerView.page`, `ComposerRail` and `ComposerMediaPane`
  (aspect-fit with a cap), a new folding section header, and the Settings row moved into `ComposerBottomBar`.
- Width breakpoints use the composer's own width (the existing `composerNarrowWidth`), so the Claude panel is
  accounted for automatically.
- One Mac CI run when the build is ready. No server or contract changes.
