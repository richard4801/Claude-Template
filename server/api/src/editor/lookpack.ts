// MUSE's own look pack (plans/video-editor.md "Looks"): ~30 original grades, tuned to keep skin natural, baked into
// 17³ .cube files by scripts/editor-looks.ts (server/api/assets/lookpack/looks/). Nothing here is copied from another
// product's LUTs: every look is the parametric `grade()` below with the numbers in LOOKS.
import { curveFn, type CurvePoint, type Look } from './look.js';
import { hexRgb as hexToRgb } from './model.js';

export type Grade = {
  exposure?: number; temp?: number; tint?: number; contrast?: number; sat?: number; vibrance?: number;
  /** 0–1: how much skin hues are kept out of saturation and hue changes (default 0.7). */
  skin?: number;
  shadows?: [string, number]; highlights?: [string, number];
  hue?: { center: number; width: number; shift: number; sat?: number }[];
  fade?: number; roll?: number; curve?: CurvePoint[];
  mono?: [number, number, number]; monoTone?: [string, number];
};
export type LookCategory = 'natural' | 'film' | 'moody' | 'warm' | 'cool' | 'bw' | 'vintage' | 'cinematic';
export type PackLook = { id: string; name: string; category: LookCategory; grade: Grade; effects?: Omit<Look, 'lut' | 'strength'> };
export const CUBE_SIZE = 17;

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const smooth = (a: number, b: number, x: number) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
const luma = (r: number, g: number, b: number) => 0.2126 * r + 0.7152 * g + 0.0722 * b;

function rgbToHsv(r: number, g: number, b: number): [number, number, number] {
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
  let h = 0;
  if (d > 1e-9) h = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [(h * 60 + 360) % 360, mx > 0 ? d / mx : 0, mx];
}
function hsvToRgb(h: number, s: number, v: number): [number, number, number] {
  const c = v * s, x = c * (1 - Math.abs(((h / 60) % 2) - 1)), m = v - c;
  const [r, g, b] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return [r + m, g + m, b + m];
}
const hueDist = (a: number, b: number) => { const d = Math.abs(a - b) % 360; return d > 180 ? 360 - d : d; };

/** How skin-like a colour is: hue near 25° (orange-red), moderate saturation, not too dark. 0–1. */
export function skinWeight(h: number, s: number, v: number) {
  return (1 - smooth(18, 40, hueDist(h, 25))) * smooth(0.08, 0.2, s) * (1 - smooth(0.65, 0.85, s)) * smooth(0.15, 0.35, v);
}

