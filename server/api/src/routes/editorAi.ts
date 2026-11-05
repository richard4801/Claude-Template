// Editor v2 routes (plans/api.md "Editor v2"): AI helper jobs, project validation and audio uploads for the
// on-device editor. Members and owners alike; nothing here names a provider or model to members.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { ApiError, badRequest } from '../errors.js';
import { uid } from '../lib/util.js';
import { EditorAiService } from '../editor/service.js';
import { checkProject } from '../editor/versions.js';
import { CAPTION_STYLES, FILTERS, HOOKS } from '../editor/presets.js';

const AUDIO_EXT: Record<string, string> = { 'audio/mp4': 'm4a', 'audio/aac': 'aac', 'audio/mpeg': 'mp3', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/webm': 'webm', 'audio/ogg': 'ogg', 'audio/flac': 'flac' };

export async function registerEditorAiRoutes(app: FastifyInstance, ctx: Ctx) {
  const svc = new EditorAiService(ctx);
  ctx.later(() => void svc.recover().then(n => { if (n) ctx.log.info({ n }, 'editor jobs interrupted by the restart were failed and released'); }).catch(e => ctx.log.warn({ err: (e as Error).message }, 'editor recover failed')), 0);

  app.get('/v1/editor/features', async () => svc.features());
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

  /** A presigned PUT for an audio file (voice-over, music) to use as an asset upload. */
  app.post('/v1/editor/uploads/presign', async req => {
    const b = (req.body ?? {}) as { contentType?: unknown; bytes?: unknown };
    const ct = typeof b.contentType === 'string' ? b.contentType.toLowerCase() : '';
    const ext = AUDIO_EXT[ct];
    if (!ext) throw badRequest(`contentType: one of ${Object.keys(AUDIO_EXT).join(', ')}`);
    if (b.bytes !== undefined && (typeof b.bytes !== 'number' || b.bytes <= 0 || b.bytes > 200 * 1024 ** 2)) throw new ApiError(400, 'bad_request', 'bytes: at most 200 MB');
    const id = uid('up'), key = `c/${id}.${ext}`, ttl = 3600;
    const signed = await ctx.storage.presignPut(key, ct, ttl);
    await ctx.db.insert(uploads).values({ id, studioId: req.user.studioId, kind: 'asset', storageKey: key, contentType: ct, bytes: (b.bytes as number) ?? null, state: 'pending', createdBy: req.user.id, createdAt: Date.now() });
    return { uploadId: id, method: 'PUT', url: signed.url, headers: signed.headers, expiresAt: Date.now() + ttl * 1000, fileUrl: `${ctx.config.PUBLIC_URL ?? ''}/uploads/${key}` };
  });
}
