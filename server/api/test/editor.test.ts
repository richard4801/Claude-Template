// Editor v2 (plans/api.md "Editor v2", plans/video-editor.md "Editor v2"): the shared model and fixtures, the AI helper
// jobs on the mock provider (estimate → hold → settle, cancel, reuse, events), saving v2 projects, and the Replicate
// adapter against a fake Replicate on localhost (no real predictions, no money).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { and, eq, sql } from 'drizzle-orm';
import { ledger, takes } from '../src/db/schema.js';
import * as M from '../src/editor/model.js';
import { FILTERS } from '../src/editor/presets.js';
import { LOOK_IDS } from '../src/editor/lookpack.js';
import { suggestCuts } from '../src/editor/cuts.js';
import { WHITE_MATTE, adaptInput, makeProvider, mockWords, parseTranscript, pickFile } from '../src/editor/providers.js';
import { noiseSuggestion } from '../src/editor/service.js';
import { editorJobs } from '../src/editor/schema.js';
import { parseSilenceDetect, silenceCuts } from '../src/editor/silence.js';
import { makeApp, people, sse, until, type Client } from './helpers.js';

type A = Awaited<ReturnType<typeof makeApp>>;
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');
const FIX = path.join(here, 'fixtures/editor');
const fx = (n: string) => JSON.parse(fs.readFileSync(path.join(FIX, n), 'utf8'));
const studioOf = async (a: A) => ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows?.[0]?.studio_id as string;

