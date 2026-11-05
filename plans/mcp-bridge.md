# MUSE ⇄ Claude ⇄ Blender: the MCP bridge (Directed camera)

_Workstream 2, started 2026-11-05. Contract: `plans/api.md` "MCP & camera sessions". Research: `plans/research/ai-video-suite-research.md` §3.4._

Blender is not inside MUSE. The owner blocks a whole clip in Blender on their Mac — where each character stands and moves over time, and how the camera moves — and Claude does the Blender work. Everything lands in one **camera session** in MUSE: the brief, the cast, the camera path and blocking, the guide renders (greybox video, keyframe stills, `camera.json`, `characters.json`) and a Shot **draft** with a cost estimate. Directed mode is the advanced mode of the suite's single Camera control (workstream 1 owns the CameraSpec and the Shot API).

**Agents never spend.** No tool can start a generation. The furthest any tool goes is `create_shot_draft` (an estimate, no hold, no ledger row). The owner presses Generate in the app.

## How it fits together

```
 MUSE app (Android / Mac)                      MUSE API on Railway                              Owner's Mac
 ─────────────────────────                      ───────────────────                              ───────────
 Camera session screen ── REST ──────────────▶  camera sessions (Postgres) ── R2 (guides)
 "Direct with Claude"  ── POST …/chat (SSE) ─▶  Director: Claude API tool loop
                                                 · MUSE tools in-process
                                                 · blender_* tools ── `blender` live event ──▶ MUSE Mac app: Blender relay
                                                                    ◀── claim + result ──────    │ TCP 127.0.0.1:9876
                                                                                                 ▼
 Owner's Claude Desktop / Claude Code ── HTTPS ▶ /mcp (MUSE MCP, owner token)                    Blender + "MCP for Blender" add-on
        └─ stdio ─▶ mcp-for-blender ─────────────────────────────────────────── TCP 9876 ──────▶  (same add-on)
                                                 renders → ~/MUSE/CameraSessions/<id>/out/ ──▶ Mac app uploads them (presigned PUT → R2)
```

Two ways in, one session:
- **(a) In the app** — "Direct with Claude" on a camera session. The server runs Claude (`claude-opus-5-5` by default) with the MUSE tools and the Blender tools. Blender tools are relayed to the owner's Mac app, which runs them against the local add-on and uploads renders straight to R2. Same transcript and assets as (b).
- **(b) The owner's own Claude** (Claude Desktop or Claude Code, on the owner's subscription) with two MCP servers: the local **Blender MCP** and the remote **MUSE MCP**. Claude reads the session (`get_camera_session`), builds the scene in Blender, stores the blocking (`set_camera_path`), renders into the session folder (the Mac app uploads), or uploads itself (`attach_guide_media` → `curl -T` → `confirm_guide_media`), and leaves a `create_shot_draft`.

Sessions link by **id** (`cs_…`, unguessable). The app shows the id with a copy button; say "Open camera session cs_… and block …" to your Claude.

## The Blender add-on: which one and why

**Chosen: "MCP for Blender" (formerly `blender-mcp`, github.com/ahujasid/blender-mcp), MIT.** Checked on 2026-11-05 against its `addon.py` (add-on v1.8, socket protocol 15) and README.

| | MCP for Blender (community) | Blender Lab official MCP server |
|---|---|---|
| Licence | **MIT** | GPL-3.0-or-later |
| Blender | 3.0+ | 5.1+ |
| Socket protocol | documented in `addon.py`: one JSON `{type, params}` → `{status, result \| message}`, no framing, `localhost:9876` | same default port 9876 (never run both) |
| Extras | viewport screenshots, scene info, asset search (Poly Haven, Sketchfab…), `BLENDER_MCP_SAFE_MODE` | Blender API/manual search, background-process tools; "runs LLM-generated code without any guards", VM recommended (◐ third-party comparison) |

Why: MIT is simpler for us (nothing of ours is linked into it, but we avoid GPL questions entirely), the socket protocol is small and readable so the Mac relay can speak it directly, and it has a safe mode for the owner's own Claude. The official server stays a good alternative for the owner's own Claude if they want its docs search; **never run both on port 9876**.

**Security facts** (from its README): the add-on's socket has **no authentication or encryption** — anyone who can reach the port can run Python inside Blender. So: keep it on `localhost` (the default; never change `BLENDER_HOST` to a network address), don't expose 9876 in the macOS firewall, and leave the asset downloaders off unless needed. Telemetry is opt-in; `DISABLE_TELEMETRY=true` turns off even the anonymous usage record.

## What runs in Blender, and what never does

