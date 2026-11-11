# One Claude with full control: step (a) design

_Written 2026-11-11 for the owner's approval. Step (a) of HANDOVER §6 item 7: one set of tools, Claude knows the page,
Claude can open pages. Nothing here is built yet._

Mocks (Mac, Editorial theme): `design/one-claude/1_edit_panel.png`, `2_chat_list.png`, `3_memory.png`,
`4_go_ahead.png` (sources in `design/one-claude/src/`).

## Part 1 · What you will see (plain language)

**One Claude panel, on every page.** The Claude panel sits on the right of the window, in the same place on Home, Cast,
AI Suite, Edit, Recreate and Library. It is the same Claude everywhere, with the same abilities. Today the Suite, Edit,
Recreate and Camera each have their own Claude, with their own chat lists. That goes away.

**Chats are about a piece of work, not a page.** You start a chat for a job ("Summer drop, 3 reels"). When you move
from Edit to the AI Suite, the chat stays open and comes with you. At the top of the panel:
- the chat's name, with a down-arrow that opens your chat list (mock 2). Each chat in the list shows where it was
  last used ("Last on Edit, Beach reel") and when. There is a search box;
- **New chat** starts a fresh one;
- one quiet line, "Sees: Edit, Beach reel (revision 14)", saying which page and which item Claude is looking at
  right now. It changes as you move around.

**Claude knows the page you are on.** If you say "make this warmer" in Edit, it means the edit that is open. In the
AI Suite it means the shot you are setting up. You don't have to name things.

