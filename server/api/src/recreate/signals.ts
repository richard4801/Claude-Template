// Recreate this edit · the reference's motion signals (workstream 1, plans/recreate-edit.md "Analysis"): global
// camera motion between frames, shots (hard cuts and gradual transitions), and per shot: camera motion as transform
// keys, a speed curve and the transition into it. Pure functions over the grey proxy (editor/motion.ts). Free.
import type { Cut, MotionFrames, Peak } from '../editor/motion.js';

export type Global = { dx: number; dy: number; scale: number };

/** Mean absolute difference of `prev` against `cur` sampled at `prev`'s grid moved by (dx, dy) px and scaled by s. */
function sadAt(prev: Uint8Array, cur: Uint8Array, w: number, h: number, dx: number, dy: number, s: number, best: number, margin: number) {
  const step = 3, cx = w / 2, cy = h / 2;
  let e = 0, n = 0;
  for (let y = margin; y < h - margin; y += step) {
    for (let x = margin; x < w - margin; x += step) {
      const sx = Math.round(cx + (x - cx) * s + dx), sy = Math.round(cy + (y - cy) * s + dy);
      if (sx < 0 || sy < 0 || sx >= w || sy >= h) continue;
      e += Math.abs(cur[sy * w + sx]! - prev[y * w + x]!); n++;
    }
    if (n && e / n > best) return Infinity; // early out
  }
  return n ? e / n : Infinity;
}

/**
 * The camera's apparent motion from `prev` to `cur`: the content's shift (fraction of the frame, + = right/down) and
 * scale (> 1 = the content grows, a zoom in). Block matching on a sampled grid within ±`radius` px; `scales` adds a
 * scale search around the best shift.
 */
export function globalMotion(prev: Uint8Array, cur: Uint8Array, w: number, h: number, o: { radius?: number; scales?: number[]; around?: { dx: number; dy: number } } = {}): Global & { err: number } {
  const radius = o.radius ?? 6, margin = radius + 2;
  const c = o.around ? { dx: Math.round(o.around.dx), dy: Math.round(o.around.dy) } : { dx: 0, dy: 0 };
  let best = { dx: c.dx, dy: c.dy, s: 1, e: sadAt(prev, cur, w, h, c.dx, c.dy, 1, Infinity, margin) };
  for (let dy = c.dy - radius; dy <= c.dy + radius; dy++) for (let dx = c.dx - radius; dx <= c.dx + radius; dx++) {
    if (dx === c.dx && dy === c.dy) continue;
    const e = sadAt(prev, cur, w, h, dx, dy, 1, best.e, margin);
    if (e < best.e - 0.01) best = { dx, dy, s: 1, e };
  }
  for (const sc of o.scales ?? []) for (let dy = best.dy - 1; dy <= best.dy + 1; dy++) for (let dx = best.dx - 1; dx <= best.dx + 1; dx++) {
    const e = sadAt(prev, cur, w, h, dx, dy, sc, best.e, margin);
    if (e < best.e - 0.01) best = { dx, dy, s: sc, e };
  }
  return { dx: best.dx / w, dy: best.dy / h, scale: best.s, err: best.e / 255 };
}

const ZOOM_GAP = 6;
const ZOOM_SCALES = Array.from({ length: 29 }, (_, k) => Math.round((0.86 + k * 0.01) * 100) / 100).filter(x => x !== 1);

/**
 * Per-frame camera motion for a whole clip, fed frame by frame (measureMotion's onFrame): the shift from the previous
 * frame, and the scale measured against the frame `ZOOM_GAP` back (a slow zoom changes too little between two frames
 * to see), spread evenly over those frames.
 */
export function motionTracker() {
  const g: Global[] = [{ dx: 0, dy: 0, scale: 1 }];
  const ring: Uint8Array[] = [];
  const hook = (cur: Uint8Array, prev: Uint8Array | null, i: number, size: { width: number; height: number }) => {
    const { width: w, height: h } = size;
    if (prev) { const m = globalMotion(prev, cur, w, h); g[i] = { dx: m.dx, dy: m.dy, scale: 1 }; }
    ring.push(cur);
    if (ring.length > ZOOM_GAP + 1) ring.shift();
    if (i >= ZOOM_GAP && ring.length === ZOOM_GAP + 1) {
      let sx = 0, sy = 0;
      for (let k = i - ZOOM_GAP + 1; k <= i; k++) { sx += g[k]!.dx * w; sy += g[k]!.dy * h; }
      const m = globalMotion(ring[0]!, cur, w, h, { radius: 1, around: { dx: sx, dy: sy }, scales: ZOOM_SCALES });
      g[i]!.scale = Math.round(Math.pow(m.scale, 1 / ZOOM_GAP) * 100000) / 100000;
    }
  };
  return { g, hook };
}

