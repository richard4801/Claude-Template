// Video on Replicate (engine "replicate", plans/backend.md "Replicate"): the Replicate line and one job's run.
//
// The dispatcher hands waiting replicate jobs here instead of to the pod pool. At most REPLICATE_MAX_CONCURRENT run at
// once (FIFO across the studio). A run: download the source → pad it to D whole seconds → upload the padded clip →
// one prediction per take (429s waited out) → download each output at once → cut it back to the exact source length
// with the source's audio → thumbnail → store → complete (settle on the seconds Replicate billed). Prediction ids are
// saved on the job (stats.replicate) as soon as they exist, so a restart resumes polling rather than paying twice.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { and, eq, sql } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { clips, jobs, type ImageRef } from '../db/schema.js';
import * as P from '../pricing.js';
import { outputUrl, ReplicateError, SAFETY_RE, CREDIT_RE, errorText, type Prediction } from '../replicate/client.js';
import { OUT_OF_CREDIT } from '../images/service.js';
import { SOMETHING_WENT_WRONG } from './jobs.js';
import { badRequest } from '../errors.js';
import { PaidLost, paidLostFailure, reportPaidLost, sleep } from './paidLost.js';
import { mediaToolsAvailable, padTo, probe, restoreAudio, stripAudio, thumbnail } from '../replicate/media.js';
import { putFile } from '../storage/objects.js';
import type { JobRow } from '../gpu/controller.js';
import { modelById } from '../suite/registry.js';
import { GENJUTSU_NO_ACCESS, GENJUTSU_RES, HF_SWAP_MIN_SEC, swapEngineById } from '../engines/purposes.js';
import type { VideoProvider } from '../suite/providers.js';

type Line = Pick<Ctx['replicate'], 'create' | 'get' | 'cancel' | 'download'>;
/** Which provider a take's prediction lives on (saved with its id, so a restart polls the right one). */
type LineId = 'replicate' | 'higgsfield';
/**
 * Higgsfield (the owner's H3 plan) behind the hosted line's calls: start → status (a GET) → the video. A failed status
 * comes back as a failed prediction carrying the provider's own error (out of credit, refused, failed), so the job reads
 * it as it reads Replicate's. The line never waits or times out itself: the run polls (services/replicateVideo.ts).
 */
export function higgsfieldLine(hf: VideoProvider): Line {
  return {
    create: async (ref, input, o) => ({ id: await hf.start(ref, input, { cancelled: () => false, seconds: Number(input.duration) || undefined, onWait: o.onWait }), status: 'starting' }) as Prediction,
    get: async (id: string): Promise<Prediction> => {
      const s = await hf.get(id);
      if (s.status === 'failed') return { id, status: 'failed', error: s.error ?? new ReplicateError('Higgsfield failed', 'failed') };
      return { id, status: s.status === 'running' ? 'processing' : s.status, output: s.url ?? undefined, metrics: s.billedSeconds ? { video_output_duration_seconds: s.billedSeconds } : {} };
    },
    cancel: id => hf.cancel(id),
    download: (url, file) => hf.download(url, file),
  } as Line;
}

/**
 * Genjutsu motion transfer's input (docs.higgsfield.ai/docs/models/genjutsu/motion-transfer): the clip, her pictures (≤ 8,
 * face first), the swap prompt as plain direction (Genjutsu reads "image 1", not H3's <Image 1> tokens), the resolution.
 */
export function genjutsuInput(videoUrl: string, imageUrls: string[], prompt: string | null | undefined, resolution: string) {
  const text = (prompt ?? '').replace(/<Image (\d+)>/g, 'image $1').replace(/<Video 1>/g, 'the source video').replace(/<Video (\d+)>/g, 'video $1').slice(0, 10000);
  return { video_url: videoUrl, image_urls: imageUrls.slice(0, 8), ...(text.trim() ? { prompt: text } : {}), resolution };
}

/** WS13: the resolution a chosen hosted swap model runs a quality at (its own list; H3 Lite has no 2K). */
function swapResolution(id: string, quality: P.Quality) {
  const m = modelById(id), want = P.QUALITY_INFO[quality].resolution;
  return m?.resolutions.find(r => r.id === want)?.id ?? m?.resolutions.at(-1)?.id ?? want;
}

/** The pod id replicate jobs are claimed under (no pod row exists for it). */
export const REPLICATE_POD = 'replicate';
export const REFUSED_CLIP = "This clip was refused by the content filter · you weren't charged";
/** The provider made it (and billed the studio), then refused or returned nothing usable: honest, never "not charged". */
export const REFUSED_PAID = "The result was refused by the content filter after it was made · the provider charged the studio";
export const FAILED_PAID = "The provider finished but sent back nothing usable · it charged the studio";

