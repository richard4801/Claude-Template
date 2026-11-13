// Claude chat threads on the owner's Claude plan (plans/api.md "Claude on the owner's plan"). The owner's Mac runs Claude
// Code and mirrors each turn here; the phone's messages become turns the Mac claims and answers (the Blender relay's
// queue/claim pattern). The server never runs Claude itself, except the opt-in API-key fallback (camera threads).
import { appTool } from '../claude/cardView.js';
import { and, desc, eq, inArray, isNull, ne, sql } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { claudeMessages, claudeSettings, claudeThreads, claudeTurns, type CameraAssetKind } from './schema.js';
import type { CameraService } from './service.js';
import { parse } from './validate.js';
import { EDIT_PROMPT, onePrompt, RECREATE_PROMPT } from '../recreate/assistant.js';
import { CHAT_REGISTRY } from '../claude/registry.js';
import { capabilityNote } from '../claude/capability.js';
import { pageOfContext } from '../claude/page.js';
import { SUITE_PROMPT } from '../suite/mcpTools.js';
import { attachmentViews, storeAttachments, type Attachment } from './claudeAttachments.js';

type ThreadRow = typeof claudeThreads.$inferSelect;
type MessageRow = typeof claudeMessages.$inferSelect;
type TurnRow = typeof claudeTurns.$inferSelect;
export type ClaudeCode = { installed: boolean; signedIn: boolean; version?: string; model?: string };

export const MAC_OFFLINE_AFTER_MS = 45_000, CLAIM_TIMEOUT_MS = 90_000, SILENT_TURN_MS = 10 * 60_000;
export const OPEN_IN_CLAUDE_URL = 'https://claude.ai/new';

const ToolEv = z.object({ type: z.literal('tool'), id: z.string().min(1).max(100), name: z.string().min(1).max(120), status: z.enum(['running', 'done', 'error']),
  summary: z.string().max(300).optional(), input: z.unknown().optional() });
const ClaudeEvent = z.discriminatedUnion('type', [
  z.object({ type: z.literal('user'), text: z.string().max(20_000), attachments: z.array(z.object({ uploadId: z.string().max(80) }).strict()).max(4).optional() /* workstream 1 */ }),
  z.object({ type: z.literal('text'), delta: z.string().max(20_000) }),
  z.object({ type: z.literal('assistant'), text: z.string().max(100_000) }),
  ToolEv,
  z.object({ type: z.literal('image'), data: z.string().max(2_800_000), mimeType: z.enum(['image/png', 'image/jpeg']) }),
  z.object({ type: z.literal('done'), ok: z.boolean(), error: z.string().max(2000).optional(), model: z.string().max(80).optional() }),
]);
export type ClaudeEventIn = z.infer<typeof ClaudeEvent>;

export class ClaudeService {
  private presence = new Map<string, { at: number; claudeCode: ClaudeCode }>();
  private timers = new Map<string, NodeJS.Timeout>();
  /** Tests shorten these. */
  claimTimeoutMs = CLAIM_TIMEOUT_MS; silentTurnMs = SILENT_TURN_MS;
  constructor(private ctx: Ctx, private camera: CameraService) {}
  private get db() { return this.ctx.db; }

  // ------------------------------------------------------------------ status
  private macOf(userId: string) {
    const p = this.presence.get(userId);
    const online = !!p && Date.now() - p.at < MAC_OFFLINE_AFTER_MS;
    return { online, claudeCode: online ? p!.claudeCode : { installed: false, signedIn: false } };
  }
  macReady(userId: string) { const m = this.macOf(userId); return m.online && m.claudeCode.installed && m.claudeCode.signedIn; }

  private async settings(studioId: string) {
    const [s] = await this.db.select().from(claudeSettings).where(eq(claudeSettings.studioId, studioId));
    return { apiFallback: !!s?.apiFallback };
  }

