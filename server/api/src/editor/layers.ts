// Layers (plans/layers-edit.md, Phase 1): the "Find layers" job's pieces. One paid run per clip tracks up to five
// tapped or boxed objects (the same tracker as Keep what you tapped, one prediction per object), stores a matte video
// per object, and reads each matte's box over time (small grey frames streamed through ffmpeg) so text can be pinned.
import { spawn } from 'node:child_process';
import { badRequest } from '../errors.js';
import type { KeepPoint } from './service.js';
import * as M from './model.js';
import { encThreads } from '../lib/resources.js';

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

/**
 * The tracker can hand back its matte at another frame rate than the source (it renders at its own default), so the matte
 * runs slow or fast and drifts away from the picture while she moves (owner report ci_f1a8073237b7). A matte whose length
 * is off by more than 2 % (and 0.1 s) is retimed to the source's length (and kept at most 720 px on its long side, grey):
 * a new local file, or null when it already lines up.
 */
export async function retimeMatte(ffmpeg: string, ffprobe: string, file: string, durationSec: number, out: string): Promise<string | null> {
  const { probe } = await import('../replicate/media.js');
  const info = await probe(ffprobe, file);
  const got = info.duration;
  if (!(got > 0) || !(durationSec > 0) || Math.abs(got - durationSec) <= Math.max(0.1, 0.02 * durationSec)) return null;
  const k = durationSec / got;
  await new Promise<void>((resolve, reject) => {
    const p = spawn(ffmpeg, ['-y', '-v', 'error', '-i', file, '-an', '-vf', `setpts=PTS*${k.toFixed(6)},scale='if(gte(iw,ih),min(720,iw),-2)':'if(gte(iw,ih),-2,min(720,ih))',format=gray`,
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', '-threads', encThreads(2), '-t', durationSec.toFixed(3), out], { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    p.stderr.on('data', d => { err = (err + d).slice(-400); });
    p.on('error', reject);
    p.on('close', code => (code === 0 ? resolve() : reject(new Error(`retime matte: ${err || `exit ${code}`}`))));
  });
  return out;
}

/**
 * Whether a found layer covers what was marked (owner report ci_0e39a2b16b08: a tap between two hair buns gave a small
 * patch of background): each kept tap is looked up in the layer's box on its own frame. Null when it covers them, else a
 * plain line for the person and for Claude.
 */
export function coverageWarning(o: LayerObject, boxes: (number[] | null)[], fps: number): string | null {
  const kept = o.points.filter(q => q.keep && !(o.box && boxPoints(o.box).some(b => b.x === q.x && b.y === q.y && b.t === q.t)));
  const at = (t: number) => boxes[Math.min(boxes.length - 1, Math.max(0, Math.round(t * fps)))] ?? null;
  const pad = 0.03;
  const inside = (q: { x: number; y: number }, b: number[] | null) => !!b && q.x >= b[0]! - pad && q.x <= b[0]! + b[2]! + pad && q.y >= b[1]! - pad && q.y <= b[1]! + b[3]! + pad;
  const seen = boxes.filter((b): b is number[] => !!b);
  if (!seen.length) return `${o.name}: nothing was found · mark it again, ideally with a box round it`;
  const missed = kept.filter(q => !inside(q, at(q.t))).length;
  let boxMiss = false;
  if (o.box) {
    const b = at(o.box.t), area = b ? b[2]! * b[3]! : 0;
    boxMiss = !b || area < 0.15 * o.box.w * o.box.h;
  }
  if (!missed && !boxMiss) return null;
  return missed ? `${o.name}: the layer doesn't cover ${missed} of the ${kept.length} ${kept.length === 1 ? 'point' : 'points'} you marked · check it, or find it again with a box round it`
    : `${o.name}: the layer is much smaller than the box you drew · check it, or find it again with a few taps on it`;
}

/**
 * A point Claude marked on the edit as get_frame shows it (x, y 0–1 of the canvas, t seconds on the timeline) → the same
 * spot on main clip `clip`'s source frame (x, y 0–1 of the source, t seconds of the source), through the inverse of the
 * clip's crop, fit and placement (model.ts itemCorners). Null when the clip isn't on screen at t, or the point is off its picture.
 */
export function canvasToSource(p: M.EditProject, clipId: string, t: number, x: number, y: number, size: { width: number; height: number }): { x: number; y: number; t: number } | null {
  const main = M.mainTrack(p), tl = M.timeline(p);
  const i = main.items.findIndex(c => c.id === clipId);
  const c = main.items[i] as M.VideoClip | undefined, span = tl[i];
  if (!c || !span || !(size.width > 0 && size.height > 0)) return null;
  const local = Math.min(Math.max(0, t - span.startSec), Math.max(0, span.endSec - span.startSec - 1e-3));
  const cr = c.crop ?? {}, cl = cr.left ?? 0, ct = cr.top ?? 0, cw = 1 - cl - (cr.right ?? 0), ch = 1 - ct - (cr.bottom ?? 0);
  const tr = c.transform ?? {};
  const k = M.itemCorners(p.canvas, size.width * cw, size.height * ch, c.fit ?? 'cover', { x: M.propAt(c, 'x', tr.x ?? 0.5, local), y: M.propAt(c, 'y', tr.y ?? 0.5, local),
    scale: M.propAt(c, 'scale', tr.scale ?? 1, local), rotation: M.propAt(c, 'rotation', tr.rotation ?? 0, local), flipX: tr.flipX, flipY: tr.flipY });
  const [TL, TR, , BL] = k as [number, number][];
  const ax = TR![0] - TL![0], ay = TR![1] - TL![1], bx = BL![0] - TL![0], by = BL![1] - TL![1];
  const det = ax * by - ay * bx;
  if (Math.abs(det) < 1e-9) return null;
  const px = x * p.canvas.width - TL![0], py = y * p.canvas.height - TL![1];
  const u = (px * by - py * bx) / det, v = (ax * py - ay * px) / det;
  if (u < -0.01 || u > 1.01 || v < -0.01 || v > 1.01) return null;
  const r4 = (n: number) => Math.round(Math.min(1, Math.max(0, n)) * 10000) / 10000;
  return { x: r4(cl + u * cw), y: r4(ct + v * ch), t: Math.round(M.clipSourceAt(c, local) * 1000) / 1000 };
}
