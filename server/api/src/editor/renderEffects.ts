// The effects library (effects.ts) in the server render: each effect as ffmpeg filters that follow its reference maths
// (effectPixel), on the clip's own picture in RGB (gbrp), after its look and before its matte, mask and placement.
// What moves per frame (glitch bands, VHS wobble, shake, flash, rain) is written here as small raw frames — one value
// per band, row or frame — scaled up and applied with displace or lut2, so nothing is evaluated per pixel in an
// expression (a per-pixel geq took ~45 s for 0.4 s of 1080 × 1920; see render.ts glitchShifts).
// Close to the apps, not pixel-exact: noise is ffmpeg's (the reference hashes it), film dust and the rain's sideways nudge
// are left out. Exact sample pixels stay pinned by the fixture against effectPixel itself.
import { hash3, type Effect } from './effects.js';

export type FxInput = { src: string; tag: string; iw: number; ih: number; n: number; fps: number; t0: number };
/** Writes raw frames (gray: 1 byte a pixel; rgb24: 3) as a new input; returns its stream label (e.g. "7:v"). */
export type FxRaw = (name: string, fmt: 'gray' | 'rgb24', w: number, h: number, frames: Buffer[]) => string;

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
const fract = (x: number) => x - Math.floor(x);
const n4 = (v: number) => String(Math.round(v * 1e4) / 1e4);
const byte = (v: number) => Math.max(0, Math.min(255, Math.round(v)));
const hex = (h: string) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)] as const;

