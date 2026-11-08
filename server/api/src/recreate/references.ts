// Recreate this edit · references (workstream 1; plans/api.md "Recreate this edit"): a studio's reference videos,
// analysed into recipes one at a time on the server's CPU. Private: each member sees their own, the owner sees all; the
// contact sheet is served only through the authenticated route. Deleted after 30 days unless kept.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { and, desc, eq, inArray, isNull, lt } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { probe } from '../replicate/media.js';
import { takes as takesTable, jobs } from '../db/schema.js';
import { editSessionsOf } from '../editor/sessions.js';
import { timeline } from '../editor/model.js';
import { analyzeReference, type Recipe } from './analyze.js';
import { buildProject, type AssembleOptions, type TakeInfo } from './assemble.js';
import { BriefSchema, matchSlots, shotRequestFor, withBriefs, type Candidate } from './slots.js';
import { recreateReferences } from './schema.js';

export const MAX_REFERENCE_SEC = 60;
export const KEEP_DAYS = 30;
const DAY = 86_400_000;

type Row = typeof recreateReferences.$inferSelect;

/** Matching, filling and assembly state, kept apart from the recipe (the analysis). */
export type FillState = {
  /** The last match: the suggested take per slot, with its score and reasons. */
  matched?: Record<string, { takeId: string; score: number; reasons: string[] }>;
  toGenerate?: string[];
  /** Slots being filled by a Suite shot. */
  jobs?: Record<string, { jobId: string; estimate?: number; at: number }>;
  /** The last assembly: where, which take per slot, which project item came from which recipe element, and the score. */
  applied?: { sessionId: string; revision: number; at: number; slots: Record<string, string>; sources: Record<string, RecipeSource>; match: MatchScore };
};
export type RecipeSource = { recipeId: string; slotId?: string; textId?: string; transitionAt?: number };
export type MatchScore = { overall: number; cuts: number; text: number; ramps: number; grade: number; shots: number; perSlot: { slotId: string; score: number }[] };

const CreateBody = z.object({ uploadId: z.string().min(1).max(80), name: z.string().trim().max(80).optional() }).strict();
const PatchBody = z.object({ keep: z.boolean().optional(), name: z.string().trim().max(80).optional() }).strict();
const parse = <T>(s: z.ZodType<T>, body: unknown): T => {
  const r = s.safeParse(body ?? {});
  if (!r.success) throw badRequest(r.error.issues.map(i => (i.path.length ? `${i.path.join('.')}: ` : '') + i.message).join('; '));
  return r.data;
};

export class RecreateReferences {
  private queue: string[] = [];
  private running: Promise<void> | null = null;
  private lastSweep = 0;
  private resumed = false;
  constructor(private ctx: Ctx) {}

  /** After a restart: analyses that were running start again (once, on first use). */
  private async resume() {
    if (this.resumed) return;
    this.resumed = true;
    const rows = await this.ctx.db.select({ id: recreateReferences.id }).from(recreateReferences).where(eq(recreateReferences.state, 'analyzing'));
    for (const r of rows) if (!this.queue.includes(r.id)) this.enqueue(r.id);
  }

  view(r: Row) {
    const base = `${this.ctx.config.PUBLIC_URL ?? ''}/v1/recreate/references/${r.id}`;
    const recipe = r.recipe as Recipe | null;
    const sheet = r.contactSheetKey ? recipe?.contactSheet : null;
    return {
      id: r.id, name: r.name, state: r.state, progress: Math.round(r.progress), phase: r.phase, error: r.error ?? undefined, durationSec: r.durationSec ?? undefined,
      userId: r.userId, keep: r.keep, createdAt: r.createdAt, expiresAt: r.keep ? null : r.expiresAt,
      // Authenticated (the reference stays private): the side-by-side player and its poster.
      videoUrl: r.storageKey ? `${base}/video` : undefined, posterUrl: sheet ? `${base}/poster` : undefined,
      recipe: recipe ? { ...recipe, id: r.id, origin: recipe.origin ?? 'reference', referenceId: r.id, createdAt: r.createdAt,
        slots: recipe.slots.map(sl => { const job = r.fill?.jobs?.[sl.id];
          return { ...sl, thumbUrl: sheet ? `${base}/slots/${sl.id}/thumb` : undefined, ...(job ? { fill: { jobId: job.jobId } } : {}) }; }),
        contactSheet: sheet ? { url: `${base}/contact-sheet`, times: sheet.times ?? recipe.slots.map(x => x.keyframeSec), tiles: sheet.tiles ?? [] } : null } : undefined,
    };
  }

