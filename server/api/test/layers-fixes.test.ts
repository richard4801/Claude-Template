// Layers fixes from the owner's first use (2026-11-12): the matte retimed to the source's length (ci_f1a8073237b7), a
// warning when a layer doesn't cover what was marked (ci_0e39a2b16b08), Claude's get_frame marks mapped onto the source
// frame (ci_0e39a2b16b08), and apply_edit_ops' patch / track-kind errors (ci_d17956dab5c5, ci_decc4aaaa9d6).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { applyOps } from '../src/editor/ops.js';
import { canvasToSource, coverageWarning, retimeMatte } from '../src/editor/layers.js';
import { probe } from '../src/replicate/media.js';
import { hasFfmpeg } from './recreate-fixture.js';

const project = (o: Partial<M.VideoClip> = {}): M.EditProject => ({
  version: 2, sourceTakeId: 't', canvas: { width: 1080, height: 1920, fps: 30 },
  assets: [{ id: 'src', kind: 'video', take: 't', durationSec: 20, width: 1920, height: 1080 }],
  tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c0', asset: 'src', inSec: 0, outSec: 2, speed: 1 } as M.VideoClip, { id: 'c1', asset: 'src', inSec: 5, outSec: 15, speed: 1, ...o } as M.VideoClip] }],
});

describe('marks from get_frame land on the source frame', () => {
  it('a cover-cropped landscape clip on a vertical canvas: canvas x maps to the middle of the source; timeline t to source t', () => {
    const p = project();
    // c1 starts at 2 s on the timeline and at 5 s of its source.
    expect(canvasToSource(p, 'c1', 3, 0.5, 0.5, { width: 1920, height: 1080 })).toEqual({ x: 0.5, y: 0.5, t: 6 });
    const left = canvasToSource(p, 'c1', 3, 0, 0.25, { width: 1920, height: 1080 })!;
    expect(left.x).toBeCloseTo(0.5 - (1080 / (1920 * (1920 / 1080))) / 2, 3); // ≈ 0.342: the canvas shows the middle third
    expect(left.y).toBeCloseTo(0.25, 3);
    // Zoomed in 2× and flipped: the canvas's left quarter is the source's right side.
    const z = canvasToSource(project({ transform: { scale: 2, flipX: true } }), 'c1', 3, 0.25, 0.5, { width: 1920, height: 1080 })!;
    expect(z.x).toBeGreaterThan(0.5);
    // Contain-fit: a spot on the bars is off the picture.
    expect(canvasToSource(project({ fit: 'contain' }), 'c1', 3, 0.5, 0.02, { width: 1920, height: 1080 })).toBeNull();
  });
});

describe('a layer that misses what was marked is said', () => {
  const obj = { name: 'Her', points: [{ x: 0.5, y: 0.4, t: 1, keep: true }, { x: 0.5, y: 0.6, t: 1, keep: true }] };
  it('a small patch at the top: the taps lower down are outside it', () => {
    const boxes = Array.from({ length: 30 }, () => [0.42, 0.02, 0.16, 0.07]);
    expect(coverageWarning(obj, boxes, 5)).toMatch(/Her: the layer doesn't cover 2 of the 2 points/);
  });
  it('the person found: no warning; nothing found: says so', () => {
    expect(coverageWarning(obj, Array.from({ length: 30 }, () => [0.25, 0.1, 0.5, 0.85]), 5)).toBeNull();
    expect(coverageWarning(obj, Array.from({ length: 30 }, () => null), 5)).toMatch(/nothing was found/);
  });
});

describe.skipIf(!hasFfmpeg)('the matte runs at the source length', () => {
  it('a 60 fps source\'s matte made at 30 fps (twice as long) is retimed; one that lines up is left alone', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-retime-'));
    try {
      const slow = path.join(dir, 'slow.mp4'), ok = path.join(dir, 'ok.mp4'), out = path.join(dir, 'out.mp4');
      execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'color=c=white:s=320x568:r=30:d=4', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', slow]);
      execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'color=c=white:s=320x568:r=30:d=2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', ok]);
      expect(await retimeMatte('ffmpeg', 'ffprobe', slow, 2, out)).toBe(out);
      expect((await probe('ffprobe', out)).duration).toBeCloseTo(2, 1);
      expect(await retimeMatte('ffmpeg', 'ffprobe', ok, 2, path.join(dir, 'x.mp4'))).toBeNull();
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
});

describe('apply_edit_ops errors Claude can act on', () => {
  const p = project();
  it('patch takes a JSON string or a single operation, and says what it wants otherwise', () => {
    const one = { op: 'add', path: '/canvas/background', value: '#111111' };
    expect(applyOps(p, [{ op: 'patch', patch: one }]).project.canvas.background).toBe('#111111');
    expect(applyOps(p, [{ op: 'patch', patch: JSON.stringify([one]) }]).project.canvas.background).toBe('#111111');
    expect(() => applyOps(p, [{ op: 'patch', patch: 'not json' }])).toThrow(/a JSON Patch array, e\.g\./);
  });
  it('an unknown track kind names the kinds', () => {
    const q = JSON.parse(JSON.stringify(p));
    q.tracks.push({ id: 'cap', kind: 'captions', items: [] });
    expect(() => M.validate(q)).toThrow(/unknown track kind "captions" \(one of main, video/);
  });
});
