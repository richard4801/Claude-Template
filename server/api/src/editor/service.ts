// Editor v2 AI helpers as jobs (plans/api.md "Editor v2"): auto-captions (word timestamps), silence/filler cuts,
// background removal (green-screen video the apps key out) and voice clean-up. Each job: estimate → hold → run on the
// provider → settle at the GPU time actually billed (or release on failure/cancel), with `editor` live events. Results are
// data the APP applies to its edit project; nothing here touches video frames (outputs are copied byte for byte).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { and, desc, eq, ne, sql } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { studioSettings, takes, uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { whoOf } from '../money/money.js';
import { putFile } from '../storage/objects.js';
import { ReplicateError } from '../replicate/client.js';
import { CUT_DEFAULTS, suggestCuts, type CutOptions, type Word } from './cuts.js';
import { makeProvider, rmQuiet, type EditorProvider, type Hooks, type TrackPoint } from './providers.js';
import { mediaToolsAvailable, probe } from '../replicate/media.js';
import { detectSilences, silenceCuts } from './silence.js';
import { decodeMono, detectBeats } from './audio.js';
import { editorJobs, type EditorJobKind, type EditorSource } from './schema.js';

type Row = typeof editorJobs.$inferSelect;
export const EDITOR_KINDS: EditorJobKind[] = ['captions', 'cuts', 'matte', 'denoise', 'beats'];
export const EDITOR_LIMITS = { maxSourceSec: 600, maxMatteSec: 120, maxRunning: 2, reuseDays: 30, minChargeUsd: 0.01 } as const;
/** GPU seconds a job is expected to take (start-up + per second of media), for the estimate. */
export const GPU_SEC = {
  transcribe: (d: number) => 8 + 0.15 * d,
  matte: (d: number) => 10 + 4 * d,
  track: (d: number) => 15 + 3 * d,
  separate: (d: number) => 5 + 0.3 * d,
};
const PHASE: Record<EditorJobKind, string> = { captions: 'Listening', cuts: 'Finding pauses', matte: 'Cutting out the background', denoise: 'Cleaning up the voice', beats: 'Finding the beat', briefs: 'Writing the briefs' };
const LANG_RE = /^[a-z]{2}$/;

/** Tap to keep (workstream 1): a point on the clip, 0–1 of the frame, at `t` seconds of the source; keep false = leave out. */
export type KeepPoint = { x: number; y: number; t: number; keep: boolean };
export const MAX_KEEP_POINTS = 10;
export type JobOptions = { language?: string | null; fromJobId?: string; analyzeOnly?: boolean; silenceOnly?: boolean; noiseDb?: number; points?: KeepPoint[] } & CutOptions;

