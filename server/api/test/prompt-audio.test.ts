// Prompt scripts, audio side (plans/prompt-scripts.md §5–6), against a FAKE Replicate on localhost (no money):
// talking detection on generated audio (speech-like, music, silence, no track), the lip-sync path (not speaking → the
// model gets the clip without sound → the clip's sound is put back with a stream copy; speaking → sound kept), the
// "Performer is speaking" switch, and beat-only audio (vocal separation → instrumental).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { decodeAudio, detectTalking, soundRanges } from '../src/audio/detect.js';
import { audioIdle } from '../src/audio/service.js';
import { beatOnlyAudio } from '../src/audio/beat.js';
import { MockProvider, ReplicateProvider } from '../src/editor/providers.js';
import { makeApp, people, demoModel, until, type Client } from './helpers.js';
import { musicLike, silence, speechLike, writeWav } from './audioSignals.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const TOKEN = 'r8_audio_test';
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-audio-test-'));
afterAll(() => fs.rmSync(work, { recursive: true, force: true }));

const ff = (...args: string[]) => execFileSync('ffmpeg', ['-y', '-v', 'error', ...args]);
/** A 360x640 clip with this audio (or none). */
function clip(name: string, audio: Float32Array | null, seconds = 6) {
  const f = path.join(work, `${name}.mp4`);
  if (!audio) { ff('-f', 'lavfi', '-i', 'testsrc=size=360x640:rate=30', '-t', String(seconds), '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', f); return f; }
  const wav = path.join(work, `${name}.wav`);
  writeWav(wav, audio);
  ff('-f', 'lavfi', '-i', 'testsrc=size=360x640:rate=30', '-i', wav, '-t', String(seconds), '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', f);
  return f;
}
const probe = (file: string) => JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', file]).toString()) as
  { format: { duration: string }; streams: { codec_type: string; codec_name: string }[] };
const hasAudio = (f: string) => probe(f).streams.some(s => s.codec_type === 'audio');
/** A checksum of the video packets only (equal = the video stream was copied, not re-encoded). */
const videoHash = (f: string) => execFileSync('ffmpeg', ['-v', 'error', '-i', f, '-map', '0:v:0', '-c', 'copy', '-f', 'md5', '-']).toString().trim();

describe.skipIf(!hasFfmpeg)('talking detection (free: ffmpeg + heuristics) on generated audio', () => {
  it('speech-like → speaking; music and music with a singer → not; silence; no audio track', async () => {
    for (const seed of [1, 2]) {
      expect(await detectTalking('ffmpeg', clip(`speech${seed}`, speechLike(8, seed)))).toMatchObject({ kind: 'speech', speaking: true });
      expect(await detectTalking('ffmpeg', clip(`speechHigh${seed}`, speechLike(8, seed, 220)))).toMatchObject({ kind: 'speech', speaking: true });
      expect(await detectTalking('ffmpeg', clip(`music${seed}`, musicLike(8, seed)))).toMatchObject({ kind: 'music', speaking: false });
      expect(await detectTalking('ffmpeg', clip(`song${seed}`, musicLike(8, seed, true)))).toMatchObject({ kind: 'music', speaking: false });
    }
    expect(await detectTalking('ffmpeg', clip('quiet', silence(6)))).toMatchObject({ kind: 'silence', speaking: false });
    expect(await detectTalking('ffmpeg', clip('mute', null))).toEqual({ kind: 'none', speaking: false, confidence: 1 });
    // The decode is 16 kHz mono, capped at 30 s.
    expect((await decodeAudio('ffmpeg', clip('long', speechLike(35, 3), 35)))!.length).toBe(30 * 16000);
  }, 60_000);
});