  /** Live progress to whoever may see it (the creator and the owner): `{type: "recreate", reference}`. */
  private emit(r: Row) {
    const v = this.view(r);
    void this.ctx.hub.emit(r.studioId, viewer => (viewer.userId === r.userId || viewer.role === 'owner' ? { type: 'recreate', reference: { ...v, recipe: undefined, slots: r.recipe?.slots.length } } : null));
  }

  /** A reference this user may see: their own, or any in the studio for the owner. */
  async row(u: AuthUser, id: string): Promise<Row> {
    const [r] = await this.ctx.db.select().from(recreateReferences).where(and(eq(recreateReferences.id, id), eq(recreateReferences.studioId, u.studioId)));
    if (!r || r.deletedAt || (u.role !== 'owner' && r.userId !== u.id)) throw notFound('Reference');
    return r;
  }

  async list(u: AuthUser) {
    await this.resume();
    void this.sweep();
    const where = and(eq(recreateReferences.studioId, u.studioId), isNull(recreateReferences.deletedAt), ...(u.role === 'owner' ? [] : [eq(recreateReferences.userId, u.id)]));
    const rows = await this.ctx.db.select().from(recreateReferences).where(where).orderBy(desc(recreateReferences.createdAt));
    return rows.map(r => { const v = this.view(r); return { ...v, recipe: undefined, slots: r.recipe?.slots.length }; });
  }

  /** A studio video upload (≤ 60 s) becomes a reference; its analysis starts in the background. */
  async create(u: AuthUser, body: unknown) {
    await this.resume();
    void this.sweep();
    const b = parse(CreateBody, body);
    const [up] = await this.ctx.db.select().from(uploads).where(and(eq(uploads.id, b.uploadId), eq(uploads.studioId, u.studioId)));
    if (!up) throw notFound('Upload');
    if (!up.contentType.startsWith('video/')) throw badRequest('uploadId: must be a video');
    if (!(await this.ctx.storage.head(up.storageKey))) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it first');
    const c = this.ctx.config;
    const info = await this.withLocal(up.storageKey, f => probe(c.FFPROBE_PATH, f)).catch(() => null);
    if (!info?.width) throw badRequest('That file isn’t a video MUSE can read');
    if (info.duration > MAX_REFERENCE_SEC + 0.5) throw badRequest(`References can be up to ${MAX_REFERENCE_SEC} s for now (this one is ${Math.round(info.duration)} s)`);
    const now = Date.now();
    const [r] = await this.ctx.db.insert(recreateReferences).values({
      id: uid('rx'), studioId: u.studioId, userId: u.id, name: b.name || 'Reference', uploadId: up.id, storageKey: up.storageKey, durationSec: Math.round(info.duration * 1000) / 1000,
      state: 'analyzing', phase: 'Waiting', createdAt: now, expiresAt: now + KEEP_DAYS * DAY,
    }).returning();
    this.enqueue(r!.id);
    this.emit(r!);
    return this.view(r!);
  }

  async patch(u: AuthUser, id: string, body: unknown) {
    const b = parse(PatchBody, body);
    const r = await this.row(u, id);
    const [n] = await this.ctx.db.update(recreateReferences).set({ ...(b.keep !== undefined ? { keep: b.keep, ...(b.keep ? {} : { expiresAt: Math.max(r.expiresAt, Date.now() + KEEP_DAYS * DAY) }) } : {}),
      ...(b.name !== undefined ? { name: b.name || 'Reference' } : {}) }).where(eq(recreateReferences.id, r.id)).returning();
    this.emit(n!);
    return this.view(n!);
  }

  /** Deletes the reference video, its contact sheet and the row's recipe. */
  async remove(u: AuthUser, id: string) {
    const r = await this.row(u, id);
    await this.purge(r);
    await this.ctx.db.delete(recreateReferences).where(eq(recreateReferences.id, r.id));
  }

