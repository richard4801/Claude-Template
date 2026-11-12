// New Swap (beta, plans/new-swap.md): remix a clip with toggles. Registry edit caps, Auto's pick and reasons, the
// suite.remix script (figure lock in every prompt), pictures and their caps, the trimmer, prices, provider inputs, and
// the API + Claude's draft on the MOCK provider. No real predictions, no money.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { pipeline } from 'node:stream/promises';
import { clips, takes, users } from '../src/db/schema.js';
import { DEFAULT_TEXTS } from '../src/prompt/library.js';
import { scriptDef } from '../src/prompt/scripts/defs.js';
import { validateRules } from '../src/prompt/scripts/run.js';
import { putObject } from '../src/storage/objects.js';
import { assistOf } from '../src/suite/assist.js';
import { buildInput } from '../src/suite/inputs.js';
import { RemixSchema, ShotRequestSchema, type Character, type RemixToggles } from '../src/suite/plan.js';
import { buildRemixPlan, fillImages, pickRemix, remixIncomplete, remixSpan, remixSupport, togglesOn } from '../src/suite/remix.js';
import { MODELS, modelById } from '../src/suite/registry.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';
import '../src/suite/prompts.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const ALL = new Set(['replicate', 'fal', 'mock', 'higgsfield']) as Set<any>;
const NO_HF = new Set(['replicate', 'fal', 'mock']) as Set<any>;
const img = (asset: string) => ({ asset });
const OUTFIT7 = ['outfit, ¾', 'outfit, front', 'outfit, face, front', 'outfit, side', 'outfit, face, profile', 'outfit, back', 'outfit, face, ¾'];
const her = (outfit = false): Character => ({ name: 'Mia', look: 'young woman, dark hair', neverAdd: ['tattoos'],
  images: outfit ? [{ label: 'face, front', image: img('ff') }, { label: 'face, profile', image: img('fp') }]
    : [{ label: 'face, front', image: img('ff') }, { label: 'face, profile', image: img('fp') }, { label: 'body, front', image: img('bf') }, { label: 'body, side', image: img('bs') }],
  outfit: outfit ? { name: 'Linen set', images: OUTFIT7.map(l => ({ label: l, image: img(l) })) } : null });
const X = (x: RemixToggles) => RemixSchema.parse(x);
const req = (o: Record<string, unknown> = {}) => ShotRequestSchema.parse({ mode: 'remix', clipId: 'c1', ...o });
const planOn = (id: string, x: RemixToggles, o: { seconds?: number; range?: [number, number]; outfit?: boolean; resolution?: string } = {}) => {
  const m = modelById(id)!;
  return buildRemixPlan(req({ remix: x, ...(o.range ? { range: o.range } : {}), ...(o.resolution ? { resolution: o.resolution } : {}) }), x,
    { model: m, support: remixSupport(m, x), why: null, tried: [] }, { her: x.character?.kind === 'model' ? her(o.outfit) : null, outfitOnly: null },
    { key: 'clips/c1.mp4', seconds: o.seconds ?? 10 }, {});
};

