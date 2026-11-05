// AI suite prompts through prompt scripts (workstream 4's engine), the talking flag, beat-only audio, and camera
// drafts priced on their target. MOCK provider and a FAKE Replicate on localhost: no real predictions, no money.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { clips, jobs, ledger } from '../src/db/schema.js';
import { DEFAULT_TEXTS } from '../src/prompt/library.js';
import { scriptDef } from '../src/prompt/scripts/defs.js';
import { validateRules } from '../src/prompt/scripts/run.js';
import { withRules } from '../src/prompt/scripts/builders.js';
import { putObject } from '../src/storage/objects.js';
import { createShotDraft } from '../src/camera/shots.js';
import { compileCamera } from '../src/suite/compile.js';
import { CameraSpecSchema } from '../src/suite/camera.js';
import { buildInput } from '../src/suite/inputs.js';
import { buildPlan, fit, needOf, ShotRequestSchema, type Character } from '../src/suite/plan.js';
import { modelById } from '../src/suite/registry.js';
import { ApiError } from '../src/errors.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const CHAR: Character = { name: 'Mia', look: 'young woman, dark hair', neverAdd: ['tattoos'],
  images: [{ label: 'face, front', image: { asset: 'face' } }, { label: 'face, profile', image: { asset: 'profile' } }], outfit: null };
const req = (o: Record<string, unknown> = {}) => ShotRequestSchema.parse({ prompt: 'She smiles at the camera.', ...o });
const AUDIO = { audio: { audio: { key: 'up/song.m4a' } } };
const plan = (id: string, res: string, r: ReturnType<typeof req>, o: { speaking?: boolean; texts?: Record<string, string> } = {}) => {
  const m = modelById(id)!, n = needOf(r, CHAR);
  return buildPlan(r, n, { model: m, resolution: m.resolutions.find(x => x.id === res)!, seconds: fit(m, res, n).seconds, tried: [] }, CHAR,
    { speaking: o.speaking, separationUsd: 0.0066, texts: o.texts });
};

