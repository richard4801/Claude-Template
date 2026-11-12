// Edit suite audio helpers (plans/video-editor.md "Edit suite additions"): voice effects / enhance as biquad chains
// (the apps run the same coefficients on device), and free beat detection for music (server, from decoded samples).
import { execFile } from 'node:child_process';
import type { VoiceEffect } from './model.js';

export type Biquad = { b0: number; b1: number; b2: number; a1: number; a2: number };
type Kind = 'lowpass' | 'highpass' | 'peaking' | 'lowshelf' | 'highshelf';
const r9 = (v: number) => Math.round(v * 1e9) / 1e9;

/** RBJ audio-EQ-cookbook biquad, normalised by a0. Shelves use S = 1. */
export function biquad(kind: Kind, f: number, sr: number, q = Math.SQRT1_2, gainDb = 0): Biquad {
  const A = Math.pow(10, gainDb / 40), w = (2 * Math.PI * f) / sr, cw = Math.cos(w), sw = Math.sin(w);
  const alpha = kind === 'lowshelf' || kind === 'highshelf' ? (sw / 2) * Math.SQRT2 : sw / (2 * q);
  let b0: number, b1: number, b2: number, a0: number, a1: number, a2: number;
  const sq = 2 * Math.sqrt(A) * alpha;
  switch (kind) {
    case 'lowpass': b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case 'highpass': b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case 'peaking': b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A; break;
    case 'lowshelf': b0 = A * (A + 1 - (A - 1) * cw + sq); b1 = 2 * A * (A - 1 - (A + 1) * cw); b2 = A * (A + 1 - (A - 1) * cw - sq);
      a0 = A + 1 + (A - 1) * cw + sq; a1 = -2 * (A - 1 + (A + 1) * cw); a2 = A + 1 + (A - 1) * cw - sq; break;
    case 'highshelf': b0 = A * (A + 1 + (A - 1) * cw + sq); b1 = -2 * A * (A - 1 + (A + 1) * cw); b2 = A * (A + 1 + (A - 1) * cw - sq);
      a0 = A + 1 - (A - 1) * cw + sq; a1 = 2 * (A - 1 - (A + 1) * cw); a2 = A + 1 - (A - 1) * cw - sq; break;
  }
  return { b0: r9(b0 / a0), b1: r9(b1 / a0), b2: r9(b2 / a0), a1: r9(a1 / a0), a2: r9(a2 / a0) };
}

/** The filters for a clip's voice: `enhance` first, then the effect. Empty = untouched. */
export function voiceChain(o: { voiceEffect?: VoiceEffect; enhance?: boolean }, sr: number): Biquad[] {
  const out: Biquad[] = [];
  if (o.enhance) out.push(biquad('highpass', 80, sr), biquad('lowshelf', 200, sr, 0, -2), biquad('peaking', 3000, sr, 1, 3));
  switch (o.voiceEffect ?? 'none') {
    case 'warm': out.push(biquad('lowshelf', 200, sr, 0, 3), biquad('highshelf', 6000, sr, 0, -3)); break;
    case 'radio': out.push(biquad('highpass', 500, sr), biquad('lowpass', 3000, sr), biquad('peaking', 1500, sr, 1, 4)); break;
    case 'phone': out.push(biquad('highpass', 300, sr), biquad('highpass', 300, sr), biquad('lowpass', 3400, sr), biquad('lowpass', 3400, sr)); break;
    case 'deep': out.push(biquad('lowshelf', 150, sr, 0, 6), biquad('highshelf', 3000, sr, 0, -4)); break;
    default: break;
  }
  return out;
}

/** Runs a chain over mono samples (direct form I, state per filter). Used by tests; the apps do the same per channel. */
export function runChain(chain: Biquad[], x: Float64Array | number[]): Float64Array {
  let cur = Float64Array.from(x);
  for (const f of chain) {
    const y = new Float64Array(cur.length);
    let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (let i = 0; i < cur.length; i++) {
      const v = f.b0 * cur[i]! + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2;
      x2 = x1; x1 = cur[i]!; y2 = y1; y1 = v; y[i] = v;
    }
    cur = y;
  }
  return cur;
}

