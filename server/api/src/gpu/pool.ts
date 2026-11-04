// Pod pool shared by the simulated and RunPod controllers (see controller.ts for the model).
import { and, desc, eq, inArray } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { jobs, pods } from '../db/schema.js';
import { randomToken, sha256, uid } from '../lib/util.js';
import * as P from '../pricing.js';
import { gpuCanRun, gpuTable, workKindOf, type GpuController, type JobRow, type PodRow, type WorkKind } from './controller.js';
import type { RunpodApi } from './runpodApi.js';

export abstract class PodPool implements GpuController {
  abstract readonly mode: 'simulated' | 'runpod';
  /** Last launch failure per job kind (no GPU of that type available), for status and back-off. */
  protected launchFailedAt = new Map<WorkKind, { at: number; message: string }>();
  protected launchBackoffMs = 60_000;
  constructor(protected ctx: Ctx) {}

  /** Start the machine for a new pod row. Returns null when no GPU from the kind's list is available. */
  protected abstract launch(pod: PodRow, kind: WorkKind, workerToken: string): Promise<{ runpodId: string | null; gpuType: string; costPerHr: number; ready: boolean } | null>;
  protected abstract terminate(pod: PodRow): Promise<void>;
  /** Called for each ready pod without a job on every dispatch (the simulated pool claims and runs here). */
  protected async idlePod(_pod: PodRow, _now: number) {}
  /** Extra housekeeping (heartbeats). */
  protected async health(_now: number) {}

  async maxGpus(studioId: string) {
    const s = await this.ctx.money.settings(studioId);
    return s.maxGpus ?? this.ctx.config.MAX_GPUS;
  }
  async activePods() {
    return this.ctx.db.select().from(pods).where(inArray(pods.state, ['starting', 'running']));
  }

  async dispatch(waiting: JobRow[], now: number) {
    let active = await this.activePods();
    const users: string[] = [];
    for (const j of waiting) if (j.userId && !users.includes(j.userId)) users.push(j.userId);
    for (const u of users) {
      const first = waiting.find(j => j.userId === u)!;
      const kind = workKindOf(first);
      if (active.some(p => p.assignedUserId === u && gpuCanRun(this.ctx.config, p.gpuType, kind))) continue;
      // Warm reuse: an idle, ready pod whose user has nothing else it can run.
      const idle = active.find(p => p.state === 'running' && !p.currentJobId && gpuCanRun(this.ctx.config, p.gpuType, kind)
        && !waiting.some(w => w.userId === p.assignedUserId && gpuCanRun(this.ctx.config, p.gpuType, workKindOf(w))));
      if (idle) {
        await this.chargeIdle(idle, now);
        const [r] = await this.ctx.db.update(pods).set({ assignedUserId: u, idleSince: now }).where(eq(pods.id, idle.id)).returning();
        this.ctx.log.info({ pod: idle.id, from: idle.assignedUserId, to: u }, 'warm pod handed to another user');
        active = active.map(p => (p.id === idle.id ? r! : p));
        continue;
      }
      if (active.length >= (await this.maxGpus(first.studioId))) continue; // waits for the next free pod
      const failed = this.launchFailedAt.get(kind);
      if (failed && now - failed.at < this.launchBackoffMs) continue;
      const pod = await this.startPod(first, kind, now);
      if (pod) active.push(pod);
    }
    for (const p of active) if (p.state === 'running' && !p.currentJobId) await this.idlePod(p, now);
  }