  async status(u: AuthUser) {
    const [running] = await this.db.select({ id: claudeTurns.id }).from(claudeTurns).where(and(eq(claudeTurns.ownerId, u.id), eq(claudeTurns.state, 'running'))).limit(1);
    const mac = this.macOf(u.id);
    return {
      mac: compact({ online: mac.online, claudeCode: compact(mac.claudeCode), answeringTurn: running?.id }),
      apiFallback: { available: !!this.ctx.config.ANTHROPIC_API_KEY, enabled: (await this.settings(u.studioId)).apiFallback },
      connectorUrl: `${this.ctx.publicBase()}/mcp`, openInClaudeUrl: OPEN_IN_CLAUDE_URL,
    };
  }

  async setSettings(u: AuthUser, body: unknown) {
    const b = parse(z.object({ apiFallback: z.boolean() }).strict(), body);
    await this.db.insert(claudeSettings).values({ studioId: u.studioId, apiFallback: b.apiFallback, updatedAt: Date.now() })
      .onConflictDoUpdate({ target: claudeSettings.studioId, set: { apiFallback: b.apiFallback, updatedAt: Date.now() } });
    return this.emitStatus(u);
  }

  private async emitStatus(u: AuthUser) {
    const status = await this.status(u);
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'status', status });
    return status;
  }

  async heartbeat(u: AuthUser, body: unknown) {
    const b = parse(z.object({ claudeCode: z.object({ installed: z.boolean(), signedIn: z.boolean(), version: z.string().max(60).optional(), model: z.string().max(80).optional() }) }), body);
    const before = this.macReady(u.id), beforeOnline = this.macOf(u.id).online;
    this.presence.set(u.id, { at: Date.now(), claudeCode: b.claudeCode });
    if (before !== this.macReady(u.id) || !beforeOnline) await this.emitStatus(u);
    return { ok: true, pending: await this.pending(u) };
  }

  // ------------------------------------------------------------------ threads
  private threadView = (t: ThreadRow) => compact({ id: t.id, contextKind: t.contextKind, contextId: t.contextId, claudeSessionId: t.claudeSessionId ?? undefined,
    contextKey: t.contextKey ?? undefined, title: t.title ?? undefined, // WS18: the chat's list and name
    createdAt: t.createdAt, updatedAt: t.updatedAt, model: t.model ?? undefined, effort: t.effort ?? undefined,
    brief: (b => (b ? { ...b, ...(t.model ? { model: t.model } : {}), ...(t.effort ? { effort: t.effort } : {}) } : b))(threadBrief(t.contextKind, t.contextKind === 'chat' ? t.id : t.contextId)) });
  private async messageView(m: MessageRow) {
    return compact({ id: m.id, threadId: m.threadId, role: m.role, source: m.source, text: m.text, turnId: m.turnId ?? undefined, tool: m.tool ? appTool(m.tool) : undefined,
      image: m.imageKey ? { url: await this.ctx.storage.presignGet(m.imageKey, 3600) } : undefined, attachments: await attachmentViews(this.ctx, m.attachments), createdAt: m.createdAt });
  }
  turnView = async (t: TurnRow) => compact({ id: t.id, threadId: t.threadId, text: t.text, from: t.from, state: t.state, error: t.error ?? undefined,
    attachments: await attachmentViews(this.ctx, t.attachments), // workstream 1: the images the Mac downloads for its turn
    createdAt: t.createdAt, claimedAt: t.claimedAt ?? undefined, finishedAt: t.finishedAt ?? undefined });

  async thread(u: AuthUser, id: string) {
    const [t] = await this.db.select().from(claudeThreads).where(and(eq(claudeThreads.id, id), eq(claudeThreads.ownerId, u.id)));
    if (!t) throw notFound('Thread');
    return t;
  }

  /**
   * POST /v1/claude/threads {contextKind, contextId, new?, title?}: the context's most recent chat (made if there is none),
   * or with `new: true` a new chat in the same list (WS18: each place keeps a list of chats the owner switches between).
   */
  async openThread(u: AuthUser, body: unknown) {
    // One Claude (plans/one-claude.md): {contextKind: 'chat', contextId: <one of the owner's chats>} opens that chat. An old
    // per-place chat (Suite, Edit, Recreate) becomes a chat that follows the owner, starting on its own page; Camera
    // chats keep their director.
    const asChat = body as { contextKind?: unknown; contextId?: unknown } | null;
    if (asChat?.contextKind === 'chat') {
      const t = await this.thread(u, String(asChat.contextId ?? ''));
      if (t.contextKind === 'chat' || t.contextKind === 'camera') return this.threadView(t);
      const [n] = await this.db.update(claudeThreads).set({ contextKind: 'chat', page: t.page ?? pageOfContext(t.contextKind, t.contextId, t.contextKey) ?? null })
        .where(eq(claudeThreads.id, t.id)).returning();
      return this.threadView(n!);
    }
    const b = parse(z.object({ /* 'chat' threads: POST /v1/claude/chats */ contextKind: z.enum(['camera', 'edit', 'recreate', 'suite']), contextId: z.string().regex(/^[A-Za-z0-9_-]{1,80}$/),
      new: z.boolean().optional(), title: z.string().trim().max(TITLE_MAX).optional() }).strict(), body);
    if (b.contextKind === 'camera') await this.camera.row(u, b.contextId);
    // workstream 1: a Recreate thread is about one of the owner's references.
    if (b.contextKind === 'recreate') await (await import('../recreate/references.js')).recreateOf(this.ctx).row(u, b.contextId);
    let key = `${b.contextKind}:${b.contextId}`;
    if (b.contextKind === 'suite') { // workstream 1: Claude in the AI Suite; WS18: its chats are listed by the composer's tool
      const a = await (await import('../suite/assist.js')).assistOf(this.ctx).row(u, b.contextId);
      key = suiteKey((a.draft as { tool?: unknown }).tool);
    }
    const where = and(eq(claudeThreads.ownerId, u.id), eq(claudeThreads.contextKind, b.contextKind), eq(claudeThreads.contextId, b.contextId));
    if (!b.new) {
      const [found] = await this.db.select().from(claudeThreads).where(where).orderBy(desc(claudeThreads.updatedAt)).limit(1);
      if (found) {
        if (found.contextKey) return this.threadView(found);
        const [n] = await this.db.update(claudeThreads).set({ contextKey: key }).where(eq(claudeThreads.id, found.id)).returning();
        return this.threadView(n!);
      }
    }
    const now = Date.now();
    const [t] = await this.db.insert(claudeThreads).values({ id: uid('ct'), studioId: u.studioId, ownerId: u.id, contextKind: b.contextKind, contextId: b.contextId,
      contextKey: key, title: b.title || null, createdAt: now, updatedAt: now }).returning();
    const view = this.threadView(t!);
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'thread', thread: view });
    return view;
  }

  /**
   * GET /v1/claude/threads?key=suite:photo (WS18): the chats of one list, newest first, each with its title (the owner's,
   * else the first message's words), when it was last used and how many messages it has. Owner only, like every thread.
   */
  async list(u: AuthUser, query: unknown) {
    const q = parse(z.object({ key: z.string().regex(KEY_RE), limit: z.coerce.number().int().min(1).max(100).optional() }).strict(), query ?? {});
    const rows = await this.db.select().from(claudeThreads).where(and(eq(claudeThreads.ownerId, u.id), eq(claudeThreads.contextKey, q.key)))
      .orderBy(desc(claudeThreads.updatedAt)).limit(q.limit ?? 50);
    const counts = rows.length ? await this.db.select({ threadId: claudeMessages.threadId, n: sql<number>`count(*)::int` }).from(claudeMessages)
      .where(and(inArray(claudeMessages.threadId, rows.map(r => r.id)), ne(claudeMessages.role, 'tool'))).groupBy(claudeMessages.threadId) : [];
    const n = new Map(counts.map(c => [c.threadId, Number(c.n)]));
    return { key: q.key, threads: rows.map(r => ({ ...this.threadView(r), messageCount: n.get(r.id) ?? 0 })) };
  }

  /** DELETE /v1/claude/threads/{id} (WS18): the chat and its messages. A turn still running in it is stopped. */
  async deleteThread(u: AuthUser, id: string) {
    const t = await this.thread(u, id);
    const open = await this.db.select().from(claudeTurns).where(and(eq(claudeTurns.threadId, t.id), inArray(claudeTurns.state, ['queued', 'running'])));
    for (const turn of open) {
      const timer = this.timers.get(turn.id); if (timer) { clearTimeout(timer); this.timers.delete(turn.id); }
      if (turn.state === 'running') void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'stop', turnId: turn.id });
    }
    await this.db.delete(claudeThreads).where(eq(claudeThreads.id, t.id));
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'threadDeleted', threadId: t.id, contextKey: t.contextKey ?? undefined });
    if (open.length) void this.emitStatus(u);
    return { ok: true, id: t.id };
  }

  async get(u: AuthUser, id: string) {
    const t = await this.thread(u, id);
    const rows = (await this.db.select().from(claudeMessages).where(eq(claudeMessages.threadId, t.id)).orderBy(desc(claudeMessages.createdAt)).limit(100)).reverse();
    const [active] = await this.db.select().from(claudeTurns).where(and(eq(claudeTurns.threadId, t.id), inArray(claudeTurns.state, ['queued', 'running']))).limit(1);
    return { ...this.threadView(t), messages: await Promise.all(rows.map(m => this.messageView(m))), ...(active ? { activeTurn: await this.turnView(active) } : {}) };
  }

  /** PATCH {claudeSessionId?, title?}: the Mac's Claude Code session, or the owner's name for the chat (WS18; "" goes back to the automatic one). */
  async patchThread(u: AuthUser, id: string, body: unknown) {
    const b = parse(z.object({ claudeSessionId: z.string().regex(/^[A-Za-z0-9_-]{1,100}$/).optional(), title: z.string().trim().max(TITLE_MAX).optional() }).strict()
      .refine(x => x.claudeSessionId !== undefined || x.title !== undefined, 'claudeSessionId or title'), body);
    const t = await this.thread(u, id);
    const set: Partial<ThreadRow> = {};
    if (b.claudeSessionId !== undefined) { set.claudeSessionId = b.claudeSessionId; set.updatedAt = Date.now(); }
    if (b.title !== undefined) set.title = b.title || (await this.firstWords(t.id)); // a rename doesn't move the chat up the list
    const [n] = await this.db.update(claudeThreads).set(set).where(eq(claudeThreads.id, t.id)).returning();
    const view = this.threadView(n!);
    if (b.title !== undefined) void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'thread', thread: view });
    return view;
  }

  /** The automatic title: the first message's words (without the app's context line), or none yet. */
  private async firstWords(threadId: string) {
    const [m] = await this.db.select({ text: claudeMessages.text }).from(claudeMessages).where(and(eq(claudeMessages.threadId, threadId), eq(claudeMessages.role, 'user')))
      .orderBy(claudeMessages.createdAt).limit(1);
    return m ? autoTitle(m.text) : null;
  }

  private async addMessage(u: AuthUser, threadId: string, m: Omit<typeof claudeMessages.$inferInsert, 'id' | 'threadId' | 'createdAt'>) {
    const [row] = await this.db.insert(claudeMessages).values({ id: uid('cm'), threadId, createdAt: Date.now(), ...m }).returning();
    // WS18: the chat's first words name it until the owner renames it.
    const title = m.role === 'user' ? autoTitle(m.text ?? '') : null;
    const [th] = await this.db.update(claudeThreads).set({ updatedAt: Date.now() }).where(eq(claudeThreads.id, threadId)).returning();
    if (title && th && !th.title) {
      const [named] = await this.db.update(claudeThreads).set({ title }).where(and(eq(claudeThreads.id, threadId), isNull(claudeThreads.title))).returning();
      if (named) void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'thread', thread: this.threadView(named) });
    }
    const message = await this.messageView(row!);
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'message', threadId, message });
    return message;
  }

  // ------------------------------------------------------------------ phone turns (relayed to the Mac)
  private async activeTurn(threadId: string) {
    const [t] = await this.db.select().from(claudeTurns).where(and(eq(claudeTurns.threadId, threadId), inArray(claudeTurns.state, ['queued', 'running']))).limit(1);
    return t;
  }

  async ask(u: AuthUser, threadId: string, body: unknown) {
    const b = parse(z.object({ text: z.string().trim().max(8000), attachments: z.unknown().optional() }).strict(), body);
    const t = await this.thread(u, threadId);
    if (!b.text && !(Array.isArray(b.attachments) && b.attachments.length)) throw badRequest('text: write something or attach an image');
    if (await this.activeTurn(t.id)) throw new ApiError(409, 'claude_busy', 'Claude is still answering in this chat');
    if (!this.macReady(u.id)) {
      const e = new ApiError(409, 'mac_offline', 'Your Mac is offline · open MUSE on your Mac with Claude Code signed in');
      (e as ApiError & { extra?: unknown }).extra = { fallback: { openInClaudeUrl: OPEN_IN_CLAUDE_URL, apiFallback: (await this.settings(u.studioId)).apiFallback && !!this.ctx.config.ANTHROPIC_API_KEY } };
      throw e;
    }
    const attachments = await storeAttachments(this.ctx, u, t.id, b.attachments); // workstream 1
    const now = Date.now();
    const [turn] = await this.db.insert(claudeTurns).values({ id: uid('tu'), threadId: t.id, ownerId: u.id, text: b.text, from: 'phone', state: 'queued', createdAt: now, ...(attachments.length ? { attachments } : {}) }).returning();
    const message = await this.addMessage(u, t.id, { role: 'user', source: 'phone', text: b.text, turnId: turn!.id, ...(attachments.length ? { attachments } : {}) });
    const view = await this.turnView(turn!);
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'turn', turn: view });
    this.arm(turn!.id, this.claimTimeoutMs, u, 'Your Mac didn\'t pick this up · check that MUSE is open on your Mac');
    return { message, turn: view };
  }

  async pending(u: AuthUser) {
    const rows = await this.db.select().from(claudeTurns).where(and(eq(claudeTurns.ownerId, u.id), eq(claudeTurns.state, 'queued')));
    return Promise.all(rows.filter(r => Date.now() - r.createdAt < this.claimTimeoutMs).map(r => this.turnView(r)));
  }

  private async turnRow(u: AuthUser, id: string) {
    const [t] = await this.db.select().from(claudeTurns).where(and(eq(claudeTurns.id, id), eq(claudeTurns.ownerId, u.id)));
    if (!t) throw new ApiError(410, 'turn_expired', 'That message has expired');
    return t;
  }

  async claim(u: AuthUser, id: string) {
    const t = await this.turnRow(u, id);
    if (t.state !== 'queued') throw t.state === 'running' ? new ApiError(409, 'already_claimed', 'Another Mac is answering this') : new ApiError(410, 'turn_expired', 'That message has expired');
    const now = Date.now();
    const [n] = await this.db.update(claudeTurns).set({ state: 'running', claimedAt: now, lastEventAt: now }).where(and(eq(claudeTurns.id, id), eq(claudeTurns.state, 'queued'))).returning();
    if (!n) throw new ApiError(409, 'already_claimed', 'Another Mac is answering this');
    this.arm(id, this.silentTurnMs, u, 'Your Mac stopped answering');
    const view = await this.turnView(n);
    // Tools shipped since this chat's last turn: Claude Code reads the note before the person's words.
    const note = await capabilityNote(this.ctx, u, n.threadId);
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'turn', turn: view });
    void this.emitStatus(u);
    return note ? { ...view, text: `${note}\n\n${n.text}` } : view; // only the claiming Mac's Claude Code reads the note
  }

  async stop(u: AuthUser, id: string) {
    const t = await this.turnRow(u, id);
    if (t.state === 'queued') return this.finish(u, t.id, 'stopped');
    if (t.state === 'running') void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'stop', turnId: t.id });
    return await this.turnView(t);
  }

  /** Fails or ends a turn once (timers, done events, stops). */
  private async finish(u: AuthUser, id: string, state: 'done' | 'failed' | 'stopped', error?: string) {
    const timer = this.timers.get(id); if (timer) { clearTimeout(timer); this.timers.delete(id); }
    const [n] = await this.db.update(claudeTurns).set({ state, error: error ?? null, finishedAt: Date.now() })
      .where(and(eq(claudeTurns.id, id), inArray(claudeTurns.state, ['queued', 'running']))).returning();
    if (!n) return await this.turnView((await this.db.select().from(claudeTurns).where(eq(claudeTurns.id, id)))[0]!);
    const view = await this.turnView(n);
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'turn', turn: view });
    void this.emitStatus(u);
    return view;
  }

  private arm(id: string, ms: number, u: AuthUser, error: string) {
    const old = this.timers.get(id); if (old) clearTimeout(old);
    const t = setTimeout(() => { this.timers.delete(id); void this.finish(u, id, 'failed', error).catch(e => this.ctx.log.warn({ err: (e as Error).message }, 'claude turn timeout')); }, ms);
    this.timers.set(id, t);
  }

  close() { for (const t of this.timers.values()) clearTimeout(t); this.timers.clear(); }

  // ------------------------------------------------------------------ the Mac mirrors its Claude Code stream
  async events(u: AuthUser, threadId: string, body: unknown) {
    const b = parse(z.object({ turnId: z.string().max(40).optional(), events: z.array(ClaudeEvent).min(1).max(500) }).strict(), body);
    const t = await this.thread(u, threadId);
    let turn: TurnRow | undefined;
    if (b.turnId) {
      turn = await this.turnRow(u, b.turnId);
      if (turn.threadId !== t.id) throw badRequest('turnId: not a turn of this thread');
      if (turn.state !== 'running') throw new ApiError(410, 'turn_expired', 'That message has ended');
      await this.db.update(claudeTurns).set({ lastEventAt: Date.now() }).where(eq(claudeTurns.id, turn.id));
      this.arm(turn.id, this.silentTurnMs, u, 'Your Mac stopped answering');
    }
    const source = 'mac' as const;
    for (const ev of b.events) {
      const relay = (event: unknown) => void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'event', threadId: t.id, ...(turn ? { turnId: turn.id } : {}), event });
      switch (ev.type) {
        case 'user':
          // A relayed turn's user message is already stored (from the phone).
          if (!turn) {
            const attachments = await storeAttachments(this.ctx, u, t.id, ev.attachments); // workstream 1: images typed on the Mac
            await this.addMessage(u, t.id, { role: 'user', source, text: ev.text, ...(attachments.length ? { attachments } : {}) });
          }
          break;
        case 'text': relay(ev); break;
        case 'assistant': if (ev.text.trim()) await this.addMessage(u, t.id, { role: 'assistant', source, text: ev.text, turnId: turn?.id }); break;
        case 'tool': {
          relay({ type: 'tool', id: ev.id, name: ev.name, status: ev.status, summary: ev.summary });
          if (ev.status !== 'running') {
            await this.addMessage(u, t.id, { role: 'tool', source, text: '', turnId: turn?.id, tool: compact({ id: ev.id, name: ev.name, ok: ev.status === 'done', summary: ev.summary }) });
          }
          break;
        }
        case 'image': {
          const buf = Buffer.from(ev.data, 'base64');
          if (buf.length > 2 * 1024 * 1024) throw badRequest('image: at most 2 MB');
          const key = `claude/${t.id}/${uid('img')}.${ev.mimeType === 'image/png' ? 'png' : 'jpg'}`;
          await this.ctx.storage.put(key, buf, ev.mimeType);
          await this.addMessage(u, t.id, { role: 'tool', source, text: '', turnId: turn?.id, imageKey: key });
          break;
        }
        case 'done':
          relay({ type: 'done', ok: ev.ok, error: ev.error, model: ev.model });
          // The Mac reports a Stop as done {ok: false, error: "Stopped"}.
          if (turn) await this.finish(u, turn.id, ev.ok ? 'done' : ev.error === 'Stopped' ? 'stopped' : 'failed', ev.ok || ev.error === 'Stopped' ? undefined : (ev.error ?? 'Claude stopped with an error'));
          break;
      }
    }
    return { ok: true };
  }

  /** API-key fallback bookkeeping: the in-app chat's user and final text join the thread. */
  async mirrorFallback(u: AuthUser, threadId: string, role: 'user' | 'assistant', text: string, attachments: Attachment[] = []) {
    if (text.trim() || attachments.length) return this.addMessage(u, threadId, { role, source: 'api', text, ...(attachments.length ? { attachments } : {}) });
    return null;
  }
  async fallbackAllowed(u: AuthUser) { return (await this.settings(u.studioId)).apiFallback && !!this.ctx.config.ANTHROPIC_API_KEY; }
}

