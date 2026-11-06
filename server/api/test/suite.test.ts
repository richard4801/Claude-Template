// AI suite (workstream 1): model registry, quality ladder, Camera compiler, provider inputs, costs and caps, and the
// Shot API end to end on the MOCK provider and on a FAKE Replicate on localhost. No real predictions, no money.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { jobs, ledger } from '../src/db/schema.js';
import { DEFAULT_TEXTS } from '../src/prompt/library.js';
import { cameraCatalog, CameraSpecSchema, MOVES, PRESETS, resolvePreset } from '../src/suite/camera.js';
import { compileCamera } from '../src/suite/compile.js';
import { buildInput } from '../src/suite/inputs.js';
import { buildPlan, billedSeconds, fit, needOf, perSecond, pickModel, ShotRequestSchema, type Character } from '../src/suite/plan.js';
import { SUITE_PROMPT_DEFS, wordings } from '../src/suite/prompts.js';
import { bakePalettes, PALETTE_DIR } from '../scripts/suite-looks.js';
import { OUT as PREVIEWS_OUT, previewsModule } from '../scripts/suite-previews.js';
import { generatedLooks, lutFor, shotLook } from '../src/suite/looks.js';
import { DEFAULT_LADDER, inputSlotsOf, MODELS, modelById, NO_INPUTS, TIERS } from '../src/suite/registry.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const ALL = new Set(['replicate', 'fal', 'mock'] as const);
const CHAR: Character = { name: 'Mia', look: 'young woman, dark hair', neverAdd: ['tattoos'],
  images: [{ label: 'face, front', image: { asset: 'face' } }, { label: 'face, profile', image: { asset: 'profile' } }, { label: 'body, front', image: { asset: 'g_front' } },
    { label: 'body, ¾', image: { asset: 'g_tq' } }, { label: 'body, back', image: { asset: 'g_back' } }],
  outfit: { name: 'Green set', images: [{ label: 'outfit, front', image: { asset: 'g_front' } }, { label: 'outfit, ¾', image: { asset: 'g_tq' } }] } };
const req = (o: Record<string, unknown> = {}) => ShotRequestSchema.parse({ prompt: 'She smiles at the camera.', ...o });
/** Words members must never see. */
const PROVIDER_WORDS = /\b(replicate|fal|runpod|minimax|h3|kling|seedance|veo|wan|ltx|lightricks|bytedance|google|sora)\b/i;

describe('AI suite · registry and ladder (unit)', () => {
  it('every ladder step names a model and resolution that exist, and no blocked model', () => {
    for (const t of TIERS) for (const s of DEFAULT_LADDER[t]) {
      const m = modelById(s.model);
      expect(m, s.model).toBeTruthy();
      expect(m!.resolutions.some(r => r.id === s.resolution), `${s.model} ${s.resolution}`).toBe(true);
      expect(m!.licence.blockNewFeatures ?? false).toBe(false);
      expect(m!.status).not.toBe('removed');
    }
  });
  it('licence flags: the open-weights H3 is blocked for new features; Sora 2 is removed', () => {
    const open = modelById('h3-open')!;
    expect(open.licence).toMatchObject({ kind: 'open-weights', blockNewFeatures: true, territoryExcluded: ['US', 'EU', 'UK', 'KR'], notice: 'Powered by MiniMax H3' });
    expect(fit(open, '768x1344', needOf(req({ modelId: 'x' }), CHAR)).why).toBe('licence');
    expect(modelById('sora-2')!.status).toBe('removed');
    expect(pickModel('standard', needOf(req(), null), { providers: new Set(['runpod']), engineModel: 'h3-open', resolution: '768x1344' })).toMatchObject({ error: 'nothing_fits' });
  });
  it('picks per tier and capability: draft text → H3 Lite; middle keyframes → Kling 4.0; 30 s → nothing on Draft', () => {
    const t = pickModel('draft', needOf(req(), null), { providers: ALL as any });
    expect('model' in t && t.model.id).toBe('h3-lite');
    const mid = pickModel('standard', needOf(req({ frames: { start: { asset: 'face' }, middle: [{ asset: 'g_tq' }], end: { asset: 'g_back' } } }), null), { providers: ALL as any });
    expect('model' in mid && [mid.model.id, mid.resolution.id]).toEqual(['kling-v4', '720p']);
    expect('model' in mid && mid.tried.map(x => x.model)).toEqual(['h3']);
    const long = pickModel('draft', needOf(req({ duration: 30 }), null), { providers: ALL as any });
    expect(long).toMatchObject({ error: 'nothing_fits' });
    const cin = pickModel('cinema', needOf(req({ duration: 30 }), null), { providers: ALL as any });
    expect('model' in cin && cin.model.id).toBe('kling-v4');
  });
  it('owner switches and providers: a switched-off or unconfigured model is skipped', () => {
    const p = pickModel('draft', needOf(req(), null), { providers: ALL as any, prefs: { models: { 'h3-lite': { enabled: false } } } });
    expect('model' in p && p.model.id).toBe('veo-3.1-lite');
    expect('model' in p && p.tried).toEqual([{ model: 'h3-lite', resolution: '768P', why: 'switched off' }]);
    expect(pickModel('draft', needOf(req(), null), { providers: new Set() })).toMatchObject({ error: 'nothing_fits' });
  });
  it('model limits: Veo 1080p only at 8 s, Veo/LTX snap to allowed lengths, a directed shot needs a guide-capable model', () => {
    const veo = modelById('veo-3.1-lite')!;
    expect(fit(veo, '1080p', needOf(req({ duration: 5 }), null)).why).toBe('1080p only at 8 s');
    expect(fit(veo, '720p', needOf(req({ duration: 5 }), null))).toEqual({ why: null, seconds: 6 });
    expect(fit(modelById('ltx-2.3')!, '1080p', needOf(req({ duration: 9 }), null)).seconds).toBe(10);
    const directed = needOf(req({ camera: { mode: 'directed', guide: { video: { url: 'https://x.test/g.mp4' } } } }), null);
    expect(fit(veo, '720p', directed).why).toBe('no guide clip');
    expect(fit(modelById('kling-v4')!, '1080p', directed).why).toBeNull();
  });
});