/** The grade as a colour function (what the .cube stores). */
export function grade(gr: Grade): (r: number, g: number, b: number) => [number, number, number] {
  const curve = curveFn(gr.curve);
  const sh = gr.shadows ? hexToRgb(gr.shadows[0]) : null, hi = gr.highlights ? hexToRgb(gr.highlights[0]) : null, mt = gr.monoTone ? hexToRgb(gr.monoTone[0]) : null;
  const centred = (c: [number, number, number]) => { const m = (c[0] + c[1] + c[2]) / 3; return [c[0] - m, c[1] - m, c[2] - m]; };
  const shC = sh ? centred(sh) : null, hiC = hi ? centred(hi) : null, mtC = mt ? centred(mt) : null;
  const protect = clamp(gr.skin ?? 0.7, 0, 1);
  return (r0, g0, b0) => {
    const ex = Math.pow(2, gr.exposure ?? 0);
    let r = r0 * ex * (1 + 0.08 * (gr.temp ?? 0)), g = g0 * ex * (1 - 0.06 * (gr.tint ?? 0)), b = b0 * ex * (1 - 0.08 * (gr.temp ?? 0));
    if (gr.mono) { const l = gr.mono[0] * r + gr.mono[1] * g + gr.mono[2] * b; r = g = b = l; }
    else {
      let [h, s, v] = rgbToHsv(clamp(r, 0, 4), clamp(g, 0, 4), clamp(b, 0, 4));
      const keep = 1 - protect * skinWeight(h, s, Math.min(1, v));
      for (const x of gr.hue ?? []) {
        const w = 1 - smooth(x.width * 0.5, x.width, hueDist(h, x.center));
        h = (h + x.shift * w * keep + 360) % 360;
        if (x.sat !== undefined) s *= 1 + x.sat * w * keep;
      }
      s *= 1 + (gr.sat ?? 0) * keep;
      s += (gr.vibrance ?? 0) * keep * s * (1 - s);
      [r, g, b] = hsvToRgb(h, clamp(s, 0, 1), v);
    }
    const c = gr.contrast ?? 0;
    const sc = (x: number) => { x = clamp(x, 0, 1); return x + c * (smooth(0, 1, x) - x); };
    r = sc(r); g = sc(g); b = sc(b);
    const L = luma(r, g, b);
    if (shC) { const w = (1 - L) ** 2 * gr.shadows![1]; r += shC[0]! * w; g += shC[1]! * w; b += shC[2]! * w; }
    if (hiC) { const w = L ** 2 * gr.highlights![1]; r += hiC[0]! * w; g += hiC[1]! * w; b += hiC[2]! * w; }
    if (mtC) { const w = gr.monoTone![1]; r += mtC[0]! * w; g += mtC[1]! * w; b += mtC[2]! * w; }
    if (curve) { r = curve(clamp(r, 0, 1)); g = curve(clamp(g, 0, 1)); b = curve(clamp(b, 0, 1)); }
    const roll = gr.roll ?? 0;
    const ro = (x: number) => x - roll * 0.35 * smooth(0.55, 1, x) * (x - 0.55);
    const f = gr.fade ?? 0;
    return [r, g, b].map(x => clamp(f + ro(clamp(x, 0, 1)) * (1 - f), 0, 1)) as [number, number, number];
  };
}

