// Editor v2 AI helpers as jobs (plans/api.md "Editor v2"): auto-captions (word timestamps), silence/filler cuts,
// background removal (green-screen video the apps key out) and voice clean-up. Each job: estimate → hold → run on the
// provider → settle at the GPU time actually billed (or release on failure/cancel), with `editor` live events. Results are
// data the APP applies to its edit project; nothing here touches video frames (outputs are copied byte for byte).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { and, desc, eq, sql } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { takes, uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { whoOf } from '../money/money.js';
import { putFile } from '../storage/objects.js';
import { ReplicateError } from '../replicate/client.js';
import { CUT_DEFAULTS, suggestCuts, type CutOptions, type Word } from './cuts.js';
import { makeProvider, rmQuiet, type EditorProvider, type Hooks } from './providers.js';
import { mediaToolsAvailable } from '../replicate/media.js';
import { detectSilences, silenceCuts } from './silence.js';
import { decodeMono, detectBeats } from './audio.js';
import { editorJobs, type EditorJobKind, type EditorSource } from './schema.js';

type Row = typeof editorJobs.$inferSelect;
export const EDITOR_KINDS: EditorJobKind[] = ['captions', 'cuts', 'matte', 'denoise', 'beats'];
export const EDITOR_LIMITS = { maxSourceSec: 600, maxMatteSec: 120, maxRunning: 2, reuseDays: 30, minChargeUsd: 0.01 } as const;
/** GPU seconds a job is expected to take (start-up + per second of media), for the estimate. */
const GPU_SEC = {
  transcribe: (d: number) => 8 + 0.15 * d,
  matte: (d: number) => 10 + 4 * d,
  separate: (d: number) => 5 + 0.3 * d,
};
const PHASE: Record<EditorJobKind, string> = { captions: 'Listening', cuts: 'Finding pauses', matte: 'Cutting out the background', denoise: 'Cleaning up the voice', beats: 'Finding the beat' };
const LANG_RE = /^[a-z]{2}$/;

export type JobOptions = { language?: string | null; fromJobId?: string; analyzeOnly?: boolean; silenceOnly?: boolean; noiseDb?: number } & CutOptions;

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
  private async patch(id: string, set: Partial<Row>) {
    const [r] = await this.ctx.db.update(editorJobs).set(set).where(eq(editorJobs.id, id)).returning();
    if (r) this.emit(r);
    return r;
  }

  // ------------------------------------------------------------------ sources
  /** The stored media a job reads, checked against the studio. */
  async source(u: AuthUser, s: any): Promise<{ source: EditorSource; key: string; contentType: string }> {
    if (!s || typeof s !== 'object') throw badRequest('source: {takeId} or {uploadId, durationSec}');
    if (typeof s.takeId === 'string') {
      const [t] = await this.ctx.db.select().from(takes).where(and(eq(takes.id, s.takeId), eq(takes.studioId, u.studioId)));
      if (!t) throw notFound('Take');
      if (!t.mediaKey || !(t.kind === 'take' || (t.kind as string) === 'edit')) throw badRequest('source.takeId: must be a video take');
      const d = Number((t.media as { durationSec?: number } | null)?.durationSec ?? s.durationSec);
      if (!(d > 0)) throw badRequest('source.durationSec: unknown video length');
      return { source: { takeId: t.id, durationSec: d }, key: t.mediaKey, contentType: String((t.media as { contentType?: string } | null)?.contentType ?? 'video/mp4') };
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
    const src = await this.source(u, body?.source);
    const d = src.source.durationSec;
    if (d > EDITOR_LIMITS.maxSourceSec) throw badRequest(`source: at most ${EDITOR_LIMITS.maxSourceSec / 60} minutes`);
    if (kind === 'matte' && d > EDITOR_LIMITS.maxMatteSec) throw badRequest(`source: background removal works on up to ${EDITOR_LIMITS.maxMatteSec} s`);
    const silenceOnly = (kind === 'cuts' && !!opts.silenceOnly) || kind === 'beats';
    if (silenceOnly && !(await mediaToolsAvailable(this.ctx.config.FFMPEG_PATH, this.ctx.config.FFPROBE_PATH))) throw badRequest(kind === 'beats' ? 'kind: beat detection is not available on this server' : 'options.silenceOnly: not available on this server');
    const reuse = silenceOnly ? null : (kind === 'cuts' || kind === 'captions' || (kind === 'denoise' && opts.analyzeOnly)) ? await this.transcriptFor(u, src.key, opts) : null;
    if (kind === 'denoise' && opts.analyzeOnly && !reuse) throw badRequest('options.analyzeOnly: make captions for this video first');
    const p = this.provider;
    let usd = 0;
    if (silenceOnly) usd = 0;
    else if (kind === 'captions' || kind === 'cuts') usd = reuse ? 0 : GPU_SEC.transcribe(d) * p.rates.transcribe;
    else if (kind === 'matte') usd = GPU_SEC.matte(d) * p.rates.matte;
    else if (!opts.analyzeOnly) usd = GPU_SEC.separate(d) * p.rates.separate;
    usd = usd > 0 ? Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(usd * 10000) / 10000) : 0;
    return { kind, opts, src, reuse, usd };
  }

  // ------------------------------------------------------------------ jobs
  async start(u: AuthUser, body: any) {
    const e = await this.estimate(u, body);
    const id = uid('edj');
    const models = e.usd === 0 ? [] : e.kind === 'matte' ? [this.provider.models.matte] : e.kind === 'denoise' ? [this.provider.models.separate] : [this.provider.models.transcribe];
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

  private async run(row: Row, u: AuthUser, src: { key: string; contentType: string; source: EditorSource }, reuse: { words: Word[]; language: string } | null) {
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
        const out = row.kind === 'matte' ? await p.matte(url, d, hooks) : await p.separate(url, d, hooks);
        file = out.file; gpuSec = out.gpuSec; rate = row.kind === 'matte' ? p.rates.matte : p.rates.separate;
        const asset = await this.store(u, src, out.file, out.contentType, row.kind === 'matte' ? 'video' : 'audio', d);
        result = row.kind === 'matte'
          ? { asset, chroma: { color: '#00FF00', similarity: 0.4, smoothness: 0.08, spill: 0.5 } }
          : { asset, suggestion: noiseSuggestion((await this.transcriptFor(u, src.key, {}).catch(() => null))?.words ?? []) };
      } else {
        result = { suggestion: noiseSuggestion(reuse?.words ?? []) };
      }
      if (this.stopping.has(id)) throw new ReplicateError('Cancelled', 'cancelled');
      const actual = !needsGpu ? 0 : gpuSec != null ? Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(gpuSec * rate * 10000) / 10000) : row.estimate;
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
  private async withLocalInput<T>(key: string, fn: (input: string) => Promise<T>): Promise<T> {
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
    if (!file) return { kind, ...(src.source.takeId ? { take: src.source.takeId } : { upload: src.source.uploadId }), durationSec };
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
    if (q.kind) conds.push(eq(editorJobs.kind, q.kind as EditorJobKind));
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

  features() {
    return {
      captions: { available: true, languages: ['auto', 'en', 'es', 'fr', 'de', 'it', 'pt', 'nl', 'ja', 'ko', 'zh'] },
      cuts: { available: true, defaults: { ...CUT_DEFAULTS } },
      matte: { available: true, maxSec: EDITOR_LIMITS.maxMatteSec },
      denoise: { available: true },
      beats: { available: true, free: true },
      maxSourceSec: EDITOR_LIMITS.maxSourceSec,
    };
  }
}
