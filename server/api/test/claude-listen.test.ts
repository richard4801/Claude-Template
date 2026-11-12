import { describe, expect, it } from 'vitest';
import { analyse } from '../src/claude/listen.js';
import { BEAT_SR, detectBeats } from '../src/editor/audio.js';

/** 1 s of silence, quiet kicks 1–4 s, heavy kicks + hats 4–7 s (the drop at 4 s), then 2 s of silence. */
function track(): Float32Array {
  const sr = BEAT_SR, x = new Float32Array(sr * 9);
  const kick = (at: number, amp: number) => { for (let i = 0; i < sr * 0.15; i++) { const t = i / sr, k = Math.floor(at * sr) + i; if (k < x.length) x[k]! += amp * Math.exp(-t * 30) * Math.sin(2 * Math.PI * 55 * t); } };
  for (let t = 1; t < 4; t += 0.5) kick(t, 0.08);
  for (let t = 4; t < 7; t += 0.5) kick(t, 0.9);
  for (let i = 4 * sr; i < 7 * sr; i++) x[i]! += 0.02 * Math.sin(2 * Math.PI * 5000 * (i / sr));
  return x;
}

describe('listen', () => {
  const r = analyse(track());
  it('curves every 0.1 s over the whole length', () => {
    expect(r.stepSec).toBe(0.1);
    expect(r.curves.bass.length).toBeGreaterThanOrEqual(89);
    expect(r.curves.all.length).toBe(r.curves.bass.length);
  });
  it('finds the drop at 4 s', () => {
    expect(r.drops.length).toBeGreaterThanOrEqual(1);
    expect(Math.abs(r.drops[0]!.t - 4)).toBeLessThanOrEqual(0.2);
  });
  it('finds bass hits on the kicks', () => {
    const heavy = r.bassHits.filter(h => h.t >= 3.9 && h.t < 7);
    expect(heavy.length).toBeGreaterThanOrEqual(4);
    for (const h of heavy) expect(Math.abs(((h.t - 4) / 0.5) - Math.round((h.t - 4) / 0.5)) * 0.5).toBeLessThanOrEqual(0.15);
  });
  it('marks the silent tail', () => {
    const tail = r.silent.at(-1)!;
    expect(tail.fromSec).toBeGreaterThanOrEqual(7);
    expect(tail.fromSec).toBeLessThanOrEqual(7.4);
    expect(tail.toSec).toBeCloseTo(9, 0);
  });
  it('detect_beats places no beats in the silent tail', () => {
    const b = detectBeats(track());
    expect(b.beats.every(t => t < 7.5)).toBe(true);
  });
});
