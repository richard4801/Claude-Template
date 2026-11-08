// Recreate this edit · per-frame poses for matching takes by movement (workstream 1; the coordinator's G2 refinements):
// the one-euro filter, dropped joints, the body-frame comparison, and MoveNet over every frame in chunks (the mannequin
// preview sliding across the frame). Free: CPU.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { POSE_MODEL } from '../src/recreate/pose.js';
import { KEYPOINTS, type Keypoint } from '../src/recreate/poseWorker.js';
import { normalizePose, OneEuro, POSE_CHUNK, poseDistance, poseSimilarity, readPoseTracks, smoothTrack, type Joint, type PoseTrack } from '../src/recreate/poseTrack.js';
import { scoreTake } from '../src/recreate/slots.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';
import { sql } from 'drizzle-orm';
import { takes } from '../src/db/schema.js';
import { putObject } from '../src/storage/objects.js';
import { makeApp, people, until, type Client } from './helpers.js';

const MANNEQUIN = path.resolve(__dirname, '../../../design/previews/angles/full.webp');
// A standing figure (0–1 frame coordinates), arms down or up; `dx`, `s` move and scale it in the frame.
const BODY: Record<string, [number, number]> = {
  nose: [0.5, 0.2], left_eye: [0.49, 0.19], right_eye: [0.51, 0.19], left_ear: [0.48, 0.2], right_ear: [0.52, 0.2],
  left_shoulder: [0.45, 0.3], right_shoulder: [0.55, 0.3], left_elbow: [0.43, 0.4], right_elbow: [0.57, 0.4], left_wrist: [0.42, 0.5], right_wrist: [0.58, 0.5],
  left_hip: [0.47, 0.55], right_hip: [0.53, 0.55], left_knee: [0.47, 0.7], right_knee: [0.53, 0.7], left_ankle: [0.47, 0.85], right_ankle: [0.53, 0.85],
};
const UP = { left_elbow: [0.42, 0.22], right_elbow: [0.58, 0.22], left_wrist: [0.41, 0.12], right_wrist: [0.59, 0.12] } as Record<string, [number, number]>;
const pose = (o: { up?: number; dx?: number; s?: number } = {}): Joint[] => KEYPOINTS.map(n => {
  const a = BODY[n]!, b = UP[n] ?? a, k = o.up ?? 0, s = o.s ?? 1;
  const x = a[0] + (b[0] - a[0]) * k, y = a[1] + (b[1] - a[1]) * k;
  return [0.5 + (x - 0.5) * s + (o.dx ?? 0), 0.5 + (y - 0.5) * s];
});
const track = (n: number, f: (i: number) => Joint[] | null, fps = 30): PoseTrack => ({ fps, frames: Array.from({ length: n }, (_, i) => f(i)) });
const kps = (p: Joint[], score = 0.8): Keypoint[] => KEYPOINTS.map((name, j) => ({ name, x: p[j]![0], y: p[j]![1], score }));

