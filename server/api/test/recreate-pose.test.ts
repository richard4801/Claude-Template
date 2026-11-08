// Recreate this edit · body poses (workstream 1): MoveNet Lightning in a child process, one job at a time, its peak
// memory measured; skipped when memory is tight or the model is missing. The subject is our own mannequin preview.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { analyzeReference } from '../src/recreate/analyze.js';
import { MAX_POSE_FRAMES, POSE_MODEL, poseOf, readPoses, runPoseJob } from '../src/recreate/pose.js';
import { KEYPOINTS, letterbox } from '../src/recreate/poseWorker.js';
import { hasFfmpeg, makeReference } from './recreate-fixture.js';

const MANNEQUIN = path.resolve(__dirname, '../../../design/previews/angles/full.webp');
const kp = (score: number) => KEYPOINTS.map(name => ({ name, x: 0.5, y: 0.5, score }));

describe('Pose helpers (unit)', () => {
  it('letterboxes into 192 × 192 and maps points back to the frame', () => {
    const w = 90, h = 160, rgb = new Uint8Array(w * h * 3).fill(200);
    const lb = letterbox(rgb, w, h);
    expect(lb.data.length).toBe(192 * 192 * 3);
    expect(lb.data[0]).toBe(0); // the left bar
    expect(lb.data[(96 * 192 + 96) * 3]).toBe(200);
    // The picture is 108 px wide, centred (42 px bars): its left edge, middle and right edge.
    expect(lb.toFrame(42 / 192, 0)).toEqual({ x: 0, y: 0 });
    expect(lb.toFrame(0.5, 0.5)).toEqual({ x: 0.5, y: 0.5 });
    expect(lb.toFrame(150 / 192, 1).x).toBeCloseTo(1, 5);
  });
  it('a person needs a mean keypoint score of 0.25; otherwise "none"', () => {
    expect(poseOf(1, kp(0.4))).toMatchObject({ status: 'done', frameSec: 1 });
    expect(poseOf(1, kp(0.1))).toEqual({ status: 'none', frameSec: 1 });
    expect(MAX_POSE_FRAMES).toBe(20);
  });
});

describe('Pose · the model in a child process', () => {
  let frame: { width: number; height: number; rgb: Uint8Array };
  beforeAll(async () => {
    // The figure, cropped as a slot's keyframe would frame it.
    const { data, info } = await sharp(MANNEQUIN).extract({ left: 90, top: 100, width: 140, height: 200 }).removeAlpha().raw().toBuffer({ resolveWithObject: true });
    frame = { width: info.width, height: info.height, rgb: new Uint8Array(data) };
  });

  it('finds the mannequin: head above shoulders above hips above ankles, centred; reports its peak memory', async () => {
    const r = await runPoseJob({ model: POSE_MODEL, frames: [frame, frame] });
    if (!r.ok) throw new Error(r.error);
    expect(r.poses).toHaveLength(2);
    const p = Object.fromEntries(r.poses[0]!.map(k => [k.name, k]));
    expect(p.nose!.y).toBeLessThan(p.left_shoulder!.y);
    expect(p.left_shoulder!.y).toBeLessThan(p.left_hip!.y);
    expect(p.left_hip!.y).toBeLessThan(p.left_knee!.y);
    expect(p.left_knee!.y).toBeLessThan(p.left_ankle!.y);
    expect(Math.abs(p.nose!.x - 0.5)).toBeLessThan(0.1);
    expect(poseOf(0, r.poses[0]!).status).toBe('done');
    expect(r.poses[1]).toEqual(r.poses[0]); // deterministic
    // The child's peak resident memory (the main process's is unaffected): logged for sizing the instance.
    console.log(`pose child: peak RSS ${r.peakRssMb} MB, ${r.ms} ms for 2 frames`);
    expect(r.peakRssMb).toBeGreaterThan(30);
    expect(r.peakRssMb).toBeLessThan(250);
  }, 60_000);

  it('jobs run one at a time; a bad model fails cleanly', async () => {
    const order: string[] = [];
    await Promise.all([
      runPoseJob({ model: POSE_MODEL, frames: [frame] }).then(() => order.push('a')),
      runPoseJob({ model: '/nonexistent.onnx', frames: [frame] }).then(r => { order.push('b'); expect(r.ok).toBe(false); }),
    ]);
    expect(order).toEqual(['a', 'b']);
  }, 60_000);

  it('skipped when the model is missing or memory is tight (nothing is started)', async () => {
    expect(await readPoses({ ffmpeg: 'ffmpeg', model: '/nonexistent.onnx' }, 'x.mp4', [1], { width: 180, height: 320 })).toEqual({ skipped: 'model' });
    const r = await readPoses({ ffmpeg: 'ffmpeg', minFreeMb: 1e9 }, 'x.mp4', [1], { width: 180, height: 320 });
    expect(r).toMatchObject({ skipped: 'memory' });
  });
});

describe.skipIf(!hasFfmpeg)('Pose · in the analysis', () => {
  let dir: string, ref: string;
  beforeAll(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-pose-')); ref = makeReference(dir); });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('each slot gets a pose at its keyframe (no person in the test clip: "none"); the run is recorded; memory short = pending + gap', async () => {
    const { recipe: r } = await analyzeReference({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe', pose: true }, ref);
    for (const s of r.slots) {
      expect(['done', 'none']).toContain(s.pose.status);
      expect(s.pose.frameSec).toBe(s.keyframeSec);
    }
    expect(r.analyzer.pose).toMatchObject({ frames: 3 });
    expect(r.gaps.map(g => g.key)).not.toContain('pose');

    const short = await analyzeReference({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe', pose: { minFreeMb: 1e9 } }, ref);
    expect(short.recipe.slots.every(s => s.pose.status === 'pending')).toBe(true);
    expect(short.recipe.analyzer.pose).toEqual({ skipped: 'memory' });
    expect(short.recipe.gaps.find(g => g.key === 'pose')!.note).toMatch(/short of memory/);
  }, 90_000);
});
