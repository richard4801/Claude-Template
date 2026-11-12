// AI suite · the suite line: runs claimed suite jobs on their provider (or the mock). Like the Replicate line
// (services/replicateVideo.ts): FIFO, SUITE_MAX_CONCURRENT at once, prediction ids saved on the job so a restart resumes
// polling instead of paying twice, every take delivered exactly as the provider made it (no trim, no re-encode).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { and, eq, sql } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { clips, jobs, takes, uploads, type ImageRef } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { PaidLost, paidLostFailure, reportPaidLost, sleep } from '../services/paidLost.js';
import { ReplicateError } from '../replicate/client.js';
import { mediaToolsAvailable, probe, restoreAudio, stripAudio, thumbnail, type MediaInfo } from '../replicate/media.js';
import { frameOf, joinClips, segment } from './extendMedia.js';
import { finishPlan, finishTake, TARGET_LUFS } from './finish.js';
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
import type { ProviderStatus, VideoProvider } from './providers.js';

/** The pod id suite jobs are claimed under (no pod row exists for it). */
export const SUITE_POD = 'suite';
export { PAID_UNSAVED, PAID_UNCONFIRMED } from '../services/paidLost.js';
type TakeState = { id?: string; provider?: string; done?: boolean; key?: string; billed?: number; output?: Record<string, unknown>;
  /** When the provider request was made (the timeout counts from here, across restarts). */ startedAt?: number;
  /** Our timeout asked the provider to cancel at this time. */ cancelAsked?: number;
  /** The provider finished: it is paid for from here on, whatever happens on our side. */ paid?: boolean; result?: { url: string; billedSeconds?: number | null; at: number } };
type Running = { cancelled: boolean; ids: Set<string>; done: Promise<void> };
type Prepared = { urls: MediaUrls; prompt: string; separationCost: number; source?: { file: string; info: MediaInfo } };

export class SuiteRunner {
  private running = new Map<string, Running>();
  private stopping = false;
  /** This server instance, for the job lease (two instances overlap during a Railway deploy). */
  private readonly instance = `${os.hostname()}:${process.pid}:${Math.random().toString(36).slice(2, 10)}`;
  constructor(private ctx: Ctx, private suite: SuiteService) {}

  busy() { return this.running.size > 0; }
  async toolsReady() { return mediaToolsAvailable(this.ctx.config.FFMPEG_PATH, this.ctx.config.FFPROBE_PATH); }
  async idle() { await Promise.all([...this.running.values()].map(r => r.done)); }
  private leaseMs() { return Math.max(1, this.ctx.config.SUITE_LEASE_SEC) * 1000; }

  /**
   * Shutdown (a deploy or restart): no new runs; running ones step back at their next poll WITHOUT failing or cancelling
   * anything at the provider. Their jobs stay running with the provider's request id saved, and the next server instance
   * resumes polling that id. Waits at most SUITE_STOP_WAIT_SEC.
   */
  async stop() {
    this.stopping = true;
    let t: NodeJS.Timeout | undefined;
    await Promise.race([this.idle(), new Promise<void>(r => { t = setTimeout(r, Math.max(0, this.ctx.config.SUITE_STOP_WAIT_SEC) * 1000); t.unref?.(); })]);
    if (t) clearTimeout(t);
  }

  /** One pass: resume orphans (claimed, nobody running them after a restart), then start the oldest waiting ones. */
  async dispatch(waiting: JobRow[]) {
    if (this.stopping) return;
    const orphans = await this.ctx.db.select().from(jobs).where(and(eq(jobs.state, 'running'), eq(jobs.gpuState, 'claimed'), eq(jobs.podId, SUITE_POD)));
    for (const j of orphans) {
      if (this.running.has(j.id)) continue;
      // Another instance still checks in on it (the old one during a deploy's overlap): leave it there.
      const l = (j.stats as any)?.suite?.lease as { by?: string; at?: number } | undefined;
      if (l?.by && l.by !== this.instance && Date.now() - (l.at ?? 0) < this.leaseMs()) continue;
      this.launch(j);
    }
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
    const beat = setInterval(() => { void this.lease(job.id).catch(() => {}); }, Math.max(50, this.leaseMs() / 3));
    beat.unref?.();
    st.done = this.lease(job.id).catch(() => {}).then(() => this.run(job, st))
      .catch(e => this.ctx.log.error({ job: job.id, err: (e as Error).message }, 'suite run crashed'))
      .finally(async () => {
        clearInterval(beat);
        // Stepping back for a restart: let the next instance take it over at once.
        if (this.stopping) await this.lease(job.id, 0).catch(() => {});
        this.running.delete(job.id);
        if (!this.stopping) this.ctx.jobs.kick();
      });
  }

