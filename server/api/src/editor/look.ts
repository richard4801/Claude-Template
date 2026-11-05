// Editor v2 "looks": the filter stack (plans/video-editor.md "Looks"). REFERENCE implementation for the Kotlin and Swift
// ports (fixture test/fixtures/editor/looks.json) and the CPU renderer the server uses for photos. Pure: no I/O.
//
// Per item, on sRGB values 0–1, in this order:
//   1 sharpen (unsharp mask)  2 chromatic aberration  3 colour matrix (adjust + filter, model.ts)  3b highlights/shadows
//   (Adjust, model.ts toneAdjust)  4 tone curves
//   5 3D LUT (trilinear, blended by strength)  6 lift (faded blacks)  7 halation  8 light leak  9 vignette  10 grain
// Steps 1, 2 and 7 look at neighbours (blur radii scale with the picture, so a thumbnail looks like the full frame).

// ------------------------------------------------------------------ types
export type CurvePoint = [number, number];
export type Curves = { rgb?: CurvePoint[]; r?: CurvePoint[]; g?: CurvePoint[]; b?: CurvePoint[] };
export type Grain = { amount: number; size?: number };
export type Vignette = { amount: number; size?: number; softness?: number };
export type Halation = { amount: number; radius?: number; threshold?: number };
export type LeakKind = 'warm' | 'rose' | 'amber' | 'teal' | 'rainbow';
export type Leak = { kind: LeakKind; amount: number; angle?: number };
/** A look: every part optional. `lut` = "pack:<id>" (a bundled look) or the id of a project asset of kind "lut". */
export type Look = { lut?: string; strength?: number; curves?: Curves; lift?: number; sharpen?: number; chromatic?: number;
  halation?: Halation; leak?: Leak; vignette?: Vignette; grain?: Grain };

export type Lut = { size: number; title: string | null; domainMin: [number, number, number]; domainMax: [number, number, number]; data: Float32Array };
export const LOOK_LIMITS = { maxLutSize: 64, minLutSize: 2, maxCubeBytes: 12 * 1024 * 1024, maxCurvePoints: 16 } as const;
export const LEAKS: LeakKind[] = ['warm', 'rose', 'amber', 'teal', 'rainbow'];

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const c01 = (v: number) => clamp(v, 0, 1);
const smoothstep = (a: number, b: number, x: number) => { const t = c01((x - a) / (b - a)); return t * t * (3 - 2 * t); };
const LUMA = [0.2126, 0.7152, 0.0722];

// ------------------------------------------------------------------ .cube
export class CubeError extends Error {}
/** Parses an Adobe/Resolve .cube 3D LUT (red changes fastest). Throws CubeError with the line on anything invalid. */
export function parseCube(text: string): Lut {
  if (text.length > LOOK_LIMITS.maxCubeBytes) throw new CubeError(`the file is over ${LOOK_LIMITS.maxCubeBytes / 1024 / 1024} MB`);
  let size = 0, title: string | null = null;
  let dmin: [number, number, number] = [0, 0, 0], dmax: [number, number, number] = [1, 1, 1];
  let data: Float32Array | null = null, n = 0;
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!.replace(/#.*$/, '').trim();
    if (!line) continue;
    const at = `line ${i + 1}`;
    if (/^[A-Za-z_]/.test(line)) {
      const [key, ...rest] = line.split(/\s+/);
      const k = key!.toUpperCase();
      if (k === 'TITLE') title = line.slice(5).trim().replace(/^"|"$/g, '').slice(0, 120);
      else if (k === 'LUT_3D_SIZE') {
        size = Number(rest[0]);
        if (!Number.isInteger(size) || size < LOOK_LIMITS.minLutSize || size > LOOK_LIMITS.maxLutSize) throw new CubeError(`${at}: LUT_3D_SIZE must be ${LOOK_LIMITS.minLutSize}–${LOOK_LIMITS.maxLutSize}`);
        data = new Float32Array(size * size * size * 3);
      } else if (k === 'LUT_1D_SIZE') throw new CubeError(`${at}: 1D LUTs are not supported, use a 3D .cube`);
      else if (k === 'DOMAIN_MIN' || k === 'DOMAIN_MAX') {
        const v = rest.map(Number);
        if (v.length !== 3 || v.some(x => !Number.isFinite(x))) throw new CubeError(`${at}: ${k} needs three numbers`);
        if (k === 'DOMAIN_MIN') dmin = v as [number, number, number]; else dmax = v as [number, number, number];
      } else if (k === 'LUT_3D_INPUT_RANGE') {
        const v = rest.map(Number);
        if (v.length !== 2 || v.some(x => !Number.isFinite(x))) throw new CubeError(`${at}: LUT_3D_INPUT_RANGE needs two numbers`);
        dmin = [v[0]!, v[0]!, v[0]!]; dmax = [v[1]!, v[1]!, v[1]!];
      } // other keywords are ignored
      continue;
    }
    if (!data) throw new CubeError(`${at}: numbers before LUT_3D_SIZE`);
    const v = line.split(/\s+/).map(Number);
    if (v.length !== 3 || v.some(x => !Number.isFinite(x))) throw new CubeError(`${at}: expected three numbers`);
    if (n >= size * size * size) throw new CubeError(`${at}: more than ${size}³ entries`);
    data[n * 3] = v[0]!; data[n * 3 + 1] = v[1]!; data[n * 3 + 2] = v[2]!;
    n++;
  }
  if (!data) throw new CubeError('no LUT_3D_SIZE line');
  if (n !== size * size * size) throw new CubeError(`expected ${size}³ = ${size * size * size} entries, found ${n}`);
  for (let c = 0; c < 3; c++) if (!(dmax[c]! > dmin[c]!)) throw new CubeError('DOMAIN_MAX must be above DOMAIN_MIN');
  return { size, title, domainMin: dmin, domainMax: dmax, data };
}

