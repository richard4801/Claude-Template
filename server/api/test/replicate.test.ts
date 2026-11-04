// Replicate engines against a FAKE Replicate server on localhost (no real predictions, no money): the video line
// (start, 429 backoff, pad → render → trim + audio → storage, settle on billed seconds, failure and safety refusal
// refunds, cancel) and the photo provider (FLUX.2 shots, Qwen edits, refusals, rate limits).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import sharp from 'sharp';
import { generatedImages, jobs, ledger, studioSettings } from '../src/db/schema.js';
import { loadConfig } from '../src/config.js';
import * as P from '../src/pricing.js';
import { replicateSwap, imageRange } from '../src/prompt/engine.js';
import { rateHintSeconds } from '../src/replicate/client.js';
import { makeApp, people, sienna, until, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const TOKEN = 'r8_test_token';

type Pred = { id: string; model: string; input: any; polls: number; status: string; output?: unknown; error?: string; billed?: number; cancelled?: boolean };
type Plan = { status?: 'succeeded' | 'failed'; error?: string; billed?: number; pollsBeforeDone?: number; holdUntilCancelled?: boolean; metrics?: Record<string, number> };

/** A tiny stand-in for api.replicate.com: scripted 429s, predictions that finish after a few polls, output files. */
async function fakeReplicate(dir: string) {
  const preds = new Map<string, Pred>();
  const state = { creates: [] as Pred[], rateLimits: [] as string[], plans: [] as Plan[], unauthorized: 0, cancels: [] as string[], videoSize: '288x512', noCredit: 0 };
  let n = 0;
  const videos = new Map<number, string>();
  const videoOf = (seconds: number) => {
    if (!videos.has(seconds)) {
      const f = path.join(dir, `out_${seconds}.mp4`);
      execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', `testsrc=size=${state.videoSize}:rate=25`, '-f', 'lavfi', '-i', 'sine=frequency=440',
        '-t', String(seconds), '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', f]);
      videos.set(seconds, f);
    }
    return videos.get(seconds)!;
  };
  const jpeg = await sharp({ create: { width: 64, height: 96, channels: 3, background: '#c08060' } }).jpeg().toBuffer();
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', c => (body += c));
    req.on('end', () => {
      const url = req.url ?? '';
      const json = (status: number, o: unknown) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
      if (url.startsWith('/files/')) {
        const name = url.slice(7);
        if (name.endsWith('.jpg')) { res.writeHead(200, { 'content-type': 'image/jpeg' }); res.end(jpeg); return; }
        const p = preds.get(name.replace(/\.mp4$/, ''))!;
        res.writeHead(200, { 'content-type': 'video/mp4' }); fs.createReadStream(videoOf(p.input.duration)).pipe(res); return;
      }
      if (req.headers.authorization !== `Bearer ${TOKEN}`) { state.unauthorized++; return json(401, { detail: 'Unauthenticated' }); }
      const create = /^\/v1\/models\/([^/]+\/[^/]+)\/predictions$/.exec(url);
      if (create && req.method === 'POST') {
        const limit = state.rateLimits.shift();
        if (limit) return json(429, { detail: limit, status: 429 });
        if (state.noCredit > 0) { state.noCredit--; return json(402, { detail: 'You have insufficient credit to run this model. Go to https://replicate.com/account/billing to purchase credit.', status: 402 }); }
        const plan = state.plans.shift() ?? {};
        const p: Pred = { id: `p${++n}`, model: create[1]!, input: JSON.parse(body).input, polls: 0, status: 'starting', error: plan.error, billed: plan.billed };
        (p as any).plan = plan;
        preds.set(p.id, p); state.creates.push(p);
        return json(201, { id: p.id, status: 'starting' });
      }
      const cancel = /^\/v1\/predictions\/([^/]+)\/cancel$/.exec(url);
      if (cancel) { const p = preds.get(cancel[1]!); if (p) { p.status = 'canceled'; p.cancelled = true; } state.cancels.push(cancel[1]!); return json(200, p ?? {}); }
      const get = /^\/v1\/predictions\/([^/]+)$/.exec(url);
      if (get) {
        const p = preds.get(get[1]!);
        if (!p) return json(404, { detail: 'Not found' });
        const plan = (p as any).plan as Plan;
        p.polls++;
        if (p.status === 'canceled') return json(200, { id: p.id, status: 'canceled' });
        if (plan.holdUntilCancelled || p.polls <= (plan.pollsBeforeDone ?? 2)) return json(200, { id: p.id, status: 'processing' });
        const base = `http://127.0.0.1:${(server.address() as any).port}/files/${p.id}`;
        if (plan.status === 'failed') return json(200, { id: p.id, status: 'failed', error: plan.error ?? 'boom' });
        const video = p.model.startsWith('minimax/');
        const output = video ? `${base}.mp4` : p.model.startsWith('qwen/') ? [`${base}.jpg`] : `${base}.jpg`;
        return json(200, { id: p.id, status: 'succeeded', output, metrics: video ? { predict_time: 30, video_output_duration_seconds: plan.billed ?? p.input.duration } : { predict_time: 3, ...(plan.metrics ?? {}) } });
      }
      json(404, { detail: 'no such route' });
    });
  });
  await new Promise<void>(r => server.listen(0, '127.0.0.1', () => r()));
  const base = `http://127.0.0.1:${(server.address() as any).port}/v1`;
  return { state, preds, base, close: () => new Promise<void>(r => server.close(() => r())) };
}