describe('New Swap · registry and Auto (unit)', () => {
  it('Wan 2.7 Edit is in the registry as an edit-only model; every edit model’s default resolution exists', () => {
    expect(modelById('wan-2.7-edit')).toMatchObject({ provider: 'replicate', ref: 'wan-video/wan-2.7-videoedit', adapter: 'wan-2.7-edit',
      modes: { text: false, image: false, reference: false }, edit: { sourceSeconds: [2, 10], maxImages: 1, keepsAudio: true, tested: false, defaultResolution: '1080p' } });
    const edit = MODELS.filter(m => m.edit);
    expect(edit.map(m => m.id).sort()).toEqual(['genjutsu', 'genjutsu-light', 'h3-max-recast', 'kling-o1', 'kling-v4', 'seedance-2.5', 'wan-2.2-animate', 'wan-2.7-edit']);
    for (const m of edit) expect(m.resolutions.some(r => r.id === m.edit!.defaultResolution), m.id).toBe(true);
  });

  it('Auto: Wan 2.7 Edit for Background / Look, Kling O1 for Outfit, Genjutsu Light with her; each says why', () => {
    const bg = pickRemix(X({ background: { mode: 'describe', words: 'a rooftop' } }), { providers: ALL });
    expect('model' in bg && [bg.model.id, bg.why]).toEqual(['wan-2.7-edit', 'Background only: Wan 2.7 Edit (keeps the sound, up to 10 s, 1080p)']);
    const look = pickRemix(X({ look: { words: 'night, neon' } }), { providers: ALL });
    expect('model' in look && look.model.id).toBe('wan-2.7-edit');
    const outfit = pickRemix(X({ outfit: { kind: 'words', words: 'a black two-piece' } }), { providers: ALL });
    expect('model' in outfit && outfit.model.id).toBe('kling-o1');
    const char = pickRemix(X({ character: { kind: 'model', modelId: 'm1' }, background: { mode: 'photo', image: img('bg') } }), { providers: ALL });
    expect('model' in char && [char.model.id, char.why]).toEqual(['genjutsu-light', 'Background + Character: Genjutsu Light (same moves, new look, MUSE puts the clip’s sound back, up to 15 s)']);
    // No Higgsfield: Auto moves on and says what it skipped.
    const noHf = pickRemix(X({ character: { kind: 'model', modelId: 'm1' } }), { providers: NO_HF });
    expect('model' in noHf && [noHf.model.id, noHf.tried.map(t => t.why)]).toEqual(['kling-o1', ['higgsfield not set up', 'higgsfield not set up']]);
    // 4c: a model hidden from members is skipped for them.
    const hidden = pickRemix(X({ look: { words: 'warm' } }), { providers: ALL, hidden: new Set(['wan-2.7-edit']) });
    expect('model' in hidden && [hidden.model.id, hidden.tried[0]]).toEqual(['kling-o1', { model: 'wan-2.7-edit', why: 'not offered to members' }]);
  });

  it('what each model can do: refusals say why; "prompt" marks instruction-only', () => {
    const bgOnly = X({ background: { mode: 'describe', words: 'beach' } });
    expect(remixSupport(modelById('genjutsu-light')!, bgOnly)).toEqual({ support: 'no', reason: 'puts a person from pictures into the clip: turn on Character (her)' });
    expect(remixSupport(modelById('wan-2.7-edit')!, X({ character: { kind: 'model', modelId: 'm' } }))).toEqual({ support: 'no', reason: 'can’t do Character' });
    expect(remixSupport(modelById('wan-2.7-edit')!, X({ outfit: { kind: 'product', image: img('p') }, background: { mode: 'photo', image: img('b') } })))
      .toEqual({ support: 'no', reason: 'takes 1 picture: these changes need 2' });
    expect(remixSupport(modelById('wan-2.7-edit')!, X({ outfit: { kind: 'words', words: 'red dress' } }))).toEqual({ support: 'prompt', reason: 'does Outfit by instruction only' });
    expect(remixSupport(modelById('genjutsu')!, X({ character: { kind: 'face', image: img('f') } })).support).toBe('no'); // face swap isn't a Genjutsu job
    expect(remixSupport(modelById('wan-2.2-animate')!, X({ character: { kind: 'model', modelId: 'm' }, look: { words: 'warm' } })).support).toBe('no');
    expect(pickRemix(X({ background: { mode: 'describe', words: 'x' } }), { providers: ALL, engineModel: 'genjutsu' })).toMatchObject({ error: 'remix_unsupported' });
    expect(pickRemix(X({ background: { mode: 'describe', words: 'x' } }), { providers: ALL, engineModel: 'veo-3.1-lite' })).toMatchObject({ error: 'remix_unsupported' });
    expect(togglesOn(X({ character: { kind: 'face', image: img('f') }, look: { words: 'w' } }))).toEqual(['face', 'look']);
    expect(remixIncomplete({})).toMatch(/^Turn on a change/);
    expect(remixIncomplete(X({ background: { mode: 'describe', words: ' ' } }))).toBe('Background · Describe: write the new place');
    expect(remixIncomplete(X({ look: { words: '' } }))).toMatch(/^Look & light/);
    expect(remixIncomplete(X({ background: { mode: 'describe', words: 'beach' } }))).toBeNull();
  });
});

