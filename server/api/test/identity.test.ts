// Identity images, safety tolerance and reference sheets (plans/api.md "Identity images, safety tolerance and reference
// sheets"), against a FAKE Replicate on localhost: no real predictions, no money.
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import sharp from 'sharp';
import { models, type SheetSlot } from '../src/db/schema.js';
import { bodySlotOf, clampIdentityRefs, identityRefs } from '../src/images/identity.js';
import { buildCollage, COLLAGE_MAX_PX, collageLayout, collageMp, labelSvg } from '../src/images/collage.js';
import { mapModel, safetyTolerance, takesReferenceSheet, type RawModel } from '../src/replicate/mapping.js';
import { collageLine, refPanelLabel } from '../src/prompt/engine.js';
import { makeApp, people, demoModel, sse, until, type Client } from './helpers.js';
import { fakeReplicate, MODELS, TOKEN } from './fakeReplicate.js';

const R = (asset: string) => ({ asset });
/** FLUX Kontext [pro]'s input schema (one input image, safety_tolerance 0–6 with a lower limit for image inputs), trimmed. */
const oneImageModel = (owner: string, name: string): RawModel => ({
  owner, name, description: 'one reference image', run_count: 1, is_official: true, visibility: 'public',
  latest_version: { id: `v-${name}`, openapi_schema: { components: { schemas: {
    Input: { type: 'object', title: 'Input', required: ['prompt'], properties: {
      prompt: { type: 'string', title: 'Prompt', 'x-order': 0, description: 'Text description of what you want to generate, or the instruction on how to edit the given image.' },
      input_image: { type: 'string', format: 'uri', title: 'Input Image', 'x-order': 1, description: 'Image to use as reference. Must be jpeg, png, gif, or webp.' },
      aspect_ratio: { allOf: [{ $ref: '#/components/schemas/aspect_ratio' }], default: 'match_input_image', 'x-order': 2 },
      seed: { type: 'integer', title: 'Seed', 'x-order': 3, nullable: true },
      output_format: { allOf: [{ $ref: '#/components/schemas/output_format' }], default: 'png', 'x-order': 4 },
      safety_tolerance: { type: 'integer', title: 'Safety Tolerance', default: 2, minimum: 0, maximum: 6, 'x-order': 5,
        description: 'Safety tolerance, 0 is most strict and 6 is most permissive. 2 is currently the maximum allowed when input images are used.' },
      prompt_upsampling: { type: 'boolean', title: 'Prompt Upsampling', default: false, 'x-order': 6 },
    } },
    aspect_ratio: { type: 'string', title: 'aspect_ratio', enum: ['match_input_image', '1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3', '4:5', '5:4', '21:9', '9:21', '2:1', '1:2'] },
    output_format: { type: 'string', title: 'output_format', enum: ['jpg', 'png'] },
    Output: { type: 'string', format: 'uri', title: 'Output' },
  } } } },
});
const KONTEXT = oneImageModel('black-forest-labs', 'flux-kontext-pro');
/** A one-image model billed per input megapixel (fixtures/replicate/page_test_one-image.html), to check the sheet's price. */
const ONE = oneImageModel('test', 'one-image');

const slotsOf = (o: Record<string, string>): SheetSlot[] => Object.entries(o).map(([key, a]) => ({ key, image: R(a), source: 'upload', busy: false }) as SheetSlot);
const FULL = { face: 'face', profile: 'profile', front: 'g_front', tq: 'g_tq', side: 'g_side', back: 'g_back', faceTq: 'c_face' };

