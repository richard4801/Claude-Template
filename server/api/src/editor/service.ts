// Editor v2 AI helpers as jobs (plans/api.md "Editor v2"): auto-captions (word timestamps), silence/filler cuts,
// background removal (green-screen video the apps key out) and voice clean-up. Each job: estimate → hold → run on the
// provider → settle at the GPU time actually billed (or release on failure/cancel), with `editor` live events. Results are
// data the APP applies to its edit project; nothing here touches video frames (outputs are copied byte for byte).
import { resultsOf } from '../claude/results.js';
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
import { cleanUploadedPhoto, putFile, readyIfStored } from '../storage/objects.js';
import { ReplicateError } from '../replicate/client.js';
import { PaidLost, paidLostFailure, reportPaidLost } from '../services/paidLost.js';
import { StepBack } from './paidPoll.js';
import { users } from '../db/schema.js';
import type { JobRow } from '../gpu/controller.js';
import { CUT_DEFAULTS, suggestCuts, type CutOptions, type Word } from './cuts.js';
import { makeProvider, rmQuiet, type EditorProvider, type Hooks, type TrackPoint } from './providers.js';
import { mediaToolsAvailable, probe } from '../replicate/media.js';
import { detectSilences, silenceCuts } from './silence.js';
import { decodeMono, detectBeats } from './audio.js';
import { REVERSE_LIMITS, reverseVideo } from './reverse.js';
import { STABILIZE_LIMITS, smoothingOf, stabilizeVideo, vidstabAvailable } from './stabilize.js';
import { TRANSLATE_LANGUAGES, TRANSLATE_LIMITS, TRANSLATE_MODELS, TranslateError, captionLines, expectedTokens, translateAppLines, translateClient, translateUsd, translateWords, type AppLine, type Quality, type TranslateClient } from './translate.js';
import { FalProvider } from '../suite/providers.js';
import { SLOWMO_LIMITS, SLOWMO_MODEL, cutRange, falInterpolate, retime, slowmoComputeSec, slowmoUsd, type SlowmoFactor } from './slowmo.js';
import { AssemblyAI, ASSEMBLY_MAX_RATE, ASSEMBLY_MODEL } from './assemblyai.js';
import { exportLanguages, exportNotice } from './scripts.js';
import { CUTOUT_LIMITS, composeCutout, prepareStill } from './cutout.js';
import { editorJobs, type EditorJobKind, type EditorSource } from './schema.js';
import { RANGED_KINDS, padToSource, parseRange, sourceSec, trimRange } from './range.js';
import { GENJUTSU_HELPERS, GENJUTSU_LIMITS, genjutsuHelperInput, genjutsuSeconds, genjutsuUsd, isGenjutsuHelper, parseGenjutsuOptions, runGenjutsu, type GenjutsuImage, type GenjutsuOptions } from './genjutsu.js';
import { GENJUTSU_NO_ACCESS } from '../engines/purposes.js';

import { LAYERS_LIMITS, coverageWarning, matteBoxes, objectsKey, parseObjects, retimeMatte, type LayerObject } from './layers.js';

type Row = typeof editorJobs.$inferSelect;
export const EDITOR_KINDS: EditorJobKind[] = ['captions', 'cuts', 'matte', 'denoise', 'beats', 'reverse', 'stabilize', 'translate', 'slowmo', 'separate', 'cutout', 'objectswap', 'restyle', 'layers'];
export const EDITOR_LIMITS = { maxSourceSec: 600, maxMatteSec: 120, maxRunning: 2, reuseDays: 30, minChargeUsd: 0.01 } as const;
/** GPU seconds a job is expected to take (start-up + per second of media), for the estimate. */
export const GPU_SEC = {
  transcribe: (d: number) => 8 + 0.15 * d,
  matte: (d: number) => 10 + 4 * d,
  track: (d: number) => 15 + 3 * d,
  /** Layers: one tracking run per object (plans/layers-edit.md; re-measure on first real runs). */
  layers: (d: number, n: number) => n * (15 + 3 * d),
  separate: (d: number) => 5 + 0.3 * d,
};
const PHASE: Record<EditorJobKind, string> = { captions: 'Listening', cuts: 'Finding pauses', matte: 'Cutting out the background', denoise: 'Cleaning up the voice', beats: 'Finding the beat', reverse: 'Reversing', stabilize: 'Steadying', translate: 'Translating', slowmo: 'Slowing down', separate: 'Splitting voice and music', cutout: 'Cutting out', layers: 'Finding layers', briefs: 'Writing the briefs', objectswap: 'Swapping the object', restyle: 'Restyling' };
const LANG_RE = /^[a-z]{2}$/;

/** Tap to keep (workstream 1): a point on the clip, 0–1 of the frame, at `t` seconds of the source; keep false = leave out. */
export type KeepPoint = { x: number; y: number; t: number; keep: boolean };
export const MAX_KEEP_POINTS = 10;
export type JobOptions = { language?: string | null; fromJobId?: string; targetLanguage?: string; sourceLanguage?: string; lines?: AppLine[]; quality?: Quality; strength?: number; zoom?: 'auto' | 'none'; factor?: SlowmoFactor; startSec?: number; endSec?: number; analyzeOnly?: boolean; silenceOnly?: boolean; noiseDb?: number; points?: KeepPoint[]; objects?: LayerObject[] } & CutOptions & GenjutsuOptions;

/** The languages translate offers: those the export draws today. */
const translateTargets = () => { const ok = exportLanguages(); return Object.keys(TRANSLATE_LANGUAGES).filter(l => ok.has(l)); };

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
  if ((kind === 'matte' || kind === 'cutout') && o.points !== undefined) {
    // workstream 1: tap to keep. The subject under the points is tracked through the clip.
    if (!Array.isArray(o.points) || !o.points.length || o.points.length > MAX_KEEP_POINTS) throw badRequest(`options.points: 1 to ${MAX_KEEP_POINTS} points`);
    out.points = o.points.map((q: any, i: number) => {
      if (!q || typeof q !== 'object') throw badRequest(`options.points.${i}: {x, y, t?, keep?}`);
      const n = (k: string, lo: number, hi: number, d?: number) => { const v = q[k] ?? d; if (typeof v !== 'number' || !Number.isFinite(v) || v < lo || v > hi) throw badRequest(`options.points.${i}.${k}: from ${lo} to ${hi}`); return Math.round(v * 10000) / 10000; };
      if (q.keep !== undefined && typeof q.keep !== 'boolean') throw badRequest(`options.points.${i}.keep: true or false`);
      // A still has one moment: its points are all at t = 0.
      return { x: n('x', 0, 1), y: n('y', 0, 1), t: kind === 'cutout' ? 0 : n('t', 0, EDITOR_LIMITS.maxSourceSec, 0), keep: q.keep !== false };
    });
    if (!out.points!.some(q => q.keep)) throw badRequest('options.points: tap at least one thing to keep');
  }
  if (kind === 'layers') out.objects = parseObjects(o.objects, EDITOR_LIMITS.maxSourceSec); // t is checked against the window in estimate()
  if (kind === 'translate') {
    // Only languages the export can draw (scripts.ts): the others would show in the app but vanish from exports.
    if (typeof o.targetLanguage !== 'string' || !TRANSLATE_LANGUAGES[o.targetLanguage] || !exportLanguages().has(o.targetLanguage)) throw badRequest(`options.targetLanguage: one of ${translateTargets().join(', ')}`);
    out.targetLanguage = o.targetLanguage;
    if (o.sourceLanguage !== undefined) { if (typeof o.sourceLanguage !== 'string' || !TRANSLATE_LANGUAGES[o.sourceLanguage]) throw badRequest('options.sourceLanguage: a language code'); out.sourceLanguage = o.sourceLanguage; }
    if (o.lines !== undefined) {
      // The app's caption lines as shown (edits included), instead of the transcript.
      const L = TRANSLATE_LIMITS;
      if (!Array.isArray(o.lines) || !o.lines.length || o.lines.length > L.maxLines) throw badRequest(`options.lines: 1 to ${L.maxLines} lines`);
      const ids = new Set<string>();
      out.lines = o.lines.map((l: any, i: number) => {
        if (!l || typeof l !== 'object' || typeof l.id !== 'string' || !l.id || l.id.length > 100 || ids.has(l.id)) throw badRequest(`options.lines.${i}.id: a unique id`);
        if (typeof l.text !== 'string' || !l.text.trim() || l.text.length > L.maxLineChars) throw badRequest(`options.lines.${i}.text: 1 to ${L.maxLineChars} characters`);
        const t = (k: string) => { const v = l[k]; if (typeof v !== 'number' || !Number.isFinite(v) || v < 0) throw badRequest(`options.lines.${i}.${k}: seconds from 0`); return Math.round(v * 1000) / 1000; };
        const startSec = t('startSec'), endSec = t('endSec');
        if (endSec < startSec) throw badRequest(`options.lines.${i}.endSec: not before startSec`);
        ids.add(l.id);
        return { id: l.id, text: l.text.trim(), startSec, endSec };
      });
    }
    if (o.quality !== undefined) { if (o.quality !== 'standard' && o.quality !== 'best') throw badRequest('options.quality: "standard" or "best"'); out.quality = o.quality; }
  }
  if (kind === 'stabilize') {
    if (o.strength !== undefined) { if (typeof o.strength !== 'number' || !Number.isFinite(o.strength) || o.strength < 0 || o.strength > 1) throw badRequest('options.strength: from 0 to 1'); out.strength = Math.round(o.strength * 100) / 100; }
    if (o.zoom !== undefined) { if (o.zoom !== 'auto' && o.zoom !== 'none') throw badRequest('options.zoom: "auto" or "none"'); out.zoom = o.zoom; }
  }
  if (kind === 'slowmo') {
    if (o.factor !== 2 && o.factor !== 4) throw badRequest('options.factor: 2 or 4');
    const n = (k: 'startSec' | 'endSec') => { if (typeof o[k] !== 'number' || !Number.isFinite(o[k]) || o[k] < 0) throw badRequest(`options.${k}: seconds from 0`); return Math.round(o[k] * 1000) / 1000; };
    out.factor = o.factor; out.startSec = n('startSec'); out.endSec = n('endSec');
    const len = out.endSec - out.startSec;
    if (len < SLOWMO_LIMITS.minRangeSec || len > SLOWMO_LIMITS.maxRangeSec) throw badRequest(`options.endSec: the range must be ${SLOWMO_LIMITS.minRangeSec} to ${SLOWMO_LIMITS.maxRangeSec} s long`);
  }
  if (isGenjutsuHelper(kind)) Object.assign(out, parseGenjutsuOptions(kind, o));
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

