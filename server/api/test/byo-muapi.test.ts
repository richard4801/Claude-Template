// Bring your own provider · Muapi (WS15). The Muapi adapter against a FAKE Muapi on localhost: its public catalog,
// model schemas and price quotes are recorded from api.muapi.ai (test/fixtures/byo/muapi-*.json, read without a key);
// balance, submit and poll answer in the shapes Muapi documents (muapi.ai/llms.txt, /playground/<model>/llms.txt).
// No live Muapi call, no key, no spend.
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { byoProviders, ledger } from '../src/db/schema.js';
import { analyse } from '../src/byo/classify.js';
import { MuapiAdapter, muapiError, muapiSchema, validSegment } from '../src/byo/adapters.js';
import { keyFromSecret, openKey } from '../src/byo/crypto.js';
import { makeApp, people, until } from './helpers.js';

const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures/byo');
const fixture = (n: string) => JSON.parse(fs.readFileSync(path.join(FIX, n), 'utf8'));
const detail = (name: string) => fixture(`muapi-model-${name}.json`);
const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const SECRET = crypto.randomBytes(32).toString('hex');
const MU_GOOD = 'mu_test_key_0123456789_qrst';
/** Words members never see for a custom Muapi model once the owner switches "Show provider names to members" off (4c). */
const PROVIDER_WORDS = /\b(muapi|seedance|kling|happy-horse|nano-banana|seedream|flux|bytedance)\b/i;
/** The provider's model refs: members never see them (only the owner's display name), whatever the settings. */
const MODEL_REFS = /kling-v2|seedream|seedance-2|bytedance-/i;
/** Never for members (4c): keys, prices at cost, markups. */
const OWNER_ONLY_WORDS = /costUsd|priceScale|apiKey|last4|mu_test/;
/** The fake's price list, in USD (the per-second rates match the quotes recorded from Muapi's estimate-cost). */
const RATES: Record<string, (b: any) => number | null> = {
  'seedance-2-t2v': b => Number(b.duration ?? 5) * (b.resolution === '480p' ? 0.12 : 0.15),
  'kling-v2.1-pro-i2v': b => Number(b.duration ?? 5) * 0.08,
  'happy-horse-1-image-to-video': b => Number(b.duration ?? 5) * (b.resolution === '1080p' ? 0.36 : 0.18),
  'bytedance-seedream-v4-edit': () => 0.04,
  'nano-banana': () => null, // the quote fails: no price, the owner sets one
};
const analysisOf = (name: string) => {
  const m = detail(name);
  const kind = /video/i.test(m.category) ? 'video' : 'image';
  return analyse({}, muapiSchema(m.input_schema.schemas.input_data, kind), { category: `x-to-${kind}` });
};

