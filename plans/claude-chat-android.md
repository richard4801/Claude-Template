# Claude chat on Android: what was wrong and what changed

_WS10, 2026-11-08, branch `claude/muse-android-chat`. The owner asked for the Claude chat in the app to behave like the regular Claude app, and found it rough. The Mac counterpart is WS11 (`claude/muse-mac-chat`), which is aligning the same behaviour and copy._

## Surfaces
Every Claude thread view on Android now draws the same component, `ui/screens/claude/ClaudeChat.kt` (`ClaudeChatContent`):

| Surface | Where | Frame |
|---|---|---|
| AI Suite | `suite/composer/ComposerScreen.kt` | `ClaudeChatSheet`, 62% sheet over the composer |
| Recreate | `edit/RecipeScreen.kt` | `ClaudeChatSheet`, 88% sheet |
| Edit | `edit/ClaudeEditUi.kt` | the phone sheet, or the tablet's right panel (Chat / Playbook) |
| Camera (Direct with Claude) | `camera/DirectWithClaude.kt` | full screen on the phone, the right column on wide windows |

The old Camera chat pieces (`YouBubble`, `ClaudeBlock`, `WorkingBlock`, `NoticeView`, `Composer`, `CamField`, `ToolChipView`, the camera `SendButton`) were no longer called by anything and have been removed, so there is one chat.

## What was wrong
1. **Raw Markdown.** Replies were one plain `Text`: `**bold**`, `` `code` ``, `## headings`, lists, tables and code fences all showed their markers. While streaming, a `▍` was glued onto the raw text.
2. **Layout.** Every message had a caption above it ("You · Phone", "Claude"). The user's text sat in a square box, and Claude's text and tool chips weren't grouped as one answer. Tool chips were a fixed 28 dp high and couldn't be opened.
3. **Leaks.**
   - The Mac puts a context line before messages typed there (`[Suite · Shot · draft 3]`), and it showed as the first line of the owner's message.
   - Tool summaries were shown as is, including JSON, paths and ids.
   - A failed turn showed the raw error string (`turn.error`), which could be a stack trace. Notices showed `e.message` as is.
   - The fallback note named the server's environment variable (`ANTHROPIC_API_KEY`).
   - A tool with no known wording showed its bare name in words, which is fine, but `mcp__…` names with a JSON summary showed the JSON.
4. **Composer.** A single-line field (`singleLine = true`), 48 dp high. Long messages scrolled sideways out of sight. The attach button looked like a photo icon, and Send used the "upload" icon.
5. **Keyboard.**
   - `imePadding` was on the chat, but the sheets were a fixed fraction of the screen. With the keyboard up, the Suite sheet (62%) left almost no room, and on a phone in landscape the composer could be pushed off the sheet.
   - The list used `animateScrollTo(maxValue)` on a `verticalScroll` Column, so it didn't keep the latest message in view when the keyboard opened.
6. **Missing pieces.**
   - No "jump to latest" button.
   - Every update forced a jump to the bottom, even while the owner was reading older messages.
   - No copy.
   - No retry of a failed turn.
   - No empty state beyond one line, and no time labels.
   - Little TalkBack wording.
   - Every message lived in one non-lazy Column, so long threads composed every message.

## What changed
### Messages (Claude-app style)
- **The owner's messages** are right-aligned bubbles in the `field` tone, up to 82% of the width (520 dp at most). The corner nearest the speaker is tighter. There's no "You · Phone" caption.
- **Claude's replies** are clean left-aligned text with no bubble. A small "Claude" label appears once, at the start of each answer, so a run of text, tool rows and frames reads as one reply.
- **Tool steps** are compact rows. A pulsing dot shows while a step runs, a check when it's done, and a warning (in `danger`) when it failed. A tap opens one plain line ("Saved camera path, done", "Grabbed a frame didn't work. Claude can try another way."). Raw input and output are never shown.
- **Images** the owner attached are thumbnails in the bubble (160 dp for one image, 76 dp each for several). A tap opens the full-screen `ImageViewer`. Frames Claude grabbed show at 200×113 dp and open the same way.
- **Streaming** text grows in place: the list is reversed, so the bottom stays anchored and the reply pushes up smoothly. Unfinished Markdown is held back instead of flashing raw (see below). The `▍` cursor is gone. Before the first words arrive, the answer shows "Claude is thinking…" with a pulsing dot, or "Waiting for your Mac…" while the turn is queued.

