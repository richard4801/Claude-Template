// One Claude (plans/one-claude.md): the chat list every app uses. Chats are per piece of work and follow the person
// across pages. The owner AND members use these routes; each person sees and opens only their own chats (the owner never
// sees a member's, a member never sees the owner's). Old per-place chats (Suite, Edit, Recreate, Camera) are listed
// here too, each starting on the page it belonged to. The owner's Mac still runs her turns on Claude Code through the
// thread routes (camera/claudeRoutes.ts); members (and the owner when her Mac is away) use the in-app turn below.
import { appTool } from './cardView.js';
import { and, desc, eq, ilike, isNull, isNotNull, lt, ne, sql, inArray } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { claudeMessages, claudeThreads } from '../camera/schema.js';
import { uploads } from '../db/schema.js';
import { parse } from '../camera/validate.js';
import type { ChatEvent, Director } from '../camera/director.js';
import type { ClaudeService } from '../camera/claude.js';
import { TITLE_MAX, threadBrief } from '../camera/claude.js';
import { storeAttachments } from '../camera/claudeAttachments.js';
import { assistantOf } from '../recreate/assistant.js';
import { ownChat, pageOf } from './chatTools.js';
import { memoryAdd, memoryRead, memoryRemove, memoryUpdate } from './memory.js';
import { pageLine, PageSchema } from './page.js';
import { permissionsOf } from './permissions.js';
import { UI_ERROR_CODES, uiOf } from './uiControl.js';
import { resultsOf } from './results.js';
import { claudeActions } from './schema.js';
import { checkEffort, checkModel, CLAUDE_MODELS, effectiveModel, personDefault, personEffort, setPersonDefault, setPersonEffort } from './models.js';

type Row = typeof claudeThreads.$inferSelect;
type P = { Params: { id: string } };

/**
 * Step 6b: the chat's own model rides in the brief (the Mac passes it to Claude Code as --model; none = the person's
 * default), and its own effort level (`--effort`; none = the person's last choice, else the model's default).
 */
const withModel = <B extends object>(b: B | undefined, model: string | null, effort: string | null) =>
  (b ? { ...b, ...(model ? { model } : {}), ...(effort ? { effort } : {}) } : b);

