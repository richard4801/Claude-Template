// AI suite (workstream 1): finishing a model's take — the planned length (a provider rounded 8 s up to 10 s) and even
// loudness (H3 sound came back near −50 dB). Real ffmpeg, no providers.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { probe } from '../src/replicate/media.js';
import { finishPlan, finishTake, measureLoudness, peakDb, TARGET_LUFS } from '../src/suite/finish.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();

describe.skipIf(!hasFfmpeg)('Suite · finishing a take', () => {
  let dir: string, quiet: string, mute: string;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-finish-'));
    quiet = path.join(dir, 'quiet.mp4'); mute = path.join(dir, 'mute.mp4');
    const v = ['-f', 'lavfi', '-i', 'testsrc=size=180x320:rate=24'];
    execFileSync('ffmpeg', ['-y', '-v', 'error', ...v, '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '10', '-af', 'volume=-50dB',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', quiet]);
    execFileSync('ffmpeg', ['-y', '-v', 'error', ...v, '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', mute]);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('plans: cut only when longer than planned (beyond slack); level only with sound', async () => {
    const qi = await probe('ffprobe', quiet), mi = await probe('ffprobe', mute);
    expect(finishPlan(qi, 8, { level: true })).toEqual({ trimTo: 8, level: true });
    expect(finishPlan(qi, 10, { level: true })).toEqual({ trimTo: null, level: true });
    expect(finishPlan(qi, null, { level: true })).toEqual({ trimTo: null, level: true });
    expect(finishPlan(mi, 6, { level: true })).toEqual({ trimTo: null, level: false });
  });

  it('a 10 s render planned at 8 s with −50 dB sound comes out 8 s at about −16 LUFS', async () => {
    const info = await probe('ffprobe', quiet);
    expect(await peakDb('ffmpeg', quiet)).toBeLessThan(-50); // so faint loudnorm alone reads it as silence
    expect((await measureLoudness('ffmpeg', quiet))!.i).toBe(-Infinity);
    const out = path.join(dir, 'out.mp4');
    const did = await finishTake('ffmpeg', quiet, out, info, finishPlan(info, 8, { level: true }));
    expect(did).toMatchObject({ trimmedFrom: expect.any(Number) });
    expect(did!.levelledFrom).toBeLessThan(-45);
    const after = await probe('ffprobe', out);
    expect(after.duration).toBeGreaterThan(7.8);
    expect(after.duration).toBeLessThan(8.3);
    expect(after.audioCodec).toBe('aac');
    expect(Math.abs((await measureLoudness('ffmpeg', out))!.i - TARGET_LUFS)).toBeLessThan(1.5);
  });

  it('nothing to do (right length, no sound) writes nothing', async () => {
    const info = await probe('ffprobe', mute);
    const out = path.join(dir, 'none.mp4');
    expect(await finishTake('ffmpeg', mute, out, info, finishPlan(info, 6, { level: true }))).toBeNull();
    expect(fs.existsSync(out)).toBe(false);
  });
});
