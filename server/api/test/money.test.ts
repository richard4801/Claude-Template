import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { ledger, studioSettings } from '../src/db/schema.js';
import { RunpodApi } from '../src/gpu/runpodApi.js';
import { makeApp, people, sienna, until, type Client } from './helpers.js';

/** A fake RunPod GraphQL API: `myself` returns `state.balance`. */
export function fakeRunpod(state: { balance: number; calls?: string[] }) {
  const f = (async (_url: string, init: any) => {
    const q = JSON.parse(init.body).query as string;
    state.calls?.push(q);
    if (init.headers.authorization !== 'Bearer rp_test_key') return new Response(JSON.stringify({ errors: [{ message: 'unauthorized' }] }), { status: 401 });
    if (q.includes('myself')) return Response.json({ data: { myself: { clientBalance: state.balance, currentSpendPerHr: 0 } } });
    return Response.json({ errors: [{ message: 'not faked' }] });
  }) as typeof fetch;
  return new RunpodApi('rp_test_key', 'http://runpod.fake/graphql', f);
}

describe('wallets, ledger and caps (real RunPod balance via a fake API)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>;
  let owner: Client, tess: Client, mo: Client;
  const rp = { balance: 20 };
  beforeAll(async () => {
    a = await makeApp({ BALANCE_MODE: 'runpod', RUNPOD_MIN_BALANCE_USD: '0', SPEED: '100000' }, { runpod: fakeRunpod(rp) });
    const p = await people(a, 2);
    owner = p.owner; tess = p.members[0]!; mo = p.members[1]!;
  });
  afterAll(async () => { await a.close(); });

  it('balance reads RunPod; members start with 0 tokens', async () => {
    const b = (await owner.req('GET', '/v1/balance')).body;
    expect(b).toMatchObject({ balance: 20, runpodBalance: 20, availableToSend: 20, balanceSource: 'runpod', role: 'owner', tokens: 2000, tokenUsd: 0.01 });
    const w = (await tess.req('GET', '/v1/wallet')).body;
    expect(w).toMatchObject({ tokens: 0, usd: 0, role: 'member' });
    expect((await tess.req('GET', '/v1/balance')).body).toMatchObject({ balance: 0, tokens: 0, role: 'member' });
  });

  it('members cannot call owner endpoints', async () => {
    for (const [m, u, b] of [['GET', '/v1/members'], ['POST', '/v1/wallets/transfer', { toUserId: tess.id, tokens: 1 }], ['POST', '/v1/wallets/reclaim', { fromUserId: tess.id, tokens: 1 }],
      ['PATCH', `/v1/members/${tess.id}`, { capPerDay: 100 }], ['PATCH', '/v1/settings/studio', { maxGpus: 9 }], ['GET', '/v1/ledger']] as const) {
      const r = await tess.req(m, u, b);
      expect(r.status, u).toBe(403); expect(r.body.code).toBe('owner_only');
    }
  });

  it('transfer: owner sends tokens; over-allocation is refused', async () => {
    let r = await owner.req('POST', '/v1/wallets/transfer', { toUserId: tess.id, tokens: 1200, note: 'test phase' });
    expect(r.status).toBe(200);
    expect(r.body.member.tokens).toBe(1200);
    expect(r.body.wallet.availableToSend).toBeCloseTo(8, 6);
    r = await owner.req('POST', '/v1/wallets/transfer', { toUserId: mo.id, tokens: 801 });
    expect(r.status).toBe(402); expect(r.body.code).toBe('over_allocation');
    expect((await owner.req('POST', '/v1/wallets/transfer', { toUserId: mo.id, tokens: 300 })).status).toBe(200);
    expect((await owner.req('POST', '/v1/wallets/transfer', { toUserId: owner.id, tokens: 1 })).status).toBe(400);
    const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.kind, 'transfer'));
    expect(rows.map(x => [x.userId, x.actorId, x.tokens, x.note])).toContainEqual([tess.id, owner.id, 1200, 'test phase']);
    expect((await owner.req('GET', '/v1/balance')).body.balance).toBeCloseTo(5, 6);
  });

  it('reclaim: only unused tokens come back', async () => {
    expect((await owner.req('POST', '/v1/wallets/reclaim', { fromUserId: mo.id, tokens: 301 })).status).toBe(400);
    const r = await owner.req('POST', '/v1/wallets/reclaim', { fromUserId: mo.id, tokens: 100, note: 'not needed' });
    expect(r.body.member.tokens).toBe(200);
    expect(r.body.wallet.availableToSend).toBeCloseTo(6, 6);
    const members = (await owner.req('GET', '/v1/members')).body;
    expect(members.find((m: any) => m.id === mo.id)).toMatchObject({ tokens: 200, todayUsd: 0, disabled: false });
    expect(members.find((m: any) => m.id === tess.id).lastActiveAt).toBeGreaterThan(0);
  });

  it('insufficient tokens are refused before any GPU work', async () => {
    const m = await sienna(mo);
    const r = await mo.req('POST', '/v1/jobs', { title: 'x', modelId: m.id, steps: 10, takes: 3 }); // $2.02 > $2.00
    expect(r.status).toBe(402); expect(r.body.code).toBe('insufficient_tokens');
    expect((await mo.req('GET', '/v1/jobs')).body.length).toBe(0);
  });

  it('hold → settle: the estimate is held, then the actual cost is spent', async () => {
    const m = await sienna(tess);
    const before = (await tess.req('GET', '/v1/wallet')).body.tokens;
    const job = (await tess.req('POST', '/v1/jobs', { title: 'Dance', modelId: m.id, steps: 10 })).body;
    expect(job.state).toBe('running');
    const w = (await tess.req('GET', '/v1/wallet')).body;
    expect(w.tokens).toBe(before - 68); expect(w.heldTokens).toBe(68);
    const holds = await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, job.id));
    expect(holds.map(h => h.kind)).toContain('hold');
    await until(async () => (await tess.req('GET', '/v1/jobs')).body.find((j: any) => j.id === job.id && j.state === 'done'));
    const after = (await tess.req('GET', '/v1/wallet')).body;
    expect(after.heldTokens).toBe(0);
    expect(after.tokens).toBe(before - 68);
    expect(after.todayUsd).toBeCloseTo(job.cost, 6);
  });

  it('hold → release on failure: the whole hold comes back', async () => {
    const m = (await tess.req('GET', '/v1/models')).body[0];
    await a.ctx.db.update(studioSettings).set({ failNext: true });
    const before = (await tess.req('GET', '/v1/wallet')).body.tokens;
    const job = (await tess.req('POST', '/v1/jobs', { title: 'Fail', modelId: m.id, steps: 10 })).body;
    const j = await until(async () => (await tess.req('GET', '/v1/jobs')).body.find((x: any) => x.id === job.id && x.state === 'failed'));
    expect(j.refunded).toBe(j.cost);
    await until(async () => (await tess.req('GET', '/v1/wallet')).body.heldTokens === 0);
    expect((await tess.req('GET', '/v1/wallet')).body.tokens).toBe(before);
    const kinds = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, job.id))).map(x => x.kind);
    expect(kinds).toEqual(expect.arrayContaining(['hold', 'release']));
  });

  it('caps: per job, per user per day (owner-set per member), per studio per day', async () => {
    const m = (await tess.req('GET', '/v1/models')).body[0];
    // $6.08 > $5 per job (also more than her tokens: the cap is checked first)
    expect((await tess.req('POST', '/v1/jobs', { title: 'x', modelId: m.id, steps: 30, takes: 3 })).body.code).toBe('over_job_limit');
    await owner.req('PATCH', `/v1/members/${tess.id}`, { capPerDay: 1 });
    const r = await tess.req('POST', '/v1/jobs', { title: 'x', modelId: m.id, steps: 10 });
    expect(r.status).toBe(402); expect(r.body.code).toBe('over_user_day_limit');
    await owner.req('PATCH', `/v1/members/${tess.id}`, { capPerDay: null });
    await owner.req('PATCH', '/v1/settings/studio', { capPerDay: 1 });
    expect((await tess.req('POST', '/v1/jobs', { title: 'x', modelId: m.id, steps: 10 })).body.code).toBe('over_day_limit');
    await owner.req('PATCH', '/v1/settings/studio', { capPerDay: 15 });
  });

  it('balance unavailable without a RunPod key: says so, transfers refused', async () => {
    const b = await makeApp({ BALANCE_MODE: 'runpod' });
    const p = await people(b, 1);
    const bal = (await p.owner.req('GET', '/v1/balance')).body;
    expect(bal.balanceSource).toBe('unavailable');
    expect((await p.owner.req('POST', '/v1/wallets/transfer', { toUserId: p.members[0]!.id, tokens: 5 })).body.code).toBe('balance_unavailable');
    expect((await p.owner.req('POST', '/v1/balance/topup', { amount: 5 })).body.code).toBe('topup_unavailable');
    await b.close();
  });
});
