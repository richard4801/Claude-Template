// The server render's text and captions (render parity): the apps' caption presets with the shared word timing,
// text styling (box, shadow, letter spacing, scale, rotation), text animation (in/out, keyframes, loops, typewriter),
// other alphabets through the fallback face. Real ffmpeg renders over a grey picture, checked by coloured pixels.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { CAPTION_STYLES } from '../src/editor/presets.js';
import { renderProject } from '../src/editor/render.js';
import * as TD from '../src/editor/textdraw.js';
import { grabFrame } from '../src/recreate/frames.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

describe('text blocks (unit)', () => {
  it('words wrap into lines no wider than the box; the line advance follows lineHeight; letters no font has are collected', () => {
    const style: M.TextStyle = { font: 'sans', weight: 400, sizePct: 0.05, color: '#FFFFFF', align: 'center' };
    const font = path.resolve('assets/fonts/figtree_400.ttf');
    const missing = new Set<string>();
    const one = TD.drawBlock([{ text: 'one two three four', color: '#FFFFFF' }], style, 50, 1000, font, { missing, id: 'a' })!;
    const two = TD.drawBlock([{ text: 'one two three four', color: '#FFFFFF' }], style, 50, 200, font, { missing, id: 'b' })!;
    expect(two.width).toBeLessThanOrEqual(200); expect(one.width).toBeGreaterThan(200);
    expect(two.height).toBeGreaterThan(one.height * 1.5);
    const tall = TD.drawBlock([{ text: 'one two three four', color: '#FFFFFF' }], { ...style, lineHeight: 2.3 }, 50, 200, font, { missing, id: 'c' })!;
    expect(tall.height / two.height).toBeCloseTo(2, 1);
    expect(missing.size).toBe(0);
    if (fs.existsSync(TD.FALLBACK_FONTS.regular)) {
      TD.drawBlock([{ text: 'Привет 😀 𓀀', color: '#FFFFFF' }], style, 50, 1000, font, { missing, id: 'd' });
      expect([...missing].sort()).toEqual([TD.EMOJI, '𓀀']); // Cyrillic from the fallback face; the emoji in one colour; the hieroglyph from none
    }
  });
});