describe('New Swap · prompt, pictures, trimmer and prices (unit)', () => {
  it('the suite.remix script validates; its only user section is the person’s words; every block exists', () => {
    const s = scriptDef('suite.remix')!;
    expect(validateRules(s, s.rules)).toBeNull();
    for (const r of s.rules) expect(DEFAULT_TEXTS[r.block], r.block).toBeDefined();
    expect(s.sections.filter(x => x.kind === 'user').map(x => x.id)).toEqual(['change']);
  });

  it('her + her outfit + a new photo on Genjutsu Light: 8 pictures, figure lock from the outfit’s angles, background last', () => {
    const x = X({ character: { kind: 'model', modelId: 'm' }, outfit: { kind: 'outfit', outfitId: 'o' }, background: { mode: 'photo', image: img('bg') } });
    const p = planOn('genjutsu-light', x, { outfit: true });
    expect(p.images.refs.map(r => r.label)).toEqual(['face, front', 'face, profile', 'outfit, front', 'outfit, back', 'outfit, side', 'outfit, ¾', 'outfit, face, front', 'background']);
    expect(p.notes.join()).toMatch(/takes 8 pictures: left out outfit, face, profile, outfit, face, ¾/);
    expect(p.prompt).toMatch(/^Edit <Video 1>\. Change only what is listed below/);
    expect(p.prompt).toContain('FIGURE LOCK: her face, hair and skin come only from <Image 1> and <Image 2>, and her body shape and proportions only from <Image 3>, <Image 4>, <Image 5> and <Image 6>, unchanged. From <Video 1> take only the motion, timing and facial gestures');
    expect(p.prompt).toContain('never the face, body, figure or proportions of the person in it');
    expect(p.prompt).toContain('PERSON: the person in <Video 1> becomes Mia, shown in <Image 1> and <Image 2>.');
    expect(p.prompt).toContain('OUTFIT: she wears the outfit shown in <Image 3>, <Image 4>, <Image 5>, <Image 6> and <Image 7>, exactly');
    expect(p.prompt).toContain('BACKGROUND: replace the place with the place in <Image 8>.');
    expect(p.prompt).toContain('KEEP: the light and colour; the motion, timing');
    expect(p.prompt).not.toMatch(/CHANGE:/); // nothing typed: no words line
    // Genjutsu reads plain words: "image 1", "the source video".
    const input = buildInput(modelById('genjutsu-light')!, p, { middle: [], refs: p.images.refs.map((_, i) => `u${i}`), videos: ['v'] });
    expect(input).toMatchObject({ video_url: 'v', resolution: '720p' });
    expect((input.image_urls as string[]).length).toBe(8);
    expect(String(input.prompt)).toMatch(/only from image 1 and image 2/);
    expect(String(input.prompt)).not.toMatch(/<Image|<Video/);
    // 10 s at 720p: $0.10 per second of output AND input → $2.00.
    expect(p.estimate).toBeCloseTo(2.0, 6);
    expect(p.remix).toMatchObject({ keepAudio: true, restoreAudio: true, range: null, toggles: ['background', 'outfit', 'character'] });
  });

  it('her without an outfit: her figure from her own body shots', () => {
    const p = planOn('genjutsu-light', X({ character: { kind: 'model', modelId: 'm' } }));
    expect(p.prompt).toContain('her body shape and proportions only from <Image 3> and <Image 4>');
    expect(p.prompt).toContain('KEEP: the outfit of the person in the clip, worn by her, the background and the light and colour; ');
  });

  it('background in words on Wan 2.7 Edit: the same-person lock, the words under CHANGE, inputs keep the sound; $1.00 for 10 s', () => {
    const p = planOn('wan-2.7-edit', X({ background: { mode: 'describe', words: 'a rooftop at golden hour' }, look: { words: 'warm, soft window light' } }));
    expect(p.prompt).toContain('FIGURE LOCK: the person in <Video 1> keeps their exact face, body, figure and proportions; never slimmer, taller or reshaped.');
    expect(p.prompt).toContain('BACKGROUND: replace the place as written under CHANGE.');
    expect(p.prompt).toContain('LOOK & LIGHT: relight and grade the whole scene as written under CHANGE');
    expect(p.prompt).toContain('KEEP: the same person and their outfit; the motion');
    expect(p.prompt).toContain('CHANGE: Background: a rooftop at golden hour. Look & light: warm, soft window light.');
    expect(buildInput(modelById('wan-2.7-edit')!, p, { middle: [], refs: [], videos: ['v'] })).toEqual({ prompt: p.prompt, video: 'v', resolution: '1080p', aspect_ratio: 'auto', audio_setting: 'origin' });
    expect([p.resolution, p.estimate]).toEqual(['1080p', 1]);
  });

  it('outfit from a product photo + look on Kling O1: 4-picture model, its own tokens; $1.26 for 10 s at 720p', () => {
    const p = planOn('kling-o1', X({ outfit: { kind: 'product', image: img('p') }, look: { words: 'night, neon, teal grade' } }));
    expect(p.prompt).toContain('OUTFIT: the person wears the garment in <<<image_1>>>, fitted to the body and the movement.');
    expect(p.prompt).toContain('KEEP: the same person and the background; ');
    expect(buildInput(modelById('kling-o1')!, p, { middle: [], refs: ['a'], videos: ['v'] })).toMatchObject({ reference_video: 'v', video_reference_type: 'base', keep_original_sound: true, mode: 'std' });
    expect(p.estimate).toBeCloseTo(1.26, 6);
  });

  it('face swap (optional): only the face changes; outfit words are never stripped as a look change', () => {
    const p = planOn('kling-o1', X({ character: { kind: 'face', image: img('f') }, outfit: { kind: 'words', words: 'a red dress with tattoos showing' } }));
    expect(p.prompt).toContain('FIGURE LOCK: only the face changes.');
    expect(p.prompt).toContain('FACE: the face of the person in <<<video_1>>> becomes the face in <<<image_1>>>');
    expect(p.prompt).toContain('CHANGE: Outfit: a red dress with tattoos showing.');
  });

  it('the trimmer: a long clip must be trimmed (priced at the model’s maximum until then); the range picks the part', () => {
    const x = X({ background: { mode: 'describe', words: 'snow' } });
    const long = planOn('wan-2.7-edit', x, { seconds: 24 });
    expect(long.remix).toMatchObject({ trimNeeded: true, maxSeconds: 10, range: [0, 10] });
    expect([long.seconds, long.estimate]).toEqual([10, 1]);
    const part = planOn('wan-2.7-edit', x, { seconds: 24, range: [5, 12] });
    expect(part.remix).toMatchObject({ range: [5, 12] });
    expect(part.remix!.trimNeeded).toBeUndefined();
    expect([part.seconds, part.estimate]).toEqual([7, 0.7]);
    expect(planOn('wan-2.7-edit', x, { seconds: 24, range: [0, 15] }).remix!.trimNeeded).toBe(true);
    expect(planOn('wan-2.7-edit', x, { seconds: 1.2 }).remix!.tooShort).toBe(true);
    expect(remixSpan(modelById('kling-v4')!, 24)).toMatchObject({ needed: false, seconds: 24 });
  });

  it('fillImages: one picture per group first, then the rest in order', () => {
    const g = (k: any, n: number) => ({ kind: k, images: Array.from({ length: n }, (_, i) => ({ label: `${k}${i}`, image: img(`${k}${i}`) })) });
    expect(fillImages([g('character', 2), g('outfit', 7), g('background', 1)], 4).groups.map(x => x.images.length)).toEqual([2, 1, 1]);
    expect(fillImages([g('character', 2), g('outfit', 7)], 1).groups.map(x => x.images.length)).toEqual([1, 0]);
  });
});