/** A real clip in storage: 6.4 s, with an AAC audio track. */
async function uploadClip(a: Awaited<ReturnType<typeof makeApp>>, c: Client, file: string, seconds: number) {
  const b = '----musereplicate';
  const meta = JSON.stringify({ name: 'kitchen', durationSec: seconds, width: 1080, height: 1920, fps: 30 });
  const body = Buffer.concat([
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="meta"\r\n\r\n${meta}\r\n`),
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="kitchen.mp4"\r\nContent-Type: video/mp4\r\n\r\n`),
    fs.readFileSync(file), Buffer.from(`\r\n--${b}--\r\n`),
  ]);
  const r = await a.app.inject({ method: 'POST', url: '/v1/uploads/clips', headers: { authorization: `Bearer ${c.token}`, 'content-type': `multipart/form-data; boundary=${b}` }, payload: body });
  expect(r.statusCode).toBe(200);
  return JSON.parse(r.body).id as string;
}

/** Live events for one user, straight from the hub. */
async function listen(a: Awaited<ReturnType<typeof makeApp>>, c: Client) {
  const [st] = await a.ctx.db.select().from(studioSettings);
  const events: any[] = [];
  const stop = a.ctx.hub.subscribe(st!.studioId, c.id, line => { if (line.startsWith('data: ')) events.push(JSON.parse(line.slice(6))); });
  return { events, stop };
}

const probe = (file: string) => JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', file]).toString()) as
  { format: { duration: string }; streams: { codec_type: string; width?: number }[] };