- **In-app chat (a):** Claude gets nine Blender tools (`blender_status`, `blender_scene_info`, `blender_screenshot`, `blender_setup_scene`, `blender_place_character`, `blender_animate_character`, `blender_add_prop`, `blender_set_camera`, `blender_render_guides`). Each is a **fixed MUSE script** shipped in the Mac app (`BlenderScripts.swift`) or a native add-on command. Claude only supplies **data** (numbers, ids, labels), which the server validates and the Mac validates again; the Mac passes it to the script base64-encoded, never spliced into code. Scripts only touch objects named `MUSE_*` and only write into `~/MUSE/CameraSessions/<sessionId>/out/`. **Free-form Python is not offered** in the in-app chat, and unknown tool names are refused on both sides.
- **The owner's own Claude (b):** the Blender MCP can run any Python Claude writes. Claude Desktop/Code ask before each tool call unless the owner allows it; turn on `BLENDER_MCP_SAFE_MODE=1` (blocks file, network and subprocess code). For extra isolation run Blender under a separate macOS user.
- **Credentials:** Blender's Python never sees a MUSE token or a storage URL. The Mac app asks the server for a presigned PUT (1 h, one object), uploads the file and confirms it. The MUSE MCP token lives in the owner's Claude config, never in Blender.
- **One Mac per call:** each relayed call must be claimed (`POST /v1/blender/calls/{id}/claim`); a second Mac gets `already_claimed`. Calls expire after 5 min (`BLENDER_CALL_TIMEOUT_SEC`). The relay accepts calls only for the signed-in owner.

## Setup (owner, once)

### 1. Blender and the add-on (Mac)
1. Install Blender (3.0+; 4.x/5.x recommended) and uv: `curl -LsSf https://astral.sh/uv/install.sh | sh`.
2. Install the add-on: `uvx mcp-for-blender install-addon`, then in Blender **Edit → Preferences → Add-ons** enable **Interface: MCP for Blender**.
3. In the 3D viewport sidebar (N) → **MCP for Blender** → **Connect** (starts the socket server on `localhost:9876`). Keep the asset integrations off unless you want them.

### 2. MUSE Mac app relay (for the in-app chat, and to auto-upload renders)
1. Sign in to the Mac app as the owner.
2. Switch on **Blender relay (debug)** (`BlenderRelayDebugView`; the final UI waits for the Figma review). It shows whether Blender answers.
3. While it's on, the Mac app: sends a heartbeat every 20 s (the session shows "Mac relay online / Blender connected"), runs relayed Blender calls one at a time, and watches `~/MUSE/CameraSessions/*/out/` for finished renders from your own Claude, uploading each to its session (`greybox.mp4`, `depth.mp4`, `pose.mp4`, `tracks.mp4`, `keyframe_start|mid|end.png`, `camera.json`, `characters.json`, `*.blend`).

### 3. A MUSE token for your own Claude
In MUSE (owner) → Settings → **Claude & MCP** → **New token** (API: `POST /v1/mcp/tokens {name}`), copy the `muse_pat_…` token — it's shown once. Revoke it there at any time (`DELETE /v1/mcp/tokens/{id}`); it stops working at once. Tokens only work for the studio owner.

### 4a. Claude Code
```bash
claude mcp add blender -e DISABLE_TELEMETRY=true -e BLENDER_MCP_SAFE_MODE=1 -- uvx mcp-for-blender
claude mcp add --transport http muse https://<your-muse-api>/mcp --header "Authorization: Bearer muse_pat_…"
```
Check with `/mcp` inside Claude Code. Renders: tell Claude to write them to `~/MUSE/CameraSessions/<sessionId>/out/` (the Mac app uploads them), or to use `attach_guide_media` and `curl -T`.

### 4b. Claude Desktop
Claude → Settings → Developer → Edit Config (`claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "blender": { "command": "uvx", "args": ["mcp-for-blender"], "env": { "DISABLE_TELEMETRY": "true", "BLENDER_MCP_SAFE_MODE": "1" } },
    "muse": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://<your-muse-api>/mcp", "--header", "Authorization:${MUSE_AUTH}"],
      "env": { "MUSE_AUTH": "Bearer muse_pat_…" }
    }
  }
}
```
If Desktop can't find `uvx`/`npx` (GUI apps don't inherit your shell PATH), use the full path from `which uvx` / `which npx`. Claude Desktop's built-in "custom connector" UI needs OAuth, which MUSE doesn't offer yet (below), so use the `mcp-remote` bridge above (◐ community package; not verified in this session).

### 5. Use it
- In MUSE: open a camera session → **Direct with Claude** → "Mia walks to the counter, turns to camera at 3 s; slow push-in."
- Or in your Claude: "Open MUSE camera session cs_… and block it in Blender; render the guides into ~/MUSE/CameraSessions/cs_…/out/ and leave a Shot draft."
- Review in the app, then press **Generate** yourself.