type TakeState = { id?: string; /** Where the prediction lives (older jobs: guessed from the id). */ provider?: LineId; done?: boolean; key?: string; thumbKey?: string;
  billed?: number; output?: Record<string, unknown>;
  /** When the prediction was made (the timeout counts from here, across restarts). */ startedAt?: number;
  /** Our timeout asked the provider to cancel at this time. */ cancelAsked?: number;
  /** The provider finished: it is paid for from here on, whatever happens on our side. */ paid?: boolean; result?: { url: string; billed?: number | null; at: number } };
type RunState = { paddedKey?: string; seconds?: number; muted?: boolean; takes: TakeState[]; /** Reference images sent (Higgsfield bills those beyond 5). */ images?: number;
  /** The owner asked to recover a paid result: only saved predictions are polled, nothing is started. */ recovering?: boolean; lost?: { take: number; kind: string; why: string; at: number } };
type Running = { cancelled: boolean; predictions: Map<string, LineId>; done: Promise<void> };
/** What starting a take needs (only made when a take must start). */
type Start = { onHf: boolean; gj: boolean; model: string; input: Record<string, unknown>; replicateInput: Record<string, unknown>; imageUrls: string[] };
/** The clip and how its sound is handled (needed to start, and by finishing to put the sound back). */
type Source = { src: string; info: Awaited<ReturnType<typeof probe>>; D: number; muteSource: boolean; gj: { minSec: number; maxSec: number; maxImages: number } | null };
const lineOf = (ts: TakeState): LineId => ts.provider ?? (ts.id?.startsWith('{') ? 'higgsfield' : 'replicate');
/** A failed prediction's error (Higgsfield's line carries its own ReplicateError). */
const failedError = (p: Prediction) => (p.error instanceof ReplicateError ? p.error : predictionError(p));

/** Why a run failed, for the job: a member-safe message shown as-is and the machine code (the details go to the log). */
export function failureOf(e: unknown): { message: string; code: string; retryable: boolean } {
  if (e instanceof ReplicateError) {
    if ((e as { paid?: boolean }).paid) return e.kind === 'refused' ? { message: REFUSED_PAID, code: 'provider_refused', retryable: false } : { message: FAILED_PAID, code: 'provider_failed', retryable: false };
    if (e.kind === 'refused') return { message: REFUSED_CLIP, code: 'provider_refused', retryable: false };
    if (e.kind === 'rate_limited') return { message: "Busy right now · you weren't charged. Try again in a minute.", code: 'provider_rate_limited', retryable: true };
    if (e.kind === 'timeout') return { message: "This took too long and was stopped · you weren't charged", code: 'provider_timeout', retryable: true };
    if (e.kind === 'out_of_credit') return { message: OUT_OF_CREDIT, code: 'provider_out_of_credit', retryable: true };
    if (e.kind === 'unavailable' && e.message === GENJUTSU_NO_ACCESS) return { message: GENJUTSU_NO_ACCESS, code: 'provider_no_access', retryable: false };
    if (e.kind === 'unavailable') return { message: SOMETHING_WENT_WRONG, code: 'provider_failed', retryable: false };
    return { message: SOMETHING_WENT_WRONG, code: 'provider_failed', retryable: true };
  }
  return { message: SOMETHING_WENT_WRONG, code: 'provider_failed', retryable: true };
}

/** A failed prediction → the error to throw (safety refusals are told apart). */
export function predictionError(p: Prediction) {
  const t = errorText(p.error);
  if (SAFETY_RE.test(t)) return new ReplicateError(t, 'refused');
  if (CREDIT_RE.test(t)) return new ReplicateError(t, 'out_of_credit');
  return new ReplicateError(t || 'the prediction failed', 'failed');
}

export class ReplicateVideo {
  private running = new Map<string, Running>();
  private stopping = false;
  /** This server instance, for the job lease (two instances overlap during a Railway deploy). */
  private readonly instance = `${os.hostname()}:${process.pid}:${Math.random().toString(36).slice(2, 10)}`;
  constructor(private ctx: Ctx) {}

  get configured() { return this.ctx.replicate.configured; }
  busy() { return this.running.size > 0; }
  async toolsReady() { return mediaToolsAvailable(this.ctx.config.FFMPEG_PATH, this.ctx.config.FFPROBE_PATH); }
  /** Waits for every run in this process to stop (tests). */
  async idle() { await Promise.all([...this.running.values()].map(r => r.done)); }
  /** The same lease and stop timing as the AI Suite line (SUITE_LEASE_SEC, SUITE_STOP_WAIT_SEC). */
  private leaseMs() { return Math.max(1, this.ctx.config.SUITE_LEASE_SEC) * 1000; }
  private lines(): Record<LineId, Line> { return { replicate: this.ctx.replicate, higgsfield: higgsfieldLine(this.ctx.suite.providers.higgsfield) }; }

