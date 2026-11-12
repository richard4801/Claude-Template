// Routes for Claude chat threads (plans/api.md "Claude on the owner's plan"). Owner only. Registered by routes/camera.ts.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { ApiError } from '../errors.js';
import type { ChatEvent, Director } from './director.js';
import { ClaudeService } from './claude.js';
import { assistantOf } from '../recreate/assistant.js';
import type { CameraService } from './service.js';
import { storeAttachments } from './claudeAttachments.js';
import { registerChatRoutes } from '../claude/chatRoutes.js';
import { CHAT_TOOLS } from '../claude/chatTools.js';
import { APP_TOOLS } from '../claude/appTools.js';
import { registerSuggestionRoutes } from '../claude/suggest.js';
import { registerCardRoutes } from '../claude/cards.js';
import { assistOf } from '../suite/assist.js';
import { CHAT_REGISTRY } from '../claude/registry.js';
import { ACTION_TOOLS, SETTINGS_TOOLS, registerActionRoutes } from '../claude/actions.js';
import { ISSUE_ADMIN_TOOLS, ISSUE_TOOLS, registerIssueRoutes } from '../claude/issues.js';
import { PERMISSION_TOOL, UPLOAD_TOOL, permissionsOf } from '../claude/permissions.js';
import { uiOf } from '../claude/uiControl.js';
import * as mcpTools from '../mcp/tools.js';

type P = { Params: { id: string } };

export async function registerClaudeRoutes(app: FastifyInstance, ctx: Ctx, camera: CameraService, director: Director) {
  const claude = new ClaudeService(ctx, camera);
  app.addHook('onClose', async () => claude.close());
  const owner = { config: { owner: true } };
  // One Claude (owner, 2026-11-11): every member runs Claude on their own Claude plan on their own computer, like the
  // owner, so the chat routes serve everyone's OWN threads (each query is by the caller's id). The studio switch and
  // the studio-key turn stay the owner's.
  const mine = {};

  app.get('/v1/claude/status', mine, async req => claude.status(req.user));
  app.patch('/v1/claude/settings', owner, async req => claude.setSettings(req.user, req.body));
  app.post('/v1/claude/mac/heartbeat', mine, async req => claude.heartbeat(req.user, req.body));
  app.post('/v1/claude/threads', mine, async req => claude.openThread(req.user, req.body));
  app.get('/v1/claude/threads', mine, async req => claude.list(req.user, req.query)); // WS18: a place's list of chats
  app.get<P>('/v1/claude/threads/:id', mine, async req => claude.get(req.user, req.params.id));
  app.delete<P>('/v1/claude/threads/:id', mine, async req => claude.deleteThread(req.user, req.params.id));
  app.patch<P>('/v1/claude/threads/:id', mine, async req => claude.patchThread(req.user, req.params.id, req.body));
  app.post<P>('/v1/claude/threads/:id/messages', mine, async (req, reply) => {
    try {
      return reply.status(202).send(await claude.ask(req.user, req.params.id, req.body));
    } catch (e) {
      const extra = (e as { extra?: Record<string, unknown> }).extra;
      if (e instanceof ApiError && extra) return reply.status(e.status).send({ error: e.message, code: e.code, ...extra });
      throw e;
    }
  });
  app.get('/v1/claude/turns', mine, async req => claude.pending(req.user));
  app.post<P>('/v1/claude/turns/:id/claim', mine, async req => claude.claim(req.user, req.params.id));
  app.post<P>('/v1/claude/turns/:id/stop', mine, async req => claude.stop(req.user, req.params.id));
  app.post<P>('/v1/claude/threads/:id/events', { ...mine, bodyLimit: 4 * 1024 * 1024 }, async req => claude.events(req.user, req.params.id, req.body));

  // The opt-in API-key fallback (billed per use): the camera chat's director, mirrored into the thread.
  app.post<P>('/v1/claude/threads/:id/api-turn', owner, async (req, reply) => {
    const t = await claude.thread(req.user, req.params.id);
    if (!(await claude.fallbackAllowed(req.user))) throw new ApiError(409, 'fallback_off', 'The API fallback is off · turn it on in Settings → Connections');
    const body = (req.body ?? {}) as { text?: unknown; attachments?: unknown };
    const message = typeof body.text === 'string' ? body.text : body.text;
    // workstream 1: Recreate and Edit threads run MUSE's own editor loop; Camera threads keep the director.
    const kind = t.contextKind === 'camera' ? null : t.contextKind;
    const hasImages = Array.isArray(body.attachments) && body.attachments.length > 0;
    if (!kind && hasImages) throw new ApiError(400, 'bad_request', 'attachments: the camera chat on the API takes text only');
    const ctxId = kind === 'chat' ? t.id : t.contextId; // One Claude: a chat is its own context
    if (kind) await assistantOf(ctx).precheck(req.user, kind, ctxId, message, hasImages);
    else await director.precheck(req.user, t.contextId, message);
    // workstream 1: attached images are checked and stored before the stream starts (plain JSON errors).
    const attachments = kind ? await storeAttachments(ctx, req.user, t.id, body.attachments) : [];
    reply.hijack();
    const res = reply.raw;
    req.raw.socket?.setNoDelay?.(true);
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache, no-store, no-transform', connection: 'keep-alive', 'x-accel-buffering': 'no' });
    let open = true, text = '';
    req.raw.on('close', () => { open = false; });
    const send = (e: ChatEvent) => {
      if (e.type === 'text') text += e.delta;
      if (e.type === 'tool') text = ''; // keep only the final answer
      if (open) res.write(`data: ${JSON.stringify(e)}\n\n`);
    };
    const mine = await claude.mirrorFallback(req.user, t.id, 'user', String(message ?? ''), attachments);
    if (kind) text = await assistantOf(ctx).run(req.user, t.id, kind, ctxId, String(message ?? ''), send, { attachments, skipMessageId: mine?.id as string | undefined }) || text;
    else await director.run(req.user, t.contextId, String(message), send);
    await claude.mirrorFallback(req.user, t.id, 'assistant', text);
    if (open) res.end();
  });
  // One Claude (plans/one-claude.md): the chat list for the owner and members, and the chat tools on the MCP server
  // (Claude Code on the owner's Mac passes its chatId).
  await registerChatRoutes(app, ctx, claude, director);
  // Claude's own reports and captured tool errors (owner reads them; plans/HANDOVER.md 4a, 16:15).
  await registerIssueRoutes(app, ctx);
  await registerActionRoutes(app, ctx); // the person's Approve cards for Claude's gated actions
  // Chat cards (claude/cards.ts): Undo on a "What I changed" row, and the page's quick-action chips.
  await registerCardRoutes(app, ctx, (u, assistId, fn) => assistOf(ctx).rewrite(u, assistId, fn));
  registerSuggestionRoutes(app, ctx);
  // Every tool of the one registry is on the MCP server too (Claude Code on the Mac): members see those members may use
  // (mcp/server.ts memberOk). Listing the registry, not each set, so a new set can't be left off the MCP list again.
  (mcpTools as { registerMcpTools: (tools: unknown[]) => void }).registerMcpTools([...CHAT_REGISTRY, ...CHAT_TOOLS, ...ISSUE_TOOLS, ...ISSUE_ADMIN_TOOLS, ...APP_TOOLS, ...ACTION_TOOLS, ...SETTINGS_TOOLS, PERMISSION_TOOL, UPLOAD_TOOL]);
  app.addHook('onClose', async () => permissionsOf(ctx).close());
  app.addHook('onClose', async () => uiOf(ctx).close());
  return claude;
}
