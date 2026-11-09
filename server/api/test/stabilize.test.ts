// Stabilise (src/editor/stabilize.ts): a shaken picture comes out steady, with its sound and length, and a 20 s 1080p
// clip stays well inside the 512 MB server.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { stabilizeVideo, vidstabAvailable } from '../src/editor/stabilize.js';
import { probe } from '../src/replicate/media.js';
import { hasFfmpeg } from './recreate-fixture.js';

describe.skipIf(!hasFfmpeg)('stabilise (ffmpeg vid.stab)', () => {
  let dir: string;
  beforeAll(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-stabtest-')); });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  /** Mean absolute difference between consecutive frames (grey, 90 × 160): how much the picture jumps around. */
  const jitter = (file: string) => {
    const raw = execFileSync('ffmpeg', ['-v', 'error', '-i', file, '-vf', 'scale=90:160,format=gray', '-f', 'rawvideo', '-'], { maxBuffer: 64 * 1024 * 1024 });
    const F = 90 * 160, n = Math.floor(raw.length / F);
    let s = 0;
    for (let f = 1; f < n; f++) for (let i = 0; i < F; i += 3) s += Math.abs(raw[f * F + i]! - raw[(f - 1) * F + i]!);
    return s / ((n - 1) * (F / 3));
  };

  it('is there on this ffmpeg; a shaken still comes out much steadier, with its sound and length', async () => {
    expect(await vidstabAvailable('ffmpeg')).toBe(true);
    const src = path.join(dir, 'shaky.mp4'), out = path.join(dir, 'steady.mp4');
    // A detailed still, cropped at a position that jumps every frame (hand shake), 4 s with a tone.
    execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=480x800:r=30:d=4', '-f', 'lavfi', '-i', 'sine=frequency=330:duration=4',
      '-filter_complex', "[0]trim=end_frame=1,loop=loop=-1:size=1,setpts=N/30/TB,crop=360:640:x='60+30*sin(n*1.7)+20*sin(n*0.9)':y='80+30*cos(n*1.3)+20*sin(n*2.1)',trim=duration=4[v]",
      '-map', '[v]', '-map', '1:a', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', '-y', src]);
    await stabilizeVideo('ffmpeg', src, out, true, 4);
    const info = await probe('ffprobe', out);
    expect(Math.abs(info.duration - 4)).toBeLessThan(0.15);
    expect(info.audioCodec).toBe('aac');
    const before = jitter(src), after = jitter(out);
    console.log(`stabilise: frame-to-frame change ${before.toFixed(1)} → ${after.toFixed(1)}`);
    expect(after).toBeLessThan(before * 0.5);
  }, 120_000);

  it('peak memory on a 20 s 1080p clip stays well under the 512 MB box', async () => {
    const src = path.join(dir, 'long.mp4'), out = path.join(dir, 'long_steady.mp4');
    execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=1080x1920:r=30:d=20', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=20',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', '-y', src]);
    const log = path.join(dir, 'hwm.log'), wrap = path.join(dir, 'ffmpeg-hwm.sh');
    fs.writeFileSync(wrap, `#!/bin/bash\nffmpeg "$@" &\npid=$!\npeak=0\nwhile kill -0 $pid 2>/dev/null; do v=$(awk '/VmHWM/{print $2}' /proc/$pid/status 2>/dev/null); [ -n "$v" ] && [ "$v" -gt "$peak" ] && peak=$v; sleep 0.05; done\nwait $pid; rc=$?\necho $peak >> ${log}\nexit $rc\n`);
    fs.chmodSync(wrap, 0o755);
    const t0 = Date.now();
    await stabilizeVideo(wrap, src, out, true, 20);
    const peaks = fs.readFileSync(log, 'utf8').trim().split('\n').map(Number);
    expect(peaks.length).toBe(2);
    const peakMb = Math.max(...peaks) / 1024;
    console.log(`stabilise 20 s 1080p: peak ffmpeg RSS detect ${(peaks[0]! / 1024).toFixed(0)} MB, transform ${(peaks[1]! / 1024).toFixed(0)} MB, ${((Date.now() - t0) / 1000).toFixed(0)} s`);
    expect(peakMb).toBeLessThan(300);
    expect(Math.abs((await probe('ffprobe', out)).duration - 20)).toBeLessThan(0.2);
  }, 400_000);
});
