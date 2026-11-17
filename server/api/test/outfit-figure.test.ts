// Outfit sets keep her figure from every angle (owner 2026-11-16: "Seedream tends to reduce the size of her bum. The idea
// is to always keep her shape, from every angle"), and an outfit made from a reference photo keeps its own words (a new
// hairstyle, piercing) in outfit-set prompts, shoots and templates.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import * as E from '../src/prompt/engine.js';
import { DEFAULT_TEXTS } from '../src/prompt/library.js';
import * as B from '../src/prompt/scripts/builders.js';
import { scriptDef } from '../src/prompt/scripts/defs.js';
import { resolveRules, validateRules } from '../src/prompt/scripts/run.js';
import { buildTemplatePrompt } from '../src/templates/prompt.js';
import { modelChoice } from '../src/engines/service.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

const demo: E.Identity = { name: 'Demo model', look: 'young woman, dark hair', neverAdd: ['tattoos'], referenceCount: 3 };
const FIGURE = (body: string) => DEFAULT_TEXTS['outfit.figure']!.replace('{body}', body);
const WORDS = 'platinum blonde high ponytail, small silver nose stud';

describe('the figure line', () => {
  it('every angle of an outfit set has it, after the task, naming the image that shows her figure', () => {
    const set = E.outfitSet(demo, { name: 'Green set' }, 7, DEFAULT_TEXTS, ['her front body photo (image 3)', 'her three-quarter body photo (image 3)']);
    expect(set.map(p => p.text.split('\n').find(l => l.startsWith('Figure:')))).toEqual([
      FIGURE('her front body photo (image 3)'), FIGURE('her three-quarter body photo (image 3)'), FIGURE('her body photos'), FIGURE('her body photos')]);
    for (const p of set) expect(p.text).toMatch(/^Task: .*\nFigure: /m);
    expect(DEFAULT_TEXTS['outfit.figure']).toMatch(/bust, waist, hips and buttocks/);
    expect(DEFAULT_TEXTS['outfit.figure']).toMatch(/never slim, flatten or reshape her body/);
  });
  it('the edits of the front (¾, side, back) and the pieces kept from her base end with it', () => {
    expect(E.outfitEditPrompt(E.OUTFIT_ANGLES[2], DEFAULT_TEXTS, 'the last image', 'NOTE.')).toBe(
      `${DEFAULT_TEXTS['outfit.edit']!.replace('{angle}', 'full body side view')} NOTE.\n${FIGURE('the last image')}\n${DEFAULT_TEXTS['sheet.realism']}`);
    const keep = { keep: { top: true } };
    expect(E.outfitKeepFront(keep, 'a red skirt')).toMatch(new RegExp(`\\n${FIGURE('the first image').replace(/[().]/g, '\\$&')}$`));
    // The face close-ups are face only: they never carry a body line.
    expect(E.outfitFacePrompt(0)).not.toMatch(/Figure:|buttocks/);
  });
  it('is locked: not optional (Presets off keeps it), can\'t be switched off; an older saved rule list gets it added', () => {
    for (const id of ['outfit.angle', 'outfit.edit']) {
      const s = scriptDef(id)!;
      const fig = s.rules.find(r => r.id === 'figure')!;
      expect(fig).toMatchObject({ locked: true, block: 'outfit.figure' });
      expect(fig.optional).toBeFalsy();
      expect(validateRules(s, s.rules.map(r => (r.id === 'figure' ? { ...r, enabled: false } : r)))).toMatch(/locked/);
      // A list saved before the figure existed keeps the owner's edits and gains the figure.
      const old = s.rules.filter(r => r.id !== 'figure').map(r => (r.id === 'prompt' || r.id === 'task' ? { ...r, label: 'Mine' } : r));
      const res = resolveRules(s, { rules: old, knownDefaults: old.map(r => r.id) });
      expect(res.stale).toBe(false);
      expect(res.rules.some(r => r.label === 'Mine')).toBe(true);
      expect(res.rules.some(r => r.id === 'figure')).toBe(true);
    }
  });
});