  /**
   * Shutdown (a deploy or restart): no new runs; running ones step back at their next poll WITHOUT failing or cancelling
   * anything at the provider. Their jobs stay running with the prediction ids saved, and the next server instance
   * resumes polling them. Waits at most SUITE_STOP_WAIT_SEC.
   */
  async stop() {
    this.stopping = true;
    let t: NodeJS.Timeout | undefined;
    await Promise.race([this.idle(), new Promise<void>(r => { t = setTimeout(r, Math.max(0, this.ctx.config.SUITE_STOP_WAIT_SEC) * 1000); t.unref?.(); })]);
    if (t) clearTimeout(t);
  }

  /**
   * One dispatcher pass for the Replicate line. `waiting`: replicate jobs waiting, oldest first. Claimed jobs nobody
   * here is running (after a restart) are resumed first, unless another instance still holds their lease; then free
   * slots take the oldest waiting jobs.
   */
  async dispatch(waiting: JobRow[]) {
    if (this.stopping) return;
    const orphans = await this.ctx.db.select().from(jobs).where(and(eq(jobs.state, 'running'), eq(jobs.gpuState, 'claimed'), eq(jobs.podId, REPLICATE_POD)));
    for (const j of orphans) {
      if (this.running.has(j.id)) continue;
      // Another instance still checks in on it (the old one during a deploy's overlap): leave it there.
      const l = (j.stats as any)?.replicateLease as { by?: string; at?: number } | undefined;
      if (l?.by && l.by !== this.instance && Date.now() - (l.at ?? 0) < this.leaseMs()) continue;
      this.ctx.log.info({ job: j.id }, 'Replicate job resumed');
      this.launch(j);
    }
    const max = Math.max(1, Math.floor(this.ctx.config.REPLICATE_MAX_CONCURRENT));
    const line: JobRow[] = [];
    for (const j of waiting) {
      if (this.running.size < max) {
        const c = await this.ctx.jobs.claim(j.id, REPLICATE_POD);
        if (c) { this.launch(c); continue; }
      }
      line.push(j);
    }
    // Queue position and ETA: each slot frees after the running job's estimate; the line moves one job per slot.
    if (!line.length) return;
    const per = (j: JobRow) => j.totalSeconds || P.totalSeconds(j.request);
    const left = (await this.ctx.db.select({ s: jobs.secondsLeft }).from(jobs)
      .where(and(eq(jobs.state, 'running'), eq(jobs.gpuState, 'claimed'), eq(jobs.podId, REPLICATE_POD)))).map(x => x.s);
    const soonest = left.length ? Math.min(...left) : 0;
    const avg = line.reduce((a, j) => a + per(j), 0) / line.length;
    const startsIn = (i: number) => soonest + Math.floor(i / max) * avg;
    for (const [i, j] of line.entries()) await this.ctx.jobs.setLinePosition(j, i + 1, startsIn(i));
  }

  /** The member cancelled: stop, and cancel each running prediction on the provider it runs on. */
  cancel(jobId: string) {
    const r = this.running.get(jobId);
    if (!r) return;
    r.cancelled = true;
    const lines = this.lines();
    for (const [id, l] of r.predictions) void lines[l].cancel(id);
  }

  private launch(job: JobRow) {
    const st: Running = { cancelled: false, predictions: new Map(), done: Promise.resolve() };
    this.running.set(job.id, st);
    const beat = setInterval(() => { void this.lease(job.id).catch(() => {}); }, Math.max(50, this.leaseMs() / 3));
    beat.unref?.();
    st.done = this.lease(job.id).catch(() => {}).then(() => this.run(job, st))
      .catch(e => this.ctx.log.error({ job: job.id, err: (e as Error).message }, 'Replicate run crashed'))
      .finally(async () => {
        clearInterval(beat);
        // Stepping back for a restart: let the next instance take it over at once.
        if (this.stopping) await this.lease(job.id, 0).catch(() => {});
        this.running.delete(job.id);
        if (!this.stopping) this.ctx.jobs.kick();
      });
  }

  /** "This instance runs the job" (atomic: never overwrites the saved predictions). */
  private async lease(jobId: string, at = Date.now()) {
    const v = JSON.stringify({ by: this.instance, at });
    await this.ctx.db.update(jobs).set({ stats: sql`jsonb_set(coalesce(${jobs.stats}, '{}'::jsonb), '{replicateLease}', ${v}::jsonb, true)` })
      .where(and(eq(jobs.id, jobId), eq(jobs.state, 'running')));
  }

  private async saveState(jobId: string, state: RunState) {
    const [j] = await this.ctx.db.select({ stats: jobs.stats }).from(jobs).where(eq(jobs.id, jobId));
    await this.ctx.db.update(jobs).set({ stats: { ...(j?.stats ?? {}), replicate: state } }).where(eq(jobs.id, jobId));
  }