/** Writes a .cube (4 decimals, red fastest). */
export function writeCube(size: number, title: string, fn: (r: number, g: number, b: number) => [number, number, number]): string {
  const out: string[] = [`TITLE "${title}"`, `LUT_3D_SIZE ${size}`, 'DOMAIN_MIN 0.0 0.0 0.0', 'DOMAIN_MAX 1.0 1.0 1.0'];
  const f = (v: number) => c01(v).toFixed(4);
  for (let b = 0; b < size; b++) for (let g = 0; g < size; g++) for (let r = 0; r < size; r++) {
    const o = fn(r / (size - 1), g / (size - 1), b / (size - 1));
    out.push(`${f(o[0])} ${f(o[1])} ${f(o[2])}`);
  }
  return out.join('\n') + '\n';
}

/** Trilinear lookup. */
export function lutSample(l: Lut, r: number, g: number, b: number): [number, number, number] {
  const N = l.size, m = N - 1;
  const pos = (v: number, c: number) => c01((v - l.domainMin[c]!) / (l.domainMax[c]! - l.domainMin[c]!)) * m;
  const fr = pos(r, 0), fg = pos(g, 1), fb = pos(b, 2);
  const r0 = Math.floor(fr), g0 = Math.floor(fg), b0 = Math.floor(fb);
  const r1 = Math.min(m, r0 + 1), g1 = Math.min(m, g0 + 1), b1 = Math.min(m, b0 + 1);
  const dr = fr - r0, dg = fg - g0, db = fb - b0;
  const out: [number, number, number] = [0, 0, 0];
  const at = (ri: number, gi: number, bi: number, c: number) => l.data[((bi * N + gi) * N + ri) * 3 + c]!;
  for (let c = 0; c < 3; c++) {
    const c00 = at(r0, g0, b0, c) * (1 - dr) + at(r1, g0, b0, c) * dr;
    const c10 = at(r0, g1, b0, c) * (1 - dr) + at(r1, g1, b0, c) * dr;
    const c01v = at(r0, g0, b1, c) * (1 - dr) + at(r1, g0, b1, c) * dr;
    const c11 = at(r0, g1, b1, c) * (1 - dr) + at(r1, g1, b1, c) * dr;
    out[c] = (c00 * (1 - dg) + c10 * dg) * (1 - db) + (c01v * (1 - dg) + c11 * dg) * db;
  }
  return out;
}

