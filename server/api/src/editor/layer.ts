// The server render's picture layers (render parity): the pieces of an ffmpeg graph that draw a video clip or a picture
// as the apps do (android RenderPlan.look / placement, model.ts): crop → chroma key → colour (matrix, tone, curves, HSL,
// LUT, lift: one baked 3D LUT) → alpha matte and mask → placed by its corners (model.ts itemCorners: fit, mirror, scale,
// rotation, position; keyframes, in/out animation and loop over time) → opacity → blended over what is below
// (model.ts blendPixel). Pure: builds strings, cube text and mask pixels.
import { curvesFn, grainCell, halationRadius, hslFn, leakColor, lutSample, sharpenRadius, vignetteMask, writeCube, type Look, type Lut } from './look.js';
import * as M from './model.js';

const n4 = (x: number) => String(Math.round(x * 10000) / 10000);
const n6 = (x: number) => String(Math.round(x * 1e6) / 1e6);
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

// ------------------------------------------------------------------ motion over time, as ffmpeg expressions
/** model.ts `ease` on a 0–1 progress expression `p`. */
export function easeExpr(kind: M.Ease | undefined, p: string): string {
  switch (kind ?? 'linear') {
    case 'easeIn': return `pow(${p},2)`;
    case 'easeOut': return `(1-pow(1-${p},2))`;
    case 'easeInOut': return `if(lt(${p},0.5),2*pow(${p},2),1-pow(2-2*${p},2)/2)`;
    case 'hold': return '0';
    default: return p;
  }
}
/** model.ts keyframeValue at the time `tv` (each span eased by its first key's ease; constant outside the keys). */
export function kfExpr(keys: M.Keyframe[] | undefined, fallback: number, tv = 't'): string {
  const k = keys ?? [];
  if (!k.length) return n4(fallback);
  if (k.length === 1) return n4(k[0]!.v);
  let e = n4(k.at(-1)!.v);
  for (let i = k.length - 2; i >= 0; i--) {
    const a = k[i]!, b = k[i + 1]!, dt = b.t - a.t;
    if (dt <= 0) { e = `if(lt(${tv},${n4(b.t)}),${n4(b.v)},${e})`; continue; }
    const p = `((${tv}-${n4(a.t)})/${n4(dt)})`;
    e = `if(lt(${tv},${n4(b.t)}),${n4(a.v)}+(${n4(b.v - a.v)})*${easeExpr(a.ease, p)},${e})`;
  }
  return `if(lt(${tv},${n4(k[0]!.t)}),${n4(k[0]!.v)},${e})`;
}

type Expr = { opacity: string; scale: string; dy: string };
/** model.ts animState (no typewriter) for an item `len` seconds long, at the time `tv`. */
export function animExpr(item: { animIn?: M.Anim; animOut?: M.Anim }, len: number, tv: string): Expr {
  const op: string[] = [], sc: string[] = [], dy: string[] = [];
  const apply = (a: M.Anim | undefined, p: string) => {
    if (!a || a.kind === 'none' || a.kind === 'typewriter') return;
    const e = `(1-pow(1-${p},2))`;
    op.push(e);
    if (a.kind === 'pop') sc.push(`if(lt(${p},0.7),0.6+0.48*(${p}/0.7),1.08-0.08*((${p}-0.7)/0.3))`);
    if (a.kind === 'zoom') sc.push(`(1.3-0.3*${e})`);
    if (a.kind === 'slideUp') dy.push(`0.05*(1-${e})`);
    if (a.kind === 'slideDown') dy.push(`-0.05*(1-${e})`);
  };
  const prog = (a: M.Anim | undefined, x: string) => (a && a.durationSec > 0 ? `clip(${x}/${n4(a.durationSec)},0,1)` : '1');
  apply(item.animIn, prog(item.animIn, tv));
  apply(item.animOut, prog(item.animOut, `(${n4(len)}-${tv})`));
  return { opacity: op.join('*') || '1', scale: sc.join('*') || '1', dy: dy.join('+') || '0' };
}
/** model.ts loopState at the time `tv`: scale ×, rotation + (degrees), dy +, opacity ×. */
export function loopExpr(loop: M.AnimLoop | undefined, tv: string): { scale: string; rotation: string; dy: string; opacity: string } {
  const st = { scale: '1', rotation: '0', dy: '0', opacity: '1' };
  if (!loop || !(loop.periodSec > 0)) return st;
  const a = clamp(loop.amount ?? 0.5, 0, 1), ph = `(2*PI*${tv}/${n4(loop.periodSec)})`, wave = `(0.5-0.5*cos(${ph}))`;
  switch (loop.kind) {
    case 'pulse': st.scale = `(1+${n6(0.12 * a)}*${wave})`; break;
    case 'sway': st.rotation = `${n6(8 * a)}*sin(${ph})`; break;
    case 'float': st.dy = `${n6(-0.03 * a)}*sin(${ph})`; break;
    case 'spin': st.rotation = `mod(360*${tv}/${n4(loop.periodSec)},360)`; break;
    case 'blink': st.opacity = `(1-${n6(a)}*${wave})`; break;
  }
  return st;
}

