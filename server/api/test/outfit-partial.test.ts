// Outfit sets that come out partly (owner 2026-11-12): the pictures made are kept and charged, the missing ones stay
// empty and are refunded, the outfit says "N of 7 made · Redo the missing ones" (each missing one priced by redo dryRun),
// and a shot with it sends only what exists, saying what's missing. A Redo where one picture fails keeps the others.
// The LoRA training set keeps the candidates made. Stub image engine (simulated provider), no money.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { ledger, outfits, users } from '../src/db/schema.js';
import { ImageEngineError, type ImageRequest } from '../src/images/engines.js';
import { outfitRefs } from '../src/images/identity.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
const engines = (a: App) => (a.ctx.images as unknown as { engines: Record<string, any> }).engines;

describe('outfit sets that come out partly', () => {
  let a: App, owner: Client, m: { id: string }, studioId: string, real: any;
  /** The next generate calls: 'ok' | 'fail' | ['partial', n] (count-n call made n before failing). */
  const plan: (string | ['partial', number])[] = [];
  beforeAll(async () => {
    a = await makeApp({ BALANCE_MODE: 'simulated' });
    ({ owner } = await people(a, 0, { topUp: 100 }) as any);
    m = await demoModel(owner);
    studioId = (await a.ctx.db.select().from(users).where(eq(users.id, owner.id)))[0]!.studioId;
    real = engines(a).simulated;
    engines(a).simulated = {
      provider: 'simulated',
      generate: async (req: ImageRequest, sel: any) => {
        const step = plan.shift() ?? 'ok';
        if (step === 'fail') throw new ImageEngineError('that one didn’t come out');
        if (Array.isArray(step)) throw Object.assign(new ImageEngineError('stopped partway'), { partial: Array.from({ length: step[1] }, (_, i) => ({ asset: ['c_front', 'c_tq', 'c_face', 'c_front'][i]! })) });
        return real.generate(req, sel);
      },
    };
  });
  afterAll(async () => { await a?.close(); });

  const made = (id: string) => until(async () => (await owner.req('GET', '/v1/outfits')).body.find((x: any) => x.id === id && x.state === 'preview'), 15_000);

  it('a new outfit that stopped after 2 of 4 angles: kept, charged for what was made, "5 of 7 made", each missing one priced', async () => {
    plan.push(['partial', 2]); // the 4-angle call makes front and ¾, then fails; the three face close-ups come out
    const est = (await owner.req('POST', '/v1/outfits', { modelId: m.id, mode: 'describe', description: 'Red satin slip dress', dryRun: true })).body;
    const o = (await owner.req('POST', '/v1/outfits', { modelId: m.id, mode: 'describe', description: 'Red satin slip dress' })).body;
    const done = await made(o.id);
    expect(done.angles.map(Boolean)).toEqual([true, true, false, false]);
    expect(done.faces.map(Boolean)).toEqual([true, true, true]);
    expect(done.partial).toEqual({ made: 5, of: 7, missing: ['side', 'back'], label: '5 of 7 made · Redo the missing ones' });
    const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, o.id))).find(x => x.kind === 'settle')!;
    expect(settle.amountUsd).toBeGreaterThan(0);
    expect(settle.amountUsd).toBeLessThan(est.cost - 1e-6); // the missing angles are refunded
    expect(done.cost).toBeCloseTo(settle.amountUsd, 6);
    const price = (await owner.req('POST', `/v1/outfits/${o.id}/redo`, { angle: 'side', dryRun: true })).body;
    expect(price).toMatchObject({ dryRun: true, images: 1 });
    expect(price.cost).toBeGreaterThan(0);
  });

  it('without its front nothing is kept (the whole set fails, refunded)', async () => {
    plan.push('fail');
    const o = (await owner.req('POST', '/v1/outfits', { modelId: m.id, mode: 'describe', description: 'Denim jacket' })).body;
    const done = await made(o.id);
    expect(done.angles).toEqual([null, null, null, null]);
    expect(done.partial).toBeUndefined();
  });

  it('Fill where one of the missing angles fails keeps the other; the outfit still says what is missing', async () => {
    await a.ctx.db.insert(outfits).values({ id: 'o_part', studioId, modelId: m.id, name: 'Part', mode: 'describe', description: '', state: 'ready', createdBy: owner.id, createdAt: Date.now(),
      angles: [{ asset: 'g_front' }, null, null, { asset: 'g_back' }], faces: [{ asset: 'face' }, { asset: 'face' }, { asset: 'face' }] });
    plan.push('ok', 'fail'); // ¾ comes out, side doesn't
    expect((await owner.req('POST', '/v1/outfits/o_part/fill')).status).toBe(200);
    const o = await until(async () => { const x = (await owner.req('GET', '/v1/outfits')).body.find((y: any) => y.id === 'o_part'); return x?.angles[1] ? x : null; }, 15_000);
    expect(o.angles.map(Boolean)).toEqual([true, true, false, true]);
    expect(o.partial).toMatchObject({ made: 6, of: 7, missing: ['side'] });
  });

  it('a LoRA training set that stopped partway keeps the candidates made', async () => {
    plan.push(['partial', 3]);
    expect((await owner.req('POST', `/v1/models/${m.id}/lora/candidates`)).body.state).toBe('building');
    const l = await until(async () => { const x = (await owner.req('GET', `/v1/models/${m.id}/lora`)).body; return x.state === 'review' ? x : null; }, 15_000);
    expect(l.candidates).toHaveLength(3);
  });

  it('a shot with a partial outfit sends only what exists, and says what is missing', () => {
    const refs = outfitRefs({ angles: [{ asset: 'g_front' }, { asset: 'g_tq' }, null, null], faces: [{ asset: 'face' }, null, { asset: 'face' }] } as any, null);
    expect(refs.map(r => r.label)).toEqual(['face', 'outfit, front', 'face profile', 'outfit, ¾']);
    const front = refs.find(r => r.label === 'outfit, front')!;
    expect(front.why).toMatch(/missing its side, back, face ¾ \(Redo them on the outfit\)/);
  });
});