function parseOptions(kind: EditorJobKind, o: any): JobOptions {
  o = o ?? {};
  if (typeof o !== 'object' || Array.isArray(o)) throw badRequest('options: must be an object');
  const out: JobOptions = {};
  if (o.language !== undefined && o.language !== null && o.language !== 'auto') {
    if (typeof o.language !== 'string' || !LANG_RE.test(o.language)) throw badRequest('options.language: a two-letter language code or "auto"');
    out.language = o.language;
  }
  if (o.fromJobId !== undefined) { if (typeof o.fromJobId !== 'string') throw badRequest('options.fromJobId: must be a job id'); out.fromJobId = o.fromJobId; }
  if (kind === 'cuts') {
    const n = (k: string, lo: number, hi: number) => { if (o[k] === undefined) return; if (typeof o[k] !== 'number' || o[k] < lo || o[k] > hi) throw badRequest(`options.${k}: from ${lo} to ${hi}`); (out as any)[k] = o[k]; };
    n('minSilenceSec', 0.25, 5); n('keepPadSec', 0, 0.5); n('noiseDb', -60, -10);
    for (const k of ['fillers', 'repeats', 'silenceOnly'] as const) if (o[k] !== undefined) { if (typeof o[k] !== 'boolean') throw badRequest(`options.${k}: true or false`); out[k] = o[k]; }
    if (o.extraFillers !== undefined) {
      if (!Array.isArray(o.extraFillers) || o.extraFillers.length > 50 || o.extraFillers.some((w: unknown) => typeof w !== 'string' || !w || (w as string).length > 30)) throw badRequest('options.extraFillers: up to 50 words');
      out.extraFillers = o.extraFillers;
    }
  }
  if (kind === 'matte' && o.points !== undefined) {
    // workstream 1: tap to keep. The subject under the points is tracked through the clip.
    if (!Array.isArray(o.points) || !o.points.length || o.points.length > MAX_KEEP_POINTS) throw badRequest(`options.points: 1 to ${MAX_KEEP_POINTS} points`);
    out.points = o.points.map((q: any, i: number) => {
      if (!q || typeof q !== 'object') throw badRequest(`options.points.${i}: {x, y, t?, keep?}`);
      const n = (k: string, lo: number, hi: number, d?: number) => { const v = q[k] ?? d; if (typeof v !== 'number' || !Number.isFinite(v) || v < lo || v > hi) throw badRequest(`options.points.${i}.${k}: from ${lo} to ${hi}`); return Math.round(v * 10000) / 10000; };
      if (q.keep !== undefined && typeof q.keep !== 'boolean') throw badRequest(`options.points.${i}.keep: true or false`);
      return { x: n('x', 0, 1), y: n('y', 0, 1), t: n('t', 0, EDITOR_LIMITS.maxMatteSec, 0), keep: q.keep !== false };
    });
    if (!out.points!.some(q => q.keep)) throw badRequest('options.points: tap at least one thing to keep');
  }
  if (kind === 'denoise' && o.analyzeOnly !== undefined) { if (typeof o.analyzeOnly !== 'boolean') throw badRequest('options.analyzeOnly: true or false'); out.analyzeOnly = o.analyzeOnly; }
  return out;
}

/** How noisy the speech sounds, from the transcript's word confidence (cheap; no audio work on the server). */
export function noiseSuggestion(words: Word[]): { level: 'none' | 'light' | 'strong'; reason: string; confidence: number | null } {
  const scored = words.filter(w => typeof w.score === 'number');
  if (scored.length < 5) return { level: 'none', reason: 'Not enough speech to judge', confidence: null };
  const avg = scored.reduce((s, w) => s + w.score!, 0) / scored.length;
  const conf = Math.round(avg * 1000) / 1000;
  if (avg < 0.6) return { level: 'strong', reason: 'The voice is hard to make out · cleaning it up should help a lot', confidence: conf };
  if (avg < 0.8) return { level: 'light', reason: 'Some background noise · a light clean-up will help', confidence: conf };
  return { level: 'none', reason: 'The voice is already clear', confidence: conf };
}

const services = new WeakMap<Ctx, EditorAiService>();
/** One service per app (routes, edit sessions and MCP tools share it). */
export const editorAi = (ctx: Ctx) => { let s = services.get(ctx); if (!s) { s = new EditorAiService(ctx); services.set(ctx, s); } return s; };

export class EditorAiService {
  readonly provider: EditorProvider;
  private stopping = new Set<string>();
  private running = 0;
  private waiting: (() => void)[] = [];
  constructor(private ctx: Ctx, provider?: EditorProvider) { this.provider = provider ?? makeProvider(ctx); }

  // ------------------------------------------------------------------ views and events
  view(r: Row, role: 'owner' | 'member') {
    return {
      id: r.id, kind: r.kind, state: r.state, progress: Math.round(r.progress), phase: r.phase, source: r.source, options: r.options,
      estimateUsd: r.estimate, costUsd: r.cost, ...(r.result ? { result: r.result } : {}), ...(r.error ? { error: r.error } : {}),
      createdAt: r.createdAt, ...(r.finishedAt ? { finishedAt: r.finishedAt } : {}),
      ...(role === 'owner' ? { models: r.models } : {}),
    };
  }
  private emit(r: Row) {
    void this.ctx.hub.emit(r.studioId, v => (v.userId === r.userId || v.role === 'owner' ? { type: 'editor', editorJob: this.view(r, v.role) } : null));
  }
  /** Called when a job finishes (done, failed or cancelled): edit sessions apply results Claude asked for. */
  readonly finished = new Set<(r: Row) => void | Promise<void>>();
  private async patch(id: string, set: Partial<Row>) {
    const [r] = await this.ctx.db.update(editorJobs).set(set).where(eq(editorJobs.id, id)).returning();
    if (r) {
      this.emit(r);
      if (r.state !== 'running') for (const f of this.finished) void Promise.resolve(f(r)).catch(e => this.ctx.log.warn({ err: (e as Error).message, job: r.id }, 'editor job listener failed'));
    }
    return r;
  }

