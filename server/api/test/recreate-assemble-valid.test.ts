// workstream 1 · the owner's "Build the edit" failure (prod, 2026-11-08): applying a 29.6 s, 7-shot reference failed with
// "project.tracks.1.items.2.startSec: items on a track must be in order and not overlap" (captions on screen together
// shared one text track). Every built project must pass the editor's own validator: the owner's case as a fixture, and
// randomised recipes (fast cuts, every transition, ramps and freezes, camera moves, many overlapping captions, short
// and long takes, baked swaps, peaks) as a property test.
import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { LOOK_IDS } from '../src/editor/lookpack.js';
import { paletteIds } from '../src/editor/photo.js';
import { FILTERS } from '../src/editor/presets.js';
import type { Recipe } from '../src/recreate/analyze.js';
import { buildProject, MAX_TEXT_LANES, packText, type AssembleOptions, type TakeInfo } from '../src/recreate/assemble.js';

const base = (JSON.parse(fs.readFileSync(path.resolve(__dirname, 'fixtures/recipe-v1.json'), 'utf8')) as { recipe: Recipe }).recipe;
const valid = (p: M.EditProject) => M.validate(p, FILTERS, LOOK_IDS, paletteIds());

/** Mulberry32: the same random recipes every run. */
function rng(seed: number) { return () => { seed |= 0; seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
const r3 = (x: number) => Math.round(x * 1000) / 1000;
const KINDS = ['cut', 'flash', 'whip', 'zoom', 'fade', 'crossfade', 'glitch', 'unknown'] as const;
const MOTIONS = ['static', 'pan', 'tilt', 'zoom_in', 'zoom_out', 'shake', 'mixed'] as const;

/** A recipe of `n` shots over `dur` seconds, with everything the analysis can find, at random. */
function recipeOf(rand: () => number, o: { shots?: number; dur?: number; texts?: number } = {}): Recipe {
  const n = o.shots ?? 1 + Math.floor(rand() * 14), dur = o.dur ?? r3(1 + rand() * 59);
  const cuts = Array.from({ length: n - 1 }, () => rand()).sort().map(x => r3(x * dur));
  const bounds = [0, ...cuts, dur];
  const slots = Array.from({ length: n }, (_, i) => {
    const startSec = bounds[i]!, endSec = Math.max(bounds[i + 1]!, r3(startSec + 0.034)), d = r3(endSec - startSec);
    const ramp = (['none', 'none', 'speed_up', 'slow_down', 'freeze'] as const)[Math.floor(rand() * 5)]!;
    const curve = Array.from({ length: Math.max(1, Math.floor(d * 4)) }, (_, k) => ({ t: r3(k / 4), speed: r3(0.1 + rand() * 4) }));
    const motion = MOTIONS[Math.floor(rand() * MOTIONS.length)]!;
    const keys = Array.from({ length: 2 + Math.floor(rand() * 60) }, (_, k) => ({ t: r3(Math.min(d, k / 30)), x: r3((rand() - 0.5) * 0.6), y: r3((rand() - 0.5) * 0.6), scale: r3(0.7 + rand() * 0.8) }));
    return { ...base.slots[0]!, id: `s${i + 1}`, index: i, startSec, endSec, durationSec: d, keyframeSec: r3(startSec + d / 2),
      camera: { motion, shake: rand(), keys, confidence: 0.6 },
      speed: { ramp, curve, confidence: 0.5, ...(ramp === 'freeze' ? { freeze: { t: r3(rand() * d), durationSec: r3(rand() * d * 1.5) } } : {}) },
      peaks: rand() < 0.5 ? [{ t: r3(rand() * d), strength: rand() }] : [] };
  });
  const transitions = slots.slice(1).map((s, i) => ({ atSec: s.startSec, kind: KINDS[Math.floor(rand() * KINDS.length)]!, durationSec: r3(rand() < 0.2 ? 0 : rand() * 2.5), confidence: 0.7, from: slots[i]!.id, to: s.id }));
  // In-shot flashes and glitches (from = to).
  for (const s of slots) if (rand() < 0.2) transitions.push({ atSec: r3(s.startSec + s.durationSec / 2), kind: rand() < 0.5 ? 'flash' : 'glitch', durationSec: 0.067, confidence: 0.6, from: s.id, to: s.id });
  const text = Array.from({ length: o.texts ?? Math.floor(rand() * 25) }, (_, i) => {
    const a = r3(rand() * dur), b = r3(Math.min(dur + 1, a + rand() * 8));
    return { ...base.text[0]!, id: `x${i + 1}`, startSec: a, endSec: b, words: rand() < 0.3 ? null : `Caption ${i + 1}`, box: { x: r3(rand() * 0.5), y: r3(rand() * 0.9), w: r3(0.1 + rand() * 0.5), h: 0.07 },
      sizeFrac: r3(0.01 + rand() * 0.3), animIn: (['cut', 'fade', 'typewriter'] as const)[Math.floor(rand() * 3)]!, animOut: (['cut', 'fade'] as const)[Math.floor(rand() * 2)]!,
      animInSec: r3(rand() * 3), animOutSec: r3(rand() * 3) };
  }) as Recipe['text'];
  return { ...base, source: { ...base.source, durationSec: dur, fps: [24, 25, 30, 60][Math.floor(rand() * 4)]! }, slots, transitions, text,
    grade: { ...base.grade, look: rand() < 0.5 ? base.grade.look : null } } as Recipe;
}
const takesOf = (rand: () => number, recipe: Recipe) => Object.fromEntries(recipe.slots.map(s => [s.id, rand() < 0.15 ? undefined : {
  id: `t_${s.id}`, durationSec: r3(0.3 + rand() * 15), width: 1080, height: rand() < 0.5 ? 1920 : 1080, hasAudio: rand() < 0.5,
  peaks: rand() < 0.5 ? [{ t: r3(rand() * 10), strength: rand() }] : [] } as TakeInfo]));

describe('every built edit is a valid project', () => {
  it('the owner’s case: 29.6 s, 7 shots at 182 BPM, glitch and flash transitions, many captions on screen together', () => {
    const beat = 60 / 182;
    const starts = [0, 10.6, 13.2, 16.5, 18.5, 23.1, 26.4], dur = 29.6;
    const slots = starts.map((a, i) => { const b = starts[i + 1] ?? dur; return { ...base.slots[0]!, id: `s${i + 1}`, index: i, startSec: a, endSec: b, durationSec: r3(b - a), keyframeSec: r3((a + b) / 2) }; });
    const kinds = ['glitch', 'flash', 'whip', 'glitch', 'flash', 'zoom'] as const;
    const transitions = slots.slice(1).map((s, i) => ({ atSec: s.startSec, kind: kinds[i]!, durationSec: kinds[i] === 'flash' ? 0.067 : 0.2, confidence: 0.6, from: slots[i]!.id, to: s.id }));
    // Captions on the beat: a top line and a bottom line on screen together, and lines that start before the last goes.
    const text = Array.from({ length: 18 }, (_, i) => ({ ...base.text[0]!, id: `x${i + 1}`, startSec: r3(i * 4 * beat), endSec: r3(i * 4 * beat + (i % 3 === 0 ? 3.1 : 1.6)),
      words: `Line ${i + 1}`, box: { x: 0.1, y: i % 2 ? 0.15 : 0.75, w: 0.8, h: 0.06 } })) as Recipe['text'];
    const recipe = { ...base, source: { ...base.source, durationSec: dur, fps: 30 }, slots, transitions, text } as Recipe;
    const takes = Object.fromEntries(slots.map((s, i) => [s.id, { id: `t${i + 1}`, durationSec: [5, 10, 6.2, 8, 12, 4, 7][i]!, width: 1080, height: 1920, peaks: [{ t: 1.2, strength: 0.8 }] } as TakeInfo]));
    const out = buildProject(recipe, 't1', takes);
    expect(() => valid(out.project)).not.toThrow();
    const textTracks = out.project.tracks.filter(t => t.kind === 'text');
    expect(textTracks.length).toBeGreaterThan(1); // the overlapping lines went to their own tracks
    expect(textTracks.flatMap(t => t.items)).toHaveLength(18); // none was lost
    expect(Math.abs(out.durationSec - dur)).toBeLessThan(0.05);
  });

  it('randomised recipes (400): fast cuts, every transition, ramps, freezes, camera moves, overlapping captions, any takes and options', () => {
    const rand = rng(20261108);
    for (let k = 0; k < 400; k++) {
      const recipe = recipeOf(rand);
      const takes = takesOf(rand, recipe);
      const o: AssembleOptions = { ...(rand() < 0.2 ? { transitions: false } : {}), ...(rand() < 0.2 ? { maxTransitionSec: r3(rand()) } : {}), ...(rand() < 0.2 ? { speed: false } : {}),
        ...(rand() < 0.2 ? { camera: false } : {}), ...(rand() < 0.2 ? { peaks: false } : {}), ...(rand() < 0.1 ? { text: false } : {}), ...(rand() < 0.2 ? { look: false } : {}) };
      // Some slots filled by the reference's own swap (G2): played from the reference's own time.
      const baked = Object.fromEntries(recipe.slots.filter(s => takes[s.id] && rand() < 0.15).map(s => [s.id, { startSec: r3(Math.max(0, s.startSec - rand())) }]));
      if (Object.keys(baked).length) o.baked = baked;
      if (!recipe.slots.some(s => takes[s.id])) continue;
      const out = buildProject(recipe, 't_s1', takes, o);
      if (out.durationSec < M.LIMITS.minOutputSec) continue; // apply refuses it in plain words (tested in recreate-slots)
      try { valid(out.project); } catch (e) {
        throw new Error(`recipe #${k} (${recipe.slots.length} shots, ${recipe.text.length} texts, options ${JSON.stringify(o)}): ${(e as Error).message}`);
      }
    }
  });

  it('packText: in order, no overlaps on a track, at most MAX_TEXT_LANES tracks, a caption with no room left is shortened or left out', () => {
    const it = (id: string, a: number, d: number): M.TextItem => ({ id, startSec: a, durationSec: d, text: id, style: { font: 'sans', weight: 900, sizePct: 0.04, color: '#FFFFFF', align: 'center', maxWidthPct: 0.8 }, transform: { x: 0.5, y: 0.5 } });
    const many = Array.from({ length: 8 }, (_, i) => it(`x${i + 1}`, 0.1 * i, 5));
    const r = packText(many);
    expect(r.tracks.length).toBe(MAX_TEXT_LANES);
    for (const lane of r.tracks) for (let i = 1; i < lane.length; i++) expect(lane[i]!.startSec).toBeGreaterThanOrEqual(lane[i - 1]!.startSec + lane[i - 1]!.durationSec - 1e-6);
    expect(r.notes.length).toBe(4);
    expect(packText([it('x1', 2, 1), it('x2', 0, 1), it('x3', 1, 1)]).tracks).toHaveLength(1); // out of order, but no overlap: one track, sorted
  });
});
