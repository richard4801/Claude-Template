// Keep GPU warm (services/warm.ts): on/off, per-minute billing, no double charge, the auto-off rules and their
// warnings, the studio permission and the live events. Simulated GPU mode, plus the RunPod controller against a fake
// RunPod API. No real pod is ever started; time is driven by passing a fake `now` to the dispatcher's pass.
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { and, eq } from 'drizzle-orm';
import { jobs, ledger, pods, users, warmSessions } from '../src/db/schema.js';
import { RunpodApi } from '../src/gpu/runpodApi.js';
import { client, makeApp, people, demoModel, sse, until, type Client } from './helpers.js';

const MIN = 60_000;
const RATE = 3.99;
type App = Awaited<ReturnType<typeof makeApp>>;

/** Live events for one user, straight from the hub. */
async function listen(a: App, c: Client) {
  const [u] = await a.ctx.db.select({ studioId: users.studioId }).from(users).where(eq(users.id, c.id));
  const events: any[] = [];
  const stop = a.ctx.hub.subscribe(u!.studioId, c.id, line => events.push(JSON.parse(line.replace(/^data: /, ''))));
  return { events, gpu: () => events.filter(e => e.type === 'gpu'), stop };
}

const warmLines = async (a: App, userId: string) =>
  (await a.ctx.db.select().from(ledger).where(and(eq(ledger.kind, 'warm'), eq(ledger.userId, userId))));
const sum = (rows: { amountUsd: number }[]) => rows.reduce((s, r) => s + r.amountUsd, 0);
const session = async (a: App, userId: string) => (await a.ctx.db.select().from(warmSessions).where(eq(warmSessions.userId, userId)))
  .sort((x, y) => y.startedAt - x.startedAt)[0]!;

