// Each provider on its own (owner 2026-11-15: "Higgsfield + Replicate should stand on their own! Higgsfield has 480p"):
// "Seedance 2.5 · Replicate" and "Seedance 2.5 · Higgsfield" are two entries with their own resolutions and prices; a pick
// never moves to the other provider, unless the studio opted in to a fallback when one refuses at start. Pure planning
// first, then a FAKE Higgsfield (free /estimate quotes, runs) + FAKE Replicate: no money, no real generation.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { ledger } from '../src/db/schema.js';
import { buildInput } from '../src/suite/inputs.js';
import { buildPlan, needOf, pickModel, ShotRequestSchema } from '../src/suite/plan.js';
import { familyOf, isRoute, MODELS, modelById, publicModels, refFor, type ProviderId } from '../src/suite/registry.js';
import { fallbackRoute } from '../src/suite/routes.js';
import { demoModel, makeApp, people, until } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const ALL = new Set<ProviderId>(['replicate', 'fal', 'higgsfield', 'mock']);
const REP = new Set<ProviderId>(['replicate', 'fal', 'mock']);
const req = (o: Record<string, unknown> = {}) => ShotRequestSchema.parse({ prompt: 'She walks to the window.', ...o });
const U = { start: 'https://x/s.png', end: 'https://x/e.png', middle: [], refs: ['https://x/1.png', 'https://x/2.png'], videos: ['https://x/v.mp4'], audio: 'https://x/a.wav' };

describe('the registry: each provider is its own model', () => {
  it('Higgsfield routes are listed on their own, linked to their Replicate model only by `family`; old ids are what they were', () => {
    const routes = MODELS.filter(isRoute).map(m => [m.id, m.family]);
    expect(routes).toEqual([['h3-hf', 'h3'], ['seedance-2.5-hf', 'seedance-2.5'], ['seedance-2.0-hf', 'seedance-2.0'], ['kling-v3-omni-hf', 'kling-v3-omni'], ['wan-2.7-hf', 'wan-2.7']]);
    const listed = publicModels().map(m => m.id);
    for (const [id, fam] of routes) { expect(listed).toContain(id); expect(listed).toContain(fam); expect(familyOf(id!)).toBe(fam); }
    expect(listed).toContain('kling-v3');
    expect(modelById('seedance-2.5')!.provider).toBe('replicate');
    expect(modelById('h3')!.provider).toBe('replicate');
    expect(modelById('h3-hf')!.provider).toBe('higgsfield');
    expect(modelById('seedance-2.5-hf')!.resolutions.map(r => r.id)).toEqual(['480p', '720p', '1080p']);
    expect(modelById('seedance-2.5')!.resolutions.map(r => r.id)).toEqual(['480p', '720p']);
  });

  it('kling 3.0 picks its std / pro / 4k endpoint by resolution; Higgsfield routes map their request fields from catalog.json', () => {
    const k3 = modelById('kling-v3')!;
    expect(['720p', '1080p', '4k'].map(r => refFor(k3, 't2v', r))).toEqual(['kling-video/v3.0/std/text-to-video', 'kling-video/v3.0/pro/text-to-video', 'kling-video/v3.0/4k/text-to-video']);
    const plan = (kind: 't2v' | 'i2v' | 'ref2v', resolution: string, o: Record<string, unknown> = {}) =>
      ({ prompt: 'p', seconds: 6.4, resolution, aspect: '9:16', audio: true, kind, mode: kind === 'i2v' ? 'image' : kind === 'ref2v' ? 'reference' : 'text', params: {}, seed: 7, negative: 'blur', ...o }) as any;
    expect(buildInput(k3, plan('i2v', '4k'), U)).toEqual({ prompt: 'p', duration: 6, sound: 'on', image_url: U.start, last_image_url: U.end });
    expect(buildInput(modelById('kling-v3-omni-hf')!, plan('ref2v', '720p'), U)).toEqual({ prompt: 'p', duration: 6, mode: 'std', sound: 'on', aspect_ratio: '9:16', image_urls: U.refs });
    expect(buildInput(modelById('seedance-2.5-hf')!, plan('ref2v', '480p'), U)).toEqual({ prompt: 'p', duration: 6, resolution: '480p', generate_audio: true, aspect_ratio: '9:16',
      image_urls: U.refs, video_urls: U.videos, audio_urls: [U.audio] });
    expect(buildInput(modelById('wan-2.7-hf')!, plan('ref2v', '1080p', { seconds: 14 }), U)).toMatchObject({ duration: 10, seed: 7, negative_prompt: 'blur' });
    expect(buildInput(modelById('h3-hf')!, plan('i2v', '2K', { seconds: 6 }), U)).toEqual({ prompt: 'p', duration: 6, resolution: '2K', aigc_watermark: false, image_url: U.start, end_image_url: U.end, aspect_ratio: 'adaptive' });
  });
});

