// Recreate this edit · per-frame poses (workstream 1; the coordinator's G2 refinements): every frame of a shot through
// MoveNet (the same child process as the keyframe poses), in chunks so memory stays inside the guard, smoothed lightly
// with a one-euro filter (little lag) and with low-confidence joints dropped, never invented. Used to match the
// studio's takes to a shot by movement (a pose-similarity term in the take score). Free: CPU.
import { spawn } from 'node:child_process';
import { DECODE_ARGS } from './frames.js';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { freeMemoryMb, MIN_POSE_SCORE, POSE_MIN_FREE_MB, POSE_MODEL, runPoseJob } from './pose.js';
import { KEYPOINTS, type Keypoint } from './poseWorker.js';

/** A joint: [x, y] in 0–1 of the frame, or null when it wasn't seen well enough. */
export type Joint = [number, number] | null;
/** One shot's (or take's) poses: `frames[i]` at i / fps seconds, null when no one is in frame. */
export type PoseTrack = { fps: number; frames: (Joint[] | null)[] };

/** Joints under this score are dropped. */
export const MIN_JOINT_SCORE = 0.3;
/** Frames per child-process job (≈ 23 MB of 256-px frames), and the most read at most this fast. */
/** Frames per pose-child job (each ≤ 256 px on its long edge: ~110 KB; the model letterboxes to 192 px anyway). */
export const POSE_CHUNK = 24, TRACK_MAX_FPS = 30, TRACK_LONG_EDGE = 256;

/** The one-euro filter (Casiez et al. 2012): smooths jitter at rest, follows fast moves with little lag. */
export class OneEuro {
  private x: number | null = null; private dx = 0;
  constructor(private freq: number, private minCutoff = 1.2, private beta = 0.4, private dCutoff = 1) {}
  private alpha(cutoff: number) { const tau = 1 / (2 * Math.PI * cutoff); return 1 / (1 + tau * this.freq); }
  reset() { this.x = null; this.dx = 0; }
  filter(v: number) {
    if (this.x === null) { this.x = v; return v; }
    const d = (v - this.x) * this.freq, ad = this.alpha(this.dCutoff);
    this.dx = ad * d + (1 - ad) * this.dx;
    const a = this.alpha(this.minCutoff + this.beta * Math.abs(this.dx));
    this.x = a * v + (1 - a) * this.x;
    return this.x;
  }
}

const r3 = (x: number) => Math.round(x * 1000) / 1000;
/** Raw MoveNet frames → a smoothed track: weak joints dropped (and their filter restarted), empty frames null. */
export function smoothTrack(raw: Keypoint[][], fps: number, o: { minJoint?: number } = {}): PoseTrack {
  const min = o.minJoint ?? MIN_JOINT_SCORE;
  const f = KEYPOINTS.map(() => [new OneEuro(fps), new OneEuro(fps)] as const);
  const frames = raw.map(kps => {
    if (!kps.length || kps.reduce((a, k) => a + k.score, 0) / kps.length < MIN_POSE_SCORE) { f.forEach(p => { p[0].reset(); p[1].reset(); }); return null; }
    return KEYPOINTS.map((_, j): Joint => {
      const k = kps[j];
      if (!k || k.score < min) { f[j]![0].reset(); f[j]![1].reset(); return null; }
      return [r3(f[j]![0].filter(k.x)), r3(f[j]![1].filter(k.y))];
    });
  });
  return { fps, frames };
}

