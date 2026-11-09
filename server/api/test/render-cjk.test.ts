// Chinese, Japanese and Korean in the server render (plans/edit-xl-options.md §4, step 2): Noto Sans SC / JP / KR, the
// face picked by script and caption language, loaded only when needed and released after the render; captions in
// ja / zh / th drawn touching. Pixel checks: the right glyphs, in the right order, against the font's own outlines;
// and the peak memory of a 1080p export with a Japanese caption.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import * as TD from '../src/editor/textdraw.js';
import { grabFrame } from '../src/recreate/frames.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';
// @ts-expect-error a plain .mjs script, no types
import { fetchCjkFonts } from '../scripts/cjk-fonts.mjs';

const LATIN = path.resolve('assets/fonts/figtree_400.ttf');
const style: M.TextStyle = { font: 'sans', weight: 400, sizePct: 0.05, color: '#FFFFFF', align: 'left' };
const PX = 120;

/** An SVG fragment rasterised to a grey mask (0–255) of w × h. */
async function mask(svg: string, w: number, h: number): Promise<Uint8Array> {
  const doc = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><rect width="${w}" height="${h}" fill="#000"/>${svg}</svg>`;
  return new Uint8Array(await sharp(Buffer.from(doc)).greyscale().raw().toBuffer());
}
/** Overlap of two masks' inked pixels (intersection over union). */
function iou(a: Uint8Array, b: Uint8Array) {
  let i = 0, u = 0;
  for (let k = 0; k < a.length; k++) { const x = a[k]! > 128, y = b[k]! > 128; if (x && y) i++; if (x || y) u++; }
  return u ? i / u : 0;
}
/** [text] drawn straight from a font's outlines at baseline [base] (the reference the block must match). */
const reference = (font: string, text: string, base: number) => `<path d="${TD.face(font)!.getPath(text, 0, base, PX).toPathData(2)}" fill="#fff"/>`;

describe('CJK text (unit, Noto faces)', () => {
  beforeAll(() => { fetchCjkFonts(TD.CJK_DIR); }, 300_000);
  afterAll(() => TD.releaseCjk());

  it('Japanese draws the right glyphs in the right order, from the JP face, only that face loaded', async () => {
    TD.releaseCjk();
    const missing = new Set<string>();
    const b = TD.drawBlock([{ text: '日本語です', color: '#FFFFFF' }], style, PX, 5000, LATIN, { missing, id: 'ja', language: 'ja' })!;
    expect(missing.size).toBe(0);
    expect(TD.cjkLoaded()).toBe(1);
    const latin = TD.face(LATIN)!, base = (latin.ascender / latin.unitsPerEm) * PX;
    const w = Math.ceil(b.width) + 10, h = Math.ceil(b.height) + 10;
    const got = await mask(b.over, w, h);
    const right = await mask(reference(TD.cjkFile('jp', false), '日本語です', base), w, h);
    const swapped = await mask(reference(TD.cjkFile('jp', false), 'です語本日', base), w, h);
    expect(iou(got, right)).toBeGreaterThan(0.97);
    expect(iou(got, swapped)).toBeLessThan(0.5);
    TD.releaseCjk();
    expect(TD.cjkLoaded()).toBe(0);
  });

  it('the face follows the script and the caption language: hangul → KR, kana → JP, Han by language (ja JP, zh SC)', () => {
    expect(TD.cjkKind('안녕하세요')).toBe('kr');
    expect(TD.cjkKind('今日は', 'zh')).toBe('jp'); // kana wins
    expect(TD.cjkKind('直接', 'ja')).toBe('jp');
    expect(TD.cjkKind('直接', 'zh')).toBe('sc');
    expect(TD.cjkKind('直接')).toBe('sc');
    expect(TD.cjkKind('Hello Привет')).toBeNull();
    // 直 has different regional forms: the block's outline is the language's face's, exactly.
    const outline = (lang: string) => TD.drawBlock([{ text: '直', color: '#FFFFFF' }], style, PX, 5000, LATIN, { missing: new Set(), id: lang, language: lang })!.over;
    const ja = outline('ja'), zh = outline('zh');
    expect(ja).not.toEqual(zh);
    const glyph = (k: TD.CjkKind) => TD.face(TD.cjkFile(k, false))!.charToGlyph('直').getPath(0, 0, PX).toPathData(2);
    expect(ja).toContain(glyph('jp')); expect(zh).toContain(glyph('sc'));
    expect(glyph('jp')).not.toEqual(glyph('sc'));
    const kr = TD.drawBlock([{ text: '한국어', color: '#FFFFFF' }], { ...style, weight: 700 }, PX, 5000, LATIN, { missing: new Set(), id: 'ko', language: 'ko' })!;
    expect(kr.width).toBeGreaterThan(PX * 2.5);
    TD.releaseCjk();
  });

  it('unspaced captions touch: two words in ja are as wide as their letters; in en a space apart', () => {
    const runs = [{ text: '今日は', color: '#FFFFFF' }, { text: '晴れ', color: '#FFFFFF' }];
    const tight = TD.drawBlock(runs, style, PX, 5000, LATIN, { missing: new Set(), id: 't', language: 'ja', tight: true })!;
    const one = TD.drawBlock([{ text: '今日は晴れ', color: '#FFFFFF' }], style, PX, 5000, LATIN, { missing: new Set(), id: 'o', language: 'ja' })!;
    const spaced = TD.drawBlock(runs, style, PX, 5000, LATIN, { missing: new Set(), id: 's', language: 'ja' })!;
    expect(Math.abs(tight.width - one.width)).toBeLessThan(1);
    expect(spaced.width).toBeGreaterThan(tight.width + PX * 0.15);
    TD.releaseCjk();
  });
});

describe.skipIf(!hasFfmpeg)('CJK captions in a 1080p export (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  beforeAll(() => {
    fetchCjkFonts(TD.CJK_DIR);
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-cjk-'));
    files.g = path.join(dir, 'g.mp4');
    ff('-f', 'lavfi', '-i', 'color=c=0x404040:s=1080x1920:r=30:d=4', ...ENC, files.g);
  }, 300_000);
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('draws a Japanese caption (nothing unsupported), releases the face, and stays well inside the 512 MB box', () => {
    // In a fresh Node (its own VmHWM, so the synchronous font parse counts), each ffmpeg's VmHWM through a wrapper.
    const log = path.join(dir, 'hwm.log'), wrap = path.join(dir, 'ffmpeg-hwm.sh'), out = path.join(dir, 'ja.mp4');
    fs.writeFileSync(wrap, `#!/bin/bash\nffmpeg "$@" &\npid=$!\npeak=0\nwhile kill -0 $pid 2>/dev/null; do v=$(awk '/VmHWM/{print $2}' /proc/$pid/status 2>/dev/null); [ -n "$v" ] && [ "$v" -gt "$peak" ] && peak=$v; sleep 0.05; done\nwait $pid; rc=$?\necho $peak >> ${log}\nexit $rc\n`);
    fs.chmodSync(wrap, 0o755);
    const res = JSON.parse(execFileSync('node', ['--import', 'tsx', 'test/cjk-render-child.ts', files.g!, out, wrap], { encoding: 'utf8', env: { ...process.env, MUSE_CJK_DIR: TD.CJK_DIR } }).trim().split('\n').pop()!);
    expect(res.unsupported).toEqual([]);
    expect(res.cjkLoaded).toBe(0); // released once the text was drawn
    const ffPeak = Math.max(...fs.readFileSync(log, 'utf8').trim().split('\n').map(Number)) / 1024;
    console.log(`CJK caption 1080p export: Node peak ${res.peakMb} MB (${res.startMb} MB before the render), ffmpeg peak ${ffPeak.toFixed(0)} MB`);
    expect(res.peakMb - res.startMb).toBeLessThan(200);
    expect(res.peakMb).toBeLessThan(384); // the image's V8 cap (NODE_OPTIONS) is on the heap; the process stays under it too
    expect(ffPeak).toBeLessThan(300);
    // White caption letters in the caption band while the page shows, none before.
    return Promise.all([grabFrame('ffmpeg', out, 2.2, 360, 640), grabFrame('ffmpeg', out, 0.1, 360, 640)]).then(([f, f0]) => {
      const inked = (fr: typeof f) => { let n = 0; for (let y = 384; y < 544; y++) for (let x = 0; x < 360; x++) { const i = (y * 360 + x) * 3; if (fr.rgb[i]! > 200 && fr.rgb[i + 1]! > 170) n++; } return n; };
      expect(inked(f)).toBeGreaterThan(200);
      expect(inked(f0)).toBe(0);
    });
  }, 300_000);
});