describe('a pick stays on its provider', () => {
  const pick = (id: string, res: string, r = req(), ok = ALL) => pickModel('hd', needOf(r, null), { providers: ok, engineModel: id, resolution: res });
  it('Seedance 2.5 · Replicate at 720p stays on Replicate; Seedance 2.5 · Higgsfield at 480p runs on Higgsfield; H3 2K stays where picked', () => {
    const r = pick('seedance-2.5', '720p');
    expect('model' in r && [r.model.id, r.alternates ?? []]).toEqual(['seedance-2.5', []]);
    const h = pick('seedance-2.5-hf', '480p');
    expect('model' in h && h.model.id).toBe('seedance-2.5-hf');
    expect('model' in pick('h3', '2K') && (pick('h3', '2K') as any).model.id).toBe('h3');
    expect('model' in pick('h3-hf', '2K') && (pick('h3-hf', '2K') as any).model.id).toBe('h3-hf');
    // A Higgsfield pick without Higgsfield set up is refused, never moved to Replicate.
    expect(pick('seedance-2.5-hf', '480p', req(), REP)).toMatchObject({ error: 'nothing_fits' });
  });
  it('a directed shot (guide clip) is made by Seedance 2.5 · Higgsfield at 480p: the guide goes as a reference video', () => {
    const r = req({ duration: 13, camera: { mode: 'directed', guide: { video: { key: 'guides/g.mp4', seconds: 13 }, use: 'blocking' } } });
    const p = pick('seedance-2.5-hf', '480p', r);
    if ('error' in p) throw new Error(JSON.stringify(p.tried));
    const plan = buildPlan(r, needOf(r, null), p, null, {});
    expect([plan.provider, plan.kind, plan.ref, plan.seconds, plan.videos.length]).toEqual(['higgsfield', 'ref2v', 'bytedance/seedance-2.5/reference-to-video', 13, 1]);
  });
});

describe('fallback at start (only when the studio opts in): the other provider at the same resolution', () => {
  const plan = (o: Record<string, unknown> = {}) => ({ resolution: '720p', kind: 't2v', images: { middle: [], refs: [] }, videos: [], ...o }) as any;
  it('names the other provider that makes the resolution and takes the inputs; none → null', () => {
    const ok = () => true;
    expect(fallbackRoute(modelById('seedance-2.5')!, plan(), ok)?.id).toBe('seedance-2.5-hf');
    expect(fallbackRoute(modelById('seedance-2.5-hf')!, plan(), ok)?.id).toBe('seedance-2.5');
    expect(fallbackRoute(modelById('seedance-2.5-hf')!, plan({ resolution: '1080p' }), ok)).toBeNull();
    expect(fallbackRoute(modelById('h3-hf')!, plan({ resolution: '2K', kind: 'ref2v', images: { middle: [], refs: [1, 2, 3] } }), ok)?.id).toBe('h3');
    expect(fallbackRoute(modelById('kling-v4')!, plan(), ok)).toBeNull();
  });
});

