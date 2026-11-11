// AI suite · MiniMax H3 on Higgsfield (api.higgsfield.ai) against a FAKE Higgsfield + Replicate (no money).
// HD shots run on Higgsfield first (50% max-discount price + $0.08 per reference image beyond 5); out of credit / bad
// key at start moves the same shot to Replicate H3 2K; without HF_CREDENTIALS the Higgsfield model is skipped.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { ledger } from '../src/db/schema.js';
import { extraPerTake } from '../src/suite/plan.js';
import { DEFAULT_LADDER, modelById } from '../src/suite/registry.js';
import { demoModel, makeApp, people, until } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();

describe('Higgsfield H3 in the registry', () => {
  it('is first on the HD ladder, 2K only, 5–15 s, no keyframes (frame shots stay on Replicate H3)', () => {
    expect(DEFAULT_LADDER.hd[0]).toEqual({ model: 'h3-hf', resolution: '2K' });
    expect(DEFAULT_LADDER.hd[1]).toEqual({ model: 'h3', resolution: '2K' });
    const m = modelById('h3-hf')!;
    expect(m).toMatchObject({ provider: 'higgsfield', duration: { min: 5, max: 15 }, modes: { image: false }, refs: { images: 9, videos: 3, audios: 3 } });
    expect(m.resolutions.map(r => [r.id, r.perSec])).toEqual([['2K', 0.065]]);
  });
  it('charges $0.08 per reference image beyond the 5 included', () => {
    const m = modelById('h3-hf')!;
    expect(extraPerTake(m, 3)).toBe(0);
    expect(extraPerTake(m, 5)).toBe(0);
    expect(extraPerTake(m, 9)).toBeCloseTo(0.32, 9);
    expect(extraPerTake(modelById('h3')!, 9)).toBe(0);
  });
});