async function videoTake(a: A, studioId: string, o: { id?: string; durationSec?: number; kind?: 'take' | 'shot' } = {}) {
  const id = o.id ?? `take_${Math.random().toString(16).slice(2, 10)}`;
  await a.ctx.storage.put(`c/${id}.mp4`, Buffer.from('source video'), 'video/mp4');
  await a.ctx.db.insert(takes).values({ id, studioId, userId: null, kind: o.kind ?? 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'Serum review',
    label: 'HD', engineLabel: 'HD · 2K', cost: 1, seed: 1, status: 'final', thumb: null, prompt: 'p', mediaKey: o.kind === 'shot' ? null : `c/${id}.mp4`,
    media: { durationSec: o.durationSec ?? 10, width: 1080, height: 1920, fps: 30, contentType: 'video/mp4' }, createdAt: Date.now() });
  return id;
}
async function upload(a: A, c: Client, kind: 'clip' | 'image', body: Buffer, contentType = kind === 'clip' ? 'video/mp4' : 'image/jpeg') {
  const p = (await c.req('POST', '/v1/uploads/presign', { kind, contentType, bytes: body.length })).body;
  const u = new URL(p.url);
  expect((await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': contentType }, payload: body })).statusCode).toBe(200);
  return p.uploadId as string;
}

// ------------------------------------------------------------------ shared fixtures
describe('shared fixtures', () => {
  it('are what the reference implementation gives today (regenerate with scripts/editor-fixtures.ts) and the app copies are identical', () => {
    const dirs = ['android/core/src/test/resources/editor', 'mac/MuseCore/Tests/MuseCoreTests/Fixtures/editor'].map(d => path.join(repo, d));
    const before = Object.fromEntries(['presets.json', 'projects.json', 'validation.json', 'functions.json', 'looks.json', 'jsonpatch.json'].map(n => [n, fs.readFileSync(path.join(FIX, n), 'utf8')]));
    for (const d of dirs) for (const [n, body] of Object.entries(before)) expect(fs.readFileSync(path.join(d, n), 'utf8'), `${d}/${n}`).toBe(body);
    execFileSync(process.execPath, ['--import', 'tsx', path.join(here, '../scripts/editor-fixtures.ts')], { cwd: path.join(here, '..'), stdio: 'pipe' });
    for (const [n, body] of Object.entries(before)) expect(fs.readFileSync(path.join(FIX, n), 'utf8'), `${n} changed: commit the regenerated fixtures`).toBe(body);
  }, 30_000);

  it('every validation case gives the expected result and field', () => {
    for (const v of fx('validation.json') as { name: string; project: M.EditProject; ok: boolean; field?: string }[]) {
      let got: { ok: boolean; field?: string } = { ok: true };
      try { M.validate(v.project, FILTERS, LOOK_IDS); } catch (e) { got = { ok: false, field: (e as M.EditProblem).field }; }
      expect(got, v.name).toEqual(v.ok ? { ok: true } : { ok: false, field: v.field });
    }
  });

  it('projects: duration, timeline, captions, envelopes and colour from the reference', () => {
    for (const x of fx('projects.json') as { name: string; project: M.EditProject; expect: any }[]) {
      expect(M.durationSec(x.project), x.name).toBeCloseTo(x.expect.durationSec, 6);
      expect(M.timeline(x.project)).toEqual(x.expect.timeline);
      expect(M.captionPages(x.project).map(p => p.words.map(w => w.index))).toEqual(x.expect.captionPages.map((p: any) => p.words));
    }
  });
});

describe('model helpers', () => {
  const p = (fx('projects.json') as { project: M.EditProject }[])[2]!.project;
  it('transitions overlap clips; the duration shrinks by each transition', () => {
    expect(M.timeline(p).map(s => [s.startSec, s.endSec])).toEqual([[0, 4], [3.5, 6.5], [5.5, 8.5]]);
    expect(M.durationSec(p)).toBe(8.5);
  });
  it('v1 round trip; v2-only features make toV1 null', () => {
    const v1: M.EditListV1 = { version: 1, sourceTakeId: 't', sourceDurationSec: 10, segments: [{ inSec: 0, outSec: 3, speed: 1 }, { inSec: 4, outSec: 8, speed: 2, muted: true }], mute: false };
    const v2 = M.fromV1(v1, { width: 1080, height: 1920, fps: 30 });
    expect(M.durationSec(v2)).toBe(5);
    expect(M.toV1(v2)).toEqual(v1);
    expect(M.toV1(p)).toBeNull();
  });
  it('applyCuts splits around source ranges and drops slivers', () => {
    const one = M.fromV1({ version: 1, sourceTakeId: 't', sourceDurationSec: 10, segments: [{ inSec: 0, outSec: 10, speed: 1 }], mute: false }, { width: 16, height: 16, fps: 30 });
    const cut = M.applyCuts(one, 'src', [{ startSec: 2, endSec: 3 }, { startSec: 9.95, endSec: 10 }]);
    expect((cut.tracks[0]!.items as M.VideoClip[]).map(c => [c.id, c.inSec, c.outSec])).toEqual([['c1', 0, 2], ['c1.2', 3, 9.95]]);
    expect(M.applyCuts(one, 'src', [{ startSec: 0, endSec: 10 }])).toBe(one);
  });
  it('colour matrix: identity, exposure and mono', () => {
    expect(M.colorMatrix({}, undefined, FILTERS)).toEqual([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]);
    expect(M.colorMatrix({ exposure: 1 }, undefined, FILTERS)[0]).toBe(2);
    const mono = M.colorMatrix({}, { id: 'mono', amount: 1 }, FILTERS);
    expect(mono[0]).toBeCloseTo(mono[4]! * 0.2126 / 0.2126 * (mono[0]! / mono[4]!), 6); // rows equal: every channel the same luma
    expect(mono.slice(0, 3)).toEqual(mono.slice(4, 7));
  });
});

describe('cuts and transcripts', () => {
  it('suggestCuts finds silences, fillers and repeats', () => {
    const r = suggestCuts(mockWords(25), 25, { repeats: true });
    expect(r.cuts.some(c => c.reason === 'filler' && /um/i.test(c.text ?? ''))).toBe(true);
    expect(r.cuts.some(c => c.reason === 'silence')).toBe(true);
    expect(r.cuts.some(c => c.reason === 'repeat')).toBe(true);
    for (let i = 1; i < r.cuts.length; i++) expect(r.cuts[i]!.startSec).toBeGreaterThan(r.cuts[i - 1]!.endSec);
  });
  it('parseTranscript reads WhisperX words, fills missing times, and falls back to segments', () => {
    const t = parseTranscript({ detected_language: 'en', segments: [{ start: 0.5, end: 2, text: ' Hi 3 cats', words: [{ word: 'Hi', start: 0.5, end: 0.8, score: 0.9 }, { word: '3' }, { word: 'cats', start: 1.4, end: 2, score: 0.7 }] }] });
    expect(t.language).toBe('en');
    expect(t.words).toEqual([{ text: 'Hi', startSec: 0.5, endSec: 0.8, score: 0.9 }, { text: '3', startSec: 0.8, endSec: 1.4 }, { text: 'cats', startSec: 1.4, endSec: 2, score: 0.7 }]);
    expect(parseTranscript(JSON.stringify({ segments: [{ start: 0, end: 1, text: 'a b' }] })).words.map(w => [w.text, w.startSec, w.endSec])).toEqual([['a', 0, 0.5], ['b', 0.5, 1]]);
    expect(parseTranscript({ word_segments: [{ word: 'x', start: 1, end: 1.2 }] }).words).toHaveLength(1);
  });
  it('pickFile and adaptInput', () => {
    expect(pickFile('https://x/a.mp4')).toBe('https://x/a.mp4');
    expect(pickFile({ drums: 'https://x/d.mp3', vocals: 'https://x/v.mp3' }, ['vocals'])).toBe('https://x/v.mp3');
    expect(adaptInput({ audio_file: 'u', align_output: true, batch_size: 32 }, ['audio', 'align_output'])).toEqual({ audio: 'u', align_output: true });
    expect(adaptInput({ input_video: 'u' }, null)).toEqual({ input_video: 'u' });
  });
  it('silencedetect log → silences → padded cuts', () => {
    const log = '[silencedetect @ 0x1] silence_start: 0\n[silencedetect @ 0x1] silence_end: 0.8 | silence_duration: 0.8\nx\n[silencedetect @ 0x1] silence_start: 3.2\n[silencedetect @ 0x1] silence_end: 4.1 | silence_duration: 0.9\n[silencedetect @ 0x1] silence_start: 5.5\n[silencedetect @ 0x1] silence_start: 9.6\n';
    const sil = parseSilenceDetect(log, 10);
    expect(sil).toEqual([{ startSec: 0, endSec: 0.8 }, { startSec: 3.2, endSec: 4.1 }, { startSec: 9.6, endSec: 10 }]);
    expect(silenceCuts(sil, 10, { minSilenceSec: 0.7, keepPadSec: 0.1 })).toEqual({ cuts: [{ startSec: 0, endSec: 0.7, reason: 'silence' }, { startSec: 3.3, endSec: 4, reason: 'silence' }], savedSec: 1.4 });
  });

  it('noise suggestion from word confidence', () => {
    const w = (s: number) => Array.from({ length: 6 }, (_, i) => ({ text: 'a', startSec: i, endSec: i + 0.5, score: s }));
    expect(noiseSuggestion(w(0.5)).level).toBe('strong');
    expect(noiseSuggestion(w(0.7)).level).toBe('light');
    expect(noiseSuggestion(w(0.95)).level).toBe('none');
    expect(noiseSuggestion([]).level).toBe('none');
  });
});

describe('which provider runs the AI helpers (EDITOR_AI_PROVIDER)', () => {
  const ctxOf = (configured: boolean, env = 'development', dev = false) =>
    ({ replicate: { configured }, config: { GEN_MS: 20, NODE_ENV: env, DEV_MODE: dev } }) as any;
  const pick = (want: string | undefined, ctx: any) => {
    const before = process.env.EDITOR_AI_PROVIDER;
    if (want === undefined) delete process.env.EDITOR_AI_PROVIDER; else process.env.EDITOR_AI_PROVIDER = want;
    try { return makeProvider(ctx); } finally { if (before === undefined) delete process.env.EDITOR_AI_PROVIDER; else process.env.EDITOR_AI_PROVIDER = before; }
  };
  it('the mock unless the owner sets auto or replicate, even when the server has a Replicate token', () => {
    expect(pick(undefined, ctxOf(true)).name).toBe('mock');
    expect(pick('mock', ctxOf(true)).name).toBe('mock');
    expect(pick('auto', ctxOf(true)).name).toBe('replicate');
    expect(pick('auto', ctxOf(false)).name).toBe('mock');
    expect(pick('replicate', ctxOf(false)).name).toBe('replicate');
    expect(pick('something-else', ctxOf(true)).name).toBe('mock');
  });
  it('the mock is free in production (no hold, no charge) and priced elsewhere (tests exercise the money path)', () => {
    expect(pick(undefined, ctxOf(true, 'production')).rates).toEqual({ transcribe: 0, matte: 0, separate: 0, track: 0 });
    expect(pick(undefined, ctxOf(true, 'production', true)).rates.transcribe).toBeGreaterThan(0);
    expect(pick(undefined, ctxOf(true)).rates.transcribe).toBeGreaterThan(0);
  });
});

// ------------------------------------------------------------------ API on the mock provider
describe('editor AI jobs (mock provider)', () => {
  let a: A, owner: Client, member: Client, studioId: string, src: string;
  beforeAll(async () => {
    a = await makeApp();
    ({ owner, members: [member] } = await people(a, 1) as any);
    studioId = await studioOf(a);
    src = await videoTake(a, studioId, { durationSec: 25 });
  });
  afterAll(async () => { await a.close(); });
  const done = (id: string, c = owner) => until(async () => { const r = (await c.req('GET', `/v1/editor/jobs/${id}`)).body; return r.state !== 'running' ? r : null; });

  it('features and presets', async () => {
    const f = (await member.req('GET', '/v1/editor/features')).body;
    expect(f).toMatchObject({ captions: { available: true }, cuts: { available: true }, matte: { maxSec: 120 }, denoise: { available: true } });
    expect(JSON.stringify(f)).not.toMatch(/whisper|replicate|matting|demucs/i);
    const p = (await member.req('GET', '/v1/editor/presets')).body;
    expect(p.filters.length).toBeGreaterThan(5);
    expect(p.hooks).toHaveLength(10);
  });

  it('captions: estimate, hold, live progress, settle; then cuts reuse the transcript for free', async () => {
    await a.app.listen({ port: 0, host: '127.0.0.1' });
    const base = `http://127.0.0.1:${(a.app.server.address() as any).port}`;
    const es = await sse(base, owner.token);
    const est = (await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', source: { takeId: src } })).body;
    expect(est).toMatchObject({ kind: 'captions', free: false, reusesTranscript: false, durationSec: 25 });
    expect(est.usd).toBeCloseTo(Math.max(0.01, (8 + 0.15 * 25) * 0.0014 * 2), 3); // cost × 2 (EDITOR_MARKUP)
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'captions', source: { takeId: src }, options: { language: 'en' } })).body;
    expect(j).toMatchObject({ kind: 'captions', state: 'running', estimateUsd: est.usd });
    expect(j.models).toEqual(['mock/transcribe']); // owner view only
    const r = await done(j.id);
    expect(r.state).toBe('done');
    expect(r.result.words.length).toBeGreaterThan(10);
    expect(r.result.words[0]).toMatchObject({ text: 'Okay' });
    expect(r.progress).toBe(100);
    const evs = await until(() => { const e = es.events.filter(x => x.type === 'editor' && x.editorJob?.id === j.id); return e.some(x => x.editorJob.state === 'done') ? e : null; });
    expect(evs.some(e => e.editorJob.progress > 0 && e.editorJob.progress < 100)).toBe(true);
    await es.stop();
    const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id));
    expect(rows.map(x => x.kind).sort()).toEqual(['hold', 'settle']);
    expect(rows.find(x => x.kind === 'settle')!.amountUsd).toBeCloseTo(r.costUsd, 6);

    const est2 = (await owner.req('POST', '/v1/editor/estimate', { kind: 'cuts', source: { takeId: src } })).body;
    expect(est2).toMatchObject({ free: true, usd: 0, reusesTranscript: true });
    const c = (await owner.req('POST', '/v1/editor/jobs', { kind: 'cuts', source: { takeId: src }, options: { fromJobId: j.id, repeats: true } })).body;
    const cr = await done(c.id);
    expect(cr.state).toBe('done');
    expect(cr.costUsd).toBe(0);
    expect(cr.result.cuts.map((x: any) => x.reason)).toEqual(expect.arrayContaining(['filler', 'silence', 'repeat']));
    expect(cr.result.savedSec).toBeGreaterThan(0);
    expect(await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, c.id))).toHaveLength(0);
    // Analyze-only voice check is free and uses the transcript.
    const d = (await owner.req('POST', '/v1/editor/jobs', { kind: 'denoise', source: { takeId: src }, options: { analyzeOnly: true } })).body;
    const dr = await done(d.id);
    expect(dr.result.suggestion.level).toMatch(/none|light|strong/);
    expect(dr.costUsd).toBe(0);
  });

  it('matte and voice clean-up give an asset the app can use; matte is an alpha matte (no chroma key)', async () => {
    const m = (await owner.req('POST', '/v1/editor/jobs', { kind: 'matte', source: { takeId: src } })).body;
    const mr = await done(m.id);
    expect(mr.result).toMatchObject({ asset: { kind: 'video' }, alpha: true, mode: 'person' });
    expect(mr.result.chroma).toBeUndefined();
    // 2026-11-08: the mock's matte is its own all-white video (keep everything), never the source: with the apps applying
    // alphaMatte, the source as a matte made the clip's dark areas see-through.
    expect(mr.result.asset.take).toBeUndefined();
    expect(mr.result.asset.upload).toEqual(expect.any(String));
    expect(mr.result.asset.url).toMatch(/\/uploads\/g\/edit_[^/]+\.mp4$/);
    expect(fs.existsSync(WHITE_MATTE)).toBe(true);
    const v = (await owner.req('POST', '/v1/editor/jobs', { kind: 'denoise', source: { takeId: src } })).body;
    const vr = await done(v.id);
    expect(vr.result.asset).toMatchObject({ kind: 'audio' });
    expect(vr.costUsd).toBeGreaterThan(0);
  });

  it('tap to keep (workstream 1): points on a frame, priced first, tracked through the clip; checks', async () => {
    const pts = [{ x: 0.5, y: 0.4, t: 1 }, { x: 0.1, y: 0.9, keep: false }];
    const est = (await owner.req('POST', '/v1/editor/estimate', { kind: 'matte', source: { takeId: src }, options: { points: pts } })).body;
    const plain = (await owner.req('POST', '/v1/editor/estimate', { kind: 'matte', source: { takeId: src } })).body;
    expect(est.usd).toBeGreaterThan(0);
    expect(est.tokens).toBeGreaterThan(0);
    expect(est.usd).not.toBe(plain.usd); // its own price
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'matte', source: { takeId: src }, options: { points: pts } })).body;
    const r = await done(j.id);
    expect(r.state, JSON.stringify(r)).toBe('done');
    expect(r.result).toMatchObject({ alpha: true, mode: 'tracked', points: [{ x: 0.5, y: 0.4, t: 1, keep: true }, { x: 0.1, y: 0.9, t: 0, keep: false }] });
    expect(r.result.asset.take).toBeUndefined(); // the white matte, not the source
    expect(r.result.asset.upload).toEqual(expect.any(String));
    const bad = (o: unknown) => owner.req('POST', '/v1/editor/estimate', { kind: 'matte', source: { takeId: src }, options: { points: o } }).then(x => x.body.error as string);
    expect(await bad([])).toMatch(/1 to 10 points/);
    expect(await bad([{ x: 2, y: 0 }])).toMatch(/points.0.x/);
    expect(await bad([{ x: 0.5, y: 0.5, keep: false }])).toMatch(/at least one thing to keep/);
    expect(await bad([{ x: 0.5, y: 0.5, t: 100 }])).toMatch(/within the clip/);
    expect(await bad(Array.from({ length: 11 }, () => ({ x: 0.5, y: 0.5 })))).toMatch(/1 to 10 points/);
  });

  it('cancel gives the hold back; finished jobs can be removed; members only see their own', async () => {
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'matte', source: { takeId: src } })).body;
    expect((await owner.req('DELETE', `/v1/editor/jobs/${j.id}`)).body.state).toBe('cancelling');
    const r = await done(j.id);
    expect(r.state).toBe('cancelled');
    const kinds = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id))).map(x => x.kind).sort();
    expect(kinds).toEqual(['hold', 'release']);
    expect((await owner.req('DELETE', `/v1/editor/jobs/${j.id}`)).body.state).toBe('deleted');
    expect((await owner.req('GET', `/v1/editor/jobs/${j.id}`)).status).toBe(404);
    const mine = (await owner.req('GET', `/v1/editor/jobs?takeId=${src}`)).body;
    expect(mine.length).toBeGreaterThan(2);
    expect((await member.req('GET', '/v1/editor/jobs')).body).toEqual([]);
    expect((await member.req('GET', `/v1/editor/jobs/${mine[0].id}`)).status).toBe(404);
  });

  it('refuses: no tokens, too long, unknown kind, photo take, bad options, transcript of another video', async () => {
    expect((await member.req('POST', '/v1/editor/jobs', { kind: 'matte', source: { takeId: src } })).body.code).toBe('insufficient_tokens');
    const long = await videoTake(a, studioId, { durationSec: 200 });
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'matte', source: { takeId: long } })).status).toBe(400);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'blur', source: { takeId: src } })).status).toBe(400);
    const shot = await videoTake(a, studioId, { kind: 'shot' });
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', source: { takeId: shot } })).body.error).toMatch(/video take/);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'cuts', source: { takeId: src }, options: { minSilenceSec: 9 } })).status).toBe(400);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', source: { takeId: src }, options: { language: 'english' } })).status).toBe(400);
    const cap = (await a.ctx.db.select().from(editorJobs).where(and(eq(editorJobs.kind, 'captions'), eq(editorJobs.state, 'done'))))[0]!;
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'cuts', source: { takeId: long }, options: { fromJobId: cap.id } })).body.error).toMatch(/another video/);
    const fresh = await videoTake(a, studioId);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'denoise', source: { takeId: fresh }, options: { analyzeOnly: true } })).body.error).toMatch(/captions for this video first/);
  });

  it('silence-only cuts are free and come from the audio itself (ffmpeg silencedetect, no transcript)', async () => {
    const file = path.join(a.dir, 'tone.mp4');
    try {
      execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6', '-af', "volume='if(between(t,2,4),0,1)':eval=frame", '-c:a', 'aac', '-y', file]);
    } catch { return; } // no ffmpeg here: the route says "not available" (covered by the estimate below being skipped)
    const id = await videoTake(a, studioId, { durationSec: 6 });
    await a.ctx.storage.put(`c/${id}.mp4`, fs.readFileSync(file), 'video/mp4');
    const est = (await owner.req('POST', '/v1/editor/estimate', { kind: 'cuts', source: { takeId: id }, options: { silenceOnly: true } })).body;
    expect(est).toMatchObject({ free: true, usd: 0, reusesTranscript: false });
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'cuts', source: { takeId: id }, options: { silenceOnly: true, minSilenceSec: 1, keepPadSec: 0.1 } })).body;
    const r = await done(j.id);
    expect(r.state, JSON.stringify(r)).toBe('done');
    expect(r.costUsd).toBe(0);
    expect(r.result.cuts).toHaveLength(1);
    expect(r.result.cuts[0].reason).toBe('silence');
    expect(r.result.cuts[0].startSec).toBeCloseTo(2.1, 1);
    expect(r.result.cuts[0].endSec).toBeCloseTo(3.9, 1);
    expect(await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id))).toHaveLength(0);
  });

  it('uploads: audio presign, and jobs on an upload need its duration', async () => {
    const p = (await member.req('POST', '/v1/editor/uploads/presign', { contentType: 'audio/mp4', bytes: 10 })).body;
    expect(p).toMatchObject({ method: 'PUT' });
    expect((await member.req('POST', '/v1/editor/uploads/presign', { contentType: 'text/plain' })).status).toBe(400);
    const u = new URL(p.url);
    await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': 'audio/mp4' }, payload: Buffer.from('m4a') });
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', source: { uploadId: p.uploadId } })).body.error).toMatch(/durationSec/);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', source: { uploadId: p.uploadId, durationSec: 30 } })).body).toMatchObject({ free: false, durationSec: 30 });
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', source: { uploadId: 'up_nope', durationSec: 30 } })).status).toBe(404);
  });

  it('a restart fails running jobs and gives their holds back', async () => {
    const [u] = (await a.ctx.db.execute(sql`select id from users where role = 'owner' limit 1`) as any).rows;
    const hold = await a.ctx.money.hold({ id: u.id, studioId, role: 'owner' }, 'edj_stuck', 0.05, { perJob: false });
    await a.ctx.db.insert(editorJobs).values({ id: 'edj_stuck', studioId, userId: u.id, kind: 'captions', state: 'running', source: { takeId: src, durationSec: 25 }, mediaKey: 'x',
      options: {}, models: [], estimate: 0.05, holdTokens: hold, createdAt: Date.now() });
    const { EditorAiService } = await import('../src/editor/service.js');
    expect(await new EditorAiService(a.ctx).recover()).toBe(1);
    const [r] = await a.ctx.db.select().from(editorJobs).where(eq(editorJobs.id, 'edj_stuck'));
    expect(r!.state).toBe('failed');
    expect((await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, 'edj_stuck'))).map(x => x.kind).sort()).toEqual(['hold', 'release']);
  });
});

