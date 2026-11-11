// Metadata cleanup (owner, 2026-11-09): every photo and video MUSE stores for a studio leaves without the provider's,
// the prompt's or a device's data. Videos are remuxed without re-encoding (ffmpeg -c copy: no global/stream tags, no
// chapters, no data/timecode tracks, no udta/meta/uuid boxes such as C2PA; rotation and colour stay because they live
// in the track header and the bitstream). Photos are re-saved by sharp (orientation baked in, sRGB, no EXIF/XMP/IPTC/
// ICC/C2PA/comments). Pixels are not touched beyond that re-save, and nothing here varies a file to dodge detection.
// MUSE's own label is written only when the person switched "Label as AI-generated" on (label: true).
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';

/** The text MUSE writes into a file when "Label as AI-generated" is on. */
export const AI_LABEL_TEXT = 'AI-generated · made with MUSE';

type Kind = { format: string; ext: string; audioOnly?: boolean };
const VIDEO: Record<string, Kind> = {
  'video/mp4': { format: 'mp4', ext: 'mp4' }, 'video/quicktime': { format: 'mov', ext: 'mov' },
  'audio/mp4': { format: 'mp4', ext: 'm4a', audioOnly: true },
};
const IMAGE = new Set(['image/jpeg', 'image/png', 'image/webp']);

export const isCleanableVideo = (ct: string) => ct in VIDEO;
export const isCleanableImage = (ct: string) => IMAGE.has(ct);

// One remux at a time (the Trial box has ~512 MB; a stream copy is small, but never several next to a render).
let chain: Promise<unknown> = Promise.resolve();
function serial<T>(fn: () => Promise<T>): Promise<T> {
  const p = chain.then(fn, fn);
  chain = p.catch(() => {});
  return p;
}

function ffmpeg(bin: string, args: string[], timeoutMs = 120_000): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn(bin, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    const t = setTimeout(() => p.kill('SIGKILL'), timeoutMs);
    p.stderr.on('data', d => { if (err.length < 2000) err += String(d); });
    p.on('error', e => { clearTimeout(t); reject(e); });
    p.on('close', code => { clearTimeout(t); code === 0 ? resolve() : reject(new Error(`ffmpeg ${code}: ${err.trim().slice(-300)}`)); });
  });
}

/**
 * A copy of [file] without metadata (and with MUSE's label when [label]), as a new temp file the caller removes.
 * Null when it isn't a video/audio type we clean or ffmpeg can't read it (the caller keeps the original).
 */
export function cleanVideoFile(bin: string, file: string, contentType: string, o: { label?: boolean } = {}): Promise<string | null> {
  const k = VIDEO[contentType];
  if (!k) return Promise.resolve(null);
  return serial(async () => {
    const out = path.join(os.tmpdir(), `muse-clean-${crypto.randomBytes(6).toString('hex')}.${k.ext}`);
    const label = o.label ? ['-metadata', `comment=${AI_LABEL_TEXT}`, '-metadata', `description=${AI_LABEL_TEXT}`] : [];
    try {
      await ffmpeg(bin, ['-y', '-v', 'error', '-i', file,
        ...(k.audioOnly ? ['-map', '0:a'] : ['-map', '0:v?', '-map', '0:a?']), '-dn', '-sn',
        '-map_metadata', '-1', '-map_chapters', '-1', '-c', 'copy',
        '-fflags', '+bitexact', '-flags:v', '+bitexact', '-flags:a', '+bitexact',
        ...label, '-movflags', '+faststart', '-f', k.format, out]);
      if (!(fs.statSync(out).size > 0)) throw new Error('empty');
      return out;
    } catch {
      fs.rmSync(out, { force: true });
      return null;
    }
  });
}

/** The photo re-saved without metadata (orientation applied, sRGB). Null when it isn't a photo sharp can read. */
export async function cleanImageBuffer(buf: Buffer, contentType: string): Promise<Buffer | null> {
  if (!IMAGE.has(contentType)) return null;
  try {
    // .rotate() bakes EXIF orientation into the pixels; sharp writes no metadata unless asked and converts to sRGB.
    const img = sharp(buf, { failOn: 'none' }).rotate().toColourspace('srgb');
    return contentType === 'image/png' ? await img.png({ compressionLevel: 9 }).toBuffer()
      : contentType === 'image/webp' ? await img.webp({ quality: 92 }).toBuffer()
        : await img.jpeg({ quality: 92 }).toBuffer();
  } catch { return null; }
}

/** A buffer cleaned (photo or video); the original when it can't be cleaned. */
export async function cleanBuffer(bin: string, buf: Buffer, contentType: string, o: { label?: boolean } = {}): Promise<Buffer> {
  if (IMAGE.has(contentType)) return (await cleanImageBuffer(buf, contentType)) ?? buf;
  if (!VIDEO[contentType]) return buf;
  const src = path.join(os.tmpdir(), `muse-raw-${crypto.randomBytes(6).toString('hex')}.${VIDEO[contentType]!.ext}`);
  fs.writeFileSync(src, buf);
  let out: string | null = null;
  try {
    out = await cleanVideoFile(bin, src, contentType, o);
    return out ? fs.readFileSync(out) : buf;
  } finally { fs.rmSync(src, { force: true }); if (out) fs.rmSync(out, { force: true }); }
}

/** A file cleaned to a new temp file (the caller removes it), or null to keep the original. Photos are read whole (small). */
export async function cleanFile(bin: string, file: string, contentType: string, o: { label?: boolean } = {}): Promise<string | null> {
  if (VIDEO[contentType]) return cleanVideoFile(bin, file, contentType, o);
  if (!IMAGE.has(contentType)) return null;
  const b = await cleanImageBuffer(await fs.promises.readFile(file), contentType);
  if (!b) return null;
  const out = path.join(os.tmpdir(), `muse-clean-${crypto.randomBytes(6).toString('hex')}${path.extname(file) || '.img'}`);
  await fs.promises.writeFile(out, b);
  return out;
}
