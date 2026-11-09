// A server render of an edit project (workstream 1; render parity, WS16): Recreate's Compare and export, Claude's
// renders. ffmpeg, CPU, one render at a time; it draws what the phone and Mac editors draw, in their order:
// - main clips (layer.ts): trims, speed and speed curves, freeze frames, crop, chroma key, colour (adjust, filter,
//   tone, curves, HSL, LUT, lift as one 3D LUT; colour keyframes in runs), background removal, masks, fit, mirror,
//   transform and its keyframes, in/out animations, opacity, over the background colour or the blur fill; joined by
//   cuts and transitions (xfade; the glitch as the apps draw it);
// - overlays (video and image tracks), in track order: the same steps, plus loops and blend modes (blendPixel);
// - adjustment layers over the pictures, under the text;
// - text and captions above everything (textdraw.ts): the fonts' own outlines, styling, animation, caption presets;
// - sound, in a pass of its own: every clip cut and timed like its picture, its voice (audio.ts voiceChain) and its
//   gain over time (model.ts audioEnvelope: volume and keys, fades, crossfades, ducking); project mute; or a guide track.
// What it can't draw is listed in `unsupported` (test/render-coverage.test.ts checks every field of the model is drawn
// or listed), so the apps can say the render is a preview.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { LOOK_IDS } from './lookpack.js';
import { FILTERS } from './presets.js';
import * as M from './model.js';
import { hash01, parseCube, type Look, type Lut } from './look.js';
import { voiceChain } from './audio.js';
import * as L from './layer.js';
import * as TD from './textdraw.js';
import { LOOK_DIR, PALETTE_DIR, paletteFiles } from './photo.js';

const here = path.dirname(fileURLToPath(import.meta.url));
export const FONT_DIR = path.resolve(here, '../../assets/fonts');
/** The apps' family per editor font (Mac EditV2TextRenderer; rounded has no bundled face, Outfit stands in). */
const FONTS: Record<M.TextStyle['font'], Record<'regular' | 'bold' | 'black', string>> = {
  sans: { regular: 'figtree_400', bold: 'figtree_700', black: 'figtree_800' },
  serif: { regular: 'instrument_serif_400', bold: 'instrument_serif_400', black: 'instrument_serif_400' },
  rounded: { regular: 'outfit_400', bold: 'outfit_700', black: 'outfit_700' },
  condensed: { regular: 'barlow_condensed_500', bold: 'barlow_condensed_700', black: 'barlow_condensed_700' },
  mono: { regular: 'dm_mono_400', bold: 'dm_mono_500', black: 'dm_mono_500' },
  marker: { regular: 'permanent_marker_400', bold: 'permanent_marker_400', black: 'permanent_marker_400' },
};
export const fontFile = (f: M.TextStyle['font'], weight: number) =>
  path.join(FONT_DIR, `${(FONTS[f] ?? FONTS.sans)[weight >= 900 ? 'black' : weight >= 700 ? 'bold' : 'regular']}.ttf`);

/** The editor transition → ffmpeg xfade (ffmpeg 5.1 names). */
const XFADE: Record<M.TransitionKind, string> = {
  fade: 'fade', black: 'fadeblack', white: 'fadewhite', slideLeft: 'slideleft', slideRight: 'slideright', slideUp: 'slideup', slideDown: 'slidedown',
  zoom: 'zoomin', whip: 'smoothleft', spin: 'radial', glitch: 'pixelize',
};

/**
 * The editor's glitch as the apps draw it (model.ts transitionState): a hard switch at the middle of the transition,
 * the picture jittering sideways (up to 4 % of the width) with red and blue pulled apart (up to 2 %), both strongest
 * at the switch. The switch is a one-frame fade at the middle, with both clips trimmed so the length and the cut times
 * are exactly a full xfade's, and both streams read together as in any xfade. `start` and `d` are frames on the
 * timeline.
 */
export function glitchSwitch(a: string, b: string, out: string, start: number, d: number, i: number, FPS: number): string[] {
  const half = Math.floor(d / 2);
  return [
    `[${a}]trim=end_frame=${start + half + 1}[gx${i}]`,
    `[${b}]trim=start_frame=${half},setpts=PTS-STARTPTS[gy${i}]`,
    `[gx${i}][gy${i}]xfade=transition=fade:duration=${n4(1 / FPS)}:offset=${n4((start + half) / FPS)}[${out}]`,
  ];
}
/**
 * The glitches' jitter and colour split, frame by frame, as rgbashift commands (one filter on the joined picture; a
 * per-pixel xfade expression took ~45 s for 0.4 s at 1080 × 1920). Red, green and blue move by the jitter, red and
 * blue a little further apart; back to rest after each window.
 */
export function glitchShifts(windows: { start: number; d: number }[], W: number, FPS: number, name: string): string {
  const cmds: string[] = [];
  const set = (f: number, r: number, g: number, bl: number) =>
    cmds.push(`${n4(f / FPS)} ${name} rh ${r}, ${name} gh ${g}, ${name} bh ${bl}`);
  for (const w of windows) {
    for (let k = 0; k < w.d; k++) {
      const p = (k + 0.5) / w.d, peak = Math.sin(Math.PI * p);
      const jit = (hash01(Math.floor(p * 24), p < 0.5 ? 1 : 2, 7) - 0.5) * 2;
      const dx = Math.round(0.04 * W * peak * jit), split = Math.round(0.02 * W * peak);
      const c = (v: number) => Math.max(-255, Math.min(255, v));
      set(w.start + k, c(dx + split), c(dx), c(dx - split));
    }
    set(w.start + w.d, 0, 0, 0);
  }
  return cmds.join(';');
}


/** A look's LUT file: a pack look, a palette, or an imported .cube (asset id → file from `files`). */
function lutFile(ref: string, files: Record<string, string>): string | null {
  if (ref.startsWith('pack:')) { const id = ref.slice(5); return LOOK_IDS.has(id) ? path.join(LOOK_DIR, `${id}.cube`) : null; }
  if (ref.startsWith('palette:')) { const f = paletteFiles().get(ref.slice(8)); return f ? path.join(PALETTE_DIR, f) : null; }
  return files[ref] ?? null;
}

const n4 = (x: number) => String(Math.round(x * 10000) / 10000);
const n6 = (x: number) => String(Math.round(x * 1e6) / 1e6);
export { easeExpr, kfExpr } from './layer.js';
/**
 * A gain envelope (model.ts audioEnvelope: piecewise-linear points on the timeline) as a flat ffmpeg expression in t: a
 * sum of the non-silent spans (no deep nesting, so long ducked beds stay cheap to parse); silent before and after.
 */