  /** The contact sheet PNG (authenticated: the reference stays private). */
  async contactSheet(u: AuthUser, id: string) {
    const r = await this.row(u, id);
    if (!r.contactSheetKey) throw notFound('Contact sheet');
    const obj = await this.ctx.storage.get(r.contactSheetKey);
    if (!obj) throw notFound('Contact sheet');
    return obj;
  }

  // ------------------------------------------------------------------ slots: briefs, matching, filling, assembly
  private async ready(u: AuthUser, id: string) {
    const r = await this.row(u, id);
    if (r.state !== 'ready' || !r.recipe) throw new ApiError(409, 'not_ready', r.state === 'failed' ? 'The analysis failed · add the reference again' : 'The recipe isn’t ready yet');
    return { r, recipe: r.recipe as Recipe };
  }
  private async saveRecipe(id: string, recipe: Recipe) {
    const [n] = await this.ctx.db.update(recreateReferences).set({ recipe }).where(eq(recreateReferences.id, id)).returning();
    return n!;
  }

  /** Claude's (or the owner's) shot briefs: `{slots: {s1: {shotSize, angle, subject, action, location, notes}}}`. */
  async setBriefs(u: AuthUser, id: string, body: unknown) {
    const b = parse(z.object({ slots: z.record(z.string(), BriefSchema).optional(), summary: z.string().trim().max(200).optional(),
      tags: z.array(z.string().trim().toLowerCase().regex(/^[a-z0-9][a-z0-9 -]{0,39}$/, 'tags are short words or phrases')).max(20).optional() }).strict(), body);
    const { r, recipe } = await this.ready(u, id);
    let next: Recipe;
    try { next = withBriefs(recipe, b.slots ?? {}); } catch (e) { throw badRequest(`slots: ${(e as Error).message}`); }
    if (b.summary !== undefined) next = { ...next, summary: b.summary };
    if (b.tags) next = { ...next, tags: [...new Set(b.tags)] };
    return this.view(await this.saveRecipe(r.id, next));
  }

  /** The studio's video takes that could fill each slot, scored, plus a suggested assignment (each take once). */
  async match(u: AuthUser, id: string, body: unknown) {
    const b = parse(z.object({ modelId: z.string().max(80).optional(), top: z.number().int().min(1).max(10).optional(), minScore: z.number().min(0).max(1).optional() }).strict(), body);
    const { recipe } = await this.ready(u, id);
    const rows = await this.ctx.db.select().from(takesTable).where(and(eq(takesTable.studioId, u.studioId), eq(takesTable.kind, 'take'))).orderBy(desc(takesTable.createdAt)).limit(300);
    const cands: Candidate[] = rows.filter(t => t.mediaKey && Number(t.media?.durationSec) > 0).map(t => ({
      id: t.id, modelId: t.modelId, durationSec: Number(t.media!.durationSec), width: Number(t.media?.width) || 0, height: Number(t.media?.height) || 0,
      status: t.status, createdAt: t.createdAt, draft: t.draft ?? null, title: t.title,
    }));
    const m = matchSlots(recipe, cands, { leadModelId: b.modelId, top: b.top, minScore: b.minScore });
    const r = await this.row(u, id);
    const matched = Object.fromEntries(m.slots.filter(x => x.suggested).map(x => { const c = x.candidates.find(y => y.takeId === x.suggested)!; return [x.slotId, { takeId: c.takeId, score: c.score, reasons: c.reasons }]; }));
    await this.saveFill(r, { ...(r.fill ?? {}), matched, toGenerate: m.slots.filter(x => x.toGenerate).map(x => x.slotId) });
    return m;
  }
  private async saveFill(r: Row, fill: FillState) {
    await this.ctx.db.update(recreateReferences).set({ fill }).where(eq(recreateReferences.id, r.id));
  }

