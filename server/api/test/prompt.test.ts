import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import * as P from '../src/pricing.js';
import * as E from '../src/prompt/engine.js';

const FIX = path.resolve(__dirname, '../../../android/core/src/test/resources');
const sienna: E.Identity = { name: 'Sienna Vale', look: 'young woman, long wavy honey-blonde hair with brown roots, green eyes, light freckles, tanned skin', neverAdd: ['tattoos', 'rings'] };

describe('pricing (android/core pricing_fixture.json, generated from prototype/app/app.js)', () => {
  const rows = JSON.parse(fs.readFileSync(path.join(FIX, 'pricing_fixture.json'), 'utf8'));
  it('has 216 rows and every one matches', () => {
    expect(rows.length).toBe(216);
    for (const o of rows) {
      const r = { engine: o.engine, use: o.use, steps: o.steps, lipSync: o.lip };
      expect(P.estMin(r)).toBeCloseTo(o.estMin, 9);
      expect(P.estCost(r)).toBeCloseTo(o.estCost, 9);
      expect(P.money(P.estCost(r))).toBe(o.costLabel);
      expect(P.genLabel(r)).toBe(o.genLabel);
      expect(P.stepsDelta(r)).toBe(o.stepsDelta);
      expect(P.sourceOption(o.use, o.steps)).toBe(o.sourceOption);
    }
  });
  it('fixed prices and LoRA', () => {
    expect(P.money(P.estCost({}))).toBe('$0.67');
    expect(P.genLabel({ takes: 3 })).toBe('Generate · 30 min · $2.02 · 3 takes');
    expect(P.money(P.loraTrainCost())).toBe('$6.65');
    expect(P.money(P.fillAnglesCost(3))).toBe('$0.06');
    expect(P.videosLeft(6.07)).toBe(9);
    expect(P.lengthSec({ use: 'full', clipSeconds: 22 })).toBe(15);
    expect(P.lengthSec({ use: 'first', clipSeconds: 3 })).toBe(3);
  });
});