// ------------------------------------------------------------------ curves
/**
 * A tone curve through points (x ascending, both 0–1) with monotone cubic (Fritsch–Carlson) interpolation; flat
 * beyond the end points. Returned as a 256-entry table plus the exact function.
 */
export function curveFn(pts: CurvePoint[] | undefined): ((x: number) => number) | null {
  if (!pts || pts.length < 2) return null;
  const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]), n = pts.length;
  const d: number[] = [], m: number[] = new Array(n).fill(0);
  for (let i = 0; i < n - 1; i++) d.push((ys[i + 1]! - ys[i]!) / (xs[i + 1]! - xs[i]!));
  m[0] = d[0]!; m[n - 1] = d[n - 2]!;
  for (let i = 1; i < n - 1; i++) m[i] = d[i - 1]! * d[i]! <= 0 ? 0 : (d[i - 1]! + d[i]!) / 2;
  for (let i = 0; i < n - 1; i++) {
    if (d[i] === 0) { m[i] = 0; m[i + 1] = 0; continue; }
    const a = m[i]! / d[i]!, b = m[i + 1]! / d[i]!, s = a * a + b * b;
    if (s > 9) { const t = 3 / Math.sqrt(s); m[i] = t * a * d[i]!; m[i + 1] = t * b * d[i]!; }
  }
  return (x: number) => {
    if (x <= xs[0]!) return ys[0]!;
    if (x >= xs[n - 1]!) return ys[n - 1]!;
    let k = 0;
    while (k < n - 2 && x > xs[k + 1]!) k++;
    const h = xs[k + 1]! - xs[k]!, t = (x - xs[k]!) / h, t2 = t * t, t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * ys[k]! + (t3 - 2 * t2 + t) * h * m[k]! + (-2 * t3 + 3 * t2) * ys[k + 1]! + (t3 - t2) * h * m[k + 1]!;
  };
}
/** The four curves applied together (master, then the channel's own). */
export function curvesFn(c: Curves | undefined): ((rgb: [number, number, number]) => [number, number, number]) | null {
  if (!c) return null;
  const m = curveFn(c.rgb), ch = [curveFn(c.r), curveFn(c.g), curveFn(c.b)];
  if (!m && !ch.some(Boolean)) return null;
  return rgb => rgb.map((v, i) => { let o = m ? m(v) : v; const f = ch[i]; if (f) o = f(o); return c01(o); }) as [number, number, number];
}

// ------------------------------------------------------------------ noise, vignette, leak
/** 32-bit integer hash (lowbias32) → 0…1. Same bits in Kotlin (Int) and Swift (UInt32). */
export function hash01(x: number, y: number, frame: number): number {
  let h = (Math.imul(x | 0, 0x27d4eb2d) ^ Math.imul(y | 0, 0x165667b1) ^ Math.imul(frame | 0, 0x9e3779b9)) >>> 0;
  h ^= h >>> 16; h = Math.imul(h, 0x7feb352d) >>> 0;
  h ^= h >>> 15; h = Math.imul(h, 0x846ca68b) >>> 0;
  h ^= h >>> 16;
  return (h >>> 0) / 4294967295;
}
/** Vignette multiplier/lift amount at u, v (0–1): m = smoothstep(size, size + softness, r), r = 1 at the corners. */
export function vignetteMask(v: Vignette, u: number, w: number): number {
  const dx = (u - 0.5) * 2, dy = (w - 0.5) * 2, r = Math.sqrt(dx * dx + dy * dy) / Math.SQRT2;
  const size = clamp(v.size ?? 0.45, 0, 1), soft = Math.max(0.05, clamp(v.softness ?? 0.5, 0, 1));
  return smoothstep(size, size + soft, r);
}
const LEAK_COLORS: Record<LeakKind, [number, number, number][]> = {
  warm: [[1, 0.55, 0.2], [1, 0.8, 0.45]], rose: [[1, 0.35, 0.45], [1, 0.7, 0.6]], amber: [[1, 0.65, 0.1], [1, 0.9, 0.5]],
  teal: [[0.2, 0.85, 0.85], [0.6, 0.95, 1]], rainbow: [[1, 0.3, 0.3], [0.4, 0.6, 1]],
};
/** Light-leak colour (to screen over the picture) at u, v and time t seconds: a soft blob from one edge that drifts. */
export function leakColor(l: Leak, u: number, v: number, t: number): [number, number, number] {
  const a = ((l.angle ?? 30) * Math.PI) / 180 + 0.25 * Math.sin(t * 0.6);
  const cx = 0.5 + 0.75 * Math.cos(a), cy = 0.5 - 0.75 * Math.sin(a);
  const d = Math.sqrt((u - cx) ** 2 + (v - cy) ** 2);
  const k = clamp(l.amount, 0, 1) * (1 - smoothstep(0.15, 0.95, d));
  const [c0, c1] = LEAK_COLORS[l.kind];
  const mix = smoothstep(0.1, 0.8, d);
  return [0, 1, 2].map(i => k * (c0[i]! * (1 - mix) + c1[i]! * mix)) as [number, number, number];
}

