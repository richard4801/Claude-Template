// AI suite · Photo tool (workstream 3): the composer's rig compiled for a still, the rig-check subset, and the routes on
// the shoot pipeline (same count and price as a shoot; /v1/shoots unchanged). Fake image engine, no money.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CameraSpecSchema, type CameraSpecInput } from '../src/suite/camera.js';
import { PhotoRequestSchema, photoFilter, photoPrompt, photoRigCheck, stillRig } from '../src/suite/photo.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

const cam = (c: CameraSpecInput) => CameraSpecSchema.parse(c);
const PROVIDER_WORDS = /\b(replicate|fal|runpod|minimax|h3|kling|seedance|veo|wan|ltx|google|sora|openai|gemini|flux|seedream|nano)\b/i;

describe('Photo tool · the rig for a still', () => {
  it('compiles camera, lens, focal, aperture, angle, lighting, look and style; drops movement and tempo with a note', () => {
    const r = stillRig({ prompt: 'She leans on the balcony rail at dusk. #Dolly in', camera: cam({
      rig: { body: 'film_35', lens: 'anamorphic', focalMm: 85, aperture: 'f1.4', look: 'portrait_negative', fps: '24' },
      lighting: { preset: 'contre_jour', direction: 'back', temperatureK: 3200 }, palette: { preset: 'golden_warmth' },
      angle: { height: 'low', shotSize: 'mcu', dutchDeg: 10 }, style: { genre: 'fashion', era: '1990s', tempo: 'calm' },
      performance: { emotion: 'calm', to: 'joy' }, move: { id: 'dolly_in' } }) });
    expect(r.scene).toBe('She leans on the balcony rail at dusk.');
    expect(r.camera).toEqual({ shot: 'medium close-up', lensMm: 85, aperture: 'f/1.4' });
    expect(r.light).toBe('contre-jour backlight, glowing hair rim, slight haze, from the back, 3200K');
    expect(r.grade).toBe('portrait colour-negative film stock, soft warm skin tones, pastel highlights, honey-gold warm palette');
    expect(r.direction).toBe('Shot on 35mm motion-picture film, fine grain, gentle halation, organic colour; anamorphic lens, oval bokeh, horizontal blue lens flares; '
      + 'low angle looking up at the subject; canted 10° Dutch angle; editorial fashion film photograph; 1990s era; expression: calm turning to joy.');
    expect(r.notes).toEqual(['Movement doesn’t apply to photos', 'Tempo doesn’t apply to photos']);
  });

  it('Auto stays Auto (the library defaults), presets and merged ids resolve, #move tokens leave the prompt', () => {
    expect(stillRig({ prompt: '', camera: undefined })).toEqual({ scene: undefined, notes: [] });
    expect(stillRig({ prompt: 'x', camera: cam({}) })).toEqual({ scene: 'x', camera: undefined, light: undefined, grade: undefined, direction: undefined, notes: [] });
    const p = stillRig({ prompt: '', camera: cam({ preset: 'cinematic' }) });
    expect(p.camera).toEqual({ shot: 'medium close-up', lensMm: 50, aperture: 'f/2' });
    expect(p.notes).toEqual(['Tempo doesn’t apply to photos']); // the preset's move isn't the member's, so no movement note
    expect(stillRig({ prompt: '', camera: cam({ rig: { body: 'super35' } }) }).direction).toMatch(/^Shot on clean digital cinema camera/);
    expect(stillRig({ prompt: '', camera: cam({ rig: { aperture: 'f8' } }) }).camera).toEqual({ shot: 'medium', lensMm: 35, aperture: 'f/8' });
    expect(photoPrompt('#Rack focus She smiles #Orbit left.')).toBe('She smiles .');
  });

  it('runs only the still rules of the rig check', () => {
    const w = photoRigCheck({ prompt: 'Open on the street, pan left. A wide shot.', camera: cam({ rig: { body: 'phone', aperture: 'f1.4', focalMm: 14 }, angle: { shotSize: 'cu', height: 'worm' },
      move: { id: 'rack_focus' } }) });
    expect(w.map(x => x.id).sort()).toEqual(['deep_focus', 'prompt_size', 'wide_close', 'worm_close']);
    expect(w.find(x => x.id === 'deep_focus')!.reason).toBe('Phone keeps everything in focus, so f/1.4 won’t blur the background');
    expect(photoRigCheck({ prompt: '', camera: cam({ rig: { look: 'bw_film' }, palette: { preset: 'hyper_neon' } }) }).map(x => x.id)).toEqual(['look_clash']);
    expect(photoRigCheck({ prompt: 'reveal her', camera: cam({ move: { id: 'orbit_left' } }) })).toEqual([]);
  });

  it('grades with the Look chip unless switched off', () => {
    expect(photoFilter({ camera: cam({ palette: { preset: 'teal_orange' } }), gradeLook: true })!.filter.lut).toMatch(/^(pack|palette):/);
    expect(photoFilter({ camera: cam({ palette: { preset: 'teal_orange' } }), gradeLook: false })).toBeNull();
    expect(photoFilter({ camera: undefined, gradeLook: true })).toBeNull();
    expect(PhotoRequestSchema.parse({ modelId: 'm' })).toMatchObject({ count: 4, gradeLook: true, prompt: '' });
    expect(PhotoRequestSchema.safeParse({ modelId: 'm', count: 5 }).success).toBe(false);
    expect(PhotoRequestSchema.safeParse({ modelId: 'm', duration: 5 }).success).toBe(false);
  });
});