  /**
   * Owner (checked by the caller, SuiteRunner.recover): brings back a Character swap that failed after the provider made
   * (or may have made) its video. Free: it only asks the provider for the saved prediction's status and result (a GET);
   * it never starts a new generation. The job runs again on the line, downloads the result and saves it as a take.
   */
  async recover(j: typeof jobs.$inferSelect) {
    if (j.state === 'running') return { ok: true, state: 'running', job: j.id };
    if (j.state !== 'failed') throw badRequest('This job is not a failed one');
    const state = ((j.stats as any)?.replicate ?? { takes: [] }) as RunState;
    const open = (state.takes ?? []).filter(t => t.id && !t.done);
    if (!open.length) throw badRequest('Nothing to recover: no provider request was saved for this job');
    const lines = this.lines();
    const statuses: string[] = [];
    for (const t of open) {
      const l = lineOf(t);
      if (l === 'higgsfield' && !this.ctx.suite.providers.higgsfield.configured()) throw badRequest('Nothing to recover: the provider (higgsfield) is not set up');
      const p = await lines[l].get(t.id!).catch(() => ({ id: t.id!, status: 'processing' }) as Prediction);
      statuses.push(p.status === 'processing' || p.status === 'starting' ? 'running' : p.status);
    }
    if (statuses.every(s => s === 'failed' || s === 'canceled')) throw badRequest('The provider says this render failed or was cancelled, so nothing was made (and nothing was charged)');
    const stats = { ...((j.stats as object | null) ?? {}), replicate: { ...state, recovering: true }, replicateLease: null } as Record<string, any>;
    delete stats.errorCode;
    const [row] = await this.ctx.db.update(jobs).set({ state: 'running', gpuState: 'claimed', podId: REPLICATE_POD, error: null, retryable: null, finishedAt: null,
      refunded: 0, holdTokens: 0, phase: 'Recovering the video', stats }).where(and(eq(jobs.id, j.id), eq(jobs.state, 'failed'))).returning();
    if (!row) throw badRequest('This job changed · try again');
    this.ctx.jobs.emitJob(row);
    this.ctx.log.warn({ job: j.id, statuses }, 'swap job: recovering a paid provider result');
    if (!this.running.has(j.id) && !this.stopping) this.launch(row);
    return { ok: true, state: 'recovering', job: j.id, provider: statuses };
  }

