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
import { contentFont } from './content.js';
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
const FONTS: Partial<Record<M.TextStyle['font'], Record<'regular' | 'bold' | 'black', string>>> = {
  sans: { regular: 'figtree_400', bold: 'figtree_700', black: 'figtree_800' },
  serif: { regular: 'instrument_serif_400', bold: 'instrument_serif_400', black: 'instrument_serif_400' },
  rounded: { regular: 'outfit_400', bold: 'outfit_700', black: 'outfit_700' },
  condensed: { regular: 'barlow_condensed_500', bold: 'barlow_condensed_700', black: 'barlow_condensed_700' },
  mono: { regular: 'dm_mono_400', bold: 'dm_mono_500', black: 'dm_mono_500' },
  marker: { regular: 'permanent_marker_400', bold: 'permanent_marker_400', black: 'permanent_marker_400' },
};
/** A family's file: a bundled one, else the content library's (src/editor/content.ts; the nine Cyrillic families). */
export const fontFile = (f: M.TextStyle['font'], weight: number) => (FONTS[f] ? null : contentFont(f, weight)) ??
  path.join(FONT_DIR, `${(FONTS[f] ?? FONTS.sans!)[weight >= 900 ? 'black' : weight >= 700 ? 'bold' : 'regular']}.ttf`);


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
export type RenderPlan = { chunks: string[][]; joinArgs: string[]; soundArgs: string[] | null; durationSec: number; width: number; height: number; unsupported: string[]; temp: string[]; stills: { file: string; svg: string; crop: TD.Crop }[]; sprites: TD.Sprite[] };

/**
 * The ffmpeg runs for a project: `soundArgs` (the sound, a pass of its own), one run per stretch of the timeline
 * (`chunks`, each with only the clips and pictures it shows, so memory stays bounded however long the edit), then
 * `joinArgs` (the stretches joined without re-encoding, with the sound). `files` maps asset ids to local files or
 * URLs; `sizes` gives each asset's pixel size and whether it has sound.
 */
