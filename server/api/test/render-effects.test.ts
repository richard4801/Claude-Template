// The server render draws a clip's `effect` (plans/edit-templates.md §7: it used to drop it silently, which broke the
// Background glitch template and every future N1 template in server exports). Real ffmpeg renders of every effect in
// the library, each checked against the reference's direction (effects.ts effectPixel) on a test picture.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { EFFECT_IDS, type Effect } from '../src/editor/effects.js';
import * as M from '../src/editor/model.js';
import { planRender, renderProject } from '../src/editor/render.js';
import { grabFrame } from '../src/recreate/frames.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

describe.skipIf(!hasFfmpeg)('render: effects (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  const W = 180, H = 320;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-fx-'));
    files.g = path.join(dir, 'g.mp4'); // a left-to-right gradient with a white square: every effect changes something here
    ff('-f', 'lavfi', '-i', 'gradients=s=180x320:c0=0x202020:c1=0xC0C0C0:x0=0:y0=0:x1=179:y1=0:r=30:d=2', '-vf', 'drawbox=x=60:y=130:w=40:h=40:c=white:t=fill', ...ENC, files.g);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  const project = (effect?: Effect): M.EditProject => ({ version: 2, sourceTakeId: 't', canvas: { width: 180, height: 320, fps: 30 }, assets: [{ id: 'g', kind: 'video', take: 't', durationSec: 2 }],
    tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c1', asset: 'g', inSec: 0, outSec: 1, speed: 1, ...(effect ? { effect } : {}) } as M.VideoClip] }] });
  const render = async (effect: Effect | undefined, name: string) => {
    const p = project(effect);
    M.validate(p);
    const out = path.join(dir, `${name}.mp4`);
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { audio: 'none' });
    expect(r.unsupported).toEqual([]);
    return out;
  };
  const diff = (a: { rgb: Uint8Array | Buffer }, b: { rgb: Uint8Array | Buffer }) => { let s = 0; for (let i = 0; i < a.rgb.length; i++) s += Math.abs(a.rgb[i]! - b.rgb[i]!); return s / a.rgb.length; };
  const luma = (f: { rgb: Uint8Array | Buffer }) => { let s = 0; for (let i = 0; i < f.rgb.length; i += 3) s += 0.2126 * f.rgb[i]! + 0.7152 * f.rgb[i + 1]! + 0.0722 * f.rgb[i + 2]!; return s / (f.rgb.length / 3); };

  it('every effect in the library changes the plan (none is dropped any more)', () => {
    const plan = (e?: Effect) => { const r = planRender(project(e), files, { g: { width: 180, height: 320, hasAudio: false } }, '/x/o.mp4'); for (const t of r.temp) fs.rmSync(t, { force: true }); return { ...r, text: JSON.stringify(r.chunks).replace(/muse-[a-z]+-[^/'"\\\s]+/g, 'TEMP') }; };
    const base = plan().text;
    for (const id of EFFECT_IDS) {
      const pl = plan({ id, amount: 0.8 });
      expect(pl.text, id).not.toBe(base);
      expect(pl.unsupported).toEqual([]);
    }
    // Amount 0 is the identity: nothing is added.
    expect(plan({ id: 'glitch', amount: 0 }).text).toBe(base);
  });

  it('renders every effect, each visibly different from the clean clip and in the reference\'s direction', async () => {
    const clean = await grabFrame('ffmpeg', await render(undefined, 'clean'), 0.1, W, H);
    const out: Record<string, { rgb: Uint8Array | Buffer }> = {};
    for (const id of EFFECT_IDS) out[id] = await grabFrame('ffmpeg', await render({ id, amount: 0.9, ...(id === 'duotone' ? { colors: ['#000080', '#FFFF00'] as [string, string] } : {}) }, id), 0.1, W, H);
    for (const id of EFFECT_IDS) expect(diff(out[id]!, clean), id).toBeGreaterThan(0.5);
    // Direction checks against the reference: flash lifts toward white at the start of each second; blur and pixelate
    // keep the mean but smooth the square's edge; the mirror's right edge is its left edge (dark, not light).
    expect(luma(out.flash!)).toBeGreaterThan(luma(clean) + 30);
    expect(Math.abs(luma(out.blur!) - luma(clean))).toBeLessThan(6);
    const px = (f: { rgb: Uint8Array | Buffer }, x: number, y: number) => f.rgb[(y * W + x) * 3]!;
    expect(px(out.mirror!, W - 3, 10)).toBeLessThan(px(clean, W - 3, 10) - 60);
    // Duotone maps dark to navy (blue high, red low) and light to yellow (red and green high, blue low).
    const at = (f: { rgb: Uint8Array | Buffer }, x: number, y: number) => { const i = (y * W + x) * 3; return [f.rgb[i]!, f.rgb[i + 1]!, f.rgb[i + 2]!]; };
    const [r0, , b0] = at(out.duotone!, 3, 10), [r1, g1, b1] = at(out.duotone!, 80, 150);
    expect(b0).toBeGreaterThan(r0);
    expect(r1).toBeGreaterThan(b1); expect(g1).toBeGreaterThan(b1);
  }, 120_000);
});
