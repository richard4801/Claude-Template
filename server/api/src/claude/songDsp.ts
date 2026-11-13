// Song notes DSP (free, pure JS on decoded mono samples): every note hit (spectral-flux onsets in three bands, refined
// in the time domain to a few ms), the key (chroma + Krumhansl–Schmuckler), sections (novelty on a self-similarity
// matrix of chroma + band energy, labelled by repetition and energy) and an energy curve. Used by the song_notes tool
// (claude/songNotes.ts); the tempo and beats come from editor/audio.ts detectBeats.

// ---- FFT ------------------------------------------------------------------------------------------------------------
type Fft = { n: number; rev: Uint32Array; cos: Float64Array; sin: Float64Array; win: Float64Array };
const ffts = new Map<number, Fft>();
function fftPlan(n: number): Fft {
  const hit = ffts.get(n);
  if (hit) return hit;
  const bits = Math.log2(n), rev = new Uint32Array(n);
  for (let i = 0; i < n; i++) { let r = 0; for (let b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b); rev[i] = r; }
  const cos = new Float64Array(n / 2), sin = new Float64Array(n / 2), win = new Float64Array(n);
  for (let i = 0; i < n / 2; i++) { cos[i] = Math.cos((2 * Math.PI * i) / n); sin[i] = -Math.sin((2 * Math.PI * i) / n); }
  for (let i = 0; i < n; i++) win[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / n);
  const p = { n, rev, cos, sin, win };
  ffts.set(n, p);
  return p;
}
/** Magnitude spectrum (bins 0..n/2) of the Hann-windowed frame x[start..start+n) (zeros past the end). */
export function magnitudes(x: Float32Array, start: number, n: number, out?: Float64Array): Float64Array {
  const p = fftPlan(n), re = new Float64Array(n), im = new Float64Array(n);
  for (let i = 0; i < n; i++) { const k = start + i; re[p.rev[i]!] = k >= 0 && k < x.length ? x[k]! * p.win[i]! : 0; }
  for (let size = 2; size <= n; size <<= 1) {
    const half = size >> 1, step = n / size;
    for (let i = 0; i < n; i += size) for (let j = 0; j < half; j++) {
      const wr = p.cos[j * step]!, wi = p.sin[j * step]!, a = i + j, b = a + half;
      const tr = re[b]! * wr - im[b]! * wi, ti = re[b]! * wi + im[b]! * wr;
      re[b] = re[a]! - tr; im[b] = im[a]! - ti; re[a] = re[a]! + tr; im[a] = im[a]! + ti;
    }
  }
  const m = out ?? new Float64Array(n / 2 + 1);
  for (let k = 0; k <= n / 2; k++) m[k] = Math.hypot(re[k]!, im[k]!);
  return m;
}

// ---- pitch ----------------------------------------------------------------------------------------------------------
export const PITCHES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'] as const;
/** MIDI pitch class (C = 0) of a frequency. */
const pcOf = (f: number) => (((Math.round(12 * Math.log2(f / 440)) + 69) % 12) + 12) % 12;
/** 12 pitch-class weights from a magnitude spectrum of an n-point FFT, bins between lo and hi Hz. */
function chromaOf(mag: Float64Array, n: number, sr: number, lo = 55, hi = 2000, out = new Float64Array(12)): Float64Array {
  const k0 = Math.max(1, Math.ceil((lo * n) / sr)), k1 = Math.min(mag.length - 1, Math.floor((hi * n) / sr));
  for (let k = k0; k <= k1; k++) out[pcOf((k * sr) / n)]! += mag[k]!;
  return out;
}

