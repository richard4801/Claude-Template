// AI suite · Recast (same take, new cast): up to 4 people in one clip → studio characters. Registry flags, the recast
// ladder, per-person references and who-is-who, the suite.recast script, provider inputs, prices, and the API on the
// MOCK provider. No real predictions, no money.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { clips, ledger } from '../src/db/schema.js';
import { DEFAULT_TEXTS } from '../src/prompt/library.js';
import { scriptDef } from '../src/prompt/scripts/defs.js';
import { validateRules } from '../src/prompt/scripts/run.js';
import { putObject } from '../src/storage/objects.js';
import { buildInput } from '../src/suite/inputs.js';
import { ShotRequestSchema, type Character } from '../src/suite/plan.js';
import { buildRecastPlan, castOrder, pickRecast, recastFit, whoWords, type CastMember } from '../src/suite/recast.js';
import { modelById, RECAST_LADDER, TIERS } from '../src/suite/registry.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const ALL = new Set(['replicate', 'fal', 'mock'] as const) as Set<any>;
const ch = (name: string, outfit = false): Character => ({ name, look: `${name}'s look`, neverAdd: ['tattoos'],
  images: [{ label: 'face, front', image: { asset: 'face' } }, { label: 'face, profile', image: { asset: 'profile' } }, { label: 'body, front', image: { asset: 'g_front' } }],
  outfit: outfit ? { name: 'Green set', images: [{ label: 'outfit, front', image: { asset: 'g_tq' } }] } : null });
const req = (o: Record<string, unknown>) => ShotRequestSchema.parse({ mode: 'recast', clipId: 'c1', ...o });
const member = (cast: Record<string, unknown>, c: Character, speaking: CastMember['speaking'] = 'unknown'): CastMember => ({ cast: { characterId: c.name, ...cast } as any, character: c, speaking });
const plan = (id: string, res: string, r: ReturnType<typeof req>, members: CastMember[], seconds = 12) =>
  buildRecastPlan(r, members, { model: modelById(id)!, resolution: modelById(id)!.resolutions.find(x => x.id === res)!, tried: [] }, { key: 'clips/c1.mp4', seconds }, {});

describe('Recast · registry and ladder (unit)', () => {
  it('flags: the fal recast model replaces up to 4 people, keeps cuts and sound, is preview and needs fal', () => {
    expect(modelById('h3-max-recast')).toMatchObject({ provider: 'fal', status: 'preview', ref: 'minimax/h3-max/recast',
      recast: { maxPeople: 4, keepsCuts: true, keepsAudio: true, refsPerPerson: 1, sourceSeconds: [5, 30], maxShotSeconds: 15 } });
    expect(modelById('wan-2.2-animate')!.recast).toMatchObject({ maxPeople: 1, keepsAudio: true });
    expect(modelById('kling-v4')!.recast).toMatchObject({ keepsAudio: false, faceCrops: true });
    for (const t of TIERS) for (const s of RECAST_LADDER[t]) expect(modelById(s.model)!.resolutions.some(r => r.id === s.resolution), `${t} ${s.model}`).toBe(true);
    // Recast-only models never join the shot ladder.
    expect(modelById('h3-max-recast')!.modes).toMatchObject({ text: false, image: false, reference: false, recast: true });
  });
  it('picks by people, clip length and provider; the fal model is skipped until FAL_KEY is set', () => {
    const p3 = pickRecast('cinema', { people: 3, seconds: 12, crops: 0 }, { providers: ALL });
    expect('model' in p3 && [p3.model.id, p3.resolution.id]).toEqual(['h3-max-recast', '1080P']);
    const noFal = pickRecast('cinema', { people: 3, seconds: 12, crops: 0 }, { providers: new Set(['replicate']) as any });
    expect('model' in noFal && noFal.model.id).toBe('kling-v4');
    expect('model' in noFal && noFal.tried[0]).toEqual({ model: 'h3-max-recast', resolution: '1080P', why: 'fal not set up' });
    expect(pickRecast('cinema', { people: 4, seconds: 12, crops: 0 }, { providers: new Set(['replicate']) as any })).toMatchObject({ error: 'nothing_fits' });
    const one = pickRecast('draft', { people: 1, seconds: 8, crops: 0 }, { providers: ALL });
    expect('model' in one && one.model.id).toBe('wan-2.2-animate');
    const two = pickRecast('draft', { people: 2, seconds: 8, crops: 0 }, { providers: ALL });
    expect('model' in two && two.model.id).toBe('kling-o1');
    expect(recastFit(modelById('kling-o1')!, '720p', { people: 1, seconds: 12, crops: 0 })).toBe('clips 3–10 s');
    expect(recastFit(modelById('h3-max-recast')!, '768P', { people: 1, seconds: 4, crops: 0 })).toBe('clips 5–30 s');
    expect(pickRecast('hd', { people: 2, seconds: 40, crops: 0 }, { providers: ALL })).toMatchObject({ error: 'nothing_fits' });
  });
});

