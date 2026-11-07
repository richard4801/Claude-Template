// The new Suite's server pieces (workstream 1, plans/ai-suite-design.md build step 2): a full draft per job and photo
// ("Reuse settings"), saved rigs, a model's default rig and the takes feed. Mock video provider, fake image engine:
// no money.
import { execFileSync } from 'node:child_process';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { aspectOf, draftOf, DraftSchema, draftSummary, RigSchema } from '../src/suite/drafts.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();

const RIG = { body: 'film_35', lens: 'anamorphic', focalMm: 85, aperture: 'f1.4', height: 'low', shotSize: 'mcu', lighting: 'contre_jour', palette: 'golden_warmth', gradeLook: true,
  genre: 'fashion', era: '1990s', tempo: 'calm', moves: [{ id: 'dolly_in', intensity: 0.4 }] };
const DRAFT = { v: 1, tool: 'shot', quality: 'draft', aspect: '9:16', duration: 5, takes: 1, sound: true, speaking: null, rig: RIG,
  tokens: [{ text: 'She walks out to the street ' }, { key: 3, move: { id: 'dolly_in', label: 'Dolly in' } }], slots: { start: null } };

describe('Drafts and rigs (unit)', () => {
  it('a rig is catalog ids only (hidden and merged ids allowed), every row optional, at most 2 moves', () => {
    expect(RigSchema.parse(RIG)).toEqual(RIG);
    expect(RigSchema.parse({})).toEqual({});
    const bad = (x: object) => RigSchema.safeParse(x).success;
    expect(bad({ body: 'nope' })).toBe(false);
    expect(bad({ lighting: 'window', extra: 1 })).toBe(false);
    expect(bad({ focalMm: 400 })).toBe(false);
    expect(bad({ moves: [{ id: 'dolly_in' }, { id: 'orbit_left' }, { id: 'tilt_up' }] })).toBe(false);
    expect(bad({ moves: [{ id: 'rise_reveal' }] })).toBe(true);
    expect(RigSchema.safeParse({ era: '2077s' }).error?.issues[0]?.message).toBe('unknown era "2077s"');
  });

  it('a draft: the tool is required and known, the rest is kept as sent (≤ 64 KB)', () => {
    expect(DraftSchema.parse({ tool: 'photo', count: 4, custom: { x: 1 } })).toEqual({ v: 1, tool: 'photo', count: 4, custom: { x: 1 } });
    expect(DraftSchema.safeParse({ tool: 'video' }).success).toBe(false);
    expect(DraftSchema.safeParse({ tool: 'shot', tokens: [{ text: 'x'.repeat(70_000) }] }).success).toBe(false);
    expect(draftOf({})).toBeNull();
    expect(() => draftOf({ draft: { quality: 'hd' } })).toThrow(/Invalid draft: tool/);
  });

  it('the summary line reads like a caption; the aspect comes from the picture', () => {
    expect(draftSummary(DRAFT as any)).toBe('9:16, 5 s, 1 take, sound on');
    expect(draftSummary({ tool: 'shot', aspect: '16:9', duration: 7.5, takes: 2, sound: false } as any)).toBe('16:9, 7.5 s, 2 takes, sound off');
    expect(draftSummary({ tool: 'photo', aspect: '4:5', count: 1 } as any)).toBe('4:5, 1 photo');
    expect(draftSummary(null, { aspect: '9:16', count: 3 })).toBe('9:16, 3 photos');
    expect(draftSummary(null, { seconds: 10, takes: 1 })).toBe('10 s, 1 take');
    expect(aspectOf(768, 1344)).toBe('9:16');
    expect(aspectOf(1920, 1080)).toBe('16:9');
    expect(aspectOf(1080, 1350)).toBe('4:5');
    expect(aspectOf(0, 10)).toBeUndefined();
  });
});

