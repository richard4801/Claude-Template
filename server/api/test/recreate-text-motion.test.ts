// Recreate this edit · text animation in/out and font family (workstream 1, gap G4). Captions drawn with ffmpeg that
// fade, type on or cut in; each is found by the tracker, then its motion is measured. And the font matcher picks the
// editor font a caption was set in (all six, light and dark).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { FONT_DIR } from '../src/editor/render.js';
import { readWords } from '../src/recreate/ocr.js';
import { findText, type TextItem } from '../src/recreate/text.js';
import { classifyIn, textMotions } from '../src/recreate/textMotion.js';
import { execFileSync } from 'node:child_process';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

const TESSERACT = (() => { try { execFileSync('tesseract', ['--version']); return true; } catch { return false; } })();
const BG = 'gradients=s=360x640:c0=0x204060:c1=0x806040:d=4:speed=0.00001';

describe('text motion (unit)', () => {
  it('classifies a contrast series: a gradual rise is a fade, the right half late is a typewriter, a step is a cut', () => {
    const ramp = [0, 0, 0, 10, 20, 30, 40, 50, 50, 50];
    expect(classifyIn(ramp, ramp, ramp)).toMatchObject({ kind: 'fade' });
    expect(classifyIn(ramp, ramp, ramp).durationSec).toBeCloseTo(0.5, 1);
    const step = [0, 0, 0, 50, 50, 50, 50];
    expect(classifyIn(step, step, step)).toEqual({ kind: 'cut', durationSec: 0 });
    const left = [0, 0, 50, 50, 50, 50, 50, 50], right = [0, 0, 0, 0, 0, 50, 50, 50];
    expect(classifyIn(left.map((l, i) => (l + right[i]!) / 2), left, right)).toMatchObject({ kind: 'typewriter' });
    expect(classifyIn([3, 3, 4, 4], [3, 3, 4, 4], [3, 3, 4, 4])).toEqual({ kind: 'cut', durationSec: 0 }); // nothing to measure
  });
});

describe.skipIf(!hasFfmpeg)('text motion on video', () => {
  let dir: string;
  const font = path.join(FONT_DIR, 'figtree_700.ttf');
  const draw = (opts: string) => `drawtext=fontfile=${font}:fontsize=44:fontcolor=white:borderw=2:bordercolor=black:x=40:y=460:${opts}`;
  const clip = (name: string, vf: string) => { const out = path.join(dir, `${name}.mp4`); ff('-f', 'lavfi', '-i', BG, '-vf', vf, '-t', '4', ...ENC, out); return out; };
  const motionOf = async (file: string) => {
    const found = await findText('ffmpeg', file, 640);
    expect(found.length).toBeGreaterThanOrEqual(1);
    const [it0] = await textMotions('ffmpeg', file, found.slice(0, 1), { width: 360, height: 640, durationSec: 4 });
    return it0 as TextItem;
  };
  beforeAll(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-text-motion-')); });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('a caption that fades in over 0.6 s and out over 0.4 s', async () => {
    const r = await motionOf(clip('fade', draw(`text='SUMMER':alpha='if(lt(t,1),0,if(lt(t,1.6),(t-1)/0.6,if(lt(t,2.6),1,if(lt(t,3),(3-t)/0.4,0))))'`)));
    expect(r.animIn).toBe('fade');
    expect(r.animInSec!).toBeGreaterThan(0.3);
    expect(r.animInSec!).toBeLessThan(1);
    expect(r.animOut).toBe('fade');
  }, 60_000);

  it('a caption typed on letter by letter, then cut', async () => {
    const word = 'SUMMER VIBES';
    const vf = [...word].map((_, i) => draw(`text='${word.slice(0, i + 1)}':enable='between(t,${(1 + i * 0.07).toFixed(2)},${i === word.length - 1 ? 3 : (1 + (i + 1) * 0.07 - 0.001).toFixed(3)})'`)).join(',');
    const r = await motionOf(clip('type', vf));
    expect(r.animIn).toBe('typewriter');
    expect(r.animOut).toBe('cut');
  }, 60_000);

  it('a caption that cuts in and out', async () => {
    const r = await motionOf(clip('cut', draw(`text='SUMMER':enable='between(t,1,3)'`)));
    expect(r.animIn).toBe('cut');
    expect(r.animOut).toBe('cut');
    expect(r.animInSec).toBeUndefined();
  }, 60_000);
});

const FILES: [TextItem['fontId'], string][] = [['sans', 'figtree_700'], ['serif', 'instrument_serif_400'], ['rounded', 'outfit_700'], ['condensed', 'barlow_condensed_700'], ['mono', 'dm_mono_500'], ['marker', 'permanent_marker_400']];
describe.skipIf(!hasFfmpeg || !TESSERACT)('font family from the caption\'s shape', () => {
  let dir: string;
  beforeAll(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-font-')); });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));
  it.each(FILES)('%s, white on a gradient and black on a light wall', async (id, file) => {
    for (const color of ['white', 'black'] as const) {
      const out = path.join(dir, `${id}-${color}.mp4`);
      const bg = color === 'white' ? BG : 'color=c=0xd0c8b0:s=360x640:d=2';
      ff('-f', 'lavfi', '-i', bg, '-vf', `drawtext=fontfile=${path.join(FONT_DIR, `${file}.ttf`)}:text='day in my life':fontsize=40:fontcolor=${color}${color === 'white' ? ':borderw=2:bordercolor=black' : ''}:x=(w-tw)/2:y=460`, '-t', '2', ...ENC, out);
      const item: TextItem = { id: 'x1', sizeFrac: 0.06, startSec: 0.2, endSec: 1.8, box: { x: 0.04, y: 0.7, w: 0.92, h: 0.09 }, color: color === 'white' ? '#FFFFFF' : '#000000', words: null, fontId: 'sans', animIn: null, animOut: null, confidence: 0.4 };
      const [r] = await readWords({ ffmpeg: 'ffmpeg', tesseract: 'tesseract' }, out, [item], { width: 360, height: 640 });
      expect(r!.words?.replace(/v/g, 'y').toLowerCase()).toBe('day in my life');
      expect(r!.fontId, `${id} ${color}`).toBe(id);
    }
  }, 120_000);
});