describe('pricing and prompt (Replicate)', () => {
  it('matches every row of replicate_pricing_fixture.json', () => {
    const rows = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../../android/core/src/test/resources/replicate_pricing_fixture.json'), 'utf8'));
    expect(rows.length).toBe(135);
    for (const o of rows) {
      const r = { engine: 'replicate', quality: o.quality, clipSeconds: o.clipSeconds, takes: o.takes };
      expect(P.replicateSeconds(o.clipSeconds)).toBe(o.seconds);
      expect(P.totalCost(r)).toBe(o.cost);
      expect(P.money(P.totalCost(r))).toBe(o.costLabel);
      expect(P.priceLine(r)).toBe(o.priceLine);
      expect(P.genLabel(r)).toBe(o.genLabel);
    }
  });
  it('matches every row of photo_pricing_fixture.json (pass-through photo estimates)', () => {
    const fx = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../../android/core/src/test/resources/photo_pricing_fixture.json'), 'utf8'));
    expect(fx.rows.length).toBe(94);
    const pp = fx.params as P.PhotoPrices;
    expect(pp).toMatchObject({ perRun: 0.015, perInputMp: 0.015, perOutputMp: 0.015, perEdit: 0.03, refMp: P.PHOTO_REF_MP, maxRefs: 6 });
    for (const r of fx.rows) {
      const v = r.kind === 'shoot' ? P.shootEstimate(pp, r.count, r.refs) : r.kind === 'outfitSet' ? P.outfitSetEstimate(pp, r.refs)
        : r.kind === 'sheetAngles' ? P.sheetAnglesEstimate(pp, r.count, r.refs) : P.loraSetEstimate(pp, r.refs);
      expect(v, JSON.stringify(r)).toBe(r.estimate);
      expect(P.aboutMoney(v)).toBe(r.label);
    }
    // The exact cost of one prediction: Replicate's dollar figure > its billing counts > the measured megapixels.
    expect(P.photoPredictionCost(pp, 'shot', { inMp: 6 * 0.786432, outMp: 1088 * 1920 / 1e6 })).toBeCloseTo(0.11711328, 12);
    expect(P.photoPredictionCost(pp, 'shot', { inMp: 9, outMp: 9 }, { image_input_megapixel_count: 1, image_output_megapixel_count: 1 })).toBeCloseTo(0.045, 12);
    expect(P.photoPredictionCost(pp, 'shot', { inMp: 9, outMp: 9 }, { cost_usd: 0.07 })).toBe(0.07);
    expect(P.photoPredictionCost(pp, 'edit', { inMp: 0, outMp: 0 })).toBe(0.03);
    expect(P.photoPredictionCost(pp, 'edit', { inMp: 0, outMp: 0 }, { image_output_count: 2 })).toBe(0.06);
  });
  it('labels and ledger notes', () => {
    expect(P.engineLabel({ engine: 'replicate', quality: 'hd' })).toBe('HD · 2K');
    expect(P.engineLabel({ engine: 'replicate' })).toBe('Draft · 768P');
    expect(P.engineLabel({ engine: 'h3', steps: 12 })).toBe('Edit');
    expect(P.takeLabel({ engine: 'h3', steps: 12 })).toBe('Edit');
    expect(P.engineLabel({ engine: 'viggle' })).toBe('Fast · beta');
    expect(P.takeLabel({ engine: 'replicate', quality: 'draft' })).toBe('Draft');
    expect(P.videoNote({ engine: 'replicate', quality: 'standard' }, [7])).toBe('Video · Standard 768P · 7 s');
    expect(P.videoNote({ engine: 'replicate', quality: 'hd' }, [7, 7])).toBe('Video · HD 2K · 2 × 7 s');
    expect(P.videoNote({ engine: 'replicate', quality: 'draft' }, [6.5, 7])).toBe('Video · Draft 768P · 13.5 s');
    expect(rateHintSeconds('Request was throttled. Your rate limit resets in ~6s.', null)).toBe(6);
    expect(rateHintSeconds('', '12')).toBe(12);
    expect(rateHintSeconds('nope', null)).toBeNull();
  });
  it('a short four-section prompt with the framing line, references in order', () => {
    const labels = ['face, front', 'face, profile', 'body, front', 'body, ¾', 'body, back', 'outfit, front', 'outfit, ¾', 'outfit, back'];
    const { text } = replicateSwap({ identity: { name: 'Sienna Vale', look: 'long wavy honey-blonde hair, green eyes, light freckles', neverAdd: ['tattoos', 'rings'] },
      outfit: { name: 'Green crop tee', source: 'reference-set' }, referenceLabels: labels });
    for (const s of ['subject_definitions:', 'summary:', 'retention_analysis:', 'detailed_description:']) expect(text).toContain(s);
    expect(text).toContain('<Subject 2> is the person in <Image 1> to <Image 8>: long wavy honey-blonde hair');
    expect(text).toContain('face and identity from <Image 1> and <Image 2>; body shape from <Image 3> to <Image 5>; the green crop tee outfit from <Image 6> to <Image 8>');
    expect(text).toContain('no tattoos, no rings, no logos');
    expect(text).toContain('keep the exact framing and crop of <Video 1>');
    expect(text).toMatch(/caption or on-screen text is removed/);
    const words = text.split(/\s+/).filter(Boolean).length;
    expect(words).toBeGreaterThan(150);
    expect(words).toBeLessThan(290);
    const described = replicateSwap({ identity: { name: 'A', look: 'short black hair' }, outfit: { name: 'Knit', description: 'cream cable-knit sweater', source: 'described' },
      referenceLabels: ['face, front', 'body, front'] }).text;
    expect(described).toContain('wearing cream cable-knit sweater, not the clothes in <Image 2>');
    expect(imageRange([1, 3, 4])).toBe('<Image 1>, <Image 3> and <Image 4>');
  });
  it('defaults: Replicate for photos and video only with a token', () => {
    expect(loadConfig({ REPLICATE_API_TOKEN: 'x' }).IMAGE_PROVIDER).toBe('replicate');
    expect(loadConfig({ REPLICATE_API_TOKEN: 'x' }).videoEngineDefault).toBe('replicate');
    expect(loadConfig({}).IMAGE_PROVIDER).toBe('simulated');
    expect(loadConfig({}).videoEngineDefault).toBe('h3');
    expect(loadConfig({ REPLICATE_API_TOKEN: 'x', IMAGE_PROVIDER: 'simulated', VIDEO_ENGINE_DEFAULT: 'h3' }).IMAGE_PROVIDER).toBe('simulated');
  });
});