export function envExpr(env: M.GainPoint[]): string {
  const parts: string[] = [];
  for (let i = 0; i + 1 < env.length; i++) {
    const a = env[i]!, b = env[i + 1]!, dt = b.t - a.t;
    if (dt <= 0 || (a.gain === 0 && b.gain === 0)) continue;
    const lin = a.gain === b.gain ? n6(a.gain) : `(${n6(a.gain)}+(${n6(b.gain - a.gain)})*(t-${n6(a.t)})/${n6(dt)})`;
    parts.push(`between(t,${n6(a.t)},${n6(b.t)})*lt(t,${n6(b.t)})*${lin}`);
  }
  const last = env.at(-1);
  if (last && last.gain) parts.push(`eq(t,${n6(last.t)})*${n6(last.gain)}`);
  return parts.join('+') || '0';
}
/**
 * A speed curve's sound (its constant-speed pieces) as one stream: four atempo stages (together 0.0625–10 000×, each
 * 0.5–100) whose tempo asendcmd sets at each piece's start (source time from `at`). One atempo per piece instead hangs:
 * a piece shorter than atempo's window never ends.
 */
export function curveTempo(pieces: M.Piece[], at: number, tag: string): string {
  const stages = (sp: number) => { const v: number[] = []; let rem = sp; for (let i = 0; i < 3; i++) { const x = Math.min(100, Math.max(0.5, rem)); v.push(x); rem /= x; } v.push(Math.min(100, Math.max(0.5, rem))); return v; };
  const cmds = pieces.map(pc => `${n4(Math.max(0, pc.inSec - at))} ${stages(pc.speed).map((v, i) => `atempo@${tag}${i} tempo ${n6(v)}`).join(', ')}`).join(';');
  return `asendcmd=c='${cmds}',${stages(pieces[0]!.speed).map((v, i) => `atempo@${tag}${i}=tempo=${n6(v)}`).join(',')}`;
}
/** atempo stages for a speed (each stage 0.5–2). */
export function atempo(speed: number): string[] {
  const out: string[] = [];
  let s = speed;
  while (s > 2) { out.push('atempo=2'); s /= 2; }
  while (s < 0.5) { out.push('atempo=0.5'); s /= 0.5; }
  if (Math.abs(s - 1) > 1e-4) out.push(`atempo=${n4(s)}`);
  return out;
}
const color = (hex: string | undefined, alpha = 1) => `0x${(hex ?? '#000000').replace('#', '').slice(0, 6).padEnd(6, '0')}${alpha < 1 ? `@${n4(Math.max(0, alpha))}` : ''}`;
const even = (x: number) => Math.max(2, Math.round(x / 2) * 2);

/** Rough line wrap for a text box (the apps measure; ~0.55 em per character is close for these faces). */
export function wrap(text: string, fontPx: number, maxPx: number): string[] {
  const per = Math.max(4, Math.floor(maxPx / (fontPx * 0.55)));
  const out: string[] = [];
  for (const para of text.split('\n')) {
    let line = '';
    for (const w of para.split(/\s+/).filter(Boolean)) {
      if (!line) line = w; else if ((line + ' ' + w).length <= per) line += ' ' + w; else { out.push(line); line = w; }
    }
    out.push(line);
  }
  return out;
}

export type RenderOptions = {
  /** The longest side of the output (default: the canvas); preview renders use 720. */
  maxSide?: number;
  fps?: number;
  /** 'project': the clips' and tracks' sound; 'none': silent; or a guide track (a file) instead of the project's sound. */
  audio?: 'project' | 'none' | { file: string; volume?: number };
  /** Make the output exactly this long (padding with the last frame / cutting), e.g. a reference's length. */
  durationSec?: number;
  quality?: 'preview' | 'export';
};
/** stills: text frames (SVG) and sprites: their shadows, drawn to PNG (renderProject) before ffmpeg runs; temp: files and folders to remove after. */
export type RenderPlan = { args: string[]; soundArgs: string[] | null; durationSec: number; width: number; height: number; unsupported: string[]; temp: string[]; stills: { file: string; svg: string; crop: TD.Crop }[]; sprites: TD.Sprite[] };

/**
 * The ffmpeg arguments for a project. `files` maps asset ids to local files or URLs; `sizes` gives each video asset's
 * pixel size (the cover/contain fit needs it); `hasAudio` says which have sound.
 */