describe('Muapi schemas', () => {
  it('text-to-video: integer duration enum, resolutions, aspects; nothing missing', () => {
    const a = analysisOf('seedance-2-t2v');
    expect(a.kind).toBe('video');
    expect(a.map).toMatchObject({ prompt: 'prompt', duration: 'duration', aspectRatio: 'aspect_ratio', resolution: 'resolution' });
    expect(a.inputs).toMatchObject({ prompt: true, startImage: false, duration: { min: 5, max: 15, allowed: [5, 10, 15] }, resolutions: ['480p', '720p'], aspectRatios: ['16:9', '9:16', '4:3', '3:4'] });
    expect(a.shapes.duration).toBe('integer');
    expect(a.missing).toEqual([]);
  });
  it('image-to-video: URL fields with no format, "int" with minValue/maxValue/step, last_image as the end frame', () => {
    const a = analysisOf('kling-v2.1-pro-i2v');
    expect(a.map).toMatchObject({ startImage: 'image_url', endImage: 'last_image', duration: 'duration' });
    expect(a.inputs.duration).toEqual({ min: 5, max: 10, allowed: [5, 10] });
    expect(a.shapes.duration).toBe('integer');
    expect(a.startRequired).toBe(true);
    expect(a.missing).toEqual([]);
  });
  it('a one-image list on a video model is its start frame; a long step range stays a range', () => {
    const a = analysisOf('happy-horse-1-image-to-video');
    expect(a.map.startImage).toBe('images_list');
    expect(a.map.referenceImages).toBeUndefined();
    expect(a.startRequired).toBe(true);
    expect(a.inputs.duration).toMatchObject({ min: 3, max: 15 });
    expect(a.inputs.resolutions).toEqual(['720p', '1080p']);
  });
  it('image edit: the image list is references (up to 10)', () => {
    const a = analysisOf('bytedance-seedream-v4-edit');
    expect(a.kind).toBe('image');
    expect(a.map.referenceImages).toBe('images_list');
    expect(a.shapes.referenceImages).toBe('array');
    expect(a.inputs.referenceImages).toBe(10);
    expect(a.missing).toEqual([]);
  });
  it('refs are one path segment: path tricks are refused', () => {
    for (const ok of ['seedance-2-t2v', 'kling-v2.6-pro-t2v', 'seedance-v2.0-t2v']) expect(validSegment(ok)).toBe(true);
    for (const bad of ['../account/balance', 'a/b', '..', 'x..y', '.hidden', 'a b', 'a?b=1', 'a%2Fb', '', 'x'.repeat(101)]) expect(validSegment(bad)).toBe(false);
  });
  it('submit refusals map onto the suite\'s error kinds', () => {
    expect(muapiError(403, '{"detail":"Not authorized: missing or invalid credentials","error":{"code":"FORBIDDEN"}}')).toMatchObject({ kind: 'unavailable', status: 403 });
    expect(muapiError(401, '')).toMatchObject({ kind: 'unavailable' });
    expect(muapiError(402, '{}').kind).toBe('out_of_credit');
    expect(muapiError(400, '{"detail":"Insufficient balance. Please top up."}').kind).toBe('out_of_credit');
    expect(muapiError(403, '{"detail":"Insufficient credits"}').kind).toBe('out_of_credit');
    expect(muapiError(400, '{"detail":"Prompt flagged by content moderation"}').kind).toBe('refused');
    expect(muapiError(429, '').kind).toBe('rate_limited');
    expect(muapiError(503, '').kind).toBe('unavailable');
    expect(muapiError(422, '{"detail":"duration: bad value"}').kind).toBe('failed');
  });
});

