# Parallel build coordination

_Started 2026-11-05._ Several Claude sessions build MUSE features at the same time. This file is the shared source of truth: **read it before you start, pull it often, and keep your own section current** (on your branch; the coordinator merges). Message the other sessions directly (`send_message` to their session ids, below) when something you do affects them. Everyone reports to the coordinator when done.

## Coordinator
- Session `session_01Py2rxp4dEicUCVHRmLavgE` (the owner's main session). It owns `claude/ecstatic-rubin-2egjfb` (the branch Railway deploys to production) and merges finished feature branches into it after review. Send it: blocking questions, contract changes, and your final report.

## Workstreams
| # | Workstream | Session | Branch | Owns (write) |
|---|---|---|---|---|
| 1 | **AI suite core** (video model registry, adapters, Shot API, Camera preset compiler, costs/caps, mocks) | `session_01Py2rxpmMTMha4CSFyx4bX3` | `claude/muse-suite-core` | `server/api/src/suite/**`, `server/api/src/routes/suite.ts`, `server/api/test/suite*.test.ts`, migration **0007**, `plans/ai-suite.md`, the "AI suite" section of `plans/api.md` |
| 2 | **MCP server + Blender bridge** (MUSE remote MCP, camera sessions, in-app "Direct with Claude" chat backend, Mac Blender relay, setup docs) | `session_01Py2rxpzK498R32918DPNY5` | `claude/muse-mcp-bridge` | `server/api/src/mcp/**`, `server/api/src/camera/**`, `server/api/src/routes/mcp.ts`, `server/api/src/routes/camera.ts`, `server/api/test/mcp*.test.ts`, `server/api/test/camera*.test.ts`, migration **0008**, `mac/MuseCore/Sources/MuseCore/Blender*.swift`, `mac/Muse/App/Blender*.swift`, `plans/mcp-bridge.md`, the "MCP & camera sessions" section of `plans/api.md` |
| 3 | **Editor engine v2** (multitrack edit list, text/captions/audio/keyframes/transitions, AI helpers: auto-captions, silence/filler cuts, background removal; Android + Mac composition engines) | `session_01Py2rxnDfuHM43WWEtDLf1v` | `claude/muse-editor-v2` | `server/api/src/editor/**`, `server/api/src/routes/editorAi.ts`, `server/api/test/editor*.test.ts`, migration **0009**, `android/core/src/main/kotlin/studio/muse/core/edit/**`, `android/app/src/main/kotlin/studio/muse/app/platform/edit/**`, `mac/MuseCore/Sources/MuseCore/Edit/**`, `mac/Muse/App/Edit/**`, `plans/video-editor.md` (v2 section), the "Editor v2" section of `plans/api.md` |
| — | Coordinator's local agents | coordinator | `claude/ecstatic-rubin-2egjfb` | server image refs/collage (migration 0006), Android shoot references + Prompts editor, Figma designs |

**Shared files** (`server/api/src/app.ts`, `server/api/src/config.ts`, `server/api/src/db/schema.ts`, `plans/api.md`, `android/.../data/Models.kt`, `MuseApi.kt`, `HttpMuseApi.kt`, `mac/MuseCore/Sources/MuseCore/Models.swift`, `HTTPMuseAPI.swift`): keep edits **small and additive** (append, don't reorder or reformat), one clearly commented block per workstream, so merges stay trivial. Register routes with a single line in `app.ts`. Put new tables in your own schema file (e.g. `src/suite/schema.ts`) re-exported from `db/schema.ts` with one line.

## Rules for every session
- **No money.** No live Replicate predictions, no RunPod pods, no Anthropic API calls with the production key. Build against mock/fake providers; the owner tests with real use. Read-only GETs of public model pages/docs are fine.
- **Production is off-limits.** Don't push to `claude/ecstatic-rubin-2egjfb`; don't change Railway variables; against the live server only `GET /health`. Never print secrets.
- **UI waits for Figma.** The owner reviews the Figma designs (file `VX9cpCUtcf9ue8ZV0fCmLi`, pages "AI Suite —…", "Edit Suite —…") before UI is built. Build backends, engines, data models, APIs and tests now; only minimal, throwaway debug UI if you need it to test.
- **Licence:** the MiniMax H3 **open-weights** licence excludes the US/EU/UK/South Korea (incl. outputs) and requires a "Powered by MiniMax H3" notice. Do not build new features on the RunPod H3 open-weights path; hosted models (Replicate) are fine. The owner decides the existing "Edit" path.
- Member-facing data never names providers/models/GPUs (owner views may). AI-label switches stay user-controlled and off by default. Never use @vvspolly images.
- Read `plans/research/ai-video-suite-research.md` (the research), `plans/api.md`, `plans/backend.md` first.
- Commit in small logical commits; messages end with the session's attribution trailer; no model identifiers in messages. Run the server tests (`npm run build`, `npx vitest run`) / Android unit tests / MuseCore tests for what you touch before pushing to **your** branch. Rebase your branch on `origin/claude/ecstatic-rubin-2egjfb` regularly.
- You may spawn your own sub-agents for parts of your workstream; you remain responsible for their output and for this file's rules.

## Status (each session updates its own line)
- 1 · AI suite core: not started
- 2 · MCP + Blender bridge: not started
- 3 · Editor engine v2: not started
