// A moving (zoomed) clip is drawn from its source's own pixels, never upscaled past them before perspective places it
// (2026-11-14 render speed: a 1080 × 1920 clip zoomed 2× was drawn 2160 × 3840 through the colour and perspective).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { planRender, renderProject } from '../src/editor/render.js';
import { ff, hasFfmpeg } from './recreate-fixture.js';

const project = (zoom: number): M.EditProject => ({
  version: 2, sourceTakeId: 'ta', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
  assets: [{ id: 'a', kind: 'video', take: 'ta', durationSec: 1 }],
  tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c1', asset: 'a', inSec: 0, outSec: 1, speed: 1, keyframes: { scale: [{ t: 0, v: 1 }, { t: 1, v: zoom }] } } as M.VideoClip] }],
});
const graph = (w: number, h: number, zoom = 2) => {
  const plan = planRender(project(zoom), { a: '/x/a.mp4' }, { a: { width: w, height: h, hasAudio: false } }, '/x/out.mp4', { quality: 'export' });
  return plan.chunks.map(c => c[c.indexOf('-filter_complex') + 1]!).join(';');
};

describe('zoomed clips are drawn at their source size (unit)', () => {
  it('a canvas-size source zoomed 2× is drawn 1080 × 1920 (not 2160 × 3840), magnified by cubic perspective', () => {
    const g = graph(1080, 1920);
    expect(g).toContain('scale=1080:1920');
    expect(g).not.toContain('scale=2160:3840');
    expect(g).toMatch(/perspective=sense=destination:eval=frame:interpolation=cubic:/);
  });
  it('a small source is still drawn at least canvas size; a 4K source keeps its detail up to the zoom', () => {
    expect(graph(540, 960)).toContain('scale=1080:1920');
    const g4k = graph(2160, 3840);
    expect(g4k).toContain('scale=2160:3840');
    expect(g4k).not.toContain('interpolation=cubic'); // drawn at its largest size: perspective only shrinks it
    expect(graph(2160, 3840, 1.5)).toContain('scale=1620:2880'); // no further than the zoom needs
  });
});

describe.skipIf(!hasFfmpeg)('zoomed clip pixels (ffmpeg)', () => {
  let dir: string;
  beforeAll(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-zoom-')); });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));
  it('at 2× the picture matches a bicubic 2× centre crop of the source (fine detail kept)', async () => {
    const src = path.join(dir, 'a.mp4'), out = path.join(dir, 'out.mp4');
    // A still, detailed picture (a fractal), 1 s, lossless enough for a fair compare.
    ff('-f', 'lavfi', '-i', 'mandelbrot=s=1080x1920:r=30', '-vf', 'trim=end_frame=1,loop=-1:1:0,setpts=N/30/TB', '-t', '1', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '4', '-pix_fmt', 'yuv420p', src);
    const p = project(2);
    p.tracks[0]!.items = [{ ...(p.tracks[0]!.items[0] as M.VideoClip), keyframes: { scale: [{ t: 0, v: 2 }, { t: 1, v: 2 }] } } as M.VideoClip];
    await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, { a: src }, out, { quality: 'export' });
    const ref = path.join(dir, 'ref.mp4');
    ff('-i', src, '-vf', 'scale=2160:3840:flags=bicubic,crop=1080:1920:540:960', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '4', '-pix_fmt', 'yuv420p', ref);
    const err = execFileSync('sh', ['-c', `ffmpeg -i '${out}' -i '${ref}' -lavfi '[0:v]trim=start_frame=5:end_frame=10[a];[1:v]trim=start_frame=5:end_frame=10[b];[a][b]psnr' -f null - 2>&1`]).toString();
    const y = Number(err.match(/PSNR y:([\d.]+)/)?.[1]);
    console.log(`zoom 2× vs bicubic reference: PSNR y ${y} dB`);
    expect(y).toBeGreaterThan(42); // old 2×-drawn path: 47.5 dB; a half-pixel offset: ~35 dB
  }, 60_000);
});