describe.skipIf(!hasFfmpeg)('video on Replicate (fake Replicate server)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>;
  let fake: Awaited<ReturnType<typeof fakeReplicate>>;
  let owner: Client, modelId: string, outfitId: string, clipId: string, silentClipId: string;
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-rep-test-'));
  const slept: number[] = [];
  let clock = Date.now();

  beforeAll(async () => {
    fake = await fakeReplicate(work);
    a = await makeApp({ REPLICATE_API_TOKEN: TOKEN, REPLICATE_API_URL: fake.base, REPLICATE_POLL_MS: '10', REPLICATE_MAX_RATE_WAIT_SEC: '120', IMAGE_PROVIDER: 'simulated', BALANCE_MODE: 'simulated',
      SIM_START_BALANCE: '50', CAP_PER_DAY_USD: '1000', CAP_PER_USER_DAY_USD: '1000' },
      { replicateTime: { sleep: async ms => { slept.push(ms); clock += ms; await new Promise(r => setTimeout(r, 2)); }, now: () => clock } });
    owner = (await people(a, 0)).owner;
    modelId = (await sienna(owner)).id;
    const o = (await owner.req('POST', '/v1/outfits', { modelId, name: 'Green crop tee', mode: 'own', images: [{ asset: 'g_front' }, { asset: 'g_tq' }, { asset: 'g_side' }, { asset: 'g_back' }] })).body;
    outfitId = o.id;
    await until(async () => (await owner.req('GET', '/v1/outfits')).body.find((x: any) => x.id === outfitId && x.state === 'preview'));
    const src = path.join(work, 'source.mp4'), silent = path.join(work, 'silent.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=360x640:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=330', '-t', '6.4',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', src]);
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=360x640:rate=30', '-t', '2.5', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', silent]);
    clipId = await uploadClip(a, owner, src, 6.4);
    silentClipId = await uploadClip(a, owner, silent, 2.5);
  }, 120_000);
  afterAll(async () => { await a?.close(); await fake?.close(); fs.rmSync(work, { recursive: true, force: true }); });

  const job = async (id: string) => (await owner.req('GET', '/v1/jobs')).body.find((j: any) => j.id === id);
  const ended = (id: string) => until(async () => { const j = await job(id); return j && ['done', 'failed'].includes(j.state) ? j : null; }, 60_000);
  const rows = (jobId: string) => a.ctx.db.select().from(ledger).where(eq(ledger.jobId, jobId));

  it('advertises Render (Draft / Standard / HD) and the add-ons (Edit, Fast · beta, Upscale coming soon), and refuses Edit-only options', async () => {
    const st = (await owner.req('GET', '/v1/settings/studio')).body;
    expect(st.features.replicate).toBe(true);
    expect(st.features.video.defaultEngine).toBe('replicate');
    expect(st.features.video.defaultQuality).toBe('draft');
    expect(st.features.video.options.map((o: any) => [o.id, o.label, o.detail, o.pricePerSec ?? null, o.available])).toEqual([
      ['draft', 'Draft', 'Quick preview · 768P', 0.02, true], ['standard', 'Standard', '768P', 0.08, true], ['hd', 'HD', '2K', 0.13, true]]);
    expect(st.features.video.addons.map((o: any) => [o.id, o.label, o.available, o.comingSoon ?? false])).toEqual([
      ['edit', 'Edit', true, false], ['fast', 'Fast · beta', true, false], ['upscale', 'Upscale', false, true]]);
    expect(st.features.video.addons[0].sends).toEqual({ engine: 'h3', use: 'full', steps: 10 });
    expect(st.features.video.addons[2].sizes).toEqual([
      { id: '1080p', label: '1080p', width: 1080, height: 1920, available: false, price: null },
      { id: '2k', label: '2K', width: 1440, height: 2560, available: false, price: null },
      { id: '4k', label: '4K', width: 2160, height: 3840, available: false, price: null }]);
    // Nothing a member reads names a provider, a GPU or steps.
    expect(JSON.stringify(st.features)).not.toMatch(/replicate\b(?!")|runpod|gpu|lite|steps? ·|warm/i);
    expect((await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId, engine: 'replicate', lipSync: true })).body.code).toBe('bad_request');
    expect((await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId, engine: 'replicate', background: 'photo' })).body.code).toBe('bad_request');
    expect((await owner.req('GET', '/health')).body.videoEngine).toBe('replicate');
  });

  it('holds price × D, waits out a 429, pads to whole seconds, trims back to the exact length with the audio, settles on billed seconds', async () => {
    fake.state.rateLimits.push('Request was throttled. Your rate limit resets in ~6s.');
    fake.state.plans.push({ billed: 6 });
    const before = slept.length;
    const r = await owner.req('POST', '/v1/jobs', { title: 'Kitchen', modelId, outfitId, clipId, quality: 'standard' });   // no engine: the default (replicate)
    expect(r.status).toBe(200);
    const j = r.body;
    expect(j.request).toMatchObject({ engine: 'replicate', quality: 'standard', use: 'full', pricePerSec: 0.08 });
    expect(j.cost).toBeCloseTo(0.56, 9);                         // 6.4 s → D = 7 → 0.08 × 7
    expect(j.engineLabel).toBe('Standard · 768P');
    const done = await ended(j.id);
    expect(done.state).toBe('done');
    expect(done.billedSeconds).toBe(6);
    // The 429's hint was honoured (6 s + 1).
    expect(slept.slice(before)).toContain(7000);
    // What Replicate was asked for.
    const p = fake.state.creates.at(-1)!;
    expect(p.model).toBe('minimax/h3');
    expect(p.input).toMatchObject({ duration: 7, resolution: '768P', ratio: '9:16' });
    expect(p.input.reference_video_urls).toHaveLength(1);
    expect(p.input.reference_image_urls).toHaveLength(9);         // 5 locked shots + 4 outfit angles
    expect(p.input.prompt).toContain('keep the exact framing and crop of <Video 1>');
    expect(p.input.prompt).toContain('<Image 1> to <Image 9>');
    expect(p.input).not.toHaveProperty('seed');
    expect(fake.state.unauthorized).toBe(0);
    // The padded source is exactly D seconds; the take is the source's exact length with its audio.
    const padded = probe(path.join(a.dir, `r/${j.id}/source_padded.mp4`));
    expect(Number(padded.format.duration)).toBeCloseTo(7, 1);
    const take = probe(path.join(a.dir, `r/${j.id}/take_1.mp4`));
    expect(Math.abs(Number(take.format.duration) - 6.4)).toBeLessThan(0.06);
    expect(take.streams.some(s => s.codec_type === 'audio')).toBe(true);
    expect(fs.existsSync(path.join(a.dir, `r/${j.id}/take_1.jpg`))).toBe(true);
    const t = (await owner.req('GET', '/v1/takes')).body.find((x: any) => x.jobId === j.id);
    expect(t).toMatchObject({ label: 'Standard', engineLabel: 'Standard · 768P', videoUrl: `/uploads/r/${j.id}/take_1.mp4`, thumb: { url: `/uploads/r/${j.id}/take_1.jpg` } });
    expect(Math.abs(t.durationSec - 6.4)).toBeLessThan(0.06);
    // Ledger: the hold, then the settle on 6 billed seconds (0.48).
    const l = await rows(j.id);
    expect(l.find(x => x.kind === 'hold')!.note).toBe('Video · Standard 768P · 7 s · hold');
    const settle = l.find(x => x.kind === 'settle')!;
    expect(settle.note).toBe('Video · Standard 768P · 6 s');
    expect(settle.amountUsd).toBeCloseTo(0.48, 9);
  }, 90_000);

  it('Draft on the lite model, a short silent clip padded to 4 s, keep audio off, two takes', async () => {
    const j = (await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId: silentClipId, engine: 'replicate', takes: 2, keepAudio: false })).body;   // no quality: Draft
    expect(j.request.quality).toBe('draft');
    expect(j.cost).toBeCloseTo(0.02 * 4 * 2, 9);
    const done = await ended(j.id);
    expect(done.state).toBe('done');
    const [p1, p2] = fake.state.creates.slice(-2);
    expect(p1!.model).toBe('minimax/h3-lite');
    expect(p2!.input.duration).toBe(4);
    for (const i of [1, 2]) {
      const take = probe(path.join(a.dir, `r/${j.id}/take_${i}.mp4`));
      expect(Math.abs(Number(take.format.duration) - 2.5)).toBeLessThan(0.06);
      expect(take.streams.some(s => s.codec_type === 'audio')).toBe(false);
    }
    expect((await rows(j.id)).find(x => x.kind === 'settle')!.note).toBe('Video · Draft 768P · 2 × 4 s');
  }, 90_000);

  it('HD asks for 2K', async () => {
    const j = (await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId, engine: 'replicate', quality: 'hd' })).body;
    expect(j.cost).toBeCloseTo(0.13 * 7, 9);
    expect((await ended(j.id)).state).toBe('done');
    expect(fake.state.creates.at(-1)!.input.resolution).toBe('2K');
  }, 90_000);

  it('a failed prediction fails the job and refunds the hold', async () => {
    fake.state.plans.push({ status: 'failed', error: 'CUDA out of memory' });
    const j = (await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId, engine: 'replicate' })).body;
    const f = await ended(j.id);
    expect(f).toMatchObject({ state: 'failed', errorCode: 'provider_failed', phase: 'Failed' });
    expect(f.error).toBe("Something went wrong · you weren't charged");
    expect(f.refunded).toBeCloseTo(0.14, 9);                       // Draft (the default): 0.02 × 7
    const l = await rows(j.id);
    expect(l.find(x => x.kind === 'release')!.tokens).toBe(l.find(x => x.kind === 'hold')!.tokens! * -1);
    expect(l.some(x => x.kind === 'settle')).toBe(false);
  }, 60_000);

  it("a safety-filter refusal says so and refunds", async () => {
    fake.state.plans.push({ status: 'failed', error: 'The input or output was flagged as sensitive. Please try again with different inputs. (E005)' });
    const j = (await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId, engine: 'replicate' })).body;
    const f = await ended(j.id);
    expect(f).toMatchObject({ state: 'failed', errorCode: 'provider_refused', error: "This clip was refused by the content filter · you weren't charged" });
    expect((await rows(j.id)).some(x => x.kind === 'release')).toBe(true);
  }, 60_000);

  it('waits in line one at a time, and deleting a running job cancels its prediction and refunds', async () => {
    fake.state.plans.push({ holdUntilCancelled: true });
    const n0 = fake.state.creates.length;
    const j1 = (await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId, engine: 'replicate' })).body;
    const j2 = (await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId, engine: 'replicate', title: 'second' })).body;
    const p1 = await until(() => { const p = fake.state.creates[n0]; return p && fake.preds.get(p.id)!.polls > 1 ? p : null; }, 30_000);
    expect(fake.state.creates.length).toBe(n0 + 1);                 // one at a time: j2 hasn't started
    const waiting = await until(async () => { const x = await job(j2.id); return x?.queuePosition === 1 ? x : null; });
    expect(waiting.phase).toMatch(/^Waiting to start/);
    expect((await owner.req('DELETE', `/v1/jobs/${j1.id}`)).status).toBe(204);
    await until(() => fake.state.cancels.includes(p1.id) || null);
    expect((await rows(j1.id)).some(x => x.kind === 'release')).toBe(true);
    const [row] = await a.ctx.db.select().from(jobs).where(eq(jobs.id, j1.id));
    expect(row!.state).toBe('failed');
    expect((await ended(j2.id)).state).toBe('done');
  }, 90_000);

  it('gives up with provider_rate_limited only after the long wait, refunded', async () => {
    for (let i = 0; i < 40; i++) fake.state.rateLimits.push('Request was throttled. Your rate limit resets in ~9s.');
    const j = (await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId, engine: 'replicate' })).body;
    const f = await ended(j.id);
    fake.state.rateLimits.length = 0;
    expect(f).toMatchObject({ state: 'failed', errorCode: 'provider_rate_limited' });
    expect(f.error).not.toMatch(/replicate/i);
    expect((await rows(j.id)).some(x => x.kind === 'release')).toBe(true);
  }, 90_000);

  it('out of credit (402): the job fails at once with a refund, and the owner gets a notice and an Engines status', async () => {
    const ev = await listen(a, owner);
    fake.state.noCredit = 1;
    const j = (await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId, engine: 'replicate' })).body;
    const f = await ended(j.id);
    ev.stop();
    expect(f).toMatchObject({ state: 'failed', errorCode: 'provider_out_of_credit', refunded: j.cost });
    expect(f.error).toBe("Something went wrong · you weren't charged. The studio owner has been told.");
    expect((await rows(j.id)).some(x => x.kind === 'release')).toBe(true);
    expect(ev.events.some(e => e.type === 'wallet' && e.notice?.code === 'provider_out_of_credit' && e.notice.engine === 'replicate')).toBe(true);
    const st = (await owner.req('GET', '/v1/settings/studio')).body;
    expect(st.engines.list.find((e: any) => e.id === 'replicate')).toMatchObject({ name: 'Replicate', status: 'out_of_credit', keySet: true });
    // The next job that works clears it.
    const ok = (await owner.req('POST', '/v1/jobs', { modelId, outfitId, clipId, engine: 'replicate' })).body;
    expect((await ended(ok.id)).state).toBe('done');
    expect((await owner.req('GET', '/v1/settings/studio')).body.engines.list.find((e: any) => e.id === 'replicate').status).toBe('ready');
  }, 90_000);
});

