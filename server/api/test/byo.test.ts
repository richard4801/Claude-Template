// Bring your own provider (WS5): owner-added provider keys (validated, encrypted at rest, never returned), the model
// catalog read from the provider's schema, enabling/renaming/pricing, and custom models in the Suite (estimate → hold →
// settle) for the owner and, when made available, members. Every provider response comes from the recorded fixtures in
// test/fixtures/byo, served by a FAKE provider on localhost. No live provider calls, no spend.
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
import { keyFromSecret, last4, openKey, sealKey } from '../src/byo/crypto.js';
import { imageInput } from '../src/byo/service.js';
import { byoInput } from '../src/suite/inputs.js';
import { modelById } from '../src/suite/registry.js';
import { makeApp, people, until, type Client } from './helpers.js';

const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures/byo');
const fixture = (n: string) => JSON.parse(fs.readFileSync(path.join(FIX, n), 'utf8'));
const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const SECRET = crypto.randomBytes(32).toString('hex');
const R8_GOOD = 'r8_good_token_abcd', FAL_GOOD = 'fal-key-id:fal-secret-wxyz';
/** Words members must never see for a custom model. */
const PROVIDER_WORDS = /\b(replicate|fal|acme|motion-1|still-1|vidgen)\b/i;

describe('keys at rest', () => {
  it('AES-256-GCM round trip, bound to the row, fails closed without a valid secret', () => {
    const k = keyFromSecret(SECRET)!;
    const sealed = sealKey(k, 'r8_secret_value_1234', 'prv_1');
    expect(sealed.startsWith('v1:')).toBe(true);
    expect(sealed).not.toContain('r8_secret');
    expect(openKey(k, sealed, 'prv_1')).toBe('r8_secret_value_1234');
    expect(() => openKey(k, sealed, 'prv_2')).toThrow(/can't be read/); // copied onto another row
    expect(() => openKey(keyFromSecret(crypto.randomBytes(32).toString('hex')), sealed, 'prv_1')).toThrow();
    expect(keyFromSecret(undefined)).toBeNull();
    expect(keyFromSecret('too-short')).toBeNull();
    expect(keyFromSecret(crypto.randomBytes(32).toString('base64'))?.length).toBe(32);
    expect(() => sealKey(null, 'x', 'prv_1')).toThrow(/PROVIDER_KEYS_SECRET/);
    expect(last4('r8_secret_value_1234')).toBe('…1234');
  });
});

describe('reading a model schema', () => {
  it('Replicate video: roles, $ref enums, kind from inputs; nothing missing', () => {
    const m = fixture('replicate-model-video.json');
    const doc = m.latest_version.openapi_schema;
    const a = analyse(doc, doc.components.schemas.Input, { text: m.description, output: doc.components.schemas.Output });
    expect(a.kind).toBe('video');
    expect(a.map).toMatchObject({ prompt: 'prompt', negativePrompt: 'negative_prompt', startImage: 'start_image', duration: 'duration', aspectRatio: 'aspect_ratio', seed: 'seed' });
    expect(a.inputs).toMatchObject({ prompt: true, startImage: true, endImage: false, referenceImages: 0, duration: { min: 5, max: 10, allowed: [5, 10] }, aspectRatios: ['16:9', '9:16', '1:1'], seed: true });
    expect(a.missing).toEqual([]);
    expect(a.startRequired).toBe(false);
  });
  it('Replicate image: the image list is references; kind image', () => {
    const m = fixture('replicate-model-image.json');
    const doc = m.latest_version.openapi_schema;
    const a = analyse(doc, doc.components.schemas.Input, { text: m.description, output: doc.components.schemas.Output });
    expect(a.kind).toBe('image');
    expect(a.map.referenceImages).toBe('image_input');
    expect(a.inputs.referenceImages).toBe(4);
    expect(a.shapes.referenceImages).toBe('array');
  });
  it('an unknown required field makes it "needs setup"', () => {
    const doc = fixture('replicate-model-odd.json').latest_version.openapi_schema;
    const a = analyse(doc, doc.components.schemas.Input, { text: 'Stylised video clips' });
    expect(a.kind).toBe('video');
    expect(a.missing).toEqual(['style_code']);
    expect(a.inputs.duration).toEqual({ min: 2, max: 8 });
  });
  it('fal: kind from the category, string durations, resolutions and the sound switch', () => {
    const m = fixture('fal-models.json').models[0];
    const doc = m.openapi;
    const a = analyse(doc, doc.paths['/acme-ai/vidgen/v2/text-to-video'].post.requestBody.content['application/json'].schema, { category: m.metadata.category });
    expect(a.kind).toBe('video');
    expect(a.shapes.duration).toBe('string');
    expect(a.inputs.resolutions).toEqual(['480p', '720p']);
    expect(a.map.audio).toBe('generate_audio');
  });
  it('fills inputs only from the mapped fields (plus the owner\'s fixed values)', () => {
    const m = fixture('fal-models.json').models[0];
    const doc = m.openapi;
    const analysis = analyse(doc, doc.components.schemas.VidgenInput, { category: 'text-to-video' });
    const spec = { byo: { analysis, fixed: { style: 'x' } } } as any;
    expect(byoInput(spec, { prompt: 'A dog runs', negative: undefined, seconds: 7, aspect: '9:16', resolution: '720p', seed: undefined, audio: false }, { middle: [], refs: [], videos: [] }))
      .toEqual({ style: 'x', prompt: 'A dog runs', duration: '5', aspect_ratio: '9:16', resolution: '720p', generate_audio: false });
    const img = analyse(fixture('fal-models.json').models[1].openapi, fixture('fal-models.json').models[1].openapi.components.schemas.PixInput, { category: 'image-to-image' });
    expect(imageInput(img, {}, { prompt: 'p', referenceImages: ['https://x/1.jpg', 'https://x/2.jpg'], width: 768, height: 1024, seed: 3 }, 1))
      .toEqual({ prompt: 'p', image_urls: ['https://x/1.jpg', 'https://x/2.jpg'], seed: 4 });
  });
});

describe('Bring your own provider · API against a FAKE Replicate and fal (recorded fixtures, no money)', () => {
  let server: http.Server, dir: string, base = '';
  const calls: { method: string; url: string; auth?: string; body?: any }[] = [];
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-byo-fake-'));
    const mp4 = path.join(dir, 'out.mp4');
    if (hasFfmpeg) execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=288x512:rate=24', '-t', '5', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', mp4]);
    server = http.createServer((q, res) => {
      let raw = '';
      q.on('data', c => (raw += c));
      q.on('end', () => {
        const url = q.url ?? '', auth = q.headers.authorization;
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (url === '/out.mp4') { res.writeHead(200, { 'content-type': 'video/mp4' }); fs.createReadStream(mp4).pipe(res); return; }
        calls.push({ method: q.method!, url, auth, body: raw ? JSON.parse(raw) : undefined });
        if (url.startsWith('/r/v1/')) { // Replicate
          if (auth !== `Bearer ${R8_GOOD}`) return json(401, { detail: 'Invalid token.' });
          const sub = url.slice(5);
          if (sub === '/account') return json(200, { type: 'user', username: 'owner', name: 'Owner' });
          if (sub.startsWith('/search?')) return json(200, fixture('replicate-search.json'));
          if (sub === '/models/acme/motion-1') return json(200, fixture('replicate-model-video.json'));
          if (sub === '/models/acme/still-1') return json(200, fixture('replicate-model-image.json'));
          if (sub === '/models/acme/odd-1') return json(200, fixture('replicate-model-odd.json'));
          if (sub.startsWith('/collections/')) return json(200, { name: 'x', slug: 'x', models: [fixture('replicate-model-video.json')] });
          if (sub === '/predictions' && q.method === 'POST') return json(201, { id: 'pv1', status: 'starting' });
          if (sub === '/predictions/pv1') return json(200, { id: 'pv1', status: 'succeeded', output: `${base}/out.mp4` });
          return json(404, { detail: 'Not found.' });
        }
        if (url.startsWith('/fal/v1/')) { // fal Platform API
          const sub = url.slice(7);
          if (sub.startsWith('/models/pricing')) return auth === `Key ${FAL_GOOD}` ? json(200, fixture('fal-pricing.json')) : json(401, { error: { type: 'authorization_error' } });
          if (sub.startsWith('/models?')) {
            const qs = new URLSearchParams(sub.split('?')[1]);
            const all = fixture('fal-models.json');
            const id = qs.get('endpoint_id');
            return json(200, id ? { models: all.models.filter((m: any) => m.endpoint_id === id), next_cursor: null, has_more: false } : all);
          }
          return json(404, {});
        }
        json(404, {});
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(() => { server?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  const env = (extra: Record<string, string> = {}) => ({ PROVIDER_KEYS_SECRET: SECRET, REPLICATE_API_URL: `${base}/r/v1`, FAL_PLATFORM_URL: `${base}/fal/v1`,
    FAL_QUEUE_URL: `${base}/falq`, SUITE_POLL_MS: '10', REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated', ...extra });
  const noKeyIn = (o: unknown) => { const s = JSON.stringify(o); expect(s).not.toContain(R8_GOOD); expect(s).not.toContain(FAL_GOOD); expect(s).not.toContain('fal-secret'); };

  it('owner only; fails closed without PROVIDER_KEYS_SECRET; a bad key is refused and not stored', async () => {
    const a = await makeApp(env({ PROVIDER_KEYS_SECRET: '' }));
    const { owner, members: [member] } = await people(a, 1);
    try {
      expect((await member!.req('GET', '/v1/providers')).status).toBe(403);
      expect((await member!.req('POST', '/v1/providers', { kind: 'replicate', apiKey: R8_GOOD })).status).toBe(403);
      const r = await owner.req('POST', '/v1/providers', { kind: 'replicate', apiKey: R8_GOOD });
      expect(r.status).toBe(503);
      expect(r.body.code).toBe('provider_keys_unavailable');
      expect((await owner.req('GET', '/v1/providers/kinds')).body.keysReady).toBe(false);
    } finally { await a.close(); }
    const b = await makeApp(env());
    const p2 = await people(b, 0);
    try {
      const r = await p2.owner.req('POST', '/v1/providers', { kind: 'replicate', apiKey: 'r8_wrong_token_0000' });
      expect(r.status).toBe(400);
      expect(r.body.code).toBe('invalid_key');
      expect((await b.ctx.db.select().from(byoProviders))).toHaveLength(0);
    } finally { await b.close(); }
  });

  it('adds a key (validated, encrypted, last 4 only), browses, adds and sets up models, and deletes', async () => {
    calls.length = 0;
    const a = await makeApp(env({ SUITE_MODE: 'mock' }));
    const { owner } = await people(a, 0);
    try {
      const add = await owner.req('POST', '/v1/providers', { kind: 'replicate', apiKey: R8_GOOD, label: 'My Replicate' });
      expect(add.status).toBe(201);
      expect(add.body).toMatchObject({ kind: 'replicate', label: 'My Replicate', keyLast4: '…abcd', status: 'ok', models: { added: 0, enabled: 0 } });
      noKeyIn(add.body);
      expect(calls.find(c => c.url === '/r/v1/account')).toBeTruthy();
      const [row] = await a.ctx.db.select().from(byoProviders);
      expect(row!.keyEnc).not.toContain(R8_GOOD);
      expect(openKey(keyFromSecret(SECRET), row!.keyEnc, row!.id)).toBe(R8_GOOD);
      const list = (await owner.req('GET', '/v1/providers')).body;
      noKeyIn(list);
      expect(list.providers).toHaveLength(1);
      const pid = add.body.id;

      // Browse: search results without a schema are read model by model; the page is cached.
      const b1 = (await owner.req('GET', `/v1/providers/${pid}/models?q=motion`)).body;
      expect(b1.models.map((m: any) => [m.ref, m.kind, m.ready])).toEqual([['acme/motion-1', 'video', true], ['acme/still-1', 'image', true]]);
      expect(b1.models[0]).toMatchObject({ price: null, added: null, inputs: { startImage: true, duration: { allowed: [5, 10] } } });
      const n = calls.length;
      await owner.req('GET', `/v1/providers/${pid}/models?q=motion`);
      expect(calls.length).toBe(n);
      expect((await owner.req('GET', `/v1/providers/${pid}/models?kind=image&q=motion`)).body.models.map((m: any) => m.ref)).toEqual(['acme/still-1']);

      // Add: switched off; Replicate has no prices, so it needs one before it can be switched on.
      const vm = await owner.req('POST', `/v1/providers/${pid}/models`, { ref: 'acme/motion-1', displayName: 'Studio Motion' });
      expect(vm.status).toBe(201);
      expect(vm.body).toMatchObject({ displayName: 'Studio Motion', providerName: 'motion-1', kind: 'video', enabled: false, members: false, status: 'ready', price: null });
      expect(vm.body.id).toMatch(/^c_/);
      const off = await owner.req('PATCH', `/v1/providers/models/${vm.body.id}`, { enabled: true });
      expect(off.status).toBe(400);
      expect(off.body.code).toBe('price_required');
      const on = await owner.req('PATCH', `/v1/providers/models/${vm.body.id}`, { enabled: true, price: { basis: 'per_run', costUsd: 0.4 }, priceScale: 1.5, displayName: 'House Motion' });
      expect(on.status).toBe(200);
      expect(on.body).toMatchObject({ enabled: true, displayName: 'House Motion', price: { basis: 'per_run', costUsd: 0.4, source: 'owner' }, memberPrice: { basis: 'per_run', usd: 0.6 } });

      // Needs setup: an unknown required field must get a fixed value first.
      const odd = (await owner.req('POST', `/v1/providers/${pid}/models`, { ref: 'acme/odd-1' })).body;
      expect(odd).toMatchObject({ status: 'needs_setup', missing: ['style_code'] });
      const blocked = await owner.req('PATCH', `/v1/providers/models/${odd.id}`, { enabled: true, price: { basis: 'per_run', costUsd: 0.2 } });
      expect(blocked.status).toBe(409);
      expect(blocked.body.code).toBe('needs_setup');
      expect((await owner.req('PATCH', `/v1/providers/models/${odd.id}`, { fixedInputs: { prompt: 'x' } })).status).toBe(400); // MUSE fills that one
      expect((await owner.req('PATCH', `/v1/providers/models/${odd.id}`, { fixedInputs: { nope: 'x' } })).status).toBe(400);
      const fixed = await owner.req('PATCH', `/v1/providers/models/${odd.id}`, { fixedInputs: { style_code: 'noir' }, price: { basis: 'per_run', costUsd: 0.2 }, enabled: true });
      expect(fixed.body).toMatchObject({ status: 'ready', enabled: true, fixedInputs: { style_code: 'noir' } });

      const all = (await owner.req('GET', '/v1/providers/models')).body.models;
      expect(all.map((m: any) => m.displayName)).toEqual(['House Motion', 'odd-1']);
      noKeyIn(all);
      expect((await owner.req('GET', '/v1/providers')).body.providers[0].models).toEqual({ added: 2, enabled: 2 });

      // In the Suite registry while enabled; gone after the provider is deleted.
      expect(modelById(vm.body.id)?.provider).toBe('byo');
      expect((await owner.req('DELETE', `/v1/providers/${pid}`)).status).toBe(204);
      expect(modelById(vm.body.id)).toBeUndefined();
      expect((await owner.req('GET', '/v1/providers/models')).body.models).toEqual([]);
    } finally { await a.close(); }
  });

  it('fal: the key check reads prices; provider prices come with the catalog; paging passes the cursor', async () => {
    calls.length = 0;
    const a = await makeApp(env({ SUITE_MODE: 'mock' }));
    const { owner } = await people(a, 0);
    try {
      expect((await owner.req('POST', '/v1/providers', { kind: 'fal', apiKey: 'wrong-key-000' })).body.code).toBe('invalid_key');
      calls.length = 0;
      const p = (await owner.req('POST', '/v1/providers', { kind: 'fal', apiKey: FAL_GOOD })).body;
      expect(p.keyLast4).toBe('…wxyz');
      const b = (await owner.req('GET', `/v1/providers/${p.id}/models?limit=2`)).body;
      expect(b.nextCursor).toBe('Mg==');
      expect(b.models.map((m: any) => [m.ref, m.kind, m.price])).toEqual([
        ['acme-ai/vidgen/v2/text-to-video', 'video', { basis: 'per_second', costUsd: 0.07, source: 'provider' }],
        ['acme-ai/pix/edit', 'image', { basis: 'per_run', costUsd: 0.04, source: 'provider' }],
      ]);
      expect(calls.every(c => !c.url.includes('/models/pricing') || c.auth === `Key ${FAL_GOOD}`)).toBe(true);
      const v = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'acme-ai/vidgen/v2/text-to-video' })).body;
      const on = (await owner.req('PATCH', `/v1/providers/models/${v.id}`, { enabled: true })).body; // the provider's price is enough
      expect(on).toMatchObject({ enabled: true, memberPrice: { basis: 'per_second', usd: 0.07 } });
      // A per-second model prices by length: 10 s × $0.07 (the only lengths are 5 and 10).
      const e = (await owner.req('POST', '/v1/suite/shots/estimate', { prompt: 'A dog runs on the beach', duration: 10, quality: 'draft', aspectRatio: '9:16', engineModel: v.id })).body;
      expect(e.estimate).toBeCloseTo(0.7, 6);
      expect(e.engine).toMatchObject({ model: v.id, provider: 'byo' });
    } finally { await a.close(); }
  });

  it('Suite: members see only models made available, by display name; estimate and run go through hold → settle (test renderer, no calls)', async () => {
    calls.length = 0;
    const a = await makeApp(env({ SUITE_MODE: 'mock', SUITE_MOCK_CHARGE: 'true' }));
    const { owner, members: [member] } = await people(a, 1, { topUp: 100 });
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: member!.id, tokens: 2000 });
    try {
      const p = (await owner.req('POST', '/v1/providers', { kind: 'replicate', apiKey: R8_GOOD })).body;
      const vm = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'acme/motion-1', displayName: 'House Motion' })).body;
      await owner.req('PATCH', `/v1/providers/models/${vm.id}`, { enabled: true, price: { basis: 'per_run', costUsd: 0.4 }, priceScale: 1.5 });
      const im = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'acme/still-1', displayName: 'House Still' })).body;
      await owner.req('PATCH', `/v1/providers/models/${im.id}`, { enabled: true, price: { basis: 'per_run', costUsd: 0.05 }, members: true });

      const oc = (await owner.req('GET', '/v1/suite/catalog')).body.custom;
      expect(oc.map((c: any) => [c.name, c.kind, c.price.usd, c.members])).toEqual([['House Motion', 'video', 0.6, false], ['House Still', 'image', 0.05, true]]);
      let mc = (await member!.req('GET', '/v1/suite/catalog')).body.custom;
      expect(mc.map((c: any) => c.name)).toEqual(['House Still']);
      const shot = { prompt: 'She walks along the pier at dusk.', duration: 5, quality: 'draft', aspectRatio: '9:16', engineModel: vm.id };
      const denied = await member!.req('POST', '/v1/suite/shots/estimate', shot);
      expect(denied.status).toBe(400);
      expect(denied.body.code).toBe('engine_unavailable');
      expect((await member!.req('POST', '/v1/suite/shots/estimate', { ...shot, engineModel: 'h3' })).status).toBe(403); // built-ins stay owner-only

      await owner.req('PATCH', `/v1/providers/models/${vm.id}`, { members: true });
      mc = (await member!.req('GET', '/v1/suite/catalog')).body.custom;
      expect(mc.map((c: any) => c.name)).toEqual(['House Motion', 'House Still']);
      expect(Object.keys(mc[0]).sort()).toEqual(['aspectRatios', 'id', 'inputs', 'kind', 'maxSeconds', 'minSeconds', 'name', 'price']);
      expect(JSON.stringify(mc)).not.toMatch(PROVIDER_WORDS);
      expect(mc[0]).toMatchObject({ minSeconds: 5, maxSeconds: 10, aspectRatios: ['16:9', '9:16', '1:1'], inputs: { start: true, images: 0 } });

      const est = (await member!.req('POST', '/v1/suite/shots/estimate', shot)).body;
      expect(est.estimate).toBeCloseTo(0.6, 6);
      expect(est.ok).toBe(true);
      expect(JSON.stringify(est)).not.toMatch(PROVIDER_WORDS);
      expect(est.engine).toBeUndefined();
      // Custom models make plain shots only.
      expect((await member!.req('POST', '/v1/suite/shots/estimate', { ...shot, mode: 'extend' })).status).toBe(400);

      if (hasFfmpeg) {
        const r = (await member!.req('POST', '/v1/suite/shots', shot)).body;
        expect(r.id).toBeTruthy();
        const j = await until(async () => { const x = (await member!.req('GET', `/v1/suite/shots/${r.id}`)).body.job; return x?.state === 'done' || x?.state === 'failed' ? x : null; }, 20_000);
        expect(j.state).toBe('done');
        const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, r.id));
        expect(rows.find(x => x.kind === 'hold')).toBeTruthy();
        expect(Math.abs(rows.find(x => x.kind === 'settle')!.amountUsd)).toBeCloseTo(0.6, 6);
      }
      // Photos on a custom image model: priced per photo (cost × markup), the studio's image engine replaced for the run.
      const { demoModel } = await import('./helpers.js');
      const dm = await demoModel(owner);
      const pe = (await member!.req('POST', '/v1/suite/photos/estimate', { modelId: dm.id, prompt: 'On the pier', count: 2, engineModel: im.id })).body;
      expect(pe.perPhoto).toBeCloseTo(0.05, 6);
      expect(pe.estimate).toBeCloseTo(0.1, 6);
      const ph = await member!.req('POST', '/v1/suite/photos', { modelId: dm.id, prompt: 'On the pier', count: 2, engineModel: im.id });
      expect(ph.status).toBe(200);
      expect((await member!.req('POST', '/v1/suite/photos/estimate', { modelId: dm.id, prompt: 'x', count: 1, engineModel: vm.id })).status).toBe(400); // not an image model
      // The test renderer called no provider.
      expect(calls.filter(c => c.url.includes('/predictions'))).toHaveLength(0);
    } finally { await a.close(); }
  });

  it.skipIf(!hasFfmpeg)('live: the shot runs on the owner\'s own key with the mapped inputs and settles at the custom price', async () => {
    calls.length = 0;
    const a = await makeApp(env({ SUITE_MODE: 'live' }));
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const p = (await owner.req('POST', '/v1/providers', { kind: 'replicate', apiKey: R8_GOOD })).body;
      const vm = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'acme/motion-1' })).body;
      await owner.req('PATCH', `/v1/providers/models/${vm.id}`, { enabled: true, price: { basis: 'per_run', costUsd: 0.4 }, priceScale: 1.5 });
      const r = (await owner.req('POST', '/v1/suite/shots', { prompt: 'A lighthouse at night, waves below.', duration: 6, quality: 'standard', aspectRatio: '9:16', engineModel: vm.id })).body;
      expect(r.id).toBeTruthy();
      const j = await until(async () => { const x = (await owner.req('GET', `/v1/suite/shots/${r.id}`)).body.job; return x?.state === 'done' || x?.state === 'failed' ? x : null; }, 20_000);
      expect(j.state).toBe('done');
      const post = calls.find(c => c.method === 'POST' && c.url === '/r/v1/predictions')!;
      expect(post.auth).toBe(`Bearer ${R8_GOOD}`);
      expect(post.body.version).toBe(fixture('replicate-model-video.json').latest_version.id);
      expect(post.body.input).toMatchObject({ duration: 5, aspect_ratio: '9:16' });
      expect(post.body.input.prompt).toContain('lighthouse');
      expect(Object.keys(post.body.input).every(k => fixture('replicate-model-video.json').latest_version.openapi_schema.components.schemas.Input.properties[k])).toBe(true);
      const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, r.id))).find(x => x.kind === 'settle');
      expect(Math.abs(settle!.amountUsd)).toBeCloseTo(0.6, 6);

      // The live image engine: one prediction per photo on the owner's key, references in the model's own field.
      const im = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'acme/still-1' })).body;
      await owner.req('PATCH', `/v1/providers/models/${im.id}`, { enabled: true, price: { basis: 'per_run', costUsd: 0.05 }, priceScale: 2 });
      calls.length = 0;
      const out = await a.ctx.suite.byo.image.generate({ prompt: 'A portrait', referenceImages: ['https://x/a.jpg'], width: 768, height: 1024, count: 2, seed: 7 },
        { provider: 'byo', model: im.id });
      expect(out.images).toHaveLength(2);
      expect(out.costUsd).toBeCloseTo(0.2, 6);
      const posts = calls.filter(c => c.method === 'POST' && c.url === '/r/v1/predictions');
      expect(posts.map(c => c.body.input)).toEqual([
        { prompt: 'A portrait', image_input: ['https://x/a.jpg'], aspect_ratio: '3:4', seed: 7 },
        { prompt: 'A portrait', image_input: ['https://x/a.jpg'], aspect_ratio: '3:4', seed: 8 },
      ]);
      expect(posts.every(c => c.auth === `Bearer ${R8_GOOD}`)).toBe(true);
    } finally { await a.close(); }
  });
});