  private async run(job: JobRow, st: Running) {
    const c = this.ctx.config, ctx = this.ctx;
    const r = job.request;
    let n = Math.max(1, r.takes ?? 1);
    const state: RunState = { takes: [], ...((job.stats as any)?.replicate ?? {}) };
    const recovering = !!state.recovering;
    const lines = this.lines();
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-rep-'));
    const perTake = P.replicateTakeSeconds(r);
    const t0 = Date.now();
    const notes = new Set<string>();
    const modelName = swapEngineById(r.swapEngine ?? '')?.name ?? 'Character swap';
    /** Progress: take i (1-based) at fraction f of its own time. False = the job ended (deleted or failed). */
    const report = async (i: number, f: number, label: string) => {
      const progress = Math.min(99.5, ((i - 1) + Math.min(1, Math.max(0, f))) / n * 100);
      const secondsLeft = Math.max(0, (n - (i - 1) - f) * perTake);
      const prefix = n > 1 ? `take ${i}/${n} · ` : '';
      const left = label === 'Rendering' ? ` · ${secondsLeft >= 60 ? `~${Math.ceil(secondsLeft / 60)} min` : `~${Math.ceil(secondsLeft)}s`} left` : '';
      const ok = await ctx.jobs.progress(job.id, { progress, take: i, step: i - 1, totalSteps: n, phase: `${prefix}${label}${left}`, secondsLeft });
      if (!ok) st.cancelled = true;
      return ok;
    };
    const cancelled = () => st.cancelled;
    /** A deploy or restart: step back, the next instance resumes (nothing is failed or cancelled at the provider). */
    const leaving = () => this.stopping;
    const hf = ctx.suite.providers.higgsfield;

    // The source clip and its sound handling: needed to start a take, and by finishing to put the sound back. Only read
    // when needed, so a resumed job whose prediction is saved never fails here.
    let source: Promise<Source> | undefined;
    const sourceOf = () => (source ??= (async (): Promise<Source> => {
      const [clip] = r.clipId ? await ctx.db.select().from(clips).where(eq(clips.id, r.clipId)) : [];
      if (!clip?.storageKey) throw new Error('the clip file is missing');
      const obj = await ctx.storage.get(clip.storageKey);
      if (!obj) throw new Error('the clip file is missing from storage');
      const src = path.join(tmp, `source${path.extname(clip.storageKey) || '.mp4'}`);
      await pipeline(obj.body, fs.createWriteStream(src));
      const info = await probe(c.FFPROBE_PATH, src);
      // Higgsfield Genjutsu (motion transfer): its own 4–30 s range (Light 4–15 s); no fallback to another model.
      const gj = swapEngineById(r.swapEngine ?? '')?.genjutsu ?? null;
      const len = Math.min(gj?.maxSec ?? P.REPLICATE_MAX_SEC, Number.isFinite(info.duration) && info.duration > 0 ? info.duration : (r.clipSeconds ?? clip.durationSec));
      // The owner's Higgsfield H3 (swapEngine h3-hf) takes 5–15 s: a shorter clip is padded to 5 s.
      const onHf = r.swapEngine === 'h3-hf' && hf.configured();
      const D = gj ? P.replicateSeconds(len, gj.minSec, gj.maxSec) : onHf ? Math.max(HF_SWAP_MIN_SEC, P.replicateSeconds(len)) : P.replicateSeconds(len);
      // Lip-sync guard: unless the clip is marked as the performer talking, the model gets the clip without sound (it
      // copies the motion, which already carries the beat) and the original sound goes back on the result.
      // Prompt scripts: the request carries the resolved switch/detection; older jobs fall back to the clip's check.
      const talking = typeof r.speaking === 'boolean' ? r.speaking
        : (clip.checks as { label: string; value: string }[] | null)?.some(x => x.label === 'Performer talking' && x.value === 'Yes') ?? false;
      return { src, info, D, muteSource: !talking && !!info.audioCodec, gj };
    })());

    // What starting a take needs: the padded clip, signed links, the model and its input.
    let starting: Promise<Start> | undefined;
    const startOf = () => (starting ??= (async (): Promise<Start> => {
      const { src, info, D, muteSource, gj } = await sourceOf();
      if (gj && !hf.configured()) throw new ReplicateError("Higgsfield isn't set up on the server", 'unavailable');
      const onHf = r.swapEngine === 'h3-hf' && hf.configured();
      // Padded to D seconds and uploaded once (kept for a resumed run).
      if (!state.paddedKey || state.seconds !== D || state.muted !== muteSource || !(await ctx.storage.head(state.paddedKey))) {
        await report(1, 0.01, 'Preparing the clip');
        const padded = path.join(tmp, 'source_padded.mp4');
        await padTo(c.FFMPEG_PATH, src, padded, D, info, { mute: muteSource });
        state.muted = muteSource;
        state.paddedKey = `r/${job.id}/source_padded.mp4`;
        state.seconds = D;
        await putFile(ctx, { key: state.paddedKey, file: padded, studioId: job.studioId, kind: 'output', userId: job.userId, contentType: 'video/mp4' });
        await this.saveState(job.id, state);
      }
      // Short-lived signed links (the bucket is never public).
      const ttl = c.REPLICATE_INPUT_URL_TTL_SEC;
      const videoUrl = await ctx.storage.presignGet(state.paddedKey!, ttl);
      const refs = ((r.references ?? []) as { label: string; image: ImageRef }[]).slice(0, gj?.maxImages ?? 9);
      const imageUrls: string[] = [];
      for (const x of refs) {
        const key = await ctx.images.storedKey(x.image, job.studioId);
        const url = key ? await ctx.storage.presignGet(key, ttl) : x.image?.url && /^https:\/\//.test(x.image.url) ? x.image.url : null;
        if (url) imageUrls.push(url);
      }
      const quality = P.qualityOf(r);
      // WS13: the owner's swap engine (`videoModel`, a hosted H3-family model) replaces the quality's default model.
      const model = typeof r.videoModel === 'string' && r.videoModel && !(r.swapEngine === 'h3-hf' && !onHf) ? r.videoModel : quality === 'draft' ? c.REPLICATE_VIDEO_DRAFT_MODEL : c.REPLICATE_VIDEO_MODEL;
      const replicateInput = { prompt: job.prompt, reference_video_urls: [videoUrl], reference_image_urls: imageUrls, duration: D,
        ...(r.videoNoResolution ? {} : { resolution: r.swapEngine && r.swapEngine !== 'h3-hf' ? swapResolution(r.swapEngine, quality) : r.swapEngine === 'h3-hf' ? '2K' : P.QUALITY_INFO[quality].resolution }), ratio: '9:16' };
      // Higgsfield's H3 reference-to-video: the clip is the reference video, the model's photos the reference images.
      const input: Record<string, unknown> = gj ? genjutsuInput(videoUrl, imageUrls, job.prompt, GENJUTSU_RES[quality] ?? '720p')
        : onHf ? { prompt: job.prompt, video_urls: [videoUrl], image_urls: imageUrls, duration: D, resolution: '2K', aspect_ratio: '9:16', aigc_watermark: false }
        : replicateInput;
      if (gj && !imageUrls.length) throw new ReplicateError('Genjutsu needs at least one picture of her', 'failed');
      state.images = imageUrls.length;
      return { onHf, gj: !!gj, model, input, replicateInput, imageUrls };
    })());
    /** Higgsfield out of credit, down or busy at the start of a take → that take and the rest run on Replicate H3. */
    const toReplicate = (e: unknown, s: Start) => {
      if (!s.onHf || !ctx.replicate.configured || !(e instanceof ReplicateError) || !['out_of_credit', 'unavailable', 'rate_limited'].includes(e.kind)) return false;
      ctx.log.warn({ job: job.id, err: e.message }, 'Higgsfield swap moved to Replicate H3');
      ctx.suite.markDown('higgsfield');
      s.onHf = false; s.model = c.REPLICATE_VIDEO_MODEL; s.input = { ...s.replicateInput, resolution: '2K' };
      return true;
    };

    try {
      if (!(await this.toolsReady())) throw new Error('ffmpeg is not installed on the server');
      await report(1, 0.01, recovering ? 'Recovering the video' : 'Preparing the clip');
      // One prediction per take, one after another.
      const outputs: Record<string, unknown>[] = [];
      const billed: number[] = [];
      let hfTakes = 0;
      for (let i = 1; i <= n; i++) {
        const ts: TakeState = state.takes[i - 1] ?? {};
        state.takes[i - 1] = ts;
        if (ts.done && ts.key && ts.output && (await ctx.storage.head(ts.key))) {
          outputs.push(ts.output); billed.push(ts.billed ?? state.seconds ?? perTake);
          if (lineOf(ts) === 'higgsfield' && r.swapEngine === 'h3-hf') hfTakes++;
          continue;
        }
        if (cancelled() || leaving()) return;
        // Resume: a saved prediction is polled by its id on the provider it was made on, never started (and paid) again.
        // A failed status check counts as "still running"; only the provider's own "no such prediction" (404) lets an
        // unpaid take start afresh.
        let pred: Prediction | null = null;
        if (ts.id) {
          pred = await lines[lineOf(ts)].get(ts.id).catch(e => {
            ctx.log.warn({ job: job.id, err: (e as Error).message }, 'swap resume: status check failed, polling on');
            return e instanceof ReplicateError && e.status === 404 && !ts.paid ? null : { id: ts.id!, status: 'processing' } as Prediction;
          });
          // We asked it to stop (our timeout) and it did: not charged, never started again.
          if (pred?.status === 'canceled' && ts.cancelAsked) throw new ReplicateError('timed out', 'timeout');
        }
        if (!pred || pred.status === 'canceled') {
          if (recovering) {
            // Recovery is free: it never starts a take. The takes it brought back are kept; the job is that many takes.
            if (outputs.length) { n = outputs.length; await ctx.db.update(jobs).set({ request: { ...r, takes: n } }).where(eq(jobs.id, job.id)); break; }
            throw new ReplicateError('nothing came back to recover', 'failed');
          }
          const s = await startOf();
          if (!(await report(i, 0.03, 'Starting'))) return;
          const lineId = (): LineId => (s.onHf || s.gj ? 'higgsfield' : 'replicate');
          const begin = () => lines[lineId()].create(s.model, s.input, {
            maxWaitMs: c.REPLICATE_MAX_RATE_WAIT_SEC * 1000, cancelled,
            onWait: async w => { await report(i, 0.03, `Waiting to start · retrying in ${w}s`); },
          });
          try { pred = await begin(); } catch (e) { if (!toReplicate(e, s)) throw e; pred = await begin(); }
          ts.id = pred.id; ts.provider = lineId(); ts.startedAt = Date.now();
          delete ts.cancelAsked; delete ts.paid; delete ts.result;
          await this.saveState(job.id, state);
        }
        const id = ts.id!, lid = lineOf(ts), line = lines[lid];
        st.predictions.set(id, lid);
        const started = ts.startedAt ?? Date.now(), limit = c.REPLICATE_PREDICTION_TIMEOUT_SEC * 1000, grace = limit / 2;
        while (pred.status === 'starting' || pred.status === 'processing') {
          if (leaving()) return;
          if (cancelled()) { await line.cancel(id); return; }
          // Too long: ask the provider to cancel, then keep polling for its answer. A cancelled render isn't charged;
          // one that finishes anyway is paid, so it is still saved as a take. Fail only if it never answers.
          if (!ts.cancelAsked && Date.now() - started > limit) {
            await line.cancel(id);
            ts.cancelAsked = Date.now();
            await this.saveState(job.id, state);
            ctx.log.warn({ job: job.id, provider: lid }, 'swap take over its time: cancel asked, waiting for the provider');
          }
          if (ts.cancelAsked && Date.now() - ts.cancelAsked > grace) throw new PaidLost('unconfirmed', i, 'the provider neither finished nor cancelled');
          if (!(await report(i, 0.05 + 0.85 * Math.min(0.95, (Date.now() - started) / 1000 / perTake), 'Rendering'))) { await line.cancel(id); return; }
          await sleep(c.REPLICATE_POLL_MS);
          if (leaving()) return;
          try { pred = await line.get(id); } catch (e) {
            ctx.log.warn({ job: job.id, err: (e as Error).message }, 'swap status check failed, polling on');
            pred = { id, status: 'processing' };
          }
        }
        st.predictions.delete(id);
        if (pred.status === 'canceled') {
          if (cancelled()) return;
          if (ts.cancelAsked) throw new ReplicateError('timed out', 'timeout');
          throw new ReplicateError('the provider cancelled the render', 'failed');
        }
        if (pred.status === 'failed') throw failedError(pred);
        const url = outputUrl(pred.output);
        if (!url) throw new ReplicateError('the provider returned no video', 'failed');
        // From here the provider has made (and charged for) the video: it must become a take. Nothing below may fail
        // the job as "not charged"; what can't be finished is skipped, what can't be saved is reported as recoverable.
        const secs = Number(pred.metrics?.video_output_duration_seconds);
        ts.paid = true; ts.result = { url, billed: Number.isFinite(secs) && secs > 0 ? secs : null, at: Date.now() };
        await this.saveState(job.id, state);
        if (!(await report(i, 0.92, 'Finishing'))) return;
        try {
          await this.deliver({ job, state, ts, i, tmp, line, url, sourceOf, leaving, notes });
        } catch (e) {
          if (leaving() || e instanceof PaidLost) throw e;
          throw new PaidLost('unsaved', i, (e as Error).message);
        }
        ts.billed = ts.result.billed ?? state.seconds ?? perTake;
        ts.done = true;
        await this.saveState(job.id, state);
        outputs.push(ts.output!);
        billed.push(ts.billed);
        if (lid === 'higgsfield' && r.swapEngine === 'h3-hf') hfTakes++;
      }
      ctx.engines.worked('replicate');
      // Done: settle on the seconds the provider billed.
      const quality = P.qualityOf(r);
      const price = r.pricePerSec ?? P.QUALITY_PRICE_DEFAULTS[quality];
      const billedSeconds = billed.reduce((a, b) => a + b, 0);
      // Higgsfield bills $0.08 per reference image beyond the 5 included, per take (registry h3-hf).
      const images = state.images ?? Math.min(9, ((r.references ?? []) as unknown[]).length);
      const hfExtra = 0.08 * Math.max(0, images - 5) * hfTakes;
      const fresh = ((await ctx.db.select({ stats: jobs.stats }).from(jobs).where(eq(jobs.id, job.id)))[0]?.stats ?? {}) as Record<string, any>;
      const { recovering: _r, ...kept } = state;
      await ctx.jobs.complete(job.id, {
        outputs, actualCostUsd: price * billedSeconds + hfExtra, settleNote: `${P.videoNote(r, billed)}${recovering ? ' · recovered' : ''}`,
        stats: { ...fresh, replicate: { ...kept, billedSeconds, wallSeconds: Math.round((Date.now() - t0) / 1000), ...(notes.size ? { finished: [...notes] } : {}) } },
      });
    } catch (e) {
      if (st.cancelled || (e instanceof ReplicateError && e.kind === 'cancelled')) return;
      if (leaving()) { ctx.log.info({ job: job.id, err: (e as Error).message }, 'Replicate job left for the next server instance'); return; }
      if (e instanceof PaidLost) {
        // Paid (or maybe paid) at the provider and not a take: say so, keep the prediction id, tell the owner.
        ctx.log.error({ job: job.id, take: e.take, kind: e.kind, err: e.why }, 'swap job: provider result paid but not saved');
        await this.saveState(job.id, { ...state, recovering: false, lost: { take: e.take, kind: e.kind, why: e.why.slice(0, 300), at: Date.now() } } as RunState).catch(() => {});
        const f = paidLostFailure(e);
        await ctx.jobs.fail(job.id, f.message, false, f.code);
        await reportPaidLost(ctx, job, modelName, e, 'swap_line').catch(err => ctx.log.warn({ err: (err as Error).message }, 'swap: could not record the issue'));
        return;
      }
      const f = failureOf(e);
      ctx.log.warn({ job: job.id, code: f.code, err: (e as Error).message }, 'Replicate job failed');
      if (f.code === 'provider_out_of_credit') await ctx.engines.outOfCredit(job.studioId, 'replicate', (e as Error).message);
      await ctx.jobs.fail(job.id, f.message, f.retryable, f.code);
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  }

  /**
   * Download the provider's video and make it a take. Only the download, the probe and the store are required; sound
   * removal, putting the clip's sound back and the thumbnail fall back to the video as the provider made it. The take is
   * the provider's file as delivered: no trim, no re-encode (trimming is the user's job in the app's editor). It covers
   * the whole clip because the source was padded to whole seconds. Skipping the re-encode also keeps a 2K take from
   * running the API instance out of memory.
   */
  private async deliver(o: { job: JobRow; state: RunState; ts: TakeState; i: number; tmp: string; line: Line; url: string; sourceOf: () => Promise<Source>;
    leaving: () => boolean; notes: Set<string> }) {
    const { job, ts, i, tmp, notes } = o;
    const ctx = this.ctx, c = ctx.config, r = job.request;
    const raw = path.join(tmp, `raw_${i}.mp4`), take = path.join(tmp, `take_${i}.mp4`), thumb = path.join(tmp, `take_${i}.jpg`);
    // Download, retried; between tries the provider is asked again (a fresh result URL). A status GET is free.
    let url = o.url, last: unknown;
    for (let a = 0; a < 3; a++) {
      try { await o.line.download(url, raw); last = undefined; break; } catch (e) {
        last = e;
        ctx.log.warn({ job: job.id, try: a + 1, err: (e as Error).message }, 'swap download failed');
        if (o.leaving()) throw e;
        await sleep(Math.min(10_000, c.REPLICATE_POLL_MS * (a + 1)));
        const p = await o.line.get(ts.id!).catch(() => null);
        const u = p?.status === 'succeeded' ? outputUrl(p.output) : null;
        if (u) url = u;
      }
    }
    if (last) throw last;
    const soft = async (what: string, fn: () => Promise<void>) => {
      try { await fn(); return true; } catch (e) {
        if (o.leaving()) throw e;
        ctx.log.warn({ job: job.id, step: what, err: (e as Error).message }, 'swap finishing step skipped');
        notes.add(`${what} skipped (kept as the provider made it)`);
        return false;
      }
    };
    let shaped = false;
    const gj = !!swapEngineById(r.swapEngine ?? '')?.genjutsu;
    // Keep audio off: drop the audio track with a stream copy (no re-encode, almost no memory).
    if (r.keepAudio === false) shaped = await soft('removing the sound', () => stripAudio(c.FFMPEG_PATH, raw, take));
    else if (gj || o.state.muted) {
      // Genjutsu: the clip's own sound always goes back on (cut to the take's length). A muted source: the original
      // sound goes back on the result.
      shaped = await soft("putting the clip's sound back", async () => {
        const s = await o.sourceOf();
        if (gj && s.info.audioCodec) await restoreAudio(c.FFMPEG_PATH, raw, s.src, take, s.info.audioCodec, { shortest: true });
        else if (!gj && s.info.audioCodec) await restoreAudio(c.FFMPEG_PATH, raw, s.src, take, s.info.audioCodec);
        else await fs.promises.copyFile(raw, take);
      });
    }
    if (!shaped) await fs.promises.copyFile(raw, take);
    let out = await probe(c.FFPROBE_PATH, take).catch(() => null);
    if (!out && shaped) {
      notes.add('sound step skipped (kept as the provider made it)');
      await fs.promises.copyFile(raw, take);
    }
    out ??= await probe(c.FFPROBE_PATH, take);
    const key = `r/${job.id}/take_${i}.mp4`, thumbKey = `r/${job.id}/take_${i}.jpg`;
    const stored = await this.store({ key, file: take, studioId: job.studioId, userId: job.userId, contentType: 'video/mp4' });
    let hasThumb = false;
    try {
      await thumbnail(c.FFMPEG_PATH, take, thumb, Math.min(1, out.duration / 2));
      await this.store({ key: thumbKey, file: thumb, studioId: job.studioId, userId: job.userId, contentType: 'image/jpeg' });
      hasThumb = true;
    } catch (e) { if (o.leaving()) throw e; ctx.log.warn({ job: job.id, err: (e as Error).message }, 'swap thumbnail skipped'); }
    ts.output = { name: `take_${i}.mp4`, key, contentType: 'video/mp4', bytes: stored.bytes, sha256: stored.sha256, width: out.width, height: out.height,
      fps: out.fps, durationSec: Math.round(out.duration * 1000) / 1000, ...(hasThumb ? { thumb: { url: `${c.PUBLIC_URL ?? ''}/uploads/${thumbKey}` } } : {}), predictionId: ts.id };
    ts.key = key;
    if (hasThumb) ts.thumbKey = thumbKey;
    for (const f of [raw, take, thumb]) fs.rmSync(f, { force: true });
  }

  /** putFile, tried twice (a storage blip must not lose a paid video). */
  private async store(f: { key: string; file: string; studioId: string; userId: string | null; contentType: string }) {
    try { return await putFile(this.ctx, { ...f, kind: 'output' }); } catch (e) {
      this.ctx.log.warn({ key: f.key, err: (e as Error).message }, 'swap store failed, trying again');
      await sleep(1000);
      return putFile(this.ctx, { ...f, kind: 'output' });
    }
  }
}