// ------------------------------------------------------------------ saving v2 projects
describe('versions with a v2 project', () => {
  let a: A, owner: Client, studioId: string, src: string;
  beforeAll(async () => {
    a = await makeApp();
    ({ owner } = await people(a, 0) as any);
    studioId = await studioOf(a);
    src = await videoTake(a, studioId);
  });
  afterAll(async () => { await a.close(); });
  const project = (): M.EditProject => {
    const p = JSON.parse(JSON.stringify((fx('projects.json') as { project: M.EditProject }[])[3]!.project)) as M.EditProject;
    p.sourceTakeId = src;
    p.assets[0]!.take = src;
    return p;
  };

  it('saves a v2 project (captions, cuts) as an edited version', async () => {
    const up = await upload(a, owner, 'clip', Buffer.from('edited v2'));
    const p = project();
    const r = await owner.req('POST', `/v1/takes/${src}/versions`, { uploadId: up, edits: p, durationSec: M.durationSec(p), width: 1080, height: 1920, fps: 30 });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body).toMatchObject({ kind: 'edit', parentTakeId: src, edits: { version: 2 } });
    expect((await owner.req('POST', '/v1/editor/validate', { project: p })).body).toMatchObject({ ok: true, durationSec: M.durationSec(p) });
  });

  it('refuses: wrong length, rule broken (field named), another studio\'s take, an upload that is not audio', async () => {
    const up = await upload(a, owner, 'clip', Buffer.from('edited v2 b'));
    const p = project();
    expect((await owner.req('POST', `/v1/takes/${src}/versions`, { uploadId: up, edits: p, durationSec: 3, width: 1080, height: 1920 })).body.error).toMatch(/durationSec/);
    const bad = project(); (bad.tracks[0]!.items[0] as M.VideoClip).speed = 12;
    expect((await owner.req('POST', `/v1/takes/${src}/versions`, { uploadId: up, edits: bad, durationSec: 7, width: 1080, height: 1920 })).body.error).toMatch(/^edits\.tracks\.0\.items\.0\.speed/);
    const other = project(); other.assets.push({ id: 'x', kind: 'audio', take: 'take_elsewhere' });
    expect((await owner.req('POST', '/v1/editor/validate', { project: other })).status).toBe(404);
    const img = await upload(a, owner, 'image', Buffer.from('jpg'));
    const wrong = project(); wrong.assets.push({ id: 'm', kind: 'audio', upload: img });
    expect((await owner.req('POST', '/v1/editor/validate', { project: wrong })).body.error).toMatch(/not an audio file/);
    expect((await owner.req('POST', '/v1/editor/validate', { project: { version: 2 } })).status).toBe(400);
    const big = project(); (big.tracks[1] as M.Track).caption!.words = Array.from({ length: 2990 }, (_, i) => ({ text: 'x'.repeat(60), startSec: i, endSec: i + 0.5 }));
    expect((await owner.req('POST', '/v1/editor/validate', { project: big })).body.error).toMatch(/at most 256 KB/);
  });

  it('the export "Label as AI-generated" choice is kept on the version (off unless sent)', async () => {
    const up = await upload(a, owner, 'clip', Buffer.from('edited v2 label'));
    const p = project();
    const r = await owner.req('POST', `/v1/takes/${src}/versions`, { uploadId: up, edits: p, durationSec: M.durationSec(p), width: 1080, height: 1920, aiLabel: true, name: '  Claude cut  ' });
    expect(r.body.aiLabel).toBe(true);
    expect(r.body.name).toBe('Claude cut');
    const up2 = await upload(a, owner, 'clip', Buffer.from('edited v2 nolabel'));
    expect((await owner.req('POST', `/v1/takes/${src}/versions`, { uploadId: up2, edits: p, durationSec: M.durationSec(p), width: 1080, height: 1920 })).body.aiLabel).toBeUndefined();
    expect((await owner.req('POST', '/v1/editor/uploads/presign', { contentType: 'video/quicktime' })).body).toMatchObject({ method: 'PUT' });
  });

  it('v1 lists still work unchanged', async () => {
    const up = await upload(a, owner, 'clip', Buffer.from('edited v1'));
    const r = await owner.req('POST', `/v1/takes/${src}/versions`, { uploadId: up, edits: { version: 1, sourceTakeId: src, sourceDurationSec: 10, segments: [{ inSec: 0, outSec: 5, speed: 1 }], mute: false }, durationSec: 5, width: 1080, height: 1920 });
    expect(r.status).toBe(200);
  });
});