export type Shot = { startSec: number; endSec: number; startFrame: number; endFrame: number };
export type Gradual = { atSec: number; startFrame: number; endFrame: number; kind: 'fade' | 'crossfade' };

const histL1 = (a: Float32Array, b: Float32Array) => { let d = 0; for (let i = 0; i < a.length; i++) d += Math.abs(a[i]! - b[i]!); return d / 2; };

/**
 * Gradual transitions: a run of frames whose picture keeps changing a little (no single jump: not a cut) that adds up
 * to a different picture from one end to the other, while the camera holds still. Through black (or white) = fade;
 * otherwise crossfade. Runs of 4 frames to 2.5 s; gaps of up to 2 quiet frames are bridged.
 */
export function findGradual(m: MotionFrames, cuts: Cut[], g: Global[]): Gradual[] {
  const n = m.hists.length, out: Gradual[] = [];
  const cutF = new Set(cuts.flatMap(c => { const f = Math.round(c.t * m.fps); return [f - 1, f, f + 1]; }));
  const active = (k: number) => m.histDist[k]! > 0.08 && !cutF.has(k);
  let k = 1;
  while (k < n) {
    if (!active(k)) { k++; continue; }
    let end = k, quiet = 0;
    for (let j = k + 1; j < n; j++) { if (active(j)) { end = j; quiet = 0; } else if (++quiet > 2) break; }
    const a = k - 1, b = end, len = b - a;
    k = end + 1;
    if (len < 4 || len > 2.5 * m.fps) continue;
    if (histL1(m.hists[a]!, m.hists[b]!) <= 0.5) continue;
    let hard = false;
    for (let j = a + 1; j <= b; j++) if (m.histDist[j]! >= 0.35 && m.energy[j]! >= 0.05) { hard = true; break; }
    const win = g.slice(a + 1, b + 1);
    // Only a big, sustained camera move rules it out (block matching is unreliable while two pictures blend; a move over
    // the same scene barely changes the histogram anyway).
    const still = Math.abs(win.reduce((s, x) => s + x.dx, 0)) < 0.4 && Math.abs(win.reduce((s, x) => s + x.dy, 0)) < 0.4 && Math.abs(win.reduce((s, x) => s + Math.log(x.scale), 0)) < 0.4;
    if (hard || !still) continue;
    const lum = Array.from(m.luma.slice(a, b + 1));
    const dark = Math.min(...lum) < 0.06 || Math.max(...lum) > 0.96;
    out.push({ atSec: round3((a + b) / 2 / m.fps), startFrame: a, endFrame: b, kind: dark ? 'fade' : 'crossfade' });
  }
  return out;
}

/** Shots between the boundaries (hard cuts, the middle of gradual transitions); flash frames don't start a shot. */
export function shotsOf(m: MotionFrames, cuts: (Cut & { flash?: boolean })[], gradual: Gradual[]): Shot[] {
  const n = m.energy.length, fps = m.fps;
  const bounds: number[] = [];
  for (let k = 0; k < cuts.length; k++) {
    const c = cuts[k]!;
    if (c.flash) continue; // the flash's own frame; the cut back out of it ends the flash
    const prevFlash = k > 0 && cuts[k - 1]!.flash;
    // Out of a flash back to the same picture: not a new shot.
    if (prevFlash) {
      const f0 = Math.round(cuts[k - 1]!.t * fps) - 1, f1 = Math.round(c.t * fps);
      if (f0 >= 0 && f1 < n && histL1(m.hists[f0]!, m.hists[f1]!) < 0.3) continue;
    }
    bounds.push(Math.round(c.t * fps));
  }
  for (const gr of gradual) bounds.push(Math.round(gr.atSec * fps));
  const b = [...new Set(bounds)].filter(f => f > 0 && f < n).sort((x, y) => x - y);
  const edges = [0, ...b, n];
  const shots: Shot[] = [];
  for (let k = 0; k + 1 < edges.length; k++) {
    if (edges[k + 1]! - edges[k]! < 2) continue; // a 1-frame sliver (a flash) belongs to its neighbour
    shots.push({ startFrame: edges[k]!, endFrame: edges[k + 1]!, startSec: round3(edges[k]! / fps), endSec: round3(edges[k + 1]! / fps) });
  }
  // Merge slivers into the previous shot so the shots still cover the whole clip.
  for (let k = 1; k < shots.length; k++) if (shots[k]!.startFrame !== shots[k - 1]!.endFrame) { shots[k - 1]!.endFrame = shots[k]!.startFrame; shots[k - 1]!.endSec = shots[k]!.startSec; }
  if (shots.length) { shots[0]!.startFrame = 0; shots[0]!.startSec = 0; }
  return shots;
}

