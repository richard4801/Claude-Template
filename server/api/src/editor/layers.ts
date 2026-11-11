// Layers (plans/layers-edit.md, Phase 1): the "Find layers" job's pieces. One paid run per clip tracks up to five
// tapped or boxed objects (the same tracker as Keep what you tapped, one prediction per object), stores a matte video
// per object, and reads each matte's box over time (small grey frames streamed through ffmpeg) so text can be pinned.
import { spawn } from 'node:child_process';
import { badRequest } from '../errors.js';
import type { KeepPoint } from './service.js';

/** Owner decisions 2026-11-11: clips up to 60 s; anything above $1 per clip asks first; no depth. */
export const LAYERS_LIMITS = { maxSec: 60, maxObjects: 5, maxPoints: 10, askAboveUsd: 1, trackFps: 5 } as const;
export type LayerBox = { x: number; y: number; w: number; h: number; t: number };
export type LayerObject = { name: string; points: KeepPoint[]; box?: LayerBox };

const r4 = (v: number) => Math.round(v * 10000) / 10000;
/**
 * A box as clicks for a click-only tracker: its centre and four points halfway to its corners (keep), and a point just
 * outside each side that is still in the frame (leave out). The box itself is kept for a box-capable model later.
 */
export function boxPoints(b: LayerBox): KeepPoint[] {
  const cx = b.x + b.w / 2, cy = b.y + b.h / 2, t = b.t;
  const keep = [[cx, cy], [cx - b.w / 4, cy - b.h / 4], [cx + b.w / 4, cy - b.h / 4], [cx - b.w / 4, cy + b.h / 4], [cx + b.w / 4, cy + b.h / 4]];
  const pad = 0.03, out = [[b.x - pad, cy], [b.x + b.w + pad, cy], [cx, b.y - pad], [cx, b.y + b.h + pad]].filter(([x, y]) => x! >= 0 && x! <= 1 && y! >= 0 && y! <= 1);
  return [...keep.map(([x, y]) => ({ x: r4(x!), y: r4(y!), t, keep: true })), ...out.map(([x, y]) => ({ x: r4(x!), y: r4(y!), t, keep: false }))];
}

/** `options.objects` of a layers job: 1–5 named objects, each tapped (points) or boxed (box). */
export function parseObjects(raw: unknown, maxT: number): LayerObject[] {
  if (!Array.isArray(raw) || !raw.length || raw.length > LAYERS_LIMITS.maxObjects) throw badRequest(`options.objects: 1 to ${LAYERS_LIMITS.maxObjects} things to find`);
  return raw.map((o: any, i) => {
    const f = `options.objects.${i}`;
    if (!o || typeof o !== 'object') throw badRequest(`${f}: {name, points | box}`);
    if (typeof o.name !== 'string' || !o.name.trim() || o.name.length > 40) throw badRequest(`${f}.name: 1 to 40 characters`);
    const n = (q: any, k: string, lo: number, hi: number, g: string, d?: number) => { const v = q?.[k] ?? d; if (typeof v !== 'number' || !Number.isFinite(v) || v < lo || v > hi) throw badRequest(`${g}.${k}: from ${lo} to ${hi}`); return r4(v); };
    let box: LayerBox | undefined, points: KeepPoint[] = [];
    if (o.box !== undefined) {
      const b = o.box;
      box = { x: n(b, 'x', 0, 1, `${f}.box`), y: n(b, 'y', 0, 1, `${f}.box`), w: n(b, 'w', 0.01, 1, `${f}.box`), h: n(b, 'h', 0.01, 1, `${f}.box`), t: n(b, 't', 0, maxT, `${f}.box`, 0) };
      if (box.x + box.w > 1.0001 || box.y + box.h > 1.0001) throw badRequest(`${f}.box: must be inside the frame`);
      points = boxPoints(box);
    }
    if (o.points !== undefined) {
      if (!Array.isArray(o.points) || !o.points.length) throw badRequest(`${f}.points: at least one point`);
      points.push(...o.points.map((q: any, j: number) => {
        if (q?.keep !== undefined && typeof q.keep !== 'boolean') throw badRequest(`${f}.points.${j}.keep: true or false`);
        return { x: n(q, 'x', 0, 1, `${f}.points.${j}`), y: n(q, 'y', 0, 1, `${f}.points.${j}`), t: n(q, 't', 0, maxT, `${f}.points.${j}`, 0), keep: q.keep !== false };
      }));
    }
    if (!points.some(q => q.keep)) throw badRequest(`${f}: tap it or draw a box round it`);
    if (points.length > LAYERS_LIMITS.maxPoints) throw badRequest(`${f}.points: at most ${LAYERS_LIMITS.maxPoints} points (a box counts as up to 9)`);
    return { name: o.name.trim(), points, ...(box ? { box } : {}) };
  });
}

/**
 * Where a matte's white part is, every 1/fps s from 0: [x, y, w, h] (0–1 of the frame), or null when less than 0.2 % of
 * the frame is white. Frames are read 96 × 96 grey from ffmpeg's pipe one at a time (≈ 9 KB each).
 */
export async function matteBoxes(ffmpeg: string, input: string, fps: number = LAYERS_LIMITS.trackFps, maxSamples = LAYERS_LIMITS.maxSec * LAYERS_LIMITS.trackFps + 25): Promise<(number[] | null)[]> {
  const S = 96, size = S * S, out: (number[] | null)[] = [];
  return new Promise((resolve, reject) => {
    const p = spawn(ffmpeg, ['-v', 'error', '-i', input, '-vf', `fps=${fps},scale=${S}:${S}:flags=area,format=gray`, '-f', 'rawvideo', 'pipe:1'], { stdio: ['ignore', 'pipe', 'pipe'] });
    let buf: Buffer = Buffer.alloc(0), err = '';
    p.stderr.on('data', d => { err = (err + d).slice(-500); });
    p.stdout.on('data', (d: Buffer) => {
      buf = buf.length ? Buffer.concat([buf, d]) : d;
      while (buf.length >= size) {
        const fr = buf.subarray(0, size);
        buf = buf.subarray(size);
        if (out.length >= maxSamples) continue;
        let x0 = S, y0 = S, x1 = -1, y1 = -1, n = 0;
        for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) if (fr[y * S + x]! > 127) { n++; if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
        out.push(n < size * 0.002 ? null : [r4(x0 / S), r4(y0 / S), r4((x1 - x0 + 1) / S), r4((y1 - y0 + 1) / S)]);
      }
    });
    p.on('error', reject);
    p.on('close', code => (code === 0 && out.length ? resolve(out) : reject(new Error(`matte boxes: ${err || `exit ${code}`}`))));
  });
}

/** The same objects whatever order the database keeps their fields in (for reuse). */
export const objectsKey = (objs: LayerObject[]) => JSON.stringify(objs.map(o => [o.name, o.points.map(q => [q.x, q.y, q.t, q.keep]), o.box ? [o.box.x, o.box.y, o.box.w, o.box.h, o.box.t] : null]));
