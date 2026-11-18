// Claude's reports of 2026-11-18: New Swap applies the images-sent choice to what it sends and prices (ci_f5f8d64b4c57)
// and joins the composer's prompt into the person's words in every mode (ci_0145b51a080f); Photo keeps Claude's size and
// count when the app's pills didn't take them (ci_90b52f873b5a); save_to_mac saves a generated place photo
// (ci_a64576ec3d2d / ci_2cc7832459f5). Mock providers: nothing is spent.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { clips, generatedImages, uploads, users } from '../src/db/schema.js';
import { suiteLocations } from '../src/suite/schema.js';
import { registryByName } from '../src/claude/registry.js';
import { permissionsOf } from '../src/claude/permissions.js';
import { SAVE_TOOL } from '../src/claude/saveToMac.js';
import type { Resolved, SentImage } from '../src/images/sent.js';
import { putObject } from '../src/storage/objects.js';
import { RemixSchema, ShotRequestSchema, type Character, type RemixToggles } from '../src/suite/plan.js';
import { buildRemixPlan, remixSupport, withPromptWords } from '../src/suite/remix.js';
import { modelById } from '../src/suite/registry.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';
import '../src/suite/prompts.js';

const img = (asset: string) => ({ asset });
const OUTFIT = ['outfit, front', 'outfit, back', 'outfit, side', 'outfit, ¾', 'outfit, face, front'];
const her: Character = { name: 'Mia', look: 'young woman, dark hair', neverAdd: ['tattoos'],
  images: [{ label: 'face, front', image: img('ff') }, { label: 'face, profile', image: img('fp') }],
  outfit: { name: 'Linen set', images: OUTFIT.map(l => ({ label: l, image: img(l) })) } };
const X = (x: RemixToggles) => RemixSchema.parse(x);
const planOn = (id: string, x: RemixToggles, o: { sent?: Resolved | null; prompt?: string } = {}) => {
  const m = modelById(id)!;
  const xx = withPromptWords(x, o.prompt);
  return buildRemixPlan(ShotRequestSchema.parse({ mode: 'remix', clipId: 'c1', remix: x, prompt: o.prompt ?? '' }), xx,
    { model: m, support: remixSupport(m, xx), why: null, tried: [] }, { her: x.character?.kind === 'model' ? her : null, outfitOnly: null },
    { key: 'clips/c1.mp4', seconds: 8 }, { sent: o.sent });
};
const pick = (asset: string, role: SentImage['role'], label = asset): SentImage => ({ image: img(asset), role, label, why: 'chosen by Claude' });
const list = (...l: SentImage[]): Resolved => ({ list: l, add: [], exclude: [], by: 'claude' });