  private async startPod(job: JobRow, kind: WorkKind, now: number) {
    const token = randomToken();
    const [row] = await this.ctx.db.insert(pods).values({
      id: uid('pod'), studioId: job.studioId, simulated: this.mode === 'simulated', workerTokenHash: sha256(token), state: 'starting',
      gpuType: gpuTable(this.ctx.config)[kind][0] ?? 'unknown', assignedUserId: job.userId, startedForJobId: job.id, startedAt: now,
    }).returning();
    let res: Awaited<ReturnType<PodPool['launch']>> = null;
    try { res = await this.launch(row!, kind, token); } catch (e) { this.ctx.log.error({ err: (e as Error).message }, 'pod launch failed'); }
    if (!res) {
      const message = `No ${gpuTable(this.ctx.config)[kind].join(' / ')} available right now; the job stays queued and we retry`;
      this.launchFailedAt.set(kind, { at: now, message });
      await this.ctx.db.update(pods).set({ state: 'failed', stoppedAt: now, error: message }).where(eq(pods.id, row!.id));
      this.ctx.log.warn({ kind }, 'no GPU available');
      return null;
    }
    this.launchFailedAt.delete(kind);
    const [up] = await this.ctx.db.update(pods).set({
      runpodId: res.runpodId, gpuType: res.gpuType, costPerHr: res.costPerHr,
      ...(res.ready ? { state: 'running' as const, readyAt: now, idleSince: now, lastHeartbeatAt: now } : {}),
    }).where(eq(pods.id, row!.id)).returning();
    this.ctx.log.info({ pod: up!.id, gpu: res.gpuType, user: job.userId }, 'pod started');
    return up!;
  }

  /** A pod reported in (claim or heartbeat): mark it ready. */
  async markReady(pod: PodRow, now: number) {
    if (pod.state !== 'starting') return pod;
    const [u] = await this.ctx.db.update(pods).set({ state: 'running', readyAt: now, idleSince: pod.currentJobId ? null : now, lastHeartbeatAt: now })
      .where(eq(pods.id, pod.id)).returning();
    return u!;
  }

  /** Claim the pod's next job; charges the warm-up to that job's user the first time. */
  async claimForPod(pod: PodRow, now: number, caps?: string[]) {
    const job = await this.ctx.jobs.claimFor(pod, caps);
    if (!job) {
      if (!pod.idleSince) await this.ctx.db.update(pods).set({ idleSince: now }).where(eq(pods.id, pod.id));
      return null;
    }
    // Idle time before this job, then the start-up time if this is the pod's first job.
    if (pod.idleSince && pod.warmupCharged) await this.charge(pod, (now - pod.idleSince) / 1000, job.id, 'GPU idle before the job');
    await this.ctx.db.update(pods).set({ currentJobId: job.id, busy: true, idleSince: null, warmupCharged: true }).where(eq(pods.id, pod.id));
    if (!pod.warmupCharged) await this.charge(pod, ((pod.readyAt ?? now) - pod.startedAt) / 1000, job.id, 'GPU warm-up');
    return job;
  }

  async jobEnded(podId: string, now: number) {
    await this.ctx.db.update(pods).set({ currentJobId: null, busy: false, idleSince: now }).where(eq(pods.id, podId));
    this.ctx.jobs.kick();
  }

  async cancel(_jobId: string) { /* the worker sees 409 job_cancelled on its next progress report */ }

  async tick(now: number) {
    await this.health(now);
    const idleMs = this.ctx.config.IDLE_SHUTDOWN_SECONDS * 1000;
    for (const p of await this.activePods()) {
      if (p.state === 'running' && !p.currentJobId && p.idleSince && now - p.idleSince >= idleMs) await this.stopPod(p, now, 'idle');
    }
  }

  async stopPod(p: PodRow, now: number, why: string) {
    const [u] = await this.ctx.db.update(pods).set({ state: 'stopping' }).where(and(eq(pods.id, p.id), inArray(pods.state, ['starting', 'running']))).returning();
    if (!u) return;
    if (p.idleSince && p.warmupCharged) await this.chargeIdle(p, now);
    else if (!p.warmupCharged && p.startedForJobId) await this.charge(p, ((p.readyAt ?? now) - p.startedAt) / 1000, p.startedForJobId, 'GPU start-up (no job ran)');
    try { await this.terminate(p); } catch (e) { this.ctx.log.error({ pod: p.id, err: (e as Error).message }, 'pod stop failed'); }
    await this.ctx.db.update(pods).set({ state: 'stopped', stoppedAt: now, busy: false }).where(eq(pods.id, p.id));
    this.ctx.log.info({ pod: p.id, why }, 'pod stopped');
  }

  /** Model load time reported by the worker: the pod's warm-up line. */
  async chargeWarmup(pod: PodRow, seconds: number, jobId: string, note: string) { await this.charge(pod, seconds, jobId, note); }