export function planRender(p: M.EditProject, files: Record<string, string>, sizes: Record<string, { width: number; height: number; hasAudio: boolean }>, out: string, o: RenderOptions = {}): RenderPlan {
  const unsupported = new Set<string>();
  const temp: string[] = [];
  const baked = new Map<string, string>(); // look key → baked .cube (one per distinct look)
  const f = Math.min(1, (o.maxSide ?? Math.max(p.canvas.width, p.canvas.height)) / Math.max(p.canvas.width, p.canvas.height));
  const W = even(p.canvas.width * f), H = even(p.canvas.height * f), FPS = Math.min(o.fps ?? p.canvas.fps ?? 30, 60);
  const inputs: string[] = [], index = new Map<string, number>(), inputArgs = new Map<number, string[]>();
  const input = (file: string) => { let i = index.get(file); if (i === undefined) { i = inputs.length; inputs.push(file); index.set(file, i); } return i; };
  const g: string[] = [];
  const main = M.mainTrack(p), clips = main.items as M.VideoClip[], tl = M.timeline(p);
  if (!clips.length) throw new Error('nothing on the main track');
  const total = o.durationSec ?? (tl.at(-1)?.endSec ?? 0);
  const fr = (t: number) => Math.round(t * FPS);
  /** A clip's frames: from its first frame on the timeline to its last. */
  const frames = (i: number) => Math.max(1, fr(tl[i]!.endSec) - fr(tl[i]!.startSec));

  /**
   * An input for a clip's source from `at` for `dur` seconds (opened there: a stream never buffers frames a later clip
   * will need). Main clips going forward through the same file, without transitions, share one.
   */
  const openAt = (file: string, at: number, dur: number, threads = 2): number => {
    const k = inputs.length;
    inputs.push(file);
    inputArgs.set(k, ['-threads', String(threads), '-ss', n4(Math.max(0, at)), '-t', n4(dur + 0.5)]);
    return k;
  };
  /** Source frames of a video clip (its speed pieces from input `k` opened at `at`, or one held frame) or a picture, `n` frames. */
  const sourceFrames = (k: number, at: number, c: { inSec: number; outSec: number; speed?: number; speedCurve?: M.SpeedCurve; holdSec?: number } | null, n: number, tag: string): string => {
    if (!c || c.holdSec !== undefined) {
      g.push(`[${k}:v]${c ? `trim=start=${n4(Math.max(0, c.inSec - at))},setpts=PTS-STARTPTS,` : ''}trim=end_frame=1,loop=loop=-1:size=1,setpts=N/${FPS}/TB,trim=end_frame=${n}[${tag}]`);
      return tag;
    }
    const pieces = M.speedPieces(c);
    pieces.forEach((pc, j) => g.push(`[${k}:v]trim=start=${n4(Math.max(0, pc.inSec - at))}:end=${n4(pc.outSec - at)},setpts=(PTS-STARTPTS)/${n4(pc.speed)},fps=${FPS}[${tag}p${j}]`));
    g.push(`${pieces.map((_, j) => `[${tag}p${j}]`).join('')}concat=n=${pieces.length}:v=1:a=0,trim=end_frame=${n},setpts=N/${FPS}/TB[${tag}]`);
    return tag;
  };
  let lookN = 0;
  /** A .cube for an item's colour (layer.ts colourCube), or null. */
  const colourFile = (adjust: M.Adjust | undefined, filter: M.FilterRef | undefined, look: Look | undefined): string | null => {
    let lut: Lut | null = null;
    if (look?.lut) {
      const f = lutFile(look.lut, files);
      if (!f) unsupported.add('a look that is not on the server');
      else try { lut = parseCube(fs.readFileSync(f, 'utf8')); } catch { unsupported.add('a look that is not on the server'); }
    }
    const cube = L.colourCube(M.colorMatrix(adjust, filter, FILTERS), adjust, look, lut);
    if (!cube) return null;
    let file = baked.get(cube);
    if (!file) { file = path.join(os.tmpdir(), `muse-look-${process.pid}-${Date.now()}-c${lookN++}.cube`); fs.writeFileSync(file, cube); temp.push(file); baked.set(cube, file); }
    return file;
  };
  const lut3d = (file: string) => `lut3d=file='${file.replace(/\\/g, '/').replace(/:/g, '\\:').replace(/'/g, '')}'`;
  const LOOK_DETAILS = ['sharpen', 'chromatic', 'halation', 'leak', 'vignette', 'grain'] as const;
  type Visual = M.VideoClip | M.ImageItem;
  /**
   * A clip or picture drawn as the apps draw it (layer.ts), from the source frames `src` (w × h px, item-local time,
   * `n` frames, `len` s long): crop → chroma key → colour → matte and mask → placed → opacity. Static and unrotated:
   * a picture to put at (x, y); else RGBA the size of the canvas (`canvas` forces that, e.g. for blend modes).
   */
  type Layer = { s: string; x: number; y: number; opaque: boolean; w: number; h: number } | { s: string; x: null; y: null; opaque: false; w: number; h: number };
  const visualLayer = (it: Visual, src: string, w: number, h: number, o: { video: boolean; n: number; len: number; fit: M.Fit; tag: string; canvas: boolean; matte?: () => string | null }): Layer => {
    const { n, len, tag } = o, vc = o.video ? it as M.VideoClip : null;
    let s = src;
    const cr = it.crop ?? {}, l = cr.left ?? 0, t = cr.top ?? 0, r = cr.right ?? 0, b = cr.bottom ?? 0;
    const cw = w * (1 - l - r), ch = h * (1 - t - b);
    const kf = (it.fit ?? o.fit) === 'cover' ? Math.max(W / cw, H / ch) : Math.min(W / cw, H / ch);
    const fw0 = cw * kf, fh0 = ch * kf;
    const mo = L.motion(it, len, `(in/${FPS})`);
    const still = [mo.x, mo.y, mo.scale, mo.rotation].map(L.constant);
    const sprite = !o.canvas && still.every(v => v !== null) && Math.abs(((still[3]! % 360) + 360) % 360) < 1e-9;
    // Drawn at the size it reaches on the canvas: its own size when still, else its largest scale.
    const big = sprite ? still[2]! : Math.min(L.maxScale(it), (2 * Math.max(W, H)) / Math.max(fw0, fh0));
    const iw = even(fw0 * big), ih = even(fh0 * big);
    const cropF = l || t || r || b ? `crop=w=iw*${n6(1 - l - r)}:h=ih*${n6(1 - t - b)}:x=iw*${n6(l)}:y=ih*${n6(t)},` : '';
    // Kept in yuv (half the memory of RGB: every clip's buffers stay for the whole render) until a step needs RGB.
    g.push(`[${s}]${cropF}scale=${iw}:${ih},setsar=1,format=yuv420p[${tag}c]`);
    s = `${tag}c`;
    let rgb = false;
    const toRgb = () => { if (!rgb) { g.push(`[${s}]format=gbrp[${tag}rgb]`); s = `${tag}rgb`; rgb = true; } };
    const alphas: string[] = [];
    // Chroma key (model.ts chromaKey): alpha and spill from the pixel's (Cb, Cr), the colour pulled towards its luma.
    if (vc?.chroma) {
      toRgb();
      const e = L.chromaExprs(vc.chroma);
      g.push(`[${s}]split=3[${tag}k0][${tag}k1][${tag}k2]`,
        `[${tag}k0]scale=out_color_matrix=bt601:out_range=full,format=yuv444p,extractplanes=u+v[${tag}u][${tag}v]`,
        `[${tag}u]split[${tag}u1][${tag}u2]`, `[${tag}v]split[${tag}v1][${tag}v2]`,
        `[${tag}u1][${tag}v1]lut2=c0='${e.alpha}'[${tag}ka]`, `[${tag}u2][${tag}v2]lut2=c0='${e.spill}',format=gbrp[${tag}ks]`,
        `[${tag}k1]colorchannelmixer=rr=0.2126:rg=0.7152:rb=0.0722:gr=0.2126:gg=0.7152:gb=0.0722:br=0.2126:bg=0.7152:bb=0.0722[${tag}kl]`,
        `[${tag}kl][${tag}k2][${tag}ks]maskedmerge[${tag}kd]`);
      s = `${tag}kd`; alphas.push(`${tag}ka`);
    }
    // Colour: the matrix (adjust, filter), tone, curves, HSL, LUT and lift as one 3D LUT; colour keyframes in runs.
    const look = it.look;
    if (look && LOOK_DETAILS.some(x => look[x] !== undefined)) unsupported.add('look details (grain, vignette, …)');
    if (M.LOOK_KF_PROPS.some(x => it.keyframes?.[x]?.length)) unsupported.add('look details (grain, vignette, …)');
    if (!M.COLOR_KF_PROPS.some(x => it.keyframes?.[x]?.length)) { const cf = colourFile(it.adjust, it.filter, look); if (cf) { toRgb(); g.push(`[${s}]${lut3d(cf)}[${tag}g]`); s = `${tag}g`; } }
    else {
      const step = Math.max(0.1, len / 60), parts: string[] = [];
      for (let a = 0; a < len - 1e-9; a += step) {
        const cf = colourFile(M.adjustAt(it, a + step / 2), it.filter, look);
        if (cf) parts.push(`${lut3d(cf)}:enable='gte(t,${n4(a)})*lt(t,${n4(a + step)})'`);
      }
      if (parts.length) { toRgb(); g.push(`[${s}]${parts.join(',')}[${tag}g]`); s = `${tag}g`; }
    }
    // Background removal: the matte's luma (cut and timed like the clip) is the alpha.
    if (vc?.alphaMatte) {
      const ms = o.matte?.();
      if (!ms) unsupported.add('background removal');
      else { g.push(`[${ms}]${cropF}scale=${iw}:${ih},format=gray${vc.alphaMatte.invert ? ',negate' : ''}[${tag}ma]`); alphas.push(`${tag}ma`); }
    }
    // Mask (model.ts maskAlpha, keyed by maskAt), in the picture's own frame: grey frames written here, one, or one a frame while it moves.
    if (it.mask) {
      const keyed = M.MASK_KF_PROPS.some(x => it.keyframes?.[x]?.length);
      const q = keyed ? Math.min(1, Math.sqrt(8e6 / (n * iw * ih))) : 1, mw = Math.max(2, Math.round(iw * q)), mh = Math.max(2, Math.round(ih * q));
      const raw = path.join(os.tmpdir(), `muse-mask-${process.pid}-${Date.now()}-${tag}.gray`);
      const fd = fs.openSync(raw, 'w');
      try { for (let f = 0; f < (keyed ? n : 1); f++) fs.writeSync(fd, L.maskPixels(M.maskAt(it, f / FPS)!, mw, mh)); } finally { fs.closeSync(fd); }
      temp.push(raw);
      const mk = inputs.length;
      inputs.push(raw);
      inputArgs.set(mk, ['-f', 'rawvideo', '-pix_fmt', 'gray', '-s', `${mw}x${mh}`, '-framerate', String(FPS)]);
      g.push(`[${mk}:v]${keyed ? '' : 'loop=loop=-1:size=1,'}setpts=N/${FPS}/TB,trim=end_frame=${n},scale=${iw}:${ih}[${tag}mk]`);
      alphas.push(`${tag}mk`);
    }
    const ac = L.constant(mo.alpha);
    // Opaque: no alpha at all (a full-frame main clip is then just cut to the canvas).
    const opaque = !alphas.length && ac !== null && ac >= 1 && sprite;
    if (alphas.length) {
      let a = alphas[0]!;
      for (let j = 1; j < alphas.length; j++) { g.push(`[${a}][${alphas[j]}]lut2=c0='x*y/255'[${tag}a${j}]`); a = `${tag}a${j}`; }
      g.push(`[${s}][${a}]alphamerge[${tag}al]`);
      s = `${tag}al`;
    } else if (!opaque) { g.push(`[${s}]format=${rgb ? 'gbrap' : 'yuva420p'}[${tag}al]`); s = `${tag}al`; }
    const flipX = !!it.transform?.flipX, flipY = !!it.transform?.flipY;
    let x: number | null = null, y: number | null = null, ow = W, oh = H;
    if (sprite) {
      // Still: mirrored, then put at its place.
      if (flipX || flipY) { g.push(`[${s}]${[flipX ? 'hflip' : '', flipY ? 'vflip' : ''].filter(Boolean).join(',')}[${tag}fl]`); s = `${tag}fl`; }
      x = Math.round(still[0]! * W - iw / 2); y = Math.round(still[1]! * H - ih / 2); ow = iw; oh = ih;
    } else {
      // Moving: placed by its corners over time (fit, mirror, scale, rotation, position; keys, animation, loop).
      // Drawn in the area it sweeps over the canvas (a frame the canvas's size costs ~4 × the memory for a picture-in-picture).
      const sw = L.sweep(it, len, n, FPS, W, H, fw0, fh0);
      const bx = Math.max(0, Math.floor((sw[0] - 2) / 2) * 2), by = Math.max(0, Math.floor((sw[1] - 2) / 2) * 2);
      const bw = Math.max(2, even(Math.min(W, Math.ceil(sw[2] + 2)) - bx)), bh = Math.max(2, even(Math.min(H, Math.ceil(sw[3] + 2)) - by));
      const fw = Math.max(iw + 2, bw), fh = Math.max(ih + 2, bh);
      const cs = L.cornerExprs(mo, W, H, fw0, fh0, iw, ih, fw, fh, flipX, flipY, bx, by);
      const moving = still.some(v => v === null);
      // (perspective in gbrap: its yuva420p alpha plane comes out wrong.)
      g.push(`[${s}]format=gbrap,pad=${fw}:${fh}:1:1:color=black@0,perspective=sense=destination:eval=${moving ? 'frame' : 'init'}:${cs.map((e, j) => `${['x', 'y'][j % 2]}${Math.floor(j / 2)}='${e}'`).join(':')},crop=${bw}:${bh}:0:0${o.canvas ? `,pad=${W}:${H}:${bx}:${by}:color=black@0` : ',format=yuva420p'}[${tag}pl]`);
      s = `${tag}pl`;
      if (!o.canvas) { x = bx; y = by; ow = bw; oh = bh; }
    }
    // Opacity over time (keys, animation, loop): a 2 × 2 grey drawn by expression, stretched and multiplied into the alpha.
    if (ac === null) {
      g.push(`color=c=white:s=2x2:r=${FPS}:d=${n4(n / FPS + 1)},format=gray,geq=lum='255*clip(${L.motion(it, len, 'T').alpha},0,1)',scale=${ow}:${oh}:flags=neighbor,trim=end_frame=${n}[${tag}op]`,
        `[${s}]split[${tag}o1][${tag}o2]`, `[${tag}o1]alphaextract[${tag}oa]`, `[${tag}oa][${tag}op]lut2=c0='x*y/255'[${tag}om]`, `[${tag}o2][${tag}om]alphamerge[${tag}o]`);
      s = `${tag}o`;
    } else if (ac < 1) { g.push(`[${s}]lut=c3='val*${n4(Math.max(0, ac))}'[${tag}o]`); s = `${tag}o`; }
    return x === null || o.canvas ? { s, x: null, y: null, opaque: false, w: W, h: H } : { s, x, y: y!, opaque, w: ow, h: oh };
  };

  // Main clips: each its own picture of the canvas (the background colour, or the blur fill, under the clip).
  /**
   * The input the previous clip read: the next one reads it too when it goes on forward through the same file without
   * a transition. Any other sharing makes ffmpeg buffer the frames decoded for a clip until its turn (gigabytes).
   */
  let shared: { file: string; k: number; at: number; end: number } | null = null;
  clips.forEach((c, i) => {
    const asset = p.assets.find(a => a.id === c.asset);
    const file = asset && files[asset.id], size = asset && sizes[asset.id];
    const n = frames(i), len = M.clipLength(c);
    const bg = `color=c=${color(p.canvas.background)}:s=${W}x${H}:r=${FPS}:d=${n4(n / FPS + 1)},trim=end_frame=${n},format=yuv420p`;
    if (!asset || !file || !size || !size.width) { g.push(`${bg},format=yuv420p,setsar=1,settb=AVTB[v${i}]`); unsupported.add('missing media'); return; }
    if (main.hidden) { g.push(`${bg},format=yuv420p,setsar=1,settb=AVTB[v${i}]`); return; } // hidden: only the background
    const from = c.holdSec !== undefined ? c.inSec : Math.min(...M.speedPieces(c).map(x => x.inSec)), to = c.holdSec !== undefined ? c.inSec + 0.2 : c.outSec;
    if (!shared || shared.file !== file || from < shared.end - 1e-6 || c.transitionIn || c.holdSec !== undefined || clips[i - 1]?.holdSec !== undefined) shared = { file, k: openAt(file, from, Math.max(0.2, to - from), clips.length > 8 ? 1 : 2), at: from, end: to };
    else { inputArgs.get(shared.k)!.splice(-1, 1, n4(to - shared.at + 0.5)); shared.end = to; }
    const src = sourceFrames(shared.k, shared.at, c, n, `m${i}s`);
    const blur = p.canvas.fill === 'blur' && (c.fit ?? 'cover') === 'contain';
    let under = `m${i}bg`, layerSrc = src;
    if (blur) {
      // Blur fill (model.ts blurFill): the clip cover-fitted with its colour (not its transform), box-blurred, darkened.
      const rad = Math.max(1, Math.round(M.blurFillRadius(p.canvas) * f));
      const cf = colourFile(c.adjust, c.filter, c.look);
      g.push(`[${src}]split[m${i}f][m${i}l]`,
        `[m${i}f]scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},setsar=1,format=gbrp${cf ? `,${lut3d(cf)}` : ''},boxblur=luma_radius=${rad}:luma_power=1:chroma_radius=${rad}:chroma_power=1,colorchannelmixer=rr=${M.BLUR_FILL_DARKEN}:gg=${M.BLUR_FILL_DARKEN}:bb=${M.BLUR_FILL_DARKEN}[${under}]`);
      layerSrc = `m${i}l`;
    }
    const matte = () => {
      const mf = c.alphaMatte && files[c.alphaMatte.asset];
      return mf ? sourceFrames(openAt(mf, from, Math.max(0.2, to - from)), from, c, n, `m${i}mt`) : null;
    };
    const lay = visualLayer(c, layerSrc, size.width, size.height, { video: true, n, len, fit: 'cover', tag: `m${i}`, canvas: false, matte });
    if (!blur && lay.opaque && lay.x !== null && lay.x <= 0 && lay.y <= 0 && lay.x + lay.w >= W && lay.y + lay.h >= H) {
      // Opaque and covering the canvas: cut to it (no background, no overlay).
      g.push(`[${lay.s}]crop=${W}:${H}:${-lay.x}:${-lay.y}[m${i}o]`);
    } else {
      if (blur) g.push(`[${under}]format=yuv420p[${under}y]`), under = `${under}y`;
      else g.push(`${bg}[${under}]`);
      g.push(`[${under}][${lay.s}]overlay=${lay.x ?? 0}:${lay.y ?? 0}:format=yuv420:eof_action=pass[m${i}o]`);
    }
    // Exactly the clip's frames on the timeline (rounded once from the timeline, so cuts never drift).
    g.push(`[m${i}o]trim=end_frame=${n},setpts=N/${FPS}/TB,format=yuv420p,setsar=1,fps=${FPS},settb=AVTB[v${i}]`);
  });

  /** Composites every overlay track (in order) over the picture `base`; returns the result (yuv420p). */
  const overlays = (base: string): string => {
    let cur = base, oi = 0, any = false;
    for (const tr of p.tracks) {
      if ((tr.kind !== 'video' && tr.kind !== 'image') || tr.hidden) continue;
      for (const it of tr.items as Visual[]) {
        const video = tr.kind === 'video', vc = video ? it as M.VideoClip : null, start = (it as { startSec: number }).startSec;
        const len = vc ? M.clipLength(vc) : (it as M.ImageItem).durationSec;
        const end = Math.min(start + len, total), n = fr(end) - fr(start);
        if (n < 1) continue;
        const asset = p.assets.find(a => a.id === it.asset), file = asset && files[asset.id], size = asset && sizes[asset.id];
        if (!asset || !file || !size || !size.width) { unsupported.add('missing media'); continue; }
        const tag = `ov${oi++}`;
        any = true;
        const from = vc ? (vc.holdSec !== undefined ? vc.inSec : Math.min(...M.speedPieces(vc).map(x => x.inSec))) : 0, to = vc ? (vc.holdSec !== undefined ? vc.inSec + 0.2 : vc.outSec) : 0;
        const vk = vc ? openAt(file, from, Math.max(0.2, to - from), 1) : -1;
        const src = vc ? sourceFrames(vk, from, vc, n, `${tag}s`) : sourceFrames(input(file), 0, null, n, `${tag}s`);
        const mode = it.blend ?? 'normal';
        const matte = () => { const mf = vc?.alphaMatte && files[vc.alphaMatte.asset]; return mf ? sourceFrames(openAt(mf, from, Math.max(0.2, to - from)), from, vc, n, `${tag}mt`) : null; };
        const lay = visualLayer(it, src, size.width, size.height, { video, n, len, fit: 'contain', tag, canvas: mode !== 'normal', matte });
        const t0 = n4(fr(start) / FPS), on = `enable='between(t,${t0},${n4((fr(start) + n - 0.5) / FPS)})'`;
        // Normal: over the picture as it is (yuv; the mix is linear, as in RGB).
        if (mode === 'normal') g.push(`[${lay.s}]setpts=PTS+${t0}/TB[${tag}t]`, `[${cur}][${tag}t]overlay=${lay.x ?? 0}:${lay.y ?? 0}:format=yuv420:eof_action=pass:${on}[${tag}x]`);
        else {
          // blendPixel: the mode's colour (lut2, exact W3C formulas) mixed in by the item's coverage (maskedmerge).
          const e = L.blendExpr(mode);
          g.push(`[${lay.s}]tpad=start_duration=${t0}:stop_duration=${n4(total)}:color=black@0,trim=end_frame=${fr(total)},split[${tag}t1][${tag}t2]`,
            `[${cur}]format=gbrp,split[${tag}b1][${tag}b2]`, `[${tag}t1]format=gbrp[${tag}tc]`, `[${tag}tc][${tag}b1]lut2=c0='${e}':c1='${e}':c2='${e}'[${tag}bl]`,
            `[${tag}t2]alphaextract,format=gbrp[${tag}ta]`, `[${tag}b2][${tag}bl][${tag}ta]maskedmerge,format=yuv420p[${tag}x]`);
        }
        cur = `${tag}x`;
      }
    }
    return any ? cur : base;
  };

  let acc = 'v0';
  const glitches: { start: number; d: number }[] = [];
  for (let i = 1; i < clips.length; i++) {
    const t = clips[i]!.transitionIn, next = `j${i}`;
    const d = t && tl[i]!.transitionSec > 0 ? fr(tl[i - 1]!.endSec) - fr(tl[i]!.startSec) : 0;
    if (t?.kind === 'glitch' && d >= 2) { g.push(...glitchSwitch(acc, `v${i}`, next, fr(tl[i]!.startSec), d, i, FPS)); glitches.push({ start: fr(tl[i]!.startSec), d }); }
    else if (t && d > 0) g.push(`[${acc}][v${i}]xfade=transition=${XFADE[t.kind] ?? 'fade'}:duration=${n4(d / FPS)}:offset=${n4(fr(tl[i]!.startSec) / FPS)}[${next}]`);
    else g.push(`[${acc}][v${i}]concat=n=2:v=1:a=0[${next}]`);
    acc = next;
  }

  // The glitches' jitter and colour split, on the joined picture.
  if (glitches.length) {
    g.push(`[${acc}]format=gbrp,sendcmd=c='${glitchShifts(glitches, W, FPS, 'rgbashift@glitch')}',rgbashift@glitch=rh=0:gh=0:bh=0:edge=smear,format=yuv420p[gfx]`);
    acc = 'gfx';
  }
  // Overlays (video and image tracks), in track order, over the joined main picture (layer.ts).
  acc = overlays(acc);
  // Adjustment layers: over the pictures, under the text. Each run of one colour is one affine channel mix, on only
  // while the run lasts: on RGBA with an opaque alpha, the offsets go in as the alpha's coefficients, so the sum is
  // clamped once, at the end (model.ts: "not clamped between layers, only at the end").
  const runs = adjustRuns(p);
  if (runs.length) {
    const st: string[] = ['format=rgba'];
    for (const { a, b, m } of runs) {
      const on = `enable='gte(t,${n4(a)})*lt(t,${n4(b)})'`;
      st.push(`colorchannelmixer=rr=${n6(m[0]!)}:rg=${n6(m[1]!)}:rb=${n6(m[2]!)}:ra=${n6(m[3]!)}:gr=${n6(m[4]!)}:gg=${n6(m[5]!)}:gb=${n6(m[6]!)}:ga=${n6(m[7]!)}:br=${n6(m[8]!)}:bg=${n6(m[9]!)}:bb=${n6(m[10]!)}:ba=${n6(m[11]!)}:${on}`);
    }
    g.push(`[${acc}]${st.join(',')},format=yuv420p[adj]`);
    acc = 'adj';
  }
  g.push(`[${acc}]tpad=stop_mode=clone:stop_duration=${n4(Math.max(0, total))},trim=duration=${n4(total)},setpts=PTS-STARTPTS,format=yuv420p[vpad]`);
  // Text and captions, above every picture (textdraw.ts): the whole canvas's text as one RGBA picture per change of
  // what shows, as a still sequence (ffconcat) overlaid once. Static stretches are one still; moving ones one a frame.
  const pieces: ((t: number) => TD.Piece | null)[] = [];
  const pages = M.captionPages(p);
  for (const tr of p.tracks) {
    if (tr.hidden) continue;
    if (tr.kind === 'caption' && tr.caption) {
      const ct = tr.caption, font = fontFile(ct.style.font, ct.style.weight);
      if (pages.length) pieces.push(t => TD.captionPiece(ct, pages, t, font));
    }
    if (tr.kind !== 'text') continue;
    for (const it of tr.items as M.TextItem[]) {
      // An own font draws from its downloaded file; without one (not fetched) the fallback family stands in.
      const own = it.style.fontAsset ? files[it.style.fontAsset] : undefined;
      if (it.style.fontAsset && (!own || /^https?:/.test(own) || !TD.face(own))) unsupported.add('own fonts');
      const font = own && !/^https?:/.test(own) && TD.face(own) ? own : fontFile(it.style.font, it.style.weight);
      pieces.push(t => TD.textPiece(it, t, font));
    }
  }
  let vlast = 'vpad';
  const stills: RenderPlan['stills'] = [], sprites: TD.Sprite[] = [];
  if (pieces.length) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-text-'));
    temp.push(dir);
    const missing = new Set<string>();
    const byKey = new Map<string, number>(), frames: TD.Frame[] = [], spriteMap = new Map<string, TD.Sprite>();
    const seq: { still: number; frames: number }[] = []; // still −1: nothing shows
    const nFrames = Math.max(1, Math.round(total * FPS));
    for (let fi = 0; fi < nFrames; fi++) {
      const shown = pieces.map(f => f(fi / FPS)).filter((x): x is TD.Piece => !!x);
      const key = shown.length ? JSON.stringify(shown) : '';
      let k = key ? byKey.get(key) : -1;
      if (k === undefined) {
        const fr = TD.frameBody(shown, W, H, missing, spriteMap);
        k = fr ? frames.push(fr) - 1 : -1;
        byKey.set(key, k);
      }
      const last = seq.at(-1);
      if (last && last.still === k) last.frames++; else seq.push({ still: k, frames: 1 });
    }
    if (missing.delete(TD.EMOJI)) unsupported.add('colour emoji (drawn in the text colour)');
    if (missing.size) unsupported.add(`letters no font on the server has (${[...missing].slice(0, 8).join(' ')})`);
    if (frames.length) {
      // Every still is cropped to the box all the text ever paints (smaller stills are much cheaper to draw and read).
      const x0 = Math.max(0, Math.floor(Math.min(...frames.map(f => f.box[0])) / 2) * 2), y0 = Math.max(0, Math.floor(Math.min(...frames.map(f => f.box[1])) / 2) * 2);
      const x1 = Math.min(W, Math.ceil(Math.max(...frames.map(f => f.box[2])))), y1 = Math.min(H, Math.ceil(Math.max(...frames.map(f => f.box[3]))));
      if (x1 > x0 && y1 > y0) {
        const crop: TD.Crop = [x0, y0, even(x1 - x0), even(y1 - y0)];
        const file = (k: number) => path.join(dir, k < 0 ? 'empty.png' : `s${k}.png`);
        stills.push({ file: file(-1), svg: '', crop }, ...frames.map((f, k) => ({ file: file(k), svg: f.svg, crop })));
        sprites.push(...spriteMap.values());
        const list = path.join(dir, 'text.ffconcat');
        fs.writeFileSync(list, ['ffconcat version 1.0', ...seq.flatMap(x => [`file '${file(x.still)}'`, `duration ${n6(x.frames / FPS)}`]), `file '${file(seq.at(-1)!.still)}'`].join('\n') + '\n');
        const k = input(list);
        inputArgs.set(k, ['-threads', '1', '-f', 'concat', '-safe', '0']);
        g.push(`[${k}:v]format=rgba[txt]`, `[vpad][txt]overlay=${x0}:${y0}:format=auto:eof_action=repeat[vtxt]`);
        vlast = 'vtxt';
      }
    }
  }
  g.push(`[${vlast}]format=yuv420p[vout]`);

  // Sound: a pass of its own before the picture's (renderProject), so reading a clip's sound never pulls its picture
  // in early (a stream that has to wait for its picture's time buffers every frame meanwhile).
  const amix: string[] = [], ag: string[] = [], ainputs: string[] = [];
  const ainput = (file: string) => { let k = ainputs.indexOf(file); if (k < 0) { k = ainputs.length; ainputs.push(file); } return k; };
  const A = 'aformat=sample_rates=48000:channel_layouts=stereo';
  if (o.audio && typeof o.audio === 'object') {
    const k = ainput(o.audio.file);
    ag.push(`[${k}:a]atrim=end=${n4(total)},asetpts=PTS-STARTPTS,${A},volume=${n4(o.audio.volume ?? 1)}[ag]`);
    amix.push('ag');
  } else if (o.audio !== 'none' && !p.mute) {
    // Each clip's sound: its source cut and timed like its picture, its voice (enhance, effect), placed on the timeline,
    // then its gain over time (model.ts audioEnvelope: volume and its keys, fades, transition crossfades, ducking).
    const voice = (c: M.VideoClip | M.AudioClip) => voiceChain(c, 48000).map(q => `,biquad=b0=${q.b0}:b1=${q.b1}:b2=${q.b2}:a0=1:a1=${q.a1}:a2=${q.a2}`).join('');
    const envelope = (c: M.VideoClip | M.AudioClip, trackId: string) => {
      const env = M.audioEnvelope(p, trackId, c.id);
      return env.some(x => x.gain > 0) ? env : null; // silent throughout: left out
    };
    const place = (src: string, c: M.VideoClip | M.AudioClip, env: M.GainPoint[], startSec: number, name: string) => {
      const ms = Math.round(startSec * 1000);
      const gain = env.every(x => x.gain === env[0]!.gain) ? n4(env[0]!.gain) : `'${envExpr(env)}':eval=frame`;
      ag.push(`[${src}]${voice(c).replace(/^,/, '') || 'anull'},adelay=${ms}|${ms},volume=${gain}[${name}]`);
      amix.push(name);
    };
    // Video clips (main and overlay tracks): cut and timed like their picture.
    const clipSound = (c: M.VideoClip, trackId: string, startSec: number, tag: string) => {
      const asset = p.assets.find(a => a.id === (c.audioAsset ?? c.asset)), file = asset && files[asset.id];
      const env = asset && file && sizes[asset.id]?.hasAudio ? envelope(c, trackId) : null;
      if (!env || !file) return;
      const k = ainput(file), pieces = M.speedPieces(c);
      if (pieces.length === 1) ag.push(`[${k}:a]atrim=start=${n4(c.inSec)}:end=${n4(c.outSec)},asetpts=PTS-STARTPTS,${A}${atempo(pieces[0]!.speed).map(x => `,${x}`).join('')}[${tag}s]`);
      else ag.push(`[${k}:a]atrim=start=${n4(c.inSec)}:end=${n4(c.outSec)},asetpts=PTS-STARTPTS,${A},${curveTempo(pieces, c.inSec, tag)}[${tag}s]`);
      const s = `${tag}s`;
      place(s, c, env, startSec, tag);
    };
    clips.forEach((c, i) => clipSound(c, main.id, tl[i]!.startSec, `ac${i}`));
    let vi = 0;
    for (const tr of p.tracks) if (tr.kind === 'video') for (const c of tr.items as M.VideoClip[]) clipSound(c, tr.id, c.startSec ?? 0, `av${vi++}`);
    let ai = 0;
    for (const tr of p.tracks.filter(t => (t.kind === 'music' || t.kind === 'voice' || t.kind === 'sfx') && !t.muted)) {
      for (const it of tr.items as M.AudioClip[]) {
        const asset = p.assets.find(a => a.id === it.asset), file = asset && files[asset.id];
        if (!asset || !file || it.muted) { if (asset?.library && !it.muted) unsupported.add('library music'); continue; }
        const env = sizes[asset.id]?.hasAudio ? envelope(it, tr.id) : null;
        if (!env) continue;
        const k = ainput(file);
        ag.push(`[${k}:a]atrim=start=${n4(it.inSec)}:end=${n4(it.outSec)},asetpts=PTS-STARTPTS,${A}${atempo(it.speed ?? 1).map(x => `,${x}`).join('')}[ar${ai}]`);
        place(`ar${ai}`, it, env, it.startSec, `at${ai}`);
        ai++;
      }
    }
  }
  if (amix.length) ag.push(`${amix.map(x => `[${x}]`).join('')}amix=inputs=${amix.length}:normalize=0:duration=longest,apad,atrim=end=${n4(total)}[aout]`);

  const q = o.quality === 'export' ? ['-preset', 'veryfast', '-crf', '18'] : ['-preset', 'ultrafast', '-crf', '28'];
  let soundArgs: string[] | null = null;
  if (amix.length) {
    const wav = path.join(os.tmpdir(), `muse-sound-${process.pid}-${Date.now()}.flac`);
    temp.push(wav);
    soundArgs = ['-y', '-v', 'error', ...ainputs.flatMap(x => ['-vn', '-i', x]), '-filter_complex', ag.join(';'), '-map', '[aout]', '-c:a', 'flac', '-t', n4(total), wav];
    inputs.push(wav);
  }
  const args = ['-y', '-v', 'error', ...inputs.flatMap((x, i) => [...(inputArgs.get(i) ?? []), '-i', x]), '-filter_complex', g.join(';'), '-map', '[vout]', ...(soundArgs ? ['-map', `${inputs.length - 1}:a`, '-c:a', 'aac', '-b:a', '128k'] : []),
    '-c:v', 'libx264', ...q, '-pix_fmt', 'yuv420p', '-r', String(FPS), '-movflags', '+faststart', '-threads', '2', '-t', n4(total), out];
  return { args, soundArgs, durationSec: total, width: W, height: H, unsupported: [...unsupported], temp, stills, sprites };
}

