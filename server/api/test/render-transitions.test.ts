// The server render's transitions (render parity): every kind drawn as model.ts transitionState says — each clip
// moved, scaled, turned and faded, the incoming one on top, whip blur and RGB split as the apps' TransitionFxEffect,
// black and white over the overlays (android FlashPiece). Unit: the expressions equal transitionState; ffmpeg: pixels.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as L from '../src/editor/layer.js';
import * as M from '../src/editor/model.js';
import { renderProject } from '../src/editor/render.js';
import { grabFrame } from '../src/recreate/frames.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

const evalExpr = (e: string, p: number) => Function('p', 'lt', 'gte', 'max', 'pow', '_if', `return ${e.replace(/\bif\(/g, '_if(')};`)(p,
  (a: number, b: number) => +(a < b), (a: number, b: number) => +(a >= b), Math.max, Math.pow, (c: number, a: number, b: number) => (c ? a : b)) as number;

describe('transition expressions (unit)', () => {
  it('equal transitionState for every kind (offsets, scale, rotation, opacity)', () => {
    for (const kind of M.TRANSITIONS) {
      if (kind === 'glitch') continue; // drawn by glitchSwitch
      const ex = L.transitionExprs(kind, 'p');
      for (let p = 0; p <= 1.0001; p += 0.05) {
        const st = M.transitionState(kind, p);
        for (const side of ['a', 'b'] as const) {
          const e = ex[side], s = st[side];
          expect(evalExpr(e.dx, p)).toBeCloseTo(s.dx, 6); expect(evalExpr(e.dy, p)).toBeCloseTo(s.dy, 6);
          expect(evalExpr(e.scale, p)).toBeCloseTo(s.scale, 6); expect(evalExpr(e.rotation, p)).toBeCloseTo(s.rotation, 6);
          // black / white: the clips switch at half-way, their colour is a layer of its own (FlashPiece)
          if (kind !== 'black' && kind !== 'white') expect(evalExpr(e.opacity, p)).toBeCloseTo(s.opacity, 6);
        }
      }
    }
  });
});

