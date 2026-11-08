// Recreate this edit · what the reference looks like (workstream 1, plans/recreate-edit.md "Analysis"): keyframes, the
// grade (five swatches → the Suite's palette→LUT path, plus the nearest existing palette) and the labelled contact
// sheet Claude reads to write each slot's brief. Free: ffmpeg and sharp on the server.
import { execFile } from 'node:child_process';
import sharp from 'sharp';
import { SWATCHES, swatchGrade } from '../suite/looks.js';
import { PALETTES } from '../suite/camera.js';

export type Rgb = { t: number; width: number; height: number; rgb: Uint8Array };

/** One RGB frame at `t` seconds, `width` px wide (a fast seek; analysis only, nothing is stored). */
export function grabFrame(ffmpeg: string, input: string, t: number, width: number, height: number): Promise<Rgb> {
  return new Promise((resolve, reject) => {
    execFile(ffmpeg, ['-v', 'error', '-ss', Math.max(0, t).toFixed(3), '-i', input, '-frames:v', '1', '-vf', `scale=${width}:${height}:flags=area`,
      '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], { encoding: 'buffer', timeout: 60_000, maxBuffer: width * height * 3 + 1024 }, (err, out) => {
      if (err) return reject(new Error(`ffmpeg failed: ${err.message.slice(0, 200)}`));
      const b = out as Buffer;
      if (b.length < width * height * 3) return reject(new Error(`no frame at ${t.toFixed(2)} s`));
      resolve({ t, width, height, rgb: new Uint8Array(b.buffer, b.byteOffset, width * height * 3) });
    });
  });
}

const hex = (c: number[]) => `#${c.map(v => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('').toUpperCase()}`;
const luma = (c: number[]) => 0.2126 * c[0]! + 0.7152 * c[1]! + 0.0722 * c[2]!;

/** Five dominant colours over the frames (k-means on a sample of pixels), darkest first. */
export function swatchesOf(frames: Rgb[], k = 5): string[] {
  const px: number[][] = [];
  for (const f of frames) {
    const n = f.width * f.height, stride = Math.max(1, Math.floor(n / 1500));
    for (let i = 0; i < n; i += stride) px.push([f.rgb[i * 3]!, f.rgb[i * 3 + 1]!, f.rgb[i * 3 + 2]!]);
  }
  if (!px.length) return [];
  // Seeds spread over brightness, so the result is stable run to run.
  const byL = [...px].sort((a, b) => luma(a) - luma(b));
  let cent = Array.from({ length: k }, (_, j) => [...byL[Math.min(byL.length - 1, Math.floor((j + 0.5) / k * byL.length))]!]);
  for (let it = 0; it < 12; it++) {
    const sum = cent.map(() => [0, 0, 0, 0]);
    for (const p of px) {
      let bi = 0, bd = Infinity;
      for (let j = 0; j < k; j++) { const c = cent[j]!; const d = (p[0]! - c[0]!) ** 2 + (p[1]! - c[1]!) ** 2 + (p[2]! - c[2]!) ** 2; if (d < bd) { bd = d; bi = j; } }
      const s = sum[bi]!; s[0]! += p[0]!; s[1]! += p[1]!; s[2]! += p[2]!; s[3]! += 1;
    }
    cent = cent.map((c, j) => (sum[j]![3]! ? [sum[j]![0]! / sum[j]![3]!, sum[j]![1]! / sum[j]![3]!, sum[j]![2]! / sum[j]![3]!] : c));
  }
  return cent.sort((a, b) => luma(a) - luma(b)).map(hex);
}

const rgbOf = (h: string) => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));

/** How far two five-swatch palettes are (each swatch to the other palette's nearest, both ways; 0 = the same, ~1 = far). */
export function paletteDistance(a: readonly string[], b: readonly string[]) {
  const d = (x: number[], y: number[]) => Math.hypot(x[0]! - y[0]!, x[1]! - y[1]!, x[2]! - y[2]!) / 441.7;
  const one = (p: readonly string[], q: readonly string[]) => p.reduce((s, h) => s + Math.min(...q.map(g => d(rgbOf(h), rgbOf(g)))), 0) / p.length;
  return Math.round(((one(a, b) + one(b, a)) / 2) * 1000) / 1000;
}

