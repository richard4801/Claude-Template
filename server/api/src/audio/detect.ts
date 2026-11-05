// Free "is the performer talking?" detection (plans/prompt-scripts.md §5): no paid model. ffmpeg decodes the clip's
// audio to 16 kHz mono PCM and a few classic speech/music features decide:
//   - low-energy ratio: speech has many pauses between syllables and phrases, music fills the time
//   - syllabic modulation: speech energy rises and falls 2–8 times a second (syllables), steady music doesn't
//   - zero-crossing variability: speech alternates voiced and unvoiced sounds
// Music with a singer is classed as music (most clips with music are people moving to a song, not singing it); the
// studio's "Performer is speaking" switch corrects it either way. Runs in well under a second for a 15 s clip.
import { execFile } from 'node:child_process';

export type AudioKind = 'speech' | 'music' | 'silence' | 'none';
export type TalkingResult = {
  kind: AudioKind; speaking: boolean; confidence: number;
  features?: { rmsDb: number; lowEnergy: number; modulation: number; zcrVar: number; activeRatio: number };
};

const RATE = 16000, FRAME = 400, HOP = 160; // 25 ms frames every 10 ms
const MAX_SECONDS = 30;

/** Decodes up to 30 s of the first audio stream to 16 kHz mono float samples, or null when there is none. */
export function decodeAudio(ffmpeg: string, file: string, timeoutMs = 60_000): Promise<Float32Array | null> {
  return new Promise((resolve, reject) => {
    execFile(ffmpeg, ['-v', 'error', '-i', file, '-vn', '-ac', '1', '-ar', String(RATE), '-t', String(MAX_SECONDS), '-f', 's16le', 'pipe:1'],
      { encoding: 'buffer', timeout: timeoutMs, maxBuffer: RATE * 2 * MAX_SECONDS + 1024 * 1024 }, (err, stdout, stderr) => {
        // No audio track: nothing to decode.
        if (err && /does not contain any stream|matches no streams/i.test(String(stderr ?? ''))) return resolve(null);
        if (err) return reject(new Error(`ffmpeg failed: ${String(stderr ?? '').trim().split('\n').slice(-2).join(' | ').slice(0, 300) || err.message}`));
        const buf = stdout as Buffer;
        if (!buf.length) return resolve(null);
        const n = Math.floor(buf.length / 2), out = new Float32Array(n);
        for (let i = 0; i < n; i++) out[i] = buf.readInt16LE(i * 2) / 32768;
        resolve(out);
      });
  });
}

const db = (x: number) => 20 * Math.log10(Math.max(1e-9, x));
const mean = (a: number[]) => (a.length ? a.reduce((s, x) => s + x, 0) / a.length : 0);
const variance = (a: number[]) => { const m = mean(a); return mean(a.map(x => (x - m) ** 2)); };
const pct = (a: number[], p: number) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))]! : 0; };

/** Share of the envelope's modulation energy between lo and hi Hz (the envelope is sampled at 100 Hz). */
function modulationShare(env: number[], lo: number, hi: number) {
  const fs = RATE / HOP, n = env.length;
  if (n < fs) return 0;
  const m = mean(env), x = env.map(v => v - m);
  let band = 0, total = 0;
  for (let f = 0.5; f <= 20; f += 0.25) {
    let re = 0, im = 0;
    for (let i = 0; i < n; i++) { const w = (2 * Math.PI * f * i) / fs; re += x[i]! * Math.cos(w); im -= x[i]! * Math.sin(w); }
    const p = re * re + im * im;
    total += p;
    if (f >= lo && f <= hi) band += p;
  }
  return total > 0 ? band / total : 0;
}

