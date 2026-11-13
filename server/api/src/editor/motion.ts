// Motion analysis (workstream 1, plans/recreate-edit.md "Action peaks"): per-frame motion energy on a small grey proxy
// (frame differencing), the action peaks in it, and the hard cuts that would otherwise read as peaks. Free: ffmpeg on
// the server's CPU, nothing stored. Used by the find_action_peaks tool and the reference analysis.
import { spawn } from 'node:child_process';

export const PROXY_WIDTH = 96;
/** The proxy keeps every source frame up to 30 fps: a one-frame flash or cut must not fall between proxy frames. */
export const PROXY_FPS_MAX = 30;

export type MotionFrames = {
  fps: number; width: number; height: number;
  /** energy[i]: mean absolute difference between frame i and i-1 (0–1; energy[0] = 0). */
  energy: Float32Array;
  /** histDist[i]: how different frame i's brightness histogram is from frame i-1's (0–1, half the L1 distance). */
  histDist: Float32Array;
  /** luma[i]: frame i's mean brightness (0–1). */
  luma: Float32Array;
  /** hists[i]: frame i's 32-bin brightness histogram (sums to 1), for comparing frames further apart. */
  hists: Float32Array[];
};
/** Called for every proxy frame with the previous one (null for the first): extra measures in the same pass. */
export type FrameHook = (cur: Uint8Array, prev: Uint8Array | null, i: number, size: { width: number; height: number }) => void;

/**
 * Decodes `input` to a `width`-px grey proxy at `fps` and measures it frame by frame (streamed: memory stays at two
 * frames whatever the length). `maxSec` caps the analysis.
 */
export function measureMotion(ffmpeg: string, ffprobe: string, input: string, o: { fps?: number; width?: number; maxSec?: number; onFrame?: FrameHook; inputArgs?: string[] } = {}): Promise<MotionFrames> {
  const width = o.width ?? PROXY_WIDTH, maxSec = o.maxSec ?? 600;
  return probeSize(ffprobe, input, width).then(({ height, fps: srcFps }) => new Promise((resolve, reject) => {
    const fps = o.fps ?? Math.min(PROXY_FPS_MAX, Math.round(srcFps) || PROXY_FPS_MAX);
    const frame = width * height;
    const p = spawn(ffmpeg, ['-v', 'error', ...(o.inputArgs ?? ['-threads', '1']) /* workstream 1: Recreate caps decode threads */, '-i', input, '-t', String(maxSec), '-an',
      '-vf', `fps=${fps},scale=${width}:${height}:flags=area,format=gray`, '-f', 'rawvideo', 'pipe:1']);
    const energy: number[] = [], hist: number[] = [], luma: number[] = [], hists: Float32Array[] = [];
    let prev: Uint8Array | null = null, prevH: Float64Array | null = null, buf: Buffer = Buffer.alloc(0), err = '';
    const take = (f: Uint8Array) => {
      const h = new Float64Array(32);
      let sum = 0;
      for (let i = 0; i < f.length; i++) { h[f[i]! >> 3]! += 1; sum += f[i]!; }
      for (let i = 0; i < 32; i++) h[i]! /= f.length;
      luma.push(sum / f.length / 255);
      hists.push(Float32Array.from(h));
      o.onFrame?.(f, prev, energy.length, { width, height });
      if (!prev) { energy.push(0); hist.push(0); }
      else {
        let s = 0;
        for (let i = 0; i < f.length; i++) s += Math.abs(f[i]! - prev[i]!);
        energy.push(s / f.length / 255);
        let d = 0;
        for (let i = 0; i < 32; i++) d += Math.abs(h[i]! - prevH![i]!);
        hist.push(d / 2);
      }
      prev = f; prevH = h;
    };
    p.stdout.on('data', (c: Buffer) => {
      buf = buf.length ? Buffer.concat([buf, c]) : c;
      while (buf.length >= frame) { take(new Uint8Array(buf.subarray(0, frame))); buf = buf.subarray(frame); }
    });
    p.stderr.on('data', d => { err += String(d); });
    const timer = setTimeout(() => p.kill('SIGKILL'), 180_000);
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.on('close', code => {
      clearTimeout(timer);
      if (code !== 0) return reject(new Error(`ffmpeg failed: ${err.trim().split('\n').slice(-1)[0]?.slice(0, 200) || `exit ${code}`}`));
      resolve({ fps, width, height, energy: Float32Array.from(energy), histDist: Float32Array.from(hist), luma: Float32Array.from(luma), hists });
    });
  }));
}

