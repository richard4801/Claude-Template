// Arabic, Hebrew, Hindi (Devanagari) and Thai in the server render (plans/edit-xl-options.md §4, step 3): shaped by
// HarfBuzz with the script's Noto face, words in bidi display order. Pixel checks against HarfBuzz's own outlines
// (glyphToPath: a different code path from the render's opentype.js outlines): the right glyphs in the right order,
// not the letter-by-letter unshaped drawing; right-to-left word order by colour; an Arabic caption in an export.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import * as hb from 'harfbuzzjs';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { CAPTION_STYLES } from '../src/editor/presets.js';
import { renderProject } from '../src/editor/render.js';
import * as TD from '../src/editor/textdraw.js';
import { grabFrame } from '../src/recreate/frames.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';
// @ts-expect-error a plain .mjs script, no types
import { fetchCjkFonts } from '../scripts/cjk-fonts.mjs';

const LATIN = path.resolve('assets/fonts/figtree_400.ttf');
const style: M.TextStyle = { font: 'sans', weight: 400, sizePct: 0.05, color: '#FFFFFF', align: 'left' };
const PX = 120;

async function raster(svg: string, w: number, h: number, channels: 1 | 3 = 1): Promise<Uint8Array> {
  const doc = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><rect width="${w}" height="${h}" fill="#000"/>${svg}</svg>`;
  const img = sharp(Buffer.from(doc)).removeAlpha();
  return new Uint8Array(await (channels === 1 ? img.greyscale() : img).raw().toBuffer());
}
function iou(a: Uint8Array, b: Uint8Array) {
  let i = 0, u = 0;
  for (let k = 0; k < a.length; k++) { const x = a[k]! > 128, y = b[k]! > 128; if (x && y) i++; if (x || y) u++; }
  return u ? i / u : 0;
}
const latinBase = () => { const f = TD.face(LATIN)!; return (f.ascender / f.unitsPerEm) * PX; };
/** [text] shaped and drawn by HarfBuzz itself (its own outlines, placed by its positions), at baseline [base]. */
function hbReference(file: string, text: string, base: number) {
  const b = fs.readFileSync(file), font = new hb.Font(new hb.Face(new hb.Blob(b.buffer.slice(b.byteOffset, b.byteOffset + b.length))));
  const upem = (font as unknown as { face?: { upem: number } }).face?.upem ?? 1000, k = PX / upem;
  const buf = new hb.Buffer(); buf.addText(text); buf.guessSegmentProperties(); hb.shape(font, buf);
  const pos = buf.getGlyphPositions();
  let x = 0;
  return buf.getGlyphInfos().map((g, i) => {
    const p = pos[i]!, s = `<path transform="translate(${x + p.xOffset * k} ${base - p.yOffset * k}) scale(${k} ${-k})" d="${font.glyphToPath(g.codepoint)}" fill="#fff"/>`;
    x += p.xAdvance * k;
    return s;
  }).join('');
}
/** [text] drawn letter by letter in reading order, no shaping (what the render did before step 3). */
function unshaped(file: string, text: string, base: number) {
  const f = TD.face(file)!;
  let x = 0, d = '';
  for (const ch of text) { const g = f.charToGlyph(ch); d += g.getPath(x, base, PX).toPathData(2); x += ((g.advanceWidth ?? 0) / f.unitsPerEm) * PX; }
  return `<path d="${d}" fill="#fff"/>`;
}

describe('shaped scripts (unit, HarfBuzz)', () => {
  beforeAll(async () => { fetchCjkFonts(TD.CJK_DIR); await TD.ensureShaper(); }, 300_000);
  afterAll(() => TD.releaseCjk());

  // [name, script, text, how unlike the letter-by-letter drawing it must be]: Arabic joins, Hebrew reverses, Hindi forms
  // a conjunct; Thai only moves its stacked marks (a tall consonant with a vowel and a tone mark above), so it differs less.
  const cases: [string, TD.ShapedKind, string, number][] = [['Arabic', 'arabic', 'مرحبا بالعالم', 0.8], ['Hebrew', 'hebrew', 'שלום', 0.8], ['Hindi', 'devanagari', 'नमस्ते दोस्तों', 0.8], ['Thai', 'thai', 'ที่ฝั่ง', 0.9]];
  for (const [name, kind, text, unlike] of cases) {
    it(`${name}: shaped like HarfBuzz draws it, not letter by letter`, async () => {
      const word = text.split(' ')[0]!;
      const missing = new Set<string>();
      const b = TD.drawBlock([{ text: word, color: '#FFFFFF' }], style, PX, 5000, LATIN, { missing, id: name })!;
      expect([...missing]).toEqual([]);
      const w = Math.ceil(b.width) + 20, h = Math.ceil(b.height) + 40, base = latinBase(), file = TD.scriptFile(kind, false);
      const got = await raster(b.over, w, h);
      const right = iou(got, await raster(hbReference(file, word, base), w, h));
      const before = iou(got, await raster(unshaped(file, word, base), w, h));
      console.log(`${name} '${word}': IoU vs HarfBuzz ${right.toFixed(3)}, vs letter-by-letter ${before.toFixed(3)}`);
      expect(right).toBeGreaterThan(0.97);
      expect(before).toBeLessThan(unlike);
    });
  }

  /** Each word in its own colour; their centres left to right. */
  const order = async (words: string[]) => {
    const colors = ['#FF0000', '#00FF00', '#0000FF', '#FFFF00'];
    const b = TD.drawBlock(words.map((t, i) => ({ text: t, color: colors[i]! })), { ...style, align: 'center' }, PX, 50_000, LATIN, { missing: new Set(), id: 'o' })!;
    const w = Math.ceil(b.width) + 20, h = Math.ceil(b.height) + 40, px = await raster(b.over, w, h, 3);
    const cx = words.map((_, i) => {
      const c = [0, 1, 2].map(k => parseInt(colors[i]!.slice(1 + 2 * k, 3 + 2 * k), 16));
      let s = 0, n = 0;
      for (let p = 0; p < w * h; p++) if (c.every((v, k) => Math.abs(px[p * 3 + k]! - v) < 40)) { s += p % w; n++; }
      return n ? s / n : NaN;
    });
    return words.map((t, i) => ({ t, x: cx[i]! })).sort((a, b) => a.x - b.x).map(x => x.t);
  };
  it('right-to-left words read right to left; numbers and Latin inside stay left to right (bidi)', async () => {
    expect(await order(['שלום', 'עולם'])).toEqual(['עולם', 'שלום']);
    expect(await order(['مرحبا', '2025', 'world'])).toEqual(['2025', 'world', 'مرحبا']);
    expect(await order(['Hello', 'שלום', 'world'])).toEqual(['Hello', 'שלום', 'world']); // a Latin paragraph keeps its order
    expect(await order(['नमस्ते', 'दोस्तों'])).toEqual(['नमस्ते', 'दोस्तों']); // Hindi is left to right
  });

  it('without the shaper loaded, the word is still drawn and the render is told (never silent)', () => {
    // A fresh shaper-less state can't be made inside this process once loaded; the flag is what the render reports.
    expect(TD.UNSHAPED).toBe('unshaped script');
    expect(TD.shapedKind('مرحبا')).toBe('arabic'); expect(TD.shapedKind('שלום')).toBe('hebrew');
    expect(TD.shapedKind('नमस्ते')).toBe('devanagari'); expect(TD.shapedKind('สวัสดี')).toBe('thai'); expect(TD.shapedKind('Hello')).toBeNull();
  });
});

describe.skipIf(!hasFfmpeg)('an Arabic caption in an export (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  beforeAll(() => {
    fetchCjkFonts(TD.CJK_DIR);
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-shaped-'));
    files.g = path.join(dir, 'g.mp4');
    ff('-f', 'lavfi', '-i', 'color=c=0x404040:s=180x320:r=30:d=4', ...ENC, files.g);
  }, 300_000);
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('draws it shaped with nothing unsupported; the first word spoken is lit on the right', async () => {
    const W = 360, H = 640;
    const p: M.EditProject = {
      version: 2, sourceTakeId: 'tg', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
      assets: [{ id: 'g', kind: 'video', take: 'tg', durationSec: 4 }],
      tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c1', asset: 'g', inSec: 0, outSec: 4, speed: 1 } as M.VideoClip] },
        { id: 'cap', kind: 'caption', items: [], caption: {
          asset: 'g', language: 'ar',
          words: [{ text: 'مرحبا', startSec: 0.5, endSec: 1.2 }, { text: 'بكم', startSec: 1.2, endSec: 1.8 }, { text: 'جميعا', startSec: 1.8, endSec: 2.6 }],
          style: { ...CAPTION_STYLES.highlight, color: '#FFFFFF', highlightColor: '#FFD400', shadow: undefined, wordsPerPage: 3 } } as M.CaptionTrack }],
    };
    M.validate(p);
    const out = path.join(dir, 'ar.mp4');
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { maxSide: 640, audio: 'none' });
    expect(r.unsupported).toEqual([]);
    const lit = async (t: number) => {
      const f = await grabFrame('ffmpeg', out, t, W, H);
      let s = 0, n = 0;
      for (let y = Math.round(0.6 * H); y < Math.round(0.85 * H); y++) for (let x = 0; x < W; x++) { const i = (y * W + x) * 3; if (f.rgb[i]! > 200 && f.rgb[i + 1]! > 170 && f.rgb[i + 2]! < 90) { s += x; n++; } }
      return { n, cx: n ? s / n / W : NaN };
    };
    const first = await lit(0.8), last = await lit(2.2);
    expect(first.n).toBeGreaterThan(20); expect(last.n).toBeGreaterThan(20);
    expect(first.cx).toBeGreaterThan(0.55); // the first word is the rightmost
    expect(last.cx).toBeLessThan(0.45);     // the last word is the leftmost
  }, 120_000);
});
