// Higgsfield Genjutsu (owner 2026-11-11) against a FAKE Higgsfield (no real calls, no money): motion transfer as a swap
// engine (Character swap / one-person Recast / Recreate), object swap and restyle as Edit helpers, the free access check.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { ledger, takes, users } from '../src/db/schema.js';
import { GENJUTSU_KEEPS, GENJUTSU_NO_ACCESS, recastIntent, SWAP_ENGINES } from '../src/engines/purposes.js';
import { genjutsuSeconds, genjutsuUsd, parseGenjutsuOptions } from '../src/editor/genjutsu.js';
import * as P from '../src/pricing.js';
import { genjutsuInput } from '../src/services/replicateVideo.js';
import { replicateSwap, videoSwap } from '../src/prompt/scripts/builders.js';
import { requestOf } from '../src/suite/assist.js';
import { placeWords } from '../src/engines/purposes.js';
import { modelById } from '../src/suite/registry.js';
import { editorAi } from '../src/editor/service.js';
import { demoModel, makeApp, people, until } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const PRESET = 'c2143317-f28d-4c3c-a0b8-39bd547e08a7';

describe('Genjutsu · registry, pricing and inputs', () => {
  it('motion transfer and Light are Higgsfield swap engines with their real ids, limits and per-second prices', () => {
    const gj = SWAP_ENGINES.find(e => e.id === 'genjutsu')!, light = SWAP_ENGINES.find(e => e.id === 'genjutsu-light')!;
    expect(gj).toMatchObject({ name: 'Genjutsu', runs: 'higgsfield', ref: 'higgsfield/genjutsu/motion-transfer/v1.0', genjutsu: { minSec: 4, maxSec: 30, maxImages: 8 } });
    expect(light).toMatchObject({ runs: 'higgsfield', ref: 'higgsfield/genjutsu-light/motion-transfer/v1.0', genjutsu: { maxSec: 15 } });
    expect(SWAP_ENGINES.some(e => e.ref?.startsWith('higgsfiled'))).toBe(false); // never the legacy misspelled id
    expect(modelById('genjutsu')!.resolutions.map(r => [r.id, r.perSec])).toEqual([['480p', 0.154], ['720p', 0.3446], ['1080p', 0.8346]]);
    // Light bills output + input seconds: twice its list rate per output second.
    expect(modelById('genjutsu-light')!.resolutions.map(r => [r.id, r.perSec])).toEqual([['480p', 0.1], ['720p', 0.2], ['1080p', 0.4]]);
    expect(modelById('genjutsu')!.modes).toMatchObject({ text: false, image: false, reference: false });
  });
  it('a swap take is fit to 4–30 s: padded up to 4 s, cut at 30 s; priced on those seconds', () => {
    expect(P.hostedSeconds({ engine: 'replicate', clipSeconds: 2.1, minSec: 4, maxSec: 30 })).toBe(4);
    expect(P.hostedSeconds({ engine: 'replicate', clipSeconds: 22.4, minSec: 4, maxSec: 30 })).toBe(23);
    expect(P.hostedSeconds({ engine: 'replicate', clipSeconds: 41, minSec: 4, maxSec: 30 })).toBe(30);
    expect(P.hostedSeconds({ engine: 'replicate', clipSeconds: 22.4 })).toBe(15); // other engines unchanged
    expect(P.estCost({ engine: 'replicate', clipSeconds: 22.4, minSec: 4, maxSec: 30, pricePerSec: 0.3446 })).toBeCloseTo(0.3446 * 23, 6);
    expect(P.videoNote({ engine: 'replicate', quality: 'hd', resolutionLabel: '1080p' }, [12])).toBe('Video · HD 1080p · 12 s');
  });
  it('the input: clip, ≤ 8 pictures, H3 tokens turned into plain words, resolution', () => {
    const imgs = Array.from({ length: 10 }, (_, i) => `https://x/${i}.jpg`);
    const i = genjutsuInput('https://x/v.mp4', imgs, 'Replace the person in <Video 1> with <Image 1>; figure from <Image 4>.', '1080p');
    expect(i).toEqual({ video_url: 'https://x/v.mp4', image_urls: imgs.slice(0, 8), prompt: 'Replace the person in the source video with image 1; figure from image 4.', resolution: '1080p' });
    expect(genjutsuInput('u', ['a'], '', '720p')).toEqual({ video_url: 'u', image_urls: ['a'], resolution: '720p' });
  });
  it('Auto: "same moves, new look or scene" → Genjutsu Light; "same scene, new person" → Recast', () => {
    expect(recastIntent('Same dance on a beach at sunset').kind).toBe('look');
    expect(recastIntent('She wears the red dress').kind).toBe('look');
    expect(recastIntent('adding a friend next to her').kind).toBe('look');
    expect(recastIntent('her holding the perfume bottle').kind).toBe('look');
    expect(recastIntent('Replace the dancer with Mia')).toEqual({ kind: 'person', reason: 'same scene, new person' });
    expect(recastIntent(undefined).kind).toBe('person');
    expect(GENJUTSU_KEEPS.notStated).toContain('cuts');
  });
  it('helpers: options checked, ≥ 4 s, first 30 s priced × markup', () => {
    expect(() => parseGenjutsuOptions('objectswap', {})).toThrow(/at least one picture/);
    expect(() => parseGenjutsuOptions('objectswap', { images: Array(9).fill({ url: 'https://x' }) })).toThrow(/at most 8/);
    expect(() => parseGenjutsuOptions('restyle', { presetId: 'Anime' })).toThrow(/presetId/);
    expect(() => parseGenjutsuOptions('restyle', { presetId: PRESET, resolution: '4K' })).toThrow(/resolution/);
    expect(parseGenjutsuOptions('restyle', { presetId: PRESET })).toMatchObject({ presetId: PRESET, resolution: '720p', images: [] });
    expect(() => genjutsuSeconds(3)).toThrow(/at least 4 s/);
    expect(genjutsuSeconds(45)).toBe(30);
    expect(genjutsuUsd('objectswap', '720p', 6.2, 2)).toBeCloseTo(0.3446 * 7 * 2, 4);
    expect(genjutsuUsd('restyle', '1080p', 60, 2)).toBeCloseTo(1.632 * 30 * 2, 4);
  });
});