/** The proxy's height for `width`, keeping the aspect (even, at least 2), and the source frame rate. */
function probeSize(ffprobe: string, input: string, width: number): Promise<{ height: number; fps: number }> {
  return new Promise((resolve, reject) => {
    const p = spawn(ffprobe, ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height,avg_frame_rate,r_frame_rate:stream_side_data=rotation', '-of', 'json', input]);
    let out = '';
    p.stdout.on('data', d => { out += String(d); });
    p.on('error', reject);
    p.on('close', () => {
      try {
        const s = JSON.parse(out).streams?.[0];
        if (!s?.width || !s?.height) return reject(new Error('no video stream'));
        const rot = Math.abs(Number(s.side_data_list?.find((x: any) => x.rotation != null)?.rotation ?? 0)) % 180 === 90;
        const [w, h] = rot ? [s.height, s.width] : [s.width, s.height];
        const rate = (r?: string) => { const [a, b] = String(r ?? '').split('/').map(Number); return a && b ? a / b : 0; };
        resolve({ height: Math.max(2, Math.round((width * h / w) / 2) * 2), fps: rate(s.avg_frame_rate) || rate(s.r_frame_rate) });
      } catch (e) { reject(e); }
    });
  });
}

export type Peak = { t: number; strength: number };
export type Cut = { t: number; strength: number };

/**
 * Hard cuts: one frame whose brightness histogram and pixels both jump (a spike against its neighbours). A flash frame (a short burst that returns
 * to the same picture) shows as two cuts 1–2 frames apart; `flash: true` marks the first of such a pair.
 */
export function findCuts(m: MotionFrames, o: { threshold?: number; minChange?: number } = {}): (Cut & { flash?: boolean })[] {
  // Both the histogram and the pixels must jump: a fade step can move a flat picture's histogram a whole bin while
  // each pixel changes by only a few levels.
  const th = o.threshold ?? 0.35, minChange = o.minChange ?? 0.05;
  const cuts: (Cut & { flash?: boolean })[] = [];
  const n = m.histDist.length;
  for (let i = 1; i < n; i++) {
    const d = m.histDist[i]!;
    if (d < th || m.energy[i]! < minChange) continue;
    // A spike at most 2 frames wide (a flash is in and out): a fade or a fast move changes the picture for many frames
    // in a row, each step about as big as the next.
    let a0 = i, a1 = i;
    while (a0 > 1 && m.histDist[a0 - 1]! >= d * 0.5) a0--;
    while (a1 < n - 1 && m.histDist[a1 + 1]! >= d * 0.5) a1++;
    if (a1 - a0 + 1 <= 2) cuts.push({ t: round3(i / m.fps), strength: round3(Math.min(1, d)) });
  }
  for (let k = 0; k + 1 < cuts.length; k++) if ((cuts[k + 1]!.t - cuts[k]!.t) * m.fps <= 2.5) cuts[k]!.flash = true;
  return cuts;
}

/**
 * Action peaks: local maxima of the (lightly smoothed) motion energy that stand out from the clip's own baseline
 * (median + k·MAD), at least `minGapSec` apart, with cut frames left out. Strength 0–1 relative to the biggest peak.
 */
export function findPeaks(m: MotionFrames, o: { minGapSec?: number; sensitivity?: number; max?: number; cuts?: Cut[] } = {}): Peak[] {
  const n = m.energy.length;
  if (n < 3) return [];
  const cutFrames = new Set((o.cuts ?? findCuts(m)).flatMap(c => { const f = Math.round(c.t * m.fps); return [f - 1, f, f + 1]; }));
  // A cut frame's difference isn't motion: replace it with its neighbours' before smoothing.
  const e = Array.from(m.energy, (v, i) => (cutFrames.has(i) ? Math.min(m.energy[i - 2] ?? 0, m.energy[i + 2] ?? 0) : v));
  const s = e.map((_, i) => ((e[i - 1] ?? e[i]!) + 2 * e[i]! + (e[i + 1] ?? e[i]!)) / 4);
  const sorted = [...s].sort((a, b) => a - b);
  const med = sorted[Math.floor(n / 2)]!;
  const mad = [...s].map(v => Math.abs(v - med)).sort((a, b) => a - b)[Math.floor(n / 2)]!;
  const floor = med + (o.sensitivity ?? 4) * Math.max(mad, 0.002);
  const cands: { i: number; v: number }[] = [];
  for (let i = 1; i < n - 1; i++) if (s[i]! > floor && s[i]! >= s[i - 1]! && s[i]! > s[i + 1]!) cands.push({ i, v: s[i]! });
  // Strongest first, keeping those at least minGap apart.
  const gap = Math.max(1, Math.round((o.minGapSec ?? 0.25) * m.fps));
  const kept: { i: number; v: number }[] = [];
  for (const c of cands.sort((a, b) => b.v - a.v)) if (kept.every(k => Math.abs(k.i - c.i) >= gap)) kept.push(c);
  const top = kept[0]?.v ?? 1;
  return kept.slice(0, o.max ?? 200).sort((a, b) => a.i - b.i).map(k => ({ t: round3(k.i / m.fps), strength: round3(k.v / top) }));
}

export type Impact = { t: number; strength: number; kind: 'start' | 'stop' | 'cut' };
/**
 * Impact frames (song_notes workflow): where motion STOPS sharply (a landing or contact: frames that moved, then the
 * next few frames still; t is the frame where it comes to rest), where it STARTS suddenly (still frames, then movement;
 * t is the first moving frame), and hard cuts. Moving = above the clip's baseline (median + k·MAD). Strength 0–1 within
 * starts and stops (relative to the sharpest), the cut's own strength for cuts. At least 0.15 s between two of a kind.
 */
export function findImpacts(m: MotionFrames, o: { sensitivity?: number; cuts?: Cut[] } = {}): Impact[] {
  const n = m.energy.length;
  if (n < 4) return [];
  const cuts = o.cuts ?? findCuts(m);
  const cutFrames = new Set(cuts.flatMap(c => { const f = Math.round(c.t * m.fps); return [f - 1, f, f + 1]; }));
  const e = Array.from(m.energy, (v, i) => (cutFrames.has(i) ? Math.min(m.energy[i - 2] ?? 0, m.energy[i + 2] ?? 0) : v));
  // A clip may move half the time (a landing every second): "still" is its quietest frames (sensor noise, grain), and
  // "moving" is a share of the way from there to its busy frames, not a deviation from the median.
  const sorted = [...e].sort((a, b) => a - b), q = (f: number) => sorted[Math.min(n - 1, Math.floor(f * n))]!;
  const still = q(0.1), busy = q(0.95);
  const act = still + Math.max(0.003, 0.2 * (busy - still)) * ((o.sensitivity ?? 3) / 3);
  const mx = (a: number, b: number) => { let v = 0; for (let k = Math.max(0, a); k <= Math.min(n - 1, b); k++) v = Math.max(v, e[k]!); return v; };
  const quiet = (v: number, ref: number) => v - still <= 0.3 * (ref - still);
  const cands: { i: number; v: number; kind: 'start' | 'stop' }[] = [];
  for (let i = 1; i < n; i++) {
    // stop at i: frames i-2..i moved, i+1..i+3 still (frame i is the last that differs from the one before it)
    const pre = mx(i - 2, i), post = mx(i + 1, i + 3);
    if (i + 1 < n && pre >= act && quiet(post, pre) && e[i]! - still >= 0.12 * (pre - still)) cands.push({ i, v: pre - post, kind: 'stop' });
    // start at i: frames i-3..i-1 still, i..i+2 moved
    const before = mx(i - 3, i - 1), after = mx(i, i + 2);
    if (i >= 1 && after >= act && quiet(before, after) && e[i]! - still >= 0.3 * (after - still)) cands.push({ i, v: after - before, kind: 'start' });
  }
  const gap = Math.max(1, Math.round(0.15 * m.fps)), out: Impact[] = [];
  for (const kind of ['start', 'stop'] as const) {
    const list = cands.filter(c => c.kind === kind).sort((a, b) => b.v - a.v), kept: typeof list = [];
    for (const c of list) if (kept.every(k => Math.abs(k.i - c.i) >= gap)) kept.push(c);
    const top = kept[0]?.v ?? 1;
    for (const k of kept) out.push({ t: round3(k.i / m.fps), strength: round3(k.v / top), kind });
  }
  for (const c of cuts) out.push({ t: c.t, strength: c.strength, kind: 'cut' });
  return out.sort((a, b) => a.t - b.t);
}

/** The energy curve downsampled to at most `points` values (for drawing), 0–1 relative to its maximum. */
export function energyCurve(m: MotionFrames, points = 120): { everySec: number; values: number[] } {
  const n = m.energy.length, step = Math.max(1, Math.ceil(n / points));
  const raw: number[] = [];
  for (let i = 0; i < n; i += step) { let s = 0, c = 0; for (let j = i; j < Math.min(n, i + step); j++) { s += m.energy[j]!; c++; } raw.push(s / c); }
  const max = Math.max(0, ...raw);
  return { everySec: round3(step / m.fps), values: raw.map(v => round3(max ? v / max : 0)) };
}

const round3 = (x: number) => Math.round(x * 1000) / 1000;
