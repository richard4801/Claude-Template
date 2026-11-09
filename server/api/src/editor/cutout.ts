// Cut-out of a still (a sticker): the background of a photo removed, as a transparent PNG (coordinator, 2026-11-09).
// No new model: the photo becomes a one-second clip for the video helpers we already run, the person matte (RVM, the
// default) or tap to keep (SAM 2, any object, the points the member tapped). The matte's middle frame becomes the photo's
// alpha channel; the transparent margins are trimmed (with a little room) so the sticker is just the subject.
import { execFile } from 'node:child_process';
import sharp from 'sharp';
import { ReplicateError } from '../replicate/client.js';

export const CUTOUT_LIMITS = { maxSide: 2048, clipSec: 1, fps: 10, maxPixels: 40_000_000, padPct: 0.02, minAlpha: 8 } as const;

function ff(ffmpeg: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => execFile(ffmpeg, ['-y', '-v', 'error', ...args], { timeout: 120_000, maxBuffer: 4 * 1024 * 1024 },
    err => (err ? reject(new ReplicateError(`Couldn't prepare the photo (${err.message.slice(0, 160)})`, 'failed')) : resolve())));
}

/**
 * The photo turned upright (EXIF), at most maxSide on its long side, with even sides (the video encoder needs them), as
 * a PNG; and a one-second clip of it for the matte helpers. → its size.
 */
export async function prepareStill(ffmpeg: string, input: string, still: string, clip: string): Promise<{ width: number; height: number }> {
  let meta: sharp.Metadata;
  try { meta = await sharp(input, { limitInputPixels: CUTOUT_LIMITS.maxPixels }).metadata(); } catch { throw new ReplicateError('That file isn’t a photo we can read', 'failed'); }
  if (!meta.width || !meta.height) throw new ReplicateError('That file isn’t a photo we can read', 'failed');
  const upright = (meta.orientation ?? 1) >= 5 ? { w: meta.height, h: meta.width } : { w: meta.width, h: meta.height };
  const k = Math.min(1, CUTOUT_LIMITS.maxSide / Math.max(upright.w, upright.h));
  const width = Math.max(2, Math.floor((upright.w * k) / 2) * 2), height = Math.max(2, Math.floor((upright.h * k) / 2) * 2);
  await sharp(input, { limitInputPixels: CUTOUT_LIMITS.maxPixels }).rotate().resize(width, height, { fit: 'fill' }).removeAlpha().png().toFile(still);
  await ff(ffmpeg, ['-loop', '1', '-framerate', String(CUTOUT_LIMITS.fps), '-i', still, '-t', String(CUTOUT_LIMITS.clipSec), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '12',
    '-pix_fmt', 'yuv420p', '-threads', '2', '-movflags', '+faststart', clip]);
  return { width, height };
}

/**
 * The cut-out: the matte video's middle frame (white = keep) as the still's alpha, trimmed to the subject (+ a little
 * room). → the PNG's size and where it sits in the still. Nothing kept → an error, not an empty sticker.
 */
export async function composeCutout(ffmpeg: string, still: string, matte: string, maskPng: string, out: string): Promise<{ width: number; height: number; box: { x: number; y: number; w: number; h: number } }> {
  const { width = 0, height = 0 } = await sharp(still).metadata();
  await ff(ffmpeg, ['-ss', String(CUTOUT_LIMITS.clipSec / 2), '-i', matte, '-frames:v', '1', '-vf', `scale=${width}:${height}:flags=bilinear,format=gray`, maskPng]);
  const mask = await sharp(maskPng).greyscale().resize(width, height, { fit: 'fill' }).raw().toBuffer();
  let x0 = width, y0 = height, x1 = -1, y1 = -1;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) if (mask[y * width + x]! > CUTOUT_LIMITS.minAlpha) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
  if (x1 < 0) throw new ReplicateError('Nothing to cut out was found in that photo', 'failed');
  const pad = Math.round(Math.max(width, height) * CUTOUT_LIMITS.padPct);
  const box = { x: Math.max(0, x0 - pad), y: Math.max(0, y0 - pad), w: 0, h: 0 };
  box.w = Math.min(width, x1 + pad + 1) - box.x; box.h = Math.min(height, y1 + pad + 1) - box.y;
  // Two passes: sharp runs its steps in a fixed order (extract before joinChannel), not the order they're chained.
  const rgba = await sharp(still).joinChannel(mask, { raw: { width, height, channels: 1 } }).raw().toBuffer();
  await sharp(rgba, { raw: { width, height, channels: 4 } }).extract({ left: box.x, top: box.y, width: box.w, height: box.h }).png().toFile(out);
  return { width: box.w, height: box.h, box };
}