describe('photos on Replicate (fake Replicate server)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>;
  let fake: Awaited<ReturnType<typeof fakeReplicate>>;
  let owner: Client, modelId: string;
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-rep-img-'));
  let clock = Date.now();

  beforeAll(async () => {
    fake = await fakeReplicate(work);
    a = await makeApp({ REPLICATE_API_TOKEN: TOKEN, REPLICATE_API_URL: fake.base, REPLICATE_POLL_MS: '10', BALANCE_MODE: 'simulated', SIM_START_BALANCE: '50',
      REPLICATE_IMAGE_MAX_WAIT_SEC: '30' }, { replicateTime: { sleep: async ms => { clock += ms; await new Promise(r => setTimeout(r, 1)); }, now: () => clock } });
    owner = (await people(a, 0)).owner;
    modelId = (await sienna(owner)).id;
  });
  afterAll(async () => { await a?.close(); await fake?.close(); fs.rmSync(work, { recursive: true, force: true }); });

  it('is the default engine, labelled', async () => {
    const e = (await owner.req('GET', '/v1/settings/image-engine')).body;
    expect(e).toMatchObject({ provider: 'replicate', model: 'black-forest-labs/flux-2-pro', editModel: 'qwen/qwen-image-edit-2511', label: 'FLUX.2 [pro] · Replicate' });
    expect(e.available.replicate).toBe(true);
  });

  it('a photoshoot makes one FLUX.2 prediction per still with shrunk references, and records the cost', async () => {
    const shots = (await owner.req('POST', '/v1/shoots', { modelId, scene: 'Rooftop · golden hour', count: 2 })).body;
    expect(shots).toHaveLength(2);
    expect(shots[0].engineLabel).toBe(''); // the engine is never shown on a photo
    expect(shots[0].thumb.url).toMatch(/^\/uploads\/g\//);
    const ps = fake.state.creates.slice(-2);
    for (const p of ps) {
      expect(p.model).toBe('black-forest-labs/flux-2-pro');
      expect(p.input).toMatchObject({ aspect_ratio: '9:16', resolution: '2 MP', output_format: 'jpg', safety_tolerance: 2 });
      expect(p.input.input_images.length).toBeLessThanOrEqual(6);
      expect(p.input).not.toHaveProperty('negative_prompt');
    }
    expect(ps[0]!.input.prompt).toContain('Sienna Vale');
    const imgs = await a.ctx.db.select().from(generatedImages).where(eq(generatedImages.provider, 'replicate'));
    expect(imgs.length).toBeGreaterThanOrEqual(2);
    // Exact cost from the real megapixels: $0.015 + $0.015 × Σ input MP (the shrunk references as sent) + $0.015 × output MP (64×96).
    const inMp = async (p: typeof ps[number]) => {
      let mp = 0;
      for (const u of p.input.input_images as string[]) { const m = await sharp(path.join(a.dir, /\/(rx\/[^?]+)/.exec(u)![1]!)).metadata(); mp += m.width! * m.height! / 1e6; }
      return mp;
    };
    for (const [i, p] of ps.entries()) expect(shots[i].cost).toBeCloseTo(0.015 + 0.015 * (await inMp(p)) + 0.015 * (64 * 96 / 1e6), 12);
    // The hold was the estimate; the settle is the exact sum.
    const holds = await a.ctx.db.select().from(ledger).where(eq(ledger.kind, 'hold'));
    const hold = holds.at(-1)!;
    expect(hold.note).toBe('Photoshoot · 2 photos · hold');
    const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, hold.jobId!))).find(x => x.kind === 'settle')!;
    expect(settle.note).toBe('Photoshoot · 2 photos');
    expect(settle.amountUsd).toBeCloseTo(shots[0].cost + shots[1].cost, 12);
    // References were shrunk to fit 1024 px.
    const rx = fs.readdirSync(path.join(a.dir, 'rx'));
    expect(rx.length).toBeGreaterThan(0);
    const meta = await sharp(path.join(a.dir, 'rx', rx[0]!)).metadata();
    expect(Math.max(meta.width!, meta.height!)).toBeLessThanOrEqual(1024);
  });

  it("Replicate's own billing counts win over the measured size when the prediction reports them", async () => {
    fake.state.plans.push({ metrics: { image_input_megapixel_count: 4, image_output_megapixel_count: 2 } });
    const shots = (await owner.req('POST', '/v1/shoots', { modelId, scene: 'Kitchen', count: 1 })).body;
    expect(shots[0].cost).toBeCloseTo(0.015 + 0.015 * 4 + 0.015 * 2, 12);   // $0.105
    fake.state.plans.push({ metrics: { cost_usd: 0.0937 } });
    const s2 = (await owner.req('POST', '/v1/shoots', { modelId, scene: 'Kitchen', count: 1 })).body;
    expect(s2[0].cost).toBe(0.0937);
  });

  it('features.photo carries the prices and estimates the apps show ("about $0.46")', async () => {
    const f = (await owner.req('GET', '/v1/settings/studio')).body.features.photo;
    expect(f).toMatchObject({ perRun: 0.015, perInputMp: 0.015, perOutputMp: 0.015, perEdit: 0.03, refMp: 0.79, maxRefs: 6, loraShots: 30 });
    expect(P.aboutMoney(f.estimates.shoot)).toBe('about $0.46');
    expect(P.aboutMoney(f.estimates.outfitSet)).toBe('about $0.19');
    expect(P.aboutMoney(f.estimates.sheetAngle)).toBe('about $0.10');
    expect(P.aboutMoney(f.estimates.loraSet)).toBe('about $3.03');
  });

  it('an outfit set: a FLUX.2 front, then three Qwen edits of it', async () => {
    const n0 = fake.state.creates.length;
    const o = (await owner.req('POST', '/v1/outfits', { modelId, name: 'Cream knit', mode: 'describe', description: 'cream cable-knit sweater' })).body;
    const done = await until(async () => (await owner.req('GET', '/v1/outfits')).body.find((x: any) => x.id === o.id && x.state === 'preview'), 30_000);
    expect(done.angles.every((x: any) => x?.url)).toBe(true);
    const ps = fake.state.creates.slice(n0);
    expect(ps.map(p => p.model)).toEqual(['black-forest-labs/flux-2-pro', 'qwen/qwen-image-edit-2511', 'qwen/qwen-image-edit-2511', 'qwen/qwen-image-edit-2511']);
    expect(ps[1]!.input).toMatchObject({ aspect_ratio: 'match_input_image', output_format: 'jpg' });
    expect(ps[1]!.input.image[0]).toMatch(/rx\//);
    expect(ps[1]!.input.prompt).toMatch(/three-quarter/);
    // Exact: the FLUX.2 front + 3 × $0.03 edits.
    expect(done.cost).toBeGreaterThan(0.09 + 0.015);
    const imgs = (await a.ctx.db.select().from(generatedImages).where(eq(generatedImages.refId, o.id)));
    expect(imgs.filter(i => i.model === 'qwen/qwen-image-edit-2511').map(i => i.costUsd)).toEqual([0.03, 0.03, 0.03]);
    expect(done.cost).toBeCloseTo(imgs.reduce((t, i) => t + i.costUsd, 0), 12);
  });

  it('a safety refusal is provider_refused (422) and the shoot is refunded', async () => {
    const before = (await owner.req('GET', '/v1/balance')).body.balance;
    fake.state.plans.push({ status: 'failed', error: 'NSFW content detected' });
    const r = await owner.req('POST', '/v1/shoots', { modelId, count: 1 });
    expect(r.status).toBe(422);
    expect(r.body).toEqual({ code: 'provider_refused', error: "This photo was refused by the content filter · you weren't charged" });
    expect((await owner.req('GET', '/v1/balance')).body.balance).toBeCloseTo(before, 6);
  });

  it('a rate limit that outlasts the wait is provider_rate_limited (429), refunded', async () => {
    for (let i = 0; i < 50; i++) fake.state.rateLimits.push('Request was throttled. Your rate limit resets in ~10s.');
    const before = (await owner.req('GET', '/v1/balance')).body.balance;
    const r = await owner.req('POST', '/v1/shoots', { modelId, count: 1 });
    fake.state.rateLimits.length = 0;
    expect(r.status).toBe(429);
    expect(r.body.code).toBe('provider_rate_limited');
    expect((await owner.req('GET', '/v1/balance')).body.balance).toBeCloseTo(before, 6);
  });

  it('out of credit (402) on a photo: 503 provider_out_of_credit, not charged, owner told', async () => {
    const ev = await listen(a, owner);
    const before = (await owner.req('GET', '/v1/balance')).body.balance;
    fake.state.noCredit = 1;
    const r = await owner.req('POST', '/v1/shoots', { modelId, count: 1 });
    ev.stop();
    expect(r.status).toBe(503);
    expect(r.body).toEqual({ code: 'provider_out_of_credit', error: "Something went wrong · you weren't charged. The studio owner has been told." });
    expect((await owner.req('GET', '/v1/balance')).body.balance).toBeCloseTo(before, 6);
    expect(ev.events.some(e => e.type === 'wallet' && e.notice?.code === 'provider_out_of_credit')).toBe(true);
  });

  it('a shoot that fails after some photos were billed: the member pays nothing, the studio records what was spent', async () => {
    const n0 = fake.state.creates.length;
    fake.state.plans.push({}, { status: 'failed', error: 'boom' });
    const sb0 = (await owner.req('GET', '/v1/studio/balance')).body;
    const r = await owner.req('POST', '/v1/shoots', { modelId, count: 2 });
    expect(r.status).toBe(502);
    expect(r.body.error).toBe("Something went wrong making the photos · you weren't charged");
    expect(fake.state.creates.length).toBe(n0 + 2);
    const over = (await a.ctx.db.select().from(ledger).where(eq(ledger.kind, 'overhead'))).at(-1)!;
    expect(over.note).toMatch(/^Photos that didn't finish · Photoshoot · 2 photos/);
    expect(over.amountUsd).toBeGreaterThan(0.015);
    const sb1 = (await owner.req('GET', '/v1/studio/balance')).body;
    expect(sb0.balanceUsd - sb1.balanceUsd).toBeCloseTo(over.amountUsd, 9);
  });
});