  // ------------------------------------------------------------------ sources
  /** The stored media a job reads, checked against the studio. */
  async source(u: AuthUser, s: any): Promise<{ source: EditorSource; key: string; contentType: string; size?: { width: number; height: number; fps?: number } }> {
    if (!s || typeof s !== 'object') throw badRequest('source: {takeId} or {uploadId, durationSec}');
    if (typeof s.takeId === 'string') {
      const [t] = await this.ctx.db.select().from(takes).where(and(eq(takes.id, s.takeId), eq(takes.studioId, u.studioId)));
      if (!t) throw notFound('Take');
      if (!t.mediaKey || !(t.kind === 'take' || (t.kind as string) === 'edit')) throw badRequest('source.takeId: must be a video take');
      const d = Number((t.media as { durationSec?: number } | null)?.durationSec ?? s.durationSec);
      if (!(d > 0)) throw badRequest('source.durationSec: unknown video length');
      const md = (t.media ?? {}) as { width?: number; height?: number; fps?: number };
      return { source: { takeId: t.id, durationSec: d }, key: t.mediaKey, contentType: String((t.media as { contentType?: string } | null)?.contentType ?? 'video/mp4'),
        ...(md.width && md.height ? { size: { width: md.width, height: md.height, ...(md.fps ? { fps: md.fps } : {}) } } : {}) };
    }
    if (typeof s.uploadId === 'string') {
      const [up] = await this.ctx.db.select().from(uploads).where(and(eq(uploads.id, s.uploadId), eq(uploads.studioId, u.studioId)));
      if (!up) throw notFound('Upload');
      if (!/^(video|audio)\//.test(up.contentType)) throw badRequest('source.uploadId: must be a video or audio upload');
      if (typeof s.durationSec !== 'number' || !(s.durationSec > 0)) throw badRequest('source.durationSec: required for an upload');
      if (!(await this.ctx.storage.head(up.storageKey))) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it to the URL first');
      return { source: { uploadId: up.id, durationSec: s.durationSec }, key: up.storageKey, contentType: up.contentType };
    }
    throw badRequest('source: {takeId} or {uploadId, durationSec}');
  }

  /** A finished transcript of the same media (this job's `fromJobId`, or the newest done captions/cuts job on it). */
  private async transcriptFor(u: AuthUser, key: string, o: JobOptions): Promise<{ words: Word[]; language: string } | null> {
    const db = this.ctx.db;
    let rows: Row[];
    if (o.fromJobId) {
      rows = await db.select().from(editorJobs).where(and(eq(editorJobs.id, o.fromJobId), eq(editorJobs.studioId, u.studioId)));
      const r = rows[0];
      if (!r) throw notFound('Job');
      if (r.state !== 'done' || !Array.isArray((r.result as any)?.words)) throw badRequest('options.fromJobId: that job has no transcript');
      if (r.mediaKey !== key) throw badRequest('options.fromJobId: that transcript is of another video');
    } else {
      const since = Date.now() - EDITOR_LIMITS.reuseDays * 86_400_000;
      rows = await db.select().from(editorJobs).where(and(eq(editorJobs.studioId, u.studioId), eq(editorJobs.mediaKey, key), eq(editorJobs.state, 'done'),
        sql`${editorJobs.kind} in ('captions', 'cuts')`, sql`${editorJobs.createdAt} > ${since}`)).orderBy(desc(editorJobs.createdAt)).limit(5);
    }
    for (const r of rows) {
      const res = r.result as { words?: Word[]; language?: string } | null;
      if (!Array.isArray(res?.words)) continue;
      if (o.language && res!.language && res!.language !== o.language && !o.fromJobId) continue;
      return { words: res!.words!, language: res!.language ?? 'en' };
    }
    return null;
  }

  // ------------------------------------------------------------------ estimate
  async estimate(u: AuthUser, body: any) {
    const kind = body?.kind as EditorJobKind;
    if (!EDITOR_KINDS.includes(kind)) throw badRequest(`kind: one of ${EDITOR_KINDS.join(', ')}`);
    const opts = parseOptions(kind, body?.options);
    // WS13 · owner only: the model for this helper, checked against its candidates (engines/service.ts); today each has one.
    if (body?.engineModel !== undefined) {
      if (typeof body.engineModel !== 'string') throw badRequest('engineModel: a model id');
      const purpose = kind === 'captions' || kind === 'cuts' ? 'captions' : kind === 'matte' ? (opts.points ? 'track' : 'matte') : kind === 'denoise' ? 'denoise' : null;
      if (!purpose) throw badRequest(`engineModel: ${kind} runs no model`);
      await (await import('../engines/service.js')).modelChoice(this.ctx).check(u, purpose, body.engineModel);
    }
    const src = await this.source(u, body?.source);
    const d = src.source.durationSec;
    if (d > EDITOR_LIMITS.maxSourceSec) throw badRequest(`source: at most ${EDITOR_LIMITS.maxSourceSec / 60} minutes`);
    // 2026-11-08: background removal is "coming soon" while production runs the mock (nothing real to give yet).
    if (kind === 'matte' && !this.matteAvailable) throw badRequest('Background removal is coming soon');
    if (kind === 'matte' && d > EDITOR_LIMITS.maxMatteSec) throw badRequest(`source: background removal works on up to ${EDITOR_LIMITS.maxMatteSec} s`);
    const silenceOnly = (kind === 'cuts' && !!opts.silenceOnly) || kind === 'beats';
    if (silenceOnly && !(await mediaToolsAvailable(this.ctx.config.FFMPEG_PATH, this.ctx.config.FFPROBE_PATH))) throw badRequest(kind === 'beats' ? 'kind: beat detection is not available on this server' : 'options.silenceOnly: not available on this server');
    const reuse = silenceOnly ? null : (kind === 'cuts' || kind === 'captions' || (kind === 'denoise' && opts.analyzeOnly)) ? await this.transcriptFor(u, src.key, opts) : null;
    if (kind === 'denoise' && opts.analyzeOnly && !reuse) throw badRequest('options.analyzeOnly: make captions for this video first');
    const p = this.provider;
    let usd = 0;
    if (silenceOnly) usd = 0;
    else if (kind === 'captions' || kind === 'cuts') usd = reuse ? 0 : GPU_SEC.transcribe(d) * p.rates.transcribe;
    else if (kind === 'matte' && opts.points) {
      if (opts.points.some(q => q.t > d)) throw badRequest(`options.points: t must be within the clip (0–${d} s)`);
      usd = GPU_SEC.track(d) * p.rates.track;
    } else if (kind === 'matte') usd = GPU_SEC.matte(d) * p.rates.matte;
    else if (!opts.analyzeOnly) usd = GPU_SEC.separate(d) * p.rates.separate;
    // workstream 1: the price is the provider's cost x EDITOR_MARKUP (the owner's choice: x 2, like Upscale).
    usd = usd > 0 ? Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(usd * this.markup * 10000) / 10000) : 0;
    return { kind, opts, src, reuse, usd };
  }