describe('Per-frame poses (unit)', () => {
  it('the one-euro filter quiets jitter at rest and follows a fast move with little lag', () => {
    const f = new OneEuro(30);
    const noisy = Array.from({ length: 60 }, (_, i) => 0.5 + (i % 2 ? 0.01 : -0.01));
    const out = noisy.map(v => f.filter(v));
    const spread = (xs: number[]) => Math.max(...xs) - Math.min(...xs);
    expect(spread(out.slice(20))).toBeLessThan(spread(noisy.slice(20)) / 2);
    const g = new OneEuro(30), step = Array.from({ length: 12 }, (_, i) => (i < 2 ? 0.2 : 0.8));
    const followed = step.map(v => g.filter(v));
    expect(followed[7]!).toBeGreaterThan(0.7); // within ~5 frames of the jump
  });
  it('weak joints are dropped (never invented); a frame with no one in it is null', () => {
    const p = kps(pose());
    p[KEYPOINTS.indexOf('left_wrist')]!.score = 0.1;
    const t = smoothTrack([p, kps(pose(), 0.05)], 30);
    expect(t.frames[0]![KEYPOINTS.indexOf('left_wrist')]).toBeNull();
    expect(t.frames[0]![KEYPOINTS.indexOf('nose')]).toEqual([0.5, 0.2]);
    expect(t.frames[1]).toBeNull();
  });
  it('poses are compared in the body’s own frame: moving or scaling the figure changes nothing, raising the arms does', () => {
    const a = normalizePose(pose())!, moved = normalizePose(pose({ dx: 0.2, s: 0.6 }))!, up = normalizePose(pose({ up: 1 }))!;
    expect(poseDistance(a, moved)!).toBeLessThan(1e-6);
    expect(poseDistance(a, up)!).toBeGreaterThan(0.2);
    expect(normalizePose(KEYPOINTS.map(() => null))).toBeNull();
  });
  it('similarity: the same movement anywhere in frame is ~1; other poses or another pace score lower; no one in frame = null', () => {
    const wave = (i: number, o: { dx?: number; s?: number; speed?: number } = {}) => pose({ up: (Math.sin(i / 30 * Math.PI * 2 * (o.speed ?? 1)) + 1) / 2, dx: o.dx, s: o.s });
    const shot = track(60, i => wave(i));
    const same = poseSimilarity(shot, track(60, i => wave(i, { dx: 0.15, s: 0.7 }), 30), 2)!;
    expect(same.score).toBeGreaterThan(0.95);
    expect(same.coverage).toBe(1);
    const still = poseSimilarity(shot, track(60, () => pose()), 2)!;
    const arms = poseSimilarity(track(60, () => pose({ up: 1 })), track(60, () => pose()), 2)!;
    expect(still.score).toBeLessThan(same.score - 0.15);
    expect(arms.score).toBeLessThan(0.6);
    // A take at 10 fps and longer than the shot: its first 2 s are compared.
    expect(poseSimilarity(shot, track(50, i => wave(i * 3), 10), 2)!.score).toBeGreaterThan(0.9);
    expect(poseSimilarity(shot, track(60, () => null), 2)).toBeNull();
    // Walking across the frame against standing in place (the same pose): the travel tells them apart.
    const walk = track(60, i => pose({ dx: -0.3 + i * 0.01 }));
    expect(poseSimilarity(walk, track(60, i => pose({ dx: -0.2 + i * 0.008, s: 0.8 })) /* a smaller figure covering as many body lengths */, 2)!.score).toBeGreaterThan(0.95);
    expect(poseSimilarity(walk, track(60, () => pose()), 2)!.score).toBeLessThan(0.75);
  });
  it('in the take score: a strong weight, with the reason shown', () => {
    const slot = { id: 's1', durationSec: 2, rig: null, brief: null } as any;
    const t = { id: 't1', modelId: null, durationSec: 3, width: 1080, height: 1920, status: 'test', createdAt: 0, draft: null, title: 't1' } as const;
    const plain = scoreTake(slot, '9:16', t), alike = scoreTake(slot, '9:16', t, { pose: { score: 0.9 } }), unlike = scoreTake(slot, '9:16', t, { pose: { score: 0.2 } });
    expect(alike.reasons).toContain('moves alike (90%)');
    expect(alike.score).toBeGreaterThan(unlike.score + 0.2);
    expect(plain.reasons).not.toContain('moves alike (90%)');
  });
});

describe.skipIf(!hasFfmpeg || !fs.existsSync(POSE_MODEL))('Per-frame poses · MoveNet over every frame, in chunks', () => {
  let dir: string, clip: string;
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-posetrack-'));
    const png = path.join(dir, 'm.png');
    await sharp(MANNEQUIN).extract({ left: 90, top: 100, width: 140, height: 200 }).flatten({ background: '#d8d0c0' }).resize(180, 256).png().toFile(png);
    // 2 s: the figure slides across a wall, so every frame differs.
    clip = path.join(dir, 'slide.mp4');
    ff('-f', 'lavfi', '-i', 'color=c=0xd8d0c0:s=360x320:r=30:d=2', '-loop', '1', '-i', png, '-filter_complex', "[0][1]overlay=x='20+t*70':y=40:shortest=1", '-t', '2', ...ENC, clip);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('reads every frame in chunks, finds the figure in most, and the track matches itself moved', async () => {
    const run = await readPoseTracks({ ffmpeg: 'ffmpeg' }, clip, [{ startSec: 0, endSec: 2 }], { width: 360, height: 320, fps: 30 });
    expect('tracks' in run).toBe(true);
    if (!('tracks' in run)) return;
    expect(run.frames).toBe(60); // more than one chunk
    expect(run.frames).toBeGreaterThan(POSE_CHUNK);
    expect(run.peakRssMb).toBeGreaterThan(0);
    const t = run.tracks[0]!;
    expect(t.fps).toBe(30);
    const seen = t.frames.filter(Boolean).length;
    expect(seen).toBeGreaterThan(45);
    // The nose moves right with the figure, smoothly (no frame-to-frame jumps).
    const nose = t.frames.map(f => f?.[0]?.[0]).filter((x): x is number => typeof x === 'number');
    expect(nose.at(-1)! - nose[0]!).toBeGreaterThan(0.2);
    for (let i = 1; i < nose.length; i++) expect(Math.abs(nose[i]! - nose[i - 1]!)).toBeLessThan(0.08);
    expect(poseSimilarity(t, t, 2)!.score).toBeGreaterThan(0.95);
    // Memory short: skipped, not read.
    expect(await readPoseTracks({ ffmpeg: 'ffmpeg', minFreeMb: 1e9 }, clip, [{ startSec: 0, endSec: 2 }], { width: 360, height: 320, fps: 30 })).toMatchObject({ skipped: 'memory' });
  }, 120_000);
});

