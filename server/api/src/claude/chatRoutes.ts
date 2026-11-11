// One Claude (plans/one-claude.md): the chat list every app uses. Chats are per piece of work and follow the person
// across pages. The owner AND members use these routes; each person sees and opens only their own chats (the owner never
// sees a member's, a member never sees the owner's). Old per-place chats (Suite, Edit, Recreate, Camera) are listed
// here too, each starting on the page it belonged to. The owner's Mac still runs her turns on Claude Code through the
// thread routes (camera/claudeRoutes.ts); members (and the owner when her Mac is away) use the in-app turn below.
import { and, desc, eq, ilike, isNull, isNotNull, ne, sql, inArray } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { claudeMessages, claudeThreads } from '../camera/schema.js';
import { parse } from '../camera/validate.js';
import type { ChatEvent, Director } from '../camera/director.js';
import type { ClaudeService } from '../camera/claude.js';
import { TITLE_MAX, threadBrief } from '../camera/claude.js';
import { storeAttachments } from '../camera/claudeAttachments.js';
import { assistantOf } from '../recreate/assistant.js';
import { ownChat, pageOf } from './chatTools.js';
import { memoryAdd, memoryRead, memoryRemove, memoryUpdate } from './memory.js';
import { pageLine, PageSchema } from './page.js';
import { checkModel, CLAUDE_MODELS, personDefault, setPersonDefault } from './models.js';

type Row = typeof claudeThreads.$inferSelect;
type P = { Params: { id: string } };

/** Step 6b: the chat's own model rides in the brief (the Mac passes it to Claude Code as --model; none = the person's default). */
const withModel = <B extends object>(b: B | undefined, model: string | null) => (b && model ? { ...b, model } : b);

export const chatView = (t: Row, messageCount?: number) => {
  const page = pageOf(t);
  return compact({ id: t.id, title: t.title ?? undefined, kind: t.contextKind, page, lastOn: pageLine(page), model: t.model ?? undefined,
    archived: t.archivedAt ? true : undefined, claudeSessionId: t.claudeSessionId ?? undefined, createdAt: t.createdAt, updatedAt: t.updatedAt, messageCount,
    brief: withModel(t.contextKind === 'chat' ? threadBrief('chat', t.id) : threadBrief(t.contextKind, t.contextId), t.model) });
};

export async function listChats(ctx: Ctx, u: AuthUser, query: unknown) {
  const q = parse(z.object({ q: z.string().trim().max(80).optional(), limit: z.coerce.number().int().min(1).max(100).optional(), archived: z.enum(['0', '1']).optional() }).strict(), query ?? {});
  const rows = await ctx.db.select().from(claudeThreads).where(and(eq(claudeThreads.ownerId, u.id), eq(claudeThreads.studioId, u.studioId),
    q.archived === '1' ? isNotNull(claudeThreads.archivedAt) : isNull(claudeThreads.archivedAt),
    q.q ? ilike(claudeThreads.title, `%${q.q.replace(/[%_\\]/g, '')}%`) : undefined))
    .orderBy(desc(claudeThreads.updatedAt)).limit(q.limit ?? 50);
  const counts = rows.length ? await ctx.db.select({ threadId: claudeMessages.threadId, n: sql<number>`count(*)::int` }).from(claudeMessages)
    .where(and(inArray(claudeMessages.threadId, rows.map(r => r.id)), ne(claudeMessages.role, 'tool'))).groupBy(claudeMessages.threadId) : [];
  const n = new Map(counts.map(c => [c.threadId, Number(c.n)]));
  return { chats: rows.map(r => chatView(r, n.get(r.id) ?? 0)) };
}

export async function createChat(ctx: Ctx, u: AuthUser, body: unknown) {
  const b = parse(z.object({ title: z.string().trim().max(TITLE_MAX).optional(), page: PageSchema.optional() }).strict(), body ?? {});
  const now = Date.now(), id = uid('ct');
  const [t] = await ctx.db.insert(claudeThreads).values({ id, studioId: u.studioId, ownerId: u.id, contextKind: 'chat', contextId: id, contextKey: 'chat',
    title: b.title || null, page: b.page ?? null, createdAt: now, updatedAt: now }).returning();
  const view = chatView(t!, 0);
  void ctx.hub.emitTo(u.id, { type: 'claude', op: 'chat', chat: view });
  return view;
}

