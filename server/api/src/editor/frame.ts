// Approximate frames of an edit for Claude (get_frame / get_contact_sheet when no MUSE app is online to render the exact
// frame): the source frame at the mapped source time (ffmpeg, one still), fitted to the canvas, the item's colour and
// Look (reference renderer), then text and the caption page drawn as SVG. Flagged approximate: no overlays/PiP,
// transitions, masks or keyframes. Nothing is encoded but stills.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { pipeline } from 'node:stream/promises';
import sharp from 'sharp';
import type { Ctx } from '../ctx.js';
import { uid } from '../lib/util.js';
import { mediaToolsAvailable } from '../replicate/media.js';
import { leanDecode, oneAtATime } from '../lib/mediaLane.js';
import { assetMedia } from './assetMedia.js';
import { renderLook, type Lut } from './look.js';
import * as M from './model.js';
import { packLut } from './photo.js';
import { FILTERS } from './presets.js';
import { lutOfUpload } from './versions.js';

const xml = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]!);
const FONT: Record<string, string> = { sans: 'DejaVu Sans, Arial, sans-serif', serif: 'DejaVu Serif, Georgia, serif', rounded: 'DejaVu Sans, Arial, sans-serif',
  condensed: 'DejaVu Sans Condensed, Arial Narrow, sans-serif', mono: 'DejaVu Sans Mono, monospace', marker: 'DejaVu Sans, cursive' };

/** One still at `sec` of the stored media, as raw RGB at the given box (cover/contain), or null. One decode at a time on
 * the server (lib/mediaLane.ts), two threads, so a contact sheet's many stills never decode side by side. */
async function still(ctx: Ctx, key: string, sec: number, w: number, h: number, fit: M.Fit): Promise<Buffer | null> {
  if (!(await mediaToolsAvailable(ctx.config.FFMPEG_PATH, ctx.config.FFPROBE_PATH))) return null;
  return oneAtATime(async () => {
    const tmp = path.join(os.tmpdir(), uid('frm')), jpg = `${tmp}.jpg`;
    let input = `${tmp}${path.extname(key)}`;
    try {
      if (ctx.storage.kind === 's3') input = await ctx.storage.presignGet(key, 600);
      else { const o = await ctx.storage.get(key); if (!o) return null; await pipeline(o.body as NodeJS.ReadableStream, fs.createWriteStream(input)); }
      await stillJpeg(ctx.config.FFMPEG_PATH, input, jpg, sec, Math.max(w, h));
      return await sharp(jpg).resize(w, h, { fit: fit === 'contain' ? 'contain' : 'cover', background: '#000000' }).removeAlpha().raw().toBuffer();
    } catch { return null; } finally {
      for (const f of [jpg, `${tmp}${path.extname(key)}`]) await fs.promises.rm(f, { force: true }).catch(() => {});
    }
  });
}

/** A JPEG of the frame at `sec` (the last frame when `sec` is just past the end), its long side at most 2×`edge` (≥ 320). */
function stillJpeg(ffmpeg: string, input: string, out: string, sec: number, edge: number): Promise<void> {
  const box = Math.max(320, Math.min(1080, Math.round(edge * 2)));
  const args = (at: number) => ['-y', '-v', 'error', ...leanDecode(), '-ss', Math.max(0, at).toFixed(3), '-i', input, '-an', '-sn', '-dn', '-frames:v', '1',
    '-vf', `scale=${box}:${box}:force_original_aspect_ratio=decrease:flags=bilinear`, '-q:v', '3', out];
  const go = (a: string[]) => new Promise<void>((resolve, reject) => execFile(ffmpeg, a, { timeout: 60_000 }, (err, _o, stderr) => (err ? reject(new Error(String(stderr || err.message).slice(0, 300))) : resolve())));
  return go(args(sec)).then(() => { if (!fs.existsSync(out)) return go(args(Math.max(0, sec - 0.25))); });
}

