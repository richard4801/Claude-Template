// workstream 1 (owner-approved via the coordinator): reference images the owner attaches to a Claude chat message.
// Each is one of the studio's confirmed image uploads (by uploadId), checked (jpeg/png/webp/heic, ≤ 10 MB, ≤ 4 a
// message), normalised (HEIC → JPEG, the long edge ≤ 2048 px, ≤ 5 MB so the Claude API takes it) and stored privately on
// the thread under ca/ (not served by /uploads; only signed links). The Mac downloads them for its Claude Code turn;
// the API fallback sends them as image blocks; suite_add_reference puts one into the Suite draft.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';

const run = promisify(execFile);
export const MAX_ATTACHMENTS = 4, MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;
const API_MAX_BYTES = 5 * 1024 * 1024, LONG_EDGE = 2048, URL_TTL_SEC = 3600;
const TYPES: Record<string, 'jpeg' | 'png' | 'webp' | 'heic'> = { 'image/jpeg': 'jpeg', 'image/jpg': 'jpeg', 'image/png': 'png', 'image/webp': 'webp', 'image/heic': 'heic', 'image/heif': 'heic' };
export type AttachmentMime = 'image/jpeg' | 'image/png' | 'image/webp';
export type Attachment = { id: string; uploadId: string; key: string; mimeType: AttachmentMime; bytes: number; width: number; height: number };

export const AttachmentsInput = z.array(z.object({ uploadId: z.string().min(1).max(80) }).strict()).max(MAX_ATTACHMENTS, `attachments: at most ${MAX_ATTACHMENTS} images a message`);

/** The studio's confirmed image upload, its bytes checked (type and size). */
export async function uploadImage(ctx: Ctx, u: AuthUser, uploadId: string) {
  const [up] = await ctx.db.select().from(uploads).where(and(eq(uploads.id, uploadId), eq(uploads.studioId, u.studioId)));
  if (!up) throw notFound('Upload');
  if (up.state !== 'ready') throw new ApiError(409, 'upload_not_ready', `${uploadId}: the upload isn't confirmed yet`);
  const kind = TYPES[up.contentType.toLowerCase()];
  if (up.kind !== 'image' || !kind) throw badRequest(`${uploadId}: attach a JPEG, PNG, WebP or HEIC image`);
  const obj = await ctx.storage.get(up.storageKey);
  if (!obj) throw new ApiError(409, 'upload_not_ready', `${uploadId}: the file hasn't arrived yet`);
  const parts: Buffer[] = [];
  let size = 0;
  for await (const ch of obj.body) { size += (ch as Buffer).length; if (size > MAX_ATTACHMENT_BYTES) throw badRequest(`${uploadId}: at most 10 MB an image`); parts.push(ch as Buffer); }
  return { up, buf: Buffer.concat(parts), kind };
}

/** HEIC → JPEG (heif-convert from libheif); a clear 415 when the server can't read it. */
async function fromHeic(buf: Buffer, uploadId: string): Promise<Buffer> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-heic-'));
  try {
    const src = path.join(dir, 'in.heic'), out = path.join(dir, 'out.jpg');
    fs.writeFileSync(src, buf);
    await run('heif-convert', ['-q', '92', src, out], { timeout: 60_000 });
    return fs.readFileSync(out);
  } catch {
    throw new ApiError(415, 'unsupported_image', `${uploadId}: this HEIC photo can't be read · send it as JPEG`);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

/** Decoded, upright, long edge ≤ 2048 px; kept as PNG/WebP/JPEG when small enough for the API, else JPEG. */
export async function normaliseImage(buf: Buffer, kind: 'jpeg' | 'png' | 'webp' | 'heic', uploadId: string): Promise<{ buf: Buffer; mimeType: AttachmentMime; width: number; height: number }> {
  const sharp = (await import('sharp')).default;
  const input = kind === 'heic' ? await fromHeic(buf, uploadId) : buf;
  let meta: { format?: string };
  try { meta = await sharp(input).metadata(); } catch { throw badRequest(`${uploadId}: not a readable image`); }
  const fmt = meta.format === 'jpg' ? 'jpeg' : meta.format;
  if (fmt !== 'jpeg' && fmt !== 'png' && fmt !== 'webp') throw badRequest(`${uploadId}: attach a JPEG, PNG, WebP or HEIC image`);
  const base = () => sharp(input).rotate().resize(LONG_EDGE, LONG_EDGE, { fit: 'inside', withoutEnlargement: true });
  let out = await (fmt === 'png' ? base().png() : fmt === 'webp' ? base().webp({ quality: 90 }) : base().jpeg({ quality: 90 })).toBuffer({ resolveWithObject: true });
  let mimeType: AttachmentMime = `image/${fmt}`;
  if (out.data.length > API_MAX_BYTES) { out = await base().flatten({ background: '#ffffff' }).jpeg({ quality: 85 }).toBuffer({ resolveWithObject: true }); mimeType = 'image/jpeg'; }
  return { buf: out.data, mimeType, width: out.info.width, height: out.info.height };
}

const EXT: Record<AttachmentMime, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };

/** Checks and stores a message's attachments on the thread (all or none). */
export async function storeAttachments(ctx: Ctx, u: AuthUser, threadId: string, input: unknown): Promise<Attachment[]> {
  if (input === undefined || input === null) return [];
  const p = AttachmentsInput.safeParse(input);
  if (!p.success) throw badRequest(p.error.issues[0]?.message ?? 'attachments: invalid');
  const ids = [...new Set(p.data.map(x => x.uploadId))];
  const ready = await Promise.all(ids.map(async id => { const { buf, kind } = await uploadImage(ctx, u, id); return { id, ...(await normaliseImage(buf, kind, id)) }; }));
  const out: Attachment[] = [];
  for (const r of ready) {
    const id = uid('att'), key = `ca/${threadId}/${id}.${EXT[r.mimeType]}`;
    await ctx.storage.put(key, r.buf, r.mimeType);
    out.push({ id, uploadId: r.id, key, mimeType: r.mimeType, bytes: r.buf.length, width: r.width, height: r.height });
  }
  return out;
}

/** What the apps see: no storage key, a private link valid 1 h. */
export async function attachmentViews(ctx: Ctx, list: Attachment[] | null | undefined) {
  if (!list?.length) return undefined;
  return Promise.all(list.map(async a => ({ id: a.id, uploadId: a.uploadId, mimeType: a.mimeType, bytes: a.bytes, width: a.width, height: a.height, url: await ctx.storage.presignGet(a.key, URL_TTL_SEC) })));
}

/** The Claude API's image blocks for these attachments (images that went missing are left out). */
export async function imageBlocks(ctx: Ctx, list: Attachment[]) {
  const out: { type: 'image'; source: { type: 'base64'; media_type: AttachmentMime; data: string } }[] = [];
  for (const a of list) {
    const obj = await ctx.storage.get(a.key);
    if (!obj) continue;
    const parts: Buffer[] = [];
    for await (const ch of obj.body) parts.push(ch as Buffer);
    out.push({ type: 'image', source: { type: 'base64', media_type: a.mimeType, data: Buffer.concat(parts).toString('base64') } });
  }
  return out;
}

/** The line Claude reads with the images, so it can name them to suite_add_reference. */
export const attachmentLine = (list: Attachment[]) =>
  list.length ? `[Attached image${list.length > 1 ? 's' : ''}, in order: ${list.map((a, i) => `${i + 1}. uploadId ${a.uploadId}`).join('; ')}]` : '';
