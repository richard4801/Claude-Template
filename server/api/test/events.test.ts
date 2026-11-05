// Live events (plans/api.md "Live events"): two SSE clients in one studio (the owner and a member) see every change as it
// happens, each in their own view; members never get owner-only payloads (studio balance, top-ups, members, invites,
// engines, image models, a template's hidden layers).
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { EventHub } from '../src/events.js';
import { demoModel, makeApp, people, sse, until, type Client } from './helpers.js';

const SECRET = 'hidden-laundrette-layer';

describe('live events: owner + member in one studio', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, base: string, owner: Client, member: Client, modelId: string;
  let oEs: Awaited<ReturnType<typeof sse>>, mEs: Awaited<ReturnType<typeof sse>>;
  beforeAll(async () => {
    a = await makeApp({ DEV_MODE: 'true', BALANCE_MODE: 'simulated', CAP_PER_USER_DAY_USD: '50', CAP_PER_DAY_USD: '100' });
    await a.app.listen({ port: 0, host: '127.0.0.1' });
    base = `http://127.0.0.1:${(a.app.server.address() as any).port}`;
    const p = await people(a, 1); owner = p.owner; member = p.members[0]!;
    modelId = (await demoModel(owner)).id;
    oEs = await sse(base, owner.token);
    mEs = await sse(base, member.token);
  });
  afterAll(async () => { await oEs.stop(); await mEs.stop(); await a.close(); });

  /** Nothing a member receives may carry an owner-only field. */
  const memberClean = () => {
    const s = JSON.stringify(mEs.events);
    for (const bad of [SECRET, 'studioBalance', 'availableToSend', 'toppedUpUsd', '"imageEngine"', '"imageModels"', '"engines"', '"variationPool"']) expect(s).not.toContain(bad);
    expect(mEs.events.filter(e => ['studio', 'member', 'invite'].includes(e.type))).toEqual([]);
  };

  it('a top-up: the owner gets studio + balance events, the member nothing about the studio money', async () => {
    const n = mEs.events.length;
    expect((await owner.req('POST', '/v1/studio/topups', { amountUsd: 25, note: 'live' })).status).toBe(200);
    const st = await until(() => oEs.events.find(e => e.type === 'studio' && e.studioBalance.topUps.some((t: any) => t.note === 'live')));
    expect(st.studioBalance.toppedUpUsd).toBeGreaterThanOrEqual(125);
    await until(() => oEs.events.some(e => e.type === 'balance' && e.balance.studioBalance >= 125));
    await new Promise(r => setTimeout(r, 100));
    expect(mEs.events.slice(n).filter(e => e.type === 'balance' || e.type === 'studio')).toEqual([]);
    memberClean();
  });

  it('a credit transfer: the member gets wallet + balance, the owner gets the member row and the studio card', async () => {
    expect((await owner.req('POST', '/v1/wallets/transfer', { toUserId: member.id, tokens: 1000 })).status).toBe(200);
    await until(() => mEs.events.find(e => e.type === 'wallet' && e.wallet.tokens === 1000));
    await until(() => mEs.events.find(e => e.type === 'balance' && e.balance.role === 'member' && e.balance.tokens === 1000));
    const row = await until(() => oEs.events.find(e => e.type === 'member' && e.member.id === member.id && e.member.tokens === 1000));
    expect(row.member.email).toBe('member1@test.dev');
    memberClean();
  });

  let tpl: any;
  it('templates: the owner sees the layers, the member only a public view (and a delete while private)', async () => {
    tpl = (await owner.req('POST', '/v1/templates', { name: 'Laundrette', layers: { scene: SECRET }, variationPool: { pose: ['pose-one'] } })).body;
    const own = await until(() => oEs.events.find(e => e.type === 'template' && e.template?.id === tpl.id));
    expect(own.template.layers.scene).toBe(SECRET);
    await until(() => mEs.events.find(e => e.type === 'template' && e.op === 'delete' && e.id === tpl.id));
    expect((await owner.req('PATCH', `/v1/templates/${tpl.id}`, { visibility: 'public' })).status).toBe(200);
    const pub = await until(() => mEs.events.find(e => e.type === 'template' && e.template?.id === tpl.id));
    expect(pub.template).toMatchObject({ name: 'Laundrette', visibility: 'public', isOwner: false });
    expect(pub.template.layers).toBeUndefined();
    // A favourite is personal: only the member's devices hear it.
    const before = oEs.events.length;
    await member.req('POST', `/v1/templates/${tpl.id}/favourite`);
    await until(() => mEs.events.find(e => e.type === 'template' && e.template?.id === tpl.id && e.template.favourite === true));
    await new Promise(r => setTimeout(r, 100));
    expect(oEs.events.slice(before).some(e => e.type === 'template' && e.template?.favourite)).toBe(false);
    memberClean();
  });

  it('a photoshoot on one device shows up on the other: takes, then status and delete', async () => {
    const shots = (await member.req('POST', '/v1/shoots', { modelId, count: 2, templateId: tpl.id })).body;
    expect(shots).toHaveLength(2);
    for (const s of shots) {
      const o = await until(() => oEs.events.find(e => e.type === 'take' && e.take?.id === s.id));
      const m = await until(() => mEs.events.find(e => e.type === 'take' && e.take?.id === s.id));
      // The template's owner sees the full prompt (with its hidden layer); the member the public one.
      expect(o.take.prompt).toContain(SECRET);
      expect(m.take.prompt).not.toContain(SECRET);
    }
    // The template's use count follows on both.
    await until(() => mEs.events.find(e => e.type === 'template' && e.template?.id === tpl.id && e.template.uses === 1));
    // A plain shoot too.
    const plain = (await owner.req('POST', '/v1/shoots', { modelId, count: 1 })).body;
    await until(() => mEs.events.find(e => e.type === 'take' && e.take?.id === plain[0].id));

    expect((await owner.req('PATCH', `/v1/takes/${shots[0].id}`, { status: 'final' })).status).toBe(200);
    await until(() => mEs.events.find(e => e.type === 'take' && e.take?.id === shots[0].id && e.take.status === 'final'));
    expect((await member.req('DELETE', `/v1/takes/${shots[1].id}`)).status).toBe(204);
    await until(() => oEs.events.find(e => e.type === 'take' && e.op === 'delete' && e.id === shots[1].id));
    // The shoot's money moved: the member's wallet and the owner's studio card.
    await until(() => mEs.events.find(e => e.type === 'wallet' && e.wallet.tokens < 1000));
    await until(() => oEs.events.find(e => e.type === 'member' && e.member.id === member.id && e.member.tokens < 1000));
    memberClean();
  });

  it('models, outfits, settings, members and invites', async () => {
    const m = (await member.req('POST', '/v1/models', { name: 'Live model' })).body;
    await until(() => oEs.events.find(e => e.type === 'model' && e.model.id === m.id));
    expect((await owner.req('POST', `/v1/models/${m.id}/archive`)).status).toBe(200);
    await until(() => mEs.events.find(e => e.type === 'model' && e.model.id === m.id && e.model.archived === true));
    expect((await owner.req('DELETE', `/v1/models/${m.id}`)).status).toBe(204);
    await until(() => mEs.events.find(e => e.type === 'model' && e.op === 'delete' && e.id === m.id));

    const o = (await owner.req('POST', '/v1/outfits', { modelId, name: 'Live fit', mode: 'describe', description: 'red dress' })).body;
    await until(() => mEs.events.find(e => e.type === 'outfit' && e.outfit.id === o.id && e.outfit.state === 'generating'));
    await until(() => mEs.events.find(e => e.type === 'outfit' && e.outfit.id === o.id && e.outfit.state === 'preview'), 20_000);

    expect((await owner.req('PATCH', '/v1/settings/studio', { capPerJob: 4 })).status).toBe(200);
    const os = await until(() => oEs.events.find(e => e.type === 'settings' && e.settings?.capPerJob === 4));
    const ms = await until(() => mEs.events.find(e => e.type === 'settings' && e.settings?.capPerJob === 4));
    expect(os.settings.engines).toBeDefined();
    expect(ms.settings.engines).toBeUndefined();
    expect(ms.settings.maxGpus).toBeUndefined();

    expect((await owner.req('PATCH', '/v1/settings/image-engine', { provider: 'simulated' })).status).toBe(200);
    await until(() => oEs.events.find(e => e.type === 'settings' && e.imageEngine?.provider === 'simulated'));

    expect((await owner.req('PATCH', `/v1/members/${member.id}`, { capPerJob: 2 })).status).toBe(200);
    await until(() => oEs.events.find(e => e.type === 'member' && e.member.id === member.id && e.member.capPerJob === 2));
    await until(() => mEs.events.find(e => e.type === 'balance' && e.balance.perJobLimit === 2));

    expect((await owner.req('POST', '/v1/invites', { email: 'new@test.dev' })).status).toBe(200);
    await until(() => oEs.events.find(e => e.type === 'invite' && e.invite?.email === 'new@test.dev'));
    await new Promise(r => setTimeout(r, 100));
    memberClean();
  });

  it('SSE headers: no buffering or transforming by a proxy', async () => {
    const ctrl = new AbortController();
    const res = await fetch(`${base}/v1/events`, { headers: { authorization: `Bearer ${member.token}` }, signal: ctrl.signal });
    expect(res.headers.get('content-type')).toMatch(/text\/event-stream/);
    expect(res.headers.get('cache-control')).toContain('no-transform');
    expect(res.headers.get('x-accel-buffering')).toBe('no');
    ctrl.abort();
  });
});