// ---------------------------------------------------------------- fake Replicate: the video model + a vocal separator
async function fakeReplicate() {
  type Pred = { id: string; model: string; version?: string; input: any; polls: number };
  const preds = new Map<string, Pred>();
  const state = { creates: [] as Pred[], demucsOutput: 'no_vocals' as 'no_vocals' | 'stems' };
  let n = 0;
  const outVideo = path.join(work, 'model_out.mp4');
  ff('-f', 'lavfi', '-i', 'testsrc2=size=288x512:rate=25', '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', outVideo);
  const stem = path.join(work, 'stem.wav');
  writeWav(stem, musicLike(3, 9));
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', c => (body += c));
    req.on('end', () => {
      const url = req.url ?? '';
      const json = (status: number, o: unknown) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
      if (url.startsWith('/files/')) { res.writeHead(200); fs.createReadStream(url.endsWith('.mp4') ? outVideo : stem).pipe(res); return; }
      if (req.headers.authorization !== `Bearer ${TOKEN}`) return json(401, { detail: 'Unauthenticated' });
      if (url === '/v1/models/ryan5453/demucs' && req.method === 'GET') return json(200, { owner: 'ryan5453', name: 'demucs', latest_version: { id: 'v_demucs' } });
      const create = /^\/v1\/models\/([^/]+\/[^/]+)\/predictions$/.exec(url);
      if ((create || url === '/v1/predictions') && req.method === 'POST') {
        const b = JSON.parse(body);
        const p: Pred = { id: `p${++n}`, model: create ? create[1]! : b.version === 'v_demucs' ? 'ryan5453/demucs' : '?', version: b.version, input: b.input, polls: 0 };
        preds.set(p.id, p); state.creates.push(p);
        return json(201, { id: p.id, status: 'starting' });
      }
      const get = /^\/v1\/predictions\/([^/]+)$/.exec(url);
      if (get) {
        const p = preds.get(get[1]!)!;
        if (++p.polls < 2) return json(200, { id: p.id, status: 'processing' });
        const base = `http://127.0.0.1:${(server.address() as any).port}/files/${p.id}`;
        if (p.model === 'ryan5453/demucs') {
          const output = state.demucsOutput === 'no_vocals' ? { vocals: `${base}_v.wav`, no_vocals: `${base}_nv.wav` }
            : { vocals: `${base}_v.wav`, drums: `${base}_d.wav`, bass: `${base}_b.wav`, other: `${base}_o.wav` };
          return json(200, { id: p.id, status: 'succeeded', output, metrics: { predict_time: 6 } });
        }
        return json(200, { id: p.id, status: 'succeeded', output: `${base}.mp4`, metrics: { predict_time: 30, video_output_duration_seconds: p.input.duration } });
      }
      json(404, { detail: 'no such route' });
    });
  });
  await new Promise<void>(r => server.listen(0, '127.0.0.1', () => r()));
  return { state, outVideo, base: `http://127.0.0.1:${(server.address() as any).port}/v1`, close: () => new Promise<void>(r => server.close(() => r())) };
}

async function uploadClip(a: Awaited<ReturnType<typeof makeApp>>, c: Client, file: string, seconds: number, extra: Record<string, unknown> = {}) {
  const b = '----museaudio';
  const meta = JSON.stringify({ name: path.basename(file), durationSec: seconds, width: 360, height: 640, fps: 30, talking: false, ...extra });
  const body = Buffer.concat([
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="meta"\r\n\r\n${meta}\r\n`),
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="clip.mp4"\r\nContent-Type: video/mp4\r\n\r\n`),
    fs.readFileSync(file), Buffer.from(`\r\n--${b}--\r\n`),
  ]);
  const r = await a.app.inject({ method: 'POST', url: '/v1/uploads/clips', headers: { authorization: `Bearer ${c.token}`, 'content-type': `multipart/form-data; boundary=${b}` }, payload: body });
  expect(r.statusCode).toBe(200);
  return JSON.parse(r.body) as { id: string; audio?: unknown; checks: { label: string; value: string }[] };
}

