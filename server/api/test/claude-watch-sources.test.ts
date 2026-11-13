// watch on awkward sources (ci_592145d6bdee: an edit's 1280x720 upload came back as ALL-BLACK frames). Frames are
// picked on a constant time grid, so a variable-frame-rate video (here: a dense 120 fps black lead-in, then 2 fps
// picture) gives the moments asked for instead of the lead-in; 10-bit HLG/PQ HDR is converted to SDR at about the
// brightness of the SDR original; rotated phone video is turned upright. Fixtures are made with ffmpeg here.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import sharp from 'sharp';
import { BLACK_LUMA, colourOf, grab, gridFps, isHdr, lumaOf } from '../src/claude/watch.js';
import { probe } from '../src/replicate/media.js';

const has = (args: string[], re: RegExp) => { try { return re.test(execFileSync('ffmpeg', ['-hide_banner', ...args], { encoding: 'utf8' })); } catch { return false; } };
const hasFfmpeg = has(['-version'], /ffmpeg/);
const hasHdrTools = hasFfmpeg && has(['-encoders'], /libx265/) && has(['-filters'], /\szscale\s/);
const ff = (...args: string[]) => execFileSync('ffmpeg', ['-y', '-v', 'error', ...args]);

describe.skipIf(!hasFfmpeg)('watch frames from awkward sources are never black', () => {
  let dir: string;
  const at = async (file: string, times: number[]) => {
    const info = await probe('ffprobe', file);
    const fps = gridFps(info.fps);
    const got = await grab('ffmpeg', file, times.map(t => Math.round(t * fps)), 256, 0, undefined, { fps, colour: await colourOf('ffprobe', file) });
    return { info, fps, got, lumas: await Promise.all(times.map(async t => { const b = got.get(Math.round(t * fps)); return b ? lumaOf(b) : -1; })) };
  };
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-watch-src-'));
    // VFR: 2 s of black at 120 fps (240 frames), then 18 s of picture at 2 fps (36 frames). The average rate is ~13.8
    // fps, so counting raw frames put 1 s → frame 14 … 15 s → frame 207: all inside the black lead-in.
    ff('-f', 'lavfi', '-i', 'color=black:s=320x180:r=120:d=2', '-f', 'lavfi', '-i', 'testsrc2=s=320x180:r=2:d=18',
      '-filter_complex', '[0]format=yuv420p,setsar=1[a];[1]format=yuv420p,setsar=1[b];[a][b]concat=n=2:v=1[v]', '-map', '[v]', '-fps_mode', 'vfr', '-c:v', 'libx264', '-preset', 'ultrafast', path.join(dir, 'vfr.mp4'));
    ff('-f', 'lavfi', '-i', 'testsrc2=s=320x180:r=30:d=3', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', path.join(dir, 'sdr.mp4'));
    // Rotated: the same picture with a 90° display matrix (as phones write portrait video).
    ff('-display_rotation', '90', '-i', path.join(dir, 'sdr.mp4'), '-c', 'copy', path.join(dir, 'rot.mp4'));
    if (hasHdrTools) for (const [trc, name] of [['arib-std-b67', 'hlg.mov'], ['smpte2084', 'pq.mp4']] as const) {
      // Real 10-bit HEVC HDR: the SDR picture converted to HLG / PQ (BT.2020), tagged as iPhone / HDR10 files are.
      ff('-f', 'lavfi', '-i', 'testsrc2=s=320x180:r=30:d=3', '-vf', `format=yuv420p,zscale=tin=bt709:pin=bt709:min=bt709:rin=tv:npl=100:t=${trc}:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le`,
        '-c:v', 'libx265', '-preset', 'ultrafast', '-x265-params', `log-level=error:colorprim=bt2020:transfer=${trc}:colormatrix=bt2020nc`,
        '-color_primaries', 'bt2020', '-color_trc', trc, '-colorspace', 'bt2020nc', '-tag:v', 'hvc1', path.join(dir, name));
    }
  });
  afterAll(() => { if (dir) fs.rmSync(dir, { recursive: true, force: true }); });

  it('VFR: frames come from the asked times on a constant grid, not the dense black lead-in', async () => {
    const { lumas } = await at(path.join(dir, 'vfr.mp4'), [1, 4, 8, 12, 16, 19]);
    expect(lumas[0]).toBeLessThan(BLACK_LUMA); // 1 s really is black
    for (const l of lumas.slice(1)) expect(l).toBeGreaterThan(60);
  });

  it('rotated video comes out upright (portrait) and not black', async () => {
    const { got, lumas } = await at(path.join(dir, 'rot.mp4'), [0.5, 1.5, 2.5]);
    for (const l of lumas) expect(l).toBeGreaterThan(60);
    const m = await sharp([...got.values()][0]!).metadata();
    expect(m.height!).toBeGreaterThan(m.width!);
  });

  it.skipIf(!hasHdrTools)('10-bit HEVC HLG and PQ: converted to SDR at about the SDR original\'s brightness', async () => {
    const ref = (await at(path.join(dir, 'sdr.mp4'), [0.5, 1.5, 2.5])).lumas;
    for (const f of ['hlg.mov', 'pq.mp4']) {
      const file = path.join(dir, f);
      const c = await colourOf('ffprobe', file);
      expect(isHdr(c)).toBe(true);
      expect(c.pixFmt).toMatch(/10/);
      const { lumas } = await at(file, [0.5, 1.5, 2.5]);
      lumas.forEach((l, i) => { expect(l).toBeGreaterThan(60); expect(Math.abs(l - ref[i]!)).toBeLessThan(20); });
    }
  });

  it('an HDR file with colour tags the conversion can\'t read still gives frames (plain conversion)', async () => {
    const file = path.join(dir, 'sdr.mp4');
    const got = await grab('ffmpeg', file, [15, 45], 128, 0, undefined, { fps: 30, colour: { transfer: 'smpte2084', primaries: 'nonsense', matrix: 'nonsense' } });
    expect(got.size).toBe(2);
    for (const b of got.values()) expect(await lumaOf(b)).toBeGreaterThan(60);
  });
});