describe('Photo tool · routes (fake image engine)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, model: any;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    model = await demoModel(owner);
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: member.id, tokens: 2000 });
  });
  afterAll(async () => { await a?.close(); });

  it('the catalog offers Photo', async () => {
    expect((await member.req('GET', '/v1/suite/catalog')).body.tools).toContainEqual({ id: 'photo', available: true });
  });

  it('estimate: same count and price as a shoot, the rig in the prompt, the still rig check, member-safe', async () => {
    const body = { modelId: model.id, prompt: 'She laughs on a rooftop in the wind.', count: 2,
      camera: { rig: { body: 'phone', focalMm: 85, aperture: 'f1.4' }, lighting: { preset: 'golden_hour' }, palette: { preset: 'teal_orange' }, angle: { shotSize: 'cu' }, move: { id: 'orbit_left' } } };
    const e = (await member.req('POST', '/v1/suite/photos/estimate', body)).body;
    const shoot = (await member.req('POST', '/v1/shoots/preview', { modelId: model.id, count: 2 })).body;
    expect(e).toMatchObject({ tool: 'photo', count: 2, ok: true, estimate: shoot.estimate, warnings: ['Movement doesn’t apply to photos'] });
    expect(e.priceLine).toBe(`${shoot.estimateLabel} · 2 photos`);
    expect(e.buttonLabel).toMatch(/^Generate · 2 photos · \$\d+\.\d\d$/);
    expect(e.prompt).toContain('Scene: she laughs on a rooftop in the wind.');
    expect(e.prompt).toContain('Camera: close-up shot, 85mm lens, f/1.4');
    expect(e.prompt).toContain('low golden-hour sun');
    expect(e.prompt).toContain('teal-and-orange blockbuster grade');
    expect(e.prompt).toContain('Shot on a modern smartphone camera');
    expect(e.rig.map((w: any) => w.id)).toEqual(['deep_focus']);
    expect(e.look).toMatchObject({ id: 'teal_orange', kind: 'palette' });
    expect(JSON.stringify({ ...e, prompt: undefined })).not.toMatch(PROVIDER_WORDS);
    expect((await member.req('POST', '/v1/suite/photos/estimate', { modelId: model.id, count: 9 })).status).toBe(400);
    expect((await member.req('POST', '/v1/suite/photos/estimate', { modelId: 'nope' })).status).toBe(404);
  });

  it('create: photos saved as "Photo" takes, graded with the Look; the legacy /v1/shoots makes "Photo" takes too (Photoshoot is gone)', async () => {
    const r = (await member.req('POST', '/v1/suite/photos', { modelId: model.id, prompt: 'A café window seat.', count: 2, camera: { palette: { preset: 'classic_bw' } } })).body;
    expect(r.tool).toBe('photo');
    expect(r.takes).toHaveLength(2);
    expect(r.takes[0]).toMatchObject({ kind: 'shot', title: expect.stringMatching(/^Photo · /) });
    expect(r.takes[0].thumb.url).toMatch(/\/uploads\/g\/fx_/); // graded
    const plain = (await member.req('POST', '/v1/suite/photos', { modelId: model.id, count: 1, gradeLook: false, camera: { palette: { preset: 'classic_bw' } } })).body;
    expect(plain.takes[0].thumb.url).not.toMatch(/\/uploads\/g\/fx_/);
    const old = (await member.req('POST', '/v1/shoots', { modelId: model.id, count: 1 })).body;
    expect(old[0].title).toMatch(/^Photo · /);
  });

  it('every photo run is a job (WS19): the Queue lists it, async answers with the running job, done lists its stills', async () => {
    const r = (await member.req('POST', '/v1/suite/photos', { modelId: model.id, prompt: 'A rooftop at dusk.', count: 4, async: true })).body;
    expect(r).toMatchObject({ tool: 'photo', takes: [], job: { state: 'running', engineLabel: 'Photo', request: { engine: 'photo', takes: 4 } } });
    expect(r.job.phase).toMatch(/^Making photo 1 of 4|^Making/);
    let j: any;
    for (let i = 0; i < 200; i++) {
      j = ((await member.req('GET', '/v1/jobs')).body as any[]).find(x => x.id === r.job.id);
      if (j?.state !== 'running') break;
      await new Promise(ok => setTimeout(ok, 20));
    }
    expect(j).toMatchObject({ state: 'done', progress: 100 });
    expect(j.takeIds).toHaveLength(4);
    const feed = (await member.req('GET', '/v1/suite/feed?tool=photo')).body;
    expect(feed.items.filter((x: any) => j.takeIds.includes(x.takeId))).toHaveLength(4);
    // Without async the call waits, as before, and the job comes back done.
    const w = (await member.req('POST', '/v1/suite/photos', { modelId: model.id, count: 1 })).body;
    expect(w.takes).toHaveLength(1);
    expect(w.job).toMatchObject({ state: 'done', takeIds: [w.takes[0].id] });
  });

  it('a Photo preset is a photo template: its own camera and light, the template pipeline', async () => {
    const t = (await owner.req('POST', '/v1/templates', { name: 'Laundrette', layers: { scene: 'a laundrette at night', camera: 'medium shot, 35mm' } })).body;
    const e = (await owner.req('POST', '/v1/suite/photos/estimate', { modelId: model.id, presetId: t.id, count: 1, camera: { rig: { focalMm: 24 } } })).body;
    expect(e).toMatchObject({ preset: { id: t.id, name: 'Laundrette' }, warnings: ['The preset sets its own camera and light'] });
    expect(e.prompt).toBeUndefined();
    const r = (await owner.req('POST', '/v1/suite/photos', { modelId: model.id, presetId: t.id, count: 1 })).body;
    expect(r.takes[0]).toMatchObject({ title: 'Photo · Laundrette', templateId: t.id });
  });
  it('without a character (owner 2026-11-11): an image alone, or an image and words; never her identity, outfit or never-add lines', async () => {
    const img = { image: { asset: 'g_front' }, guides: ['pose', 'look', 'scene'] };
    const alone = await member.req('POST', '/v1/suite/photos/estimate', { references: [img], count: 1 });
    expect(alone.status, JSON.stringify(alone.body)).toBe(200);
    expect(alone.body).toMatchObject({ tool: 'photo', count: 1, ok: true });
    expect(alone.body.prompt).toMatch(/^A new photograph made from image 1/);
    const edit = (await member.req('POST', '/v1/suite/photos/estimate', { references: [img], prompt: 'Make it night with neon signs.', count: 1, camera: { lighting: { preset: 'golden_hour' } } })).body;
    expect(edit.prompt).toMatch(/^Edit image 1: Make it night with neon signs\. Keep everything else/);
    expect(edit.prompt).toContain('Light: ');
    for (const p of [alone.body.prompt, edit.prompt]) {
      expect(p).not.toMatch(/Identity from|Wearing|figure|locked reference|Seed:|rooftop|Do not take the face/);
      expect(p).not.toContain(model.name);
    }
    const made = (await member.req('POST', '/v1/suite/photos', { references: [img], count: 1 })).body;
    expect(made.takes).toHaveLength(1);
    expect(made.takes[0]).toMatchObject({ kind: 'shot', title: expect.stringMatching(/^Photo · /) });
    // Words alone (owner 2026-11-11): plain text-to-image, no images sent.
    const words = await member.req('POST', '/v1/suite/photos/estimate', { prompt: 'A quiet beach at dawn.', count: 1 });
    expect(words.status, JSON.stringify(words.body)).toBe(200);
    expect(words.body.prompt).toMatch(/^A photograph: A quiet beach at dawn\.\n/);
    expect(words.body.prompt).not.toMatch(/Identity from|Wearing|figure|image 1|Seed:|rooftop/);
    const wm = (await member.req('POST', '/v1/suite/photos', { prompt: 'A quiet beach at dawn.', count: 1 })).body;
    expect(wm.takes, JSON.stringify(wm)).toHaveLength(1);
    // Nothing to go on, or a preset without her, is still refused.
    expect((await member.req('POST', '/v1/suite/photos/estimate', { count: 1 })).body.error).toBe('Describe the photo or add an image');
    expect((await member.req('POST', '/v1/suite/photos/estimate', { prompt: 'x', presetId: 'tpl_x' })).body.error).toBe('Presets need a character · pick one with @');
  });
});