describe('Keep add-on engine ready (was Keep GPU warm), owner-only, simulated GPU', () => {
  let a: App;
  let owner: Client, co: Client, m1: Client, m2: Client;
  const tick = (now: number) => a.ctx.jobs.tick(now);
  const wallet = async (c: Client) => (await c.req('GET', '/v1/wallet')).body;

  beforeAll(async () => {
    a = await makeApp({ GPU_MODE: 'simulated', BALANCE_MODE: 'simulated', MAX_GPUS: '3' }, { startLoops: false });
    const p = await people(a, 2, { topUp: 1000 });
    owner = p.owner; [m1, m2] = p.members as [Client, Client];
    co = await coOwner(a, owner);
    for (const m of [m1, m2]) expect((await owner.req('POST', '/v1/wallets/transfer', { toUserId: m.id, tokens: 1500 })).status).toBe(200);
  });
  afterAll(async () => { await a.close(); });
  afterEach(async () => { for (const c of [owner, co]) await c.req('POST', '/v1/gpu/warm', { on: false }); });

  it('members never see or use it: 403 owner_only, no settings for it, no nudge data', async () => {
    for (const m of [m1, m2]) {
      for (const [verb, url, body] of [['GET', '/v1/gpu/warm'], ['POST', '/v1/gpu/warm', { on: true }], ['POST', '/v1/gpu/warm', { extend: true }]] as const) {
        const r = await m.req(verb, url, body);
        expect(r.status, `${verb} ${url}`).toBe(403); expect(r.body.code).toBe('owner_only');
      }
      const st = (await m.req('GET', '/v1/settings/studio')).body;
      for (const k of ['warmGpuAllowed', 'warmIdleMinutes', 'warmMaxMinutes', 'gpu', 'maxGpus', 'overheadPayer', 'engines', 'minRunpodBalance', 'lowBalance']) expect(st[k], k).toBeUndefined();
    }
    expect(await a.ctx.db.select().from(warmSessions)).toEqual([]);
  });

  it('is off by default for the owner; the owner settings show the rules under Engines', async () => {
    const g = (await owner.req('GET', '/v1/gpu/warm')).body;
    expect(g).toMatchObject({ state: 'off', startedAt: null, minutes: 0, costUsd: 0, autoOffAt: null, allowed: true, idleMinutes: 20, maxMinutes: 120, canExtend: false });
    const st = (await owner.req('GET', '/v1/settings/studio')).body;
    expect(st).toMatchObject({ warmIdleMinutes: 20, warmMaxMinutes: 120, engines: { keepReady: { idleMinutes: 20, maxMinutes: 120, ratePerHour: RATE } } });
    expect(st.warmGpuAllowed).toBeUndefined();
    // The retired permission is accepted and ignored.
    expect((await owner.req('PATCH', '/v1/settings/studio', { warmGpuAllowed: 'everyone' })).status).toBe(200);
    expect((await m1.req('POST', '/v1/gpu/warm', { on: true })).status).toBe(403);
    expect((await owner.req('POST', '/v1/gpu/warm', {})).status).toBe(400);
    expect((await owner.req('POST', '/v1/gpu/warm', { extend: true })).body.code).toBe('not_warm');
    expect((await owner.req('PATCH', '/v1/settings/studio', { warmIdleMinutes: 2 })).status).toBe(400);
  });

  it('on → a dedicated pod held by the session (no idle shutdown), off → the pod stops', async () => {
    const t0 = Date.now();
    const on = await owner.req('POST', '/v1/gpu/warm', { on: true });
    expect(on.status).toBe(200);
    expect(on.body).toMatchObject({ state: 'warm', minutes: 0, costUsd: 0, ratePerHour: RATE, busy: false, autoOffReason: 'idle', canExtend: true, allowed: true });
    expect(on.body.startedAt).toBeGreaterThanOrEqual(t0);
    expect(on.body.autoOffAt).toBe(on.body.readyAt + 20 * MIN);
    expect(on.body.warningAt).toBe(on.body.autoOffAt - 5 * MIN);
    expect((await owner.req('POST', '/v1/gpu/warm', { on: true })).body.startedAt).toBe(on.body.startedAt);
    const [pod] = await a.ctx.db.select().from(pods).where(eq(pods.assignedUserId, owner.id));
    expect(pod!.warmSessionId).toBeTruthy();
    await tick(t0 + 4 * MIN);
    expect((await a.ctx.db.select().from(pods).where(eq(pods.id, pod!.id)))[0]!.state).toBe('running');
    const off = (await owner.req('POST', '/v1/gpu/warm', { on: false })).body;
    expect(off).toMatchObject({ state: 'off', lastOff: { reason: 'user' } });
    expect((await a.ctx.db.select().from(pods).where(eq(pods.id, pod!.id)))[0]!.state).toBe('stopped');
    expect((await a.ctx.db.select().from(ledger).where(and(eq(ledger.kind, 'warmup'), eq(ledger.userId, owner.id)))).length).toBe(0);
  });

  it('bills the wall time per minute from the studio balance ("Add-on engine ready" lines), the last part pro rata', async () => {
    const before = (await owner.req('GET', '/v1/studio/balance')).body;
    const on = (await owner.req('POST', '/v1/gpu/warm', { on: true })).body;
    const t0 = on.startedAt as number;
    await tick(t0 + 30_000);
    expect((await warmLines(a, owner.id)).filter(l => l.createdAt >= t0).length).toBe(0);
    await tick(t0 + MIN + 1);
    let lines = (await warmLines(a, owner.id)).filter(l => l.createdAt >= t0);
    expect(lines.length).toBe(1);
    expect(lines[0]!.amountUsd).toBeCloseTo(RATE / 60, 6);
    expect(lines[0]!.note).toMatch(/^Add-on engine ready · 1 min/);
    await tick(t0 + 3.5 * MIN);
    lines = (await warmLines(a, owner.id)).filter(l => l.createdAt >= t0);
    expect(sum(lines)).toBeCloseTo(3 * RATE / 60, 6);
    expect((await owner.req('GET', '/v1/gpu/warm')).body.costUsd).toBeCloseTo(3 * RATE / 60, 3);
    const after = (await owner.req('GET', '/v1/studio/balance')).body;
    expect(before.balanceUsd - after.balanceUsd).toBeCloseTo(3 * RATE / 60, 6);
    expect((await wallet(m1)).tokens).toBe(1500); // members' credit isn't touched
    await owner.req('POST', '/v1/gpu/warm', { on: false });
    const s = await session(a, owner.id);
    expect(s.state).toBe('off');
    expect(s.costUsd).toBeCloseTo(3 * RATE / 60, 6);
  });

  it("the owner's renders on it are not charged GPU time again", async () => {
    const m = await demoModel(owner);
    const on = (await owner.req('POST', '/v1/gpu/warm', { on: true })).body;
    expect(on.state).toBe('warm');
    const j = (await owner.req('POST', '/v1/jobs', { title: 'On warm', modelId: m.id, steps: 4, engine: 'h3' })).body;
    expect(j.state).toBe('running');
    await tick(Date.now());
    const done = await until(async () => {
      const x = (await owner.req('GET', '/v1/jobs')).body.find((y: any) => y.id === j.id);
      return x?.state === 'done' ? x : null;
    });
    expect(done.warm).toBe(true);
    const [row] = await a.ctx.db.select().from(jobs).where(eq(jobs.id, j.id));
    expect(row!.actualCost).toBe(0);
    expect(row!.warmupCost).toBe(0);
    expect((await wallet(owner)).heldTokens).toBe(0);
    const [pod] = await a.ctx.db.select().from(pods).where(eq(pods.id, row!.podId!));
    expect(pod!.warmSessionId).toBe((await session(a, owner.id)).id);
  });

  it('idle: a warning 5 minutes before, then off after 20 minutes without a render (charged up to the auto-off)', async () => {
    const ev = await listen(a, owner);
    const on = (await owner.req('POST', '/v1/gpu/warm', { on: true })).body;
    const t0 = on.readyAt as number;
    await tick(t0 + 14 * MIN);
    expect(ev.gpu().filter(e => e.event === 'warning').length).toBe(0);
    await tick(t0 + 15 * MIN + 1);
    const warn = ev.gpu().filter(e => e.event === 'warning');
    expect(warn.length).toBe(1);
    expect(warn[0].warning).toMatchObject({ reason: 'idle', autoOffAt: t0 + 20 * MIN });
    expect(warn[0].warning.message).toBe('Add-on engine turns off in 5 min (no renders)');
    await tick(t0 + 16 * MIN);
    expect(ev.gpu().filter(e => e.event === 'warning').length).toBe(1);
    await tick(t0 + 20 * MIN + 30_000);
    const g = (await owner.req('GET', '/v1/gpu/warm')).body;
    expect(g).toMatchObject({ state: 'off', lastOff: { reason: 'idle' } });
    expect((await session(a, owner.id)).costUsd).toBeCloseTo(20 * RATE / 60, 6);
    expect(ev.gpu().filter(e => e.event === 'state').map(e => e.gpu.state)).toEqual(['warm', 'stopping', 'off']);
    ev.stop();
  });

  it('cap: warning 5 minutes before, "Keep ready" extends it once, then it turns off', async () => {
    expect((await owner.req('PATCH', '/v1/settings/studio', { warmIdleMinutes: 120, warmMaxMinutes: 30 })).status).toBe(200);
    try {
      const ev = await listen(a, owner);
      const on = (await owner.req('POST', '/v1/gpu/warm', { on: true })).body;
      expect(on).toMatchObject({ autoOffReason: 'cap', maxMinutes: 30, canExtend: true });
      const t0 = on.startedAt as number;
      await tick(t0 + 25 * MIN + 1);
      expect(ev.gpu().filter(e => e.event === 'warning').map(e => e.warning.reason)).toEqual(['cap']);
      const ext = (await owner.req('POST', '/v1/gpu/warm', { extend: true })).body;
      expect(ext).toMatchObject({ maxMinutes: 60, canExtend: false, autoOffAt: t0 + 60 * MIN, autoOffReason: 'cap' });
      expect((await owner.req('POST', '/v1/gpu/warm', { extend: true })).body).toMatchObject({ maxMinutes: 60, canExtend: false });
      await tick(t0 + 60 * MIN);
      expect((await owner.req('GET', '/v1/gpu/warm')).body.lastOff).toMatchObject({ reason: 'cap', minutes: 60 });
      ev.stop();
    } finally {
      await owner.req('PATCH', '/v1/settings/studio', { warmIdleMinutes: 20, warmMaxMinutes: 120 });
    }
  });

  it("credit: refused when the studio balance can't cover 10 minutes, and turns off when it no longer can; a low RunPod balance plays no part", async () => {
    // Soak up what's free by sending it to a member, leaving $1.00.
    const free = (await owner.req('GET', '/v1/studio/balance')).body.availableUsd;
    expect((await owner.req('POST', '/v1/wallets/transfer', { toUserId: m2.id, tokens: Math.floor(free * 100) - 50 })).status).toBe(200);
    const r = await owner.req('POST', '/v1/gpu/warm', { on: true });
    expect(r.status).toBe(402);
    expect(r.body.code).toBe('insufficient_balance');
    expect(r.body.error).toMatch(/studio balance.*\$0\.67/);
    expect((await owner.req('POST', '/v1/wallets/reclaim', { fromUserId: m2.id, tokens: 50 })).status).toBe(200); // ~$1.00 free
    const on = (await owner.req('POST', '/v1/gpu/warm', { on: true })).body;
    expect(on.state).toBe('warm');
    const t0 = on.startedAt as number;
    await tick(t0 + 4 * MIN + 1);
    expect((await owner.req('GET', '/v1/gpu/warm')).body.state).toBe('warm');
    await tick(t0 + 6 * MIN + 1);
    const g = (await owner.req('GET', '/v1/gpu/warm')).body;
    expect(g).toMatchObject({ state: 'off', lastOff: { reason: 'credit' } });
    const back = (await wallet(m2)).tokens;
    expect((await owner.req('POST', '/v1/wallets/reclaim', { fromUserId: m2.id, tokens: back - 1500 })).status).toBe(200);
  });

  it('SSE: gpu events (state, the per-minute tick, the warning) reach only that owner', async () => {
    await a.app.listen({ port: 0, host: '127.0.0.1' });
    const addr = a.app.server.address() as { port: number };
    const base = `http://127.0.0.1:${addr.port}`;
    const mine = await sse(base, owner.token), coEv = await sse(base, co.token), member = await sse(base, m1.token);
    try {
      const on = (await owner.req('POST', '/v1/gpu/warm', { on: true })).body;
      await tick(on.startedAt + MIN + 1);
      await tick(on.readyAt + 15 * MIN + 1);
      await owner.req('POST', '/v1/gpu/warm', { on: false });
      await until(() => mine.events.some(e => e.type === 'gpu' && e.gpu.state === 'off'));
      const g = mine.events.filter(e => e.type === 'gpu');
      expect(g[0]).toMatchObject({ type: 'gpu', event: 'state', gpu: { state: 'warm' } });
      expect(g.find(e => e.event === 'tick').gpu.minutes).toBe(1);
      expect(g.find(e => e.event === 'warning').warning.reason).toBe('idle');
      expect(coEv.events.filter(e => e.type === 'gpu').length).toBe(0);
      expect(member.events.filter(e => e.type === 'gpu').length).toBe(0);
    } finally { await mine.stop(); await coEv.stop(); await member.stop(); }
  });
});