export async function registerChatRoutes(app: FastifyInstance, ctx: Ctx, claude: ClaudeService, director: Director) {
  app.get('/v1/claude/chats', async req => listChats(ctx, req.user, req.query));
  app.post('/v1/claude/chats', async req => createChat(ctx, req.user, req.body));
  app.get<P>('/v1/claude/chats/:id', async req => {
    const t = await ownChat(ctx, req.user, req.params.id);
    const full = await claude.get(req.user, t.id);
    return { ...full, ...chatView(t) };
  });
  app.patch<P>('/v1/claude/chats/:id', async req => {
    const b = parse(z.object({ title: z.string().trim().max(TITLE_MAX).optional(), archived: z.boolean().optional(), model: z.union([z.string().max(60), z.null()]).optional() }).strict()
      .refine(x => x.title !== undefined || x.archived !== undefined || x.model !== undefined, 'title, archived or model'), req.body);
    const t = await ownChat(ctx, req.user, req.params.id);
    const [n] = await ctx.db.update(claudeThreads).set({ ...(b.title !== undefined ? { title: b.title || t.title } : {}),
      ...(b.model !== undefined ? { model: checkModel(b.model) } : {}),
      ...(b.archived !== undefined ? { archivedAt: b.archived ? Date.now() : null } : {}) }).where(eq(claudeThreads.id, t.id)).returning();
    const view = chatView(n!);
    void ctx.hub.emitTo(req.user.id, { type: 'claude', op: 'chat', chat: view });
    return view;
  });
  /** Step 6b: the Claude models anyone can pick (plain-words speed and cost) and this person's default. */
  app.get('/v1/claude/models', async req => ({ models: CLAUDE_MODELS, default: await personDefault(ctx, req.user), studioDefault: ctx.config.DIRECTOR_MODEL }));
  app.put('/v1/claude/prefs', async req => {
    const b = parse(z.object({ defaultModel: z.union([z.string().max(60), z.null()]) }).strict(), req.body);
    await setPersonDefault(ctx, req.user, checkModel(b.defaultModel));
    return { default: await personDefault(ctx, req.user) };
  });

  /** The app reports the page as the person moves (debounced); Claude reads it each turn (where_am_i over MCP). */
  app.put<P>('/v1/claude/chats/:id/page', async req => {
    const page = parse(PageSchema, (req.body as { page?: unknown } | undefined)?.page);
    const t = await ownChat(ctx, req.user, req.params.id);
    await ctx.db.update(claudeThreads).set({ page }).where(eq(claudeThreads.id, t.id));
    return { ok: true, page, lastOn: pageLine(page) };
  });
  /** The person's OWN memory (per person: the owner's is hers, a member's is theirs). Remember on Claude's question saves here. */
  app.get('/v1/claude/memory', async req => {
    const q = parse(z.object({ area: z.string().max(20).optional(), characterId: z.string().max(80).optional() }).strict(), req.query ?? {});
    return { rules: await memoryRead(ctx, req.user, q), canEdit: true };
  });
  app.post('/v1/claude/memory', async req => memoryAdd(ctx, req.user, (req.body ?? {}) as Record<string, unknown>, 'owner'));
  app.patch<P>('/v1/claude/memory/:id', async req => memoryUpdate(ctx, req.user, req.params.id, (req.body ?? {}) as Record<string, unknown>));
  app.delete<P>('/v1/claude/memory/:id', async (req, reply) => { await memoryRemove(ctx, req.user, req.params.id); return reply.status(204).send(); });

  /**
   * A turn in the app on the STUDIO's Claude key (SSE; the opt-in API fallback, billed to the studio's Anthropic account).
   * Owner only: everyone else runs Claude on their own Claude plan on their own computer (owner, 2026-11-11).
   */
  app.post<P>('/v1/claude/chats/:id/turn', { config: { owner: true } }, async (req, reply) => {
    const t = await ownChat(ctx, req.user, req.params.id);
    if (!(await claude.fallbackAllowed(req.user))) throw new ApiError(409, 'fallback_off', 'Claude in the app is off · turn it on in Settings → Connections');
    const body = parse(z.object({ text: z.string().max(8000).optional(), attachments: z.unknown().optional(), page: PageSchema.optional() }).strict(), req.body ?? {});
    const message = body.text ?? '';
    const hasImages = Array.isArray(body.attachments) && body.attachments.length > 0;
    const camera = t.contextKind === 'camera';
    if (camera && hasImages) throw new ApiError(400, 'bad_request', 'attachments: the camera chat on the API takes text only');
    // The page first, so the turn sees where the person is. An old per-place chat becomes a chat that follows them.
    if (body.page) await ctx.db.update(claudeThreads).set({ page: body.page }).where(eq(claudeThreads.id, t.id));
    if (camera) await director.precheck(req.user, t.contextId, message);
    else await assistantOf(ctx).precheck(req.user, 'chat', t.id, message, hasImages);
    const attachments = camera ? [] : await storeAttachments(ctx, req.user, t.id, body.attachments);
    reply.hijack();
    const res = reply.raw;
    req.raw.socket?.setNoDelay?.(true);
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache, no-store, no-transform', connection: 'keep-alive', 'x-accel-buffering': 'no' });
    let open = true, text = '';
    req.raw.on('close', () => { open = false; });
    const write = (e: unknown) => { if (open) res.write(`data: ${JSON.stringify(e)}\n\n`); };
    let uiQueue = Promise.resolve();
    const send = (e: ChatEvent) => {
      if (e.type === 'text') text += e.delta;
      if (e.type === 'tool') text = '';
      write(e);
      // Lines the app acts on (open a page, "Remembered … Undo") also arrive in the stream, right after their tool.
      const ev = e as { type: string; name?: string; status?: string };
      if (ev.type === 'tool' && ev.status === 'done' && (ev.name === 'open_page' || ev.name === 'memory_add' || ev.name === 'memory_suggest')) {
        uiQueue = uiQueue.then(async () => {
          const [m] = await ctx.db.select().from(claudeMessages).where(and(eq(claudeMessages.threadId, t.id), eq(claudeMessages.role, 'tool')))
            .orderBy(desc(claudeMessages.createdAt)).limit(1);
          if (m?.tool?.ui && m.tool.name === ev.name) write({ type: 'ui', name: m.tool.name, ui: m.tool.ui });
        }).catch(() => undefined);
      }
    };
    try {
      const mine = await claude.mirrorFallback(req.user, t.id, 'user', message, attachments);
      if (camera) await director.run(req.user, t.contextId, message, send);
      else text = await assistantOf(ctx).run(req.user, t.id, 'chat', t.id, message, send, { attachments, skipMessageId: mine?.id as string | undefined }) || text;
      await claude.mirrorFallback(req.user, t.id, 'assistant', text);
    } finally {
      await uiQueue;
      if (open) res.end();
    }
  });
}