export const chatView = (t: Row, messageCount?: number) => {
  const page = pageOf(t);
  return compact({ id: t.id, title: t.title ?? undefined, kind: t.contextKind, page, lastOn: pageLine(page), model: t.model ?? undefined, effort: t.effort ?? undefined,
    archived: t.archivedAt ? true : undefined, claudeSessionId: t.claudeSessionId ?? undefined, createdAt: t.createdAt, updatedAt: t.updatedAt, messageCount,
    brief: withModel(t.contextKind === 'chat' ? threadBrief('chat', t.id) : threadBrief(t.contextKind, t.contextId), t.model, t.effort) });
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
    const b = parse(z.object({ title: z.string().trim().max(TITLE_MAX).optional(), archived: z.boolean().optional(), model: z.union([z.string().max(60), z.null()]).optional(),
      effort: z.union([z.string().max(10), z.null()]).optional() }).strict()
      .refine(x => x.title !== undefined || x.archived !== undefined || x.model !== undefined || x.effort !== undefined, 'title, archived, model or effort'), req.body);
    const t = await ownChat(ctx, req.user, req.params.id);
    const model = b.model !== undefined ? checkModel(b.model) : undefined;
    // The level must be one the chat's model takes (the model sent with it, else the chat's own, else the person's default).
    const effort = b.effort !== undefined ? checkEffort(b.effort, await effectiveModel(ctx, req.user, model !== undefined ? model : t.model)) : undefined;
    // A pick is also the person's last choice: new chats and chats without one start from it.
    if (effort) await setPersonEffort(ctx, req.user, effort);
    const [n] = await ctx.db.update(claudeThreads).set({ ...(b.title !== undefined ? { title: b.title || t.title } : {}),
      ...(model !== undefined ? { model } : {}), ...(effort !== undefined ? { effort } : {}),
      ...(b.archived !== undefined ? { archivedAt: b.archived ? Date.now() : null } : {}) }).where(eq(claudeThreads.id, t.id)).returning();
    const view = chatView(n!);
    void ctx.hub.emitTo(req.user.id, { type: 'claude', op: 'chat', chat: view });
    return view;
  });
  /**
   * Delete chats (owner, 2026-11-11: "messages are piling up"): the person's OWN chats only (anyone else's is 404). The
   * chat, its messages and turns go (a running turn is stopped), with its waiting approvals and result links; their
   * memory and anything they made (takes, outfits, …) stay.
   */
  app.delete<P>('/v1/claude/chats/:id', async req => {
    const t = await ownChat(ctx, req.user, req.params.id);
    await deleteChats(ctx, claude, req.user, [t.id]);
    return { ok: true, deleted: [t.id] };
  });
  /** Several at once: {ids} and/or {olderThanDays} (chats not used for that long). */
  app.post('/v1/claude/chats/delete', async req => {
    const b = parse(z.object({ ids: z.array(z.string().min(1).max(80)).max(200).optional(), olderThanDays: z.number().int().min(1).max(3650).optional() }).strict()
      .refine(x => (x.ids?.length ?? 0) > 0 || x.olderThanDays !== undefined, 'ids or olderThanDays'), req.body);
    const ids = new Set<string>();
    if (b.ids?.length) {
      const rows = await ctx.db.select({ id: claudeThreads.id }).from(claudeThreads)
        .where(and(inArray(claudeThreads.id, b.ids), eq(claudeThreads.ownerId, req.user.id), eq(claudeThreads.studioId, req.user.studioId)));
      if (rows.length !== new Set(b.ids).size) throw notFound('Chat');
      rows.forEach(r => ids.add(r.id));
    }
    if (b.olderThanDays !== undefined) {
      const before = Date.now() - b.olderThanDays * 86_400_000;
      const rows = await ctx.db.select({ id: claudeThreads.id }).from(claudeThreads)
        .where(and(eq(claudeThreads.ownerId, req.user.id), eq(claudeThreads.studioId, req.user.studioId), lt(claudeThreads.updatedAt, before)));
      rows.forEach(r => ids.add(r.id));
    }
    await deleteChats(ctx, claude, req.user, [...ids]);
    return { ok: true, deleted: [...ids] };
  });

  /**
   * Step 6b: the Claude models anyone can pick (plain-words speed and cost, the effort levels each takes and its own
   * default level), this person's default model and their last effort choice.
   */
  app.get('/v1/claude/models', async req => ({ models: CLAUDE_MODELS, default: await personDefault(ctx, req.user), studioDefault: ctx.config.DIRECTOR_MODEL,
    defaultEffort: await personEffort(ctx, req.user) }));
  app.put('/v1/claude/prefs', async req => {
    const b = parse(z.object({ defaultModel: z.union([z.string().max(60), z.null()]).optional(), defaultEffort: z.union([z.string().max(10), z.null()]).optional() }).strict()
      .refine(x => x.defaultModel !== undefined || x.defaultEffort !== undefined, 'defaultModel or defaultEffort'), req.body);
    if (b.defaultModel !== undefined) await setPersonDefault(ctx, req.user, checkModel(b.defaultModel));
    if (b.defaultEffort !== undefined) await setPersonEffort(ctx, req.user, checkEffort(b.defaultEffort));
    return { default: await personDefault(ctx, req.user), defaultEffort: await personEffort(ctx, req.user) };
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

  /** Files on this Mac: Claude Code's questions waiting for this person (the Mac shows them as approval cards). */
  app.get('/v1/claude/permissions', async req => ({ asks: permissionsOf(ctx).pending(req.user) }));
  app.post<P>('/v1/claude/permissions/:id', async (req, reply) => {
    const b = parse(z.object({ allow: z.boolean(), message: z.string().max(500).optional(),
      result: z.object({ uploadId: z.string().min(1).max(120), kind: z.enum(['image', 'clip', 'audio']), url: z.string().max(2000).optional(), name: z.string().max(200).optional(),
        durationSec: z.number().positive().max(36_000).optional() }).strict().optional() }).strict(), req.body);
    if (b.result) {
      // An upload the Mac made for upload_local_file: this person's, in this studio, confirmed.
      const [up] = await ctx.db.select({ id: uploads.id, state: uploads.state, createdBy: uploads.createdBy, kind: uploads.kind, contentType: uploads.contentType, storageKey: uploads.storageKey })
        .from(uploads).where(and(eq(uploads.id, b.result.uploadId), eq(uploads.studioId, req.user.studioId)));
      if (!up || (up.createdBy && up.createdBy !== req.user.id)) throw new ApiError(400, 'bad_request', 'result.uploadId: not a ready upload of yours');
      if (b.result.kind === 'audio') {
        // A sound (ci_de89873ab1de): an editor audio upload (presign + PUT, no confirm step), so its file is checked here.
        if (up.kind !== 'asset' || !up.contentType.startsWith('audio/')) throw new ApiError(400, 'bad_request', 'result.uploadId: not a sound upload of yours');
        if (up.state !== 'ready') {
          const head = await ctx.storage.head(up.storageKey);
          if (!head) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it to the URL first');
          await ctx.db.update(uploads).set({ state: 'ready', bytes: head.size }).where(eq(uploads.id, up.id));
        }
        b.result.url ??= `${ctx.config.PUBLIC_URL ?? ''}/uploads/${up.storageKey}`;
      } else if (up.state !== 'ready') {
        throw new ApiError(400, 'bad_request', 'result.uploadId: not a ready upload of yours');
      }
    }
    permissionsOf(ctx).answer(req.user, req.params.id, b);
    return reply.status(204).send();
  });

  /** The Mac says what it does with a question: shows its card, uploads (bytes so far, try n), checks the file. */
  app.post<P>('/v1/claude/permissions/:id/progress', async (req, reply) => {
    const b = parse(z.object({ phase: z.enum(['asking', 'uploading', 'confirming']), sentBytes: z.number().int().min(0).max(4 * 1024 ** 3).optional(),
      totalBytes: z.number().int().min(0).max(4 * 1024 ** 3).optional(), attempt: z.number().int().min(1).max(10).optional() }).strict(), req.body);
    permissionsOf(ctx).progress(req.user, req.params.id, b);
    return reply.status(204).send();
  });

  /** Claude operating the MUSE window (claude/uiControl.ts): calls waiting for this person's Mac; one Mac claims, acts, answers. */
  app.get('/v1/claude/ui', async req => ({ calls: uiOf(ctx).pending(req.user) }));
  app.post<P>('/v1/claude/ui/:id/claim', async req => {
    const b = parse(z.object({ device: z.string().min(1).max(120) }).strict(), req.body ?? {});
    return uiOf(ctx).claim(req.user, req.params.id, b.device);
  });
  app.post<P>('/v1/claude/ui/:id', { bodyLimit: 3 * 1024 * 1024 }, async (req, reply) => {
    const b = parse(z.object({ result: z.record(z.string(), z.unknown()).optional(),
      image: z.string().max(2_500_000).regex(/^[A-Za-z0-9+/=]+$/).optional(), // a small JPEG of the MUSE window, base64
      error: z.string().max(1000).optional(), code: z.enum(UI_ERROR_CODES).optional() }).strict(), req.body);
    if (b.result && JSON.stringify(b.result).length > 400_000) throw new ApiError(400, 'bad_request', 'result: too large (send fewer controls)');
    uiOf(ctx).answer(req.user, req.params.id, b);
    return reply.status(204).send();
  });

  /** Results arrive in the chat: one of the person's Macs claims a result before running Claude on it. */
  app.post<P>('/v1/claude/results/:id/claim', async req => resultsOf(ctx).claim(req.user, req.params.id));

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
    // One Claude: an old Camera chat, or any chat while the person is on the Camera page with a session open, runs the
    // director there (camera session tools + Blender through the Mac's relay), as the Camera page's own chat did.
    const pageNow = body.page ?? pageOf(t);
    const camId = t.contextKind === 'camera' ? t.contextId : pageNow?.name === 'camera' ? pageNow.ids?.cameraSessionId : undefined;
    const camera = !!camId;
    if (camera && hasImages) throw new ApiError(400, 'bad_request', 'attachments: the camera chat on the API takes text only');
    // The page first, so the turn sees where the person is. An old per-place chat becomes a chat that follows them.
    if (body.page) await ctx.db.update(claudeThreads).set({ page: body.page }).where(eq(claudeThreads.id, t.id));
    if (camera) await director.precheck(req.user, camId!, message);
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
    const sentCards = new Set<string>(), startedAt = Date.now();
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
      } else if (ev.type === 'tool' && ev.status === 'done') {
        // Cards (claude/cards.ts) any tool put up during this step: plan, clip, what changed, approve. Each once.
        uiQueue = uiQueue.then(async () => {
          const rows = await ctx.db.select().from(claudeMessages).where(and(eq(claudeMessages.threadId, t.id), eq(claudeMessages.role, 'tool')))
            .orderBy(desc(claudeMessages.createdAt)).limit(4);
          for (const m of rows.reverse()) {
            if (m.tool?.name !== 'card' && m.tool?.name !== 'approve') continue;
            if (sentCards.has(m.id) || m.createdAt < startedAt) continue;
            sentCards.add(m.id);
            write({ type: 'ui', name: m.tool.name, messageId: m.id, ui: appTool(m.tool).ui });
          }
        }).catch(() => undefined);
      }
    };
    try {
      const mine = await claude.mirrorFallback(req.user, t.id, 'user', message, attachments);
      if (camera) await director.run(req.user, camId!, message, send);
      else text = await assistantOf(ctx).run(req.user, t.id, 'chat', t.id, message, send, { attachments, skipMessageId: mine?.id as string | undefined }) || text;
      await claude.mirrorFallback(req.user, t.id, 'assistant', text);
    } finally {
      await uiQueue;
      if (open) res.end();
    }
  });
}


/** Deletes the person's own chats (already checked): each through the thread delete (stops a running turn, tells
 * their apps), plus the chat's waiting approvals and result links. Memory and made things are kept. */
export async function deleteChats(ctx: Ctx, claude: ClaudeService, u: AuthUser, ids: string[]) {
  for (const id of ids) {
    await claude.deleteThread(u, id);
    await ctx.db.delete(claudeActions).where(and(eq(claudeActions.chatId, id), eq(claudeActions.userId, u.id)));
    resultsOf(ctx).forgetChat(id);
  }
}