describe('AI suite · camera compiler (unit)', () => {
  it('presets and the catalog validate; every move has default wording', () => {
    for (const p of PRESETS) expect(CameraSpecSchema.safeParse({ ...p.spec }).success, p.id).toBe(true);
    const w = wordings(DEFAULT_TEXTS['suite.camera.moves'], MOVES);
    for (const m of MOVES) expect(w.get(m.id), m.id).toBeTruthy();
    expect(MOVES.length).toBeGreaterThanOrEqual(30);
    expect(resolvePreset(CameraSpecSchema.parse({ preset: 'cinematic', rig: { focalMm: 85 } })).rig).toMatchObject({ body: 'film_35', focalMm: 85 });
  });
  it('per model: LTX gets camera_motion + fps; tagged blocks drop a mix; a guide clip only where a model takes video', () => {
    const spec = CameraSpecSchema.parse({ move: { id: 'dolly_in', intensity: 1, speed: 'slow' }, mix: { id: 'crane_up', intensity: 0.5 }, rig: { fps: '24', focalMm: 35 }, angle: { height: 'low', shotSize: 'mcu' } });
    const ltx = compileCamera(spec, modelById('ltx-2.3')!, { durationS: 8 });
    expect(ltx.params).toEqual({ camera_motion: 'dolly_in', fps: 24 });
    expect(ltx.moves).toEqual(['dolly_in']);
    expect(ltx.text).toMatch(/^Camera: slow, bold physical dolly-in toward the subject about 2\.0 m/);
    const sd = compileCamera(spec, modelById('seedance-2.5')!, { durationS: 8 });
    expect(sd.text.startsWith('[Camera] ')).toBe(true);
    expect(sd.notes.join()).toMatch(/one camera move per shot/);
    const k = compileCamera(spec, modelById('kling-v4')!, { durationS: 8 });
    expect(k.moves).toEqual(['dolly_in', 'crane_up']);
    expect(k.text).toMatch(/Medium close-up from the chest up, low angle looking up at the subject/);
    const short = compileCamera(spec, modelById('kling-v4')!, { durationS: 4 });
    expect(short.moves).toEqual(['dolly_in']);
    const g = CameraSpecSchema.parse({ guide: { video: { url: 'https://x.test/g.mp4' } } });
    expect(compileCamera(g, modelById('kling-v4')!).usesGuide).toBe(true);
    const v = compileCamera(g, modelById('veo-3.1-lite')!);
    expect(v.usesGuide).toBe(false);
    expect(v.notes.join()).toMatch(/guide clip is not sent/);
    expect(compileCamera(CameraSpecSchema.parse({ move: { id: 'whip_pan' } }), modelById('h3')!).notes.join()).toMatch(/editor effect/);
    expect(compileCamera(CameraSpecSchema.parse({ move: { id: 'orbit_360' } }), modelById('h3')!, { talking: true }).notes.join()).toMatch(/fight lip sync/);
    expect(compileCamera(CameraSpecSchema.parse({ move: { id: 'handheld' } }), modelById('h3')!, { talking: true }).notes).toEqual([]);
    expect(() => CameraSpecSchema.parse({ move: { id: 'teleport' } })).toThrow();
  });
  it('owner wording overrides change what is sent (and a deleted line falls back)', () => {
    const t = { ...DEFAULT_TEXTS, 'suite.camera.moves': 'dolly_in: the camera glides in {amount}\nnonsense line' };
    const c = compileCamera(CameraSpecSchema.parse({ move: { id: 'dolly_in', intensity: 0 } }), modelById('h3')!, { texts: t });
    expect(c.text).toMatch(/Subtle the camera glides in about 0\.8 m/);
    const c2 = compileCamera(CameraSpecSchema.parse({ move: { id: 'orbit_left', intensity: 0 } }), modelById('h3')!, { texts: t });
    expect(c2.text).toMatch(/orbits around the subject to the left about 60°/);
    for (const d of SUITE_PROMPT_DEFS) expect(d.group).toBe('suite');
  });
});