  /** Idle time since `idleSince`, charged to the pod's current user with their most recent job on it. */
  protected async chargeIdle(p: PodRow, now: number) {
    if (!p.idleSince || !p.warmupCharged) return;
    const [last] = await this.ctx.db.select({ id: jobs.id }).from(jobs).where(and(eq(jobs.podId, p.id), eq(jobs.userId, p.assignedUserId ?? ''))).orderBy(desc(jobs.claimedAt)).limit(1);
    await this.charge(p, (now - p.idleSince) / 1000, last?.id ?? null, 'GPU idle');
    await this.ctx.db.update(pods).set({ idleSince: now }).where(eq(pods.id, p.id));
  }

  /** Warm-up and idle time: the pod's user pays (default) or the owner, per studio setting. */
  protected async charge(p: PodRow, seconds: number, jobId: string | null, note: string) {
    const usd = Math.max(0, seconds) / 3600 * p.costPerHr;
    if (usd < 1e-6) return;
    const userId = p.assignedUserId;
    const s = await this.ctx.money.settings(p.studioId);
    if ((s.overheadPayer ?? 'user') === 'owner' || !userId) { await this.ctx.money.overhead(p.studioId, usd, `${note} (pod ${p.id})`); return; }
    await this.ctx.money.gpuOverhead(p.studioId, userId, usd, jobId, `${note} (pod ${p.id}, ${Math.round(seconds)}s)`);
    if (jobId) {
      const [j] = await this.ctx.db.select().from(jobs).where(eq(jobs.id, jobId));
      if (j) {
        const [u] = await this.ctx.db.update(jobs).set({ warmupCost: j.warmupCost + usd }).where(eq(jobs.id, jobId)).returning();
        if (u) this.ctx.jobs.emitJob(u);
      }
    }
  }

  async shutdown() {}

  async status() {
    const active = await this.activePods();
    return {
      mode: this.mode,
      pods: active.map(p => ({ id: p.id, state: p.state, gpuType: p.gpuType, assignedUserId: p.assignedUserId, busy: !!p.currentJobId })),
      noGpu: [...this.launchFailedAt.entries()].map(([kind, f]) => ({ kind, since: f.at, message: f.message })),
    };
  }
}

/** Virtual pods; renders run in-process at SPEED× like the mock. Free. */
export class SimulatedGpu extends PodPool {
  readonly mode = 'simulated' as const;
  private runners = new Map<string, NodeJS.Timeout>();

  protected async launch(_pod: PodRow, kind: WorkKind) {
    return { runpodId: null, gpuType: gpuTable(this.ctx.config)[kind][0] ?? 'simulated', costPerHr: 0, ready: true };
  }
  protected async terminate() {}

  protected async idlePod(pod: PodRow, now: number) {
    if (this.ctx.config.SPEED <= 0) return;
    const job = await this.claimForPod(pod, now);
    if (job) this.run(job, pod.id);
  }

  private run(job: JobRow, podId: string) {
    const ctx = this.ctx, speed = ctx.config.SPEED;
    const t0 = Date.now();
    const lora = job.kind === 'lora-train';
    const totalSec = lora ? P.loraTrainMinutes() * 60 : job.totalSeconds;
    const rate = lora ? speed * 5 : speed; // LoRA runs 5× faster than renders, like the mock
    let failAt = Infinity, busy = false, done = false;
    void ctx.money.settings(job.studioId).then(async s => {
      if (s.failNext) { failAt = lora ? totalSec * 0.1 : P.failAt(job.request); await ctx.money.clearFailNext(job.studioId); }
    });
    const finish = async (fn: () => Promise<unknown>) => {
      done = true; clearInterval(iv); this.runners.delete(job.id);
      await fn(); await this.jobEnded(podId, Date.now());
    };
    const iv = setInterval(async () => {
      if (busy || done) return;
      busy = true;
      try {
        const elapsed = (Date.now() - t0) / 1000 * rate;
        if (elapsed >= failAt) {
          const p = P.progressAt(job.request, failAt);
          await ctx.db.update(jobs).set({ progress: p.progress, step: p.step }).where(eq(jobs.id, job.id));
          await finish(() => ctx.jobs.fail(job.id, `The GPU disconnected at step ${p.step}.`, true));
        } else if (elapsed >= totalSec) {
          await finish(() => ctx.jobs.complete(job.id, { simulated: true, gpuSeconds: totalSec }));
        } else {
          const p = lora ? { progress: elapsed / totalSec * 100 } : P.progressAt(job.request, elapsed);
          if (!(await ctx.jobs.progress(job.id, p))) await finish(async () => {});
        }
      } catch (e) {
        ctx.log.error({ err: (e as Error).message }, 'simulated job tick failed');
      } finally { busy = false; }
    }, 250);
    this.runners.set(job.id, iv);
  }

