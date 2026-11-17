// Owner-only failure diagnostics (lib/failure.ts; coordinator 2026-11-16, job j_c1d11a56e120): a job that fails at the
// provider keeps the provider, model, HTTP status, a category, the provider's own words (scrubbed, ≤300 characters) and
// the stage in its stats; the owner sees it (GET /v1/jobs, GET /v1/jobs/:id, queue_list), a member never does, and the
// member-safe `error` text is unchanged. Photos on a custom Muapi model run against a FAKE Muapi on localhost.
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq, sql } from 'drizzle-orm';
import { jobs, users } from '../src/db/schema.js';
import { muapiError, higgsfieldError } from '../src/byo/adapters.js';
import { ReplicateError } from '../src/replicate/client.js';
import { categoryOf, providerFailure, scrubProviderMessage } from '../src/lib/failure.js';
import { PHOTO_FAILED, OUT_OF_CREDIT } from '../src/images/service.js';
import { APP_TOOLS } from '../src/claude/appTools.js';
import type { AuthUser } from '../src/ctx.js';
import { makeApp, people, until, type Client } from './helpers.js';

const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures/byo');
const fixture = (n: string) => JSON.parse(fs.readFileSync(path.join(FIX, n), 'utf8'));
const SECRET = crypto.randomBytes(32).toString('hex');
const MU_GOOD = 'mu_test_key_0123456789_qrst';
const SIGNED = 'https://bucket.r2.cloudflarestorage.com/u/img_ab12.png?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAEXAMPLE%2F20261116&X-Amz-Signature=0123456789abcdef0123456789abcdef';
/** Nothing credential-shaped, and no signed-URL query, may be stored. */
const LEAKS = [MU_GOOD, 'X-Amz-Signature', 'X-Amz-Credential', '0123456789abcdef0123456789abcdef', 'sk-live-abcdefghijklmnop', 'tok_9f8e7d6c5b4a'];
const noLeak = (o: unknown) => { const s = JSON.stringify(o); for (const l of LEAKS) expect(s, l).not.toContain(l); };

