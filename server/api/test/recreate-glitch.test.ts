// Recreate this edit · glitch transitions (workstream 1, gap G6). A glitch flickers between the two shots for a few
// frames, jittered and colour-split. Before, the cut finder (spikes up to 2 frames) and the fade finder (no hard steps)
// both passed it over and the two shots merged into one.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { analyzeReference } from '../src/recreate/analyze.js';
import { findGlitches } from '../src/recreate/signals.js';
import { buildProject } from '../src/recreate/assemble.js';
import * as M from '../src/editor/model.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

describe('glitch bursts (unit)', () => {
  const frames = (hd: number[], en: number[], hist: (i: number) => number) => {
    const h = (v: number) => { const a = new Float32Array(32); a[v] = 1; return a; };
    return { fps: 30, width: 180, height: 320, histDist: Float32Array.from(hd), energy: Float32Array.from(en), luma: new Float32Array(hd.length).fill(0.4), hists: hd.map((_, i) => h(hist(i))) };
  };
  it('3+ hard steps in a row are a glitch; one is a cut; the same picture after is a glitch inside the shot', () => {
    const hd = [0, 0.01, 0.01, 0.7, 0.7, 0.2, 0.7, 0.7, 0.01, 0.01, 0.01], en = hd.map(v => (v > 0.3 ? 0.3 : 0.005));
    const [g] = findGlitches(frames(hd, en, i => (i < 5 ? 3 : 20)));
    expect(g).toMatchObject({ kind: 'glitch', startFrame: 2, endFrame: 7, inShot: false });
    expect(findGlitches(frames(hd, en, () => 3))[0]).toMatchObject({ inShot: true });
    const one = [0, 0.01, 0.01, 0.7, 0.01, 0.01, 0.01];
    expect(findGlitches(frames(one, one.map(v => (v > 0.3 ? 0.3 : 0.005)), i => (i < 3 ? 3 : 20)))).toEqual([]);
    const long = Array.from({ length: 40 }, (_, i) => (i > 2 && i < 30 ? 0.7 : 0.01)); // 0.9 s of change: not a glitch
    expect(findGlitches(frames(long, long.map(v => (v > 0.3 ? 0.3 : 0.005)), i => (i < 15 ? 3 : 20)))).toEqual([]);
  });
});

describe.skipIf(!hasFfmpeg)('glitch transitions on video', () => {
  let dir: string, a: string, b: string;
  // Frames 33–39 flicker A/B with sideways jitter and an RGB split; the edit is on B after.
  const glitch = (out: string, back: boolean) => {
    const sel = back ? 'if(between(T,1.1,1.3),eq(mod(N,2),0),1)' : 'if(between(T,1.1,1.3),eq(mod(N,2),0),lt(T,1.2))';
    const fx = (sign: number, k: number) => `format=gbrp,rgbashift=rh=${-3 * sign}:bh=${3 * sign}:enable='between(t,1.1,1.3)',crop=iw-12:ih:x='6+6*sin(n*${k})*between(t,1.1,1.3)':y=0,scale=180:320`;
    ff('-i', a, '-i', b, '-filter_complex', `[0]${fx(1, 2.1)}[A];[1]${fx(-1, 1.7)}[B];[A][B]blend=all_expr='if(${sel},A,B)',format=yuv420p[v]`, '-map', '[v]', '-t', '2.5', ...ENC, out);
    return out;
  };
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-glitch-'));
    a = path.join(dir, 'a.mp4'); b = path.join(dir, 'b.mp4');
    ff('-f', 'lavfi', '-i', 'testsrc2=s=180x320:r=30', '-t', '3', ...ENC, a);
    ff('-f', 'lavfi', '-i', 'gradients=s=180x320:r=30:d=3:speed=0.01:nb_colors=3:c0=0xFFD27A:c1=0x7A40FF:c2=0x103020:seed=3', '-t', '3', ...ENC, b);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('a glitch between two shots is found, splits the shots, and becomes the editor\'s glitch', async () => {
    const { recipe: r } = await analyzeReference({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, glitch(path.join(dir, 'g.mp4'), false));
    expect(r.slots).toHaveLength(2);
    expect(r.transitions).toHaveLength(1);
    expect(r.transitions[0]).toMatchObject({ kind: 'glitch', from: 's1', to: 's2' });
    expect(Math.abs(r.transitions[0]!.atSec - 1.2)).toBeLessThanOrEqual(0.07);
    expect(r.transitions[0]!.durationSec).toBeGreaterThan(0.15);
    expect(r.transitions[0]!.durationSec).toBeLessThan(0.45);
    expect(r.slots.flatMap(s => s.peaks).every(p => p.t < 1.0 || p.t > 1.4)).toBe(true); // the flicker isn't action
    const out = buildProject(r, 'take_src', { s1: { id: 'tA', durationSec: 3, width: 720, height: 1280 }, s2: { id: 'tB', durationSec: 3, width: 720, height: 1280 } });
    expect((M.mainTrack(out.project).items[1] as M.VideoClip).transitionIn?.kind).toBe('glitch');
  }, 60_000);

  it('a glitch that comes back to the same shot is an effect inside it; a plain cut stays a cut', async () => {
    const { recipe: r } = await analyzeReference({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, glitch(path.join(dir, 'gi.mp4'), true));
    expect(r.slots).toHaveLength(1);
    expect(r.transitions).toEqual([expect.objectContaining({ kind: 'glitch', from: 's1', to: 's1' })]);
    const cut = path.join(dir, 'cut.mp4');
    ff('-i', a, '-i', b, '-filter_complex', '[0]trim=0:1.2[x];[1]trim=0:1.3,setpts=PTS-STARTPTS[y];[x][y]concat=n=2:v=1[v]', '-map', '[v]', ...ENC, cut);
    const { recipe: c } = await analyzeReference({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, cut);
    expect(c.transitions.map(t => t.kind)).toEqual(['cut']);
  }, 60_000);
});