/** An item's placement over time (android RenderPlan.itemPlacement): centre x, y (canvas fractions), scale, rotation (°), alpha. */
export type Motion = { x: string; y: string; scale: string; rotation: string; alpha: string };
export function motion(item: { transform?: M.Transform; keyframes?: M.Keyframes; opacity?: number; animIn?: M.Anim; animOut?: M.Anim; animLoop?: M.AnimLoop }, len: number, tv: string): Motion {
  const k = item.keyframes ?? {}, tr = item.transform ?? {};
  const an = animExpr(item, len, tv), lp = loopExpr(item.animLoop, tv);
  const mul = (...xs: string[]) => xs.filter(x => x !== '1').join('*') || '1';
  const add = (...xs: string[]) => xs.filter(x => x !== '0').join('+') || '0';
  return {
    x: kfExpr(k.x, tr.x ?? 0.5, tv),
    y: add(kfExpr(k.y, tr.y ?? 0.5, tv), an.dy, lp.dy),
    scale: mul(kfExpr(k.scale, tr.scale ?? 1, tv), an.scale, lp.scale),
    rotation: add(kfExpr(k.rotation, tr.rotation ?? 0, tv), lp.rotation),
    alpha: mul(kfExpr(k.opacity, item.opacity ?? 1, tv), an.opacity, lp.opacity),
  };
}
/** Whether a motion expression is a constant (no time in it), and its value. */
export const constant = (e: string): number | null => (/^-?[\d.]+$/.test(e) ? Number(e) : null);
/** The largest scale an item reaches (keys, static scale, pop / zoom / pulse), to draw it sharp enough. */
export function maxScale(item: { transform?: M.Transform; keyframes?: M.Keyframes; animIn?: M.Anim; animOut?: M.Anim; animLoop?: M.AnimLoop }): number {
  const ks = item.keyframes?.scale?.map(k => k.v) ?? [];
  let s = Math.max(item.transform?.scale ?? 1, ...ks);
  if ([item.animIn, item.animOut].some(a => a?.kind === 'zoom')) s *= 1.3; else if ([item.animIn, item.animOut].some(a => a?.kind === 'pop')) s *= 1.08;
  if (item.animLoop?.kind === 'pulse') s *= 1 + 0.12 * (item.animLoop.amount ?? 0.5);
  return s;
}

/**
 * perspective corners (sense=destination) that place an item: its picture is drawn iw × ih at (1, 1) of a transparent
 * frame fw × fh; the frame's corners go where the affine map of model.ts itemCorners (picture on the canvas fw0 × fh0
 * px at scale 1: fit applied; mirrored, scaled, rotated about the centre and moved) sends them. Order: top-left,
 * top-right, bottom-left, bottom-right (perspective's x0 y0 … x3 y3).
 */
