// Reverse in pieces (src/editor/reverse.ts): the frames come out in reverse order, sound too, and memory stays at
// one piece whatever the length (the production server has 512 MB).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { reverseVideo } from '../src/editor/reverse.js';
import { probe } from '../src/replicate/media.js';
import { hasFfmpeg } from './recreate-fixture.js';

describe.skipIf(!hasFfmpeg)('reverse in pieces (ffmpeg)', () => {
  let dir: string;
  beforeAll(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-revtest-')); });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  const luma = (file: string, t: number) =>
    execFileSync('ffmpeg', ['-v', 'error', '-ss', t.toFixed(3), '-i', file, '-frames:v', '1', '-vf', 'scale=1:1,format=gray', '-f', 'rawvideo', '-'])[0]!;

  it('a brightness ramp comes out falling, across every join, with its sound and length', async () => {
    const src = path.join(dir, 'ramp.mp4'), out = path.join(dir, 'ramp_rev.mp4');
    // 5.5 s getting brighter (pieces of 0.5 s), a tone.
    execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=30:d=5.5,format=gray,geq=lum=\'T*40\'', '-f', 'lavfi', '-i', 'sine=frequency=330:duration=5.5',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', '-y', src]);
    await reverseVideo('ffmpeg', src, out, true, 5.5);
    const info = await probe('ffprobe', out);
    expect(Math.abs(info.duration - 5.5)).toBeLessThan(0.15);
    expect(info.audioCodec).toBeTruthy();
    const ts = [0.05, 0.45, 0.95, 1.05, 1.5, 1.95, 2.05, 2.5, 3.5, 4.45, 4.55, 5.0, 5.4];
    const ys = ts.map(t => luma(out, t));
    // Expected: brightness of the source at 5.5 − t (≈ 40·(5.5 − t)), within encoding error, falling throughout.
    ts.forEach((t, i) => expect(Math.abs(ys[i]! - 40 * (5.5 - t)), `t=${t}: ${ys[i]}`).toBeLessThan(12));
    for (let i = 1; i < ys.length; i++) expect(ys[i]!).toBeLessThanOrEqual(ys[i - 1]! + 3);
  }, 120_000);

  it('peak memory stays at one piece on a 20 s 1080p clip', async () => {
    const src = path.join(dir, 'long.mp4'), out = path.join(dir, 'long_rev.mp4');
    execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=1080x1920:r=30:d=20', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=20',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', '-y', src]);
    // A wrapper that records each ffmpeg's peak resident memory (VmHWM, kB).
    const log = path.join(dir, 'hwm.log'), wrap = path.join(dir, 'ffmpeg-hwm.sh');
    fs.writeFileSync(wrap, `#!/bin/bash\nffmpeg "$@" &\npid=$!\npeak=0\nwhile kill -0 $pid 2>/dev/null; do v=$(awk '/VmHWM/{print $2}' /proc/$pid/status 2>/dev/null); [ -n "$v" ] && [ "$v" -gt "$peak" ] && peak=$v; sleep 0.02; done\nwait $pid; rc=$?\necho $peak >> ${log}\nexit $rc\n`);
    fs.chmodSync(wrap, 0o755);
    await reverseVideo(wrap, src, out, true, 20);
    const peaks = fs.readFileSync(log, 'utf8').trim().split('\n').map(Number);
    expect(peaks.length).toBe(41); // 40 pieces of 0.5 s + the join
    const peakMb = Math.max(...peaks) / 1024;
    console.log(`reverse 20 s 1080p: peak ffmpeg RSS ${peakMb.toFixed(0)} MB over ${peaks.length} runs`);
    expect(peakMb).toBeLessThan(260); // the 512 MB server also runs Node
    expect(Math.abs((await probe('ffprobe', out)).duration - 20)).toBeLessThan(0.2);
  }, 300_000);
});