describe.skipIf(!hasFfmpeg)('AI suite · Higgsfield H3 against a FAKE Higgsfield + Replicate (no money)', () => {
  let server: http.Server, dir: string, base = '';
  const hf: { url: string; auth?: string; input: any }[] = [];
  const rep: { model: string; input: any }[] = [];
  let hfMode: 'ok' | 'no_credit' = 'ok';
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-hf-fake-'));
    const file = path.join(dir, 'out.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=288x512:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', file]);
    server = http.createServer((q, res) => {
      let body = '';
      q.on('data', c => (body += c));
      q.on('end', () => {
        const url = q.url ?? '';
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (url === '/out.mp4') { res.writeHead(200, { 'content-type': 'video/mp4' }); fs.createReadStream(file).pipe(res); return; }
        // Higgsfield
        if (url.startsWith('/hf/')) {
          if (q.headers.authorization !== 'Key hfid:hfsecret') return json(401, { detail: 'Invalid API credentials' });
          const sub = url.slice(3);
          if (q.method === 'POST' && sub.startsWith('/minimax/h3/')) {
            hf.push({ url: sub, auth: q.headers.authorization, input: JSON.parse(body) });
            if (hfMode === 'no_credit') return json(403, { detail: 'Not enough credits' });
            const id = `00000000-0000-0000-0000-00000000000${hf.length}`;
            return json(200, { status: 'queued', request_id: id, status_url: `${base}/hf/requests/${id}/status`, cancel_url: `${base}/hf/requests/${id}/cancel` });
          }
          if (/^\/requests\/[0-9a-f-]+\/status$/.test(sub)) return json(200, { status: 'completed', request_id: 'x', video: { url: `${base}/out.mp4` } });
          return json(404, {});
        }
        // Replicate
        if (q.headers.authorization !== 'Bearer r8_suite') return json(401, {});
        const m = /^\/v1\/models\/([^/]+\/[^/]+)\/predictions$/.exec(url);
        if (m && q.method === 'POST') { rep.push({ model: m[1]!, input: JSON.parse(body).input }); return json(201, { id: `p${rep.length}`, status: 'starting' }); }
        if (/^\/v1\/predictions\/p\d+$/.test(url)) return json(200, { id: 'p', status: 'succeeded', output: `${base}/out.mp4`, metrics: { video_output_duration_seconds: 6 } });
        json(404, {});
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(() => { server?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  const env = (extra: Record<string, string> = {}) => ({ SUITE_MODE: 'live', SUITE_POLL_MS: '10', REPLICATE_API_TOKEN: 'r8_suite', REPLICATE_API_URL: `${base}/v1`,
    REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated', HIGGSFIELD_API_URL: `${base}/hf`, ...extra });
  const shot = async (a: Awaited<ReturnType<typeof makeApp>>, owner: any) => {
    const m = await demoModel(owner);
    const r = (await owner.req('POST', '/v1/suite/shots', { modelId: m.id, prompt: 'She turns to the camera.', duration: 6, quality: 'hd', camera: { preset: 'talking_head' } })).body;
    expect(r.id).toBeTruthy();
    const j = await until(async () => { const x = (await owner.req('GET', `/v1/suite/shots/${r.id}`)).body.job; return x?.state === 'done' || x?.state === 'failed' ? x : null; }, 20_000);
    const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, r.id))).find(x => x.kind === 'settle');
    return { j, settle };
  };

  it('HD runs on Higgsfield with the key, 2K, the shot aspect, no watermark, and settles at the discounted price', async () => {
    hf.length = 0; rep.length = 0; hfMode = 'ok';
    const a = await makeApp(env({ HF_CREDENTIALS: 'hfid:hfsecret' }));
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const { j, settle } = await shot(a, owner);
      expect(j.state).toBe('done');
      expect(rep).toHaveLength(0);
      expect(hf).toHaveLength(1);
      expect(hf[0]!.url).toBe('/minimax/h3/reference-to-video');
      expect(hf[0]!.input).toMatchObject({ duration: 6, resolution: '2K', aspect_ratio: '9:16', aigc_watermark: false });
      const n = hf[0]!.input.image_urls.length;
      expect(n).toBeGreaterThan(0);
      expect(settle!.amountUsd).toBeCloseTo(0.065 * 6 + 0.08 * Math.max(0, n - 5), 6);
    } finally { await a.close(); }
  });

  it('out of credit at start: the same shot runs on Replicate H3 2K and later shots skip Higgsfield', async () => {
    hf.length = 0; rep.length = 0; hfMode = 'no_credit';
    const a = await makeApp(env({ HF_CREDENTIALS: 'hfid:hfsecret' }));
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const first = await shot(a, owner);
      expect(first.j.state).toBe('done');
      expect(hf).toHaveLength(1);
      expect(rep).toHaveLength(1);
      expect(rep[0]).toMatchObject({ model: 'minimax/h3', input: { resolution: '2K' } });
      const second = await shot(a, owner);
      expect(second.j.state).toBe('done');
      expect(hf).toHaveLength(1); // skipped while marked down
      expect(rep).toHaveLength(2);
    } finally { await a.close(); }
  });

  /** A real 3.2 s clip in storage (a Character swap source). */
  const clipOf = async (a: Awaited<ReturnType<typeof makeApp>>, owner: any) => {
    const src = path.join(dir, 'swap-src.mp4');
    if (!fs.existsSync(src)) execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=360x640:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=330', '-t', '3.2',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', src]);
    const b = '----musehf', meta = JSON.stringify({ name: 'dance', durationSec: 3.2, width: 1080, height: 1920, fps: 30 });
    const payload = Buffer.concat([Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="meta"\r\n\r\n${meta}\r\n`),
      Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="dance.mp4"\r\nContent-Type: video/mp4\r\n\r\n`), fs.readFileSync(src), Buffer.from(`\r\n--${b}--\r\n`)]);
    const r = await a.app.inject({ method: 'POST', url: '/v1/uploads/clips', headers: { authorization: `Bearer ${owner.token}`, 'content-type': `multipart/form-data; boundary=${b}` }, payload });
    expect(r.statusCode).toBe(200);
    return JSON.parse(r.body).id as string;
  };
  const swap = async (a: Awaited<ReturnType<typeof makeApp>>, owner: any) => {
    const m = await demoModel(owner), clipId = await clipOf(a, owner);
    const r = await owner.req('POST', '/v1/jobs', { modelId: m.id, clipId, engineModel: 'h3-hf', quality: 'hd' });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const j = await until(async () => { const x = (await owner.req('GET', '/v1/jobs')).body.find((y: any) => y.id === r.body.id); return x && ['done', 'failed'].includes(x.state) ? x : null; }, 30_000);
    return { req: r.body.request, j };
  };

  it('Character swap: MiniMax H3 · Higgsfield is offered only with the key, at $0.065/s 2K, 5–15 s', async () => {
    for (const [creds, offered] of [[true, true], [false, false]] as const) {
      const a = await makeApp(env(creds ? { HF_CREDENTIALS: 'hfid:hfsecret' } : {}));
      const { owner } = await people(a, 0, { topUp: 100 });
      try {
        const list = (await owner.req('GET', '/v1/engines?purpose=swap')).body;
        const hfRow = (list.engines ?? list).find((e: any) => e.model === 'h3-hf');
        if (!offered) { expect(hfRow).toBeUndefined(); continue; }
        expect(hfRow).toMatchObject({ name: 'MiniMax H3', label: 'MiniMax H3 · Higgsfield', providerName: 'Higgsfield', resolution: '2K', price: { basis: 'per_second', usd: 0.065 } });
        expect(hfRow.purposes).toContain('swap');
        expect(hfRow.limits).toMatchObject({ minSeconds: 5, maxInputSeconds: 15 });
      } finally { await a.close(); }
    }
  });

  it('labels: the same H3 on Replicate and on Higgsfield never look the same (owner, members, provider names off)', async () => {
    const a = await makeApp(env({ HF_CREDENTIALS: 'hfid:hfsecret' }));
    const { owner, members: [member] } = await people(a, 1, { topUp: 100 });
    try {
      const h3s = (l: any[]) => l.filter((e: any) => e.model === 'h3' || e.model === 'h3-hf').sort((x: any, y: any) => x.model.localeCompare(y.model));
      const unique = (l: any[]) => expect(new Set(l.map((e: any) => e.label)).size).toBe(l.length);
      for (const who of [owner, member!]) {
        const eng = (await who.req('GET', '/v1/engines?purpose=swap')).body.engines;
        expect(h3s(eng).map((e: any) => e.label)).toEqual(['MiniMax H3 · Replicate', 'MiniMax H3 · Higgsfield']);
        unique(eng);
        for (const e of eng) expect(e.label).toBe(`${e.name} · ${e.providerName}`);
        const cat = (await who.req('GET', '/v1/suite/catalog')).body.engines;
        expect(h3s(cat).map((e: any) => [e.name, e.label, e.providerName])).toEqual([['MiniMax H3', 'MiniMax H3 · Replicate', 'Replicate'], ['MiniMax H3', 'MiniMax H3 · Higgsfield', 'Higgsfield']]);
        unique(cat);
      }
      // 4c switch off: members get no provider, and the two H3s become "Option 1" and "Option 2", never the same bare name.
      await owner.req('PATCH', '/v1/engines/members', { showProviderNames: false });
      const eng = (await member!.req('GET', '/v1/engines?purpose=swap')).body.engines;
      expect(h3s(eng).map((e: any) => e.label)).toEqual(['MiniMax H3 · Option 1', 'MiniMax H3 · Option 2']);
      unique(eng);
      expect(JSON.stringify(eng)).not.toMatch(/Higgsfield|Replicate|"provider(Name)?"/);
      const cat = (await member!.req('GET', '/v1/suite/catalog')).body.engines;
      unique(cat);
      expect(h3s(cat).map((e: any) => e.name)).toEqual(['MiniMax H3 · Option 1', 'MiniMax H3 · Option 2']);
      expect(JSON.stringify(cat)).not.toMatch(/Higgsfield|Replicate|"provider(Name)?"/);
      // The owner always sees providers.
      expect(h3s((await owner.req('GET', '/v1/engines?purpose=swap')).body.engines).map((e: any) => e.label)).toEqual(['MiniMax H3 · Replicate', 'MiniMax H3 · Higgsfield']);
    } finally { await a.close(); }
  });

  it('Character swap on Higgsfield: the clip is the reference video, 2K, padded to 5 s, settled at $0.065/s (+$0.08 per image beyond 5)', async () => {
    hf.length = 0; rep.length = 0; hfMode = 'ok';
    const a = await makeApp(env({ HF_CREDENTIALS: 'hfid:hfsecret' }));
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const { req, j } = await swap(a, owner);
      expect(req).toMatchObject({ engine: 'replicate', swapEngine: 'h3-hf', videoModel: 'minimax/h3/reference-to-video', pricePerSec: 0.065 });
      expect(j.state, j.error).toBe('done');
      expect(rep).toHaveLength(0);
      expect(hf).toHaveLength(1);
      expect(hf[0]!.url).toBe('/minimax/h3/reference-to-video');
      expect(hf[0]!.input).toMatchObject({ duration: 5, resolution: '2K', aspect_ratio: '9:16', aigc_watermark: false });
      expect(hf[0]!.input.video_urls).toHaveLength(1);
      expect(hf[0]!.input.prompt).toContain('<Video 1>');
      const n = hf[0]!.input.image_urls.length;
      expect(n).toBeGreaterThan(0);
      const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id))).find(x => x.kind === 'settle');
      expect(settle!.amountUsd).toBeCloseTo(0.065 * 5 + 0.08 * Math.max(0, n - 5), 6);
    } finally { await a.close(); }
  });

  it('Character swap: Higgsfield out of credit at the start → the swap runs on Replicate H3 2K', async () => {
    hf.length = 0; rep.length = 0; hfMode = 'no_credit';
    const a = await makeApp(env({ HF_CREDENTIALS: 'hfid:hfsecret' }));
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const { j } = await swap(a, owner);
      expect(j.state, j.error).toBe('done');
      expect(hf).toHaveLength(1);
      expect(rep).toHaveLength(1);
      expect(rep[0]).toMatchObject({ model: 'minimax/h3', input: { resolution: '2K', ratio: '9:16' } });
      expect(rep[0]!.input.reference_video_urls).toHaveLength(1);
    } finally { await a.close(); }
  });

  it('without HF_CREDENTIALS the Higgsfield model is skipped and HD runs on Replicate H3 2K', async () => {
    hf.length = 0; rep.length = 0; hfMode = 'ok';
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const { j } = await shot(a, owner);
      expect(j.state).toBe('done');
      expect(hf).toHaveLength(0);
      expect(rep[0]).toMatchObject({ model: 'minimax/h3', input: { resolution: '2K' } });
    } finally { await a.close(); }
  });
});