export function cornerExprs(m: Motion, W: number, H: number, fw0: number, fh0: number, iw: number, ih: number, fw: number, fh: number, flipX: boolean, flipY: boolean, ox = 0, oy = 0): string[] {
  const out: string[] = [];
  const fx = flipX ? -1 : 1, fy = flipY ? -1 : 1;
  for (const [px, py] of [[0, 0], [fw, 0], [0, fh], [fw, fh]] as const) {
    // perspective puts the frame's corner coordinates on pixel positions, not pixel edges: so the affine map is taken at
    // the pixel's centre (+ 0.5) and read back as a position (− 0.5). Without it a picture magnified k× sat 0.5 × (k − 1)
    // px off (2026-11-14: −0.25 px when drawn 2× and shown 1×; +0.5 px at a 2× zoom drawn at source size).
    // the frame corner in the picture's own centred coordinates, scaled to canvas pixels at scale 1
    const u = ((px + 0.5 - 1 - iw / 2) / iw) * fw0 * fx, v = ((py + 0.5 - 1 - ih / 2) / ih) * fh0 * fy;
    const r = `((${m.rotation})*PI/180)`;
    out.push(`${n4(W)}*(${m.x})-${n4(ox + 0.5)}+(${m.scale})*(${n4(u)}*cos(${r})-(${n4(v)})*sin(${r}))`);
    out.push(`${n4(H)}*(${m.y})-${n4(oy + 0.5)}+(${m.scale})*(${n4(u)}*sin(${r})+(${n4(v)})*cos(${r}))`);
  }
  return out;
}

/**
 * The canvas area (x0, y0, x1, y1 px) an item's picture covers over `n` of its frames from frame `skip` (android RenderPlan.itemPlacement
 * from model.ts propAt / animState / loopState, every frame), so a moving item is drawn in a frame no bigger than that.
 */
export function sweep(item: { transform?: M.Transform; keyframes?: M.Keyframes; opacity?: number; animIn?: M.Anim; animOut?: M.Anim; animLoop?: M.AnimLoop }, len: number, n: number, fps: number, W: number, H: number, fw0: number, fh0: number, skip = 0): [number, number, number, number] {
  const tr = item.transform ?? {};
  const box: [number, number, number, number] = [Infinity, Infinity, -Infinity, -Infinity];
  for (let f = skip; f <= skip + n; f++) {
    const t = Math.min(len, f / fps), a = M.animState({ durationSec: len, animIn: item.animIn, animOut: item.animOut }, t), lp = M.loopState(item.animLoop, t);
    const x = M.propAt(item, 'x', tr.x ?? 0.5, t) * W, y = (M.propAt(item, 'y', tr.y ?? 0.5, t) + a.dy + lp.dy) * H;
    const sc = M.propAt(item, 'scale', tr.scale ?? 1, t) * a.scale * lp.scale, r = ((M.propAt(item, 'rotation', tr.rotation ?? 0, t) + lp.rotation) * Math.PI) / 180;
    const hw = (fw0 * sc) / 2, hh = (fh0 * sc) / 2, ex = Math.abs(hw * Math.cos(r)) + Math.abs(hh * Math.sin(r)), ey = Math.abs(hw * Math.sin(r)) + Math.abs(hh * Math.cos(r));
    box[0] = Math.min(box[0], x - ex); box[1] = Math.min(box[1], y - ey); box[2] = Math.max(box[2], x + ex); box[3] = Math.max(box[3], y + ey);
  }
  return box;
}

// ------------------------------------------------------------------ transitions (model.ts transitionState)
export type SideExpr = { dx: string; dy: string; scale: string; rotation: string; opacity: string };
/**
 * model.ts transitionState as expressions of the progress `p` (0–1): the outgoing (a) and incoming (b) clips' offset
 * (canvas widths / heights), scale, rotation (°) and opacity. Blur and RGB split come from transitionState itself
 * (frame by frame). The glitch is drawn on its own (glitchSwitch).
 */
