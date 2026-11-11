// Bring your own provider · Higgsfield. The catalog is Higgsfield's documented models (assets/higgsfield/catalog.json, built
// from docs.higgsfield.ai by scripts/higgsfield-catalog.py: Higgsfield has no model-list API). The adapter runs against a
// FAKE Higgsfield on localhost that answers in the shapes its docs give (POST /estimate/{id} → {usd}, POST /{id} →
// {request_id, status_url, cancel_url}, GET /requests/{id}/status, POST /requests/{id}/cancel, 401/403 bodies).
// No live Higgsfield call, no real key, no spend.
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
import { HiggsfieldAdapter, higgsfieldCatalog, higgsfieldError, higgsfieldSample } from '../src/byo/adapters.js';
import { setupOf } from '../src/byo/service.js';
import { modelById } from '../src/suite/registry.js';
import { makeApp, people, until } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const SECRET = crypto.randomBytes(32).toString('hex');
const HF_GOOD = 'hfid-good-0000:hfsecret-good-wxyz';
const HF_SERVER = 'hfid-server-1111:hfsecret-server-abcd';
const OK_KEYS = new Set([HF_GOOD, HF_SERVER]);
/** The fake's price list (USD per request, like Higgsfield's estimate). */
const RATES: Record<string, (b: any) => number | null> = {
  'kling-video/v2.6/pro/text-to-video': b => Number(b.duration ?? 5) * 0.07,
  'kling-video/v2.6/pro/image-to-video': b => (b.image_url ? Number(b.duration ?? 5) * 0.07 : null), // needs its start frame
  'bytedance/seedance-2.5/text-to-video': b => Number(b.duration ?? 5) * ({ '480p': 0.1, '720p': 0.2, '1080p': 0.45 } as Record<string, number>)[b.resolution ?? '720p']!,
  'minimax/hailuo-2.3/standard/text-to-video': () => 0.28, // the same price for 6 s and 10 s: per run
  'higgsfield-ai/soul/v2/standard': () => 0.094,
  'alibaba/qwen-image-3/edit': b => (Array.isArray(b.image_urls) && b.image_urls.length ? 0.04 : null),
  'z-image/turbo': () => null, // the quote fails: the owner prices it
};
const entry = (ref: string) => higgsfieldCatalog().find(e => e.ref === ref)!;
const analysisOf = (ref: string) => { const e = entry(ref); return analyse({}, e.schema as any, { category: `x-to-${e.kind}`, text: e.name }); };

