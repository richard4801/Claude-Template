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

describe('wallets, ledger and caps (owner-loaded studio balance)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>;
  let owner: Client, tess: Client, mo: Client;
  const rp = { balance: 3 }; // RunPod's own balance no longer backs anything
  beforeAll(async () => {
    a = await makeApp({ BALANCE_MODE: 'runpod', RUNPOD_MIN_BALANCE_USD: '0', SPEED: '100000' }, { runpod: fakeRunpod(rp) });
    const p = await people(a, 2, { topUp: 0 });
    owner = p.owner; tess = p.members[0]!; mo = p.members[1]!;
  });
  afterAll(async () => { await a.close(); });

  it('a new studio starts at $0 and asks for the first top-up; nothing can be sent yet', async () => {
    const b0 = (await owner.req('GET', '/v1/balance')).body;
    expect(b0).toMatchObject({ balance: 0, studioBalance: 0, availableToSend: 0, balanceSource: 'studio', needsFirstTopUp: true });
    expect(b0.runpodBalance).toBeUndefined();
    const r = await owner.req('POST', '/v1/wallets/transfer', { toUserId: tess.id, tokens: 1 });
    expect(r.status).toBe(402); expect(r.body.code).toBe('over_allocation');
  });

  it('top-ups: the owner records money loaded; it shows in the studio balance and the ledger', async () => {
    expect((await owner.req('POST', '/v1/studio/topups', { amountUsd: 0 })).status).toBe(400);
    expect((await owner.req('POST', '/v1/studio/topups', { amountUsd: 5, paidAt: Date.now() + 86_400_000 })).status).toBe(400);
    const paidAt = Date.now() - 3_600_000;
    const sb = (await owner.req('POST', '/v1/studio/topups', { amountUsd: 20, note: 'card', paidAt })).body;
    expect(sb).toMatchObject({ balanceUsd: 20, toppedUpUsd: 20, spentUsd: 0, availableUsd: 20, membersCreditUsd: 0, needsFirstTopUp: false });
    expect(sb.topUps[0]).toMatchObject({ amountUsd: 20, note: 'card', paidAt, createdBy: owner.id });
    expect((await owner.req('GET', '/v1/studio/topups')).body.length).toBe(1);
    const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.kind, 'topup'));
    expect(rows.map(x => [x.amountUsd, x.note])).toEqual([[20, 'Added $20.00 · card']]);
    for (const [m, u, b] of [['GET', '/v1/studio/balance'], ['POST', '/v1/studio/topups', { amountUsd: 5 }], ['GET', '/v1/studio/topups'], ['POST', '/v1/balance/topup', { amount: 5 }]] as const) {
      const r = await tess.req(m, u, b);
      expect(r.status, u).toBe(403); expect(r.body.code).toBe('owner_only');
    }
  });

  it('balance is the studio balance; members start with 0 tokens', async () => {
    const b = (await owner.req('GET', '/v1/balance')).body;
    expect(b).toMatchObject({ balance: 20, studioBalance: 20, availableToSend: 20, balanceSource: 'studio', role: 'owner', tokens: 2000, tokenUsd: 0.01 });
    const w = (await tess.req('GET', '/v1/wallet')).body;
    expect(w).toMatchObject({ tokens: 0, usd: 0, role: 'member' });
    expect((await tess.req('GET', '/v1/balance')).body).toMatchObject({ balance: 0, tokens: 0, role: 'member' });
  });

  it('members cannot call owner endpoints', async () => {
    for (const [m, u, b] of [['GET', '/v1/members'], ['GET', '/v1/gpu/warm'], ['POST', '/v1/gpu/warm', { on: true }], ['PATCH', '/v1/settings/image-engine', { provider: 'simulated' }], ['POST', '/v1/wallets/transfer', { toUserId: tess.id, tokens: 1 }], ['POST', '/v1/wallets/reclaim', { fromUserId: tess.id, tokens: 1 }],
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
    expect((await owner.req('GET', '/v1/studio/balance')).body).toMatchObject({ balanceUsd: 20, membersCreditUsd: 15, availableUsd: 5 });
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

  it('spending from every engine counts against the studio balance; the owner spends from what is free', async () => {
    const sb = (await owner.req('GET', '/v1/studio/balance')).body;
    expect(sb.spentUsd).toBeGreaterThan(0); // tess's render settled
    expect(sb.balanceUsd).toBeCloseTo(20 - sb.spentUsd, 6);
    const w = (await tess.req('GET', '/v1/wallet')).body, m = (await mo.req('GET', '/v1/wallet')).body;
    expect(sb.availableUsd).toBeCloseTo(sb.balanceUsd - (w.tokens + w.heldTokens + m.tokens + m.heldTokens) / 100, 6);
    const om = await sienna(owner);
    const r = await owner.req('POST', '/v1/jobs', { title: 'x', modelId: om.id, steps: 10, takes: 1, use: 'full' }); // ~$1.3 > what's free
    if (sb.availableUsd < 1.3) { expect(r.status).toBe(402); expect(r.body.code).toBe('insufficient_balance'); expect(r.body.error).toMatch(/studio balance/); }
  });

  it('without a RunPod key the studio balance still works (it never reads RunPod); POST /v1/balance/topup records a top-up', async () => {
    const b = await makeApp({ BALANCE_MODE: 'runpod' });
    const p = await people(b, 1, { topUp: 0 });
    expect((await p.owner.req('GET', '/v1/balance')).body).toMatchObject({ balanceSource: 'studio', balance: 0, needsFirstTopUp: true });
    const r = await p.owner.req('POST', '/v1/balance/topup', { amount: 5, method: 'card' });
    expect(r.body).toMatchObject({ balance: 5, studioBalance: 5, needsFirstTopUp: false });
    expect((await p.owner.req('POST', '/v1/wallets/transfer', { toUserId: p.members[0]!.id, tokens: 500 })).status).toBe(200);
    expect((await p.owner.req('POST', '/v1/wallets/transfer', { toUserId: p.members[0]!.id, tokens: 1 })).body.code).toBe('over_allocation');
    await b.close();
  });
});