describe.skipIf(!hasFfmpeg)('render text and captions (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  const W = 360, H = 640;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-text-'));
    files.g = path.join(dir, 'g.mp4');
    ff('-f', 'lavfi', '-i', 'color=c=0x404040:s=180x320:r=30:d=4', ...ENC, files.g);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  const project = (): M.EditProject => ({
    version: 2, sourceTakeId: 'tg', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
    assets: [{ id: 'g', kind: 'video', take: 'tg', durationSec: 4 }],
    tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c1', asset: 'g', inSec: 0, outSec: 4, speed: 1 } as M.VideoClip] }],
  });
  const render = async (p: M.EditProject, name: string) => {
    M.validate(p);
    const out = path.join(dir, `${name}.mp4`);
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { maxSide: 640, audio: 'none' });
    return { out, r };
  };
  /** Pixels matching `test` inside a box (fractions of the frame), with their bounding box. */
  const count = async (file: string, t: number, test: (r: number, g: number, b: number) => boolean, box = [0, 0, 1, 1]) => {
    const f = await grabFrame('ffmpeg', file, t, W, H);
    let n = 0, x0 = W, x1 = -1, y0 = H, y1 = -1;
    for (let y = Math.round(box[1]! * H); y < Math.round(box[3]! * H); y++) for (let x = Math.round(box[0]! * W); x < Math.round(box[2]! * W); x++) {
      const i = (y * W + x) * 3;
      if (test(f.rgb[i]!, f.rgb[i + 1]!, f.rgb[i + 2]!)) { n++; x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
    }
    return { n, w: x1 - x0 + 1, h: y1 - y0 + 1, cx: (x0 + x1) / 2 / W, cy: (y0 + y1) / 2 / H };
  };
  const white = (r: number, g: number, b: number) => r > 220 && g > 220 && b > 220;
  const yellow = (r: number, g: number, b: number) => r > 200 && g > 170 && b < 90;

  const captions = (preset: M.CaptionPreset, extra: Partial<M.CaptionStyle> = {}): M.Track => ({ id: 'cap', kind: 'caption', items: [], caption: {
    asset: 'g', words: [{ text: 'alpha', startSec: 0.5, endSec: 1 }, { text: 'beta', startSec: 1, endSec: 1.5 }, { text: 'gamma', startSec: 1.5, endSec: 2 }],
    style: { ...CAPTION_STYLES[preset], color: '#FFFFFF', highlightColor: '#FFD400', shadow: undefined, ...extra } } });

  it('captions: the page shows over its words, the active word lit (highlight), every word so far (karaoke), a box behind it (box)', async () => {
    const p = project();
    p.tracks.push(captions('highlight', { wordsPerPage: 3, y: 0.72 }));
    const { out, r } = await render(p, 'cap-highlight');
    expect(r.unsupported).toEqual([]);
    expect((await count(out, 0.3, white, [0, 0.6, 1, 0.85])).n).toBe(0); // before the first word
    const a = await count(out, 0.7, yellow, [0, 0.6, 1, 0.85]), c = await count(out, 1.7, yellow, [0, 0.6, 1, 0.85]);
    expect(a.n).toBeGreaterThan(30); expect(c.n).toBeGreaterThan(30);
    expect(a.cx).toBeLessThan(0.45); expect(c.cx).toBeGreaterThan(0.55); // the lit word moves along the line
    expect(Math.abs(a.cy - 0.72)).toBeLessThan(0.04);
    expect((await count(out, 1.7, white, [0, 0.6, 1, 0.85])).n).toBeGreaterThan(30); // the other words stay white
    expect((await count(out, 3, white, [0, 0.6, 1, 0.85])).n).toBe(0); // gone after the page's tail

    const k = project();
    k.tracks.push(captions('karaoke', { wordsPerPage: 3 }));
    const kr = await render(k, 'cap-karaoke');
    expect((await count(kr.out, 1.7, yellow, [0, 0.6, 1, 0.85])).w).toBeGreaterThan(a.w * 2.5); // all three lit

    const b = project();
    b.tracks.push(captions('box', { wordsPerPage: 3 }));
    const br = await render(b, 'cap-box');
    expect((await count(br.out, 1.2, yellow, [0, 0.6, 1, 0.85])).n).toBeGreaterThan(a.n * 3); // a filled box, not letters

    const hid = project();
    hid.tracks.push({ ...captions('box'), hidden: true });
    expect((await count((await render(hid, 'cap-hidden')).out, 1.2, yellow)).n).toBe(0);
  }, 120_000);

  const text = (extra: Partial<M.TextItem> = {}, style: Partial<M.TextStyle> = {}): M.Track => ({ id: 'tx', kind: 'text', items: [{
    id: 't1', startSec: 0, durationSec: 4, text: 'HELLO', style: { font: 'sans', weight: 900, sizePct: 0.06, color: '#FFFFFF', align: 'center', ...style }, transform: { x: 0.5, y: 0.5 }, ...extra } as M.TextItem] });

  it('text styling: a background box, a shadow, letter spacing, scale and rotation', async () => {
    const plain = await render({ ...project(), tracks: [...project().tracks, text()] }, 'tx-plain');
    expect(plain.r.unsupported).toEqual([]);
    const base = await count(plain.out, 1, white);
    expect(base.n).toBeGreaterThan(100);
    expect(Math.abs(base.cx - 0.5)).toBeLessThan(0.03); expect(Math.abs(base.cy - 0.5)).toBeLessThan(0.03);

    const red = (r: number, g: number, b: number) => r > 180 && g < 60 && b < 60;
    const boxed = await render({ ...project(), tracks: [...project().tracks, text({}, { background: { color: '#FF0000', opacity: 1, paddingPct: 0.3, radiusPct: 0.2 } })] }, 'tx-box');
    const bx = await count(boxed.out, 1, red);
    expect(bx.n).toBeGreaterThan(base.n); expect(bx.w).toBeGreaterThan(base.w);

    const shadowed = await render({ ...project(), tracks: [...project().tracks, text({}, { shadow: { color: '#000000', opacity: 1, blurPct: 0, dyPct: 0.3 } })] }, 'tx-shadow');
    const dark = await count(shadowed.out, 1, (r, g, b) => r < 15 && g < 15 && b < 15, [0, 0.4, 1, 0.6]);
    expect(dark.n).toBeGreaterThan(50); expect(dark.cy).toBeGreaterThan(base.cy); // dropped below the letters
    const soft = await render({ ...project(), tracks: [...project().tracks, text({}, { shadow: { color: '#000000', opacity: 1, blurPct: 0.3, dyPct: 0.3 } })] }, 'tx-soft');
    const darkish = await count(soft.out, 1, (r, g, b) => r < 50 && g < 50 && b < 50, [0, 0.4, 1, 0.6]);
    expect(darkish.n).toBeGreaterThan(50); expect(darkish.h).toBeGreaterThan(dark.h); // blurred: spread wider
    expect((await count(soft.out, 1, white)).n).toBeGreaterThan(base.n * 0.8); // the letters stay on top

    const spaced = await render({ ...project(), tracks: [...project().tracks, text({}, { letterSpacing: 0.4 })] }, 'tx-spaced');
    expect((await count(spaced.out, 1, white)).w).toBeGreaterThan(base.w * 1.4);

    const big = await render({ ...project(), tracks: [...project().tracks, text({ transform: { x: 0.5, y: 0.5, scale: 2 } })] }, 'tx-scale');
    expect((await count(big.out, 1, white)).w / base.w).toBeCloseTo(2, 0);

    const turned = await render({ ...project(), tracks: [...project().tracks, text({ transform: { x: 0.5, y: 0.5, rotation: 90 } })] }, 'tx-rot');
    const tb = await count(turned.out, 1, white);
    expect(tb.h).toBeGreaterThan(tb.w * 2); // standing up
  }, 120_000);

  it('text animation: fade in, a slide, keyframed position, a blink loop, typewriter', async () => {
    const fade = await render({ ...project(), tracks: [...project().tracks, text({ animIn: { kind: 'fade', durationSec: 1 } })] }, 'tx-fade');
    expect(fade.r.unsupported).toEqual([]);
    expect((await count(fade.out, 0.1, white)).n).toBe(0); // still faint
    expect((await count(fade.out, 2, white)).n).toBeGreaterThan(100);

    const moved = await render({ ...project(), tracks: [...project().tracks, text({ keyframes: { x: [{ t: 0, v: 0.25 }, { t: 2, v: 0.75 }] } })] }, 'tx-keys');
    const m0 = await count(moved.out, 0.05, white), m2 = await count(moved.out, 3, white);
    expect(m0.cx).toBeLessThan(0.3); expect(m2.cx).toBeGreaterThan(0.7);

    const slid = await render({ ...project(), tracks: [...project().tracks, text({ animIn: { kind: 'slideUp', durationSec: 1 } })] }, 'tx-slide');
    expect((await count(slid.out, 0.7, (r, g, b) => r > 150 && g > 150 && b > 150)).cy).toBeGreaterThan(0.5); // still below its place

    const blink = await render({ ...project(), tracks: [...project().tracks, text({ animLoop: { kind: 'blink', periodSec: 2, amount: 1 } })] }, 'tx-blink');
    expect((await count(blink.out, 0.05, white)).n).toBeGreaterThan(100);
    expect((await count(blink.out, 1, (r, g, b) => r > 150 && g > 150 && b > 150)).n).toBe(0); // fully faded at half a period

    const typed = await render({ ...project(), tracks: [...project().tracks, text({ animIn: { kind: 'typewriter', durationSec: 2 } })] }, 'tx-type');
    const early = await count(typed.out, 0.5, white), done = await count(typed.out, 3, white);
    expect(early.w).toBeLessThan(done.w * 0.6);
  }, 120_000);

  it.skipIf(!fs.existsSync(TD.FALLBACK_FONTS.regular))('other alphabets draw through the fallback face; letters no font has are listed', async () => {
    const ru = await render({ ...project(), tracks: [...project().tracks, text({ text: 'ПРИВЕТ' })] }, 'tx-ru');
    expect(ru.r.unsupported).toEqual([]);
    expect((await count(ru.out, 1, white)).n).toBeGreaterThan(100);
    const emoji = await render({ ...project(), tracks: [...project().tracks, text({ text: 'HI 😀 𓀀' })] }, 'tx-emoji');
    expect(emoji.r.unsupported.sort()).toEqual(['colour emoji (drawn in the text colour)', 'letters no font on the server has (𓀀)']);
  }, 60_000);
});