export function transitionExprs(kind: M.TransitionKind, p: string): { a: SideExpr; b: SideExpr } {
  const e = `if(lt(${p},0.5),2*pow(${p},2),1-pow(2-2*${p},2)/2)`, e3 = `if(lt(${p},0.5),4*pow(${p},3),1-pow(2-2*${p},3)/2)`;
  const S = (o: Partial<SideExpr> = {}): SideExpr => ({ dx: '0', dy: '0', scale: '1', rotation: '0', opacity: '1', ...o });
  const before = `lt(${p},0.5)`, after = `gte(${p},0.5)`;
  switch (kind) {
    case 'fade': return { a: S(), b: S({ opacity: p }) };
    case 'black': case 'white': return { a: S({ opacity: `max(0,1-2*${p})` }), b: S({ opacity: `max(0,2*${p}-1)` }) };
    case 'slideLeft': return { a: S({ dx: `-(${e})` }), b: S({ dx: `1-(${e})` }) };
    case 'slideRight': return { a: S({ dx: e }), b: S({ dx: `-(1-(${e}))` }) };
    case 'slideUp': return { a: S({ dy: `-(${e})` }), b: S({ dy: `1-(${e})` }) };
    case 'slideDown': return { a: S({ dy: e }), b: S({ dy: `-(1-(${e}))` }) };
    case 'zoom': return { a: S({ scale: `1+0.25*(${e})`, opacity: `1-${p}` }), b: S({ opacity: p }) };
    case 'whip': return { a: S({ dx: `-(${e3})` }), b: S({ dx: `1-(${e3})` }) };
    case 'spin': return { a: S({ rotation: `180*(${e})`, scale: `1-0.6*(${e})`, opacity: before }), b: S({ rotation: `-180*(1-(${e}))`, scale: `0.4+0.6*(${e})`, opacity: after }) };
    case 'glitch': return { a: S({ opacity: before }), b: S({ opacity: after }) };
    case 'zoomOut': return { a: S({ scale: `1-0.2*(${e})`, opacity: `1-${p}` }), b: S({ scale: `1.2-0.2*(${e})`, opacity: p }) };
    case 'whipRight': return { a: S({ dx: e3 }), b: S({ dx: `-(1-(${e3}))` }) };
    case 'coverLeft': return { a: S(), b: S({ dx: `1-(${e})` }) };
    case 'coverRight': return { a: S(), b: S({ dx: `-(1-(${e}))` }) };
    case 'coverUp': return { a: S(), b: S({ dy: `1-(${e})` }) };
    case 'coverDown': return { a: S(), b: S({ dy: `-(1-(${e}))` }) };
    case 'splitFade': return { a: S(), b: S({ opacity: p }) };
  }
}

// ------------------------------------------------------------------ colour: one 3D LUT
/**
 * The item's colour as a 33³ .cube (look.ts renderLook steps 3–6 on the item's own frame): colour matrix (adjust +
 * filter, clamped), highlights / shadows, curves, HSL, the LUT at its strength, lift. Null when it changes nothing.
 */
export function colourCube(matrix: number[] | null, adjust: M.Adjust | undefined, look: Look | undefined, lut: Lut | null): string | null {
  const curves = curvesFn(look?.curves), hsl = hslFn(look?.hsl), s = clamp(look?.strength ?? 1, 0, 1);
  const lift = 0.12 * clamp(look?.lift ?? 0, 0, 1), sh = adjust?.shadows ?? 0, hi = adjust?.highlights ?? 0;
  const ident = !matrix || matrix.every((v, i) => Math.abs(v - [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0][i]!) < 1e-9);
  if (ident && !curves && !hsl && !(lut && s > 0) && !lift && !sh && !hi) return null;
  const c01 = (v: number) => clamp(v, 0, 1);
  return writeCube(33, 'muse colour', (r, g, b) => {
    let rgb: [number, number, number] = [r, g, b];
    if (!ident) rgb = [0, 1, 2].map(i => c01(matrix![i * 4]! * rgb[0] + matrix![i * 4 + 1]! * rgb[1] + matrix![i * 4 + 2]! * rgb[2] + matrix![i * 4 + 3]!)) as [number, number, number];
    if (sh || hi) rgb = rgb.map(v => M.toneAdjust(v, sh, hi)) as [number, number, number];
    if (curves) rgb = curves(rgb);
    if (hsl) rgb = hsl(rgb);
    if (lut && s > 0) { const t = lutSample(lut, rgb[0], rgb[1], rgb[2]); rgb = [0, 1, 2].map(i => c01(rgb[i]! + (t[i]! - rgb[i]!) * s)) as [number, number, number]; }
    if (lift > 0) rgb = rgb.map(v => lift + v * (1 - lift)) as [number, number, number];
    return rgb;
  });
}