describe('prompt engine (port of PromptEngine.kt)', () => {
  const cases = JSON.parse(fs.readFileSync(path.join(FIX, 'prompt_fixture.json'), 'utf8'));
  const outfits = ['Green set', 'Crystal dress'];
  it('photoshoot matches the prototype fixture slot for slot', () => {
    for (const c of cases) {
      const i = c.input;
      const built = E.photoshoot({ identity: sienna, outfit: { name: outfits[i.outfit] }, scene: i.scene, camera: { shot: i.shot, lensMm: i.lens, aperture: i.aperture },
        light: i.light, grade: i.grade, direction: i.direction, lockSeed: i.lockSeed ?? false });
      expect(built.text).toBe(c.text);
      for (const k of ['identity', 'outfit', 'scene', 'camera', 'light', 'direction', 'style', 'negative', 'seed'] as const) expect(E.slotText(built, k) ?? '').toBe(c.parts[k] ?? '');
    }
  });
  it('drops empty slots and strips labels', () => {
    const p = E.photoshoot({ identity: sienna, outfit: { name: 'Green set' }, direction: '   ' });
    expect(E.slotText(p, 'direction')).toBeUndefined();
    expect(p.text).not.toContain('\n\n');
    expect(E.slotBody(p.slots[0]!)).toMatch(/^young woman, long wavy/);
  });
  it('lens-aware camera wording', () => {
    const cam = (mm: number) => E.slotText(E.photoshoot({ identity: sienna, outfit: { name: 'Green set' }, camera: { shot: 'Close', lensMm: mm, aperture: 'f/1.4' } }), 'camera')!;
    expect(cam(16)).toMatch(/slight wide-angle distortion\.$/);
    expect(cam(85)).toMatch(/compressed background, creamy bokeh\.$/);
    expect(cam(50)).toBe('Camera: close shot, 50mm lens, f/1.4.');
  });
  it('direction cannot add never-add items or override identity', () => {
    expect(E.sanitizeDirection('laughing mid-step, wearing a gold ring, holding an iced coffee', sienna)).toEqual({ clean: 'laughing mid-step, holding an iced coffee', removed: ['wearing a gold ring'] });
    const p = E.photoshoot({ identity: sienna, outfit: { name: 'Green set' }, direction: 'small tattoo on her wrist, smiling' });
    expect(E.slotText(p, 'direction')).toBe('Direction: smiling');
    expect(p.removed).toEqual(['small tattoo on her wrist']);
    const r = E.sanitizeDirection('blonde hair turned platinum, blue eyes, hair blowing in the wind', sienna);
    expect(r.clean).toBe('hair blowing in the wind');
    expect(r.removed.length).toBe(2);
  });
  it('never list merges defaults without duplicates', () => {
    expect(E.neverList({ ...sienna, neverAdd: ['tattoos', 'Logos', 'chokers'] })).toEqual(['tattoos', 'Logos', 'chokers', 'extra fingers', 'warped jewellery']);
  });
  it('outfit set: one seed, four angles, no logos', () => {
    const set = E.outfitSet(sienna, { name: 'Cream knit + jeans', description: 'Cream cable-knit sweater, light-wash straight jeans, white sneakers', source: 'described' });
    expect(set.length).toBe(4);
    expect(new Set(set.map(s => s.seed)).size).toBe(1);
    expect(E.slotText(set[0]!, 'outfit')).toMatch(/^Wearing: Cream cable-knit sweater/);
    expect(E.slotText(set[3]!, 'task')).toContain('back view');
    expect(E.slotText(set[0]!, 'negative')).toContain('visible brand logos');
  });
  it('character sheet shot', () => {
    const p = E.characterSheetShot(sienna, E.sheetAngle('profile')!);
    expect(p.slots.map(s => s.layer)).toEqual(['identity', 'task', 'style', 'negative']);
    expect(E.slotText(p, 'task')).toContain('plain light-grey studio background');
    expect(E.slotText(p, 'task')).toContain('side profile');
  });
  it('H3 video swap prompt', () => {
    const v = E.videoSwap({ identity: sienna, outfit: { name: 'Green set' }, performer: { description: 'the young woman with long red hair', tattoos: true, rings: true, setting: 'a living room' } });
    expect(v.text.startsWith('subject_definitions:\n<Subject 1> is the young woman with long red hair with tattoos and rings in <Video 1>')).toBe(true);
    for (const h of ['summary:', 'retention_analysis:', 'detailed_description:']) expect(v.text).toContain(`\n\n${h}\n`);
    expect(v.text).toContain("None of <Subject 1>'s tattoos remain.");
    expect(v.text).toContain('<Audio 1>: fully_copy');
    expect(v.text).toContain('<Image 6> (body, back)');
    expect(v.steps).toBe(10);
    const w = E.videoSwap({ identity: { ...sienna, referenceCount: 3 }, outfit: { name: 'Crystal dress' }, keepAudio: false, keepBackground: false, backgroundMotion: 'subtly alive' });
    expect(w.text).not.toContain('<Audio 1> is the synchronized');
    expect(w.text).toContain('<Audio 1>: replaced');
    expect(w.text).toContain('(subtly alive)');
    expect(w.text).toContain('<Image 1>-<Image 3>');
    expect(w.audioMode).toBe('replace');
  });
  it('Lock look seed matches Kotlin (Java String.hashCode)', () => {
    const a = E.photoshoot({ identity: sienna, outfit: { name: 'Green set' }, lockSeed: true });
    expect(a.seed).toBe(E.seedFor('Sienna Vale'));
    // "Sienna Vale".hashCode() in Java = -60458670 → (& 0x7fffffff) % 1_000_000
    expect(E.seedFor('Sienna Vale')).toBe((-60458670 & 0x7fffffff) % 1_000_000);
  });
  it('LoRA tokens and layers', () => {
    expect(E.loraToken('Sienna Vale', 1)).toBe('sienna_v1');
    expect(E.loraToken('  Noor Ellis', 3)).toBe('noor_v3');
    const on = E.photoshoot({ identity: { ...sienna, lora: 'sienna_v2' }, outfit: { name: 'Green set' } });
    expect(E.slotText(on, 'identity')).toMatch(/Identity from 6 locked reference images \+ LoRA sienna_v2 \(photo\)\.$/);
    expect(E.videoSwap({ identity: { ...sienna, lora: 'sienna_v1' }, outfit: { name: 'Green set' } }).text).toContain('<Image 6> (body, back), with LoRA sienna_v1 video.\n<Video 1>');
  });
});
