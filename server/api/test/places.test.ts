// Her world, phase 1 (plans/model-world.md §1, §5, §6): places on her page, @tag in Shot and Photo, priced place photos,
// "Studio places" kept, Copy to another model, and Claude's tools.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { demoModel, makeApp, people, type Client } from './helpers.js';
import { placeSetting, placePrompt, resolvePlace, slugTag } from '../src/suite/locations.js';
import { buildPlan, needOf, ShotRequestSchema } from '../src/suite/plan.js';
import { modelById } from '../src/suite/registry.js';
import { registryByName } from '../src/claude/registry.js';
import { sql } from 'drizzle-orm';

describe('her world · places', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, other: Client;
  let her: { id: string }, second: { id: string };
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock' });
    ({ owner, members: [member, other] } = await people(a, 2) as any);
    her = await demoModel(owner);
    second = (await owner.req('POST', '/v1/models', { name: 'Second', age: 25, niche: 'Fitness' })).body;
  });
  afterAll(async () => { await a?.close(); });
  const asUser = async (c: Client, role: 'owner' | 'member') => {
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${c.id}`)) as any).rows[0].studio_id;
    return { id: c.id, studioId, email: '', role, studioName: 'Test Studio', sessionId: null } as any;
  };
  const tool = async (c: Client, role: 'owner' | 'member', name: string, args: Record<string, unknown>) =>
    registryByName.get(name)!.run({ ctx: a.ctx, user: await asUser(c, role), source: 'chat' } as any, args) as Promise<any>;

  it('slugs a tag from the name', () => {
    expect(slugTag('Café by the gym')).toBe('cafe-by-the-gym');
    expect(slugTag('  !!! ')).toBe('place');
  });

  it('her place starts empty, gets a tag, and lists before the studio’s', async () => {
    const studio = (await member.req('POST', '/v1/suite/locations', { name: 'Rooftop', image: { asset: 'g_front' } })).body;
    expect(studio).toMatchObject({ scope: 'studio', modelId: null, tag: 'rooftop', images: [{ asset: 'g_front', source: 'upload' }], cover: 0 });
    const r = await member.req('POST', '/v1/suite/locations', { name: 'Café by the gym', modelId: her.id, tag: '@Cafe', description: 'Corner café with a striped awning, wet cobbles, warm window light' });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ scope: 'model', modelId: her.id, tag: 'cafe', images: [], image: {} });
    const list = (await other.req('GET', `/v1/suite/locations?modelId=${her.id}`)).body;
    expect(list.map((l: any) => l.name)).toEqual(['Café by the gym', 'Rooftop']);
    // A studio place needs a photo (as before); a tag is unique in her places.
    expect((await member.req('POST', '/v1/suite/locations', { name: 'Bare' })).status).toBe(400);
    const dupe = await member.req('POST', '/v1/suite/locations', { name: 'Other café', modelId: her.id, tag: 'cafe' });
    expect(dupe.status).toBe(409);
    expect(dupe.body.error?.code ?? dupe.body.code).toBe('tag_taken');
    // The same tag on the studio's or another model's is fine; an auto tag gets -2.
    expect((await member.req('POST', '/v1/suite/locations', { name: 'Cafe', modelId: second.id })).body.tag).toBe('cafe');
    expect((await member.req('POST', '/v1/suite/locations', { name: 'Cafe', modelId: second.id })).body.tag).toBe('cafe-2');
    expect((await member.req('POST', '/v1/suite/locations', { name: 'X', modelId: 'nope' })).status).toBe(404);
  });

  it('photos: add up to 8, pick the cover, remove (the one who added it or the owner)', async () => {
    const p = (await member.req('POST', '/v1/suite/locations', { name: 'Gym', modelId: her.id, image: { asset: 'g_tq' } })).body;
    for (const k of ['g_side', 'g_back']) expect((await other.req('POST', `/v1/suite/locations/${p.id}/images`, { image: { asset: k } })).status).toBe(200);
    let v = (await member.req('PATCH', `/v1/suite/locations/${p.id}`, { cover: 2, name: 'Gym downstairs', tag: 'gym', description: 'Mirrors and rubber floor' })).body;
    expect(v).toMatchObject({ name: 'Gym downstairs', tag: 'gym', cover: 2, image: { asset: 'g_back' } });
    expect((await member.req('PATCH', `/v1/suite/locations/${p.id}`, { cover: 7 })).status).toBe(400);
    expect((await other.req('DELETE', `/v1/suite/locations/${p.id}/images/0`)).status).toBe(403);
    v = (await member.req('DELETE', `/v1/suite/locations/${p.id}/images/0`)).body;
    expect(v.images.map((i: any) => i.asset)).toEqual(['g_side', 'g_back']);
    expect(v.cover).toBe(1); // still the same photo
    for (let i = 0; i < 6; i++) await member.req('POST', `/v1/suite/locations/${p.id}/images`, { image: { asset: 'face' } });
    const full = await member.req('POST', `/v1/suite/locations/${p.id}/images`, { image: { asset: 'face' } });
    expect(full.status).toBe(409);
    expect((await owner.req('DELETE', `/v1/suite/locations/${p.id}/images/7`)).status).toBe(200);
  });

  it('Copy to another model keeps the photos and the tag when it is free', async () => {
    const src = (await member.req('POST', '/v1/suite/locations', { name: 'Bedroom', modelId: her.id, image: { asset: 'g_front' }, description: 'White sheets' })).body;
    const c = await other.req('POST', `/v1/suite/locations/${src.id}/copy`, { modelId: second.id });
    expect(c.status).toBe(200);
    expect(c.body).toMatchObject({ name: 'Bedroom', tag: 'bedroom', modelId: second.id, description: 'White sheets', images: [{ asset: 'g_front' }] });
    expect(c.body.id).not.toBe(src.id);
    expect((await other.req('POST', `/v1/suite/locations/${src.id}/copy`, { modelId: second.id })).body.tag).toBe('bedroom-2');
    expect((await other.req('POST', `/v1/suite/locations/${src.id}/copy`, { modelId: her.id })).status).toBe(400);
  });

  it('a place photo is priced first, refused above the approved price, and never charged more', async () => {
    const p = (await owner.req('POST', '/v1/suite/locations', { name: 'Kitchen', modelId: her.id, description: 'Small white kitchen, morning sun' })).body;
    // Random needs a photo to start from.
    expect((await owner.req('POST', `/v1/suite/locations/${p.id}/generate/estimate`, { mode: 'random' })).status).toBe(409);
    const e = await owner.req('POST', `/v1/suite/locations/${p.id}/generate/estimate`, { mode: 'description' });
    expect(e.status).toBe(200);
    expect(e.body.estimate).toBeGreaterThan(0);
    expect(e.body.buttonLabel).toBe(`Generate · $${e.body.estimate.toFixed(2)}`);
    expect(e.body.prompt).toMatch(/No people/);
    const low = await owner.req('POST', `/v1/suite/locations/${p.id}/generate`, { mode: 'description', maxUsd: e.body.estimate / 10 });
    expect(low.status).toBe(409);
    expect(low.body.error?.code ?? low.body.code).toBe('price_changed');
    const before = (await owner.req('GET', '/v1/wallet')).body;
    const g = await owner.req('POST', `/v1/suite/locations/${p.id}/generate`, { mode: 'description', maxUsd: e.body.estimate });
    expect(g.status).toBe(200);
    expect(g.body.place.images).toHaveLength(1);
    expect(g.body.place.images[0].source).toBe('description');
    expect(g.body.chargedUsd).toBeLessThanOrEqual(e.body.estimate);
    const after = (await owner.req('GET', '/v1/wallet')).body;
    if (typeof before?.balanceUsd === 'number') expect(before.balanceUsd - after.balanceUsd).toBeLessThanOrEqual(e.body.estimate + 1e-6);
    // Now a random view and a rebuild from a reference work too.
    const r = await owner.req('POST', `/v1/suite/locations/${p.id}/generate`, { mode: 'random' });
    expect(r.status).toBe(200);
    expect(r.body.place.images.map((i: any) => i.source)).toEqual(['description', 'random']);
    expect((await owner.req('POST', `/v1/suite/locations/${p.id}/generate/estimate`, { mode: 'reference' })).status).toBe(200); // priced before a picture is picked
    expect((await owner.req('POST', `/v1/suite/locations/${p.id}/generate`, { mode: 'reference' })).status).toBe(400);
    expect((await owner.req('POST', `/v1/suite/locations/${p.id}/generate`, { mode: 'reference', reference: { asset: 'g_front' } })).body.place.images).toHaveLength(3);
  });

  it('place prompts never ask for people', () => {
    for (const mode of ['random', 'description', 'reference'] as const) expect(placePrompt({ name: 'Café', description: 'striped awning' }, { mode })).toMatch(/No people/);
    expect(placeSetting({ id: 'x', name: 'Café by the gym', tag: 'cafe', description: 'Corner café with a striped awning.', image: null })).toBe('Setting: Café by the gym, corner café with a striped awning.');
  });

  it('@tag resolves to her place first, then the studio’s; e-mails are not tags', async () => {
    const user = await asUser(owner, 'owner');
    const r1 = await resolvePlace(a.ctx, user, { prompt: 'She sips coffee at @cafe, mail me@cafe.com', modelId: her.id });
    expect(r1.place?.name).toBe('Café by the gym');
    expect(r1.prompt).toBe('She sips coffee at Café by the gym, mail me@cafe.com');
    const r2 = await resolvePlace(a.ctx, user, { prompt: 'Up on the @rooftop', modelId: her.id });
    expect(r2.place?.name).toBe('Rooftop');
    const r3 = await resolvePlace(a.ctx, user, { prompt: 'At @cafe', modelId: null });
    expect(r3.place).toBeNull(); // her place isn't the studio's
  });

  it('Shot: the tagged place goes after her images as the location reference', async () => {
    const cafe = (await owner.req('GET', `/v1/suite/locations?modelId=${her.id}`)).body.find((l: any) => l.tag === 'cafe');
    await member.req('POST', `/v1/suite/locations/${cafe.id}/images`, { image: { asset: 'c_face' } });
    const job = await owner.req('POST', '/v1/suite/shots', { modelId: her.id, prompt: 'She sips coffee at @cafe.', duration: 5, quality: 'standard', mode: 'reference' });
    expect(job.status).toBe(200);
    const plan = ((await a.ctx.jobs.get(job.body.id))!.stats as any).suite.plan;
    const refs = plan.images.refs as { role: string; label: string; image: any }[];
    expect(refs.at(-1)).toEqual({ label: 'Café by the gym', role: 'location', image: { asset: 'c_face' } });
    expect(refs.findIndex(x => x.role === 'location')).toBeGreaterThan(refs.findIndex(x => x.role === 'character'));
    expect(plan.prompt).toContain('Café by the gym');
    expect(plan.prompt).not.toContain('@cafe');
  });

  it('Shot: with no room the place is described in words (her images stay)', () => {
    const r = ShotRequestSchema.parse({ prompt: 'She sips coffee at Café by the gym.', mode: 'reference', duration: 5 });
    const character = { name: 'Zel', look: 'dark hair', neverAdd: [], images: ['face, front', 'face, profile', 'body, front', 'body, ¾'].map(label => ({ label, image: { asset: label } })) };
    const place = { name: 'Café by the gym', image: { asset: 'cafe' }, words: 'Setting: Café by the gym, corner café with a striped awning.' };
    const m = modelById('kling-v3-omni')!;
    const small = { ...m, refs: { ...m.refs, images: 4, totalImages: undefined } };
    const pick = { model: small, resolution: small.resolutions[0]!, seconds: 5, tried: [] } as any;
    const plan = buildPlan(r, needOf(r, character as any), pick, character as any, { place });
    expect(plan.images.refs.filter(x => x.role === 'character')).toHaveLength(4);
    expect(plan.images.refs.some(x => x.role === 'location')).toBe(false);
    expect(plan.prompt).toContain('striped awning');
    expect(plan.notes.join(' ')).toMatch(/Café by the gym is described in words/);
    // With room it is sent, and the prompt names it as the location.
    const roomy = { ...pick, model: { ...small, refs: { ...small.refs, images: 7 } } };
    const p2 = buildPlan(r, needOf(r, character as any), roomy, character as any, { place });
    expect(p2.images.refs.at(-1)).toMatchObject({ role: 'location', label: 'Café by the gym' });
    expect(p2.prompt).not.toContain('striped awning');
  });

  it('Shot: a place past the included images shows its price (MiniMax H3 · Higgsfield over 5)', () => {
    const r = ShotRequestSchema.parse({ prompt: 'At the café.', mode: 'reference', duration: 5 });
    const character = { name: 'Zel', look: '', neverAdd: [], images: ['face, front', 'face, profile', 'body, front', 'body, ¾', 'body, side'].map(label => ({ label, image: { asset: label } })) };
    const m = modelById('h3-hf')!;
    const pick = { model: m, resolution: m.resolutions[0]!, seconds: 5, tried: [] } as any;
    const without = buildPlan(r, needOf(r, character as any), pick, character as any, {});
    const withPlace = buildPlan(r, needOf(r, character as any), pick, character as any, { place: { name: 'Café', image: { asset: 'cafe' }, words: 'Setting: Café.' } });
    expect(withPlace.images.refs).toHaveLength(without.images.refs.length + 1);
    expect(withPlace.extraPerTake - without.extraPerTake).toBeCloseTo(0.08, 5);
    expect(withPlace.notes.join(' ')).toMatch(/past the 5 included add \$0\.08 per take/);
  });

  it('Photo: @tag sends the place as the scene reference', async () => {
    const e = await member.req('POST', '/v1/suite/photos/estimate', { modelId: her.id, prompt: 'Coffee at @cafe', count: 1 });
    expect(e.status).toBe(200);
    const sent = e.body.sentImages?.images ?? [];
    expect(sent.some((x: any) => x.image?.asset === 'c_face')).toBe(true);
    expect(e.body.prompt ?? '').not.toContain('@cafe');
  });

  it('Photo: a place with no photo is described in words', async () => {
    await member.req('POST', '/v1/suite/locations', { name: 'Park bench', modelId: her.id, tag: 'park', description: 'Green bench under plane trees' });
    const e = await member.req('POST', '/v1/suite/photos/estimate', { modelId: her.id, prompt: 'Reading on @park', count: 1 });
    expect(e.status).toBe(200);
    expect(e.body.warnings.join(' ')).toMatch(/Park bench is described in words/);
    expect(e.body.prompt).toMatch(/plane trees/);
  });

  it('unknown placeId is refused', async () => {
    expect((await member.req('POST', '/v1/suite/photos/estimate', { modelId: her.id, prompt: 'x', placeId: 'loc_nope', count: 1 })).status).toBe(400);
  });

  it('Claude: places tool (free) and place_make_photo behind Approve, with the price', async () => {
    const made = await tool(member, 'member', 'places', { action: 'create', name: 'Her balcony', modelId: her.id, description: 'Small balcony with plants' });
    expect(made).toMatchObject({ name: 'Her balcony', tag: 'her-balcony', modelId: her.id });
    const list = await tool(member, 'member', 'places', { action: 'list', modelId: her.id });
    expect(JSON.stringify(list)).toContain('Her balcony');
    expect(await tool(member, 'member', 'places', { action: 'update', placeId: made.id, tag: 'balcony' })).toMatchObject({ tag: 'balcony' });
    const quote = await tool(owner, 'owner', 'place_make_photo', { placeId: made.id, mode: 'description' });
    expect(quote.needsConfirmation).toBe(true);
    expect(quote.estimateUsd).toBeGreaterThan(0);
    const ask = await tool(owner, 'owner', 'place_make_photo', { placeId: made.id, mode: 'description', confirm: true });
    expect(ask.waitingForApproval).toBe(true);
    const stored = ((await a.ctx.db.execute(sql`select call from claude_actions where id = ${ask.actionId}`)) as any).rows[0].call;
    expect(stored.body.maxUsd).toBe(quote.estimateUsd);
    // Nothing is made before Approve.
    expect((await owner.req('GET', `/v1/suite/locations/${made.id}`)).body.images).toHaveLength(0);
    const ok = await owner.req('POST', `/v1/claude/actions/${ask.actionId}`, { approve: true });
    expect(ok.body.status).toBe('done');
    expect((await owner.req('GET', `/v1/suite/locations/${made.id}`)).body.images).toHaveLength(1);
  });
});
