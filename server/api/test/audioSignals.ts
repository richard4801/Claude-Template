// Generated test audio for talking detection: speech-like, music, music with a singer, silence. Deterministic.
import fs from 'node:fs';
export const RATE = 16000;

function rng(seed: number) { let a = seed >>> 0; return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }

/** A vowel: harmonics of f0 shaped by two formants. */
function vowel(out: Float32Array, at: number, len: number, f0: number, f1: number, f2: number, amp: number) {
  for (let i = 0; i < len && at + i < out.length; i++) {
    const t = i / RATE, env = Math.sin(Math.PI * i / len) ** 0.6;
    let v = 0;
    for (let h = 1; h * f0 < 4000; h++) {
      const f = h * f0, g = Math.exp(-(((f - f1) / 150) ** 2)) + 0.6 * Math.exp(-(((f - f2) / 200) ** 2)) + 0.05;
      v += g * Math.sin(2 * Math.PI * f * t) / h ** 0.5;
    }
    out[at + i]! += amp * env * v * 0.15;
  }
}
function noise(out: Float32Array, at: number, len: number, amp: number, r: () => number) {
  for (let i = 0; i < len && at + i < out.length; i++) out[at + i]! += amp * (r() * 2 - 1) * Math.sin(Math.PI * i / len);
}

/** Syllables at ~4–5 a second with consonant bursts, short gaps and phrase pauses. */
export function speechLike(seconds: number, seed = 1, f0Base = 140) {
  const r = rng(seed), out = new Float32Array(seconds * RATE);
  let at = Math.floor(0.2 * RATE), inPhrase = 0;
  const vowels = [[700, 1200], [400, 2000], [300, 2300], [500, 900], [600, 1700]];
  while (at < out.length) {
    if (r() < 0.6) { const c = Math.floor((0.03 + r() * 0.05) * RATE); noise(out, at, c, 0.08, r); at += c; }
    const len = Math.floor((0.12 + r() * 0.12) * RATE), [f1, f2] = vowels[Math.floor(r() * vowels.length)]!;
    vowel(out, at, len, f0Base * (0.85 + r() * 0.35), f1!, f2!, 0.7 + r() * 0.3);
    at += len + Math.floor((0.03 + r() * 0.08) * RATE);
    if (++inPhrase > 6 + r() * 6) { inPhrase = 0; at += Math.floor((0.3 + r() * 0.4) * RATE); }
  }
  return out;
}

/** Sustained chords that change every 2 s, a kick on every beat and an off-beat hi-hat at 120 bpm. */
export function musicLike(seconds: number, seed = 2, withVocal = false) {
  const r = rng(seed), out = new Float32Array(seconds * RATE);
  const chords = [[220, 277.2, 329.6], [196, 246.9, 293.7], [174.6, 220, 261.6], [196, 246.9, 311.1]];
  for (let i = 0; i < out.length; i++) {
    const t = i / RATE, ch = chords[Math.floor(t / 2) % chords.length]!;
    let v = 0;
    for (const f of ch) v += Math.sin(2 * Math.PI * f * t) + 0.3 * Math.sin(4 * Math.PI * f * t);
    out[i] = 0.08 * v;
    const beat = t % 0.5;
    out[i]! += 0.5 * Math.exp(-beat * 25) * Math.sin(2 * Math.PI * (60 + 60 * Math.exp(-beat * 30)) * beat);
    const off = (t + 0.25) % 0.5;
    if (off < 0.05) out[i]! += 0.05 * (r() * 2 - 1) * Math.exp(-off * 60);
  }
  if (withVocal) { const v = speechLike(seconds, seed + 7, 220); for (let i = 0; i < out.length; i++) out[i]! += 0.5 * v[i]!; }
  return out;
}

export const silence = (seconds: number, seed = 3) => { const r = rng(seed), out = new Float32Array(seconds * RATE); for (let i = 0; i < out.length; i++) out[i] = 0.0005 * (r() * 2 - 1); return out; };

/** 16-bit mono WAV. */
export function writeWav(file: string, s: Float32Array) {
  const b = Buffer.alloc(44 + s.length * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + s.length * 2, 4); b.write('WAVE', 8); b.write('fmt ', 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(RATE, 24); b.writeUInt32LE(RATE * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(s.length * 2, 40);
  for (let i = 0; i < s.length; i++) b.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(s[i]! * 32767))), 44 + i * 2);
  fs.writeFileSync(file, b);
}
