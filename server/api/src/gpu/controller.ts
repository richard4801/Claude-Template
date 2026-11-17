// The GPU controller interface. One GPU per user: when a user's job is waiting and they have no pod, the controller
// hands them a warm idle pod (if one with the right GPU is free) or starts a new one, up to MAX_GPUS. Each pod runs its
// user's jobs FIFO and stops IDLE_SHUTDOWN_SECONDS after its last job. Two implementations share that logic (pool.ts):
//  - SimulatedGpu: virtual pods; jobs run in-process like the mock (SPEED× real time), no GPU and no cost.
//  - RunpodGpu: real pods through the RunPod GraphQL API; workers pull jobs over the worker protocol (routes/worker.ts).
//  - OffGpu: MUSE's own GPU is switched off (GPU_MODE=off, or runpod without a key; plans/gpu-off.md). No pod, no RunPod call.
import type { Config } from '../config.js';
import { ApiError } from '../errors.js';
import type { jobs, pods } from '../db/schema.js';

export type JobRow = typeof jobs.$inferSelect;
export type PodRow = typeof pods.$inferSelect;
/** A waiting job as the dispatcher reads it: no draft, outputs, stats, prompt or thumb (services/jobs.ts waitingCols). */
export type WaitingJob = Omit<JobRow, 'draft' | 'outputs' | 'stats' | 'prompt' | 'thumb'>;
export type WorkKind = 'h3' | 'viggle' | 'lora-train' | 'upscale';

export type GpuMode = 'simulated' | 'runpod' | 'off';
/** What every feature that needs our GPU answers while it is switched off (plans/gpu-off.md). */
export const GPU_OFF_MESSAGE = "This needs MUSE's own GPU, which is switched off · pick a hosted model";
export const GPU_OFF_REASON = 'RunPod is switched off';
/** Refused up front, before any hold or charge. `engine_unavailable` like any engine that can't run now. */
export const gpuOffError = () => new ApiError(400, 'engine_unavailable', GPU_OFF_MESSAGE);

export interface GpuController {
  readonly mode: GpuMode;
  /**
   * Waiting jobs that may start (FIFO, not paused). Assign or start pods for their users. `active`: the active pods the
   * caller just read (saves a read). Returns the active pods afterwards, or null when they may have changed underneath.
   */
  dispatch(waiting: WaitingJob[], now: number, active?: PodRow[]): Promise<PodRow[] | null | void>;
  /** The job was deleted or cancelled: stop working on it. */
  cancel(jobId: string): Promise<void>;
  /** Housekeeping: heartbeats, boot timeouts, idle shutdown. */
  tick(now: number, active?: PodRow[] | null): Promise<PodRow[] | null | void>;
  /** Pods starting or running. */
  activePods?(): Promise<PodRow[]>;
  /** A job on this pod ended (done, failed or cancelled): the pod is idle until it claims another. */
  jobEnded(podId: string, now: number): Promise<void>;
  shutdown(): Promise<void>;
  status(): Promise<Record<string, unknown>>;
}

let cache: { raw: string; table: Record<WorkKind, string[]> } | null = null;
/** GPU types per job kind, best first (config GPU_TABLE). */
export function gpuTable(c: Config): Record<WorkKind, string[]> {
  if (cache?.raw === c.GPU_TABLE) return cache.table;
  let t: Record<string, string[]>;
  try { t = JSON.parse(c.GPU_TABLE); } catch { throw new Error('Bad configuration: GPU_TABLE is not valid JSON'); }
  const table = { h3: t.h3 ?? [], viggle: t.viggle ?? [], 'lora-train': t['lora-train'] ?? t.h3 ?? [], upscale: t.upscale ?? t.h3 ?? [] };
  cache = { raw: c.GPU_TABLE, table };
  return table;
}
/** Can a pod with this GPU run this kind of job? */
export const gpuCanRun = (c: Config, gpuType: string, kind: WorkKind) => gpuTable(c)[kind].includes(gpuType);
export const workKindOf = (j: Pick<JobRow, 'kind' | 'request'>): WorkKind => j.kind === 'lora-train' ? 'lora-train' : j.request.engine === 'viggle' ? 'viggle' : j.request.engine === 'upscale' ? 'upscale' : 'h3';
