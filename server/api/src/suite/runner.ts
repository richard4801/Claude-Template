// AI suite · the suite line: runs claimed suite jobs on their provider (or the mock). Like the Replicate line
// (services/replicateVideo.ts): FIFO, SUITE_MAX_CONCURRENT at once, prediction ids saved on the job so a restart resumes
// polling instead of paying twice, every take delivered exactly as the provider made it (no trim, no re-encode).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { and, eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { clips, jobs, uploads, type ImageRef } from '../db/schema.js';
import { ReplicateError } from '../replicate/client.js';
import { mediaToolsAvailable, probe, restoreAudio, stripAudio, thumbnail } from '../replicate/media.js';
import { pipeline } from 'node:stream/promises';
import { failureOf } from '../services/replicateVideo.js';
import { beatOnlyAudio } from '../audio/beat.js';
import { putFile } from '../storage/objects.js';
import type { JobRow } from '../gpu/controller.js';
import type { VideoRef } from './camera.js';
import { buildInput, type MediaUrls } from './inputs.js';
import { billedSeconds, shotNote, type ShotPlan } from './plan.js';
import { modelById } from './registry.js';
import type { SuiteService } from './service.js';

/** The pod id suite jobs are claimed under (no pod row exists for it). */
export const SUITE_POD = 'suite';
type TakeState = { id?: string; provider?: string; done?: boolean; key?: string; billed?: number; output?: Record<string, unknown> };
type Running = { cancelled: boolean; ids: Set<string>; done: Promise<void> };

export class SuiteRunner {
  private running = new Map<string, Running>();
  constructor(private ctx: Ctx, private suite: SuiteService) {}

  busy() { return this.running.size > 0; }
  async toolsReady() { return mediaToolsAvailable(this.ctx.config.FFMPEG_PATH, this.ctx.config.FFPROBE_PATH); }
  async idle() { await Promise.all([...this.running.values()].map(r => r.done)); }

  /** One pass: resume orphans (claimed, nobody running them after a restart), then start the oldest waiting ones. */
  async dispatch(waiting: JobRow[]) {
    const orphans = await this.ctx.db.select().from(jobs).where(and(eq(jobs.state, 'running'), eq(jobs.gpuState, 'claimed'), eq(jobs.podId, SUITE_POD)));
    for (const j of orphans) if (!this.running.has(j.id)) this.launch(j);
    const max = Math.max(1, Math.floor(this.ctx.config.SUITE_MAX_CONCURRENT));
    let pos = 0;
    for (const j of waiting) {
      if (this.running.size < max) {
        const c = await this.ctx.jobs.claim(j.id, SUITE_POD);
        if (c) { this.launch(c); continue; }
      }
      pos++;
      await this.ctx.jobs.setLinePosition(j, pos, 0);
    }
  }

  cancel(jobId: string) {
    const r = this.running.get(jobId);
    if (!r) return;
    r.cancelled = true;
  }

  private launch(job: JobRow) {
    const st: Running = { cancelled: false, ids: new Set(), done: Promise.resolve() };
    this.running.set(job.id, st);
    st.done = this.run(job, st)
      .catch(e => this.ctx.log.error({ job: job.id, err: (e as Error).message }, 'suite run crashed'))
      .finally(() => { this.running.delete(job.id); this.ctx.jobs.kick(); });
  }

  private async save(jobId: string, takes: TakeState[]) {
    const [j] = await this.ctx.db.select({ stats: jobs.stats }).from(jobs).where(eq(jobs.id, jobId));
    const s = (j?.stats ?? {}) as Record<string, any>;
    await this.ctx.db.update(jobs).set({ stats: { ...s, suite: { ...(s.suite ?? {}), takes } } }).where(eq(jobs.id, jobId));
  }

  private async saveExtra(jobId: string, extra: Record<string, unknown>) {
    const [j] = await this.ctx.db.select({ stats: jobs.stats }).from(jobs).where(eq(jobs.id, jobId));
    const s = (j?.stats ?? {}) as Record<string, any>;
    await this.ctx.db.update(jobs).set({ stats: { ...s, suite: { ...(s.suite ?? {}), ...extra } } }).where(eq(jobs.id, jobId));
  }
  storageKeyOf(v: VideoRef) { return v.key ?? (v.url ? /\/uploads\/([A-Za-z0-9][A-Za-z0-9._\/-]*)$/.exec(v.url)?.[1] : undefined); }

