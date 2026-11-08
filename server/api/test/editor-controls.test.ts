// The owner's controls for paid AI editing helpers (workstream 1, before the switch from the mock to Replicate):
// a runtime switch (no redeploy), a daily spend cap per studio, the price at cost × 2, pinned model versions and
// the rates checked on each model's page. No money: the mock provider.
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { takes, users } from '../src/db/schema.js';
import { DEFAULT_RATES, DEFAULT_VERSIONS, ReplicateProvider } from '../src/editor/providers.js';
import { editorAi } from '../src/editor/service.js';
import { makeApp, people, until, type Client } from './helpers.js';

describe('Paid AI editing helpers · the owner\'s controls', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, studioId: string;
  const src = 'take_ctl';
  beforeAll(async () => {
    a = await makeApp();
    ({ owner, members: [member] } = await people(a, 1) as any);
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    studioId = u!.studioId;
    await a.ctx.db.insert(takes).values({ id: src, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'Walk', label: 'HD',
      engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: `c/${src}.mp4`, media: { durationSec: 25, width: 1080, height: 1920, fps: 30 }, createdAt: Date.now() });
  });
  afterAll(async () => { await a?.close(); });
  const job = (kind = 'captions') => owner.req('POST', '/v1/editor/jobs', { kind, source: { takeId: src } });
  const done = (id: string) => until(async () => { const r = (await owner.req('GET', `/v1/editor/jobs/${id}`)).body; return r.state !== 'running' ? r : null; });

  it('the owner sees the switch, the cap, today\'s spend and the markup; members can\'t', async () => {
    expect((await owner.req('GET', '/v1/editor/settings')).body).toEqual({ paidHelpers: 'on', capPerDayUsd: 5, todayUsd: 0, markup: 2, provider: 'mock' });
    expect((await member.req('GET', '/v1/editor/settings')).status).toBe(403);
    expect((await member.req('PATCH', '/v1/editor/settings', { paidHelpers: 'off' })).status).toBe(403);
    expect((await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'maybe' })).status).toBe(400);
    expect((await owner.req('PATCH', '/v1/editor/settings', { capPerDayUsd: -1 })).status).toBe(400);
    expect((await owner.req('PATCH', '/v1/editor/settings', { provider: 'replicate' })).status).toBe(400);
  });

  it('the price is the cost × 2, estimated and settled', async () => {
    const est = (await owner.req('POST', '/v1/editor/estimate', { kind: 'matte', source: { takeId: src } })).body;
    expect(est.usd).toBeCloseTo((10 + 4 * 25) * DEFAULT_RATES.matte * 2, 4);
    const j = (await job('matte')).body;
    const r = await done(j.id);
    expect(r.state).toBe('done');
    expect(r.costUsd).toBeCloseTo((10 + 4 * 25) * DEFAULT_RATES.matte * 2, 4); // the mock bills the estimated GPU time
    expect((await owner.req('GET', '/v1/editor/settings')).body.todayUsd).toBeCloseTo(r.costUsd, 4);
  });

  it('switched off at run time: paid helpers are refused and hidden; free ones stay; back on, they run again', async () => {
    expect((await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'off' })).body.paidHelpers).toBe('off');
    const f = (await member.req('GET', '/v1/editor/features')).body;
    expect(f).toMatchObject({ paid: { available: false }, matte: { available: false }, captions: { available: false }, denoise: { available: false }, cuts: { available: true }, beats: { available: true } });
    const r = await job();
    expect(r).toMatchObject({ status: 503, body: { code: 'editor_paid_off' } });
    // The estimate still answers (the apps show why it's unavailable from features).
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', source: { takeId: src } })).status).toBe(200);
    await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'on' });
    expect((await member.req('GET', '/v1/editor/features')).body.paid).toEqual({ available: true });
    const ok = await job();
    expect(ok.status).toBe(200);
    await done(ok.body.id);
  });

  it('the daily cap counts what ran today (and what is running); over it, a new paid job is refused', async () => {
    const today = (await owner.req('GET', '/v1/editor/settings')).body.todayUsd as number;
    await owner.req('PATCH', '/v1/editor/settings', { capPerDayUsd: Math.round((today + 0.01) * 100) / 100 });
    const r = await job('matte'); // always paid (a second captions job would reuse the transcript, free)
    expect(r).toMatchObject({ status: 402, body: { code: 'editor_daily_cap' } });
    expect(r.body.error).toMatch(/Today’s AI editing limit \(\$[0-9.]+\) is reached/);
    // The cap applies to Claude's paid helpers too: they start through the same path.
    await expect(editorAi(a.ctx).start({ id: owner.id, studioId, email: '', role: 'owner', studioName: '', sessionId: null } as never, { kind: 'matte', source: { takeId: src } }))
      .rejects.toMatchObject({ code: 'editor_daily_cap' });
    // null = the server's default again.
    expect((await owner.req('PATCH', '/v1/editor/settings', { capPerDayUsd: null })).body.capPerDayUsd).toBe(5);
    expect((await job('matte')).status).toBe(200);
  });
});

describe('Paid AI editing helpers · versions and rates (unit)', () => {
  it('each default model runs a pinned version; EDITOR_*_VERSION overrides one', () => {
    const ctx = { log: { info() {} }, config: {}, replicate: {}, imageModels: {} } as never;
    const p = new ReplicateProvider(ctx);
    for (const m of Object.values(p.models)) expect(p.versions[m]).toMatch(/^[a-f0-9]{64}$/);
    expect(p.versions['meta/sam-2-video']).toBe(DEFAULT_VERSIONS['meta/sam-2-video']);
    process.env.EDITOR_MATTE_VERSION = 'abc123';
    try { expect(new ReplicateProvider(ctx).versions['arielreplicate/robust_video_matting']).toBe('abc123'); } finally { delete process.env.EDITOR_MATTE_VERSION; }
  });
  it('the rates are what each model\'s page bills (2026-11-08)', () => {
    expect(DEFAULT_RATES).toEqual({ transcribe: 0.0014, matte: 0.000975, separate: 0.00115, track: 0.000975 });
  });
});
