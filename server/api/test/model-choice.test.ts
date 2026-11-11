// WS13 · model choice everywhere (plans/model-choice.md): the owner catalog per purpose, overrides on every generate
// endpoint (accepted, refused, priced, hidden from members) and the studio's default per purpose. Fakes only: the mock
// Suite provider, the simulated GPU, a FAKE Replicate on localhost. No live provider calls, no spend.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'drizzle-orm';
import { clips } from '../src/db/schema.js';
import * as P from '../src/pricing.js';
import { purposeOfShot, PURPOSES, SWAP_ENGINES, videoPurposes } from '../src/engines/purposes.js';
import { modelById } from '../src/suite/registry.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';
import { fakeReplicate, TOKEN } from './fakeReplicate.js';

/** Words a member's run estimate (no model picked) never carries. */
const PROVIDER_WORDS = /\b(replicate|fal|runpod|minimax|h3|kling|seedance|veo|wan|ltx|lightricks|bytedance|google|sora|seedvr|whisperx|demucs|viggle|flux)\b/i;
/** 4c: what members never see, whatever the studio settings: keys, prices at cost, markups, licence lines. */
const OWNER_ONLY_WORDS = /costUsd|priceScale|apiKey|last4|"notice"|"members"|browsed/;
const UPSCALE = JSON.stringify({ '1080p': { usdPerSec: 0.02, gpuSecPerSec: 8 }, '2k': { usdPerSec: 0.04, gpuSecPerSec: 15 } });

describe('model choice · purposes (unit)', () => {
  it('each registry model serves the purposes its capabilities allow', () => {
    expect(videoPurposes(modelById('h3')!)).toEqual(['shot', 'talking', 'ugc', 'storyboard', 'guide', 'fill']);
    expect(videoPurposes(modelById('kling-v4')!)).toEqual(expect.arrayContaining(['shot', 'ugc', 'guide', 'recast', 'extend']));
    expect(videoPurposes(modelById('kling-v4')!)).not.toContain('talking'); // no reference audio
    expect(videoPurposes(modelById('h3-max-recast')!)).toEqual(['recast']);
    expect(videoPurposes(modelById('h3-max-3d')!)).toEqual(['guide']);
    expect(videoPurposes(modelById('veo-3.1-lite')!)).not.toContain('guide');
    expect(videoPurposes(modelById('seedance-2.5')!)).toContain('extend');
  });
  it('a shot request maps to its purpose', () => {
    expect(purposeOfShot({ mode: 'swap' })).toBe('swap');
    expect(purposeOfShot({ cast: [{}] })).toBe('recast');
    expect(purposeOfShot({ extend: {} })).toBe('extend');
    expect(purposeOfShot({ camera: { mode: 'directed' } })).toBe('guide');
    expect(purposeOfShot({ references: { audio: {} } })).toBe('talking');
    expect(purposeOfShot({ draft: { tool: 'ugc_ad' } })).toBe('ugc');
    expect(purposeOfShot({ draft: { tool: 'storyboard' } })).toBe('storyboard');
    expect(purposeOfShot({})).toBe('shot');
  });
  it('swap engines: the hosted H3 family (registry prices) and Edit / Fast on our GPU', () => {
    expect(SWAP_ENGINES.map(e => e.id)).toEqual(['h3', 'h3-lite', 'h3-highspeed', 'h3-hf', 'h3-open', 'viggle']);
    for (const e of SWAP_ENGINES.filter(x => x.runs !== 'gpu')) { const ref = modelById(e.id)?.ref; expect(typeof ref === 'string' ? ref : (ref as { ref2v?: string })?.ref2v).toBe(e.ref); }
  });
});

