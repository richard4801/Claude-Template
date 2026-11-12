// Photo runs whose provider made (and billed) some stills before a later one failed: those stills are kept and
// charged, the rest refunded, and the job says so; a run cut off by a restart gives the member's hold back and puts
// what the provider may have billed on studio overhead (paid-jobs-3). Stub image engine, no money.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { and, eq } from 'drizzle-orm';
import { jobs, ledger } from '../src/db/schema.js';
import { openDb } from '../src/db/client.js';
import { ImageEngineError } from '../src/images/engines.js';
import { client, demoModel, makeApp, people, until } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
const engineOf = (a: App) => (a.ctx.images as unknown as { engines: Record<string, unknown> }).engines;

describe('Photo · partial results and restarts', () => {
  let a: App, owner: any, m: any;
  beforeAll(async () => { a = await makeApp({ SUITE_MODE: 'mock' }); ({ owner } = await people(a, 0, { topUp: 100 })); m = await demoModel(owner); });
  afterAll(async () => { await a?.close(); });

  it('one still made, the next one failed: the made one is a take, charged; the job is done "1 of 2" with the rest refunded', async () => {
    const real = engineOf(a).simulated;
    engineOf(a).simulated = { provider: 'simulated', generate: async () => { throw Object.assign(new ImageEngineError('the second still failed'), { partial: [{ asset: 'g_front' }] }); } };
    try {
      const r = (await owner.req('POST', '/v1/suite/photos', { modelId: m.id, prompt: 'A rooftop at dusk.', count: 2 })).body;
      expect(r.takes, JSON.stringify(r)).toHaveLength(1);
      expect(r.job).toMatchObject({ state: 'done' });
      expect(r.job.phase).toMatch(/^Done · 1 of 2 photos/);
      expect(r.job.refunded).toBeGreaterThan(0);
      expect(r.job.refunded).toBeLessThan(r.job.cost);
      const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.kind, 'settle'))).at(-1)!;
      expect(settle.amountUsd).toBeGreaterThan(0); // the kept still is charged
    } finally { engineOf(a).simulated = real; }
  });

  it('a graded shoot whose finishing step fails keeps the still as made (not a failure)', async () => {
    const tpl = a.ctx.templates as unknown as { postProcess: (...x: unknown[]) => Promise<unknown> };
    const real = tpl.postProcess;
    tpl.postProcess = async () => { throw new Error('sharp crashed'); };
    try {
      const r = await owner.req('POST', '/v1/suite/photos', { modelId: m.id, count: 1, camera: { palette: { preset: 'classic_bw' } } });
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(r.body.takes).toHaveLength(1);
      expect(r.body.job.state).toBe('done');
    } finally { tpl.postProcess = real; }
  });

  it('a photo run cut off by a restart: failed, the hold given back, refunded, the possible cost on overhead', async () => {
    const db = await openDb('pglite://memory');
    const x = await makeApp({ SUITE_MODE: 'mock' }, { db });
    let y: App | undefined;
    try {
      const { owner } = await people(x, 0, { topUp: 100 });
      const m = await demoModel(owner);
      engineOf(x).simulated = { provider: 'simulated', generate: () => new Promise(() => {}) }; // never finishes
      const before = (await owner.req('GET', '/v1/balance')).body.tokens;
      const r = (await owner.req('POST', '/v1/suite/photos', { modelId: m.id, count: 1, async: true })).body;
      expect(r.job.state).toBe('running');
      expect((await owner.req('GET', '/v1/balance')).body.tokens).toBeLessThan(before); // held
      await x.close();
      y = await makeApp({ SUITE_MODE: 'mock' }, { db });
      const c = { req: client(y, owner.token) };
      const j = await until(async () => { const v = ((await c.req('GET', '/v1/jobs')).body as any[]).find(z => z.id === r.job.id); return v?.state === 'failed' && v.refunded > 0 ? v : null; }, 10_000);
      expect(j.error).toMatch(/restart/);
      // The hold came back (the owner's balance is the studio's, which also carries the overhead line).
      await until(async () => (await y!.ctx.db.select().from(ledger).where(eq(ledger.kind, 'release'))).some(l => /interrupted by a restart/.test(l.note ?? '') && l.tokens > 0) ? true : null, 10_000);
      const over = await y.ctx.db.select().from(ledger).where(and(eq(ledger.kind, 'overhead')));
      expect(over.some(o => /interrupted by a restart/.test(o.note ?? ''))).toBe(true);
      const row = (await y.ctx.db.select().from(jobs).where(eq(jobs.id, r.job.id)))[0]!;
      expect(row.refunded).toBe(row.cost);
    } finally { await y?.close(); await db.close(); }
  });
});