const J = Object.fromEntries(KEYPOINTS.map((n, i) => [n, i])) as Record<(typeof KEYPOINTS)[number], number>;
const mid = (a: Joint, b: Joint): [number, number] | null => (a && b ? [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2] : a ?? b ?? null);
/** A pose moved and scaled into the body's own frame (hips at the origin, torso length 1), so framing doesn't count. */
export function normalizePose(p: Joint[]): Joint[] | null {
  const sh = mid(p[J.left_shoulder]!, p[J.right_shoulder]!), hip = mid(p[J.left_hip]!, p[J.right_hip]!);
  const centre = hip ?? sh;
  if (!centre) return null;
  let scale = sh && hip ? Math.hypot(sh[0] - hip[0], sh[1] - hip[1]) : 0;
  if (scale < 1e-3) {
    const ls = p[J.left_shoulder], rs = p[J.right_shoulder];
    scale = ls && rs ? Math.hypot(ls[0] - rs[0], ls[1] - rs[1]) * 1.6 : 0;
  }
  if (scale < 1e-3) return null;
  return p.map(j => (j ? [(j[0] - centre[0]) / scale, (j[1] - centre[1]) / scale] : null));
}
/** Mean distance between the joints both poses have (normalized), or null when fewer than 4 are shared. */
export function poseDistance(a: Joint[], b: Joint[]): number | null {
  let s = 0, n = 0;
  for (let j = 0; j < a.length; j++) { const x = a[j], y = b[j]; if (x && y) { s += Math.hypot(x[0] - y[0], x[1] - y[1]); n++; } }
  return n >= 4 ? s / n : null;
}
/** The track's raw frame at t seconds (the nearest). */
const rawAt = (t: PoseTrack, sec: number) => t.frames[Math.min(t.frames.length - 1, Math.max(0, Math.round(sec * t.fps)))] ?? null;
/** Where the body is (hips, else shoulders) and how big (torso length), in frame units. */
function bodyAt(p: Joint[]): { c: [number, number]; size: number } | null {
  const sh = mid(p[J.left_shoulder]!, p[J.right_shoulder]!), hip = mid(p[J.left_hip]!, p[J.right_hip]!);
  const c = hip ?? sh;
  const size = sh && hip ? Math.hypot(sh[0] - hip[0], sh[1] - hip[1]) : 0;
  return c && size > 1e-3 ? { c, size } : null;
}

/**
 * How alike two movements are, 0–1: the shot's poses against the take's over the shot's length (the take's first
 * `seconds`, stretched if it is shorter), compared in the body's own frame; how much each moves; and how the body
 * travels through the frame (in body lengths, so framing doesn't count). Null when too few moments can be compared.
 */
export function poseSimilarity(shot: PoseTrack, take: PoseTrack, seconds: number): { score: number; coverage: number } | null {
  const n = Math.max(4, Math.min(60, Math.round(seconds * 10)));
  const takeSec = Math.min(seconds, take.frames.length / take.fps);
  const ds: number[] = [];
  const a: (Joint[] | null)[] = [], b: (Joint[] | null)[] = [];
  const ta: ({ c: [number, number]; size: number } | null)[] = [], tb: typeof ta = [];
  for (let i = 0; i < n; i++) {
    const u = (i + 0.5) / n;
    const ra = rawAt(shot, u * seconds), rb = rawAt(take, u * takeSec);
    const p = ra ? normalizePose(ra) : null, q = rb ? normalizePose(rb) : null;
    a.push(p); b.push(q); ta.push(ra ? bodyAt(ra) : null); tb.push(rb ? bodyAt(rb) : null);
    const d = p && q ? poseDistance(p, q) : null;
    if (d !== null) ds.push(d);
  }
  const coverage = ds.length / n;
  if (coverage < 0.3) return null;
  ds.sort((x, y) => x - y);
  const shape = Math.exp(-ds[Math.floor(ds.length / 2)]! / 0.35);
  // How much each one moves between moments (a dance against standing still).
  const activity = (xs: (Joint[] | null)[]) => {
    let s = 0, k = 0;
    for (let i = 1; i < xs.length; i++) { const d = xs[i] && xs[i - 1] ? poseDistance(xs[i]!, xs[i - 1]!) : null; if (d !== null) { s += d; k++; } }
    return k ? s / k : 0;
  };
  const ma = activity(a), mb = activity(b);
  const pace = ma + mb < 0.02 ? 1 : Math.min(ma, mb) / Math.max(ma, mb);
  // How the body travels through the frame (walking in, stepping to the side), in body lengths from where it started.
  const first = (xs: typeof ta) => xs.find(Boolean) ?? null;
  const a0 = first(ta), b0 = first(tb);
  let td = 0, tk = 0;
  if (a0 && b0) for (let i = 0; i < n; i++) {
    const x = ta[i], y = tb[i];
    if (!x || !y) continue;
    td += Math.hypot((x.c[0] - a0.c[0]) / a0.size - (y.c[0] - b0.c[0]) / b0.size, (x.c[1] - a0.c[1]) / a0.size - (y.c[1] - b0.c[1]) / b0.size); tk++;
  }
  const travel = tk ? Math.exp(-(td / tk) / 0.6) : 1;
  return { score: Math.round(shape * (0.7 + 0.3 * pace) * (0.5 + 0.5 * travel) * 1000) / 1000, coverage: Math.round(coverage * 100) / 100 };
}

export type TrackRun = { tracks: (PoseTrack | null)[]; frames: number; ms: number; peakRssMb: number } | { skipped: 'memory' | 'model' | 'failed'; detail?: string };

