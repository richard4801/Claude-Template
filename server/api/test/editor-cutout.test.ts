// Cut-out of a still (src/editor/cutout.ts, kind "cutout"): a photo's background removed as a transparent PNG through
// the matte helpers we already run (person: RVM; taps: SAM 2), on a one-second clip of the photo. Unit: the matte's
// alpha on the photo, trimmed; upright from EXIF; nothing kept is an error. Job (mock provider): priced like matte /
// track, a PNG upload with alpha, taps in pixels at frame 0, members don't see the model, the owner's switch.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq, sql } from 'drizzle-orm';
import { ledger, takes } from '../src/db/schema.js';
import { CUTOUT_LIMITS, composeCutout, prepareStill } from '../src/editor/cutout.js';
import { MockProvider, type Hooks, type TrackPoint } from '../src/editor/providers.js';
import { EditorAiService, GPU_SEC } from '../src/editor/service.js';
import { makeApp, people, until, type Client } from './helpers.js';
import { hasFfmpeg } from './recreate-fixture.js';

describe.skipIf(!hasFfmpeg)('cut-out (unit)', () => {
  let dir: string;
  beforeAll(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-cutout-')); });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));
  const f = (n: string) => path.join(dir, n);

  it('the photo upright (EXIF), as a one-second clip; the matte becomes its alpha, trimmed to the subject', async () => {
    // A 600 × 400 photo stored sideways (EXIF orientation 6: shown 400 × 600).
    await sharp({ create: { width: 600, height: 400, channels: 3, background: { r: 200, g: 40, b: 40 } } }).jpeg().withMetadata({ orientation: 6 }).toFile(f('photo.jpg'));
    const size = await prepareStill('ffmpeg', f('photo.jpg'), f('still.png'), f('clip.mp4'));
    expect(size).toEqual({ width: 400, height: 600 });
    const dur = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f('clip.mp4')]).toString());
    expect(Math.abs(dur - CUTOUT_LIMITS.clipSec)).toBeLessThan(0.15);
    // The matte a helper would give: white where the subject is (x 100–299, y 150–449), black elsewhere.
    execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=400x600:r=10:d=1', '-vf', 'drawbox=x=100:y=150:w=200:h=300:c=white:t=fill', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', f('matte.mp4')]);
    const c = await composeCutout('ffmpeg', f('still.png'), f('matte.mp4'), f('mask.png'), f('out.png'));
    const pad = Math.round(600 * CUTOUT_LIMITS.padPct);
    expect(Math.abs(c.box.x - (100 - pad))).toBeLessThanOrEqual(2); expect(Math.abs(c.box.y - (150 - pad))).toBeLessThanOrEqual(2);
    expect(Math.abs(c.box.w - (200 + 2 * pad))).toBeLessThanOrEqual(3); expect(Math.abs(c.box.h - (300 + 2 * pad))).toBeLessThanOrEqual(3);
    const { data, info } = await sharp(f('out.png')).raw().toBuffer({ resolveWithObject: true });
    expect(info.channels).toBe(4);
    expect([info.width, info.height]).toEqual([c.width, c.height]);
    const at = (x: number, y: number) => data[(y * info.width + x) * 4 + 3]!;
    expect(at(1, 1)).toBeLessThan(10); // the trimmed margin is transparent
    expect(at(Math.floor(info.width / 2), Math.floor(info.height / 2))).toBeGreaterThan(245); // the subject is solid
    expect(data[(Math.floor(info.height / 2) * info.width + Math.floor(info.width / 2)) * 4]).toBeGreaterThan(150); // and keeps its colour
  });

  it('a matte that keeps nothing is an error, not an empty sticker', async () => {
    await sharp({ create: { width: 200, height: 200, channels: 3, background: '#888' } }).png().toFile(f('p2.png'));
    await prepareStill('ffmpeg', f('p2.png'), f('s2.png'), f('c2.mp4'));
    execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=200x200:r=10:d=1', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', f('m2.mp4')]);
    await expect(composeCutout('ffmpeg', f('s2.png'), f('m2.mp4'), f('k2.png'), f('o2.png'))).rejects.toThrow(/Nothing to cut out/);
  });
});

