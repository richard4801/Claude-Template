// AssemblyAI captions (src/editor/assemblyai.ts) against a fake AssemblyAI API on localhost: no network, no spend.
// With its key set it is the default captions model; exact word timing (ms → s); detected language; settled on the
// audio seconds × the model it used; the transcript is deleted there whatever happens; the owner can pick the other
// model; members never see the vendor.
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq, sql } from 'drizzle-orm';
import { ledger, takes } from '../src/db/schema.js';
import { editorAi } from '../src/editor/service.js';
import { ASSEMBLY_MODEL } from '../src/editor/assemblyai.js';
import { makeApp, people, until, type Client } from './helpers.js';

describe('AssemblyAI captions (fake server)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, srv: http.Server;
  const seen: { method: string; url: string; auth?: string; body?: any }[] = [];
  let mode: 'ok' | 'error' | 'silent' = 'ok', n = 0;
  const polls = new Map<string, number>();

  beforeAll(async () => {
    srv = http.createServer((req, res) => {
      let body = '';
      req.on('data', c => { body += c; });
      req.on('end', () => {
        const url = req.url ?? '';
        seen.push({ method: req.method!, url, auth: req.headers.authorization, body: body ? JSON.parse(body) : undefined });
        const json = (o: unknown, status = 200) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (req.method === 'POST' && url === '/v2/transcript') return json({ id: `tr${++n}`, status: 'queued' });
        const m = /^\/v2\/transcript\/(\w+)$/.exec(url);
        if (m && req.method === 'DELETE') return json({ id: m[1], status: 'completed' });
        if (m && req.method === 'GET') {
          const k = (polls.get(m[1]!) ?? 0) + 1; polls.set(m[1]!, k);
          if (k === 1) return json({ id: m[1], status: 'processing' });
          if (mode === 'error') return json({ id: m[1], status: 'error', error: 'Download error, unable to download the file' });
          if (mode === 'silent') return json({ id: m[1], status: 'error', error: 'language_detection cannot be performed on files with no spoken audio.' });
          return json({ id: m[1], status: 'completed', language_code: 'es', language_confidence: 0.97, audio_duration: 600, speech_model_used: 'universal-2', text: 'Hola a todos.',
            words: [{ text: 'Hola', start: 1234, end: 1560, confidence: 0.99, speaker: null }, { text: 'a', start: 1600, end: 1650, confidence: 0.9, speaker: null }, { text: 'todos.', start: 1700, end: 2105, confidence: 0.95, speaker: null }] });
        }
        json({ error: 'not found' }, 404);
      });
    });
    await new Promise<void>(r => srv.listen(0, '127.0.0.1', r));
    a = await makeApp({ ASSEMBLYAI_API_KEY: 'test-aai-key', ASSEMBLYAI_API_URL: `http://127.0.0.1:${(srv.address() as AddressInfo).port}` });
    const p = await people(a, 1);
    owner = p.owner; member = p.members[0]!;
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: (member as any).id, tokens: 1000, note: 'test' });
    editorAi(a.ctx).assembly.pollMs = 10;
  }, 60_000);
  afterAll(async () => { await a?.close(); await new Promise(r => srv?.close(r)); });

  const take = async (durationSec = 600) => {
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id as string;
    const id = `take_${Math.random().toString(16).slice(2, 10)}`;
    await a.ctx.storage.put(`c/${id}.mp4`, Buffer.from('video'), 'video/mp4');
    await a.ctx.db.insert(takes).values({ id, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 't', label: 'HD', engineLabel: 'HD', cost: 1, seed: 1,
      status: 'final', thumb: null, prompt: 'p', mediaKey: `c/${id}.mp4`, media: { durationSec, width: 1080, height: 1920, fps: 30, contentType: 'video/mp4' }, createdAt: Date.now() });
    return id;
  };
  const done = (c: Client, id: string) => until(async () => { const x = (await c.req('GET', `/v1/editor/jobs/${id}`)).body; return x.state !== 'running' ? x : null; });
  const ledgerKinds = async (id: string) => (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, id))).map(x => x.kind).sort();

  it('is the default captions model; exact word times, detected language, settled on audio × the model used, deleted after', async () => {
    const eng = (await owner.req('GET', '/v1/engines?purpose=captions')).body;
    expect(eng.default).toBe(ASSEMBLY_MODEL);
    expect(eng.models.map((m: any) => m.model)).toContain(editorAi(a.ctx).provider.models.transcribe);
    const src = await take();
    const est = (await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', source: { takeId: src } })).body;
    expect(est.usd).toBeCloseTo(600 * 0.21 / 3600 * 2, 4); // the dearer model, × 2
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'captions', source: { takeId: src } })).body;
    expect(j.models).toEqual([ASSEMBLY_MODEL]);
    const r = await done(owner, j.id);
    expect(r.state, JSON.stringify(r)).toBe('done');
    expect(r.result.language).toBe('es');
    expect(r.result.words).toEqual([{ text: 'Hola', startSec: 1.234, endSec: 1.56, score: 0.99 }, { text: 'a', startSec: 1.6, endSec: 1.65, score: 0.9 }, { text: 'todos.', startSec: 1.7, endSec: 2.105, score: 0.95 }]);
    expect(r.costUsd).toBeCloseTo(600 * 0.15 / 3600 * 2, 4); // Universal-2 was used
    expect(await ledgerKinds(j.id)).toEqual(['hold', 'settle']);
    const sub = seen.find(x => x.method === 'POST')!;
    expect(sub.auth).toBe('test-aai-key');
    expect(sub.body).toMatchObject({ language_detection: true, speech_models: ['universal-3-5-pro', 'universal-2'] });
    expect(sub.body.audio_url).toMatch(new RegExp(src));
    expect(seen.some(x => x.method === 'DELETE' && x.url === '/v2/transcript/tr1')).toBe(true);

    // A language given is sent as such; cuts use it too; members never see the vendor.
    const s2 = await take(30);
    const m = (await member.req('POST', '/v1/editor/jobs', { kind: 'cuts', source: { takeId: s2 }, options: { language: 'fr' } })).body;
    expect(m.models).toBeUndefined();
    const mr = await done(member, m.id);
    expect(mr.state, JSON.stringify(mr)).toBe('done');
    expect(seen.filter(x => x.method === 'POST').at(-1)!.body).toMatchObject({ language_code: 'fr' });
    expect(seen.filter(x => x.method === 'POST').at(-1)!.body.language_detection).toBeUndefined();
    expect(JSON.stringify(mr)).not.toMatch(/assembly|universal/i);
    expect(JSON.stringify((await member.req('GET', '/v1/editor/features')).body)).not.toMatch(/assembly/i);
  }, 60_000);

  it('the owner can pick the other model, per job or as the studio default', async () => {
    const other = editorAi(a.ctx).provider.models.transcribe;
    const s = await take(30);
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'captions', source: { takeId: s }, engineModel: other })).body;
    expect(j.models).toEqual([other]);
    expect((await done(owner, j.id)).state).toBe('done');
    expect((await owner.req('PATCH', '/v1/engines/defaults', { captions: other })).status).toBe(200);
    const s2 = await take(30);
    expect((await owner.req('POST', '/v1/editor/jobs', { kind: 'captions', source: { takeId: s2 } })).body.models).toEqual([other]);
    await owner.req('PATCH', '/v1/engines/defaults', { captions: null });
    const s3 = await take(30);
    expect((await owner.req('POST', '/v1/editor/jobs', { kind: 'captions', source: { takeId: s3 } })).body.models).toEqual([ASSEMBLY_MODEL]);
  }, 60_000);

  it('a failed transcript fails the job, gives the hold back and is deleted; a silent video gives no words', async () => {
    mode = 'error';
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'captions', source: { takeId: await take(30) } })).body;
    const r = await done(owner, j.id);
    expect(r.state).toBe('failed');
    expect(await ledgerKinds(j.id)).toEqual(['hold', 'release']);
    const id = seen.filter(x => x.method === 'POST').length;
    expect(seen.some(x => x.method === 'DELETE' && x.url === `/v2/transcript/tr${id}`)).toBe(true);
    mode = 'silent';
    const q = await done(owner, (await owner.req('POST', '/v1/editor/jobs', { kind: 'captions', source: { takeId: await take(30) } })).body.id);
    mode = 'ok';
    expect(q.state, JSON.stringify(q)).toBe('done');
    expect(q.result.words).toEqual([]);
  }, 60_000);
});