describe('AI suite · plans, inputs and prices (unit)', () => {
  const plan = (id: string, res: string, r: ReturnType<typeof req>, ch: Character | null = CHAR) => {
    const m = modelById(id)!;
    const n = needOf(r, ch);
    return buildPlan(r, n, { model: m, resolution: m.resolutions.find(x => x.id === res)!, seconds: fit(m, res, n).seconds, tried: [] }, ch, {});
  };
  it('H3: the character subset (≤ 9, face first), <Image n> tokens, ratio and the price', () => {
    const p = plan('h3', '768P', req({ modelId: 'm', duration: 6 }));
    expect(p.images.refs.map(x => x.label)).toEqual(['face, front', 'face, profile', 'body, front', 'body, ¾', 'body, back', 'outfit, front', 'outfit, ¾']);
    expect(p.prompt).toMatch(/^Mia is the woman shown in <Image 1>, <Image 2>, <Image 3>, <Image 4> and <Image 5>/);
    expect(p.prompt).toMatch(/She wears Green set as shown in <Image 6> and <Image 7>\./);
    expect(p.estimate).toBeCloseTo(0.48, 6);
    const i = buildInput(modelById('h3')!, p, { middle: [], refs: p.images.refs.map((_, k) => `u${k}`), videos: [] });
    expect(i).toMatchObject({ duration: 6, resolution: '768P', ratio: '9:16', reference_image_urls: ['u0', 'u1', 'u2', 'u3', 'u4', 'u5', 'u6'] });
    expect(i).not.toHaveProperty('first_frame_image');
  });
  it('Kling 4.0: @image tokens, middle keyframes count toward 10 images, guide clip → reference_videos and the video price', () => {
    const r = req({ modelId: 'm', frames: { start: { asset: 'face' }, middle: [{ asset: 'g_tq' }, { asset: 'g_side' }], end: { asset: 'g_back' } },
      camera: { guide: { video: { key: 'cam/g.mp4', seconds: 6 }, use: 'camera' } }, quality: 'cinema', duration: 6 });
    const p = plan('kling-v4', '1080p', r);
    expect(p.images.refs.length).toBe(6); // 10 − 4 frames
    expect(p.images.refs[0]!.label).toBe('face, front');
    expect(p.prompt).toMatch(/@image_1/);
    expect(p.prompt).toMatch(/Take the camera movement and framing from @video_1/);
    expect(p.perSec).toBe(0.141);
    expect(p.billedPerTake).toBe(12);
    const i = buildInput(modelById('kling-v4')!, p, { start: 's', middle: ['m1', 'm2'], end: 'e', refs: p.images.refs.map((_, k) => `r${k}`), videos: ['v'] });
    expect(i).toMatchObject({ start_image: 's', middle_images: ['m1', 'm2'], end_image: 'e', reference_videos: ['v'], resolution: '1080p', aspect_ratio: '9:16', duration: 6 });
  });
  it('Seedance: frames exclude references (adaptive ratio), [Image1] tokens otherwise; 2.5 video refs cost ~4×', () => {
    const f = plan('seedance-2.0', '720p', req({ modelId: 'm', frames: { start: { asset: 'face' } } }));
    expect(f.images.refs).toEqual([]);
    expect(f.notes.join()).toMatch(/keyframes carry the look/);
    expect(buildInput(modelById('seedance-2.0')!, f, { start: 's', middle: [], refs: [], videos: [] })).toMatchObject({ image: 's', aspect_ratio: 'adaptive', generate_audio: true });
    const r = plan('seedance-2.0', '720p', req({ modelId: 'm' }));
    expect(r.prompt).toMatch(/\[Image1\]/);
    expect(perSecond(modelById('seedance-2.5')!, modelById('seedance-2.5')!.resolutions[1]!, { videoInput: true, audio: true, kind: 'ref2v' })).toBe(0.9676);
  });
  it('Wan / LTX / Veo field names; fal 5-second minimum; negative prompt only where a model has one', () => {
    const w = plan('wan-2.7', '1080p', req({ frames: { start: { asset: 'face' }, end: { asset: 'g_back' } } }), null);
    expect(w.kind).toBe('i2v');
    expect(w.ref).toBe('wan-video/wan-2.7-i2v');
    expect(w.perSec).toBe(0.15);
    expect(w.negative).toMatch(/watermark/);
    expect(buildInput(modelById('wan-2.7')!, w, { start: 's', end: 'e', middle: [], refs: [], videos: [] })).toMatchObject({ first_frame: 's', last_frame: 'e' });
    const l = plan('ltx-2.3', '1080p', req({ camera: { move: { id: 'crane_up' } }, duration: 8 }), null);
    expect(buildInput(modelById('ltx-2.3')!, l, { middle: [], refs: [], videos: [] })).toMatchObject({ task: 'text_to_video', camera_motion: 'jib_up', duration: 8 });
    expect(l.negative).toBeUndefined();
    const v = plan('veo-3.1-lite', '720p', req({ frames: { start: { asset: 'face' } } }), null);
    expect(buildInput(modelById('veo-3.1-lite')!, v, { start: 's', middle: [], refs: [], videos: [] })).toMatchObject({ image: 's', duration: 6, resolution: '720p' });
    expect(billedSeconds(modelById('h3-max-3d')!, 3, { videoInput: true })).toBe(5);
  });
  it('prompts never name a provider or model', () => {
    for (const m of MODELS.filter(x => x.status !== 'removed' && !x.licence.blockNewFeatures && x.modes.reference)) {
      const p = plan(m.id, m.resolutions[0]!.id, req({ modelId: 'm', camera: { preset: 'music_video' } }));
      expect(p.prompt, m.id).not.toMatch(PROVIDER_WORDS);
    }
  });
});