describe.skipIf(!hasFfmpeg)('lip-sync fix: speaking decides what the model hears (fake Replicate)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, fake: Awaited<ReturnType<typeof fakeReplicate>>, owner: Client, modelId: string;
  let speechClip: string, musicClip: string;
  beforeAll(async () => {
    fake = await fakeReplicate();
    a = await makeApp({ REPLICATE_API_TOKEN: TOKEN, REPLICATE_API_URL: fake.base, REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated', BALANCE_MODE: 'simulated',
      SIM_START_BALANCE: '50', CAP_PER_DAY_USD: '1000', CAP_PER_USER_DAY_USD: '1000' }, { replicateTime: { sleep: async () => { await new Promise(r => setTimeout(r, 2)); }, now: Date.now } });
    owner = (await people(a, 0)).owner;
    modelId = (await demoModel(owner)).id;
    const s = await uploadClip(a, owner, clip('up_speech', speechLike(6, 4)), 6);
    const m = await uploadClip(a, owner, clip('up_music', musicLike(6, 4)), 6);
    speechClip = s.id; musicClip = m.id;
  }, 120_000);
  afterAll(async () => { await a?.close(); await fake?.close(); });

  const ended = (id: string) => until(async () => { const j = (await owner.req('GET', '/v1/jobs')).body.find((x: any) => x.id === id); return j && ['done', 'failed'].includes(j.state) ? j : null; }, 60_000);
  const run = async (body: Record<string, unknown>) => {
    const r = await owner.req('POST', '/v1/jobs', { modelId, engine: 'replicate', ...body });
    expect(r.status).toBe(200);
    const done = await ended(r.body.id);
    expect(done.state).toBe('done');
    return { job: r.body, pred: fake.state.creates.at(-1)!, padded: path.join(a.dir, `r/${r.body.id}/source_padded.mp4`), take: path.join(a.dir, `r/${r.body.id}/take_1.mp4`) };
  };

  it('upload: the clip comes back classified; the talking check follows the detection', async () => {
    const s = await uploadClip(a, owner, clip('up_speech2', speechLike(6, 5)), 6);
    const m = await uploadClip(a, owner, clip('up_music2', musicLike(6, 5)), 6);
    const q = await uploadClip(a, owner, clip('up_mute', null), 6);
    expect(s.audio).toEqual({ kind: 'speech', speaking: true, detected: true });
    expect(m.audio).toEqual({ kind: 'music', speaking: false, detected: true });
    expect(q.audio).toEqual({ kind: 'none', speaking: false, detected: true });
    expect(s.checks.find(c => c.label === 'Performer talking')!.value).toBe('Yes');
    expect(m.checks.find(c => c.label === 'Performer talking')!.value).toBe('No');
    // An app that says the performer talks wins over the detection.
    const said = await uploadClip(a, owner, clip('up_said', musicLike(6, 6)), 6, { talking: true });
    expect(said.audio).toEqual({ kind: 'music', speaking: true, detected: true });
    await audioIdle();
  });

  it('not speaking: the model gets the clip without sound and the silent wording; the sound is put back by a stream copy', async () => {
    const r = await run({ clipId: musicClip });
    expect(r.job.request).toMatchObject({ speaking: false, speakingSource: 'detected' });
    expect(hasAudio(r.padded)).toBe(false);
    expect(r.pred.input.prompt).toContain('she does not speak, sing or mouth words');
    expect(r.pred.input.prompt).not.toMatch(/words being mouthed|lip movement/);
    expect(hasAudio(r.take)).toBe(true);
    expect(videoHash(r.take)).toBe(videoHash(fake.outVideo));      // the model's video, untouched
    const back = await detectTalking('ffmpeg', r.take);
    expect(back.kind).toBe('music');                                 // the clip's own music, not the model's sound
  }, 60_000);

  it('speaking: the model gets the sound and the lip-sync wording; the take is the model file as delivered', async () => {
    const r = await run({ clipId: speechClip, direction: 'smiling' });
    expect(r.job.request).toMatchObject({ speaking: true, speakingSource: 'detected' });
    expect(hasAudio(r.padded)).toBe(true);
    expect(r.pred.input.prompt).toContain('the words being mouthed');
    expect(r.pred.input.prompt).toMatch(/\nDirection from the user: smiling\n$/);
    expect(fs.readFileSync(r.take).equals(fs.readFileSync(fake.outVideo))).toBe(true);
  }, 60_000);

  it('the switch wins over the detection, both ways', async () => {
    const off = await run({ clipId: speechClip, speaking: false });
    expect(off.job.request).toMatchObject({ speaking: false, speakingSource: 'switch' });
    expect(hasAudio(off.padded)).toBe(false);
    const on = await run({ clipId: musicClip, speaking: true });
    expect(on.job.request).toMatchObject({ speaking: true, speakingSource: 'switch' });
    expect(hasAudio(on.padded)).toBe(true);
    expect(on.pred.input.prompt).toContain('mouth and lip movement');
  }, 90_000);

  it('Edit (structured prompt) gets the mouth line when not speaking', async () => {
    const r = await owner.req('POST', '/v1/jobs', { modelId, clipId: musicClip, engine: 'h3', queue: true });
    expect(r.status).toBe(200);
    const [row] = await a.ctx.db.select().from((await import('../src/db/schema.js')).jobs).where((await import('drizzle-orm')).eq((await import('../src/db/schema.js')).jobs.id, r.body.id));
    expect(row!.prompt).toContain("<Subject 2>'s mouth follows <Video 1> exactly; she does not speak, sing or mouth words.");
  });

  it('beat-only audio: the editor separator (no_vocals) gives the instrumental, stored audio-only and priced from GPU time', async () => {
    const key = 'c/beat_source.wav';
    writeWav(path.join(a.dir, key), musicLike(3, 5, true));
    const provider = new ReplicateProvider(a.ctx);
    const r = await beatOnlyAudio(a.ctx, { studioId: 's', jobId: 'jbeat', audioKey: key, durationSec: 3, provider });
    const p = fake.state.creates.at(-1)!;
    expect(p).toMatchObject({ model: 'ryan5453/demucs', version: 'v_demucs' });
    expect(p.input).toMatchObject({ stem: 'vocals' });
    expect(p.input.audio).toMatch(/beat_source\.wav/);
    expect(r).toMatchObject({ instrumentalKey: 'r/jbeat/instrumental.m4a', separated: true, seconds: 6, predictionId: p.id });
    expect(r.costUsd).toBeCloseTo(6 * provider.rates.separate, 9);
    expect(probe(path.join(a.dir, r.instrumentalKey)).streams.map(s => s.codec_type)).toEqual(['audio']);
    // A separator that returns four stems: the accompaniment stem ("other") is used.
    fake.state.demucsOutput = 'stems';
    const r2 = await beatOnlyAudio(a.ctx, { studioId: 's', jobId: 'jbeat2', audioKey: key, durationSec: 3, provider });
    expect(probe(path.join(a.dir, r2.instrumentalKey)).streams.map(s => s.codec_type)).toEqual(['audio']);
    // The mock (EDITOR_AI_PROVIDER unset): no provider call, the source is used as is.
    const before = fake.state.creates.length;
    const m = await beatOnlyAudio(a.ctx, { studioId: 's', jobId: 'jbeat3', audioKey: key, durationSec: 3, provider: new MockProvider(1) });
    expect(m).toMatchObject({ instrumentalKey: key, separated: false });
    expect(fake.state.creates.length).toBe(before);
  }, 60_000);
});

describe('sound ranges (for the editor\'s silence cuts)', () => {
  it('finds the sound between silences and bridges short gaps', () => {
    const s = new Float32Array(16000 * 5);
    const tone = (from: number, to: number) => { for (let i = from * 16000; i < to * 16000; i++) s[i] = 0.3 * Math.sin(2 * Math.PI * 220 * i / 16000); };
    tone(0.5, 1.5); tone(1.6, 2.0); tone(3.5, 4.5);
    const r = soundRanges(s);
    expect(r).toHaveLength(2);
    expect(r[0]!.startSec).toBeCloseTo(0.5, 1); expect(r[0]!.endSec).toBeCloseTo(2.0, 1);
    expect(r[1]!.startSec).toBeCloseTo(3.5, 1); expect(r[1]!.endSec).toBeCloseTo(4.5, 1);
    expect(soundRanges(silence(3))).toEqual([]);
  });
});