/** A job's options as the apps see them (the server instance running it stays internal). */
const viewOptions = (o: Record<string, unknown>) => { const { runner: _r, ...rest } = o ?? {}; return rest; };
/**
 * A finished job's result; a failed one made at the provider but not saved carries `errorCode` (provider_paid_unsaved /
 * provider_unconfirmed: the owner's free Recover, POST /v1/jobs/:id/recover; provider_paid_lost: not recoverable).
 */
const viewResult = (res: Record<string, unknown> | null, role: 'owner' | 'member') => {
  if (!res) return {};
  const { errorCode, paid, recovering: _x, ...rest } = res as { errorCode?: string; paid?: { recoverable?: boolean; usd?: number }; recovering?: boolean };
  return { ...(Object.keys(rest).length ? { result: rest } : {}), ...(errorCode ? { errorCode, recoverable: !!paid?.recoverable } : {}),
    ...(role === 'owner' && paid?.usd != null ? { paidUsd: paid.usd } : {}) };
};

export class EditorAiService {
  readonly provider: EditorProvider;
  private stopping = new Set<string>();
  /** This server instance: a job resumed by another instance after a deploy is left to it (options.runner). */
  private leaving = false;
  /** Shutdown (a deploy): Genjutsu / slow-motion runs step back at their next poll, their jobs stay running with the
   *  request id saved, and the next instance resumes them (never failed, never cancelled at the provider). */
  stop() { this.leaving = true; }
  private readonly instance = `${os.hostname()}:${process.pid}:${Math.random().toString(36).slice(2, 10)}`;
  private running = 0;
  private waiting: (() => void)[] = [];
  constructor(private ctx: Ctx, provider?: EditorProvider) { this.provider = provider ?? makeProvider(ctx); this.fal = new FalProvider(ctx); this.assembly = new AssemblyAI(ctx.config.ASSEMBLYAI_API_KEY, ctx.config.ASSEMBLYAI_API_URL, fetch, ctx.log); }