describe('AI suite · prompt scripts (unit)', () => {
  it('both suite scripts are registered and validate their own defaults', () => {
    for (const id of ['suite.camera', 'suite.shot']) {
      const s = scriptDef(id)!;
      expect(s, id).toBeTruthy();
      expect(validateRules(s, s.rules)).toBeNull();
      for (const r of s.rules) expect(DEFAULT_TEXTS[r.block], `${id}: ${r.block}`).toBeDefined();
    }
    expect(scriptDef('suite.shot')!.sections.filter(s => s.kind === 'user').map(s => s.id)).toEqual(['scene']);
  });
  it('mouth wording only from the audio rules: silent by default, dialogue when speaking with no audio sent', () => {
    const quiet = plan('h3', '768P', req());
    expect(quiet.speaking).toBe(false);
    expect(quiet.prompt).toMatch(/^Mia does not speak, sing or mouth words\.$/m);
    const talk = plan('h3', '768P', req({ prompt: 'She says "hi guys!"' }), { speaking: true });
    expect(talk.prompt).toMatch(/^Mia speaks the lines in quotes; her lips match every word\.$/m);
    expect(talk.prompt).not.toMatch(/does not speak/);
    // The camera and performance blocks never talk about mouths.
    const cam = compileCamera(CameraSpecSchema.parse({ preset: 'talking_head', performance: { emotion: 'joy' } }), modelById('h3')!);
    expect(cam.text).not.toMatch(/\b(mouth|lips|speaks?|sings?|words)\b/i);
  });
  it('audio reference: speaking sends the speech (lip-sync line); not speaking sends the instrumental (beat line) and adds the separation price', () => {
    const beat = plan('h3', '768P', req({ references: AUDIO }), { speaking: false });
    expect(beat.audioRef).toEqual({ ref: { key: 'up/song.m4a' }, beatOnly: true });
    expect(beat.prompt).toMatch(/^Mia moves to the beat of <Audio 1>; she does not sing, speak or mouth lyrics\.$/m);
    expect(beat.estimate).toBeCloseTo(0.08 * 5 + 0.0066, 6);
    expect(buildInput(modelById('h3')!, beat, { middle: [], refs: ['a', 'b'], videos: [], audio: 'inst' })).toMatchObject({ reference_audio_urls: ['inst'] });
    const sing = plan('seedance-2.0', '720p', req({ references: AUDIO }), { speaking: true });
    expect(sing.audioRef!.beatOnly).toBe(false);
    expect(sing.estimate).toBeCloseTo(0.18 * 5, 6);
    expect(sing.prompt).toMatch(/^Mia speaks in sync with \[Audio1\]: the lips match every word exactly\.$/m);
    expect(buildInput(modelById('seedance-2.0')!, sing, { middle: [], refs: ['a'], videos: [], audio: 'speech' })).toMatchObject({ reference_audios: ['speech'] });
    // Models with no audio input are skipped on the ladder; audio alone (no image or video reference) fits nothing.
    expect(fit(modelById('veo-3.1-lite')!, '720p', needOf(req({ frames: { start: { asset: 'face' } }, references: AUDIO }), CHAR)).why).toBe('no reference audio');
    expect(fit(modelById('h3')!, '768P', needOf(req({ references: AUDIO }), null)).why).toBe('audio needs an image or video reference');
  });
  it('the user’s scene is the only user section and is sanitised (never-add and identity changes are dropped)', () => {
    const p = plan('h3', '768P', req({ prompt: 'She dances in the kitchen, showing a big tattoo on her arm.' }));
    expect(p.prompt).toMatch(/^She dances in the kitchen,?$/m);
    expect(p.prompt).not.toMatch(/tattoo on her arm/);
    expect(p.notes.join()).toMatch(/left out of the scene/);
  });
  it('owner rule edits reach the shot prompt (switching off the not-speaking line) and the camera block (another format)', () => {
    const s = scriptDef('suite.shot')!;
    const off = withRules(DEFAULT_TEXTS, { 'suite.shot': s.rules.map(r => (r.id === 'audio.silent' ? { ...r, enabled: false } : r)) });
    expect(plan('h3', '768P', req(), { texts: off }).prompt).not.toMatch(/does not speak/);
    const c = scriptDef('suite.camera')!;
    const t = withRules(DEFAULT_TEXTS, { 'suite.camera': c.rules.map(r => (r.id === 'kling' ? { ...r, block: 'suite.camera.format.seedance' } : r)) });
    expect(compileCamera(CameraSpecSchema.parse({ move: { id: 'dolly_in' } }), modelById('kling-v4')!, { texts: t }).text.startsWith('[Camera] ')).toBe(true);
  });
});