describe('model choice · API (mock Suite, simulated GPU, fake Replicate)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, fake: Awaited<ReturnType<typeof fakeReplicate>>, char: { id: string };
  beforeAll(async () => {
    fake = await fakeReplicate();
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10', REPLICATE_API_TOKEN: TOKEN, REPLICATE_API_URL: fake.base, REPLICATE_WEB_URL: fake.web,
      UPSCALE_PRICES: UPSCALE, BALANCE_MODE: 'simulated' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    char = await demoModel(owner);
    const [o] = await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`).then((r: any) => r.rows ?? r);
    await a.ctx.db.insert(clips).values({ id: 'c_swap', studioId: o.studio_id, name: 'dance', durationSec: 7.2, width: 720, height: 1280, fps: 30, meta: {}, checks: [],
      storageKey: 'clips/dance.mp4', createdAt: Date.now() });
  });
  afterAll(async () => { await a?.close(); await fake?.close(); });

  it('GET /v1/engines: every purpose with its default; entries carry kind, purposes, limits, price and inputs', async () => {
    const r = await owner.req('GET', '/v1/engines');
    expect(r.status).toBe(200);
    expect(r.body.purposes.map((p: any) => p.id)).toEqual([...PURPOSES]);
    const def = Object.fromEntries(r.body.purposes.map((p: any) => [p.id, p.default]));
    expect(def).toMatchObject({ swap: 'h3', recast: 'wan-2.2-animate', extend: 'wan-2.7', upscale: 'seedvr2', shot: 'h3-lite', photo: a.ctx.config.REPLICATE_IMAGE_MODEL });
    const h3 = r.body.engines.find((e: any) => e.model === 'h3');
    expect(h3).toMatchObject({ kind: 'video', provider: 'replicate', custom: false, price: { basis: 'per_second' }, limits: { minSeconds: 4, maxSeconds: 15 } });
    expect(h3.purposes).toEqual(expect.arrayContaining(['shot', 'talking', 'swap', 'fill']));
    expect(r.body.engines.find((e: any) => e.model === 'h3-open')).toMatchObject({ purposes: ['swap', 'fill'], provider: 'runpod', notice: expect.stringMatching(/MiniMax H3/) });
    expect(r.body.engines.find((e: any) => e.model === 'seedvr2')).toMatchObject({ kind: 'tool', price: { basis: 'per_output_second', usd: 0.02 } });
    for (const p of ['matte', 'track', 'captions', 'denoise']) expect(r.body.engines.some((e: any) => e.purposes.includes(p)), p).toBe(true);
    expect((await owner.req('GET', '/v1/engines?purpose=nope')).status).toBe(400);
  });

  it('?purpose= lists only that purpose\'s candidates and marks the default', async () => {
    const swap = (await owner.req('GET', '/v1/engines?purpose=swap')).body;
    expect(swap.engines.map((e: any) => e.model)).toEqual(['h3', 'h3-lite', 'h3-highspeed', 'h3-open', 'viggle']);
    expect(swap.engines.filter((e: any) => e.default).map((e: any) => e.model)).toEqual(['h3']);
    const talk = (await owner.req('GET', '/v1/engines?purpose=talking')).body.engines.map((e: any) => e.model);
    expect(talk).toContain('h3');
    expect(talk).not.toContain('kling-v4');
    const recast = (await owner.req('GET', '/v1/engines?purpose=recast')).body.engines.map((e: any) => e.model);
    expect(recast).toEqual(expect.arrayContaining(['kling-v4', 'kling-o1', 'wan-2.2-animate', 'h3-max-recast']));
    const outfit = (await owner.req('GET', '/v1/engines?purpose=outfit')).body.engines;
    expect(outfit.every((e: any) => e.kind === 'image')).toBe(true);
    expect(outfit.find((e: any) => e.default).model).toBe(a.ctx.config.REPLICATE_IMAGE_MODEL);
  });

  it('members (4c): every video and image model not hidden, with provider names while the studio shows them; no tools, defaults or owner-only fields', async () => {
    const r = await member.req('GET', '/v1/engines');
    expect(r.status).toBe(200);
    const ids = r.body.engines.map((e: any) => e.model);
    expect(ids).toEqual(expect.arrayContaining(['kling-v4', 'h3', 'h3-lite', 'h3-open']));
    expect(r.body.engines.every((e: any) => e.kind === 'video' || e.kind === 'image')).toBe(true);
    expect(r.body.engines.find((e: any) => e.model === 'kling-v4')).toMatchObject({ provider: expect.any(String), providerName: expect.any(String) });
    expect(r.body.purposes.every((p: any) => p.default === null && p.studioDefault === null)).toBe(true);
    expect(JSON.stringify(r.body)).not.toMatch(OWNER_ONLY_WORDS);
    expect(r.body.memberSettings).toBeUndefined();
    expect((await member.req('GET', '/v1/engines/defaults')).status).toBe(403);
    // The owner's switches: members can't see or change them.
    expect((await member.req('GET', '/v1/engines/members')).status).toBe(403);
    expect((await member.req('PATCH', '/v1/engines/members', { showProviderNames: false })).status).toBe(403);
    const ow = (await owner.req('GET', '/v1/engines')).body;
    expect(ow.memberSettings).toEqual({ showProviderNames: true });
    expect(ow.engines.find((e: any) => e.model === 'kling-v4').members).toBe(true);
    // Provider names off and Kling hidden: gone from the member's list and refused when picked; the owner still has it.
    const off = await owner.req('PATCH', '/v1/engines/members', { showProviderNames: false, hidden: { 'kling-v4': true } });
    expect(off.status).toBe(200);
    expect(off.body.showProviderNames).toBe(false);
    expect(off.body.models.find((m: any) => m.model === 'kling-v4').members).toBe(false);
    const hid = (await member.req('GET', '/v1/engines')).body;
    expect(hid.engines.map((e: any) => e.model)).not.toContain('kling-v4');
    expect(JSON.stringify(hid)).not.toMatch(/"provider(Name)?"/);
    expect((await member.req('GET', '/v1/suite/catalog')).body.engines.some((e: any) => e.model === 'kling-v4' || e.provider)).toBe(false);
    const shot = { modelId: char.id, prompt: 'She smiles.', duration: 5, quality: 'standard', engineModel: 'kling-v4' };
    expect((await member.req('POST', '/v1/suite/shots/estimate', shot)).status).toBe(403);
    expect((await owner.req('POST', '/v1/suite/shots/estimate', shot)).status).toBe(200);
    expect((await owner.req('PATCH', '/v1/engines/members', { hidden: { 'no-such-model': true } })).status).toBe(400);
    expect((await owner.req('PATCH', '/v1/engines/members', { showProviderNames: true, hidden: { 'kling-v4': false } })).body.showProviderNames).toBe(true);
    expect((await member.req('GET', '/v1/engines')).body.engines.map((e: any) => e.model)).toContain('kling-v4');
  });

  it('shot: an override is priced on that model (members too, 4c); a model of another purpose is refused with the valid list', async () => {
    const body = { modelId: char.id, prompt: 'She smiles.', duration: 5, quality: 'standard' };
    const k = (await owner.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'kling-v4', resolution: '720p' })).body;
    expect(k.engine).toMatchObject({ model: 'kling-v4', resolution: '720p' });
    expect(k.estimate).toBeCloseTo(0.157 * 5, 1);
    const bad = await owner.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'h3-max-recast' });
    expect(bad.status).toBe(400);
    expect(bad.body.code).toBe('engine_not_allowed');
    expect(bad.body.valid).toEqual(expect.arrayContaining(['h3', 'kling-v4']));
    expect(bad.body.valid).not.toContain('h3-max-recast');
    const mk = await member.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'kling-v4', resolution: '720p' });
    expect(mk.status).toBe(200);
    expect(mk.body.estimate).toBeCloseTo(k.estimate, 6); // charged as the owner's run is priced
    expect((await member.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'h3-max-recast' })).body.code).toBe('engine_not_allowed');
  });

  it('recast, extend, guide: refused outside their candidates', async () => {
    const recast = await owner.req('POST', '/v1/suite/shots/estimate', { mode: 'recast', clipId: 'c_swap', cast: [{ characterId: char.id }], engineModel: 'veo-3.1-lite' });
    expect([recast.status, recast.body.code]).toEqual([400, 'engine_not_allowed']);
    const ext = await owner.req('POST', '/v1/suite/shots/estimate', { mode: 'extend', extend: { video: { key: 'clips/dance.mp4', seconds: 7 } }, engineModel: 'veo-3.1-lite' });
    expect([ext.status, ext.body.code]).toEqual([400, 'engine_not_allowed']);
    const guide = await owner.req('POST', '/v1/suite/shots/estimate', { prompt: 'x', engineModel: 'veo-3.1-lite', camera: { mode: 'directed', guide: { video: { url: 'https://x.test/g.mp4' } } } });
    expect([guide.status, guide.body.code]).toEqual([400, 'engine_not_allowed']);
  });

  it('swap (Suite): any swap engine, priced on it (members too, 4c); a non-swap model is refused; nothing runs', async () => {
    const body = { mode: 'swap', modelId: char.id, clipId: 'c_swap', quality: 'standard' };
    const base = (await owner.req('POST', '/v1/suite/shots/estimate', body)).body;
    expect(base.estimate).toBeCloseTo(0.08 * 8, 2); // H3 Standard 768P · 8 billed seconds (built-in price)
    const lite = (await owner.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'h3-lite' })).body;
    expect(lite.estimate).toBeCloseTo(0.02 * 8, 2);
    expect(lite.engine).toMatchObject({ model: 'h3-lite', source: 'request' });
    const edit = (await owner.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'h3-open' })).body;
    expect(edit.label).toBe('Edit');
    expect(edit.estimate).toBeCloseTo(P.totalCost({ engine: 'h3', use: 'full', steps: P.STEPS_DEFAULT, takes: 1, clipSeconds: 7.2 }), 2);
    const bad = await owner.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'kling-v4' });
    expect([bad.status, bad.body.code]).toEqual([400, 'engine_not_allowed']);
    expect(bad.body.valid).toEqual(['h3', 'h3-lite', 'h3-highspeed', 'h3-open', 'viggle']);
    expect((await member.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'h3-lite' })).body.estimate).toBeCloseTo(lite.estimate, 6);
    expect(JSON.stringify((await member.req('POST', '/v1/suite/shots/estimate', body)).body)).not.toMatch(PROVIDER_WORDS);
    expect(fake.state.creates).toEqual([]);
  });

  it('Character swap sent as a one-person Recast (the apps) with a swap model picked runs as a swap on that model', async () => {
    const asRecast = { mode: 'recast', clipId: 'c_swap', quality: 'standard', cast: [{ characterId: char.id }] };
    for (const m of ['h3', 'h3-lite', 'h3-highspeed', 'h3-open', 'viggle']) {
      const e = await owner.req('POST', '/v1/suite/shots/estimate', { ...asRecast, engineModel: m });
      expect(e.status, `${m}: ${JSON.stringify(e.body)}`).toBe(200);
      expect(e.body).toMatchObject({ mode: 'swap', engine: { model: m, source: 'request' } });
    }
    expect((await owner.req('POST', '/v1/suite/shots/estimate', { ...asRecast, engineModel: 'h3-lite' })).body.estimate).toBeCloseTo(0.02 * 8, 2);
    // A real Recast model stays a Recast; two people stay a Recast (a swap model is refused there).
    const two = await owner.req('POST', '/v1/suite/shots/estimate', { ...asRecast, cast: [{ characterId: char.id }, { characterId: char.id }], engineModel: 'h3-lite' });
    expect(two.body.code).toBe('engine_not_allowed');
    // Auto (no model) is unchanged.
    expect((await owner.req('POST', '/v1/suite/shots/estimate', asRecast)).status).toBe(200);
    expect(fake.state.creates).toEqual([]);
  });

  it('swap (POST /v1/jobs): the job carries the hosted model and its price; highspeed sends no resolution', async () => {
    const j = (await owner.req('POST', '/v1/jobs', { modelId: char.id, clipId: 'c_swap', engine: 'replicate', quality: 'hd', engineModel: 'h3-lite', queue: true })).body;
    const [row] = await a.ctx.db.execute(sql`select request, cost from jobs where id = ${j.id}`).then((r: any) => r.rows ?? r);
    expect(row.request).toMatchObject({ engine: 'replicate', videoModel: 'minimax/h3-lite', swapEngine: 'h3-lite', pricePerSec: 0.02 }); // H3 Lite has no 2K: 768P
    expect(row.cost).toBeCloseTo(0.02 * 8, 4);
    const hs = (await owner.req('POST', '/v1/jobs', { modelId: char.id, clipId: 'c_swap', engineModel: 'h3-highspeed', queue: true })).body;
    const [r2] = await a.ctx.db.execute(sql`select request from jobs where id = ${hs.id}`).then((r: any) => r.rows ?? r);
    expect(r2.request).toMatchObject({ videoModel: 'minimax/h3-highspeed', videoNoResolution: true, pricePerSec: 0.03 });
    const gpu = (await owner.req('POST', '/v1/jobs', { modelId: char.id, clipId: 'c_swap', engineModel: 'viggle', queue: true })).body;
    const [r3] = await a.ctx.db.execute(sql`select request from jobs where id = ${gpu.id}`).then((r: any) => r.rows ?? r);
    expect(r3.request).toMatchObject({ engine: 'viggle', swapEngine: 'viggle' });
    expect(r3.request.videoModel).toBeUndefined();
    // A client can't smuggle a model ref in.
    const sneak = (await owner.req('POST', '/v1/jobs', { modelId: char.id, clipId: 'c_swap', engine: 'replicate', videoModel: 'evil/model', swapEngine: 'h3', queue: true })).body;
    const [r4] = await a.ctx.db.execute(sql`select request from jobs where id = ${sneak.id}`).then((r: any) => r.rows ?? r);
    expect(r4.request.videoModel).toBeUndefined();
    expect((await owner.req('POST', '/v1/jobs', { modelId: char.id, clipId: 'c_swap', engineModel: 'kling-v4', queue: true })).body.code).toBe('engine_not_allowed');
    // 4c: a member may pick a swap model unless the owner hid it from members.
    await owner.req('PATCH', '/v1/engines/members', { hidden: { 'h3-lite': true } });
    expect((await member.req('POST', '/v1/jobs', { modelId: char.id, clipId: 'c_swap', engineModel: 'h3-lite', queue: true })).status).toBe(403);
    await owner.req('PATCH', '/v1/engines/members', { hidden: { 'h3-lite': false } });
    expect(fake.state.creates).toEqual([]);
  });

  it('studio defaults: "always use X for Swap" prices and runs every swap on X (members included); bad values refused; null clears', async () => {
    expect((await owner.req('PATCH', '/v1/engines/defaults', { swap: 'kling-v4' })).body.code).toBe('engine_not_allowed');
    expect((await owner.req('PATCH', '/v1/engines/defaults', { nope: 'h3' })).status).toBe(400);
    expect((await member.req('PATCH', '/v1/engines/defaults', { swap: 'h3-lite' })).status).toBe(403);
    const set = (await owner.req('PATCH', '/v1/engines/defaults', { swap: 'h3-lite', recast: 'kling-o1' })).body;
    expect(set.defaults).toMatchObject({ swap: 'h3-lite', recast: 'kling-o1', shot: null });
    expect(set.builtin.swap).toBe('h3');
    const list = (await owner.req('GET', '/v1/engines?purpose=swap')).body;
    expect(list.purposes[0]).toMatchObject({ default: 'h3-lite', studioDefault: 'h3-lite', rule: 'fixed' });
    const body = { mode: 'swap', modelId: char.id, clipId: 'c_swap', quality: 'standard' };
    const e = (await owner.req('POST', '/v1/suite/shots/estimate', body)).body;
    expect(e.estimate).toBeCloseTo(0.02 * 8, 2);
    expect(e.engine).toMatchObject({ model: 'h3-lite', source: 'studio' });
    expect((await member.req('POST', '/v1/suite/shots/estimate', body)).body.estimate).toBeCloseTo(0.02 * 8, 2);
    const j = (await member.req('POST', '/v1/jobs', { modelId: char.id, clipId: 'c_swap', engine: 'replicate', quality: 'standard', queue: true })).body;
    const [row] = await a.ctx.db.execute(sql`select request from jobs where id = ${j.id}`).then((r: any) => r.rows ?? r);
    expect(row.request).toMatchObject({ videoModel: 'minimax/h3-lite', swapEngine: 'h3-lite' });
    // Edit / Fast asked for by name keep their engine.
    const ed = (await owner.req('POST', '/v1/jobs', { modelId: char.id, clipId: 'c_swap', engine: 'h3', queue: true })).body;
    const [r2] = await a.ctx.db.execute(sql`select request from jobs where id = ${ed.id}`).then((r: any) => r.rows ?? r);
    expect(r2.request.engine).toBe('h3');
    expect(r2.request.swapEngine).toBeUndefined();
    const cleared = (await owner.req('PATCH', '/v1/engines/defaults', { swap: null, recast: null })).body;
    expect(cleared.defaults.swap).toBeNull();
    expect((await owner.req('POST', '/v1/suite/shots/estimate', body)).body.estimate).toBeCloseTo(0.08 * 8, 2);
  });

  it('shot default that can’t make a shot falls back to the ladder with a member-safe warning', async () => {
    await owner.req('PATCH', '/v1/engines/defaults', { shot: 'ltx-2.3' }); // LTX: no reference images (can't be adapted)
    const e = (await member.req('POST', '/v1/suite/shots/estimate', { prompt: 'A cat.', duration: 5, aspectRatio: '1:1', quality: 'draft',
      references: { images: [{ image: { url: 'https://example.com/p.png' }, role: 'product' }] } })).body;
    expect(e.warnings).toContain('The studio’s chosen engine can’t make this shot · the quality’s usual engine is used');
    expect(JSON.stringify(e)).not.toMatch(PROVIDER_WORDS);
    const fits = (await owner.req('POST', '/v1/suite/shots/estimate', { prompt: 'A cat.', duration: 8, aspectRatio: '9:16', quality: 'draft' })).body;
    expect(fits.engine.model).toBe('ltx-2.3');
    await owner.req('PATCH', '/v1/engines/defaults', { shot: null });
  });

  it('photo: imageModel priced on that model; the studio Photo default applies when nothing is picked', async () => {
    const body = { modelId: char.id, prompt: 'On the pier', count: 1 };
    const pick = (await owner.req('POST', '/v1/suite/photos/estimate', { ...body, imageModel: 'black-forest-labs/flux-2-dev' })).body;
    const plain = (await owner.req('POST', '/v1/suite/photos/estimate', body)).body;
    expect((await owner.req('PATCH', '/v1/engines/defaults', { photo: 'black-forest-labs/flux-2-dev' })).status).toBe(200);
    expect((await owner.req('POST', '/v1/suite/photos/estimate', body)).body.estimate).toBeCloseTo(pick.estimate, 6);
    expect((await member.req('POST', '/v1/suite/photos/estimate', body)).body.estimate).toBeCloseTo(pick.estimate, 6);
    await owner.req('PATCH', '/v1/engines/defaults', { photo: null });
    expect((await owner.req('POST', '/v1/suite/photos/estimate', body)).body.estimate).toBeCloseTo(plain.estimate, 6);
    expect((await owner.req('PATCH', '/v1/engines/defaults', { photo: 'not a model' })).status).toBe(400);
  });

  it('outfits and character photos: imageModel is checked; members (4c) only a shown model, never any Replicate ref', async () => {
    expect((await member.req('POST', `/v1/models/${char.id}/fill-angles`, { imageModel: 'someone/else' })).status).toBe(403);
    await owner.req('PATCH', '/v1/engines/members', { hidden: { 'black-forest-labs/flux-2-dev': true } });
    expect((await member.req('POST', `/v1/models/${char.id}/fill-angles`, { imageModel: 'black-forest-labs/flux-2-dev' })).status).toBe(403);
    expect((await member.req('POST', '/v1/suite/photos/estimate', { modelId: char.id, prompt: 'x', count: 1, imageModel: 'black-forest-labs/flux-2-dev' })).status).toBe(403);
    await owner.req('PATCH', '/v1/engines/members', { hidden: { 'black-forest-labs/flux-2-dev': false } });
    expect((await member.req('POST', '/v1/suite/photos/estimate', { modelId: char.id, prompt: 'x', count: 1, imageModel: 'black-forest-labs/flux-2-dev' })).status).toBe(200);
    const bad = await owner.req('POST', `/v1/models/${char.id}/fill-angles`, { imageModel: 'not a model' });
    expect([bad.status, bad.body.code]).toEqual([400, 'engine_not_allowed']);
    expect((await member.req('POST', '/v1/outfits', { modelId: char.id, name: 'Red', mode: 'own', imageModel: 'someone/else' })).status).toBe(403);
  });

  it('upscale and editor helpers: only their own candidates; members get 403', async () => {
    const up = await owner.req('POST', '/v1/takes/t_missing/upscale', { size: '2k', engineModel: 'kling-v4' });
    expect([up.status, up.body.code]).toEqual([400, 'engine_not_allowed']);
    expect(up.body.valid).toEqual(['seedvr2']);
    expect((await owner.req('POST', '/v1/takes/t_missing/upscale', { size: '2k', engineModel: 'seedvr2' })).status).toBe(404); // allowed; no such take
    expect((await member.req('POST', '/v1/takes/t_missing/upscale', { size: '2k', engineModel: 'seedvr2' })).status).toBe(403);
    const cap = (await owner.req('GET', '/v1/engines?purpose=captions')).body.engines[0].model;
    const ed = await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', engineModel: 'someone/else', source: { takeId: 't_missing' } });
    expect([ed.status, ed.body.code, ed.body.valid]).toEqual([400, 'engine_not_allowed', [cap]]);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', engineModel: cap, source: { takeId: 't_missing' } })).status).toBe(404); // allowed
    expect((await member.req('POST', '/v1/editor/estimate', { kind: 'captions', engineModel: cap, source: { takeId: 't_missing' } })).status).toBe(403);
  });

  it('the apps\' picker shape: catalog fields on every entry, ?purpose aliases, {purpose, default, models}, PATCH {purpose, model}', async () => {
    const r = (await owner.req('GET', '/v1/engines?purpose=camera')).body; // alias of guide
    expect(r).toMatchObject({ purpose: 'guide', default: expect.any(String) });
    expect(r.models).toEqual(r.engines);
    const k = r.models.find((e: any) => e.model === 'kling-v4');
    expect(k).toMatchObject({ tier: 'standard', perSec: expect.any(Number), perRun: null, minSeconds: 3, maxSeconds: 30, allowedSeconds: null, aspectRatios: expect.arrayContaining(['9:16']) });
    expect(k.resolutions[0]).toEqual({ id: '720p', label: '720p', perSec: 0.157 });
    expect((await owner.req('GET', '/v1/engines?purpose=recreate')).body.purpose).toBe('fill');
    expect((await owner.req('GET', '/v1/engines?purpose=model_photos')).body.purpose).toBe('character');
    expect((await owner.req('GET', '/v1/engines?purpose=background')).body.purpose).toBe('plate');
    const set = (await owner.req('PATCH', '/v1/engines/defaults', { purpose: 'background', model: 'black-forest-labs/flux-2-dev' })).body;
    expect(set.defaults.plate).toBe('black-forest-labs/flux-2-dev');
    expect((await owner.req('PATCH', '/v1/engines/defaults', { purpose: 'background', model: null })).body.defaults.plate).toBeNull();
  });

  it('the Suite catalog engines[] carries purposes', async () => {
    const engines = (await owner.req('GET', '/v1/suite/catalog')).body.engines;
    expect(engines.find((e: any) => e.model === 'h3').purposes).toEqual(expect.arrayContaining(['shot', 'swap']));
    expect(engines.find((e: any) => e.kind === 'image').purposes).toEqual(['photo', 'outfit', 'character', 'plate']);
    expect(fake.state.creates).toEqual([]);
  });
});