  /**
   * Each slot's state for the app: ready (its fill job is done), generating, matched (the last match's take), to
   * generate, or empty; with the last assembly's match score and sources.
   */
  async fillView(u: AuthUser, id: string) {
    const r = await this.row(u, id);
    const recipe = r.recipe as Recipe | null, f = r.fill ?? {};
    const jobIds = Object.values(f.jobs ?? {}).map(j => j.jobId);
    const js = jobIds.length ? await this.ctx.db.select({ id: jobs.id, state: jobs.state }).from(jobs).where(inArray(jobs.id, jobIds)) : [];
    const ts = jobIds.length ? await this.ctx.db.select({ id: takesTable.id, jobId: takesTable.jobId, index: takesTable.index }).from(takesTable).where(inArray(takesTable.jobId, jobIds)) : [];
    const slots = (recipe?.slots ?? []).map(sl => {
      const job = f.jobs?.[sl.id], m = f.matched?.[sl.id];
      if (job) {
        const st = js.find(x => x.id === job.jobId)?.state;
        const take = ts.filter(x => x.jobId === job.jobId).sort((a, b) => a.index - b.index)[0];
        if (st === 'done' && take) return { slotId: sl.id, state: 'ready' as const, takeId: take.id, jobId: job.jobId, reason: 'Generated for this slot' };
        if (st !== 'failed') return { slotId: sl.id, state: 'generating' as const, jobId: job.jobId, ...(job.estimate != null ? { estimate: { amount: job.estimate, label: `about $${job.estimate.toFixed(2)}` } } : {}) };
      }
      if (m) return { slotId: sl.id, state: 'matched' as const, takeId: m.takeId, score: m.score, reason: m.reasons.join(', ') };
      if (f.toGenerate?.includes(sl.id)) return { slotId: sl.id, state: 'to_generate' as const, reason: 'None of your takes fits this shot' };
      return { slotId: sl.id, state: 'empty' as const };
    });
    return { referenceId: r.id, slots, ...(f.applied ? { applied: f.applied, match: f.applied.match } : {}) };
  }

  private fillRequest(recipe: Recipe, r: Row, slotId: string, body: unknown) {
    const b = parse(z.object({ modelId: z.string().min(1).max(80), quality: z.enum(['draft', 'standard', 'hd', 'cinema']).default('standard') }).strict(), body);
    const slot = recipe.slots.find(s => s.id === slotId);
    if (!slot) throw notFound('Slot');
    return { slot, request: shotRequestFor(recipe, slot, { modelId: b.modelId, quality: b.quality ?? 'standard', referenceName: r.name }) };
  }
  /** The price of filling a slot with a new Suite shot (nothing is held). */
  async estimateSlot(u: AuthUser, id: string, slotId: string, body: unknown) {
    const { r, recipe } = await this.ready(u, id);
    const { request } = this.fillRequest(recipe, r, slotId, body);
    return { slotId, request, estimate: await this.ctx.suite.estimate(u, request) };
  }
  /** Fills a slot with a new Suite shot: an ordinary job, held and priced like any shot (the caller confirmed the price). */
  async fillSlot(u: AuthUser, id: string, slotId: string, body: unknown) {
    const { r, recipe } = await this.ready(u, id);
    const { request } = this.fillRequest(recipe, r, slotId, body);
    const job = await this.ctx.suite.create(u, request) as { id: string; cost?: number };
    const fresh = await this.row(u, id);
    await this.saveFill(fresh, { ...(fresh.fill ?? {}), jobs: { ...(fresh.fill?.jobs ?? {}), [slotId]: { jobId: job.id, estimate: job.cost, at: Date.now() } } });
    return { slotId, job };
  }

