// After-effects that image models do badly (plans/templates.md): a colour grade, film grain and a deliberate motion blur
// over the face. They run on the finished still with sharp, after the image engine.
//
// Limitation: there is no face detector yet. The "face box" is the upper-centre of the frame (where a portrait-format
// phone photo's face usually is): x 28–72 %, y 6–40 %. A cheap detector can replace `faceBox()` later.
import sharp from 'sharp';
import type { TemplateAfterEffects } from '../db/schema.js';

export const GRADES = ['none', 'phone-natural', 'underexposed', 'moody-blue', 'golden', 'harsh-sun', 'faded', 'mono'] as const;
export type Grade = (typeof GRADES)[number];

type GradeSpec = { matrix?: number[][]; brightness?: number; saturation?: number; linear?: [number, number]; gamma?: number; grey?: boolean };
const GRADE_SPECS: Record<Grade, GradeSpec> = {
  none: {},
  'phone-natural': { matrix: [[1.02, 0.01, 0], [0, 1.0, 0], [0, 0, 0.98]], saturation: 1.03 },
  underexposed: { brightness: 0.8, saturation: 0.92, linear: [1.04, -6] },
  'moody-blue': { matrix: [[0.82, 0.05, 0.08], [0.02, 0.84, 0.1], [0.08, 0.06, 1.08]], brightness: 0.72, saturation: 0.78, linear: [0.95, 8] },
  golden: { matrix: [[1.1, 0.04, 0], [0.02, 1.02, 0], [0, 0, 0.84]], saturation: 1.08, brightness: 1.03 },
  'harsh-sun': { matrix: [[1.03, 0.01, 0], [0, 1.0, 0], [0, 0, 0.95]], linear: [1.16, -20], saturation: 1.02 },
  faded: { linear: [0.82, 30], saturation: 0.82, matrix: [[1.0, 0.02, 0.02], [0.01, 1.0, 0.02], [0.02, 0.02, 0.98]] },
  mono: { grey: true, linear: [1.08, -8] },
};
export const isGrade = (g: unknown): g is Grade => typeof g === 'string' && (GRADES as readonly string[]).includes(g);

/** The face region (see the limitation above). */
export function faceBox(w: number, h: number) {
  const left = Math.round(w * 0.28), top = Math.round(h * 0.06);
  return { left, top, width: Math.max(8, Math.round(w * 0.44)), height: Math.max(8, Math.round(h * 0.34)) };
}

/** A line kernel of `len` taps at `angle` degrees: convolving with it smears pixels along that direction. */
function lineKernel(len: number, angleDeg: number) {
  const size = len % 2 ? len : len + 1, c = (size - 1) / 2;
  const k = new Array(size * size).fill(0);
  const a = (angleDeg * Math.PI) / 180, dx = Math.cos(a), dy = Math.sin(a);
  for (let i = -c; i <= c; i++) {
    const x = Math.round(c + i * dx), y = Math.round(c + i * dy);
    k[y * size + x] = 1;
  }
  const sum = k.reduce((s, v) => s + v, 0);
  return { width: size, height: size, kernel: k, scale: sum };
}

export const hasEffects = (fx?: TemplateAfterEffects | null) =>
  !!fx && ((fx.faceMotionBlur ?? 0) > 0 || (fx.grain ?? 0) > 0 || (!!fx.grade && fx.grade !== 'none'));

/** Applies the template's after-effects to one image. Returns JPEG bytes. */
export async function applyAfterEffects(input: Buffer, fx: TemplateAfterEffects, o: { maxWidth?: number } = {}): Promise<Buffer> {
  let img = sharp(input, { failOn: 'none' }).rotate();
  if (o.maxWidth) img = img.resize({ width: o.maxWidth, withoutEnlargement: true });
  let buf = await img.removeAlpha().toColourspace('srgb').png().toBuffer();
  const meta = await sharp(buf).metadata();
  const w = meta.width ?? 1, h = meta.height ?? 1;

  // 1. Motion blur on the face box, feathered back into the sharp frame.
  const strength = Math.max(0, Math.min(1, fx.faceMotionBlur ?? 0));
  if (strength > 0) {
    const box = faceBox(w, h);
    const len = Math.max(3, Math.min(61, Math.round(strength * box.width * 0.3)));
    const region = await sharp(buf).extract(box).toBuffer();
    // Pad so the smear doesn't pull in black edges, then crop back.
    const pad = Math.ceil(len / 2) + 1;
    // sharp runs one pipeline in a fixed order, so pad, smear and crop are three steps.
    const padded = await sharp(region).extend({ top: pad, bottom: pad, left: pad, right: pad, extendWith: 'copy' }).png().toBuffer();
    const smeared = await sharp(padded).convolve(lineKernel(len, fx.blurAngle ?? 0)).png().toBuffer();
    const blurred = await sharp(smeared).extract({ left: pad, top: pad, width: box.width, height: box.height }).toBuffer();
    const feather = Math.max(2, Math.round(Math.min(box.width, box.height) * 0.12));
    const mask = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${box.width}" height="${box.height}">` +
      `<defs><filter id="f" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="${feather}"/></filter></defs>` +
      `<ellipse cx="${box.width / 2}" cy="${box.height / 2}" rx="${box.width / 2 - feather * 1.5}" ry="${box.height / 2 - feather * 1.5}" fill="#fff" filter="url(#f)"/></svg>`);
    const alpha = await sharp(mask).resize(box.width, box.height).extractChannel(0).toBuffer();
    const withAlpha = await sharp(blurred).removeAlpha().joinChannel(alpha).png().toBuffer();
    buf = await sharp(buf).composite([{ input: withAlpha, left: box.left, top: box.top }]).png().toBuffer();
  }

  // 2. Colour grade.
  const g = isGrade(fx.grade) ? GRADE_SPECS[fx.grade] : GRADE_SPECS.none;
  if (g !== GRADE_SPECS.none) {
    let s = sharp(buf);
    if (g.grey) s = s.greyscale();
    if (g.matrix) s = s.recomb(g.matrix as [[number, number, number], [number, number, number], [number, number, number]]);
    if (g.brightness || g.saturation) s = s.modulate({ brightness: g.brightness ?? 1, saturation: g.saturation ?? 1 });
    if (g.linear) s = s.linear(g.linear[0], g.linear[1]);
    buf = await s.toColourspace('srgb').png().toBuffer();
  }

  // 3. Grain: gaussian noise blended soft-light.
  const grain = Math.max(0, Math.min(1, fx.grain ?? 0));
  if (grain > 0) {
    const noise = await sharp({ create: { width: w, height: h, channels: 3, background: '#808080', noise: { type: 'gaussian', mean: 128, sigma: 18 + grain * 40 } } })
      .greyscale().toColourspace('srgb').ensureAlpha(Math.min(1, 0.25 + grain * 0.6)).png().toBuffer();
    buf = await sharp(buf).composite([{ input: noise, blend: 'soft-light' }]).png().toBuffer();
  }
  return sharp(buf).jpeg({ quality: 88, mozjpeg: true }).toBuffer();
}
