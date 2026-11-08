// Recreate this edit · body poses (workstream 1, plans/recreate-edit.md "Pose"; the coordinator's choice (a)): MoveNet
// Lightning in a child process, one job at a time, the model loaded only for a reference that needs it, at most
// MAX_POSE_FRAMES keyframes. The child's peak memory is measured and returned. When memory is tight, the model is
// missing or the child fails, poses are skipped (the slots stay "pending" and the gap says why). Free: CPU.
import { fork } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { grabFrame } from './frames.js';
import type { Keypoint, PoseJob, PoseReply } from './poseWorker.js';

const here = path.dirname(fileURLToPath(import.meta.url));
/** MoveNet SinglePose Lightning, fp32 (Apache-2.0; assets/pose/README.md). The int8 export scores near 0 everywhere. */
export const POSE_MODEL = path.resolve(here, '../../assets/pose/movenet-lightning.onnx');
export const MAX_POSE_FRAMES = 20;
/** Below this much free memory (MB; the container's limit when there is one) poses are skipped. */
export const POSE_MIN_FREE_MB = 200;
/** The frame width the keyframes are read at (MoveNet looks at 192 × 192). */
const FRAME_W = 256;

export type SlotPose = { status: 'done'; frameSec: number; keypoints: Keypoint[] } | { status: 'none'; frameSec: number };
export type PoseRun = { poses: SlotPose[]; peakRssMb: number; ms: number } | { skipped: 'memory' | 'model' | 'failed'; detail?: string; peakRssMb?: number };

/**
 * Free memory in MB: the cgroup's limit minus its use when there is one (containers), else the machine's. The use
 * leaves out inactive page cache (the video file just read), which the kernel gives back before it kills anything.
 * Tests (and a box without a cgroup limit) can cap it with MUSE_MEMORY_LIMIT_MB: limit minus this process tree's RSS.
 */
export function freeMemoryMb(): number {
  const cap = Number(process.env.MUSE_MEMORY_LIMIT_MB);
  if (cap > 0) return Math.round(cap - treeRssMb(process.pid));
  try {
    const max = fs.readFileSync('/sys/fs/cgroup/memory.max', 'utf8').trim();
    if (max !== 'max') {
      const cur = Number(fs.readFileSync('/sys/fs/cgroup/memory.current', 'utf8').trim());
      let cache = 0;
      try { cache = Number(/^inactive_file (\d+)$/m.exec(fs.readFileSync('/sys/fs/cgroup/memory.stat', 'utf8'))?.[1] ?? 0); } catch { /* no stat */ }
      const n = Number(max);
      if (Number.isFinite(n) && Number.isFinite(cur)) return Math.round((n - cur + cache) / 1048576);
    }
  } catch { /* not a cgroup v2 container */ }
  return Math.round(os.freemem() / 1048576);
}

/** RSS in MB of a process and all its descendants (Linux /proc; 0 elsewhere). */
export function treeRssMb(root: number): number {
  try {
    const kids = new Map<number, number[]>();
    for (const d of fs.readdirSync('/proc')) {
      if (!/^\d+$/.test(d)) continue;
      try { const st = fs.readFileSync(`/proc/${d}/stat`, 'utf8'); const ppid = Number(st.slice(st.lastIndexOf(')') + 2).split(' ')[1]); (kids.get(ppid) ?? kids.set(ppid, []).get(ppid)!).push(Number(d)); } catch { /* gone */ }
    }
    let kb = 0;
    const stack = [root];
    while (stack.length) {
      const p = stack.pop()!;
      try { kb += Number(/^VmRSS:\s+(\d+)/m.exec(fs.readFileSync(`/proc/${p}/status`, 'utf8'))?.[1] ?? 0); } catch { /* gone */ }
      stack.push(...(kids.get(p) ?? []));
    }
    return Math.round(kb / 1024);
  } catch { return 0; }
}

/** No person: the mean keypoint score is under this. */
export const MIN_POSE_SCORE = 0.25;
export const poseOf = (frameSec: number, kps: Keypoint[]): SlotPose =>
  kps.reduce((a, k) => a + k.score, 0) / kps.length >= MIN_POSE_SCORE ? { status: 'done', frameSec, keypoints: kps } : { status: 'none', frameSec };

let chain: Promise<unknown> = Promise.resolve();

/** Runs one pose job in a child process (one at a time across the server) and resolves with its reply. */
export function runPoseJob(job: PoseJob, o: { timeoutMs?: number } = {}): Promise<PoseReply> {
  const go = () => new Promise<PoseReply>(resolve => {
    const js = path.join(here, 'poseWorker.js'), ts = path.join(here, 'poseWorker.ts');
    const fromSource = !fs.existsSync(js);
    const child = fork(fromSource ? ts : js, [], {
      serialization: 'advanced', stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
      execArgv: fromSource ? ['--import', 'tsx'] : [],
      env: { ...process.env, MUSE_POSE_WORKER: '1', NODE_OPTIONS: '--max-old-space-size=128', OMP_NUM_THREADS: '1' },
    });
    let err = '', done = false;
    const finish = (r: PoseReply) => { if (!done) { done = true; clearTimeout(timer); child.kill('SIGKILL'); resolve(r); } };
    const timer = setTimeout(() => finish({ ok: false, error: 'timed out', peakRssMb: 0 }), o.timeoutMs ?? 90_000);
    child.stderr?.on('data', d => { err = (err + String(d)).slice(-500); });
    child.on('message', m => finish(m as PoseReply));
    child.on('error', e => finish({ ok: false, error: e.message, peakRssMb: 0 }));
    child.on('exit', code => finish({ ok: false, error: `exited (${code}) ${err.trim().split('\n').slice(-1)[0] ?? ''}`.trim(), peakRssMb: 0 }));
    child.send(job);
  });
  const p = chain.then(go, go);
  chain = p.catch(() => undefined);
  return p;
}

/** Each keyframe's pose (the first MAX_POSE_FRAMES), or why poses were skipped. */
export async function readPoses(cfg: { ffmpeg: string; model?: string; minFreeMb?: number }, input: string, times: number[], src: { width: number; height: number }): Promise<PoseRun> {
  const model = cfg.model ?? POSE_MODEL;
  if (!fs.existsSync(model)) return { skipped: 'model' };
  const free = freeMemoryMb();
  if (free < (cfg.minFreeMb ?? POSE_MIN_FREE_MB)) return { skipped: 'memory', detail: `${free} MB free` };
  const fw = Math.min(FRAME_W, src.width - (src.width % 2)), fh = Math.max(2, Math.round(fw * src.height / src.width / 2) * 2);
  const ts = times.slice(0, MAX_POSE_FRAMES);
  const frames = [];
  for (const t of ts) frames.push(await grabFrame(cfg.ffmpeg, input, t, fw, fh));
  const r = await runPoseJob({ model, frames: frames.map(f => ({ width: f.width, height: f.height, rgb: f.rgb })) });
  if (!r.ok) return { skipped: 'failed', detail: r.error, peakRssMb: r.peakRssMb };
  return { poses: r.poses.map((kps, i) => poseOf(ts[i]!, kps)), peakRssMb: r.peakRssMb, ms: r.ms };
}
