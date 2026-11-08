// The server render of an edit project (workstream 1, for Recreate's Compare and export): real files made with ffmpeg,
// a project with a cut, a fade, a speed curve, a zoom (scale keyframes), a Look, text and music; the render is checked
// by its length and by the pixels at known times.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { atempo, kfExpr, renderProject, wrap } from '../src/editor/render.js';
import { grabFrame } from '../src/recreate/frames.js';
import { probe } from '../src/replicate/media.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

describe('render helpers (unit)', () => {
  it('keyframes as a piecewise-linear expression; atempo stages; line wrap', () => {
    expect(kfExpr(undefined, 1)).toBe('1');
    expect(kfExpr([{ t: 0, v: 1 }], 2)).toBe('1');
    const e = kfExpr([{ t: 0, v: 1 }, { t: 2, v: 1.5 }], 1);
    expect(e).toBe('if(lt(t,0),1,if(lt(t,2),1+(0.5)*(t-0)/2,1.5))');
    expect(atempo(1)).toEqual([]);
    expect(atempo(4)).toEqual(['atempo=2', 'atempo=2']);
    expect(atempo(0.25)).toEqual(['atempo=0.5', 'atempo=0.5']);
    expect(atempo(1.5)).toEqual(['atempo=1.5']);
    expect(wrap('the oat flat white is back', 40, 400)).toEqual(['the oat flat white', 'is back']); // 18 characters a line
  });
});