// ------------------------------------------------------------------ beats
export type Beats = { bpm: number; beats: number[]; strong: number[] };
export const BEAT_SR = 11025, BEAT_HOP = 256;
/**
 * Beat grid from mono samples: an onset envelope (half-wave rectified rise of log energy, hop 256 at 11025 Hz),
 * tempo by autocorrelation (60–180 BPM, a mild preference near 120), the phase with the most onset energy, then beats
 * on that grid snapped to the nearest onset peak within ±70 ms; every 4th beat from the strongest offset is "strong".
 */
export function detectBeats(x: Float32Array, sr = BEAT_SR): Beats {
  const hop = BEAT_HOP, win = 1024, n = Math.floor((x.length - win) / hop);
  if (n < 32) return { bpm: 0, beats: [], strong: [] };
  const env = new Float64Array(n);
  let prev = 0;
  for (let i = 0; i < n; i++) {
    let e = 0; for (let k = 0; k < win; k++) { const v = x[i * hop + k]!; e += v * v; }
    const le = Math.log(1e-9 + e / win);
    env[i] = i ? Math.max(0, le - prev) : 0; prev = le;
  }
  const fps = sr / hop;
  let best = 0, bestLag = 0;
  for (let bpm = 60; bpm <= 180; bpm += 0.1) {
    const lag = (60 / bpm) * fps; let s = 0, c = 0;
    for (let i = 0; i + lag < n; i++) { const j = i + lag, j0 = Math.floor(j), f = j - j0; s += env[i]! * (env[j0]! * (1 - f) + (env[Math.min(n - 1, j0 + 1)]! * f)); c++; }
    const score = (c ? s / c : 0) * Math.exp(-0.5 * Math.pow(Math.log2(bpm / 120) / 1.0, 2));
    if (score > best) { best = score; bestLag = lag; }
  }
  if (!bestLag) return { bpm: 0, beats: [], strong: [] };
  const snap = Math.round(0.07 * fps), beatsF: number[] = [];
  // workstream 1: octave check. The autocorrelation scores a pulse and half of it alike, so a 140 bpm track could read
  // as 70. If the points halfway between the grid's beats are onsets too (at least half as strong), the tempo is the
  // double, as long as that stays at most 180 bpm.
  const near = (t: number) => { const c = Math.round(t); let m = 0; for (let k = Math.max(0, c - snap); k <= Math.min(n - 1, c + snap); k++) m = Math.max(m, env[k]!); return m; };
  const gridMean = (lag: number, ph: number) => { let s = 0, c = 0; for (let t = ph; t < n; t += lag) { s += near(t); c++; } return c ? s / c : 0; };
  const phaseOf = (lag: number) => { let bp = 0, bs = -1; for (let ph = 0; ph < lag; ph += 0.5) { let s = 0; for (let t = ph; t < n; t += lag) s += env[Math.round(t)] ?? 0; if (s > bs) { bs = s; bp = ph; } } return bp; };
  let bestPhase = phaseOf(bestLag);
  // A pulse with off-beats (eighth notes) also lines up every 1.5 beats (120 bpm read as 80): if a grid two thirds as
  // long lands on onsets just as well, that is the beat.
  {
    const l2 = (bestLag * 2) / 3, p2 = phaseOf(l2);
    if ((60 * fps) / l2 <= 180.5 && gridMean(l2, p2) >= 0.8 * gridMean(bestLag, bestPhase)) { bestLag = l2; bestPhase = p2; }
  }
  while ((60 * fps) / (bestLag / 2) <= 180.5) {
    const on = gridMean(bestLag, bestPhase), mid = gridMean(bestLag, bestPhase + bestLag / 2);
    if (!(on > 0 && mid >= 0.5 * on)) break;
    bestLag /= 2; bestPhase = phaseOf(bestLag);
  }
  // Track: each beat is looked for around the previous beat + one period, so a slightly wrong tempo doesn't drift.
  for (let t = bestPhase; t < n; ) {
    const c = Math.round(t); let m = Math.min(n - 1, c);
    for (let k = Math.max(0, c - snap); k <= Math.min(n - 1, c + snap); k++) if (env[k]! > env[m]!) m = k;
    if (env[m]! <= 0) m = Math.min(n - 1, c); // no onset nearby: keep the grid
    beatsF.push(m);
    t = m + bestLag;
  }
  let strongOff = 0, strongSum = -1;
  for (let o = 0; o < 4; o++) { let s = 0; for (let k = o; k < beatsF.length; k += 4) s += env[beatsF[k]!]!; if (s > strongSum) { strongSum = s; strongOff = o; } }
  const toSec = (f: number) => Math.round(((f * hop + win - hop / 2) / sr) * 1000) / 1000; // the rise shows when the window first takes the onset in
  // No beats in silence: the grid keeps running through a silent tail or intro; drop beats whose surrounding ~0.3 s is
  // 45 dB below the track's loudest stretch (or quieter than -60 dBFS).
  const rmsDb = (f: number) => { const c = f * hop + win / 2, h = Math.round(0.15 * sr); let e = 0, k = 0; for (let i = Math.max(0, c - h); i < Math.min(x.length, c + h); i++) { e += x[i]! * x[i]!; k++; } return 10 * Math.log10(1e-12 + (k ? e / k : 0)); };
  let loud = -120; for (let f = 0; f < n; f += 4) loud = Math.max(loud, rmsDb(f));
  const floor = Math.max(-60, loud - 45);
  for (let k = beatsF.length - 1; k >= 0; k--) if (rmsDb(beatsF[k]!) < floor) beatsF.splice(k, 1);
  if (!beatsF.length) return { bpm: 0, beats: [], strong: [] };
  const beats = beatsF.map(toSec);
  // Tempo from the beats themselves (least squares on beat number → time), finer than the lag grid.
  const m = beats.length, mx = (m - 1) / 2, my = beats.reduce((a, b) => a + b, 0) / m;
  let sxy = 0, sxx = 0; beats.forEach((b, k) => { sxy += (k - mx) * (b - my); sxx += (k - mx) ** 2; });
  const period = m > 2 && sxy > 0 ? sxy / sxx : bestLag / fps;
  return { bpm: Math.round((60 / period) * 10) / 10, beats, strong: beats.filter((_, k) => k % 4 === strongOff) };
}

/** Decodes a file or URL's audio (first 10 min) to 11025 Hz mono floats with ffmpeg (analysis only; nothing encoded). */
export function decodeMono(ffmpeg: string, input: string, maxSec = 600, fromSec = 0): Promise<Float32Array> {
  return new Promise((resolve, reject) => {
    execFile(ffmpeg, ['-v', 'error', '-threads', '1', ...(fromSec > 0 ? ['-ss', fromSec.toFixed(3)] : []), '-vn', '-sn', '-dn', '-i', input, '-ac', '1', '-ar', String(BEAT_SR), '-t', String(maxSec), '-f', 'f32le', 'pipe:1'],
      { encoding: 'buffer', timeout: 180_000, maxBuffer: BEAT_SR * 4 * maxSec + 1024 * 1024 }, (err, stdout, stderr) => {
        if (err) return reject(new Error(`ffmpeg failed: ${String(stderr ?? '').trim().split('\n').slice(-1)[0]?.slice(0, 200) || err.message}`));
        const b = stdout as Buffer;
        resolve(new Float32Array(b.buffer.slice(b.byteOffset, b.byteOffset + Math.floor(b.length / 4) * 4)));
      });
  });
}
