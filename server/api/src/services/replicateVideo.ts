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
import { and, eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { clips, jobs, type ImageRef } from '../db/schema.js';
import * as P from '../pricing.js';
import { outputUrl, ReplicateError, SAFETY_RE, errorText, type Prediction } from '../replicate/client.js';
import { finishTake, mediaToolsAvailable, padTo, probe, thumbnail } from '../replicate/media.js';
import { putFile } from '../storage/objects.js';
import type { JobRow } from '../gpu/controller.js';

/** The pod id replicate jobs are claimed under (no pod row exists for it). */
export const REPLICATE_POD = 'replicate';
export const REFUSED_CLIP = "Replicate's safety filter refused this clip";

type TakeState = { id?: string; done?: boolean; key?: string; thumbKey?: string; billed?: number; output?: Record<string, unknown> };
type RunState = { paddedKey?: string; seconds?: number; takes: TakeState[] };
type Running = { cancelled: boolean; predictions: Set<string>; done: Promise<void> };

/** Why a run failed, for the job: the message shown as-is and the machine code. */
export function failureOf(e: unknown): { message: string; code: string; retryable: boolean } {
  if (e instanceof ReplicateError) {
    if (e.kind === 'refused') return { message: REFUSED_CLIP, code: 'provider_refused', retryable: false };
    if (e.kind === 'rate_limited') return { message: 'Replicate stayed busy for too long (rate limit). You were not charged · try again later.', code: 'provider_rate_limited', retryable: true };
    if (e.kind === 'timeout') return { message: `${e.message}. You were not charged.`, code: 'provider_timeout', retryable: true };
    if (e.kind === 'unavailable') return { message: `${e.message}. You were not charged.`, code: 'provider_failed', retryable: false };
    return { message: `Replicate couldn't render this clip: ${e.message}. You were not charged.`, code: 'provider_failed', retryable: true };
  }
  return { message: `The render couldn't be finished: ${(e as Error)?.message ?? 'unknown error'}. You were not charged.`, code: 'provider_failed', retryable: true };
}

/** A failed prediction → the error to throw (safety refusals are told apart). */
export function predictionError(p: Prediction) {
  const t = errorText(p.error);
  if (SAFETY_RE.test(t)) return new ReplicateError(t, 'refused');
  return new ReplicateError(t || 'the prediction failed', 'failed');
}

export class ReplicateVideo {
  private running = new Map<string, Running>();
  constructor(private ctx: Ctx) {}

  get configured() { return this.ctx.replicate.configured; }
  busy() { return this.running.size > 0; }
  async toolsReady() { return mediaToolsAvailable(this.ctx.config.FFMPEG_PATH, this.ctx.config.FFPROBE_PATH); }
  /** Waits for every run in this process to stop (tests, shutdown). */
  async idle() { await Promise.all([...this.running.values()].map(r => r.done)); }

  /**
   * One dispatcher pass for the Replicate line. `waiting`: replicate jobs waiting, oldest first. Claimed jobs nobody
   * here is running (after a restart) are resumed first; then free slots take the oldest waiting jobs.
   */
  async dispatch(waiting: JobRow[]) {
    const orphans = await this.ctx.db.select().from(jobs).where(and(eq(jobs.state, 'running'), eq(jobs.gpuState, 'claimed'), eq(jobs.podId, REPLICATE_POD)));
    for (const j of orphans) if (!this.running.has(j.id)) { this.ctx.log.info({ job: j.id }, 'Replicate job resumed'); this.launch(j); }
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

  cancel(jobId: string) {
    const r = this.running.get(jobId);
    if (!r) return;
    r.cancelled = true;
    for (const id of r.predictions) void this.ctx.replicate.cancel(id);
  }

  private launch(job: JobRow) {
    const st: Running = { cancelled: false, predictions: new Set(), done: Promise.resolve() };
    this.running.set(job.id, st);
    st.done = this.run(job, st)
      .catch(e => this.ctx.log.error({ job: job.id, err: (e as Error).message }, 'Replicate run crashed'))
      .finally(() => { this.running.delete(job.id); this.ctx.jobs.kick(); });
  }

  private async saveState(jobId: string, state: RunState) {
    const [j] = await this.ctx.db.select({ stats: jobs.stats }).from(jobs).where(eq(jobs.id, jobId));
    await this.ctx.db.update(jobs).set({ stats: { ...(j?.stats ?? {}), replicate: state } }).where(eq(jobs.id, jobId));
  }

  private async run(job: JobRow, st: Running) {
    const c = this.ctx.config, ctx = this.ctx, rep = ctx.replicate;
    const r = job.request;
    const n = Math.max(1, r.takes ?? 1);
    const state: RunState = { takes: [], ...((job.stats as any)?.replicate ?? {}) };
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-rep-'));
    const perTake = P.replicateTakeSeconds(r);
    const t0 = Date.now();
    /** Progress: take i (1-based) at fraction f of its own time. False = the job ended (deleted or failed). */
    const report = async (i: number, f: number, label: string) => {
      const progress = Math.min(99.5, ((i - 1) + Math.min(1, Math.max(0, f))) / n * 100);
      const secondsLeft = Math.max(0, (n - (i - 1) - f) * perTake);
      const prefix = n > 1 ? `take ${i}/${n} · ` : '';
      const ok = await ctx.jobs.progress(job.id, { progress, take: i, step: i - 1, totalSteps: n, phase: `${prefix}${label}`, secondsLeft });
      if (!ok) st.cancelled = true;
      return ok;
    };
    const cancelled = () => st.cancelled;
    try {
      if (!(await this.toolsReady())) throw new Error('ffmpeg is not installed on the server');
      await report(1, 0.01, 'Preparing the clip');
      // 1. The source and its exact length.
      const [clip] = r.clipId ? await ctx.db.select().from(clips).where(eq(clips.id, r.clipId)) : [];
      if (!clip?.storageKey) throw new Error('the clip file is missing');
      const obj = await ctx.storage.get(clip.storageKey);
      if (!obj) throw new Error('the clip file is missing from storage');
      const src = path.join(tmp, `source${path.extname(clip.storageKey) || '.mp4'}`);
      await pipeline(obj.body, fs.createWriteStream(src));
      const info = await probe(c.FFPROBE_PATH, src);
      const len = Math.min(P.REPLICATE_MAX_SEC, Number.isFinite(info.duration) && info.duration > 0 ? info.duration : (r.clipSeconds ?? clip.durationSec));
      const D = P.replicateSeconds(len);
      // 2. Padded to D seconds and uploaded once (kept for a resumed run).
      if (!state.paddedKey || state.seconds !== D || !(await ctx.storage.head(state.paddedKey))) {
        const padded = path.join(tmp, 'source_padded.mp4');
        await padTo(c.FFMPEG_PATH, src, padded, D, info);
        state.paddedKey = `r/${job.id}/source_padded.mp4`;
        state.seconds = D;
        await putFile(ctx, { key: state.paddedKey, file: padded, studioId: job.studioId, kind: 'output', userId: job.userId, contentType: 'video/mp4' });
        await this.saveState(job.id, state);
      }
      if (cancelled()) return;
      // 3. Short-lived signed links (the bucket is never public).
      const ttl = c.REPLICATE_INPUT_URL_TTL_SEC;
      const videoUrl = await ctx.storage.presignGet(state.paddedKey!, ttl);
      const refs = ((r.references ?? []) as { label: string; image: ImageRef }[]).slice(0, 9);
      const imageUrls: string[] = [];
      for (const x of refs) {
        const key = await ctx.images.storedKey(x.image, job.studioId);
        const url = key ? await ctx.storage.presignGet(key, ttl) : x.image?.url && /^https:\/\//.test(x.image.url) ? x.image.url : null;
        if (url) imageUrls.push(url);
      }
      const quality = P.qualityOf(r);
      const model = quality === 'draft' ? c.REPLICATE_VIDEO_DRAFT_MODEL : c.REPLICATE_VIDEO_MODEL;
      const input = { prompt: job.prompt, reference_video_urls: [videoUrl], reference_image_urls: imageUrls, duration: D,
        resolution: P.QUALITY_INFO[quality].resolution, ratio: '9:16' };
      // 4. One prediction per take, one after another.
      const outputs: Record<string, unknown>[] = [];
      const billed: number[] = [];
      for (let i = 1; i <= n; i++) {
        const ts: TakeState = state.takes[i - 1] ?? {};
        state.takes[i - 1] = ts;
        if (ts.done && ts.key && ts.output && (await ctx.storage.head(ts.key))) { outputs.push(ts.output); billed.push(ts.billed ?? D); continue; }
        if (cancelled()) return;
        let pred: Prediction | null = null;
        if (ts.id) pred = await rep.get(ts.id).catch(() => null);
        if (!pred || pred.status === 'canceled') {
          if (!(await report(i, 0.03, 'Starting on Replicate'))) return;
          pred = await rep.create(model, input, {
            maxWaitMs: c.REPLICATE_MAX_RATE_WAIT_SEC * 1000, cancelled,
            onWait: async s => { await report(i, 0.03, `Replicate is busy · retrying in ${s}s`); },
          });
          ts.id = pred.id;
          await this.saveState(job.id, state);
        }
        st.predictions.add(pred.id);
        if (!(await report(i, 0.05, 'Rendering on Replicate'))) { await rep.cancel(pred.id); return; }
        const renderShare = 0.85;
        const done = pred.status === 'succeeded' || pred.status === 'failed' || pred.status === 'canceled' ? pred
          : await rep.wait(pred.id, {
            pollMs: c.REPLICATE_POLL_MS, timeoutMs: c.REPLICATE_PREDICTION_TIMEOUT_SEC * 1000, cancelled,
            onPoll: async (_p, ms) => { await report(i, 0.05 + renderShare * Math.min(0.95, ms / 1000 / perTake), 'Rendering on Replicate'); },
          });
        st.predictions.delete(pred.id);
        if (done.status === 'canceled') { if (cancelled()) return; throw new ReplicateError('Replicate cancelled the render', 'failed'); }
        if (done.status === 'failed') throw predictionError(done);
        const url = outputUrl(done.output);
        if (!url) throw new ReplicateError('Replicate returned no video', 'failed');
        if (!(await report(i, 0.92, 'Finishing · exact length and audio'))) return;
        const raw = path.join(tmp, `raw_${i}.mp4`), take = path.join(tmp, `take_${i}.mp4`), thumb = path.join(tmp, `take_${i}.jpg`);
        await rep.download(url, raw);
        await finishTake(c.FFMPEG_PATH, raw, src, take, { duration: len, keepAudio: r.keepAudio !== false, audioCodec: info.audioCodec });
        const out = await probe(c.FFPROBE_PATH, take);
        await thumbnail(c.FFMPEG_PATH, take, thumb, Math.min(1, out.duration / 2));
        const key = `r/${job.id}/take_${i}.mp4`, thumbKey = `r/${job.id}/take_${i}.jpg`;
        const stored = await putFile(ctx, { key, file: take, studioId: job.studioId, kind: 'output', userId: job.userId, contentType: 'video/mp4' });
        await putFile(ctx, { key: thumbKey, file: thumb, studioId: job.studioId, kind: 'output', userId: job.userId, contentType: 'image/jpeg' });
        const secs = Number(done.metrics?.video_output_duration_seconds);
        ts.billed = Number.isFinite(secs) && secs > 0 ? secs : D;
        ts.output = { name: `take_${i}.mp4`, key, contentType: 'video/mp4', bytes: stored.bytes, sha256: stored.sha256, width: out.width, height: out.height,
          fps: out.fps, durationSec: Math.round(out.duration * 1000) / 1000, thumb: { url: `${c.PUBLIC_URL ?? ''}/uploads/${thumbKey}` }, predictionId: done.id };
        ts.done = true; ts.key = key; ts.thumbKey = thumbKey;
        await this.saveState(job.id, state);
        outputs.push(ts.output);
        billed.push(ts.billed);
        for (const f of [raw, take, thumb]) fs.rmSync(f, { force: true });
      }
      // 5. Done: settle on the seconds Replicate billed.
      const price = r.pricePerSec ?? P.QUALITY_PRICE_DEFAULTS[quality];
      const billedSeconds = billed.reduce((a, b) => a + b, 0);
      await ctx.jobs.complete(job.id, {
        outputs, actualCostUsd: price * billedSeconds, settleNote: P.videoNote(r, billed),
        stats: { ...((job.stats as object | null) ?? {}), replicate: { ...state, billedSeconds, wallSeconds: Math.round((Date.now() - t0) / 1000) } },
      });
    } catch (e) {
      if (st.cancelled || (e instanceof ReplicateError && e.kind === 'cancelled')) return;
      const f = failureOf(e);
      ctx.log.warn({ job: job.id, code: f.code, err: (e as Error).message }, 'Replicate job failed');
      await ctx.jobs.fail(job.id, f.message, f.retryable, f.code);
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  }
}
