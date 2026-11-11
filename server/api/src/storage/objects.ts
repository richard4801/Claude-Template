// Size and sha256 of stored objects, so GPU workers can verify what they download. Recorded when we write an object;
// computed once (by reading it back) for objects that arrived through a presigned PUT.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { uid } from '../lib/util.js';
import { cleanBuffer, cleanFile, isCleanableImage, isCleanableVideo } from './clean.js';
import { contentTypeFor } from './index.js';

/** Storage context; [config] gives the ffmpeg to clean videos with (else `ffmpeg` on the PATH). */
type StoreCtx = Pick<Ctx, 'db' | 'storage'> & { config?: { FFMPEG_PATH?: string } };
/** Photos and videos are stored without metadata (storage/clean.ts); [label] adds MUSE's AI label (videos). A member's
 * own clip (kind 'clip': source material, e.g. a Recreate reference) and [keepMetadata] are stored as sent. */
type CleanOpts = { keepMetadata?: boolean; label?: boolean };
const ffmpegOf = (ctx: StoreCtx) => ctx.config?.FFMPEG_PATH ?? 'ffmpeg';

export const sha256Of = (b: Buffer) => crypto.createHash('sha256').update(b).digest('hex');

/** Store bytes and record them. */
export async function putObject(ctx: StoreCtx, o: { key: string; body: Buffer; studioId: string; kind: typeof uploads.$inferInsert['kind']; userId?: string | null; contentType?: string } & CleanOpts) {
  const contentType = o.contentType ?? contentTypeFor(o.key);
  const body = o.keepMetadata || o.kind === 'clip' ? o.body : await cleanBuffer(ffmpegOf(ctx), o.body, contentType, { label: o.label });
  await ctx.storage.put(o.key, body, contentType);
  const row = { studioId: o.studioId, kind: o.kind, storageKey: o.key, contentType, bytes: body.length, sha256: sha256Of(body), state: 'ready' as const, createdBy: o.userId ?? null, createdAt: Date.now() };
  const [existing] = await ctx.db.select({ id: uploads.id }).from(uploads).where(eq(uploads.storageKey, o.key));
  if (existing) await ctx.db.update(uploads).set(row).where(eq(uploads.id, existing.id));
  else await ctx.db.insert(uploads).values({ id: uid('up'), ...row });
  return { bytes: row.bytes, sha256: row.sha256 };
}

/** {bytes, sha256} of a stored object; hashes it once if we don't know yet. Null if it isn't there. */
export async function objectInfo(ctx: Pick<Ctx, 'db' | 'storage'>, key: string): Promise<{ bytes: number; sha256: string } | null> {
  const [u] = await ctx.db.select().from(uploads).where(eq(uploads.storageKey, key));
  if (u?.sha256 && u.bytes != null && u.state === 'ready') return { bytes: u.bytes, sha256: u.sha256 };
  const obj = await ctx.storage.get(key);
  if (!obj) return null;
  const h = crypto.createHash('sha256');
  let bytes = 0;
  for await (const chunk of obj.body) { h.update(chunk as Buffer); bytes += (chunk as Buffer).length; }
  const sha = h.digest('hex');
  if (u) await ctx.db.update(uploads).set({ bytes, sha256: sha, state: 'ready' }).where(eq(uploads.id, u.id));
  return { bytes, sha256: sha };
}

/** Store a file from disk (renders: streamed, never held in memory) and record it. */
export async function putFile(ctx: StoreCtx, o: { key: string; file: string; studioId: string; kind: typeof uploads.$inferInsert['kind']; userId?: string | null; contentType?: string } & CleanOpts) {
  const contentType = o.contentType ?? contentTypeFor(o.key);
  const clean = o.keepMetadata || o.kind === 'clip' ? null : await cleanFile(ffmpegOf(ctx), o.file, contentType, { label: o.label });
  try { return await putFileAs(ctx, { ...o, file: clean ?? o.file, contentType }); } finally { if (clean) await fs.promises.rm(clean, { force: true }); }
}

async function putFileAs(ctx: StoreCtx, o: { key: string; file: string; studioId: string; kind: typeof uploads.$inferInsert['kind']; userId?: string | null; contentType: string }) {
  const contentType = o.contentType;
  const bytes = (await fs.promises.stat(o.file)).size;
  const h = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(o.file)) h.update(chunk as Buffer);
  const sha = h.digest('hex');
  await ctx.storage.putStream(o.key, fs.createReadStream(o.file), contentType, bytes);
  const row = { studioId: o.studioId, kind: o.kind, storageKey: o.key, contentType, bytes, sha256: sha, state: 'ready' as const, createdBy: o.userId ?? null, createdAt: Date.now() };
  const [existing] = await ctx.db.select({ id: uploads.id }).from(uploads).where(eq(uploads.storageKey, o.key));
  if (existing) await ctx.db.update(uploads).set(row).where(eq(uploads.id, existing.id));
  else await ctx.db.insert(uploads).values({ id: uid('up'), ...row });
  return { bytes, sha256: sha };
}

/**
 * Cleans an object that arrived through a presigned PUT (app exports, GPU outputs) in place: streamed to a temp file,
 * remuxed/re-saved, written back under the same key and re-recorded. Best effort: on any failure the object stays as
 * it was. Returns the new size, or null when nothing changed.
 */
export async function cleanStored(ctx: StoreCtx, key: string, contentType: string, o: { label?: boolean } = {}): Promise<number | null> {
  if (!isCleanableVideo(contentType) && !isCleanableImage(contentType)) return null;
  const obj = await ctx.storage.get(key);
  if (!obj) return null;
  const src = path.join(os.tmpdir(), `muse-stored-${crypto.randomBytes(6).toString('hex')}${path.extname(key)}`);
  let clean: string | null = null;
  try {
    await pipeline(obj.body, fs.createWriteStream(src));
    clean = await cleanFile(ffmpegOf(ctx), src, contentType, o);
    if (!clean) return null;
    const bytes = (await fs.promises.stat(clean)).size, h = crypto.createHash('sha256');
    for await (const chunk of fs.createReadStream(clean)) h.update(chunk as Buffer);
    await ctx.storage.putStream(key, fs.createReadStream(clean), contentType, bytes);
    await ctx.db.update(uploads).set({ bytes, sha256: h.digest('hex') }).where(eq(uploads.storageKey, key));
    return bytes;
  } finally {
    await fs.promises.rm(src, { force: true });
    if (clean) await fs.promises.rm(clean, { force: true });
  }
}