/** SVG for the text items and the caption page showing at t. */
function overlaySvg(p: M.EditProject, t: number, W: number, H: number): string {
  const parts: string[] = [];
  const textEl = (s: M.TextStyle, x: number, y: number, body: string, scale = 1) => {
    const size = Math.max(6, s.sizePct * H * scale), stroke = s.stroke ? ` stroke="${s.stroke.color}" stroke-width="${(s.stroke.widthPct * size).toFixed(1)}" paint-order="stroke"` : '';
    const anchor = s.align === 'left' ? 'start' : s.align === 'right' ? 'end' : 'middle';
    return `<text x="${x.toFixed(1)}" y="${y.toFixed(1)}" font-family="${FONT[s.font] ?? FONT.sans}" font-weight="${s.weight}" font-size="${size.toFixed(1)}" fill="${s.color}" text-anchor="${anchor}" dominant-baseline="middle"${stroke}>${body}</text>`;
  };
  for (const tr of p.tracks.filter(x => x.kind === 'text' && !x.hidden)) for (const it of tr.items as M.TextItem[]) {
    if (t < it.startSec || t >= it.startSec + it.durationSec) continue;
    const s = it.style, lines = (s.uppercase ? it.text.toUpperCase() : it.text).split('\n'), size = s.sizePct * H * (it.transform?.scale ?? 1);
    const x = (it.transform?.x ?? 0.5) * W, y0 = (it.transform?.y ?? 0.5) * H - ((lines.length - 1) * size * (s.lineHeight ?? 1.15)) / 2;
    lines.forEach((ln, i) => parts.push(textEl(s, x, y0 + i * size * (s.lineHeight ?? 1.15), xml(ln), it.transform?.scale ?? 1)));
  }
  const ct = p.tracks.find(x => x.kind === 'caption' && x.caption && !x.hidden)?.caption;
  const at = ct ? M.captionAt(p, t) : null;
  if (ct && at) {
    const page = M.captionPages(p)[at.page]!, s = ct.style;
    const words = page.words.map((w, k) => {
      const lit = s.preset === 'karaoke' ? k <= at.word : k === at.word && s.preset !== 'plain';
      const txt = xml(s.uppercase ? w.text.toUpperCase() : w.text);
      return lit ? `<tspan fill="${s.highlightColor}">${txt}</tspan>` : txt;
    }).join(' ');
    parts.push(textEl(s, W / 2, (s.y ?? 0.72) * H, words));
  }
  return parts.length ? `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">${parts.join('')}</svg>` : '';
}

