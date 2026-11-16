// Multipart uploads for large files (owner 2026-11-16: edit footage up to 60 min / 2 GB, from a file or a link). Any
// pending upload from POST /v1/uploads/presign or /v1/editor/uploads/presign can go up in parts instead of one PUT:
//   POST   /v1/uploads/:id/multipart {bytes}                → {multipartId, partSize, parts:[{n, url}], expiresAt}
//   GET    /v1/uploads/:id/multipart?multipartId=…          → the parts already stored (resume) and fresh URLs for the rest
//   POST   /v1/uploads/:id/multipart/complete {multipartId, parts:[{n, etag}]} → {uploadId, bytes}
//   DELETE /v1/uploads/:id/multipart?multipartId=…          → cancelled, the parts dropped
// Each part is PUT straight to storage (R2, or the local disk in dev) with the URL given; the ETag header it returns
// goes into complete. After complete the upload is used exactly as after a single PUT (confirm, /v1/imports, Edit).
import type { FastifyInstance } from 'fastify';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { PART_BYTES } from '../storage/index.js';

export const MULTIPART_MAX_BYTES = 2 * 1024 ** 3;
const URL_TTL_SEC = 6 * 3600;

function parse<T>(schema: z.ZodType<T>, body: unknown): T {
  const r = schema.safeParse(body ?? {});
  if (!r.success) throw badRequest(r.error.issues.map(i => `${i.path.join('.') || 'body'}: ${i.message}`).join('; '));
  return r.data;
}

export function registerMultipartRoutes(app: FastifyInstance, ctx: Ctx) {
  const pending = async (u: AuthUser, id: string) => {
    const [up] = await ctx.db.select().from(uploads).where(and(eq(uploads.id, id), eq(uploads.studioId, u.studioId)));
    if (!up || (up.createdBy && up.createdBy !== u.id && u.role !== 'owner')) throw notFound('Upload');
    if (up.state !== 'pending') throw new ApiError(409, 'upload_done', 'This upload is already finished');
    return up;
  };
  const partsFor = (bytes: number) => Math.max(1, Math.ceil(bytes / PART_BYTES));
  const urls = (key: string, mp: string, ns: number[]) => Promise.all(ns.map(async n => ({ n, url: await ctx.storage.multipart.partUrl(key, mp, n, URL_TTL_SEC) })));
  const gone = (e: unknown): never => {
    const m = String((e as Error)?.message ?? e);
    if (/NoSuchUpload|no such multipart|bad multipart id|404/i.test(m) || (e as { name?: string })?.name === 'NoSuchUpload') throw new ApiError(404, 'upload_missing', 'That upload was cancelled or has expired · start it again');
    throw e;
  };

  app.post<{ Params: { id: string } }>('/v1/uploads/:id/multipart', async req => {
    const b = parse(z.object({ bytes: z.number().int().positive() }).strict(), req.body);
    if (b.bytes > MULTIPART_MAX_BYTES) throw new ApiError(400, 'too_big', `This file is ${(b.bytes / 1024 ** 3).toFixed(1)} GB · uploads can be up to 2 GB`);
    const up = await pending(req.user, req.params.id);
    if (up.bytes !== b.bytes) await ctx.db.update(uploads).set({ bytes: b.bytes }).where(eq(uploads.id, up.id));
    const multipartId = await ctx.storage.multipart.create(up.storageKey, up.contentType);
    const n = partsFor(b.bytes);
    return { uploadId: up.id, multipartId, partSize: PART_BYTES, partCount: n, parts: await urls(up.storageKey, multipartId, Array.from({ length: n }, (_, i) => i + 1)),
      expiresAt: Date.now() + URL_TTL_SEC * 1000 };
  });

  app.get<{ Params: { id: string }; Querystring: { multipartId?: string } }>('/v1/uploads/:id/multipart', async req => {
    const mp = req.query.multipartId;
    if (!mp) throw badRequest('multipartId: Required');
    const up = await pending(req.user, req.params.id);
    const done = await ctx.storage.multipart.listParts(up.storageKey, mp).catch(gone);
    const n = partsFor(up.bytes ?? 0), have = new Set(done.map(p => p.n));
    const missing = Array.from({ length: n }, (_, i) => i + 1).filter(i => !have.has(i));
    return { uploadId: up.id, multipartId: mp, partSize: PART_BYTES, partCount: n, done, parts: await urls(up.storageKey, mp, missing), expiresAt: Date.now() + URL_TTL_SEC * 1000 };
  });

  app.post<{ Params: { id: string } }>('/v1/uploads/:id/multipart/complete', async req => {
    const b = parse(z.object({ multipartId: z.string().min(1).max(1024), parts: z.array(z.object({ n: z.number().int().min(1).max(10000), etag: z.string().min(1).max(200) }).strict()).min(1).max(10000) }).strict(), req.body);
    const up = await pending(req.user, req.params.id);
    const ns = b.parts.map(p => p.n).sort((x, y) => x - y);
    if (ns.some((n, i) => n !== i + 1)) throw badRequest('parts: every part from 1 up, once each');
    if (up.bytes && ns.length !== partsFor(up.bytes)) throw badRequest(`parts: ${partsFor(up.bytes)} expected, ${ns.length} sent`);
    try { await ctx.storage.multipart.complete(up.storageKey, b.multipartId, b.parts); } catch (e) {
      if ((e as { badPart?: number }).badPart || /InvalidPart|EntityTooSmall/i.test(String((e as Error).message ?? e) + String((e as { name?: string }).name)))
        throw new ApiError(409, 'upload_part_missing', 'A part of the file didn’t arrive · resume the upload');
      gone(e);
    }
    const head = await ctx.storage.head(up.storageKey);
    if (!head) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it first');
    if (head.size > MULTIPART_MAX_BYTES) {
      await ctx.storage.delete(up.storageKey).catch(() => undefined);
      throw new ApiError(400, 'too_big', 'Uploads can be up to 2 GB');
    }
    await ctx.db.update(uploads).set({ bytes: head.size }).where(eq(uploads.id, up.id));
    return { uploadId: up.id, bytes: head.size };
  });

  app.delete<{ Params: { id: string }; Querystring: { multipartId?: string } }>('/v1/uploads/:id/multipart', async (req, reply) => {
    const mp = req.query.multipartId;
    if (!mp) throw badRequest('multipartId: Required');
    const up = await pending(req.user, req.params.id);
    await ctx.storage.multipart.abort(up.storageKey, mp).catch(() => undefined);
    return reply.status(204).send();
  });
}
