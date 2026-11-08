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
   - **Errors:** in plain words with what to do: limit reached, signed out, offline, timed out, stopped, not set up. Anything technical becomes "Claude stopped before finishing. Try again."
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
