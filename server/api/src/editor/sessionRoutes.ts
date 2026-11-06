// Edit-session routes for the apps (plans/api.md "Edit sessions"). Owner only. Registered from routes/editorAi.ts.
import type { FastifyInstance } from 'fastify';
import { and, desc, eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { badRequest } from '../errors.js';
import { approximateFrame } from './frame.js';
import type * as M from './model.js';
import { editSessions } from './schema.js';
import { editSessionsOf } from './sessions.js';

export function registerEditSessionRoutes(app: FastifyInstance, ctx: Ctx) {
  const svc = editSessionsOf(ctx);
  type P = { Params: { id: string } };
  app.post('/v1/edit-sessions', async req => svc.open(req.user, (req.body ?? {}) as Record<string, unknown>));
  app.get<{ Querystring: { takeId?: string } }>('/v1/edit-sessions', async req => {
    svc.owner(req.user);
    const conds = [eq(editSessions.studioId, req.user.studioId), eq(editSessions.status, 'open')];
    if (req.query?.takeId) conds.push(eq(editSessions.takeId, req.query.takeId));
    const rows = await ctx.db.select().from(editSessions).where(and(...conds)).orderBy(desc(editSessions.updatedAt)).limit(50);
    return Promise.all(rows.map(r => svc.view(r, { history: false })));
  });
  app.get<P>('/v1/edit-sessions/:id', async req => svc.view(await svc.row(req.user, req.params.id)));
  app.get<P & { Querystring: { limit?: string } }>('/v1/edit-sessions/:id/history', async req => svc.history(req.user, req.params.id, Number(req.query?.limit) || 100));
  app.post<P>('/v1/edit-sessions/:id/patch', async req => svc.push(req.user, req.params.id, (req.body ?? {}) as Record<string, unknown>));
  app.post<P>('/v1/edit-sessions/:id/reset', async req => svc.reset(req.user, req.params.id, (req.body ?? {}) as Record<string, unknown>));
  app.post<P>('/v1/edit-sessions/:id/undo', async req => svc.undo(req.user, req.params.id, (req.body ?? {}) as Record<string, unknown>));
  app.post<P>('/v1/edit-sessions/:id/close', async req => svc.close(req.user, req.params.id));
  app.post<P>('/v1/edit-sessions/:id/presence', async req => { await svc.row(req.user, req.params.id); return svc.touch(req.user, req.params.id, (req.body ?? {}) as Record<string, unknown>); });
  app.delete<{ Params: { id: string; device: string } }>('/v1/edit-sessions/:id/presence/:device', async req => { await svc.row(req.user, req.params.id); svc.leave(req.params.id, req.params.device); return { ok: true }; });
  app.post<{ Params: { id: string; rid: string } }>('/v1/edit-sessions/:id/frames/:rid', async req => svc.frameDone(req.user, req.params.id, req.params.rid, (req.body ?? {}) as Record<string, unknown>));
  app.post<{ Params: { id: string; rid: string } }>('/v1/edit-sessions/:id/requests/:rid', async req => svc.appRequestDone(req.user, req.params.id, req.params.rid, (req.body ?? {}) as Record<string, unknown>));
  app.post<{ Params: { id: string; pid: string } }>('/v1/edit-sessions/:id/pending/:pid', async req => svc.answer(req.user, req.params.id, req.params.pid, (req.body ?? {}) as Record<string, unknown>));
  /** The server's approximate frame (what Claude sees when no app renders): PNG. */
  app.get<P & { Querystring: { t?: string; width?: string } }>('/v1/edit-sessions/:id/frame', async (req, reply) => {
    const s = await svc.row(req.user, req.params.id), t = Number(req.query?.t ?? 0);
    if (!Number.isFinite(t) || t < 0) throw badRequest('t: seconds');
    const f = await approximateFrame(ctx, s.studioId, s.project as M.EditProject, t, Number(req.query?.width) || 540);
    return reply.header('content-type', 'image/png').header('x-muse-approximate', '1').send(f.png);
  });
}
