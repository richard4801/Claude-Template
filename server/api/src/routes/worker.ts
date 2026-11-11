// Worker protocol (plans/backend.md, "Worker protocol"). The GPU worker on each pod authenticates with
// `Authorization: Bearer <WORKER_TOKEN>` (issued per pod at start), pulls jobs, reports progress and results.
import { and, eq, inArray } from 'drizzle-orm';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../ctx.js';
import { clips, jobs, loras, models, outfits, pods } from '../db/schema.js';
import { ApiError } from '../errors.js';
import { SOMETHING_WENT_WRONG } from '../services/jobs.js';
import { sha256, uid } from '../lib/util.js';
import { contentTypeFor } from '../storage/index.js';
import { cleanStored, objectInfo } from '../storage/objects.js';
import * as P from '../pricing.js';
import { workKindOf, type JobRow, type PodRow, type WorkKind } from '../gpu/controller.js';
import type { PodPool } from '../gpu/pool.js';

// Every optional field may be absent (the worker omits rather than sending null); null is tolerated too.
const opt = <T extends z.ZodTypeAny>(t: T) => t.nullish().transform(v => v ?? undefined);
const Claim = z.object({ podId: opt(z.string().max(100)), gpu: opt(z.string().max(100)), capabilities: opt(z.array(z.string().max(40)).max(20)) }).passthrough();
const Progress = z.object({ step: z.number().int().min(0), totalSteps: z.number().int().min(1), phase: opt(z.string().max(100)), etaSeconds: opt(z.number().nonnegative()),
  take: opt(z.number().int().min(1)), takes: opt(z.number().int().min(1)) }).passthrough();
const Output = z.object({ name: z.string().max(200), bytes: opt(z.number()), sha256: opt(z.string().max(128)), width: opt(z.number()), height: opt(z.number()),
  fps: opt(z.number()), durationSec: opt(z.number()), contentType: opt(z.string().max(100)) }).passthrough();
const Stats = z.object({ load_s: opt(z.number().nonnegative()), gen_s: opt(z.number().nonnegative()), step_times_s: opt(z.array(z.number())), peak_vram_gb: opt(z.number()), attention: opt(z.string().max(50)) }).passthrough();
const Done = z.object({ outputs: opt(z.array(Output)), gpuSeconds: opt(z.number().nonnegative()), stats: opt(Stats) }).passthrough();
const Failed = z.object({ error: opt(z.string().max(2000)), retryable: opt(z.boolean()) }).passthrough();
const Heartbeat = z.object({ podId: opt(z.string().max(100)), busy: opt(z.boolean()), jobId: opt(z.string().max(100)), state: opt(z.string().max(60)) }).passthrough();

/** Capabilities the worker advertises → job kinds it can run. */