describe('EventHub', () => {
  it('per-viewer views keep each client in emit order, once per user, and skip nulls', async () => {
    const hub = new EventHub();
    const got: Record<string, string[]> = { o: [], m: [], m2: [] };
    hub.subscribe('s', 'o', l => got.o!.push(l), 'owner');
    hub.subscribe('s', 'm', l => got.m!.push(l), 'member');
    hub.subscribe('s', 'm', l => got.m2!.push(l), 'member');
    hub.subscribe('other', 'x', () => { throw new Error('wrong studio'); }, 'owner');
    let calls = 0;
    const slow = hub.emit('s', async v => { calls++; await new Promise(r => setTimeout(r, 30)); return { type: 'take', n: 1, role: v.role }; });
    hub.emit('s', { type: 'take', n: 2 });
    hub.emitOwners('s', { type: 'studio', n: 3 });
    hub.emit('s', v => (v.role === 'owner' ? { type: 'take', n: 4 } : null));
    await slow;
    await new Promise(r => setTimeout(r, 10));
    const ns = (ls: string[]) => ls.map(l => JSON.parse(l.slice(6)).n);
    expect(ns(got.o!)).toEqual([1, 2, 3, 4]);
    expect(ns(got.m!)).toEqual([1, 2]);
    expect(ns(got.m2!)).toEqual([1, 2]);
    expect(calls).toBe(2);
    expect(JSON.parse(got.o![0]!.slice(6)).role).toBe('owner');
  });
});