// ------------------------------------------------------------------ the Replicate adapter on a fake Replicate
const PINS = { EDITOR_TRANSCRIBE_VERSION: 'v_whisper', EDITOR_MATTE_VERSION: 'v_rvm', EDITOR_SEPARATE_VERSION: 'v_demucs', EDITOR_TRACK_VERSION: 'v_sam2' };
describe('Replicate provider (fake Replicate on localhost)', () => {
  let a: A, owner: Client, server: http.Server, studioId: string, src: string;
  const creates: any[] = [];
  beforeAll(async () => {
    let n = 0;
    const schema = (props: string[]) => ({ components: { schemas: { Input: { properties: Object.fromEntries(props.map(p => [p, { type: 'string' }])) } } } });
    const MODELS: Record<string, any> = {
      'victor-upmeet/whisperx': { owner: 'victor-upmeet', name: 'whisperx', latest_version: { id: 'v_whisper', openapi_schema: schema(['audio_file', 'language', 'align_output', 'batch_size']) } },
      'arielreplicate/robust_video_matting': { owner: 'arielreplicate', name: 'robust_video_matting', latest_version: { id: 'v_rvm', openapi_schema: schema(['input_video', 'output_type']) } },
      'ryan5453/demucs': { owner: 'ryan5453', name: 'demucs', latest_version: { id: 'v_demucs', openapi_schema: schema(['audio', 'stem', 'output_format']) } },
      'meta/sam-2-video': { owner: 'meta', name: 'sam-2-video', latest_version: { id: 'v_sam2', openapi_schema: schema(['input_video', 'click_coordinates', 'click_labels', 'click_frames', 'click_object_ids', 'mask_type', 'output_video']) } },
    };
    const preds = new Map<string, any>();
    server = http.createServer((req, res) => {
      let body = '';
      req.on('data', c => (body += c));
      req.on('end', () => {
        const url = req.url ?? '';
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (url.startsWith('/files/')) { res.writeHead(200, { 'content-type': 'application/octet-stream' }); res.end(Buffer.from(`file ${url}`)); return; }
        if (req.headers.authorization !== 'Bearer r8_editor') return json(401, {});
        const m = /^\/v1\/models\/([^/]+\/[^/]+)$/.exec(url);
        if (m && req.method === 'GET') return MODELS[m[1]!] ? json(200, MODELS[m[1]!]) : json(404, {});
        if (url === '/v1/predictions' && req.method === 'POST') {
          const b = JSON.parse(body); creates.push(b);
          const id = `p${++n}`, port = (server.address() as any).port;
          const out = b.version === 'v_whisper' ? { detected_language: 'en', segments: [{ start: 0.2, end: 1.5, words: [{ word: 'Hello', start: 0.2, end: 0.6, score: 0.9 }, { word: 'um', start: 0.7, end: 0.9, score: 0.5 }, { word: 'there', start: 1.1, end: 1.5, score: 0.9 }] }] }
            : b.version === 'v_rvm' ? `http://127.0.0.1:${port}/files/green.mp4` : b.version === 'v_sam2' ? `http://127.0.0.1:${port}/files/tracked.mp4` : { vocals: `http://127.0.0.1:${port}/files/vocals.mp3`, no_vocals: `http://127.0.0.1:${port}/files/rest.mp3` };
          preds.set(id, { id, status: 'succeeded', output: out, metrics: { predict_time: 12.5 } });
          return json(201, { id, status: 'starting' });
        }
        const g = /^\/v1\/predictions\/([^/]+)$/.exec(url);
        if (g) return json(200, preds.get(g[1]!));
        json(404, {});
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    const port = (server.address() as any).port;
    process.env.EDITOR_AI_PROVIDER = 'auto'; // the owner switched the helpers on (the default is the mock)
    // The fake catalog's versions stand in for the pinned ones (workstream 1: production pins real version ids).
    Object.assign(process.env, PINS);
    a = await makeApp({ REPLICATE_API_TOKEN: 'r8_editor', REPLICATE_API_URL: `http://127.0.0.1:${port}/v1`, REPLICATE_POLL_MS: '10' });
    ({ owner } = await people(a, 0) as any);
    studioId = await studioOf(a);
    src = await videoTake(a, studioId, { durationSec: 8 });
  });
  afterAll(async () => { delete process.env.EDITOR_AI_PROVIDER; for (const k of Object.keys(PINS)) delete process.env[k]; await a.close(); server.close(); });
  const done = (id: string) => until(async () => { const r = (await owner.req('GET', `/v1/editor/jobs/${id}`)).body; return r.state !== 'running' ? r : null; });

  it('captions run the transcription model by version and settle at the billed GPU time', async () => {
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'captions', source: { takeId: src } })).body;
    expect(j.models).toEqual(['victor-upmeet/whisperx']);
    const r = await done(j.id);
    expect(r.state, JSON.stringify(r)).toBe('done');
    expect(r.result.words.map((w: any) => w.text)).toEqual(['Hello', 'um', 'there']);
    expect(r.costUsd).toBeCloseTo(12.5 * 0.0014 * 2, 6); // billed GPU time × rate × 2
    const c = creates.find(x => x.version === 'v_whisper');
    expect(c.input).toMatchObject({ align_output: true, batch_size: 32 });
    expect(c.input.audio_file).toMatch(/^http/);
  });

  it('matte and voice clean-up copy the output into storage as a studio upload', async () => {
    const m = (await owner.req('POST', '/v1/editor/jobs', { kind: 'matte', source: { takeId: src } })).body;
    const mr = await done(m.id);
    expect(mr.state, JSON.stringify(mr)).toBe('done');
    expect(mr.result.asset).toMatchObject({ kind: 'video', upload: expect.stringMatching(/^up_/) });
    expect(creates.find(x => x.version === 'v_rvm').input).toMatchObject({ output_type: 'alpha-mask' }); // fix 1: the matte, not a green composite
    const stored = await a.app.inject({ method: 'GET', url: new URL(mr.result.asset.url, 'http://x').pathname });
    expect(stored.body).toBe('file /files/green.mp4');
    // Tap to keep: the points in pixels and frames of the source (1080 × 1920 at 30 fps here), one object, a binary mask.
    const t = (await owner.req('POST', '/v1/editor/jobs', { kind: 'matte', source: { takeId: src }, options: { points: [{ x: 0.5, y: 0.25, t: 2 }, { x: 0, y: 1, keep: false }] } })).body;
    expect(t.models).toEqual(['meta/sam-2-video']); // the owner sees the model
    const tr = await done(t.id);
    expect(tr.state, JSON.stringify(tr)).toBe('done');
    expect(creates.find(x => x.version === 'v_sam2').input).toMatchObject({ click_coordinates: '[540,480],[0,1919]', click_labels: '1,0', click_frames: '60,0', mask_type: 'binary', output_video: true });
    expect(tr.result).toMatchObject({ alpha: true, mode: 'tracked', asset: { kind: 'video', upload: expect.stringMatching(/^up_/) } });
    expect(tr.costUsd).toBeGreaterThan(0);
    const d = (await owner.req('POST', '/v1/editor/jobs', { kind: 'denoise', source: { takeId: src } })).body;
    const dr = await done(d.id);
    expect(dr.result.asset).toMatchObject({ kind: 'audio', upload: expect.stringMatching(/^up_/) });
    expect(creates.find(x => x.version === 'v_demucs').input).toMatchObject({ stem: 'vocals' });
    // Beat-only audio for other features (workstream 4): the other stem of the same split.
    const svc = new (await import('../src/editor/providers.js')).ReplicateProvider(a.ctx);
    const beat = await svc.separate('https://x/in.mp4', 8, { cancelled: () => false }, 'no_vocals');
    expect(fs.readFileSync(beat.file!, 'utf8')).toBe('file /files/rest.mp3');
    fs.rmSync(beat.file!, { force: true });
    // The saved voice can be used in a project.
    const p = M.fromV1({ version: 1, sourceTakeId: src, sourceDurationSec: 8, segments: [{ inSec: 0, outSec: 8, speed: 1 }], mute: false }, { width: 1080, height: 1920, fps: 30 });
    p.assets.push({ id: 'voice', kind: 'audio', upload: dr.result.asset.upload, durationSec: 8 });
    (p.tracks[0]!.items[0] as M.VideoClip).audioAsset = 'voice';
    expect((await owner.req('POST', '/v1/editor/validate', { project: p })).body).toMatchObject({ ok: true });
  });
});

describe('Edit suite additions', () => {
  it('beats: a free job finds the tempo of a click track', async () => {
    const { execFileSync } = await import('node:child_process');
    const a = await makeApp();
    try {
      const { owner } = await people(a, 0) as any;
      const file = path.join(a.dir, 'clicks.m4a');
      try {
        execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', "aevalsrc='if(lt(mod(t,0.5),0.03),sin(2*PI*1000*t),0)':s=22050:d=12", '-c:a', 'aac', '-y', file]);
      } catch { return; }
      const studio = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id;
      const p = (await owner.req('POST', '/v1/editor/uploads/presign', { contentType: 'audio/mp4' })).body;
      const u = new URL(p.url);
      await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': 'audio/mp4' }, payload: fs.readFileSync(file) });
      void studio;
      const est = (await owner.req('POST', '/v1/editor/estimate', { kind: 'beats', source: { uploadId: p.uploadId, durationSec: 12 } })).body;
      expect(est).toMatchObject({ free: true, usd: 0 });
      const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'beats', source: { uploadId: p.uploadId, durationSec: 12 } })).body;
      const r = await until(async () => { const x = (await owner.req('GET', `/v1/editor/jobs/${j.id}`)).body; return x.state !== 'running' ? x : null; });
      expect(r.state, JSON.stringify(r)).toBe('done');
      expect(r.result.bpm).toBeGreaterThan(118);
      expect(r.result.bpm).toBeLessThan(122);
      expect(r.result.beats.length).toBeGreaterThan(18);
      expect(r.result.strong.length).toBeGreaterThan(3);
      expect(r.costUsd).toBe(0);
    } finally { await a.close(); }
  });
});
