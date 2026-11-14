// One model, several providers (owner 2026-11-14: "I should have options. Right now I'm tied to using a certain model for
// a certain quality"). A model's resolutions are the union of its provider routes; each runs on the cheapest route that
// makes it; a route that refuses at start hands the shot to another at the same resolution. Pure planning first, then a
// FAKE Higgsfield (free /estimate quotes, runs) + FAKE Replicate: no money, no real generation.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { ledger } from '../src/db/schema.js';
import { buildInput } from '../src/suite/inputs.js';
import { buildPlan, needOf, pickAdapted, pickModel, ShotRequestSchema, type Character } from '../src/suite/plan.js';
import { familyOf, isRoute, MODELS, modelById, publicModels, refFor, routesOf, type ProviderId } from '../src/suite/registry.js';
import { fallbackRoute, familySpec, routesAt, unionResolutions } from '../src/suite/routes.js';
import { pickExtend } from '../src/suite/extend.js';
import { resolutionFit } from '../src/engines/service.js';
import { demoModel, makeApp, people, until } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const ALL = new Set<ProviderId>(['replicate', 'fal', 'higgsfield', 'mock']);
const REP = new Set<ProviderId>(['replicate', 'fal', 'mock']);
const CHAR: Character = { name: 'Mia', look: 'young woman, dark hair', neverAdd: [],
  images: [{ label: 'face, front', image: { asset: 'face' } }, { label: 'face, profile', image: { asset: 'profile' } }], outfit: null };
const req = (o: Record<string, unknown> = {}) => ShotRequestSchema.parse({ prompt: 'She walks to the window.', ...o });
const U = { start: 'https://x/s.png', end: 'https://x/e.png', middle: [], refs: ['https://x/1.png', 'https://x/2.png'], videos: ['https://x/v.mp4'], audio: 'https://x/a.wav' };

