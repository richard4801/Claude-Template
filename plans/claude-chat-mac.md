# Claude chat on the Mac (WS11)

_2026-11-08. Owner ask: Claude chat on the Mac should behave like the regular Claude desktop app, on every surface that has it. Branch `claude/muse-mac-chat`, built on WS2's phase B (`claude/muse-mcp-bridge` at 6475d3e). Android counterpart: WS10 (`claude/muse-android-chat`), same rules and copy._

## Surfaces
One chat, four places. Each now draws the same rows and the same composer:

| Surface | Where | View |
|---|---|---|
| Edit | the editor's Claude panel, Chat tab | `ClaudeChatView(contextKind: "edit")` |
| AI Suite | Claude's panel beside the Setup rail | `ClaudeChatView(contextKind: "suite")`; demo mode: `SuiteClaudeDemoChat` on the same parts |
| Recreate | Claude beside the Recipe | `ClaudeChatView(contextKind: "recreate")` |
| Camera | Direct with Claude | `ClaudeChatView(contextKind: "camera")`; the studio API key fallback on the same parts |

The shared parts are in `mac/Muse/Views/Claude/`: `ChatTranscriptView` (rows, states, following, Jump to latest), `ChatMarkdownView` (blocks, code, tables), `ChatComposer` (the growing field and bar), and `ClaudeChatModel` (thread, send, retry, stop, images). The rules live in MuseCore so they are tested and match Android: `ChatMarkdown` (parser) and `ChatLeakFilter` (what may be shown).

## What was wrong
1. **Bubbles and rows.**
   - Each surface drew its own: the Camera fallback had ink-filled bubbles and boxed, mono, ALL-CAPS tool chips with a cube icon; the Suite demo copied the bubble code.
   - Tool steps were chips in a flowing row: no state other than a mini spinner, nothing to open.
   - "You" and "Claude" labels sat over every message.
   - The streaming caret was a "▍" glyph.
2. **Markdown shown raw.** Claude's text was a plain `Text`: `**bold**`, backticks, `#` headings, `|` tables and code fences showed as typed, mid-stream too.
3. **Leaks.**
   - User bubbles showed the context line the app puts in front only where a surface passed `unwrapShown`.
   - Suggestion prompts showed Claude's instructions in the bubble ("Use get_recipe.", "with match_slots and apply_recipe"), and their tooltips showed them too.
   - The attached-image paths and upload ids could show.
   - Replies could carry system briefs, raw tool JSON, ids (`tk_…`, `es_…`, UUIDs), file paths and stack traces, and the error line showed Claude Code's raw error.
   - The composer line showed the model id ("On your Claude plan · claude-sonnet-…").
4. **Composer.**
   - A SwiftUI `TextField` capped at 5 lines.
   - Return submitted and there was no Shift-Return.
   - Paste and drop of images worked only in the Suite, through a hidden window-wide ⌘V button.
   - ⌘Return was the only send shortcut on some surfaces and was off in the Suite.
   - No Esc to stop, no ⌘K.
   - The composer could be squeezed at small window sizes.
5. **Everything else.**
   - It scrolled to the bottom on every change, even while you were reading above.
   - No "Jump to latest", no copy, no retry.
   - The empty, loading, error and offline states were thin: one hint line, a raw error, and no offline state.
   - It used an eager `VStack`, which got slow on long threads.
   - VoiceOver read labels and bubbles separately.

## What changed
1. **Rows** (`ChatTranscriptView`):
   - **Your messages:** right-aligned bubbles in `field`, with image thumbnails above the text. "From your phone" appears only when that's true.
   - **Claude's replies:** clean markdown text on the canvas, with no bubble and no label, as in the Claude app.
   - **Tool steps:** compact rows, grouped when they run back to back. Each shows a spinner while running, a check when done, or a warning in `danger` when it failed. A row opens to one plain sentence (`ChatLeakFilter.toolDetail`).
   - **Frames Claude looked at:** a thumbnail with a caption.
   - **Streaming:** smooth, with the markdown re-parsed per delta. A reply that is still open styles to its end instead of flashing markers.
2. **Markdown** (`MuseCore/Claude/ChatMarkdown.swift`, `ChatMarkdownView`):
   - **Inline:** bold, italic, both, strikethrough, inline code (tinted, monospaced), links and bare URLs, escapes and entities.
   - **Blocks:** headings (ATX and setext), nested, ordered and task lists, blockquotes, fenced code (language label, Copy, sideways scroll), tables (alignment, escaped pipes, short rows padded) and rules.
   - **Mid-stream:** a marker that has only just begun is hidden (`**`, a backtick, `~~`, `[`, `#`). An open span or fence styles to the end. A table waits for its divider row, and a closing fence still being typed is hidden.
   - **Literal symbols stay:** "2 * 3", snake_case and "#Dolly in" mid-line are left alone.
   - **Tests:** 23 MuseCore tests (`ChatMarkdownTests`). One of them parses every prefix of a tricky reply and asserts that no raw `**`, backtick, `__`, `~~` or `#` heading ever shows.
