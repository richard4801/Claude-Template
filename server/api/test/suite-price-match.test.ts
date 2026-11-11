// AI suite · the price on Generate is what is billed (owner bug 2026-11-11: Draft, 13 s, 9:16, MiniMax H3 (Higgsfield) 2K,
// six images of her, a directed guide clip → "$1.17", expected about $0.93). The three Camera-stage guide stills were sent
// as reference images 7–9, each past Higgsfield's 5 included costing $0.08. The guide clip carries the blocking, so on a
// per-image model the stills only take free slots. Pure planning: no app, no provider, no money.
import { describe, expect, it } from 'vitest';
import { buildPlan, extraPerTake, needOf, pickModel, ShotRequestSchema, type Character } from '../src/suite/plan.js';
import { billedSeconds } from '../src/suite/plan.js';
import { MODELS, modelById, type ProviderId } from '../src/suite/registry.js';

const img = (l: string) => ({ label: l, image: { asset: l } });
const MIA: Character = { name: 'Mia', look: 'young woman', neverAdd: [], images: ['face, front', 'face, profile'].map(img),
  outfit: { name: 'Look', images: ['outfit, front', 'outfit, ¾', 'outfit, side', 'outfit, back'].map(img) } } as Character;
const ALL = new Set<ProviderId>(['replicate', 'fal', 'higgsfield', 'runpod', 'mock']);
const STILLS = { start: 'https://x/s.png', middle: ['https://x/m.png'], end: 'https://x/e.png' };
const ownerShot = (o: Record<string, unknown> = {}) => ShotRequestSchema.parse({
  prompt: 'She walks to the window.', modelId: 'mia', duration: 13, quality: 'draft', aspectRatio: '9:16', takes: 1, engineModel: 'h3-hf', resolution: '2K',
  camera: { mode: 'directed', guide: { video: { key: 'guides/g.mp4', seconds: 13 }, use: 'blocking', keyframes: STILLS } }, ...o });
const planOf = (r: ReturnType<typeof ownerShot>, ch: Character | null = MIA) => {
  const p = pickModel(r.quality, needOf(r, ch), { providers: ALL, engineModel: r.engineModel, resolution: r.resolution });
  if ('error' in p) throw new Error(JSON.stringify(p));
  return buildPlan(r, needOf(r, ch), p, ch, {});
};

describe('Higgsfield H3: the shown price is the billed price', () => {
  it("the owner's shot: 13 s × $0.065 + one image past 5 × $0.08 = $0.93, the guide stills not sent", () => {
    const plan = planOf(ownerShot());
    expect(plan.images.refs.map(x => x.label)).toEqual(['face, front', 'face, profile', 'outfit, front', 'outfit, ¾', 'outfit, side', 'outfit, back']);
    expect(plan.videos).toHaveLength(1); // the guide clip carries the blocking
    expect(plan.estimate).toBeCloseTo(13 * 0.065 + 0.08, 6);
    expect(Math.round(plan.estimate * 100) / 100).toBe(0.93);
    expect(plan.notes.join(' ')).toMatch(/guide stills aren't sent on this model/);
    expect(plan.notes.join(' ')).toContain('1 reference image past the 5 included add $0.08 per take');
    expect(plan.prompt).not.toContain('<Image 7>');
  });
  it('free slots are still used: two images of her + the three stills = 5, nothing extra', () => {
    const ch = { ...MIA, outfit: null } as Character;
    const plan = planOf(ownerShot(), ch);
    expect(plan.images.refs).toHaveLength(5);
    expect(plan.extraPerTake).toBe(0);
    expect(plan.estimate).toBeCloseTo(13 * 0.065, 6);
  });
  it('takes multiply the per-image extra too', () => {
    const plan = planOf(ownerShot({ takes: 2 }));
    expect(plan.estimate).toBeCloseTo(2 * (13 * 0.065 + 0.08), 6);
  });
});

describe('every model: the estimate is what the runner settles', () => {
  // The runner settles perSec × billed seconds + extraPerTake × takes (suite/runner.ts); the estimate must be that sum.
  for (const m of MODELS.filter(x => x.status !== 'removed' && (x.modes.text || x.modes.reference || x.modes.image))) {
    for (const res of m.resolutions) {
      it(`${m.id} ${res.id}`, () => {
        const reference = m.modes.reference;
        const r = ShotRequestSchema.parse({ prompt: 'She walks to the window.', modelId: reference ? 'mia' : undefined, duration: m.duration.allowed?.[0] ?? Math.min(10, m.duration.max),
          quality: 'hd', aspectRatio: m.aspectRatios[0], takes: 2, engineModel: m.id, resolution: res.id });
        const ch = reference ? MIA : null;
        const p = pickModel('hd', needOf(r, ch), { providers: ALL, engineModel: m.id, resolution: res.id });
        if ('error' in p) return; // a model this plain shot can't run is priced by its own tests
        const plan = buildPlan(r, needOf(r, ch), p, ch, {});
        const settled = plan.perSec * billedSeconds(m, plan.seconds, { videoInput: plan.videos.length > 0 }) * plan.takes + plan.extraPerTake * plan.takes;
        expect(plan.estimate).toBeCloseTo(settled, 4);
        expect(plan.extraPerTake).toBeCloseTo(extraPerTake(modelById(m.id)!, plan.images.refs.length), 6); // only images actually sent are charged
      });
    }
  }
});