describe('the registry: one entry per model, the union of its providers', () => {
  it('routes belong to a family and are never listed on their own; old ids still resolve', () => {
    const routes = MODELS.filter(isRoute).map(m => [m.id, m.family]);
    expect(routes).toEqual([['h3-hf', 'h3'], ['seedance-2.5-hf', 'seedance-2.5'], ['seedance-2.0-hf', 'seedance-2.0'], ['kling-v3-omni-hf', 'kling-v3-omni'], ['wan-2.7-hf', 'wan-2.7']]);
    const listed = publicModels().map(m => m.id);
    for (const [id, fam] of routes) { expect(listed).not.toContain(id); expect(listed).toContain(fam); expect(familyOf(id!)).toBe(fam); }
    expect(listed).toContain('kling-v3'); // new: Kling 3.0 (std / pro / 4K) on Higgsfield
    expect(modelById('h3-hf')).toBeDefined();
    expect(routesOf('h3-hf').map(m => m.id)).toEqual(['h3', 'h3-hf']);
    // Every route reads the same prompt as its head (reference words), so a shot can move between them at start.
    for (const m of MODELS.filter(isRoute)) expect(m.camera.refStyle).toBe(modelById(m.family!)!.camera.refStyle);
  });

  it('resolutions are the union across providers, each on its cheapest route', () => {
    const u = (id: string, ok: Set<ProviderId> = ALL) => unionResolutions(id, m => ok.has(m.provider)).map(r => [r.id, r.provider, r.rate]);
    expect(u('seedance-2.5')).toEqual([['480p', 'replicate', 0.1028], ['720p', 'replicate', 0.2312], ['1080p', 'higgsfield', null]]);
    expect(u('seedance-2.5', REP)).toEqual([['480p', 'replicate', 0.1028], ['720p', 'replicate', 0.2312]]);
    expect(u('seedance-2.0')).toEqual([['480p', 'replicate', 0.08], ['720p', 'replicate', 0.18], ['1080p', 'replicate', 0.45], ['4k', 'replicate', 1]]);
    expect(u('h3')).toEqual([['768P', 'replicate', 0.08], ['2K', 'higgsfield', 0.065]]);
    expect(u('kling-v3-omni').map(r => r[0])).toEqual(['720p', '1080p', '4k']);
    expect(u('kling-v3')).toEqual([['720p', 'higgsfield', null], ['1080p', 'higgsfield', null], ['4k', 'higgsfield', null]]);
    expect(u('wan-2.7')).toEqual([['720p', 'replicate', 0.1], ['1080p', 'replicate', 0.1]]);
    // A live quote cheaper than Replicate's rate wins that resolution.
    const quoted = unionResolutions('seedance-2.0', () => true, (m, r) => (m.livePrice ? (r === '4k' ? 0.8 : null) : m.resolutions.find(x => x.id === r)!.perSec));
    expect(quoted.find(r => r.id === '4k')).toMatchObject({ provider: 'higgsfield', rate: 0.8 });
  });

  it('the family as one model: the union of modes, frames, references, lengths and shapes', () => {
    const s = familySpec('h3')!;
    expect(s.resolutions.map(r => r.id)).toEqual(['768P', '2K']);
    expect(s.duration).toMatchObject({ min: 4, max: 15 });
    const k = familySpec('seedance-2.5', m => m.provider === 'higgsfield')!;
    expect(k.resolutions.map(r => r.id)).toEqual(['480p', '720p', '1080p']);
    expect(familySpec('seedance-2.5', () => false)).toBeUndefined();
  });

  it('kling 3.0 picks its std / pro / 4k endpoint by resolution; Higgsfield routes map their request fields from catalog.json', () => {
    const k3 = modelById('kling-v3')!;
    expect(['720p', '1080p', '4k'].map(r => refFor(k3, 't2v', r))).toEqual(['kling-video/v3.0/std/text-to-video', 'kling-video/v3.0/pro/text-to-video', 'kling-video/v3.0/4k/text-to-video']);
    expect(refFor(k3, 'i2v', '4k')).toBe('kling-video/v3.0/4k/image-to-video');
    const plan = (id: string, kind: 't2v' | 'i2v' | 'ref2v', resolution: string, o: Record<string, unknown> = {}) =>
      ({ prompt: 'p', seconds: 6.4, resolution, aspect: '9:16', audio: true, kind, mode: kind === 'i2v' ? 'image' : kind === 'ref2v' ? 'reference' : 'text', params: {}, seed: 7, negative: 'blur', ...o }) as any;
    expect(buildInput(k3, plan('kling-v3', 'i2v', '4k'), U)).toEqual({ prompt: 'p', duration: 6, sound: 'on', image_url: U.start, last_image_url: U.end });
    expect(buildInput(modelById('kling-v3-omni-hf')!, plan('', 'ref2v', '720p'), U)).toEqual({ prompt: 'p', duration: 6, mode: 'std', sound: 'on', aspect_ratio: '9:16', image_urls: U.refs });
    expect(buildInput(modelById('kling-v3-omni-hf')!, plan('', 'i2v', '4k'), U)).toMatchObject({ mode: '4k', first_frame_url: U.start, last_frame_url: U.end });
    expect(buildInput(modelById('seedance-2.5-hf')!, plan('', 'i2v', '1080p'), U)).toEqual({ prompt: 'p', duration: 6, resolution: '1080p', generate_audio: true, image_url: U.start, end_image_url: U.end });
    expect(buildInput(modelById('seedance-2.5-hf')!, plan('', 'ref2v', '1080p'), U)).toEqual({ prompt: 'p', duration: 6, resolution: '1080p', generate_audio: true, aspect_ratio: '9:16',
      image_urls: U.refs, video_urls: U.videos, audio_urls: [U.audio] });
    expect(buildInput(modelById('seedance-2.0-hf')!, plan('', 't2v', '4k'), U)).toEqual({ prompt: 'p', duration: 6, resolution: '4k', generate_audio: true, aspect_ratio: '9:16' });
    expect(buildInput(modelById('wan-2.7-hf')!, plan('', 'ref2v', '1080p', { seconds: 14 }), U)).toEqual({ prompt: 'p', duration: 10, resolution: '1080p', negative_prompt: 'blur', seed: 7,
      aspect_ratio: '9:16', image_urls: U.refs, video_urls: U.videos });
    expect(buildInput(modelById('h3-hf')!, plan('', 'i2v', '2K', { seconds: 6 }), U)).toEqual({ prompt: 'p', duration: 6, resolution: '2K', aigc_watermark: false, image_url: U.start, end_image_url: U.end, aspect_ratio: 'adaptive' });
  });
});