/** A second owner of the same studio (an owner-role invite). */
async function coOwner(a: App, owner: Client): Promise<Client> {
  const inv = (await owner.req('POST', '/v1/invites', { role: 'owner' })).body;
  const r = await client(a)('POST', '/v1/auth/signup', { studioName: 'x', email: `co${Date.now()}@test.dev`, password: 'correct horse', inviteCode: inv.code, attestAdultRightsOriginal: true, attestLabelAi: true });
  expect(r.status).toBe(200);
  return { token: r.body.token, id: r.body.user.id, role: 'owner', req: client(a, r.body.token) };
}

// ---------------------------------------------------------------------------------------------- RunPod (fake API)
type Fake = { balance: number; deployed: { id: string; token: string; podId: string; env: Record<string, string> }[]; terminated: string[] };
function fakeRunpod(state: Fake) {
  let n = 0;
  const f = (async (_url: string, init: any) => {
    const { query, variables } = JSON.parse(init.body);
    if (query.includes('myself')) return Response.json({ data: { myself: { clientBalance: state.balance, currentSpendPerHr: 0 } } });
    if (query.includes('podFindAndDeployOnDemand')) {
      const env = Object.fromEntries(variables.input.env.map((e: any) => [e.key, e.value]));
      const id = `rpw${++n}`;
      state.deployed.push({ id, token: env.WORKER_TOKEN, podId: env.MUSE_POD_ID, env });
      return Response.json({ data: { podFindAndDeployOnDemand: { id, desiredStatus: 'RUNNING', costPerHr: 3.6 } } });
    }
    if (query.includes('podTerminate')) { state.terminated.push(variables.input.podId); return Response.json({ data: { podTerminate: null } }); }
    return Response.json({ errors: [{ message: 'not faked' }] });
  }) as typeof fetch;
  return new RunpodApi('rp_test_key', 'http://runpod.fake/graphql', f);
}