// ------------------------------------------------------------------ CPU renderer
export type Image = { width: number; height: number; data: Float32Array /* rgb, row-major, 0–1 */ };
const px = (img: Image, x: number, y: number, c: number) =>
  img.data[(clamp(y, 0, img.height - 1) * img.width + clamp(x, 0, img.width - 1)) * 3 + c]!;
/** Box blur, separable, clamp to edge, radius in pixels (≥ 1). */
export function boxBlur(img: Image, radius: number): Image {
  const { width: w, height: h } = img, R = Math.max(1, Math.round(radius)), n = 2 * R + 1;
  const tmp = new Float32Array(w * h * 3), out = new Float32Array(w * h * 3);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let c = 0; c < 3; c++) {
    let s = 0; for (let k = -R; k <= R; k++) s += px(img, x + k, y, c);
    tmp[(y * w + x) * 3 + c] = s / n;
  }
  const t: Image = { width: w, height: h, data: tmp };
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let c = 0; c < 3; c++) {
    let s = 0; for (let k = -R; k <= R; k++) s += px(t, x, y + k, c);
    out[(y * w + x) * 3 + c] = s / n;
  }
  return { width: w, height: h, data: out };
}
function bilinear(img: Image, fx: number, fy: number, c: number) {
  const x0 = Math.floor(fx), y0 = Math.floor(fy), dx = fx - x0, dy = fy - y0;
  return (px(img, x0, y0, c) * (1 - dx) + px(img, x0 + 1, y0, c) * dx) * (1 - dy) + (px(img, x0, y0 + 1, c) * (1 - dx) + px(img, x0 + 1, y0 + 1, c) * dx) * dy;
}
/** Pixel radii for the spatial steps, from the picture's short side (so they scale with resolution). */
export const sharpenRadius = (short: number) => Math.max(1, Math.round(short * 0.0015));
export const halationRadius = (short: number, h: Halation) => Math.max(1, Math.round(short * 0.04 * clamp(h.radius ?? 0.5, 0.05, 1)));
export const grainCell = (short: number, g: Grain) => Math.max(1, Math.round((short / 1080) * clamp(g.size ?? 1, 0.5, 3)));

/**
 * Renders a look on an image. `matrix` = the item's colour matrix (model.ts colorMatrix, 3×4) or null; `lut` = the
 * resolved LUT or null; `frame`/`fps` animate the grain and leak.
 */
