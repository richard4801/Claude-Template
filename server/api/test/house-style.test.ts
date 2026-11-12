// The house style split (owner 2026-11-11): Realism always; Camera feel ("realistic smartphone photo") only when the shot
// has no camera of its own (a rig's or preset's camera body, lens, grade or look); the default grade yields the same way.
// An owner's saved single house style is split so nothing she wrote is lost. Video Suite shots never use it.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { promptOverrides, users } from '../src/db/schema.js';
import * as E from '../src/prompt/engine.js';
import { DEFAULT_TEXTS, migrateOverrides, resolveTexts, splitHouseStyle } from '../src/prompt/library.js';
import { SAMPLE } from '../src/prompt/scripts/defs.js';
import { STARTERS } from '../src/templates/starters.js';
import { buildTemplatePrompt, templateOwnCamera } from '../src/templates/prompt.js';
import { CameraSpecSchema } from '../src/suite/camera.js';
import { stillRig } from '../src/suite/photo.js';
import { buildPlan, fit, needOf, ShotRequestSchema, type Character } from '../src/suite/plan.js';
import { modelById } from '../src/suite/registry.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

const PHONE = 'realistic smartphone photo';
const REALISM = DEFAULT_TEXTS['style.realism']!;
const id: E.Identity = { name: 'Demo model', look: 'young woman', neverAdd: ['rings'], referenceCount: 3 };
const cam = (c: object) => CameraSpecSchema.parse(c);

describe('house style split (unit)', () => {
  it('at the defaults, Camera feel + Realism read exactly as the old single house style', () => {
    expect(E.HOUSE_STYLE).toBe('realistic smartphone photo, natural skin texture, true-to-life colour, no beauty filter, no AI gloss');
    expect(E.houseStyle()).toBe(E.HOUSE_STYLE);
    expect(E.houseStyle(DEFAULT_TEXTS, true)).toBe(REALISM);
  });

  it('a phone shot keeps Camera feel and the phone-natural grade; a shot with its own camera drops both and its words stand', () => {
    const phone = E.photoshoot({ identity: id, outfit: { name: 'Green set' } }).text;
    expect(phone).toContain(`Style: ${E.HOUSE_STYLE}.`);
    expect(phone).toContain('Light: golden hour; grade: phone-natural.');
    const rig = E.photoshoot({ identity: id, outfit: { name: 'Green set' }, ownCamera: true, direction: 'Shot on 35mm motion-picture film.' }).text;
    expect(rig).not.toContain(PHONE);
    expect(rig).not.toContain('phone-natural');
    expect(rig).toContain('Light: golden hour.\n');
    expect(rig).toContain(`Style: ${REALISM}.`);
    expect(rig).toContain('Direction: Shot on 35mm motion-picture film.');
    // A look or palette from the rig is its grade.
    expect(E.photoshoot({ identity: id, outfit: { name: 'Green set' }, ownCamera: true, grade: 'Tungsten cinema stock' }).text).toContain('Light: golden hour; grade: tungsten cinema stock.');
    // The old Photo tool's grade picker isn't a rig: Camera feel stays (the apps' offline engines match this).
    expect(E.photoshoot({ identity: id, outfit: { name: 'Green set' }, grade: 'Warm film' }).text).toContain(`Style: ${E.HOUSE_STYLE}.`);
  });

  it('a scene typed as a sentence gets one full stop, not two', () => {
    expect(E.photoshoot({ identity: id, outfit: { name: 'Green set' }, scene: 'She leans on a rooftop rail at dusk. ' }).text).toContain('\nScene: she leans on a rooftop rail at dusk.\n');
    expect(E.photoshoot({ identity: id, outfit: { name: 'Green set' }, scene: '...' }).text).toContain('\nScene: rooftop · golden hour.\n');
  });

  it('sheet fills, LoRA sets and outfit sets keep the clean reference look (Realism + Camera feel)', () => {
    expect(E.characterSheetShot(id, E.SHEET_ANGLES[0]).text).toContain(`Style: ${E.HOUSE_STYLE}.`);
    expect(E.outfitSet(id, { name: 'Green set' })[0]!.text).toContain(`Style: ${E.HOUSE_STYLE}.`);
    // The owner's edits reach them; an empty Camera feel leaves only Realism.
    const t = { ...DEFAULT_TEXTS, 'style.camera': 'shot on a phone', 'style.realism': 'real skin.' };
    expect(E.characterSheetShot(id, E.SHEET_ANGLES[2], t).text).toContain('Style: shot on a phone, real skin.\n');
    expect(E.outfitSet(id, { name: 'Green set' }, 1, { ...DEFAULT_TEXTS, 'style.camera': '' })[0]!.text).toContain(`Style: ${REALISM}.`);
  });

  it('the Photo rig has its own camera with a body, lens character, look or palette; not for focal length, aperture, shot size or light', () => {
    for (const c of [{ rig: { body: 'cinema_digital' } }, { rig: { body: 'phone' } }, { rig: { lens: 'anamorphic' } }, { rig: { look: 'tungsten_stock' } }, { palette: { preset: 'teal_orange' } }, { preset: 'cinematic' }])
      expect(stillRig({ prompt: '', camera: cam(c) }).ownCamera, JSON.stringify(c)).toBe(true);
    for (const c of [{}, { rig: { focalMm: 85, aperture: 'f1.4' } }, { angle: { shotSize: 'cu' } }, { lighting: { preset: 'golden_hour' } }])
      expect(stillRig({ prompt: '', camera: cam(c) }).ownCamera, JSON.stringify(c)).toBeUndefined();
  });

  it('a preset (photo template) has its own camera when its camera words aren’t a phone’s and name a film / cinema camera or lens', () => {
    for (const s of STARTERS) expect(templateOwnCamera(s.layers), s.name).toBe(false);
    expect(templateOwnCamera({ camera: 'anamorphic cinema lens, 35mm motion-picture film' })).toBe(true);
    expect(templateOwnCamera({ style: 'cinematic still', camera: 'eye level' })).toBe(true);
    expect(templateOwnCamera({ camera: 'eye level, slight tilt' })).toBe(false);
    const build = (camera: string) => buildTemplatePrompt({ templateId: 't', templateName: 'T', layers: { camera, style: 'moody' }, pool: {}, identity: id, outfit: null, shuffleSeed: 1 }).fullText;
    expect(build('phone held low')).toContain(`Style: moody; ${E.HOUSE_STYLE}.`);
    expect(build('85mm portrait prime on a full-frame camera')).toContain(`Style: moody; ${REALISM}.`);
  });

  it('Video Suite shots never use the house style', () => {
    const CHAR: Character = { name: 'Mia', look: 'young woman', neverAdd: [], images: [{ label: 'face, front', image: { asset: 'face' } }], outfit: null };
    const texts = { ...DEFAULT_TEXTS, 'style.camera': 'CAMERA_FEEL_MARK', 'style.realism': 'REALISM_MARK' };
    for (const [mid, res] of [['h3', '768P'], ['veo-3.1-lite', '720p']] as const) {
      const m = modelById(mid)!, r = ShotRequestSchema.parse({ prompt: 'She smiles.', frames: { start: { asset: 'face' } } }), n = needOf(r, CHAR);
      const p = buildPlan(r, n, { model: m, resolution: m.resolutions.find(x => x.id === res)!, seconds: fit(m, res, n).seconds, tried: [] }, CHAR, { texts });
      expect(JSON.stringify(p)).not.toMatch(/CAMERA_FEEL_MARK|REALISM_MARK/);
    }
  });
});