describe('Bring your own provider · Muapi against a FAKE Muapi (recorded fixtures, no money)', () => {
  let server: http.Server, dir: string, base = '';
  const calls: { method: string; url: string; key?: string; auth?: string; body?: any }[] = [];
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-muapi-fake-'));
    const mp4 = path.join(dir, 'out.mp4');
    if (hasFfmpeg) execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=288x512:rate=24', '-t', '5', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', mp4]);
    const runs = new Map<string, any>();
    server = http.createServer((q, res) => {
      let raw = '';
      q.on('data', c => (raw += c));
      q.on('end', () => {
        const url = q.url ?? '', key = q.headers['x-api-key'] as string | undefined;
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (url === '/out.mp4') { res.writeHead(200, { 'content-type': 'video/mp4' }); fs.createReadStream(mp4).pipe(res); return; }
        const body = raw ? JSON.parse(raw) : undefined;
        calls.push({ method: q.method!, url, key, auth: q.headers.authorization, body });
        if (!url.startsWith('/mu/')) return json(404, {});
        const denied = () => json(403, { detail: 'Not authorized: missing or invalid credentials', error: { code: 'FORBIDDEN', message: 'Not authorized: missing or invalid credentials' } });
        const sub = url.slice('/mu/api/v1'.length);
        // Public: the catalog, one model, a quote.
        if (sub === '/models') return json(200, fixture('muapi-models.json'));
        let m = /^\/models\/([^/?]+)\/estimate-cost$/.exec(sub);
        if (m && q.method === 'POST') { const c = RATES[m[1]!]?.(body ?? {}); return c == null ? json(503, { detail: 'busy' }) : json(200, { model: m[1], cost: Math.round(c * 1e6) / 1e6, currency: 'USD', dynamic_pricing: true }); }
        m = /^\/models\/([^/?]+)$/.exec(sub);
        if (m) return fs.existsSync(path.join(FIX, `muapi-model-${m[1]}.json`)) ? json(200, detail(m[1]!)) : json(404, { detail: { error: { code: 'MODEL_NOT_FOUND', message: `Unknown model: ${m[1]}` } } });
        // Keyed.
        if (key !== MU_GOOD) return denied();
        if (sub === '/account/balance') return json(200, { balance: 12.5, currency: 'USD' });
        m = /^\/predictions\/([^/]+)\/result$/.exec(sub);
        if (m) { const r = runs.get(decodeURIComponent(m[1]!)); return r ? json(200, r) : json(404, { detail: 'Not found' }); }
        m = /^\/mu\/app\/cancel_prediction\/([^/]+)$/.exec(url);
        if (m && q.method === 'POST') { const r = runs.get(m[1]!); if (r) r.status = 'cancelled'; return json(200, { ok: true }); }
        m = /^\/([A-Za-z0-9][A-Za-z0-9._-]*)$/.exec(sub);
        if (m && q.method === 'POST') {
          const p = String(body?.prompt ?? '');
          if (/REFUSE/.test(p)) return json(400, { detail: 'Prompt flagged by content moderation' });
          if (/BROKE/.test(p)) return json(402, { detail: 'Insufficient balance. Please top up your wallet.' });
          if (/BUSY/.test(p)) return json(429, { detail: 'Too many requests' });
          const id = `req_${runs.size + 1}`;
          const done = { id, status: 'completed', outputs: [`${base}/out.mp4`], urls: { get: `${base}/mu/api/v1/predictions/${id}/result` }, has_nsfw_contents: [false] };
          runs.set(id, /NSFWOUT/.test(p) ? { ...done, has_nsfw_contents: [true] }
            : /FAILLATER/.test(p) ? { id, status: 'failed', outputs: [], error: 'Content policy violation' }
            : /HOLD/.test(p) ? { id, status: 'processing', outputs: [] } : done);
          return json(200, { request_id: id, status: 'processing' });
        }
        return json(404, { detail: 'Not Found' });
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(() => { server?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  const env = (extra: Record<string, string> = {}) => ({ PROVIDER_KEYS_SECRET: SECRET, MUAPI_API_URL: `${base}/mu/api/v1`, REPLICATE_API_URL: `${base}/none`,
    SUITE_POLL_MS: '10', REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated', ...extra });
  const noKeyIn = (o: unknown) => expect(JSON.stringify(o)).not.toContain(MU_GOOD);
  const publicCall = (c: { url: string }) => /\/models(\/[^/]+(\/estimate-cost)?)?$/.test(c.url);

  it('the adapter: validate, search with prices, submit / poll / cancel, and errors as suite kinds', async () => {
    const ad = new MuapiAdapter(() => `${base}/mu/api/v1`);
    calls.length = 0;
    expect(await ad.validate(MU_GOOD)).toBe('ok');
    expect(await ad.validate('mu_wrong_key_0000')).toBe('invalid');
    expect(calls.map(c => [c.url, c.key])).toEqual([['/mu/api/v1/account/balance', MU_GOOD], ['/mu/api/v1/account/balance', 'mu_wrong_key_0000']]);
    expect(calls.every(c => !c.auth)).toBe(true); // x-api-key only
    await expect(new MuapiAdapter(() => 'http://127.0.0.1:1/api/v1').validate(MU_GOOD)).rejects.toThrow(/muapi unreachable/);

    calls.length = 0;
    const v = await ad.search(MU_GOOD, { kind: 'video', limit: 10 });
    expect(v.models.map(m => [m.ref, m.version, m.analysis.kind, m.price])).toEqual([
      ['happy-horse-1-image-to-video', 'happy-horse-1-image-to-video', 'video', { basis: 'per_second', costUsd: 0.36, source: 'provider' }],
      ['kling-v2.1-pro-i2v', 'kling-v2.1-pro-i2v', 'video', { basis: 'per_second', costUsd: 0.08, source: 'provider' }],
      ['seedance-2-t2v', 'seedance-v2.0-t2v', 'video', { basis: 'per_second', costUsd: 0.15, source: 'provider' }],
    ]); // the lipsync model and the LLM are left out
    expect(v.nextCursor).toBeNull();
    // Public reads never carry the key.
    expect(calls.length).toBeGreaterThan(0);
    expect(calls.every(c => publicCall(c) && !c.key && !c.auth)).toBe(true);
    const img = await ad.search(MU_GOOD, { kind: 'image', limit: 10 });
    expect(img.models.map(m => [m.ref, m.price])).toEqual([
      ['bytedance-seedream-v4-edit', { basis: 'per_run', costUsd: 0.04, source: 'provider' }],
      ['nano-banana', null], // the quote failed: the owner prices it
    ]); // flux-3-dev is "coming soon" in the recorded catalog: left out, and can't be added
    expect(await ad.model(MU_GOOD, 'flux-3-dev')).toBeNull();
    // A fixed price (dynamic_pricing false) is used as is, with no quote.
    const fixedCalls: string[] = [];
    const fixedFetch = (async (u: string) => { fixedCalls.push(String(u)); return new Response(JSON.stringify({ ...detail('flux-3-dev'), is_coming_soon: false }), { status: 200 }); }) as typeof fetch;
    expect((await new MuapiAdapter(() => 'https://api.example/api/v1', fixedFetch).model(MU_GOOD, 'flux-3-dev'))?.price).toEqual({ basis: 'per_run', costUsd: 0.025, source: 'provider' });
    expect(fixedCalls).toEqual(['https://api.example/api/v1/models/flux-3-dev']);
    expect((await ad.search(MU_GOOD, { q: 'kling', limit: 10 })).models.map(m => m.ref)).toEqual(['kling-v2.1-pro-i2v']);
    const p1 = await ad.search(MU_GOOD, { limit: 2 });
    expect(p1.nextCursor).toBe('2');
    expect((await ad.search(MU_GOOD, { limit: 2, cursor: p1.nextCursor })).models).toHaveLength(2);
    expect(await ad.model(MU_GOOD, '../account/balance')).toBeNull();
    expect(await ad.model(MU_GOOD, 'no-such-model')).toBeNull();

    // Runs: POST /{endpoint_url}, a lone URL into a list field becomes a one-item list, then poll the result.
    calls.length = 0;
    const h = await ad.start(MU_GOOD, { ref: 'happy-horse-1-image-to-video', version: 'happy-horse-1-image-to-video' }, { prompt: 'A horse runs', images_list: 'https://cdn.example/s.jpg', duration: 5 });
    expect(calls[0]).toMatchObject({ method: 'POST', url: '/mu/api/v1/happy-horse-1-image-to-video', key: MU_GOOD, body: { prompt: 'A horse runs', images_list: ['https://cdn.example/s.jpg'], duration: 5 } });
    expect(await ad.get(MU_GOOD, h)).toEqual({ status: 'succeeded', url: `${base}/out.mp4` });
    await expect(ad.start(MU_GOOD, { ref: 'x', version: '../account' }, { prompt: 'p' })).rejects.toMatchObject({ kind: 'failed' });
    await expect(ad.start(MU_GOOD, { ref: 'seedance-2-t2v', version: 'seedance-v2.0-t2v' }, { prompt: 'REFUSE this' })).rejects.toMatchObject({ kind: 'refused' });
    await expect(ad.start(MU_GOOD, { ref: 'seedance-2-t2v', version: 'seedance-v2.0-t2v' }, { prompt: 'BROKE' })).rejects.toMatchObject({ kind: 'out_of_credit', status: 402 });
    await expect(ad.start(MU_GOOD, { ref: 'seedance-2-t2v', version: 'seedance-v2.0-t2v' }, { prompt: 'BUSY' })).rejects.toMatchObject({ kind: 'rate_limited' });
    const bad = await ad.start('mu_wrong_key_0000', { ref: 'seedance-2-t2v', version: 'seedance-v2.0-t2v' }, { prompt: 'p' }).catch(e => e);
    expect(bad).toMatchObject({ kind: 'unavailable', status: 403 });
    expect(bad.message).not.toContain('mu_wrong_key');
    const nsfw = await ad.get(MU_GOOD, await ad.start(MU_GOOD, { ref: 'seedance-2-t2v', version: 'seedance-v2.0-t2v' }, { prompt: 'NSFWOUT' }));
    expect(nsfw).toMatchObject({ status: 'failed', error: { kind: 'refused' } });
    const later = await ad.get(MU_GOOD, await ad.start(MU_GOOD, { ref: 'seedance-2-t2v', version: 'seedance-v2.0-t2v' }, { prompt: 'FAILLATER' }));
    expect(later).toMatchObject({ status: 'failed', error: { kind: 'refused' } });
    const hold = await ad.start(MU_GOOD, { ref: 'seedance-2-t2v', version: 'seedance-v2.0-t2v' }, { prompt: 'HOLD' });
    expect(await ad.get(MU_GOOD, hold)).toEqual({ status: 'running' });
    await ad.cancel(MU_GOOD, hold);
    expect(calls.at(-1)).toMatchObject({ method: 'POST', url: `/mu/app/cancel_prediction/${JSON.parse(hold).id}`, key: MU_GOOD });
    expect(await ad.get(MU_GOOD, hold)).toEqual({ status: 'canceled' });
    expect(await ad.get('mu_wrong_key_0000', hold)).toMatchObject({ status: 'failed', error: { kind: 'unavailable' } });
  });

  it('API: kinds list Muapi; a bad key is refused and not stored; a good one is encrypted; browse, add and switch on', async () => {
    const a = await makeApp(env({ SUITE_MODE: 'mock' }));
    const { owner } = await people(a, 0);
    try {
      const kinds = (await owner.req('GET', '/v1/providers/kinds')).body.kinds;
      expect(kinds.map((k: any) => k.kind)).toEqual(['replicate', 'fal', 'muapi', 'higgsfield']);
      expect(kinds[2]).toEqual({ kind: 'muapi', label: 'Muapi', keyHint: 'An API key from muapi.ai → Access keys', keyUrl: 'https://muapi.ai/access-keys' });

      const bad = await owner.req('POST', '/v1/providers', { kind: 'muapi', apiKey: 'mu_wrong_key_0000' });
      expect(bad.status).toBe(400);
      expect(bad.body.code).toBe('invalid_key');
      noKeyIn(bad.body);
      expect(await a.ctx.db.select().from(byoProviders)).toHaveLength(0);

      calls.length = 0;
      const add = await owner.req('POST', '/v1/providers', { kind: 'muapi', apiKey: MU_GOOD });
      expect(add.status).toBe(201);
      expect(add.body).toMatchObject({ kind: 'muapi', label: 'Muapi', keyLast4: '…qrst', status: 'ok' });
      noKeyIn(add.body);
      const [row] = await a.ctx.db.select().from(byoProviders);
      expect(row!.keyEnc).not.toContain(MU_GOOD);
      expect(openKey(keyFromSecret(SECRET), row!.keyEnc, row!.id)).toBe(MU_GOOD);
      const pid = add.body.id;

      const b = (await owner.req('GET', `/v1/providers/${pid}/models?kind=video`)).body;
      noKeyIn(b);
      expect(b.models.map((m: any) => [m.ref, m.kind, m.ready, m.price?.costUsd])).toEqual([
        ['happy-horse-1-image-to-video', 'video', true, 0.36], ['kling-v2.1-pro-i2v', 'video', true, 0.08], ['seedance-2-t2v', 'video', true, 0.15]]);
      expect(b.models[2].inputs).toMatchObject({ duration: { allowed: [5, 10, 15] }, resolutions: ['480p', '720p'] });

      // Refs: Muapi's single-segment names; owner/name and path tricks are refused before any call.
      for (const ref of ['../account/balance', 'acme/motion-1', 'seedance-2-t2v/../../x']) expect((await owner.req('POST', `/v1/providers/${pid}/models`, { ref })).status).toBe(400);
      expect((await owner.req('POST', `/v1/providers/${pid}/models`, { ref: 'no-such-model' })).status).toBe(404);

      const vm = await owner.req('POST', `/v1/providers/${pid}/models`, { ref: 'seedance-2-t2v', displayName: 'Studio Motion' });
      expect(vm.status).toBe(201);
      expect(vm.body).toMatchObject({ providerKind: 'muapi', ref: 'seedance-2-t2v', providerName: 'seedance-2-t2v', displayName: 'Studio Motion', kind: 'video', status: 'ready',
        enabled: false, price: { basis: 'per_second', costUsd: 0.15, source: 'provider' } });
      // Muapi's own price is enough to switch it on; a rename and a markup come with it.
      const on = await owner.req('PATCH', `/v1/providers/models/${vm.body.id}`, { enabled: true, displayName: 'House Motion', priceScale: 2 });
      expect(on.body).toMatchObject({ enabled: true, displayName: 'House Motion', memberPrice: { basis: 'per_second', usd: 0.3 } });
      // A model with no quote needs the owner's price (Price corrections).
      const nb = (await owner.req('POST', `/v1/providers/${pid}/models`, { ref: 'nano-banana' })).body;
      expect(nb).toMatchObject({ kind: 'image', price: null });
      expect((await owner.req('PATCH', `/v1/providers/models/${nb.id}`, { enabled: true })).body.code).toBe('price_required');
      expect((await owner.req('PATCH', `/v1/providers/models/${nb.id}`, { enabled: true, price: { basis: 'per_run', costUsd: 0.04 } })).body).toMatchObject({ enabled: true, price: { source: 'owner' } });

      const e = (await owner.req('POST', '/v1/suite/shots/estimate', { prompt: 'A dog runs on the beach', duration: 10, quality: 'draft', aspectRatio: '9:16', engineModel: vm.body.id })).body;
      expect(e.estimate).toBeCloseTo(3, 6); // 10 s × $0.15 × 2
      expect(e.engine).toMatchObject({ model: vm.body.id, provider: 'byo' });
      expect(calls.filter(c => !publicCall(c)).every(c => c.url === '/mu/api/v1/account/balance')).toBe(true); // nothing ran
    } finally { await a.close(); }
  });

  it('members (4c) see every Muapi model the owner hasn\'t hidden, by display name with the provider\'s name while shown; never refs, keys or cost', async () => {
    const a = await makeApp(env({ SUITE_MODE: 'mock', SUITE_MOCK_CHARGE: 'true' }));
    const { owner, members: [member] } = await people(a, 1, { topUp: 100 });
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: member!.id, tokens: 2000 });
    try {
      const p = (await owner.req('POST', '/v1/providers', { kind: 'muapi', apiKey: MU_GOOD })).body;
      const vm = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'kling-v2.1-pro-i2v', displayName: 'House Motion' })).body;
      await owner.req('PATCH', `/v1/providers/models/${vm.id}`, { enabled: true });
      const im = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'bytedance-seedream-v4-edit', displayName: 'House Still' })).body;
      await owner.req('PATCH', `/v1/providers/models/${im.id}`, { enabled: true });

      expect((await owner.req('GET', '/v1/suite/catalog')).body.custom.map((c: any) => [c.name, c.provider])).toEqual([['House Motion', 'muapi'], ['House Still', 'muapi']]);
      expect((await member!.req('GET', '/v1/providers')).status).toBe(403);
      expect((await member!.req('GET', `/v1/providers/${p.id}/models`)).status).toBe(403);
      // A newly added model is available to members at once, with the provider's name (the studio shows it by default).
      let mc = (await member!.req('GET', '/v1/suite/catalog')).body;
      expect(mc.custom.map((c: any) => [c.name, c.providerName])).toEqual([['House Motion', 'Muapi'], ['House Still', 'Muapi']]);
      expect(mc.custom[0]).toMatchObject({ minSeconds: 5, maxSeconds: 10, inputs: { start: true, end: true } });
      expect(mc.engines.filter((e: any) => e.custom).map((e: any) => [e.name, e.providerName])).toEqual([['House Motion', 'Muapi'], ['House Still', 'Muapi']]);
      let engines = (await member!.req('GET', '/v1/engines')).body;
      expect(engines.engines.filter((e: any) => e.custom).map((e: any) => e.name)).toEqual(['House Motion', 'House Still']);
      for (const x of [mc.custom, mc.engines.filter((e: any) => e.custom), engines.engines.filter((e: any) => e.custom)]) expect(JSON.stringify(x)).not.toMatch(MODEL_REFS);
      for (const x of [mc, engines]) expect(JSON.stringify(x)).not.toMatch(OWNER_ONLY_WORDS);
      // The owner hides one (the old "available to members" switch from today's apps is the same switch).
      expect((await owner.req('PATCH', `/v1/providers/models/${vm.id}`, { members: false })).body.members).toBe(false);
      mc = (await member!.req('GET', '/v1/suite/catalog')).body;
      expect(mc.custom.map((c: any) => c.name)).toEqual(['House Still']);
      expect(mc.engines.some((e: any) => e.model === vm.id)).toBe(false);
      expect((await member!.req('POST', '/v1/suite/shots/estimate', { prompt: 'x', duration: 5, quality: 'draft', engineModel: vm.id })).status).toBeGreaterThanOrEqual(400);
      await owner.req('PATCH', '/v1/engines/members', { hidden: { [vm.id]: false } });
      expect((await owner.req('GET', '/v1/providers/models')).body.models.find((m: any) => m.id === vm.id).members).toBe(true);
      // Provider names off: members see display names only.
      await owner.req('PATCH', '/v1/engines/members', { showProviderNames: false });
      mc = (await member!.req('GET', '/v1/suite/catalog')).body;
      expect(mc.custom.map((c: any) => c.name)).toEqual(['House Motion', 'House Still']);
      expect(JSON.stringify(mc.custom)).not.toMatch(PROVIDER_WORDS);
      engines = (await member!.req('GET', '/v1/engines')).body;
      expect(JSON.stringify(engines.engines.filter((e: any) => e.custom))).not.toMatch(PROVIDER_WORDS);
      expect(JSON.stringify(engines)).not.toMatch(/"provider(Name)?"/);
      await owner.req('PATCH', '/v1/engines/members', { showProviderNames: true });
      // A custom video model is in the video pickers (the list loads the studio's custom models itself).
      expect((await owner.req('GET', '/v1/engines?purpose=shot')).body.engines.find((e: any) => e.model === vm.id)).toMatchObject({ name: 'House Motion', custom: true });
      // A custom image model serves every image purpose, and can be the studio's default for each.
      for (const purpose of ['photo', 'outfit', 'character', 'plate']) {
        expect((await owner.req('GET', `/v1/engines?purpose=${purpose}`)).body.engines.map((e: any) => e.model), purpose).toContain(im.id);
      }
      expect((await owner.req('PATCH', '/v1/engines/defaults', { outfit: im.id })).status).toBeLessThan(300);
      expect((await owner.req('GET', '/v1/engines?purpose=outfit')).body.default).toBe(im.id);
      // The start frame is required: a member's text-only shot is refused before anything is spent.
      const shot = { prompt: 'She walks along the pier at dusk.', duration: 5, quality: 'draft', aspectRatio: '9:16', engineModel: vm.id };
      const est = await member!.req('POST', '/v1/suite/shots/estimate', shot);
      expect(JSON.stringify(est.body)).not.toMatch(PROVIDER_WORDS);
      expect(est.body.engine).toBeUndefined();
    } finally { await a.close(); }
  });

  it.skipIf(!hasFfmpeg)('live: a shot runs on the owner\'s Muapi key and settles at Muapi\'s price; a refusal and no credit fail member-safe', async () => {
    calls.length = 0;
    const a = await makeApp(env({ SUITE_MODE: 'live' }));
    const { owner, members: [member] } = await people(a, 1, { topUp: 100 });
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: member!.id, tokens: 2000 });
    try {
      const p = (await owner.req('POST', '/v1/providers', { kind: 'muapi', apiKey: MU_GOOD })).body;
      const vm = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'seedance-2-t2v' })).body;
      await owner.req('PATCH', `/v1/providers/models/${vm.id}`, { enabled: true, members: true, displayName: 'House Motion' });
      const run = async (who: typeof owner, prompt: string) => {
        const r = (await who.req('POST', '/v1/suite/shots', { prompt, duration: 6, quality: 'standard', aspectRatio: '9:16', engineModel: vm.id })).body;
        expect(r.id).toBeTruthy();
        const j = await until(async () => { const x = (await who.req('GET', `/v1/suite/shots/${r.id}`)).body.job; return x?.state === 'done' || x?.state === 'failed' ? x : null; }, 20_000);
        return { id: r.id as string, job: j };
      };

      const ok = await run(owner, 'A lighthouse at night, waves below.');
      expect(ok.job.state).toBe('done');
      const post = calls.find(c => c.method === 'POST' && c.url === '/mu/api/v1/seedance-v2.0-t2v')!;
      expect(post.key).toBe(MU_GOOD);
      expect(post.auth).toBeUndefined();
      expect(post.body).toMatchObject({ duration: 5, aspect_ratio: '9:16' });
      expect(post.body.prompt).toContain('lighthouse');
      expect(Object.keys(post.body).every(k => detail('seedance-2-t2v').input_schema.schemas.input_data.properties[k])).toBe(true);
      expect(calls.some(c => /^\/mu\/api\/v1\/predictions\/req_\d+\/result$/.test(c.url) && c.key === MU_GOOD)).toBe(true);
      const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, ok.id))).find(x => x.kind === 'settle');
      expect(Math.abs(settle!.amountUsd)).toBeCloseTo(0.75, 6); // 5 s × $0.15

      const refused = await run(member!, 'REFUSE: she walks along the pier.');
      expect(refused.job).toMatchObject({ state: 'failed', errorCode: 'provider_refused' });
      expect(JSON.stringify(refused.job)).not.toMatch(PROVIDER_WORDS);
      const broke = await run(member!, 'BROKE: she walks along the pier.');
      expect(broke.job).toMatchObject({ state: 'failed', errorCode: 'provider_out_of_credit' });
      expect(JSON.stringify(broke.job)).not.toMatch(PROVIDER_WORDS);
      for (const j of [refused, broke]) {
        const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id));
        expect(rows.find(x => x.kind === 'settle' && Math.abs(x.amountUsd) > 0)).toBeUndefined(); // nothing charged
      }
      // The key was never refused: the provider stays "ok".
      expect((await owner.req('GET', '/v1/providers')).body.providers[0].status).toBe('ok');

      // The live image engine: one prediction per photo, references as Muapi's list.
      const im = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'bytedance-seedream-v4-edit' })).body;
      await owner.req('PATCH', `/v1/providers/models/${im.id}`, { enabled: true });
      calls.length = 0;
      const out = await a.ctx.suite.byo.image.generate({ prompt: 'A portrait', referenceImages: ['https://x/a.jpg'], width: 768, height: 1024, count: 2, seed: 7 }, { provider: 'byo', model: im.id });
      expect(out.images).toHaveLength(2);
      expect(out.costUsd).toBeCloseTo(0.08, 6);
      const posts = calls.filter(c => c.method === 'POST' && c.url === '/mu/api/v1/bytedance-seedream-edit-v4');
      // Owner 2026-11-09: sent at the model's largest size when it has a size choice.
      const base = { prompt: 'A portrait', images_list: ['https://x/a.jpg'], aspect_ratio: '3:4' };
      expect(posts.map(c => c.body)).toEqual([expect.objectContaining(base), expect.objectContaining(base)]);
      const sizes = posts.map(c => (c.body as Record<string, unknown>).resolution ?? (c.body as Record<string, unknown>).image_size ?? null);
      expect(new Set(sizes).size).toBe(1);
      await expect(a.ctx.suite.byo.image.generate({ prompt: 'REFUSE', referenceImages: ['https://x/a.jpg'], width: 768, height: 1024, count: 1 }, { provider: 'byo', model: im.id }))
        .rejects.toMatchObject({ code: 'provider_refused' });
    } finally { await a.close(); }
  });
});