describe('New Swap · the images-sent choice (ci_f5f8d64b4c57)', () => {
  const x = X({ character: { kind: 'model', modelId: 'm' }, outfit: { kind: 'outfit', outfitId: 'o' }, background: { mode: 'photo', image: img('bg') } });

  it('Claude’s list replaces MUSE’s pick in order; the prompt’s tokens follow the new order; the estimate shows exactly what is sent', () => {
    const auto = planOn('genjutsu-light', x);
    expect(auto.sentImages).toMatchObject({ changed: false, max: 8 });
    // The person's base face uploads first (not among MUSE's pictures), then her profile, one outfit angle, the place.
    const p = planOn('genjutsu-light', x, { sent: list(pick('up_face', 'person', 'face, front (base)'), pick('fp', 'person'), pick('outfit, front', 'outfit'), pick('bg', 'location')) });
    expect(p.images.refs.map(r => r.image)).toEqual([img('up_face'), img('fp'), img('outfit, front'), img('bg')]);
    expect(p.sentImages).toMatchObject({ changed: true, changedBy: 'claude', max: 8 });
    expect(p.sentImages!.images.map(s => s.image)).toEqual(p.images.refs.map(r => r.image));
    expect(p.prompt).toContain('PERSON: the person in <Video 1> becomes Mia, shown in <Image 1> and <Image 2>.');
    expect(p.prompt).toContain('her body shape and proportions only from <Image 3>');
    expect(p.prompt).toContain('OUTFIT: she wears the outfit shown in <Image 3>, exactly');
    expect(p.prompt).toContain('BACKGROUND: replace the place with the place in <Image 4>.');
    expect(p.notes.join()).toMatch(/images sent: chosen by Claude \(4 of 8\)/);
    // Reordered: the place first moves every token.
    const r = planOn('genjutsu-light', x, { sent: list(pick('bg', 'location'), pick('ff', 'person'), pick('outfit, back', 'outfit')) });
    expect(r.prompt).toContain('shown in <Image 2>.');
    expect(r.prompt).toContain('BACKGROUND: replace the place with the place in <Image 1>.');
    expect(r.prompt).toContain('OUTFIT: she wears the outfit shown in <Image 3>, exactly');
  });

  it('over the model’s picture room is refused in words; reset is MUSE’s pick; the per-picture price follows the list', () => {
    const k = X({ character: { kind: 'model', modelId: 'm' }, look: { words: 'night' } });
    expect(() => planOn('kling-o1', k, { sent: list(...['a', 'b', 'c', 'd', 'e'].map(a => pick(a, 'person'))) })).toThrow(/takes up to 4 images · 5 chosen/);
    expect(planOn('kling-o1', k, { sent: { add: [], exclude: [], by: 'claude', reset: true } }).sentImages!.changed).toBe(false);
    // An image that isn't hers or the outfit's goes in as a reference, named in the words.
    const p = planOn('kling-o1', k, { sent: list(pick('ff', 'person'), pick('prop', 'other', 'pouf')) });
    expect(p.images.refs).toHaveLength(2);
    expect(p.prompt).toContain('Also use <<<image_2>>> as a reference.');
  });
});

describe('New Swap · the composer’s words (ci_0145b51a080f)', () => {
  it('the prompt joins the direction under CHANGE in every background mode, sanitised against her look', () => {
    const photo = planOn('genjutsu-light', X({ character: { kind: 'model', modelId: 'm' }, background: { mode: 'photo', image: img('bg') } }),
      { prompt: 'Keep the pouf she sits on' });
    expect(photo.prompt).toContain('CHANGE: Direction: Keep the pouf she sits on.');
    const words = planOn('wan-2.7-edit', X({ background: { mode: 'describe', words: 'a rooftop' }, direction: 'slow light' }), { prompt: 'keep the chair' });
    expect(words.prompt).toContain('CHANGE: Background: a rooftop. Direction: keep the chair slow light.');
    const kept = planOn('wan-2.7-edit', X({ look: { words: 'night' } }), { prompt: 'the lamp stays on' });
    expect(kept.prompt).toContain('Direction: the lamp stays on.');
    const clean = planOn('genjutsu-light', X({ character: { kind: 'model', modelId: 'm' } }), { prompt: 'she has tattoos' });
    expect(clean.prompt).not.toMatch(/tattoos/);
    expect(withPromptWords(X({ look: { words: 'night' } }), '  ')).toEqual(X({ look: { words: 'night' } }));
  });
});

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); return true; } catch { return false; } })();
type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, ownerU: AuthUser, mia: { id: string }, studioId: string, dir: string;
const run = (name: string, args: Record<string, unknown>) => registryByName.get(name)!.run({ ctx: a.ctx, user: ownerU, source: 'chat' } as any, args) as Promise<any>;
const newDraft = async (draft: Record<string, unknown>) => (await owner.req('POST', '/v1/suite/assist', { draft })).body.id as string;
const get = async (id: string) => (await owner.req('GET', `/v1/suite/assist/${id}`)).body;
const patch = async (id: string, draft: Record<string, unknown>) => {
  const r = await owner.req('PATCH', `/v1/suite/assist/${id}`, { draft, baseRevision: (await get(id)).revision });
  expect(r.status, JSON.stringify(r.body)).toBe(200);
  return r.body;
};