describe('AI suite · composer catalogue (visible, merged)', () => {
  const cat = cameraCatalog();
  const shown = (l: { id: string; visible?: boolean; label: string }[]) => l.filter(x => x.visible).map(x => x.label);
  it('members see the composer lists; merged and hidden ids stay in the API', () => {
    expect(shown(cat.bodies)).toEqual(['Phone', 'Creator camera', 'Cinema camera', '35mm film', '16mm film', 'Super 8', 'Large format 65mm', 'DV camcorder', 'Webcam', 'CCTV']);
    expect(shown(cat.lenses)).toEqual(['Clean sharp', 'Warm vintage', 'Anamorphic', 'Vintage anamorphic', 'Halation', 'Swirl bokeh', 'Macro', 'Tilt-shift', 'Fisheye']);
    expect(cat.focals.filter(f => f.visible).map(f => f.mm)).toEqual([14, 24, 35, 50, 85, 135]);
    expect(cat.apertures.filter(a => a.visible).map(a => `${a.label} ${a.description}`)).toEqual(['f/1.4 Dreamy blur', 'f/2.8 Soft background', 'f/5.6 Natural', 'f/11 Everything sharp']);
    expect(shown(cat.frameRates)).toEqual([]);
    expect(shown(cat.shutters)).toEqual([]);
    expect(cat.tempos.map(t => t.label)).toContain('Slow motion');
    expect(cat.moves.find(m => m.id === 'motion_blur')).toMatchObject({ label: 'Motion blur streaks', group: 'special' });
    expect(Object.fromEntries(cat.bodies.filter(b => b.mergedInto).map(b => [b.id, b.mergedInto]))).toEqual({ super35: 'cinema_digital', modular_8k: 'cinema_digital', full_frame_cine: 'cinema_digital', creator_cine: 'vlog' });
    expect(cat.lenses.find(l => l.id === 'vintage')?.mergedInto).toBe('warm_vintage');
    expect(cat.lenses.find(l => l.id === 'cine_zoom')).toMatchObject({ visible: false });
    // Every visible hardware option has a render (some are stand-ins until their own stills exist).
    for (const b of [...cat.bodies, ...cat.lenses].filter(x => x.visible)) expect((b as { render?: string }).render, b.id).toBeTruthy();
    expect(cat.moveGroups.map(g => g.label)).toEqual(['Featured', 'UGC', 'Push', 'Pan & tilt', 'Orbit', 'Crane', 'Follow', 'Aerial', 'Special']);
    for (const m of cat.moves) expect(cat.moveGroups.map(g => g.id)).toContain(m.group);
  });
  it('old ids still validate and compile as their survivor', () => {
    const model = modelById('h3')!;
    const old = compileCamera(CameraSpecSchema.parse({ rig: { body: 'super35', lens: 'vintage' } }), model);
    const now = compileCamera(CameraSpecSchema.parse({ rig: { body: 'cinema_digital', lens: 'warm_vintage' } }), model);
    expect(old.text).toBe(now.text);
    expect(old.text).toContain('clean digital cinema camera');
    // Hidden (not merged) ids compile as themselves.
    expect(compileCamera(CameraSpecSchema.parse({ rig: { aperture: 'f2', fps: '60' } }), model).text).toMatch(/f\/2, shallow depth of field.*60 fps/);
    // UGC ad formats: in the catalog, and in the Style part of the prompt.
    expect(cat.ugcFormats.map(f => f.id)).toEqual(['unboxing', 'review', 'try_on', 'before_after', 'grwm', 'haul', 'tutorial', 'testimonial']);
    expect(compileCamera(CameraSpecSchema.parse({ style: { format: 'unboxing', genre: 'ugc' } }), model).text).toMatch(/unboxing video[^.]*first genuine reaction/i);
    expect(compileCamera(CameraSpecSchema.parse({ style: { tempo: 'slow_motion' }, move: { id: 'motion_blur' } }), model).text).toMatch(/streaking motion blur[\s\S]*slow motion|slow motion[\s\S]*streaking motion blur/);
  });
});

describe('AI suite · composer previews', () => {
  it('the catalogue names each move, lighting and angle preview (generated file matches design/previews/manifest.tsv)', () => {
    expect(fs.readFileSync(PREVIEWS_OUT, 'utf8'), 'run npx tsx scripts/suite-previews.ts').toBe(previewsModule());
    const cat = cameraCatalog();
    expect(cat.moves.find(m => m.id === 'dolly_in')?.preview).toEqual({ video: 'moves/dolly_in.mp4', poster: 'moves/dolly_in.jpg', seconds: 2.5 });
    expect(cat.moves.filter(m => !m.preview).map(m => m.id)).toEqual(['motion_blur']); // no loop yet: the apps draw the still
    expect(cat.lighting.every(l => l.preview?.poster === `lighting/${l.id}.jpg`)).toBe(true);
    expect([...cat.heights, ...cat.shotSizes].every(a => a.preview?.poster === `angles/${a.id}.jpg`)).toBe(true);
    expect(cat.autoPreviews.lighting).toEqual({ poster: 'lighting/auto.jpg' });
    for (const p of [...cat.moves, ...cat.lighting, ...cat.heights, ...cat.shotSizes].flatMap(x => x.preview ? [x.preview.poster, x.preview.video].filter(Boolean) : []))
      expect(fs.existsSync(path.resolve(__dirname, '../../../design/previews', p!)), p).toBe(true);
  });
});