describe('routing: a resolution runs on the cheapest provider that makes it, and never forces another model', () => {
  const pick = (id: string, res: string, r = req(), ok = ALL) => {
    const p = pickModel('hd', needOf(r, null), { providers: ok, engineModel: id, resolution: res });
    if ('error' in p) throw new Error(JSON.stringify(p.tried));
    return p;
  };
  it('Seedance 2.5: 480p/720p on Replicate (known price, Higgsfield priced live is the alternate); 1080p on Higgsfield', () => {
    const p720 = pick('seedance-2.5', '720p');
    expect([p720.model.id, p720.alternates!.map(m => m.id)]).toEqual(['seedance-2.5', ['seedance-2.5-hf']]);
    const p1080 = pick('seedance-2.5', '1080p');
    expect([p1080.model.id, p1080.resolution.id, p1080.alternates]).toEqual(['seedance-2.5-hf', '1080p', []]);
    const plan = buildPlan(req(), needOf(req(), null), p1080, null, {});
    expect([plan.provider, plan.ref, plan.resolution]).toEqual(['higgsfield', 'bytedance/seedance-2.5/text-to-video', '1080p']);
  });
  it('MiniMax H3: 2K on Higgsfield (cheaper), 768P on Replicate; the old id h3-hf is the same model', () => {
    expect(pick('h3', '2K').model.id).toBe('h3-hf');
    expect(pick('h3', '2K').alternates!.map(m => m.id)).toEqual(['h3']);
    expect(pick('h3-hf', '2K').model.id).toBe('h3-hf');
    expect(pick('h3', '768P').model.id).toBe('h3');
    expect(pick('h3-hf', '768P').model.id).toBe('h3'); // a resolution only Replicate makes
    expect(pick('h3', '2K', req(), REP).model.id).toBe('h3'); // no Higgsfield key: Replicate's 2K
  });
  it('a resolution the model makes on no set-up provider moves to the nearest it makes, with a note (never another model)', () => {
    const a = pickAdapted('hd', req(), null, { providers: REP, engineModel: 'seedance-2.5', resolution: '1080p' });
    if ('error' in a) throw new Error(JSON.stringify(a.refusals));
    expect([a.pick.model.id, a.pick.resolution.id]).toEqual(['seedance-2.5', '720p']);
    expect(a.adapted.notes.join(' ')).toMatch(/made at 720p \(Seedance 2\.5 · Replicate makes 480p, 720p\)/);
  });
  it('a shot a route can\'t take stays on the route that can (reference video on Kling 3.0 Omni; an end frame alone on H3)', () => {
    const vid = req({ references: { videos: [{ video: { key: 'v.mp4', seconds: 5 }, use: 'motion' }] } });
    expect(pick('kling-v3-omni', '1080p', vid).model.id).toBe('kling-v3-omni');
    expect(pick('kling-v3-omni', '1080p', vid).alternates).toEqual([]);
    const end = req({ frames: { end: { url: 'https://x/e.png' } } });
    expect(pick('h3', '2K', end).model.id).toBe('h3');
  });
  it('resolutionFit: every model stays listed; one without the resolution says what it makes and what picking it uses', () => {
    const e = { kind: 'video', limits: { resolutions: [] }, resolutions: [{ id: '480p', label: '480p', perSec: 0.1 }, { id: '720p', label: '720p', perSec: 0.2 }] } as any;
    expect(resolutionFit(e, '720p')).toEqual({ asked: '720p', has: true, resolution: '720p', note: null });
    expect(resolutionFit(e, '4k')).toEqual({ asked: '4k', has: false, resolution: '720p', note: 'Makes 480p, 720p · picking it uses 720p' });
    expect(resolutionFit({ ...e, kind: 'image' }, '4k')).toBeUndefined();
  });
});