describe('Saved rigs and the model default rig (API)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, other: Client;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock' });
    ({ owner, members: [member, other] } = await people(a, 2) as any);
  });
  afterAll(async () => { await a?.close(); });

  it('each member keeps their own rigs; the owner sees all of them, theirs first', async () => {
    const mine = await member.req('POST', '/v1/suite/rigs', { name: '  Golden film  ', rig: RIG });
    expect(mine.status).toBe(200);
    expect(mine.body).toMatchObject({ name: 'Golden film', rig: RIG, mine: true, userId: member.id });
    const theirs = (await other.req('POST', '/v1/suite/rigs', { name: 'Neon night', rig: { palette: 'hyper_neon', lighting: 'practicals' } })).body;
    const own = (await owner.req('POST', '/v1/suite/rigs', { name: 'Talking head', rig: { body: 'phone', lighting: 'ring_light', moves: [] } })).body;
    expect((await member.req('GET', '/v1/suite/rigs')).body.map((r: any) => r.name)).toEqual(['Golden film']);
    const all = (await owner.req('GET', '/v1/suite/rigs')).body;
    expect(all.map((r: any) => [r.name, r.mine])).toEqual([['Talking head', true], ['Neon night', false], ['Golden film', false]]);
    expect(own.mine).toBe(true);

    // Rename and change; another member's rig reads as not found; the owner may tidy any rig.
    const p = await member.req('PATCH', `/v1/suite/rigs/${mine.body.id}`, { name: 'Golden 35', rig: { ...RIG, era: '1970s' } });
    expect(p.body).toMatchObject({ name: 'Golden 35', rig: { era: '1970s' } });
    expect(p.body.updatedAt).toBeGreaterThanOrEqual(mine.body.updatedAt);
    expect((await member.req('PATCH', `/v1/suite/rigs/${theirs.id}`, { name: 'Mine now' })).status).toBe(404);
    expect((await member.req('DELETE', `/v1/suite/rigs/${theirs.id}`)).status).toBe(404);
    expect((await owner.req('PATCH', `/v1/suite/rigs/${theirs.id}`, { name: 'Neon' })).body.name).toBe('Neon');
    expect((await owner.req('DELETE', `/v1/suite/rigs/${theirs.id}`)).status).toBe(204);
    expect((await other.req('GET', '/v1/suite/rigs')).body).toEqual([]);
  });

  it('refuses unknown ids, an empty name and unknown fields', async () => {
    const bad = await member.req('POST', '/v1/suite/rigs', { name: 'x', rig: { lens: 'fisheye_9000' } });
    expect(bad.status).toBe(400);
    expect(bad.body.error).toMatch(/rig\.lens: unknown lens "fisheye_9000"/);
    expect((await member.req('POST', '/v1/suite/rigs', { name: '  ', rig: {} })).body.error).toMatch(/Give the rig a name/);
    expect((await member.req('POST', '/v1/suite/rigs', { name: 'x', rig: {}, shared: true })).status).toBe(400);
    expect((await member.req('PATCH', '/v1/suite/rigs/rig_nope', { name: 'x' })).status).toBe(404);
  });

  it('a model carries an optional default rig: set, returned with the model, cleared with null', async () => {
    const m = await demoModel(owner);
    const r = await member.req('PATCH', `/v1/models/${m.id}`, { defaultRig: { body: 'film_35', palette: 'golden_warmth', moves: [{ id: 'orbit_left' }] } });
    expect(r.status).toBe(200);
    expect(r.body.defaultRig).toEqual({ body: 'film_35', palette: 'golden_warmth', moves: [{ id: 'orbit_left' }] });
    expect((await owner.req('GET', '/v1/models')).body.find((x: any) => x.id === m.id).defaultRig).toMatchObject({ body: 'film_35' });
    expect((await member.req('PATCH', `/v1/models/${m.id}`, { defaultRig: { body: 'vhs_9000' } })).status).toBe(400);
    expect((await member.req('PATCH', `/v1/models/${m.id}`, { name: 'Renamed' })).body.defaultRig).toMatchObject({ body: 'film_35' }); // untouched
    expect((await member.req('PATCH', `/v1/models/${m.id}`, { defaultRig: null })).body.defaultRig).toBeUndefined();
    expect((await member.req('PATCH', `/v1/models/${m.id}`, { defaultRig: {} })).body.defaultRig).toBeUndefined(); // all Auto = none
  });
});