export function renderLook(img: Image, look: Look, o: { matrix?: number[] | null; tone?: { shadows?: number; highlights?: number } | null; lut?: Lut | null; frame?: number; fps?: number } = {}): Image {
  const { width: w, height: h } = img, short = Math.min(w, h);
  let src = img;
  // 1. sharpen
  const sh = clamp(look.sharpen ?? 0, 0, 1);
  if (sh > 0) {
    const bl = boxBlur(src, sharpenRadius(short)), d = new Float32Array(src.data.length);
    for (let i = 0; i < d.length; i++) d[i] = c01(src.data[i]! + 1.5 * sh * (src.data[i]! - bl.data[i]!));
    src = { width: w, height: h, data: d };
  }
  // 2. chromatic aberration (red out, blue in, from the centre)
  const ca = clamp(look.chromatic ?? 0, 0, 1) * 0.006;
  const curves = curvesFn(look.curves);
  const strength = clamp(look.strength ?? 1, 0, 1);
  const lift = 0.12 * clamp(look.lift ?? 0, 0, 1);
  const M = o.matrix ?? null, L = o.lut ?? null, sh0 = o.tone?.shadows ?? 0, hi0 = o.tone?.highlights ?? 0;
  const out = new Float32Array(w * h * 3);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let rgb: [number, number, number];
    if (ca > 0) {
      const u = (x + 0.5) / w - 0.5, v = (y + 0.5) / h - 0.5;
      rgb = [bilinear(src, x + u * ca * w, y + v * ca * h, 0), px(src, x, y, 1), bilinear(src, x - u * ca * w, y - v * ca * h, 2)];
    } else rgb = [px(src, x, y, 0), px(src, x, y, 1), px(src, x, y, 2)];
    // 3. colour matrix
    if (M) rgb = [0, 1, 2].map(i => c01(M[i * 4]! * rgb[0] + M[i * 4 + 1]! * rgb[1] + M[i * 4 + 2]! * rgb[2] + M[i * 4 + 3]!)) as [number, number, number];
    // 3b. highlights / shadows (Adjust)
    if (sh0 || hi0) rgb = rgb.map(v => c01(v + 0.25 * (sh0 * 4 * v * (1 - v) * (1 - v) + hi0 * 4 * v * v * (1 - v)))) as [number, number, number];
    // 4. curves
    if (curves) rgb = curves(rgb);
    // 5. LUT
    if (L && strength > 0) { const t = lutSample(L, rgb[0], rgb[1], rgb[2]); rgb = [0, 1, 2].map(i => c01(rgb[i]! + (t[i]! - rgb[i]!) * strength)) as [number, number, number]; }
    // 6. lift
    if (lift > 0) rgb = rgb.map(v => lift + v * (1 - lift)) as [number, number, number];
    out.set(rgb, (y * w + x) * 3);
  }
  let res: Image = { width: w, height: h, data: out };
  // 7. halation: blurred highlights, warm red, screened on
  const ha = look.halation;
  if (ha && ha.amount > 0) {
    const thr = clamp(ha.threshold ?? 0.7, 0, 0.99), bl = boxBlur(res, halationRadius(short, ha)), k = clamp(ha.amount, 0, 1);
    const tint = [1, 0.35, 0.2];
    for (let i = 0; i < w * h; i++) {
      const l = LUMA[0]! * bl.data[i * 3]! + LUMA[1]! * bl.data[i * 3 + 1]! + LUMA[2]! * bl.data[i * 3 + 2]!;
      const hgl = c01((l - thr) / (1 - thr)) * k;
      for (let c = 0; c < 3; c++) out[i * 3 + c] = 1 - (1 - out[i * 3 + c]!) * (1 - tint[c]! * hgl);
    }
    res = { width: w, height: h, data: out };
  }
  const t = (o.frame ?? 0) / (o.fps ?? 30);
  const vg = look.vignette && look.vignette.amount !== 0 ? look.vignette : null;
  const gr = look.grain && look.grain.amount > 0 ? look.grain : null;
  const lk = look.leak && look.leak.amount > 0 ? look.leak : null;
  if (vg || gr || lk) {
    const cell = gr ? grainCell(short, gr) : 1, ga = gr ? clamp(gr.amount, 0, 1) * 0.18 : 0, va = vg ? clamp(vg.amount, -1, 1) : 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 3, u = (x + 0.5) / w, v = (y + 0.5) / h;
      // 8. light leak (screen)
      if (lk) { const c = leakColor(lk, u, v, t); for (let k = 0; k < 3; k++) out[i + k] = 1 - (1 - out[i + k]!) * (1 - c[k]!); }
      // 9. vignette
      if (vg) {
        const m = vignetteMask(vg, u, v);
        for (let k = 0; k < 3; k++) out[i + k] = va > 0 ? out[i + k]! * (1 - va * m) : out[i + k]! + -va * m * (1 - out[i + k]!);
      }
      // 10. grain: mono, strongest in the mid-tones, cells of `cell` px, a new pattern every frame
      if (gr) {
        const n = hash01(Math.floor(x / cell), Math.floor(y / cell), o.frame ?? 0) - 0.5;
        const l = LUMA[0]! * out[i]! + LUMA[1]! * out[i + 1]! + LUMA[2]! * out[i + 2]!;
        const g = ga * n * (1 - Math.abs(2 * l - 1) * 0.5);
        for (let k = 0; k < 3; k++) out[i + k] = out[i + k]! + g;
      }
      for (let k = 0; k < 3; k++) out[i + k] = c01(out[i + k]!);
    }
  }
  return res;
}

