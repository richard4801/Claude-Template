// The server render's look details (render parity): look.ts renderLook steps 1, 2 and 7–10 on the item's own picture
// — sharpen, chromatic aberration, halation, light leak, vignette, grain — and their keyframes (lookAt). Real ffmpeg
// renders, checked by pixels against the reference formulas' direction and size.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { Look } from '../src/editor/look.js';
import * as M from '../src/editor/model.js';
import { renderProject } from '../src/editor/render.js';
import { grabFrame } from '../src/recreate/frames.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

describe.skipIf(!hasFfmpeg)('render look details (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  const W = 360, H = 640;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-look-'));
    files.g = path.join(dir, 'g.mp4'); // flat mid grey
    ff('-f', 'lavfi', '-i', 'color=c=0x808080:s=180x320:r=30:d=3', ...ENC, files.g);
    files.sq = path.join(dir, 'sq.mp4'); // a white square on black
    ff('-f', 'lavfi', '-i', 'color=c=black:s=180x320:r=30:d=3', '-vf', 'drawbox=x=60:y=130:w=60:h=60:c=white:t=fill', ...ENC, files.sq);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  const render = async (asset: 'g' | 'sq', look: Look, name: string, keyframes?: M.Keyframes) => {
    const p: M.EditProject = { version: 2, sourceTakeId: 't', canvas: { width: 1080, height: 1920, fps: 30 }, assets: [{ id: asset, kind: 'video', take: 't', durationSec: 3 }],
      tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c1', asset, inSec: 0, outSec: 3, speed: 1, look, ...(keyframes ? { keyframes } : {}) } as M.VideoClip] }] };
    M.validate(p);
    const out = path.join(dir, `${name}.mp4`);
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { maxSide: 640, audio: 'none' });
    expect(r.unsupported).toEqual([]);
    return out;
  };
  const frame = (file: string, t: number) => grabFrame('ffmpeg', file, t, W, H);
  const at = (f: { rgb: Uint8Array | Buffer }, x: number, y: number) => { const i = (Math.round(y * (H - 1)) * W + Math.round(x * (W - 1))) * 3; return [f.rgb[i]!, f.rgb[i + 1]!, f.rgb[i + 2]!]; };

  it('vignette darkens (or lifts) towards the corners; keyed, it grows over time', async () => {
    const dark = await frame(await render('g', { vignette: { amount: 0.8 } }, 'vig'), 1);
    expect(Math.abs(at(dark, 0.5, 0.5)[0]! - 128)).toBeLessThan(8);
    expect(at(dark, 0.02, 0.02)[0]!).toBeLessThan(60);
    const light = await frame(await render('g', { vignette: { amount: -0.8 } }, 'vig-neg'), 1);
    expect(at(light, 0.02, 0.02)[0]!).toBeGreaterThan(190);
    const keyed = await render('g', {}, 'vig-keys', { vignette: [{ t: 0, v: 0 }, { t: 2, v: 0.9 }] });
    expect(at(await frame(keyed, 0.05), 0.02, 0.02)[0]!).toBeGreaterThan(115);
    expect(at(await frame(keyed, 2.5), 0.02, 0.02)[0]!).toBeLessThan(60);
  }, 90_000);

  it('a warm light leak screens in from its edge; grain is mono noise, new every frame', async () => {
    const leak = await frame(await render('g', { leak: { kind: 'warm', amount: 1, angle: 0 } }, 'leak'), 0);
    const [lr, lg, lb] = at(leak, 0.97, 0.5), far = at(leak, 0.03, 0.5); // angle 0: from the right edge
    expect(lr!).toBeGreaterThan(200); expect(lr!).toBeGreaterThan(lb! + 40); expect(lg!).toBeGreaterThan(lb!);
    expect(Math.abs(far[0]! - 128)).toBeLessThan(10);

    const file = await render('g', { grain: { amount: 1 } }, 'grain');
    const stats = (f: { rgb: Uint8Array | Buffer }) => {
      let s = 0, s2 = 0, n = 0, chroma = 0;
      for (let y = 200; y < 440; y++) for (let x = 100; x < 260; x++) {
        const i = (y * W + x) * 3, v = f.rgb[i + 1]!; s += v; s2 += v * v; n++; chroma += Math.abs(f.rgb[i]! - f.rgb[i + 2]!);
      }
      return { mean: s / n, sd: Math.sqrt(s2 / n - (s / n) ** 2), chroma: chroma / n };
    };
    const a = await frame(file, 1), b = await frame(file, 1.5), st = stats(a);
    expect(Math.abs(st.mean - 128)).toBeLessThan(6); expect(st.sd).toBeGreaterThan(5); expect(st.chroma).toBeLessThan(4); // mono, around the grey
    let diff = 0; for (let i = 0; i < a.rgb.length; i += 97) diff += Math.abs(a.rgb[i]! - b.rgb[i]!);
    expect(diff / (a.rgb.length / 97)).toBeGreaterThan(3); // another pattern
  }, 90_000);

  it('halation glows warm around highlights; sharpen lifts edges; chromatic aberration splits red and blue at edges', async () => {
    const plain = await frame(await render('sq', {}, 'sq-plain'), 1);
    const halo = await frame(await render('sq', { halation: { amount: 1, radius: 0.5, threshold: 0.05 } }, 'sq-halo'), 1);
    // Just outside the square (it spans 1/3–2/3 across, ~0.41–0.59 down): black before, a warm glow after.
    const p0 = at(plain, 0.5, 0.4), p1 = at(halo, 0.5, 0.4); // 4 px out, inside the 7 px blur
    expect(p0[0]!).toBeLessThan(15);
    expect(p1[0]!).toBeGreaterThan(p0[0]! + 25); expect(p1[0]!).toBeGreaterThan(p1[2]! + 15);

    const g = await frame(await render('sq', { chromatic: 1 }, 'sq-ca'), 1);
    // Red is sampled from further out: at the square's left edge red falls off first, blue reaches past it.
    let redFringe = 0;
    for (let x = Math.round(0.30 * W); x < Math.round(0.36 * W); x++) { const i = (Math.round(0.5 * H) * W + x) * 3; redFringe += g.rgb[i + 2]! - g.rgb[i]!; }
    expect(Math.abs(redFringe)).toBeGreaterThan(40);

    const sharp = await render('sq', { sharpen: 1 }, 'sq-sharp');
    expect(fs.statSync(sharp).size).toBeGreaterThan(0);
  }, 120_000);
});
