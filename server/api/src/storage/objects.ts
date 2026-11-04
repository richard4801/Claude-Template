// Size and sha256 of stored objects, so GPU workers can verify what they download. Recorded when we write an object;
// computed once (by reading it back) for objects that arrived through a presigned PUT.
import crypto from 'node:crypto';
import { eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { uid } from '../lib/util.js';
import { contentTypeFor } from './index.js';

export const sha256Of = (b: Buffer) => crypto.createHash('sha256').update(b).digest('hex');

/** Store bytes and record them. */
export async function putObject(ctx: Pick<Ctx, 'db' | 'storage'>, o: { key: string; body: Buffer; studioId: string; kind: typeof uploads.$inferInsert['kind']; userId?: string | null; contentType?: string }) {
  const contentType = o.contentType ?? contentTypeFor(o.key);
  await ctx.storage.put(o.key, o.body, contentType);
  const row = { studioId: o.studioId, kind: o.kind, storageKey: o.key, contentType, bytes: o.body.length, sha256: sha256Of(o.body), state: 'ready' as const, createdBy: o.userId ?? null, createdAt: Date.now() };
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
export async function putFile(ctx: Pick<Ctx, 'db' | 'storage'>, o: { key: string; file: string; studioId: string; kind: typeof uploads.$inferInsert['kind']; userId?: string | null; contentType?: string }) {
  const fs = await import('node:fs');
  const contentType = o.contentType ?? contentTypeFor(o.key);
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
