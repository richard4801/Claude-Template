// Recreate this edit · how text comes in and goes out (workstream 1, plans/recreate-edit.md §2 "animation in/out",
// gap G4). The tracker finds a caption once its strokes are near-white or near-black, so a fade is found late and its
// start isn't seen. Around each item's in and out times, a few frames are read and the contrast inside its box is
// measured: a gradual rise is a fade, the box's right half appearing well after its left a typewriter, else a cut.
import { readWindow, type Rgb } from './frames.js';
import type { TextItem } from './text.js';

/** Items looked at (each costs ~16 frame reads). */
export const MAX_MOTION_ITEMS = 20;
const STEP = 0.1, BEFORE = 0.8, AFTER = 0.4, W = 256;

/** The luma spread (standard deviation, 0–255) inside a box, or one half of it. */
export function contrast(f: Rgb, box: TextItem['box'], half?: 'left' | 'right'): number {
  const x0 = Math.max(0, Math.floor((box.x + (half === 'right' ? box.w / 2 : 0)) * f.width)), x1 = Math.min(f.width, Math.ceil((box.x + (half === 'left' ? box.w / 2 : box.w)) * f.width));
  const y0 = Math.max(0, Math.floor(box.y * f.height)), y1 = Math.min(f.height, Math.ceil((box.y + box.h) * f.height));
  let n = 0, s = 0, s2 = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const i = (y * f.width + x) * 3, l = 0.2126 * f.rgb[i]! + 0.7152 * f.rgb[i + 1]! + 0.0722 * f.rgb[i + 2]!;
    n++; s += l; s2 += l * l;
  }
  return n ? Math.sqrt(Math.max(0, s2 / n - (s / n) ** 2)) : 0;
}

export type Motion = { kind: 'cut' | 'fade' | 'typewriter'; durationSec: number };
/**
 * In: `series` is contrast at evenly spaced times (STEP apart) ending fully on, `left`/`right` the same per half. The
 * first sample is before the text (the background), the last with the text fully there.
 */
export function classifyIn(series: number[], left: number[], right: number[]): Motion {
  const base = series[0]!, full = series.at(-1)!, span = full - base;
  if (span < 6) return { kind: 'cut', durationSec: 0 }; // nothing measurable
  const level = (xs: number[], k: number) => { const b = xs[0]!, f = xs.at(-1)!; return f - b < 3 ? -1 : xs.findIndex(v => (v - b) / (f - b) >= k); };
  const lAt = level(left, 0.5), rAt = level(right, 0.5);
  if (lAt >= 0 && rAt >= 0 && (rAt - lAt) * STEP >= 0.2) return { kind: 'typewriter', durationSec: round2(Math.max(0.2, (rAt - lAt) * 2 * STEP)) };
  const appear = level(series, 0.2), done = level(series, 0.85);
  if (appear >= 0 && done >= 0 && (done - appear) * STEP >= 0.2) return { kind: 'fade', durationSec: round2((done - appear + 1) * STEP) };
  return { kind: 'cut', durationSec: 0 };
}
const round2 = (x: number) => Math.round(x * 100) / 100;

/**
 * Each item's animation in and out (the first MAX_MOTION_ITEMS); others keep "cut". Memory (workstream 1, the 512 MB
 * box): each window is one ffmpeg pipe read in order, never parallel decodes; `stop` is asked before each item and
 * ends the step early (the rest keep "cut") when memory is short.
 */
export async function textMotions(ffmpeg: string, input: string, items: TextItem[], src: { width: number; height: number; durationSec: number }, o: { stop?: () => boolean } = {}): Promise<TextItem[]> {
  const w = Math.min(W, src.width - (src.width % 2)), h = Math.max(2, Math.round(w * src.height / src.width / 2) * 2);
  const clampT = (t: number) => Math.max(0, Math.min(src.durationSec - 0.04, t));
  /** The frames at `ts` (each clamped into the video), from one window read. */
  const at = async (ts: number[]): Promise<(Rgb | null)[]> => {
    const cs = ts.map(clampT), start = Math.min(...cs), count = Math.round((Math.max(...cs) - start) / STEP) + 1;
    const fs = await readWindow(ffmpeg, input, start, count, 1 / STEP, w, h).catch(() => [] as Rgb[]);
    return cs.map(t => fs[Math.round((t - start) / STEP)] ?? null);
  };
  const out: TextItem[] = [];
  let stopped = false;
  for (const [i, it] of items.entries()) {
    if (i >= MAX_MOTION_ITEMS || stopped || (stopped = !!o.stop?.())) { out.push(it); continue; }
    try {
      // In: from before it was found to a little after; the tracker's start is when it was already readable.
      const tin: number[] = []; for (let t = it.startSec - BEFORE; t <= it.startSec + AFTER + 1e-6; t += STEP) tin.push(t);
      const fin = await at(tin);
      // Out: mirrored (fully on → gone), read backwards so the same rule applies.
      const tout: number[] = []; for (let t = it.endSec + BEFORE; t >= it.endSec - AFTER - 1e-6; t -= STEP) tout.push(t);
      const fout = await at(tout);
      const ok = (fs: (Rgb | null)[]) => fs.every(Boolean) ? fs as Rgb[] : null;
      const a = ok(fin), b = ok(fout);
      const m = (fs: Rgb[]) => classifyIn(fs.map(f => contrast(f, it.box)), fs.map(f => contrast(f, it.box, 'left')), fs.map(f => contrast(f, it.box, 'right')));
      const mi = a ? m(a) : null, mo = b ? m(b) : null;
      out.push({ ...it, animIn: mi?.kind ?? it.animIn, animOut: mo ? (mo.kind === 'typewriter' ? 'fade' : mo.kind) : it.animOut,
        ...(mi && mi.kind !== 'cut' ? { animInSec: mi.durationSec } : {}), ...(mo && mo.kind !== 'cut' ? { animOutSec: mo.durationSec } : {}) });
    } catch { out.push(it); }
  }
  return out;
}