3. **No leaks** (`MuseCore/Claude/ChatLeakFilter.swift`, 12 tests). Every text goes through the filter before it is drawn:
   - **Removed:** `<system-reminder>`, `<thinking>` and tool-call markup (and an unclosed one mid-stream hides what follows); context lines (`[Suite …]`, `[Recreate …]`); raw JSON lines and JSON code blocks; stack traces (JS, Python, Apple, gdb); ids and UUIDs.
   - **Paths:** shown as their file name, or "a file on this Mac" when the name is an id. Paths inside a code block are kept.
   - **MCP tool names:** turned into words.
   - **Your bubbles:** without the suggestion instructions or the image list.
   - **Errors:** in plain words with what to do: limit reached, signed out, offline, timed out, stopped, not set up. A turn the server timed out reads "Claude on this Mac stopped answering. Try again." Anything technical becomes "Claude couldn't finish this reply. Try again." (the same sentences as Android).
   - **Members:** never see provider, model or GPU names. The chat is owner-only today, but the rule is in place for when that changes.
   - **Mode line:** says "On your Claude plan"; the model name is only in its tooltip.
4. **Composer** (`ChatComposer.swift`):
   - **The field:** an `NSTextView` that grows with the text up to 8 lines, then scrolls. It re-measures when the window narrows.
   - **Keys:** Return sends, Shift-Return or Option-Return makes a new line, and ⌘Return sends where the surface allows (not in the Suite, where it is Generate). Esc stops a running reply and ⌘. stops too. ⌘K puts the caret in the field. Input methods with marked text are never sent mid-composition.
   - **Images:** "+" attaches them; paste and drop work on the field and on the whole chat. In the Suite they go through its upload path. Elsewhere they stay on this Mac for Claude Code to read (up to 4, path only, no upload id). The hidden window-wide ⌘V catcher is gone from the chat.
   - **Stop:** replaces Send while Claude answers.
   - **Small windows:** the bar keeps its height and the transcript gives way, so the composer is never hidden.
5. **The rest:**
   - **Following new text:** the chat follows new text only while you're at the bottom. Scroll up and it stays put, and "Jump to latest" appears.
   - **Copy:** a reply has Copy on hover, and both kinds of message have Copy in the context menu. "Copy as plain text" is there too, and code blocks have their own Copy.
   - **Retry:** a failed turn shows its plain-words error with "Try again", which sends your last message again.
   - **States:** an empty state says what the chat is for, plus the keys. Loading is a conversation-shaped skeleton. Errors say what happened, with Try again. Offline has its own state with Try again.
   - **VoiceOver:** labels for each row ("You: …", "Claude: …", a tool step and its state), the code blocks and tables, and every icon button. Tooltips are on every icon button.
   - **Themes:** roles and the type scale only, in all four themes.
   - **Long threads:** a `LazyVStack` with stable ids, and rows that are `Equatable`, so only the changed row redraws while text streams.

## Review and CI
- **Review screenshots** (`SnapshotRunner+Chat.swift`), each surface in all four themes with the sample thread (`ClaudeChatSample`, which carries plumbing that must not show):
  - `mac_<theme>_claude_{camera,suite,recreate,edit}.png`;
  - `mac_<theme>_claude_camera_streaming.png` (a tool running, text arriving, Stop);
  - `mac_<theme>_claude_camera_composer.png` (8-line field and two images waiting).