describe('Swap background · Describe it (prompts)', () => {
  const id = { name: 'Mia', look: 'young woman' };
  it('hosted prompt: the place comes from the direction, the moves and timing stay, the background is not kept', () => {
    const keep = replicateSwap({ identity: id, referenceLabels: ['face, front'], direction: 'on a rooftop at night', speaking: true }).text;
    const desc = replicateSwap({ identity: id, referenceLabels: ['face, front'], direction: 'on a rooftop at night', speaking: true, newBackground: true }).text;
    expect(keep).toMatch(/background and the lighting of <Video 1> stay unchanged/);
    expect(desc).toMatch(/replaced by the place described in the direction from the user/);
    expect(desc).toMatch(/motion_preserved/);
    expect(desc).not.toMatch(/in the same place/);
    expect(desc).not.toMatch(/fully_preserved - camera motion, framing and crop, background/);
    expect(desc).toMatch(/Direction from the user: on a rooftop at night/);
    const silent = replicateSwap({ identity: id, referenceLabels: ['face, front'], direction: 'on a beach', speaking: false, newBackground: true }).text;
    expect(silent).toMatch(/new background/);
    expect(silent).not.toMatch(/mouth and lip movement and head turn/);
  });
  it('Edit prompt: its own background sentence and retention line', () => {
    const t = videoSwap({ identity: { ...id, age: 25 } as any, outfit: { name: 'red dress' }, keepBackground: false, describeBackground: true, direction: 'in a neon club' }).text;
    expect(t).toMatch(/the background is replaced by the place described in the direction from the user/);
    expect(t).toMatch(/the background is not kept, it is replaced by the place the user describes/);
    const photo = videoSwap({ identity: { ...id, age: 25 } as any, outfit: { name: 'red dress' }, keepBackground: false }).text;
    expect(photo).toMatch(/background reference photo/);
  });
  it('the draft carries it; place words are found', () => {
    expect(requestOf({ v: 1, tool: 'swap', background: 'describe' } as any)).toMatchObject({ background: 'describe' });
    expect((requestOf({ v: 1, tool: 'swap' } as any) as any).background).toBeUndefined();
    expect(placeWords('same dance on a rooftop at night')).toBe('rooftop');
    expect(placeWords('she smiles more')).toBeNull();
  });
});