describe.skipIf(!hasFfmpeg)('New Swap · API and Claude on the mock provider', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, mia: { id: string }, dir: string, studioId: string;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner } = await people(a, 0, { topUp: 100 }) as any);
    mia = await demoModel(owner);
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-remix-'));
    const f = path.join(dir, 'src.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=180x320:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=330', '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', f]);
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    studioId = u!.studioId;
    await putObject(a.ctx, { key: 'clips/remix.mp4', body: fs.readFileSync(f), studioId, kind: 'clip', contentType: 'video/mp4' });
    await a.ctx.db.insert(clips).values({ id: 'c_six', studioId, name: 'six seconds', durationSec: 6, width: 180, height: 320, fps: 24, meta: {}, checks: [], storageKey: 'clips/remix.mp4', createdAt: Date.now() });
    // The same file declared longer, to check the trimmer's refusal without a long encode.
    await a.ctx.db.insert(clips).values({ id: 'c_long', studioId, name: 'long', durationSec: 24, width: 180, height: 320, fps: 24, meta: {}, checks: [], storageKey: 'clips/remix.mp4', createdAt: Date.now() });
  });
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const done = (id: string) => until(async () => { const j = (await owner.req('GET', `/v1/suite/shots/${id}`)).body.job; return j?.state === 'done' || j?.state === 'failed' ? j : null; }, 20_000);
  const BG = { background: { mode: 'describe', words: 'a rooftop at golden hour' } };

  it('estimate: Swap label, Auto’s reason, the part used, the trimmer and the built prompt', async () => {
    const e = await owner.req('POST', '/v1/suite/shots/estimate', { mode: 'remix', clipId: 'c_six', remix: BG });
    expect(e.status, JSON.stringify(e.body)).toBe(200);
    expect(e.body).toMatchObject({ mode: 'remix', label: 'Swap · Draft · 1080p', seconds: 6, estimate: 0.6,
      remix: { toggles: ['background'], why: 'Background only: Wan 2.7 Edit (keeps the sound, up to 10 s, 1080p)', tested: false, uses: { from: 0, to: 6, of: 6 }, trim: { needed: false, maxSeconds: 10 } },
      engine: { model: 'wan-2.7-edit', label: 'Wan 2.7 Edit · Replicate' } });
    expect(e.body.prompt).toContain('CHANGE: Background: a rooftop at golden hour.');
    expect(e.body.warnings.join()).toMatch(/hasn’t had a test run in MUSE yet/);
    const long = (await owner.req('POST', '/v1/suite/shots/estimate', { mode: 'remix', clipId: 'c_long', remix: BG })).body;
    expect(long.remix.trim).toEqual({ needed: true, tooShort: false, minSeconds: 2, maxSeconds: 10 });
    expect(long.estimate).toBe(1);
  });

  it('refusals: nothing on, a missing word, a model that can’t, a clip longer than the model takes (until trimmed)', async () => {
    const b = (x: object) => owner.req('POST', '/v1/suite/shots', { mode: 'remix', ...x });
    expect((await b({ clipId: 'c_six' })).body).toMatchObject({ code: 'remix_empty' });
    expect((await b({ clipId: 'c_six', remix: { look: { words: '' } } })).body).toMatchObject({ code: 'remix_incomplete' });
    expect((await b({ remix: BG })).body.error).toMatch(/needs the video/);
    expect((await b({ clipId: 'c_six', remix: BG, engineModel: 'genjutsu' })).body.code).toMatch(/remix_unsupported|engine_unavailable/);
    const t = await b({ clipId: 'c_long', remix: BG });
    expect(t.status).toBe(400);
    expect(t.body).toMatchObject({ code: 'remix_trim_needed' });
    expect(t.body.error).toMatch(/Trim the clip first: Wan 2.7 Edit · Replicate takes up to 10 s/);
  });

  it('runs on the mock: Wan 2.7 Edit’s inputs, only the trimmed part is sent, the take keeps the clip’s sound', async () => {
    const before = a.ctx.suite.mock.calls.length;
    const r = (await owner.req('POST', '/v1/suite/shots', { mode: 'remix', clipId: 'c_six', remix: BG, range: [1, 4] })).body;
    expect(r.request).toMatchObject({ engine: 'suite', mode: 'remix', clipId: 'c_six', range: [1, 4], remix: BG });
    expect(r.title).toBe('New Swap');
    const j = await done(r.id);
    expect(j.state, JSON.stringify(j.error ?? j)).toBe('done');
    const call = a.ctx.suite.mock.calls.slice(before)[0]!;
    expect(call.ref).toBe('wan-video/wan-2.7-videoedit');
    expect(call.input).toMatchObject({ resolution: '1080p', audio_setting: 'origin', aspect_ratio: 'auto' });
    expect(String(call.input.video)).toMatch(/source_part\.mp4/);
    const take = (await owner.req('GET', '/v1/takes')).body.find((t: any) => t.jobId === r.id);
    expect(take).toBeTruthy();
    // The clip's own sound was put back on the take (stream copy from the part used).
    const [trow] = await a.ctx.db.select().from(takes).where(eq(takes.id, take.id));
    const obj = await a.ctx.storage.get(trow!.mediaKey!);
    const tf = path.join(dir, 'take.mp4');
    await pipeline(obj!.body, fs.createWriteStream(tf));
    expect(execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=codec_type', '-of', 'csv=p=0', tf]).toString()).toMatch(/audio/);
    // A finished take becomes a New Swap source of its own (Library → clip), copied, not shared.
    const c = await owner.req('POST', '/v1/clips/from-take', { takeId: take.id });
    expect(c.status, JSON.stringify(c.body)).toBe(200);
    expect(c.body.durationSec).toBeGreaterThan(0);
    expect((await owner.req('GET', `/v1/clips/${c.body.id}`)).body).toMatchObject({ id: c.body.id, durationSec: c.body.durationSec });
    expect((await owner.req('GET', '/v1/clips/c_nope')).status).toBe(404);
    const [row] = await a.ctx.db.select().from(clips).where(eq(clips.id, c.body.id));
    expect(row!.storageKey).not.toBe(trow!.mediaKey);
  });

  it('the model pill: every video-editing model with support, limits and the price for this clip; Auto marked', async () => {
    const m = (await owner.req('POST', '/v1/suite/remix/models', { clipId: 'c_six', remix: BG })).body;
    expect(m.auto).toEqual({ model: 'wan-2.7-edit', why: 'Background only: Wan 2.7 Edit (keeps the sound, up to 10 s, 1080p)' });
    const wan = m.models.find((x: any) => x.model === 'wan-2.7-edit');
    expect(wan).toMatchObject({ support: 'yes', auto: true, tested: false, limits: { minSeconds: 2, maxSeconds: 10, keepsAudio: true }, price: { resolution: '1080p', perSec: 0.1, seconds: 6, usd: 0.6 } });
    const gj = m.models.find((x: any) => x.model === 'genjutsu-light');
    expect(gj.support).toBe('no');
    expect(gj.reason).toMatch(/turn on Character/);
  });

  it('Claude: switches Swap to New Swap, sets the clip and the toggles, prices it, and asks the owner to Approve', async () => {
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    const me = { id: u!.id, studioId, email: u!.email, role: 'owner' as const, studioName: 'Test Studio', sessionId: null };
    const svc = assistOf(a.ctx);
    const d = await svc.create(me as any, { draft: { v: 1, tool: 'swap' } }) as any;
    await expect(svc.set(me as any, d.id, { remix: BG })).rejects.toThrow(/switch to it first/);
    await svc.set(me as any, d.id, { swapVariant: 'new' });
    const v = await svc.set(me as any, d.id, { clipId: 'c_six', remix: { ...BG, character: { kind: 'model', modelId: mia.id } } }) as any;
    expect(v.draft.tool).toBe('remix');
    expect(v.request).toMatchObject({ mode: 'remix', clipId: 'c_six', remix: { character: { kind: 'model', modelId: mia.id } } });
    // A toggle set to null is switched off (kept from the clip).
    const off = await svc.set(me as any, d.id, { remix: { character: null } }) as any;
    expect(off.request.remix).toEqual(BG);
    const e = await svc.estimate(me as any, d.id) as any;
    expect(e.estimate).toMatchObject({ mode: 'remix', remix: { why: expect.stringMatching(/^Background only/) } });
    const p = await svc.ask(me as any, d.id);
    expect(p).toMatchObject({ kind: 'suite_request_shot', status: 'waiting' });
    await svc.set(me as any, d.id, { clipId: 'c_long' });
    await expect(svc.ask(me as any, d.id)).rejects.toThrow(/Trim the clip first/);
    await svc.set(me as any, d.id, { range: [0, 8] });
    expect((await svc.ask(me as any, d.id)).status).toBe('waiting');
    await expect(svc.set(me as any, d.id, { clipId: 'c_nope' })).rejects.toThrow(/no clip/);
  });
});