  /**
   * Builds the edit from the recipe and a take (or a finished fill job) per slot, and puts it in an edit session as one
   * undoable change (Claude's, or the owner's from the app). Slots without a take are left out.
   */
  async apply(u: AuthUser, id: string, body: unknown, o: { by: 'claude' | 'app'; device?: string } = { by: 'app' }) {
    const b = parse(z.object({
      sessionId: z.string().min(1), baseRevision: z.number().int().min(0).optional(),
      slots: z.record(z.string(), z.string().min(1).max(80)),
      options: z.object({ camera: z.boolean().optional(), speed: z.boolean().optional(), text: z.boolean().optional(), look: z.boolean().optional() }).strict().optional(),
    }).strict(), body);
    const { r, recipe } = await this.ready(u, id);
    const svc = editSessionsOf(this.ctx);
    const s = await svc.row(u, b.sessionId);
    const ids = Object.values(b.slots);
    const unknownSlot = Object.keys(b.slots).find(k => !recipe.slots.some(x => x.id === k));
    if (unknownSlot) throw badRequest(`slots: no slot ${unknownSlot}`);
    // A value is a take, or a finished job whose first take fills the slot.
    const doneJobs = await this.ctx.db.select({ id: jobs.id, state: jobs.state }).from(jobs).where(and(eq(jobs.studioId, u.studioId), inArray(jobs.id, ids.length ? ids : ['-'])));
    const rows = await this.ctx.db.select().from(takesTable).where(and(eq(takesTable.studioId, u.studioId), eq(takesTable.kind, 'take')));
    const byId = new Map(rows.map(t => [t.id, t]));
    const takes: Record<string, TakeInfo | undefined> = {};
    const waiting: string[] = [];
    for (const [slotId, v] of Object.entries(b.slots)) {
      let t = byId.get(v);
      if (!t && doneJobs.some(j => j.id === v)) {
        t = rows.filter(x => x.jobId === v).sort((x, y) => x.index - y.index)[0];
        if (!t) { waiting.push(slotId); continue; }
      }
      if (!t) throw badRequest(`slots.${slotId}: no video take or job ${v}`);
      if (!t.mediaKey) throw badRequest(`slots.${slotId}: the take has no video yet`);
      takes[slotId] = { id: t.id, durationSec: Number(t.media?.durationSec) || 1, width: Number(t.media?.width) || 1080, height: Number(t.media?.height) || 1920, hasAudio: true };
    }
    const out = buildProject(recipe, s.takeId, takes, (b.options ?? {}) as AssembleOptions);
    if (!out.project.tracks[0]!.items.length) throw badRequest('slots: give at least one slot a take');
    const label = `Recreated “${r.name}”`;
    const res = o.by === 'claude'
      ? await svc.applyClaude(u, s.id, { baseRevision: b.baseRevision ?? s.revision, ops: [{ op: 'patch', patch: [
          { op: 'replace', path: '/canvas', value: out.project.canvas }, { op: 'replace', path: '/assets', value: out.project.assets },
          { op: 'replace', path: '/tracks', value: out.project.tracks }] }], label })
      : await svc.reset(u, s.id, { baseRevision: b.baseRevision ?? s.revision, project: out.project, device: o.device, label });
    const fresh = await this.row(u, id);
    const match = matchScore(recipe, out.project, takes, fresh.fill ?? {}, (b.options ?? {}) as AssembleOptions);
    const sources = sourcesOf(recipe, out.project, r.id, takes);
    await this.saveFill(fresh, { ...(fresh.fill ?? {}), applied: { sessionId: s.id, revision: res.revision, at: Date.now(), slots: Object.fromEntries(Object.entries(takes).filter(([, t]) => t).map(([k, t]) => [k, t!.id])), sources, match } });
    return { sessionId: s.id, revision: res.revision, durationSec: out.durationSec, missing: [...out.missing.filter(x => !waiting.includes(x)), ...waiting], waiting, notes: out.notes, label, match, sources };
  }

  /** One slot's thumbnail, cropped from the contact sheet (PNG). `slotId` null = the poster (the first slot). */
  async thumb(u: AuthUser, id: string, slotId: string | null) {
    const r = await this.row(u, id);
    const recipe = r.recipe as Recipe | null;
    const tiles = recipe?.contactSheet?.tiles ?? [];
    const tile = slotId ? tiles.find(t => t.slotId === slotId) : tiles[0];
    if (!r.contactSheetKey || !tile) throw notFound(slotId ? 'Slot' : 'Poster');
    const obj = await this.ctx.storage.get(r.contactSheetKey);
    if (!obj) throw notFound('Contact sheet');
    const chunks: Buffer[] = []; for await (const c of obj.body as AsyncIterable<Buffer>) chunks.push(Buffer.from(c));
    const sharp = (await import('sharp')).default;
    return sharp(Buffer.concat(chunks)).extract({ left: tile.x, top: tile.y, width: tile.w, height: tile.h }).png().toBuffer();
  }
  /** The reference video for the side-by-side player (authenticated; a short-lived link on S3). */
  async video(u: AuthUser, id: string): Promise<{ redirect: string } | { body: NodeJS.ReadableStream; contentType: string }> {
    const r = await this.row(u, id);
    if (!r.storageKey) throw notFound('Reference video');
    if (this.ctx.storage.kind === 's3') return { redirect: await this.ctx.storage.presignGet(r.storageKey, 3600) };
    const obj = await this.ctx.storage.get(r.storageKey);
    if (!obj) throw notFound('Reference video');
    return { body: obj.body as NodeJS.ReadableStream, contentType: obj.contentType };
  }