/**
 * Adjustment layers ([M.adjustLayerMatrix]) as runs of one matrix: split at every layer's start and end, and every
 * [stepSec] inside a layer with keyframes; equal neighbours merged; identity left out. A long keyed layer samples
 * more coarsely so the graph stays under [maxRuns].
 */
export function adjustRuns(p: M.EditProject, stepSec = 0.1, maxRuns = 600): { a: number; b: number; m: number[] }[] {
  const items = p.tracks.filter(t => t.kind === 'adjust' && !t.hidden).flatMap(t => t.items as M.AdjustItem[]);
  if (!items.length) return [];
  const keyed = items.filter(it => it.keyframes && Object.values(it.keyframes).some(k => k?.length));
  const keyedSec = keyed.reduce((s, it) => s + it.durationSec, 0);
  const step = Math.max(stepSec, keyedSec / maxRuns);
  const cuts = new Set<number>();
  const r4 = (x: number) => Math.round(x * 1e4) / 1e4;
  for (const it of items) { cuts.add(r4(it.startSec)); cuts.add(r4(it.startSec + it.durationSec)); }
  for (const it of keyed) for (let t = it.startSec + step; t < it.startSec + it.durationSec - 1e-6; t += step) cuts.add(r4(t));
  const ts = [...cuts].sort((x, y) => x - y);
  const out: { a: number; b: number; m: number[] }[] = [];
  for (let i = 0; i + 1 < ts.length; i++) {
    const a = ts[i]!, b = ts[i + 1]!;
    const m = M.adjustLayerMatrix(p, a, FILTERS);
    const last = out.at(-1);
    if (!m) continue;
    if (last && Math.abs(last.b - a) < 1e-9 && last.m.every((v, k) => v === m[k])) last.b = b;
    else out.push({ a, b, m });
  }
  return out;
}

