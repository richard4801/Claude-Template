// The GPU controller interface. One GPU per user: when a user's job is waiting and they have no pod, the controller
// hands them a warm idle pod (if one with the right GPU is free) or starts a new one, up to MAX_GPUS. Each pod runs its
// user's jobs FIFO and stops IDLE_SHUTDOWN_SECONDS after its last job. Two implementations share that logic (pool.ts):
//  - SimulatedGpu: virtual pods; jobs run in-process like the mock (SPEED× real time), no GPU and no cost.
//  - RunpodGpu: real pods through the RunPod GraphQL API; workers pull jobs over the worker protocol (routes/worker.ts).
import type { Config } from '../config.js';
import type { jobs, pods } from '../db/schema.js';

export type JobRow = typeof jobs.$inferSelect;
export type PodRow = typeof pods.$inferSelect;
export type WorkKind = 'h3' | 'viggle' | 'lora-train';

export interface GpuController {
  readonly mode: 'simulated' | 'runpod';
  /** Waiting jobs that may start (FIFO, not paused). Assign or start pods for their users. */
  dispatch(waiting: JobRow[], now: number): Promise<void>;
  /** The job was deleted or cancelled: stop working on it. */
  cancel(jobId: string): Promise<void>;
  /** Housekeeping: heartbeats, boot timeouts, idle shutdown. */
  tick(now: number): Promise<void>;
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
  const table = { h3: t.h3 ?? [], viggle: t.viggle ?? [], 'lora-train': t['lora-train'] ?? t.h3 ?? [] };
  cache = { raw: c.GPU_TABLE, table };
  return table;
}
/** Can a pod with this GPU run this kind of job? */
export const gpuCanRun = (c: Config, gpuType: string, kind: WorkKind) => gpuTable(c)[kind].includes(gpuType);
export const workKindOf = (j: JobRow): WorkKind => j.kind === 'lora-train' ? 'lora-train' : j.request.engine === 'viggle' ? 'viggle' : 'h3';