describe.skipIf(!hasFfmpeg)('Genjutsu against a FAKE Higgsfield (no money)', () => {
  let server: http.Server, dir: string, base = '';
  const hf: { url: string; input: any }[] = [];
  const rep: unknown[] = [];
  let mode: 'ok' | 'no_access' | 'no_credit' = 'ok';
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-gj-fake-'));
    const file = path.join(dir, 'out.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=288x512:rate=24', '-t', '4', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-an', file]);
    server = http.createServer((q, res) => {
      let body = '';
      q.on('data', c => (body += c));
      q.on('end', () => {
        const url = q.url ?? '';
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (url === '/out.mp4') { res.writeHead(200, { 'content-type': 'video/mp4' }); fs.createReadStream(file).pipe(res); return; }
        if (!url.startsWith('/hf/')) { rep.push(url); return json(401, {}); }
        if (q.headers.authorization !== 'Key hfid:hfsecret') return json(401, { detail: 'Invalid credentials' });
        const sub = url.slice(3);
        if (q.method === 'GET' && sub === '/models/higgsfield/genjutsu/restyle/v1.0/presets') {
          if (mode === 'no_access') return json(403, { detail: 'Model not available on your plan' });
          return json(200, { model: 'higgsfield/genjutsu/restyle/v1.0', items: [{ id: PRESET, name: 'Cel-Shaded CG Anime', preview_url: 'https://x/p.jpg' }] });
        }
        if (q.method === 'POST' && sub.startsWith('/higgsfield/genjutsu')) {
          hf.push({ url: sub, input: JSON.parse(body) });
          if (mode === 'no_access') return json(403, { detail: 'Model not available on your plan' });
          if (mode === 'no_credit') return json(403, { detail: 'Not enough credits' });
          const id = `00000000-0000-0000-0000-0000000000${String(hf.length).padStart(2, '0')}`;
          return json(200, { status: 'queued', request_id: id, status_url: `${base}/hf/requests/${id}/status`, cancel_url: `${base}/hf/requests/${id}/cancel` });
        }
        if (/^\/requests\/[0-9a-f-]+\/status$/.test(sub)) return json(200, { status: 'completed', request_id: 'x', video: { url: `${base}/out.mp4` } });
        json(404, {});
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(() => { server?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  const env = (extra: Record<string, string> = {}) => ({ SUITE_MODE: 'live', SUITE_POLL_MS: '10', REPLICATE_API_TOKEN: 'r8_suite', REPLICATE_API_URL: `${base}/v1`,
    REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated', HIGGSFIELD_API_URL: `${base}/hf`, HF_CREDENTIALS: 'hfid:hfsecret', ...extra });
  /** A real 3.2 s clip with sound (shorter than Genjutsu's 4 s: padded). */
  const clipOf = async (a: Awaited<ReturnType<typeof makeApp>>, owner: any) => {
    const src = path.join(dir, 'swap-src.mp4');
    if (!fs.existsSync(src)) execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=360x640:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=330', '-t', '3.2',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', src]);
    const b = '----musegj', meta = JSON.stringify({ name: 'dance', durationSec: 3.2, width: 1080, height: 1920, fps: 30 });
    const payload = Buffer.concat([Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="meta"\r\n\r\n${meta}\r\n`),
      Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="dance.mp4"\r\nContent-Type: video/mp4\r\n\r\n`), fs.readFileSync(src), Buffer.from(`\r\n--${b}--\r\n`)]);
    const r = await a.app.inject({ method: 'POST', url: '/v1/uploads/clips', headers: { authorization: `Bearer ${owner.token}`, 'content-type': `multipart/form-data; boundary=${b}` }, payload });
    expect(r.statusCode).toBe(200);
    return JSON.parse(r.body).id as string;
  };
  const swap = async (a: Awaited<ReturnType<typeof makeApp>>, owner: any, engineModel = 'genjutsu', quality = 'hd') => {
    const m = await demoModel(owner), clipId = await clipOf(a, owner);
    const r = await owner.req('POST', '/v1/jobs', { modelId: m.id, clipId, engineModel, quality });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const j = await until(async () => { const x = (await owner.req('GET', '/v1/jobs')).body.find((y: any) => y.id === r.body.id); return x && ['done', 'failed'].includes(x.state) ? x : null; }, 30_000);
    return { req: r.body.request, j };
  };

  it('offered for Swap (and Recreate fills) to the owner and members, 4–30 s, 720p price; members see "Genjutsu · Higgsfield" while provider names are shown', async () => {
    const a = await makeApp(env());
    const { owner, members: [member] } = await people(a, 1, { topUp: 100 });
    try {
      const list = (await owner.req('GET', '/v1/engines?purpose=swap')).body;
      const row = (list.engines ?? list).find((e: any) => e.model === 'genjutsu');
      expect(row).toMatchObject({ name: 'Genjutsu', label: 'Genjutsu · Higgsfield', provider: 'higgsfield', price: { basis: 'per_second', usd: 0.3446 } });
      expect(row.purposes).toEqual(expect.arrayContaining(['swap', 'fill']));
      expect(row.limits).toMatchObject({ minSeconds: 4, maxInputSeconds: 30 });
      expect((list.engines ?? list).some((e: any) => e.model === 'genjutsu-light')).toBe(true);
      const ml = (await member!.req('GET', '/v1/engines?purpose=swap')).body;
      const mrow = (ml.engines ?? ml).find((e: any) => e.model === 'genjutsu');
      expect(mrow).toBeTruthy();
      expect(mrow).toMatchObject({ name: 'Genjutsu', label: 'Genjutsu · Higgsfield', providerName: 'Higgsfield' });
    } finally { await a.close(); }
  });

  it('Character swap on Genjutsu: motion-transfer endpoint, the clip + ≤ 8 pictures, plain prompt, 1080p, padded to 4 s, settled at $0.8346/s, sound back', async () => {
    hf.length = 0; rep.length = 0; mode = 'ok';
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const { req, j } = await swap(a, owner);
      expect(req).toMatchObject({ engine: 'replicate', swapEngine: 'genjutsu', videoModel: 'higgsfield/genjutsu/motion-transfer/v1.0', pricePerSec: 0.8346, minSec: 4, maxSec: 30, resolutionLabel: '1080p' });
      expect(j.state, j.error).toBe('done');
      expect(rep).toHaveLength(0);
      expect(hf).toHaveLength(1);
      expect(hf[0]!.url).toBe('/higgsfield/genjutsu/motion-transfer/v1.0');
      expect(Object.keys(hf[0]!.input).sort()).toEqual(['image_urls', 'prompt', 'resolution', 'video_url']);
      expect(hf[0]!.input.resolution).toBe('1080p');
      expect(hf[0]!.input.image_urls.length).toBeGreaterThan(0);
      expect(hf[0]!.input.image_urls.length).toBeLessThanOrEqual(8);
      expect(hf[0]!.input.prompt).not.toMatch(/<Image|<Video/);
      const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id))).find(x => x.kind === 'settle');
      expect(settle!.amountUsd).toBeCloseTo(0.8346 * 4, 6);
      const [take] = await a.ctx.db.select().from(takes).where(eq(takes.jobId, j.id));
      expect(take).toBeTruthy();
    } finally { await a.close(); }
  });

  it('Light at Standard: the Light endpoint at 720p, $0.20 per output second', async () => {
    hf.length = 0; mode = 'ok';
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const { req, j } = await swap(a, owner, 'genjutsu-light', 'standard');
      expect(req).toMatchObject({ swapEngine: 'genjutsu-light', pricePerSec: 0.2, maxSec: 15 });
      expect(j.state, j.error).toBe('done');
      expect(hf[0]).toMatchObject({ url: '/higgsfield/genjutsu-light/motion-transfer/v1.0', input: { resolution: '720p' } });
    } finally { await a.close(); }
  });

  it('no Genjutsu on the plan: the swap fails plainly, nothing charged, no fallback to another model', async () => {
    hf.length = 0; rep.length = 0; mode = 'no_access';
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const { j } = await swap(a, owner);
      expect(j.state).toBe('failed');
      expect(j.error).toBe(GENJUTSU_NO_ACCESS);
      expect(rep).toHaveLength(0);
      const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id))).find(x => x.kind === 'settle' && x.amountUsd > 0);
      expect(settle).toBeUndefined();
      expect((await owner.req('GET', '/v1/engines/genjutsu/access')).body).toMatchObject({ access: 'no', detail: GENJUTSU_NO_ACCESS });
    } finally { await a.close(); mode = 'ok'; }
  });

  it('a one-person Recast on Auto asking for a new scene runs on Genjutsu Light, and says why; a plain recast does not', async () => {
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const m = await demoModel(owner), clipId = await clipOf(a, owner);
      const look = await owner.req('POST', '/v1/suite/shots/estimate', { mode: 'recast', clipId, cast: [{ characterId: m.id }], prompt: 'Same moves, now on a rooftop at night in a black outfit', quality: 'standard' });
      expect(look.status, JSON.stringify(look.body)).toBe(200);
      expect(look.body.mode).toBe('swap');
      expect(look.body.warnings[0]).toMatch(/^Auto chose Genjutsu Light: you asked for a new look or scene/);
      expect(look.body.engine).toMatchObject({ model: 'genjutsu-light', perSec: 0.2 });
      const list = (await owner.req('GET', '/v1/engines?purpose=swap')).body;
      expect((list.engines ?? list).find((e: any) => e.model === 'genjutsu-light').keeps).toEqual(GENJUTSU_KEEPS);
      const plain = await owner.req('POST', '/v1/suite/shots/estimate', { mode: 'recast', clipId, cast: [{ characterId: m.id }], prompt: 'Replace the dancer', quality: 'standard' });
      expect(plain.body.engine?.model).not.toBe('genjutsu-light');
      expect(plain.body.mode).not.toBe('swap');
    } finally { await a.close(); }
  });

  it('Swap background: Describe it / New photo → Auto runs Genjutsu Light and says why; Keep with a place in the prompt → a warning', async () => {
    hf.length = 0; mode = 'ok';
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const m = await demoModel(owner), clipId = await clipOf(a, owner);
      const base = { mode: 'swap', modelId: m.id, clipId, prompt: '', quality: 'standard' };
      const desc = await owner.req('POST', '/v1/suite/shots/estimate', { ...base, background: 'describe', direction: 'dancing on a rooftop at night' });
      expect(desc.status, JSON.stringify(desc.body)).toBe(200);
      expect(desc.body.engine).toMatchObject({ model: 'genjutsu-light' });
      expect(desc.body.warnings[0]).toMatch(/^Auto chose Genjutsu Light: the background is set to Describe it/);
      const photo = await owner.req('POST', '/v1/suite/shots/estimate', { ...base, background: 'photo', backgroundImage: { url: 'https://example.com/room.jpg' } });
      expect(photo.body.engine).toMatchObject({ model: 'genjutsu-light' });
      const keep = await owner.req('POST', '/v1/suite/shots/estimate', { ...base, direction: 'on a beach at sunset' });
      expect(keep.body.engine?.model).not.toBe('genjutsu-light');
      expect(keep.body.warnings).toContain('Background is set to Keep · your prompt describes a new place · switch to Describe it?');
      expect(keep.body.fixes).toEqual([{ fix: 'background:describe', label: 'Describe it' }]);
      const plain = await owner.req('POST', '/v1/suite/shots/estimate', { ...base, direction: 'she smiles more' });
      expect(plain.body.warnings ?? []).not.toContain('Background is set to Keep · your prompt describes a new place · switch to Describe it?');
      // Describe it needs words; the job's prompt then says the place is new.
      expect((await owner.req('POST', '/v1/jobs', { modelId: m.id, clipId, engineModel: 'genjutsu-light', quality: 'standard', background: 'describe' })).body.error).toMatch(/describe the new place/);
      const r = await owner.req('POST', '/v1/jobs', { modelId: m.id, clipId, engineModel: 'genjutsu-light', quality: 'standard', background: 'describe', direction: 'dancing on a rooftop at night' });
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      const j = await until(async () => { const x = (await owner.req('GET', '/v1/jobs')).body.find((y: any) => y.id === r.body.id); return x && ['done', 'failed'].includes(x.state) ? x : null; }, 30_000);
      expect(j.state, j.error).toBe('done');
      expect(hf.at(-1)!.input.prompt).toMatch(/replaced by the place described in the direction from the user/);
      expect(hf.at(-1)!.input.prompt).toMatch(/rooftop at night/);
      // Genjutsu with a new photo: the photo is the last picture and the direction points to it.
      const r2 = await owner.req('POST', '/v1/jobs', { modelId: m.id, clipId, engineModel: 'genjutsu-light', quality: 'standard', background: 'photo', backgroundImage: { url: 'https://example.com/room.jpg' } });
      expect(r2.status, JSON.stringify(r2.body)).toBe(200);
      await until(async () => { const x = (await owner.req('GET', '/v1/jobs')).body.find((y: any) => y.id === r2.body.id); return x && ['done', 'failed'].includes(x.state) ? x : null; }, 30_000);
      const last = hf.at(-1)!.input;
      expect(last.image_urls.at(-1)).toBe('https://example.com/room.jpg');
      expect(last.prompt).toMatch(new RegExp(`place and background from image ${last.image_urls.length}`));
      // Other hosted swaps still refuse a background photo.
      expect((await owner.req('POST', '/v1/jobs', { modelId: m.id, clipId, engineModel: 'h3', quality: 'standard', background: 'photo', backgroundImage: { url: 'https://example.com/room.jpg' } })).body.error).toMatch(/only on Edit or Genjutsu/);
    } finally { await a.close(); }
  });

  it('access check is free (preset list only), owner only; without the key it is unknown and Genjutsu is not offered', async () => {
    hf.length = 0; mode = 'ok';
    const a = await makeApp(env());
    const { owner, members: [member] } = await people(a, 1, { topUp: 100 });
    try {
      expect((await owner.req('GET', '/v1/engines/genjutsu/access')).body).toMatchObject({ access: 'yes', presets: 1 });
      expect(hf).toHaveLength(0); // no generation was started
      expect((await member!.req('GET', '/v1/engines/genjutsu/access')).status).toBe(403);
    } finally { await a.close(); }
    const b = await makeApp(env({ HF_CREDENTIALS: '' }));
    const { owner: o2 } = await people(b, 0, { topUp: 100 });
    try {
      expect((await o2.req('GET', '/v1/engines/genjutsu/access')).body.access).toBe('unknown');
      const list = (await o2.req('GET', '/v1/engines?purpose=swap')).body;
      expect((list.engines ?? list).some((e: any) => e.model === 'genjutsu')).toBe(false);
    } finally { await b.close(); }
  });

  it('Edit helpers: object swap and restyle priced × 2, run on their endpoints, refuse short videos; features list the presets', async () => {
    hf.length = 0; mode = 'ok';
    const a = await makeApp(env());
    const { owner } = await people(a, 0, { topUp: 100 });
    try {
      const [me] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
      const sid = me!.studioId;
      await a.ctx.db.insert(takes).values({ id: 'take_gj6', studioId: sid, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'v', label: '', engineLabel: '', cost: 0, seed: 0,
        status: 'final', thumb: null, prompt: '', mediaKey: 'c/take_gj6.mp4', media: { durationSec: 6.2, width: 1080, height: 1920, contentType: 'video/mp4' }, createdAt: Date.now() });
      await a.ctx.db.insert(takes).values({ id: 'take_gj3', studioId: sid, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'v', label: '', engineLabel: '', cost: 0, seed: 0,
        status: 'final', thumb: null, prompt: '', mediaKey: 'c/take_gj3.mp4', media: { durationSec: 3, width: 1080, height: 1920, contentType: 'video/mp4' }, createdAt: Date.now() });
      const f = (await owner.req('GET', '/v1/editor/features')).body;
      expect(f.objectswap).toMatchObject({ available: true, minSec: 4, maxSec: 30, maxImages: 8 });
      expect(f.restyle.presets).toEqual([{ id: PRESET, name: 'Cel-Shaded CG Anime', preview: 'https://x/p.jpg' }]);
      const os1 = { kind: 'objectswap', source: { takeId: 'take_gj6' }, options: { images: [{ url: 'https://example.com/bag.jpg' }], prompt: 'the handbag becomes this one' } };
      expect((await owner.req('POST', '/v1/editor/estimate', os1)).body.usd).toBeCloseTo(0.3446 * 7 * 2, 4);
      expect((await owner.req('POST', '/v1/editor/estimate', { ...os1, source: { takeId: 'take_gj3' } })).body.error).toMatch(/at least 4 s/);
      const done = (id: string) => until(async () => { const x = (await owner.req('GET', `/v1/editor/jobs/${id}`)).body; return x.state !== 'running' ? x : null; }, 30_000);
      editorAi(a.ctx).genjutsuPollMs = 10;
      expect((await owner.req('PATCH', '/v1/editor/settings', { capPerDayUsd: 50 })).status).toBe(200); // a Genjutsu helper costs more than the $5 default day cap
      const j1 = (await owner.req('POST', '/v1/editor/jobs', os1)).body;
      const r1 = await done(j1.id);
      expect(r1.state, r1.error).toBe('done');
      expect(hf.at(-1)).toMatchObject({ url: '/higgsfield/genjutsu/object-swap/v1.0', input: { image_urls: ['https://example.com/bag.jpg'], prompt: 'the handbag becomes this one', resolution: '720p' } });
      expect(r1.costUsd).toBeCloseTo(0.3446 * 7 * 2, 4);
      const j2 = (await owner.req('POST', '/v1/editor/jobs', { kind: 'restyle', source: { takeId: 'take_gj6' }, options: { presetId: PRESET, resolution: '480p' } })).body;
      expect(j2.id, JSON.stringify(j2)).toBeTruthy();
      const r2 = await done(j2.id);
      expect(r2.state, r2.error).toBe('done');
      expect(hf.at(-1)).toMatchObject({ url: '/higgsfield/genjutsu/restyle/v1.0', input: { preset_id: PRESET, image_urls: [], resolution: '480p' } });
      expect(r2.costUsd).toBeCloseTo(0.318 * 7 * 2, 4);
    } finally { await a.close(); }
  });
});