  // ------------------------------------------------------------------ views and events
  view(r: Row, role: 'owner' | 'member') {
    return {
      id: r.id, kind: r.kind, state: r.state, progress: Math.round(r.progress), phase: r.phase, source: r.source, options: viewOptions(r.options),
      estimateUsd: r.estimate, costUsd: r.cost, ...viewResult(r.result, role), ...(r.error ? { error: r.error } : {}),
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
      // Results arrive in the chat: an Edit helper job (captions, cut fillers, background, …) ended.
      if (r.state === 'done' || r.state === 'failed') void resultsOf(this.ctx).report(`editor-${r.id}`, { kind: `edit ${r.kind}`, status: r.state === 'done' ? 'done' : 'failed',
        title: `Edit · ${String(r.kind).replace(/[_-]/g, ' ')}`, editorJobId: r.id, ...(r.error ? { error: r.error } : {}) }).catch(() => undefined);
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
      const range = parseRange(s.range, d);
      return { source: { takeId: t.id, durationSec: d, ...(range ? { range } : {}) }, key: t.mediaKey, contentType: String((t.media as { contentType?: string } | null)?.contentType ?? 'video/mp4'),
        ...(md.width && md.height ? { size: { width: md.width, height: md.height, ...(md.fps ? { fps: md.fps } : {}) } } : {}) };
    }
    if (typeof s.uploadId === 'string') {
      const [up] = await this.ctx.db.select().from(uploads).where(and(eq(uploads.id, s.uploadId), eq(uploads.studioId, u.studioId)));
      if (!up) throw notFound('Upload');
      if (!/^(video|audio)\//.test(up.contentType)) throw badRequest('source.uploadId: must be a video or audio upload');
      if (typeof s.durationSec !== 'number' || !(s.durationSec > 0)) throw badRequest('source.durationSec: required for an upload');
      if (!(await this.ctx.storage.head(up.storageKey))) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it to the URL first');
      // A video or audio upload is made ready with its size, never read into memory (a phone video can be hundreds of MB).
      if (up.state !== 'ready') await readyIfStored(this.ctx, up);
      const range = parseRange(s.range, s.durationSec);
      return { source: { uploadId: up.id, durationSec: s.durationSec, ...(range ? { range } : {}) }, key: up.storageKey, contentType: up.contentType };
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
      const purpose = kind === 'captions' || kind === 'cuts' ? 'captions' : kind === 'layers' ? 'track' : kind === 'matte' ? (opts.points ? 'track' : 'matte') : kind === 'denoise' ? 'denoise' : null;
      if (!purpose) throw badRequest(`engineModel: ${kind} runs no model`);
      await (await import('../engines/service.js')).modelChoice(this.ctx).check(u, purpose, body.engineModel);
    }
    const requested = typeof body?.engineModel === 'string' ? body.engineModel : null;
    if (kind === 'cutout') {
      // A still's cut-out (a sticker): the person matte, or with taps the object tracker, on a one-second clip of it.
      if (!this.matteAvailable) throw badRequest('Background removal is coming soon');
      const src = await this.imageSource(u, body?.source), sec = CUTOUT_LIMITS.clipSec, p = this.provider;
      const usd = opts.points ? GPU_SEC.track(sec) * p.rates.track : GPU_SEC.matte(sec) * p.rates.matte;
      return { kind, opts, src, reuse: null, usd: usd > 0 ? Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(usd * this.markup * 10000) / 10000) : 0 };
    }
    const src = await this.source(u, body?.source);
    if (src.source.range && !RANGED_KINDS.includes(kind)) throw badRequest(`source.range: only for ${RANGED_KINDS.join(', ')}`);
    // ci_238dd2979f5a: an item-scoped job is priced on the seconds it sends (its window), the same seconds the run bills.
    const d = sourceSec(src.source), win0 = src.source.range?.startSec ?? 0, win1 = src.source.range?.endSec ?? src.source.durationSec;
    const inWindow = (t: number) => t >= win0 - 0.05 && t <= win1 + 0.05;
    if (src.source.durationSec > EDITOR_LIMITS.maxSourceSec) throw badRequest(`source: at most ${EDITOR_LIMITS.maxSourceSec / 60} minutes`);
    // Genjutsu helpers (Higgsfield): object swap / restyle, priced per source second (first 30 s) × the editor markup.
    if (isGenjutsuHelper(kind)) {
      if (!this.ctx.suite.providers.higgsfield.configured()) throw badRequest('kind: Genjutsu is not available on this server');
      genjutsuSeconds(d);
      await this.genjutsuImages(u, opts.images ?? [], 60);
      return { kind, opts, src, reuse: null, usd: Math.max(EDITOR_LIMITS.minChargeUsd, genjutsuUsd(kind, opts.resolution ?? '720p', d, this.markup)) };
    }
    // 2026-11-08: background removal is "coming soon" while production runs the mock (nothing real to give yet).
    if (kind === 'matte' && !this.matteAvailable) throw badRequest('Background removal is coming soon');
    if (kind === 'matte' && d > EDITOR_LIMITS.maxMatteSec) throw badRequest(`source: background removal works on up to ${EDITOR_LIMITS.maxMatteSec} s`);
    if (kind === 'layers') {
      // Find layers (plans/layers-edit.md): the tracker once per object; the same objects on the same video again are free.
      if (!this.matteAvailable) throw badRequest('Layers are coming soon');
      if (d > LAYERS_LIMITS.maxSec + 0.05) throw badRequest(`source: layers work on clips up to ${LAYERS_LIMITS.maxSec} s · trim it first`);
      if (opts.objects!.some(ob => ob.points.some(q => !inWindow(q.t)))) throw badRequest(`options.objects: t must be within the clip (${win0}–${win1} s of its source)`);
      if (await this.layersBefore(u.studioId, src.key, opts.objects!, src.source.range)) return { kind, opts, src, reuse: null, usd: 0 };
      const usd = GPU_SEC.layers(d, opts.objects!.length) * this.provider.rates.track;
      return { kind, opts, src, reuse: null, usd: usd > 0 ? Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(usd * this.markup * 10000) / 10000) : 0 };
    }
    if (kind === 'reverse' && d > REVERSE_LIMITS.maxSec) throw badRequest(`source: reverse works on videos up to ${REVERSE_LIMITS.maxSec} s`);
    if (kind === 'stabilize' && d > STABILIZE_LIMITS.maxSec) throw badRequest(`source: stabilise works on videos up to ${STABILIZE_LIMITS.maxSec / 60} minutes`);
    if (kind === 'stabilize' && !(await this.stabilizeAvailable())) throw badRequest('kind: stabilise is not available on this server');
    const silenceOnly = (kind === 'cuts' && !!opts.silenceOnly) || kind === 'beats' || kind === 'reverse' || kind === 'stabilize';
    if (silenceOnly && !(await mediaToolsAvailable(this.ctx.config.FFMPEG_PATH, this.ctx.config.FFPROBE_PATH))) throw badRequest(kind === 'beats' ? 'kind: beat detection is not available on this server' : kind === 'reverse' ? 'kind: reverse is not available on this server' : 'options.silenceOnly: not available on this server');
    const reuse = silenceOnly ? null : (kind === 'cuts' || kind === 'captions' || (kind === 'translate' && !opts.lines) || (kind === 'denoise' && opts.analyzeOnly)) ? await this.transcriptFor(u, src.key, kind === 'translate' ? { fromJobId: opts.fromJobId } : opts) : null;
    if (kind === 'translate') {
      if (!this.translator()) throw badRequest('kind: translating captions is not available on this server');
      if (opts.lines) {
        if (opts.sourceLanguage === opts.targetLanguage) throw badRequest('options.targetLanguage: the captions are already in that language');
        return { kind, opts, src, reuse, usd: translateUsd(opts.quality ?? 'standard', expectedTokens(opts.lines), this.markup) };
      }
      if (!reuse) throw badRequest('options: make captions for this video first');
      if (reuse.words.length > TRANSLATE_LIMITS.maxWords) throw badRequest(`source: at most ${TRANSLATE_LIMITS.maxWords} words`);
      if (reuse.language === opts.targetLanguage) throw badRequest('options.targetLanguage: the captions are already in that language');
      return { kind, opts, src, reuse, usd: translateUsd(opts.quality ?? 'standard', expectedTokens(captionLines(reuse.words)), this.markup) };
    }
    if (kind === 'slowmo') {
      if (!(await this.slowmoAvailable())) throw badRequest('kind: smooth slow motion is not available on this server');
      if (opts.endSec! > d + 0.05) throw badRequest(`options.endSec: within the clip (0–${d} s)`);
      // The same range at the same speed done before (by anyone in the studio) is reused, free.
      if (await this.slowmoBefore(u.studioId, src.key, opts)) return { kind, opts, src, reuse, usd: 0 };
      const sz = src.size;
      return { kind, opts, src, reuse, usd: slowmoUsd(slowmoComputeSec(opts.endSec! - opts.startSec!, sz?.fps ?? 30, opts.factor!, sz?.width ?? 1080, sz?.height ?? 1920), this.markup) };
    }
    if (kind === 'separate') {
      // Voice and music as two audio files (one split, priced like the voice clean-up). Not while production runs the mock.
      if (!this.matteAvailable) throw badRequest('Splitting voice and music is coming soon');
      if (await this.separateBefore(u.studioId, src.key)) return { kind, opts, src, reuse, usd: 0 };
      return { kind, opts, src, reuse, usd: Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(GPU_SEC.separate(d) * this.provider.rates.separate * this.markup * 10000) / 10000) };
    }
    if (kind === 'denoise' && opts.analyzeOnly && !reuse) throw badRequest('options.analyzeOnly: make captions for this video first');
    const p = this.provider;
    let usd = 0, transcriber: string | null = null;
    if (silenceOnly) usd = 0;
    else if (kind === 'captions' || kind === 'cuts') {
      if (!reuse) {
        transcriber = await this.transcriber(u, requested);
        usd = transcriber === ASSEMBLY_MODEL ? d * ASSEMBLY_MAX_RATE : GPU_SEC.transcribe(d) * p.rates.transcribe;
      }
    }
    else if (kind === 'matte' && opts.points) {
      if (opts.points.some(q => !inWindow(q.t))) throw badRequest(`options.points: t must be within the clip (${win0}–${win1} s of its source)`);
      usd = GPU_SEC.track(d) * p.rates.track;
    } else if (kind === 'matte') usd = GPU_SEC.matte(d) * p.rates.matte;
    else if (!opts.analyzeOnly) usd = GPU_SEC.separate(d) * p.rates.separate;
    // workstream 1: the price is the provider's cost x EDITOR_MARKUP (the owner's choice: x 2, like Upscale).
    usd = usd > 0 ? Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(usd * this.markup * 10000) / 10000) : 0;
    return { kind, opts, src, reuse, usd, transcriber };
  }

  // ------------------------------------------------------------------ jobs
  async start(u: AuthUser, body: any) {
    const e = await this.estimate(u, body);
    // Layers (owner, 2026-11-11): a run above $1 per clip asks first; the app (or the owner's approval) sends acceptUsd.
    if (e.kind === 'layers' && e.usd > LAYERS_LIMITS.askAboveUsd && !(typeof body?.acceptUsd === 'number' && body.acceptUsd >= e.usd - 1e-9))
      throw Object.assign(new ApiError(409, 'price_confirm', `Finding these layers costs $${e.usd.toFixed(2)} · confirm to go ahead`), { extra: { usd: e.usd } });
    if (e.usd > 0) await this.allowPaid(u.studioId, e.usd);
    const id = uid('edj');
    const models = e.kind === 'layers' ? (e.usd > 0 ? [this.provider.models.track] : []) : isGenjutsuHelper(e.kind) ? [GENJUTSU_HELPERS[e.kind].ref] : e.kind === 'cutout' ? (e.usd > 0 ? [e.opts.points ? this.provider.models.track : this.provider.models.matte] : []) : e.kind === 'separate' ? (e.usd > 0 ? [this.provider.models.separate] : []) : e.kind === 'slowmo' ? (e.usd > 0 ? [SLOWMO_MODEL.ref] : []) : e.kind === 'translate' ? [TRANSLATE_MODELS[e.opts.quality ?? 'standard'].model] : e.usd === 0 ? [] : e.kind === 'matte' ? [e.opts.points ? this.provider.models.track : this.provider.models.matte] : e.kind === 'denoise' ? [this.provider.models.separate] : [('transcriber' in e && e.transcriber) || this.provider.models.transcribe];
    const holdTokens = e.usd > 0 ? await this.ctx.money.hold(whoOf(u), id, e.usd, { perJob: false, note: `Editor ${e.kind} · hold` }) : 0;
    let row: Row;
    resultsOf(this.ctx).link(u, `editor-${id}`);
    try {
      [row] = await this.ctx.db.insert(editorJobs).values({
        id, studioId: u.studioId, userId: u.id, kind: e.kind, state: 'running', source: e.src.source, mediaKey: e.src.key, options: { ...(e.opts as Record<string, unknown>), runner: this.instance },
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
  /** Heavy local ffmpeg jobs (reverse, stabilise) run one at a time: each can take ~200 MB of the 512 MB box. */
  private localBusy = false;
  private localWaiting: (() => void)[] = [];
  private async localSlot() {
    if (!this.localBusy) { this.localBusy = true; return; }
    await new Promise<void>(r => this.localWaiting.push(r));
  }
  private localFree() { const next = this.localWaiting.shift(); if (next) next(); else this.localBusy = false; }
  private translateFake: TranslateClient | null = null;
  private translateReal: TranslateClient | null = null;
  /** Tests: a fake Claude client for translations. */
  setTranslateClient(c: TranslateClient | null) { this.translateFake = c; }
  /** The client translations use (the server's Anthropic key), or null when the server has none. */
  translator(): TranslateClient | null { return this.translateFake ?? (this.translateReal ??= translateClient(this.ctx.config.ANTHROPIC_API_KEY)); }
  /** fal (smooth slow motion), with the server's FAL_KEY. */
  private fal: FalProvider;
  /** Tests: how often fal is polled. */
  falPollMs = 2000;
  private slowTools: Promise<boolean> | null = null;
  /** Whether slow motion can run: fal is set up and ffmpeg is here. */
  async slowmoAvailable() { return !!this.ctx.config.FAL_KEY && await (this.slowTools ??= mediaToolsAvailable(this.ctx.config.FFMPEG_PATH, this.ctx.config.FFPROBE_PATH)); }
  /** The same objects (names and taps) found on the same video before, by anyone in the studio, within the reuse window. */
  /** A run on a window (range) is reused only by a job whose window lies inside it (the mattes are black outside it). */
  private async layersBefore(studioId: string, key: string, objects: LayerObject[], range?: EditorSource['range']) {
    const since = Date.now() - EDITOR_LIMITS.reuseDays * 86_400_000, want = objectsKey(objects);
    const prev = await this.ctx.db.select().from(editorJobs).where(and(eq(editorJobs.studioId, studioId), eq(editorJobs.kind, 'layers'), eq(editorJobs.mediaKey, key), eq(editorJobs.state, 'done'), sql`${editorJobs.createdAt} > ${since}`)).orderBy(desc(editorJobs.createdAt)).limit(20);
    const covers = (r: Row) => { const w = r.source.range; return !w || (!!range && w.startSec <= range.startSec + 1e-6 && w.endSec >= range.endSec - 1e-6); };
    return prev.find(r => objectsKey((r.options as JobOptions).objects ?? []) === want && covers(r) && !!r.result && !(r.result as { reused?: boolean }).reused && (r.result as { aligned?: boolean }).aligned === true) ?? null;
  }
  private async slowmoBefore(studioId: string, key: string, o: JobOptions) {
    const prev = await this.ctx.db.select().from(editorJobs).where(and(eq(editorJobs.studioId, studioId), eq(editorJobs.kind, 'slowmo'), eq(editorJobs.mediaKey, key), eq(editorJobs.state, 'done'))).orderBy(desc(editorJobs.createdAt)).limit(20);
    return prev.find(r => { const p = r.options as JobOptions; return p.factor === o.factor && p.startSec === o.startSec && p.endSec === o.endSec && !!r.result; }) ?? null;
  }
  /** AssemblyAI (captions and cuts) with the server's key. */
  readonly assembly: AssemblyAI;
  /**
   * The transcriber for captions and cuts: the owner's pick (request, else the studio default for captions), else
   * AssemblyAI when its key is set, else the Replicate model.
   */
  private async transcriber(u: AuthUser, requested: string | null): Promise<string> {
    const c = await (await import('../engines/service.js')).modelChoice(this.ctx).choose(u, 'captions', requested);
    if (c && (c.model !== ASSEMBLY_MODEL || this.assembly.configured())) return c.model;
    return this.assembly.configured() ? ASSEMBLY_MODEL : this.provider.models.transcribe;
  }
  /** A photo to cut out: a still take (kind "shot") or an image upload. */
  async imageSource(u: AuthUser, s: any): Promise<{ source: EditorSource; key: string; contentType: string; size?: { width: number; height: number } }> {
    if (!s || typeof s !== 'object') throw badRequest('source: {takeId} or {uploadId} of a photo');
    if (typeof s.takeId === 'string') {
      const [t] = await this.ctx.db.select().from(takes).where(and(eq(takes.id, s.takeId), eq(takes.studioId, u.studioId)));
      if (!t) throw notFound('Take');
      const md = (t.media ?? {}) as { width?: number; height?: number; contentType?: string; durationSec?: number };
      const ct = md.contentType ?? (/\.(png)$/i.test(t.mediaKey ?? '') ? 'image/png' : /\.(jpe?g)$/i.test(t.mediaKey ?? '') ? 'image/jpeg' : /\.webp$/i.test(t.mediaKey ?? '') ? 'image/webp' : '');
      if (!t.mediaKey || !ct.startsWith('image/')) throw badRequest('source.takeId: must be a photo');
      return { source: { takeId: t.id, durationSec: 0 }, key: t.mediaKey, contentType: ct, ...(md.width && md.height ? { size: { width: md.width, height: md.height } } : {}) };
    }
    if (typeof s.uploadId === 'string') {
      const [up] = await this.ctx.db.select().from(uploads).where(and(eq(uploads.id, s.uploadId), eq(uploads.studioId, u.studioId)));
      if (!up) throw notFound('Upload');
      if (!/^image\/(png|jpeg|webp)$/.test(up.contentType)) throw badRequest('source.uploadId: must be a photo (PNG, JPEG or WebP)');
      if (!(await this.ctx.storage.head(up.storageKey))) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it to the URL first');
      if (up.state !== 'ready') await cleanUploadedPhoto(this.ctx, up); // no EXIF/GPS reaches a provider
      return { source: { uploadId: up.id, durationSec: 0 }, key: up.storageKey, contentType: up.contentType };
    }
    throw badRequest('source: {takeId} or {uploadId} of a photo');
  }

  /**
   * The cut-out: the photo upright and at most 2048 px as a one-second clip (stored for the helper to fetch, deleted
   * after), the matte (person, or the tapped object at frame 0), then its alpha on the photo, trimmed: a PNG upload.
   */
  private async cutout(u: AuthUser, src: { key: string; source: EditorSource }, o: JobOptions, _url: string, hooks: Hooks, temps: string[],
    paid: <T extends { gpuSec: number | null }>(rate: number, f: () => Promise<T>) => Promise<T>) {
    const ffmpeg = this.ctx.config.FFMPEG_PATH, p = this.provider;
    const [still, clip, mask, out] = ['png', 'mp4', 'png', 'png'].map(ext => path.join(os.tmpdir(), `${uid('cut')}.${ext}`)) as [string, string, string, string];
    temps.push(still, clip, mask, out);
    const size = await this.withLocalInput(src.key, input => prepareStill(ffmpeg, input, still, clip));
    const key = `t/${uid('cutin')}.mp4`;
    await this.ctx.storage.putStream(key, fs.createReadStream(clip), 'video/mp4', fs.statSync(clip).size);
    let made: { file: string | null; gpuSec: number | null };
    try {
      const url = await this.ctx.storage.presignGet(key, this.ctx.config.REPLICATE_INPUT_URL_TTL_SEC);
      made = o.points?.length
        ? await paid(p.rates.track, () => p.track(url, CUTOUT_LIMITS.clipSec, o.points!.map(q => ({ x: q.x * (size.width - 1), y: q.y * (size.height - 1), frame: 0, keep: q.keep })), hooks))
        : await paid(p.rates.matte, () => p.matte(url, CUTOUT_LIMITS.clipSec, hooks));
    } finally { await this.ctx.storage.delete(key).catch(() => {}); }
    if (made.file) temps.push(made.file);
    if (!made.file) throw new ReplicateError('The background removal returned nothing', 'failed');
    const c = await composeCutout(ffmpeg, still, made.file, mask, out);
    const asset = await this.store(u, src, out, 'image/png', 'image', 0);
    return { gpuSec: made.gpuSec, result: { asset: { ...asset, width: c.width, height: c.height }, width: c.width, height: c.height, box: c.box, sourceWidth: size.width, sourceHeight: size.height } as Record<string, unknown> };
  }

  /** The last finished voice/music split of this source in the studio (reused, free). */
  private async separateBefore(studioId: string, key: string) {
    const [prev] = await this.ctx.db.select().from(editorJobs).where(and(eq(editorJobs.studioId, studioId), eq(editorJobs.kind, 'separate'), eq(editorJobs.mediaKey, key), eq(editorJobs.state, 'done'))).orderBy(desc(editorJobs.createdAt)).limit(1);
    return prev?.result ? prev : null;
  }
  private vidstab: Promise<boolean> | null = null;
  /** Whether this server's ffmpeg can stabilise (checked once). */
  stabilizeAvailable() { return (this.vidstab ??= mediaToolsAvailable(this.ctx.config.FFMPEG_PATH, this.ctx.config.FFPROBE_PATH).then(ok => ok && vidstabAvailable(this.ctx.config.FFMPEG_PATH))); }

  private async run(row: Row, u: AuthUser, src: { key: string; contentType: string; source: EditorSource; size?: { width: number; height: number; fps?: number } }, reuse: { words: Word[]; language: string } | null,
    resume = false) {
    // d: the seconds the provider sees and bills (the job's window, ci_238dd2979f5a); full: the source's own length.
    const id = row.id, d = sourceSec(src.source), full = src.source.durationSec, win = src.source.range, o = row.options as JobOptions, p = this.provider;
    /** Genjutsu / slow motion after a restart or a recover: the saved provider request is polled, never started again. */
    const resumeId = resume ? row.predictionId : null;
    const recovering = resume && !!(row.result as { recovering?: boolean } | null)?.recovering;
    // Once a provider has made a result it is paid: a late cancel no longer throws it away, and a failure after it is
    // said honestly (services/paidLost.ts). `made.usd` is what it cost (provider × markup, what the member would pay).
    let made: { usd: number } | null = null;
    const addMade = (usd: number) => { made = { usd: (made?.usd ?? 0) + Math.max(0, usd) }; };
    const gpuUsd = (gpuSec: number | null, r: number) => gpuSec != null ? Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(gpuSec * r * this.markup * 10000) / 10000) : row.estimate;
    /** A paid Replicate helper call: its cost counts as made the moment it returns. */
    const paid = async <T extends { gpuSec: number | null }>(r: number, f: () => Promise<T>) => { const out = await f(); if (row.estimate > 0) addMade(gpuUsd(out.gpuSec, r)); return out; };
    const saveHandle = async (hid: string) => { await this.ctx.db.update(editorJobs).set({ predictionId: hid }).where(eq(editorJobs.id, id)); };
    const hooks: Hooks = {
      cancelled: () => this.stopping.has(id),
      onPrediction: async pid => { await this.ctx.db.update(editorJobs).set({ predictionId: pid }).where(eq(editorJobs.id, id)); },
      onProgress: async (f, phase) => { await this.patch(id, { progress: Math.min(95, 5 + f * 90), ...(phase ? { phase } : {}) }); },
    };
    const needsGpu = row.estimate > 0;
    if (needsGpu) await this.slot();
    let file: string | null = null, windowKey: string | null = null;
    const temps: string[] = [];
    /** A result made on the window, back at its place in the source (black / silence around it); the mock's is left as made. */
    const toSource = async (f: string | null, kind: 'video' | 'audio') => {
      if (!win || !f || p.name === 'mock') return f;
      const outF = path.join(os.tmpdir(), `${uid('edpad')}.${kind === 'video' ? 'mp4' : 'wav'}`);
      temps.push(outF);
      await this.localSlot();
      try { await padToSource(this.ctx.config.FFMPEG_PATH, f, outF, win, full, kind); } finally { this.localFree(); }
      return outF;
    };
    try {
      if (this.stopping.has(id)) throw new ReplicateError('Cancelled', 'cancelled');
      await this.patch(id, { phase: recovering ? 'Recovering the result' : PHASE[row.kind], progress: 5 });
      let url = await this.ctx.storage.presignGet(src.key, this.ctx.config.REPLICATE_INPUT_URL_TTL_SEC);
      if (win && needsGpu && p.name !== 'mock' && RANGED_KINDS.includes(row.kind)) {
        // Only the window goes to the provider (it bills the seconds it is sent).
        const cut = path.join(os.tmpdir(), `${uid('edwin')}.${row.kind === 'denoise' ? 'wav' : 'mp4'}`);
        temps.push(cut);
        await this.localSlot();
        try { await this.withLocalInput(src.key, input => trimRange(this.ctx.config.FFMPEG_PATH, input, cut, win, row.kind === 'denoise' ? 'audio' : 'video')); } finally { this.localFree(); }
        windowKey = `t/${uid('edwin')}.${row.kind === 'denoise' ? 'wav' : 'mp4'}`;
        await this.ctx.storage.putStream(windowKey, fs.createReadStream(cut), row.kind === 'denoise' ? 'audio/wav' : 'video/mp4', fs.statSync(cut).size);
        url = await this.ctx.storage.presignGet(windowKey, this.ctx.config.REPLICATE_INPUT_URL_TTL_SEC);
      }
      let result: Record<string, unknown>, gpuSec: number | null = null, rate = 0, spentUsd: number | null = null;
      const transcript = async () => {
        if (reuse) return reuse;
        if (row.models[0] === ASSEMBLY_MODEL) {
          const t = await this.assembly.transcribe(url, d, o.language ?? null, hooks);
          spentUsd = Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(t.usd * this.markup * 10000) / 10000);
          return t;
        }
        const t = await paid(p.rates.transcribe, () => p.transcribe(url, d, o.language ?? null, hooks));
        gpuSec = t.gpuSec; rate = p.rates.transcribe;
        return t;
      };
      if (row.kind === 'captions') {
        const t = await transcript();
        // Captions in a script the export can't draw yet say so (the apps show `exportNotice` with the track).
        const notice = exportNotice(t.language, t.words);
        result = { language: t.language, words: t.words, durationSec: d, reused: !!reuse, ...(notice ? { exportNotice: notice } : {}) };
      } else if (row.kind === 'beats') {
        const samples = await this.withLocalInput(src.key, input => decodeMono(this.ctx.config.FFMPEG_PATH, input));
        await this.patch(id, { progress: 70 });
        result = { ...detectBeats(samples), durationSec: d };
      } else if (row.kind === 'reverse' || row.kind === 'stabilize') {
        // The same source reversed / steadied before (by anyone in the studio) is reused.
        // Stabilise: only with the same strength and zoom.
        const same = (r: Row) => row.kind === 'reverse' || (smoothingOf((r.options as JobOptions).strength) === smoothingOf(o.strength) && ((r.options as JobOptions).zoom ?? 'auto') === (o.zoom ?? 'auto'));
        const prev = (await this.ctx.db.select().from(editorJobs).where(and(eq(editorJobs.studioId, u.studioId), eq(editorJobs.kind, row.kind), eq(editorJobs.mediaKey, src.key), eq(editorJobs.state, 'done'))).orderBy(desc(editorJobs.createdAt)).limit(20)).find(same);
        if (prev?.result) result = { ...(prev.result as Record<string, unknown>), reused: true };
        else {
          // One heavy local ffmpeg job at a time (the 512 MB box).
          await this.localSlot();
          try {
            const info = await this.withLocalInput(src.key, f => probe(this.ctx.config.FFPROBE_PATH, f));
            // The duration a client sends for an upload isn't trusted: it decides how long the job may take.
            const max = row.kind === 'reverse' ? REVERSE_LIMITS.maxSec : STABILIZE_LIMITS.maxSec;
            if (!(info.duration > 0) || info.duration > max + 0.5) throw new ReplicateError(row.kind === 'reverse' ? `Reverse works on videos up to ${max} s` : `Stabilise works on videos up to ${max / 60} minutes`, 'failed');
            const out = path.join(os.tmpdir(), `${uid(row.kind === 'reverse' ? 'rev' : 'stab')}.mp4`);
            file = out;
            await this.withLocalInput(src.key, input => row.kind === 'reverse' ? reverseVideo(this.ctx.config.FFMPEG_PATH, input, out, !!info.audioCodec, info.duration)
              : stabilizeVideo(this.ctx.config.FFMPEG_PATH, input, out, !!info.audioCodec, info.duration, smoothingOf(o.strength), o.zoom ?? 'auto'));
            await this.patch(id, { progress: 90 });
            const asset = await this.store(u, src, out, 'video/mp4', 'video', d);
            result = { asset, width: info.width, height: info.height, hasAudio: !!info.audioCodec, durationSec: d, reused: false };
          } finally { this.localFree(); }
        }
      } else if (isGenjutsuHelper(row.kind)) {
        const out = path.join(os.tmpdir(), `${uid('gj')}.mp4`);
        temps.push(out);
        // The pictures are only signed when a request must start (a resumed one is polled by its saved id).
        await runGenjutsu(this.ctx.suite.providers.higgsfield, row.kind,
          async () => genjutsuHelperInput(row.kind as 'objectswap' | 'restyle', url, await this.genjutsuImages(u, o.images ?? [], this.ctx.config.REPLICATE_INPUT_URL_TTL_SEC), o), out, {
          cancelled: () => this.stopping.has(id), leaving: () => this.leaving, pollMs: this.genjutsuPollMs, timeoutMs: this.genjutsuTimeoutMs, resumeId, onStart: saveHandle,
          onMade: () => { addMade(row.estimate); }, // Higgsfield bills the source seconds the estimate priced
          onProgress: f => this.patch(id, { progress: 5 + f * 85 }).then(() => undefined) });
        const info = await probe(this.ctx.config.FFPROBE_PATH, out).catch(() => null);
        const seconds = info?.duration && info.duration > 0 ? Math.round(info.duration * 1000) / 1000 : Math.min(d, GENJUTSU_LIMITS.maxSec);
        const asset = await this.store(u, src, out, 'video/mp4', 'video', seconds);
        result = { asset, durationSec: seconds, width: info?.width ?? null, height: info?.height ?? null, hasAudio: !!info?.audioCodec, resolution: o.resolution ?? '720p',
          ...(o.presetId ? { presetId: o.presetId } : {}), reused: false };
        spentUsd = row.estimate; // Higgsfield bills the source seconds the estimate priced
      } else if (row.kind === 'slowmo') {
        const prev = await this.slowmoBefore(u.studioId, src.key, o);
        if (prev) { result = { ...(prev.result as Record<string, unknown>), reused: true }; spentUsd = 0; }
        else {
          const r = await this.slowmo(row, u, src, o, temps, { resumeId, onStart: saveHandle, onMade: c => addMade(c != null ? slowmoUsd(c, this.markup) : row.estimate) });
          result = r.result;
          if (r.computeSec != null) spentUsd = slowmoUsd(r.computeSec, this.markup);
        }
      } else if (row.kind === 'cutout') {
        const tracked = !!o.points?.length;
        const c = await this.cutout(u, src, o, url, hooks, temps, paid);
        gpuSec = c.gpuSec; rate = tracked ? p.rates.track : p.rates.matte;
        result = { ...c.result, mode: tracked ? 'tracked' : 'person', ...(tracked ? { points: o.points } : {}) };
      } else if (row.kind === 'separate') {
        const prev = await this.separateBefore(u.studioId, src.key);
        if (prev) { result = { ...(prev.result as Record<string, unknown>), reused: true }; spentUsd = 0; }
        else {
          const out = await paid(p.rates.separate, () => p.separateBoth(url, d, hooks));
          temps.push(...[out.vocals.file, out.instrumental.file].filter((f): f is string => !!f));
          gpuSec = out.gpuSec; rate = p.rates.separate;
          const vocals = await this.store(u, src, out.vocals.file, out.vocals.contentType, 'audio', d);
          const instrumental = await this.store(u, src, out.instrumental.file, out.instrumental.contentType, 'audio', d);
          result = { vocals, instrumental, durationSec: d, reused: false };
        }
      } else if (row.kind === 'translate') {
        const q = o.quality ?? 'standard';
        const progress = (f: number) => this.patch(id, { progress: 5 + f * 90 }).then(() => undefined);
        const t = o.lines ? await translateAppLines(this.translator()!, o.lines, o.sourceLanguage ?? null, o.targetLanguage!, q, progress)
          : await translateWords(this.translator()!, reuse!.words, o.targetLanguage!, q, progress);
        spentUsd = translateUsd(q, t.usage, this.markup);
        // lines: each caption line (the app's ids when it sent its own), its text and time, translated or kept as it was.
        const lines = t.lines.map(l => ({ ...('id' in l ? { id: l.id } : {}), text: l.text, startSec: l.startSec, endSec: l.endSec, translated: l.translated }));
        result = { language: o.targetLanguage, sourceLanguage: o.lines ? o.sourceLanguage ?? null : reuse!.language, words: t.words, lines, untranslatedLines: t.missing, quality: q, durationSec: d };
      } else if (row.kind === 'cuts' && o.silenceOnly) {
        const minSilenceSec = o.minSilenceSec ?? CUT_DEFAULTS.minSilenceSec, keepPadSec = o.keepPadSec ?? CUT_DEFAULTS.keepPadSec;
        const sil = await this.withLocalInput(src.key, input => detectSilences(this.ctx.config.FFMPEG_PATH, input, d, { minSilenceSec, noiseDb: o.noiseDb }));
        await this.patch(id, { progress: 90 });
        result = { ...silenceCuts(sil, d, { minSilenceSec, keepPadSec }), words: [], options: { ...CUT_DEFAULTS, ...o }, durationSec: d };
      } else if (row.kind === 'cuts') {
        const t = await transcript();
        const s = suggestCuts(t.words, d, o);
        result = { ...s, words: t.words, language: t.language, options: { ...CUT_DEFAULTS, ...o }, durationSec: d };
      } else if (row.kind === 'layers') {
        const prev = await this.layersBefore(u.studioId, src.key, o.objects!, src.source.range);
        if (prev) result = { ...(prev.result as Record<string, unknown>), reused: true };
        else {
          const out: Record<string, unknown>[] = [], objs = o.objects!;
          let billed = 0, known = true;
          for (let k = 0; k < objs.length; k++) {
            const ob = objs[k]!;
            const part: Hooks = { ...hooks, onProgress: async (f, ph) => { await hooks.onProgress?.((k + f) / objs.length, ph ? `${ph} · ${ob.name}` : `Finding ${ob.name}`); } };
            const pts = await this.pixelPoints(src.key, ob.points, src.size, p.name === 'mock', win?.startSec ?? 0);
            const fps = await this.sourceFps(src.key, src.size);
            const made = await paid(p.rates.track, () => p.track(url, d, pts, part, { fps }));
            if (made.file) temps.push(made.file);
            if (made.gpuSec == null) known = false; else billed += made.gpuSec;
            const matte = await toSource(made.file && p.name !== 'mock' ? await this.alignMatte(made.file, d, temps, id) : made.file, 'video');
            // Where the object is over time, for pinned text (best effort: a layer without it just can't take a pin).
            const boxes = matte ? await matteBoxes(this.ctx.config.FFMPEG_PATH, matte).catch(e => { this.ctx.log.warn({ err: (e as Error).message, job: id }, 'layer boxes failed'); return null; }) : null;
            const warning = boxes ? coverageWarning(ob, boxes, LAYERS_LIMITS.trackFps) : null;
            const asset = await this.store(u, src, matte, made.contentType, 'video', full);
            out.push({ name: ob.name, asset, ...(boxes ? { track: { fps: LAYERS_LIMITS.trackFps, boxes } } : {}), ...(warning ? { warning } : {}) });
          }
          gpuSec = known ? billed : null; rate = p.rates.track;
          // aligned: the mattes run at the source's length (results from before this fix aren't reused).
          result = { layers: out, durationSec: full, reused: false, aligned: true, ...(win ? { window: win } : {}) };
        }
      } else if (row.kind === 'matte' || (row.kind === 'denoise' && !o.analyzeOnly)) {
        const tracked = row.kind === 'matte' && !!o.points?.length;
        const pts = tracked ? await this.pixelPoints(src.key, o.points!, src.size, p.name === 'mock', win?.startSec ?? 0) : [];
        const trackFps = tracked ? await this.sourceFps(src.key, src.size) : undefined;
        const out = row.kind !== 'matte' ? await paid(p.rates.separate, () => p.separate(url, d, hooks))
          : tracked ? await paid(p.rates.track, () => p.track(url, d, pts, hooks, { fps: trackFps })) : await paid(p.rates.matte, () => p.matte(url, d, hooks));
        if (tracked && out.file && p.name !== 'mock') { temps.push(out.file); out.file = await this.alignMatte(out.file, d, temps, id); }
        file = out.file; gpuSec = out.gpuSec; rate = row.kind !== 'matte' ? p.rates.separate : tracked ? p.rates.track : p.rates.matte;
        const placed = await toSource(out.file, row.kind === 'matte' ? 'video' : 'audio');
        const asset = await this.store(u, src, placed, placed !== out.file ? (row.kind === 'matte' ? 'video/mp4' : 'audio/wav') : out.contentType, row.kind === 'matte' ? 'video' : 'audio', full);
        // workstream 1: an alpha matte (white = keep) the apps apply to the original clip; no green composite, no chroma key.
        result = row.kind === 'matte'
          ? { asset, alpha: true, mode: tracked ? 'tracked' : 'person', ...(tracked ? { points: o.points } : {}), ...(win ? { window: win } : {}) }
          : { asset, suggestion: noiseSuggestion((await this.transcriptFor(u, src.key, {}).catch(() => null))?.words ?? []) };
      } else {
        result = { suggestion: noiseSuggestion(reuse?.words ?? []) };
      }
      // A cancel that arrives after the provider made the result doesn't throw the paid result away.
      if (this.stopping.has(id) && !made) throw new ReplicateError('Cancelled', 'cancelled');
      if (!(await this.owns(id))) return; // another server instance resumed it after a deploy
      const billed = spentUsd != null ? spentUsd : !needsGpu ? 0 : gpuSec != null ? Math.max(EDITOR_LIMITS.minChargeUsd, Math.round(gpuSec * rate * this.markup * 10000) / 10000) : row.estimate;
      // The owner's rule (ci_238dd2979f5a): never charge more than the approved estimate. A provider that billed more is
      // MUSE's cost: the excess goes on studio overhead and is logged.
      const actual = row.estimate > 0 ? Math.min(billed, row.estimate) : billed;
      if (billed - actual > 1e-9) {
        this.ctx.log.warn({ job: id, kind: row.kind, estimateUsd: row.estimate, billedUsd: billed, gpuSec, sourceSec: d }, 'editor job ran over its estimate · charged the estimate');
        await this.ctx.money.overhead(u.studioId, Math.round((billed - actual) * 10000) / 10000, `Edit ${row.kind} ran over its estimate (job ${id})`).catch(() => {});
      }
      if (row.holdTokens || actual > 0) await this.ctx.money.settle(u.studioId, u.id, id, row.holdTokens, actual, `Editor ${row.kind}`);
      await this.patch(id, { state: 'done', progress: 100, phase: 'Done', result, cost: actual, finishedAt: Date.now() });
    } catch (e) {
      if (e instanceof StepBack || this.leaving) { this.ctx.log.info({ job: id }, 'editor job left for the next server instance'); return; }
      if (!(await this.owns(id).catch(() => true))) return; // another server instance resumed it after a deploy
      const lost = e instanceof PaidLost ? e : made ? new PaidLost('unsaved', 1, (e as Error).message) : null;
      if (lost) { await this.paidLost(row, u, lost, (made as { usd: number } | null)?.usd ?? row.estimate); return; }
      const cancelled = e instanceof ReplicateError && e.kind === 'cancelled';
      if (row.holdTokens) await this.ctx.money.release(u.studioId, u.id, id, row.holdTokens, cancelled ? 'editor job cancelled' : 'editor job failed').catch(() => {});
      if (!cancelled) this.ctx.log.warn({ err: (e as Error).message, job: id, kind: row.kind }, 'editor job failed');
      const msg = cancelled ? 'Cancelled' : e instanceof ReplicateError && e.message === GENJUTSU_NO_ACCESS ? GENJUTSU_NO_ACCESS
        : e instanceof ReplicateError && /^Higgsfield/.test(e.message) && e.kind !== 'refused' ? `${e.message.replace(/https?:\/\/\S+/g, '<link>').slice(0, 300)} · you weren't charged` : e instanceof ReplicateError && e.kind === 'refused' ? 'This video was refused by the safety check'
        : e instanceof ReplicateError && e.kind === 'out_of_credit' ? 'The studio is out of AI credit · ask the owner'
        : e instanceof TranslateError ? (e.kind === 'refused' ? 'These captions couldn’t be translated · you weren’t charged' : 'Couldn’t translate these captions this time · you weren’t charged')
        : e instanceof ReplicateError && (row.kind === 'reverse' || row.kind === 'stabilize' || row.kind === 'slowmo') && /^(Reverse|Stabilise|Slow motion) works/.test(e.message) ? e.message : 'Something went wrong · try again';
      await this.patch(id, { state: cancelled ? 'cancelled' : 'failed', phase: msg, error: msg, finishedAt: Date.now() }).catch(() => {});
    } finally {
      rmQuiet(file);
      for (const t of temps) rmQuiet(t);
      if (windowKey) await this.ctx.storage.delete(windowKey).catch(() => {});
      this.stopping.delete(id);
      if (needsGpu) this.free();
    }
  }

  /**
   * Smooth slow motion: the range cut here (one local ffmpeg job at a time), stored for fal to fetch, interpolated by
   * fal, then retimed here to play at the source's frame rate. The cut sent to fal is deleted again whatever happens.
   */
  private async slowmo(row: Row, u: AuthUser, src: { key: string; source: EditorSource }, o: JobOptions, temps: string[],
    run: { resumeId: string | null; onStart: (id: string) => Promise<void>; onMade: (computeSec: number | null) => void }) {
    const ffmpeg = this.ctx.config.FFMPEG_PATH, ffprobe = this.ctx.config.FFPROBE_PATH, factor = o.factor!, cancelled = () => this.stopping.has(row.id);
    const cut = path.join(os.tmpdir(), `${uid('slowcut')}.mp4`), raw = path.join(os.tmpdir(), `${uid('slowraw')}.mp4`), out = path.join(os.tmpdir(), `${uid('slow')}.mp4`);
    temps.push(cut, raw, out);
    let info: Awaited<ReturnType<typeof probe>>;
    await this.localSlot();
    try {
      info = await this.withLocalInput(src.key, f => probe(ffprobe, f));
      // The duration a client sends for an upload isn't trusted.
      if (!(info.duration > 0) || o.endSec! > info.duration + 0.05) throw new ReplicateError(`Slow motion works on a range inside the clip (0–${Math.floor((info.duration || 0) * 10) / 10} s)`, 'failed');
      await this.withLocalInput(src.key, input => cutRange(ffmpeg, input, cut, o.startSec!, o.endSec!, info.fps));
    } finally { this.localFree(); }
    const rangeSec = (await probe(ffprobe, cut)).duration || o.endSec! - o.startSec!;
    await this.patch(row.id, { progress: 15 });
    // The cut is uploaded for fal only when a request must start (a resumed one is polled by its saved id).
    const key = `t/${uid('slowin')}.mp4`;
    let uploaded = false, computeSec: number | null;
    try {
      ({ computeSec } = await falInterpolate(this.fal, async () => {
        await this.ctx.storage.putStream(key, fs.createReadStream(cut), 'video/mp4', fs.statSync(cut).size);
        uploaded = true;
        return this.ctx.storage.presignGet(key, 3600);
      }, factor, raw, { cancelled, leaving: () => this.leaving, pollMs: this.falPollMs, resumeId: run.resumeId, onStart: run.onStart, onMade: (_u, c) => run.onMade(c),
        onProgress: f => this.patch(row.id, { progress: 15 + f * 70 }).then(() => undefined) }));
    } finally { if (uploaded) await this.ctx.storage.delete(key).catch(() => {}); }
    // From here fal has made (and billed) it: a late cancel no longer throws it away.
    const got = await probe(ffprobe, raw);
    if (!(got.duration > 0)) throw new ReplicateError('Slow motion came back empty', 'failed');
    const seconds = Math.round(rangeSec * factor * 1000) / 1000, fps = Math.min(info.fps || 30, SLOWMO_LIMITS.maxFps);
    await this.localSlot();
    try { await retime(ffmpeg, raw, out, got.duration, seconds, fps); } finally { this.localFree(); }
    await this.patch(row.id, { progress: 92 });
    const asset = await this.store(u, src, out, 'video/mp4', 'video', seconds);
    const fin = await probe(ffprobe, out).catch(() => null);
    return {
      computeSec,
      result: { asset, factor, startSec: o.startSec, endSec: o.endSec, fps, width: fin?.width ?? got.width, height: fin?.height ?? got.height, hasAudio: false, durationSec: seconds, reused: false } as Record<string, unknown>,
    };
  }

  /** The media as something ffmpeg can read: a presigned URL on R2, else a temporary copy of the local object. */
  /** The stored media as a local path (or a short-lived URL on S3) for ffmpeg; temporary copies are removed after. */
  /** The source's frame rate (known from the take, else probed; 30 when unknown). */
  private async sourceFps(key: string, known: { fps?: number } | undefined): Promise<number> {
    if (known?.fps) return known.fps;
    const info = await this.withLocalInput(key, f => probe(this.ctx.config.FFPROBE_PATH, f)).catch(() => null);
    return info?.fps || 30;
  }
  /** A tracked matte retimed to the source's length when the tracker made it at another frame rate (layers.ts retimeMatte). */
  private async alignMatte(file: string, d: number, temps: string[], job: string): Promise<string> {
    const out = path.join(os.tmpdir(), `${uid('matte')}.mp4`);
    await this.localSlot();
    try {
      const done = await retimeMatte(this.ctx.config.FFMPEG_PATH, this.ctx.config.FFPROBE_PATH, file, d, out);
      if (done) { temps.push(done); this.ctx.log.info({ job }, 'tracked matte retimed to the source length'); return done; }
      return file;
    } catch (e) {
      this.ctx.log.warn({ err: (e as Error).message, job }, 'retiming the matte failed (kept as made)');
      return file;
    } finally { this.localFree(); }
  }
  /** Tap points (0–1, seconds) → pixels and frame numbers of the source (workstream 1). The mock may guess the size. */
  private async pixelPoints(key: string, points: KeepPoint[], known: { width: number; height: number; fps?: number } | undefined, mock: boolean, startSec = 0): Promise<TrackPoint[]> {
    const info = known ?? await this.withLocalInput(key, f => probe(this.ctx.config.FFPROBE_PATH, f)).catch(() => null);
    const w = info?.width || (mock ? 1080 : 0), h = info?.height || (mock ? 1920 : 0), fps = info?.fps || 30;
    if (!w || !h) throw new ReplicateError('Couldn’t read the video', 'failed');
    // A job on a window (range.ts) sends frames from its start: a tap at source t is frame (t − start) × fps there.
    return points.map(q => ({ x: q.x * (w - 1), y: q.y * (h - 1), frame: Math.max(0, Math.round((q.t - startSec) * fps)), keep: q.keep }));
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

  /** Tests: how often Higgsfield is polled for a Genjutsu helper, and how long before a cancel is asked. */
  genjutsuPollMs = 3000;
  genjutsuTimeoutMs = 30 * 60_000;

  /** Whether this instance still runs the job (false: another instance resumed it after a deploy and finishes it). */
  private async owns(id: string) {
    const [r] = await this.ctx.db.select({ options: editorJobs.options, state: editorJobs.state }).from(editorJobs).where(eq(editorJobs.id, id));
    const by = (r?.options as { runner?: string } | undefined)?.runner;
    return !!r && r.state === 'running' && (!by || by === this.instance);
  }

  /**
   * The provider made (and billed) the result, or may still, and it isn't saved. The member's hold goes back (they get
   * nothing). Genjutsu and slow motion keep their request id: the owner recovers them for free (recoverJob), and the
   * provider's cost waits for that. Replicate helpers can't be fetched again: their cost goes on studio overhead now.
   */
  private async paidLost(row: Row, u: AuthUser, e: PaidLost, usd: number) {
    const [fresh] = await this.ctx.db.select().from(editorJobs).where(eq(editorJobs.id, row.id));
    const recoverable = (isGenjutsuHelper(row.kind) || row.kind === 'slowmo') && !!fresh?.predictionId;
    if (row.holdTokens) await this.ctx.money.release(u.studioId, u.id, row.id, row.holdTokens, 'editor result made but not saved').catch(() => {});
    if (!recoverable && usd > 1e-9) await this.ctx.money.overhead(u.studioId, usd, `Edit ${row.kind} made but not saved`).catch(() => {});
    const f = paidLostFailure(e);
    const msg = recoverable ? f.message : 'The result was made but MUSE couldn’t save it · you weren’t charged (the studio paid for it) · try again';
    this.ctx.log.error({ job: row.id, kind: row.kind, why: e.why, usd }, 'editor job: provider result paid but not saved');
    await this.patch(row.id, { state: 'failed', phase: msg, error: msg, finishedAt: Date.now(), holdTokens: 0,
      result: { errorCode: recoverable ? f.code : 'provider_paid_lost', paid: { usd, recoverable, kind: e.kind, why: e.why.slice(0, 300) } } }).catch(() => {});
    if (recoverable) await reportPaidLost(this.ctx, { id: row.id, studioId: row.studioId, userId: row.userId } as JobRow, `Edit ${row.kind}`, e, 'editor')
      .catch(err => this.ctx.log.warn({ err: (err as Error).message }, 'editor: could not record the issue'));
  }

  /** The job's person, as the run needs them (money is held and settled on them). */
  private async userOf(row: Row): Promise<AuthUser> {
    const [x] = await this.ctx.db.select({ role: users.role, email: users.email }).from(users).where(eq(users.id, row.userId));
    return { id: row.userId, studioId: row.studioId, email: x?.email ?? '', role: (x?.role as AuthUser['role']) ?? 'member', studioName: '', sessionId: null };
  }

  /** Runs a saved Genjutsu / slow-motion request again on this instance: polls its id, never a new paid start. */
  private async relaunch(row: Row) {
    const [r] = await this.ctx.db.update(editorJobs).set({ options: { ...(row.options ?? {}), runner: this.instance } }).where(eq(editorJobs.id, row.id)).returning() as Row[];
    const u = await this.userOf(r!);
    void this.run(r!, u, { key: r!.mediaKey!, contentType: '', source: r!.source }, null, true);
  }

  /**
   * Owner, free: an Edit helper (Genjutsu restyle / object swap, slow motion) that failed after the provider made its
   * result (errorCode provider_paid_unsaved / provider_unconfirmed) is fetched again by its saved request id. Never a
   * new generation. The member is charged as usual once it is saved.
   */
  async recoverJob(u: AuthUser, id: string) {
    if (u.role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can do that');
    const [r] = await this.ctx.db.select().from(editorJobs).where(and(eq(editorJobs.id, id), eq(editorJobs.studioId, u.studioId)));
    if (!r) throw notFound('Job');
    if (r.state === 'running') return { ok: true, state: 'running', job: id };
    const paid = (r.result as { paid?: { recoverable?: boolean } } | null)?.paid;
    if (r.state !== 'failed' || !paid?.recoverable || !r.predictionId) throw badRequest('Nothing to recover: no saved provider request for this job');
    const [row] = await this.ctx.db.update(editorJobs).set({ state: 'running', error: null, finishedAt: null, holdTokens: 0, phase: 'Recovering the result', result: { recovering: true } })
      .where(and(eq(editorJobs.id, id), eq(editorJobs.state, 'failed'))).returning() as Row[];
    if (!row) throw badRequest('This job changed · try again');
    this.emit(row);
    await this.relaunch(row);
    return { ok: true, state: 'recovering', job: id };
  }
  private presetCache: { at: number; list: { id: string; name: string; preview?: string | null }[] } | null = null;
  /** Restyle's presets from Higgsfield (free; cached 6 h; an empty list when it can't be read). */
  async restylePresets() {
    const hf = this.ctx.suite.providers.higgsfield as { genjutsuPresets?: () => Promise<{ access: string; presets: { id: string; name: string; preview?: string | null }[] }> };
    if (!this.ctx.suite.providers.higgsfield.configured() || !hf.genjutsuPresets) return [];
    if (this.presetCache && Date.now() - this.presetCache.at < 6 * 3600_000) return this.presetCache.list;
    const r = await hf.genjutsuPresets().catch(() => null);
    if (r?.access === 'yes') this.presetCache = { at: Date.now(), list: r.presets };
    return r?.presets ?? [];
  }
  /** $ per source second as charged (× the editor markup), per resolution. */
  private genjutsuRates(kind: 'objectswap' | 'restyle') {
    return Object.fromEntries(Object.entries(GENJUTSU_HELPERS[kind].perSec).map(([k, v]) => [k, Math.round(v * this.markup * 10000) / 10000]));
  }
  /** The helper's pictures as short-lived URLs (uploads checked against the studio; no EXIF/GPS reaches Higgsfield). */
  private async genjutsuImages(u: AuthUser, imgs: GenjutsuImage[], ttl: number) {
    const out: string[] = [];
    for (const [i, x] of imgs.entries()) {
      if (x.uploadId) {
        const [up] = await this.ctx.db.select().from(uploads).where(and(eq(uploads.id, x.uploadId), eq(uploads.studioId, u.studioId)));
        if (!up || !/^image\//.test(up.contentType)) throw badRequest(`options.images[${i}]: an image upload of this studio`);
        if (!(await this.ctx.storage.head(up.storageKey))) throw new ApiError(409, 'upload_missing', 'The picture has not arrived yet · upload it first');
        if (up.state !== 'ready') await cleanUploadedPhoto(this.ctx, up);
        out.push(await this.ctx.storage.presignGet(up.storageKey, ttl));
        continue;
      }
      const key = await this.ctx.images.storedKey(x, u.studioId);
      if (key) { out.push(await this.ctx.storage.presignGet(key, ttl)); continue; }
      if (x.url && /^https:\/\//.test(x.url)) { out.push(x.url); continue; }
      throw badRequest(`options.images[${i}]: a picture MUSE can read`);
    }
    return out;
  }

  /** Stores a produced file as an upload of the studio (bytes copied, never re-encoded); the mock points at the source. */
  private async store(u: AuthUser, src: { key: string; source: EditorSource }, file: string | null, contentType: string, kind: 'video' | 'audio' | 'image', durationSec: number) {
    if (!file) return { kind, ...(src.source.takeId ? { take: src.source.takeId } : { upload: src.source.uploadId }), url: `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${src.key}`, durationSec };
    const ext = contentType === 'image/png' ? 'png' : contentType === 'video/mp4' ? 'mp4' : contentType === 'audio/wav' ? 'wav' : contentType === 'audio/flac' ? 'flac' : contentType === 'audio/mp4' ? 'm4a' : 'mp3';
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
      // Genjutsu / slow motion with a saved request: polled again (never started, never paid twice). Its hold stays.
      if ((isGenjutsuHelper(r.kind) || r.kind === 'slowmo') && r.predictionId && r.mediaKey) {
        this.ctx.log.info({ job: r.id, kind: r.kind }, 'editor job resumed after a restart');
        await this.relaunch(r).catch(e => this.ctx.log.warn({ job: r.id, err: (e as Error).message }, 'editor resume failed'));
        continue;
      }
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
      stabilize: { available: await this.stabilizeAvailable(), free: true, maxSec: STABILIZE_LIMITS.maxSec },
      separate: { available: paid && this.matteAvailable },
      cutout: { available: paid && this.matteAvailable, maxPoints: MAX_KEEP_POINTS },
      layers: { available: paid && this.matteAvailable, maxSec: LAYERS_LIMITS.maxSec, maxObjects: LAYERS_LIMITS.maxObjects, askAboveUsd: LAYERS_LIMITS.askAboveUsd },
      slowmo: { available: paid && await this.slowmoAvailable(), factors: [2, 4], maxRangeSec: SLOWMO_LIMITS.maxRangeSec },
      translate: { available: paid && !!this.translator(), languages: translateTargets(), qualities: ['standard', 'best'], maxWords: TRANSLATE_LIMITS.maxWords, maxLines: TRANSLATE_LIMITS.maxLines, maxLineChars: TRANSLATE_LIMITS.maxLineChars },
      objectswap: { available: paid && this.ctx.suite.providers.higgsfield.configured(), minSec: GENJUTSU_LIMITS.minSec, maxSec: GENJUTSU_LIMITS.maxSec, maxImages: GENJUTSU_HELPERS.objectswap.maxImages,
        resolutions: [...GENJUTSU_LIMITS.resolutions], perSec: this.genjutsuRates('objectswap'), note: 'Swaps an object in the video for the one in your pictures (1–8); prompt optional. First 30 s only.' },
      restyle: { available: paid && this.ctx.suite.providers.higgsfield.configured(), minSec: GENJUTSU_LIMITS.minSec, maxSec: GENJUTSU_LIMITS.maxSec, maxImages: GENJUTSU_HELPERS.restyle.maxImages,
        resolutions: [...GENJUTSU_LIMITS.resolutions], perSec: this.genjutsuRates('restyle'), presets: paid ? await this.restylePresets() : [], note: 'The whole video in a preset look (options.presetId). First 30 s only.' },
      maxSourceSec: EDITOR_LIMITS.maxSourceSec,
    };
  }
}
