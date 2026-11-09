// Own fonts (Edit suite text): an uploaded .ttf/.otf, checked and named from its `name` table. WOFF/WOFF2 and
// collections (.ttc) are refused.
import { and, eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';

export const FONT_LIMITS = { maxBytes: 10 * 1024 * 1024 };
/** Upload content types accepted for a font, to the stored extension. */
export const FONT_EXT: Record<string, 'ttf' | 'otf'> = {
  'font/ttf': 'ttf', 'font/sfnt': 'ttf', 'application/x-font-ttf': 'ttf', 'application/font-sfnt': 'ttf',
  'font/otf': 'otf', 'application/vnd.ms-opentype': 'otf', 'application/x-font-otf': 'otf', 'application/octet-stream': 'ttf',
};

export class FontError extends Error {}

/**
 * The font's display name: full name (name ID 4), else family + subfamily (1 + 2); at most 80 characters. Throws
 * FontError when [b] is not a TrueType or OpenType font.
 */
export function fontName(b: Buffer): string {
  if (b.length < 12) throw new FontError('not a TrueType or OpenType font');
  const tag = b.readUInt32BE(0);
  if (tag !== 0x00010000 && tag !== 0x74727565 /* 'true' */ && tag !== 0x4f54544f /* 'OTTO' */) throw new FontError('not a TrueType or OpenType font');
  const n = b.readUInt16BE(4);
  if (12 + n * 16 > b.length) throw new FontError('not a TrueType or OpenType font');
  let nameOff = -1, nameLen = 0;
  for (let i = 0; i < n; i++) {
    const r = 12 + i * 16;
    if (b.toString('latin1', r, r + 4) === 'name') { nameOff = b.readUInt32BE(r + 8); nameLen = b.readUInt32BE(r + 12); }
  }
  const names = new Map<number, string>();
  if (nameOff >= 0 && nameOff + 6 <= b.length && nameOff + nameLen <= b.length) {
    const count = b.readUInt16BE(nameOff + 2), strings = nameOff + b.readUInt16BE(nameOff + 4);
    for (let i = 0; i < count; i++) {
      const r = nameOff + 6 + i * 12;
      if (r + 12 > b.length) break;
      const platform = b.readUInt16BE(r), id = b.readUInt16BE(r + 6), len = b.readUInt16BE(r + 8), off = strings + b.readUInt16BE(r + 10);
      if (![1, 2, 4].includes(id) || off + len > b.length) continue;
      // Windows/Unicode names are UTF-16BE; Mac Roman is read as Latin-1. Windows wins.
      const s = platform === 3 || platform === 0 ? utf16be(b.subarray(off, off + len)) : platform === 1 ? b.toString('latin1', off, off + len) : '';
      if (s.trim() && (!names.has(id) || platform === 3)) names.set(id, s.trim());
    }
  }
  const full = names.get(4) ?? [names.get(1), names.get(2)].filter(Boolean).join(' ');
  return (full || 'Font').replace(/[\u0000-\u001f]/g, '').slice(0, 80);
}

function utf16be(b: Buffer): string {
  let s = '';
  for (let i = 0; i + 1 < b.length; i += 2) s += String.fromCharCode(b.readUInt16BE(i));
  return s;
}

const fontCache = new Map<string, string>();
/** An uploaded font of the studio, checked and named (cached by storage key). bad_request when it isn't a usable .ttf/.otf. */
export async function fontOfUpload(ctx: Ctx, studioId: string, uploadId: string): Promise<{ name: string }> {
  const [up] = await ctx.db.select().from(uploads).where(and(eq(uploads.id, uploadId), eq(uploads.studioId, studioId)));
  if (!up) throw notFound('Upload');
  if (!/\.(ttf|otf)$/.test(up.storageKey)) throw badRequest('uploadId: not a font upload');
  const hit = fontCache.get(up.storageKey);
  if (hit) return { name: hit };
  const obj = await ctx.storage.get(up.storageKey);
  if (!obj) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it to the URL first');
  const chunks: Buffer[] = [];
  let n = 0;
  for await (const c of obj.body as AsyncIterable<Buffer>) { n += c.length; if (n > FONT_LIMITS.maxBytes) throw badRequest('the font is over 10 MB'); chunks.push(Buffer.from(c)); }
  let name: string;
  try { name = fontName(Buffer.concat(chunks)); } catch (e) { if (e instanceof FontError) throw badRequest(e.message); throw e; }
  if (up.state !== 'ready') await ctx.db.update(uploads).set({ state: 'ready', bytes: n }).where(eq(uploads.id, up.id));
  if (fontCache.size > 100) fontCache.clear();
  fontCache.set(up.storageKey, name);
  return { name };
}