describe('AI suite · Look grading', () => {
  it('every palette and film stock names a LUT: a pack twin, else one generated from its swatches (committed files match)', () => {
    const cat = cameraCatalog();
    for (const x of [...cat.palettes, ...cat.looks]) {
      expect(x.swatches, x.id).toHaveLength(5);
      expect(x.lut, x.id).toMatch(/^(pack|palette):/);
    }
    expect(lutFor('palettes', 'teal_orange')).toBe('pack:cine-teal-orange');
    expect(lutFor('palettes', 'hyper_neon')).toBe('palette:hyper_neon');
    expect(lutFor('looks', 'cross_process')).toBe('palette:stock-cross_process');
    const files = bakePalettes();
    for (const [n, body] of Object.entries(files)) expect(fs.readFileSync(path.join(PALETTE_DIR, n), 'utf8'), `${n}: run npx tsx scripts/suite-looks.ts`).toBe(body);
    expect(fs.readdirSync(PALETTE_DIR).filter(f => f.endsWith('.cube'))).toHaveLength(generatedLooks().length);
    for (const l of [...cat.palettes, ...cat.looks].filter(x => x.lut!.startsWith('palette:'))) expect(fs.existsSync(path.join(PALETTE_DIR, `${l.lut!.slice(8)}.cube`)), l.id).toBe(true);
  });
  it("a shot's look: the palette, else the film stock (presets included); none when grading is off", () => {
    expect(shotLook(CameraSpecSchema.parse({ palette: { preset: 'hyper_neon' }, rig: { look: 'slide_film' } }), true)).toEqual({ id: 'hyper_neon', kind: 'palette', label: 'Hyper neon', lut: 'palette:hyper_neon' });
    expect(shotLook(CameraSpecSchema.parse({ rig: { look: 'slide_film' } }), true)).toMatchObject({ kind: 'stock', lut: 'pack:film-chrome' });
    expect(shotLook(resolvePreset(CameraSpecSchema.parse({ preset: 'noir' })), true)).toMatchObject({ id: 'low_key_noir', lut: 'pack:cine-noir' });
    expect(shotLook(CameraSpecSchema.parse({ palette: { preset: 'hyper_neon' } }), false)).toBeNull();
    expect(shotLook(CameraSpecSchema.parse({ move: { id: 'static' } }), true)).toBeNull();
  });
});

describe('AI suite · input slots', () => {
  it('a tier takes what any of its models takes, capped to what a shot request can carry', () => {
    expect(inputSlotsOf([])).toEqual(NO_INPUTS);
    const kling = modelById('kling-o1')!; // recast-only: no keyframes
    expect(inputSlotsOf([kling])).toMatchObject({ start: false, end: false, middle: 0 });
    const many = MODELS.find(m => m.frames.middle >= 8 && m.modes.image)!;
    const s = inputSlotsOf([kling, many]);
    expect(s).toMatchObject({ start: true, end: true, middle: 8 });
    expect(inputSlotsOf(MODELS).images).toBe(6);
    expect(inputSlotsOf(MODELS).videos).toBe(3);
    const noRefs = MODELS.find(m => m.modes.image && m.refs.images === 0 && m.refs.audios === 0)!;
    expect(inputSlotsOf([noRefs])).toMatchObject({ start: true, images: 0, videos: 0, audio: false, framesWithRefs: false });
  });
});