describe("a photo-made outfit's own words", () => {
  it('outfit-set prompts carry them on the outfit line, every angle (so the front, and its face close-ups, show the new hair)', () => {
    const set = E.outfitSet(demo, { name: 'Street set', source: 'product-photo', description: `${WORDS}.` }, 7);
    for (const p of set) expect(p.text.split('\n')[1]).toBe(`Wearing: the outfit from the product photo reference (street set). For this look also: ${WORDS}.`);
    const plain = E.outfitSet(demo, { name: 'Street set', source: 'product-photo', description: '  ' }, 7);
    for (const p of plain) expect(p.text).not.toMatch(/For this look also/);
    // A described outfit's description is its outfit line already: no second sentence.
    expect(E.outfitSet(demo, { name: 'Knit', source: 'described', description: 'a knit' }, 7)[0]!.text).not.toMatch(/For this look also/);
  });
  it('shoots and templates with that outfit (a reference set by then) carry them too; one outfit slot', () => {
    const outfit: E.OutfitSpec = { name: 'Street set', source: 'reference-set', description: WORDS, extra: WORDS };
    const p = B.photoshoot({ identity: demo, outfit, presets: false });
    expect(p.slots.filter(s => s.layer === 'outfit')).toEqual([{ layer: 'outfit', text: `Wearing: street set (outfit reference set). For this look also: ${WORDS}.` }]);
    const t = buildTemplatePrompt({ templateId: 't', templateName: 'Mirror', layers: { scene: 'mirror' }, pool: {}, identity: demo, outfit, shuffleSeed: 1 });
    expect(t.fullText).toContain(`Wearing: street set (outfit reference set). For this look also: ${WORDS}.`);
    // Without words (every other outfit): unchanged.
    expect(B.photoshoot({ identity: demo, outfit: { name: 'Street set' }, presets: false }).text).not.toMatch(/For this look also/);
  });
});

describe('outfit sets on a custom model (Seedream on Muapi): each angle sends her body photo of ITS angle and names it', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, m: { id: string };
  const calls: any[] = [];
  beforeAll(async () => {
    a = await makeApp({ BALANCE_MODE: 'simulated' });
    ({ owner } = await people(a, 0) as any);
    m = await demoModel(owner);
    vi.spyOn(modelChoice(a.ctx), 'imageOverrides').mockResolvedValue({ shot: 'c_seedream' } as any);
    vi.spyOn(a.ctx.suite.byo, 'photoCapacity').mockResolvedValue(6);
    vi.spyOn(a.ctx.suite.byo, 'photoPerShot').mockResolvedValue(0.05);
    vi.spyOn(a.ctx.images, 'generate').mockImplementation(async (o: any) => {
      calls.push(o);
      return { images: [{ asset: 'c_front' }], costUsd: 0.05, costs: [0.05], selection: { provider: 'byo', model: 'c_seedream' } } as any;
    });
  });
  afterAll(async () => { vi.restoreAllMocks(); await a?.close(); });

  const make = async (body: Record<string, unknown>) => {
    calls.length = 0;
    const o = (await owner.req('POST', '/v1/outfits', { modelId: m.id, ...body })).body;
    await until(async () => (await owner.req('GET', '/v1/outfits')).body.find((x: any) => x.id === o.id && x.state === 'preview'), 15_000);
    return calls.filter(c => !c.editOf && !/face close-up/.test(c.req.prompt));
  };

  it('front→front, ¾→tq, side→side, back→back, each named in its prompt', async () => {
    const shots = await make({ mode: 'describe', description: 'a red bikini' });
    expect(shots).toHaveLength(4);
    const words = ['front', 'three-quarter', 'side', 'back'];
    shots.forEach((c, i) => {
      const k = c.refs.findIndex((r: any) => r.asset === ['g_front', 'g_tq', 'g_side', 'g_back'][i]);
      expect(k, words[i]).toBeGreaterThanOrEqual(0);
      // Her other body photos aren't sent for this angle.
      expect(c.refs.filter((r: any) => /^g_/.test(r.asset ?? ''))).toHaveLength(1);
      expect(c.req.prompt).toContain(FIGURE(`her ${words[i]} body photo (image ${k + 1})`));
      expect(c.req.prompt).toContain(`full body ${words[i] === 'three-quarter' ? 'three-quarter' : words[i]} view`);
    });
  });

  it('a chosen image list (the same for every angle) gets each angle\'s own body photo in place of the front one', async () => {
    const list = [{ image: { asset: 'face' }, role: 'person', label: 'face' }, { image: { asset: 'g_front' }, role: 'person', label: 'body' }];
    const shots = await make({ mode: 'describe', description: 'a red bikini', sentImages: list });
    expect(shots.map(c => c.refs.map((r: any) => r.asset))).toEqual([['face', 'g_front'], ['face', 'g_tq'], ['face', 'g_side'], ['face', 'g_back']]);
    expect(shots[3]!.req.prompt).toContain(FIGURE('her back body photo (image 2)'));
  });

  it('made from a reference photo with words: every angle carries them (the front too, so its face close-ups copy the hair)', async () => {
    const shots = await make({ mode: 'photo', description: WORDS, images: [{ asset: 'c_front' }] });
    expect(shots).toHaveLength(4);
    for (const c of shots) expect(c.req.prompt).toContain(`For this look also: ${WORDS}.`);
  });
});
