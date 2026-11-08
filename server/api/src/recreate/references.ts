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
import { clips as clipsTable, models, uploads } from '../db/schema.js';
import * as P from '../pricing.js';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { probe } from '../replicate/media.js';
import { takes as takesTable, jobs } from '../db/schema.js';
import { editSessionsOf } from '../editor/sessions.js';
import { clipLength, timeline } from '../editor/model.js';
import { findPeaks, measureMotion } from '../editor/motion.js';
import { analyzeReference, type Recipe } from './analyze.js';
import { poseSimilarity, readPoseTracks, type PoseTrack } from './poseTrack.js';
import { BAKED_ELEMENTS, buildProject, peakInPoint, rangeFor, type AssembleOptions, type TakeInfo } from './assemble.js';
import { BriefSchema, matchSlots, promptSource, shotRequestFor, swapDirection, swapSegment, withBriefs, type Candidate } from './slots.js';
import { learningOf } from '../editor/learn.js';
import { pinnedDirectives, provenStart } from './playbook.js';
import { rendersOf, type RenderState } from '../editor/renders.js';
import type { EditProject } from '../editor/model.js';
import { checkInfo, FALLBACK, linkError, normalizeLink, tiktokDownloadsOff, ytDlp, type Resolver } from './links.js';
import { recreateReferences } from './schema.js';

export const MAX_REFERENCE_SEC = 60;
/** Matching by movement: at most this many takes are read for poses per match, over their first seconds. */
export const POSE_MATCH_TAKES = 8, POSE_TAKE_SEC = 6;
export const KEEP_DAYS = 30;
const DAY = 86_400_000;

type Row = typeof recreateReferences.$inferSelect;

/** Matching, filling and assembly state, kept apart from the recipe (the analysis). */
export type FillState = {
  /** The last match: the suggested take per slot, with its score and reasons. */
  matched?: Record<string, { takeId: string; score: number; reasons: string[] }>;
  toGenerate?: string[];
  /**
   * Slots being filled: by a Suite shot (method "generate"), or by swapping the model into the reference's own segment
   * (method "swap", G2: the segment's place in the reference, and the private segment clip deleted with the reference).
   */
  jobs?: Record<string, { jobId: string; estimate?: number; at: number; method?: 'swap' | 'generate'; segment?: { startSec: number; endSec: number }; clipId?: string; clipKey?: string }>;
  /** The last assembly: where, which take per slot, which project item came from which recipe element, and the score. */
  applied?: { sessionId: string; revision: number; at: number; slots: Record<string, string>; sources: Record<string, RecipeSource>; match: MatchScore;
    /** Swapped slots and what their pixels already carry from the reference (not applied again). */
    baked?: Record<string, string[]> };
  /** Gap keys already reported to the learning editor for this reference (each once). */
  gapsReported?: string[];
  /** Exports made from this reference (storage keys), deleted with it. */
  exports?: string[];
};
const FillBody = z.object({
  modelId: z.string().min(1).max(80), quality: z.enum(['draft', 'standard', 'hd', 'cinema']).default('standard'),
  /** G2: "swap" (default when possible) puts the model into the reference's own segment; "generate" makes a new shot. */
  method: z.enum(['swap', 'generate']).optional(),
  outfitId: z.string().max(80).optional(),
  /** Swap: keep the reference's setting (default), or "Use your own setting" from the slot's brief (needs Edit). */
  keepBackground: z.boolean().default(true),
}).strict();
type FillBody = z.infer<typeof FillBody>;
const run = promisify(execFile);
export type RecipeSource = { recipeId: string; slotId?: string; textId?: string; transitionAt?: number };
export type MatchScore = { overall: number; cuts: number; text: number; ramps: number; grade: number; shots: number; perSlot: { slotId: string; score: number }[] };