  // ------------------------------------------------------------------ jobs
  async start(u: AuthUser, body: any) {
    const e = await this.estimate(u, body);
    if (e.usd > 0) await this.allowPaid(u.studioId, e.usd);
    const id = uid('edj');
    const models = e.usd === 0 ? [] : e.kind === 'matte' ? [e.opts.points ? this.provider.models.track : this.provider.models.matte] : e.kind === 'denoise' ? [this.provider.models.separate] : [this.provider.models.transcribe];
    const holdTokens = e.usd > 0 ? await this.ctx.money.hold(whoOf(u), id, e.usd, { perJob: false, note: `Editor ${e.kind} · hold` }) : 0;
    let row: Row;
    try {
      [row] = await this.ctx.db.insert(editorJobs).values({
        id, studioId: u.studioId, userId: u.id, kind: e.kind, state: 'running', source: e.src.source, mediaKey: e.src.key, options: e.opts as Record<string, unknown>,
        models, estimate: e.usd, holdTokens, progress: 0, phase: e.usd > 0 ? 'Waiting' : PHASE[e.kind], createdAt: Date.now(),
      }).returning() as Row[];
    } catch (err) {
      if (holdTokens) await this.ctx.money.release(u.studioId, u.id, id, holdTokens, 'editor job not started');
      throw err;
    }
    this.emit(row!);
    void this.run(row!, u, e.src, e.reuse);
    return this.view(row!, u.role);
  }

