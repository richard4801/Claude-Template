/**
 * The effects library (owner-approved 2026-11-09): twelve in-house picture effects as reference maths, pixel by pixel.
 * The apps implement these as GPU shaders and the server render matches them; the fixture (functions.json `effects`)
 * pins sample pixels so all engines can be checked against the same numbers.
 *
 * Conventions:
 * - u, v ∈ [0, 1] across the clip's own frame, v pointing down; W×H is the frame in pixels.
 * - t is item-local seconds, s is speed (default 1), a is amount (0 = identity for every effect).
 * - sample(u, v) clamps at the edges.
 * - Noise is hash3 over Ken Perlin's permutation table, so it's exact on every platform (on the GPU: a 256×1 texture).
 */
export type EffectId = 'glitch' | 'vhs' | 'film' | 'blur' | 'zoomBlur' | 'mirror' | 'pixelate' | 'posterize' | 'duotone' | 'shake' | 'flash' | 'rain';
export const EFFECT_IDS: readonly EffectId[] = ['glitch', 'vhs', 'film', 'blur', 'zoomBlur', 'mirror', 'pixelate', 'posterize', 'duotone', 'shake', 'flash', 'rain'];
/** Effects whose look moves over time (they take a speed). */
export const EFFECT_SPEED: readonly EffectId[] = ['glitch', 'vhs', 'film', 'shake', 'flash', 'rain'];
export type Effect = { id: EffectId; amount: number; speed?: number; colors?: [string, string] };
export const DUOTONE_DEFAULT: [string, string] = ['#1B1464', '#FF6B6B'];

/** Ken Perlin's permutation (improved noise, 2002). */
export const PERM: readonly number[] = [151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10,
  23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68,
  175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65,
  25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226,
  250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44,
  154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34,
  242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50,
  45, 127, 4, 150, 254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180];

const m256 = (i: number) => ((Math.floor(i) % 256) + 256) % 256;
/** Noise in [0, 1] from three integers: exact on every platform. */
export const hash3 = (i: number, j: number, k: number) => PERM[m256(PERM[m256(PERM[m256(i)]! + j)]! + k)]! / 255;
const fract = (x: number) => x - Math.floor(x);
const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
const mix = (a: number, b: number, k: number) => a + (b - a) * k;
const hex = (h: string): RGB => [parseInt(h.slice(1, 3), 16) / 255, parseInt(h.slice(3, 5), 16) / 255, parseInt(h.slice(5, 7), 16) / 255];

export type RGB = [number, number, number];
export type Sampler = (u: number, v: number) => RGB;