describe('the diagnostic itself', () => {
  it('categories from status and kind: 400 validation, 402 credit, 401 key, 5xx server, refusals, timeouts, unreachable', () => {
    expect(categoryOf(muapiError(400, '{"detail":"images_list: field required"}'))).toBe('validation');
    expect(categoryOf(muapiError(422, '{"detail":"resolution: 2K is not supported for 9:16"}'))).toBe('validation');
    expect(categoryOf(muapiError(402, '{}'))).toBe('credit');
    expect(categoryOf(muapiError(400, '{"detail":"Insufficient balance. Please top up."}'))).toBe('credit');
    expect(categoryOf(muapiError(401, ''))).toBe('key');
    expect(categoryOf(muapiError(403, '{"detail":"Not authorized: missing or invalid credentials"}'))).toBe('key');
    expect(categoryOf(muapiError(500, 'upstream exploded'))).toBe('server');
    expect(categoryOf(muapiError(429, ''))).toBe('server');
    expect(categoryOf(muapiError(400, '{"detail":"Prompt flagged by content moderation"}'))).toBe('content_filter');
    expect(categoryOf(higgsfieldError(403, '{"detail":"Not enough credits"}'))).toBe('credit');
    expect(categoryOf(new ReplicateError('timed out', 'timeout'))).toBe('timeout');
    expect(categoryOf(new ReplicateError('muapi unreachable (TypeError)', 'unavailable'))).toBe('unreachable');
    expect(categoryOf(new Error('ffmpeg is not installed on the server'))).toBe('unknown');
  });

  it('keeps the provider\'s own body (not just the member line), scrubbed and capped at 300 characters, with the stage', () => {
    const body = JSON.stringify({ detail: [{ loc: ['body', 'images_list', 0], msg: `could not download ${SIGNED}`, type: 'value_error' }],
      headers: { 'x-api-key': MU_GOOD }, note: 'Authorization: Bearer sk-live-abcdefghijklmnop, token=tok_9f8e7d6c5b4a', pad: 'x'.repeat(600) });
    const e = muapiError(400, body);
    expect(e.message).toMatch(/^Muapi rejected the request \(400/);
    const f = providerFailure(e, { provider: 'byo', model: 'c_1', secrets: [MU_GOOD] });
    expect(f).toMatchObject({ provider: 'muapi', model: 'c_1', httpStatus: 400, category: 'validation', stage: 'submit' });
    expect(f.providerMessage).toContain('images_list');
    expect(f.providerMessage).toContain('https://bucket.r2.cloudflarestorage.com/u/img_ab12.png?[query removed]');
    expect(f.providerMessage!.length).toBeLessThanOrEqual(300);
    expect(f.at).toBeGreaterThan(Date.now() - 5000);
    noLeak(f);
    // A key the scrub rules wouldn't recognise is still removed when it's in hand.
    expect(scrubProviderMessage('echo: plainkeyvalue', ['plainkeyvalue'])).toBe('echo: [redacted]');
  });
});

describe('Photos on a custom Muapi model that fails at Muapi', () => {
  let server: http.Server, base = '', png: Buffer;
  beforeAll(async () => {
    png = await (await import('sharp')).default({ create: { width: 64, height: 48, channels: 3, background: '#c04' } }).png().toBuffer();
    server = http.createServer((q, res) => {
      let raw = '';
      q.on('data', c => (raw += c));
      q.on('end', () => {
        const url = q.url ?? '', key = q.headers['x-api-key'] as string | undefined;
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        // An outside picture that redirects (like /uploads/… on MUSE's own API): MUSE follows it, the provider never sees it.
        if (url === '/moved.png') { res.writeHead(302, { location: '/pic.png' }); res.end(); return; }
        if (url === '/pic.png') { res.writeHead(200, { 'content-type': 'image/png' }); res.end(png); return; }
        const sub = url.slice('/mu/api/v1'.length);
        if (sub === '/models') return json(200, fixture('muapi-models.json'));
        if (/^\/models\/[^/]+\/estimate-cost$/.test(sub)) return json(200, { cost: 0.04, currency: 'USD' });
        const m = /^\/models\/([^/?]+)$/.exec(sub);
        if (m) return json(200, fixture(`muapi-model-${m[1]}.json`));
        if (key !== MU_GOOD) return json(403, { detail: 'Not authorized: missing or invalid credentials' });
        if (sub === '/account/balance') return json(200, { balance: 1, currency: 'USD' });
        const p = String((raw ? JSON.parse(raw) : {}).prompt ?? '');
        if (/VALIDATION/.test(p)) return json(400, { detail: [{ loc: ['body', 'images_list', 0], msg: `Image could not be downloaded: ${SIGNED}`, type: 'value_error' }], echo: { 'x-api-key': MU_GOOD } });
        if (/BROKE/.test(p)) return json(402, { detail: 'Insufficient balance. Please top up your wallet.' });
        if (/BOOM/.test(p)) return json(500, { detail: 'upstream exploded · token=tok_9f8e7d6c5b4a' });
        if (/KEYBAD/.test(p)) return json(401, { detail: 'Not authorized: invalid api key' });
        return json(404, { detail: 'Not Found' });
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(() => { server?.close(); });

  it('the owner sees provider, model, status, category, Muapi\'s words and stage; a member sees only the member-safe error', async () => {
    const a = await makeApp({ PROVIDER_KEYS_SECRET: SECRET, MUAPI_API_URL: `${base}/mu/api/v1`, REPLICATE_API_URL: `${base}/none`,
      SUITE_POLL_MS: '10', REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated', SUITE_MODE: 'live' });
    const { owner, members: [member] } = await people(a, 1, { topUp: 100 });
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: member!.id, tokens: 2000 });
    const authUser = async (c: Client, role: 'owner' | 'member'): Promise<AuthUser> => {
      const [u] = await a.ctx.db.select().from(users).where(eq(users.id, c.id));
      const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${c.id}`)) as any).rows[0].studio_id;
      return { id: u!.id, studioId, email: u!.email, role, studioName: 'Test Studio', sessionId: null } as AuthUser;
    };
    try {
      const p = (await owner.req('POST', '/v1/providers', { kind: 'muapi', apiKey: MU_GOOD })).body;
      const im = (await owner.req('POST', `/v1/providers/${p.id}/models`, { ref: 'bytedance-seedream-v4-edit' })).body;
      expect((await owner.req('PATCH', `/v1/providers/models/${im.id}`, { enabled: true, members: true, displayName: 'House Still' })).status).toBe(200);
      const shoot = async (who: Client, prompt: string) => {
        // An edit model takes a picture to work from (words alone are refused before the run since 2026-11-17).
        const r = await who.req('POST', '/v1/suite/photos', { prompt, count: 2, imageModel: im.id, async: true, references: [{ image: { asset: 'g_front' }, guides: ['look'] }] });
        expect(r.status, JSON.stringify(r.body)).toBe(200);
        const id = r.body.job.id as string;
        return until(async () => { const j = (await who.req('GET', `/v1/jobs/${id}`)).body; return j?.state === 'failed' || j?.state === 'done' ? j : null; }, 15_000);
      };

      // 400 validation: Muapi's own words (the bad image URL), scrubbed; the member line is unchanged.
      const v = await shoot(member!, 'VALIDATION: on the pier');
      expect(v).toMatchObject({ state: 'failed', error: PHOTO_FAILED });
      expect(v.failure).toBeUndefined(); // a member's own job: still no diagnostic
      const vo = (await owner.req('GET', `/v1/jobs/${v.id}`)).body;
      expect(vo.error).toBe(PHOTO_FAILED);
      expect(vo.failure).toMatchObject({ provider: 'muapi', model: 'bytedance-seedream-v4-edit', httpStatus: 400, category: 'validation', stage: 'submit' });
      expect(vo.failure.providerMessage).toContain('Image could not be downloaded');
      expect(vo.failure.providerMessage.length).toBeLessThanOrEqual(300);
      noLeak(vo);
      // Stored with the job (stats.failure), never with the key.
      const [row] = await a.ctx.db.select().from(jobs).where(eq(jobs.id, v.id));
      expect((row!.stats as any).failure.category).toBe('validation');
      noLeak(row!.stats);

      // 402 credit: said as no credit (it was "something went wrong" before), and Replicate isn't flagged for it.
      const b = await shoot(member!, 'BROKE: on the pier');
      expect(b).toMatchObject({ state: 'failed', error: OUT_OF_CREDIT });
      expect((await owner.req('GET', `/v1/jobs/${b.id}`)).body.failure).toMatchObject({ provider: 'muapi', httpStatus: 402, category: 'credit', stage: 'submit' });
      expect((a.ctx.engines as unknown as { credit: Map<string, unknown> }).credit.has('replicate')).toBe(false);

      // 5xx server.
      const s = await shoot(owner, 'BOOM: on the pier');
      expect(s.failure).toMatchObject({ provider: 'muapi', httpStatus: 500, category: 'server', stage: 'submit' });
      noLeak(s);

      // The lists: the owner's GET /v1/jobs and queue_list carry `failure` on failed jobs; the member's never do.
      const ownerList = (await owner.req('GET', '/v1/jobs')).body as any[];
      const memberList = (await member!.req('GET', '/v1/jobs')).body as any[];
      expect(ownerList.filter(j => j.failure).map(j => j.failure.category).sort()).toEqual(['credit', 'server', 'validation']);
      expect(memberList.length).toBe(ownerList.length);
      expect(memberList.some(j => 'failure' in j)).toBe(false);
      expect(JSON.stringify(memberList)).not.toContain('providerMessage');
      const tool = APP_TOOLS.find(t => t.name === 'queue_list')!;
      const oq = await tool.run({ ctx: a.ctx, user: await authUser(owner, 'owner'), source: 'chat' } as any, { limit: 10 }) as any;
      const mq = await tool.run({ ctx: a.ctx, user: await authUser(member!, 'member'), source: 'chat' } as any, { limit: 10 }) as any;
      const qv = oq.jobs.find((j: any) => j.id === v.id);
      expect(qv.failure).toMatchObject({ category: 'validation', httpStatus: 400 });
      expect(qv.failure.providerMessage).toBe(vo.failure.providerMessage); // whole, not cut by the tool's 240-character trim
      expect(JSON.stringify(mq)).not.toContain('providerMessage');
      expect(mq.jobs.find((j: any) => j.id === v.id).error).toBe(PHOTO_FAILED);
      noLeak(oq);
      // A member can't read another studio's job, and a missing one is a 404.
      expect((await member!.req('GET', '/v1/jobs/j_nothere')).status).toBe(404);

      // References for a custom model are direct signed storage links: a stored image as is; an outside link (here one that
      // redirects) copied once as a JPEG; a cache-buster on an /uploads/ link doesn't turn it into a redirect.
      const studioId = (await authUser(owner, 'owner')).studioId;
      const outside = await a.ctx.images.providerRef({ url: `${base}/moved.png` }, studioId);
      expect(outside).toMatch(/\/storage\/local\/rx\/p_[0-9a-f]{32}\.jpg\?exp=/);
      expect(outside).not.toContain(base);
      await a.ctx.storage.put('u/ref_ok.jpg', png, 'image/jpeg');
      expect(await a.ctx.images.providerRef({ url: '/uploads/u/ref_ok.jpg?v=3' }, studioId)).toMatch(/\/storage\/local\/u\/ref_ok\.jpg\?exp=/);
      expect(await a.ctx.images.providerRef({ url: 'not a link' }, studioId)).toBeNull();

      // 401 key (last: it marks the key refused).
      const k = await shoot(owner, 'KEYBAD: on the pier');
      expect(k.state).toBe('failed');
      expect(k.failure).toMatchObject({ provider: 'muapi', httpStatus: 401, category: 'key', stage: 'submit' });
    } finally { await a.close(); }
  });
});