describe('Higgsfield catalog (from its docs)', () => {
  it('lists every documented model; 69 can run in MUSE, 14 need a source video (not wired to custom models yet)', () => {
    const all = higgsfieldCatalog();
    expect(all).toHaveLength(83);
    expect(all.filter(e => e.kind === 'image')).toHaveLength(16);
    const setup = all.map(e => ({ e, s: setupOf({ analysis: analysisOf(e.ref), fixedInputs: {}, kind: e.kind }) }));
    // The provider's kind and MUSE's reading of the schema agree for every model.
    for (const { e } of setup) expect(analysisOf(e.ref).kind, e.ref).toBe(e.kind);
    expect(setup.filter(x => x.s.ready)).toHaveLength(69);
    const needs = setup.filter(x => !x.s.ready);
    expect(needs.every(x => x.s.missing.some(f => /^video_urls?$/.test(f)))).toBe(true);
    for (const ref of ['higgsfield/genjutsu/motion-transfer/v1.0', 'higgsfield/genjutsu/restyle/v1.0', 'kling-video/motion-control/pro', 'bytedance/seedance-2.5/video-edit'])
      expect(needs.map(x => x.e.ref)).toContain(ref);
  });
  it('maps Higgsfield fields onto MUSE roles', () => {
    expect(analysisOf('kling-video/v3.0/pro/image-to-video').map).toMatchObject({ prompt: 'prompt', startImage: 'image_url', endImage: 'last_image_url', duration: 'duration' });
    const h3 = analysisOf('minimax/h3/reference-to-video');
    expect(h3.map).toMatchObject({ referenceImages: 'image_urls', duration: 'duration', resolution: 'resolution', aspectRatio: 'aspect_ratio' });
    expect(h3.inputs).toMatchObject({ referenceImages: 9, duration: { min: 5, max: 15 }, resolutions: ['2K'] });
    const q = analysisOf('alibaba/qwen-image-3/edit');
    expect(q).toMatchObject({ kind: 'image', map: { referenceImages: 'image_urls' }, inputs: { referenceImages: 3 } });
    expect(analysisOf('kling-video/o3/first-last-frame').map).toMatchObject({ startImage: 'first_frame_url', endImage: 'last_frame_url' });
  });
  it('a price quote fills every required field with a sample (media as placeholder URLs)', () => {
    const e = entry('higgsfield/genjutsu/restyle/v1.0');
    const s = higgsfieldSample(e.schema, analysisOf(e.ref));
    expect(s).toMatchObject({ video_url: expect.stringMatching(/^https:\/\/.+\.mp4$/), preset_id: expect.any(String) });
    expect(higgsfieldSample(entry('alibaba/qwen-image-3/edit').schema, analysisOf('alibaba/qwen-image-3/edit'))).toMatchObject({ prompt: 'x', image_urls: [expect.stringMatching(/\.jpg$/)] });
  });
  it('refusals map onto the suite\'s error kinds (403 is an empty balance unless the key expired or was disabled)', () => {
    expect(higgsfieldError(401, '{"detail":"Invalid credentials"}')).toMatchObject({ kind: 'unavailable', status: 401 });
    expect(higgsfieldError(403, '{"code":"api_key_expired","detail":"This API key has expired."}')).toMatchObject({ kind: 'unavailable', status: 403 });
    expect(higgsfieldError(403, '{"code":"api_key_disabled"}').kind).toBe('unavailable');
    expect(higgsfieldError(403, '{"detail":"Not enough credits"}')).toMatchObject({ kind: 'out_of_credit', message: 'Higgsfield is out of credit' });
    expect(higgsfieldError(403, '').kind).toBe('out_of_credit');
    expect(higgsfieldError(400, '{"detail":"Insufficient balance"}').kind).toBe('out_of_credit');
    expect(higgsfieldError(429, '{"detail":{"code":"account_queue_full"}}').kind).toBe('rate_limited');
    expect(higgsfieldError(423, '{"detail":"Model temporarily blocked"}').kind).toBe('unavailable');
    expect(higgsfieldError(503, '').kind).toBe('unavailable');
    expect(higgsfieldError(422, '{"detail":"duration: bad value"}').kind).toBe('failed');
  });
  it('the built-in Higgsfield H3 (h3-hf) is untouched', () => {
    expect(modelById('h3-hf')).toMatchObject({ provider: 'higgsfield', ref: { t2v: 'minimax/h3/text-to-video', ref2v: 'minimax/h3/reference-to-video' } });
  });
});