  /** "This instance runs the job" (atomic: never overwrites the saved takes). */
  private async lease(jobId: string, at = Date.now()) {
    const v = JSON.stringify({ by: this.instance, at });
    await this.ctx.db.update(jobs).set({ stats: sql`jsonb_set(coalesce(${jobs.stats}, '{}'::jsonb), '{suite,lease}', ${v}::jsonb, true)` })
      .where(and(eq(jobs.id, jobId), eq(jobs.state, 'running'), sql`jsonb_typeof(${jobs.stats}->'suite') = 'object'`));
  }

  /** The provider a saved take was started on. */
  private providerById(id: string | undefined): VideoProvider | undefined {
    if (!id) return undefined;
    if (this.suite.mode === 'mock') return this.suite.mock;
    return (this.suite.providers as Record<string, VideoProvider>)[id];
  }

  /**
   * Owner: brings back a suite job that failed after the provider made (or may have made) its video. Free: it only asks
   * the provider for the saved request's status and result (a GET); it never starts a new generation. The job runs
   * again on the line, downloads the result and saves it as a take, settled at the provider's cost.
   */
  async recover(u: AuthUser, jobId: string) {
    if (u.role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can do that');
    // Edit helpers (Genjutsu, slow motion) keep their own saved provider request (editor/service.ts).
    if (jobId.startsWith('edj_')) return (await import('../editor/service.js')).editorAi(this.ctx).recoverJob(u, jobId);
    const [j] = await this.ctx.db.select().from(jobs).where(and(eq(jobs.id, jobId), eq(jobs.studioId, u.studioId)));
    if (!j) throw notFound('Job');
    // Character swap (Replicate / Higgsfield line): its own saved predictions (services/replicateVideo.ts).
    if (j.request?.engine === 'replicate') return this.ctx.replicateVideo.recover(j);
    if (j.request?.engine !== 'suite') throw badRequest('Only AI Suite and Character swap jobs can be recovered');
    if (j.state === 'running') return { ok: true, state: 'running', job: jobId };
    if (j.state !== 'failed') throw badRequest('This job is not a failed one');
    const suite = ((j.stats as any)?.suite ?? {}) as { takes?: TakeState[]; plan?: unknown };
    const open = (suite.takes ?? []).filter(t => t.id && !t.done);
    if (!suite.plan || !open.length) throw badRequest('Nothing to recover: no provider request was saved for this job');
    const statuses: ProviderStatus['status'][] = [];
    for (const t of open) {
      const p = this.providerById(t.provider);
      if (!p) throw badRequest(`Nothing to recover: the provider (${t.provider ?? '?'}) is not set up`);
      const s = await p.get(t.id!).catch(() => ({ status: 'running' } as ProviderStatus));
      statuses.push(s.status);
    }
    if (statuses.every(s => s === 'failed' || s === 'canceled')) throw badRequest('The provider says this render failed or was cancelled, so nothing was made (and nothing was charged)');
    const stats = { ...((j.stats as object | null) ?? {}), suite: { ...suite, recovering: true, lease: null } } as Record<string, any>;
    delete stats.errorCode;
    const [row] = await this.ctx.db.update(jobs).set({ state: 'running', gpuState: 'claimed', podId: SUITE_POD, error: null, retryable: null, finishedAt: null,
      refunded: 0, holdTokens: 0, phase: 'Recovering the video', stats }).where(and(eq(jobs.id, jobId), eq(jobs.state, 'failed'))).returning();
    if (!row) throw badRequest('This job changed · try again');
    this.ctx.jobs.emitJob(row);
    this.ctx.log.warn({ job: jobId, statuses }, 'suite job: recovering a paid provider result');
    if (!this.running.has(jobId) && !this.stopping) this.launch(row);
    return { ok: true, state: 'recovering', job: jobId, provider: statuses };
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
      const take = row || clip ? null : (await this.ctx.db.select({ id: takes.id }).from(takes).where(and(eq(takes.mediaKey, key), eq(takes.studioId, studioId))))[0];
      if (!row && !clip && !take && !key.startsWith('assets/')) throw new ReplicateError('a video is not in this studio', 'failed');
      return this.ctx.storage.presignGet(key, ttl);
    }
    if (v.url && /^https:\/\//.test(v.url)) return v.url;
    throw new ReplicateError('a video could not be signed', 'failed');
  }

  /**
   * What starting a take needs: signed media URLs, the audio (vocals removed once, saved), the extend source. Only done
   * when a take must start (or an extend joins): a resumed job whose request is saved never fails here.
   */
  private async prepare(job: JobRow, plan: ShotPlan, mock: boolean, tmp: string, report: (i: number, f: number, label: string) => Promise<boolean>, cancelled: () => boolean): Promise<Prepared> {
    const ctx = this.ctx, c = ctx.config;
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
        type Sep = { instrumentalKey?: string | null; costUsd?: number; separated?: boolean; pending?: string };
        const saved = (job.stats as any)?.suite?.audio as Sep | undefined;
        let sep: Sep | undefined = saved && (saved.separated === false || (saved.instrumentalKey && (await ctx.storage.head(saved.instrumentalKey)))) ? saved : undefined;
        if (!sep && mock) sep = { instrumentalKey: null, costUsd: 0, separated: false };
        if (!sep) {
          if (!key) throw new ReplicateError('the audio must be an upload to separate its beat', 'failed');
          await report(1, 0.02, 'Preparing the audio');
          // The separation's prediction is saved as soon as it exists: a restart polls it, never pays for a second one.
          const b = await beatOnlyAudio(ctx, { studioId: job.studioId, userId: job.userId, jobId: job.id, audioKey: key, cancelled,
            resumeId: saved?.pending ?? null, onPrediction: id => this.saveExtra(job.id, { audio: { pending: id } }) }) as { instrumentalKey: string; costUsd: number; separated?: boolean; lost?: boolean };
          const separated = b.separated !== false && b.instrumentalKey !== key;
          // A separation that was paid but couldn't be saved is still billed (the shot runs on its no-audio prompt).
          sep = separated ? { instrumentalKey: b.instrumentalKey, costUsd: b.costUsd, separated: true } : { instrumentalKey: null, costUsd: b.lost ? b.costUsd ?? 0 : 0, separated: false };
          await this.saveExtra(job.id, { audio: sep });
        }
        separationCost = sep.costUsd ?? 0;
        if (sep.separated && sep.instrumentalKey) {
          urls.audio = await ctx.storage.presignGet(sep.instrumentalKey, c.REPLICATE_INPUT_URL_TTL_SEC);
        } else if (plan.promptNoAudio) {
          prompt = plan.promptNoAudio;
          await ctx.db.update(jobs).set({ prompt }).where(eq(jobs.id, job.id));
        }
      } else urls.audio = await this.videoUrl(plan.audioRef.ref, job.studioId);
    }
    // Extend: the part of the source the model continues from, or the bridge frame (the source itself stays whole for the join).
    let source: { file: string; info: MediaInfo } | undefined;
    const ex = plan.extend;
    if (ex) {
      await report(1, 0.02, 'Preparing the clip');
      const file = path.join(tmp, 'extend_source.mp4');
      const obj = await ctx.storage.get(ex.source.key);
      if (!obj) throw new ReplicateError('the clip to extend is missing', 'failed');
      await pipeline(obj.body, fs.createWriteStream(file));
      source = { file, info: await probe(c.FFPROBE_PATH, file) };
      const put = async (name: string, f: string, contentType: string) => {
        const key = `s/${job.id}/${name}`;
        await putFile(ctx, { key, file: f, studioId: job.studioId, kind: 'output', userId: job.userId, contentType });
        return ctx.storage.presignGet(key, c.REPLICATE_INPUT_URL_TTL_SEC);
      };
      if (ex.method === 'frame') {
        const f = path.join(tmp, 'bridge.jpg');
        await frameOf(c.FFMPEG_PATH, file, f, ex.direction === 'after' ? 'last' : 'first', source.info);
        const url = await put('bridge.jpg', f, 'image/jpeg');
        if (ex.direction === 'after') urls.start = url; else urls.end = url;
      } else if (ex.useSeconds < source.info.duration - 0.05) {
        const f = path.join(tmp, 'source_part.mp4');
        await segment(c.FFMPEG_PATH, file, f, ex.useSeconds, ex.direction === 'after' ? 'end' : 'start', source.info);
        urls.videos = [await put('source_part.mp4', f, 'video/mp4')];
      }
    }
    return { urls, prompt, separationCost, source };
  }

  private async run(job: JobRow, st: Running) {
    const ctx = this.ctx, c = ctx.config;
    const plan = (job.stats as any)?.suite?.plan as ShotPlan | undefined;
    const prior = ((job.stats as any)?.suite?.takes ?? []) as TakeState[];
    const recovering = !!(job.stats as any)?.suite?.recovering;
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-suite-'));
    const finishNotes = new Set<string>(); // AI suite (workstream 1): what finishing did (length cut, sound levelled)
    let n = Math.max(1, plan?.takes ?? 1);
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
    /** A deploy or restart: step back, the next instance resumes (nothing is failed or cancelled at the provider). */
    const leaving = () => this.stopping;
    let modelName = plan?.modelId ?? 'model';
    try {
      if (!plan) throw new Error('the shot plan is missing');
      if (plan.provider === 'byo') await this.suite.byo.ensure(job.studioId, true); // WS5: custom models are per studio
      let model = modelById(plan.modelId);
      if (!model) throw new ReplicateError('model no longer in the registry', 'unavailable');
      modelName = model.name ?? modelName;
      let provider = this.suite.providerFor(plan);
      let ref = plan.ref;
      const alt = modelById('h3');
      let moved = false;
      const moveToReplicate = () => { model = alt!; provider = this.suite.providers.replicate; ref = typeof alt!.ref === 'string' ? alt!.ref : (alt!.ref.ref2v ?? alt!.ref.t2v ?? ''); moved = true; };
      // A shot that already moved to Replicate (Higgsfield refused at its start) resumes there, never on Higgsfield again.
      if (provider.id === 'higgsfield' && alt && prior.some(t => t.id && t.provider === 'replicate')) moveToReplicate();
      const mock = provider.id === 'mock';
      if (!(await this.toolsReady())) throw new Error('ffmpeg is not installed on the server');
      await report(1, 0.01, 'Preparing');
      let prepared: Promise<Prepared> | undefined;
      const prepare = () => (prepared ??= this.prepare(job, plan, mock, tmp, report, cancelled));
      const inputFor = async () => {
        const p = await prepare();
        return buildInput(model!, { ...plan, prompt: p.prompt, ...(moved ? { resolution: '2K' } : {}) }, p.urls);
      };
      const takes: TakeState[] = prior.map(x => ({ ...x }));
      const outputs: Record<string, unknown>[] = [], billed: number[] = [];
      for (let i = 1; i <= n; i++) {
        const ts: TakeState = takes[i - 1] ?? {};
        takes[i - 1] = ts;
        if (ts.done && ts.key && ts.output && (await ctx.storage.head(ts.key))) { outputs.push(ts.output); billed.push(ts.billed ?? plan.billedPerTake); continue; }
        if (cancelled() || leaving()) return;
        // Resume: a saved request is polled by its id, never started (and paid) again. A failed status check counts as
        // "still running"; only the provider's own "no such request" (404) lets it start afresh.
        let status: ProviderStatus | null = null;
        if (ts.id && ts.provider === provider.id) {
          status = await provider.get(ts.id).catch(e => {
            ctx.log.warn({ job: job.id, err: (e as Error).message }, 'suite resume: status check failed, polling on');
            return e instanceof ReplicateError && e.status === 404 && !ts.paid ? null : { status: 'running' } as ProviderStatus;
          });
        }
        if (!status || status.status === 'canceled') {
          if (recovering) {
            // Recovery is free: it never starts a take. The takes it brought back are kept; the job is that many takes.
            if (billed.length) {
              n = billed.length;
              await ctx.db.update(jobs).set({ request: { ...job.request, takes: n } }).where(eq(jobs.id, job.id));
              await this.saveExtra(job.id, { plan: { ...plan, takes: n } });
              break;
            }
            throw new ReplicateError('nothing came back to recover', 'failed');
          }
          let input = await inputFor();
          if (!(await report(i, 0.03, 'Starting'))) return;
          const seeded = (x: Record<string, unknown>) => plan.seed != null && x.seed != null ? { ...x, seed: plan.seed + i - 1 } : x;
          const hooks = { cancelled, seconds: plan.seconds, onWait: async (s: number) => { await report(i, 0.03, `Waiting to start · retrying in ${s}s`); } };
          try {
            ts.id = await provider.start(ref, seeded(input), hooks);
          } catch (e) {
            // Higgsfield refused before anything ran (no credit, bad key, busy, down): skip it for a while and run the
            // same shot on Replicate H3 2K (same model, prompt and references). The quoted price stands (the studio
            // absorbs the difference); the owner sees why in the log. Nothing was charged by Higgsfield.
            const canMove = provider.id === 'higgsfield' && alt && e instanceof ReplicateError && ['out_of_credit', 'unavailable', 'rate_limited'].includes(e.kind)
              && !takes.some(t => t.id) && this.suite.providers.replicate.configured();
            if (!canMove) throw e;
            this.suite.markDown('higgsfield');
            ctx.log.warn({ job: job.id, reason: (e as Error).message }, 'higgsfield refused at start: running the shot on Replicate H3');
            moveToReplicate();
            input = await inputFor();
            ts.id = await provider.start(ref, seeded(input), hooks);
          }
          ts.provider = provider.id; ts.startedAt = Date.now();
          delete ts.cancelAsked; delete ts.paid; delete ts.result;
          await this.save(job.id, takes);
          status = { status: 'running' };
        }
        st.ids.add(ts.id!);
        const t0 = ts.startedAt ?? Date.now(), limit = c.SUITE_PREDICTION_TIMEOUT_SEC * 1000, grace = limit / 2;
        while (status.status === 'running') {
          if (leaving()) return;
          if (cancelled()) { await provider.cancel(ts.id!); return; }
          // Too long: ask the provider to cancel, then keep polling for its answer. A cancelled render isn't charged;
          // one that finishes anyway is paid, so it is still saved as a take. Fail only if it never answers.
          if (!ts.cancelAsked && Date.now() - t0 > limit) {
            await provider.cancel(ts.id!);
            ts.cancelAsked = Date.now();
            await this.save(job.id, takes);
            ctx.log.warn({ job: job.id }, 'suite take over its time: cancel asked, waiting for the provider');
          }
          if (ts.cancelAsked && Date.now() - ts.cancelAsked > grace) throw new PaidLost('unconfirmed', i, 'the provider neither finished nor cancelled');
          if (!(await report(i, 0.05 + 0.85 * Math.min(0.95, (Date.now() - t0) / 1000 / perTake), 'Rendering'))) { await provider.cancel(ts.id!); return; }
          await sleep(c.SUITE_POLL_MS);
          if (leaving()) return;
          try { status = await provider.get(ts.id!); } catch (e) {
            ctx.log.warn({ job: job.id, err: (e as Error).message }, 'suite status check failed, polling on');
            status = { status: 'running' };
          }
        }
        st.ids.delete(ts.id!);
        if (status.status === 'canceled') {
          if (cancelled()) return;
          if (ts.cancelAsked) throw new ReplicateError('timed out', 'timeout');
          throw new ReplicateError('the provider cancelled the render', 'failed');
        }
        if (status.status === 'failed') throw status.error ?? new ReplicateError('the render failed', 'failed');
        if (!status.url) throw new ReplicateError('no video came back', 'failed');
        // From here the provider has made (and charged for) the video: it must become a take. Nothing below may fail
        // the job as "not charged"; what can't be finished is skipped, what can't be saved is reported as recoverable.
        ts.paid = true; ts.result = { url: status.url, billedSeconds: status.billedSeconds ?? null, at: Date.now() };
        await this.save(job.id, takes);
        if (!(await report(i, 0.92, 'Finishing'))) return;
        let extension: Record<string, unknown> | undefined;
        try {
          extension = await this.deliver({ job, plan, model, provider, ts, i, tmp, prepare, finishNotes, leaving, url: status.url });
        } catch (e) {
          if (leaving() || e instanceof PaidLost) throw e;
          throw new PaidLost('unsaved', i, (e as Error).message);
        }
        const out = ts.result.billedSeconds ?? plan.seconds;
        ts.billed = billedSeconds(model, out, { videoInput: plan.videos.length > 0, guideSeconds: plan.videos[0]?.video.seconds });
        ts.done = true;
        await this.save(job.id, takes);
        outputs.push(ts.output!); billed.push(ts.billed);
        if (extension) outputs.push(extension);
      }
      // Settle: price × billed seconds (+ fixed extras); the mock charges nothing unless SUITE_MOCK_CHARGE.
      const savedSep = (job.stats as any)?.suite?.audio as { separated?: boolean; costUsd?: number } | undefined;
      const separationCost = prepared ? (await prepared).separationCost : savedSep?.costUsd ?? 0;
      const exact = plan.perSec * billed.reduce((a, b) => a + b, 0) + plan.extraPerTake * n + separationCost;
      const actual = mock && !c.SUITE_MOCK_CHARGE ? 0 : exact;
      const fresh = ((await ctx.db.select({ stats: jobs.stats }).from(jobs).where(eq(jobs.id, job.id)))[0]?.stats ?? {}) as Record<string, any>;
      await ctx.jobs.complete(job.id, {
        outputs, actualCostUsd: actual, settleNote: `${shotNote(plan.tier, plan.resolution, outputs.map(o => Number(o.durationSec) || plan.seconds), plan.mode === 'recast' ? 'Recast' : plan.mode === 'extend' ? 'Extend' : 'Shot')}${mock ? ' · test render' : ''}${recovering ? ' · recovered' : ''}`,
        stats: { ...fresh, suite: { ...(fresh.suite ?? {}), takes, billedSeconds: billed.reduce((a, b) => a + b, 0), exactCost: exact, separationCost, ...(finishNotes.size ? { finished: [...finishNotes] } : {}) } },
      });
    } catch (e) {
      if (st.cancelled || (e instanceof ReplicateError && e.kind === 'cancelled')) return;
      if (leaving()) { ctx.log.info({ job: job.id, err: (e as Error).message }, 'suite job left for the next server instance'); return; }
      if (e instanceof PaidLost) {
        // Paid (or maybe paid) at the provider and not a take: say so, keep the request id, tell the owner.
        ctx.log.error({ job: job.id, take: e.take, kind: e.kind, err: e.why }, 'suite job: provider result paid but not saved');
        await this.saveExtra(job.id, { lost: { take: e.take, kind: e.kind, why: e.why.slice(0, 300), at: Date.now() } }).catch(() => {});
        const f = paidLostFailure(e);
        await ctx.jobs.fail(job.id, f.message, false, f.code);
        await reportPaidLost(ctx, job, modelName, e, 'suite_runner').catch(err => ctx.log.warn({ err: (err as Error).message }, 'suite: could not record the issue'));
        return;
      }
      const f = failureOf(e);
      ctx.log.warn({ job: job.id, code: f.code, err: (e as Error).message }, 'suite job failed');
      if (f.code === 'provider_out_of_credit' && plan?.provider === 'replicate' && this.suite.mode === 'live') await ctx.engines.outOfCredit(job.studioId, 'replicate', (e as Error).message);
      await ctx.jobs.fail(job.id, f.message, f.retryable, f.code);
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  }

  /**
   * Download the provider's video and make it a take. Only the download, the probe and the store are required; sound
   * removal, finishing, the extend join and the thumbnail fall back to the video as the provider made it.
   */
  private async deliver(o: { job: JobRow; plan: ShotPlan; model: NonNullable<ReturnType<typeof modelById>>; provider: VideoProvider; ts: TakeState; i: number; tmp: string;
    prepare: () => Promise<Prepared>; finishNotes: Set<string>; leaving: () => boolean; url: string }) {
    const { job, plan, model, provider, ts, i, tmp, finishNotes } = o;
    const ctx = this.ctx, c = ctx.config, ex = plan.extend;
    const raw = path.join(tmp, `raw_${i}.mp4`), take = path.join(tmp, `take_${i}.mp4`), thumb = path.join(tmp, `take_${i}.jpg`);
    // Download, retried; between tries the provider is asked again (a fresh result URL). A status GET is free.
    let url = o.url, last: unknown;
    for (let a = 0; a < 3; a++) {
      try { await provider.download(url, raw); last = undefined; break; } catch (e) {
        last = e;
        ctx.log.warn({ job: job.id, try: a + 1, err: (e as Error).message }, 'suite download failed');
        if (o.leaving()) throw e;
        await sleep(Math.min(10_000, c.SUITE_POLL_MS * (a + 1)));
        const s = await provider.get(ts.id!).catch(() => null);
        if (s?.status === 'succeeded' && s.url) url = s.url;
      }
    }
    if (last) throw last;
    const soft = async (what: string, fn: () => Promise<void>) => {
      try { await fn(); return true; } catch (e) {
        if (o.leaving()) throw e;
        ctx.log.warn({ job: job.id, step: what, err: (e as Error).message }, 'suite finishing step skipped');
        finishNotes.add(`${what} skipped (kept as the provider made it)`);
        return false;
      }
    };
    // Sound off: the audio track is dropped by stream copy. Then finishing (below) cuts to the planned length and levels the sound.
    let shaped = false;
    if (plan.recast?.restoreAudio && plan.videos[0]?.video.key) {
      // Recast keeps the original sound: this model doesn't return it, so it goes back on by stream copy (no re-encode).
      shaped = await soft('putting the original sound back', async () => {
        const src = path.join(tmp, 'source');
        if (!fs.existsSync(src)) { const obj = await ctx.storage.get(plan.videos[0]!.video.key!); if (!obj) throw new ReplicateError('the source clip is missing', 'failed'); await pipeline(obj.body, fs.createWriteStream(src)); }
        const si = await probe(c.FFPROBE_PATH, src);
        if (si.audioCodec) await restoreAudio(c.FFMPEG_PATH, raw, src, take, si.audioCodec); else await fs.promises.copyFile(raw, take);
      });
    } else if (!plan.audio && model.audio === 'always') shaped = await soft('removing the sound', () => stripAudio(c.FFMPEG_PATH, raw, take));
    if (!shaped) await fs.promises.copyFile(raw, take);
    // AI suite (workstream 1): the planned length (a provider may round up) and even loudness (~−16 LUFS) for the
    // model's own sound. Recast keeps the original sound and length; Extend is cut by its join, not here.
    if (!plan.recast) {
      await soft('finishing (length and sound level)', async () => {
        const ti = await probe(c.FFPROBE_PATH, take);
        const fp = finishPlan(ti, ex ? null : plan.seconds, { level: true });
        const fin = path.join(tmp, `finished_${i}.mp4`);
        const did = await finishTake(c.FFMPEG_PATH, take, fin, ti, fp);
        if (did) {
          await fs.promises.rename(fin, take);
          if (did.trimmedFrom) finishNotes.add(`cut to the planned ${plan.seconds} s (the render came back ${did.trimmedFrom} s)`);
          if (did.levelledFrom != null) finishNotes.add(`sound levelled to ${TARGET_LUFS} LUFS (was ${did.levelledFrom})`);
        }
      });
    }
    let extension: Record<string, unknown> | undefined;
    const source = ex?.join ? (await o.prepare().catch(() => undefined))?.source : undefined;
    if (ex && source && ex.join) {
      // One take: source then extension (after) or extension then source (before). The extension alone is kept too.
      const ext = { file: path.join(tmp, `extension_${i}.mp4`), info: await probe(c.FFPROBE_PATH, take) };
      await fs.promises.copyFile(take, ext.file);
      await soft('joining to the clip', async () => {
        let head: { file: string; info: MediaInfo } | null = source;
        // ⚠ unverified: a continuation model may return the clip it continued from plus the new part (longer than asked).
        if (ex.method === 'clip' && ex.direction === 'after' && ext.info.duration > plan.seconds + 1) {
          const keep = source.info.duration - ex.useSeconds;
          if (keep < 0.2) head = null;
          else { const f = path.join(tmp, 'source_head.mp4'); await segment(c.FFMPEG_PATH, source.file, f, keep, 'start', source.info); head = { file: f, info: await probe(c.FFPROBE_PATH, f) }; }
        }
        if (!head) await fs.promises.copyFile(ext.file, take);
        else if (ex.direction === 'after') await joinClips(c.FFMPEG_PATH, head, ext, take, source.info);
        else await joinClips(c.FFMPEG_PATH, ext, head, take, source.info);
      });
      const extKey = `s/${job.id}/extension_${i}.mp4`;
      const stored = await this.store({ key: extKey, file: ext.file, studioId: job.studioId, userId: job.userId, contentType: 'video/mp4' });
      extension = { name: `extension_${i}.mp4`, key: extKey, contentType: 'video/mp4', bytes: stored.bytes, durationSec: Math.round(ext.info.duration * 1000) / 1000 };
      fs.rmSync(ext.file, { force: true });
    }
    const info = await probe(c.FFPROBE_PATH, take);
    const key = `s/${job.id}/take_${i}.mp4`, thumbKey = `s/${job.id}/take_${i}.jpg`;
    const stored = await this.store({ key, file: take, studioId: job.studioId, userId: job.userId, contentType: 'video/mp4' });
    let hasThumb = false;
    try {
      await thumbnail(c.FFMPEG_PATH, take, thumb, Math.min(1, info.duration / 2));
      await this.store({ key: thumbKey, file: thumb, studioId: job.studioId, userId: job.userId, contentType: 'image/jpeg' });
      hasThumb = true;
    } catch (e) { if (o.leaving()) throw e; ctx.log.warn({ job: job.id, err: (e as Error).message }, 'suite thumbnail skipped'); }
    ts.output = { name: `take_${i}.mp4`, key, contentType: 'video/mp4', bytes: stored.bytes, sha256: stored.sha256, width: info.width, height: info.height, fps: info.fps,
      durationSec: Math.round(info.duration * 1000) / 1000, ...(hasThumb ? { thumb: { url: `${c.PUBLIC_URL ?? ''}/uploads/${thumbKey}` } } : {}) };
    ts.key = key;
    for (const f of [raw, take, thumb]) fs.rmSync(f, { force: true });
    return extension;
  }

  /** putFile, tried twice (a storage blip must not lose a paid video). */
  private async store(f: { key: string; file: string; studioId: string; userId: string | null; contentType: string }) {
    try { return await putFile(this.ctx, { ...f, kind: 'output' }); } catch (e) {
      this.ctx.log.warn({ key: f.key, err: (e as Error).message }, 'suite store failed, trying again');
      await sleep(1000);
      return putFile(this.ctx, { ...f, kind: 'output' });
    }
  }
}
