// Claude chat threads on the owner's Claude plan (plans/api.md "Claude on the owner's plan"). The owner's Mac runs Claude
// Code and mirrors each turn here; the phone's messages become turns the Mac claims and answers (the Blender relay's
// queue/claim pattern). The server never runs Claude itself, except the opt-in API-key fallback (camera threads).
import { and, desc, eq, inArray } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { claudeMessages, claudeSettings, claudeThreads, claudeTurns, type CameraAssetKind } from './schema.js';
import type { CameraService } from './service.js';
import { parse } from './validate.js';
import { EDIT_PROMPT, RECREATE_PROMPT } from '../recreate/assistant.js';

type ThreadRow = typeof claudeThreads.$inferSelect;
type MessageRow = typeof claudeMessages.$inferSelect;
type TurnRow = typeof claudeTurns.$inferSelect;
export type ClaudeCode = { installed: boolean; signedIn: boolean; version?: string; model?: string };

export const MAC_OFFLINE_AFTER_MS = 45_000, CLAIM_TIMEOUT_MS = 90_000, SILENT_TURN_MS = 10 * 60_000;
export const OPEN_IN_CLAUDE_URL = 'https://claude.ai/new';

const ToolEv = z.object({ type: z.literal('tool'), id: z.string().min(1).max(100), name: z.string().min(1).max(120), status: z.enum(['running', 'done', 'error']),
  summary: z.string().max(300).optional(), input: z.unknown().optional() });