describe('Bring your own provider · Higgsfield against a FAKE Higgsfield (no money)', () => {
  let server: http.Server, dir: string, base = '';
  const calls: { method: string; url: string; auth?: string; body?: any }[] = [];
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-hf-byo-'));
    const mp4 = path.join(dir, 'out.mp4');
    if (hasFfmpeg) execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=288x512:rate=24', '-t', '5', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', mp4]);
    const runs = new Map<string, any>();
    server = http.createServer((q, res) => {
      let raw = '';
      q.on('data', c => (raw += c));
      q.on('end', () => {
        const url = q.url ?? '', auth = q.headers.authorization;
        const json = (s: number, o?: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(o === undefined ? '' : JSON.stringify(o)); };
        if (url === '/out.mp4') { res.writeHead(200, { 'content-type': 'video/mp4' }); fs.createReadStream(mp4).pipe(res); return; }
        const body = raw ? JSON.parse(raw) : undefined;
        calls.push({ method: q.method!, url, auth, body });
        if (!url.startsWith('/hf/')) return json(404, {});
        const key = auth?.startsWith('Key ') ? auth.slice(4) : '';
        if (key === 'hfid-old:expired-secret') return json(403, { code: 'api_key_expired', detail: 'This API key has expired.' });
        if (!OK_KEYS.has(key)) return json(401, { detail: 'Invalid credentials' });
        const sub = url.slice(3);
        let m = /^\/estimate\/(.+)$/.exec(sub);
        if (m && q.method === 'POST') { const c = RATES[m[1]!]?.(body ?? {}); return c == null ? json(500, { detail: 'error' }) : json(200, { usd: String(Math.round(c * 1e4) / 1e4) }); }
        m = /^\/requests\/([^/]+)\/status$/.exec(sub);
        if (m) { const r = runs.get(m[1]!); return r ? json(200, r) : json(404, { detail: 'Not found' }); }
        m = /^\/requests\/([^/]+)\/cancel$/.exec(sub);
        if (m && q.method === 'POST') { const r = runs.get(m[1]!); if (!r || r.status !== 'queued') return json(400, { detail: 'not queued' }); r.status = 'canceled'; return json(202); }
        if (q.method === 'POST') {
          const p = String(body?.prompt ?? '');
          if (/BROKE/.test(p)) return json(403, { detail: 'Not enough credits' });
          if (/BUSY/.test(p)) return json(429, { detail: { code: 'account_queue_full', retry_after_seconds: 30 } });
          if (/BADINPUT/.test(p)) return json(422, { detail: [{ loc: ['body', 'duration'], msg: 'bad value' }] });
          const id = crypto.randomUUID();
          const image = /soul|qwen|image-3/.test(sub);
          const done = image ? { status: 'completed', request_id: id, images: [{ url: `${base}/out.mp4` }] } : { status: 'completed', request_id: id, video: { url: `${base}/out.mp4` } };
          runs.set(id, /NSFW/.test(p) ? { status: 'nsfw', request_id: id } : /FAILLATER/.test(p) ? { status: 'failed', request_id: id, error: 'Generation failed' }
            : /HOLD/.test(p) ? { status: 'queued', request_id: id } : done);
          const own = `${base}/hf/requests/${id}`;
          return json(200, { status: 'queued', request_id: id, status_url: /EVIL/.test(p) ? `http://evil.example/steal/${id}` : `${own}/status`, cancel_url: `${own}/cancel` });
        }
        return json(404, { detail: 'Not Found' });
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(() => { server?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  const env = (extra: Record<string, string> = {}) => ({ PROVIDER_KEYS_SECRET: SECRET, HIGGSFIELD_API_URL: `${base}/hf`, REPLICATE_API_URL: `${base}/none`,
    SUITE_POLL_MS: '10', REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated', ...extra });
  const noKeyIn = (o: unknown) => { const s = JSON.stringify(o); for (const k of [HF_GOOD, HF_SERVER, 'hfsecret']) expect(s).not.toContain(k); };

  it('the adapter: key check, catalog with this account\'s prices, submit / poll / cancel, and errors', async () => {
    const ad = new HiggsfieldAdapter(() => `${base}/hf`);
    calls.length = 0;
    expect(await ad.validate(HF_GOOD)).toBe('ok');
    expect(await ad.validate('hfid-bad:nope-nope')).toBe('invalid');
    expect(await ad.validate('hfid-old:expired-secret')).toBe('invalid');
    expect(calls.slice(0, 2).map(c => [c.method, c.url, c.auth])).toEqual([['POST', '/hf/estimate/higgsfield-ai/soul/v2/standard', `Key ${HF_GOOD}`], ['POST', '/hf/estimate/higgsfield-ai/soul/v2/standard', 'Key hfid-bad:nope-nope']]);
    await expect(new HiggsfieldAdapter(() => 'http://127.0.0.1:1/hf').validate(HF_GOOD)).rejects.toThrow(/higgsfield unreachable/);

    // Search: the documented catalog, filtered here; prices from the estimate (the dearest case is kept).
    const kling = await ad.search(HF_GOOD, { q: 'kling 2.6 pro to', kind: 'video', limit: 10 });
    expect(kling.models.map(m => [m.ref, m.analysis.kind, m.price])).toEqual([
      ['kling-video/v2.6/pro/image-to-video', 'video', { basis: 'per_second', costUsd: 0.07, source: 'provider' }],
      ['kling-video/v2.6/pro/text-to-video', 'video', { basis: 'per_second', costUsd: 0.07, source: 'provider' }],
    ]);
    expect(kling.models[0]!.description).toMatch(/^https:\/\/docs\.higgsfield\.ai\//);
    const sd = await ad.model(HF_GOOD, 'bytedance/seedance-2.5/text-to-video');
    expect(sd?.price).toEqual({ basis: 'per_second', costUsd: 0.45, source: 'provider' }); // 1080p, the dearest
    expect((await ad.model(HF_GOOD, 'minimax/hailuo-2.3/standard/text-to-video'))?.price).toEqual({ basis: 'per_run', costUsd: 0.28, source: 'provider' });
    expect((await ad.model(HF_GOOD, 'higgsfield-ai/soul/v2/standard'))?.price).toEqual({ basis: 'per_run', costUsd: 0.094, source: 'provider' });
    expect((await ad.model(HF_GOOD, 'z-image/turbo'))?.price).toBeNull();
    expect(await ad.model(HF_GOOD, 'acme/not-documented')).toBeNull();
    expect(await ad.model(HF_GOOD, '../requests/x')).toBeNull();
    const images = await ad.search(HF_GOOD, { kind: 'image', limit: 50 });
    expect(images.models).toHaveLength(16);
    expect(images.nextCursor).toBeNull();
    const p1 = await ad.search(HF_GOOD, { kind: 'video', limit: 20 });
    expect(p1.nextCursor).toBe('20');
    // Every call went to Higgsfield's own host, with the key only in Authorization.
    expect(calls.every(c => c.url.startsWith('/hf/') && c.auth?.startsWith('Key '))).toBe(true);

    // Runs: POST /{endpoint} with the flat input, then the status URL.
    calls.length = 0;
    const h = await ad.start(HF_GOOD, { ref: 'kling-video/v2.6/pro/text-to-video' }, { prompt: 'A horse runs', duration: 5, aspect_ratio: '9:16' });
    expect(calls[0]).toMatchObject({ method: 'POST', url: '/hf/kling-video/v2.6/pro/text-to-video', auth: `Key ${HF_GOOD}`, body: { prompt: 'A horse runs', duration: 5, aspect_ratio: '9:16' } });
    expect(await ad.get(HF_GOOD, h)).toEqual({ status: 'succeeded', url: `${base}/out.mp4` });
    expect(await ad.get(HF_GOOD, await ad.start(HF_GOOD, { ref: 'higgsfield-ai/soul/v2/standard' }, { prompt: 'A portrait' }))).toEqual({ status: 'succeeded', url: `${base}/out.mp4` });
    // A status URL on another host is never followed with the key.
    const evil = JSON.parse(await ad.start(HF_GOOD, { ref: 'kling-video/v2.6/pro/text-to-video' }, { prompt: 'EVIL' }));
    expect(evil.s).toBe(`${base}/hf/requests/${evil.id}/status`);
    await expect(ad.start(HF_GOOD, { ref: '../x' }, { prompt: 'p' })).rejects.toMatchObject({ kind: 'failed' });
    await expect(ad.start(HF_GOOD, { ref: 'kling-video/v2.6/pro/text-to-video' }, { prompt: 'BROKE' })).rejects.toMatchObject({ kind: 'out_of_credit', status: 403 });
    await expect(ad.start(HF_GOOD, { ref: 'kling-video/v2.6/pro/text-to-video' }, { prompt: 'BUSY' })).rejects.toMatchObject({ kind: 'rate_limited' });
    await expect(ad.start(HF_GOOD, { ref: 'kling-video/v2.6/pro/text-to-video' }, { prompt: 'BADINPUT' })).rejects.toMatchObject({ kind: 'failed', status: 422 });
    const bad = await ad.start('hfid-bad:nope-nope', { ref: 'kling-video/v2.6/pro/text-to-video' }, { prompt: 'p' }).catch(e => e);
    expect(bad).toMatchObject({ kind: 'unavailable', status: 401 });
    expect(bad.message).not.toContain('nope');
    expect(await ad.get(HF_GOOD, await ad.start(HF_GOOD, { ref: 'kling-video/v2.6/pro/text-to-video' }, { prompt: 'NSFW' }))).toMatchObject({ status: 'failed', error: { kind: 'refused' } });
    expect(await ad.get(HF_GOOD, await ad.start(HF_GOOD, { ref: 'kling-video/v2.6/pro/text-to-video' }, { prompt: 'FAILLATER' }))).toMatchObject({ status: 'failed', error: { kind: 'failed' } });
    const hold = await ad.start(HF_GOOD, { ref: 'kling-video/v2.6/pro/text-to-video' }, { prompt: 'HOLD' });
    expect(await ad.get(HF_GOOD, hold)).toEqual({ status: 'running' });
    await ad.cancel(HF_GOOD, hold);
    expect(calls.at(-1)).toMatchObject({ method: 'POST', url: `/hf/requests/${JSON.parse(hold).id}/cancel`, auth: `Key ${HF_GOOD}` });
    expect(await ad.get(HF_GOOD, hold)).toEqual({ status: 'canceled' });
    expect(await ad.get('hfid-bad:nope-nope', hold)).toMatchObject({ status: 'failed', error: { kind: 'unavailable' } });
  });

  it('API: Higgsfield is a provider kind; with the server\'s Higgsfield account it connects with no key pasted (nothing stored)', async () => {
    const a = await makeApp(env({ SUITE_MODE: 'mock', HF_CREDENTIALS: HF_SERVER }));
    const { owner, members: [member] } = await people(a, 1);
    try {
      calls.length = 0;
      const kinds = (await owner.req('GET', '/v1/providers/kinds')).body.kinds;
      expect(kinds.map((k: any) => k.kind)).toEqual(['replicate', 'fal', 'muapi', 'higgsfield']);
      expect(kinds[3]).toEqual({ kind: 'higgsfield', label: 'Higgsfield', keyHint: 'An API key from console.higgsfield.ai, as KEY_ID:KEY_SECRET', keyUrl: 'https://console.higgsfield.ai', serverKey: true });
      expect(kinds.slice(0, 3).some((k: any) => k.serverKey)).toBe(false);
      expect((await member!.req('POST', '/v1/providers', { kind: 'higgsfield' })).status).toBe(403);

      const add = await owner.req('POST', '/v1/providers', { kind: 'higgsfield' });
      expect(add.status).toBe(201);
      expect(add.body).toMatchObject({ kind: 'higgsfield', label: 'Higgsfield (studio account)', keyLast4: 'server key', serverKey: true, status: 'ok' });
      noKeyIn(add.body);
      const [row] = await a.ctx.db.select().from(byoProviders);
      expect(row!.keyEnc).toBe('server'); // the key itself stays in the server's settings
      expect((await owner.req('POST', '/v1/providers', { kind: 'higgsfield' })).status).toBe(400); // once is enough
      const pid = add.body.id;
      noKeyIn((await owner.req('GET', '/v1/providers')).body);

      const b = (await owner.req('GET', `/v1/providers/${pid}/models?kind=video&q=kling%202.6%20pro%20to`)).body;
      noKeyIn(b);
      expect(b.models.map((m: any) => [m.ref, m.kind, m.ready, m.price?.costUsd])).toEqual([
        ['kling-video/v2.6/pro/image-to-video', 'video', true, 0.07], ['kling-video/v2.6/pro/text-to-video', 'video', true, 0.07]]);
      expect(calls.filter(c => c.url.startsWith('/hf/estimate/')).every(c => c.auth === `Key ${HF_SERVER}`)).toBe(true);

      // Genjutsu motion transfer can be browsed and added, but needs a source video MUSE doesn't send custom models yet.
      const gj = await owner.req('POST', `/v1/providers/${pid}/models`, { ref: 'higgsfield/genjutsu/motion-transfer/v1.0', displayName: 'Motion transfer' });
      expect(gj.status).toBe(201);
      expect(gj.body).toMatchObject({ providerKind: 'higgsfield', kind: 'video', status: 'needs_setup', missing: ['video_url'] });
      expect((await owner.req('POST', `/v1/providers/${pid}/models`, { ref: 'acme/undocumented-model' })).status).toBe(404);
      expect((await owner.req('POST', `/v1/providers/${pid}/models`, { ref: '../requests/x' })).status).toBe(400);

      const vm = await owner.req('POST', `/v1/providers/${pid}/models`, { ref: 'kling-video/v2.6/pro/text-to-video', displayName: 'House Kling' });
      expect(vm.body).toMatchObject({ status: 'ready', price: { basis: 'per_second', costUsd: 0.07, source: 'provider' } });
      expect((await owner.req('PATCH', `/v1/providers/models/${vm.body.id}`, { enabled: true, priceScale: 2 })).body).toMatchObject({ enabled: true, memberPrice: { basis: 'per_second', usd: 0.14 } });
      const e = (await owner.req('POST', '/v1/suite/shots/estimate', { prompt: 'A dog runs on the beach', duration: 10, quality: 'draft', aspectRatio: '9:16', engineModel: vm.body.id })).body;
      expect(e.estimate).toBeCloseTo(1.4, 6); // 10 s × $0.07 × 2
      expect((await member!.req('GET', '/v1/suite/catalog')).body.custom.map((c: any) => [c.name, c.providerName])).toEqual([['House Kling', 'Higgsfield']]);
      expect(calls.some(c => c.method === 'POST' && !c.url.startsWith('/hf/estimate/'))).toBe(false); // nothing ran

      // The owner can still use their own key instead (stored encrypted, like the other providers).
      const own = await owner.req('PATCH', `/v1/providers/${pid}`, { apiKey: HF_GOOD });
      expect(own.body).toMatchObject({ serverKey: false, keyLast4: '…wxyz' });
      noKeyIn(own.body);
    } finally { await a.close(); }
  });

  it('API: without a server Higgsfield account a key is required; a bad one is refused and not stored', async () => {
    const a = await makeApp(env({ SUITE_MODE: 'mock' }));
    const { owner } = await people(a, 0);
    try {
      expect((await owner.req('GET', '/v1/providers/kinds')).body.kinds.find((k: any) => k.kind === 'higgsfield').serverKey).toBeUndefined();
      expect((await owner.req('POST', '/v1/providers', { kind: 'higgsfield' })).status).toBe(400);
      const bad = await owner.req('POST', '/v1/providers', { kind: 'higgsfield', apiKey: 'hfid-bad:nope-nope' });
      expect(bad.body.code).toBe('invalid_key');
      expect(await a.ctx.db.select().from(byoProviders)).toHaveLength(0);
      const ok = await owner.req('POST', '/v1/providers', { kind: 'higgsfield', apiKey: HF_GOOD });
      expect(ok.body).toMatchObject({ kind: 'higgsfield', label: 'Higgsfield', keyLast4: '…wxyz', serverKey: false });
      noKeyIn(ok.body);
    } finally { await a.close(); }
  });

  it.skipIf(!hasFfmpeg)('live: a shot runs on the server\'s Higgsfield account and settles at Higgsfield\'s price; no credit fails with nothing charged', async () => {
    const a = await makeApp(env({ SUITE_MODE: 'live', HF_CREDENTIALS: HF_SERVER }));
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const p = (await owner.req('POST', '/v1/providers', { kind: 'higgsfield' })).body;
      const vm = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'kling-video/v2.6/pro/text-to-video', displayName: 'House Kling' })).body;
      await owner.req('PATCH', `/v1/providers/models/${vm.id}`, { enabled: true });
      const run = async (prompt: string) => {
        const r = (await owner.req('POST', '/v1/suite/shots', { prompt, duration: 5, quality: 'standard', aspectRatio: '9:16', engineModel: vm.id })).body;
        expect(r.id).toBeTruthy();
        const j = await until(async () => { const x = (await owner.req('GET', `/v1/suite/shots/${r.id}`)).body.job; return x?.state === 'done' || x?.state === 'failed' ? x : null; }, 20_000);
        return { id: r.id as string, job: j };
      };
      calls.length = 0;
      const ok = await run('A lighthouse at night, waves below.');
      expect(ok.job.state).toBe('done');
      const post = calls.find(c => c.method === 'POST' && c.url === '/hf/kling-video/v2.6/pro/text-to-video')!;
      expect(post.auth).toBe(`Key ${HF_SERVER}`);
      expect(post.body).toMatchObject({ duration: 5, aspect_ratio: '9:16' });
      expect(Object.keys(post.body).every(k => entry('kling-video/v2.6/pro/text-to-video').schema.properties![k])).toBe(true);
      const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, ok.id))).find(x => x.kind === 'settle');
      expect(Math.abs(settle!.amountUsd)).toBeCloseTo(0.35, 6); // 5 s × $0.07

      const broke = await run('BROKE: she walks along the pier.');
      expect(broke.job).toMatchObject({ state: 'failed', errorCode: 'provider_out_of_credit' });
      const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, broke.id));
      expect(rows.find(x => x.kind === 'settle' && Math.abs(x.amountUsd) > 0)).toBeUndefined();
      expect((await owner.req('GET', '/v1/providers')).body.providers[0].status).toBe('ok'); // no credit isn't a bad key

      // The image engine: references as Higgsfield's image_urls list.
      const im = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'alibaba/qwen-image-3/edit' })).body;
      expect(im).toMatchObject({ kind: 'image', price: { basis: 'per_run', costUsd: 0.04 } });
      await owner.req('PATCH', `/v1/providers/models/${im.id}`, { enabled: true });
      calls.length = 0;
      const out = await a.ctx.suite.byo.image.generate({ prompt: 'A portrait', referenceImages: ['https://x/a.jpg'], width: 768, height: 1024, count: 1, seed: 7 }, { provider: 'byo', model: im.id });
      expect(out.images).toHaveLength(1);
      expect(out.costUsd).toBeCloseTo(0.04, 6);
      expect(calls.find(c => c.method === 'POST' && c.url === '/hf/alibaba/qwen-image-3/edit')!.body).toMatchObject({ prompt: 'A portrait', image_urls: ['https://x/a.jpg'], aspect_ratio: '3:4', seed: 7 });
    } finally { await a.close(); }
  });
});