describe.skipIf(!hasFfmpeg)('AI suite · Shot API on the mock provider', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, model: { id: string };
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    model = await demoModel(owner);
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: member.id, tokens: 2000 });
  });
  afterAll(async () => { await a?.close(); });
  const done = (id: string) => until(async () => { const j = (await owner.req('GET', `/v1/suite/shots/${id}`)).body.job; return j?.state === 'done' || j?.state === 'failed' ? j : null; }, 20_000);

  it('catalog: tiers and camera for members (no engines); the owner also sees the models per tier', async () => {
    const m = (await member.req('GET', '/v1/suite/catalog')).body;
    expect(m.tiers.map((t: any) => [t.id, t.label, t.available])).toEqual([['draft', 'Draft', true], ['standard', 'Standard', true], ['hd', 'HD', true], ['cinema', 'Cinema', true]]);
    expect(m.test).toBe(true);
    expect(m.camera.moves.length).toBeGreaterThanOrEqual(30);
    expect(JSON.stringify(m.tiers)).not.toMatch(PROVIDER_WORDS);
    const o = (await owner.req('GET', '/v1/suite/catalog')).body;
    expect(o.tiers[0].models[0]).toMatchObject({ model: 'h3-lite', name: 'MiniMax H3 Lite', resolution: '768P' });
    // Input slots: member-safe numbers per tier (the apps show a slot only when the tier takes it); per model for the owner.
    for (const t of m.tiers) expect(Object.keys(t.inputs).sort()).toEqual(['audio', 'end', 'framesWithRefs', 'images', 'middle', 'start', 'videos']);
    expect(m.tiers[0].inputs).toMatchObject({ start: true, end: true, images: 6, videos: 3, audio: true });
    expect(m.tiers.map((t: any) => [t.minSeconds, t.maxSeconds])).toEqual([[2, 15], [2, 30], [3, 30], [3, 30]]);
    expect(m.tools).toEqual([{ id: 'shot', available: true }, { id: 'swap', available: true }, { id: 'recast', available: true }, { id: 'storyboard', available: true },
      { id: 'talking', available: true }, { id: 'ugc_ad', available: true }, { id: 'extend', available: false, comingSoon: true }, { id: 'photo', available: true }]);
    expect(o.tiers[0].models[0].inputs).toEqual({ start: true, end: true, middle: 0, images: 6, videos: 3, audio: true, framesWithRefs: true });
  });

  it('estimate: price, caps and warnings for a member; the owner also gets the engine and the inputs', async () => {
    const body = { modelId: model.id, prompt: 'She waves at the camera.', duration: 6, quality: 'hd', camera: { preset: 'phone_ugc' } };
    const e = (await member.req('POST', '/v1/suite/shots/estimate', body)).body;
    expect(e).toMatchObject({ quality: 'hd', label: 'Shot · HD · 2K', seconds: 6, estimate: 0.78, priceLine: 'about $0.78 · 6 s', ok: true, mode: 'reference', test: true });
    expect(JSON.stringify(e)).not.toMatch(PROVIDER_WORDS);
    const o = (await owner.req('POST', '/v1/suite/shots/estimate', body)).body;
    expect(o.engine).toMatchObject({ model: 'h3', provider: 'replicate', ref: 'minimax/h3', resolution: '2K', perSec: 0.13 });
    expect((await member.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'kling-v4' })).status).toBe(403);
    const none = await owner.req('POST', '/v1/suite/shots/estimate', { prompt: 'x', duration: 30, quality: 'draft' });
    expect(none.status).toBe(400);
    expect(none.body.code).toBe('nothing_fits');
    expect(none.body.tried.length).toBe(5);
    const nm = await member.req('POST', '/v1/suite/shots/estimate', { prompt: 'x', duration: 30, quality: 'draft' });
    expect(nm.body.tried).toBeUndefined();
    // Look grading: the estimate names the take's Look (off with gradeLook: false).
    const lk = (await member.req('POST', '/v1/suite/shots/estimate', { ...body, camera: { preset: 'cinematic' } })).body;
    expect(lk.look).toEqual({ id: 'teal_orange', kind: 'palette', label: 'Teal & orange', lut: 'pack:cine-teal-orange' });
    expect((await member.req('POST', '/v1/suite/shots/estimate', { ...body, camera: { preset: 'cinematic' }, gradeLook: false })).body.look).toBeNull();
  });

  it('a shot runs on the mock: hold → takes delivered as made → settle $0 (test render), with real inputs recorded', async () => {
    const before = a.ctx.suite.mock.calls.length;
    const r = await member.req('POST', '/v1/suite/shots', { modelId: model.id, prompt: 'She laughs.', duration: 5, takes: 2, aspectRatio: '9:16', camera: { move: { id: 'dolly_in', intensity: 0.5 }, palette: { preset: 'hyper_neon' } } });
    expect(r.status).toBe(200);
    expect(r.body.request).toMatchObject({ engine: 'suite', engineLabel: 'Shot · Draft · 768p', quality: 'draft', seconds: 5, takes: 2 });
    expect(r.body.engineLabel).toBe('Shot · Draft · 768p');
    expect(JSON.stringify(r.body)).not.toMatch(PROVIDER_WORDS);
    const j = await done(r.body.id);
    expect(j.state).toBe('done');
    const calls = a.ctx.suite.mock.calls.slice(before);
    expect(calls.length).toBe(2);
    expect(calls[0]!.ref).toBe('minimax/h3-lite');
    expect(calls[0]!.input).toMatchObject({ duration: 5, resolution: '768P', ratio: '9:16' });
    expect((calls[0]!.input.reference_image_urls as string[]).length).toBeGreaterThanOrEqual(5);
    const takes = (await member.req('GET', '/v1/takes')).body.filter((t: any) => t.jobId === r.body.id);
    expect(takes.length).toBe(2);
    expect(takes[0]).toMatchObject({ label: 'Draft', engineLabel: 'Shot · Draft · 768p', durationSec: 5, width: 180, height: 320 });
    expect(takes[0].videoUrl).toMatch(/\/uploads\/s\//);
    // Look grading: the job request and every take carry the Look (the Edit suite opens with it applied).
    const look = { id: 'hyper_neon', kind: 'palette', label: 'Hyper neon', lut: 'palette:hyper_neon' };
    expect(r.body.request.look).toEqual(look);
    for (const t of takes) expect(t.look).toEqual(look);
    const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, r.body.id));
    expect(rows.find(x => x.kind === 'hold')!.note).toBe('Video · Shot · Draft · 768p · 5 s · 2 takes · hold');
    const settle = rows.find(x => x.kind === 'settle')!;
    expect(settle.amountUsd).toBe(0);
    expect(settle.note).toBe('Video · Shot Draft 768p · 2 × 5 s · test render');
    const s = (await owner.req('GET', `/v1/suite/shots/${r.body.id}`)).body;
    expect(s.engine).toMatchObject({ model: 'h3-lite', test: true });
    expect((await member.req('GET', `/v1/suite/shots/${r.body.id}`)).body.engine).toBeUndefined();
  });

  it('dryRun plans and prices without a job; failures and refusals refund in full', async () => {
    const n0 = (await a.ctx.db.select().from(jobs)).length;
    const d = (await member.req('POST', '/v1/suite/shots', { prompt: 'A city at night.', dryRun: true })).body;
    expect(d.dryRun).toBe(true);
    expect(d.estimate.mode).toBe('text');
    expect((await a.ctx.db.select().from(jobs)).length).toBe(n0);
    a.ctx.suite.mock.failNext = 1;
    const f = await done((await member.req('POST', '/v1/suite/shots', { prompt: 'A city at night.' })).body.id);
    expect(f).toMatchObject({ state: 'failed', errorCode: 'provider_failed', error: "Something went wrong · you weren't charged" });
    expect(f.refunded).toBe(f.cost);
    a.ctx.suite.mock.refuseNext = 1;
    const g = await done((await member.req('POST', '/v1/suite/shots', { prompt: 'A city at night.' })).body.id);
    expect(g).toMatchObject({ state: 'failed', errorCode: 'provider_refused' });
  });

  it('cancel: deleting a running shot stops it and returns the hold', async () => {
    a.ctx.suite.mock.pollsToFinish = 10_000;
    try {
      const r = (await member.req('POST', '/v1/suite/shots', { prompt: 'Slow waves.' })).body;
      await until(async () => a.ctx.suite.mock.calls.some(c => (c.input.prompt as string).includes('Slow waves.')));
      expect((await member.req('DELETE', `/v1/jobs/${r.id}`)).status).toBe(204);
      const [row] = await a.ctx.db.select().from(jobs).where(eq(jobs.id, r.id));
      expect(row).toMatchObject({ state: 'failed', gpuState: 'cancelled' });
      await until(() => a.ctx.suite.mock.calls.find(c => (c.input.prompt as string).includes('Slow waves.'))?.cancelled);
    } finally { a.ctx.suite.mock.pollsToFinish = 1; }
  });

  it('settings: caps refuse a shot, licence-blocked models stay off, the ladder is owner-editable', async () => {
    expect((await member.req('GET', '/v1/suite/settings')).status).toBe(403);
    const s = (await owner.req('GET', '/v1/suite/settings')).body;
    expect(s.mode).toBe('mock');
    expect(s.models.find((m: any) => m.id === 'h3-open')).toMatchObject({ blocked: true, enabled: false, blockedReason: 'Licence: not for new features' });
    expect((await owner.req('PATCH', '/v1/suite/settings', { models: { 'h3-open': { enabled: true } } })).body.code).toBe('model_blocked');
    await owner.req('PATCH', '/v1/suite/settings', { capPerJob: 0.05 });
    const big = await member.req('POST', '/v1/suite/shots', { prompt: 'x', quality: 'cinema', duration: 10 });
    expect(big.status).toBe(402);
    expect(big.body.code).toBe('suite_over_job_limit');
    const est = (await member.req('POST', '/v1/suite/shots/estimate', { prompt: 'x', quality: 'cinema', duration: 10 })).body;
    expect(est).toMatchObject({ ok: false, code: 'suite_over_job_limit' });
    await owner.req('PATCH', '/v1/suite/settings', { capPerJob: null, ladder: { draft: [{ model: 'veo-3.1-lite', resolution: '720p' }] } });
    const o = (await owner.req('POST', '/v1/suite/shots/estimate', { prompt: 'x', duration: 6 })).body;
    expect(o.engine.model).toBe('veo-3.1-lite');
    expect((await owner.req('PATCH', '/v1/suite/settings', { ladder: { draft: [{ model: 'nope', resolution: 'x' }] } })).status).toBe(400);
    await owner.req('PATCH', '/v1/suite/settings', { ladder: null });
  });

  it('camera compile endpoint and owner wording overrides from the prompt library', async () => {
    const c = (await member.req('POST', '/v1/suite/camera/compile', { camera: { move: { id: 'orbit_left', intensity: 1 } }, quality: 'cinema' })).body;
    expect(c.text).toMatch(/orbits around the subject to the left about 180°/);
    expect(c.engine).toBeUndefined();
    const lib = (await owner.req('GET', '/v1/prompts')).body;
    expect(lib.groups.some((g: any) => g.id === 'suite')).toBe(true);
    expect((await owner.req('PUT', '/v1/prompts/suite.camera.moves', { text: 'orbit_left: the camera circles her {amount}' })).status).toBe(200);
    const c2 = (await member.req('POST', '/v1/suite/camera/compile', { camera: { move: { id: 'orbit_left', intensity: 1 } }, quality: 'cinema' })).body;
    expect(c2.text).toMatch(/the camera circles her about 180°/);
    await owner.req('DELETE', '/v1/prompts/suite.camera.moves');
    expect((await member.req('GET', '/v1/suite/camera')).body.presets.length).toBe(PRESETS.length);
    const tg = (await member.req('GET', '/v1/suite/targets')).body;
    expect(tg.map((x: any) => x.quality)).toEqual(['draft', 'standard', 'hd', 'cinema']);
    expect(tg[3]).toMatchObject({ available: true, maxSeconds: 30, guideSeconds: { min: 3, max: 30 }, shortSide: 1080, keyframes: { middle: 8 } });
    expect(JSON.stringify(tg)).not.toMatch(PROVIDER_WORDS);
    expect((await owner.req('GET', '/v1/suite/targets')).body[3].model).toBe('kling-v4');
  });

  it('beat-only audio in a test render sends no audio (never the track with vocals) and uses the no-audio prompt', async () => {
    const [o] = await a.ctx.db.execute((await import('drizzle-orm')).sql`select studio_id from users where id = ${owner.id}`).then((r: any) => r.rows ?? r);
    const { putObject } = await import('../src/storage/objects.js');
    await putObject(a.ctx, { key: 'up/mock-song.m4a', body: Buffer.from('not really audio'), studioId: o.studio_id, kind: 'clip', contentType: 'audio/mp4' });
    const before = a.ctx.suite.mock.calls.length;
    const r = (await owner.req('POST', '/v1/suite/shots', { modelId: model.id, speaking: false, prompt: 'She dances.', references: { audio: { audio: { key: 'up/mock-song.m4a' } } } })).body;
    expect(r.prompt).toMatch(/moves to the beat of <Audio 1>/);
    const j = await done(r.id);
    expect(j.state).toBe('done');
    const call = a.ctx.suite.mock.calls.slice(before)[0]!;
    expect(call.input.audio).toBeUndefined();
    expect(call.input.prompt).toMatch(/does not speak, sing or mouth words/);
    expect(j.prompt).toMatch(/does not speak, sing or mouth words/);
  });

  it('swap is a suite mode over the existing engine (unavailable without Replicate)', async () => {
    const r = await member.req('POST', '/v1/suite/shots/estimate', { mode: 'swap', modelId: model.id, clipId: 'c_missing' });
    expect(r.status).toBe(400);
    expect(r.body.code).toBe('engine_unavailable');
  });
});