describe('identity images (unit)', () => {
  it('3 by default: face front, face ¾, the chosen body image; the face front is never dropped', () => {
    const pick = (m: Parameters<typeof identityRefs>[0], o?: Parameters<typeof identityRefs>[1], opts?: Parameters<typeof identityRefs>[2]) =>
      identityRefs(m, o, opts).map(i => `${(i.image as any).asset}:${i.label}:${i.role}`);
    expect(pick({ slots: slotsOf(FULL) })).toEqual(['face:face:person', 'c_face:face ¾:person', 'g_front:body:person']);
    expect(pick({ slots: slotsOf(FULL), identityBodySlot: 'side' })).toEqual(['face:face:person', 'c_face:face ¾:person', 'g_side:body:person']);
    // No ¾ close-up: her profile instead.
    const { faceTq: _tq, ...noTq } = FULL;
    expect(pick({ slots: slotsOf(noTq) })).toEqual(['face:face:person', 'profile:face profile:person', 'g_front:body:person']);
    // The chosen body slot is empty: the next filled one.
    const { back: _b, front: _f, ...noBack } = FULL;
    expect(pick({ slots: slotsOf(noBack), identityBodySlot: 'back' })[2]).toBe('g_tq:body:person');
    // More (studio setting): profile, then her other body angles; fewer: the face front stays.
    expect(pick({ slots: slotsOf(FULL), identityBodySlot: 'side' }, null, { count: 7 }).map(x => x.split(':')[0]))
      .toEqual(['face', 'c_face', 'g_side', 'profile', 'g_front', 'g_tq', 'g_back']);
    expect(pick({ slots: slotsOf(FULL) }, null, { count: 1 })).toEqual(['face:face:person']);
    // With an outfit (owner 2026-11-11): ONLY the outfit's images. An older one without face close-ups: her base face front,
    // then its angles; then product photos. The person budget doesn't cut them.
    const outfit = { angles: [R('o_front'), R('o_tq'), null, null] };
    expect(pick({ slots: slotsOf(FULL) }, outfit, { outfit: true, extra: [{ image: R('p1'), label: 'product', role: 'product' }] }).map(x => x.split(':')[0]))
      .toEqual(['face', 'o_front', 'o_tq', 'p1']);
    // Its own face close-ups (hair, make-up, accessories) in place of hers: face, front angle, ¾, profile, then the other angles.
    expect(pick({ slots: slotsOf(FULL) }, { angles: [R('o_front'), R('o_tq'), R('o_side'), R('o_back')], faces: [R('o_face'), R('o_ftq'), R('o_prof')] }, { outfit: true, count: 1 }).map(x => x.split(':')[0]))
      .toEqual(['o_face', 'o_front', 'o_ftq', 'o_prof', 'o_tq', 'o_side', 'o_back']);
    // Without the outfit flag, her own images as before.
    expect(pick({ slots: slotsOf(FULL) }, outfit, {}).map(x => x.split(':')[0])).toEqual(['face', 'c_face', 'g_front']);
    expect([clampIdentityRefs(null), clampIdentityRefs(0), clampIdentityRefs(9), clampIdentityRefs(5)]).toEqual([3, 1, 7, 5]);
    expect([bodySlotOf({ slots: [] }), bodySlotOf({ slots: [], identityBodySlot: 'left' }), bodySlotOf({ slots: [], identityBodySlot: 'back' })]).toEqual(['front', 'front', 'back']);
  });

  it('safety tolerance: 5 on FLUX.2 and Kontext, within the schema (Kontext with an input image: 2); other models: not sent', () => {
    const inputs = (m: RawModel) => mapModel(m, 'shot').inputs;
    const flux2 = inputs(MODELS['black-forest-labs/flux-2-pro']!);
    expect(safetyTolerance('black-forest-labs/flux-2-pro', flux2, 5, true)).toBe(5);
    expect(safetyTolerance('black-forest-labs/flux-2-pro', flux2, 9, true)).toBe(5);   // the schema's maximum
    expect(safetyTolerance('black-forest-labs/flux-2-pro', flux2, 0, true)).toBe(1);   // and minimum
    expect(safetyTolerance('black-forest-labs/flux-kontext-pro', inputs(KONTEXT), 5, true)).toBe(2);
    expect(safetyTolerance('black-forest-labs/flux-kontext-pro', inputs(KONTEXT), 5, false)).toBe(5);
    expect(safetyTolerance('test/one-image', inputs(ONE), 5, true)).toBeNull();
    expect(safetyTolerance('black-forest-labs/flux-krea-dev', inputs(MODELS['black-forest-labs/flux-krea-dev']!), 5, true)).toBeNull();
  });

  it('one-image models get a reference sheet; arrays and img2img models do not', () => {
    const k = mapModel(KONTEXT, 'shot');
    expect(k).toMatchObject({ compatible: true, mapping: { image: { field: 'input_image', array: false } } });
    expect(k.warnings).toContain('1 image: MUSE sends a reference sheet');
    expect(takesReferenceSheet(k.mapping)).toBe(true);
    expect(takesReferenceSheet(mapModel(MODELS['black-forest-labs/flux-2-pro']!, 'shot').mapping)).toBe(false);
    const krea = mapModel(MODELS['black-forest-labs/flux-krea-dev']!, 'shot');
    expect(takesReferenceSheet(krea.mapping)).toBe(false);
    expect(krea.warnings).toContain('takes 1 reference only');
  });

  it('the sheet: face front largest, ≤ 2048 px, a layout that depends only on the count; JPEG', async () => {
    for (let n = 1; n <= 10; n++) {
      const l = collageLayout(n);
      expect(l.cells).toHaveLength(n);
      expect(Math.max(l.width, l.height)).toBeLessThanOrEqual(COLLAGE_MAX_PX);
      for (const c of l.cells.slice(1)) expect(c.w * c.h).toBeLessThan(l.cells[0]!.w * l.cells[0]!.h);
      for (const c of l.cells) expect(c.x + c.w <= l.width && c.y + c.h <= l.height).toBe(true);
      expect(collageMp(n)).toBeCloseTo(l.width * l.height / 1e6, 12);
    }
    const img = (bg: string, w: number, h: number) => sharp({ create: { width: w, height: h, channels: 3, background: bg } }).png().toBuffer();
    const c = await buildCollage(await Promise.all([img('#a33', 768, 1024), img('#3a3', 1024, 768), img('#33a', 600, 900), img('#aa3', 900, 900)]), ['face', 'face ¾', 'body', 'ref: pose & framing']);
    const meta = await sharp(c.data).metadata();
    expect(meta).toMatchObject({ format: 'jpeg', width: collageLayout(4).width, height: collageLayout(4).height });
    expect([c.width, c.height]).toEqual([meta.width, meta.height]);
    // Labels wrap at spaces rather than being cut.
    expect(labelSvg('1 face ¾', 3, 1000).lines).toEqual(['1 FACE 3/4']);
    const long = labelSvg('6 ref: look & colour & scene', 3, 420);
    expect(long.lines).toEqual(['6 REF: LOOK & COLOUR &', 'SCENE']);
    expect(long.width).toBeLessThanOrEqual(420);
  });

  it('the prompt line names the panels', () => {
    expect(collageLine([{ label: 'face', role: 'person' }, { label: 'face ¾', role: 'person' }, { label: 'body', role: 'person' }, { label: 'outfit', role: 'outfit' },
      { label: refPanelLabel(['look', 'scene']), role: 'ref', guides: ['look', 'scene'] }])).toBe('The input image is a reference sheet of numbered panels ("image N" below means panel N): '
      + 'panels 1–3 show the person (use her face, hair and body exactly); panel 4 shows the outfit to wear; panel 5 guides the look & colour and the scene only; create one new photo, not a collage.');
    expect(collageLine([{ label: 'face', role: 'person' }, { label: 'product', role: 'product' }])).toContain(': panel 1 shows the person (use her face, hair and body exactly); panel 2 shows the product;');
    expect(refPanelLabel(['scene', 'pose'])).toBe('ref: pose & framing & scene');
  });
});