  async cancel(jobId: string) { const t = this.runners.get(jobId); if (t) clearInterval(t); this.runners.delete(jobId); }
  async shutdown() { for (const t of this.runners.values()) clearInterval(t); this.runners.clear(); }
}

/** Real pods on RunPod with the network volume. Workers pull jobs over /worker/v1 (routes/worker.ts). */
export class RunpodGpu extends PodPool {
  readonly mode = 'runpod' as const;
  constructor(ctx: Ctx, private api: RunpodApi) { super(ctx); }

  protected async launch(pod: PodRow, kind: WorkKind, workerToken: string) {
    const c = this.ctx.config;
    if (!c.RUNPOD_NETWORK_VOLUME_ID) throw new Error('RUNPOD_NETWORK_VOLUME_ID is not set');
    for (const gpuTypeId of gpuTable(c)[kind]) {
      try {
        const r = await this.api.deployOnDemand({
          cloudType: 'SECURE', gpuCount: 1, gpuTypeId, name: `muse-${pod.id}`, imageName: c.RUNPOD_IMAGE,
          networkVolumeId: c.RUNPOD_NETWORK_VOLUME_ID, volumeMountPath: '/workspace', containerDiskInGb: c.RUNPOD_CONTAINER_DISK_GB,
          ...(c.RUNPOD_DATACENTER_ID ? { dataCenterId: c.RUNPOD_DATACENTER_ID } : {}),
          ...(c.RUNPOD_START_CMD ? { dockerArgs: c.RUNPOD_START_CMD } : {}),
          env: [
            { key: 'MUSE_API_URL', value: this.ctx.publicBase() },
            { key: 'MUSE_POD_ID', value: pod.id },
            { key: 'POD_ID', value: pod.id },
            { key: 'WORKER_TOKEN', value: workerToken },
          ],
        });
        return { runpodId: r.id, gpuType: gpuTypeId, costPerHr: Number(r.costPerHr ?? c.GPU_HOURLY_USD), ready: false };
      } catch (e) {
        this.ctx.log.warn({ gpuTypeId, err: (e as Error).message }, 'RunPod deploy failed, trying the next GPU type');
      }
    }
    return null;
  }

  protected async terminate(pod: PodRow) {
    // Terminate rather than stop: models live on the network volume and outputs in R2, so nothing on the pod is kept,
    // and a stopped pod still bills its disk.
    if (pod.runpodId) await this.api.terminate(pod.runpodId);
  }

  protected async health(now: number) {
    const c = this.ctx.config;
    for (const p of await this.activePods()) {
      if (p.state === 'starting' && now - p.startedAt > c.POD_BOOT_TIMEOUT_SEC * 1000) {
        this.ctx.log.warn({ pod: p.id }, 'pod never reported in');
        await this.stopPod(p, now, 'boot timeout');
        continue;
      }
      const last = p.lastHeartbeatAt ?? p.readyAt;
      if (p.state === 'running' && last && now - last > c.WORKER_HEARTBEAT_TIMEOUT_SEC * 1000) {
        this.ctx.log.warn({ pod: p.id }, 'heartbeats stopped');
        if (p.currentJobId) await this.ctx.jobs.fail(p.currentJobId, 'The GPU stopped responding. You were not charged.', true);
        await this.ctx.db.update(pods).set({ currentJobId: null, idleSince: null }).where(eq(pods.id, p.id));
        await this.stopPod({ ...p, currentJobId: null, idleSince: null }, now, 'heartbeat timeout');
      }
    }
  }

  async shutdown() {}
}
