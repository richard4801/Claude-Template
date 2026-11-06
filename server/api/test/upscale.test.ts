// Upscale (SeedVR2 on the add-on GPU; plans/app-cleanup.md decision 6): priced per output second from measured times
// (UPSCALE_PRICES). Runs on the simulated GPU here: no pods, no money.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { ledger, takes } from '../src/db/schema.js';
import * as P from '../src/pricing.js';
import { makeApp, people, until, type Client } from './helpers.js';

const PRICES = JSON.stringify({ '1080p': { usdPerSec: 0.02, gpuSecPerSec: 8 }, '2k': { usdPerSec: 0.04, gpuSecPerSec: 15 } });

describe('Upscale', () => {
  it('prices: per output second from config; nothing priced = coming soon', () => {
    expect(P.upscalePrices('')).toEqual({});
    expect(P.upscalePrices(PRICES)['4k']).toBeUndefined();
    const r = P.upscaleRequest('2k', 8, P.upscalePrices(PRICES)['2k']!);
    expect(r).toEqual({ engine: 'upscale', size: '2k', seconds: 8, gpuSeconds: 60 + 120, usd: 0.32, takes: 1 });
    expect(P.totalCost(r)).toBe(0.32);
    expect(P.totalSeconds(r)).toBe(180);
    expect(P.engineLabel(r)).toBe('Upscale · 2K');
    expect(P.progressAt(r, 30).phase).toMatch(/^Getting ready/);
    expect(P.progressAt(r, 120).phase).toMatch(/^Upscaling/);
    expect(() => P.upscalePrices('{nope')).toThrow(/UPSCALE_PRICES/);
  });

  describe('API on the simulated GPU', () => {
    let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, studioId: string;
    beforeAll(async () => {
      a = await makeApp({ UPSCALE_PRICES: PRICES, BALANCE_MODE: 'simulated' });
      ({ owner } = await people(a, 0) as any);
      const [o] = await a.ctx.db.execute((await import('drizzle-orm')).sql`select studio_id from users where id = ${owner.id}`).then((r: any) => r.rows ?? r);
      studioId = o.studio_id;
      await a.ctx.db.insert(takes).values({ id: 't_src', studioId, userId: owner.id, kind: 'take', jobId: null, modelId: 'm_x', index: 1, of: 1, title: 'Café', label: 'HD',
        engineLabel: 'HD · 2K', cost: 1, seed: 7, status: 'test', thumb: { asset: 'g_front' }, prompt: 'She smiles.', mediaKey: 'r/j_src/take_1.mp4',
        media: { durationSec: 8, width: 720, height: 1280, fps: 24 }, createdAt: Date.now() } as any);
    });
    afterAll(async () => { await a?.close(); });

    it('features list the priced sizes; 4K stays off until measured', async () => {
      const up = (await owner.req('GET', '/v1/settings/studio')).body.features.video.addons.find((x: any) => x.id === 'upscale');
      expect(up.available).toBe(true);
      expect(up.comingSoon).toBeUndefined();
      expect(up.sizes.map((z: any) => [z.id, z.available, z.price])).toEqual([['1080p', true, 0.02], ['2k', true, 0.04], ['4k', false, null]]);
      expect((await owner.req('POST', '/v1/takes/t_src/upscale', { size: '4k' })).status).toBe(409);
    });

    it('a take upscales as a held job, runs, and settles at its quoted price with an "Upscale · 2K" take', async () => {
      const r = await owner.req('POST', '/v1/takes/t_src/upscale', { size: '2k' });
      expect(r.status).toBe(200);
      expect(r.body).toMatchObject({ title: 'Café · Upscale · 2K', cost: 0.32, engineLabel: 'Upscale · 2K', request: { engine: 'upscale', size: '2k', seconds: 8, takeId: 't_src' } });
      const j = await until(async () => { const x = await a.ctx.jobs.get(r.body.id); return x?.state === 'done' || x?.state === 'failed' ? x : null; }, 20_000);
      expect(j.state).toBe('done');
      const t = (await owner.req('GET', '/v1/takes')).body.find((x: any) => x.jobId === r.body.id);
      expect(t).toMatchObject({ label: 'Upscale · 2K', engineLabel: 'Upscale · 2K' });
      const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, r.body.id));
      expect(rows.some(x => x.kind === 'hold')).toBe(true);
    });
  });
});