const FILM_GRAIN = { amount: 0.22, size: 1.2 };
/** The pack. Ids are stable (projects store "pack:<id>"). */
export const LOOKS: PackLook[] = [
  // UGC-natural: phone footage, cleaner and a touch warmer, skin first
  { id: 'natural-clean', name: 'Clean', category: 'natural', grade: { contrast: 0.12, vibrance: 0.25, temp: 0.08, roll: 0.3 } },
  { id: 'natural-glow', name: 'Glow', category: 'natural', grade: { exposure: 0.08, contrast: 0.05, vibrance: 0.2, temp: 0.15, roll: 0.5, highlights: ['#FFE2C6', 0.12] }, effects: { halation: { amount: 0.15, radius: 0.6, threshold: 0.75 } } },
  { id: 'natural-soft', name: 'Soft', category: 'natural', grade: { contrast: -0.12, sat: -0.05, fade: 0.03, temp: 0.06, roll: 0.4 } },
  { id: 'natural-pop', name: 'Pop', category: 'natural', grade: { contrast: 0.22, vibrance: 0.4, sat: 0.08, roll: 0.3 }, effects: { sharpen: 0.25 } },
  { id: 'natural-bright', name: 'Bright', category: 'natural', grade: { exposure: 0.18, contrast: 0.06, vibrance: 0.15, fade: 0.02, roll: 0.6 } },
  // Film emulation (generic stocks, our own numbers)
  { id: 'film-gold', name: 'Gold 200', category: 'film', grade: { temp: 0.3, contrast: 0.15, sat: 0.05, shadows: ['#3A4A5A', 0.08], highlights: ['#FFD9A0', 0.14], fade: 0.035, roll: 0.5, hue: [{ center: 110, width: 50, shift: -12, sat: -0.15 }] }, effects: { grain: FILM_GRAIN, halation: { amount: 0.12 } } },
  { id: 'film-pastel', name: 'Pastel 400', category: 'film', grade: { exposure: 0.1, contrast: -0.08, sat: -0.12, temp: 0.12, fade: 0.06, highlights: ['#FFE9E0', 0.1], shadows: ['#5B6C8A', 0.07], roll: 0.6 }, effects: { grain: FILM_GRAIN } },
  { id: 'film-cine', name: 'Tungsten 500', category: 'film', grade: { temp: -0.35, tint: 0.05, contrast: 0.18, shadows: ['#1F4A5A', 0.12], highlights: ['#FFCF9E', 0.1], fade: 0.03, roll: 0.5 }, effects: { grain: { amount: 0.28, size: 1.3 }, halation: { amount: 0.3, threshold: 0.65 } } },
  { id: 'film-chrome', name: 'Chrome', category: 'film', grade: { contrast: 0.3, sat: 0.1, hue: [{ center: 210, width: 60, shift: 6, sat: 0.2 }, { center: 0, width: 30, shift: 0, sat: 0.1 }], shadows: ['#20304A', 0.06], roll: 0.3 }, effects: { grain: { amount: 0.15, size: 1 } } },
  // Moody
  { id: 'moody-teal', name: 'Teal shadow', category: 'moody', grade: { exposure: -0.12, contrast: 0.2, sat: -0.2, shadows: ['#1B5E66', 0.22], highlights: ['#F2C9A0', 0.08], fade: 0.04 }, effects: { vignette: { amount: 0.3 } } },
  { id: 'moody-forest', name: 'Forest', category: 'moody', grade: { exposure: -0.1, contrast: 0.18, sat: -0.25, hue: [{ center: 100, width: 60, shift: 20, sat: -0.3 }], shadows: ['#24402E', 0.15], fade: 0.03 }, effects: { vignette: { amount: 0.35 } } },
  { id: 'moody-night', name: 'Night', category: 'moody', grade: { exposure: -0.25, temp: -0.3, contrast: 0.25, sat: -0.3, shadows: ['#18243F', 0.2], roll: 0.4 }, effects: { vignette: { amount: 0.4 }, grain: { amount: 0.18 } } },
  { id: 'moody-shadow', name: 'Low key', category: 'moody', grade: { exposure: -0.1, contrast: 0.28, sat: -0.12, curve: [[0, 0.01], [0.25, 0.21], [0.6, 0.6], [1, 0.97]] }, effects: { vignette: { amount: 0.45, size: 0.35 } } },
  // Warm
  { id: 'warm-sunset', name: 'Sunset', category: 'warm', grade: { temp: 0.55, tint: -0.05, contrast: 0.1, vibrance: 0.2, highlights: ['#FFB27A', 0.16], shadows: ['#5A3A4A', 0.08], roll: 0.5 }, effects: { leak: { kind: 'warm', amount: 0.2, angle: 35 } } },
  { id: 'warm-honey', name: 'Honey', category: 'warm', grade: { temp: 0.4, contrast: 0.08, sat: 0.05, highlights: ['#FFD58A', 0.15], fade: 0.02, roll: 0.4 } },
  { id: 'warm-peach', name: 'Peach', category: 'warm', grade: { exposure: 0.06, temp: 0.25, tint: -0.1, sat: -0.05, highlights: ['#FFC9B0', 0.14], fade: 0.03, roll: 0.5 } },
  { id: 'warm-amber', name: 'Amber', category: 'warm', grade: { temp: 0.65, contrast: 0.16, sat: -0.05, hue: [{ center: 200, width: 60, shift: -15, sat: -0.3 }], roll: 0.4 }, effects: { vignette: { amount: 0.2 } } },
  // Cool
  { id: 'cool-ice', name: 'Ice', category: 'cool', grade: { temp: -0.5, contrast: 0.12, sat: -0.15, highlights: ['#DDF2FF', 0.12], roll: 0.4 } },
  { id: 'cool-mint', name: 'Mint', category: 'cool', grade: { temp: -0.2, tint: 0.15, sat: -0.05, hue: [{ center: 100, width: 70, shift: 25, sat: 0.1 }], shadows: ['#2C5A55', 0.1], fade: 0.03 } },
  { id: 'cool-blue-hour', name: 'Blue hour', category: 'cool', grade: { exposure: -0.08, temp: -0.45, contrast: 0.15, shadows: ['#26375E', 0.18], highlights: ['#FFDDBB', 0.06], roll: 0.4 }, effects: { vignette: { amount: 0.25 } } },
  { id: 'cool-crisp', name: 'Crisp', category: 'cool', grade: { temp: -0.18, contrast: 0.22, vibrance: 0.2, roll: 0.3 }, effects: { sharpen: 0.3 } },
  // Black & white
  { id: 'bw-classic', name: 'Classic B&W', category: 'bw', grade: { mono: [0.3, 0.59, 0.11], contrast: 0.15 } },
  { id: 'bw-contrast', name: 'Hard B&W', category: 'bw', grade: { mono: [0.35, 0.55, 0.1], contrast: 0.45, curve: [[0, 0], [0.3, 0.2], [0.7, 0.82], [1, 1]] }, effects: { grain: { amount: 0.25, size: 1.1 } } },
  { id: 'bw-soft', name: 'Soft B&W', category: 'bw', grade: { mono: [0.4, 0.5, 0.1], contrast: -0.1, fade: 0.06, roll: 0.5 } },
  { id: 'bw-sepia', name: 'Sepia', category: 'bw', grade: { mono: [0.33, 0.55, 0.12], contrast: 0.1, monoTone: ['#C69C6D', 0.18], fade: 0.04 }, effects: { vignette: { amount: 0.3 } } },
  // Vintage
  { id: 'vintage-70s', name: '1970s', category: 'vintage', grade: { temp: 0.35, sat: -0.1, contrast: -0.05, fade: 0.08, highlights: ['#FFE0A8', 0.1], shadows: ['#5A3E62', 0.12], hue: [{ center: 110, width: 60, shift: -20 }] }, effects: { grain: { amount: 0.3, size: 1.5 }, vignette: { amount: 0.3 } } },
  { id: 'vintage-instant', name: 'Instant', category: 'vintage', grade: { exposure: 0.1, contrast: -0.12, sat: -0.18, tint: 0.12, fade: 0.1, shadows: ['#3D5C6E', 0.12], highlights: ['#FFF2D6', 0.12], roll: 0.7 }, effects: { vignette: { amount: 0.25, softness: 0.7 }, leak: { kind: 'rose', amount: 0.12, angle: 140 } } },
  { id: 'vintage-faded', name: 'Faded', category: 'vintage', grade: { contrast: -0.2, sat: -0.3, fade: 0.12, temp: 0.1, roll: 0.5 }, effects: { grain: { amount: 0.2 } } },
  // Cinematic
  { id: 'cine-teal-orange', name: 'Blockbuster', category: 'cinematic', grade: { contrast: 0.22, sat: 0.05, shadows: ['#11535E', 0.2], highlights: ['#FFB070', 0.14], hue: [{ center: 200, width: 70, shift: -10, sat: 0.15 }, { center: 110, width: 50, shift: 40, sat: -0.2 }], roll: 0.5 }, effects: { vignette: { amount: 0.2 } } },
  { id: 'cine-bleach', name: 'Bleach', category: 'cinematic', grade: { contrast: 0.35, sat: -0.45, fade: 0.02, roll: 0.3, curve: [[0, 0], [0.2, 0.15], [0.8, 0.86], [1, 1]] }, effects: { grain: { amount: 0.15 } } },
  { id: 'cine-noir', name: 'Neo noir', category: 'cinematic', grade: { exposure: -0.15, temp: -0.2, contrast: 0.3, sat: -0.35, shadows: ['#102540', 0.2], hue: [{ center: 350, width: 40, shift: 0, sat: 0.4 }] }, effects: { vignette: { amount: 0.45 }, halation: { amount: 0.2, threshold: 0.75 } } },
  { id: 'cine-golden', name: 'Golden hour', category: 'cinematic', grade: { temp: 0.45, contrast: 0.18, vibrance: 0.15, shadows: ['#3C3350', 0.1], highlights: ['#FFC27A', 0.18], roll: 0.6 }, effects: { halation: { amount: 0.25, threshold: 0.7 }, leak: { kind: 'amber', amount: 0.15, angle: 20 } } },
];

/** A ready look for an item: the baked LUT plus the look's texture effects (the user can change any part after). */
export const packLook = (id: string): Look | null => { const l = LOOKS.find(x => x.id === id); return l ? { lut: `pack:${l.id}`, strength: 1, ...(l.effects ?? {}) } : null; };
export const LOOK_IDS = new Set(LOOKS.map(l => l.id));
