// Editor v2 routes (plans/api.md "Editor v2"): AI helper jobs, project validation and audio uploads for the
// on-device editor. Members and owners alike; nothing here names a provider or model to members.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { and, eq } from 'drizzle-orm';
import fs from 'node:fs';
import path from 'node:path';
import { ApiError, badRequest, notFound } from '../errors.js';
import { LOOK_LIMITS } from '../editor/look.js';
import { LOOK_IDS } from '../editor/lookpack.js';
import { LOOK_DIR } from '../editor/photo.js';
import { uid } from '../lib/util.js';
import { editorAi } from '../editor/service.js';
import { registerEditSessionRoutes } from '../editor/sessionRoutes.js';
import { editSessionsOf } from '../editor/sessions.js';
import { repairSourceMatteVersions } from '../editor/repair.js';
import { registerLearnRoutes } from '../editor/learnRoutes.js';
import { EDIT_TOOLS } from '../editor/mcpTools.js';
import * as mcpTools from '../mcp/tools.js';
import { checkProject, lutOfUpload } from '../editor/versions.js';
import { CAPTION_STYLES, FILTERS, HOOKS } from '../editor/presets.js';

const VIDEO_EXT: Record<string, string> = { 'video/mp4': 'mp4', 'video/quicktime': 'mov' };
// Pictures for picture/sticker items (Mac Edit audit 2026-11-08: the apps had no way to bring a picture in).
const IMAGE_EXT: Record<string, string> = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/heic': 'heic' };
const AUDIO_EXT: Record<string, string> = { 'audio/mp4': 'm4a', 'audio/aac': 'aac', 'audio/mpeg': 'mp3', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/webm': 'webm', 'audio/ogg': 'ogg', 'audio/flac': 'flac' };

export async function registerEditorAiRoutes(app: FastifyInstance, ctx: Ctx) {
  const svc = editorAi(ctx);
  registerEditSessionRoutes(app, ctx); // Edit sessions shared with Claude (plans/claude-editing.md A)
  registerLearnRoutes(app, ctx); // the learning editor (workstream 3)
  // Claude's editing tools on MUSE's MCP server: workstream 2's registry (mcp/tools.ts registerMcpTools) when it exists.
  const register = (mcpTools as { registerMcpTools?: (tools: unknown[]) => void }).registerMcpTools;
  if (register) register(EDIT_TOOLS);
  // One-off repair (WS3, 2026-11-08): cut-outs whose matte was the source itself (the mock before 06ec12c). Counts only.
  ctx.later(() => void Promise.all([editSessionsOf(ctx).repairSourceMattes(), repairSourceMatteVersions(ctx)])
    .then(([sessions, versions]) => { if (sessions || versions) ctx.log.info({ sessions, versions }, 'removed cut-outs whose matte was the source (one-off repair)'); })
    .catch(e => ctx.log.warn({ err: (e as Error).message }, 'matte repair failed')), 0);
  ctx.later(() => void svc.recover().then(n => { if (n) ctx.log.info({ n }, 'editor jobs interrupted by the restart were failed and released'); }).catch(e => ctx.log.warn({ err: (e as Error).message }, 'editor recover failed')), 0);

  app.get('/v1/editor/features', async req => svc.features(req.user));
  // workstream 1: the owner's runtime switch and daily cap for paid helpers (no redeploy).
  app.get('/v1/editor/settings', async req => svc.settings(req.user));
  app.patch('/v1/editor/settings', async req => svc.patchSettings(req.user, req.body));
  /** Filters, caption styles and hook templates (the apps also carry these tables; this is the server's copy). */
  app.get('/v1/editor/presets', async () => ({ filters: FILTERS, captionStyles: CAPTION_STYLES, hooks: HOOKS }));

  app.post('/v1/editor/estimate', async req => {
    const e = await svc.estimate(req.user, req.body);
    return { kind: e.kind, usd: e.usd, tokens: e.usd > 0 ? ctx.money.toTokens(e.usd) : 0, free: e.usd === 0, reusesTranscript: !!e.reuse, durationSec: e.src.source.durationSec };
  });
  app.post('/v1/editor/jobs', async req => svc.start(req.user, req.body));
  app.get<{ Querystring: { kind?: string; takeId?: string; uploadId?: string; limit?: string } }>('/v1/editor/jobs', async req => svc.list(req.user, req.query ?? {}));
  app.get<{ Params: { id: string } }>('/v1/editor/jobs/:id', async req => svc.view(await svc.get(req.user, req.params.id), req.user.role));
  app.delete<{ Params: { id: string } }>('/v1/editor/jobs/:id', async req => svc.remove(req.user, req.params.id));

  /** Checks a project against the rules (free); 400 bad_request with the field otherwise. */
  app.post('/v1/editor/validate', async req => {
    const b = req.body as { project?: unknown } | null;
    if (!b || b.project === undefined) throw badRequest('project: Required');
    return { ok: true, ...(await checkProject(ctx, req.user.studioId, b.project, null)) };
  });

  // ---- Looks (filters): the bundled pack, and the user's own .cube files
  app.get('/v1/editor/looks', async () => JSON.parse(fs.readFileSync(path.join(LOOK_DIR, 'looks.json'), 'utf8')));
  app.get<{ Params: { file: string } }>('/v1/editor/looks/:file', async (req, reply) => {
    const m = /^([a-z0-9-]+)\.cube$/.exec(req.params.file);
    if (!m || !LOOK_IDS.has(m[1]!)) throw notFound('Look');
    return reply.header('content-type', 'text/plain; charset=utf-8').header('cache-control', 'public, max-age=86400').send(fs.createReadStream(path.join(LOOK_DIR, req.params.file)));
  });
  /** Where an upload of the studio can be fetched (AI results, imported looks, bin files): → {uploadId, url, contentType, bytes}. */
  app.get<{ Params: { id: string } }>('/v1/editor/uploads/:id', async req => {
    const [up] = await ctx.db.select().from(uploads).where(and(eq(uploads.id, req.params.id), eq(uploads.studioId, req.user.studioId)));
    if (!up) throw notFound('Upload');
    return { uploadId: up.id, url: `${ctx.config.PUBLIC_URL ?? ''}/uploads/${up.storageKey}`, contentType: up.contentType, bytes: up.bytes };
  });
  /** Checks an uploaded .cube (after its PUT): → {uploadId, size, title}; bad_request with the line when it isn't a usable 3D LUT. */
  app.post('/v1/editor/luts/validate', async req => {
    const id = (req.body as { uploadId?: unknown } | null)?.uploadId;
    if (typeof id !== 'string') throw badRequest('uploadId: Required');
    const l = await lutOfUpload(ctx, req.user.studioId, id);
    return { uploadId: id, size: l.size, title: l.title };
  });

  /** A presigned PUT for an audio file (voice-over, music), a video, a picture (stickers) or, with `purpose: "lut"`, a .cube look, to use as an asset upload. */
  app.post('/v1/editor/uploads/presign', async req => {
    const b = (req.body ?? {}) as { contentType?: unknown; bytes?: unknown; purpose?: unknown };
    const ct = typeof b.contentType === 'string' ? b.contentType.toLowerCase() : '';
    const lut = b.purpose === 'lut';
    const ext = lut ? (['text/plain', 'application/octet-stream', 'application/x-cube'].includes(ct) ? 'cube' : undefined) : (AUDIO_EXT[ct] ?? VIDEO_EXT[ct] ?? IMAGE_EXT[ct]);
    if (!ext) throw badRequest(lut ? 'contentType: text/plain or application/octet-stream for a .cube' : `contentType: one of ${[...Object.keys(AUDIO_EXT), ...Object.keys(VIDEO_EXT), ...Object.keys(IMAGE_EXT)].join(', ')}`);
    const max = lut ? LOOK_LIMITS.maxCubeBytes : VIDEO_EXT[ct] ? 2 * 1024 ** 3 : IMAGE_EXT[ct] ? 30 * 1024 ** 2 : 200 * 1024 ** 2;
    if (b.bytes !== undefined && (typeof b.bytes !== 'number' || b.bytes <= 0 || b.bytes > max)) throw new ApiError(400, 'bad_request', `bytes: at most ${max / 1024 ** 2} MB`);
    const id = uid('up'), key = `c/${id}.${ext}`, ttl = 3600;
    const signed = await ctx.storage.presignPut(key, ct, ttl);
    await ctx.db.insert(uploads).values({ id, studioId: req.user.studioId, kind: 'asset', storageKey: key, contentType: ct, bytes: (b.bytes as number) ?? null, state: 'pending', createdBy: req.user.id, createdAt: Date.now() });
    return { uploadId: id, method: 'PUT', url: signed.url, headers: signed.headers, expiresAt: Date.now() + ttl * 1000, fileUrl: `${ctx.config.PUBLIC_URL ?? ''}/uploads/${key}` };
  });
}
