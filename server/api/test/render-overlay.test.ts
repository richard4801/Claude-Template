// The server render's overlays (render parity): video and image tracks placed, keyed, animated, blended, keyed out,
// matted and masked as the apps draw them (model.ts itemCorners, blendPixel, chromaKey, maskAlpha; android
// RenderPlan.itemPlacement). Real ffmpeg renders over a grey picture, checked by pixels.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as L from '../src/editor/layer.js';
import * as M from '../src/editor/model.js';
import { renderProject } from '../src/editor/render.js';
import { grabFrame } from '../src/recreate/frames.js';
import { rms } from './render-helpers.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

/** An ffmpeg expression evaluated in JS (the functions these builders use). */
function evalExpr(e: string, vars: Record<string, number>): number {
  const fns = { _if: (c: number, a: number, b: number) => (c ? a : b), lt: (a: number, b: number) => +(a < b), lte: (a: number, b: number) => +(a <= b), gte: (a: number, b: number) => +(a >= b),
    clip: (v: number, a: number, b: number) => Math.min(b, Math.max(a, v)), pow: Math.pow, sin: Math.sin, cos: Math.cos, mod: (a: number, b: number) => a % b, hypot: Math.hypot,
    sqrt: Math.sqrt, abs: Math.abs, min: Math.min, max: Math.max, PI: Math.PI };
  const js = e.replace(/\bif\(/g, '_if(');
  return Function(...Object.keys(fns), ...Object.keys(vars), `return ${js};`)(...Object.values(fns), ...Object.values(vars)) as number;
}

describe('overlay expressions match model.ts (unit)', () => {
  it('keyframes (eased), in/out animations and loops: the same values as keyframeValue, animState and loopState', () => {
    const item = { transform: { x: 0.3, y: 0.6, scale: 0.8, rotation: 10 }, opacity: 0.9,
      keyframes: { x: [{ t: 0, v: 0.2, ease: 'easeInOut' as const }, { t: 1, v: 0.7, ease: 'easeIn' as const }, { t: 2, v: 0.4 }], scale: [{ t: 0.5, v: 1 }, { t: 1.5, v: 2, ease: 'hold' as const }, { t: 1.8, v: 1.2 }] },
      animIn: { kind: 'pop' as const, durationSec: 0.6 }, animOut: { kind: 'slideDown' as const, durationSec: 0.5 } };
    const len = 3;
    for (const loop of [undefined, { kind: 'pulse' as const, periodSec: 0.7, amount: 0.8 }, { kind: 'sway' as const, periodSec: 1 }, { kind: 'float' as const, periodSec: 1.3 }, { kind: 'spin' as const, periodSec: 2 }, { kind: 'blink' as const, periodSec: 0.5, amount: 0.3 }]) {
      const it = { ...item, animLoop: loop }, mo = L.motion(it, len, 't');
      for (let t = 0; t <= len; t += 0.037) {
        const a = M.animState({ durationSec: len, animIn: it.animIn, animOut: it.animOut }, t), lp = M.loopState(loop, t);
        expect(evalExpr(mo.x, { t })).toBeCloseTo(M.propAt(it, 'x', 0.3, t), 3);
        expect(evalExpr(mo.y, { t })).toBeCloseTo(0.6 + a.dy + lp.dy, 3);
        expect(evalExpr(mo.scale, { t })).toBeCloseTo(M.propAt(it, 'scale', 0.8, t) * a.scale * lp.scale, 3);
        expect(evalExpr(mo.rotation, { t })).toBeCloseTo(10 + lp.rotation, 3);
        expect(evalExpr(mo.alpha, { t })).toBeCloseTo(0.9 * a.opacity * lp.opacity, 3);
      }
    }
  });

  it('the corners land where model.ts itemCorners puts the picture; blends and the chroma key are the model\'s formulas', () => {
    const W = 1080, H = 1920, tr = { x: 0.3, y: 0.6, scale: 0.7, rotation: 25, flipX: true };
    const mo = L.motion({ transform: tr }, 1, 't'), iw = 400, ih = 300, fw = 1082, fh = 1922;
    const cs = L.cornerExprs(mo, W, H, 1080, 810, iw, ih, fw, fh, true, false).map(e => evalExpr(e, { t: 0 }));
    // The picture's own corners (1, 1) … (iw + 1, ih + 1) by the same affine map as the frame's corners. perspective's
    // corner coordinates are pixel positions (centres): an edge e is the position e − 0.5, read back on the canvas + 0.5.
    const at = (px: number, py: number) => {
      const [x0, y0, x1, y1, x2, y2] = cs as [number, number, number, number, number, number];
      const u = px - 0.5, v = py - 0.5;
      return [x0 + (x1 - x0) * u / fw + (x2 - x0) * v / fh + 0.5, y0 + (y1 - y0) * u / fw + (y2 - y0) * v / fh + 0.5];
    };
    const want = M.itemCorners({ width: W, height: H }, 4, 3, 'contain', tr);
    const got = [at(1, 1), at(iw + 1, 1), at(iw + 1, ih + 1), at(1, ih + 1)];
    got.forEach((g, i) => { expect(g[0]).toBeCloseTo(want[i]![0], 1); expect(g[1]).toBeCloseTo(want[i]![1], 1); });
    for (const mode of M.ALL_BLEND_MODES) for (const [x, y] of [[0, 0], [30, 200], [128, 64], [200, 250], [255, 128], [90, 30]]) {
      const v = evalExpr(L.blendExpr(mode), { x: x!, y: y! });
      expect(Math.abs(v - 255 * M.blendChannel(mode, x! / 255, y! / 255))).toBeLessThan(0.01);
    }
    const key: M.Chroma = { color: '#22CC44', similarity: 0.2, smoothness: 0.1, spill: 0.3 };
    for (const [r, g, b] of [[0.13, 0.8, 0.27], [0.5, 0.5, 0.5], [0.9, 0.2, 0.1], [0.2, 0.7, 0.4]]) {
      const u = 128 + 255 * (-0.168736 * r! - 0.331264 * g! + 0.5 * b!), v = 128 + 255 * (0.5 * r! - 0.418688 * g! - 0.081312 * b!);
      const e = L.chromaExprs(key), want = M.chromaKey(r!, g!, b!, key);
      expect(evalExpr(e.alpha, { x: u, y: v }) / 255).toBeCloseTo(want[3], 4);
    }
  });
});

describe.skipIf(!hasFfmpeg)('render overlays (ffmpeg)', () => {
  let dir: string;
  const files: Record<string, string> = {};
  const W = 360, H = 640;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-ov-'));
    const v = (id: string, src: string, extra: string[] = []) => { files[id] = path.join(dir, `${id}.mp4`); ff('-f', 'lavfi', '-i', src, ...extra, ...ENC, files[id]!); };
    v('g', 'color=c=0x404040:s=180x320:r=30:d=4');
    files.r = path.join(dir, 'r.mp4'); // red, with a tone
    ff('-f', 'lavfi', '-i', 'color=c=red:s=180x320:r=30:d=4', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4', '-shortest', ...ENC, '-c:a', 'aac', files.r);
    v('gs', 'color=c=0x00FF00:s=180x320:r=30:d=4', ['-vf', 'drawbox=x=90:y=0:w=90:h=320:c=blue:t=fill']); // green left, blue right
    v('mt', 'color=c=white:s=180x320:r=30:d=4', ['-vf', 'drawbox=x=90:y=0:w=90:h=320:c=black:t=fill']); // keep the left half
    files.im = path.join(dir, 'im.png'); // a 2:1 green picture
    ff('-f', 'lavfi', '-i', 'color=c=0x00FF00:s=200x100', '-frames:v', '1', files.im);
  });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  const project = (...tracks: M.Track[]): M.EditProject => ({
    version: 2, sourceTakeId: 'tg', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
    assets: [{ id: 'g', kind: 'video', take: 'tg', durationSec: 4 }, { id: 'r', kind: 'video', upload: 'u_r', durationSec: 4 }, { id: 'gs', kind: 'video', upload: 'u_gs', durationSec: 4 },
      { id: 'mt', kind: 'video', upload: 'u_mt', durationSec: 4 }, { id: 'im', kind: 'image', upload: 'u_im' }],
    tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c1', asset: 'g', inSec: 0, outSec: 4, speed: 1 } as M.VideoClip] }, ...tracks],
  });
  const vid = (extra: Partial<M.VideoClip> = {}): M.Track => ({ id: 'ov', kind: 'video', items: [{ id: 'o1', asset: 'r', inSec: 0, outSec: 2, speed: 1, startSec: 0.5, ...extra } as M.VideoClip] });
  const img = (extra: Partial<M.ImageItem> = {}): M.Track => ({ id: 'img', kind: 'image', items: [{ id: 'i1', asset: 'im', startSec: 0, durationSec: 3, ...extra } as M.ImageItem] });
  const render = async (p: M.EditProject, name: string, audio: 'none' | 'project' = 'none') => {
    M.validate(p);
    const out = path.join(dir, `${name}.mp4`);
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, p, files, out, { maxSide: 640, audio });
    return { out, r };
  };
  const px = async (file: string, t: number, x: number, y: number) => {
    const f = await grabFrame('ffmpeg', file, t, W, H);
    const i = (Math.round(y * (H - 1)) * W + Math.round(x * (W - 1))) * 3;
    return [f.rgb[i]!, f.rgb[i + 1]!, f.rgb[i + 2]!];
  };
  const area = async (file: string, t: number, test: (r: number, g: number, b: number) => boolean) => {
    const f = await grabFrame('ffmpeg', file, t, W, H);
    let n = 0, x0 = W, x1 = -1, y0 = H, y1 = -1;
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 3;
      if (test(f.rgb[i]!, f.rgb[i + 1]!, f.rgb[i + 2]!)) { n++; x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
    }
    return { n, w: (x1 - x0 + 1) / W, h: (y1 - y0 + 1) / H, cx: (x0 + x1 + 1) / 2 / W, cy: (y0 + y1 + 1) / 2 / H };
  };
  const red = (r: number, g: number, b: number) => r > 200 && g < 60 && b < 60;
  const green = (r: number, g: number, b: number) => g > 200 && r < 80 && b < 80;
  const grey = ([r, g, b]: number[]) => Math.abs(r! - 64) < 14 && Math.abs(g! - 64) < 14 && Math.abs(b! - 64) < 14;

  it('a picture-in-picture: placed and sized by its transform, only while it is on, with its own sound', async () => {
    const { out, r } = await render(project(vid({ transform: { x: 0.3, y: 0.25, scale: 0.4 } })), 'pip', 'project');
    expect(r.unsupported).toEqual([]);
    expect((await area(out, 0.3, red)).n).toBe(0); // not yet
    const a = await area(out, 1.2, red);
    expect(a.w).toBeCloseTo(0.4, 1); expect(a.h).toBeCloseTo(0.4, 1); // contain: the same 9:16 shape, 0.4 of the canvas
    expect(a.cx).toBeCloseTo(0.3, 1); expect(a.cy).toBeCloseTo(0.25, 1);
    expect(grey(await px(out, 1.2, 0.8, 0.8))).toBe(true);
    expect((await area(out, 2.7, red)).n).toBe(0); // gone after its 2 s
    expect(rms(out, 0.8, 2.2)).toBeGreaterThan(0.05); expect(rms(out, 2.7, 3.5)).toBeLessThan(0.01); // its tone, while it plays
  }, 60_000);

  it('a picture: contain-fitted, scaled, rotated and moving by its keyframes; opacity; a fade-in', async () => {
    const rot = await render(project(img({ transform: { x: 0.5, y: 0.5, scale: 0.5, rotation: 90 } })), 'img-rot');
    const a = await area(rot.out, 1, green);
    expect(a.w).toBeCloseTo(0.5 * 0.5 * 1080 / 1080, 1); expect(a.h).toBeCloseTo(0.5 * 1080 / 1920, 1); // 2:1 turned upright

    const moving = await render(project(img({ transform: { scale: 0.3 }, keyframes: { x: [{ t: 0, v: 0.2 }, { t: 2, v: 0.8 }] } })), 'img-keys');
    expect((await area(moving.out, 0.05, green)).cx).toBeLessThan(0.3);
    expect((await area(moving.out, 2.5, green)).cx).toBeGreaterThan(0.7);

    const half = await render(project(vid({ startSec: 0, opacity: 0.5 })), 'opacity');
    const [r, g] = await px(half.out, 1, 0.5, 0.5);
    expect(Math.abs(r! - (255 + 64) / 2)).toBeLessThan(15); expect(Math.abs(g! - 32)).toBeLessThan(15);

    const fade = await render(project(vid({ startSec: 0, animIn: { kind: 'fade', durationSec: 1.5 } })), 'fade-in');
    const early = await px(fade.out, 0.15, 0.5, 0.5), late = await px(fade.out, 1.8, 0.5, 0.5);
    expect(early[0]!).toBeLessThan(late[0]! - 100);
  }, 90_000);

  it('blend modes: multiply darkens, screen lightens, as blendPixel', async () => {
    const mul = await render(project(vid({ startSec: 0, blend: 'multiply' })), 'mul');
    expect(mul.r.unsupported).toEqual([]);
    const [mr, mg, mb] = await px(mul.out, 1, 0.5, 0.5); // red × grey = (64, 0, 0)
    expect(Math.abs(mr! - 64)).toBeLessThan(14); expect(mg!).toBeLessThan(14); expect(mb!).toBeLessThan(14);
    const scr = await render(project(vid({ startSec: 0, blend: 'screen', transform: { scale: 0.5 } })), 'screen');
    const [sr, sg, sb] = await px(scr.out, 1, 0.5, 0.5); // red screen grey = (255, 64, 64)
    expect(sr!).toBeGreaterThan(240); expect(Math.abs(sg! - 64)).toBeLessThan(14); expect(Math.abs(sb! - 64)).toBeLessThan(14);
    expect(grey(await px(scr.out, 1, 0.05, 0.05))).toBe(true); // outside the picture: untouched
    expect(grey(await px(scr.out, 3, 0.5, 0.5))).toBe(true); // after it
  }, 90_000);

  it('blend modes difference and exclusion (gated for the apps; the render draws them): red over grey', async () => {
    // Validation refuses them until BLEND_NEXT_LIVE, so this renders without it (renderProject itself takes any mode).
    const dif = path.join(dir, 'difference.mp4'), exc = path.join(dir, 'exclusion.mp4');
    const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, project(vid({ startSec: 0, blend: 'difference' })), files, dif, { maxSide: 640, audio: 'none' });
    expect(r.unsupported).toEqual([]);
    const [dr, dg, db] = await px(dif, 1, 0.5, 0.5); // |grey − red| = (191, 64, 64)
    expect(Math.abs(dr! - 191)).toBeLessThan(14); expect(Math.abs(dg! - 64)).toBeLessThan(14); expect(Math.abs(db! - 64)).toBeLessThan(14);
    await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, project(vid({ startSec: 0, blend: 'exclusion' })), files, exc, { maxSide: 640, audio: 'none' });
    const [er, eg, eb] = await px(exc, 1, 0.5, 0.5); // 0.25 + 1 − 2·0.25 = 0.75 → (191, 64, 64) on grey 64
    expect(Math.abs(er! - 191)).toBeLessThan(14); expect(Math.abs(eg! - 64)).toBeLessThan(14); expect(Math.abs(eb! - 64)).toBeLessThan(14);
    expect(grey(await px(dif, 3, 0.5, 0.5))).toBe(true);
  }, 90_000);

  it('chroma key, a background-removal matte and a mask make parts of the picture see-through', async () => {
    const key = await render(project({ id: 'ov', kind: 'video', items: [{ id: 'o1', asset: 'gs', inSec: 0, outSec: 3, speed: 1, startSec: 0, chroma: { color: '#00FF00' } } as M.VideoClip] }), 'chroma');
    expect(key.r.unsupported).toEqual([]);
    expect(grey(await px(key.out, 1, 0.25, 0.5))).toBe(true); // the green half is gone
    const [br, , bb] = await px(key.out, 1, 0.75, 0.5);
    expect(bb!).toBeGreaterThan(200); expect(br!).toBeLessThan(60);

    const matte = await render(project(vid({ startSec: 0, alphaMatte: { asset: 'mt' } })), 'matte');
    expect(red(...(await px(matte.out, 1, 0.25, 0.5)) as [number, number, number])).toBe(true);
    expect(grey(await px(matte.out, 1, 0.75, 0.5))).toBe(true);
    const inv = await render(project(vid({ startSec: 0, alphaMatte: { asset: 'mt', invert: true } })), 'matte-inv');
    expect(grey(await px(inv.out, 1, 0.25, 0.5))).toBe(true);

    const mask = await render(project(vid({ startSec: 0, mask: { shape: 'circle', width: 0.5, height: 0.3, feather: 0.02 } })), 'mask');
    expect(red(...(await px(mask.out, 1, 0.5, 0.5)) as [number, number, number])).toBe(true);
    expect(grey(await px(mask.out, 1, 0.5, 0.1))).toBe(true);
    const moved = await render(project(vid({ startSec: 0, mask: { shape: 'rect', width: 0.3, height: 0.3, feather: 0.02 }, keyframes: { maskX: [{ t: 0, v: 0.25 }, { t: 2, v: 0.75 }] } })), 'mask-keys');
    expect(red(...(await px(moved.out, 0.05, 0.25, 0.5)) as [number, number, number])).toBe(true);
    expect(red(...(await px(moved.out, 1.9, 0.75, 0.5)) as [number, number, number])).toBe(true);
    expect(grey(await px(moved.out, 1.9, 0.25, 0.5))).toBe(true);
  }, 120_000);

  it('a freeze frame holds one source frame for holdSec, silently; the next clip follows on time', async () => {
    files.rb = path.join(dir, 'rb.mp4'); // red for 1 s, then blue, with a tone
    if (!fs.existsSync(files.rb)) ff('-f', 'lavfi', '-i', 'color=c=red:s=180x320:r=30:d=1', '-f', 'lavfi', '-i', 'color=c=blue:s=180x320:r=30:d=1', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2',
      '-filter_complex', '[0][1]concat=n=2:v=1:a=0[v]', '-map', '[v]', '-map', '2:a', ...ENC, '-c:a', 'aac', files.rb);
    const p = project();
    p.assets.push({ id: 'rb', kind: 'video', upload: 'u_rb', durationSec: 2 });
    p.tracks[0]!.items = [{ id: 'c1', asset: 'rb', inSec: 1.5, outSec: 1.6, speed: 1, holdSec: 1.2 } as M.VideoClip,
      { id: 'c2', asset: 'rb', inSec: 0, outSec: 0.8, speed: 1 } as M.VideoClip];
    const { out, r } = await render(p, 'freeze', 'project');
    expect(r.unsupported).toEqual([]);
    for (const t of [0.05, 0.6, 1.1]) { const [rr, , bb] = await px(out, t, 0.5, 0.5); expect(bb!).toBeGreaterThan(180); expect(rr!).toBeLessThan(60); } // the blue frame, held
    const [r2, , b2] = await px(out, 1.5, 0.5, 0.5); expect(r2!).toBeGreaterThan(180); expect(b2!).toBeLessThan(60); // then the red clip, at 1.2 s
    expect(rms(out, 0.1, 1.1)).toBeLessThan(0.01); // a hold is silent
    expect(rms(out, 1.3, 1.9)).toBeGreaterThan(0.05);
    expect(Math.abs((await (await import('../src/replicate/media.js')).probe('ffprobe', out)).duration - 2)).toBeLessThan(0.1);
  }, 60_000);

  it('content library: a sticker (transparent PNG) and a sound effect from the bundled packs draw and play', async () => {
    const { contentFile, catalog } = await import('../src/editor/content.js');
    const sticker = catalog()!.packs.find(x => x.kind === 'stickers')!, sfx = catalog()!.packs.find(x => x.kind === 'sfx')!;
    const st = `content:${sticker.id}/${sticker.items[0]!.id}`, fx = `content:${sfx.id}/${sfx.items.find(i => (i.durationSec as number) >= 1)!.id}`;
    files.st = contentFile(st)!; files.fx = contentFile(fx)!;
    const p = project({ id: 'img', kind: 'image', items: [{ id: 'i1', asset: 'st', startSec: 0, durationSec: 2, transform: { scale: 0.5 } } as M.ImageItem] },
      { id: 'sfx', kind: 'sfx', items: [{ id: 's1', asset: 'fx', startSec: 0.2, inSec: 0, outSec: 0.8 } as M.AudioClip] });
    p.assets.push({ id: 'st', kind: 'image', library: st }, { id: 'fx', kind: 'audio', library: fx });
    const { out, r } = await render(p, 'content', 'project');
    expect(r.unsupported).toEqual([]);
    expect(grey(await px(out, 1, 0.02, 0.02))).toBe(true); // the sticker's transparent surround shows the clip
    expect(grey(await px(out, 1, 0.5, 0.5))).toBe(false); // the emoji is drawn in the middle
    expect(rms(out, 0.25, 0.75)).toBeGreaterThan(0.002);
    delete files.st; delete files.fx;
  }, 60_000);

  it('blur fill: the clip blurred and darkened where it leaves the frame; through a fade it switches half-way, not mixed', async () => {
    for (const [id, c] of [['wr', 'red'], ['wb', 'blue']] as const) {
      files[id] = path.join(dir, `${id}.mp4`);
      if (!fs.existsSync(files[id]!)) ff('-f', 'lavfi', '-i', `color=c=${c}:s=320x180:r=30:d=3`, ...ENC, files[id]!); // landscape: contain leaves the top and bottom
    }
    const p = project();
    p.assets.push({ id: 'wr', kind: 'video', upload: 'u_wr', durationSec: 3 }, { id: 'wb', kind: 'video', upload: 'u_wb', durationSec: 3 });
    p.canvas.fill = 'blur';
    p.tracks[0]!.items = [{ id: 'c1', asset: 'wr', inSec: 0, outSec: 2, speed: 1, fit: 'contain' } as M.VideoClip,
      { id: 'c2', asset: 'wb', inSec: 0, outSec: 2, speed: 1, fit: 'contain', transitionIn: { kind: 'fade', durationSec: 1 } } as M.VideoClip];
    const { out, r } = await render(p, 'blurfill');
    expect(r.unsupported).toEqual([]);
    const [r0, g0, b0] = await px(out, 0.5, 0.5, 0.1); // the fill: red, darkened (× 0.85)
    expect(Math.abs(r0! - 217)).toBeLessThan(20); expect(g0!).toBeLessThan(30); expect(b0!).toBeLessThan(30);
    const before = await px(out, 1.35, 0.5, 0.1), after = await px(out, 1.65, 0.5, 0.1); // the fade runs 1–2 s
    expect(before[0]!).toBeGreaterThan(180); expect(before[2]!).toBeLessThan(40); // still the red clip's fill
    expect(after[2]!).toBeGreaterThan(180); expect(after[0]!).toBeLessThan(40); // already the blue one's
    const mid = await px(out, 1.5, 0.5, 0.5); // the pictures themselves do mix
    expect(mid[0]!).toBeGreaterThan(60); expect(mid[2]!).toBeGreaterThan(60);
  }, 60_000);

  it('an overlay\'s colour (adjust); adjustment layers apply over the overlays, clamped only at the end', async () => {
    const mono = await render(project(vid({ startSec: 0, adjust: { saturation: -1 } })), 'ov-mono');
    const [r, g, b] = await px(mono.out, 1, 0.5, 0.5);
    expect(Math.abs(r! - g!)).toBeLessThan(10); expect(Math.abs(g! - b!)).toBeLessThan(10); expect(r!).toBeGreaterThan(30);

    // Contrast 1.5 then its −0.25 offset: red stays full red (1.5 − 0.25 > 1); clamping before the offset gave 191.
    const p = project(vid({ startSec: 0 }));
    p.tracks.push({ id: 'adj', kind: 'adjust', items: [{ id: 'a1', startSec: 0, durationSec: 3, adjust: { contrast: 0.5 } } as M.AdjustItem] });
    const lay = await render(p, 'adj-over');
    const [ar, ag] = await px(lay.out, 1, 0.5, 0.5);
    expect(ar!).toBeGreaterThan(240); expect(ag!).toBeLessThan(15);
  }, 60_000);
});
