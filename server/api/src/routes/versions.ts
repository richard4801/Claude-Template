// Edited versions of a video take (plans/api.md "Video editor", plans/video-editor.md). The apps trim, split, change
// speed and mute ON THE DEVICE and upload the finished MP4 with a presigned PUT; this file only checks the edit list,
// links the upload to a new take (kind "edit") and tells the studio. Nothing here encodes video: the only media work
// is an optional single-frame ffmpeg grab when the app sent no thumbnail. Free: no price, hold or ledger row.
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { and, desc, eq, sql } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../ctx.js';
import { takes, uploads, type ImageRef } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { takeView } from '../services/jobs.js';
import { putObject } from '../storage/objects.js';
import { mediaToolsAvailable, thumbnail } from '../replicate/media.js';
import { checkProject } from '../editor/versions.js';

export const EDIT_SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2] as const;
export const EDIT_LIMITS = { maxSegments: 50, minSegmentSec: 0.1, minOutputSec: 0.5, maxOutputSec: 600, maxJsonBytes: 16 * 1024, endSlackSec: 0.05 } as const;

export type EditSegment = { inSec: number; outSec: number; speed: (typeof EDIT_SPEEDS)[number]; muted?: boolean };
export type EditList = { version: 1; sourceTakeId: string; sourceDurationSec: number; segments: EditSegment[]; mute: boolean };

const Speed = z.number().refine(v => (EDIT_SPEEDS as readonly number[]).includes(v), { message: `must be one of ${EDIT_SPEEDS.join(', ')}` });
const Segment = z.object({ inSec: z.number().finite().nonnegative(), outSec: z.number().finite().positive(), speed: Speed, muted: z.boolean().optional() }).strict();
export const EditListSchema = z.object({
  version: z.literal(1),
  sourceTakeId: z.string().min(1).max(100),
  sourceDurationSec: z.number().finite().positive().max(36_000),
  segments: z.array(Segment).min(1, 'needs at least one segment').max(EDIT_LIMITS.maxSegments, `at most ${EDIT_LIMITS.maxSegments} segments`),
  mute: z.boolean(),
}).strict();

/** Output seconds of an edit list: each kept part of the source, divided by its speed. */
export const outputSeconds = (e: Pick<EditList, 'segments'>) => e.segments.reduce((s, g) => s + (g.outSec - g.inSec) / g.speed, 0);

/** The rules zod can't express; throws `bad_request` naming the field. */
export function checkEditList(e: EditList) {
  let prevOut = 0;
  e.segments.forEach((g, i) => {
    const at = `edits.segments.${i}`;
    if (g.outSec <= g.inSec) throw badRequest(`${at}: outSec must be after inSec`);
    if (g.outSec - g.inSec < EDIT_LIMITS.minSegmentSec - 1e-9) throw badRequest(`${at}: a segment must be at least ${EDIT_LIMITS.minSegmentSec} s`);
    if (g.outSec > e.sourceDurationSec + EDIT_LIMITS.endSlackSec) throw badRequest(`${at}: outSec is past the end of the video`);
    if (i > 0 && g.inSec < prevOut - 1e-9) throw badRequest(`${at}: segments must be in order and not overlap`);
    prevOut = g.outSec;
  });
  const out = outputSeconds(e);
  if (out < EDIT_LIMITS.minOutputSec) throw badRequest(`edits: the edited video must be at least ${EDIT_LIMITS.minOutputSec} s`);
  if (out > EDIT_LIMITS.maxOutputSec) throw badRequest(`edits: the edited video must be at most ${EDIT_LIMITS.maxOutputSec} s`);
  return out;
}

const ImageRefIn = z.object({ asset: z.string().max(100).optional(), url: z.string().max(2000).optional() });
const VersionBody = z.object({
  uploadId: z.string().min(1).max(100),
  thumbUploadId: z.string().min(1).max(100).optional(),
  thumb: ImageRefIn.optional(),
  edits: z.unknown(),
  durationSec: z.number().finite().positive(),
  width: z.number().int().min(16).max(4096),
  height: z.number().int().min(16).max(4096),
  fps: z.number().finite().min(1).max(240).optional(),
  aiLabel: z.boolean().optional(), // Edit suite export "Label as AI-generated" (workstream 3); off unless the user switched it on
});