/** Classifies decoded samples. Exported for tests (generated speech-like, music and silence signals). */
export function classifySamples(s: Float32Array): TalkingResult {
  const rms: number[] = [], zcr: number[] = [];
  for (let start = 0; start + FRAME <= s.length; start += HOP) {
    let e = 0, z = 0;
    for (let i = start; i < start + FRAME; i++) { e += s[i]! * s[i]!; if (i > start && (s[i]! >= 0) !== (s[i - 1]! >= 0)) z++; }
    rms.push(Math.sqrt(e / FRAME)); zcr.push(z / FRAME);
  }
  if (rms.length < 50) return { kind: 'silence', speaking: false, confidence: 0.5 };
  const loud = pct(rms, 0.95);
  const rmsDb = db(loud);
  if (rmsDb < -45) return { kind: 'silence', speaking: false, confidence: 0.95, features: { rmsDb, lowEnergy: 1, modulation: 0, zcrVar: 0, activeRatio: 0 } };
  // Low-energy ratio over 1 s windows: frames under half the window's mean RMS.
  const win = 100, ler: number[] = [];
  for (let i = 0; i + win <= rms.length; i += win) { const w = rms.slice(i, i + win), m = mean(w); ler.push(w.filter(v => v < 0.5 * m).length / win); }
  const lowEnergy = mean(ler);
  // Envelope in dB relative to the loud level, floored, so quiet noise doesn't count as modulation.
  const env = rms.map(v => Math.max(-40, db(v) - rmsDb));
  const modulation = modulationShare(env, 2, 8);
  const active = rms.map((v, i) => (db(v) > rmsDb - 25 ? zcr[i]! : -1)).filter(v => v >= 0);
  const activeRatio = active.length / rms.length;
  const zcrVar = Math.sqrt(variance(active)) / Math.max(1e-6, mean(active));
  // Score: each feature votes on a 0–1 scale.
  const score = 0.6 * clamp01((lowEnergy - 0.08) / 0.22) + 0.15 * clamp01((modulation - 0.2) / 0.3) + 0.25 * clamp01((zcrVar - 0.4) / 0.5);
  const speaking = score >= 0.5;
  const features = { rmsDb: r2(rmsDb), lowEnergy: r2(lowEnergy), modulation: r2(modulation), zcrVar: r2(zcrVar), activeRatio: r2(activeRatio) };
  return { kind: speaking ? 'speech' : 'music', speaking, confidence: r2(0.5 + Math.abs(score - 0.5)), features };
}
const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
const r2 = (x: number) => Math.round(x * 100) / 100;

/** Decodes and classifies a clip's audio. A clip without an audio stream is 'none' (nothing to lip-sync to). */
export async function detectTalking(ffmpeg: string, file: string): Promise<TalkingResult> {
  const s = await decodeAudio(ffmpeg, file);
  if (!s || s.length < RATE / 2) return { kind: 'none', speaking: false, confidence: 1 };
  return classifySamples(s);
}

/**
 * Where there is sound worth keeping: ranges of `samples` (16 kHz mono) louder than 25 dB under the clip's loud level,
 * gaps under `minGapSec` bridged, ranges under `minSec` dropped. Energy-based (free): for silence cuts, not a word
 * detector (music counts as sound). The editor (workstream 3) uses it for silence-only cuts.
 */
export function soundRanges(s: Float32Array, o: { minGapSec?: number; minSec?: number; floorDb?: number } = {}): { startSec: number; endSec: number }[] {
  const minGap = o.minGapSec ?? 0.3, minLen = o.minSec ?? 0.2;
  const rms: number[] = [];
  for (let start = 0; start + FRAME <= s.length; start += HOP) {
    let e = 0;
    for (let i = start; i < start + FRAME; i++) e += s[i]! * s[i]!;
    rms.push(Math.sqrt(e / FRAME));
  }
  if (!rms.length) return [];
  const loud = db(pct(rms, 0.95));
  if (loud < -45) return [];
  const floor = o.floorDb ?? loud - 25, t = (i: number) => (i * HOP) / RATE;
  const out: { startSec: number; endSec: number }[] = [];
  let open = -1;
  rms.forEach((v, i) => {
    const on = db(v) > floor;
    if (on && open < 0) open = i;
    if (!on && open >= 0) { out.push({ startSec: t(open), endSec: t(i - 1) + FRAME / RATE }); open = -1; }
  });
  if (open >= 0) out.push({ startSec: t(open), endSec: s.length / RATE });
  const merged: typeof out = [];
  for (const r of out) { const last = merged.at(-1); if (last && r.startSec - last.endSec < minGap) last.endSec = r.endSec; else merged.push({ ...r }); }
  return merged.filter(r => r.endSec - r.startSec >= minLen).map(r => ({ startSec: Math.round(r.startSec * 1000) / 1000, endSec: Math.round(r.endSec * 1000) / 1000 }));
}
/** soundRanges for a file (decoded with ffmpeg); [] when it has no audio. */
export async function fileSoundRanges(ffmpeg: string, file: string, o?: Parameters<typeof soundRanges>[1]) {
  const s = await decodeAudio(ffmpeg, file);
  return s ? soundRanges(s, o) : [];
}