/** One output pixel of [e] at (u, v) of a W×H frame at item-local time t. */
export function effectPixel(e: Effect, t: number, W: number, H: number, u: number, v: number, sample: Sampler): RGB {
  const a = clamp01(e.amount), s = e.speed ?? 1, ts = t * s;
  if (a <= 0) return sample(u, v);
  switch (e.id) {
    case 'glitch': {
      const n = Math.floor(ts * 12), b = Math.floor(v * 16);
      const u2 = hash3(b, n, 1) > 1 - 0.5 * a ? u + (hash3(b, n, 2) - 0.5) * 0.2 * a : u;
      const sp = 0.015 * a;
      return [sample(u2 + sp, v)[0], sample(u2, v)[1], sample(u2 - sp, v)[2]];
    }
    case 'vhs': {
      const u2 = u + Math.sin(40 * v + 6 * ts) * 0.004 * a;
      const c: RGB = [sample(u2 + 0.006 * a, v)[0], sample(u2, v)[1], sample(u2 - 0.006 * a, v)[2]];
      const scan = 1 - 0.2 * a * (0.5 + 0.5 * Math.cos(2 * Math.PI * 240 * v));
      const nz = (hash3(Math.floor(320 * u), Math.floor(240 * v), Math.floor(24 * ts)) - 0.5) * 0.1 * a;
      return c.map(x => clamp01(x * scan + nz)) as RGB;
    }
    case 'film': {
      const c = sample(u + Math.sin(7 * ts) * 0.002 * a, v + Math.cos(5 * ts) * 0.002 * a);
      const g = (hash3(Math.floor(480 * u), Math.floor(480 * v), Math.floor(24 * t)) - 0.5) * 0.16 * a;
      const dust = hash3(Math.floor(160 * u), Math.floor(160 * v), Math.floor(12 * ts) + 7) >= 1 - 0.02 * a ? 0.35 : 1;
      return [clamp01((c[0] + g) * dust * (1 + 0.05 * a)), clamp01((c[1] + g) * dust), clamp01((c[2] + g) * dust * (1 - 0.05 * a))];
    }
    case 'blur': {
      const R = 0.02 * a;
      const w = Array.from({ length: 13 }, (_, i) => Math.exp(-0.5 * ((i - 6) / 3) ** 2));
      const sum = w.reduce((x, y) => x + y, 0);
      const out: RGB = [0, 0, 0];
      for (let i = 0; i < 13; i++) for (let j = 0; j < 13; j++) {
        const k = (w[i]! / sum) * (w[j]! / sum);
        const c = sample(u + ((i - 6) * R / 6) * H / W, v + (j - 6) * R / 6);
        out[0] += k * c[0]; out[1] += k * c[1]; out[2] += k * c[2];
      }
      return out;
    }
    case 'zoomBlur': {
      const out: RGB = [0, 0, 0];
      for (let k = 0; k < 10; k++) {
        const z = 1 - 0.15 * a * k / 9;
        const c = sample(0.5 + (u - 0.5) * z, 0.5 + (v - 0.5) * z);
        out[0] += c[0] / 10; out[1] += c[1] / 10; out[2] += c[2] / 10;
      }
      return out;
    }
    case 'mirror': {
      const u2 = u < 0.5 ? u : 1 - u;
      const v2 = a >= 0.5 ? (v < 0.5 ? v : 1 - v) : v;
      return sample(u2, v2);
    }
    case 'pixelate': {
      const n = Math.round(160 - 150 * a), cw = 1 / n, ch = cw * W / H;
      return sample((Math.floor(u / cw) + 0.5) * cw, (Math.floor(v / ch) + 0.5) * ch);
    }
    case 'posterize': {
      const L = Math.round(16 - 13 * a);
      return sample(u, v).map(x => Math.round(x * (L - 1)) / (L - 1)) as RGB;
    }
    case 'duotone': {
      const [dark, light] = (e.colors ?? DUOTONE_DEFAULT).map(hex) as [RGB, RGB];
      const c = sample(u, v);
      const y = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
      return [0, 1, 2].map(i => mix(c[i]!, mix(dark[i]!, light[i]!, y), a)) as RGB;
    }
    case 'shake': {
      const n = Math.floor(15 * ts), z = 1 + 0.05 * a;
      return sample(0.5 + (u - 0.5) / z + (hash3(n, 3, 0) - 0.5) * 0.04 * a, 0.5 + (v - 0.5) / z + (hash3(n, 4, 0) - 0.5) * 0.04 * a);
    }
    case 'flash': {
      const f = Math.max(0, 1 - 4 * fract(ts));
      return sample(u, v).map(x => x + (1 - x) * f * a) as RGB;
    }
    case 'rain': {
      const cx = Math.floor(48 * u);
      const on = hash3(cx, 5, 0) < 0.6;
      const sp = 0.4 + 0.8 * hash3(cx, 6, 0);
      const y0 = fract(hash3(cx, 7, 0) + ts * sp);
      const d = fract(v - y0);
      const i = on && d < 0.08 ? 1 - d / 0.08 : 0;
      return sample(u + 0.006 * a * i, v).map(x => clamp01(x + 0.12 * a * i)) as RGB;
    }
  }
}

/**
 * A sampler over a W×H RGB image (row-major, 0–1): bilinear between pixel centres ((x + 0.5)/W), clamped at the edges,
 * like a GPU texture with linear filtering and clamp-to-edge.
 */
export function imageSampler(W: number, H: number, px: RGB[]): Sampler {
  const at = (x: number, y: number) => px[Math.min(H - 1, Math.max(0, y)) * W + Math.min(W - 1, Math.max(0, x))]!;
  return (u, v) => {
    const fx = Math.min(W - 0.5, Math.max(0.5, u * W)) - 0.5, fy = Math.min(H - 0.5, Math.max(0.5, v * H)) - 0.5;
    const x0 = Math.floor(fx), y0 = Math.floor(fy), dx = fx - x0, dy = fy - y0;
    const a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1);
    return [0, 1, 2].map(i => (a[i]! * (1 - dx) + b[i]! * dx) * (1 - dy) + (c[i]! * (1 - dx) + d[i]! * dx) * dy) as RGB;
  };
}