export type CameraMotion = { motion: 'static' | 'pan' | 'tilt' | 'zoom_in' | 'zoom_out' | 'shake' | 'mixed'; shake: number;
  keys: { t: number; x: number; y: number; scale: number }[]; confidence: number };

/** Frames whose motion estimate is meaningless: inside gradual transitions and next to cuts (and the zoom gap after). */
export function transitionFrames(m: MotionFrames, cuts: Cut[], gradual: Gradual[]): Set<number> {
  const s = new Set<number>();
  for (const c of cuts) { const f = Math.round(c.t * m.fps); for (let k = f - 1; k <= f + 6; k++) s.add(k); }
  for (const gr of gradual) for (let k = gr.startFrame; k <= gr.endFrame + 6; k++) s.add(k);
  return s;
}

/**
 * A shot's camera motion: the content's cumulative shift and scale from the shot's first frame, as transform keys
 * (about 4 a second), labelled by what dominates. Shake = frame-to-frame jitter that doesn't add up to a move.
 */
export function cameraOf(shot: Shot, g: Global[], fps: number, skip: Set<number> = new Set()): CameraMotion {
  const a = shot.startFrame + 1, b = shot.endFrame; // g[i] is frame i-1 → i
  const keys: CameraMotion['keys'] = [{ t: 0, x: 0, y: 0, scale: 1 }];
  let x = 0, y = 0, s = 1;
  const every = Math.max(1, Math.round(fps / 4));
  let jitter = 0, n = 0, pdx = 0, pdy = 0;
  for (let i = a; i < b; i++) {
    const m = g[i];
    if (!m || skip.has(i)) continue; // inside a transition: two pictures blend, the motion estimate means nothing
    x += m.dx; y += m.dy; s *= m.scale;
    if (n) jitter += Math.hypot(m.dx - pdx, m.dy - pdy);
    pdx = m.dx; pdy = m.dy; n++;
    if ((i - shot.startFrame) % every === 0 || i === b - 1) keys.push({ t: round3((i - shot.startFrame) / fps), x: round3(x), y: round3(y), scale: round3(s) });
  }
  const shake = n > 1 ? Math.min(1, (jitter / (n - 1)) * 12) : 0;
  const dur = Math.max(1 / fps, (b - shot.startFrame) / fps);
  const pan = Math.abs(x) / dur, tilt = Math.abs(y) / dur, zoom = Math.abs(Math.log(s)) / dur;
  const big = [pan > 0.08 ? 'pan' : null, tilt > 0.08 ? 'tilt' : null, zoom > 0.06 ? (s > 1 ? 'zoom_in' : 'zoom_out') : null].filter(Boolean) as CameraMotion['motion'][];
  const motion: CameraMotion['motion'] = big.length > 1 ? 'mixed' : big[0] ?? (shake > 0.35 ? 'shake' : 'static');
  const confidence = round3(n < 4 ? 0.3 : motion === 'static' ? 0.8 : 0.65);
  return { motion, shake: round3(shake), keys, confidence };
}

export type Speed = { ramp: 'none' | 'speed_up' | 'slow_down' | 'freeze' | 'mixed'; curve: { t: number; speed: number }[]; confidence: number;
  /** Where the longest freeze is (seconds from the shot's start), when `ramp` is "freeze". */
  freeze?: { t: number; durationSec: number } };