describe.skipIf(!hasFfmpeg)('AI suite · live mode against a FAKE Replicate (no money)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, server: http.Server, dir: string;
  const creates: { model: string; input: any }[] = [];
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-suite-fake-'));
    const file = path.join(dir, 'out.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=288x512:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', file]);
    server = http.createServer((q, res) => {
      let body = '';
      q.on('data', c => (body += c));
      q.on('end', () => {
        const url = q.url ?? '';
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (url === '/out.mp4') { res.writeHead(200, { 'content-type': 'video/mp4' }); fs.createReadStream(file).pipe(res); return; }
        if (q.headers.authorization !== 'Bearer r8_suite') return json(401, {});
        const m = /^\/v1\/models\/([^/]+\/[^/]+)\/predictions$/.exec(url);
        if (m && q.method === 'POST') { creates.push({ model: m[1]!, input: JSON.parse(body).input }); return json(201, { id: `p${creates.length}`, status: 'starting' }); }
        if (/^\/v1\/predictions\/p\d+$/.test(url)) {
          const port = (server.address() as any).port;
          return json(200, { id: 'p', status: 'succeeded', output: `http://127.0.0.1:${port}/out.mp4`, metrics: { video_output_duration_seconds: 6 } });
        }
        json(404, {});
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    a = await makeApp({ SUITE_MODE: 'live', SUITE_POLL_MS: '10', REPLICATE_API_TOKEN: 'r8_suite', REPLICATE_API_URL: `http://127.0.0.1:${(server.address() as any).port}/v1`,
      REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated' });
    ({ owner } = await people(a, 0, { topUp: 100 }));
  });
  afterAll(async () => { await a?.close(); server?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  it('runs on the provider, settles to price × billed seconds, keeps the take exactly as delivered; fal-only models are skipped without a key', async () => {
    const m = await demoModel(owner);
    const r = (await owner.req('POST', '/v1/suite/shots', { modelId: m.id, prompt: 'She turns to the camera.', duration: 6, quality: 'standard', camera: { preset: 'talking_head' } })).body;
    const j = await until(async () => { const x = (await owner.req('GET', `/v1/suite/shots/${r.id}`)).body.job; return x?.state === 'done' || x?.state === 'failed' ? x : null; }, 20_000);
    expect(j.state).toBe('done');
    expect(creates[0]).toMatchObject({ model: 'minimax/h3', input: { duration: 6, resolution: '768P', ratio: '9:16' } });
    expect(creates[0]!.input.prompt).toMatch(/Locked-off static camera/i);
    const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, r.id))).find(x => x.kind === 'settle')!;
    expect(settle.amountUsd).toBeCloseTo(0.48, 6);
    expect(settle.note).toBe('Video · Shot Standard 768p · 6 s');
    const take = (await owner.req('GET', '/v1/takes')).body.find((t: any) => t.jobId === r.id);
    expect([take.width, take.height, take.durationSec]).toEqual([288, 512, 6]);
    const st = (await owner.req('GET', '/v1/suite/settings')).body;
    expect(st.models.find((x: any) => x.id === 'h3-max-3d').configured).toBe(false);
    const g = await owner.req('POST', '/v1/suite/shots/estimate', { prompt: 'x', engineModel: 'h3-max-3d', resolution: '768P', camera: { mode: 'directed', guide: { video: { url: 'https://x.test/g.mp4' } } } });
    expect(g.body.code).toBe('nothing_fits');
  });
});
