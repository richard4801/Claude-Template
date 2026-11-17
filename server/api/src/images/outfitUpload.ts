// A picture the person puts in an outfit slot themselves (owner 2026-11-17: "upload image manually to already generated
// outfits. I shouldn't need to generate if I already have it"). Read from storage, checked to be a photo, and saved like
// a generated outfit picture: upright (EXIF orientation applied), sRGB, no metadata, JPEG, long edge at most 2048.
import sharp from 'sharp';
import type { Ctx } from '../ctx.js';
import { cleanMemberPhoto } from '../storage/clean.js';

/** Longest edge of an outfit picture put in by hand (generated ones are 768×1024; a sharper upload is kept up to this). */
export const OUTFIT_UPLOAD_MAX_PX = 2048;
/** Largest stored file read for it (a big PNG from a Mac included). */
export const OUTFIT_UPLOAD_MAX_BYTES = 40 * 1024 * 1024;
const PHOTO_FORMATS = new Set(['jpeg', 'png', 'webp', 'heif']);

/** The stored object's bytes (null when missing or over the limit). */
export async function storedBytes(ctx: Pick<Ctx, 'storage'>, key: string, max = OUTFIT_UPLOAD_MAX_BYTES): Promise<Buffer | null> {
  const obj = await ctx.storage.get(key);
  if (!obj) return null;
  const parts: Buffer[] = [];
  let size = 0;
  for await (const ch of obj.body) {
    size += (ch as Buffer).length;
    if (size > max) return null;
    parts.push(ch as Buffer);
  }
  return Buffer.concat(parts);
}

/**
 * The upload as an outfit picture (JPEG), or null when it isn't a photo (jpeg, png, webp or heic). HEIC becomes JPEG
 * the same way member uploads do (storage/clean.ts).
 */
export async function outfitPicture(buf: Buffer): Promise<Buffer | null> {
  let format: string | undefined;
  try { format = (await sharp(buf, { failOn: 'none' }).metadata()).format; } catch { format = undefined; }
  // sharp reads a HEIC's container but often not its pixels: heif-convert first (storage/clean.ts), as /v1/uploads/images does.
  if (!format && isHeic(buf)) format = 'heif';
  if (!format || !PHOTO_FORMATS.has(format)) return null;
  let src = buf;
  if (format === 'heif' && !(await decodes(buf))) {
    const c = await cleanMemberPhoto(buf, 'image/heic');
    if (!c) return null;
    src = c.body;
  }
  try {
    return await sharp(src, { failOn: 'none' }).rotate().toColourspace('srgb')
      .resize(OUTFIT_UPLOAD_MAX_PX, OUTFIT_UPLOAD_MAX_PX, { fit: 'inside', withoutEnlargement: true })
      .flatten({ background: '#ffffff' }).jpeg({ quality: 92 }).toBuffer();
  } catch { return null; }
}

/** An ISO-BMFF file whose brand is a HEIC/HEIF one. */
function isHeic(b: Buffer) {
  if (b.length < 12 || b.toString('latin1', 4, 8) !== 'ftyp') return false;
  return /^(heic|heix|hevc|hevx|heim|heis|mif1|msf1)$/.test(b.toString('latin1', 8, 12));
}
async function decodes(b: Buffer) {
  try { await sharp(b).resize(8, 8).raw().toBuffer(); return true; } catch { return false; }
}