export type { CameraAssetKind };

// ------------------------------------------------------------------ WS18: lists of chats
export const TITLE_MAX = 80;
/** A list's key: `suite:<tool>` or `<kind>:<contextId>`. */
export const KEY_RE = /^(suite|camera|edit|recreate):[A-Za-z0-9_-]{1,80}$/;
/** The AI Suite's list for a composer tool (Shot, Photo, Talking, …); anything unknown is Shot's. */
export function suiteKey(tool: unknown) {
  const t = typeof tool === 'string' && /^[a-z]{1,20}$/.test(tool) ? tool : 'shot';
  return `suite:${t}`;
}
/**
 * A chat's automatic title from its first message: the app's context line (`[Suite …]`, `[Recreate …]`) and any ids or
 * paths left out, one line, at most 60 characters cut at a word.
 */
export function autoTitle(text: string): string | null {
  let lines = text.split('\n');
  while (lines.length && /^\s*\[.*\]\s*$/.test(lines[0]!)) lines = lines.slice(1);
  let s = lines.join(' ')
    .replace(/<[^>]{0,200}>/g, ' ')
    .replace(/\b(?:sa|ct|cm|tu|es|cs|tk|up|img)_[A-Za-z0-9]{4,}\b/g, ' ')
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, ' ')
    .replace(/(?:~|\/)[\w.-]*\/[\w./-]+/g, ' ')
    .replace(/\s+/g, ' ').trim();
  if (!s) return null;
  if (s.length > 60) { const cut = s.slice(0, 60); const sp = cut.lastIndexOf(' '); s = (sp > 30 ? cut.slice(0, sp) : cut).replace(/[\s,.;:–-]+$/, '') + '…'; }
  return s;
}