// ------------------------------------------------------------------ look details (look.ts renderLook steps 1, 2, 7–10)
const ss = (a: string, b: string, x: string) => `(pow(clip((${x}-(${a}))/((${b})-(${a})),0,1),2)*(3-2*clip((${x}-(${a}))/((${b})-(${a})),0,1)))`;
/** Step 1, sharpen: box radius (from the picture's short side) and the lut2 expression (x = pixel, y = its blur), or null. */
export function sharpen(look: Look | undefined, short: number): { radius: number; expr: string } | null {
  const sh = clamp(look?.sharpen ?? 0, 0, 1);
  return sh > 0 ? { radius: sharpenRadius(short), expr: `clip(x+${n6(1.5 * sh)}*(x-y),0,255)` } : null;
}
/**
 * Step 2, chromatic aberration: red sampled outwards and blue inwards from the centre by `ca` of the picture, i.e. the
 * red plane shrunk by 1 / (1 + ca) and the blue one grown by 1 / (1 − ca) about the centre (edges smeared). Null if none.
 */
export function chromatic(look: Look | undefined, w: number, h: number): { r: [number, number]; b: [number, number] } | null {
  const ca = clamp(look?.chromatic ?? 0, 0, 1) * 0.006;
  if (!(ca > 0)) return null;
  const ev = (x: number) => Math.max(2, Math.round(x / 2) * 2);
  return { r: [ev(w / (1 + ca)), ev(h / (1 + ca))], b: [ev(w / (1 - ca)), ev(h / (1 - ca))] };
}
/** Step 7, halation: box radius and the highlights' tinted screen layer (lutrgb on the blurred picture's luma), or null. */
export function halation(look: Look | undefined, short: number): { radius: number; lut: string } | null {
  const ha = look?.halation;
  if (!ha || !(ha.amount > 0)) return null;
  const thr = clamp(ha.threshold ?? 0.7, 0, 0.99), k = clamp(ha.amount, 0, 1);
  const hl = `clip((val/255-${n6(thr)})/${n6(1 - thr)},0,1)*${n6(k)}*255`;
  return { radius: halationRadius(short, ha), lut: `lutrgb=r='${hl}':g='${hl}*0.35':b='${hl}*0.2'` };
}
/** What steps 8–10 (light leak, vignette, grain) draw on an item, with their amounts at their keyframes (lookAt). */
export type Finish = {
  /** The leak's colour (to screen on) at frame f of the item, `w` × `h` RGB 0–255; null without a leak. */
  leak: ((f: number, w: number, h: number) => Buffer) | null;
  /** The vignette at frame f, grey: 128 + 127 × amount × mask (above 128 darkens, below lifts); null without one. */
  vignette: ((f: number, w: number, h: number) => Buffer) | null;
  /** Whether either moves (then one picture a frame, else one for all). */
  moving: boolean;
  /** Grain: its strength over time as an expression of `local` (0–1 × amount), and its cell size in pixels; or null. */
  grain: { amount: string; cell: number } | null;
};
/**
 * Steps 8–10 for an item (look.ts renderLook): the leak (drifting with the timeline clock) and the vignette as smooth
 * fields drawn here (they are scaled up from 1/8 size), the grain's amount. `local(f)` / `clock(f)`: the item's own
 * time and the timeline's at frame f. Grain's pattern is ffmpeg's own noise (look.ts hash01's bit mixing has no ffmpeg
 * form); its amount, cell size and mid-tone weighting are the reference's.
 */