describe.skipIf(!hasFfmpeg || !fs.existsSync(POSE_MODEL))('Per-frame poses · matching takes by movement (API)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, dir: string, refId: string;
  beforeAll(async () => {
    a = await makeApp({});
    ({ owner } = await people(a, 0) as any);
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-posematch-'));
    const png = path.join(dir, 'm.png');
    await sharp(MANNEQUIN).extract({ left: 90, top: 100, width: 140, height: 200 }).flatten({ background: '#d8d0c0' }).resize(180, 256).png().toFile(png);
    const make = (name: string, x: string) => {
      const out = path.join(dir, `${name}.mp4`);
      ff('-f', 'lavfi', '-i', 'color=c=0xd8d0c0:s=360x320:r=30:d=2', '-loop', '1', '-i', png, '-filter_complex', `[0][1]overlay=x='${x}':y=40:shortest=1`, '-t', '2', ...ENC, out);
      return fs.readFileSync(out);
    };
    // The reference: one shot of the figure sliding right. Takes: the same slide, and the figure standing still.
    await putObject(a.ctx, { key: 'u/rx/slide.mp4', body: make('ref', '20+t*70'), studioId, kind: 'clip', contentType: 'video/mp4' });
    for (const [id, x] of [['t_slide', '30+t*70'], ['t_still', '90']] as const) {
      await putObject(a.ctx, { key: `c/${id}.mp4`, body: make(id, x), studioId, kind: 'clip', contentType: 'video/mp4' });
      await a.ctx.db.insert(takes).values({ id, studioId, userId: owner.id, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: id, label: 'HD', engineLabel: '', cost: 0, seed: 0,
        status: 'test', thumb: null, prompt: '', mediaKey: `c/${id}.mp4`, media: { durationSec: 2, width: 360, height: 320, fps: 30 }, createdAt: Date.now() });
    }
    const [up] = await a.ctx.db.execute(sql`select id from uploads where storage_key = 'u/rx/slide.mp4'`).then((r: any) => r.rows ?? r);
    refId = (await owner.req('POST', '/v1/recreate/references', { uploadId: up.id, name: 'Slide' })).body.id;
    await until(async () => { const r = (await owner.req('GET', `/v1/recreate/references/${refId}`)).body; return r.state === 'ready' ? r : null; }, 90_000);
  }, 120_000);
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  it('the analysis keeps every frame\'s pose next to the reference; matching ranks the take that moves alike first', async () => {
    const ref = (await owner.req('GET', `/v1/recreate/references/${refId}`)).body;
    expect(ref.recipe.analyzer.poseTracks).toMatchObject({ frames: expect.any(Number) });
    expect(ref.recipe.slots[0].pose.track).toMatchObject({ fps: 30 });
    const m = (await owner.req('POST', `/v1/recreate/references/${refId}/match`, { minScore: 0 })).body;
    const c = m.slots[0].candidates;
    expect(c[0].takeId).toBe('t_slide');
    expect(c[0].reasons.some((x: string) => /^moves alike/.test(x))).toBe(true);
    expect(c[0].score).toBeGreaterThan(c.find((x: any) => x.takeId === 't_still').score + 0.05);
    // Without poses, the two takes score the same on everything else.
    const off = (await owner.req('POST', `/v1/recreate/references/${refId}/match`, { minScore: 0, poses: false })).body.slots[0].candidates;
    expect(off[0].score).toBe(off[1].score);
  }, 120_000);
});