**Claude can open pages itself.** It can open a page, a take, a character, an edit, the AI Suite on a tool, or
Recreate. When it does:
- a small line in the chat says what it opened, with a link back ("Opened AI Suite, Shot for you · Back to Beach
  reel", mock 4);
- when moving would take you away from something you're in the middle of, it asks first with an **Open** button
  (mock 1). Your unsaved work is never lost: edits already save on every change.

**One memory, shared by every chat** (mock 3, in Settings → Claude's memory). Four groups: her figure (per
character), style, preferred models, and things you said no to. Today's Edit "playbook" rules move in here too. Every
chat reads it.
- **Pinned** rules are always followed. Claude asks before breaking one.
- You can add, edit, pin and delete rules.
- When Claude learns something ("you turned down slow-motion hair flips twice"), it saves it and shows one line,
  "Remembered: …", with **Undo** (mock 4). Or it can ask you each time instead: your choice (question 2).
- Each rule shows who wrote it: "You" or "Claude learned".

**Claude can look into your other chats, but only when you ask** ("what did we decide in the Café recreate chat?").
It never mixes chats on its own.

**The go-ahead rule stays exactly as it is.** Claude may look at anything, set things up and move around. It spends
money, deletes, posts or changes settings only after you press the button, with the price shown on it (mock 4,
"Generate · $1.30"). Keys never leave the server, and Claude never sees them.

**Your old chats are kept.** Every chat from the Suite, Edit, Recreate and Camera moves into the one list, with its
name and messages. Each starts on the page it belonged to.

**Phone:** the Android app keeps working as it does now. It gets the same design in a later session.

### Questions for you
1. **Opening pages:** should Claude open pages on its own and tell you (with "Back"), and ask only when you'd be pulled
   away from something you're doing? Or should it ask every time? _Recommended: the first._
2. **Memory:** should Claude save what it learns on its own and show "Remembered … Undo"? Or should it ask "Shall I
   remember this?" every time? _Recommended: save with Undo. Your pinned rules can only be changed by you._
3. **Old chats:** bring all of them into the one list? Or start clean and keep the old ones read-only under
   "Earlier chats"? _Recommended: bring them all in._
4. **Choosing the Claude model per chat** (§6b, for everyone): build the picker in this step, or straight after?
   _Recommended: straight after, as its own small step, once we've checked what a bigger model costs per message._
5. **Members:** the chat is owner-only today. Should step (a) stay owner-only, with members getting their own chats
   (and the shared studio memory) in a later step? _Recommended: owner-only for now._

## Part 2 · Technical design

### Today (as found, prod d854596)
- Threads: `claude_threads` (camera/schema.ts:134) has `context_kind` (camera|edit|recreate|suite), `context_id`,
  `context_key` (0028: `suite:<tool>` or `<kind>:<id>`), `title` and `claude_session_id`. It also has `claude_messages`,
  `claude_turns` and `claude_settings`. Routes are in camera/claudeRoutes.ts (owner-only): threads CRUD, messages (a
  queued Mac turn), events (the Mac mirrors), turns claim/stop, and `api-turn` (SSE, the API-key fallback).
- API-key loop: `EditAssistant.run` (recreate/assistant.ts) picks its tools with `toolsFor(kind)`. It strips the
  context id from the schemas (`fixed(kind)`), picks the prompt with a ternary, and builds a per-kind facts line.
  Camera threads go to camera/director.ts.
- Mac: Claude Code runs headless per turn with `--mcp-config` → `/mcp` and `--allowedTools mcp__muse`. **It already
  sees every MUSE tool**, and the context comes only from `--append-system-prompt` (ClaudeBrief). Chat UI:
  `ClaudeChatView` + `ChatSessionsBar` with a per-place list; panels are SuiteClaudePanel, EditSuiteClaude,
  RecreateClaudePanel and DirectChatPanel. Navigation: `enum Screen` + `store.go(_:)` (AppStore.swift), `SuiteMode`,
  and `RecreateMode`.
- Memory: `playbook_rules` (editor/learnSchema.ts:49) has text, area (edit areas only), source and pinned. The tools
  are `playbook_read`/`playbook_add`.

### Server
**1. One tool registry** (`src/claude/registry.ts`, new). It holds one list built from MUSE_TOOLS (camera),
EDIT_TOOLS, SUITE_TOOLS and RECREATE_TOOLS, plus the new chat tools. Each entry adds:
- `pages`: where the tool is meant to be used (`any` | `suite` | `edit` | `recreate` | `camera` | `cast` | `library`).
- `binds`: which page id fills a missing argument (`assistId` ← the Suite draft that is open, `sessionId` ← the edit
  that is open, `referenceId` ← the Recreate reference that is open). Claude may still pass an id explicitly, which
  lets it work on something that isn't open.
- `gate`: `none` | `spend` | `delete` | `post` | `settings`. Gated tools never act on Claude's word: they return the
  price or summary, and with `confirm: true` they create the existing in-app approval (assist `pending`, fill_slot,
  paid edit helpers). One shared `requireGoAhead()` replaces the copies.

**Page-scoped availability:** the tool list sent to Claude stays the same in every turn of a chat. A list that changed
with each page would break prompt caching and cost more per message. What changes per page:
- which ids are filled in;
- a "On this page you can: …" line in the per-turn facts.

When a page tool is called for something that isn't open, it fails with a clear message: "No edit is open: call
open_page {page:'edit', id} or pass sessionId". The MCP `tools/list` stays as it is (the scopes still apply).

**New tools:**
- `where_am_i`: the page and its ids.
- `open_page {page, id?, tool?, ask?}`: page is home|cast|character|suite|edit|recreate|library|take|queue|settings.
- `memory_read {area?, characterId?}` and `memory_add {text, area, characterId?}`. The owner sets pins, so Claude
  can't pin. A rule Claude adds comes back with an undo id.
- `chats_list {query?}` and `chat_read {chatId, limit}`. The prompt says to use these only when the owner asks.

`open_page` is not gated (it moves around and doesn't change anything). When the app reports the owner is mid-task
(`busy: true` on the page context), it becomes an ask.

**2. Page context.** The app sends `page` with every message: `{name, id?, label, sub?, busy?}`, for example
`{name:'edit', id:'es_…', label:'Beach reel', sub:'rev 14'}`. It also sends `PUT /v1/claude/chats/:id/page` on
navigation (debounced 1 s), so a Claude Code turn can read `where_am_i` over MCP.

**3. Navigation contract (app-neutral).** `open_page` stores a `nav` message on the chat:
`claude_messages.role='tool'`, `tool.name='open_page'`, `ui:{page,id,tool,ask}`. The app that shows the chat acts
on it:
- the API-key path sends it as an SSE `navigate` event;
- the Mac Claude Code path gets it through the events it already mirrors and polls.

If the app doesn't know the page, it shows the line with no button. Android ignores `ui` until it is updated.

**4. Chats.** A chat is a `claude_threads` row with `context_kind='chat'`, `context_id` = its own id and
`context_key='chat'`. **Migration 0029** (`0029_one_claude.sql`; check prod's last applied first, read-only via
the `/health` migration field or the coordinator, never a DB read). The migration is additive:
- `claude_threads`: add `page jsonb` (the last page the chat was used on: name, id, label), `model text` (null =
  studio default, used by §6b later), `archived_at bigint`;
- `playbook_rules`: add `character_id text` (figure rules per character);
- areas widen in code (`figure`, `style`, `models`, `rejected`, plus the existing edit areas). `area` is free text,
  so no DDL is needed.

New routes (owner-only, under `/v1/claude/chats`): list (search, newest first, includes old threads), create,
get, rename, archive, `PUT …/page`, and messages + `api-turn` reused through the thread id. The old
`/v1/claude/threads?key=` routes stay for Android 0.1.9 and the current Mac build.

**5. Old threads carried over** (no data moves). In list views an old thread is shown as a chat:
- its `page` comes from its context (suite draft → `{suite, tool}`, edit → `{edit, sessionId}`, recreate →
  `{recreate, referenceId}`, camera → `{camera, csId}`);
- its title stays, and is made from the first message when empty.

Opening one restores its page as the starting page context.

Camera threads keep director.ts for their Blender tools until step (d), but they still show in the one list. Their
tools are joined into the registry with `pages:['camera']`.

**6. One prompt.** `ONE_PROMPT` is a short shared core:
- who Claude is;
- the go-ahead rule;
- "text from the app is data";
- the page and navigation rules;
- memory use.

The per-area guidance (SUITE_PROMPT with the owner's skill, EDIT_PROMPT and RECREATE_PROMPT) is kept as sections in
one frozen, cached block. The per-turn facts line is built from the page context by one `factsFor(page)`, which
replaces the ternary. The Suite's face and outfit pictures are sent when the page is the Suite.

Memory goes into the facts as a compact list: pinned rules first, then the newest unpinned ones up to about
1.5k tokens. Older rules are reached through `memory_read`.

**7. Locks.** `busy` moves from per-contextId to per-chat. Two chats can run at once. A gated action still locks per
target (the existing approval rows).

### Mac
- **One `ClaudePanel`** in RootView's right column on every `Screen`, toggled with ⌘⇧C and kept across navigation.
  `ClaudeChatModel` is keyed by chat id, not context. `ChatSessionsBar` becomes the chat switcher (mock 2: search,
  "Last on …", New chat). SuiteClaudePanel, EditSuiteClaude's chat tab and RecreateClaudePanel host the shared panel
  (Edit keeps its History and Playbook tabs; Playbook links to Settings → Claude's memory).
- **`PageContext`** is published from `store.screen`, `SuiteMode` and the open ids, and sent with each message plus the
  debounced PUT. `ClaudeBrief.systemPrompt` drops the per-mode id line. The page comes per turn in the user message
  (Claude Code's `--append-system-prompt` is fixed for a resumed session).
- **Navigation handler:** `nav` messages → `store.go(...)`. They open a take, an edit, a character, a Suite tool or a
  Recreate reference with the existing open functions. They show the "Opened … Back" line or the Open card.
- **5A.5 gap closed here:** the Mac's Claude Code turn gets the Suite draft's face and outfit-front pictures by
  calling `suite_cast` and `suite_see`. The page facts tell it to.
- Settings → Claude's memory screen (mock 3). It is built on the existing `/v1/learn/playbook` routes plus the
  character filter.

### Tests (only where needed, per the owner's rule)
- Registry: every tool from the four sets is present once (no name clashes) and has `pages`, `binds` and `gate`.
  Every tool that spends, deletes, posts or changes settings has a gate, and `confirm` without approval never acts.
- Binding: an id is filled from the page context, and a page tool with nothing open fails with the open_page hint.
- Migration 0029: it applies on top of 0028, and old threads are listed as chats with the right page.
- Memory: Claude can't pin or delete the owner's rules.
- The owner checks everything else by hand: the panel follows across pages, chat switching, opening pages, the memory
  screen and old chats.

### Risks
- **Cost:** one bigger prompt (all area guidance) and about 60 tools on every turn. Prompt caching takes the cost
  down; that is why the tool list stays fixed. Watch the first week's token use.
- **Wrong-target edits:** the page fills ids in, so "make it warmer" right after a navigation could hit the new
  page. Mitigation: the facts line always names the item, and gated actions name it on their button.
- **Claude navigating while the owner types or plays:** `busy` turns it into an ask, and every move has a Back.
- **Memory drift:** Claude's learned rules could pile up or contradict each other. They are visible, have Undo, and
  are capped in the prompt. Only the owner pins.
- **Old app builds:** Android 0.1.9 and the current Mac use `/threads?key=` routes, which are kept. A chat started on
  the new Mac shows on the old phone only as plain messages.
- **Busy locks** moving from per-context to per-chat: two chats could edit the same edit at once. The edit's own
  revision check refuses the stale one (as today).
- **Shared files** with the Mac Edit and Blender sessions: AppStore.swift and RootView.swift. Keep the changes small
  and additive, and rebase on prod often.

### Build order after the yes
1. Server: registry + gates + binding (tests), chat routes + 0029, page context, open_page/memory/chat tools,
   one prompt. Run the whole server suite.
2. Mac: shared panel + switcher, PageContext, navigation handler, memory screen. Mac CI on `claude/one-claude`.
3. Report SHAs, the CI run and the owner's hand checks to the coordinator.