  /** Waits for the analysis queue to empty (tests, shutdown). */
  async idle() { while (this.running) await this.running; }

  // ------------------------------------------------------------------ analysis
  private enqueue(id: string) {
    this.queue.push(id);
    if (!this.running) this.running = this.drain().finally(() => { this.running = null; });
  }
  private async drain() {
    // One at a time: the analysis decodes video on a small instance.
    while (this.queue.length) await this.analyze(this.queue.shift()!).catch(() => undefined);
  }
  private async analyze(id: string) {
    const db = this.ctx.db, c = this.ctx.config;
    const [r] = await db.select().from(recreateReferences).where(eq(recreateReferences.id, id));
    if (!r || r.state !== 'analyzing' || !r.storageKey) return;
    const set = async (v: Partial<Row>) => { const [n] = await db.update(recreateReferences).set(v).where(eq(recreateReferences.id, id)).returning(); if (n) this.emit(n); };
    try {
      const out = await this.withLocal(r.storageKey, f => analyzeReference({ ffmpeg: c.FFMPEG_PATH, ffprobe: c.FFPROBE_PATH, ...(c.TESSERACT_PATH ? { tesseract: c.TESSERACT_PATH } : {}),
        ...(c.RECREATE_POSE ? { pose: { minFreeMb: c.RECREATE_POSE_MIN_FREE_MB } } : {}) }, f, {
        maxSec: MAX_REFERENCE_SEC + 1, progress: (p, phase) => set({ progress: Math.round(5 + p * 90), phase }),
      }));
      // The pose child's peak memory, for sizing the instance (plans/recreate-edit.md "Pose").
      if (out.recipe.analyzer.pose) this.ctx.log?.info({ referenceId: r.id, pose: out.recipe.analyzer.pose }, 'recreate pose');
      let sheet: string | null = null;
      if (out.contactSheetPng) {
        sheet = `rx/${r.studioId}/${r.id}/contact.png`;
        await this.ctx.storage.put(sheet, out.contactSheetPng, 'image/png');
      }
      await set({ state: 'ready', progress: 100, phase: 'Done', recipe: out.recipe as Recipe, contactSheetKey: sheet, error: null });
    } catch (e) {
      await set({ state: 'failed', phase: 'Failed', error: `The analysis didn’t finish: ${(e as Error).message.slice(0, 200)}` });
    }
  }

  private async withLocal<T>(key: string, fn: (input: string) => Promise<T>): Promise<T> {
    if (this.ctx.storage.kind === 's3') return fn(await this.ctx.storage.presignGet(key, 900));
    const obj = await this.ctx.storage.get(key);
    if (!obj) throw new Error('media missing');
    const file = path.join(os.tmpdir(), `${uid('rxin')}${path.extname(key) || '.mp4'}`);
    try {
      await pipeline(obj.body as NodeJS.ReadableStream, fs.createWriteStream(file));
      return await fn(file);
    } finally { fs.rmSync(file, { force: true }); }
  }

  // ------------------------------------------------------------------ retention
  /** Expired references (30 days, not kept) lose their video and contact sheet; the recipe stays (no pixels in it). At most hourly. */
  async sweep(now = Date.now(), force = false) {
    if (!force && now - this.lastSweep < 3_600_000) return 0;
    this.lastSweep = now;
    const due = await this.ctx.db.select().from(recreateReferences)
      .where(and(lt(recreateReferences.expiresAt, now), eq(recreateReferences.keep, false), isNull(recreateReferences.deletedAt)));
    for (const r of due) {
      await this.purge(r);
      await this.ctx.db.update(recreateReferences).set({ state: 'expired', deletedAt: now, storageKey: null, uploadId: null, contactSheetKey: null }).where(eq(recreateReferences.id, r.id));
    }
    return due.length;
  }
  private async purge(r: Row) {
    const st = this.ctx.storage;
    if (r.contactSheetKey) await st.delete(r.contactSheetKey).catch(() => undefined);
    if (r.storageKey) {
      await st.delete(r.storageKey).catch(() => undefined);
      if (r.uploadId) await this.ctx.db.delete(uploads).where(eq(uploads.id, r.uploadId));
    }
  }
}