describe.skipIf(!hasFfmpeg)('cut-out job (mock provider)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, studioId: string;
  const tracked: TrackPoint[][] = [];
  beforeAll(async () => {
    a = await makeApp();
    const p = await people(a, 1);
    owner = p.owner; member = p.members[0]!;
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: (member as any).id, tokens: 1000, note: 'test' });
    studioId = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id as string;
    // The tracker records the points it gets.
    const svc = (await import('../src/editor/service.js')).editorAi(a.ctx);
    const mock = svc.provider as MockProvider;
    const orig = mock.track.bind(mock);
    mock.track = async (url: string, d: number, pts: TrackPoint[], h: Hooks) => { tracked.push(pts); return orig(url, d, pts, h); };
  }, 60_000);
  afterAll(async () => { await a.close(); });

  const photo = async (w = 1200, h = 1600) => {
    const id = `shot_${Math.random().toString(16).slice(2, 10)}`;
    await a.ctx.storage.put(`s/${id}.png`, await sharp({ create: { width: w, height: h, channels: 3, background: { r: 20, g: 120, b: 220 } } }).png().toBuffer(), 'image/png');
    await a.ctx.db.insert(takes).values({ id, studioId, userId: null, kind: 'shot', jobId: null, modelId: null, index: 1, of: 1, title: 'p', label: '', engineLabel: '', cost: 0, seed: 0,
      status: 'final', thumb: null, prompt: '', mediaKey: `s/${id}.png`, media: { width: w, height: h, contentType: 'image/png' }, createdAt: Date.now() });
    return id;
  };
  const done = (c: Client, id: string) => until(async () => { const x = (await c.req('GET', `/v1/editor/jobs/${id}`)).body; return x.state !== 'running' ? x : null; }, 30_000);

  it('a person cut-out: priced like the matte, a transparent PNG upload, settled; taps go to the tracker at frame 0', async () => {
    const src = await photo();
    expect((await owner.req('GET', '/v1/editor/features')).body.cutout).toMatchObject({ available: true });
    const est = (await owner.req('POST', '/v1/editor/estimate', { kind: 'cutout', source: { takeId: src } })).body;
    expect(est.usd).toBeCloseTo(Math.max(0.01, GPU_SEC.matte(1) * 0.000975 * 2), 3);
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'cutout', source: { takeId: src } })).body;
    expect(j.models).toEqual(['mock/matte']);
    const r = await done(owner, j.id);
    expect(r.state, JSON.stringify(r)).toBe('done');
    expect(r.result).toMatchObject({ mode: 'person', asset: { kind: 'image', upload: expect.stringMatching(/^up_/) }, sourceWidth: 1200, sourceHeight: 1600 });
    const png = (await a.app.inject({ method: 'GET', url: new URL(r.result.asset.url, 'http://x').pathname })).rawPayload;
    const meta = await sharp(png).metadata();
    expect(meta.format).toBe('png'); expect(meta.channels).toBe(4);
    expect((await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id))).map(x => x.kind).sort()).toEqual(['hold', 'settle']);
    expect(fs.existsSync(path.join(a.dir, 't')) ? fs.readdirSync(path.join(a.dir, 't')).filter(n => n.startsWith('cutin')) : []).toEqual([]); // the clip sent out is gone

    // Taps (any object): the tracker, priced like it, the points in the photo's pixels at frame 0.
    const m = (await member.req('POST', '/v1/editor/jobs', { kind: 'cutout', source: { takeId: src }, options: { points: [{ x: 0.5, y: 0.25 }, { x: 0, y: 1, keep: false }] } })).body;
    expect(m.models).toBeUndefined();
    expect(m.estimateUsd).toBeCloseTo(Math.max(0.01, GPU_SEC.track(1) * 0.000975 * 2), 3);
    const mr = await done(member, m.id);
    expect(mr.state, JSON.stringify(mr)).toBe('done');
    expect(mr.result).toMatchObject({ mode: 'tracked', points: [{ x: 0.5, y: 0.25, t: 0, keep: true }, { x: 0, y: 1, t: 0, keep: false }] });
    expect(tracked.at(-1)).toEqual([{ x: 0.5 * 1199, y: 0.25 * 1599, frame: 0, keep: true }, { x: 0, y: 1599, frame: 0, keep: false }]);
    expect(JSON.stringify(mr)).not.toMatch(/mock|replicate|sam|rvm|matting/i);
  }, 60_000);

  it('refuses a video, a bad tap; "coming soon" on the production mock; the owner\'s switch stops it', async () => {
    const vid = `take_${Math.random().toString(16).slice(2, 10)}`;
    await a.ctx.db.insert(takes).values({ id: vid, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'v', label: '', engineLabel: '', cost: 0, seed: 0,
      status: 'final', thumb: null, prompt: '', mediaKey: `c/${vid}.mp4`, media: { durationSec: 5, width: 1080, height: 1920, contentType: 'video/mp4' }, createdAt: Date.now() });
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'cutout', source: { takeId: vid } })).body.error).toMatch(/must be a photo/);
    const src = await photo(400, 400);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'cutout', source: { takeId: src }, options: { points: [{ x: 2, y: 0 }] } })).body.error).toMatch(/points.0.x/);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'cutout', source: { takeId: src }, options: { points: [{ x: 0.5, y: 0.5, keep: false }] } })).body.error).toMatch(/at least one thing to keep/);
    const prodCtx = { ...a.ctx, config: { ...a.ctx.config, NODE_ENV: 'production', DEV_MODE: false } } as typeof a.ctx;
    const prodMock = new EditorAiService(prodCtx, new MockProvider(5));
    expect((await prodMock.features()).cutout).toMatchObject({ available: false });
    await expect(prodMock.estimate({ id: 'u', studioId, role: 'owner' } as any, { kind: 'cutout', source: { takeId: src } })).rejects.toThrow(/coming soon/);
    await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'off' });
    expect((await owner.req('POST', '/v1/editor/jobs', { kind: 'cutout', source: { takeId: src } })).status).toBe(503);
    await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'on' });
  });
});