describe('Extend: a resolution runs on the route that makes it', () => {
  it('Seedance 2.5 at 1080p continues on Higgsfield (the clip as a reference video); 720p stays on Replicate', () => {
    const n = { direction: 'after' as const, sourceSeconds: 6, seconds: 5, aspect: '9:16' };
    const p = pickExtend('hd', n, { providers: ALL, engineModel: 'seedance-2.5', resolution: '1080p' });
    expect('model' in p && [p.model.id, p.method, p.resolution.id]).toEqual(['seedance-2.5-hf', 'reference', '1080p']);
    const q = pickExtend('hd', n, { providers: ALL, engineModel: 'seedance-2.5', resolution: '720p' });
    expect('model' in q && q.model.id).toBe('seedance-2.5');
    const r = pickExtend('hd', n, { providers: REP, engineModel: 'seedance-2.5', resolution: '1080p' });
    expect(r).toMatchObject({ error: 'nothing_fits' });
  });
});

describe('fallback at start: the other provider at the same resolution', () => {
  const plan = (o: Record<string, unknown> = {}) => ({ resolution: '720p', kind: 't2v', images: { middle: [], refs: [] }, videos: [], ...o }) as any;
  it('goes to another route that makes the resolution and takes the inputs; none → null', () => {
    const ok = () => true;
    expect(fallbackRoute(modelById('seedance-2.5')!, plan(), ok)?.id).toBe('seedance-2.5-hf');
    expect(fallbackRoute(modelById('seedance-2.5-hf')!, plan(), ok)?.id).toBe('seedance-2.5');
    expect(fallbackRoute(modelById('seedance-2.5-hf')!, plan({ resolution: '1080p' }), ok)).toBeNull(); // only Higgsfield makes 1080p
    expect(fallbackRoute(modelById('h3-hf')!, plan({ resolution: '2K', kind: 'ref2v', images: { middle: [], refs: [1, 2, 3] } }), ok)?.id).toBe('h3');
    expect(fallbackRoute(modelById('h3')!, plan({ resolution: '2K', kind: 'i2v', images: { middle: [], refs: [], end: {} } }), ok)).toBeNull(); // end frame alone: Higgsfield can't
    expect(fallbackRoute(modelById('kling-v3-omni')!, plan({ resolution: '1080p', kind: 'ref2v', videos: [{}] }), ok)).toBeNull(); // no reference video there
    expect(fallbackRoute(modelById('seedance-2.5')!, plan(), m => m.provider !== 'higgsfield')).toBeNull(); // not set up
    expect(fallbackRoute(modelById('kling-v4')!, plan(), ok)).toBeNull(); // one provider
  });
  it('cheapest known first', () => {
    expect(routesAt('h3', '2K').map(m => m.id)).toEqual(['h3-hf', 'h3']);
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

  it('the pickers: one Seedance 2.5 with 480p/720p on Replicate and 1080p on Higgsfield at its quoted rate; members hide providers', async () => {
    reset(); rates = { 'bytedance/seedance-2.5/text-to-video@1080p': 0.5, 'bytedance/seedance-2.5/text-to-video@720p': 0.32 };
    const a = await makeApp(env());
    const { owner, members: [member] } = await people(a, 1, { topUp: 100 });
    try {
      const shot = (await owner.req('GET', '/v1/engines?purpose=shot&resolution=1080p')).body.engines;
      const sd = shot.find((e: any) => e.model === 'seedance-2.5');
      expect(shot.filter((e: any) => e.model.startsWith('seedance-2.5'))).toHaveLength(1);
      expect(sd).toMatchObject({ label: 'Seedance 2.5 · Replicate + Higgsfield', resolutionFit: { asked: '1080p', has: true, resolution: '1080p', note: null } });
      expect(sd.resolutions.map((r: any) => [r.id, r.provider, r.perSec])).toEqual([['480p', 'replicate', 0.1028], ['720p', 'replicate', 0.2312], ['1080p', 'higgsfield', 0.5]]);
      // A model without 1080p stays listed and says what it makes.
      expect(shot.find((e: any) => e.model === 'h3-lite').resolutionFit).toMatchObject({ has: false, resolution: '768P', note: 'Makes 480P, 768P · picking it uses 768P' });
      const cat = (await owner.req('GET', '/v1/suite/catalog')).body.engines.find((e: any) => e.model === 'seedance-2.5');
      expect(cat.resolutions.map((r: any) => [r.id, r.modelLabel])).toEqual([['480p', 'Seedance 2.5 · Replicate'], ['720p', 'Seedance 2.5 · Replicate'], ['1080p', 'Seedance 2.5 · Higgsfield']]);
      await owner.req('PATCH', '/v1/engines/members', { showProviderNames: false });
      const mem = (await member!.req('GET', '/v1/suite/catalog')).body.engines.find((e: any) => e.model === 'seedance-2.5');
      expect(mem.resolutions.map((r: any) => r.id)).toEqual(['480p', '720p', '1080p']);
      expect(JSON.stringify(mem)).not.toMatch(/Higgsfield|Replicate|"provider/);
    } finally { await a.close(); }
  });

  it('the estimate runs the cheapest route for the exact shot: Replicate at 720p, Higgsfield when its quote is lower, Higgsfield at 1080p', async () => {
    reset(); rates = { 'bytedance/seedance-2.5/text-to-video@720p': 0.32, 'bytedance/seedance-2.5/text-to-video@1080p': 0.5 };
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const est = (o: Record<string, unknown>) => owner.req('POST', '/v1/suite/shots/estimate', { prompt: 'Rain on a window.', engineModel: 'seedance-2.5', duration: 6, audio: false, ...o });
      const e720 = (await est({ resolution: '720p' })).body;
      expect(e720.engine).toMatchObject({ model: 'seedance-2.5', family: 'seedance-2.5', provider: 'replicate', label: 'Seedance 2.5 · Replicate', resolution: '720p' });
      expect(e720.estimate).toBeCloseTo(6 * 0.2312, 2);
      expect(e720.engine.routes).toEqual([{ model: 'seedance-2.5', provider: 'replicate', estimate: 1.3872, providerName: 'Replicate', chosen: true },
        { model: 'seedance-2.5-hf', provider: 'higgsfield', estimate: 1.92, providerName: 'Higgsfield', chosen: false }]);
      expect(quotes.at(-1)).toMatchObject({ url: 'bytedance/seedance-2.5/text-to-video', body: { duration: 6, resolution: '720p', aspect_ratio: '9:16', generate_audio: false } });
      rates['bytedance/seedance-2.5/text-to-video@720p'] = 0.2; // Higgsfield now quotes less: it runs there
      const cheaper = (await est({ resolution: '720p', duration: 7 })).body;
      expect(cheaper.engine).toMatchObject({ model: 'seedance-2.5-hf', provider: 'higgsfield', label: 'Seedance 2.5 · Higgsfield' });
      expect(cheaper.estimate).toBeCloseTo(1.4, 6);
      const e1080 = (await est({ resolution: '1080p' })).body;
      expect(e1080.engine).toMatchObject({ model: 'seedance-2.5-hf', provider: 'higgsfield', resolution: '1080p', ref: 'bytedance/seedance-2.5/text-to-video' });
      expect(e1080.estimate).toBeCloseTo(3, 6);
      expect(e1080.engine.routes).toBeUndefined(); // only Higgsfield makes 1080p
      // No quote, no run (the price would be a guess).
      delete rates['bytedance/seedance-2.5/text-to-video@1080p'];
      expect((await est({ resolution: '1080p', duration: 8 })).body).toMatchObject({ code: 'price_unavailable' });
      // MiniMax H3 2K: Higgsfield's known plan rate beats Replicate's; the old id still works.
      const h = (await owner.req('POST', '/v1/suite/shots/estimate', { prompt: 'Rain.', engineModel: 'h3-hf', resolution: '2K', duration: 6 })).body;
      expect(h.engine).toMatchObject({ model: 'h3-hf', family: 'h3', provider: 'higgsfield' });
      expect(h.engine.routes.map((x: any) => [x.model, x.estimate])).toEqual([['h3-hf', 0.39], ['h3', 0.78]]);
    } finally { await a.close(); }
  });

  it('runs on the chosen route and settles its quoted price; Replicate out of credit at start → the same shot on Higgsfield at the same resolution', async () => {
    reset(); rates = { 'bytedance/seedance-2.5/text-to-video@720p': 0.32, 'bytedance/seedance-2.5/text-to-video@1080p': 0.5 };
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const body = { prompt: 'Rain on a window.', engineModel: 'seedance-2.5', duration: 6, audio: false };
      const hi = await run(a, owner, { ...body, resolution: '1080p' });
      expect(hi.j.state, hi.j.error).toBe('done');
      expect(hf.map(x => x.url)).toEqual(['/bytedance/seedance-2.5/text-to-video']);
      expect(hf[0]!.input).toMatchObject({ duration: 6, resolution: '1080p', aspect_ratio: '9:16', generate_audio: false });
      expect(rep).toHaveLength(0);
      expect(hi.settle!.amountUsd).toBeCloseTo(3, 6);
      reset(); repMode = 'no_credit';
      const moved = await run(a, owner, { ...body, resolution: '720p' });
      expect(moved.j.state, moved.j.error).toBe('done');
      expect(rep.map(x => x.model)).toEqual(['bytedance/seedance-2.5']);
      expect(hf.map(x => [x.url, x.input.resolution])).toEqual([['/bytedance/seedance-2.5/text-to-video', '720p']]);
      expect(moved.settle!.amountUsd).toBeCloseTo(6 * 0.2312, 4); // the quoted price stands
    } finally { await a.close(); }
  });

  it('Character swap: MiniMax H3 at HD runs on Higgsfield; a studio default of the old id h3-hf still resolves', async () => {
    reset();
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const est = (await owner.req('GET', '/v1/engines/defaults')).body;
      expect(est.defaults.swap).toBeNull();
      expect((await owner.req('PATCH', '/v1/engines/defaults', { swap: 'h3-hf' })).status).toBe(200);
      const l = (await owner.req('GET', '/v1/engines?purpose=swap')).body;
      expect(l.default).toBe('h3');
      const mc = (await import('../src/engines/service.js')).modelChoice(a.ctx);
      expect(mc.swapRoute('h3', 'hd', {})).toBe('h3-hf');
      expect(mc.swapRoute('h3', 'standard', {})).toBe('h3');
      expect(mc.swapRoute('h3', 'hd', {}, 3)).toBe('h3'); // shorter than Higgsfield's 5 s minimum
      expect(mc.swapRoute('h3', 'hd', { models: { 'h3-hf': { enabled: false } } })).toBe('h3');
      const studioId = (await a.ctx.db.select().from((await import('../src/db/schema.js')).users)).find(x => x.id === owner.id)!.studioId;
      expect(await mc.swapQuote(studioId, 'h3', 'hd', 10)).toMatchObject({ resolution: '2K', perSec: 0.065 });
      expect(await mc.swapQuote(studioId, 'h3', 'standard', 10)).toMatchObject({ resolution: '768P', perSec: 0.08 });
    } finally { await a.close(); }
  });
});