const services = new WeakMap<Ctx, RecreateReferences>();
export const recreateOf = (ctx: Ctx) => { let s = services.get(ctx); if (!s) { s = new RecreateReferences(ctx); services.set(ctx, s); } return s; };

/** How close the assembled edit is to the reference, per element (0–1). */
export function matchScore(recipe: Recipe, project: import('../editor/model.js').EditProject, takes: Record<string, TakeInfo | undefined>, fill: FillState, o: AssembleOptions): MatchScore {
  const r2 = (x: number) => Math.round(x * 100) / 100;
  const used = recipe.slots.filter(s => takes[s.id]);
  // Cuts: each used slot's start on the timeline against the reference (exact = 1, off by 2 frames or more = 0).
  const tl = timeline(project);
  const frame = 1 / Math.max(1, recipe.source.fps || 30);
  const cutErr = used.slice(1).map((s, i) => Math.abs((tl[i + 1]?.startSec ?? 0) + (tl[i + 1]?.transitionSec ?? 0) / 2 - s.startSec));
  const coverage = used.length / Math.max(1, recipe.slots.length);
  const cuts = (cutErr.length ? cutErr.reduce((a, e) => a + Math.max(0, 1 - e / (2 * frame)), 0) / cutErr.length : 1) * coverage;
  const text = !recipe.text.length ? 1 : o.text === false ? 0 : recipe.text.reduce((a, x) => a + (x.words ? 1 : 0.6), 0) / recipe.text.length;
  const ramped = recipe.slots.filter(s => s.speed.ramp !== 'none' && s.speed.ramp !== 'freeze');
  const ramps = !ramped.length ? 1 : o.speed === false ? 0 : ramped.filter(s => takes[s.id]).length / ramped.length;
  const look = recipe.grade.look;
  const grade = !look ? 0.5 : o.look === false || look.distance >= 0.4 ? 0 : Math.max(0, 1 - look.distance);
  const perSlot = recipe.slots.map(s => {
    const t = takes[s.id];
    if (!t) return { slotId: s.id, score: 0 };
    const m = fill.matched?.[s.id];
    const generated = !!fill.jobs?.[s.id];
    return { slotId: s.id, score: r2(m && m.takeId === t.id ? m.score : generated ? 0.85 : 0.6) };
  });
  const shots = perSlot.reduce((a, x) => a + x.score, 0) / Math.max(1, perSlot.length);
  const overall = 0.25 * cuts + 0.35 * shots + 0.15 * text + 0.1 * ramps + 0.15 * grade;
  return { overall: r2(overall), cuts: r2(cuts), text: r2(text), ramps: r2(ramps), grade: r2(grade), shots: r2(shots), perSlot };
}

/** Which recipe element each item of the assembled project came from (for workstream 3's corrections log). */
export function sourcesOf(recipe: Recipe, project: import('../editor/model.js').EditProject, recipeId: string, takes: Record<string, TakeInfo | undefined>): Record<string, RecipeSource> {
  const out: Record<string, RecipeSource> = {};
  const main = project.tracks.find(t => t.kind === 'main')?.items ?? [];
  // Main clips are in slot order; slots without a take were left out.
  const used = recipe.slots.filter(s => takes[s.id]);
  used.forEach((s, k) => {
    const it = main[k] as { id: string; transitionIn?: unknown } | undefined;
    if (!it) return;
    const tr = it.transitionIn ? recipe.transitions.find(t => t.to === s.id && t.from !== t.to) : undefined;
    out[it.id] = { recipeId, slotId: s.id, ...(tr ? { transitionAt: tr.atSec } : {}) };
  });
  // Text items keep the recipe's order (x1, x2, …).
  (project.tracks.find(t => t.kind === 'text')?.items ?? []).forEach((it, i) => { out[it.id] = { recipeId, textId: recipe.text[i]?.id ?? it.id }; });
  return out;
}