## Server configuration (Railway variables; owner sets them, never in chat)
| Variable | Default | |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Needed only for the in-app chat. Without it the chat answers `director_unavailable`; the MCP server and REST work without it. |
| `DIRECTOR_MODEL` | `claude-opus-5-5` | Model of the in-app chat. |
| `DIRECTOR_EFFORT` | `high` | `low`…`max`. Lower is cheaper and faster. |
| `DIRECTOR_MAX_TOKENS` / `DIRECTOR_MAX_STEPS` | 32000 / 24 | Per response / tool rounds per chat message. |
| `DIRECTOR_FALLBACKS` | `true` | Server-side refusal fallbacks (`fallbacks: "default"`). |
| `BLENDER_CALL_TIMEOUT_SEC` | 300 | How long a relayed call waits for the Mac. |
| `MCP_ENABLED` | `true` | `false` removes `/mcp`. |

**Cost of the in-app chat** (research §3.4.5, estimates ⚠): about $0.50–0.80 per directed shot on Opus 5.5 with caching (≈ 12 tool steps). The system prompt and tools are frozen and cached; each turn's volatile facts (revision, relay status) go into the user message; the conversation is stored append-only so the cache and thinking blocks stay valid. The owner's own Claude (b) costs MUSE nothing.

## Auth: today and next
- **Today:** owner personal access tokens (`muse_pat_…`, sha256 stored, revocable, optional expiry, refused for non-owners) in the `Authorization` header only (never a query string). `/mcp` answers 401 with `WWW-Authenticate: Bearer resource_metadata=…` and serves Protected Resource Metadata (RFC 9728) at `/.well-known/oauth-protected-resource` (with no authorization server listed yet). Browsers' `Origin` must match the API's own origin (DNS-rebinding protection). Rate limit 240 requests/min.
- **Follow-up: OAuth 2.1** per the MCP authorization spec (2026-07-28): an authorization server (or Neon/Managed auth) with PKCE, resource indicators and audience-bound tokens; client registration through Client ID Metadata Documents; scopes `camera:read`, `camera:write`, `cast:read`, `assets:write`, `generate:estimate` (no `generate:run` for agents). That makes MUSE addable as a Claude custom connector (redirect `https://claude.ai/api/mcp/auth_callback`) without `mcp-remote`.

## Known limits
- Hosted video models treat guides as strong suggestions, not frame-accurate paths (research §3.3). Keep ≤ 3 characters and one camera move per shot.
- The relay and the pending calls live in the API's memory (one instance, like live events). A restart ends waiting calls with an error the chat shows.
- Character height isn't in the character pack yet: proxies default to 1.68 m unless the session's cast sets `heightM`.
- The MUSE Blender add-on operators (`bpy.ops.muse.*`) from the research's phase C3 are replaced for now by the fixed scripts in the Mac app; moving them into a real add-on later keeps the same tool contract.

## Phase 2 · UI (Directed mode, Direct with Claude, Connections)
_Spec: `design/screens/ai-suite-desktop__D6.jpg` (Mac) and `ai-suite-mobile__M5.jpg` (phone); exact copy and sizes in `design/source/ai_desktop.py` (`chat_panel`, the D6 block around lines 140–190) and `ai_mobile.py`. Owner only: members never see any of it. Use the studio's real characters (never "Sienna"); owner views may name models._

**Data:** everything comes from the camera-session API (`plans/api.md` "MCP & camera sessions"): `GET /v1/camera-sessions[/{id}]`, `PATCH`, `PUT …/path`, `POST …/assets` + confirm, `POST …/shot-draft`, `POST …/chat` (SSE ChatEvents), live `camera`/`blender` events, `GET /v1/connections`, `/v1/mcp/tokens`.