  private async slot() {
    if (this.running < EDITOR_LIMITS.maxRunning) { this.running++; return; }
    await new Promise<void>(r => this.waiting.push(r));
    this.running++;
  }
  private free() { this.running--; this.waiting.shift()?.(); }

  private async run(row: Row, u: AuthUser, src: { key: string; contentType: string; source: EditorSource; size?: { width: number; height: number; fps?: number } }, reuse: { words: Word[]; language: string } | null) {
    const id = row.id, d = src.source.durationSec, o = row.options as JobOptions, p = this.provider;
    const hooks: Hooks = {
      cancelled: () => this.stopping.has(id),
      onPrediction: async pid => { await this.ctx.db.update(editorJobs).set({ predictionId: pid }).where(eq(editorJobs.id, id)); },
      onProgress: async (f, phase) => { await this.patch(id, { progress: Math.min(95, 5 + f * 90), ...(phase ? { phase } : {}) }); },
    };
    const needsGpu = row.estimate > 0;
    if (needsGpu) await this.slot();
    let file: string | null = null;
    try {
      if (this.stopping.has(id)) throw new ReplicateError('Cancelled', 'cancelled');
      await this.patch(id, { phase: PHASE[row.kind], progress: 5 });
      const url = await this.ctx.storage.presignGet(src.key, this.ctx.config.REPLICATE_INPUT_URL_TTL_SEC);
      let result: Record<string, unknown>, gpuSec: number | null = null, rate = 0;
      const transcript = async () => {
        if (reuse) return reuse;
        const t = await p.transcribe(url, d, o.language ?? null, hooks);
        gpuSec = t.gpuSec; rate = p.rates.transcribe;
        return t;
      };
      if (row.kind === 'captions') {
        const t = await transcript();
        result = { language: t.language, words: t.words, durationSec: d, reused: !!reuse };
      } else if (row.kind === 'beats') {
        const samples = await this.withLocalInput(src.key, input => decodeMono(this.ctx.config.FFMPEG_PATH, input));
        await this.patch(id, { progress: 70 });
        result = { ...detectBeats(samples), durationSec: d };
      } else if (row.kind === 'cuts' && o.silenceOnly) {
        const minSilenceSec = o.minSilenceSec ?? CUT_DEFAULTS.minSilenceSec, keepPadSec = o.keepPadSec ?? CUT_DEFAULTS.keepPadSec;
        const sil = await this.withLocalInput(src.key, input => detectSilences(this.ctx.config.FFMPEG_PATH, input, d, { minSilenceSec, noiseDb: o.noiseDb }));
        await this.patch(id, { progress: 90 });
        result = { ...silenceCuts(sil, d, { minSilenceSec, keepPadSec }), words: [], options: { ...CUT_DEFAULTS, ...o }, durationSec: d };
      } else if (row.kind === 'cuts') {
        const t = await transcript();
        const s = suggestCuts(t.words, d, o);
        result = { ...s, words: t.words, language: t.language, options: { ...CUT_DEFAULTS, ...o }, durationSec: d };
      } else if (row.kind === 'matte' || (row.kind === 'denoise' && !o.analyzeOnly)) {
        const tracked = row.kind === 'matte' && !!o.points?.length;
        const out = row.kind !== 'matte' ? await p.separate(url, d, hooks)
          : tracked ? await p.track(url, d, await this.pixelPoints(src.key, o.points!, src.size, p.name === 'mock'), hooks) : await p.matte(url, d, hooks);
        file = out.file; gpuSec = out.gpuSec; rate = row.kind !== 'matte' ? p.rates.separate : tracked ? p.rates.track : p.rates.matte;
        const asset = await this.store(u, src, out.file, out.contentType, row.kind === 'matte' ? 'video' : 'audio', d);
        // workstream 1: an alpha matte (white = keep) the apps apply to the original clip; no green composite, no chroma key.
        result = row.kind === 'matte'
          ? { asset, alpha: true, mode: tracked ? 'tracked' : 'person', ...(tracked ? { points: o.points } : {}) }
          : { asset, suggestion: noiseSuggestion((await this.transcriptFor(u, src.key, {}).catch(() => null))?.words ?? []) };
      } else {
        result = { suggestion: noiseSuggestion(reuse?.words ?? []) };
      }
      if (this.stopping.has(id)) throw new ReplicateError('Cancelled', 'cancelled');
      const actual = !needsGpu ? 0 : gpuSec != null ? Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(gpuSec * rate * this.markup * 10000) / 10000) : row.estimate;
      if (row.holdTokens || actual > 0) await this.ctx.money.settle(u.studioId, u.id, id, row.holdTokens, actual, `Editor ${row.kind}`);
      await this.patch(id, { state: 'done', progress: 100, phase: 'Done', result, cost: actual, finishedAt: Date.now() });
    } catch (e) {
      const cancelled = e instanceof ReplicateError && e.kind === 'cancelled';
      if (row.holdTokens) await this.ctx.money.release(u.studioId, u.id, id, row.holdTokens, cancelled ? 'editor job cancelled' : 'editor job failed').catch(() => {});
      if (!cancelled) this.ctx.log.warn({ err: (e as Error).message, job: id, kind: row.kind }, 'editor job failed');
      const msg = cancelled ? 'Cancelled' : e instanceof ReplicateError && e.kind === 'refused' ? 'This video was refused by the safety check'
        : e instanceof ReplicateError && e.kind === 'out_of_credit' ? 'The studio is out of AI credit · ask the owner' : 'Something went wrong · try again';
      await this.patch(id, { state: cancelled ? 'cancelled' : 'failed', phase: msg, error: msg, finishedAt: Date.now() }).catch(() => {});
    } finally {
      rmQuiet(file);
      this.stopping.delete(id);
      if (needsGpu) this.free();
    }
  }

  /** The media as something ffmpeg can read: a presigned URL on R2, else a temporary copy of the local object. */
  /** The stored media as a local path (or a short-lived URL on S3) for ffmpeg; temporary copies are removed after. */
  /** Tap points (0–1, seconds) → pixels and frame numbers of the source (workstream 1). The mock may guess the size. */
  private async pixelPoints(key: string, points: KeepPoint[], known: { width: number; height: number; fps?: number } | undefined, mock: boolean): Promise<TrackPoint[]> {
    const info = known ?? await this.withLocalInput(key, f => probe(this.ctx.config.FFPROBE_PATH, f)).catch(() => null);
    const w = info?.width || (mock ? 1080 : 0), h = info?.height || (mock ? 1920 : 0), fps = info?.fps || 30;
    if (!w || !h) throw new ReplicateError('Couldn’t read the video', 'failed');
    return points.map(q => ({ x: q.x * (w - 1), y: q.y * (h - 1), frame: Math.round(q.t * fps), keep: q.keep }));
  }

  async withLocalInput<T>(key: string, fn: (input: string) => Promise<T>): Promise<T> {
    if (this.ctx.storage.kind === 's3') return fn(await this.ctx.storage.presignGet(key, 900));
    const obj = await this.ctx.storage.get(key);
    if (!obj) throw new Error('media missing');
    const file = path.join(os.tmpdir(), `${uid('edin')}${path.extname(key)}`);
    try {
      await pipeline(obj.body as NodeJS.ReadableStream, fs.createWriteStream(file));
      return await fn(file);
    } finally { rmQuiet(file); }
  }

  /** Stores a produced file as an upload of the studio (bytes copied, never re-encoded); the mock points at the source. */
  private async store(u: AuthUser, src: { key: string; source: EditorSource }, file: string | null, contentType: string, kind: 'video' | 'audio', durationSec: number) {
    if (!file) return { kind, ...(src.source.takeId ? { take: src.source.takeId } : { upload: src.source.uploadId }), url: `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${src.key}`, durationSec };
    const ext = contentType === 'video/mp4' ? 'mp4' : contentType === 'audio/wav' ? 'wav' : contentType === 'audio/flac' ? 'flac' : contentType === 'audio/mp4' ? 'm4a' : 'mp3';
    const key = `g/${uid('edit')}.${ext}`;
    await putFile(this.ctx, { key, file, studioId: u.studioId, kind: 'generated', userId: u.id, contentType });
    const [up] = await this.ctx.db.select({ id: uploads.id }).from(uploads).where(eq(uploads.storageKey, key));
    return { kind, upload: up!.id, url: `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${key}`, durationSec };
  }

  async get(u: AuthUser, id: string) {
    const [r] = await this.ctx.db.select().from(editorJobs).where(and(eq(editorJobs.id, id), eq(editorJobs.studioId, u.studioId)));
    if (!r || (r.userId !== u.id && u.role !== 'owner')) throw notFound('Job');
    return r;
  }
  async list(u: AuthUser, q: { kind?: string; takeId?: string; uploadId?: string; limit?: string }) {
    const conds = [eq(editorJobs.studioId, u.studioId), eq(editorJobs.userId, u.id)];
    // Recreate's shot briefs (G8) count in the day's spend but aren't editor jobs the apps show.
    conds.push(q.kind ? eq(editorJobs.kind, q.kind as EditorJobKind) : ne(editorJobs.kind, 'briefs'));
    if (q.takeId) conds.push(sql`${editorJobs.source}->>'takeId' = ${q.takeId}`);
    if (q.uploadId) conds.push(sql`${editorJobs.source}->>'uploadId' = ${q.uploadId}`);
    const lim = Math.min(100, Math.max(1, Number(q.limit) || 50));
    return (await this.ctx.db.select().from(editorJobs).where(and(...conds)).orderBy(desc(editorJobs.createdAt)).limit(lim)).map(r => this.view(r, u.role));
  }
  /** Running: cancel (the hold goes back). Finished: forget it. */
  async remove(u: AuthUser, id: string) {
    const r = await this.get(u, id);
    if (r.state === 'running') {
      this.stopping.add(id);
      if (r.predictionId && this.provider.name === 'replicate') await this.ctx.replicate.cancel(r.predictionId);
      return { ok: true, state: 'cancelling' };
    }
    await this.ctx.db.delete(editorJobs).where(eq(editorJobs.id, id));
    void this.ctx.hub.emit(r.studioId, v => (v.userId === r.userId || v.role === 'owner' ? { type: 'editor', op: 'delete', id } : null));
    return { ok: true, state: 'deleted' };
  }

  /** After a restart nothing is running any more: fail those jobs and give their holds back. */
  async recover() {
    const rows = await this.ctx.db.select().from(editorJobs).where(eq(editorJobs.state, 'running'));
    for (const r of rows) {
      if (r.holdTokens) await this.ctx.money.release(r.studioId, r.userId, r.id, r.holdTokens, 'editor job interrupted by a restart').catch(() => {});
      if (r.predictionId && this.provider.name === 'replicate') await this.ctx.replicate.cancel(r.predictionId);
      await this.ctx.db.update(editorJobs).set({ state: 'failed', error: 'Interrupted · try again', phase: 'Interrupted · try again', finishedAt: Date.now() }).where(eq(editorJobs.id, r.id));
    }
    return rows.length;
  }

  /** False while production runs the mock provider: the apps show Remove background as "Coming soon". Dev and tests keep it. */
  get matteAvailable() {
    return this.provider.name !== 'mock' || this.ctx.config.NODE_ENV !== 'production' || !!this.ctx.config.DEV_MODE;
  }

  // ------------------------------------------------------------------ the owner's controls (workstream 1)
  get markup() { return this.ctx.config.EDITOR_MARKUP > 0 ? this.ctx.config.EDITOR_MARKUP : 1; }
  private async controls(studioId: string) {
    const [s] = await this.ctx.db.select({ off: studioSettings.editorPaidOff, cap: studioSettings.editorCapPerDay }).from(studioSettings).where(eq(studioSettings.studioId, studioId));
    return { off: !!s?.off, capPerDayUsd: s?.cap ?? this.ctx.config.EDITOR_CAP_PER_DAY_USD };
  }
  /** What paid helpers have charged (done) or hold (running) for the studio since midnight UTC. */
  async todayUsd(studioId: string, now = Date.now()) {
    const since = now - (now % 86_400_000);
    const rows = await this.ctx.db.select({ state: editorJobs.state, estimate: editorJobs.estimate, cost: editorJobs.cost }).from(editorJobs)
      .where(and(eq(editorJobs.studioId, studioId), sql`${editorJobs.createdAt} >= ${since}`));
    return Math.round(rows.reduce((a, r) => a + (r.state === 'done' ? Number(r.cost ?? 0) : r.state === 'running' ? Number(r.estimate ?? 0) : 0), 0) * 10000) / 10000;
  }
  /** A paid helper may start: the owner's switch is on and the day's cap has room (also Recreate's shot briefs). */
  async allowPaid(studioId: string, usd: number) {
    const c = await this.controls(studioId);
    if (c.off) throw new ApiError(503, 'editor_paid_off', 'AI editing helpers are switched off for now · the owner can switch them back on');
    const today = await this.todayUsd(studioId);
    if (today + usd > c.capPerDayUsd + 1e-9)
      throw new ApiError(402, 'editor_daily_cap', `Today’s AI editing limit ($${c.capPerDayUsd.toFixed(2)}) is reached · try tomorrow, or the owner can raise it`);
  }
  /** The owner's view: the switch, the cap, today's spend, and the markup. */
  async settings(u: AuthUser) {
    if (u.role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can see this');
    const c = await this.controls(u.studioId);
    return { paidHelpers: c.off ? 'off' as const : 'on' as const, capPerDayUsd: c.capPerDayUsd, todayUsd: await this.todayUsd(u.studioId), markup: this.markup, provider: this.provider.name };
  }
  async patchSettings(u: AuthUser, body: any) {
    if (u.role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can change this');
    const b = body ?? {};
    const keys = Object.keys(b).filter(k => !['paidHelpers', 'capPerDayUsd'].includes(k));
    if (keys.length) throw badRequest(`${keys[0]}: not a setting`);
    const set: Partial<typeof studioSettings.$inferInsert> = {};
    if (b.paidHelpers !== undefined) { if (b.paidHelpers !== 'on' && b.paidHelpers !== 'off') throw badRequest('paidHelpers: "on" or "off"'); set.editorPaidOff = b.paidHelpers === 'off'; }
    if (b.capPerDayUsd !== undefined) {
      if (b.capPerDayUsd !== null && (typeof b.capPerDayUsd !== 'number' || !(b.capPerDayUsd >= 0) || b.capPerDayUsd > 1000)) throw badRequest('capPerDayUsd: from 0 to 1000, or null for the default');
      set.editorCapPerDay = b.capPerDayUsd;
    }
    if (Object.keys(set).length)
      await this.ctx.db.insert(studioSettings).values({ studioId: u.studioId, ...set }).onConflictDoUpdate({ target: studioSettings.studioId, set });
    return this.settings(u);
  }

  async features(u?: AuthUser) {
    const c = u ? await this.controls(u.studioId) : { off: false };
    const paid = !c.off;
    return {
      // Paid helpers are hidden while the owner has them switched off (silence cuts, beats and the voice check stay free).
      paid: { available: paid, ...(paid ? {} : { reason: 'AI editing helpers are switched off for now' }) },
      captions: { available: paid, languages: ['auto', 'en', 'es', 'fr', 'de', 'it', 'pt', 'nl', 'ja', 'ko', 'zh'] },
      cuts: { available: true, defaults: { ...CUT_DEFAULTS } },
      matte: { available: paid && this.matteAvailable, maxSec: EDITOR_LIMITS.maxMatteSec },
      denoise: { available: paid },
      beats: { available: true, free: true },
      maxSourceSec: EDITOR_LIMITS.maxSourceSec,
    };
  }
}
