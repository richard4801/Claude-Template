// The server render in stretches (render parity, memory): a long edit renders one stretch of the timeline at a time,
// each with only the inputs it shows, then joined without re-encoding. Items that cross a stretch's edge carry on
// exactly (position, animation, text); the cuts land on their frames; the sound is one piece.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { planRender, renderProject } from '../src/editor/render.js';
import { grabFrame } from '../src/recreate/frames.js';
import { probe } from '../src/replicate/media.js';
import { rms } from './render-helpers.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

describe.skipIf(!hasFfmpeg)('render a long edit in stretches (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  const W = 360, H = 640;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-win-'));
    for (const [id, c] of [['a', 'red'], ['b', 'blue']] as const) {
      files[id] = path.join(dir, `${id}.mp4`);
      ff('-f', 'lavfi', '-i', `color=c=${c}:s=180x320:r=30:d=6`, '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6', '-shortest', ...ENC, '-c:a', 'aac', files[id]!);
    }
    files.im = path.join(dir, 'im.png');
    ff('-f', 'lavfi', '-i', 'color=c=0x00FF00:s=100x100', '-frames:v', '1', files.im);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  // 14 cuts of 0.5 s, alternating takes, forward through each; a fade at cut 7; a green square moving across the whole
  // edit; a title over all of it.
  const project = (): M.EditProject => ({
    version: 2, sourceTakeId: 'ta', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
    assets: [{ id: 'a', kind: 'video', take: 'ta', durationSec: 6 }, { id: 'b', kind: 'video', take: 'tb', durationSec: 6 }, { id: 'im', kind: 'image', upload: 'u_im' }],
    tracks: [
      { id: 'main', kind: 'main', items: Array.from({ length: 14 }, (_, i) => ({ id: `c${i}`, asset: i % 2 ? 'b' : 'a', inSec: (i >> 1) * 0.8, outSec: (i >> 1) * 0.8 + 0.5, speed: 1,
        ...(i === 7 ? { transitionIn: { kind: 'fade', durationSec: 0.2 } } : {}) }) as M.VideoClip) },
      { id: 'img', kind: 'image', items: [{ id: 'i1', asset: 'im', startSec: 0, durationSec: 6.8, transform: { y: 0.2, scale: 0.15 }, keyframes: { x: [{ t: 0, v: 0.1 }, { t: 6.8, v: 0.9 }] } } as M.ImageItem] },
      { id: 'tx', kind: 'text', items: [{ id: 't1', startSec: 0, durationSec: 6.8, text: 'TITLE', style: { font: 'sans', weight: 900, sizePct: 0.06, color: '#FFFFFF', align: 'center' }, transform: { y: 0.8 } } as M.TextItem] },
    ],
  });

  it('is cut into stretches that never split a transition; what crosses an edge carries on; one sound', async () => {
    const p = project();
    M.validate(p);
    const tl = M.timeline(p);
    const sizes = { a: { width: 180, height: 320, hasAudio: true }, b: { width: 180, height: 320, hasAudio: true }, im: { width: 100, height: 100, hasAudio: false } };
    const plan = planRender(p, files, sizes, path.join(dir, 'x.mp4'), { maxSide: 640 });
    for (const t of plan.temp) fs.rmSync(t, { force: true, recursive: true });
    expect(plan.chunks.length).toBeGreaterThan(2);
    // No stretch reads more than a handful of inputs.
    for (const c of plan.chunks) expect(c.filter(x => x === '-i').length).toBeLessThanOrEqual(8);

    const out = path.join(dir, 'long.mp4');
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { maxSide: 640 });
    expect(r.unsupported).toEqual([]);
    const info = await probe('ffprobe', out);
    expect(Math.abs(info.duration - tl.at(-1)!.endSec)).toBeLessThan(0.1);
    const f = async (t: number) => grabFrame('ffmpeg', out, t, W, H);
    const px = (fm: { rgb: Buffer | Uint8Array }, x: number, y: number) => { const i = (Math.round(y * (H - 1)) * W + Math.round(x * (W - 1))) * 3; return [fm.rgb[i]!, fm.rgb[i + 1]!, fm.rgb[i + 2]!]; };
    for (let i = 0; i < tl.length; i++) {
      if (i === 7 || i === 6) continue; // the fade
      const fm = await f((tl[i]!.startSec + tl[i]!.endSec) / 2);
      const [rr, , bb] = px(fm, 0.5, 0.5);
      if (i % 2) { expect(bb).toBeGreaterThan(180); expect(rr).toBeLessThan(70); } else { expect(rr).toBeGreaterThan(180); expect(bb).toBeLessThan(70); }
    }
    // The square's centre follows its keyframe straight through every edge; the title stays.
    for (const t of [0.4, 1.6, 2.9, 4.1, 5.3, 6.4]) {
      const fm = await f(t);
      let sx = 0, n = 0, white = 0;
      for (let y = Math.round(0.15 * H); y < Math.round(0.25 * H); y++) for (let x = 0; x < W; x++) {
        const i = (y * W + x) * 3; if (fm.rgb[i + 1]! > 200 && fm.rgb[i]! < 80 && fm.rgb[i + 2]! < 80) { sx += x; n++; }
      }
      for (let y = Math.round(0.75 * H); y < Math.round(0.85 * H); y++) for (let x = 0; x < W; x++) {
        const i = (y * W + x) * 3; if (fm.rgb[i]! > 220 && fm.rgb[i + 1]! > 220 && fm.rgb[i + 2]! > 220) white++;
      }
      expect(n).toBeGreaterThan(20);
      expect(Math.abs(sx / n / (W - 1) - (0.1 + 0.8 * t / 6.8))).toBeLessThan(0.02);
      expect(white).toBeGreaterThan(50);
    }
    expect(rms(out, 0.2, 6.5)).toBeGreaterThan(0.05); // the cuts' tones, all through
  }, 180_000);
});