/**
 * Every frame of each segment (up to TRACK_MAX_FPS and `maxFrames` in all), read with one ffmpeg pipe per segment and
 * sent to the pose child POSE_CHUNK frames at a time; memory is checked before each chunk.
 */
export async function readPoseTracks(cfg: { ffmpeg: string; model?: string; minFreeMb?: number }, input: string, segments: { startSec: number; endSec: number }[],
  src: { width: number; height: number; fps: number }, o: { maxFrames?: number; frameW?: number } = {}): Promise<TrackRun> {
  const model = cfg.model ?? POSE_MODEL;
  if (!fs.existsSync(model)) return { skipped: 'model' };
  const minFree = cfg.minFreeMb ?? POSE_MIN_FREE_MB;
  const fps = Math.min(TRACK_MAX_FPS, Math.max(1, Math.round(src.fps || 30)));
  // Workstream 1 (512 MB box): decoded small inside ffmpeg (the long edge TRACK_LONG_EDGE), never full-size frames in Node.
  const w = o.frameW ? Math.min(o.frameW, src.width - (src.width % 2)) : Math.max(2, Math.round(TRACK_LONG_EDGE * src.width / Math.max(src.width, src.height) / 2) * 2);
  const h = Math.max(2, Math.round(w * src.height / src.width / 2) * 2);
  let budget = o.maxFrames ?? 1800, peak = 0, total = 0;
  const t0 = Date.now(), tracks: (PoseTrack | null)[] = [];
  for (const seg of segments) {
    const want = Math.min(budget, Math.max(1, Math.round((seg.endSec - seg.startSec) * fps)));
    if (budget <= 0 || want <= 0) { tracks.push(null); continue; }
    const raw: Keypoint[][] = [];
    let chunk: { width: number; height: number; rgb: Uint8Array }[] = [];
    const flush = async () => {
      if (!chunk.length) return;
      const free = freeMemoryMb();
      if (free < minFree) throw Object.assign(new Error(`${free} MB free`), { code: 'memory' });
      const r = await runPoseJob({ model, frames: chunk });
      chunk = [];
      if (!r.ok) throw new Error(r.error);
      peak = Math.max(peak, r.peakRssMb);
      raw.push(...r.poses);
    };
    try {
      await readFrames(cfg.ffmpeg, input, seg.startSec, want / fps, fps, w, h, async rgb => {
        chunk.push({ width: w, height: h, rgb });
        if (chunk.length >= POSE_CHUNK) await flush();
      });
      await flush();
    } catch (e) {
      const m = String((e as Error)?.message ?? e);
      return (e as { code?: string }).code === 'memory' ? { skipped: 'memory', detail: m } : { skipped: 'failed', detail: m.slice(0, 200) };
    }
    budget -= raw.length; total += raw.length;
    tracks.push(raw.length ? smoothTrack(raw, fps) : null);
  }
  return { tracks, frames: total, ms: Date.now() - t0, peakRssMb: peak };
}

/**
 * Decodes `len` seconds from `start` at `fps` as w×h RGB frames and hands them to `each` one at a time. Workstream 1
 * (512 MB box): ffmpeg writes the small frames to a temporary file and exits before the first one is used, so the
 * decoder and the pose child never hold memory at the same time; the file is read back one frame at a time.
 */
async function readFrames(ffmpeg: string, input: string, start: number, len: number, fps: number, w: number, h: number, each: (rgb: Uint8Array) => Promise<void>): Promise<void> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-pose-')), raw = path.join(dir, 'frames.rgb');
  try {
    await new Promise<void>((resolve, reject) => {
      const p = spawn(ffmpeg, ['-v', 'error', ...DECODE_ARGS, '-ss', String(Math.max(0, start)), '-i', input, '-t', String(len), '-an',
        '-vf', `fps=${fps},scale=${w}:${h}:flags=area,format=rgb24`, '-f', 'rawvideo', '-y', raw]);
      let err = '';
      p.stderr.on('data', d => { err = (err + String(d)).slice(-2000); });
      p.on('error', reject);
      p.on('close', code => (code === 0 ? resolve() : reject(new Error(`ffmpeg failed: ${err.trim().split('\n').slice(-1)[0]?.slice(0, 200)}`))));
    });
    const size = w * h * 3, fd = fs.openSync(raw, 'r');
    try {
      for (let pos = 0; ; pos += size) {
        const frame = new Uint8Array(size);
        if (fs.readSync(fd, frame, 0, size, pos) < size) break;
        await each(frame);
      }
    } finally { fs.closeSync(fd); }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