describe('Keep add-on engine ready on the RunPod controller (fake RunPod)', () => {
  let a: App;
  let owner: Client, m1: Client, m2: Client; // m1 = the owner, m2 = a co-owner (it's owner-only)
  const rp: Fake = { balance: 100, deployed: [], terminated: [] };
  const worker = (token: string) => async (url: string, body: unknown = {}) => {
    const r = await a.app.inject({ method: 'POST', url, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, payload: JSON.stringify(body) });
    return { status: r.statusCode, body: r.body ? JSON.parse(r.body) : null };
  };
  const tick = (now: number) => a.ctx.jobs.tick(now);

  beforeAll(async () => {
    a = await makeApp({ GPU_MODE: 'runpod', BALANCE_MODE: 'runpod', RUNPOD_NETWORK_VOLUME_ID: 'vol_123', MAX_GPUS: '1', PUBLIC_URL: 'http://api.test' },
      { runpod: fakeRunpod(rp), startLoops: false });
    const p = await people(a, 0);
    owner = p.owner; m1 = owner; m2 = await coOwner(a, owner);
  });
  afterAll(async () => { await a.close(); });

  it('starting while the pod boots (billed from the start), warm once the worker reports in, a render on it is free, off terminates it', async () => {
    const on = (await m1.req('POST', '/v1/gpu/warm', { on: true })).body;
    expect(on).toMatchObject({ state: 'starting', readyAt: null, autoOffReason: 'cap' });
    expect(rp.deployed.length).toBe(1);
    const d = rp.deployed[0]!;
    // The worker's own idle self-stop is later than the warm idle auto-off (20 min), so it never cuts a warm GPU short.
    expect(Number(d.env.SELF_STOP_IDLE_SECONDS)).toBeGreaterThanOrEqual(20 * 60 + 300);
    const t0 = on.startedAt as number;
    // Boots for 4 minutes: billed, and no idle shutdown or boot timeout meanwhile.
    await tick(t0 + 4 * MIN + 1);
    expect((await m1.req('GET', '/v1/gpu/warm')).body.state).toBe('starting');
    expect(sum(await warmLines(a, m1.id))).toBeCloseTo(4 * 3.6 / 60, 6); // the pod's own rate
    // Only one GPU allowed: someone else can't get one while it's held.
    const busy = await m2.req('POST', '/v1/gpu/warm', { on: true });
    expect(busy.status).toBe(409);
    expect(busy.body.code).toBe('no_gpu_free');
    // The worker reports in.
    const w = worker(d.token);
    expect((await w('/worker/v1/heartbeat', { podId: d.id, busy: false, state: 'idle' })).status).toBe(204);
    await tick(Date.now());
    const warm = (await m1.req('GET', '/v1/gpu/warm')).body;
    expect(warm.state).toBe('warm');
    expect(warm.ratePerHour).toBe(3.6);
    // A render goes straight to the warm pod.
    const m = await demoModel(m1);
    const clip = await uploadClip(a, m1);
    const j = (await m1.req('POST', '/v1/jobs', { title: 'Warm', modelId: m.id, clipId: clip, steps: 10 })).body;
    await tick(Date.now());
    expect(rp.deployed.length).toBe(1);
    const c = await w('/worker/v1/claim', { podId: d.id, capabilities: ['h3', 'latentsync'] });
    expect(c.body.job.id).toBe(j.id);
    const put = await a.app.inject({ method: 'PUT', url: c.body.job.outputs[0].uploadUrl.replace('http://api.test', ''), headers: { 'content-type': 'video/mp4' }, payload: Buffer.from('v') });
    expect(put.statusCode).toBe(200);
    expect((await w(`/worker/v1/jobs/${j.id}/done`, { outputs: [{ name: 'take_1.mp4' }], gpuSeconds: 200, stats: { load_s: 40 } })).status).toBe(204);
    const [row] = await a.ctx.db.select().from(jobs).where(eq(jobs.id, j.id));
    expect(row!.state).toBe('done');
    expect(row!.actualCost).toBe(0);
    expect(row!.warmupCost).toBe(0); // no model-load line either: the warm GPU paid for that time
    expect((await a.ctx.db.select().from(ledger).where(and(eq(ledger.userId, m1.id), eq(ledger.kind, 'warmup')))).length).toBe(0);
    expect((await m1.req('GET', '/v1/wallet')).body.heldTokens).toBe(0);
    // Off: settled and terminated.
    const off = (await m1.req('POST', '/v1/gpu/warm', { on: false })).body;
    expect(off).toMatchObject({ state: 'off', lastOff: { reason: 'user' } });
    expect(rp.terminated).toContain(d.id);
  });

  it('turning off while a render runs hands the pod back to the pool; only the part after "off" is charged to the job', async () => {
    const on = (await m2.req('POST', '/v1/gpu/warm', { on: true })).body;
    expect(on.state).toBe('starting');
    const d = rp.deployed[rp.deployed.length - 1]!;
    const w = worker(d.token);
    await w('/worker/v1/heartbeat', { podId: d.id, busy: false });
    const m = await demoModel(m2);
    const clip = await uploadClip(a, m2);
    const j = (await m2.req('POST', '/v1/jobs', { title: 'Mid', modelId: m.id, clipId: clip, steps: 10 })).body;
    await tick(Date.now());
    const c = await w('/worker/v1/claim', { podId: d.id, capabilities: ['h3'] });
    expect(c.body.job.id).toBe(j.id);
    // Claimed 100 s ago (pretend), off now, done 100 s later: half of the render is outside the warm session.
    const claimedAt = Date.now() - 100_000;
    await a.ctx.db.update(jobs).set({ claimedAt }).where(eq(jobs.id, j.id));
    await a.ctx.db.update(warmSessions).set({ startedAt: claimedAt - 1000, settledUntil: claimedAt - 1000 }).where(eq(warmSessions.userId, m2.id));
    expect((await m2.req('POST', '/v1/gpu/warm', { on: false })).body.state).toBe('off');
    const [pod] = await a.ctx.db.select().from(pods).where(eq(pods.id, d.podId));
    expect(pod!.state).toBe('running');
    expect(pod!.warmSessionId).toBeNull();
    expect(rp.terminated).not.toContain(d.id);
    const sess = await session(a, m2.id);
    await a.ctx.db.update(warmSessions).set({ endedAt: Date.now() }).where(eq(warmSessions.id, sess.id));
    // Finish ~100 s after the session ended (the worker keeps sending heartbeats meanwhile).
    await a.ctx.db.update(pods).set({ lastHeartbeatAt: Date.now() + 3_600_000 }).where(eq(pods.id, d.podId));
    const realNow = Date.now;
    const fakeDone = Date.now() + 100_000;
    Date.now = () => fakeDone;
    try {
      const put = await a.app.inject({ method: 'PUT', url: c.body.job.outputs[0].uploadUrl.replace('http://api.test', ''), headers: { 'content-type': 'video/mp4' }, payload: Buffer.from('v') });
      expect(put.statusCode).toBe(200);
      expect((await w(`/worker/v1/jobs/${j.id}/done`, { outputs: [{ name: 'take_1.mp4' }], gpuSeconds: 200 })).status).toBe(204);
    } finally { Date.now = realNow; }
    const [row] = await a.ctx.db.select().from(jobs).where(eq(jobs.id, j.id));
    expect(row!.actualCost).toBeGreaterThan(200 / 3600 * 3.6 * 0.4);
    expect(row!.actualCost).toBeLessThan(200 / 3600 * 3.6 * 0.6);
    // Back in the pool it stops after the normal idle shutdown.
    await tick(fakeDone + 60_000);
    expect(rp.terminated).not.toContain(d.id);
    await tick(fakeDone + 181_000);
    expect(rp.terminated).toContain(d.id);
  });

  it('a pod lost while warm (heartbeats stop) ends the session as gpu_lost', async () => {
    const on = (await m1.req('POST', '/v1/gpu/warm', { on: true })).body;
    const d = rp.deployed[rp.deployed.length - 1]!;
    await worker(d.token)('/worker/v1/heartbeat', { podId: d.id, busy: false });
    await tick(on.startedAt + 1000);
    expect((await m1.req('GET', '/v1/gpu/warm')).body.state).toBe('warm');
    await tick(Date.now() + 61_000 + MIN);
    const g = (await m1.req('GET', '/v1/gpu/warm')).body;
    expect(g.state).toBe('off');
    expect(g.lastOff.reason).toBe('gpu_lost');
    expect(rp.terminated).toContain(d.id);
  });
});

async function uploadClip(a: App, c: Client) {
  const b = '----musetest';
  const meta = JSON.stringify({ name: 'dance', durationSec: 5.2, width: 1080, height: 1920, fps: 30 });
  const body = Buffer.concat([
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="meta"\r\n\r\n${meta}\r\n`),
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="dance.mp4"\r\nContent-Type: video/mp4\r\n\r\n`),
    Buffer.from('fake mp4 bytes'), Buffer.from(`\r\n--${b}--\r\n`),
  ]);
  const r = await a.app.inject({ method: 'POST', url: '/v1/uploads/clips', headers: { authorization: `Bearer ${c.token}`, 'content-type': `multipart/form-data; boundary=${b}` }, payload: body });
  expect(r.statusCode).toBe(200);
  return JSON.parse(r.body).id as string;
}