const ClaudeEvent = z.discriminatedUnion('type', [
  z.object({ type: z.literal('user'), text: z.string().max(20_000) }),
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
    createdAt: t.createdAt, updatedAt: t.updatedAt, brief: threadBrief(t.contextKind, t.contextId) });
  private async messageView(m: MessageRow) {
    return compact({ id: m.id, threadId: m.threadId, role: m.role, source: m.source, text: m.text, turnId: m.turnId ?? undefined, tool: m.tool ?? undefined,
      image: m.imageKey ? { url: await this.ctx.storage.presignGet(m.imageKey, 3600) } : undefined, createdAt: m.createdAt });
  }
  turnView = (t: TurnRow) => compact({ id: t.id, threadId: t.threadId, text: t.text, from: t.from, state: t.state, error: t.error ?? undefined,
    createdAt: t.createdAt, claimedAt: t.claimedAt ?? undefined, finishedAt: t.finishedAt ?? undefined });

  async thread(u: AuthUser, id: string) {
    const [t] = await this.db.select().from(claudeThreads).where(and(eq(claudeThreads.id, id), eq(claudeThreads.ownerId, u.id)));
    if (!t) throw notFound('Thread');
    return t;
  }

  async openThread(u: AuthUser, body: unknown) {
    const b = parse(z.object({ contextKind: z.enum(['camera', 'edit', 'recreate']), contextId: z.string().regex(/^[A-Za-z0-9_-]{1,80}$/) }).strict(), body);
    if (b.contextKind === 'camera') await this.camera.row(u, b.contextId);
    // workstream 1: a Recreate thread is about one of the owner's references.
    if (b.contextKind === 'recreate') await (await import('../recreate/references.js')).recreateOf(this.ctx).row(u, b.contextId);
    const where = and(eq(claudeThreads.ownerId, u.id), eq(claudeThreads.contextKind, b.contextKind), eq(claudeThreads.contextId, b.contextId));
    const [found] = await this.db.select().from(claudeThreads).where(where);
    if (found) return this.threadView(found);
    const now = Date.now();
    const [t] = await this.db.insert(claudeThreads).values({ id: uid('ct'), studioId: u.studioId, ownerId: u.id, contextKind: b.contextKind, contextId: b.contextId, createdAt: now, updatedAt: now })
      .onConflictDoNothing().returning();
    const row = t ?? (await this.db.select().from(claudeThreads).where(where))[0]!;
    const view = this.threadView(row);
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'thread', thread: view });
    return view;
  }

  async get(u: AuthUser, id: string) {
    const t = await this.thread(u, id);
    const rows = (await this.db.select().from(claudeMessages).where(eq(claudeMessages.threadId, t.id)).orderBy(desc(claudeMessages.createdAt)).limit(100)).reverse();
    const [active] = await this.db.select().from(claudeTurns).where(and(eq(claudeTurns.threadId, t.id), inArray(claudeTurns.state, ['queued', 'running']))).limit(1);
    return { ...this.threadView(t), messages: await Promise.all(rows.map(m => this.messageView(m))), ...(active ? { activeTurn: this.turnView(active) } : {}) };
  }

  async patchThread(u: AuthUser, id: string, body: unknown) {
    const b = parse(z.object({ claudeSessionId: z.string().regex(/^[A-Za-z0-9_-]{1,100}$/) }).strict(), body);
    const t = await this.thread(u, id);
    const [n] = await this.db.update(claudeThreads).set({ claudeSessionId: b.claudeSessionId, updatedAt: Date.now() }).where(eq(claudeThreads.id, t.id)).returning();
    return this.threadView(n!);
  }

  private async addMessage(u: AuthUser, threadId: string, m: Omit<typeof claudeMessages.$inferInsert, 'id' | 'threadId' | 'createdAt'>) {
    const [row] = await this.db.insert(claudeMessages).values({ id: uid('cm'), threadId, createdAt: Date.now(), ...m }).returning();
    await this.db.update(claudeThreads).set({ updatedAt: Date.now() }).where(eq(claudeThreads.id, threadId));
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
    const b = parse(z.object({ text: z.string().trim().min(1).max(8000) }).strict(), body);
    const t = await this.thread(u, threadId);
    if (await this.activeTurn(t.id)) throw new ApiError(409, 'claude_busy', 'Claude is still answering in this chat');
    if (!this.macReady(u.id)) {
      const e = new ApiError(409, 'mac_offline', 'Your Mac is offline · open MUSE on your Mac with Claude Code signed in');
      (e as ApiError & { extra?: unknown }).extra = { fallback: { openInClaudeUrl: OPEN_IN_CLAUDE_URL, apiFallback: (await this.settings(u.studioId)).apiFallback && !!this.ctx.config.ANTHROPIC_API_KEY } };
      throw e;
    }
    const now = Date.now();
    const [turn] = await this.db.insert(claudeTurns).values({ id: uid('tu'), threadId: t.id, ownerId: u.id, text: b.text, from: 'phone', state: 'queued', createdAt: now }).returning();
    const message = await this.addMessage(u, t.id, { role: 'user', source: 'phone', text: b.text, turnId: turn!.id });
    const view = this.turnView(turn!);
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'turn', turn: view });
    this.arm(turn!.id, this.claimTimeoutMs, u, 'Your Mac didn\'t pick this up · check that MUSE is open on your Mac');
    return { message, turn: view };
  }

  async pending(u: AuthUser) {
    const rows = await this.db.select().from(claudeTurns).where(and(eq(claudeTurns.ownerId, u.id), eq(claudeTurns.state, 'queued')));
    return rows.filter(r => Date.now() - r.createdAt < this.claimTimeoutMs).map(this.turnView);
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
    const view = this.turnView(n);
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'turn', turn: view });
    void this.emitStatus(u);
    return view;
  }

  async stop(u: AuthUser, id: string) {
    const t = await this.turnRow(u, id);
    if (t.state === 'queued') return this.finish(u, t.id, 'stopped');
    if (t.state === 'running') void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'stop', turnId: t.id });
    return this.turnView(t);
  }

  /** Fails or ends a turn once (timers, done events, stops). */
  private async finish(u: AuthUser, id: string, state: 'done' | 'failed' | 'stopped', error?: string) {
    const timer = this.timers.get(id); if (timer) { clearTimeout(timer); this.timers.delete(id); }
    const [n] = await this.db.update(claudeTurns).set({ state, error: error ?? null, finishedAt: Date.now() })
      .where(and(eq(claudeTurns.id, id), inArray(claudeTurns.state, ['queued', 'running']))).returning();
    if (!n) return this.turnView((await this.db.select().from(claudeTurns).where(eq(claudeTurns.id, id)))[0]!);
    const view = this.turnView(n);
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
          if (!turn) await this.addMessage(u, t.id, { role: 'user', source, text: ev.text });
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
  async mirrorFallback(u: AuthUser, threadId: string, role: 'user' | 'assistant', text: string) {
    if (text.trim()) await this.addMessage(u, threadId, { role, source: 'api', text });
  }
  async fallbackAllowed(u: AuthUser) { return (await this.settings(u.studioId)).apiFallback && !!this.ctx.config.ANTHROPIC_API_KEY; }
}

export type { CameraAssetKind };

/**
 * workstream 1: what Claude on the owner's Mac starts a Recreate or Edit thread with: the role, the MUSE tools for it
 * (all on the MUSE MCP server) and the id they act on. Camera threads keep the Mac's own director prompt.
 */
export function threadBrief(kind: string, contextId: string) {
  if (kind === 'recreate') return { prompt: RECREATE_PROMPT, tools: ['get_recipe', 'set_slot_briefs', 'match_slots', 'fill_slot', 'open_edit', 'apply_recipe', 'apply_edit_ops', 'playbook_read', 'playbook_add', 'report_gap'], referenceId: contextId };
  if (kind === 'edit') return { prompt: EDIT_PROMPT, tools: ['get_edit', 'apply_edit_ops', 'undo_edit', 'get_frame', 'auto_captions', 'remove_background', 'playbook_read'], sessionId: contextId };
  return undefined;
}