export function planRender(p: M.EditProject, files: Record<string, string>, sizes: Record<string, { width: number; height: number; hasAudio: boolean }>, out: string, o: RenderOptions = {}): RenderPlan {
  const unsupported = new Set<string>();
  const temp: string[] = [];
  const baked = new Map<string, string>(); // cube text → its file (one per distinct colour)
  const f = Math.min(1, (o.maxSide ?? Math.max(p.canvas.width, p.canvas.height)) / Math.max(p.canvas.width, p.canvas.height));
  const W = even(p.canvas.width * f), H = even(p.canvas.height * f), FPS = Math.min(o.fps ?? p.canvas.fps ?? 30, 60);
  const main = M.mainTrack(p), clips = main.items as M.VideoClip[], tl = M.timeline(p);
  if (!clips.length) throw new Error('nothing on the main track');
  const total = o.durationSec ?? (tl.at(-1)?.endSec ?? 0);
  const fr = (t: number) => Math.round(t * FPS);
  const TOTAL = Math.max(1, fr(total));
  /** A clip's frames: from its first frame on the timeline to its last. */
  const frames = (i: number) => Math.max(1, fr(tl[i]!.endSec) - fr(tl[i]!.startSec));
  let tmpN = 0;
  const tmpName = (kind: string, ext: string) => path.join(os.tmpdir(), `muse-${kind}-${process.pid}-${Date.now()}-${tmpN++}.${ext}`);

  let lookN = 0;
  /** A .cube for an item's colour (layer.ts colourCube), or null. */
  const colourFile = (adjust: M.Adjust | undefined, filter: M.FilterRef | undefined, look: Look | undefined): string | null => {
    let lut: Lut | null = null;
    if (look?.lut) {
      const lf = lutFile(look.lut, files);
      if (!lf) unsupported.add('a look that is not on the server');
      else try { lut = parseCube(fs.readFileSync(lf, 'utf8')); } catch { unsupported.add('a look that is not on the server'); }
    }
    const cube = L.colourCube(M.colorMatrix(adjust, filter, FILTERS), adjust, look, lut);
    if (!cube) return null;
    let file = baked.get(cube);
    if (!file) { file = path.join(os.tmpdir(), `muse-look-${process.pid}-${Date.now()}-c${lookN++}.cube`); fs.writeFileSync(file, cube); temp.push(file); baked.set(cube, file); }
    return file;
  };
  const lut3d = (file: string) => `lut3d=file='${file.replace(/\\/g, '/').replace(/:/g, '\\:').replace(/'/g, '')}'`;
  type Visual = M.VideoClip | M.ImageItem;
  type Src = { inSec: number; outSec: number; speed?: number; speedCurve?: M.SpeedCurve; holdSec?: number };

  // ---------------------------------------------------------------- what is on the timeline, in frames
  /** A picture item on the timeline: its first frame and frame count, its source, and how many inputs it reads. */
  type Placed = { it: Visual; video: boolean; start: number; n: number; len: number; file: string; size: { width: number; height: number }; track: number };
  const overlayItems: Placed[] = [];
  p.tracks.forEach((tr, ti) => {
    if ((tr.kind !== 'video' && tr.kind !== 'image') || tr.hidden) return;
    for (const it of tr.items as Visual[]) {
      const video = tr.kind === 'video', start = (it as { startSec: number }).startSec;
      const len = video ? M.clipLength(it as M.VideoClip) : (it as M.ImageItem).durationSec;
      const s0 = fr(start), n = Math.min(fr(start + len), TOTAL) - s0;
      if (n < 1) continue;
      const asset = p.assets.find(a => a.id === it.asset), file = asset && files[asset.id], size = asset && sizes[asset.id];
      if (!asset || !file || !size || !size.width) { unsupported.add('missing media'); continue; }
      overlayItems.push({ it, video, start: s0, n, len, file, size, track: ti });
    }
  });
  const cost = (it: Visual, video: boolean) => 1 + (it.mask ? 1 : 0) + (video && (it as M.VideoClip).alphaMatte ? 1 : 0);

  // ---------------------------------------------------------------- the stretches (windows) rendered one at a time
  // A window never cuts a transition; it ends where reading more would take more than MAX_INPUTS inputs at once
  // (each input holds decoded frames for the whole run), and at most every 60 s.
  const MAX_INPUTS = 6;
  const inTransition = (F: number) => clips.some((c, i) => i > 0 && c.transitionIn && tl[i]!.transitionSec > 0 && F > fr(tl[i]!.startSec) && F < fr(tl[i - 1]!.endSec))
    || clips.some((c, i) => i > 0 && c.transitionIn && tl[i]!.transitionSec > 0 && F === fr(tl[i]!.startSec));
  const marks = new Set<number>([TOTAL]);
  clips.forEach((_, i) => marks.add(fr(tl[i]!.startSec)));
  for (const x of overlayItems) { marks.add(x.start); marks.add(x.start + x.n); }
  for (let F = 0; F < TOTAL; F += 15 * FPS) marks.add(F);
  const cuts = [...marks].filter(F => F > 0 && F <= TOTAL && (F === TOTAL || !inTransition(F))).sort((a, b) => a - b);
  const load = (F0: number, F1: number) => clips.reduce((s, _, i) => s + (fr(tl[i]!.startSec) < F1 && fr(tl[i]!.startSec) + frames(i) > F0 ? cost(clips[i]!, true) : 0), 0)
    + overlayItems.reduce((s, x) => s + (x.start < F1 && x.start + x.n > F0 ? cost(x.it, x.video) : 0), 0);
  const windows: [number, number][] = [];
  for (let F0 = 0; F0 < TOTAL;) {
    let end = cuts.find(F => F > F0)!;
    for (const F of cuts) {
      if (F <= end) continue;
      if (F - F0 > 60 * FPS || load(F0, F) > MAX_INPUTS) break;
      end = F;
    }
    windows.push([F0, end]);
    F0 = end;
  }

  // ---------------------------------------------------------------- text and captions: stills for the whole timeline
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
  const stills: RenderPlan['stills'] = [], sprites: TD.Sprite[] = [];
  let textSeq: number[] = [], textCrop: TD.Crop | null = null, stillFile = (_k: number) => '';
  if (pieces.length) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-text-'));
    temp.push(dir);
    const missing = new Set<string>();
    const byKey = new Map<string, number>(), fms: TD.Frame[] = [], spriteMap = new Map<string, TD.Sprite>();
    textSeq = new Array(TOTAL); // the still each frame shows (−1: none)
    for (let fi = 0; fi < TOTAL; fi++) {
      const shown = pieces.map(x => x(fi / FPS)).filter((x): x is TD.Piece => !!x);
      const key = shown.length ? JSON.stringify(shown) : '';
      let k = key ? byKey.get(key) : -1;
      if (k === undefined) { const fm = TD.frameBody(shown, W, H, missing, spriteMap); k = fm ? fms.push(fm) - 1 : -1; byKey.set(key, k); }
      textSeq[fi] = k;
    }
    // The text is outlines now: drop the CJK faces (80–110 MB each parsed) before the stills and ffmpeg run.
    TD.releaseCjk();
    if (missing.delete(TD.EMOJI)) unsupported.add('colour emoji (drawn in the text colour)');
    if (missing.size) unsupported.add(`letters no font on the server has (${[...missing].slice(0, 8).join(' ')})`);
    if (fms.length) {
      // Every still is cropped to the box all the text ever paints (smaller stills are much cheaper to draw and read).
      const x0 = Math.max(0, Math.floor(Math.min(...fms.map(x => x.box[0])) / 2) * 2), y0 = Math.max(0, Math.floor(Math.min(...fms.map(x => x.box[1])) / 2) * 2);
      const x1 = Math.min(W, Math.ceil(Math.max(...fms.map(x => x.box[2])))), y1 = Math.min(H, Math.ceil(Math.max(...fms.map(x => x.box[3]))));
      if (x1 > x0 && y1 > y0) {
        textCrop = [x0, y0, even(x1 - x0), even(y1 - y0)];
        stillFile = (k: number) => path.join(dir, k < 0 ? 'empty.png' : `s${k}.png`);
        stills.push({ file: stillFile(-1), svg: '', crop: textCrop }, ...fms.map((x, k) => ({ file: stillFile(k), svg: x.svg, crop: textCrop! })));
        sprites.push(...spriteMap.values());
      }
    }
  }
  const runs = adjustRuns(p);
  const masks = new Map<string, string>(); // static masks, written once

  // ---------------------------------------------------------------- one window's graph
  const chunk = (F0: number, F1: number, outFile: string): string[] => {
    const inputs: string[] = [], index = new Map<string, number>(), inputArgs = new Map<number, string[]>();
    const input = (file: string) => { let i = index.get(file); if (i === undefined) { i = inputs.length; inputs.push(file); index.set(file, i); } return i; };
    const g: string[] = [];
    const N = F1 - F0;
    /** An input for a clip's source from `at` for `dur` seconds (opened there, so it never buffers frames for later). */
    const openAt = (file: string, at: number, dur: number, threads = 2): number => {
      const k = inputs.length;
      inputs.push(file);
      inputArgs.set(k, ['-threads', String(threads), '-ss', n4(Math.max(0, at)), '-t', n4(dur + 0.5)]);
      return k;
    };
    /**
     * Frames [skip, skip + n) of a video clip (its speed pieces, or one held frame) or of a picture, from its own start.
     * A constant-speed clip's input opens at the first frame needed; a curve's is cut after its pieces are joined.
     */
    const source = (file: string, c: Src | null, skip: number, n: number, tag: string, threads: number): string => {
      if (!c || c.holdSec !== undefined) {
        const k = c ? openAt(file, c.inSec, 0.2, threads) : input(file);
        g.push(`[${k}:v]trim=end_frame=1,loop=loop=-1:size=1,setpts=N/${FPS}/TB,trim=end_frame=${n}[${tag}]`);
        return tag;
      }
      const pieces = M.speedPieces(c);
      if (pieces.length === 1) {
        const sp = pieces[0]!.speed, at = c.inSec + (skip / FPS) * sp;
        const k = openAt(file, at, Math.max(0.2, c.outSec - at), threads);
        g.push(`[${k}:v]setpts=(PTS-STARTPTS)/${n4(sp)},fps=${FPS},trim=end_frame=${n},setpts=N/${FPS}/TB[${tag}]`);
        return tag;
      }
      const k = openAt(file, c.inSec, c.outSec - c.inSec, threads);
      pieces.forEach((pc, j) => g.push(`[${k}:v]trim=start=${n4(pc.inSec - c.inSec)}:end=${n4(pc.outSec - c.inSec)},setpts=(PTS-STARTPTS)/${n4(pc.speed)},fps=${FPS}[${tag}p${j}]`));
      g.push(`${pieces.map((_, j) => `[${tag}p${j}]`).join('')}concat=n=${pieces.length}:v=1:a=0,trim=start_frame=${skip}:end_frame=${skip + n},setpts=N/${FPS}/TB[${tag}]`);
      return tag;
    };
    type Layer = { s: string; x: number; y: number; opaque: boolean; w: number; h: number } | { s: string; x: null; y: null; opaque: false; w: number; h: number };
    /**
     * A clip or picture drawn as the apps draw it (layer.ts), its frames [skip, skip + n) from the source frames `src`
     * (w × h px): crop → chroma key → colour → matte and mask → placed → opacity. Static and unrotated: a picture to put
     * at (x, y); moving: drawn in the area it sweeps; `canvas`: RGBA the size of the canvas (blend modes).
     */
    const visualLayer = (it: Visual, src: string, w: number, h: number, o: { video: boolean; skip: number; n: number; len: number; fit: M.Fit; tag: string; canvas: boolean; at: number; matte?: () => string | null }): Layer => {
      const { skip, n, len, tag } = o, vc = o.video ? it as M.VideoClip : null, t0 = skip / FPS, clockAt = o.at / FPS;
      let s = src;
      const cr = it.crop ?? {}, l = cr.left ?? 0, t = cr.top ?? 0, r = cr.right ?? 0, b = cr.bottom ?? 0;
      const cw = w * (1 - l - r), ch = h * (1 - t - b);
      const kf = (it.fit ?? o.fit) === 'cover' ? Math.max(W / cw, H / ch) : Math.min(W / cw, H / ch);
      const fw0 = cw * kf, fh0 = ch * kf;
      const mo = L.motion(it, len, `((in+${skip})/${FPS})`);
      const still = [mo.x, mo.y, mo.scale, mo.rotation].map(L.constant);
      const sprite = !o.canvas && still.every(v => v !== null) && Math.abs(((still[3]! % 360) + 360) % 360) < 1e-9;
      // Drawn at the size it reaches on the canvas: its own size when still, else its largest scale.
      const big = sprite ? still[2]! : Math.min(L.maxScale(it), (2 * Math.max(W, H)) / Math.max(fw0, fh0));
      const iw = even(fw0 * big), ih = even(fh0 * big);
      const cropF = l || t || r || b ? `crop=w=iw*${n6(1 - l - r)}:h=ih*${n6(1 - t - b)}:x=iw*${n6(l)}:y=ih*${n6(t)},` : '';
      // Kept in yuv (half the memory of RGB) until a step needs RGB.
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
      // The look's first steps (look.ts renderLook 1–2): sharpen, chromatic aberration.
      const look = it.look, short = Math.min(iw, ih);
      const shp = L.sharpen(look, short);
      if (shp) { toRgb(); g.push(`[${s}]split[${tag}h0][${tag}h1]`, `[${tag}h1]boxblur=luma_radius=${shp.radius}:luma_power=1:chroma_radius=${shp.radius}:chroma_power=1[${tag}hb]`, `[${tag}h0][${tag}hb]lut2=c0='${shp.expr}':c1='${shp.expr}':c2='${shp.expr}'[${tag}sh]`); s = `${tag}sh`; }
      const cab = L.chromatic(look, iw, ih);
      if (cab) {
        toRgb();
        const [rw, rh] = cab.r, [bw, bh] = cab.b, px = Math.ceil((iw - rw) / 2), py = Math.ceil((ih - rh) / 2);
        g.push(`[${s}]extractplanes=g+b+r[${tag}cg][${tag}cb][${tag}cr]`,
          `[${tag}cr]scale=${rw}:${rh}:flags=bilinear,pad=${iw}:${ih}:${(iw - rw) / 2}:${(ih - rh) / 2},fillborders=left=${px}:right=${px}:top=${py}:bottom=${py}:mode=smear,setsar=1[${tag}cr2]`,
          `[${tag}cb]scale=${bw}:${bh}:flags=bilinear,crop=${iw}:${ih},setsar=1[${tag}cb2]`,
          `[${tag}cg][${tag}cb2][${tag}cr2]mergeplanes=0x001020:gbrp[${tag}ca]`);
        s = `${tag}ca`;
      }
      // Colour (3–6): the matrix (adjust, filter), tone, curves, HSL, LUT and lift as one 3D LUT; colour keyframes in runs.
      if (!M.COLOR_KF_PROPS.some(x => it.keyframes?.[x]?.length)) { const cf = colourFile(it.adjust, it.filter, look); if (cf) { toRgb(); g.push(`[${s}]${lut3d(cf)}[${tag}g]`); s = `${tag}g`; } }
      else {
        const step = Math.max(0.1, len / 60), parts: string[] = [];
        for (let a = 0; a < len - 1e-9; a += step) {
          if (a + step < t0 || a > t0 + n / FPS) continue;
          const cf = colourFile(M.adjustAt(it, a + step / 2), it.filter, look);
          if (cf) parts.push(`${lut3d(cf)}:enable='gte(t,${n4(a - t0)})*lt(t,${n4(a + step - t0)})'`);
        }
        if (parts.length) { toRgb(); g.push(`[${s}]${parts.join(',')}[${tag}g]`); s = `${tag}g`; }
      }
      // The look's last steps (7–10): halation; light leak, vignette and grain (their amounts at their keyframes).
      const hal = L.halation(look, short);
      if (hal) {
        toRgb();
        g.push(`[${s}]split[${tag}x0][${tag}x1]`, `[${tag}x1]boxblur=luma_radius=${hal.radius}:luma_power=1:chroma_radius=${hal.radius}:chroma_power=1,colorchannelmixer=rr=0.2126:rg=0.7152:rb=0.0722:gr=0.2126:gg=0.7152:gb=0.0722:br=0.2126:bg=0.7152:bb=0.0722,${hal.lut}[${tag}xh]`,
          `[${tag}x0][${tag}xh]blend=all_mode=screen[${tag}ha]`);
        s = `${tag}ha`;
      }
      const fin = L.finish(it, short, fi => (skip + fi) / FPS, fi => clockAt + fi / FPS, `(T+${n6(t0)})`);
      if (fin) {
        toRgb();
        // A field (leak, vignette) written at 1/8 size, one frame or one a frame, read as raw video and scaled up.
        const field = (draw: (fi: number, w: number, h: number) => Buffer, fmt: 'rgb24' | 'gray', name: string) => {
          const fw = Math.max(2, Math.round(iw / 8)), fh = Math.max(2, Math.round(ih / 8)), count = fin.moving ? n : 1;
          const raw = tmpName(name, fmt === 'gray' ? 'gray' : 'rgb');
          const fd = fs.openSync(raw, 'w');
          try { for (let fi = 0; fi < count; fi++) fs.writeSync(fd, draw(fi, fw, fh)); } finally { fs.closeSync(fd); }
          temp.push(raw);
          const k = inputs.length;
          inputs.push(raw);
          inputArgs.set(k, ['-f', 'rawvideo', '-pix_fmt', fmt, '-s', `${fw}x${fh}`, '-framerate', String(FPS)]);
          g.push(`[${k}:v]${count === 1 ? 'loop=loop=-1:size=1,' : ''}setpts=N/${FPS}/TB,trim=end_frame=${n},scale=${iw}:${ih}:flags=bilinear,format=gbrp[${tag}${name}]`);
          return `${tag}${name}`;
        };
        if (fin.leak) { const lf = field(fin.leak, 'rgb24', 'lk'); g.push(`[${s}][${lf}]blend=all_mode=screen[${tag}lk2]`); s = `${tag}lk2`; }
        if (fin.vignette) { const vf = field(fin.vignette, 'gray', 'vg'); g.push(`[${s}][${vf}]lut2=c0='${L.VIGNETTE_LUT2}':c1='${L.VIGNETTE_LUT2}':c2='${L.VIGNETTE_LUT2}'[${tag}vg2]`); s = `${tag}vg2`; }
        if (fin.grain) {
          // Mono uniform noise (±0.09 × amount), strongest in the mid-tones: n × (1 − |2·luma − 1| / 2), added to every channel.
          const gw = Math.max(2, Math.round(iw / fin.grain.cell)), gh = Math.max(2, Math.round(ih / fin.grain.cell));
          const amt = L.constant(fin.grain.amount);
          g.push(`color=c=0x808080:s=${gw}x${gh}:r=${FPS}:d=${n4(n / FPS + 1)},format=gray,noise=alls=${amt !== null ? n4(Math.min(100, 46 * Math.max(0, amt))) : 46}:allf=t+u,trim=end_frame=${n},scale=${iw}:${ih}:flags=neighbor[${tag}gn]`);
          let noise = `${tag}gn`;
          if (amt === null) {
            g.push(`color=c=white:s=2x2:r=${FPS}:d=${n4(n / FPS + 1)},format=gray,geq=lum='255*clip(${fin.grain.amount},0,1)',scale=${iw}:${ih}:flags=neighbor,trim=end_frame=${n}[${tag}ga]`,
              `[${noise}][${tag}ga]lut2=c0='128+(x-128)*y/255'[${tag}gn2]`);
            noise = `${tag}gn2`;
          }
          g.push(`[${s}]split[${tag}g0][${tag}g1]`, `[${tag}g1]colorchannelmixer=rr=0.2126:rg=0.7152:rb=0.0722,extractplanes=r[${tag}gl]`,
            `[${noise}][${tag}gl]lut2=c0='128+(x-128)*(1-abs(2*y/255-1)*0.5)',format=gbrp[${tag}gw]`,
            `[${tag}g0][${tag}gw]lut2=c0='clip(x+y-128,0,255)':c1='clip(x+y-128,0,255)':c2='clip(x+y-128,0,255)'[${tag}gr]`);
          s = `${tag}gr`;
        }
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
        const key = `${it.id}|${mw}x${mh}`;
        let raw = keyed ? undefined : masks.get(key);
        if (!raw) {
          raw = tmpName('mask', 'gray');
          const fd = fs.openSync(raw, 'w');
          try { for (let fi = 0; fi < (keyed ? n : 1); fi++) fs.writeSync(fd, L.maskPixels(M.maskAt(it, (skip + fi) / FPS)!, mw, mh)); } finally { fs.closeSync(fd); }
          temp.push(raw);
          if (!keyed) masks.set(key, raw);
        }
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
        // Moving: placed by its corners over time (fit, mirror, scale, rotation, position; keys, animation, loop),
        // drawn in the area it sweeps over the canvas (a frame the canvas's size costs ~4 × the memory for a picture-in-picture).
        const sw = L.sweep(it, len, n, FPS, W, H, fw0, fh0, skip);
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
        g.push(`color=c=white:s=2x2:r=${FPS}:d=${n4(n / FPS + 1)},format=gray,geq=lum='255*clip(${L.motion(it, len, `(T+${n6(t0)})`).alpha},0,1)',scale=${ow}:${oh}:flags=neighbor,trim=end_frame=${n}[${tag}op]`,
          `[${s}]split[${tag}o1][${tag}o2]`, `[${tag}o1]alphaextract[${tag}oa]`, `[${tag}oa][${tag}op]lut2=c0='x*y/255'[${tag}om]`, `[${tag}o2][${tag}om]alphamerge[${tag}o]`);
        s = `${tag}o`;
      } else if (ac < 1) { g.push(`[${s}]lut=c3='val*${n4(Math.max(0, ac))}'[${tag}o]`); s = `${tag}o`; }
      return x === null || o.canvas ? { s, x: null, y: null, opaque: false, w: W, h: H } : { s, x, y: y!, opaque, w: ow, h: oh };
    };

    // Main clips in the window: each its own picture of the canvas (the background colour, or the blur fill, under it).
    const mine = clips.map((c, i) => ({ c, i, S: fr(tl[i]!.startSec), n: frames(i) })).filter(x => x.S < F1 && x.S + x.n > F0);
    const many = mine.length > MAX_INPUTS;
    // Blur fill (model.ts blurFill / blurFillClip): one picture behind all the main clips, each clip's own frames
    // cover-fitted with its colour (not its transform), box-blurred and darkened, switching to the incoming clip half-way
    // through a transition. The clips are then drawn over transparency and joined with their alpha.
    const fillOn = p.canvas.fill === 'blur' && !main.hidden;
    const fills: string[] = [];
    const rad = Math.max(1, Math.round(M.blurFillRadius(p.canvas) * f));
    for (const { c, i, S, n: whole } of mine) {
      const skip = Math.max(0, F0 - S), n = Math.min(S + whole, F1) - Math.max(S, F0), tag = `m${i}`;
      const asset = p.assets.find(a => a.id === c.asset);
      const file = asset && files[asset.id], size = asset && sizes[asset.id];
      const len = M.clipLength(c);
      const bg = fillOn ? `color=c=black@0:s=${W}x${H}:r=${FPS}:d=${n4(n / FPS + 1)},trim=end_frame=${n},format=rgba,format=yuva420p`
        : `color=c=${color(p.canvas.background)}:s=${W}x${H}:r=${FPS}:d=${n4(n / FPS + 1)},trim=end_frame=${n},format=yuv420p`;
      const pix = fillOn ? 'yuva420p' : 'yuv420p';
      const fillPart = (src: string | null) => {
        // This clip's stretch of the fill: from half-way through its transition in to half-way through the next one.
        if (!fillOn) return;
        const nx = clips[i + 1] && tl[i + 1]!.transitionSec > 0 ? fr(tl[i + 1]!.startSec + tl[i + 1]!.transitionSec / 2) : S + whole;
        const a = Math.max(F0, tl[i]!.transitionSec > 0 ? fr(tl[i]!.startSec + tl[i]!.transitionSec / 2) : S), b = Math.min(F1, nx);
        if (b <= a) return;
        const ft = `${tag}fill`;
        if (!src) g.push(`color=c=${color(p.canvas.background)}:s=${W}x${H}:r=${FPS}:d=${n4((b - a) / FPS + 1)},trim=end_frame=${b - a},format=yuv420p[${ft}]`);
        else {
          const cf = colourFile(c.adjust, c.filter, c.look);
          g.push(`[${src}]trim=start_frame=${a - Math.max(S, F0)}:end_frame=${b - Math.max(S, F0)},setpts=N/${FPS}/TB,scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},setsar=1,format=gbrp${cf ? `,${lut3d(cf)}` : ''},boxblur=luma_radius=${rad}:luma_power=1:chroma_radius=${rad}:chroma_power=1,colorchannelmixer=rr=${M.BLUR_FILL_DARKEN}:gg=${M.BLUR_FILL_DARKEN}:bb=${M.BLUR_FILL_DARKEN},format=yuv420p,settb=AVTB[${ft}]`);
        }
        fills.push(ft);
      };
      if (!asset || !file || !size || !size.width) { g.push(`${bg},setsar=1,settb=AVTB[v${i}]`); unsupported.add('missing media'); fillPart(null); continue; }
      if (main.hidden) { g.push(`${bg},setsar=1,settb=AVTB[v${i}]`); continue; } // hidden: only the background
      let layerSrc = source(file, c, skip, n, `${tag}s`, many ? 1 : 2);
      if (fillOn) { g.push(`[${layerSrc}]split[${tag}l][${tag}f]`); layerSrc = `${tag}l`; fillPart(`${tag}f`); }
      const under = `${tag}bg`;
      const matte = () => { const mf = c.alphaMatte && files[c.alphaMatte.asset]; return mf ? source(mf, c, skip, n, `${tag}mt`, 1) : null; };
      const lay = visualLayer(c, layerSrc, size.width, size.height, { video: true, skip, n, len, fit: 'cover', tag, canvas: false, matte, at: Math.max(S, F0) });
      if (lay.opaque && lay.x !== null && lay.x <= 0 && lay.y <= 0 && lay.x + lay.w >= W && lay.y + lay.h >= H) {
        // Opaque and covering the canvas: cut to it (no background, no overlay).
        g.push(`[${lay.s}]crop=${W}:${H}:${-lay.x}:${-lay.y}[${tag}o]`);
      } else g.push(`${bg}[${under}]`, `[${under}][${lay.s}]overlay=${lay.x ?? 0}:${lay.y ?? 0}:format=yuv420:eof_action=pass[${tag}o]`);
      // Exactly the clip's frames in the window (rounded once from the timeline, so cuts never drift).
      g.push(`[${tag}o]trim=end_frame=${n},setpts=N/${FPS}/TB,format=${pix},setsar=1,fps=${FPS},settb=AVTB[v${i}]`);
    }
    // Joined: a cut is a concat; a transition is drawn as model.ts transitionState says (transitions never straddle windows).
    const pix = fillOn ? 'yuva420p' : 'yuv420p';
    const flashes: { at: number; d: number; kind: 'black' | 'white' }[] = [];
    /**
     * The transition from the joined picture `A` (frames up to at + d) to clip `B`, d frames from `at`: the d frames are
     * the background (or nothing, under a blur fill), the outgoing clip and the incoming one on top, each moved, scaled,
     * turned and faded by transitionState (perspective and alpha by expression), whip blur and RGB split frame by frame
     * (android TransitionFxEffect: a horizontal box over ±4 % of the width, red and blue ±2 % apart). Black and white
     * switch at half-way; their colour is drawn over the overlays later (android FlashPiece).
     */
    const transition = (A: string, B: string, at: number, d: number, kind: M.TransitionKind, tag: string, out: string) => {
      g.push(`[${A}]split[${tag}h][${tag}t]`, `[${tag}h]trim=end_frame=${at}[${tag}h2]`, `[${tag}t]trim=start_frame=${at}:end_frame=${at + d},setpts=N/${FPS}/TB[${tag}A]`,
        `[${B}]split[${tag}bh][${tag}br]`, `[${tag}bh]trim=end_frame=${d},setpts=N/${FPS}/TB[${tag}B]`, `[${tag}br]trim=start_frame=${d},setpts=N/${FPS}/TB[${tag}R]`);
      const flash = kind === 'black' || kind === 'white';
      const ex = L.transitionExprs(flash ? 'glitch' : kind, `(in/${d})`), exT = L.transitionExprs(flash ? 'glitch' : kind, `(T*${FPS}/${d})`);
      const side = (src: string, which: 'a' | 'b') => {
        let s = src;
        const e = ex[which], st = Array.from({ length: d }, (_, k) => M.transitionState(kind, k / d)[which]);
        if (st.some(x => x.blur > 0)) {
          const cmds = st.map((x, k) => `${n4(k / FPS)} avgblur@${tag}${which} sizeX ${Math.max(1, Math.round(0.04 * W * x.blur))}`).join(';');
          g.push(`[${s}]format=gbrp,sendcmd=c='${cmds}',avgblur@${tag}${which}=sizeX=1:sizeY=1[${tag}${which}bl]`);
          s = `${tag}${which}bl`;
        }
        if (st.some(x => x.rgbSplit > 0)) {
          const cmds = st.map((x, k) => { const sp = Math.round(0.02 * W * x.rgbSplit); return `${n4(k / FPS)} rgbashift@${tag}${which} rh ${sp}, rgbashift@${tag}${which} bh ${-sp}`; }).join(';');
          g.push(`[${s}]format=gbrp,sendcmd=c='${cmds}',rgbashift@${tag}${which}=rh=0:bh=0:edge=smear[${tag}${which}rs]`);
          s = `${tag}${which}rs`;
        }
        if (e.dx !== '0' || e.dy !== '0' || e.scale !== '1' || e.rotation !== '0') {
          const cs = L.cornerExprs({ x: `0.5+(${e.dx})`, y: `0.5+(${e.dy})`, scale: e.scale, rotation: e.rotation, alpha: '1' }, W, H, W, H, W, H, W + 2, H + 2, false, false);
          g.push(`[${s}]format=gbrap,pad=${W + 2}:${H + 2}:1:1:color=black@0,perspective=sense=destination:eval=frame:${cs.map((x, j) => `${['x', 'y'][j % 2]}${Math.floor(j / 2)}='${x}'`).join(':')},crop=${W}:${H}:0:0[${tag}${which}pl]`);
          s = `${tag}${which}pl`;
        }
        if (e.opacity !== '1') {
          g.push(`color=c=white:s=2x2:r=${FPS}:d=${n4(d / FPS + 1)},format=gray,geq=lum='255*clip(${exT[which].opacity},0,1)',scale=${W}:${H}:flags=neighbor,trim=end_frame=${d}[${tag}${which}op]`,
            `[${s}]format=yuva420p,split[${tag}${which}o1][${tag}${which}o2]`, `[${tag}${which}o1]alphaextract[${tag}${which}oa]`,
            `[${tag}${which}oa][${tag}${which}op]lut2=c0='x*y/255'[${tag}${which}om]`, `[${tag}${which}o2][${tag}${which}om]alphamerge[${tag}${which}o]`);
          s = `${tag}${which}o`;
        }
        return s;
      };
      const a = side(`${tag}A`, 'a'), b = side(`${tag}B`, 'b');
      const bg = fillOn ? `color=c=black@0:s=${W}x${H}:r=${FPS}:d=${n4(d / FPS + 1)},format=rgba,format=yuva420p` : `color=c=${color(p.canvas.background)}:s=${W}x${H}:r=${FPS}:d=${n4(d / FPS + 1)},format=yuv420p`;
      g.push(`${bg},trim=end_frame=${d}[${tag}bg]`, `[${tag}bg][${a}]overlay=0:0:format=yuv420:eof_action=pass[${tag}x]`, `[${tag}x][${b}]overlay=0:0:format=yuv420:eof_action=pass,format=${pix},setsar=1,settb=AVTB[${tag}T]`,
        `[${tag}h2][${tag}T][${tag}R]concat=n=3:v=1:a=0[${out}]`);
    };
    let acc = `v${mine[0]!.i}`;
    const glitches: { start: number; d: number }[] = [];
    for (const { c, i } of mine.slice(1)) {
      const t = c.transitionIn, next = `j${i}`;
      const d = t && tl[i]!.transitionSec > 0 ? fr(tl[i - 1]!.endSec) - fr(tl[i]!.startSec) : 0;
      const at = fr(tl[i]!.startSec) - F0;
      if (t?.kind === 'glitch' && d >= 2) { g.push(...glitchSwitch(acc, `v${i}`, next, at, d, i, FPS)); glitches.push({ start: at, d }); }
      else if (t && d > 0) { transition(acc, `v${i}`, at, d, t.kind, `tr${i}`, next); if (t.kind === 'black' || t.kind === 'white') flashes.push({ at, d, kind: t.kind }); }
      else g.push(`[${acc}][v${i}]concat=n=2:v=1:a=0[${next}]`);
      acc = next;
    }
    // The glitches' jitter and colour split, on the joined picture.
    if (glitches.length) {
      g.push(`[${acc}]format=${fillOn ? 'gbrap' : 'gbrp'},sendcmd=c='${glitchShifts(glitches, W, FPS, 'rgbashift@glitch')}',rgbashift@glitch=rh=0:gh=0:bh=0:edge=smear,format=${fillOn ? 'yuva420p' : 'yuv420p'}[gfx]`);
      acc = 'gfx';
    }
    // Held on its last frame to the window's end (a set render length past the timeline's end).
    g.push(`[${acc}]tpad=stop_mode=clone:stop_duration=${n4(N / FPS)},trim=end_frame=${N},setpts=N/${FPS}/TB[base]`);
    acc = 'base';
    if (fills.length) {
      g.push(`${fills.map(x => `[${x}]`).join('')}concat=n=${fills.length}:v=1:a=0,tpad=stop_mode=clone:stop_duration=${n4(N / FPS)},trim=end_frame=${N},setpts=N/${FPS}/TB[fill]`,
        `[fill][base]overlay=0:0:format=yuv420:eof_action=pass,format=yuv420p[filled]`);
      acc = 'filled';
    }
    // Overlays (video and image tracks), in track order (layer.ts).
    overlayItems.filter(x => x.start < F1 && x.start + x.n > F0).forEach((x, oi) => {
      const { it, video } = x, vc = video ? it as M.VideoClip : null, tag = `ov${oi}`;
      const skip = Math.max(0, F0 - x.start), n = Math.min(x.start + x.n, F1) - Math.max(x.start, F0), at = Math.max(x.start, F0) - F0;
      const src = source(x.file, vc, skip, n, `${tag}s`, 1);
      const mode = it.blend ?? 'normal';
      const matte = () => { const mf = vc?.alphaMatte && files[vc.alphaMatte.asset]; return mf ? source(mf, vc, skip, n, `${tag}mt`, 1) : null; };
      const lay = visualLayer(it, src, x.size.width, x.size.height, { video, skip, n, len: x.len, fit: 'contain', tag, canvas: mode !== 'normal', matte, at: Math.max(x.start, F0) });
      const t0 = n4(at / FPS), on = `enable='between(t,${t0},${n4((at + n - 0.5) / FPS)})'`;
      // Normal: over the picture as it is (yuv; the mix is linear, as in RGB).
      if (mode === 'normal') g.push(`[${lay.s}]setpts=PTS+${t0}/TB[${tag}t]`, `[${acc}][${tag}t]overlay=${lay.x ?? 0}:${lay.y ?? 0}:format=yuv420:eof_action=pass:${on}[${tag}x]`);
      else {
        // blendPixel: the mode's colour (lut2, exact W3C formulas) mixed in by the item's coverage (maskedmerge).
        const e = L.blendExpr(mode);
        g.push(`[${lay.s}]tpad=start_duration=${t0}:stop_duration=${n4(N / FPS)}:color=black@0,trim=end_frame=${N},split[${tag}t1][${tag}t2]`,
          `[${acc}]format=gbrp,split[${tag}b1][${tag}b2]`, `[${tag}t1]format=gbrp[${tag}tc]`, `[${tag}tc][${tag}b1]lut2=c0='${e}':c1='${e}':c2='${e}'[${tag}bl]`,
          `[${tag}t2]alphaextract,format=gbrp[${tag}ta]`, `[${tag}b2][${tag}bl][${tag}ta]maskedmerge,format=yuv420p[${tag}x]`);
      }
      acc = `${tag}x`;
    });
    // Adjustment layers: over the pictures, under the text. Each run of one colour is one affine channel mix, on only
    // while the run lasts: on RGBA with an opaque alpha, the offsets go in as the alpha's coefficients, so the sum is
    // clamped once, at the end (model.ts: "not clamped between layers, only at the end").
    const mineRuns = runs.filter(r => fr(r.b) > F0 && fr(r.a) < F1);
    if (mineRuns.length) {
      const st: string[] = ['format=rgba'];
      for (const { a, b, m } of mineRuns) {
        const on = `enable='gte(t,${n4(a - F0 / FPS)})*lt(t,${n4(b - F0 / FPS)})'`;
        st.push(`colorchannelmixer=rr=${n6(m[0]!)}:rg=${n6(m[1]!)}:rb=${n6(m[2]!)}:ra=${n6(m[3]!)}:gr=${n6(m[4]!)}:gg=${n6(m[5]!)}:gb=${n6(m[6]!)}:ga=${n6(m[7]!)}:br=${n6(m[8]!)}:bg=${n6(m[9]!)}:bb=${n6(m[10]!)}:ba=${n6(m[11]!)}:${on}`);
      }
      g.push(`[${acc}]${st.join(',')},format=yuv420p[adj]`);
      acc = 'adj';
    }
    // Black and white transitions' colour, over the pictures and overlays, under the text: alpha 1 − |1 − 2p|.
    flashes.forEach((fl, k) => {
      g.push(`color=c=white:s=2x2:r=${FPS}:d=${n4(fl.d / FPS + 1)},format=gray,geq=lum='255*clip(1-abs(1-2*T*${FPS}/${fl.d}),0,1)',scale=${W}:${H}:flags=neighbor,trim=end_frame=${fl.d}[fl${k}a]`,
        `color=c=${fl.kind === 'white' ? 'white' : 'black'}:s=${W}x${H}:r=${FPS}:d=${n4(fl.d / FPS + 1)},format=yuv420p,trim=end_frame=${fl.d}[fl${k}c]`,
        `[fl${k}c][fl${k}a]alphamerge,setpts=PTS+${n4(fl.at / FPS)}/TB[fl${k}]`,
        `[${acc}][fl${k}]overlay=0:0:format=yuv420:eof_action=pass:enable='between(t,${n4(fl.at / FPS)},${n4((fl.at + fl.d - 0.5) / FPS)})'[fl${k}x]`);
      acc = `fl${k}x`;
    });
    // Text and captions, above every picture (textdraw.ts): the window's stretch of the stills, overlaid once.
    if (textCrop && textSeq.slice(F0, F1).some(k => k >= 0)) {
      const seq: { still: number; frames: number }[] = [];
      for (let fi = F0; fi < F1; fi++) { const k = textSeq[fi]!, last = seq.at(-1); if (last && last.still === k) last.frames++; else seq.push({ still: k, frames: 1 }); }
      const list = tmpName('text', 'ffconcat');
      fs.writeFileSync(list, ['ffconcat version 1.0', ...seq.flatMap(x => [`file '${stillFile(x.still)}'`, `duration ${n6(x.frames / FPS)}`]), `file '${stillFile(seq.at(-1)!.still)}'`].join('\n') + '\n');
      temp.push(list);
      const k = input(list);
      inputArgs.set(k, ['-threads', '1', '-f', 'concat', '-safe', '0']);
      g.push(`[${k}:v]format=rgba[txt]`, `[${acc}][txt]overlay=${textCrop[0]}:${textCrop[1]}:format=auto:eof_action=repeat[vtxt]`);
      acc = 'vtxt';
    }
    g.push(`[${acc}]format=yuv420p[vout]`);
    return ['-y', '-v', 'error', ...inputs.flatMap((x, i) => [...(inputArgs.get(i) ?? []), '-i', x]), '-filter_complex', g.join(';'), '-map', '[vout]',
      '-c:v', 'libx264', ...q, '-pix_fmt', 'yuv420p', '-r', String(FPS), '-threads', '2', '-frames:v', String(N), outFile];
  };

  // ---------------------------------------------------------------- sound: a pass of its own
  // Before the pictures (renderProject), so reading a clip's sound never pulls its picture in early (a stream waiting
  // for its picture's time buffers every frame meanwhile).
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
    const voice = (c: M.VideoClip | M.AudioClip) => voiceChain(c, 48000).map(v => `,biquad=b0=${v.b0}:b1=${v.b1}:b2=${v.b2}:a0=1:a1=${v.a1}:a2=${v.a2}`).join('');
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
      const k = ainput(file), pcs = M.speedPieces(c);
      if (pcs.length === 1) ag.push(`[${k}:a]atrim=start=${n4(c.inSec)}:end=${n4(c.outSec)},asetpts=PTS-STARTPTS,${A}${atempo(pcs[0]!.speed).map(x => `,${x}`).join('')}[${tag}s]`);
      else ag.push(`[${k}:a]atrim=start=${n4(c.inSec)}:end=${n4(c.outSec)},asetpts=PTS-STARTPTS,${A},${curveTempo(pcs, c.inSec, tag)}[${tag}s]`);
      place(`${tag}s`, c, env, startSec, tag);
    };
    clips.forEach((c, i) => clipSound(c, main.id, tl[i]!.startSec, `ac${i}`));
    let vi = 0;
    for (const tr of p.tracks) if (tr.kind === 'video') for (const c of tr.items as M.VideoClip[]) clipSound(c, tr.id, c.startSec ?? 0, `av${vi++}`);
    let ai = 0;
    for (const tr of p.tracks.filter(t => (t.kind === 'music' || t.kind === 'voice' || t.kind === 'sfx') && !t.muted)) {
      for (const it of tr.items as M.AudioClip[]) {
        const asset = p.assets.find(a => a.id === it.asset), file = asset && files[asset.id];
        if (!asset || !file || it.muted) { if (asset?.library && !it.muted) unsupported.add('library sounds that are not on the server'); continue; }
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
  let soundArgs: string[] | null = null, sound: string | null = null;
  if (amix.length) {
    sound = tmpName('sound', 'flac');
    temp.push(sound);
    soundArgs = ['-y', '-v', 'error', ...ainputs.flatMap(x => ['-vn', '-i', x]), '-filter_complex', ag.join(';'), '-map', '[aout]', '-c:a', 'flac', '-t', n4(total), sound];
  }

  // ---------------------------------------------------------------- the pictures, window by window, then joined
  // Export: x264's frame threads and lookahead held ~190 MB at 1080 × 1920; sliced threads and a 5-frame lookahead
  // halve that (the box has 512 MB) for ~50 % more encode time.
  const q = o.quality === 'export' ? ['-preset', 'veryfast', '-x264-params', 'sliced-threads=1:rc-lookahead=5:sync-lookahead=0', '-crf', '18'] : ['-preset', 'ultrafast', '-crf', '28'];
  const chunkFiles = windows.map(() => tmpName('part', 'mp4'));
  temp.push(...chunkFiles);
  const chunks = windows.map(([F0, F1], i) => chunk(F0, F1, chunkFiles[i]!));
  const list = tmpName('parts', 'ffconcat');
  fs.writeFileSync(list, ['ffconcat version 1.0', ...chunkFiles.map(x => `file '${x}'`)].join('\n') + '\n');
  temp.push(list);
  const joinArgs = ['-y', '-v', 'error', '-f', 'concat', '-safe', '0', '-i', list, ...(sound ? ['-i', sound] : []), '-map', '0:v', ...(sound ? ['-map', '1:a', '-c:a', 'aac', '-b:a', '128k'] : []),
    '-c:v', 'copy', '-movflags', '+faststart', '-t', n4(TOTAL / FPS), out];
  return { chunks, joinArgs, soundArgs, durationSec: total, width: W, height: H, unsupported: [...unsupported], temp, stills, sprites };
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
    for (const c of plan.chunks) await run(c);
    await run(plan.joinArgs);
  } finally { for (const t of plan.temp) fs.rmSync(t, { force: true, recursive: true }); }
  return { durationSec: plan.durationSec, width: plan.width, height: plan.height, unsupported: plan.unsupported };
}
