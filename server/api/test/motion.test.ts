// Motion peaks (workstream 1, plans/recreate-edit.md): frame-difference energy on a grey proxy, action peaks and hard
// cuts, on synthetic clips made with ffmpeg (a still picture with a box that moves only in known bursts). Free, local.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { energyCurve, findCuts, findPeaks, measureMotion } from '../src/editor/motion.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const enc = ['-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-r', '30'];

describe.skipIf(!hasFfmpeg)('Motion peaks', () => {
  let dir: string, bursts: string, cut: string, flash: string, still: string, fade: string;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-motion-'));
    bursts = path.join(dir, 'bursts.mp4'); fade = path.join(dir, 'fade.mp4'); cut = path.join(dir, 'cut.mp4'); flash = path.join(dir, 'flash.mp4'); still = path.join(dir, 'still.mp4');
    // A white box on grey (portrait): still, except two fast moves at 1.0–1.3 s and 2.5–2.8 s (the second is bigger).
    const x = "if(between(t,1,1.3),40+(t-1)*300,if(between(t,1.3,2.5),130,if(between(t,2.5,2.8),130-(t-2.5)*400,10)))";
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=gray:s=180x320:d=4:r=30', '-f', 'lavfi', '-i', 'color=c=white:s=40x40:d=4:r=30',
      '-filter_complex', `[0][1]overlay=x='${x}':y=140:eval=frame`, '-t', '4', ...enc, bursts]);
    // A hard cut at 2.0 s between two still pictures (no motion at all).
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=0x202060:s=180x320:d=2:r=30', '-f', 'lavfi', '-i', 'testsrc2=s=180x320:d=2:r=30',
      '-filter_complex', '[1]trim=end_frame=1,loop=59:1:0,setpts=N/30/TB[b];[0][b]concat=n=2:v=1', ...enc, cut]);
    // A one-frame white flash at 1.5 s in a still shot.
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=0x204020:s=180x320:d=3:r=30', '-vf', "drawbox=c=white:t=fill:enable='eq(n,45)'", ...enc, flash]);
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=gray:s=180x320:d=2:r=30', ...enc, still]);
    // A one-second crossfade between two still pictures: a transition, not a cut.
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=0x202060:s=180x320:d=2:r=30', '-f', 'lavfi', '-i', 'color=c=0xe0c060:s=180x320:d=2:r=30',
      '-filter_complex', '[0][1]xfade=transition=fade:duration=1:offset=1', ...enc, fade]);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('measures a 96-px grey proxy at the source frame rate (≤ 30 fps), keeping the aspect', async () => {
    const m = await measureMotion('ffmpeg', 'ffprobe', bursts);
    expect([m.fps, m.width, m.height]).toEqual([30, 96, 170]);
    expect(m.energy.length).toBe(120);
    expect((await measureMotion('ffmpeg', 'ffprobe', bursts, { fps: 10 })).energy.length).toBe(40);
    expect(m.energy[0]).toBe(0);
  });

  it('finds the two action bursts (strength relative to the strongest); a still clip has none', async () => {
    const m = await measureMotion('ffmpeg', 'ffprobe', bursts);
    const peaks = findPeaks(m);
    expect(peaks.length).toBe(2);
    expect(peaks[0]!.t).toBeGreaterThanOrEqual(0.95);
    expect(peaks[0]!.t).toBeLessThanOrEqual(1.4);
    expect(peaks[1]!.t).toBeGreaterThanOrEqual(2.45);
    expect(peaks[1]!.t).toBeLessThanOrEqual(2.9);
    expect(Math.max(peaks[0]!.strength, peaks[1]!.strength)).toBe(1);
    expect(Math.min(peaks[0]!.strength, peaks[1]!.strength)).toBeGreaterThan(0.5);
    expect(findCuts(m)).toEqual([]);
    expect(findPeaks(await measureMotion('ffmpeg', 'ffprobe', still))).toEqual([]);
    const c = energyCurve(m, 20);
    expect(c.values.length).toBeLessThanOrEqual(20);
    expect(Math.max(...c.values)).toBe(1);
  });

  it('a hard cut is a cut, not an action peak; a one-frame flash is marked as a flash', async () => {
    const m = await measureMotion('ffmpeg', 'ffprobe', cut);
    const cuts = findCuts(m);
    expect(cuts.length).toBe(1);
    expect(Math.abs(cuts[0]!.t - 2)).toBeLessThanOrEqual(1 / 30 + 0.001); // frame-accurate
    expect(findPeaks(m, { cuts })).toEqual([]);
    const f = await measureMotion('ffmpeg', 'ffprobe', flash);
    const fc = findCuts(f);
    expect(fc.length).toBe(2);
    expect(fc[0]!.flash).toBe(true);
    expect(Math.abs(fc[0]!.t - 1.5)).toBeLessThanOrEqual(0.1);
    expect(findPeaks(f)).toEqual([]);
    expect(findCuts(await measureMotion('ffmpeg', 'ffprobe', fade))).toEqual([]);
  });

  it('minGapSec merges close peaks; max keeps the strongest', async () => {
    const m = await measureMotion('ffmpeg', 'ffprobe', bursts);
    expect(findPeaks(m, { minGapSec: 3 }).length).toBe(1);
    expect(findPeaks(m, { max: 1 })[0]!.strength).toBe(1);
  });
});