const CreateBody = z.union([
  z.object({ uploadId: z.string().min(1).max(80), name: z.string().trim().max(80).optional() }).strict(),
  z.object({ url: z.string().trim().min(8).max(500), name: z.string().trim().max(80).optional() }).strict(),
]);
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
      source: r.sourceUrl ? 'link' as const : 'file' as const, sourceUrl: r.sourceUrl ?? undefined, errorCode: r.errorCode ?? undefined,
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
    if ('url' in b) return this.createFromLink(u, b);
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

  // ------------------------------------------------------------------ links (plans/research/platform-download-rules.md)
  /** The link resolver (yt-dlp; tests replace it). */
  resolver: Resolver | null = null;
  /** Reads a public page (TikTok's downloads setting); tests replace it. No cookies, no sign-in. */
  fetchPage = async (url: string) => {
    const r = await fetch(url, { headers: { 'user-agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36', 'accept-language': 'en' }, redirect: 'follow', signal: AbortSignal.timeout(20_000) });
    if (!r.ok) throw linkError('link_blocked', FALLBACK);
    return r.text();
  };
  private linkChain: Promise<unknown> = Promise.resolve();
  /** One platform request at a time across the server. */
  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const p = this.linkChain.then(fn, fn);
    this.linkChain = p.catch(() => undefined);
    return p;
  }
  private get links() { return this.resolver ?? ytDlp(this.ctx.config.YTDLP_PATH); }
  private get maxLinkBytes() { return this.ctx.config.RECREATE_LINK_MAX_MB * 1048576; }
  /** The member's own live reference from the same link (fetched once; deleted or expired ones don't count). */
  private async cachedLink(u: AuthUser, url: string) {
    const [r] = await this.ctx.db.select().from(recreateReferences).where(and(eq(recreateReferences.studioId, u.studioId), eq(recreateReferences.userId, u.id),
      eq(recreateReferences.sourceUrl, url), isNull(recreateReferences.deletedAt), inArray(recreateReferences.state, ['analyzing', 'ready']))).orderBy(desc(recreateReferences.createdAt)).limit(1);
    return r && (r.storageKey || r.state === 'analyzing') ? r : null;
  }

  /**
   * A reference from a public link: the metadata is read and checked (public, not age-gated, the creator allows
   * downloads, ≤ 60 s, under the size cap) before anything is downloaded; the download and the analysis run in the
   * queue. The same link again (by this member) returns the reference already made (`cached: true`).
   */
  private async createFromLink(u: AuthUser, b: { url: string; name?: string }) {
    if (!this.ctx.config.RECREATE_LINKS) throw linkError('link_blocked', FALLBACK);
    const n = normalizeLink(b.url);
    const hit = await this.cachedLink(u, n.url);
    if (hit) return { ...this.view(hit), cached: true };
    const info = await this.serial(() => this.links.info(n.url));
    let url = n.url;
    try { if (info.webpage_url) url = normalizeLink(info.webpage_url).url; } catch { /* keep the pasted form */ }
    if (url !== n.url) { const again = await this.cachedLink(u, url); if (again) return { ...this.view(again), cached: true }; }
    checkInfo(info, { maxSec: MAX_REFERENCE_SEC, maxBytes: this.maxLinkBytes });
    if (n.platform === 'tiktok') {
      const html = await this.serial(() => this.fetchPage(url)).catch(e => { throw e instanceof ApiError ? e : linkError('link_blocked', FALLBACK); });
      if (tiktokDownloadsOff(html) === true) throw linkError('link_downloads_off', 'The creator turned downloads off for this video, so MUSE won’t fetch it. Use another video, or ask the creator');
    }
    const now = Date.now(), id = uid('rx');
    // The metadata, for the download (no second page request); deleted once the video is stored.
    await this.ctx.storage.put(`rx/${u.studioId}/${id}/info.json`, Buffer.from(JSON.stringify(info)), 'application/json');
    const [r] = await this.ctx.db.insert(recreateReferences).values({
      id, studioId: u.studioId, userId: u.id, name: b.name || (info.title ?? '').trim().slice(0, 80) || 'Reference', uploadId: null, storageKey: null, sourceUrl: url,
      durationSec: info.duration != null ? Math.round(info.duration * 1000) / 1000 : null, state: 'analyzing', phase: 'Fetching the video', createdAt: now, expiresAt: now + KEEP_DAYS * DAY,
    }).returning();
    this.enqueue(r!.id);
    this.emit(r!);
    return this.view(r!);
  }

  /** Downloads a link's video into private storage (rx/…/source.mp4) and checks it; the reference fails with a code when it can't. */
  private async fetchLinkVideo(r: Row, set: (v: Partial<Row>) => Promise<void>): Promise<Row | null> {
    const infoKey = `rx/${r.studioId}/${r.id}/info.json`, dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rxlink-'));
    try {
      const obj = await this.ctx.storage.get(infoKey);
      if (!obj) throw linkError('link_blocked', FALLBACK);
      const infoFile = path.join(dir, 'info.json');
      await pipeline(obj.body as NodeJS.ReadableStream, fs.createWriteStream(infoFile));
      const file = await this.serial(() => this.links.download(infoFile, dir, { maxBytes: this.maxLinkBytes, ffmpeg: this.ctx.config.FFMPEG_PATH }));
      const info = await probe(this.ctx.config.FFPROBE_PATH, file).catch(() => null);
      if (!info?.width) throw linkError('link_blocked', FALLBACK);
      if (info.duration > MAX_REFERENCE_SEC + 0.5) throw linkError('too_long', `References can be up to ${MAX_REFERENCE_SEC} s for now (this one is ${Math.round(info.duration)} s)`, 400);
      const key = `rx/${r.studioId}/${r.id}/source.mp4`, size = fs.statSync(file).size;
      await this.ctx.storage.putStream(key, fs.createReadStream(file), 'video/mp4', size);
      const [n] = await this.ctx.db.update(recreateReferences).set({ storageKey: key, durationSec: Math.round(info.duration * 1000) / 1000, phase: 'Fetched' })
        .where(eq(recreateReferences.id, r.id)).returning();
      return n ?? null;
    } catch (e) {
      const err = e instanceof ApiError ? e : linkError('link_blocked', FALLBACK);
      await set({ state: 'failed', phase: 'Failed', error: err.message, errorCode: err.code });
      return null;
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
      await this.ctx.storage.delete(infoKey).catch(() => undefined);
    }
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
    const b = parse(z.object({ modelId: z.string().max(80).optional(), top: z.number().int().min(1).max(10).optional(), minScore: z.number().min(0).max(1).optional(),
      /** Compare movement with the takes' poses (default true; the first time reads up to POSE_MATCH_TAKES takes, free CPU). */
      poses: z.boolean().optional() }).strict(), body);
    const { r: ref, recipe } = await this.ready(u, id);
    const rows = await this.ctx.db.select().from(takesTable).where(and(eq(takesTable.studioId, u.studioId), eq(takesTable.kind, 'take'))).orderBy(desc(takesTable.createdAt)).limit(300);
    const cands: Candidate[] = rows.filter(t => t.mediaKey && Number(t.media?.durationSec) > 0).map(t => ({
      id: t.id, modelId: t.modelId, durationSec: Number(t.media!.durationSec), width: Number(t.media?.width) || 0, height: Number(t.media?.height) || 0,
      status: t.status, createdAt: t.createdAt, draft: t.draft ?? null, title: t.title,
    }));
    const pose = b.poses === false ? undefined : await this.poseScores(u, ref, recipe, cands, rows, b.modelId).catch(e => { this.ctx.log?.warn({ err: String(e) }, 'recreate pose match'); return undefined; });
    const m = matchSlots(recipe, cands, { leadModelId: b.modelId, top: b.top, minScore: b.minScore, pose });
    const r = await this.row(u, id);
    const matched = Object.fromEntries(m.slots.filter(x => x.suggestion).map(x => [x.slotId, { takeId: x.suggestion!.takeId, score: x.suggestion!.score, reasons: x.suggestion!.reasons }]));
    await this.saveFill(r, { ...(r.fill ?? {}), matched, toGenerate: m.slots.filter(x => x.toGenerate).map(x => x.slotId) });
    return m;
  }
  private posesKey = (r: Pick<Row, 'studioId' | 'id'>) => `rx/${r.studioId}/${r.id}/poses.json`;
  /**
   * Pose similarity per slot and take (the per-frame movement), for the takes that already score best on everything
   * else (at most POSE_MATCH_TAKES, each read once at 10 fps over its first seconds and cached with the take's media).
   */
  private async poseScores(u: AuthUser, r: Row, recipe: Recipe, cands: Candidate[], rows: (typeof takesTable.$inferSelect)[], leadModelId?: string) {
    if (!this.ctx.config.RECREATE_POSE) return undefined;
    const obj = await this.ctx.storage.get(this.posesKey(r)).catch(() => null);
    if (!obj) return undefined;
    const chunks: Buffer[] = []; for await (const c of obj.body as AsyncIterable<Buffer>) chunks.push(Buffer.from(c));
    const shots = (JSON.parse(Buffer.concat(chunks).toString('utf8')) as { slots: Record<string, PoseTrack | null> }).slots;
    // Only shots where someone was seen most of the time.
    const withTrack = recipe.slots.filter(s => { const t = shots[s.id]; return !!t && t.frames.filter(Boolean).length >= 0.3 * t.frames.length; });
    if (!withTrack.length) return undefined;
    // The best few takes on everything else, across the slots that have movement to compare.
    const base = matchSlots({ ...recipe, slots: withTrack }, cands, { leadModelId, top: 4, minScore: 0 });
    const pick = [...new Set(base.slots.flatMap(s => s.candidates.map(c => c.takeId)))].slice(0, POSE_MATCH_TAKES);
    const out: Record<string, Record<string, { score: number; coverage: number }>> = {};
    for (const takeId of pick) {
      const row = rows.find(t => t.id === takeId);
      if (!row?.mediaKey) continue;
      const track = await this.takeTrack(row);
      if (!track) continue;
      for (const s of withTrack) {
        const sim = poseSimilarity(shots[s.id]!, track, s.durationSec);
        if (sim) (out[s.id] ??= {})[takeId] = sim;
      }
    }
    return out;
  }
  private trackCache = new Map<string, PoseTrack | null>();
  /** A take's poses at 10 fps over its first POSE_TAKE_SEC seconds (cached by take and media). */
  private async takeTrack(t: typeof takesTable.$inferSelect): Promise<PoseTrack | null> {
    const k = `${t.id}:${t.mediaKey}`;
    if (this.trackCache.has(k)) return this.trackCache.get(k)!;
    const c = this.ctx.config;
    const w = Number(t.media?.width) || 720, h = Number(t.media?.height) || 1280, d = Number(t.media?.durationSec) || POSE_TAKE_SEC;
    const run = await this.withLocal(t.mediaKey!, f => readPoseTracks({ ffmpeg: c.FFMPEG_PATH, minFreeMb: c.RECREATE_POSE_MIN_FREE_MB }, f, [{ startSec: 0, endSec: Math.min(d, POSE_TAKE_SEC) }],
      { width: w, height: h, fps: 10 }, { maxFrames: POSE_TAKE_SEC * 10 }));
    const track = 'tracks' in run ? run.tracks[0] ?? null : null;
    if ('tracks' in run || run.skipped !== 'memory') this.trackCache.set(k, track); // short of memory: try again next time
    if (this.trackCache.size > 300) this.trackCache.delete(this.trackCache.keys().next().value!);
    return track;
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
        const method = job.method ?? 'generate';
        if (st === 'done' && take) return { slotId: sl.id, state: 'ready' as const, takeId: take.id, jobId: job.jobId, method, reason: method === 'swap' ? 'Your model in the reference’s own shot' : 'Generated for this slot' };
        if (st !== 'failed') return { slotId: sl.id, state: 'generating' as const, jobId: job.jobId, method, ...(job.estimate != null ? { estimate: { amount: job.estimate, label: `about $${job.estimate.toFixed(2)}` } } : {}) };
        // A failed swap (refunded): offer a generated shot instead, at its own price.
        if (method === 'swap') return { slotId: sl.id, state: 'to_generate' as const, reason: 'The swap didn’t work and you weren’t charged · generate this shot instead', fallback: 'generate' as const, failedJobId: job.jobId };
      }
      if (m) return { slotId: sl.id, state: 'matched' as const, takeId: m.takeId, score: m.score, reason: m.reasons.join(', ') };
      if (f.toGenerate?.includes(sl.id)) return { slotId: sl.id, state: 'to_generate' as const, reason: 'None of your takes fits this shot' };
      return { slotId: sl.id, state: 'empty' as const };
    });
    return { referenceId: r.id, slots, ...(f.applied ? { applied: f.applied, match: f.applied.match } : {}) };
  }

  private fillRequest(recipe: Recipe, r: Row, slotId: string, body: unknown) {
    const b = parse(FillBody, body) as FillBody;
    const slot = recipe.slots.find(s => s.id === slotId);
    if (!slot) throw notFound('Slot');
    return { slot, b, request: shotRequestFor(recipe, slot, { modelId: b.modelId, quality: b.quality ?? 'standard', referenceName: r.name }) };
  }

  /**
   * G2: the engines that can swap the model into the reference's segment, in order: Edit (our pods), then the hosted
   * swap. Your own setting needs Edit (the hosted swap keeps the clip's background).
   */
  private swapEngines(keepBackground: boolean): ('h3' | 'replicate')[] {
    const out: ('h3' | 'replicate')[] = [];
    if (this.ctx.jobs.capabilities().includes('h3')) out.push('h3');
    if (keepBackground && this.ctx.replicate.configured) out.push('replicate');
    return out;
  }
  /** Why a slot can't be swapped (null when it can). */
  private swapBlocked(r: Row, keepBackground: boolean) {
    if (!r.storageKey) return 'The reference’s video is gone (deleted after 30 days), so its shots can’t be swapped · generate them instead';
    if (!this.swapEngines(keepBackground).length) return keepBackground ? 'Swapping isn’t available right now · generate this shot instead' : 'Your own setting needs Edit, which isn’t available right now · keep the reference’s setting, or generate this shot';
    return null;
  }
  /** The swap job for a slot on one engine: the Jobs request (without its clip), the segment and the price. */
  private swapPlan(recipe: Recipe, r: Row, slot: Recipe['slots'][number], b: FillBody, engine: 'h3' | 'replicate') {
    const seg = swapSegment(recipe, slot, engine === 'replicate' ? P.REPLICATE_MIN_SEC : 2);
    const seconds = Math.round((seg.endSec - seg.startSec) * 1000) / 1000;
    const quality = b.quality === 'cinema' ? 'hd' : b.quality;
    const rr: P.RenderReq = engine === 'replicate'
      ? { engine, quality, takes: 1, clipSeconds: seconds, pricePerSec: this.ctx.jobs.qualityPrice(quality) }
      : { engine, use: 'full', steps: P.STEPS_DEFAULT, takes: 1, clipSeconds: seconds };
    const cost = Math.round(P.totalCost(rr) * 100) / 100;
    const request = {
      title: `${r.name || 'Recreate'} · ${slot.id}`, modelId: b.modelId, outfitId: b.outfitId ?? '', engine, takes: 1, use: 'full' as const, steps: P.STEPS_DEFAULT,
      ...(engine === 'replicate' ? { quality } : {}),
      // Recreate puts the reference's sound under the whole edit, so the swap's own sound isn't kept.
      keepAudio: false, background: b.keepBackground ? 'keep' as const : 'photo' as const, direction: swapDirection(slot, b.keepBackground),
      speaking: !!recipe.source.hasAudio, clipSeconds: seconds,
      draft: { v: 1, tool: 'swap', quality, aspect: recipe.source.aspect, duration: seconds, takes: 1, recreate: { slotId: slot.id, method: 'swap' } },
    };
    const estimate = { method: 'swap' as const, label: P.engineLabel(rr), seconds, takes: 1, estimate: cost, priceLine: `about ${P.money(cost)} · ${seconds.toFixed(1)} s`,
      buttonLabel: `Swap in · ${seconds.toFixed(1)} s · ${P.money(cost)}`, ok: true, warnings: b.quality === 'cinema' && engine === 'replicate' ? ['Swap tops out at HD'] : [] };
    return { engine, segment: seg, request, estimate, rr };
  }
  private async checkModel(u: AuthUser, modelId: string) {
    const [m] = await this.ctx.db.select({ id: models.id, archivedAt: models.archivedAt }).from(models).where(and(eq(models.id, modelId), eq(models.studioId, u.studioId)));
    if (!m) throw notFound('Model');
    if (m.archivedAt) throw new ApiError(409, 'model_archived', 'This model is archived · restore her in Settings → Archived models');
  }
  /** "swap" when the reference's segment can be swapped (the default), else "generate"; a swap asked for and blocked is refused. */
  private methodFor(r: Row, b: FillBody): { method: 'swap' | 'generate'; blocked: string | null } {
    const blocked = this.swapBlocked(r, b.keepBackground);
    if (b.method === 'generate') return { method: 'generate', blocked };
    if (blocked && b.method === 'swap') throw new ApiError(409, 'swap_unavailable', blocked);
    return { method: blocked ? 'generate' : 'swap', blocked };
  }

  /**
   * The price of filling a slot (nothing is held). By default the model is swapped into the reference's own segment of
   * that shot (method "swap", G2); "generate" makes a new Suite shot from the brief.
   */
  async estimateSlot(u: AuthUser, id: string, slotId: string, body: unknown) {
    const { r, recipe } = await this.ready(u, id);
    const { slot, b, request } = this.fillRequest(recipe, r, slotId, body);
    const { method, blocked } = this.methodFor(r, b);
    if (method === 'swap') {
      await this.checkModel(u, b.modelId);
      const plan = this.swapPlan(recipe, r, slot, b, this.swapEngines(b.keepBackground)[0]!);
      return { slotId, method, keepBackground: b.keepBackground, segment: plan.segment, baked: [...BAKED_ELEMENTS], request: plan.request, estimate: plan.estimate };
    }
    // promptFrom: "brief", or "summary"/"default" while the slot has no brief yet (the apps suggest writing one).
    return { slotId, method, ...(blocked ? { swapUnavailable: blocked } : {}), request, promptFrom: promptSource(recipe, slot), estimate: await this.ctx.suite.estimate(u, request) };
  }
  /**
   * Fills a slot (the caller confirmed the price): a swap job on the reference's segment (Edit, else the hosted swap),
   * or a new Suite shot. Either is an ordinary job, held and priced like any other.
   */
  async fillSlot(u: AuthUser, id: string, slotId: string, body: unknown) {
    const { r, recipe } = await this.ready(u, id);
    const { slot, b, request } = this.fillRequest(recipe, r, slotId, body);
    const { method } = this.methodFor(r, b);
    if (method === 'swap') return this.fillBySwap(u, r, recipe, slot, b);
    const job = await this.ctx.suite.create(u, request) as { id: string; cost?: number };
    const fresh = await this.row(u, id);
    await this.saveFill(fresh, { ...(fresh.fill ?? {}), jobs: { ...(fresh.fill?.jobs ?? {}), [slotId]: { jobId: job.id, estimate: job.cost, at: Date.now(), method: 'generate' } } });
    return { slotId, method, job };
  }
  private async fillBySwap(u: AuthUser, r: Row, recipe: Recipe, slot: Recipe['slots'][number], b: FillBody) {
    await this.checkModel(u, b.modelId);
    let last: unknown = null;
    for (const engine of this.swapEngines(b.keepBackground)) {
      const plan = this.swapPlan(recipe, r, slot, b, engine);
      const clip = await this.segmentClip(u, r, recipe, slot.id, plan.segment);
      try {
        const job = await this.ctx.jobs.create(u, { ...plan.request, clipId: clip.id }) as { id: string; cost?: number };
        const fresh = await this.row(u, r.id);
        await this.saveFill(fresh, { ...(fresh.fill ?? {}), jobs: { ...(fresh.fill?.jobs ?? {}), [slot.id]: {
          jobId: job.id, estimate: job.cost, at: Date.now(), method: 'swap', segment: plan.segment, clipId: clip.id, clipKey: clip.key } } });
        return { slotId: slot.id, method: 'swap' as const, segment: plan.segment, job };
      } catch (e) {
        await this.dropClip(clip.id, clip.key);
        // Edit not available right now: try the hosted swap. Anything else (a cap, the wallet) stops here.
        if (e instanceof ApiError && e.code === 'engine_unavailable') { last = e; continue; }
        throw e;
      }
    }
    throw last ?? new ApiError(409, 'swap_unavailable', 'Swapping isn’t available right now · generate this shot instead');
  }
  /** The reference's segment as a private clip (rx/…, deleted with the reference): video only, cut frame-exact. */
  private async segmentClip(u: AuthUser, r: Row, recipe: Recipe, slotId: string, seg: { startSec: number; endSec: number }) {
    if (!r.storageKey) throw new ApiError(409, 'swap_unavailable', 'The reference’s video is gone (deleted after 30 days) · generate this shot instead');
    const c = this.ctx.config, id = uid('clip'), key = `rx/${r.studioId}/${r.id}/swap-${slotId}-${id}.mp4`;
    const out = path.join(os.tmpdir(), `${id}.mp4`), len = seg.endSec - seg.startSec;
    try {
      await this.withLocal(r.storageKey, f => run(c.FFMPEG_PATH, ['-y', '-v', 'error', '-ss', String(seg.startSec), '-i', f, '-t', String(len), '-an',
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '16', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { timeout: 120_000 }));
      await this.ctx.storage.put(key, fs.readFileSync(out), 'video/mp4');
    } finally { fs.rmSync(out, { force: true }); }
    const s = recipe.source;
    await this.ctx.db.insert(clipsTable).values({ id, studioId: u.studioId, name: `${r.name || 'Reference'} · ${slotId}`, durationSec: Math.round(len * 1000) / 1000,
      width: s.width || 1080, height: s.height || 1920, fps: s.fps || 30, meta: { recreate: r.id, slotId, people: 1 }, checks: [], storageKey: key, createdBy: u.id, createdAt: Date.now() });
    return { id, key };
  }
  private async dropClip(id: string, key: string) {
    await this.ctx.storage.delete(key).catch(() => undefined);
    await this.ctx.db.delete(clipsTable).where(eq(clipsTable.id, id)).catch(() => undefined);
  }

  /**
   * Builds the edit from the recipe and a take (or a finished fill job) per slot, and puts it in an edit session as one
   * undoable change (Claude's, or the owner's from the app). Slots without a take are left out.
   */
  async apply(u: AuthUser, id: string, body: unknown, o: { by: 'claude' | 'app'; device?: string } = { by: 'app' }) {
    const b = parse(z.object({
      sessionId: z.string().min(1), baseRevision: z.number().int().min(0).optional(),
      slots: z.record(z.string(), z.string().min(1).max(80)),
      options: z.object({ camera: z.boolean().optional(), speed: z.boolean().optional(), text: z.boolean().optional(), look: z.boolean().optional(), transitions: z.boolean().optional(),
        peaks: z.boolean().optional() }).strict().optional(),
      /** A proven recipe of the studio's to start from (its look fills in when the reference's can't be mapped); false = none; omitted = the nearest that fits. */
      startFrom: z.union([z.string().min(1).max(80), z.literal(false)]).optional(),
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
    // G2: slots whose take is this reference's own swap for that slot carry its camera, speed and look already.
    const baked = bakedSlots(r.fill ?? {}, Object.fromEntries(Object.entries(takes).map(([k, t]) => [k, t && byId.get(t.id)?.jobId])));
    // The takes' action peaks (free, server CPU; cached per take), to line them up with the reference's.
    if (b.options?.peaks !== false) {
      for (const info of Object.values(takes)) {
        const row = info && byId.get(info.id);
        if (info && row?.mediaKey) info.peaks = await this.takePeaks(row.id, row.mediaKey).catch(() => []);
      }
    }
    // The playbook (workstream 3's learning editor): the owner's pinned rules shape the plan. Claude can't override them;
    // the owner's own explicit options in the app can.
    const pb = await pinnedDirectives(this.ctx, u);
    const fromRules: AssembleOptions = { ...pb.directives };
    const opts: AssembleOptions = o.by === 'claude' ? { ...(b.options ?? {}), ...fromRules } : { ...fromRules, ...(b.options ?? {}) };
    const start = b.startFrom === false ? null : await this.startFrom(u, r.id, b.startFrom);
    const ownLookUsable = !!recipe.grade.look && recipe.grade.look.distance < 0.4;
    if (start?.look && !ownLookUsable && opts.look !== false) opts.fallbackLook = start.look;
    if (Object.keys(baked).length) opts.baked = baked;
    const out = buildProject(recipe, s.takeId, takes, opts);
    if (!out.project.tracks[0]!.items.length) throw badRequest('slots: give at least one slot a take');
    const label = `Recreated “${r.name}”`;
    // Which recipe element each item came from: on the op, so the owner's later corrections carry it (workstream 3).
    const sources = sourcesOf(recipe, out.project, r.id, takes);
    const res = o.by === 'claude'
      ? await svc.applyClaude(u, s.id, { baseRevision: b.baseRevision ?? s.revision, ops: [{ op: 'patch', patch: [
          { op: 'replace', path: '/canvas', value: out.project.canvas }, { op: 'replace', path: '/assets', value: out.project.assets },
          { op: 'replace', path: '/tracks', value: out.project.tracks }] }], label, meta: { sources } })
      : await svc.reset(u, s.id, { baseRevision: b.baseRevision ?? s.revision, project: out.project, device: o.device, label }, { meta: { sources } });
    const fresh = await this.row(u, id);
    const match = matchScore(recipe, out.project, takes, fresh.fill ?? {}, opts);
    const gapsReported = await this.reportGaps(u, r, recipe, fresh.fill?.gapsReported ?? []);
    const bakedView = Object.fromEntries(Object.keys(baked).map(k => [k, [...BAKED_ELEMENTS]]));
    await this.saveFill(fresh, { ...(fresh.fill ?? {}), applied: { sessionId: s.id, revision: res.revision, at: Date.now(), slots: Object.fromEntries(Object.entries(takes).filter(([, t]) => t).map(([k, t]) => [k, t!.id])), sources, match,
      ...(Object.keys(bakedView).length ? { baked: bakedView } : {}) }, gapsReported });
    const borrowed = opts.fallbackLook && start ? ['look'] : [];
    return { sessionId: s.id, revision: res.revision, durationSec: out.durationSec, missing: [...out.missing.filter(x => !waiting.includes(x)), ...waiting], waiting, notes: out.notes, label, match, sources, baked: bakedView,
      playbook: { followed: pb.followed, followYourself: pb.toFollow },
      startedFrom: start ? { recipeId: start.recipeId, name: start.name, distance: start.distance, borrowed } : null };
  }

  private peakCache = new Map<string, { t: number; strength: number }[]>();
  /** A take's action peaks (the find_action_peaks detector), cached by take and media. */
  private async takePeaks(takeId: string, key: string) {
    const k = `${takeId}:${key}`, hit = this.peakCache.get(k);
    if (hit) return hit;
    const c = this.ctx.config;
    const peaks = await this.withLocal(key, async f => findPeaks(await measureMotion(c.FFMPEG_PATH, c.FFPROBE_PATH, f, { maxSec: 120 })));
    const out = peaks.map(p => ({ t: Math.round(p.t * 1000) / 1000, strength: p.strength }));
    this.peakCache.set(k, out);
    if (this.peakCache.size > 500) this.peakCache.delete(this.peakCache.keys().next().value!);
    return out;
  }

  /**
   * "Fix this shot" (plan §4): one slot's clip in the built edit gets another take (or a finished fill job), in place,
   * as one undoable change. Its place and length on the timeline, transition, ramp, camera keys and look stay; the new
   * take starts where its action peak lines up. Later hand edits elsewhere are kept.
   */
  async replaceSlot(u: AuthUser, id: string, slotId: string, body: unknown, o: { by: 'claude' | 'app'; device?: string } = { by: 'app' }) {
    const b = parse(z.object({ sessionId: z.string().min(1), take: z.string().min(1).max(80), baseRevision: z.number().int().min(0).optional() }).strict(), body);
    const { r, recipe } = await this.ready(u, id);
    const slot = recipe.slots.find(x => x.id === slotId);
    if (!slot) throw notFound('Slot');
    const svc = editSessionsOf(this.ctx);
    const s = await svc.row(u, b.sessionId);
    const applied = r.fill?.applied;
    if (!applied || applied.sessionId !== s.id) throw new ApiError(409, 'not_built_here', 'Build the edit from this reference in this session first');
    const itemId = Object.entries(applied.sources ?? {}).find(([, src]) => src.slotId === slotId)?.[0];
    const p = structuredClone(s.project) as unknown as EditProject;
    const ti = p.tracks.findIndex(t => t.kind === 'main'), ii = ti < 0 ? -1 : p.tracks[ti]!.items.findIndex(x => (x as { id: string }).id === itemId);
    if (!itemId || ii < 0) throw new ApiError(409, 'slot_not_in_edit', `Shot ${slotId} isn’t in the edit any more · rebuild the edit to put it back`);
    // The take: a take id, or a finished job's first take.
    let t = (await this.ctx.db.select().from(takesTable).where(and(eq(takesTable.id, b.take), eq(takesTable.studioId, u.studioId), eq(takesTable.kind, 'take'))))[0];
    if (!t) {
      const [job] = await this.ctx.db.select({ id: jobs.id, state: jobs.state }).from(jobs).where(and(eq(jobs.id, b.take), eq(jobs.studioId, u.studioId)));
      if (job && job.state !== 'done') throw new ApiError(409, 'job_not_done', 'That shot is still being made · try again when it’s done');
      if (job) t = (await this.ctx.db.select().from(takesTable).where(and(eq(takesTable.jobId, job.id), eq(takesTable.studioId, u.studioId)))).sort((x, y) => x.index - y.index)[0];
    }
    if (!t) throw badRequest(`take: no video take or job ${b.take}`);
    if (!t.mediaKey) throw badRequest('take: it has no video yet');
    const info: TakeInfo = { id: t.id, durationSec: Number(t.media?.durationSec) || 1, width: Number(t.media?.width) || 1080, height: Number(t.media?.height) || 1920, hasAudio: true,
      peaks: await this.takePeaks(t.id, t.mediaKey).catch(() => []) };
    const old = p.tracks[ti]!.items[ii] as import('../editor/model.js').VideoClip;
    let asset = p.assets.find(a => a.take === t!.id);
    if (!asset) { asset = { id: `a${p.assets.length + 1}`, kind: 'video', take: t.id, durationSec: info.durationSec, width: info.width, height: info.height, hasAudio: true }; p.assets.push(asset); }
    const len = clipLength(old);
    const off = old.transitionIn ? old.transitionIn.durationSec / 2 : 0;
    const swap = bakedSlots(r.fill ?? {}, { [slotId]: t.jobId })[slotId];
    const wasBaked = !!applied.baked?.[slotId];
    let next: import('../editor/model.js').VideoClip, inSec: number, range: { outSec: number; speed: number; curve?: import('../editor/model.js').SpeedCurve };
    if (swap) {
      // G2: the reference's own shot with the model in it: from the matching moment at 1×, nothing applied again.
      inSec = Math.round(Math.max(0, Math.min(slot.startSec - off - swap.startSec, info.durationSec - 0.05)) * 10000) / 10000;
      range = rangeFor(inSec, len, info.durationSec);
      next = { ...old, asset: asset.id, inSec, outSec: range.outSec, speed: range.speed };
      delete next.speedCurve; delete next.keyframes; delete next.look;
    } else if (wasBaked) {
      // A swapped shot replaced by an ordinary take: the reference's camera, speed and look come back, as a build would.
      const used = Object.fromEntries(Object.keys(applied.slots).map(k => [k, info]));
      const built = buildProject(recipe, s.takeId, used, { peaks: true })
        .project.tracks[0]!.items[recipe.slots.filter(x => applied.slots[x.id]).findIndex(x => x.id === slotId)] as import('../editor/model.js').VideoClip | undefined;
      inSec = built?.inSec ?? 0;
      range = { outSec: (built?.outSec ?? len) - inSec, speed: built?.speed ?? 1, ...(built?.speedCurve ? { curve: built.speedCurve } : {}) };
      next = { ...old, asset: asset.id, inSec, outSec: built?.outSec ?? len, speed: range.speed };
      for (const k of ['speedCurve', 'keyframes', 'look'] as const) { if (built?.[k]) (next as Record<string, unknown>)[k] = built[k]; else delete next[k]; }
    } else {
      // The same length on the timeline, from the new take (slower if it is too short), starting at its action peak.
      range = rangeFor(0, len, info.durationSec, old.speedCurve);
      inSec = peakInPoint(slot, info, range, off);
      next = { ...old, asset: asset.id, inSec, outSec: Math.round((inSec + range.outSec) * 10000) / 10000, speed: range.speed };
      if (range.curve) next.speedCurve = range.curve; else delete next.speedCurve;
    }
    delete next.audioAsset; delete next.alphaMatte; delete next.chroma;
    p.tracks[ti]!.items[ii] = next;
    const label = `Replaced shot ${slotId} in “${r.name}”`, sources = { [old.id]: { recipeId: r.id, slotId } };
    const res = o.by === 'claude'
      ? await svc.applyClaude(u, s.id, { baseRevision: b.baseRevision ?? s.revision, ops: [{ op: 'patch', patch: [{ op: 'replace', path: '/assets', value: p.assets }, { op: 'replace', path: `/tracks/${ti}/items/${ii}`, value: next }] }], label, meta: { sources } })
      : await svc.reset(u, s.id, { baseRevision: b.baseRevision ?? s.revision, project: p, device: o.device, label }, { meta: { sources } });
    const fresh = await this.row(u, id);
    if (fresh.fill?.applied) {
      const { [slotId]: _gone, ...rest } = fresh.fill.applied.baked ?? {};
      const bakedNow = swap ? { ...rest, [slotId]: [...BAKED_ELEMENTS] } : rest;
      await this.saveFill(fresh, { ...fresh.fill, applied: { ...fresh.fill.applied, revision: res.revision, slots: { ...fresh.fill.applied.slots, [slotId]: t.id }, baked: bakedNow } });
    }
    return { sessionId: s.id, revision: res.revision, slotId, itemId: old.id, takeId: t.id, inSec, label, ...(swap ? { baked: [...BAKED_ELEMENTS] } : {}),
      ...(range.speed < 1 ? { note: `The take is shorter than the shot, so it plays at ${Math.round(range.speed * 100)}%` } : {}) };
  }

  /** The proven recipe to start from: the one asked for (it must be in the library), else the nearest that fits. */
  private async startFrom(u: AuthUser, referenceId: string, id?: string) {
    if (!id) return provenStart(this.ctx, u, referenceId);
    const e = await learningOf(this.ctx).recipe(u, id) as { id: string; name: string; recipe?: Recipe };
    const look = e.recipe?.grade?.look;
    return { recipeId: e.id, name: e.name, distance: 0, look: look?.id ? { id: look.id, label: look.label } : null };
  }

  /**
   * What the editor can't rebuild from this recipe goes to the learning editor's gaps (once per reference): freezes
   * without a known place, and flashes and glitches inside a shot. Unknown transitions and unread text are already counted from the recipe's gaps.
   */
  private async reportGaps(u: AuthUser, r: Row, recipe: Recipe, done: string[]) {
    if (u.role !== 'owner') return done;
    const found: { key: string; kind: string; what: string; note: string }[] = [];
    // Freezes are rebuilt as a 0.1× hold (G5); only those without a known place are a gap.
    const freeze = recipe.slots.filter(sl => sl.speed.ramp === 'freeze' && !sl.speed.freeze);
    if (freeze.length) found.push({ key: 'speed:freeze-frame', kind: 'effect', what: 'Freeze frame', note: `“${r.name}”: ${freeze.map(x => x.id).join(', ')}` });
    const flashes = recipe.transitions.filter(t => t.from === t.to && t.kind === 'flash');
    if (flashes.length) found.push({ key: 'effect:flash-in-shot', kind: 'effect', what: 'A white flash inside a shot', note: `“${r.name}” at ${flashes.map(t => `${t.atSec.toFixed(2)} s`).join(', ')}` });
    const glitches = recipe.transitions.filter(t => t.from === t.to && t.kind === 'glitch');
    if (glitches.length) found.push({ key: 'effect:glitch-in-shot', kind: 'effect', what: 'A glitch inside a shot', note: `“${r.name}” at ${glitches.map(t => `${t.atSec.toFixed(2)} s`).join(', ')}` });
    const out = [...done];
    for (const g of found.filter(x => !done.includes(x.key))) {
      try { await learningOf(this.ctx).addGap(u, g); out.push(g.key); } catch { /* the gap list is best effort */ }
    }
    return out;
  }

  // ------------------------------------------------------------------ export (plan step 7, Release 1)
  private exportKey = (r: Row, sessionId: string, revision: number, sound: ExportSound) => `rx/${r.studioId}/${r.id}/export-${sessionId}-r${revision}-${sound}.mp4`;
  private exportView(r: Row, sessionId: string, sound: ExportSound, st: RenderState | null, revision: number) {
    const recipe = r.recipe as Recipe;
    const q = `sessionId=${encodeURIComponent(sessionId)}&sound=${sound}&revision=${revision}`;
    return {
      referenceId: r.id, sessionId, revision, sound, state: st?.state ?? 'none',
      ...(st?.state === 'ready' ? { url: `${this.ctx.config.PUBLIC_URL ?? ''}/v1/recreate/references/${r.id}/export.mp4?${q}`, durationSec: st.durationSec, width: st.width, height: st.height, unsupported: st.unsupported ?? [] } : {}),
      ...(st?.error ? { error: st.error } : {}),
      useThisSound: useThisSound(r.sourceUrl, sound, recipe.source.durationSec),
    };
  }
  private exportBody(body: unknown) {
    const b = parse(z.object({ sessionId: z.string().min(1).max(80), sound: z.enum(['guide', 'silent']).optional(), revision: z.coerce.number().int().min(0).optional() }).strict(), body);
    return { ...b, sound: (b.sound ?? 'guide') as ExportSound };
  }
  /**
   * Renders the built edit (the session's current revision) for posting, as long as the reference: with the
   * reference's sound as a guide track, or silent. Either way the response says how to post with the original sound.
   */
  async exportEdit(u: AuthUser, id: string, body: unknown) {
    const b = this.exportBody(body);
    const { r, recipe } = await this.ready(u, id);
    const s = await editSessionsOf(this.ctx).row(u, b.sessionId);
    if (b.sound === 'guide' && (!r.storageKey || !recipe.source.hasAudio))
      throw new ApiError(409, 'no_reference_sound', r.storageKey ? 'The reference has no sound · export it silent' : 'The reference’s video is gone (deleted after 30 days) · export it silent and add the sound when you post');
    const key = this.exportKey(r, s.id, s.revision, b.sound);
    const have = await rendersOf(this.ctx).state(key);
    if (have && have.state !== 'failed') return this.exportView(r, s.id, b.sound, have, s.revision);
    const fresh = await this.row(u, id);
    await this.saveFill(fresh, { ...(fresh.fill ?? {}), exports: [...new Set([...(fresh.fill?.exports ?? []), key])].slice(-20) });
    const st = rendersOf(this.ctx).start(r.studioId, key, s.revision, s.project as unknown as EditProject, {
      quality: 'export', durationSec: recipe.source.durationSec, ...(b.sound === 'guide' ? { guideKey: r.storageKey! } : { audio: 'none' as const }),
    }, async done => {
      const now = await this.ctx.db.select().from(recreateReferences).where(eq(recreateReferences.id, r.id)).then(x => x[0]);
      if (now) void this.ctx.hub.emit(now.studioId, v => (v.userId === now.userId || v.role === 'owner' ? { type: 'recreate', export: this.exportView(now, s.id, b.sound, done, s.revision) } : null));
    });
    return this.exportView(r, s.id, b.sound, st, s.revision);
  }
  /** An export's state (no render started); `revision` defaults to the session's current one. */
  async exportState(u: AuthUser, id: string, query: unknown) {
    const b = this.exportBody(query);
    const r = await this.row(u, id);
    const s = await editSessionsOf(this.ctx).row(u, b.sessionId);
    const rev = b.revision ?? s.revision;
    return this.exportView(r, s.id, b.sound, await rendersOf(this.ctx).state(this.exportKey(r, s.id, rev, b.sound)), rev);
  }
  async exportFile(u: AuthUser, id: string, query: unknown) {
    const b = this.exportBody(query);
    const r = await this.row(u, id);
    const s = await editSessionsOf(this.ctx).row(u, b.sessionId);
    const f = await rendersOf(this.ctx).serve(this.exportKey(r, s.id, b.revision ?? s.revision, b.sound));
    if (!f) throw notFound('Export');
    return f;
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
    let [r] = await db.select().from(recreateReferences).where(eq(recreateReferences.id, id));
    if (!r || r.state !== 'analyzing') return;
    const set = async (v: Partial<Row>) => { const [n] = await db.update(recreateReferences).set(v).where(eq(recreateReferences.id, id)).returning(); if (n) this.emit(n); };
    if (!r.storageKey) {
      if (!r.sourceUrl) return;
      const got = await this.fetchLinkVideo(r, set);
      if (!got?.storageKey) return;
      r = got;
    }
    const storageKey = r.storageKey!;
    try {
      const out = await this.withLocal(storageKey, f => analyzeReference({ ffmpeg: c.FFMPEG_PATH, ffprobe: c.FFPROBE_PATH, ...(c.TESSERACT_PATH ? { tesseract: c.TESSERACT_PATH } : {}),
        ...(c.RECREATE_POSE ? { pose: { minFreeMb: c.RECREATE_POSE_MIN_FREE_MB } } : {}) }, f, {
        maxSec: MAX_REFERENCE_SEC + 1, progress: (p, phase) => set({ progress: Math.round(5 + p * 90), phase }),
      }));
      // The pose child's peak memory, for sizing the instance (plans/recreate-edit.md "Pose").
      if (out.recipe.analyzer.pose) this.ctx.log?.info({ referenceId: r.id, pose: out.recipe.analyzer.pose }, 'recreate pose');
      // Per-frame poses (keypoints only), private next to the reference and deleted with it; read when matching takes.
      if (out.poseTracks) await this.ctx.storage.put(this.posesKey(r), Buffer.from(JSON.stringify({ v: 1, slots: Object.fromEntries(out.recipe.slots.map((s, i) => [s.id, out.poseTracks![i] ?? null])) })), 'application/json');
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
    if (r.sourceUrl) await st.delete(`rx/${r.studioId}/${r.id}/info.json`).catch(() => undefined);
    for (const k of r.fill?.exports ?? []) await rendersOf(this.ctx).remove(k);
    // The swap segments (G2): the reference's pixels, so they go with it. The swapped takes are the studio's own.
    for (const j of Object.values(r.fill?.jobs ?? {})) if (j.clipId && j.clipKey) await this.dropClip(j.clipId, j.clipKey);
    if (r.contactSheetKey) await st.delete(r.contactSheetKey).catch(() => undefined);
    await st.delete(this.posesKey(r)).catch(() => undefined);
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
  // G2: a swapped slot's pixels are the reference's own (its ramp and grade included), so those count as matched.
  const baked = (id: string) => !!o.baked?.[id];
  const ramped = recipe.slots.filter(s => s.speed.ramp !== 'none' && (s.speed.ramp !== 'freeze' || s.speed.freeze));
  const ramps = !ramped.length ? 1 : ramped.filter(s => takes[s.id] && (baked(s.id) || o.speed !== false)).length / ramped.length;
  const look = recipe.grade.look;
  const grade0 = !look ? 0.5 : o.look === false || look.distance >= 0.4 ? 0 : Math.max(0, 1 - look.distance);
  const grade = used.length ? used.reduce((a, s) => a + (baked(s.id) ? 1 : grade0), 0) / used.length : grade0;
  const perSlot = recipe.slots.map(s => {
    const t = takes[s.id];
    if (!t) return { slotId: s.id, score: 0 };
    const m = fill.matched?.[s.id];
    const generated = !!fill.jobs?.[s.id];
    return { slotId: s.id, score: r2(baked(s.id) ? 0.95 : m && m.takeId === t.id ? m.score : generated ? 0.85 : 0.6) };
  });
  const shots = perSlot.reduce((a, x) => a + x.score, 0) / Math.max(1, perSlot.length);
  const overall = 0.25 * cuts + 0.35 * shots + 0.15 * text + 0.1 * ramps + 0.15 * grade;
  return { overall: r2(overall), cuts: r2(cuts), text: r2(text), ramps: r2(ramps), grade: r2(grade), shots: r2(shots), perSlot };
}

/**
 * G2: the slots whose take is this reference's own swap job for that slot, with where the segment starts in the
 * reference (`jobOf`: each slot's take's job).
 */
export function bakedSlots(fill: FillState, jobOf: Record<string, string | null | undefined>): Record<string, { startSec: number }> {
  const out: Record<string, { startSec: number }> = {};
  for (const [slotId, jobId] of Object.entries(jobOf)) {
    const j = fill.jobs?.[slotId];
    if (jobId && j?.method === 'swap' && j.jobId === jobId && j.segment) out[slotId] = { startSec: j.segment.startSec };
  }
  return out;
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

export type ExportSound = 'guide' | 'silent';
/**
 * How to post the export with the reference's original sound (the platform's "Use this sound"), so the post carries
 * the sound properly instead of a copy of it. Platform from the reference's link; general steps for a file.
 */
export function useThisSound(sourceUrl: string | null | undefined, sound: ExportSound, durationSec: number) {
  let platform: 'tiktok' | 'instagram' | 'youtube' | null = null;
  try { if (sourceUrl) platform = normalizeLink(sourceUrl).platform; } catch { /* a file reference */ }
  const steps = platform === 'tiktok' ? ['Open the reference on TikTok', 'Tap the sound at the bottom, then “Use this sound”', 'Add this video, with the sound starting at 0:00']
    : platform === 'instagram' ? ['Open the reference reel on Instagram', 'Tap the audio name, then “Use audio”', 'Add this video, with the audio starting at 0:00']
    : platform === 'youtube' ? ['Open the reference Short on YouTube', 'Tap “Remix”, then “Use sound”', 'Add this video, with the sound starting at 0:00']
    : ['Find the reference’s sound on the platform you post to', 'Use it as your post’s sound, starting at 0:00', 'Add this video'];
  return {
    platform, ...(sourceUrl ? { sourceUrl } : {}), startAtSec: 0, durationSec,
    title: 'Post with the original sound',
    steps,
    note: sound === 'guide'
      ? 'The sound in this export is the reference’s, as a guide for the timing. Post with the platform’s own sound (above) rather than this copy: reused audio can be muted or flagged.'
      : 'This export is silent and timed to the reference’s sound: add the sound when you post (above).',
  };
}