describe.skipIf(!hasFfmpeg)('render an edit project (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  const W = 360, H = 640;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-'));
    // Three takes: solid red, green and blue (3 s, with a tone), and a music bed.
    for (const [id, c] of [['a', 'red'], ['b', 'green'], ['c', 'blue']] as const) {
      files[id] = path.join(dir, `${id}.mp4`);
      ff('-f', 'lavfi', '-i', `color=c=${c}:s=180x320:r=30:d=3`, '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3', '-shortest', ...ENC, '-c:a', 'aac', files[id]!);
    }
    files.m = path.join(dir, 'm.m4a');
    ff('-f', 'lavfi', '-i', 'sine=frequency=220:duration=6', '-c:a', 'aac', files.m!);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  const project = (): M.EditProject => ({
    version: 2, sourceTakeId: 'ta', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
    assets: [{ id: 'a', kind: 'video', take: 'ta', durationSec: 3 }, { id: 'b', kind: 'video', take: 'tb', durationSec: 3 }, { id: 'c', kind: 'video', take: 'tc', durationSec: 3 }, { id: 'm', kind: 'audio', upload: 'up_m', durationSec: 6 }],
    tracks: [
      { id: 'main', kind: 'main', items: [
        { id: 'c1', asset: 'a', inSec: 0, outSec: 1, speed: 1 } as M.VideoClip,
        { id: 'c2', asset: 'b', inSec: 0, outSec: 1.4, speed: 1, transitionIn: { kind: 'fade', durationSec: 0.4 }, speedCurve: { preset: 'custom', points: [[0, 1], [0.5, 0.5], [1, 1]] } } as M.VideoClip,
        { id: 'c3', asset: 'c', inSec: 0, outSec: 1.5, speed: 1, keyframes: { scale: [{ t: 0, v: 1 }, { t: 1.5, v: 2 }] }, look: { lut: 'pack:bw-classic', strength: 1 } } as M.VideoClip,
      ] },
      { id: 'text', kind: 'text', items: [{ id: 'x1', startSec: 0.2, durationSec: 0.6, text: 'HELLO', style: { font: 'sans', weight: 900, sizePct: 0.08, color: '#FFFFFF', align: 'center', stroke: { color: '#000000', widthPct: 0.08 } }, transform: { x: 0.5, y: 0.5 } } as M.TextItem] },
      { id: 'mus', kind: 'music', items: [{ id: 'mu', asset: 'm', startSec: 0, inSec: 0, outSec: 4 } as M.AudioClip] },
    ],
  });
  const px = async (file: string, t: number, x: number, y: number) => {
    const f = await grabFrame('ffmpeg', file, t, W, H);
    const i = (Math.round(y * (H - 1)) * W + Math.round(x * (W - 1))) * 3;
    return [f.rgb[i]!, f.rgb[i + 1]!, f.rgb[i + 2]!];
  };

  it('cut, fade, speed curve, zoom, Look, text and sound: the right picture at the right time, the timeline\'s length', async () => {
    const p = project();
    M.validate(p);
    const tl = M.timeline(p);
    const out = path.join(dir, 'out.mp4');
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { maxSide: 640 });
    expect(r).toMatchObject({ width: W, height: H, unsupported: [] });
    const info = await probe('ffprobe', out);
    expect(Math.abs(info.duration - tl.at(-1)!.endSec)).toBeLessThan(0.1);
    expect(info.audioCodec).toBeTruthy();
    const [r1, g1, b1] = await px(out, 0.1, 0.1, 0.1); // clip 1: red
    expect(r1).toBeGreaterThan(200); expect(g1).toBeLessThan(60); expect(b1).toBeLessThan(60);
    const mid = tl[1]!.startSec + tl[1]!.transitionSec / 2; // halfway through the fade: red and green mixed
    const [rm, gm] = await px(out, mid, 0.1, 0.1);
    expect(rm).toBeGreaterThan(70); expect(gm).toBeGreaterThan(50);
    const [r2, g2] = await px(out, tl[1]!.startSec + 1, 0.1, 0.1); // clip 2: green
    expect(g2).toBeGreaterThan(100); expect(r2).toBeLessThan(60);
    // Clip 3: blue through a black-and-white look → grey, not blue.
    const [r3, g3, b3] = await px(out, tl[2]!.startSec + 0.5, 0.5, 0.5);
    expect(Math.abs(r3 - b3)).toBeLessThan(25); expect(Math.abs(g3 - b3)).toBeLessThan(25);
    // The text: white letters with a dark outline in the middle while it is on, red there before it starts.
    const f = await grabFrame('ffmpeg', out, 0.5, W, H);
    let white = 0;
    for (let y = Math.round(H * 0.45); y < Math.round(H * 0.55); y++) for (let x = Math.round(W * 0.3); x < Math.round(W * 0.7); x++) {
      const i = (y * W + x) * 3; if (f.rgb[i]! > 230 && f.rgb[i + 1]! > 230 && f.rgb[i + 2]! > 230) white++;
    }
    expect(white).toBeGreaterThan(50);
    const [rb, gb] = await px(out, 0.1, 0.5, 0.5);
    expect(rb).toBeGreaterThan(200); expect(gb).toBeLessThan(60);
  }, 120_000);

  it('a guide track replaces the project\'s sound, padded to a set length; what can\'t be drawn is listed', async () => {
    const p = project();
    (p.tracks[0]!.items[0] as M.VideoClip).mask = { shape: 'circle' };
    p.tracks.push({ id: 'ov', kind: 'video', items: [{ id: 'v1', asset: 'a', inSec: 0, outSec: 1, speed: 1, startSec: 0 } as M.VideoClip] });
    const out = path.join(dir, 'guide.mp4');
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { maxSide: 320, audio: { file: files.m! }, durationSec: 5 });
    expect(r.unsupported.sort()).toEqual(['masks', 'overlays']);
    const info = await probe('ffprobe', out);
    expect(Math.abs(info.duration - 5)).toBeLessThan(0.1);
    expect(info.audioCodec).toBeTruthy();
    // Silent.
    const silent = path.join(dir, 'silent.mp4');
    await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, project(), files, silent, { maxSide: 320, audio: 'none' });
    expect((await probe('ffprobe', silent)).audioCodec).toBeFalsy();
  }, 120_000);
});