describe('camera drafts are priced on their target model', () => {
  it('the target becomes engineModel + resolution; a target that can’t make the shot falls back to the ladder with a warning', async () => {
    const seen: any[] = [];
    const ctx = { config: { TOKEN_USD: 0.01 }, suite: { estimate: async (_u: unknown, b: any) => {
      seen.push(b);
      if (b.engineModel === 'veo-3.1-lite') throw new ApiError(400, 'nothing_fits', 'no');
      return { estimate: b.engineModel ? 1.18 : 0.9 };
    } } } as any;
    const base = { prompt: 'walk', durationSec: 5, aspect: '9:16', camera: {}, characters: [], cameraSessionId: 'cs_x' };
    const d = await createShotDraft(ctx, { role: 'owner' } as any, { ...base, targetModel: 'kling-v4.0' });
    expect(seen[0]).toMatchObject({ engineModel: 'kling-v4', resolution: '1080p', quality: 'cinema' });
    expect(d.estimate.usd).toBe(1.18);
    const f = await createShotDraft(ctx, { role: 'owner' } as any, { ...base, targetModel: 'veo-3.1-lite' });
    expect(f.estimate.usd).toBe(0.9);
    expect((f.request as any).engineModel).toBeUndefined();
    expect((f as any).warnings[0]).toMatch(/veo-3.1-lite can't make this shot right now/);
  });
});

describe.skipIf(!hasFfmpeg)('AI suite · talking flag and beat-only audio over HTTP', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, server: http.Server, dir: string, model: { id: string };
  const creates: { model: string; version?: string; input: any }[] = [];
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-suite-beat-'));
    const video = path.join(dir, 'out.mp4'), stem = path.join(dir, 'no_vocals.mp3');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=288x512:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '5', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', video]);
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=220', '-t', '5', stem]);
    server = http.createServer((q, res) => {
      let body = '';
      q.on('data', c => (body += c));
      q.on('end', () => {
        const url = q.url ?? '', port = (server.address() as any).port;
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (url === '/out.mp4') { res.writeHead(200, { 'content-type': 'video/mp4' }); fs.createReadStream(video).pipe(res); return; }
        if (url === '/no_vocals.mp3') { res.writeHead(200, { 'content-type': 'audio/mpeg' }); fs.createReadStream(stem).pipe(res); return; }
        if (q.headers.authorization !== 'Bearer r8_beat') return json(401, {});
        if (url === '/v1/models/ryan5453/demucs') return json(200, { latest_version: { id: 'demucs_v1' } });
        const m = /^\/v1\/models\/([^/]+\/[^/]+)\/predictions$/.exec(url);
        if ((m || url === '/v1/predictions') && q.method === 'POST') {
          const b = JSON.parse(body);
          creates.push({ model: m ? m[1]! : 'ryan5453/demucs', version: b.version, input: b.input });
          return json(201, { id: `p${creates.length}`, status: 'starting' });
        }
        const g = /^\/v1\/predictions\/p(\d+)$/.exec(url);
        if (g) {
          const c = creates[Number(g[1]) - 1]!;
          if (c.model === 'ryan5453/demucs') return json(200, { id: `p${g[1]}`, status: 'succeeded', output: { vocals: `http://127.0.0.1:${port}/x.mp3`, no_vocals: `http://127.0.0.1:${port}/no_vocals.mp3` }, metrics: { predict_time: 4 } });
          return json(200, { id: `p${g[1]}`, status: 'succeeded', output: `http://127.0.0.1:${port}/out.mp4`, metrics: { video_output_duration_seconds: 5 } });
        }
        json(404, {});
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    a = await makeApp({ SUITE_MODE: 'live', SUITE_POLL_MS: '10', REPLICATE_API_TOKEN: 'r8_beat', REPLICATE_API_URL: `http://127.0.0.1:${(server.address() as any).port}/v1`,
      REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated' });
    ({ owner } = await people(a, 0, { topUp: 100 }));
    model = await demoModel(owner);
    const [o] = await a.ctx.db.execute((await import('drizzle-orm')).sql`select studio_id from users where id = ${owner.id}`).then((r: any) => r.rows ?? r);
    await putObject(a.ctx, { key: 'up/song.m4a', body: fs.readFileSync(stem), studioId: o.studio_id, kind: 'clip', contentType: 'audio/mpeg' });
    await putObject(a.ctx, { key: 'up/talk.mp4', body: fs.readFileSync(video), studioId: o.studio_id, kind: 'clip', contentType: 'video/mp4' });
    await a.ctx.db.insert(clips).values({ id: 'c_talk', studioId: o.studio_id, name: 'talk', durationSec: 5, width: 288, height: 512, fps: 24, meta: { talking: true }, checks: [], storageKey: 'up/talk.mp4', createdAt: Date.now() });
  });
  afterAll(async () => { await a?.close(); server?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  it('speaking resolves switch → upload’s talking flag → detection → no, and is reported on the estimate', async () => {
    const body = (extra: object) => ({ modelId: model.id, quality: 'standard', ...extra });
    expect((await owner.req('POST', '/v1/suite/shots/estimate', body({ speaking: true }))).body.speaking).toEqual({ speaking: true, source: 'switch' });
    expect((await owner.req('POST', '/v1/suite/shots/estimate', body({}))).body.speaking).toEqual({ speaking: false, source: 'default' });
    expect((await owner.req('POST', '/v1/suite/shots/estimate', body({ references: { audio: { audio: { key: 'up/talk.mp4' } } } }))).body.speaking).toEqual({ speaking: true, source: 'upload' });
    const det = (await owner.req('POST', '/v1/suite/shots/estimate', body({ references: { audio: { audio: { key: 'up/song.m4a' } } } }))).body;
    expect(det.speaking.source).toBe('detected');
    expect((await owner.req('POST', '/v1/suite/shots/estimate', body({ references: { audio: { audio: { key: 'up/nope.m4a' } } } }))).body.speaking).toEqual({ speaking: false, source: 'default' });
  });

  it('not speaking: the vocals are separated once, only the instrumental is sent, and the separation is billed with the job', async () => {
    const r = (await owner.req('POST', '/v1/suite/shots', { modelId: model.id, quality: 'standard', duration: 5, speaking: false, prompt: 'She dances.',
      references: { audio: { audio: { key: 'up/song.m4a' } } } })).body;
    expect(r.request).toMatchObject({ speaking: false, speakingSource: 'switch' });
    const j = await until(async () => { const x = (await owner.req('GET', `/v1/suite/shots/${r.id}`)).body.job; return x?.state === 'done' || x?.state === 'failed' ? x : null; }, 20_000);
    expect(j.state).toBe('done');
    // The separator may be a real Replicate run or a no-op stand-in (which service runs it is workstream 3/4's choice):
    // at most one run per job, the shot gets the instrumental (or the source when nothing was separated), and the
    // settle is the shot plus exactly what the separation cost.
    expect(creates.filter(c => c.model.includes('demucs')).length).toBeLessThanOrEqual(1);
    const shot = creates.find(c => c.model === 'minimax/h3')!;
    expect(shot.input.reference_audio_urls).toHaveLength(1);
    expect(shot.input.reference_audio_urls[0]).toMatch(new RegExp(`(r/${r.id}/instrumental\\.m4a|up/song\\.m4a)`));
    expect(shot.input.prompt).toMatch(/moves to the beat of <Audio 1>; she does not sing, speak or mouth lyrics/);
    const [row] = await a.ctx.db.select().from(jobs).where(eq(jobs.id, r.id));
    const sepCost = (row!.stats as any).suite.separationCost as number;
    expect(sepCost).toBeGreaterThanOrEqual(0);
    const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, r.id))).find(x => x.kind === 'settle')!;
    expect(settle.amountUsd).toBeCloseTo(0.08 * 5 + sepCost, 6);
    expect(r.cost).toBeCloseTo(0.08 * 5 + 0.0066, 6); // the hold includes the separation estimate
  });

  it('a beat from an outside https link is refused (only uploads can be separated)', async () => {
    const r = await owner.req('POST', '/v1/suite/shots', { modelId: model.id, quality: 'standard', speaking: false, prompt: 'x', references: { audio: { audio: { url: 'https://x.test/song.mp3' } } } });
    expect(r.status).toBe(400);
    expect(r.body.error).toMatch(/Upload the audio/);
  });

  it('owner rule edit over HTTP: the not-speaking line can be switched off for the studio', async () => {
    const s = (await owner.req('GET', '/v1/prompt-scripts/suite.shot')).body;
    const rules = s.rules.map((x: any) => (x.id === 'audio.silent' ? { ...x, enabled: false } : x));
    const put = await owner.req('PUT', '/v1/prompt-scripts/suite.shot', { rules });
    expect(put.status, JSON.stringify(put.body).slice(0, 300)).toBe(200);
    expect(put.body.rules.find((x: any) => x.id === 'audio.silent').enabled, JSON.stringify({ o: put.body.overridden, s: put.body.stale, r: put.body.rules.map((x: any) => x.id + ':' + x.enabled) })).toBe(false);
    const e = (await owner.req('POST', '/v1/suite/shots/estimate', { modelId: model.id, quality: 'standard', prompt: 'x' })).body;
    expect(e.prompt).not.toMatch(/does not speak/);
    await owner.req('DELETE', '/v1/prompt-scripts/suite.shot');
    expect((await owner.req('POST', '/v1/suite/shots/estimate', { modelId: model.id, quality: 'standard', prompt: 'x' })).body.prompt).toMatch(/does not speak/);
  });
});