// ---- key ------------------------------------------------------------------------------------------------------------
const KS_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const KS_MINOR = [6.33, 2.68, 3.52, 5.38, 2.6, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
const pearson = (a: ArrayLike<number>, b: ArrayLike<number>) => {
  let ma = 0, mb = 0; for (let i = 0; i < 12; i++) { ma += a[i]!; mb += b[i]!; } ma /= 12; mb /= 12;
  let s = 0, sa = 0, sb = 0; for (let i = 0; i < 12; i++) { const x = a[i]! - ma, y = b[i]! - mb; s += x * y; sa += x * x; sb += y * y; }
  return sa && sb ? s / Math.sqrt(sa * sb) : 0;
};
// Camelot wheel (for chaining songs): major keys B, minor A; C major = 8B, A minor = 8A.
const CAMELOT_MAJOR = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1], CAMELOT_MINOR = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10];
export type Key = { name: string; tonic: string; mode: 'major' | 'minor'; confidence: number; camelot: string; relative: string; runnerUp: { name: string; r: number }; mixesWith: string[] };
const keyName = (pc: number, mode: 'major' | 'minor') => `${PITCHES[pc]} ${mode}`;
const camelotOf = (pc: number, mode: 'major' | 'minor') => `${(mode === 'major' ? CAMELOT_MAJOR : CAMELOT_MINOR)[pc]}${mode === 'major' ? 'B' : 'A'}`;
/** Krumhansl–Schmuckler: the key whose profile correlates best with the chroma. */
export function keyOf(chroma: ArrayLike<number>): Key | null {
  let tot = 0; for (let i = 0; i < 12; i++) tot += chroma[i]!;
  if (!(tot > 0)) return null;
  const all: { pc: number; mode: 'major' | 'minor'; r: number }[] = [];
  for (let pc = 0; pc < 12; pc++) for (const mode of ['major', 'minor'] as const) {
    const prof = mode === 'major' ? KS_MAJOR : KS_MINOR, rot = Array.from({ length: 12 }, (_, i) => prof[(i - pc + 12) % 12]!);
    all.push({ pc, mode, r: pearson(chroma, rot) });
  }
  all.sort((a, b) => b.r - a.r);
  const [b, s] = [all[0]!, all[1]!];
  const relPc = b.mode === 'major' ? (b.pc + 9) % 12 : (b.pc + 3) % 12, relMode = b.mode === 'major' ? 'minor' : 'major';
  const num = (b.mode === 'major' ? CAMELOT_MAJOR : CAMELOT_MINOR)[b.pc]!, L = b.mode === 'major' ? 'B' : 'A';
  // Confidence: how well it fits (r) and how clearly it beats the next key (a relative major/minor runner-up is normal).
  const conf = Math.max(0, Math.min(1, b.r * 0.6 + Math.min(1, (b.r - s.r) * 8) * 0.4));
  return { name: keyName(b.pc, b.mode), tonic: PITCHES[b.pc]!, mode: b.mode, confidence: r2(conf), camelot: `${num}${L}`, relative: keyName(relPc, relMode),
    runnerUp: { name: keyName(s.pc, s.mode), r: r2(s.r) },
    mixesWith: [`${num}${L === 'A' ? 'B' : 'A'}`, `${(num % 12) + 1}${L}`, `${((num + 10) % 12) + 1}${L}`] };
}