export function finish(item: { look?: Look; keyframes?: M.Keyframes }, short: number, local: (f: number) => number, clock: (f: number) => number, tv: string): Finish | null {
  const look = item.look ?? {}, k = item.keyframes ?? {};
  const has = (x: unknown, keys?: M.Keyframe[]) => !!x || !!keys?.length;
  const lk = has(look.leak, k.leak), vg = has(look.vignette, k.vignette), gr = has(look.grain, k.grain);
  if (!lk && !vg && !gr) return null;
  const at = (f: number) => M.lookAt(item, local(f)) ?? {};
  const grain = gr ? { amount: kfExpr(k.grain, look.grain?.amount ?? 0, tv), cell: grainCell(short, look.grain ?? { amount: 0 }) } : null;
  return {
    leak: lk ? (f, w, h) => {
      const l = at(f).leak, out = Buffer.alloc(w * h * 3);
      if (l && l.amount > 0) for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const c = leakColor(l, (x + 0.5) / w, (y + 0.5) / h, clock(f));
        for (let i = 0; i < 3; i++) out[(y * w + x) * 3 + i] = Math.round(255 * clamp(c[i]!, 0, 1));
      }
      return out;
    } : null,
    vignette: vg ? (f, w, h) => {
      const v = at(f).vignette, out = Buffer.alloc(w * h, 128);
      if (v && v.amount !== 0) for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) out[y * w + x] = Math.round(128 + 127 * clamp(v.amount, -1, 1) * vignetteMask(v, (x + 0.5) / w, (y + 0.5) / h));
      return out;
    } : null,
    moving: lk || !!k.vignette?.length,
    grain: grain && constant(grain.amount) !== 0 ? grain : null,
  };
}
/** The vignette field (grey, see Finish) on a channel, as a lut2 expression: x = the channel, y = the field. */
export const VIGNETTE_LUT2 = `clip(if(gte(y,128),x*(1-(y-128)/127),x+((128-y)/127)*(255-x)),0,255)`;

// ------------------------------------------------------------------ alpha: chroma key, mask
/** model.ts chromaKey's alpha and spill amount as lut2 expressions of 8-bit full-range BT.601 U (x) and V (y), 0–255. */
export function chromaExprs(key: M.Chroma): { alpha: string; spill: string } {
  const [kr, kg, kb] = M.hexRgb(key.color);
  const kcb = -0.168736 * kr - 0.331264 * kg + 0.5 * kb, kcr = 0.5 * kr - 0.418688 * kg - 0.081312 * kb;
  const base = `(hypot((x-128)/255-(${n6(kcb)}),(y-128)/255-(${n6(kcr)}))-${n6(key.similarity ?? 0.4)})`;
  return {
    alpha: `255*pow(clip(${base}/${n6(Math.max(key.smoothness ?? 0.08, 1e-4))},0,1),1.5)`,
    spill: `255*pow(clip(${base}/${n6(Math.max(key.spill ?? 0.5, 1e-4))},0,1),1.5)`,
  };
}
/** A mask (model.ts maskAlpha) as 8-bit grey pixels, w × h, over the item's own frame. */
export function maskPixels(m: M.Mask, w: number, h: number): Buffer {
  const out = Buffer.alloc(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) out[y * w + x] = Math.round(255 * M.maskAlpha(m, (x + 0.5) / w, (y + 0.5) / h));
  return out;
}

// ------------------------------------------------------------------ blending
/** model.ts blendChannel as a lut2 expression: x = the item (0–255), y = what is below. */
export function blendExpr(mode: M.BlendMode): string {
  const s = '(x/255)', b = '(y/255)';
  const f = (() => {
    switch (mode) {
      case 'normal': return s;
      case 'multiply': return `${b}*${s}`;
      case 'screen': return `(${b}+${s}-${b}*${s})`;
      case 'overlay': return `if(lte(${b},0.5),2*${b}*${s},1-2*(1-${b})*(1-${s}))`;
      case 'softLight': return `if(lte(${s},0.5),${b}-(1-2*${s})*${b}*(1-${b}),${b}+(2*${s}-1)*(if(lte(${b},0.25),((16*${b}-12)*${b}+4)*${b},sqrt(${b}))-${b}))`;
      case 'darken': return `min(${b},${s})`;
      case 'lighten': return `max(${b},${s})`;
      case 'add': return `min(1,${b}+${s})`;
    }
  })();
  return `clip(255*${f},0,255)`;
}