describe('Recast · plans, prompt script and inputs (unit)', () => {
  it('the suite.recast script validates; mouths only from per-person audio rules', () => {
    const s = scriptDef('suite.recast')!;
    expect(validateRules(s, s.rules)).toBeNull();
    for (const r of s.rules) expect(DEFAULT_TEXTS[r.block], r.block).toBeDefined();
    expect(s.sections.filter(x => x.kind === 'user').map(x => x.id)).toEqual(['direction']);
  });
  it('fal: one photo per person in left-to-right order, who-is-who and mouths in the prompt, sound and cuts kept, priced per output second', () => {
    const r = req({ quality: 'hd', cast: [{ personHint: 'right', characterId: 'Leo' }, { personHint: 'left', characterId: 'Mia' }], prompt: 'Keep the café busy, and give her a tattoo.' });
    const p = plan('h3-max-recast', '1080P', r, [member({ personHint: 'right' }, ch('Leo'), 'no'), member({ personHint: 'left' }, ch('Mia', true), 'yes')]);
    expect(p.images.refs.map(x => x.label)).toEqual(['person 1 · outfit, front', 'person 2 · body, front']);
    expect(p.prompt).toMatch(/^Recast the source video: replace 2 people with the characters below\./);
    expect(p.prompt).toMatch(/the person on the left in the source video becomes Mia, shown in reference photo 1: Mia's look\. She wears Green set \(reference photo 1\)\. She never has: tattoos\./);
    expect(p.prompt).toMatch(/the person on the right in the source video becomes Leo, shown in reference photo 2/);
    expect(p.prompt).toMatch(/^Mia’s lips match every word of the original audio\.$/m);
    expect(p.prompt).toMatch(/^Leo’s mouth follows the source video exactly; she does not speak, sing or mouth words\.$/m);
    expect(p.prompt).toMatch(/never swap faces/);
    expect(p.prompt).toMatch(/Keep every cut and shot change/);
    expect(p.prompt).toMatch(/^Direction: Keep the café busy,?$/m);
    expect(p.notes.join()).toMatch(/left out of the direction/);
    expect(p.recast).toMatchObject({ keepAudio: true, restoreAudio: false });
    expect(p.estimate).toBeCloseTo(0.45 * 12, 6);
    expect(buildInput(modelById('h3-max-recast')!, p, { middle: [], refs: ['a', 'b'], videos: ['v'] })).toEqual({ prompt: p.prompt, video_url: 'v', reference_image_urls: ['a', 'b'], resolution: '1080P' });
  });
  it('Kling 4.0 edit: several images per person and face crops, source sound put back, video-input billing', () => {
    const r = req({ quality: 'cinema', cast: [{ personIndex: 1, characterId: 'Mia', faceCrop: { url: 'https://x.test/crop1.jpg' } }, { personIndex: 2, characterId: 'Leo' }] });
    const p = plan('kling-v4', '1080p', r, [member({ personIndex: 1, faceCrop: { url: 'https://x.test/crop1.jpg' } }, ch('Mia')), member({ personIndex: 2 }, ch('Leo'))]);
    expect(p.images.refs.length).toBe(7); // 3 + crop + 3
    expect(p.prompt).toMatch(/@image_4 shows which person the first person \(from the left, or to appear\) is\./);
    expect(p.prompt).toMatch(/^Mia’s mouth follows @video_1 exactly\.$/m);
    expect(p.recast!.restoreAudio).toBe(true);
    expect(p.billedPerTake).toBe(24);
    expect(p.estimate).toBeCloseTo(0.141 * 24, 6);
    expect(buildInput(modelById('kling-v4')!, p, { middle: [], refs: ['1', '2'], videos: ['v'] })).toMatchObject({ base_video: 'v', reference_images: ['1', '2'], resolution: '1080p' });
  });
  it('Wan Animate (one person, no prompt) and Kling O1 inputs; who words and cast order', () => {
    const w = plan('wan-2.2-animate', '480', req({ quality: 'draft', keepAudio: false, cast: [{ characterId: 'Mia' }] }), [member({}, ch('Mia'))], 8);
    expect(buildInput(modelById('wan-2.2-animate')!, w, { middle: [], refs: ['img'], videos: ['v'] })).toEqual({ video: 'v', character_image: 'img', resolution: '480', merge_audio: false });
    expect(w.estimate).toBeCloseTo(0.02 * 8, 6);
    const k = plan('kling-o1', '720p', req({ quality: 'standard', aspectRatio: '9:16', cast: [{ characterId: 'Mia' }, { characterId: 'Leo' }] }), [member({}, ch('Mia')), member({}, ch('Leo'))], 8);
    expect(buildInput(modelById('kling-o1')!, k, { middle: [], refs: ['a', 'b', 'c', 'd'], videos: ['v'] })).toMatchObject({ reference_video: 'v', video_reference_type: 'base', keep_original_sound: true, mode: 'std', aspect_ratio: '9:16' });
    expect(k.prompt).toMatch(/<<<image_1>>>/);
    expect(whoWords({ characterId: 'x', personHint: 'center', personNote: 'red coat' } as any, 0)).toBe('the person in the centre (red coat)');
    expect(castOrder([{ cast: { characterId: 'a' } }, { cast: { characterId: 'b', personHint: 'left' } }, { cast: { characterId: 'c', personIndex: 2 } }] as any).map((x: any) => x.cast.characterId)).toEqual(['b', 'c', 'a']);
    expect(() => req({ cast: [1, 2, 3, 4, 5].map(i => ({ characterId: `c${i}` })) })).toThrow();
  });
});

describe.skipIf(!hasFfmpeg)('Recast · API on the mock provider', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, mem: Client, mia: { id: string }, leo: { id: string }, dir: string;
  const PROVIDER_WORDS = /\b(replicate|fal|runpod|minimax|h3|kling|seedance|veo|wan|ltx|lightricks|bytedance|google|sora)\b/i;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [mem] } = await people(a, 1, { topUp: 100 }) as any);
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: mem.id, tokens: 3000 });
    mia = await demoModel(owner);
    leo = await demoModel(owner);
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-recast-'));
    const f = path.join(dir, 'src.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=180x320:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=330', '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', f]);
    const [o] = await a.ctx.db.execute((await import('drizzle-orm')).sql`select studio_id from users where id = ${owner.id}`).then((r: any) => r.rows ?? r);
    await putObject(a.ctx, { key: 'clips/two.mp4', body: fs.readFileSync(f), studioId: o.studio_id, kind: 'clip', contentType: 'video/mp4' });
    await a.ctx.db.insert(clips).values({ id: 'c_two', studioId: o.studio_id, name: 'two people', durationSec: 6, width: 180, height: 320, fps: 24, meta: { talking: true }, checks: [], storageKey: 'clips/two.mp4', createdAt: Date.now() });
  });
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const done = (id: string) => until(async () => { const j = (await owner.req('GET', `/v1/suite/shots/${id}`)).body.job; return j?.state === 'done' || j?.state === 'failed' ? j : null; }, 20_000);

  it('estimate (member): Recast label, the cast with who-is-who and speaking, no engine names', async () => {
    const e = await mem.req('POST', '/v1/suite/shots/estimate', { mode: 'recast', clipId: 'c_two', quality: 'hd',
      cast: [{ personHint: 'left', characterId: mia.id, speaking: true }, { personHint: 'right', characterId: leo.id, speaking: false }] });
    expect(e.status).toBe(200);
    expect(e.body).toMatchObject({ mode: 'recast', label: 'Recast · HD · 1080p', seconds: 6, estimate: 2.7, keepAudio: true,
      cast: [{ characterId: mia.id, who: 'the person on the left', speaking: 'yes' }, { characterId: leo.id, who: 'the person on the right', speaking: 'no' }] });
    expect(JSON.stringify(e.body)).not.toMatch(PROVIDER_WORDS);
    const o = (await owner.req('POST', '/v1/suite/shots/estimate', { mode: 'recast', clipId: 'c_two', quality: 'hd', cast: [{ characterId: mia.id }] })).body;
    expect(o.engine).toMatchObject({ model: 'h3-max-recast', provider: 'fal', resolution: '1080P' });
    // Look grading applies to Recast too (Character swap / Recast show the Look chip).
    expect(o.look).toBeNull();
    const graded = (await owner.req('POST', '/v1/suite/shots/estimate', { mode: 'recast', clipId: 'c_two', quality: 'hd', cast: [{ characterId: mia.id }], camera: { palette: { preset: 'teal_orange' } } })).body;
    expect(graded.look).toMatchObject({ id: 'teal_orange', lut: 'pack:cine-teal-orange' });
    // One person, no switch: the clip's own talking flag decides.
    expect(o.cast[0].speaking).toBe('yes');
    expect(o.speaking).toEqual({ speaking: true, source: 'upload' });
  });

  it('a recast runs on the mock: the real inputs are recorded, the take is the clip’s length, settle $0 (test render)', async () => {
    const before = a.ctx.suite.mock.calls.length;
    const r = (await mem.req('POST', '/v1/suite/shots', { mode: 'recast', clipId: 'c_two', quality: 'hd',
      cast: [{ personHint: 'right', characterId: leo.id }, { personHint: 'left', characterId: mia.id }] })).body;
    expect(r.engineLabel).toBe('Recast · HD · 1080p');
    expect(r.request).toMatchObject({ engine: 'suite', mode: 'recast', clipId: 'c_two', keepAudio: true });
    const j = await done(r.id);
    expect(j.state).toBe('done');
    const call = a.ctx.suite.mock.calls.slice(before)[0]!;
    expect(call.ref).toBe('minimax/h3-max/recast');
    expect(call.input).toMatchObject({ resolution: '1080P' });
    expect(call.input.reference_image_urls).toHaveLength(2);
    expect(call.input.video_url).toMatch(/clips\/two\.mp4/);
    expect(call.input.prompt).toMatch(/the person on the left in the source video becomes Demo model/);
    const take = (await mem.req('GET', '/v1/takes')).body.find((t: any) => t.jobId === r.id);
    expect(take).toMatchObject({ label: 'HD', engineLabel: 'Recast · HD · 1080p', durationSec: 6 });
    const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, r.id))).find(x => x.kind === 'settle')!;
    expect(settle).toMatchObject({ amountUsd: 0, note: 'Video · Recast HD 1080p · 6 s · test render' });
  });

  it('the owner can pick a model that drops the sound: the source sound is put back on the take', async () => {
    const r = (await owner.req('POST', '/v1/suite/shots', { mode: 'recast', clipId: 'c_two', engineModel: 'kling-v4', resolution: '720p', cast: [{ characterId: mia.id }] })).body;
    const j = await done(r.id);
    expect(j.state).toBe('done');
    const take = (await owner.req('GET', '/v1/takes')).body.find((t: any) => t.jobId === r.id);
    expect(take.videoUrl).toBeTruthy();
  });

  it('refusals: no clip, no cast, two entries for one person, an unknown character, too many people', async () => {
    const b = (x: object) => mem.req('POST', '/v1/suite/shots/estimate', { mode: 'recast', ...x });
    expect((await b({ cast: [{ characterId: mia.id }] })).body.error).toMatch(/source clip/);
    expect((await b({ clipId: 'c_two' })).body.error).toMatch(/needs a cast/);
    expect((await b({ clipId: 'c_two', cast: [{ personIndex: 1, characterId: mia.id }, { personIndex: 1, characterId: leo.id }] })).body.error).toMatch(/same person/);
    expect((await b({ clipId: 'c_two', cast: [{ characterId: 'm_nope' }] })).status).toBe(404);
    expect((await b({ clipId: 'c_two', cast: [1, 2, 3, 4, 5].map(() => ({ characterId: mia.id })) })).status).toBe(400);
    expect((await b({ clipId: 'c_nope', cast: [{ characterId: mia.id }] })).status).toBe(404);
  });
});
