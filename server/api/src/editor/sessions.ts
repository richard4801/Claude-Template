// Edit sessions (plans/claude-editing.md A, plans/api.md "Edit sessions"): a live, revisioned working copy of an
// EditProject v2 per take, shared by the owner's apps and Claude. Every change is a JSON Patch with its inverse, so
// every change (Claude's too) is undoable; changes reach the apps as `edit` events. Owner only.
import { and, desc, eq, lte } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { takes, uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { applyPatch, diff, PatchError, type PatchOp } from './jsonpatch.js';
import * as M from './model.js';
import { applyOps, type EditOp } from './ops.js';
import { FILTERS } from './presets.js';
import { LOOK_IDS } from './lookpack.js';
import { paletteIds } from './photo.js';
import { editOps, editSessions } from './schema.js';
import { editorAi } from './service.js';
import { learningOf, touched } from './learn.js';
import { CAPTION_STYLES } from './presets.js';
import type { Word } from './cuts.js';
import { sourceMatteCandidates, stripSourceMattes } from './repair.js';

type Session = typeof editSessions.$inferSelect;
type OpRow = typeof editOps.$inferSelect;
export const SESSION_LIMITS = { historyKept: 500, historyShown: 60, presenceSec: 45, frameWaitMs: 12_000, claudeOpsPerMin: 120 } as const;

export type Presence = { device: string; label: string; platform: 'android' | 'mac' | 'other'; canRender: boolean; at: number };
type Waiter = { resolve: (v: { uploadId: string } | null) => void; timer: NodeJS.Timeout };
export type AppRequest = { id: string; kind: 'save' | 'export'; name?: string; preset?: Record<string, unknown>; device: string; status: 'sent' | 'done' | 'failed'; versionId?: string; error?: string; at: number };
export type Pending = { id: string; kind: string; label: string; estimateUsd: number; args: Record<string, unknown>; status: 'waiting' | 'approved' | 'declined' | 'running' | 'done' | 'failed'; jobId?: string; createdAt: number };

const services = new WeakMap<Ctx, EditSessions>();
export const editSessionsOf = (ctx: Ctx) => { let s = services.get(ctx); if (!s) { s = new EditSessions(ctx); services.set(ctx, s); } return s; };

export class EditSessions {
  private presence = new Map<string, Map<string, Presence>>();
  private frames = new Map<string, Waiter>();
  private requests = new Map<string, AppRequest[]>();
  private rate = new Map<string, number[]>();
  constructor(private ctx: Ctx) {
    editorAi(ctx).finished.add(r => this.jobFinished(r.id, r.state, r.result as Record<string, unknown> | null));
  }

  // ------------------------------------------------------------------ access
  owner(u: AuthUser) { if (u.role !== 'owner') throw new ApiError(403, 'owner_only', 'Editing with Claude is for the studio owner'); }
  async row(u: AuthUser, id: string): Promise<Session> {
    this.owner(u);
    const [s] = await this.ctx.db.select().from(editSessions).where(and(eq(editSessions.id, id), eq(editSessions.studioId, u.studioId)));
    if (!s) throw notFound('Edit session');
    return s;
  }
  private online(id: string): Presence[] {
    const now = Date.now();
    return [...(this.presence.get(id)?.values() ?? [])].filter(p => now - p.at < SESSION_LIMITS.presenceSec * 1000);
  }
  entryView = (o: OpRow) => ({ id: o.id, revision: o.revision, author: o.author, byClaude: o.author === 'claude', kind: o.kind, label: o.label,
    undoes: o.undoes ?? undefined, undone: !!o.undone, createdAt: o.createdAt });
  async view(s: Session, o: { history?: boolean } = {}) {
    const hist = o.history === false ? undefined : (await this.ctx.db.select().from(editOps).where(eq(editOps.sessionId, s.id)).orderBy(desc(editOps.id)).limit(SESSION_LIMITS.historyShown)).map(this.entryView);
    return { id: s.id, takeId: s.takeId, baseVersionId: s.baseVersionId ?? undefined, revision: s.revision, project: s.project as M.EditProject,
      durationSec: M.durationSec(s.project as M.EditProject), status: s.status, updatedBy: s.updatedBy, updatedAt: s.updatedAt,
      pending: (s.pending as Pending[]).filter(p => p.status === 'waiting' || p.status === 'running'),
      online: this.online(s.id).map(p => ({ device: p.device, label: p.label, platform: p.platform, canRender: p.canRender })),
      requests: (this.requests.get(s.id) ?? []).slice(-10), ...(hist ? { history: hist } : {}) };
  }
  private emit(s: Session, ev: Record<string, unknown>) {
    void this.ctx.hub.emit(s.studioId, v => (v.role === 'owner' ? { type: 'edit', sessionId: s.id, ...ev } : null));
  }

  // ------------------------------------------------------------------ open
  /** The take's open session, or a new one from `project` (the app's) or from the take (its saved edit list, else untouched). */
  async open(u: AuthUser, b: { takeId?: unknown; project?: unknown; baseVersionId?: unknown; device?: unknown; fresh?: unknown }) {
    this.owner(u);
    if (typeof b.takeId !== 'string') throw badRequest('takeId: required');
    // A blank project ("New blank project", no source take): always a new session, stored under the marker take id.
    if (b.takeId === M.BLANK_SOURCE) {
      const project = b.project !== undefined ? this.check(b.project as M.EditProject, M.BLANK_SOURCE) : M.blankProject();
      const now = Date.now();
      const [s] = await this.ctx.db.insert(editSessions).values({ id: uid('es'), studioId: u.studioId, ownerId: u.id, takeId: M.BLANK_SOURCE,
        baseVersionId: null, project: project as unknown as Record<string, unknown>, revision: 0, updatedBy: this.author(b.device), createdAt: now, updatedAt: now }).returning();
      return this.view(s!);
    }
    const [t] = await this.ctx.db.select().from(takes).where(and(eq(takes.id, b.takeId), eq(takes.studioId, u.studioId)));
    if (!t) throw notFound('Take');
    if (!t.mediaKey || !(t.kind === 'take' || (t.kind as string) === 'edit')) throw badRequest('takeId: must be a video take');
    if (b.fresh !== true) {
      const [cur] = await this.ctx.db.select().from(editSessions).where(and(eq(editSessions.studioId, u.studioId), eq(editSessions.takeId, t.id), eq(editSessions.status, 'open')))
        .orderBy(desc(editSessions.updatedAt)).limit(1);
      if (cur) return this.view(cur);
    }
    let project: M.EditProject;
    if (b.project !== undefined) project = this.check(b.project as M.EditProject, t.id);
    else project = this.fromTake(t);
    const now = Date.now(), by = this.author(b.device);
    const [s] = await this.ctx.db.insert(editSessions).values({ id: uid('es'), studioId: u.studioId, ownerId: u.id, takeId: t.id,
      baseVersionId: typeof b.baseVersionId === 'string' ? b.baseVersionId : null, project: project as unknown as Record<string, unknown>, revision: 0,
      updatedBy: by, createdAt: now, updatedAt: now }).returning();
    return this.view(s!);
  }
  /** A take's starting project: an edited version's v2 project or v1 list (on its source take), else the untouched take. */
  private fromTake(t: typeof takes.$inferSelect): M.EditProject {
    const media = (t.media ?? {}) as { durationSec?: number; width?: number; height?: number; fps?: number; edits?: unknown; parentTakeId?: string };
    const e = media.edits as { version?: number } | undefined;
    // A saved blank project: its own video is now the source it is a version of (sessions check sourceTakeId).
    if (e?.version === 2) { const p = e as unknown as M.EditProject; return M.isBlank(p) ? { ...p, sourceTakeId: t.id } : p; }
    // Live takes can carry 0 or no width / height / fps / duration (owner blocker 2026-11-07): never a 0×0 canvas or a 0 s clip.
    const pos = (v: unknown, d: number) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : d; };
    const facts = { width: Math.round(pos(media.width, 1080)), height: Math.round(pos(media.height, 1920)), fps: pos(media.fps, 30) };
    if (e?.version === 1) return M.fromV1(e as M.EditListV1, facts);
    const d = pos(media.durationSec, 1);
    const p = M.fromV1({ version: 1, sourceTakeId: t.id, sourceDurationSec: d, segments: [{ inSec: 0, outSec: d, speed: 1 }], mute: false }, facts);
    // A suite take graded with a look (workstream 1) starts with it on the main clip (reversible like any look).
    const look = (media as { look?: { lut?: string } }).look;
    if (look?.lut) (p.tracks[0]!.items[0] as M.VideoClip).look = { lut: look.lut, strength: 1 };
    return p;
  }
  private check(p: M.EditProject, takeId?: string): M.EditProject {
    if (JSON.stringify(p ?? null).length > M.LIMITS.maxJsonBytes) throw badRequest(`project: at most ${M.LIMITS.maxJsonBytes / 1024} KB`);
    try { M.validate(p, FILTERS, LOOK_IDS, paletteIds(), { draft: true }); } catch (e) {
      if (e instanceof M.EditProblem) throw badRequest(e.message.replace(/^edits/, 'project'));
      throw badRequest(`project: ${(e as Error).message}`);
    }
    if (takeId && p.sourceTakeId !== takeId) throw badRequest('project.sourceTakeId: must be the session\'s take');
    return p;
  }
  private author(device: unknown) { return typeof device === 'string' && device ? `app:${device.slice(0, 40)}` : 'app'; }

  // ------------------------------------------------------------------ changes
  /** Stores a new project (already validated) with its patch and inverse; tells the apps. */
  private async commit(s: Session, next: M.EditProject, o: { author: string; kind: OpRow['kind']; label: string; undoes?: number; meta?: Record<string, unknown> }) {
    const patch = diff(s.project, next), inverse = diff(next, s.project);
    if (!patch.length && o.kind !== 'tool') return { session: s, entry: null as OpRow | null, patch };
    const now = Date.now(), rev = s.revision + (patch.length ? 1 : 0);
    const [u] = await this.ctx.db.update(editSessions).set({ project: next as unknown as Record<string, unknown>, revision: rev, updatedBy: o.author, updatedAt: now })
      .where(and(eq(editSessions.id, s.id), eq(editSessions.revision, s.revision))).returning();
    if (!u) throw await this.stale(s.id, s.revision); // someone else committed in between
    const [entry] = await this.ctx.db.insert(editOps).values({ sessionId: s.id, revision: rev, author: o.author, kind: o.kind, label: o.label.slice(0, 200),
      patch, inverse, undoes: o.undoes ?? null, meta: patch.length ? { ...(o.meta ?? {}), touched: touched(s.project as M.EditProject, next) } : (o.meta ?? null), createdAt: now }).returning();
    if (o.undoes) await this.ctx.db.update(editOps).set({ undone: 1 }).where(eq(editOps.id, o.undoes));
    await this.prune(s.id);
    if (patch.length) this.emit(u, { op: 'patch', revision: rev, baseRevision: s.revision, patch, entry: this.entryView(entry!) });
    // The learning editor (workstream 3): the owner's change to one of Claude's becomes a correction. Never blocks.
    if (patch.length && o.author !== 'claude' && !o.author.startsWith('system:')) void learningOf(this.ctx).observe(s, s.project as M.EditProject, next, entry!);
    return { session: u, entry: entry!, patch };
  }
  /**
   * One-off repair (WS3, 2026-11-08, repair.ts): removes alphaMatte entries whose matte is the clip's own source, as an
   * ordinary change ("Removed a broken cut-out", undoable, sent to the apps). Returns how many sessions changed.
   */
  async repairSourceMattes(): Promise<number> {
    let n = 0;
    for (const id of await sourceMatteCandidates(this.ctx)) {
      const [s] = await this.ctx.db.select().from(editSessions).where(eq(editSessions.id, id));
      if (!s) continue;
      const { project, removed } = stripSourceMattes(s.project as unknown as M.EditProject);
      if (!removed) continue;
      try { await this.commit(s, project, { author: 'system:repair', kind: 'edit', label: 'Removed a broken cut-out' }); n++; }
      catch (e) { if (!(e instanceof ApiError)) throw e; } // moved on meanwhile: the next start tries again
    }
    return n;
  }
  private async stale(id: string, baseRevision: number) {
    const [cur] = await this.ctx.db.select().from(editSessions).where(eq(editSessions.id, id));
    return new ApiError(409, 'stale_revision', `The edit moved on (revision ${cur?.revision ?? '?'}, you sent ${baseRevision}) · get it again and re-apply`);
  }
  private async prune(id: string) {
    const old = await this.ctx.db.select({ id: editOps.id }).from(editOps).where(eq(editOps.sessionId, id)).orderBy(desc(editOps.id)).offset(SESSION_LIMITS.historyKept).limit(1);
    if (old[0]) await this.ctx.db.delete(editOps).where(and(eq(editOps.sessionId, id), lte(editOps.id, old[0].id)));
  }
  private revOf(b: { baseRevision?: unknown }) {
    if (typeof b.baseRevision !== 'number' || !Number.isInteger(b.baseRevision)) throw badRequest('baseRevision: required (the revision your change is based on)');
    return b.baseRevision;
  }

  /** An app's change: a JSON Patch against `baseRevision` (409 stale_revision when the session moved on). */
  async push(u: AuthUser, id: string, b: { baseRevision?: unknown; patch?: unknown; label?: unknown; device?: unknown }) {
    const s = await this.row(u, id), base = this.revOf(b);
    if (base !== s.revision) throw await this.stale(id, base);
    if (!Array.isArray(b.patch)) throw badRequest('patch: a JSON Patch array');
    let next: M.EditProject;
    try { next = applyPatch(s.project as M.EditProject, b.patch as PatchOp[]); } catch (e) { if (e instanceof PatchError) throw badRequest(`patch: ${e.message}`); throw e; }
    this.check(next, s.takeId);
    const r = await this.commit(s, next, { author: this.author(b.device), kind: 'edit', label: typeof b.label === 'string' && b.label ? b.label : 'Edit' });
    return { revision: r.session.revision, entry: r.entry ? this.entryView(r.entry) : null };
  }
  /** Replaces the whole project (an app's Reset / reload); undoable. */
  async reset(u: AuthUser, id: string, b: { baseRevision?: unknown; project?: unknown; device?: unknown; label?: unknown }, o: { meta?: Record<string, unknown> } = {} /* workstream 1: Recreate's sources, server-side only */) {
    const s = await this.row(u, id), base = this.revOf(b);
    if (base !== s.revision) throw await this.stale(id, base);
    const next = this.check(b.project as M.EditProject, s.takeId);
    const r = await this.commit(s, next, { author: this.author(b.device), kind: 'reset', label: typeof b.label === 'string' && b.label ? b.label : 'Reset', ...(o.meta ? { meta: o.meta } : {}) });
    return { revision: r.session.revision, entry: r.entry ? this.entryView(r.entry) : null };
  }
  /** Claude's ops (MCP apply_edit_ops): applied, validated, committed as one undoable change. */
  async applyClaude(u: AuthUser, id: string, b: { baseRevision?: unknown; ops?: unknown; label?: string; meta?: Record<string, unknown> }) {
    const s = await this.row(u, id), base = this.revOf(b);
    if (base !== s.revision) throw await this.stale(id, base);
    this.limit(id);
    const { project, labels } = applyOps(s.project as M.EditProject, b.ops as EditOp[]);
    this.check(project, s.takeId);
    // workstream 1: the owner's pinned playbook rules (no ramps, cuts only, …) hold for every change of Claude's.
    await (await import('../recreate/playbook.js')).guardClaudeChange(this.ctx, u, s.project as M.EditProject, project);
    const r = await this.commit(s, project, { author: 'claude', kind: 'edit', label: b.label ?? labels.join(' · '), ...(b.meta ? { meta: b.meta } : {}) }); // label: a tool's own name for the change (workstream 1)
    return { revision: r.session.revision, changes: labels, entry: r.entry ? this.entryView(r.entry) : null, durationSec: M.durationSec(project) };
  }
  private limit(id: string) {
    const now = Date.now(), list = (this.rate.get(id) ?? []).filter(t => now - t < 60_000);
    if (list.length >= SESSION_LIMITS.claudeOpsPerMin) throw new ApiError(429, 'rate_limited', 'Too many changes in a minute · slow down');
    list.push(now); this.rate.set(id, list);
  }
  /** Undoes one change (by anyone): applies its inverse to the current project. 409 when later changes make that impossible. */
  async undo(u: AuthUser, id: string, b: { entryId?: unknown; device?: unknown; author?: string }) {
    const s = await this.row(u, id);
    const entryId = Number(b.entryId);
    if (!Number.isInteger(entryId) || entryId <= 0) throw badRequest('entryId: required (from the history)'); // was a 500 on a missing id
    const [e] = await this.ctx.db.select().from(editOps).where(and(eq(editOps.id, entryId), eq(editOps.sessionId, id)));
    if (!e) throw notFound('Change');
    if (e.undone) throw new ApiError(409, 'already_undone', 'That change was already undone');
    if (!(e.inverse as unknown[]).length) throw badRequest('That entry changed nothing');
    let next: M.EditProject;
    try { next = applyPatch(s.project as M.EditProject, e.inverse as PatchOp[]); this.check(next, s.takeId); }
    catch { throw new ApiError(409, 'cannot_undo', 'Later changes touch the same parts · undo those first'); }
    const r = await this.commit(s, next, { author: b.author ?? this.author(b.device), kind: 'undo', label: `Undo: ${e.label}`, undoes: e.id });
    return { revision: r.session.revision, entry: r.entry ? this.entryView(r.entry) : null };
  }
  /** A note in the history without a change (every MCP call is logged). */
  async log(s: Session, label: string) {
    const [entry] = await this.ctx.db.insert(editOps).values({ sessionId: s.id, revision: s.revision, author: 'claude', kind: 'tool', label: label.slice(0, 200), patch: [], inverse: [], createdAt: Date.now() }).returning();
    this.emit(s, { op: 'log', entry: this.entryView(entry!) });
  }
  async history(u: AuthUser, id: string, limit = 100) {
    await this.row(u, id);
    return (await this.ctx.db.select().from(editOps).where(eq(editOps.sessionId, id)).orderBy(desc(editOps.id)).limit(Math.min(500, Math.max(1, limit)))).map(this.entryView);
  }
  async close(u: AuthUser, id: string) {
    const s = await this.row(u, id);
    await this.ctx.db.update(editSessions).set({ status: 'closed', updatedAt: Date.now() }).where(eq(editSessions.id, s.id));
    this.emit(s, { op: 'closed' });
    return { ok: true };
  }

  // ------------------------------------------------------------------ apps online: presence, frames, save/export
  touch(u: AuthUser, id: string, b: { device?: unknown; label?: unknown; platform?: unknown; canRender?: unknown }) {
    this.owner(u);
    if (typeof b.device !== 'string' || !b.device) throw badRequest('device: required');
    const m = this.presence.get(id) ?? new Map<string, Presence>();
    m.set(b.device, { device: b.device.slice(0, 40), label: typeof b.label === 'string' ? b.label.slice(0, 60) : b.device, platform: b.platform === 'android' || b.platform === 'mac' ? b.platform : 'other',
      canRender: b.canRender !== false, at: Date.now() });
    this.presence.set(id, m);
    return { ok: true, online: this.online(id).length };
  }
  leave(id: string, device: string) { this.presence.get(id)?.delete(device); }
  renderer(id: string) { return this.online(id).filter(p => p.canRender).sort((a, b) => (a.platform === 'mac' ? -1 : 0) - (b.platform === 'mac' ? -1 : 0) || b.at - a.at)[0] ?? null; }

  /** Asks the online app to render frame t exactly; resolves with its upload id, or null after the wait. */
  async requestFrame(s: Session, t: number, width: number): Promise<{ uploadId: string; device: string } | null> {
    const r = this.renderer(s.id);
    if (!r) return null;
    const requestId = uid('fr');
    const got = await new Promise<{ uploadId: string } | null>(resolve => {
      const timer = setTimeout(() => { this.frames.delete(requestId); resolve(null); }, SESSION_LIMITS.frameWaitMs);
      this.frames.set(requestId, { resolve, timer });
      this.emit(s, { op: 'frame_request', requestId, t, width, revision: s.revision, device: r.device });
    });
    return got ? { ...got, device: r.device } : null;
  }
  async frameDone(u: AuthUser, id: string, requestId: string, b: { uploadId?: unknown }) {
    await this.row(u, id);
    const w = this.frames.get(requestId);
    if (!w) throw notFound('Frame request');
    if (typeof b.uploadId !== 'string') throw badRequest('uploadId: required');
    const [up] = await this.ctx.db.select().from(uploads).where(and(eq(uploads.id, b.uploadId), eq(uploads.studioId, u.studioId)));
    if (!up || !up.contentType.startsWith('image/')) throw badRequest('uploadId: an image upload of the studio');
    clearTimeout(w.timer); this.frames.delete(requestId);
    w.resolve({ uploadId: b.uploadId });
    return { ok: true };
  }
  /** Asks an online app to save a version / export (only apps encode video). */
  appRequest(s: Session, kind: AppRequest['kind'], o: { name?: string; preset?: Record<string, unknown> }): AppRequest | null {
    const r = this.renderer(s.id);
    if (!r) return null;
    const req: AppRequest = { id: uid('ar'), kind, ...(o.name ? { name: o.name } : {}), ...(o.preset ? { preset: o.preset } : {}), device: r.device, status: 'sent', at: Date.now() };
    const list = this.requests.get(s.id) ?? [];
    list.push(req); this.requests.set(s.id, list.slice(-20));
    this.emit(s, { op: 'app_request', request: req });
    return req;
  }
  async appRequestDone(u: AuthUser, id: string, requestId: string, b: { status?: unknown; versionId?: unknown; error?: unknown }) {
    const s = await this.row(u, id);
    const req = (this.requests.get(id) ?? []).find(r => r.id === requestId);
    if (!req) throw notFound('Request');
    req.status = b.status === 'failed' ? 'failed' : 'done';
    if (typeof b.versionId === 'string') req.versionId = b.versionId;
    if (typeof b.error === 'string') req.error = b.error.slice(0, 200);
    this.emit(s, { op: 'app_request', request: req });
    return req;
  }

  // ------------------------------------------------------------------ AI helpers Claude asks for
  /** A paid helper waits for the owner's yes in the app. */
  async askOwner(s: Session, p: Omit<Pending, 'id' | 'status' | 'createdAt'>) {
    const item: Pending = { ...p, id: uid('pa'), status: 'waiting', createdAt: Date.now() };
    const list = [...(s.pending as Pending[]).filter(x => x.status === 'waiting' || x.status === 'running').slice(-9), item];
    await this.ctx.db.update(editSessions).set({ pending: list as unknown as Record<string, unknown>[] }).where(eq(editSessions.id, s.id));
    this.emit(s, { op: 'pending', pending: item });
    await this.log(s, `Asked the owner: ${p.label} (about $${p.estimateUsd.toFixed(2)})`);
    return item;
  }
  /** The owner answers in the app; yes starts the job (the hold is the owner's, like any job they start). */
  async answer(u: AuthUser, id: string, pid: string, b: { approve?: unknown }) {
    const s = await this.row(u, id);
    const list = s.pending as Pending[];
    const p = list.find(x => x.id === pid);
    if (!p || p.status !== 'waiting') throw notFound('Waiting request');
    if (b.approve !== true) p.status = 'declined';
    else if (p.kind === 'recreate_fill') {
      // Workstream 1 (Recreate this edit): a missing slot filled with a Suite shot. An ordinary job with its own events.
      const { recreateOf } = await import('../recreate/references.js');
      const r = await recreateOf(this.ctx).fillSlot(u, String(p.args.referenceId), String(p.args.slotId), p.args.body);
      p.status = 'done'; p.jobId = String((r.job as { id: string }).id);
    } else {
      const job = await editorAi(this.ctx).start(u, p.args);
      p.status = 'running'; p.jobId = String(job.id);
    }
    await this.ctx.db.update(editSessions).set({ pending: list as unknown as Record<string, unknown>[] }).where(eq(editSessions.id, s.id));
    this.emit(s, { op: 'pending', pending: p });
    return p;
  }
  /** Job → session: when a job Claude started (or the owner approved) finishes, its result is applied as Claude's change. */
  private watch = new Map<string, { sessionId: string; studioId: string; ownerId: string; kind: string; itemId?: string; reasons?: string[]; label: string }>();
  track(jobId: string, w: { sessionId: string; studioId: string; ownerId: string; kind: string; itemId?: string; reasons?: string[]; label: string }) { this.watch.set(jobId, w); }
  private async jobFinished(jobId: string, state: string, result: Record<string, unknown> | null) {
    let w = this.watch.get(jobId);
    if (!w) { // approved from the app: find it in a session's pending list
      const rows = await this.ctx.db.select().from(editSessions).where(eq(editSessions.status, 'open'));
      const s = rows.find(r => (r.pending as Pending[]).some(p => p.jobId === jobId));
      const p = s && (s.pending as Pending[]).find(x => x.jobId === jobId);
      if (!s || !p) return;
      w = { sessionId: s.id, studioId: s.studioId, ownerId: s.ownerId, kind: p.kind, itemId: p.args.itemId as string | undefined, reasons: p.args.reasons as string[] | undefined, label: p.label };
      p.status = state === 'done' ? 'done' : 'failed';
      await this.ctx.db.update(editSessions).set({ pending: s.pending }).where(eq(editSessions.id, s.id));
      this.emit(s, { op: 'pending', pending: p });
    }
    this.watch.delete(jobId);
    const [s] = await this.ctx.db.select().from(editSessions).where(eq(editSessions.id, w.sessionId));
    if (!s) return;
    if (state !== 'done' || !result) { await this.log(s, `${w.label} didn't finish`); return; }
    try {
      const next = this.applyResult(s.project as M.EditProject, w, result);
      if (!next) { await this.log(s, `${w.label}: nothing to change`); return; }
      this.check(next, s.takeId);
      await this.commit(s, next, { author: 'claude', kind: 'edit', label: w.label });
    } catch (e) {
      this.ctx.log.warn({ err: (e as Error).message, session: s.id, job: jobId }, 'applying an editor job to a session failed');
      await this.log(s, `${w.label}: couldn't apply (the edit changed)`);
    }
  }
  /** The main source asset (the session's take) or the asset of `itemId`. */
  sourceAsset(p: M.EditProject, takeId: string, itemId?: string): M.Asset {
    if (itemId) {
      for (const t of p.tracks) { const it = t.items.find(i => i.id === itemId) as M.VideoClip | undefined; if (it?.asset) return p.assets.find(a => a.id === it.asset)!; }
      throw badRequest(`itemId: no item ${itemId}`);
    }
    const first = M.mainTrack(p).items[0] as M.VideoClip | undefined;
    if (!first && !p.assets.some(a => a.take === takeId && a.kind === 'video')) throw badRequest('The edit has no clip yet · add a video first');
    return p.assets.find(a => a.take === takeId && a.kind === 'video') ?? p.assets.find(a => a.id === first!.asset)!;
  }
  applyResult(p0: M.EditProject, w: { kind: string; itemId?: string; reasons?: string[] }, result: Record<string, unknown>): M.EditProject | null {
    const p: M.EditProject = JSON.parse(JSON.stringify(p0));
    const asset = this.sourceAsset(p, p.sourceTakeId, w.itemId);
    switch (w.kind) {
      case 'captions': {
        const words = (result.words as Word[] | undefined) ?? [];
        if (!words.length) return null;
        let t = p.tracks.find(x => x.kind === 'caption');
        const style = t?.caption?.style ?? CAPTION_STYLES.pop;
        const cap = { asset: asset.id, words: words.slice(0, M.LIMITS.maxWords).map(x => ({ text: x.text.slice(0, 60) || '…', startSec: x.startSec, endSec: Math.max(x.startSec, x.endSec) })), style };
        if (t) t.caption = cap; else { t = { id: 'captions', kind: 'caption', items: [], caption: cap }; p.tracks.push(t); }
        return p;
      }
      case 'cuts': {
        const cuts = ((result.cuts as { startSec: number; endSec: number; reason: string }[]) ?? []).filter(c => !w.reasons || w.reasons.includes(c.reason));
        if (!cuts.length) return null;
        const out = M.applyCuts(p, asset.id, cuts);
        return out === p ? null : out;
      }
      case 'beats': {
        const beats = result.beats as number[] | undefined, strong = result.strong as number[] | undefined;
        let n = 0;
        for (const t of p.tracks.filter(x => x.kind === 'music')) for (const it of t.items as M.AudioClip[]) if (it.asset === asset.id) { it.beats = beats; it.strongBeats = strong; n++; }
        return n ? p : null;
      }
      case 'matte': {
        const a = result.asset as { upload?: string; take?: string; durationSec?: number; url?: string } | undefined;
        if (!a) return null;
        const id = `bg${p.assets.length + 1}`;
        p.assets.push({ id, kind: 'video', ...(a.upload ? { upload: a.upload } : { take: a.take! }), durationSec: a.durationSec, ...(a.url ? { url: a.url } : {}) });
        for (const t of p.tracks) for (const it of t.items as M.VideoClip[]) if (it.asset === asset.id && (t.kind === 'main' || t.kind === 'video') && (!w.itemId || it.id === w.itemId)) {
          // workstream 1: an alpha matte on the original clip (fix 1, and tap to keep); older results were green composites.
          if (result.alpha) { it.alphaMatte = { asset: id }; delete it.chroma; }
          else { it.asset = id; it.audioAsset ??= asset.id; it.chroma = result.chroma as M.Chroma; }
        }
        return p;
      }
      case 'denoise': {
        const a = result.asset as { upload?: string; take?: string; durationSec?: number; url?: string } | undefined;
        if (!a) return null;
        const id = `vo${p.assets.length + 1}`;
        p.assets.push({ id, kind: 'audio', ...(a.upload ? { upload: a.upload } : { take: a.take! }), durationSec: a.durationSec, ...(a.url ? { url: a.url } : {}) });
        for (const t of p.tracks) for (const it of t.items as M.VideoClip[]) if (it.asset === asset.id && (!w.itemId || it.id === w.itemId)) it.audioAsset = id;
        return p;
      }
    }
    return null;
  }
}