export type GradeInfo = {
  swatches: string[]; contrast: number; saturation: number; warmth: number;
  /** The nearest of the Suite's palettes (its Look and LUT exist), with how far it is. */
  look: { id: string; kind: 'palette'; label: string; distance: number } | null;
  /** The reference's own grade, from its swatches (suite/looks.ts swatchGrade → the look pack's grade function). */
  grade: ReturnType<typeof swatchGrade> | null;
  confidence: number;
};

export function gradeOf(frames: Rgb[]): GradeInfo {
  const swatches = swatchesOf(frames);
  if (!swatches.length) return { swatches: [], contrast: 0, saturation: 0, warmth: 0, look: null, grade: null, confidence: 0 };
  let ls: number[] = [], sat = 0, warm = 0, n = 0;
  for (const f of frames) {
    const N = f.width * f.height, stride = Math.max(1, Math.floor(N / 2000));
    for (let i = 0; i < N; i += stride) {
      const r = f.rgb[i * 3]! / 255, g = f.rgb[i * 3 + 1]! / 255, b = f.rgb[i * 3 + 2]! / 255;
      const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
      ls.push(0.2126 * r + 0.7152 * g + 0.0722 * b); sat += mx > 0 ? (mx - mn) / mx : 0; warm += r - b; n++;
    }
  }
  const mean = ls.reduce((a, b) => a + b, 0) / n;
  const sd = Math.sqrt(ls.reduce((a, b) => a + (b - mean) ** 2, 0) / n);
  ls = [];
  let look: GradeInfo['look'] = null;
  for (const p of PALETTES) {
    const sw = SWATCHES[p.id];
    if (!sw || p.mergedInto) continue;
    const distance = paletteDistance(swatches, sw);
    if (!look || distance < look.distance) look = { id: p.id, kind: 'palette', label: p.label, distance };
  }
  const r2 = (x: number) => Math.round(x * 100) / 100;
  return {
    swatches, contrast: r2(Math.min(1, sd / 0.3)), saturation: r2(sat / n), warmth: r2(Math.max(-1, Math.min(1, (warm / n) * 3))),
    look, grade: swatchGrade(swatches), confidence: frames.length >= 3 ? 0.8 : 0.6,
  };
}

/** The contact sheet: each slot's keyframe, labelled "1 · 0.0–1.4 s", in rows of `cols`, for Claude's shot briefs. */
export const SHEET_COLS = 5, SHEET_LABEL_PX = 18;
/** Where each frame's picture sits in the contact sheet (without its label), for cropping one slot's thumbnail. */
export const sheetTiles = (n: number, w: number, h: number, cols = SHEET_COLS) =>
  Array.from({ length: n }, (_, i) => ({ x: (i % cols) * w, y: Math.floor(i / cols) * (h + SHEET_LABEL_PX), w, h }));
export async function contactSheet(frames: Rgb[], labels: string[], cols = SHEET_COLS): Promise<Buffer> {
  if (!frames.length) throw new Error('no frames');
  const tw = frames[0]!.width, th = frames[0]!.height, lab = SHEET_LABEL_PX;
  const tiles = await Promise.all(frames.map(async (f, i) => {
    const label = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${tw}" height="${lab}"><rect width="100%" height="100%" fill="#111"/><text x="4" y="13" font-size="12" fill="#fff" font-family="DejaVu Sans Mono, monospace">${escapeXml(labels[i] ?? '')}</text></svg>`);
    const img = sharp(Buffer.from(f.rgb), { raw: { width: f.width, height: f.height, channels: 3 } }).resize(tw, th, { fit: 'fill' });
    return { input: await img.extend({ bottom: lab, background: '#111111' }).composite([{ input: label, top: th, left: 0 }]).png().toBuffer(), left: (i % cols) * tw, top: Math.floor(i / cols) * (th + lab) };
  }));
  const rows = Math.ceil(frames.length / cols);
  return sharp({ create: { width: tw * Math.min(cols, frames.length), height: rows * (th + lab), channels: 3, background: '#111111' } }).composite(tiles).png().toBuffer();
}

const escapeXml = (s: string) => s.replace(/[<>&'"]/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' }[c]!));