describe('identity images and reference sheets (API, fake Replicate)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, fake: Awaited<ReturnType<typeof fakeReplicate>>;
  let owner: Client, tess: Client, modelId: string, studioId: string, base: string;
  beforeAll(async () => {
    fake = await fakeReplicate({ 'black-forest-labs/flux-kontext-pro': KONTEXT, 'test/one-image': ONE });
    a = await makeApp({ REPLICATE_API_TOKEN: TOKEN, REPLICATE_API_URL: fake.base, REPLICATE_WEB_URL: fake.web, REPLICATE_POLL_MS: '10', BALANCE_MODE: 'simulated',
      CAP_PER_DAY_USD: '1000', CAP_PER_USER_DAY_USD: '1000', CAP_PER_JOB_USD: '100' });
    await a.app.listen({ port: 0, host: '127.0.0.1' });
    base = `http://127.0.0.1:${(a.app.server.address() as any).port}`;
    const p = await people(a, 1); owner = p.owner; tess = p.members[0]!;
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: tess.id, tokens: 2000 });
    modelId = (await demoModel(owner)).id;
    studioId = (await a.ctx.db.select().from(models).where(eq(models.id, modelId)))[0]!.studioId;
  }, 60_000);
  afterAll(async () => { await a?.close(); await fake?.close(); });
  const last = (n = 1) => fake.state.creates.slice(-n);
  const rxKey = (u: string) => /\/(rx\/[^?]+)/.exec(u)?.[1];
  /** The rx/ key each of these sheet images is sent under. */
  const rx = async (...assets: string[]) => Promise.all(assets.map(async x => rxKey((await a.ctx.images.replicateRef(R(x), studioId))!.url)));
  const sent = () => (last()[0]!.input.input_images as string[]).map(rxKey);

  it('settings: identityRefs 3 by default (owner view and features.photo); 1–7, owner only', async () => {
    const o = (await owner.req('GET', '/v1/settings/studio')).body;
    expect(o.identityRefs).toBe(3);
    expect(o.features.photo.identityRefs).toBe(3);
    const m = (await tess.req('GET', '/v1/settings/studio')).body;
    expect(m.identityRefs).toBeUndefined();
    expect(m.features.photo.identityRefs).toBe(3);
    expect((await tess.req('PATCH', '/v1/settings/studio', { identityRefs: 5 })).status).toBe(403);
    for (const v of [0, 8, 2.5]) expect((await owner.req('PATCH', '/v1/settings/studio', { identityRefs: v })).status, String(v)).toBe(400);
  });

  it('a shoot sends face front, face ¾ and her body image (identityBodySlot); the outfit front comes next', async () => {
    await owner.req('POST', '/v1/shoots', { modelId, count: 1 });
    expect(last()[0]!.model).toBe('black-forest-labs/flux-2-pro');
    expect(sent()).toEqual(await rx('face', 'c_face', 'g_front'));
    expect(last()[0]!.input.prompt).toContain('Identity from 3 locked reference images.');
    // Her body slot: the owner or her creator; a model event carries it.
    expect((await owner.req('GET', '/v1/models')).body.find((x: any) => x.id === modelId).identityBodySlot).toBe('front');
    const forbidden = await tess.req('PATCH', `/v1/models/${modelId}`, { identityBodySlot: 'side' });
    expect(forbidden.status).toBe(403);
    expect(forbidden.body.code).toBe('owner_only');
    expect((await owner.req('PATCH', `/v1/models/${modelId}`, { identityBodySlot: 'left' })).status).toBe(400);
    const es = await sse(base, owner.token);
    const v = (await owner.req('PATCH', `/v1/models/${modelId}`, { identityBodySlot: 'side' })).body;
    expect(v.identityBodySlot).toBe('side');
    await until(() => es.events.some(e => e.type === 'model' && e.model.id === modelId && e.model.identityBodySlot === 'side'));
    await es.stop();
    const own = (await tess.req('POST', '/v1/models', { name: 'Tess model', age: 25 })).body;
    expect((await tess.req('PATCH', `/v1/models/${own.id}`, { identityBodySlot: 'back' })).body.identityBodySlot).toBe('back');
    await tess.req('POST', '/v1/shoots', { modelId, count: 1 });
    expect(sent()).toEqual(await rx('face', 'c_face', 'g_side'));
    // With an outfit: only its images (its 3 face close-ups, made from her base faces and its front, and its angles).
    const outfit = (await owner.req('POST', '/v1/outfits', { modelId, name: 'Own set', mode: 'own', images: [R('hero'), R('g_tq')] })).body;
    const made = await until(async () => { const x = (await owner.req('GET', '/v1/outfits')).body.find((y: any) => y.id === outfit.id); return x?.state === 'preview' ? x : null; });
    expect(made.faces.every((f: any) => f?.url)).toBe(true);
    const pv = (await owner.req('POST', '/v1/shoots/preview', { modelId, outfitId: outfit.id, count: 1 })).body;
    expect(pv).toMatchObject({ images: 5, referenceSheet: false });
    expect(pv.sentImages.images.map((x: any) => x.label)).toEqual(['face', 'outfit, front', 'face ¾', 'face profile', 'outfit, ¾']);
    await owner.req('POST', '/v1/shoots', { modelId, outfitId: outfit.id, count: 1 });
    const out = sent();
    expect(out.length).toBe(5);
    expect([out[1], out[4]]).toEqual(await rx('hero', 'g_tq'));
    for (const base of await rx('face', 'c_face', 'g_side')) expect(out).not.toContain(base);
  });

  it('the studio setting widens or narrows it; estimates follow', async () => {
    const before = (await owner.req('GET', '/v1/settings/studio')).body.features.photo.estimates.shoot;
    const s = (await owner.req('PATCH', '/v1/settings/studio', { identityRefs: 5 })).body;
    expect(s).toMatchObject({ identityRefs: 5, features: { photo: { identityRefs: 5 } } });
    expect(s.features.photo.estimates.shoot).toBeCloseTo(before + 4 * 0.015 * 0.79 * 2, 9);
    await owner.req('POST', '/v1/shoots', { modelId, count: 1 });
    expect(sent()).toEqual(await rx('face', 'c_face', 'g_side', 'profile', 'g_front'));
    expect(last()[0]!.input.prompt).toContain('Identity from 5 locked reference images.');
    await owner.req('PATCH', '/v1/settings/studio', { identityRefs: 1 });
    const pv = (await tess.req('POST', '/v1/shoots/preview', { modelId, refs: [{ image: R('c_tq'), guides: ['pose'] }], count: 1 })).body;
    expect(pv.images).toBe(2);
    expect(pv.refs).toEqual([{ index: 2, guides: ['pose'] }]);
    await owner.req('PATCH', '/v1/settings/studio', { identityRefs: 3 });
  });

  it('a one-image model (Kontext): one reference sheet with a prompt line, safety tolerance 2, compatible in the catalog', async () => {
    const d = (await owner.req('GET', '/v1/image-models/model?id=black-forest-labs/flux-kontext-pro&step=shot')).body;
    expect(d).toMatchObject({ compatible: true });
    expect(d.warnings).toContain('1 image: MUSE sends a reference sheet');
    const refs = [{ image: R('c_tq'), guides: ['pose'] }, { image: R('c_front'), guides: ['look', 'scene'] }];
    const body = { modelId, refs, scene: 'Kitchen', count: 1, models: { shot: 'black-forest-labs/flux-kontext-pro' } };
    const pv = (await owner.req('POST', '/v1/shoots/preview', body)).body;
    expect(pv).toMatchObject({ images: 5, referenceSheet: true, refs: [{ index: 4, guides: ['pose'] }, { index: 5, guides: ['look', 'scene'] }] });
    const line = 'The input image is a reference sheet of numbered panels ("image N" below means panel N): panels 1–3 show the person (use her face, hair and body exactly); '
      + 'panel 4 guides the pose & framing only; panel 5 guides the look & colour and the scene only; create one new photo, not a collage.';
    expect(pv.text.startsWith(`${line}\n`)).toBe(true);
    expect(pv.slots[0]).toEqual({ layer: 'sheet', text: line });
    expect(pv.text).toContain('Copy the pose and framing from image 4.');
    await owner.req('POST', '/v1/shoots', body);
    const p = last()[0]!;
    expect(p.model).toBe('black-forest-labs/flux-kontext-pro');
    expect(typeof p.input.input_image).toBe('string');
    expect(rxKey(p.input.input_image)).toMatch(/^rx\/sheet_[0-9a-f]{32}\.jpg$/);
    expect(p.input).toMatchObject({ prompt: pv.text, aspect_ratio: '9:16', output_format: 'jpg', safety_tolerance: 2 });
    expect(Object.keys(p.input)).not.toContain('disable_safety_checker');
    expect(Object.keys(p.input)).not.toContain('input_images');
    const meta = await sharp(path.join(a.dir, rxKey(p.input.input_image)!)).metadata();
    expect(meta).toMatchObject({ format: 'jpeg', width: collageLayout(5).width, height: collageLayout(5).height });
  });

  it('the sheet is priced by its megapixels (estimate and exact settle)', async () => {
    const refs = [{ image: R('c_tq'), guides: ['scene'] }];
    const body = { modelId, refs, count: 2, models: { shot: 'test/one-image' } };
    const pv = (await owner.req('POST', '/v1/shoots/preview', body)).body;
    expect(pv).toMatchObject({ images: 4, referenceSheet: true });
    const one = 0.015 + 0.015 * collageMp(4) + 0.015 * 2;
    expect(pv.estimate).toBeCloseTo(2 * one, 9);
    const shots = (await owner.req('POST', '/v1/shoots', body)).body;
    expect(shots).toHaveLength(2);
    for (const p of last(2)) {
      expect(p.model).toBe('test/one-image');
      expect(p.input).not.toHaveProperty('safety_tolerance');   // not a FLUX model: its own default
    }
    // The fake's output is 64×96.
    for (const s of shots) expect(s.cost).toBeCloseTo(0.015 + 0.015 * collageMp(4) + 0.015 * (64 * 96 / 1e6), 12);
  });

  it('the studio shot model on a one-image model: sheet fills send her identity images as one sheet', async () => {
    expect((await owner.req('PUT', '/v1/image-models/shot', { model: 'black-forest-labs/flux-kontext-pro' })).status).toBe(200);
    const m = (await owner.req('POST', '/v1/models', { name: 'Fill test', age: 26 })).body;
    for (const [k, x] of Object.entries({ face: 'face', faceTq: 'c_face', front: 'g_front' })) await owner.req('PUT', `/v1/models/${m.id}/slots/${k}`, { image: R(x), source: 'upload' });
    const n0 = fake.state.creates.length;
    expect((await owner.req('POST', `/v1/models/${m.id}/fill-angles`)).status).toBe(200);
    await until(async () => (await owner.req('GET', '/v1/models')).body.find((x: any) => x.id === m.id)?.slots.every((s: any) => !s.busy));
    const made = fake.state.creates.slice(n0);
    expect(made).toHaveLength(4);   // profile, tq, side, back
    for (const p of made) {
      expect(p.model).toBe('black-forest-labs/flux-kontext-pro');
      expect(rxKey(p.input.input_image)).toMatch(/^rx\/sheet_/);
      expect(p.input.prompt.split('\n')[0]).toBe('The input image is a reference sheet of numbered panels ("image N" below means panel N): panels 1–3 show the person (use her face, hair and body exactly); create one new photo, not a collage.');
    }
    expect((await owner.req('DELETE', '/v1/image-models/shot')).status).toBe(200);
  });
});