// ---- filters --------------------------------------------------------------------------------------------------------
function biquad(x: Float32Array, sr: number, f0: number, kind: 'low' | 'high'): Float32Array {
  const w = (2 * Math.PI * f0) / sr, cw = Math.cos(w), al = Math.sin(w) / (2 * Math.SQRT1_2);
  const b0 = kind === 'low' ? (1 - cw) / 2 : (1 + cw) / 2, b1 = kind === 'low' ? 1 - cw : -(1 + cw), b2 = b0, a0 = 1 + al, a1 = -2 * cw, a2 = 1 - al;
  const y = new Float32Array(x.length);
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (let i = 0; i < x.length; i++) { const v = (b0 * x[i]! + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0; x2 = x1; x1 = x[i]!; y2 = y1; y1 = v; y[i] = v; }
  return y;
}

// ---- onsets ---------------------------------------------------------------------------------------------------------
export type Band = 'low' | 'mid' | 'high';
export type Onset = { t: number; strength: number; band: Band; pitch: string };
const ONSET_N = 512, ONSET_HOP = 110; // ~46 ms window, ~10 ms hop at 11025 Hz
const BAND_HZ = { low: [20, 200], mid: [200, 2000], high: [2000, 5500] } as const;

/** Every note hit: log-magnitude spectral flux per band, adaptive threshold, peaks ≥ 50 ms apart, each refined to the
 * sample where its band's energy rises, with the dominant pitch class of the next ~0.19 s. Times in seconds from 0. */
export function noteOnsets(x: Float32Array, sr: number): Onset[] {
  const N = ONSET_N, hop = ONSET_HOP, nf = Math.floor((x.length - N) / hop) + 1;
  if (nf < 8) return [];
  const bins = (b: Band) => [Math.max(1, Math.round((BAND_HZ[b][0] * N) / sr)), Math.min(N / 2, Math.round((BAND_HZ[b][1] * N) / sr))] as const;
  const B = { low: bins('low'), mid: bins('mid'), high: bins('high') };
  const flux = { low: new Float64Array(nf), mid: new Float64Array(nf), high: new Float64Array(nf) };
  const rms = new Float64Array(nf);
  let prev = new Float64Array(N / 2 + 1), cur = new Float64Array(N / 2 + 1);
  for (let i = 0; i < nf; i++) {
    magnitudes(x, i * hop, N, cur);
    for (let k = 0; k <= N / 2; k++) cur[k] = Math.log1p(100 * cur[k]!);
    let e = 0; for (let k = i * hop; k < i * hop + N; k++) e += x[k]! * x[k]!; rms[i] = e / N;
    if (i) for (const b of ['low', 'mid', 'high'] as const) { let s = 0; for (let k = B[b][0]; k <= B[b][1]; k++) { const d = cur[k]! - prev[k]!; if (d > 0) s += d; } flux[b][i] = s; }
    const t = prev; prev = cur; cur = t;
  }
  // Each band scaled by its own 98th percentile so a quiet hi-hat counts next to a loud bass.
  const pct = (a: Float64Array, q: number) => { const s = Float64Array.from(a).sort(); return s[Math.min(s.length - 1, Math.floor(q * s.length))]!; };
  const norm = { low: Math.max(1e-6, pct(flux.low, 0.98)), mid: Math.max(1e-6, pct(flux.mid, 0.98)), high: Math.max(1e-6, pct(flux.high, 0.98)) };
  const nov = new Float64Array(nf);
  for (let i = 0; i < nf; i++) nov[i] = flux.low[i]! / norm.low + flux.mid[i]! / norm.mid + flux.high[i]! / norm.high;
  // Loudness floor: nothing 45 dB below the loudest frame (or quieter than −70 dBFS) counts.
  let loud = 0; for (let i = 0; i < nf; i++) loud = Math.max(loud, rms[i]!);
  const floor = Math.max(1e-7, loud * 10 ** (-45 / 10));
  // Adaptive threshold: the local median (±0.2 s) plus a share of the local mean and of the global spread.
  const R = Math.round(0.2 * sr / hop), p90 = pct(nov, 0.9), gap = Math.round(0.05 * sr / hop), near = 3;
  const cands: { i: number; v: number }[] = [];
  const buf: number[] = [];
  for (let i = 1; i < nf - 1; i++) {
    const v = nov[i]!;
    if (v <= 0 || rms[Math.min(nf - 1, i + 1)]! < floor) continue;
    let peak = true; for (let k = Math.max(0, i - near); k <= Math.min(nf - 1, i + near); k++) if (nov[k]! > v || (nov[k] === v && k < i)) { peak = false; break; }
    if (!peak) continue;
    buf.length = 0; let mean = 0;
    for (let k = Math.max(0, i - R); k <= Math.min(nf - 1, i + R); k++) { buf.push(nov[k]!); mean += nov[k]!; }
    mean /= buf.length; buf.sort((a, b) => a - b);
    const thr = buf[buf.length >> 1]! + 0.3 * mean + 0.12 * p90;
    if (v > thr) cands.push({ i, v });
  }
  const kept: { i: number; v: number }[] = [];
  for (const c of cands) { const last = kept.at(-1); if (last && c.i - last.i < gap) { if (c.v > last.v) kept[kept.length - 1] = c; } else kept.push(c); }
  if (!kept.length) return [];
  const filtered: Record<Band, Float32Array | null> = { low: null, mid: null, high: null };
  const bandSig = (b: Band) => filtered[b] ??= b === 'low' ? biquad(x, sr, 200, 'low') : b === 'mid' ? biquad(biquad(x, sr, 2000, 'low'), sr, 200, 'high') : biquad(x, sr, 2000, 'high');
  const out: Onset[] = [];
  const pm = new Float64Array(2048 / 2 + 1);
  for (const k of kept) {
    const fb = (['low', 'mid', 'high'] as const).map(b => ({ b, v: flux[b][k.i]! / norm[b] })).sort((a, z) => z.v - a.v)[0]!.b;
    const y = bandSig(fb), t = refine(y, sr, k.i * hop, N);
    // A note hit raises its band's energy: the 30 ms after it must be ≥ 1.5 dB above the 30 ms before (a decay, a fade
    // or a codec artefact in a tail flickers the spectrum without that).
    const at = Math.round(t * sr), w30 = Math.round(0.03 * sr);
    const pow = (a: number, b: number) => { let e = 0, c = 0; for (let q = Math.max(0, a); q < Math.min(y.length, b); q++) { e += y[q]! * y[q]!; c++; } return c ? e / c : 0; };
    if (pow(at, at + w30) < 1.4 * pow(at - w30, at) + 1e-12) continue;
    if (rms[Math.min(nf - 1, k.i + 1)]! < loud * 10 ** (-40 / 10)) continue;
    // The dominant pitch class just after the hit (~0.19 s from 10 ms in).
    magnitudes(x, Math.round(t * sr + 0.01 * sr), 2048, pm);
    const ch = chromaOf(pm, 2048, sr, fb === 'low' ? 30 : 55, 2000);
    let pc = 0; for (let q = 1; q < 12; q++) if (ch[q]! > ch[pc]!) pc = q;
    out.push({ t: r3(t), strength: k.v, band: fb, pitch: ch[pc]! > 0 ? PITCHES[pc]! : '?' });
  }
  const top = Math.max(1e-12, ...out.map(o => o.strength));
  for (const o of out) o.strength = r2(o.strength / top);
  return out;
}
/** The onset time inside frame [start, start + N): on a 3 ms energy envelope of the band signal, the first sample that
 * rises a fifth of the way from the quiet before to the peak after. */
function refine(y: Float32Array, sr: number, start: number, N: number): number {
  const a = Math.max(0, start - Math.round(N * 0.25)), b = Math.min(y.length - 1, start + N + Math.round(0.02 * sr)), w = Math.max(4, Math.round(0.003 * sr));
  const env = new Float64Array(b - a + 1);
  let s = 0;
  for (let i = a - w; i <= b; i++) { if (i >= 0) s += y[i]! * y[i]!; if (i - w >= 0) s -= y[i - w]! * y[i - w]!; if (i >= a) env[i - a] = Math.max(0, s) / w; }
  // the biggest rise over 10 ms decides which peak is the hit
  const d = Math.round(0.01 * sr);
  let best = 0, bi = -1;
  for (let i = d; i < env.length; i++) { const r = Math.log(1e-12 + env[i]!) - Math.log(1e-12 + env[i - d]!); if (r > best) { best = r; bi = i; } }
  if (bi < 0) return (start + N / 2) / sr;
  let lo = bi - d; for (let i = bi - d; i < bi; i++) if (env[i]! < env[lo]!) lo = i;
  let hi = bi; for (let i = bi; i < Math.min(env.length, bi + d); i++) if (env[i]! > env[hi]!) hi = i;
  const cut = env[lo]! + 0.2 * (env[hi]! - env[lo]!);
  let at = lo; while (at < hi && env[at]! < cut) at++;
  return (a + at - w / 2) / sr; // the envelope trails by its own half width
}

// ---- chroma frames, energy, sections ------------------------------------------------------------------------------
const CH_N = 4096, CH_HOP = 2048;
export type Frames = { hopSec: number; /** a frame's centre is offsetSec after its start */ offsetSec: number; chroma: Float64Array[]; bands: Float64Array[] /* low, mid, high power */ };
/** Chroma and band power every ~0.19 s (4096-point frames at 11025 Hz: ~2.7 Hz bins, fine enough for low notes). */
export function chromaFrames(x: Float32Array, sr: number): Frames {
  const n = Math.max(0, Math.floor((x.length - CH_N) / CH_HOP) + 1), mag = new Float64Array(CH_N / 2 + 1);
  const chroma: Float64Array[] = [], bands: Float64Array[] = [];
  const bin = (f: number) => Math.round((f * CH_N) / sr);
  for (let i = 0; i < n; i++) {
    magnitudes(x, i * CH_HOP, CH_N, mag);
    const c = new Float64Array(12);
    const k0 = bin(55), k1 = Math.min(mag.length - 1, bin(2000));
    for (let k = k0; k <= k1; k++) c[pcOf((k * sr) / CH_N)]! += mag[k]! * mag[k]!;
    chroma.push(c);
    const bp = new Float64Array(3);
    for (let k = 1; k < mag.length; k++) { const f = (k * sr) / CH_N, p = mag[k]! * mag[k]!; bp[f < 200 ? 0 : f < 2000 ? 1 : 2]! += p; }
    bands.push(bp);
  }
  return { hopSec: CH_HOP / sr, offsetSec: CH_N / 2 / sr, chroma, bands };
}
/** The song's overall pitch-class profile: each frame's chroma normalised (sqrt-compressed) so quiet passages count. */
export function songChroma(f: Frames): Float64Array {
  const s = new Float64Array(12);
  for (const c of f.chroma) { let t = 0; for (let i = 0; i < 12; i++) t += c[i]!; if (t <= 0) continue; for (let i = 0; i < 12; i++) s[i]! += Math.sqrt(c[i]! / t); }
  return s;
}
/** RMS level in dBFS every stepSec (rounded to whole dB). */
export function energyCurve(x: Float32Array, sr: number, stepSec = 0.25): number[] {
  const h = Math.max(1, Math.round(stepSec * sr)), out: number[] = [];
  for (let i = 0; i < x.length; i += h) { let e = 0; const end = Math.min(x.length, i + h); for (let k = i; k < end; k++) e += x[k]! * x[k]!; out.push(Math.max(-90, Math.round(10 * Math.log10(1e-12 + e / (end - i))))); }
  return out;
}

export type Section = { name: string; label: string; fromSec: number; toSec: number; repeats: number; energy: 'low' | 'mid' | 'high'; /** dB below the loudest section (0 = loudest) */ levelDb: number; guess: string | null };
/**
 * Sections: blocks of ≥ 0.5 s described by their chroma (unit length) and band levels; a self-similarity matrix of
 * them; Foote novelty (a checkerboard kernel ~4 s each side) whose peaks are boundaries (≥ 3 s apart); sections that
 * sound alike share a letter. Names stay honest: "section B (repeats 3×)", with a hedged guess ("chorus?").
 */
export function sections(f: Frames, durationSec: number): Section[] {
  if (!f.chroma.length) return [];
  const blockSec = Math.max(0.5, durationSec / 400), per = Math.max(1, Math.round(blockSec / f.hopSec)), nb = Math.ceil(f.chroma.length / per);
  const bs = per * f.hopSec;
  const feats: { c: Float64Array; e: Float64Array; db: number }[] = [];
  for (let b = 0; b < nb; b++) {
    const c = new Float64Array(12), e = new Float64Array(3);
    let cnt = 0;
    for (let i = b * per; i < Math.min(f.chroma.length, (b + 1) * per); i++, cnt++) { for (let q = 0; q < 12; q++) c[q]! += f.chroma[i]![q]!; for (let q = 0; q < 3; q++) e[q]! += f.bands[i]![q]!; }
    let len = 0; for (let q = 0; q < 12; q++) { c[q] = Math.sqrt(c[q]!); len += c[q]! ** 2; } len = Math.sqrt(len) || 1;
    for (let q = 0; q < 12; q++) c[q]! /= len;
    const tot = e[0]! + e[1]! + e[2]!;
    for (let q = 0; q < 3; q++) e[q] = 10 * Math.log10(1e-12 + e[q]! / Math.max(1, cnt));
    feats.push({ c, e, db: 10 * Math.log10(1e-12 + tot / Math.max(1, cnt)) });
  }
  const sim = (a: { c: Float64Array; e: Float64Array }, b: { c: Float64Array; e: Float64Array }) => {
    let dot = 0; for (let q = 0; q < 12; q++) dot += a.c[q]! * b.c[q]!;
    let de = 0; for (let q = 0; q < 3; q++) de += Math.abs(a.e[q]! - b.e[q]!);
    return 0.6 * dot + 0.4 * Math.exp(-de / 3 / 6);
  };
  const L = Math.max(2, Math.round(4 / bs));
  const nov = new Float64Array(nb);
  for (let i = 0; i < nb; i++) {
    let s = 0, w = 0;
    for (let a = -L; a < L; a++) for (let b = -L; b < L; b++) {
      const ia = i + a, ib = i + b;
      if (ia < 0 || ib < 0 || ia >= nb || ib >= nb) continue;
      const sign = (a < 0) === (b < 0) ? 1 : -1, g = Math.exp(-((a + 0.5) ** 2 + (b + 0.5) ** 2) / (2 * (L / 2) ** 2));
      s += sign * g * sim(feats[ia]!, feats[ib]!); w += g;
    }
    nov[i] = w ? s / w : 0;
  }
  let mean = 0; for (const v of nov) mean += v; mean /= nb;
  let sd = 0; for (const v of nov) sd += (v - mean) ** 2; sd = Math.sqrt(sd / nb);
  const minGap = Math.max(1, Math.round(3 / bs));
  const peaks: { i: number; v: number }[] = [];
  for (let i = 1; i < nb - 1; i++) {
    const v = nov[i]!;
    if (v < mean + 0.5 * sd || v < 0.02) continue;
    let pk = true; for (let k = Math.max(0, i - L); k <= Math.min(nb - 1, i + L); k++) if (nov[k]! > v) { pk = false; break; }
    if (pk && i >= minGap && nb - i >= Math.max(1, Math.round(1.5 / bs))) peaks.push({ i, v });
  }
  const bounds = [0];
  for (const p of peaks.sort((a, b) => a.i - b.i)) if (p.i - bounds.at(-1)! >= minGap) bounds.push(p.i);
  bounds.push(nb);
  // Mean features per section, then letters by likeness.
  const secs = bounds.slice(0, -1).map((b0, k) => {
    const b1 = bounds[k + 1]!, c = new Float64Array(12), e = new Float64Array(3);
    let db = 0;
    for (let i = b0; i < b1; i++) { for (let q = 0; q < 12; q++) c[q]! += feats[i]!.c[q]!; for (let q = 0; q < 3; q++) e[q]! += feats[i]!.e[q]!; db += 10 ** (feats[i]!.db / 10); }
    let len = 0; for (let q = 0; q < 12; q++) len += c[q]! ** 2; len = Math.sqrt(len) || 1;
    for (let q = 0; q < 12; q++) c[q]! /= len;
    for (let q = 0; q < 3; q++) e[q]! /= b1 - b0;
    return { from: b0 ? b0 * bs + f.offsetSec : 0, to: b1 === nb ? durationSec : Math.min(durationSec, b1 * bs + f.offsetSec), c, e, db: 10 * Math.log10(1e-12 + db / (b1 - b0)), label: '' };
  });
  const letters: { c: Float64Array; e: Float64Array; label: string }[] = [];
  for (const s of secs) {
    const same = letters.map(l => ({ l, v: sim(l, s) })).sort((a, b) => b.v - a.v)[0];
    if (same && same.v >= 0.9) s.label = same.l.label;
    else { s.label = String.fromCharCode(65 + Math.min(25, letters.length)); letters.push({ c: s.c, e: s.e, label: s.label }); }
  }
  const dbs = secs.map(s => s.db), maxDb = Math.max(...dbs), minDb = Math.min(...dbs);
  const level = (db: number): Section['energy'] => (maxDb - minDb < 3 ? 'mid' : db >= maxDb - (maxDb - minDb) / 3 ? 'high' : db <= minDb + (maxDb - minDb) / 3 ? 'low' : 'mid');
  const count = (l: string) => secs.filter(s => s.label === l).length;
  const most = [...new Set(secs.map(s => s.label))].sort((a, b) => count(b) - count(a) || secs.find(s => s.label === b)!.db - secs.find(s => s.label === a)!.db)[0];
  return secs.map((s, k) => {
    const energy = level(s.db), reps = count(s.label);
    const prevBass = k ? secs[k - 1]!.e[0]! : -Infinity;
    const guess = secs.length < 2 ? null
      : k === 0 && energy !== 'high' ? 'intro?'
      : k === secs.length - 1 && energy === 'low' ? 'outro?'
      : energy === 'high' && s.e[0]! - prevBass >= 6 ? 'drop?'
      : energy === 'high' && s.label === most && reps > 1 ? 'chorus?'
      : energy !== 'high' && reps > 1 ? 'verse?' : null;
    return { name: `section ${s.label}${reps > 1 ? ` (repeats ${reps}×)` : ''}`, label: s.label, fromSec: r2(s.from), toSec: r2(s.to), repeats: reps, energy, levelDb: Math.round(s.db - maxDb), guess };
  });
}

const r2 = (v: number) => Math.round(v * 100) / 100, r3 = (v: number) => Math.round(v * 1000) / 1000;