/**
 * workstream 1: what Claude on the owner's Mac starts a Recreate or Edit thread with: the role, the MUSE tools for it
 * (all on the MUSE MCP server) and the id they act on. Camera threads keep the Mac's own director prompt.
 */
export function threadBrief(kind: string, contextId: string) {
  // One Claude (plans/one-claude.md): a chat that follows the person; the Mac passes its chatId to the chat tools.
  if (kind === 'chat') return { prompt: onePrompt(), tools: CHAT_REGISTRY.map(t => t.name), chatId: contextId };
  if (kind === 'recreate') return { prompt: RECREATE_PROMPT, tools: ['get_recipe', 'set_slot_briefs', 'match_slots', 'fill_slot', 'open_edit', 'apply_recipe', 'apply_edit_ops', 'playbook_read', 'playbook_add', 'report_gap'], referenceId: contextId };
  if (kind === 'edit') return { prompt: EDIT_PROMPT, tools: ['get_edit', 'apply_edit_ops', 'undo_edit', 'get_frame', 'auto_captions', 'remove_background', 'playbook_read'], sessionId: contextId };
  if (kind === 'suite') return { prompt: SUITE_PROMPT, tools: ['suite_options', 'suite_get_draft', 'suite_set_draft', 'suite_add_reference', 'suite_estimate', 'suite_request_shot', 'suite_feed', 'suite_cast', 'suite_see'], assistId: contextId };
  return undefined;
}