describe.skipIf(!hasFfmpeg)('Drafts per job and the takes feed (mock provider, fake image engine)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, model: { id: string }, model2: { id: string };
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    model = await demoModel(owner);
    model2 = await demoModel(owner);
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: member.id, tokens: 2000 });
  });
  afterAll(async () => { await a?.close(); });
  const done = (id: string) => until(async () => { const j = (await owner.req('GET', `/v1/suite/shots/${id}`)).body.job; return j?.state === 'done' || j?.state === 'failed' ? j : null; }, 20_000);

  it('a shot keeps its draft on the job and on every take; a bad draft is refused before anything is held', async () => {
    const r = await member.req('POST', '/v1/suite/shots', { modelId: model.id, prompt: 'She walks out to the street.', duration: 5, quality: 'draft', takes: 2, draft: { ...DRAFT, takes: 2 } });
    expect(r.status).toBe(200);
    expect(r.body.draft).toEqual({ ...DRAFT, takes: 2 });
    expect(r.body.request.draft).toBeUndefined(); // stored on its own, not in the request
    const j = await done(r.body.id);
    expect(j.state).toBe('done');
    const ts = (await member.req('GET', '/v1/takes')).body.filter((t: any) => t.jobId === r.body.id);
    expect(ts).toHaveLength(2);
    for (const t of ts) expect(t.draft).toEqual({ ...DRAFT, takes: 2 });
    expect((await member.req('GET', '/v1/jobs')).body.find((x: any) => x.id === r.body.id).draft.tool).toBe('shot');
    const bad = await member.req('POST', '/v1/suite/shots', { modelId: model.id, prompt: 'x', duration: 5, quality: 'draft', draft: { tool: 'hologram' } });
    expect(bad.status).toBe(400);
    expect(bad.body.error).toMatch(/^Invalid draft: tool/);
  });

  it('photos keep their draft on every still; no draft stays no draft', async () => {
    const p = (await member.req('POST', '/v1/suite/photos', { modelId: model2.id, prompt: 'A café window seat.', count: 2,
      draft: { tool: 'photo', aspect: '9:16', count: 2, rig: { lighting: 'window' }, tokens: [{ text: 'A café window seat.' }] } })).body;
    expect(p.takes).toHaveLength(2);
    for (const t of p.takes) expect(t.draft).toMatchObject({ tool: 'photo', count: 2, rig: { lighting: 'window' } });
    const plain = (await member.req('POST', '/v1/suite/photos', { modelId: model2.id, count: 1 })).body;
    expect(plain.takes[0].draft).toBeUndefined();
    expect((await member.req('POST', '/v1/suite/photos', { modelId: model2.id, count: 1, draft: { tool: 'photo', tokens: 'nope' } })).status).toBe(400);
  });

  it('the feed: newest first; queued, running and failed jobs as one card, each take or photo as its own; filters; member-safe', async () => {
    // A queued job (held, not started) sits at the top.
    const q = (await owner.req('POST', '/v1/jobs', { modelId: model.id, clipId: 'clip_sample', queue: true, title: 'Queued swap', draft: { tool: 'swap', aspect: '9:16' } })).body;
    const f = (await member.req('GET', '/v1/suite/feed')).body;
    expect(f.nextCursor).toBeNull();
    const kinds = f.items.map((x: any) => `${x.kind}:${x.tool}:${x.status}`);
    expect(kinds[0]).toBe('job:swap:queued');
    expect(kinds.filter((k: string) => k === 'photo:photo:done')).toHaveLength(3);
    expect(kinds.filter((k: string) => k === 'take:shot:done')).toHaveLength(2);
    const times = f.items.map((x: any) => x.createdAt);
    expect([...times].sort((x: number, y: number) => y - x)).toEqual(times);
    expect(f.items[0]).toMatchObject({ id: q.id, jobId: q.id, title: 'Queued swap', aspect: '9:16', price: q.cost, modelId: model.id, modelName: 'Demo model' });
    const take = f.items.find((x: any) => x.kind === 'take');
    expect(take).toMatchObject({ status: 'done', aspect: '9:16', summary: '9:16, 5 s, 2 takes, sound on', final: false, modelName: 'Demo model' });
    expect(take.videoUrl).toMatch(/\/uploads\//);
    expect(take.poster).toBeTruthy();
    expect(take.durationSec).toBeGreaterThan(4);
    const photo = f.items.find((x: any) => x.kind === 'photo');
    expect(photo).toMatchObject({ aspect: '9:16', poster: expect.anything() });
    expect(photo.videoUrl).toBeUndefined();
    expect(JSON.stringify(f)).not.toMatch(/\b(replicate|fal|runpod|minimax|kling|seedance|veo|wan-2|ltx)\b/i);

    // Filters: tool, status, model (combinable; comma lists).
    const only = async (qs: string) => (await member.req('GET', `/v1/suite/feed?${qs}`)).body.items.map((x: any) => `${x.kind}:${x.tool}:${x.status}`);
    expect(new Set(await only('tool=photo'))).toEqual(new Set(['photo:photo:done']));
    expect(await only('status=queued')).toEqual(['job:swap:queued']);
    expect(new Set(await only('status=done&tool=shot,swap'))).toEqual(new Set(['take:shot:done']));
    expect((await only(`model=${model2.id}`)).every((k: string) => k.startsWith('photo'))).toBe(true);
    expect((await member.req('GET', '/v1/suite/feed?status=lost')).status).toBe(400);
    expect((await member.req('GET', '/v1/suite/feed?tool=video')).status).toBe(400);

    // Hidden (deleted from Queue) jobs drop out with their takes.
    await owner.req('DELETE', `/v1/jobs/${q.id}`);
    expect((await only('status=queued'))).toEqual([]);
  });

  it('pages with a cursor: every item once, in order, until nextCursor is null', async () => {
    const all = (await member.req('GET', '/v1/suite/feed')).body.items.map((x: any) => x.id);
    const seen: string[] = [];
    let cursor: string | null = null, pages = 0;
    do {
      const r: any = (await member.req('GET', `/v1/suite/feed?limit=2${cursor ? `&cursor=${cursor}` : ''}`)).body;
      expect(r.items.length).toBeLessThanOrEqual(2);
      seen.push(...r.items.map((x: any) => x.id));
      cursor = r.nextCursor;
      pages++;
    } while (cursor && pages < 20);
    expect(seen).toEqual(all);
    expect(pages).toBe(Math.ceil(all.length / 2));
    expect((await member.req('GET', '/v1/suite/feed?cursor=bm9wZQ')).status).toBe(400);
    expect((await member.req('GET', '/v1/suite/feed?limit=500')).status).toBe(400);
  });
});