// ------------------------------------------------------------------ validation (called by model.ts validate)
export function lookProblem(look: unknown, assetKinds: Map<string, string>, packIds: Set<string>): { field: string; message: string } | null {
  if (look === undefined) return null;
  if (!look || typeof look !== 'object' || Array.isArray(look)) return { field: '', message: 'must be an object' };
  const l = look as Look;
  const num = (f: string, v: unknown, lo: number, hi: number, opt = true) =>
    (v === undefined && opt) ? null : (typeof v !== 'number' || !Number.isFinite(v) || v < lo || v > hi) ? { field: f, message: `must be a number from ${lo} to ${hi}` } : null;
  if (l.lut !== undefined) {
    if (typeof l.lut !== 'string') return { field: 'lut', message: 'must be "pack:<id>" or a lut asset id' };
    if (l.lut.startsWith('pack:')) { if (packIds.size && !packIds.has(l.lut.slice(5))) return { field: 'lut', message: 'unknown look' }; }
    else if (assetKinds.get(l.lut) !== 'lut') return { field: 'lut', message: 'must be "pack:<id>" or a lut asset id' };
  }
  const simple = num('strength', l.strength, 0, 1) ?? num('lift', l.lift, 0, 1) ?? num('sharpen', l.sharpen, 0, 1) ?? num('chromatic', l.chromatic, 0, 1);
  if (simple) return simple;
  if (l.curves !== undefined) {
    if (!l.curves || typeof l.curves !== 'object') return { field: 'curves', message: 'must be an object' };
    for (const [k, pts] of Object.entries(l.curves)) {
      if (!['rgb', 'r', 'g', 'b'].includes(k)) return { field: `curves.${k}`, message: 'unknown curve' };
      if (!Array.isArray(pts) || pts.length < 2 || pts.length > LOOK_LIMITS.maxCurvePoints) return { field: `curves.${k}`, message: `2–${LOOK_LIMITS.maxCurvePoints} points` };
      let prev = -1;
      for (let i = 0; i < pts.length; i++) {
        const p = pts[i];
        if (!Array.isArray(p) || p.length !== 2 || p.some(v => typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > 1)) return { field: `curves.${k}.${i}`, message: 'must be [x, y], each 0–1' };
        if (p[0]! <= prev) return { field: `curves.${k}.${i}`, message: 'x must increase' };
        prev = p[0]!;
      }
    }
  }
  const obj = (f: string, v: unknown, checks: [string, number, number, boolean][]) => {
    if (v === undefined) return null;
    if (!v || typeof v !== 'object') return { field: f, message: 'must be an object' };
    for (const [k, lo, hi, req] of checks) { const p = num(`${f}.${k}`, (v as Record<string, unknown>)[k], lo, hi, !req); if (p) return p; }
    return null;
  };
  const o = obj('grain', l.grain, [['amount', 0, 1, true], ['size', 0.5, 3, false]])
    ?? obj('vignette', l.vignette, [['amount', -1, 1, true], ['size', 0, 1, false], ['softness', 0, 1, false]])
    ?? obj('halation', l.halation, [['amount', 0, 1, true], ['radius', 0.05, 1, false], ['threshold', 0, 0.99, false]])
    ?? obj('leak', l.leak, [['amount', 0, 1, true], ['angle', -360, 360, false]]);
  if (o) return o;
  if (l.leak !== undefined && !LEAKS.includes(l.leak.kind)) return { field: 'leak.kind', message: `one of ${LEAKS.join(', ')}` };
  const known = new Set(['lut', 'strength', 'curves', 'lift', 'sharpen', 'chromatic', 'halation', 'leak', 'vignette', 'grain']);
  const extra = Object.keys(l).find(k => !known.has(k));
  if (extra) return { field: extra, message: 'is not a look setting' };
  return null;
}