describe.skipIf(!hasFfmpeg)('render transitions (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  const W = 360, H = 640;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-tr-'));
    for (const [id, c] of [['a', 'red'], ['b', 'blue']] as const) { files[id] = path.join(dir, `${id}.mp4`); ff('-f', 'lavfi', '-i', `color=c=${c}:s=180x320:r=30:d=3`, ...ENC, files[id]!); }
    files.st = path.join(dir, 'st.mp4'); // red with a white stripe
    ff('-f', 'lavfi', '-i', 'color=c=red:s=180x320:r=30:d=3', '-vf', 'drawbox=x=80:y=0:w=20:h=320:c=white:t=fill', ...ENC, files.st);
    files.im = path.join(dir, 'im.png');
    ff('-f', 'lavfi', '-i', 'color=c=0x00FF00:s=100x100', '-frames:v', '1', files.im);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  // Red for 2 s, then blue, with a 1 s transition: it runs 1–2 s, half-way at 1.5 s.
  const render = async (kind: M.TransitionKind, extra: M.Track[] = [], first = 'a') => {
    const p: M.EditProject = { version: 2, sourceTakeId: 'ta', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
      assets: [{ id: 'a', kind: 'video', take: 'ta', durationSec: 3 }, { id: 'b', kind: 'video', take: 'tb', durationSec: 3 }, { id: 'im', kind: 'image', upload: 'u_im' }, { id: 'st', kind: 'video', take: 'tst', durationSec: 3 }],
      tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c1', asset: first, inSec: 0, outSec: 2, speed: 1 } as M.VideoClip,
        { id: 'c2', asset: 'b', inSec: 0, outSec: 2, speed: 1, transitionIn: { kind, durationSec: 1 } } as M.VideoClip] }, ...extra] };
    M.validate(p);
    const out = path.join(dir, `${kind}-${first}.mp4`);
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { maxSide: 640, audio: 'none' });
    expect(r.unsupported).toEqual([]);
    return out;
  };
  const px = async (file: string, t: number, x: number, y: number) => {
    const f = await grabFrame('ffmpeg', file, t, W, H);
    const i = (Math.round(y * (H - 1)) * W + Math.round(x * (W - 1))) * 3;
    return [f.rgb[i]!, f.rgb[i + 1]!, f.rgb[i + 2]!];
  };
  const red = ([r, , b]: number[]) => r! > 180 && b! < 70, blue = ([r, , b]: number[]) => b! > 180 && r! < 70, dark = ([r, g, b]: number[]) => r! < 40 && g! < 40 && b! < 40;

  it('slides push, covers slide over a still clip, zoom out and spin scale and turn', async () => {
    const slide = await render('slideLeft'); // half-way: red has moved half out to the left, blue half in from the right
    expect(red(await px(slide, 1.5, 0.25, 0.5))).toBe(true); expect(blue(await px(slide, 1.5, 0.75, 0.5))).toBe(true);
    const early = await render('coverRight'); // blue comes in from the left over red, which stays put
    expect(blue(await px(early, 1.5, 0.25, 0.5))).toBe(true); expect(red(await px(early, 1.5, 0.75, 0.5))).toBe(true);
    expect(red(await px(early, 1.2, 0.9, 0.5))).toBe(true);
    const up = await render('coverUp');
    expect(red(await px(up, 1.5, 0.5, 0.25))).toBe(true); expect(blue(await px(up, 1.5, 0.5, 0.75))).toBe(true);
    const out = await render('zoomOut'); // blue comes in at 1.2×, fading over red shrinking from 1×
    const m = await px(out, 1.5, 0.5, 0.5);
    expect(m[0]!).toBeGreaterThan(60); expect(m[2]!).toBeGreaterThan(60);
    const spin = await render('spin'); // just before half-way: red, turned ~90° and scaled to ~0.7: the corners show the background
    expect(dark(await px(spin, 1.45, 0.05, 0.05))).toBe(true); expect(red(await px(spin, 1.45, 0.5, 0.5))).toBe(true);
    expect(blue(await px(spin, 1.6, 0.5, 0.5))).toBe(true);
  }, 120_000);

  it('whip blurs while it moves; split fade pulls red and blue apart; black darkens over the overlays too', async () => {
    // A white stripe on the outgoing clip: sharp before, smeared sideways at the whip's peak (±4 % of the width).
    const soft = async (kind: M.TransitionKind, t: number) => {
      const out = await render(kind, [], 'st');
      const f = await grabFrame('ffmpeg', out, t, W, H);
      let n = 0; for (let x = 0; x < W; x++) { const i = (320 * W + x) * 3; if (f.rgb[i + 1]! > 30 && f.rgb[i + 1]! < 220) n++; }
      return n;
    };
    expect(await soft('whipRight', 0.5)).toBeLessThan(8); // scaling and chroma leave a few soft columns
    expect(await soft('whipRight', 1.45)).toBeGreaterThan(14);
    const split = await render('splitFade');
    const s = await grabFrame('ffmpeg', split, 1.5, W, H), sp = await grabFrame('ffmpeg', split, 2.5, W, H);
    const edge = (fm: { rgb: Uint8Array | Buffer }) => { let n = 0; for (let x = 0; x < 12; x++) { const i = (320 * W + x) * 3; n += Math.abs(fm.rgb[i]! - fm.rgb[i + 2]!); } return n; };
    expect(Math.abs(edge(s) - edge(sp))).toBeGreaterThan(0);
    const blk = await render('black', [{ id: 'img', kind: 'image', items: [{ id: 'i1', asset: 'im', startSec: 0, durationSec: 3, transform: { scale: 0.3 } } as M.ImageItem] }]);
    expect(dark(await px(blk, 1.5, 0.5, 0.5))).toBe(true); // the green picture is covered at the dip's darkest
    const [, g] = await px(blk, 0.5, 0.5, 0.5); expect(g!).toBeGreaterThan(200); // and shows before it
    expect(red(await px(blk, 1.1, 0.1, 0.1)) || dark(await px(blk, 1.1, 0.1, 0.1))).toBe(true);
    expect(blue(await px(blk, 2.4, 0.1, 0.1))).toBe(true);
  }, 120_000);
});
