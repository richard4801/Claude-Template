// Shoot reference images and the owner prompt library (plans/api.md "Shoot references and the prompt library"), against a
// FAKE Replicate on localhost: no real predictions, no money.
import fs from 'node:fs';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { ledger } from '../src/db/schema.js';
import * as E from '../src/prompt/engine.js';
import { DEFAULT_TEXTS, fill, PROMPT_DEFS, resolveTexts, validatePrompt } from '../src/prompt/library.js';
import { dressPrompt, exampleFor, libraryDefaults } from '../src/prompt/service.js';
import { planShotImages } from '../src/images/service.js';
import { buildTemplatePrompt } from '../src/templates/prompt.js';
import { makeApp, people, demoModel, until, sse, type Client } from './helpers.js';
import { fakeReplicate, MODELS, TOKEN } from './fakeReplicate.js';

const FIX = path.resolve(__dirname, '../../../android/core/src/test/resources');
const R = (asset: string) => ({ asset });

describe('prompt library (unit)', () => {
  it('every default validates, keys are unique, and every group has entries', () => {
    expect(PROMPT_DEFS.length).toBe(53);
    expect(new Set(PROMPT_DEFS.map(p => p.key)).size).toBe(PROMPT_DEFS.length);
    for (const p of PROMPT_DEFS) expect(validatePrompt(p.key, p.default), p.key).toBeNull();
    for (const g of ['photoshoot', 'references', 'sheet', 'outfits', 'enhance', 'dressup', 'templates', 'video', 'lora']) expect(PROMPT_DEFS.some(p => p.group === g), g).toBe(true);
    for (const p of PROMPT_DEFS) expect(exampleFor(p).length, p.key).toBeGreaterThan(0);
  });
  it('validation: unknown placeholder, missing required, empty, too long; other braces are fine', () => {
    expect(validatePrompt('shoot.scene', 'Place: {where}.')).toBe('Unknown placeholder {where} · this prompt can use {scene}');
    expect(validatePrompt('style.house', 'x {name}')).toBe('Unknown placeholder {name} · this prompt has no placeholders');
    expect(validatePrompt('refs.pose', 'Copy the pose.')).toBe('Keep {refIndex} · this prompt needs it');
    expect(validatePrompt('enhance.prompt', '  ')).toBe('This prompt can’t be empty');
    expect(validatePrompt('shoot.camera.wide', '')).toBeNull();
    expect(validatePrompt('shoot.scene', 'x'.repeat(4001) + '{scene}')).toMatch(/under 4000/);
    expect(validatePrompt('shoot.scene', 'Scene { } {1} {scene}.')).toBeNull();
    expect(validatePrompt('nope', 'x')).toBe('Unknown prompt');
    expect(fill('{a}-{b}-{a}', { a: 1 })).toBe('1--1');
    // A stored override that no longer validates (or names a removed key) falls back to the default.
    expect(resolveTexts({ 'shoot.scene': 'no placeholder', gone: 'x', 'style.house': 'HOUSE' })).toMatchObject({ 'shoot.scene': DEFAULT_TEXTS['shoot.scene'], 'style.house': 'HOUSE' });
  });
  it('the server-built shoot prompt matches shoot_prompt_fixture.json (the apps check their fallback against it)', () => {
    const fx = JSON.parse(fs.readFileSync(path.join(FIX, 'shoot_prompt_fixture.json'), 'utf8'));
    for (const r of fx.rows) {
      const i = r.input;
      const p = E.photoshoot({ identity: fx.identity, outfit: { name: i.outfit }, scene: i.scene, camera: { shot: i.shot, lensMm: i.lens, aperture: i.aperture }, light: i.light, grade: i.grade,
        direction: i.direction, lockSeed: i.lockSeed, presets: i.presets, refs: i.refs });
      expect(p.text).toBe(r.text);
      expect(p.slots).toEqual(r.slots);
      expect(p.seed).toBe(r.seed);
    }
  });
  it("the app's demo copy of the library (android/app/src/main/resources/prompt_library.json) is current", () => {
    const shipped = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../../android/app/src/main/resources/prompt_library.json'), 'utf8'));
    expect(shipped).toEqual(libraryDefaults());
  });
  it('reference lines: guides in order pose, look, scene, then the guard; Presets off keeps them', () => {
    expect(E.referenceLine({ index: 7, guides: ['scene', 'pose'] })).toBe('Copy the pose and framing from image 7. Use the place and background from image 7. Do not take the face, body, hair or clothes from image 7.');
    const id = { name: 'A', look: 'b', neverAdd: [] };
    const off = E.photoshoot({ identity: id, outfit: { name: 'Set' }, presets: false, direction: 'smiling', refs: [{ index: 2, guides: ['look'] }] });
    expect(off.slots.map(s => s.layer)).toEqual(['identity', 'outfit', 'direction', 'reference', 'seed']);
    const t = { ...DEFAULT_TEXTS, 'refs.look': 'LOOK {refIndex}', 'refs.guard': '' };
    expect(E.referenceLine({ index: 3, guides: ['look'] }, t)).toBe('LOOK 3');
    const tp = buildTemplatePrompt({ templateId: 't', templateName: 'Mirror', layers: { scene: 'mirror' }, pool: {}, identity: id, outfit: null, shuffleSeed: 1, refs: [{ index: 4, guides: ['pose'] }] });
    expect(tp.visibleText).toContain('Template: Mirror\nCopy the pose and framing from image 4.');
    expect(tp.fullText).toContain('Copy the pose and framing from image 4.');
  });
  it('image plan: identity first (≤ 6), then the references, within the model limit; never drops the face front', () => {
    const id = ['face', 'profile', 'front', 'tq', 'back', 'side', 'faceTq'].map(R);
    const refs = [{ image: R('r1'), guides: ['pose' as const] }, { image: R('r2'), guides: ['look' as const] }, { image: R('r3'), guides: ['scene' as const] }];
    const p8 = planShotImages(id, refs, 6, 8);
    expect(p8.images.map(i => i.asset)).toEqual(['face', 'profile', 'front', 'tq', 'back', 'r1', 'r2', 'r3']);
    expect(p8.refs.map(r => r.index)).toEqual([6, 7, 8]);
    expect(planShotImages(id, refs.slice(0, 1), 6, 8).images.map(i => i.asset)).toEqual(['face', 'profile', 'front', 'tq', 'back', 'side', 'r1']);
    expect(planShotImages([null, ...id], refs, 6, 4).images.map(i => i.asset)).toEqual(['face', 'r1', 'r2', 'r3']);
    const two = planShotImages(id, refs, 6, 2);
    expect(two.images.map(i => i.asset)).toEqual(['face', 'r1']);
    expect(two.refs).toEqual([{ index: 2, guides: ['pose'] }, { index: null, guides: ['look'], dropped: true }, { index: null, guides: ['scene'], dropped: true }]);
    expect(planShotImages(id, refs, 6, 1).sent).toEqual([]);
    expect(planShotImages(id, refs, 6, 0).images).toEqual([]);
    expect(planShotImages([], refs, 6, 2).sent.map(s => s.index)).toEqual([1, 2]);
  });
  it('overrides reach every builder', () => {
    const id = { name: 'Demo model', look: 'x', neverAdd: ['rings'] };
    const t = { ...DEFAULT_TEXTS, 'style.house': 'HOUSE', 'never.base': 'aliens, hats', 'sheet.task': 'SHEET {angle}', 'outfit.edit': 'EDIT {angle}', 'enhance.prompt': 'ENH',
      'dress.body': 'BODY{anchor}', 'dress.anchor': 'ANCHOR', 'video.replicate.summary': 'RSUM', 'video.edit.detailed': 'EDET {outfit}', 'lora.variation': 'VAR {variation}', 'lora.variations': 'one\ntwo',
      'template.locked': 'LOCKED {name}' };
    expect(E.characterSheetShot(id, E.SHEET_ANGLES[0], t).text).toContain('SHEET face · front\nStyle: HOUSE.\nNever add: rings, aliens, hats.');
    expect(E.outfitEditPrompt(E.OUTFIT_ANGLES[3], t)).toBe('EDIT full body back view');
    expect(dressPrompt('front', true, t)).toBe('BODY ANCHOR');
    expect(dressPrompt('front', false, t)).toBe('BODY');
    expect(E.replicateSwap({ identity: id, referenceLabels: ['face, front'] }, t).text).toContain('summary:\nRSUM\n');
    expect(E.videoSwap({ identity: id, outfit: { name: 'Knit' } }, t).detailedDescription).toBe('EDET knit');
    expect(exampleFor(PROMPT_DEFS.find(p => p.key === 'lora.variation')!, t)).toMatch(/VAR one$/);
    expect(buildTemplatePrompt({ templateId: 't', templateName: 'M', layers: {}, pool: {}, identity: id, outfit: null, shuffleSeed: 1 }, t).visibleText).toContain('LOCKED M');
  });
});