- **Fit check** (`fit-check.txt`):
  - `chat_composer` at 1440 × 900, 1280 × 800, 1000 × 700 and 960 × 600 with 1, 4 and 12 lines, where the bar must be fully inside the window;
  - `chat_composer_grows` (4 lines taller than 1 by at least 2.5 lines) and `chat_composer_caps` (12 lines no taller than 8);
  - `chat_long` (every bubble and reply inside the panel's width);
  - one line per surface and theme (composer and a reply drawn).

## Coordination
- **WS2:** owns the Suite bridge and the approve card. This branch only changes how the chat is drawn, plus two small, compatible MuseCore edits:
  - `ClaudeAttachmentPrompt` drops "(uploadId …)" for a local image;
  - `ClaudeRelay` skips empty upload ids.
  - `SuiteClaudeAttachRow` gained `inComposer` (no "+" and no ⌘V catcher when it sits in the shared composer).
- **WS10 (Android):**
  - same copy: "Jump to latest", "Try again", "Claude is working…", "On your Claude plan", "From your phone", the error sentences in `ChatLeakFilter.errorWords`, and "Frame Claude looked at";
  - same leak rules;
  - same markdown coverage.

## The old screen stayed drawn after a screen change (root cause found)
_Seen only in review mode on the CI runner (macOS 15), four times over five runs; not reproduced by hand. For the owner of `RootView` and screen switching._

**What happens.** After `store.go(…)` (or `openEdit`, which calls it), the sidebar shows the new screen as selected, and `store.screen` has the new value, but the main area keeps drawing the old screen. Seen:
- **Run 42555982098, theme D:** the sidebar is on Edit, Home is still drawn (`mac_d_claude_recreate.png`). Re-running `openEdit` + `openRecreate` on the same screen changed nothing three times. Going to another screen first (`go(.gallery)`) and back drew it.
- **Runs 42547399430 (theme C) and 42551704028 (themes C and D):** the sidebar is on Edit, and the Suite or the Edit home is still drawn.

**How to reproduce.** This is review mode's order in `SnapshotRunner+Chat.swift` before the workaround (commit 9d304c8):
1. Theme C or D.
2. Put up an overlay that holds a live chat (`SnapshotRunner.state.overlay = "chat"`, a `ClaudeChatView` with the sample thread).
3. In the same tick, close the overlay (`state.overlay = nil`) and change the screen (`store.openEdit(takeId: nil)` and then `store.openRecreate()`).
4. Wait 2.5 s and capture: the old screen is still there.

By hand, the nearest equivalent is to open a Claude panel, then click a sidebar item while a reply is streaming, in Soft Tactile or Creator Pop.

**Suspected code.**
- `Shell.screen` in `mac/Muse/Views/RootView.swift` (about line 54) swaps the screen with `.id(store.screen)` plus `.transition(MotionStyle.of(t.id).transition)`.
- `AppStore.go(_:)` (`AppStore.swift` about line 934) wraps the change in `withAnimation(MotionStyle.of(themeID).animation)`.
- For themes C and D that animation is a spring (`.spring(response: 0.45/0.42, dampingFraction: 0.72/0.6)`); A and B use timing curves. Every failure was in C or D.
- **The likely cause:** the outgoing screen's removal transition never finishes. That happens when another animated transaction lands on the same update, such as the overlay's removal or the chat's animated `scrollTo`, while the spring is still settling. SwiftUI then leaves the old `.id` view in the hierarchy until the next screen change.

**Ideas to try.**
- Give screen changes a fixed-duration curve in every theme. Keep the spring's character with `.timingCurve`.
- Or remove the old screen without a transition: `removal: .identity`.
- Or check in a debug build that only one child of the `ZStack` remains 1 s after `go(_:)`.

**Workaround in review mode only.** The chat shots pause 0.8 s after the overlay closes. Recreate and Edit retry through another screen if their chat isn't drawn, up to three times, and log each try.

**Status (WS17): root cause found; fix pending two green Mac CI runs.** The first fix (ScreenHost alone, CI 42594641852) wasn't enough. Prod's runs at 231387e and 0d2b123 failed `stale_screen d`, and WS9's composer fit check drew Library under Video suite.

**Root cause: a missed Observation update.**
- `AppStore` is `@Observable`. Observation tells SwiftUI about a change on `willSet`, before the new value is stored.
- Review mode logs every ScreenHost body run after a screen change. Run 42610578768, theme D, try 6 logged `bodies [home@e, edit@e+1]`. ScreenHost ran once after `go(.edit)` began and read the OLD screen, Home.
- That body run re-armed tracking before `screen = .edit` landed, so nothing reported the change. ScreenHost stayed on Home until the next screen change (`edit@e+1` is the redraw below).
- Every symptom fits: the sidebar shows the new screen while the main area keeps the old one, and passing through another screen draws it.
- It is timing-dependent, which is why it showed up under the load of review mode on the CI runner.

**The fix (`AppStore.go(_:)`, `ScreenHost` in `RootView.swift`).**
- `go(_:)` bumps `screenEpoch` on the next main-actor turn, after the new screen is stored. ScreenHost reads it, so it always redraws with the stored screen.
- Every screen change goes through `go(_:)`, so this covers all of them, the Suite and Library included.
- Kept from before:
  - ScreenHost is its own view.
  - Screen changes use fixed-duration curves in every theme.
  - The old screen is removed at once.

**The checks (Mac CI).**
- **Stale screen:** `staleScreenCheck` (`SnapshotRunner+Chat.swift`) runs 10 tries in each of the four themes. Each try closes the chat overlay in the same tick as `openEdit` + `openRecreate`. 1 s later the window must hold only `store.screen`, read from a `ScreenProbe` (an AppKit view per screen). Each line also lists the ScreenHost body runs. All 40 tries must pass.
- **Stream close:** `streamCloseCheck` (`SnapshotRunner+StreamClose.swift`) runs first. In C and D it closes the chat mid-reply in the same tick as the screen change: 4 tries with the demo relay streaming slowly and 2 with the sample's streaming state. A main-thread watchdog runs alongside. If the main thread doesn't answer for 10 s, it writes a CUT line naming the stage, samples the app into `stream-close-sample.txt` and quits.

**The freeze seen in run 42580182117** (review mode stalled 10 min in the same flow, with the chat streaming) has not come back. That is 12 of 12 stream-close tries across two runs, with the main thread back within 0.2 s. That run had no stage logging, so its cause is unknown. The watchdog stays in CI to catch it with a stack sample if it returns.

**The review-mode workaround is gone**: the chat shots' 0.8 s pause and the Recreate/Edit retries through another screen.