### Markdown (`ChatMarkdown.kt` parser, `ChatMarkdownView.kt` renderer)
- **Blocks:**
  - Paragraphs, with line breaks kept.
  - Headings: H1 at `title`, H2 at 17 sp, H3 and below at `heading`.
  - Bullet, numbered and nested lists, plus task lists with check boxes.
  - Blockquotes, with a 3 dp rule and `ink2` text.
  - Fenced code (``` and ~~~, any fence length). It's monospace and scrolls sideways, never wraps. A header row shows the language and a **Copy** button that changes to "Copied".
  - Tables, with or without outer pipes, and `:---:` alignment. Columns are sized to their content (64 to 260 dp), and the table scrolls sideways when wide.
  - Horizontal rules.
- **Inline:**
  - Bold, italic, bold-italic and strikethrough.
  - Inline code, including double-backtick spans.
  - Links: `[text](url)`, `<url>` and bare `https://` links, opened in the browser through Compose's `LinkAnnotation`. Only http, https and mailto links open; others render as plain text.
  - Backslash escapes.
- **Never raw:**
  - A marker that never closes styles the rest while the reply streams (`**bold so far` shows as bold), and is dropped once the reply is finished.
  - Mid-stream, a last line that is only a marker (`##`, `-`, `1.`, `|`, `` ` ``) is held back.
  - `[text](` shows the text and waits for the url.
  - An open code fence is a code block until it closes.
  - Underscores inside words (`snake_case`) and math (`5 * 3`) stay literal.
- **Tests:** `ChatMarkdownTest` (24 cases). One feeds every prefix of a long mixed reply, character by character, as a stream, and asserts that no `**`, `` ` ``, `__`, `~~` or leading `#` ever reaches the visible text.

### No leaks (`ChatClean` in `ClaudeLogic.kt`)
- **Context lines and briefs.** A bracketed context line the Mac adds before a message (`[Suite …]`, `[Camera session …]`, `[Recreate …]`, `[Edit …]`) is stripped from the owner's messages. So are system-brief tags (`<system-reminder>`, `<muse-…>`, `<context>`, `<brief>`), which are also stripped from replies.
- **Tool summaries** are kept only when they're a short plain line. JSON, stack traces and `mcp__` names fall back to the tool's name in words. Paths become "a file", and ids (`tk_8a7sdf9a`) are removed. Summaries are cut to 80 characters.
- **Errors become one plain sentence:**
  - Timeouts: "Claude took too long to answer. Try again."
  - Network: "Couldn't reach the studio. Check your connection and try again."
  - Rate limits: "Claude is busy right now. Try again in a minute."
  - Anything technical (traces, JSON, paths, error codes, "Error:" lines): "Claude couldn't finish this reply."
  - This applies to failed turns, notices, upload errors and the load error.
- **Copy:** the API fallback note no longer names an environment variable ("The API fallback isn't set up on the server yet"). The chat names no model or provider. Claude chat is owner-only, as before.

### Composer
- **Field:** a multi-line field in a `raised` box, 1 to 6 lines tall, then it scrolls inside (3 lines in the compact layout). Sentence capitalisation is on. **Enter adds a new line**; the Send button sends.
- **Buttons:** the paperclip (attach images, up to 4) on the left. On the right is **Send** (an arrow-up in the `action` fill, quiet while there's nothing to send), which becomes **Stop** (a square in ink) while Claude answers. Both have 48 dp targets.
- **Attachments** show as 56 dp thumbnails above the text, with a remove button. They're dimmed while uploading and outlined in `danger` if the upload failed.

### Keyboard
- **Above the keyboard:** the chat pads itself with `imePadding()`.
- **Sheets:** the phone sheets (`ClaudeSheetFrame`) now sit on top of the keyboard and grow to at least 92% of the space left while it's open. The Suite sheet no longer shrinks to a sliver.
- **Scroll position:** the transcript is a `reverseLayout` `LazyColumn`. The newest message stays at the bottom when the keyboard opens or a reply grows. When the keyboard opens and the owner was at the bottom, the list scrolls to the latest message.
- **Compact layout:** below 360 dp of height (a phone on its side with the keyboard up), the header drops to its status line and the composer puts attach, field and Send on one row.
- **Screenshots** below show the keyboard open on a phone in portrait and landscape and on a tablet. They use real IME insets dispatched to the window. The grey block only marks where the keyboard is.

### Everything else
- **Scrolling:** the list follows new messages while the owner is at the bottom. Scrolling up stops following, and a **Jump to latest** pill appears. Tapping it, or scrolling back down, resumes following.
- **Copy:** long-press any message (the owner's or Claude's) to copy it. There's a haptic tick and a "Copied" pill. TalkBack offers the same as a "Copy message" / "Copy reply" action. Code blocks have their own Copy.
- **Retry:** a failed reply shows "Claude couldn't finish this reply." (or the plain reason) with **Retry**. Retry sends the owner's last message again, on the Mac, or on the studio key if that's what answered (`ClaudeChatStore.retry()`).
- **States:**
  - Loading: a skeleton shaped like a bubble and three lines.
  - Empty: "Start a conversation" plus a one-line hint for that surface.
  - Load error: "Can't open the chat", the plain reason, and Try again.
  - Offline: "Claude on your Mac is offline", what to do, then "Use the studio API key" (the one primary action, when the fallback is on) or "Open in Claude", the connector note, and "Add MUSE in Connections".
  - Notices: a warning icon, plain text, and tap to dismiss.
- **Timestamps:** a centred label ("Today 14:05", "Yesterday 09:12", "Mon 3 Nov, 18:40") above the first message and wherever the conversation paused for 30 minutes or more.
- **Accessibility:**
  - The owner's messages read "You: …". Headings are marked as headings.
  - Tool rows read "Done: Saved camera path. Show details".
  - Send, Stop, Attach, Remove image, Jump to latest and the code Copy all have labels.
  - The status line and "Copied" are polite live regions.
  - Text uses the type scale in sp, with no fixed text heights, so font scaling works.
  - The theme's roles (all four themes) are used throughout, so light and dark both work. In Creator Pop, Markdown rules use the tonal `field`, not the solid-ink hairline that's reserved for the primary action and selection.
- **Performance:**
  - `LazyColumn` with stable keys (message ids; live parts keyed by tool id or index) and content types.
  - Markdown is parsed in `remember(text, streaming)`, so only the streaming reply re-parses as it grows.
  - Table column widths are measured once per table.

### Icons
`arrow-up`, `arrow-down`, `paperclip`, `square` and `check-square` were added to `design/icons/icons.txt` (Phosphor Regular 2.1.1). `python3 design/icons/build.py` regenerated `PhosphorIcons.kt` and the Mac asset catalog; the change only adds icons.

## Copy (shared with WS11)
| Where | Text |
|---|---|
| Status, ready | On your Claude plan, answered by your Mac |
| Status, answering | Your Mac is answering |
| Status / block, offline | Claude on your Mac is offline |
| Studio key answering | Answering on the studio API key, billed per use |
| Waiting | Waiting for your Mac… · Claude is thinking… |
| Failed turn | Claude couldn't finish this reply. + Retry |
| Placeholder | Describe the shot… (Suite) · Ask Claude to edit… (Edit) · Direct the shot… (Camera) · Message Claude… (Recreate, others) |
| Scrolled up | Jump to latest |
| Copy | Copy · Copied |
| Empty | Start a conversation + the surface's hint |

## Tests
- `claude/ChatMarkdownTest`: tricky Markdown, streaming prefixes, unclosed markers, tables, lists, links, escapes.
- `claude/ChatCleanTest`: context lines, briefs, tool summaries, errors, the transcript's words, retry text, time labels, and no key or model names in the copy.
- `claude/ClaudeChatSurfacesScreenshotTest`: 4 surfaces × 4 themes × (phone and tablet, keyboard closed and open, plus phone landscape with the keyboard), and 6 states × 4 themes. Each case also asserts that no raw marker, context line, `mcp__` name, JSON or exception text is on screen. The PNGs are `app/build/outputs/roborazzi/chat_<theme>_<surface>_<device>_<kb|nokb>.png` and `chat_<theme>_state_<state>.png`.
- The existing `ClaudeChatScreenshotTest`, `ClaudeLogicTest` and `FakeClaudeApiTest` were updated for the new copy and the icon-only Stop button.
