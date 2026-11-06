# Claude in the Edit suite (spec, 2026-11-06)

The owner asked for both, together:
- Claude makes and edits videos directly in MUSE's Edit suite.
- A chat inside MUSE that runs on the owner's **Claude subscription**, not the API.

This follows the pattern used by HyperFrames Studio (HeyGen):
- The app installs Anthropic's official Claude Code on the computer and opens Claude's own sign-in (`claude auth login`).
- It then runs that Claude Code as a background process and shows its conversation in a chat panel.
- Runs bill to the account Claude Code is signed in with, and the app never touches the credentials.
- The agent gets editing tools for what is on screen, including "grab the frame at time t" so it can check its own edits (HyperFrames' WebMCP `studio_frame`).

Owner-only. Members never see this. Using "your own Claude" as a member feature waits for a terms check (`plans/legal-todo.md`).

## Parts and owners

| Part | Owner |
|---|---|
| A. Edit sessions (live shared project) and the editing tools on MUSE's MCP server | workstream 3 (Edit suite), with server help from workstream 2 for MCP registration |
| B. OAuth 2.1 on `/mcp`, so MUSE can be added as a **custom connector in claude.ai** (works in the Claude phone, desktop and web apps on the owner's subscription) | workstream 2 |
| C. Mac in-app chat via the owner's local **Claude Code**, using the subscription | workstream 2 |
| D. Phone in-app chat **relayed to the Mac's Claude Code** (like the Blender relay), with a fallback | workstream 2 |
| E. One chat UI component used by the Edit suite and Camera stage (Direct with Claude) on both apps | workstream 2 builds; workstream 3 places it in the Edit suite |

## A. Edit sessions and tools

**Edit session.** A server-side, revisioned working copy of an EditProject v2 for one take or version. It is new table(s) in workstream 3's schema file, re-exported with one line.
- Fields: `id`, `ownerId`, `takeId`, `baseVersionId?`, `project` (EditProject v2 JSON), `revision`, `updatedAt`, `updatedBy` (`app:<device>` or `claude`), and an `ops` log for undo.
- The app's Edit suite opens or creates the session for the take it edits, applies local edits as ops (debounced), and applies remote ops live from the `edit` SSE event (`op: patch | reset`). Conflicts are last-writer-wins per op, with the revision check below.
- Claude's changes show live on the Mac and the phone, each with a "Claude" badge in the undo history; **Undo** reverts them like any edit.
- **Save** creates a normal version (`POST /v1/takes/{id}/versions`) from the session, as today.

**MCP tools.** Owner token or OAuth, all scoped `edit:*`.
- **Read:** `list_takes(recent, query)`, `open_edit(takeId) → session`, `get_edit(sessionId)` (project summary plus full JSON), `list_looks`, `list_caption_styles`.
- **Change.** Each call takes `baseRevision`; a stale revision gets a 409 with the current one.
  - `apply_edit_ops(sessionId, ops[])` with ops for: trim, split, delete or ripple, move, speed (constant or curve), add text/caption/hook, caption style, look (+ intensity), adjust, transition, mask, transform/keyframe, audio volume/duck/fades, voice effect, music track, ratio.
  - The op vocabulary is the one the Edit suite already uses. Document it in `plans/video-editor.md`.
- **AI helpers** (existing editor jobs; free ones are free; paid ones return an estimate and need `confirm: true` plus owner confirmation in the app):
  - `auto_captions`
  - `cut_silences`
  - `cut_fillers`
  - `remove_background`
  - `detect_beats`
  - `denoise`
- **See:** `get_frame(sessionId, t)` returns a PNG of the edit at time *t*.
  - When a MUSE app with the session open is online, the server asks it to render the frame and upload it (an exact match of the on-device engine).
  - Otherwise the server renders an approximate frame: the source frame plus Look LUT, text and captions drawn with the shared reference implementation, flagged `approximate: true`.
  - `get_contact_sheet(sessionId, every=1s)` returns a strip for checking pacing.
- **Finish:** `save_version(sessionId, name)`. `export(sessionId, preset)` asks an online app to export; otherwise it returns "open MUSE on your Mac or phone to export".
- **Guardrails:**
  - Claude never posts to socials, never spends without confirmation, and never deletes takes.
  - Every op is undoable, and every MCP call is rate-limited and logged in the session's history.

## B. OAuth 2.1 on `/mcp` (claude.ai custom connector)
- Follow the plan already written in `plans/mcp-bridge.md` "Auth: today and next":
  - MCP authorization spec 2026-07-28;
  - authorization server with PKCE and resource indicators;
  - audience-bound tokens;
  - client registration through Client ID Metadata Documents, with dynamic registration if claude.ai still needs it;
  - redirect `https://claude.ai/api/mcp/auth_callback`.
- **Login:** the owner logs in with their MUSE owner account on a small hosted page. Members are refused.
- **Scopes:** `camera:*`, `edit:*`, `cast:read`, `assets:write`, `generate:estimate`. There is no `generate:run` scope.
- **Existing tokens:** personal tokens keep working.
- **Settings → Connections** gains "Add MUSE to Claude" steps (claude.ai → Settings → Connectors → Add custom connector → URL). It then shows in the Claude apps on phone and desktop.

## C. Mac chat via the owner's Claude Code
- **Detect:** run `claude --version` and `claude auth status`, from the user's PATH plus common install paths. If missing, offer **Install** (runs Anthropic's official `curl -fsSL https://claude.ai/install.sh | bash` in a visible Terminal) and **Sign in** (`claude auth login`, which opens Claude's own page). MUSE never reads Claude credentials.
- **Run.** Headless Claude Code in a MUSE working folder (`~/MUSE/Claude/`):
  - stream-json in and out (`-p --input-format stream-json --output-format stream-json --verbose`);
  - an `--mcp-config` giving it MUSE's `/mcp` with a short-lived owner token the app mints;
  - `--allowedTools` limited to `mcp__muse__*` (plus Blender's tools when the Blender relay is on);
  - no Bash and no file writes outside the working folder;
  - `--resume <session>` to continue a conversation.
- **One conversation per edit or camera session.** The transcript is mirrored to the server, so the phone sees it too.
- **Show:** streaming text, tool calls as chips ("Trimmed 0:03–0:05", "Applied Look · Golden warmth"), frames Claude grabbed, Stop, and the current mode ("On your Claude plan").
- **Model and effort:** use Claude Code's defaults, and show the model name to the owner only.

## D. Phone chat
1. If the owner's Mac is online with Claude Code ready, the phone's messages go to the server and the Mac runs the turn. The reply streams back to the phone over SSE. Use the same queue/claim pattern as the Blender relay; the Mac shows "Answering from your phone".
2. Otherwise the phone shows "Your Mac is offline" with two options:
   - **Open in Claude**: a deep link to the Claude app, with MUSE added as a connector (part B).
   - **Use the studio API key**: only if `ANTHROPIC_API_KEY` is set and the owner has turned the fallback on in Settings. It is off by default and billed per use.

## E. Chat UI
One component, in the Edit suite (a right panel on Mac and tablet, a sheet from a "Claude" button on the phone) and in Camera stage (replacing the current Direct with Claude transcript view). The same transcript and tool chips everywhere.

## Tests (no money)
- **Server:** edit-session revisions and conflicts, every op and its undo, `get_frame` approximate render, OAuth flows (PKCE, wrong audience, member refused), and relay queue/claim/timeout.
- **Mac:** a fake `claude` executable that replays a recorded stream-json transcript (no real Claude calls in CI), plus MuseCore tests for the stream parser and tool-chip mapping.
- **Android:** relay chat with a fake server; Roborazzi for the chat sheet and the "Mac offline" state.
