// The beat detector on click tracks (workstream 1, for workstream 3's detectBeats): the tempo, not half or double it.
import { describe, expect, it } from 'vitest';
import { BEAT_SR, detectBeats } from '../src/editor/audio.js';
import { musicLike, RATE } from './audioSignals.js';

/** Short decaying clicks at `bpm` for `sec` seconds, optionally with quieter off-beats; deterministic. */
function clicks(bpm: number, sec = 12, o: { accentEvery?: number; offbeat?: number; start?: number } = {}) {
  const x = new Float32Array(Math.round(sec * BEAT_SR)), period = 60 / bpm;
  const click = (t: number, amp: number) => {
    const at = Math.round(t * BEAT_SR);
    for (let i = 0; i < 400 && at + i < x.length; i++) x[at + i]! += amp * Math.exp(-i / 60) * Math.sin(2 * Math.PI * 1500 * i / BEAT_SR);
  };
  for (let k = 0, t = o.start ?? 0.25; t < sec - 0.05; k++, t += period) {
    click(t, o.accentEvery && k % o.accentEvery === 0 ? 0.9 : 0.6);
    if (o.offbeat) click(t + period / 2, o.offbeat);
  }
  return x;
}

describe('detectBeats · tempo on click tracks', () => {
  for (const bpm of [90, 120, 128, 140, 174]) {
    it(`${bpm} bpm: the tempo itself (not half or double), a beat on each click`, () => {
      const r = detectBeats(clicks(bpm, 12, { accentEvery: 4 }));
      expect(Math.abs(r.bpm - bpm)).toBeLessThan(1.5);
      const period = 60 / bpm;
      expect(r.beats.length).toBeGreaterThanOrEqual(Math.floor((12 - 0.5) / period) - 1);
      // Each beat sits on a click (within 40 ms).
      for (const b of r.beats) expect(Math.abs(((b - 0.25) / period) - Math.round((b - 0.25) / period)) * period).toBeLessThan(0.04);
      // The accented click starts the bar.
      expect(Math.abs(((r.strong[0]! - 0.25) / period) % 4)).toBeLessThan(0.1);
    });
  }
  it('quiet off-beats do not double a mid tempo past 180; a slow pulse with strong off-beats reads as its double', () => {
    expect(Math.abs(detectBeats(clicks(120, 12, { offbeat: 0.25 })).bpm - 120)).toBeLessThan(1.5);
    expect(Math.abs(detectBeats(clicks(70, 12, { offbeat: 0.55 })).bpm - 140)).toBeLessThan(1.5);
  });
  it('the edges of the range and plain pulses stay as they are (60, 100, 160, 180 bpm)', () => {
    for (const bpm of [60, 100, 160, 180]) expect(Math.abs(detectBeats(clicks(bpm)).bpm - bpm)).toBeLessThan(1.5);
  });
  it('music with a kick on the beat and an off-beat hi-hat at 120 bpm reads as 120', () => {
    const m = musicLike(12), x = new Float32Array(Math.floor(m.length * BEAT_SR / RATE));
    for (let i = 0; i < x.length; i++) x[i] = m[Math.floor(i * RATE / BEAT_SR)]!;
    expect(Math.abs(detectBeats(x).bpm - 120)).toBeLessThan(1.5);
  });
});