/** A file's picture size and whether it has sound; audio-only files too (media.ts probe wants a picture). Null if unreadable. */
async function probeStreams(ffprobe: string, file: string): Promise<{ width: number; height: number; hasAudio: boolean } | null> {
  const out = await new Promise<string | null>(resolve => execFile(ffprobe, ['-v', 'error', '-print_format', 'json', '-show_streams', file], { timeout: 60_000, maxBuffer: 4 * 1024 * 1024 },
    (err, o) => resolve(err ? null : o)));
  if (!out) return null;
  try {
    const st = (JSON.parse(out) as { streams?: { codec_type?: string; width?: number; height?: number }[] }).streams ?? [];
    const v = st.find(x => x.codec_type === 'video');
    if (!v && !st.some(x => x.codec_type === 'audio')) return null;
    return { width: v?.width ?? 0, height: v?.height ?? 0, hasAudio: st.some(x => x.codec_type === 'audio') };
  } catch { return null; }
}

/** Probes each asset file (size, sound), plans and runs the render. */
export async function renderProject(cfg: { ffmpeg: string; ffprobe: string }, p: M.EditProject, files: Record<string, string>, out: string, o: RenderOptions = {}) {
  const sizes: Record<string, { width: number; height: number; hasAudio: boolean }> = {};
  for (const [id, file] of Object.entries(files)) {
    const a = p.assets.find(x => x.id === id);
    if (!a || a.kind === 'lut' || a.kind === 'font') continue;
    const info = await probeStreams(cfg.ffprobe, file);
    if (info) sizes[id] = { width: info.width || a.width || 1080, height: info.height || a.height || 1920, hasAudio: info.hasAudio };
  }
  const plan = planRender(p, files, sizes, out, o);
  try {
    const sprites = await TD.drawSprites(plan.sprites);
    for (const st of plan.stills) await TD.rasterize(st.svg, st.crop, st.file, sprites);
    const run = (args: string[]) => new Promise<void>((resolve, reject) => execFile(cfg.ffmpeg, args, { timeout: 15 * 60_000, maxBuffer: 8 * 1024 * 1024 },
      (err, _o, e) => (err ? reject(new Error(`render failed: ${String(e ?? err.message).trim().split('\n').slice(-2).join(' ').slice(0, 300)}`)) : resolve())));
    if (plan.soundArgs) await run(plan.soundArgs);
    await run(plan.args);
  } finally { for (const t of plan.temp) fs.rmSync(t, { force: true, recursive: true }); }
  return { durationSec: plan.durationSec, width: plan.width, height: plan.height, unsupported: plan.unsupported };
}