/** An approximate PNG of the edit at timeline second t, `width` px wide. */
export async function approximateFrame(ctx: Ctx, studioId: string, p: M.EditProject, t: number, width = 540): Promise<{ png: Buffer; width: number; height: number; note: string; read: boolean }> {
  const W = Math.max(32, Math.min(Math.round(width), p.canvas.width)), H = Math.max(32, Math.round((W * p.canvas.height) / p.canvas.width));
  const d = M.durationSec(p);
  t = Math.min(Math.max(0, t), Math.max(0, d - 1e-3));
  const spans = M.timeline(p), main = M.mainTrack(p);
  if (!main.items.length) { // A blank project with no clip yet: its background colour (text and captions still drawn).
    const hex = /^#[0-9a-f]{6}$/i.test(p.canvas.background ?? '') ? p.canvas.background! : '#000000';
    const rgb = Buffer.alloc(W * H * 3);
    for (let i = 0; i < rgb.length; i += 3) { rgb[i] = parseInt(hex.slice(1, 3), 16); rgb[i + 1] = parseInt(hex.slice(3, 5), 16); rgb[i + 2] = parseInt(hex.slice(5, 7), 16); }
    let img = sharp(rgb, { raw: { width: W, height: H, channels: 3 } });
    const svg = overlaySvg(p, t, W, H);
    if (svg) img = img.composite([{ input: Buffer.from(svg) }]);
    return { png: await img.png().toBuffer(), width: W, height: H, note: 'approximate: the edit has no clip yet, so only its background is shown', read: true };
  }
  let k = spans.length - 1;
  for (let i = spans.length - 1; i >= 0; i--) if (t >= spans[i]!.startSec) { k = i; break; }
  const clip = main.items[k] as M.VideoClip, asset = p.assets.find(a => a.id === clip.asset);
  const src = M.clipSourceAt(clip, t - spans[k]!.startSec);
  let note = 'approximate: the source frame with its look, text and captions; no overlays, transitions, masks or keyframes';
  let rgb: Buffer | null = null;
  const media = asset ? await assetMedia(ctx, studioId, asset) : null;
  if (media) rgb = await still(ctx, media.key, src, W, H, clip.fit ?? 'cover');
  const read = !!rgb;
  if (!rgb) { rgb = Buffer.alloc(W * H * 3, 0); note = 'approximate: the source frame could not be read here, so only text and captions are drawn'; }
  // Colour and look.
  const lookRef = clip.look?.lut;
  let lut: Lut | null = null;
  if (lookRef) {
    if (lookRef.startsWith('pack:') || lookRef.startsWith('palette:')) lut = packLut(lookRef);
    else { const a = p.assets.find(x => x.id === lookRef); if (a?.upload) lut = await lutOfUpload(ctx, studioId, a.upload).catch(() => null); }
  }
  // Colour keyframes: the adjust at this frame.
  const adj = M.adjustAt(clip, t - spans[k]!.startSec);
  const look = M.lookAt(clip, t - spans[k]!.startSec);
  const hasColour = look || clip.filter || adj;
  if (hasColour) {
    const f = new Float32Array(W * H * 3);
    for (let i = 0; i < f.length; i++) f[i] = rgb[i]! / 255;
    const out = renderLook({ width: W, height: H, data: f }, look ?? {}, {
      matrix: M.colorMatrix(adj, clip.filter, FILTERS), tone: adj ? { shadows: adj.shadows, highlights: adj.highlights } : null,
      lut, frame: Math.round(t * p.canvas.fps), fps: p.canvas.fps,
    });
    for (let i = 0; i < out.data.length; i++) rgb[i] = Math.round(out.data[i]! * 255);
  }
  // Adjustment layers on screen: their colour over the composed picture (under the text and captions).
  const layer = M.adjustLayerMatrix(p, t, FILTERS);
  if (layer) for (let i = 0; i < W * H * 3; i += 3) {
    const r = rgb[i]! / 255, g = rgb[i + 1]! / 255, b = rgb[i + 2]! / 255;
    for (let c = 0; c < 3; c++) rgb[i + c] = Math.round(Math.min(1, Math.max(0, layer[c * 4]! * r + layer[c * 4 + 1]! * g + layer[c * 4 + 2]! * b + layer[c * 4 + 3]!)) * 255);
  }
  let img = sharp(rgb, { raw: { width: W, height: H, channels: 3 } });
  const svg = overlaySvg(p, t, W, H);
  if (svg) img = img.composite([{ input: Buffer.from(svg) }]);
  return { png: await img.png().toBuffer(), width: W, height: H, note, read };
}

/** A strip of approximate frames every `everySec` (at most 40), 6 per row, each 160 px wide with its time. */
export async function contactSheet(ctx: Ctx, studioId: string, p: M.EditProject, everySec = 1): Promise<{ png: Buffer; times: number[]; unread: number }> {
  const d = M.durationSec(p), step = Math.max(0.25, everySec, d / 40);
  const times: number[] = [];
  for (let t = 0; t < d - 1e-6 && times.length < 40; t += step) times.push(Math.round(t * 100) / 100);
  // Two at a time: each frame is an ffmpeg decode of the source, and 40 at once ran the small box out of memory (502s).
  const tiles: Awaited<ReturnType<typeof approximateFrame>>[] = new Array(times.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(2, times.length) }, async () => { while (next < times.length) { const i = next++; tiles[i] = await approximateFrame(ctx, studioId, p, times[i]!, 160); } }));
  const tw = 160, th = tiles[0]?.height ?? 284, cols = Math.min(6, times.length), rows = Math.ceil(times.length / 6), lab = 18;
  const comps = await Promise.all(tiles.map(async (tl, i) => {
    const label = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${tw}" height="${lab}"><rect width="100%" height="100%" fill="#111"/><text x="4" y="13" font-size="12" fill="#fff" font-family="DejaVu Sans Mono, monospace">${times[i]!.toFixed(1)} s</text></svg>`);
    return { input: await sharp(tl.png).extend({ bottom: lab, background: '#111111' }).composite([{ input: label, top: th, left: 0 }]).png().toBuffer(), left: (i % 6) * tw, top: Math.floor(i / 6) * (th + lab) };
  }));
  const png = await sharp({ create: { width: Math.max(1, cols) * tw, height: Math.max(1, rows) * (th + lab), channels: 3, background: '#111111' } }).composite(comps).png().toBuffer();
  return { png, times, unread: tiles.filter(x => !x.read).length };
}