describe('shoot references and prompt library (API, fake Replicate)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, fake: Awaited<ReturnType<typeof fakeReplicate>>;
  let owner: Client, tess: Client, modelId: string, base: string;
  // A 4-image community model (nano-banana's schema capped at 4) to check the image limit.
  const nano = MODELS['google/nano-banana']!;
  const four = JSON.parse(JSON.stringify({ ...nano, owner: 'test', name: 'four-images', is_official: false, latest_version: { ...nano.latest_version, id: 'v-four' } }));
  four.latest_version.openapi_schema.components.schemas.Input.properties.image_input.maxItems = 4;
  beforeAll(async () => {
    fake = await fakeReplicate({ 'test/four-images': four });
    a = await makeApp({ REPLICATE_API_TOKEN: TOKEN, REPLICATE_API_URL: fake.base, REPLICATE_WEB_URL: fake.web, REPLICATE_POLL_MS: '10', BALANCE_MODE: 'simulated',
      CAP_PER_DAY_USD: '1000', CAP_PER_USER_DAY_USD: '1000', CAP_PER_JOB_USD: '100' });
    await a.app.listen({ port: 0, host: '127.0.0.1' });
    base = `http://127.0.0.1:${(a.app.server.address() as any).port}`;
    const p = await people(a, 1); owner = p.owner; tess = p.members[0]!;
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: tess.id, tokens: 2000 });
    modelId = (await demoModel(owner)).id;
  }, 60_000);
  afterAll(async () => { await a?.close(); await fake?.close(); });
  const lastShots = (n: number) => fake.state.creates.slice(-n);
  const refs3 = [{ image: R('c_front'), guides: ['pose'] }, { image: R('c_tq'), guides: ['look', 'scene'] }, { image: R('c_face'), guides: ['scene'] }];

  it('owner-only: list, save, reset, preview; members get 403 and no event', async () => {
    for (const [m, u, b] of [['GET', '/v1/prompts'], ['PUT', '/v1/prompts/style.house', { text: 'x' }], ['DELETE', '/v1/prompts/style.house'], ['POST', '/v1/prompts/preview', { key: 'style.house' }]] as const) {
      const r = await tess.req(m, u, b);
      expect(r.status, u).toBe(403); expect(r.body.code).toBe('owner_only');
    }
    const l = (await owner.req('GET', '/v1/prompts')).body;
    expect(l.groups.map((g: any) => g.label)).toEqual(['Photoshoot', 'References', 'Character sheet', 'Outfits', 'Enhance', 'Dress up', 'Templates', 'Video', 'LoRA']);
    expect(l.prompts).toHaveLength(53);
    const refPose = l.prompts.find((p: any) => p.key === 'refs.pose');
    expect(refPose).toMatchObject({ group: 'references', current: refPose.default, overridden: false, allowEmpty: false, updatedAt: null,
      placeholders: [{ name: 'refIndex', required: true }] });
    // Validation.
    expect((await owner.req('PUT', '/v1/prompts/shoot.scene', { text: 'Place: {where}.' })).body).toMatchObject({ code: 'prompt_invalid', error: 'Unknown placeholder {where} · this prompt can use {scene}' });
    expect((await owner.req('PUT', '/v1/prompts/refs.guard', { text: 'Not the face.' })).body.error).toBe('Keep {refIndex} · this prompt needs it');
    expect((await owner.req('PUT', '/v1/prompts/nope', { text: 'x' })).status).toBe(404);
    expect((await owner.req('PUT', '/v1/prompts/style.house', {})).body.code).toBe('prompt_invalid');
    // Save, with the live event to owners only.
    const oEs = await sse(base, owner.token), mEs = await sse(base, tess.token);
    const saved = (await owner.req('PUT', '/v1/prompts/shoot.scene', { text: 'Location: {scene}!' })).body;
    expect(saved).toMatchObject({ key: 'shoot.scene', current: 'Location: {scene}!', overridden: true, updatedBy: 'owner@test.dev' });
    expect(saved.updatedAt).toBeGreaterThan(0);
    const ev = await until(() => oEs.events.find(e => e.type === 'prompts'));
    expect(ev.prompt).toMatchObject({ key: 'shoot.scene', overridden: true });
    await new Promise(r => setTimeout(r, 100));
    expect(mEs.events.some(e => e.type === 'prompts')).toBe(false);
    await oEs.stop(); await mEs.stop();
    // Preview: the entry with sample values and the whole prompt it is part of; a draft text is checked too.
    const pv = (await owner.req('POST', '/v1/prompts/preview', { key: 'shoot.scene' })).body;
    expect(pv.text).toBe('Location: rooftop · golden hour!');
    expect(pv.example).toContain('\nLocation: rooftop · golden hour!\n');
    expect(pv.sample).toEqual({ scene: 'rooftop · golden hour' });
    expect((await owner.req('POST', '/v1/prompts/preview', { key: 'refs.pose', text: 'Pose like image {refIndex}.' })).body.example).toContain('Pose like image 8. Copy the light');
    expect((await owner.req('POST', '/v1/prompts/preview', { key: 'refs.pose', text: 'Pose.' })).status).toBe(400);
    // Reset; saving the default text also clears the override.
    expect((await owner.req('DELETE', '/v1/prompts/shoot.scene')).body).toMatchObject({ overridden: false, current: 'Scene: {scene}.', updatedAt: null });
    await owner.req('PUT', '/v1/prompts/style.house', { text: 'x' });
    expect((await owner.req('PUT', '/v1/prompts/style.house', { text: DEFAULT_TEXTS['style.house'] })).body.overridden).toBe(false);
  });

  it('the server builds the shoot prompt; preview = what is sent; Edit as text is sent exactly; Presets off', async () => {
    const body = { modelId, scene: 'Café window', camera: { shot: 'Close', lens: 85, aperture: 'f/1.4' }, light: 'Window light', grade: 'Warm film', direction: 'laughing, blonde hair', count: 1 };
    const pv = (await tess.req('POST', '/v1/shoots/preview', body)).body;
    expect(pv.text).toContain('Scene: café window.\nCamera: close shot, 85mm lens, f/1.4, compressed background, creamy bokeh.\nLight: window light; grade: warm film.\nDirection: laughing');
    expect(pv.removed).toEqual(['blonde hair']);
    expect(pv).toMatchObject({ images: 3, refs: [], edited: false, referenceSheet: false });
    expect(pv.slots.map((s: any) => s.layer)).toEqual(['identity', 'outfit', 'scene', 'camera', 'light', 'direction', 'style', 'negative', 'seed']);
    expect(pv.estimate).toBeCloseTo(0.015 + 0.015 * 2 + 0.015 * 0.79 * 3, 9);
    expect(pv.estimateLabel).toBe('about $0.08');
    await tess.req('POST', '/v1/shoots', body);
    expect(lastShots(1)[0]!.input.prompt).toBe(pv.text);
    // Edit as text.
    await tess.req('POST', '/v1/shoots', { ...body, prompt: 'My own words exactly.' });
    expect(lastShots(1)[0]!.input.prompt).toBe('My own words exactly.');
    expect((await tess.req('POST', '/v1/shoots/preview', { ...body, prompt: 'Mine' })).body).toMatchObject({ text: 'Mine', edited: true, slots: [{ layer: 'custom', text: 'Mine' }] });
    // Presets off.
    const off = (await tess.req('POST', '/v1/shoots/preview', { ...body, presets: false })).body;
    expect(off.slots.map((s: any) => s.layer)).toEqual(['identity', 'outfit', 'direction', 'seed']);
  });

  it('reference images: after her 3 identity images, within 8 images, lines with their numbers, priced per image, stored on the shot', async () => {
    const pv = (await tess.req('POST', '/v1/shoots/preview', { modelId, refs: refs3, count: 2 })).body;
    expect(pv.images).toBe(6);
    expect(pv.refs).toEqual([{ index: 4, guides: ['pose'] }, { index: 5, guides: ['look', 'scene'] }, { index: 6, guides: ['scene'] }]);
    expect(pv.text).toContain('Copy the pose and framing from image 4. Do not take the face, body, hair or clothes from image 4.\n'
      + 'Copy the light, colour grade and camera feel from image 5. Use the place and background from image 5. Do not take the face, body, hair or clothes from image 5.\n'
      + 'Use the place and background from image 6. Do not take the face, body, hair or clothes from image 6.\nStyle:');
    expect(pv.text).toContain('Identity from 3 locked reference images.');
    expect(pv.estimate).toBeCloseTo(2 * (0.015 + 0.015 * 2 + 0.015 * 0.79 * 6), 9);
    const shots = (await tess.req('POST', '/v1/shoots', { modelId, refs: refs3, count: 2 })).body;
    const sent = lastShots(2);
    for (const p of sent) {
      expect(p.model).toBe('black-forest-labs/flux-2-pro');
      expect(p.input.input_images).toHaveLength(6);
      expect(p.input.prompt).toBe(pv.text);
    }
    // The hold was the estimate with the extra images.
    const hold = (await a.ctx.db.select().from(ledger).where(eq(ledger.kind, 'hold'))).at(-1)!;
    expect(-hold.tokens).toBe(a.ctx.money.toTokens(pv.estimate));
    // The exact cost counts the extra input megapixels: more than the same shoot without references.
    const plain = (await tess.req('POST', '/v1/shoots', { modelId, count: 1 })).body;
    expect(lastShots(1)[0]!.input.input_images).toHaveLength(3);
    expect(shots[0].cost).toBeGreaterThan(plain[0].cost);
    const [row] = await a.ctx.db.query.takes.findMany({ where: (t, { eq: e }) => e(t.id, shots[0].id) });
    expect(row!.refs).toEqual(refs3);
    expect(shots[0].refs).toEqual(refs3);
    expect((await tess.req('GET', '/v1/takes')).body.find((t: any) => t.id === shots[0].id).refs).toEqual(refs3);
    expect(plain[0].refs).toBeUndefined();
  });

  it('a smaller model: identity references give way first, never the face front; a 1-image model drops the references', async () => {
    const four = (await owner.req('POST', '/v1/shoots/preview', { modelId, refs: refs3, models: { shot: 'test/four-images' }, count: 1 })).body;
    expect(four.images).toBe(4);
    expect(four.refs.map((r: any) => r.index)).toEqual([2, 3, 4]);
    await owner.req('POST', '/v1/shoots', { modelId, refs: refs3, models: { shot: 'test/four-images' }, count: 1 });
    const p = lastShots(1)[0]!;
    expect(p.model).toBe('test/four-images');
    expect(p.input.image_input).toHaveLength(4);
    expect(p.input.prompt).toContain('from image 2.');
    const one = (await owner.req('POST', '/v1/shoots/preview', { modelId, refs: refs3, models: { shot: 'black-forest-labs/flux-krea-dev' }, count: 1 })).body;
    expect(one.images).toBe(1);
    expect(one.refs.every((r: any) => r.dropped)).toBe(true);
    expect(one.text).not.toContain('from image');
  });

  it('refs validation: at most 3, an image each, 1–3 known guides', async () => {
    const bad = [
      [...refs3, refs3[0]], [{ image: {}, guides: ['pose'] }], [{ image: R('c_face'), guides: [] }], [{ image: R('c_face'), guides: ['outfit'] }], [{ image: R('c_face'), guides: ['pose', 'pose'] }],
    ];
    for (const refs of bad) expect((await tess.req('POST', '/v1/shoots', { modelId, refs, count: 1 })).status, JSON.stringify(refs)).toBe(400);
  });

  it('template shoots take references too; the member sees the locked line plus the reference lines', async () => {
    const t = (await owner.req('POST', '/v1/templates', { name: 'Ref look', visibility: 'public', layers: { scene: 'a bathroom mirror', light: 'soft window light' } })).body;
    const pv = (await tess.req('POST', '/v1/shoots/preview', { modelId, templateId: t.id, refs: refs3.slice(0, 1), shuffleSeed: 5, count: 1 })).body;
    expect(pv.text).toContain('Template: Ref look\nCopy the pose and framing from image 4.');
    expect(pv.text).not.toContain('bathroom');
    expect(pv.images).toBe(4);
    await tess.req('POST', '/v1/shoots', { modelId, templateId: t.id, refs: refs3.slice(0, 1), shuffleSeed: 5, count: 1 });
    const p = lastShots(1)[0]!;
    expect(p.input.prompt).toContain('a bathroom mirror');
    expect(p.input.prompt).toContain('Copy the pose and framing from image 4.');
    expect(p.input.input_images).toHaveLength(4);
  });

  it('a saved override changes what is sent: shoots, sheet fills, outfit sets, Enhance, Dress up, video', async () => {
    const put = async (key: string, text: string) => expect((await owner.req('PUT', `/v1/prompts/${key}`, { text })).status, key).toBe(200);
    await put('style.house', 'HOUSE STYLE X');
    await put('refs.pose', 'POSE FROM {refIndex}.');
    await put('sheet.task', 'SHEET TASK {angle}.');
    await put('outfit.edit', 'OUTFIT EDIT {angle}.');
    await put('enhance.prompt', 'ENHANCE X');
    await put('dress.body', 'DRESS BODY X{anchor}');
    await put('dress.closeup', 'DRESS CLOSE X');
    await put('video.edit.detailed', 'EDIT DETAILS {outfit}.');
    // Shoot (a member's).
    await tess.req('POST', '/v1/shoots', { modelId, refs: refs3.slice(0, 1), count: 1 });
    expect(lastShots(1)[0]!.input.prompt).toContain('Style: HOUSE STYLE X.');
    expect(lastShots(1)[0]!.input.prompt).toContain('POSE FROM 4.');
    // Sheet fill.
    const m2 = (await owner.req('POST', '/v1/models', { name: 'Sheet test', age: 25 })).body;
    await owner.req('PUT', `/v1/models/${m2.id}/slots/face`, { image: R('face'), source: 'upload' });
    const n0 = fake.state.creates.length;
    await owner.req('POST', `/v1/models/${m2.id}/fill-angles`);
    await until(async () => (await owner.req('GET', '/v1/models')).body.find((x: any) => x.id === m2.id).slots.every((s: any) => !s.busy), 30_000);
    const fills = fake.state.creates.slice(n0);
    expect(fills.length).toBe(6);
    expect(fills.every(p => /SHEET TASK [a-z ·¾]+\.\nStyle: HOUSE STYLE X\./.test(p.input.prompt))).toBe(true);
    // Outfit set: the front, then the edits.
    const n1 = fake.state.creates.length;
    const o = (await tess.req('POST', '/v1/outfits', { modelId, name: 'Linen', mode: 'describe', description: 'a linen shirt' })).body;
    await until(async () => (await tess.req('GET', '/v1/outfits')).body.find((x: any) => x.id === o.id)?.state === 'preview', 30_000);
    const set = fake.state.creates.slice(n1);
    expect(set[0]!.input.prompt).toContain('Style: HOUSE STYLE X.');
    expect(set.slice(1).map(p => p.input.prompt)).toEqual(['OUTFIT EDIT full body three-quarter view.', 'OUTFIT EDIT full body side view.', 'OUTFIT EDIT full body back view.']);
    // Enhance.
    const n2 = fake.state.creates.length;
    const en = (await tess.req('POST', `/v1/models/${modelId}/enhance`, { realism: 'subtle', upscale: 'off', slots: ['face'] })).body;
    await until(async () => (await tess.req('GET', `/v1/tool-runs/${en.id}`)).body.state === 'review', 30_000);
    expect(fake.state.creates.slice(n2).map(p => p.input.prompt)).toEqual(['ENHANCE X']);
    // Dress up.
    const n3 = fake.state.creates.length;
    const du = (await tess.req('POST', `/v1/models/${modelId}/dress-up`, { outfitImage: R('c_front') })).body;
    await until(async () => (await tess.req('GET', `/v1/tool-runs/${du.id}`)).body.state === 'review', 30_000);
    const dress = fake.state.creates.slice(n3).map(p => p.input.prompt);
    expect(dress[0]).toBe('DRESS BODY X');
    expect(dress).toContain('DRESS BODY X The last image shows the same outfit already worn: match its colours, prints and details exactly.');
    expect(dress).toContain('DRESS CLOSE X');
    // Video (Edit): the job's exact prompt.
    const job = (await tess.req('POST', '/v1/jobs', { title: 't', modelId, outfitId: '', clipId: '', engine: 'h3', steps: 4, use: 'first', takes: 1, keepAudio: true, lipSync: false,
      background: 'keep', backgroundMotion: 'still', queue: true })).body;
    expect(job.prompt).toContain('detailed_description:\nEDIT DETAILS outfit.');
    // Reset: back to the default.
    await owner.req('DELETE', '/v1/prompts/style.house');
    await tess.req('POST', '/v1/shoots', { modelId, count: 1 });
    expect(lastShots(1)[0]!.input.prompt).toContain(`Style: ${DEFAULT_TEXTS['style.house']}.`);
  });
});
