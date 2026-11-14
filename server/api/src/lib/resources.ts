// What the box really has (CPUs, memory) and the media profile that follows from it (2026-11-14, Railway Trial → Hobby).
// On the trial (~0.5–1 GB, 1–2 vCPU) every ffmpeg was capped to survive OOM; on Hobby (up to 8 vCPU / 8 GB, billed by
// use) those caps made Claude's renders slow. SMALL (< 1.5 GB) keeps the trial's exact behaviour: every call site passes
// its old thread count and gets it back unchanged. LARGE scales threads, x264 frame threading and concurrency.
// Env overrides: MEDIA_CPUS, MEDIA_MEM_MB (whole numbers).
import fs from 'node:fs';
import os from 'node:os';

export type Resources = { cpus: number; memMB: number };
export type MediaProfile = Resources & {
  name: 'small' | 'large';
  /** x264 / encoder threads (LARGE only; SMALL keeps each call site's own number). */
  encodeThreads: number;
  /** Decoder threads (LARGE only; SMALL keeps each call site's own number). */
  decodeThreads: number;
  /** x264 with sliced threads and a short lookahead (low memory) instead of normal frame threads. */
  x264Sliced: boolean;
  /** How many heavy ffmpeg pipelines (Claude's watch, frames, listen, motion) run at once (lib/mediaLane.ts). */
  laneConcurrency: number;
  /** How many edit renders run at once (editor/renders.ts): their own budget, never behind the lane. */
  renderConcurrency: number;
};

type Read = (file: string) => string;
const readFile: Read = f => fs.readFileSync(f, 'utf8');
const posInt = (v: unknown) => { const n = Math.floor(Number(v)); return Number.isFinite(n) && n > 0 ? n : null; };

/** cgroup v2 cpu.max ("max 100000" or "200000 100000") → CPUs (rounded up), else null. */
export function cgroupCpus(read: Read = readFile): number | null {
  try {
    const [quota, period] = read('/sys/fs/cgroup/cpu.max').trim().split(/\s+/);
    if (!quota || quota === 'max') return null;
    const q = Number(quota), p = Number(period) || 100_000;
    return q > 0 ? Math.max(1, Math.ceil(q / p)) : null;
  } catch { return null; }
}
/** cgroup v2 memory.max in MB, else null ("max" = no limit). */
export function cgroupMemMB(read: Read = readFile): number | null {
  try {
    const v = read('/sys/fs/cgroup/memory.max').trim();
    if (!v || v === 'max') return null;
    const b = Number(v);
    return b > 0 ? Math.floor(b / (1024 * 1024)) : null;
  } catch { return null; }
}

/** Usable CPUs and memory: env override, then the cgroup limit, then the host. */
export function detectResources(env: NodeJS.ProcessEnv = process.env, read: Read = readFile): Resources {
  const hostCpus = typeof os.availableParallelism === 'function' ? os.availableParallelism() : os.cpus().length;
  const hostMem = Math.floor(os.totalmem() / (1024 * 1024));
  const cpus = posInt(env.MEDIA_CPUS) ?? Math.min(hostCpus, cgroupCpus(read) ?? hostCpus);
  const memMB = posInt(env.MEDIA_MEM_MB) ?? Math.min(hostMem, cgroupMemMB(read) ?? hostMem);
  return { cpus: Math.max(1, cpus), memMB: Math.max(1, memMB) };
}

/** The media profile for these resources. */
export function profileFor(r: Resources): MediaProfile {
  const small = r.memMB < 1536;
  if (small) return { ...r, name: 'small', encodeThreads: 2, decodeThreads: 1, x264Sliced: true, laneConcurrency: 1, renderConcurrency: 1 };
  return {
    ...r, name: 'large',
    encodeThreads: Math.min(r.cpus, 6),
    decodeThreads: Math.min(r.cpus, 4),
    x264Sliced: r.memMB < 3072,
    laneConcurrency: r.memMB >= 6144 ? 3 : r.memMB >= 3072 ? 2 : 1,
    renderConcurrency: r.memMB >= 4096 ? 2 : 1,
  };
}

let current: MediaProfile | null = null;
/** The profile this process runs with (detected once). */
export function mediaProfile(): MediaProfile { return current ??= profileFor(detectResources()); }
/** Tests and the benchmark: run with these resources (null: detect again). */
export function setMediaResources(r: Resources | null) { current = r ? profileFor(r) : null; }

/** Encoder threads: the call site's trial number on SMALL, the profile's on LARGE. */
export const encThreads = (small: number) => { const p = mediaProfile(); return String(p.name === 'small' ? small : p.encodeThreads); };
/** Decoder threads: the call site's trial number on SMALL, the profile's on LARGE. */
export const decThreads = (small: number) => { const p = mediaProfile(); return String(p.name === 'small' ? small : p.decodeThreads); };
/**
 * x264 options for a quality encode: sliced threads + a 5-frame lookahead (the trial's low-memory form, ~190 → ~95 MB at
 * 1080 × 1920) while memory is short, x264's normal frame threads (faster) once there is room.
 */
export const x264Lean = (): string[] => mediaProfile().x264Sliced ? ['-x264-params', 'sliced-threads=1:rc-lookahead=5:sync-lookahead=0'] : [];

type Log = { info: (o: object, msg: string) => void };
/** Runs `fn` and logs how long it took (ms), the input's seconds and the profile. */
export async function timed<T>(log: Log | undefined, tool: string, inputSec: number | undefined, fn: () => Promise<T>): Promise<T> {
  const t0 = Date.now();
  try { return await fn(); } finally {
    const p = mediaProfile();
    log?.info({ tool, ms: Date.now() - t0, ...(inputSec !== undefined && Number.isFinite(inputSec) ? { inputSec: Math.round(inputSec * 1000) / 1000 } : {}), profile: p.name, cpus: p.cpus, memMB: p.memMB }, 'media timing');
  }
}