export async function registerWorkerRoutes(app: FastifyInstance, ctx: Ctx) {
  const pool = ctx.gpu as unknown as PodPool;
  const ttl = () => ctx.config.PRESIGN_TTL_SEC;

  /** The pod behind the bearer token. The static WORKER_TOKEN (dev) gets a "manual" pod that may take anyone's job. */
  async function podFor(req: FastifyRequest, bodyPodId?: string): Promise<{ pod: PodRow; manual: boolean }> {
    const h = req.headers.authorization;
    const token = h?.startsWith('Bearer ') ? h.slice(7).trim() : '';
    if (!token) throw new ApiError(401, 'unauthorized', 'Worker token required');
    const [pod] = await ctx.db.select().from(pods).where(and(eq(pods.workerTokenHash, sha256(token)), inArray(pods.state, ['starting', 'running'])));
    if (pod) return { pod, manual: false };
    const st = ctx.config.WORKER_TOKEN;
    if (st && token.length === st.length && sha256(token) === sha256(st)) {
      // One "manual" pod for the static token (progress/done carry no podId, so it can't depend on the body).
      void bodyPodId;
      const id = 'manual';
      const [m] = await ctx.db.select().from(pods).where(eq(pods.id, id));
      if (m && m.state !== 'stopped') return { pod: m, manual: true };
      const now = Date.now();
      const [n] = await ctx.db.insert(pods).values({ id, studioId: 'manual', workerTokenHash: sha256(`manual:${id}`), state: 'running', gpuType: 'manual', startedAt: now, readyAt: now,
        lastHeartbeatAt: now, warmupCharged: true, idleSince: now }).onConflictDoUpdate({ target: pods.id, set: { state: 'running', lastHeartbeatAt: now, stoppedAt: null } }).returning();
      return { pod: n!, manual: true };
    }
    throw new ApiError(401, 'unauthorized', 'Unknown or expired worker token');
  }

  async function jobOf(pod: PodRow, id: string) {
    const [j] = await ctx.db.select().from(jobs).where(eq(jobs.id, id));
    if (!j || j.podId !== pod.id) throw new ApiError(404, 'not_found', 'Job not found for this pod');
    return j;
  }

  /** The claim payload: presigned R2 GETs for inputs and PUTs for outputs. */
  async function payload(j: JobRow) {
    const kind = workKindOf(j);
    const inputs: { name: string; url: string; bytes?: number; sha256?: string }[] = [];
    const outputs: { name: string; uploadUrl: string; key: string; contentType: string }[] = [];
    /** Adds a stored object as an input with its size and sha256 so the worker can verify the download. */
    const addKey = async (name: string, key: string | null) => {
      if (!key) return;
      const info = await objectInfo(ctx, key);
      if (!info) return;
      inputs.push({ name, url: await ctx.storage.presignGet(key, ttl()), bytes: info.bytes, sha256: info.sha256 });
    };
    const add = async (name: string, ref: Parameters<typeof ctx.images.storedKey>[0]) => addKey(name, await ctx.images.storedKey(ref, j.studioId));
    const out = async (name: string, key: string, contentType: string) => outputs.push({ name, key, contentType, uploadUrl: (await ctx.storage.presignPut(key, contentType, ttl())).url });
    const [m] = await ctx.db.select().from(models).where(eq(models.id, j.modelId));
    let params: Record<string, unknown>;
    if (kind === 'lora-train') {
      const [l] = await ctx.db.select().from(loras).where(eq(loras.modelId, j.modelId));
      const kept = (l?.candidates ?? []).filter(c => c.keep);
      for (const [i, c] of kept.entries()) await add(`train_${String(i + 1).padStart(2, '0')}.jpg`, c.image);
      for (const s of m?.slots ?? []) if (s.image) await add(`ref_${s.key}.jpg`, s.image);
      const token = String(j.request.token);
      for (const n of ['lora_photo.safetensors', 'lora_video.safetensors']) await out(n, `l/${j.modelId}/v${j.request.version}/${n}`, 'application/octet-stream');
      params = { token, version: j.request.version, rank: j.request.rank ?? 16, photoMinutes: j.request.photoMinutes, videoMinutes: j.request.videoMinutes,
        captions: Object.fromEntries(kept.map((c, i) => [`train_${String(i + 1).padStart(2, '0')}.jpg`, `${token}, ${c.label}`])) };
    } else if (kind === 'upscale') {
      // Upscale (SeedVR2): the finished take in, one upscaled take out at the size's frame (aspect kept, long side fitted).
      const r = j.request, z = P.UPSCALE_SIZES.find(x => x.id === r.size);
      await addKey('source.mp4', r.sourceKey ?? null);
      await out('take_1.mp4', `r/${j.id}/take_1.mp4`, 'video/mp4');
      params = { engine: 'upscale', size: r.size, width: z?.width, height: z?.height, seconds: r.seconds, source: 'source.mp4', keepAudio: true };
    } else {
      const r = j.request;
      const [clip] = r.clipId ? await ctx.db.select().from(clips).where(eq(clips.id, r.clipId)) : [];
      await addKey('source.mp4', clip?.storageKey ?? null);
      // References as chosen at submit time (≤ 6, tested order), named so image_n matches <Image n> in the prompt.
      const refs = (r.references ?? []) as { label: string; image: Parameters<typeof add>[1] }[];
      for (const [i, x] of refs.entries()) await add(`image_${i + 1}.jpg`, x.image);
      const n = r.takes ?? 1;
      for (let i = 1; i <= n; i++) await out(`take_${i}.mp4`, `r/${j.id}/take_${i}.mp4`, 'video/mp4');
      params = { engine: r.engine ?? 'h3', takes: n, seeds: Array.from({ length: n }, (_, i) => j.seed + i), use: r.use ?? 'first', lengthSec: P.lengthSec(r),
        clipSeconds: r.clipSeconds ?? clip?.durationSec ?? null, keepAudio: r.keepAudio ?? true, audioMode: r.keepAudio === false ? 'replace' : 'fully_copy',
        lipSync: !!r.lipSync, background: r.background ?? 'keep', backgroundMotion: r.backgroundMotion ?? 'subtle', lora: r.lora ?? null,
        // Input names, in <Image n> order; `source` is the input name of the clip.
        references: refs.map((_, i) => `image_${i + 1}.jpg`), referenceLabels: refs.map(x => x.label),
        source: clip?.storageKey ? 'source.mp4' : undefined, audioSource: 'source',
        sourceInfo: clip ? { width: clip.width, height: clip.height, fps: clip.fps, durationSec: clip.durationSec } : undefined };
    }
    await ctx.db.update(jobs).set({ outputs: outputs.map(o => ({ name: o.name, key: o.key })) }).where(eq(jobs.id, j.id));
    return {
      job: { id: j.id, kind, params, inputs, outputs: outputs.map(({ name, uploadUrl, contentType }) => ({ name, uploadUrl, contentType })), prompt: j.prompt, seed: j.seed,
        steps: kind === 'lora-train' || kind === 'upscale' ? null : j.request.engine === 'viggle' ? 4 : j.request.steps ?? P.STEPS_DEFAULT },
    };
  }

  app.post('/worker/v1/claim', async (req, reply) => {
    const b = Claim.parse(req.body ?? {});
    let { pod, manual } = await podFor(req, b.podId);
    const now = Date.now();
    pod = await pool.markReady(pod, now);
    await ctx.db.update(pods).set({ lastHeartbeatAt: now }).where(eq(pods.id, pod.id));
    const caps = b.capabilities?.length ? b.capabilities : undefined;
    await ctx.db.update(pods).set({ capabilities: caps ?? null }).where(eq(pods.id, pod.id));
    // A worker that restarted mid-job gets its job again.
    if (pod.currentJobId) {
      const [cur] = await ctx.db.select().from(jobs).where(eq(jobs.id, pod.currentJobId));
      if (cur && cur.state === 'running' && cur.gpuState === 'claimed' && cur.podId === pod.id) return payload(cur);
    }
    let job: JobRow | null;
    if (manual) {
      job = await ctx.jobs.claimFor({ ...pod, gpuType: b.gpu ?? pod.gpuType }, caps, true);
      if (job) await ctx.db.update(pods).set({ currentJobId: job.id, busy: true, idleSince: null }).where(eq(pods.id, pod.id));
    } else job = await pool.claimForPod(pod, now, caps);
    if (!job) return reply.status(204).send();
    req.log.info({ job: job.id, pod: pod.id }, 'job claimed');
    return payload(job);
  });

  app.post<{ Params: { id: string } }>('/worker/v1/jobs/:id/progress', async (req, reply) => {
    const { pod } = await podFor(req);
    const b = Progress.parse(req.body ?? {});
    const j = await jobOf(pod, req.params.id);
    await ctx.db.update(pods).set({ lastHeartbeatAt: Date.now() }).where(eq(pods.id, pod.id));
    const fields = j.kind === 'lora-train'
      ? { progress: Math.min(99.9, b.step / b.totalSteps * 100), step: b.step, totalSteps: b.totalSteps, phase: b.phase ?? 'Training', secondsLeft: b.etaSeconds ?? 0 }
      : P.progressFromWorker(b.takes ? { ...j.request, takes: b.takes } : j.request, b);
    if (!(await ctx.jobs.progress(j.id, fields))) throw new ApiError(409, 'job_cancelled', 'This job was cancelled or has ended · stop working on it');
    return reply.status(204).send();
  });

  app.post<{ Params: { id: string } }>('/worker/v1/jobs/:id/done', async (req, reply) => {
    const { pod, manual } = await podFor(req);
    const b = Done.parse(req.body ?? {});
    const j = await jobOf(pod, req.params.id);
    if (j.state !== 'running') throw new ApiError(409, 'job_cancelled', 'This job was cancelled or has ended');
    const planned = (j.outputs ?? []) as { name: string; key: string }[];
    const reported = b.outputs ?? [];
    for (const o of planned) {
      if (!reported.some(x => x.name === o.name)) continue;
      if (!(await ctx.storage.head(o.key))) throw new ApiError(400, 'output_missing', `${o.name} was not uploaded`);
    }
    // gpuSeconds is wall time from claim to done, including the model load on a pod's first job. The job pays for
    // gpuSeconds − load_s; the load goes on the pod's "GPU warm-up" line (its user's, or the owner's overhead).
    const load = Math.min(b.gpuSeconds ?? 0, b.stats?.load_s ?? 0);
    const rate = pod.costPerHr || ctx.config.GPU_HOURLY_USD;
    if (load > 0 && !manual && !j.warmSessionId) await pool.chargeWarmup(pod, load, j.id, 'Add-on start-up: model load');
    // Upscale is sold at its quoted price per output second (measured), not by GPU time.
    const fixed = j.request.engine === 'upscale' && typeof j.request.usd === 'number' ? { actualCostUsd: j.request.usd, settleNote: `${P.upscaleLabel(j.request.size)} · ${j.request.seconds} s` } : {};
    await ctx.jobs.complete(j.id, { outputs: reported, gpuSeconds: b.gpuSeconds == null ? undefined : b.gpuSeconds - load, costPerHr: rate, stats: b.stats ?? null, ...fixed });
    await pool.jobEnded(pod.id, Date.now());
    // The outputs arrived through presigned PUTs: their metadata goes in the background (storage/clean.ts).
    for (const o of planned) if (reported.some(x => x.name === o.name) && /\.(mp4|mov|jpe?g|png|webp)$/.test(o.key))
      void cleanStored(ctx, o.key, contentTypeFor(o.key)).catch(e => req.log.warn({ err: (e as Error).message, key: o.key }, 'output metadata cleanup failed'));
    return reply.status(204).send();
  });

  app.post<{ Params: { id: string } }>('/worker/v1/jobs/:id/failed', async (req, reply) => {
    const { pod } = await podFor(req);
    const b = Failed.parse(req.body ?? {});
    const j = await jobOf(pod, req.params.id);
    // The worker's own words (CUDA, OOM, paths) go to the log; members see a plain message.
    req.log.warn({ job: j.id, pod: pod.id, retryable: b.retryable, err: (b.error ?? '').slice(0, 500) }, 'worker reported failure');
    await ctx.jobs.fail(j.id, SOMETHING_WENT_WRONG, b.retryable ?? false);
    await pool.jobEnded(pod.id, Date.now());
    return reply.status(204).send();
  });

  app.post('/worker/v1/heartbeat', async (req, reply) => {
    const b = Heartbeat.parse(req.body ?? {});
    const found = await podFor(req, b.podId);
    const now = Date.now();
    const pod = await pool.markReady(found.pod, now);
    await ctx.db.update(pods).set({ lastHeartbeatAt: now, busy: !!b.busy, workerState: b.state ?? null }).where(eq(pods.id, pod.id));
    if (b.jobId && b.jobId === pod.currentJobId) await ctx.db.update(jobs).set({ lastProgressAt: now }).where(eq(jobs.id, b.jobId));
    // The worker's dead-man's switch fired (gpu/worker/muse_worker/selfstop.py): it is terminating its own pod.
    // Settle the pod's idle time and terminate it from here too (harmless if RunPod already removed it).
    if (b.state === 'self-stopping' && !found.manual && !pod.currentJobId) {
      req.log.warn({ pod: pod.id, reason: (req.body as any)?.reason }, 'worker is self-stopping its pod');
      await pool.stopPod({ ...pod, lastHeartbeatAt: now }, now, 'worker self-stop');
    }
    return reply.status(204).send();
  });
  void uid;
}