describe.skipIf(!hasFfmpeg)('one model, several providers against a FAKE Higgsfield + Replicate (no money)', () => {
  let server: http.Server, dir: string, base = '';
  const hf: { url: string; input: any }[] = [];
  const quotes: { url: string; body: any }[] = [];
  const rep: { model: string; input: any }[] = [];
  /** $/s Higgsfield quotes per endpoint and resolution (or Kling mode); missing = no quote (404). */
  let rates: Record<string, number> = {};
  let hfMode: 'ok' | 'no_credit' = 'ok', repMode: 'ok' | 'no_credit' = 'ok';
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-routes-fake-'));
    const file = path.join(dir, 'out.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=288x512:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', file]);
    server = http.createServer((q, res) => {
      let body = '';
      q.on('data', c => (body += c));
      q.on('end', () => {
        const url = q.url ?? '';
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (url === '/out.mp4') { res.writeHead(200, { 'content-type': 'video/mp4' }); fs.createReadStream(file).pipe(res); return; }
        if (url.startsWith('/hf/')) {
          if (q.headers.authorization !== 'Key hfid:hfsecret') return json(401, { detail: 'Invalid API credentials' });
          const sub = url.slice(3);
          if (q.method === 'POST' && sub.startsWith('/estimate/')) {
            const b = JSON.parse(body), ref = sub.slice('/estimate/'.length);
            quotes.push({ url: ref, body: b });
            const rate = rates[`${ref}@${b.resolution ?? b.mode}`];
            return rate == null ? json(404, { detail: 'no price' }) : json(200, { usd: Math.round(rate * Number(b.duration) * 10000) / 10000, currency: 'USD' });
          }
          if (/^\/requests\/[0-9a-f-]+\/status$/.test(sub)) return json(200, { status: 'completed', request_id: 'x', video: { url: `${base}/out.mp4` } });
          if (q.method === 'POST') {
            hf.push({ url: sub, input: JSON.parse(body) });
            if (hfMode === 'no_credit') return json(403, { detail: 'Not enough credits' });
            const id = `00000000-0000-0000-0000-0000000000${String(hf.length).padStart(2, '0')}`;
            return json(200, { status: 'queued', request_id: id, status_url: `${base}/hf/requests/${id}/status`, cancel_url: `${base}/hf/requests/${id}/cancel` });
          }
          return json(404, {});
        }
        if (q.headers.authorization !== 'Bearer r8_suite') return json(401, {});
        const m = /^\/v1\/models\/([^/]+\/[^/]+)\/predictions$/.exec(url);
        if (m && q.method === 'POST') {
          rep.push({ model: m[1]!, input: JSON.parse(body).input });
          if (repMode === 'no_credit') return json(402, { detail: 'Payment required' });
          return json(201, { id: `p${rep.length}`, status: 'starting' });
        }
        if (/^\/v1\/predictions\/p\d+$/.test(url)) return json(200, { id: 'p', status: 'succeeded', output: `${base}/out.mp4`, metrics: { video_output_duration_seconds: 6 } });
        json(404, {});
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(() => { server?.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const env = (extra: Record<string, string> = {}) => ({ SUITE_MODE: 'live', SUITE_POLL_MS: '10', REPLICATE_API_TOKEN: 'r8_suite', REPLICATE_API_URL: `${base}/v1`,
    REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated', HIGGSFIELD_API_URL: `${base}/hf`, HF_CREDENTIALS: 'hfid:hfsecret', ...extra });
  const reset = () => { hf.length = 0; rep.length = 0; quotes.length = 0; hfMode = 'ok'; repMode = 'ok'; };
  const run = async (a: Awaited<ReturnType<typeof makeApp>>, owner: any, body: Record<string, unknown>) => {
    const r = (await owner.req('POST', '/v1/suite/shots', body)).body;
    expect(r.id, JSON.stringify(r)).toBeTruthy();
    const j = await until(async () => { const x = (await owner.req('GET', `/v1/suite/shots/${r.id}`)).body.job; return x?.state === 'done' || x?.state === 'failed' ? x : null; }, 20_000);
    const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, r.id))).find(x => x.kind === 'settle');
    return { j, settle };
  };

  it('the pickers: Seedance 2.5 · Replicate and Seedance 2.5 · Higgsfield, each with its own resolutions; Higgsfield quoted live, else priced at Generate', async () => {
    reset(); rates = { 'bytedance/seedance-2.5/text-to-video@480p': 0.11, 'bytedance/seedance-2.5/text-to-video@1080p': 0.5 };
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const list = (await owner.req('GET', '/v1/engines?purpose=guide')).body.engines;
      const rows = list.filter((e: any) => e.model.startsWith('seedance-2.5'));
      expect(rows.map((e: any) => [e.model, e.label])).toEqual([['seedance-2.5', 'Seedance 2.5 · Replicate'], ['seedance-2.5-hf', 'Seedance 2.5 · Higgsfield']]);
      expect(rows[0].resolutions.map((r: any) => [r.id, r.perSec, r.provider])).toEqual([['480p', 0.1028, 'replicate'], ['720p', 0.2312, 'replicate']]);
      // 720p's quote didn't come back: priced at Generate (perSec 0, livePrice).
      expect(rows[1].resolutions.map((r: any) => [r.id, r.perSec, r.livePrice])).toEqual([['480p', 0.11, true], ['720p', 0, true], ['1080p', 0.5, true]]);
      const cat = (await owner.req('GET', '/v1/suite/catalog')).body.engines.filter((e: any) => e.model.startsWith('seedance-2.5'));
      expect(cat.map((e: any) => e.label)).toEqual(['Seedance 2.5 · Replicate', 'Seedance 2.5 · Higgsfield']);
    } finally { await a.close(); }
  });

  it('a directed 13 s shot at 480p on Seedance 2.5 · Higgsfield is quoted for its exact request (guide clip as a reference video), with no switching', async () => {
    reset(); rates = { 'bytedance/seedance-2.5/reference-to-video@480p': 0.2 };
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const body = { prompt: 'She walks to the window.', duration: 13, quality: 'cinema', audio: false, resolution: '480p',
        camera: { mode: 'directed', guide: { video: { url: 'https://example.com/g.mp4', seconds: 13 }, use: 'blocking' } } };
      const hfE = (await owner.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'seedance-2.5-hf' })).body;
      expect(hfE.engine).toMatchObject({ model: 'seedance-2.5-hf', provider: 'higgsfield', label: 'Seedance 2.5 · Higgsfield', resolution: '480p' });
      expect(hfE.engine.routes).toBeUndefined();
      expect(hfE.estimate).toBeCloseTo(2.6, 6);
      expect(quotes.at(-1)).toMatchObject({ url: 'bytedance/seedance-2.5/reference-to-video', body: { duration: 13, resolution: '480p' } });
      expect(quotes.at(-1)!.body.video_urls).toHaveLength(1);
      // The Replicate entry keeps its own price (video-reference rate) and is never swapped for the cheaper one.
      const repE = (await owner.req('POST', '/v1/suite/shots/estimate', { ...body, engineModel: 'seedance-2.5' })).body;
      expect(repE.engine).toMatchObject({ model: 'seedance-2.5', provider: 'replicate' });
      expect(repE.estimate).toBe(5.6); // the owner's $5.60 (13 s × $0.4304)
    } finally { await a.close(); }
  });

  it('Replicate out of credit at start: by default the shot fails, refunded, naming the other provider; opted in it runs there', async () => {
    reset(); rates = { 'bytedance/seedance-2.5/text-to-video@720p': 0.32 }; repMode = 'no_credit';
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const body = { prompt: 'Rain on a window.', engineModel: 'seedance-2.5', resolution: '720p', duration: 6, audio: false };
      const off = await run(a, owner, body);
      expect(off.j.state).toBe('failed');
      expect(off.j.error).toBe("Replicate is out of credit · you weren't charged · pick Seedance 2.5 · Higgsfield");
      expect(hf).toHaveLength(0);
      expect(off.settle?.amountUsd ?? 0).toBe(0);
      await owner.req('PATCH', '/v1/suite/settings', { providerFallback: true });
      reset(); repMode = 'no_credit';
      const on = await run(a, owner, body);
      expect(on.j.state, on.j.error).toBe('done');
      expect(hf.map(x => [x.url, x.input.resolution])).toEqual([['/bytedance/seedance-2.5/text-to-video', '720p']]);
      expect(on.settle!.amountUsd).toBeCloseTo(6 * 0.2312, 4); // the quoted price stands
    } finally { await a.close(); }
  });
});