describe.skipIf(!hasFfmpeg)('on the app (mock providers)', () => {
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner } = await people(a, 0, { topUp: 100 }) as any);
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    studioId = u!.studioId;
    ownerU = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    mia = await demoModel(owner) as any;
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-sent-'));
    const f = path.join(dir, 'src.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=180x320:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=330', '-t', '4', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', f]);
    await putObject(a.ctx, { key: 'clips/sent.mp4', body: fs.readFileSync(f), studioId, kind: 'clip', contentType: 'video/mp4' });
    await a.ctx.db.insert(clips).values({ id: 'c_four', studioId, name: 'four', durationSec: 4, width: 180, height: 320, fps: 24, meta: {}, checks: [], storageKey: 'clips/sent.mp4', createdAt: Date.now() });
  });
  afterAll(async () => { await a?.close(); if (dir) fs.rmSync(dir, { recursive: true, force: true }); });

  it('New Swap: set_sent_images and the draft prompt reach the estimate, and the run sends exactly that', async () => {
    const id = await newDraft({ v: 1, tool: 'swap' });
    await run('suite_set_draft', { assistId: id, swapVariant: 'new' });
    await run('suite_set_draft', { assistId: id, clipId: 'c_four', engineModel: 'kling-o1', prompt: 'Keep the pouf she sits on',
      remix: { character: { kind: 'model', modelId: mia.id }, look: { words: 'warm evening light' } } });
    const before = (await run('get_sent_images', { assistId: id })).sentImages;
    expect(before.changed).toBe(false);
    const chosen = [before.images.at(-1), before.images[0]].map((x: any) => ({ image: x.image, role: x.role }));
    const set = await run('set_sent_images', { assistId: id, list: chosen });
    expect(set.sentImages).toMatchObject({ changed: true, changedBy: 'claude', max: 4 });
    expect(set.sentImages.images.map((x: any) => x.image)).toEqual(chosen.map(c => c.image));
    const e = (await run('suite_estimate', { assistId: id })).estimate;
    expect(e.sentImages.images.map((x: any) => x.image)).toEqual(chosen.map(c => c.image));
    expect(e.prompt).toContain('Direction: Keep the pouf she sits on.');
    // Generate (the owner approves): the provider gets those two pictures, in that order, and the same prompt.
    const calls = a.ctx.suite.mock.calls.length;
    const v = await get(id);
    const r = await owner.req('POST', '/v1/suite/shots', v.request);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    let call: any;
    for (let i = 0; i < 400 && !call; i++) { call = a.ctx.suite.mock.calls.slice(calls)[0]; if (!call) await new Promise(res => setTimeout(res, 25)); }
    expect(call, 'the run reached the provider').toBeTruthy();
    expect((call.input.reference_images as string[]).length).toBe(2);
    expect(String(call.input.prompt)).toContain('Keep the pouf she sits on');
  });

  it('Photo: Claude’s 1:1 and 2 stills survive the Mac’s syncs and reach the estimate and the run; the person’s change wins', async () => {
    const mac = (count: number, extra: Record<string, unknown> = {}) => ({ v: 1, tool: 'photo', count, tokens: [{ t: 'text', text: 'A face reference' }],
      screen: { tool: 'photo', request: { count, prompt: 'A face reference' } }, ...extra });
    const id = await newDraft(mac(1));
    await run('suite_set_draft', { assistId: id, aspect: '1:1', count: 2 });
    // The Mac's Photo composer keeps its own pills (no size in its draft, 1 still) and syncs twice.
    await patch(id, mac(1));
    const d = (await patch(id, mac(1))).draft;
    expect([d.aspect, d.count]).toEqual(['1:1', 2]);
    const e = (await run('suite_estimate', { assistId: id })).estimate;
    expect([e.aspect, e.count]).toEqual(['1:1', 2]);
    // The Mac's own Generate estimate (its pills: no size, 1 still) is priced as Claude set it.
    const direct = (await owner.req('POST', '/v1/suite/photos/estimate', { prompt: 'A face reference', count: 1, draft: mac(1) })).body;
    expect([direct.aspect, direct.count]).toEqual(['1:1', 2]);
    // The person picks 3 stills and 4:5 on the Mac: theirs from then on.
    const m = (await patch(id, mac(3, { screen: { tool: 'photo', request: { count: 3, aspect: '4:5', prompt: 'A face reference' } } }))).draft;
    expect([m.aspect, m.count, m.photoHold]).toEqual(['4:5', 3, undefined]);
    const after = (await owner.req('POST', '/v1/suite/photos/estimate', { prompt: 'A face reference', count: 3, aspect: '4:5' })).body;
    expect([after.aspect, after.count]).toEqual(['4:5', 3]);
  });

  it('save_to_mac: a generated place photo by its img_ id (also as uploadId), and a place’s photo by placeId', async () => {
    const hub = permissionsOf(a.ctx);
    hub.uploadAnswerMs = 30;
    try {
      await a.app.inject({ method: 'GET', url: '/v1/claude/permissions', headers: { authorization: `Bearer ${owner.token}`, 'x-muse-caps': 'files,results,ui,acks,save' } });
      await a.ctx.db.insert(uploads).values({ id: 'up_place', studioId, kind: 'generated', storageKey: 'g/img_place1.png', contentType: 'image/png', bytes: 1_500_000, state: 'ready', createdAt: Date.now() });
      await a.ctx.db.insert(suiteLocations).values({ id: 'loc_cafe', studioId, name: 'Corner café', image: {}, tag: 'cafe', description: '', modelId: mia.id,
        images: [{ url: 'https://muse.test/uploads/g/img_place0.png', source: 'upload' }, { url: 'https://muse.test/uploads/g/img_place1.png', source: 'generated' }], cover: 1, createdAt: Date.now() } as any);
      await a.ctx.db.insert(generatedImages).values({ id: 'img_place1', studioId, userId: owner.id, purpose: 'place_photo', refId: 'loc_cafe', provider: 'mock', model: 'mock', prompt: 'a café',
        image: { url: 'https://muse.test/uploads/g/img_place1.png' }, storageKey: 'g/img_place1.png', createdAt: Date.now() });
      const save = (args: Record<string, unknown>) => SAVE_TOOL.run({ ctx: a.ctx, user: ownerU }, args);
      const ask = async (args: Record<string, unknown>) => {
        await save(args);
        let x: any;
        for (let i = 0; i < 50 && !x; i++) { x = (await owner.req('GET', '/v1/claude/permissions')).body.asks[0]; if (!x) await new Promise(r => setTimeout(r, 20)); }
        await owner.req('POST', `/v1/claude/permissions/${x.id}`, { allow: false });
        return x.input;
      };
      expect(await ask({ imageId: 'img_place1' })).toMatchObject({ url: '/uploads/g/img_place1.png', fileName: 'corner-café-place-imgplace1.png', contentType: 'image/png', bytes: 1_500_000 });
      expect((await ask({ uploadId: 'img_place1' })).what).toMatch(/the place photo of Corner café \(img_place1\)/);
      expect(await ask({ placeId: 'loc_cafe' })).toMatchObject({ url: '/uploads/g/img_place1.png', fileName: 'corner-café-place-loccafe-2.png' });
      expect(await ask({ placeId: 'loc_cafe', photo: 1 })).toMatchObject({ url: '/uploads/g/img_place0.png' });
      await expect(save({ placeId: 'loc_cafe', photo: 3 })).rejects.toThrow(/has 2 photos/);
      await expect(save({ imageId: 'img_nope' })).rejects.toThrow(/not a picture of this studio/);
    } finally { hub.uploadAnswerMs = 40_000; }
  });
});
