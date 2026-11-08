// Recreate this edit · on-screen text (workstream 1, plans/recreate-edit.md "Text and captions"): where text sits, how
// big, what colour, and when it comes in and goes out, from text-like regions tracked over time. The words need OCR
// (pending the owner's/coordinator's choice); until then `words` is null and Claude reads them off the contact sheet.
import { spawn } from 'node:child_process';
import { DECODE_ARGS } from './frames.js';

export type TextBox = { x: number; y: number; w: number; h: number };
export type TextItem = { id: string; startSec: number; endSec: number; box: TextBox; words: string | null; sizeFrac: number; color: string;
  /** The nearest editor font family (sans, serif, rounded, condensed, mono, marker). */
  fontId: 'sans' | 'serif' | 'rounded' | 'condensed' | 'mono' | 'marker';
  animIn: 'cut' | 'fade' | 'typewriter' | null; animOut: 'cut' | 'fade' | null;
  /** How long the fade or typewriter in and the fade out take (G4). */
  animInSec?: number; animOutSec?: number; confidence: number };

const W = 192, BANDS = 40, FPS = 6;
/** The recipe's size cap (≈ 256 KB in all): at most this many text items. */
export const MAX_TEXT_ITEMS = 100;

type FrameBoxes = { t: number; boxes: (TextBox & { light: boolean })[] };

/**
 * Text-like regions of one grey frame: horizontal bands thick with sharp edges made of near-white or near-black
 * pixels (caption strokes), merged into boxes.
 */
export function textRegions(f: Uint8Array, w: number, h: number): (TextBox & { light: boolean })[] {
  const bandH = Math.max(2, Math.floor(h / BANDS));
  const rows: { y0: number; y1: number; x0: number; x1: number; light: boolean }[] = [];
  for (let b = 0; b < BANDS; b++) {
    const y0 = b * bandH, y1 = Math.min(h, y0 + bandH);
    let edges = 0, stroke = 0, light = 0, dark = 0, xs: number[] = [];
    for (let y = y0; y < y1; y++) for (let x = 1; x < w; x++) {
      const v = f[y * w + x]!, d = Math.abs(v - f[y * w + x - 1]!);
      if (d > 60 && (v > 215 || v < 40 || f[y * w + x - 1]! > 215 || f[y * w + x - 1]! < 40)) { edges++; xs.push(x); }
      if (v > 215) { stroke++; light++; } else if (v < 40) { stroke++; dark++; }
    }
    const area = (y1 - y0) * (w - 1);
    if (edges / area > 0.05 && stroke / area > 0.08 && stroke / area < 0.85) {
      xs.sort((a, b2) => a - b2);
      rows.push({ y0, y1, x0: xs[Math.floor(xs.length * 0.03)]!, x1: xs[Math.floor(xs.length * 0.97)]!, light: light >= dark });
    }
  }
  // Adjacent bands make one box.
  const boxes: (TextBox & { light: boolean })[] = [];
  for (const r of rows) {
    const last = boxes.at(-1);
    if (last && Math.abs(r.y0 / h - (last.y + last.h)) < 1.5 / BANDS) {
      const x0 = Math.min(last.x, r.x0 / w), x1 = Math.max(last.x + last.w, r.x1 / w);
      last.x = x0; last.w = x1 - x0; last.h = r.y1 / h - last.y;
    } else boxes.push({ x: r.x0 / w, y: r.y0 / h, w: (r.x1 - r.x0) / w, h: (r.y1 - r.y0) / h, light: r.light });
  }
  return boxes.filter(b => b.w > 0.08 && b.h < 0.35);
}

const iou = (a: TextBox, b: TextBox) => {
  const x = Math.max(0, Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)), y = Math.max(0, Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y));
  const i = x * y; return i / (a.w * a.h + b.w * b.h - i || 1);
};

/** Boxes followed over time: one item per box that stays (≥ 0.3 s), with its in and out times. */
export function trackText(frames: FrameBoxes[], fps = FPS): TextItem[] {
  const open: { box: TextBox & { light: boolean }; start: number; last: number; seen: number }[] = [];
  const done: typeof open = [];
  for (const f of frames) {
    const used = new Set<number>();
    for (const o of open) {
      const j = f.boxes.findIndex((b, k) => !used.has(k) && iou(b, o.box) > 0.4);
      if (j >= 0) { used.add(j); o.last = f.t; o.seen++; o.box = { ...f.boxes[j]!, light: o.box.light }; }
    }
    for (let k = open.length - 1; k >= 0; k--) if (open[k]!.last < f.t - 1.5 / fps) done.push(...open.splice(k, 1));
    f.boxes.forEach((b, k) => { if (!used.has(k)) open.push({ box: b, start: f.t, last: f.t, seen: 1 }); });
  }
  done.push(...open);
  const end = frames.at(-1)?.t ?? 0;
  return done.filter(o => o.last - o.start >= 0.3 && o.seen >= 3).sort((a, b) => a.start - b.start).slice(0, MAX_TEXT_ITEMS).map((o, i): TextItem => ({
    id: `x${i + 1}`, startSec: r3(o.start), endSec: r3(Math.min(end + 1 / fps, o.last + 1 / fps)),
    box: { x: r3(o.box.x), y: r3(o.box.y), w: r3(o.box.w), h: r3(o.box.h) }, words: null,
    // A caption's cap height is about 60% of its band box.
    sizeFrac: r3(o.box.h * 0.6), color: o.box.light ? '#FFFFFF' : '#000000', fontId: 'sans' as const, animIn: 'cut' as const, animOut: 'cut' as const, confidence: 0.45,
  }));
}

/** Samples the clip at 6 fps, 192 px wide, and returns its text items. */
export function findText(ffmpeg: string, input: string, height: number, maxSec = 600): Promise<TextItem[]> {
  return new Promise((resolve, reject) => {
    const h = Math.max(2, Math.round(height / 2) * 2), frame = W * h;
    const p = spawn(ffmpeg, ['-v', 'error', ...DECODE_ARGS, '-i', input, '-t', String(maxSec), '-an', '-vf', `fps=${FPS},scale=${W}:${h}:flags=area,format=gray`, '-f', 'rawvideo', 'pipe:1']);
    const frames: FrameBoxes[] = [];
    let buf: Buffer = Buffer.alloc(0), err = '';
    p.stdout.on('data', (c: Buffer) => {
      buf = buf.length ? Buffer.concat([buf, c]) : c;
      while (buf.length >= frame) { frames.push({ t: frames.length / FPS, boxes: textRegions(new Uint8Array(buf.subarray(0, frame)), W, h) }); buf = buf.subarray(frame); }
    });
    p.stderr.on('data', d => { err += String(d); });
    p.on('error', reject);
    p.on('close', code => (code === 0 ? resolve(trackText(frames)) : reject(new Error(`ffmpeg failed: ${err.trim().split('\n').slice(-1)[0]?.slice(0, 200)}`))));
  });
}

const r3 = (x: number) => Math.round(x * 1000) / 1000;
