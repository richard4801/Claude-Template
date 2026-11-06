// AI suite (workstream 1): Extend — a longer take from a finished one (suite/extend.ts, runner join). No money: unit
// tests on the plan and inputs, and runs on the mock provider (real ffmpeg for the trim, bridge frame and join).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { clips } from '../src/db/schema.js';
import { putObject } from '../src/storage/objects.js';
import { buildExtendPlan, pickExtend } from '../src/suite/extend.js';
import { buildInput } from '../src/suite/inputs.js';
import { ShotRequestSchema } from '../src/suite/plan.js';
import { modelById } from '../src/suite/registry.js';
import { makeApp, people, until, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const providers = new Set(['replicate', 'fal', 'mock'] as const);
const req = (x: object) => ShotRequestSchema.parse({ mode: 'extend', extend: { video: { key: 'clips/src.mp4' } }, duration: 5, ...x });

describe('Extend · plan (unit)', () => {
  it('picks a true continuation first, a reference model for "before", and the frame bridge last', () => {
    const after = pickExtend('draft', { direction: 'after', sourceSeconds: 20, seconds: 5, aspect: '9:16' }, { providers: providers as any });
    expect('model' in after && [after.model.id, after.method]).toEqual(['wan-2.7', 'clip']);
    const before = pickExtend('draft', { direction: 'before', sourceSeconds: 20, seconds: 5, aspect: '9:16' }, { providers: providers as any });
    expect('model' in before && [before.model.id, before.method]).toEqual(['seedance-2.5', 'reference']);
    const off = { models: { 'seedance-2.5': { enabled: false }, 'wan-2.7': { enabled: false } } };
    const bridge = pickExtend('hd', { direction: 'before', sourceSeconds: 20, seconds: 5, aspect: '9:16' }, { providers: providers as any, prefs: off as any });
    expect('model' in bridge && [bridge.model.id, bridge.method]).toEqual(['kling-v4', 'frame']);
    const none = pickExtend('draft', { direction: 'after', sourceSeconds: 1, seconds: 5, aspect: '9:16' }, { providers: providers as any, prefs: { models: { 'kling-v4': { enabled: false } } } as any });
    expect('error' in none && none.tried.map(t => t.why)).toEqual(['source at least 2 s', 'source at least 2 s', 'switched off']);
  });

  it('plans: what is sent, the prompt, the price; adapters map the source', () => {
    const r = req({ prompt: 'She waves goodbye.', quality: 'draft' });
    const p = pickExtend('draft', { direction: 'after', sourceSeconds: 20, seconds: 5, aspect: '9:16' }, { providers: providers as any });
    if (!('model' in p)) throw new Error('no pick');
    const plan = buildExtendPlan(r, p, { key: 'clips/src.mp4', seconds: 20 }, {});
    expect(plan).toMatchObject({ mode: 'extend', modelId: 'wan-2.7', kind: 'i2v', seconds: 5, extend: { direction: 'after', method: 'clip', join: true, useSeconds: 10 } });
    expect(plan.videos).toEqual([{ video: { key: 'clips/src.mp4', seconds: 10 }, use: 'source' }]);
    expect(plan.prompt).toMatch(/^Continue the source clip seamlessly.*Next: She waves goodbye\./);
    expect(plan.notes).toContain('only the last 10 s of the clip are sent to continue from');
    expect(buildInput(modelById('wan-2.7')!, plan, { middle: [], refs: [], videos: ['https://x/part.mp4'] })).toMatchObject({ first_clip: 'https://x/part.mp4', duration: 5 });
    expect(buildInput(modelById('wan-2.7')!, plan, { middle: [], refs: [], videos: ['https://x/part.mp4'] }).first_frame).toBeUndefined();

    const rb = req({ extend: { video: { key: 'clips/src.mp4' }, direction: 'before' }, quality: 'hd' });
    const pb = pickExtend('hd', { direction: 'before', sourceSeconds: 8, seconds: 5, aspect: '9:16' }, { providers: providers as any });
    if (!('model' in pb)) throw new Error('no pick');
    const sb = buildExtendPlan(rb, pb, { key: 'clips/src.mp4', seconds: 8 }, {});
    expect(sb.prompt).toMatch(/moments just before \[Video1\], ending exactly where \[Video1\] begins/);
    expect(buildInput(modelById('seedance-2.5')!, sb, { middle: [], refs: [], videos: ['https://x/src.mp4'] })).toMatchObject({ reference_videos: ['https://x/src.mp4'] });
    expect(sb.perSec).toBe(0.9676); // video references cost more
    expect(sb.estimate).toBeCloseTo(0.9676 * 5, 4);

    const off = { models: { 'seedance-2.5': { enabled: false }, 'wan-2.7': { enabled: false } } };
    const pf = pickExtend('hd', { direction: 'before', sourceSeconds: 8, seconds: 5, aspect: '9:16' }, { providers: providers as any, prefs: off as any });
    if (!('model' in pf)) throw new Error('no pick');
    const sf = buildExtendPlan(rb, pf, { key: 'clips/src.mp4', seconds: 8 }, {});
    expect(sf.videos).toEqual([]);
    expect(sf.prompt).toMatch(/^The shot ends exactly on the given last frame/);
    const fi = buildInput(modelById('kling-v4')!, sf, { end: 'https://x/bridge.jpg', middle: [], refs: [], videos: [] });
    expect(fi).toMatchObject({ end_image: 'https://x/bridge.jpg' });
    expect(fi.start_image).toBeUndefined();
  });
});

describe.skipIf(!hasFfmpeg)('Extend · API on the mock provider', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, dir: string;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-extend-'));
    const f = path.join(dir, 'src.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=180x320:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=330', '-t', '4', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', f]);
    const [o] = await a.ctx.db.execute((await import('drizzle-orm')).sql`select studio_id from users where id = ${owner.id}`).then((r: any) => r.rows ?? r);
    await putObject(a.ctx, { key: 'clips/src.mp4', body: fs.readFileSync(f), studioId: o.studio_id, kind: 'clip', contentType: 'video/mp4' });
    await a.ctx.db.insert(clips).values({ id: 'c_src', studioId: o.studio_id, name: 'source', durationSec: 4, width: 180, height: 320, fps: 24, meta: {}, checks: [], storageKey: 'clips/src.mp4', createdAt: Date.now() });
  });
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const done = (id: string) => until(async () => { const j = (await owner.req('GET', `/v1/suite/shots/${id}`)).body.job; return j?.state === 'done' || j?.state === 'failed' ? j : null; }, 30_000);

  it('estimate: Extend label and price; members get no engine; a video outside the studio is refused', async () => {
    const e = await member.req('POST', '/v1/suite/shots/estimate', { mode: 'extend', extend: { video: { key: 'clips/src.mp4' } }, duration: 5, quality: 'draft' });
    expect(e.status).toBe(200);
    expect(e.body).toMatchObject({ mode: 'extend', label: 'Extend · Draft · 720p', seconds: 5, test: true });
    expect(e.body.engine).toBeUndefined();
    expect((await member.req('POST', '/v1/suite/shots/estimate', { mode: 'extend', extend: { video: { key: 'clips/other.mp4', seconds: 4 } } })).body.error).toMatch(/isn’t in this studio/);
    expect((await member.req('POST', '/v1/suite/shots/estimate', { mode: 'extend' })).body.error).toMatch(/needs the video/);
  });

  it('after: one take = source + extension (real join), the extension kept apart; then extending that take backwards', async () => {
    const r = (await owner.req('POST', '/v1/suite/shots', { mode: 'extend', extend: { video: { key: 'clips/src.mp4' } }, prompt: 'She turns away.', duration: 3, quality: 'draft' })).body;
    expect(r.request).toMatchObject({ engine: 'suite', mode: 'extend', engineLabel: 'Extend · Draft · 720p' });
    const j = await done(r.id);
    expect(j.state).toBe('done');
    const t = (await owner.req('GET', '/v1/takes')).body.find((x: any) => x.jobId === r.id);
    expect(t.durationSec).toBeGreaterThan(6.5); // 4 s source + 3 s extension
    expect(t.durationSec).toBeLessThan(7.6);
    const row = await a.ctx.jobs.get(r.id);
    expect((row!.outputs as any[]).map(o => o.name)).toEqual(['take_1.mp4', 'extension_1.mp4']);
    // Extend the new take backwards (a take is a valid source).
    const takeKey = (row!.outputs as any[])[0].key;
    const b = (await owner.req('POST', '/v1/suite/shots', { mode: 'extend', extend: { video: { key: takeKey }, direction: 'before' }, duration: 2, quality: 'draft' })).body;
    const jb = await done(b.id);
    expect(jb.state).toBe('done');
    const tb = (await owner.req('GET', '/v1/takes')).body.find((x: any) => x.jobId === b.id);
    expect(tb.durationSec).toBeGreaterThan(t.durationSec + 1.5);
  });
});