**Directed pane (Mac, D6)** — inside the suite's Camera control when "Directed · Blender" is picked (workstream 1 owns the header, Preset|Directed toggle, Cancel / Apply to shot):
- Tabs **Blocking · Guides · History**.
- Session strip: id chip (`cs_7Q2M` = first 4 of the id after `cs_`, upper-case), title, `9:16 · 24 fps · 6.0 s · rev 4`; view switch **Plan · Camera view · Side**; **Re-render** (sends the chat message "Re-render the guides for this revision.").
- **Plan** (top-down, metres, X right, Y up on screen = +Y away from camera): grid (0.5 m), 1 m scale bar; each cast member's path from `blocking` as a dashed line with time ticks (`0.0s`, `1.2s`…) at keyframes, a round token with initials at the position at the playhead time, a small facing arrow, and the action label of the active key ("turns to camera"); the camera path from `cameraPath` (dotted), a camera glyph at the playhead and its **view cone** (horizontal FOV from focal mm and sensor 36 mm: `2·atan(18/f)`, toward `target`), label `CAM A · 35 mm · 1.5 m`. Fit the drawing to the bounds of every point (+1 m margin). Empty state: "No blocking yet · ask Claude in the chat, or block it in Blender from your Claude app."
- **Drag** a character token or the camera at the playhead → moves that keyframe (or inserts one at the playhead) → `PUT …/path` (debounced 400 ms); note "Drag a token or the camera to adjust · Claude sees your edits".
- **Camera view**: the newest `preview`/`keyframe_*` still nearest the playhead; **Side**: the same plan projected on X/Z (heights).
- Legend row: one line style per character name, "Camera path & view".
- **Timeline** (bottom): ruler 0…duration s, tracks CAMERA, one per character (upper-case name), CUTS; keyframes as red diamonds with their label (camera: derived "push 0.4 m · ease in-out" from consecutive keys' distance + ease, or "orbit 90°" from angle change; characters: `action`); the span between keys as a bar; red playhead with a time chip (`2.4 s`) — drag to scrub; END chip with the duration.
- **Guides** tab: ready assets by kind (greybox, depth, pose, tracks, keyframes START/MID/END, camera.json, characters.json, .blend) with thumbnails/play for video, size, source (Mac app / your Claude / chat), time.
- **History** tab: newest first, the transcript's tool steps and notes plus assets by time, grouped per revision when it's known ("rev 4 · Claude (chat) · set camera path and blocking · 2 min ago").

**Direct with Claude panel (Mac right column, phone M5 full screen)**:
- Header "Direct with Claude" + pill `● LIVE` (live events connected).
- Status rows with a coloured dot: **Claude session** — "Working…" while `claude.chatBusy`, "Connected · your Claude app" when `appLastSeenAt` < 5 min, else "In MUSE (this chat)" / "Not set up" when `inAppChat` is false; **Blender <addonVersion>** — "Mac · localhost" when `relay.blender`, "Mac app online · Blender not connected", "Mac app offline"; **Renders** — "Uploading n of m to MUSE" while assets are pending, "Guides ready" when a greybox is ready, else "None yet".
- Transcript: `user` messages as dark bubbles right-aligned (label "YOU · MAC APP"/"YOU · PHONE" from the source device if known, else "YOU"); assistant text under a `CLAUDE` label; tool messages as small outlined chips with a cube icon and the upper-case tool name (`BUILD_STAGE`, `PLACE_CHARACTER ×2` — consecutive same tool collapsed), red outline when `ok` is false.
- **Guides ready · rev N** card when guides exist: `6.0 s · 24 fps`, thumbnails (greybox, depth, pose, START, MID, END).
- **Working strip** while a turn streams: "CLAUDE · WORKING ON REV n+1", the last tool step or text as a quote, a progress bar (steps done / steps seen, or the render's own progress when the Mac reports it), percent.
- Composer: "Direct the shot… “lower the camera, lens 50”" + send (disabled while busy; `chat_busy` → "Claude is still working on this shot"). `director_unavailable` → inline "Direct with Claude isn't set up on the server yet (ANTHROPIC_API_KEY) · you can still direct from your own Claude app" with a link to Connections.
- Footer: "Claude never spends money. Generating waits for your tap · est. $1.92 at HD." (price from `shotDraft.estimate.usd`, quality from the draft request; without a draft: "Claude never spends money. Generating waits for your tap.").
- Phone (M5): back, title "Direct with Claude", `…` menu (Copy session id, Open in Settings → Connections); session card (title, `cs_7Q2M · 6.0 s · rev 4`, pill GUIDES READY / BLOCKING / DRAFTING); status card; Plan view (read-only, no drag, no timeline); last user bubble; CLAUDE · WORKING strip; guides row with "rev 4 guides · Greybox · depth · pose · 3 keyframes · Use for Shot 01 →"; composer. Blender runs on the Mac, never on the phone.

**Settings → Connections (owner)**:
- **Claude & MCP**: MUSE MCP URL (copy), "New token" (name) → the token shown once in a copy box with "You won't see it again"; list (name, prefix…, created, last used, Revoke with confirm). Snippets to copy for Claude Code (`claude mcp add --transport http muse <url> --header "Authorization: Bearer <token>"`) and Claude Desktop (the `mcp-remote` JSON), link "Setup guide" (`docsUrl`).
- **Blender relay** (Mac app): on/off switch (BlenderRelayService), status lines (Mac app online, Blender connected + add-on version, last call, last error), "Install the Blender add-on" steps (3 lines from "Setup (owner, once)"). On the phone the section is read-only status + "Runs in the MUSE Mac app".
- **In-app chat**: "Direct with Claude in MUSE" available / "Needs ANTHROPIC_API_KEY on the server".