describe('an owner’s saved house style is split, nothing lost', () => {
  it('phone phrases go to Camera feel, the rest to Realism, in her words and order', () => {
    expect(splitHouseStyle(DEFAULT_TEXTS['style.camera'] + ', ' + REALISM)).toEqual({ camera: PHONE, realism: REALISM });
    expect(splitHouseStyle('Candid iPhone snapshot; warm skin with visible pores. no retouching, shot on a phone at arm’s length'))
      .toEqual({ camera: 'Candid iPhone snapshot, shot on a phone at arm’s length', realism: 'warm skin with visible pores, no retouching' });
    expect(splitHouseStyle('film grain, soft skin')).toEqual({ camera: '', realism: 'film grain, soft skin' });
    expect(splitHouseStyle('selfie on a smartphone')).toEqual({ camera: 'selfie on a smartphone', realism: '' });
  });
  it('the old key becomes the two new ones (unless they are saved already); resolveTexts reads old saves', () => {
    expect(migrateOverrides({ 'style.house': 'phone photo, real skin', 'shoot.scene': 'S {scene}' })).toEqual({ 'shoot.scene': 'S {scene}', 'style.camera': 'phone photo', 'style.realism': 'real skin' });
    expect(migrateOverrides({ 'style.house': 'phone photo, real skin', 'style.realism': 'mine' })).toEqual({ 'style.realism': 'mine' });
    // Every phrase about the phone: Realism keeps its default (her words are all in Camera feel).
    expect(migrateOverrides({ 'style.house': 'iPhone photo' })).toEqual({ 'style.camera': 'iPhone photo' });
    const t = resolveTexts({ 'style.house': 'grainy phone pic, honest colour' });
    expect(E.houseStyle(t)).toBe('grainy phone pic, honest colour');
    expect(E.houseStyle(t, true)).toBe('honest colour');
  });
});

