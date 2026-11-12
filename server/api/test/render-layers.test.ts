// Layers in the server render (plans/layers-edit.md, Phase 1): a layer's colour stays inside its matte, and an
// aboveText layer is drawn over the text ("text behind her"). Real ffmpeg over a grey picture, checked by pixels.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { renderProject } from '../src/editor/render.js';
import { grabFrame } from '../src/recreate/frames.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

describe.skipIf(!hasFfmpeg)('render layers (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  const W = 360, H = 640;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-layers-'));
    files.g = path.join(dir, 'g.mp4'); files.m = path.join(dir, 'm.mp4');
    ff('-f', 'lavfi', '-i', 'color=c=0x808080:s=180x320:r=30:d=3', ...ENC, files.g);
    // The "object": the left half of the frame (white), the rest black.
    ff('-f', 'lavfi', '-i', 'color=c=black:s=180x320:r=30:d=3', '-vf', 'drawbox=x=0:y=0:w=90:h=320:color=white:t=fill', ...ENC, files.m);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  const project = (layer: Partial<M.ClipLayer>, text = false): M.EditProject => ({
    version: 2, sourceTakeId: 'tg', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
    assets: [{ id: 'g', kind: 'video', take: 'tg', durationSec: 3, width: 180, height: 320 }, { id: 'm', kind: 'video', upload: 'up_m', durationSec: 3 }],
    tracks: [
      { id: 'main', kind: 'main', items: [{ id: 'c1', asset: 'g', inSec: 0, outSec: 3, speed: 1, layers: [{ id: 'l1', name: 'Left', matte: 'm', ...layer }] } as M.VideoClip] },
      ...(text ? [{ id: 'tx', kind: 'text' as const, items: [{ id: 't1', startSec: 0, durationSec: 3, text: 'WWWWWWWW', style: { font: 'sans' as const, weight: 900 as const, sizePct: 0.12, color: '#FFFFFF', align: 'center' as const, maxWidthPct: 1 } }] }] : []),
    ],
  });
  const render = async (p: M.EditProject, name: string) => {
    M.validate(p);
    const out = path.join(dir, `${name}.mp4`);
    await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { maxSide: 640, audio: 'none' });
    return grabFrame('ffmpeg', out, 1.5, W, H);
  };
  const count = (f: { rgb: Buffer | Uint8Array }, x0: number, x1: number, test: (r: number, g: number, b: number) => boolean) => {
    let n = 0;
    for (let y = 0; y < H; y++) for (let x = Math.round(x0 * W); x < Math.round(x1 * W); x++) { const i = (y * W + x) * 3; if (test(f.rgb[i]!, f.rgb[i + 1]!, f.rgb[i + 2]!)) n++; }
    return n;
  };
  const reddish = (r: number, g: number, b: number) => r > g + 40 && r > b + 40;
  const white = (r: number, g: number, b: number) => r > 220 && g > 220 && b > 220;

  it('a recoloured layer changes only the pixels inside its matte', async () => {
    const f = await render(project({ recolor: { color: '#FF0000', amount: 1 } }), 'recolor');
    expect(count(f, 0.05, 0.45, reddish)).toBeGreaterThan(0.9 * 0.4 * W * H);
    expect(count(f, 0.55, 0.95, reddish)).toBe(0);
  });

  it('text is above a layer, unless the layer is aboveText (then the text is hidden inside its matte only)', async () => {
    const over = await render(project({}, true), 'over');
    const behind = await render(project({ aboveText: true }, true), 'behind');
    const l0 = count(over, 0.05, 0.45, white), r0 = count(over, 0.55, 0.95, white);
    expect(l0).toBeGreaterThan(200); expect(r0).toBeGreaterThan(200);
    expect(count(behind, 0.05, 0.45, white)).toBeLessThan(l0 * 0.05);
    expect(count(behind, 0.55, 0.95, white)).toBeGreaterThan(r0 * 0.9);
  });
});
