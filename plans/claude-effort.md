# Claude effort levels (owner, 2026-11-13: "Add effort levels for Claude in the app, just as we have here")

## Where MUSE runs Claude, and effort on each path
| Path | Model chosen by | Effort today → with this work | Billing |
|---|---|---|---|
| Mac Claude panel → Claude Code (`ClaudeCommand`, relay) | chat model → person default (`--model`) | none (Claude Code's own default) → `--effort <level>` | person's own Claude plan |
| In-app chat turn `POST /v1/claude/chats/:id/turn` and thread `api-turn` (recreate/assistant.ts) | `effectiveModel` (chat → person → DIRECTOR_MODEL) | fixed `DIRECTOR_EFFORT` (high) → chat's level, else last choice, else model default | studio API key; owner only, opt-in in Settings → Connections |
| Camera director (camera/director.ts) | DIRECTOR_MODEL | DIRECTOR_EFFORT (unchanged) | studio key |
| Edit translate (editor/translate.ts) | Haiku 5.5 / Sonnet 5.5 by quality | low / medium fixed (unchanged) | studio key |
| RECREATE_BRIEF_MODEL and other one-shot calls | config | unchanged | studio key |

Claude Code CLI: `--effort low|medium|high|xhigh|max`. API: `output_config.effort`, same five values.

Levels per model (all five on every listed model; default in brackets): Fable 5.2 [high], Opus 5.5 [medium],
Sonnet 5.5 [high], Haiku 5.5 [medium]. Older models (not listed in MUSE): Opus 4.6/Sonnet 4.6 low–high + max (no xhigh);
Opus 4.5 low–high; Sonnet 4.5 / Haiku 4.5 none. The catalog's `efforts: []` hides the picker for such a model.

## Rules
- Per chat (`claude_threads.effort`), else the person's last choice (`claude_prefs.default_effort`, set by every pick),
  else the model's own default. A level the model doesn't take falls back to the model's default.
- Cost: on the plan, higher levels use more of the plan, no per-call spend. On the in-app API path (studio key) a higher
  level means more thinking/output tokens (Opus 5.5 output $20/M); Max can cost several times Medium on hard turns.
  That path is already owner-only and opt-in (the existing spend rule), so no extra card. Behaviour change: with no
  pick, the in-app turn now runs at the model's default (Opus 5.5: medium) instead of DIRECTOR_EFFORT high.

## Shipped
- Server (branch claude/claude-effort): migration 0036; GET /v1/claude/models adds `efforts`, `defaultEffort` per model
  and the person's `defaultEffort`; PATCH /v1/claude/chats/:id `{effort}`; PUT /v1/claude/prefs `{defaultEffort}`;
  brief carries `effort`; test/claude-effort.test.ts.
- Mac: plans/patches/claude-effort-mac.patch (applies on claude/mac-bundle-10 46ce022). Android after Mac approval.