describe('house style (API)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, modelId: string;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock' });
    ({ owner } = await people(a, 0, { topUp: 100 }) as any);
    modelId = (await demoModel(owner)).id;
  });
  afterAll(async () => { await a?.close(); });

  it('a saved single house style shows as Camera feel + Realism in Settings, with its date and author, and reaches the next shoot', async () => {
    const [me] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    await a.ctx.db.insert(promptOverrides).values({ studioId: me!.studioId, key: 'style.house', text: 'casual phone photo, soft real skin, no filter', updatedBy: owner.id, updatedAt: 1_700_000_000_000 });
    const list = (await owner.req('GET', '/v1/prompts')).body.prompts;
    expect(list.find((p: any) => p.key === 'style.house')).toBeUndefined();
    expect(list.find((p: any) => p.key === 'style.camera')).toMatchObject({ current: 'casual phone photo', overridden: true, updatedAt: 1_700_000_000_000, updatedBy: 'owner@test.dev' });
    expect(list.find((p: any) => p.key === 'style.realism')).toMatchObject({ current: 'soft real skin, no filter', overridden: true });
    const rows = await a.ctx.db.select().from(promptOverrides).where(eq(promptOverrides.studioId, me!.studioId));
    expect(rows.map(r => r.key).sort()).toEqual(['style.camera', 'style.realism']);
    const shoot = (await owner.req('POST', '/v1/shoots/preview', { modelId, count: 1 })).body;
    expect(shoot.text).toContain('Style: casual phone photo, soft real skin, no filter.');
    await owner.req('DELETE', '/v1/prompts/style.camera');
    await owner.req('DELETE', '/v1/prompts/style.realism');
  });

  it('Photo: no rig keeps Camera feel and phone-natural; a cinematic rig drops both and its body, lens and look stand', async () => {
    const est = async (camera?: object) => (await owner.req('POST', '/v1/suite/photos/estimate', { modelId, prompt: 'She leans on a rooftop rail.', count: 1, ...(camera ? { camera } : {}) })).body.prompt as string;
    const phone = await est();
    expect(phone).toContain(`Style: ${E.HOUSE_STYLE}.`);
    expect(phone).toContain('grade: phone-natural');
    const cine = await est({ rig: { body: 'film_35', lens: 'anamorphic', look: 'tungsten_stock' } });
    expect(cine).not.toContain(PHONE);
    expect(cine).not.toContain('phone-natural');
    expect(cine).toContain(`Style: ${REALISM}.`);
    expect(cine).toContain('grade: tungsten-balanced cinema film stock');
    expect(cine).toMatch(/Shot on 35mm motion-picture film/);
    // A body alone: no grade at all (the default yields), light stays.
    const body = await est({ rig: { body: 'cinema_digital' } });
    expect(body).toContain('Light: golden hour.\n');
    expect(body).not.toContain('grade:');
  });

  it('previews: one consistent sample set, and a “with a cinematic rig” variant without Camera feel', async () => {
    const lib = (await owner.req('POST', '/v1/prompts/preview', { key: 'style.camera' })).body;
    expect(lib.example).toContain(`Identity from ${SAMPLE.refCount} locked reference images`);
    expect(lib.example).toContain(`Copy the pose and framing from image ${SAMPLE.refIndex}.`);
    expect(lib.example).toContain(`Style: ${E.HOUSE_STYLE}.`);
    expect(lib.variants).toHaveLength(1);
    expect(lib.variants[0]).toMatchObject({ id: 'cinematic', label: 'With a cinematic rig' });
    expect(lib.variants[0].example).not.toContain(PHONE);
    expect(lib.variants[0].example).toContain(`Style: ${REALISM}.`);
    const sheet = (await owner.req('POST', '/v1/prompts/preview', { key: 'refs.collage' })).body.example as string;
    expect(sheet).toMatch(/^The input image is a reference sheet .*panels 1–3 show the person .*panel 4 shows the outfit to wear; panel 5 guides the pose & framing and the look & colour and the scene only/);
    expect(sheet).toContain('Identity from 3 locked reference images');
    expect(sheet).toContain('from image 5.');
    expect((await owner.req('POST', '/v1/prompts/preview', { key: 'sheet.task' })).body.variants).toEqual([]);

    const script = async (sid: string) => (await owner.req('POST', '/v1/prompt-scripts/preview', { id: sid })).body;
    const shoot = await script('photoshoot');
    expect(shoot.text).toContain('Identity from 3 locked reference images');
    expect(shoot.text).toContain('Copy the pose and framing from image 5.');
    expect(shoot.text).toContain(`Style: ${E.HOUSE_STYLE}.`);
    expect(shoot.variants[0].text).not.toContain(PHONE);
    expect(shoot.variants[0].text).not.toContain('phone-natural');
    expect(shoot.variants[0].text).toContain(`grade: ${SAMPLE.cinematic.grade}`);
    expect((await script('template')).variants[0].text).toContain(`Style: ${REALISM}.`);
    const house = await script('style.house');
    expect(house.text).toBe(`${PHONE}\n${REALISM}`);
    expect(house.variants[0].text).toBe(REALISM);
    expect((await script('sheet')).variants).toEqual([]);
    const listed = (await owner.req('GET', '/v1/prompt-scripts')).body.scripts;
    expect(listed.find((s: any) => s.id === 'photoshoot').variants).toEqual([{ id: 'cinematic', label: 'With a cinematic rig' }]);
  });
});