/**
 * A shot's playback speed, estimated from how much the picture changes per frame (relative to the shot's own median):
 * a ramp is a sustained rise or fall, a freeze is a run of identical frames in a moving shot. A proxy for optical flow,
 * so its confidence stays moderate.
 */
export function speedOf(shot: Shot, m: MotionFrames): Speed {
  const e = Array.from(m.energy.slice(shot.startFrame + 1, shot.endFrame));
  if (e.length < 6) return { ramp: 'none', curve: [{ t: 0, speed: 1 }], confidence: 0.3 };
  const med = [...e].sort((x, y) => x - y)[Math.floor(e.length / 2)]!;
  const base = Math.max(med, 0.004);
  const every = Math.max(1, Math.round(m.fps / 4));
  const curve: Speed['curve'] = [];
  for (let i = 0; i < e.length; i += every) {
    const w = e.slice(Math.max(0, i - every), i + every);
    curve.push({ t: round3(i / m.fps), speed: round3(Math.min(4, (w.reduce((x, y) => x + y, 0) / w.length) / base)) });
  }
  const third = Math.floor(e.length / 3);
  const mean = (xs: number[]) => xs.reduce((x, y) => x + y, 0) / Math.max(1, xs.length);
  const first = mean(e.slice(0, third)), last = mean(e.slice(-third));
  const moving = med > 0.01;
  let frozen = 0, run = 0, frozenEnd = 0;
  e.forEach((v, i) => { run = v < 0.0015 ? run + 1 : 0; if (run > frozen) { frozen = run; frozenEnd = i; } });
  const ramp: Speed['ramp'] = moving && frozen >= Math.round(m.fps * 0.3) ? 'freeze'
    : moving && last > first * 2 ? 'speed_up' : moving && first > last * 2 ? 'slow_down' : 'none';
  // The run of identical frames: the frame before it is the one held (difference i is frame i+1 against frame i).
  const freeze = ramp === 'freeze' ? { t: round3((frozenEnd - frozen + 1) / m.fps), durationSec: round3(frozen / m.fps) } : undefined;
  return { ramp, curve, confidence: moving ? 0.55 : 0.35, ...(freeze ? { freeze } : {}) };
}

export type Transition = { atSec: number; kind: 'cut' | 'flash' | 'whip' | 'zoom' | 'fade' | 'crossfade' | 'glitch' | 'unknown'; durationSec: number; confidence: number };

/** What happens at a hard cut: a flash, a whip (fast camera motion across it), a zoom through, or a plain cut. */
export function classifyCut(c: Cut & { flash?: boolean }, m: MotionFrames, g: Global[], cuts: (Cut & { flash?: boolean })[]): Transition {
  const f = Math.round(c.t * m.fps), fps = m.fps;
  const prevFlash = cuts.find(x => x.flash && Math.abs(Math.round(x.t * fps) - f) <= 3 && x.t < c.t);
  if (c.flash || prevFlash || (m.luma[f] ?? 0) > 0.9) return { atSec: c.t, kind: 'flash', durationSec: round3(2 / fps), confidence: 0.8 };
  const around = (k: number) => { const xs: Global[] = []; for (let i = f - k; i <= f + k; i++) if (i !== f && g[i]) xs.push(g[i]!); return xs; };
  const near = around(3);
  const speed = near.length ? near.reduce((a, x) => a + Math.hypot(x.dx, x.dy), 0) / near.length : 0;
  const zoom = near.length ? near.reduce((a, x) => a + Math.abs(Math.log(x.scale)), 0) / near.length : 0;
  const blur = ((m.energy[f - 1] ?? 0) + (m.energy[f + 1] ?? 0)) / 2;
  if (speed > 0.035 && blur > 0.04) return { atSec: c.t, kind: 'whip', durationSec: round3(6 / fps), confidence: 0.6 };
  if (zoom > 0.025) return { atSec: c.t, kind: 'zoom', durationSec: round3(6 / fps), confidence: 0.55 };
  return { atSec: c.t, kind: 'cut', durationSec: 0, confidence: 0.9 };
}

export const peaksIn = (peaks: Peak[], shot: Shot) => peaks.filter(p => p.t >= shot.startSec && p.t < shot.endSec).map(p => ({ t: round3(p.t - shot.startSec), strength: p.strength }));
const round3 = (x: number) => Math.round(x * 1000) / 1000;