const parse = <T>(schema: z.ZodType<T>, body: unknown, prefix = ''): T => {
  const r = schema.safeParse(body ?? {});
  if (!r.success) { const i = r.error.issues[0]!; throw badRequest(`${[prefix, ...i.path].filter(x => x !== '').join('.') || 'body'}: ${i.message}`); }
  return r.data;
};

const isVideo = (t: typeof takes.$inferSelect) => (t.kind === 'take' || (t.kind as string) === 'edit') && !!t.mediaKey;
/** The source an edit take was cut from (kept in `media`, so no migration was needed). */
export const parentOf = (t: typeof takes.$inferSelect) => (t.media as { parentTakeId?: string } | null)?.parentTakeId;

export async function registerVersionRoutes(app: FastifyInstance, ctx: Ctx) {
  const db = ctx.db;
  const pub = ctx.config.PUBLIC_URL ?? '';
  const uploadUrl = (key: string) => `${pub}/uploads/${key}`;
  const emitTake = (t: typeof takes.$inferSelect) => void ctx.hub.emit(t.studioId, v => ({ type: 'take', take: takeView(t, pub, v.userId) }));

  async function sourceTake(studioId: string, id: string) {
    const [t] = await db.select().from(takes).where(and(eq(takes.id, id), eq(takes.studioId, studioId)));
    if (!t) throw notFound('Take');
    return t;
  }

  /** A thumbnail the app uploaded: a presigned image upload, or an ImageRef from POST /v1/uploads/images. Must be this studio's. */
  async function clientThumb(studioId: string, b: { thumbUploadId?: string; thumb?: { url?: string; asset?: string } }): Promise<ImageRef | null> {
    let row: typeof uploads.$inferSelect | undefined;
    if (b.thumbUploadId) {
      [row] = await db.select().from(uploads).where(and(eq(uploads.id, b.thumbUploadId), eq(uploads.studioId, studioId)));
      if (!row) throw notFound('Thumbnail upload');
    } else if (b.thumb?.url) {
      const m = /(?:^|\/)uploads\/(u\/[A-Za-z0-9._-]+)$/.exec(b.thumb.url);
      if (!m) throw badRequest('thumb: use an image uploaded to MUSE');
      [row] = await db.select().from(uploads).where(and(eq(uploads.storageKey, m[1]!), eq(uploads.studioId, studioId)));
      if (!row) throw badRequest('thumb: use an image uploaded to MUSE');
    } else if (b.thumb?.asset) throw badRequest('thumb: use an image uploaded to MUSE');
    else return null;
    if (row.kind !== 'image' || !row.contentType.startsWith('image/')) throw badRequest('thumb: must be an image');
    if (!(await ctx.storage.head(row.storageKey))) throw new ApiError(409, 'upload_missing', 'The thumbnail has not arrived yet · upload it to the URL first');
    if (row.state !== 'ready') await db.update(uploads).set({ state: 'ready' }).where(eq(uploads.id, row.id));
    return { url: uploadUrl(row.storageKey) };
  }

  /** No thumbnail from the app: one JPEG frame (ffmpeg seeks into the stored file; the video is not re-encoded). Best effort. */
  async function serverThumb(t: typeof takes.$inferSelect) {
    const c = ctx.config;
    if (!t.mediaKey || !(await mediaToolsAvailable(c.FFMPEG_PATH, c.FFPROBE_PATH))) return;
    const out = path.join(os.tmpdir(), `${uid('thumb')}.jpg`);
    try {
      const src = await ctx.storage.presignGet(t.mediaKey, 600);
      const dur = Number((t.media as { durationSec?: number } | null)?.durationSec ?? 1);
      await thumbnail(c.FFMPEG_PATH, src, out, Math.min(0.5, dur / 2));
      const key = `g/${uid('thumb')}.jpg`;
      await putObject(ctx, { key, body: await fs.promises.readFile(out), studioId: t.studioId, kind: 'generated', userId: t.userId, contentType: 'image/jpeg' });
      const [u] = await db.update(takes).set({ thumb: { url: uploadUrl(key) } }).where(eq(takes.id, t.id)).returning();
      if (u) emitTake(u);
    } catch (e) {
      ctx.log.warn({ err: (e as Error).message, take: t.id }, 'edit thumbnail failed; keeping the source thumbnail');
    } finally {
      await fs.promises.rm(out, { force: true }).catch(() => {});
    }
  }

  app.post<{ Params: { id: string } }>('/v1/takes/:id/versions', async req => {
    const u = req.user;
    // Editor v2 (workstream 3): a v2 project is checked by editor/versions.ts (its own size limit and rules).
    const v2 = ((req.body as { edits?: { version?: unknown } } | null)?.edits?.version) === 2;
    if (!v2 && JSON.stringify((req.body as { edits?: unknown } | null)?.edits ?? null).length > EDIT_LIMITS.maxJsonBytes) throw badRequest(`edits: at most ${EDIT_LIMITS.maxJsonBytes / 1024} KB`);
    const b = parse(VersionBody, req.body);
    if (b.edits === undefined) throw badRequest('edits: Required');
    const edits = v2 ? (b.edits as EditList) : (parse(EditListSchema, b.edits, 'edits') as EditList);
    const expected = v2 ? (await checkProject(ctx, u.studioId, b.edits, req.params.id)).durationSec : checkEditList(edits);
    if (Math.abs(b.durationSec - expected) > Math.max(0.5, expected * 0.05))
      throw badRequest(`durationSec: ${b.durationSec.toFixed(2)} s doesn't match the edit list (${expected.toFixed(2)} s)`);

    const src = await sourceTake(u.studioId, req.params.id);
    if (!isVideo(src)) throw badRequest('Edit works on a video take');
    if (edits.sourceTakeId !== src.id) throw badRequest('edits.sourceTakeId: must be the take in the URL');

    const [up] = await db.select().from(uploads).where(and(eq(uploads.id, b.uploadId), eq(uploads.studioId, u.studioId)));
    if (!up) throw notFound('Upload');
    if (up.kind !== 'clip' || !up.contentType.startsWith('video/')) throw badRequest('uploadId: must be a video upload');
    const [used] = await db.select({ id: takes.id }).from(takes).where(eq(takes.mediaKey, up.storageKey));
    if (used) throw new ApiError(409, 'upload_used', 'This video was already saved');
    const head = await ctx.storage.head(up.storageKey);
    if (!head) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it to the URL first');
    const thumb = await clientThumb(u.studioId, b);
    await db.update(uploads).set({ state: 'ready', bytes: head.size }).where(eq(uploads.id, up.id));

    const [row] = await db.insert(takes).values({
      id: uid('take'), studioId: u.studioId, userId: u.id, kind: 'edit' as 'take', jobId: null, modelId: src.modelId,
      index: 1, of: 1, title: src.title, label: 'Edited', engineLabel: src.engineLabel, cost: 0, seed: src.seed, status: 'test',
      thumb: thumb ?? src.thumb ?? null, prompt: src.prompt, publicPrompt: src.publicPrompt,
      templateId: src.templateId, templateName: src.templateName, templateOwnerId: src.templateOwnerId,
      mediaKey: up.storageKey,
      media: { durationSec: b.durationSec, width: b.width, height: b.height, ...(b.fps ? { fps: b.fps } : {}), bytes: head.size, contentType: up.contentType,
        parentTakeId: src.id, edits, ...(b.aiLabel ? { aiLabel: true } : {}) },
      createdAt: Date.now(),
    }).returning();
    emitTake(row!);
    if (!thumb) void serverThumb(row!);
    return takeView(row!, pub, u.id);
  });

  app.get<{ Params: { id: string } }>('/v1/takes/:id/versions', async req => {
    const src = await sourceTake(req.user.studioId, req.params.id);
    const rows = await db.select().from(takes)
      .where(and(eq(takes.studioId, req.user.studioId), sql`${takes.kind} = 'edit'`, sql`${takes.media}->>'parentTakeId' = ${src.id}`))
      .orderBy(desc(takes.createdAt));
    return rows.map(t => takeView(t, pub, req.user.id));
  });
}