  /** A signed URL an outside service can fetch for an image. */
  private async imageUrl(ref: ImageRef | undefined, studioId: string): Promise<string | undefined> {
    if (!ref) return undefined;
    const ttl = this.ctx.config.REPLICATE_INPUT_URL_TTL_SEC;
    const key = await this.ctx.images.storedKey(ref, studioId);
    if (key) return this.ctx.storage.presignGet(key, ttl);
    if (ref.url && /^https:\/\//.test(ref.url)) return ref.url;
    throw new ReplicateError('an image could not be signed', 'failed');
  }
  private async videoUrl(v: VideoRef, studioId: string): Promise<string> {
    const ttl = this.ctx.config.REPLICATE_INPUT_URL_TTL_SEC;
    const key = v.key ?? (v.url ? /\/uploads\/([A-Za-z0-9][A-Za-z0-9._\/-]*)$/.exec(v.url)?.[1] : undefined);
    if (key) {
      const [row] = await this.ctx.db.select({ id: uploads.id }).from(uploads).where(and(eq(uploads.storageKey, key), eq(uploads.studioId, studioId)));
      const clip = row ? null : (await this.ctx.db.select({ id: clips.id }).from(clips).where(and(eq(clips.storageKey, key), eq(clips.studioId, studioId))))[0];
      if (!row && !clip && !key.startsWith('assets/')) throw new ReplicateError('a video is not in this studio', 'failed');
      return this.ctx.storage.presignGet(key, ttl);
    }
    if (v.url && /^https:\/\//.test(v.url)) return v.url;
    throw new ReplicateError('a video could not be signed', 'failed');
  }

  private async run(job: JobRow, st: Running) {
    const ctx = this.ctx, c = ctx.config;
    const plan = (job.stats as any)?.suite?.plan as ShotPlan | undefined;
    const prior = ((job.stats as any)?.suite?.takes ?? []) as TakeState[];
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-suite-'));
    const n = Math.max(1, plan?.takes ?? 1);
    const perTake = (job.totalSeconds || 90) / n;
    const report = async (i: number, f: number, label: string) => {
      const progress = Math.min(99.5, ((i - 1) + Math.min(1, Math.max(0, f))) / n * 100);
      const secondsLeft = Math.max(0, (n - (i - 1) - f) * perTake);
      const ok = await ctx.jobs.progress(job.id, { progress, take: i, step: i - 1, totalSteps: n, secondsLeft,
        phase: `${n > 1 ? `take ${i}/${n} · ` : ''}${label}${label === 'Rendering' ? ` · ${secondsLeft >= 60 ? `~${Math.ceil(secondsLeft / 60)} min` : `~${Math.ceil(secondsLeft)}s`} left` : ''}` });
      if (!ok) st.cancelled = true;
      return ok;
    };
    const cancelled = () => st.cancelled;
    try {
      if (!plan) throw new Error('the shot plan is missing');
      const model = modelById(plan.modelId);
      if (!model) throw new ReplicateError('model no longer in the registry', 'unavailable');
      const provider = this.suite.providerFor(plan);
      const mock = provider.id === 'mock';
      if (!(await this.toolsReady())) throw new Error('ffmpeg is not installed on the server');
      await report(1, 0.01, 'Preparing');
      const urls: MediaUrls = {
        start: await this.imageUrl(plan.images.start, job.studioId), end: await this.imageUrl(plan.images.end, job.studioId),
        middle: await Promise.all(plan.images.middle.map(x => this.imageUrl(x, job.studioId).then(u => u!))),
        refs: await Promise.all(plan.images.refs.map(x => this.imageUrl(x.image, job.studioId).then(u => u!))),
        videos: await Promise.all(plan.videos.map(v => this.videoUrl(v.video, job.studioId))),
      };
      // Audio: speech is sent as is. Not speaking: only a real instrumental (vocals removed once per job, billed with
      // it). When nothing was separated (the separator is off, or this is a test render) NO audio is sent and the
      // shot uses its no-audio prompt: the original track would let the model sing or lip-sync to it.
      let separationCost = 0, prompt = plan.prompt;
      if (plan.audioRef) {
        const key = this.storageKeyOf(plan.audioRef.ref);
        if (plan.audioRef.beatOnly) {
          type Sep = { instrumentalKey?: string | null; costUsd?: number; separated?: boolean };
          const saved = (job.stats as any)?.suite?.audio as Sep | undefined;
          let sep: Sep | undefined = saved && (saved.separated === false || (saved.instrumentalKey && (await ctx.storage.head(saved.instrumentalKey)))) ? saved : undefined;
          if (!sep && mock) sep = { instrumentalKey: null, costUsd: 0, separated: false };
          if (!sep) {
            if (!key) throw new ReplicateError('the audio must be an upload to separate its beat', 'failed');
            await report(1, 0.02, 'Preparing the audio');
            const b = await beatOnlyAudio(ctx, { studioId: job.studioId, userId: job.userId, jobId: job.id, audioKey: key, cancelled }) as { instrumentalKey: string; costUsd: number; separated?: boolean };
            const separated = b.separated !== false && b.instrumentalKey !== key;
            sep = separated ? { instrumentalKey: b.instrumentalKey, costUsd: b.costUsd, separated: true } : { instrumentalKey: null, costUsd: 0, separated: false };
            await this.saveExtra(job.id, { audio: sep });
          }
          if (sep.separated && sep.instrumentalKey) {
            separationCost = sep.costUsd ?? 0;
            urls.audio = await ctx.storage.presignGet(sep.instrumentalKey, c.REPLICATE_INPUT_URL_TTL_SEC);
          } else if (plan.promptNoAudio) {
            prompt = plan.promptNoAudio;
            await ctx.db.update(jobs).set({ prompt }).where(eq(jobs.id, job.id));
          }
        } else urls.audio = await this.videoUrl(plan.audioRef.ref, job.studioId);
      }
      const input = buildInput(model, { ...plan, prompt }, urls);
      const takes: TakeState[] = prior.map(x => ({ ...x }));
      const outputs: Record<string, unknown>[] = [], billed: number[] = [];
      for (let i = 1; i <= n; i++) {
        const ts: TakeState = takes[i - 1] ?? {};
        takes[i - 1] = ts;
        if (ts.done && ts.key && ts.output && (await ctx.storage.head(ts.key))) { outputs.push(ts.output); billed.push(ts.billed ?? plan.billedPerTake); continue; }
        if (cancelled()) return;
        let status = ts.id && ts.provider === provider.id ? await provider.get(ts.id).catch(() => null) : null;
        if (!status || status.status === 'canceled') {
          if (!(await report(i, 0.03, 'Starting'))) return;
          const takeInput = plan.seed != null && input.seed != null ? { ...input, seed: plan.seed + i - 1 } : input;
          ts.id = await provider.start(plan.ref, takeInput, { cancelled, seconds: plan.seconds, onWait: async s => { await report(i, 0.03, `Waiting to start · retrying in ${s}s`); } });
          ts.provider = provider.id;
          await this.save(job.id, takes);
          status = { status: 'running' };
        }
        st.ids.add(ts.id!);
        const t0 = Date.now();
        while (status.status === 'running') {
          if (cancelled()) { await provider.cancel(ts.id!); return; }
          if (Date.now() - t0 > c.SUITE_PREDICTION_TIMEOUT_SEC * 1000) { await provider.cancel(ts.id!); throw new ReplicateError('timed out', 'timeout'); }
          if (!(await report(i, 0.05 + 0.85 * Math.min(0.95, (Date.now() - t0) / 1000 / perTake), 'Rendering'))) { await provider.cancel(ts.id!); return; }
          await new Promise(r => setTimeout(r, c.SUITE_POLL_MS));
          status = await provider.get(ts.id!);
        }
        st.ids.delete(ts.id!);
        if (status.status === 'canceled') { if (cancelled()) return; throw new ReplicateError('the provider cancelled the render', 'failed'); }
        if (status.status === 'failed') throw status.error ?? new ReplicateError('the render failed', 'failed');
        if (!status.url) throw new ReplicateError('no video came back', 'failed');
        if (!(await report(i, 0.92, 'Finishing'))) return;
        const raw = path.join(tmp, `raw_${i}.mp4`), take = path.join(tmp, `take_${i}.mp4`), thumb = path.join(tmp, `take_${i}.jpg`);
        await provider.download(status.url, raw);
        // Delivered as the provider made it: no trim, no re-encode. Sound off: the audio track is dropped by stream copy.
        if (plan.recast?.restoreAudio && plan.videos[0]?.video.key) {
          // Recast keeps the original sound: this model doesn't return it, so it goes back on by stream copy (no re-encode).
          const src = path.join(tmp, 'source');
          if (!fs.existsSync(src)) { const obj = await ctx.storage.get(plan.videos[0].video.key); if (!obj) throw new ReplicateError('the source clip is missing', 'failed'); await pipeline(obj.body, fs.createWriteStream(src)); }
          const si = await probe(c.FFPROBE_PATH, src);
          if (si.audioCodec) await restoreAudio(c.FFMPEG_PATH, raw, src, take, si.audioCodec); else await fs.promises.copyFile(raw, take);
        } else if (!plan.audio && model.audio === 'always') await stripAudio(c.FFMPEG_PATH, raw, take); else await fs.promises.copyFile(raw, take);
        const info = await probe(c.FFPROBE_PATH, take);
        await thumbnail(c.FFMPEG_PATH, take, thumb, Math.min(1, info.duration / 2));
        const key = `s/${job.id}/take_${i}.mp4`, thumbKey = `s/${job.id}/take_${i}.jpg`;
        const stored = await putFile(ctx, { key, file: take, studioId: job.studioId, kind: 'output', userId: job.userId, contentType: 'video/mp4' });
        await putFile(ctx, { key: thumbKey, file: thumb, studioId: job.studioId, kind: 'output', userId: job.userId, contentType: 'image/jpeg' });
        const out = status.billedSeconds ?? plan.seconds;
        ts.billed = billedSeconds(model, out, { videoInput: plan.videos.length > 0, guideSeconds: plan.videos[0]?.video.seconds });
        ts.output = { name: `take_${i}.mp4`, key, contentType: 'video/mp4', bytes: stored.bytes, sha256: stored.sha256, width: info.width, height: info.height, fps: info.fps,
          durationSec: Math.round(info.duration * 1000) / 1000, thumb: { url: `${c.PUBLIC_URL ?? ''}/uploads/${thumbKey}` } };
        ts.done = true; ts.key = key;
        await this.save(job.id, takes);
        outputs.push(ts.output); billed.push(ts.billed);
        for (const f of [raw, take, thumb]) fs.rmSync(f, { force: true });
      }
      // Settle: price × billed seconds (+ fixed extras); the mock charges nothing unless SUITE_MOCK_CHARGE.
      const exact = plan.perSec * billed.reduce((a, b) => a + b, 0) + plan.extraPerTake * n + separationCost;
      const actual = mock && !c.SUITE_MOCK_CHARGE ? 0 : exact;
      const fresh = ((await ctx.db.select({ stats: jobs.stats }).from(jobs).where(eq(jobs.id, job.id)))[0]?.stats ?? {}) as Record<string, any>;
      await ctx.jobs.complete(job.id, {
        outputs, actualCostUsd: actual, settleNote: `${shotNote(plan.tier, plan.resolution, outputs.map(o => Number(o.durationSec) || plan.seconds), plan.mode === 'recast' ? 'Recast' : 'Shot')}${mock ? ' · test render' : ''}`,
        stats: { ...fresh, suite: { ...(fresh.suite ?? {}), takes, billedSeconds: billed.reduce((a, b) => a + b, 0), exactCost: exact, separationCost } },
      });
    } catch (e) {
      if (st.cancelled || (e instanceof ReplicateError && e.kind === 'cancelled')) return;
      const f = failureOf(e);
      ctx.log.warn({ job: job.id, code: f.code, err: (e as Error).message }, 'suite job failed');
      if (f.code === 'provider_out_of_credit' && plan?.provider === 'replicate' && this.suite.mode === 'live') await ctx.engines.outOfCredit(job.studioId, 'replicate', (e as Error).message);
      await ctx.jobs.fail(job.id, f.message, f.retryable, f.code);
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  }
}