export function effectFilters(e: Effect, o: FxInput, raw: FxRaw): { graph: string[]; out: string } {
  const a = clamp01(e.amount), sp = e.speed ?? 1, { iw, ih, n, fps, t0, tag } = o;
  const g: string[] = [];
  let s = o.src;
  const t = (fi: number) => t0 + fi / fps; // item-local seconds of output frame fi
  /** A map or field, frame by frame (or one frame for all), scaled to the picture, as gbrp. */
  const field = (name: string, w: number, h: number, frames: Buffer[], flags: 'neighbor' | 'bilinear' = 'neighbor') => {
    const k = raw(name, 'gray', w, h, frames);
    g.push(`[${k}]${frames.length === 1 ? 'loop=loop=-1:size=1,' : ''}setpts=N/${fps}/TB,trim=end_frame=${n},scale=${iw}:${ih}:flags=${flags},format=gbrp[${tag}${name}]`);
    return `${tag}${name}`;
  };
  const still128 = (name: string) => field(name, 2, 2, [Buffer.alloc(4, 128)]);
  /** Moves each pixel by the maps (128 = still; value − 128 pixels, sampled from there, edges smeared). */
  const displace = (xmap: string, ymap: string, name: string) => { g.push(`[${s}][${xmap}][${ymap}]displace=edge=smear[${tag}${name}]`); s = `${tag}${name}`; };
  const step = (name: string, f: string) => { g.push(`[${s}]${f}[${tag}${name}]`); s = `${tag}${name}`; };
  const split = (px: number, name: string) => { const d = Math.round(px); if (d) step(name, `rgbashift=rh=${-d}:bh=${d}:edge=smear`); };

  switch (e.id) {
    case 'glitch': {
      // 16 bands; a band jumps sideways by up to 10 % × amount on some of the 12 ticks a second; red/blue 1.5 % apart.
      const frames = Array.from({ length: n }, (_, fi) => {
        const tick = Math.floor(t(fi) * sp * 12);
        return Buffer.from(Array.from({ length: 16 }, (_, b) => (hash3(b, tick, 1) > 1 - 0.5 * a ? byte(128 + (hash3(b, tick, 2) - 0.5) * 0.2 * a * iw) : 128)));
      });
      displace(field('gx', 1, 16, frames), still128('gy'), 'gd');
      split(0.015 * a * iw, 'gs');
      break;
    }
    case 'vhs': {
      const rows = Math.min(ih, 128);
      const frames = Array.from({ length: n }, (_, fi) => Buffer.from(Array.from({ length: rows }, (_, r) => byte(128 + Math.sin(40 * ((r + 0.5) / rows) + 6 * t(fi) * sp) * 0.004 * a * iw))));
      displace(field('vx', 1, rows, frames, 'bilinear'), still128('vy'), 'vd');
      split(0.006 * a * iw, 'vs');
      // Scan lines: 240 across the height, darkening by up to 20 % × amount.
      const lines = field('vl', 1, ih, [Buffer.from(Array.from({ length: ih }, (_, r) => byte(255 * (1 - 0.2 * a * (0.5 + 0.5 * Math.cos(2 * Math.PI * 240 * ((r + 0.5) / ih)))))))]);
      g.push(`[${s}][${lines}]lut2=c0='x*y/255':c1='x*y/255':c2='x*y/255'[${tag}vl2]`);
      s = `${tag}vl2`;
      step('vn', `noise=alls=${Math.round(Math.min(100, 0.1 * a * 255 / 2))}:allf=t`);
      break;
    }
    case 'film': {
      step('fc', `colorchannelmixer=rr=${n4(1 + 0.05 * a)}:bb=${n4(1 - 0.05 * a)}`);
      step('fn', `noise=alls=${Math.round(Math.min(100, 0.16 * a * 255 / 2))}:allf=t`);
      break;
    }
    case 'blur': {
      const sigma = 0.01 * a * ih;
      if (sigma >= 0.3) step('bl', `gblur=sigma=${n4(sigma)}`);
      break;
    }
    case 'zoomBlur': {
      // The mean of 10 copies zoomed in by up to 15 % × amount about the centre.
      const k = 10;
      g.push(`[${s}]split=${k}${Array.from({ length: k }, (_, j) => `[${tag}z${j}]`).join('')}`);
      for (let j = 0; j < k; j++) {
        const z = 1 - (0.15 * a * j) / (k - 1);
        if (j === 0) { g.push(`[${tag}z0]null[${tag}zz0]`); continue; }
        g.push(`[${tag}z${j}]crop=w=${n4(iw * z)}:h=${n4(ih * z)}:x=${n4((iw - iw * z) / 2)}:y=${n4((ih - ih * z) / 2)},scale=${iw}:${ih}:flags=bilinear,setsar=1[${tag}zz${j}]`);
      }
      g.push(`${Array.from({ length: k }, (_, j) => `[${tag}zz${j}]`).join('')}mix=inputs=${k}[${tag}zb]`);
      s = `${tag}zb`;
      break;
    }
    case 'mirror': {
      // The left half, and its mirror on the right; from half amount, the top half mirrored down too.
      g.push(`[${s}]split[${tag}m0][${tag}m1]`, `[${tag}m0]crop=${iw / 2}:${ih}:0:0[${tag}ml]`, `[${tag}m1]crop=${iw / 2}:${ih}:0:0,hflip[${tag}mr]`, `[${tag}ml][${tag}mr]hstack[${tag}mh]`);
      s = `${tag}mh`;
      if (a >= 0.5) {
        const hh = Math.floor(ih / 2);
        g.push(`[${s}]split[${tag}n0][${tag}n1]`, `[${tag}n0]crop=${iw}:${hh}:0:0[${tag}nt]`, `[${tag}n1]crop=${iw}:${ih - hh}:0:0,vflip[${tag}nb]`, `[${tag}nt][${tag}nb]vstack[${tag}mv]`);
        s = `${tag}mv`;
      }
      break;
    }
    case 'pixelate': {
      const across = Math.max(1, Math.round(160 - 150 * a)), down = Math.max(1, Math.round((across * ih) / iw));
      step('px', `scale=${across}:${down}:flags=neighbor,scale=${iw}:${ih}:flags=neighbor`);
      break;
    }
    case 'posterize': {
      const L = Math.round(16 - 13 * a), f = `round(val/255*${L - 1})/${L - 1}*255`;
      step('po', `lutrgb=r='${f}':g='${f}':b='${f}'`);
      break;
    }
    case 'duotone': {
      const [d, l] = [hex(e.colors?.[0] ?? '#1B1464'), hex(e.colors?.[1] ?? '#FF6B6B')];
      const ch = (i: number) => `${d[i]}+(${l[i]! - d[i]!})*val/255`;
      g.push(`[${s}]split[${tag}d0][${tag}d1]`,
        `[${tag}d0]colorchannelmixer=rr=0.2126:rg=0.7152:rb=0.0722:gr=0.2126:gg=0.7152:gb=0.0722:br=0.2126:bg=0.7152:bb=0.0722,lutrgb=r='${ch(0)}':g='${ch(1)}':b='${ch(2)}'[${tag}dt]`,
        `[${tag}dt][${tag}d1]blend=all_mode=normal:all_opacity=${n4(a)}[${tag}dm]`);
      s = `${tag}dm`;
      break;
    }
    case 'shake': {
      // Moved by up to ±2 % × amount on 15 ticks a second, then zoomed 1 + 5 % × amount so no edge shows.
      const z = 1 + 0.05 * a;
      const tick = (fi: number) => Math.floor(15 * t(fi) * sp);
      const xs = Array.from({ length: n }, (_, fi) => Buffer.from([byte(128 + (hash3(tick(fi), 3, 0) - 0.5) * 0.04 * a * iw)]));
      const ys = Array.from({ length: n }, (_, fi) => Buffer.from([byte(128 + (hash3(tick(fi), 4, 0) - 0.5) * 0.04 * a * ih)]));
      displace(field('sx', 1, 1, xs), field('sy', 1, 1, ys), 'sd');
      step('sz', `crop=w=${n4(iw / z)}:h=${n4(ih / z)}:x=${n4((iw - iw / z) / 2)}:y=${n4((ih - ih / z) / 2)},scale=${iw}:${ih}:flags=bilinear,setsar=1`);
      break;
    }
    case 'flash': {
      // Each second (at speed 1) starts white × amount and falls back within a quarter second.
      const frames = Array.from({ length: n }, (_, fi) => Buffer.from([byte(255 * a * Math.max(0, 1 - 4 * fract(t(fi) * sp)))]));
      const f = field('fl', 1, 1, frames);
      g.push(`[${s}][${f}]lut2=c0='x+(255-x)*y/255':c1='x+(255-x)*y/255':c2='x+(255-x)*y/255'[${tag}fl2]`);
      s = `${tag}fl2`;
      break;
    }
    case 'rain': {
      // 48 columns, 60 % of them with a falling streak 8 % of the height long, brightening by 12 % × amount.
      const rows = 96;
      const frames = Array.from({ length: n }, (_, fi) => {
        const ts = t(fi) * sp, b = Buffer.alloc(48 * rows);
        for (let cx = 0; cx < 48; cx++) {
          if (hash3(cx, 5, 0) >= 0.6) continue;
          const y0 = fract(hash3(cx, 7, 0) + ts * (0.4 + 0.8 * hash3(cx, 6, 0)));
          for (let r = 0; r < rows; r++) {
            const d = fract((r + 0.5) / rows - y0);
            if (d < 0.08) b[r * 48 + cx] = byte(255 * 0.12 * a * (1 - d / 0.08));
          }
        }
        return b;
      });
      const f = field('rn', 48, rows, frames);
      g.push(`[${s}][${f}]lut2=c0='min(255,x+y)':c1='min(255,x+y)':c2='min(255,x+y)'[${tag}rn2]`);
      s = `${tag}rn2`;
      break;
    }
  }
  return { graph: g, out: s };
}
