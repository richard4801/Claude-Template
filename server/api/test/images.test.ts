import http from 'node:http';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CustomHttpEngine, FalEngine } from '../src/images/engines.js';
import { makeApp, people, sienna, type Client } from './helpers.js';

describe('image engine adapters', () => {
  it('fal: submits to the queue, polls, fetches the result', async () => {
    const calls: { url: string; method: string; auth: string; body?: any }[] = [];
    let polls = 0;
    const f = (async (url: string, init: any = {}) => {
      calls.push({ url, method: init.method ?? 'GET', auth: init.headers?.authorization, body: init.body && JSON.parse(init.body) });
      if (init.method === 'POST') return Response.json({ request_id: 'r1', status_url: 'https://queue.fal.run/m/requests/r1/status', response_url: 'https://queue.fal.run/m/requests/r1' });
      if (url.endsWith('/status')) return Response.json({ status: ++polls < 2 ? 'IN_PROGRESS' : 'COMPLETED' });
      return Response.json({ images: [{ url: 'https://fal.media/a.png' }, { url: 'https://fal.media/b.png' }], seed: 77 });
    }) as typeof fetch;
    const e = new FalEngine('fal_key', 'https://queue.fal.run', 0.03, 5000, f, 1);
    const r = await e.generate({ prompt: 'p', referenceImages: ['https://r2/x.jpg'], width: 768, height: 1024, count: 2, seed: 5 }, { provider: 'fal', model: 'fal-ai/bytedance/seedream/v4/edit' });
    expect(calls[0]).toMatchObject({ url: 'https://queue.fal.run/fal-ai/bytedance/seedream/v4/edit', method: 'POST', auth: 'Key fal_key',
      body: { prompt: 'p', num_images: 2, image_size: { width: 768, height: 1024 }, seed: 5, image_urls: ['https://r2/x.jpg'] } });
    expect(r).toEqual({ images: [{ url: 'https://fal.media/a.png' }, { url: 'https://fal.media/b.png' }], seed: 77, costUsd: 0.06 });
    await expect(new FalEngine(undefined, 'x', 0, 1, f).generate({ prompt: 'p', referenceImages: [], width: 1, height: 1, count: 1 }, { provider: 'fal', model: 'm' })).rejects.toThrow(/FAL_KEY/);
  });

  it('custom-http: posts our contract and reads {images, seed, costUsd}', async () => {
    let got: any;
    const srv = http.createServer((req, res) => {
      let b = ''; req.on('data', c => (b += c)); req.on('end', () => { got = JSON.parse(b); res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ images: [{ b64: 'aGk=' }], seed: 9, costUsd: 0.01 })); });
    });
    await new Promise<void>(r => srv.listen(0, '127.0.0.1', r));
    const url = `http://127.0.0.1:${(srv.address() as any).port}/gen`;
    const r = await new CustomHttpEngine(5000).generate({ prompt: 'p', negative: 'n', referenceImages: ['u'], width: 1, height: 2, seed: 3, count: 1, simAssets: ['x'] }, { provider: 'custom-http', model: 'mine', url });
    expect(got).toEqual({ prompt: 'p', negative: 'n', referenceImages: ['u'], width: 1, height: 2, seed: 3, count: 1, model: 'mine' });
    expect(r).toEqual({ images: [{ b64: 'aGk=' }], seed: 9, costUsd: 0.01 });
    srv.close();
  });
});

describe('image engine selection per studio', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, tess: Client;
  let srv: http.Server, url: string;
  beforeAll(async () => {
    srv = http.createServer((req, res) => { req.resume(); req.on('end', () => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ images: [{ b64: Buffer.from('png!').toString('base64') }], seed: 4242, costUsd: 0.02 })); }); });
    await new Promise<void>(r => srv.listen(0, '127.0.0.1', r));
    url = `http://127.0.0.1:${(srv.address() as any).port}/gen`;
    a = await makeApp({ DEV_MODE: 'true', BALANCE_MODE: 'simulated', SIM_START_BALANCE: '20' });
    const p = await people(a, 1); owner = p.owner; tess = p.members[0]!;
    await a.ctx.money.simTopUp({ id: owner.id, studioId: (await a.ctx.db.query.users.findFirst())!.studioId, role: 'owner' }, 20);
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: tess.id, tokens: 500 });
  });
  afterAll(async () => { await a.close(); srv.close(); });

  it('defaults to simulated; fal needs FAL_KEY; custom-http is owner-only', async () => {
    expect((await tess.req('GET', '/v1/settings/image-engine')).body).toMatchObject({ provider: 'simulated', model: 'bundled-stills', available: { simulated: true, fal: false, 'custom-http': true } });
    expect((await tess.req('PATCH', '/v1/settings/image-engine', { provider: 'fal' })).status).toBe(400);
    expect((await tess.req('PATCH', '/v1/settings/image-engine', { provider: 'custom-http', model: 'mine', url })).status).toBe(403);
    const r = await owner.req('PATCH', '/v1/settings/image-engine', { provider: 'custom-http', model: 'mine', url });
    expect(r.body).toMatchObject({ provider: 'custom-http', model: 'mine', url });
  });

  it('shoots use the studio engine, store the image and record provider, model, prompt, seed and cost', async () => {
    const m = await sienna(tess);
    const shots = (await tess.req('POST', '/v1/shoots', { modelId: m.id, scene: 'Rooftop · golden hour', count: 1 })).body;
    expect(shots.length).toBe(1);
    expect(shots[0].thumb.url).toMatch(/^\/uploads\/g\/img_[0-9a-f]+\.png$/);
    expect(shots[0].seed).toBe(4242);
    const rec = (await a.ctx.db.query.generatedImages.findMany())[0]!;
    expect(rec).toMatchObject({ provider: 'custom-http', model: 'mine', seed: 4242, costUsd: 0.02, purpose: 'shoot' });
    expect(rec.prompt).toContain('Scene: rooftop.');
    const img = await a.app.inject({ method: 'GET', url: shots[0].thumb.url });
    expect(img.body).toBe('png!');
    // A call can override the studio's engine.
    const sim = (await tess.req('POST', '/v1/shoots', { modelId: m.id, scene: 'Café', count: 2, imageEngine: { provider: 'simulated' } })).body;
    expect(sim[0].thumb.asset).toBe('g_front');
    expect((await a.ctx.db.query.generatedImages.findMany()).filter(x => x.provider === 'simulated').length).toBe(2);
  });

  it('an engine failure refunds the shoot', async () => {
    await owner.req('PATCH', '/v1/settings/image-engine', { provider: 'custom-http', model: 'mine', url: 'http://127.0.0.1:1/nothing' });
    const m = (await tess.req('GET', '/v1/models')).body[0];
    const before = (await tess.req('GET', '/v1/wallet')).body.tokens;
    const r = await tess.req('POST', '/v1/shoots', { modelId: m.id, count: 1 });
    expect(r.status).toBe(502); expect(r.body.code).toBe('image_engine_failed');
    expect((await tess.req('GET', '/v1/wallet')).body.tokens).toBe(before);
  });
});
