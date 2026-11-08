// Import a video from a link (WS12; plans/api.md "Import a video from a link"): the generalised link check and rules,
// and imported clips (Library clips the Suite's Swap/Edit and the editor's media bin use like any upload).
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { importsOf } from '../imports/service.js';

export async function registerImportRoutes(app: FastifyInstance, ctx: Ctx) {
  const im = importsOf(ctx);
  const id = (req: { params: unknown }) => (req.params as { id: string }).id;
  app.get('/v1/links/settings', async req => im.settings(req.user));
  app.post('/v1/links/check', async req => im.check(req.user, req.body));
  app.get('/v1/imports', async req => im.list(req.user));
  app.post('/v1/imports', async req => im.create(req.user, req.body));
  app.get('/v1/imports/:id', async req => im.view(await im.row(req.user, id(req))));
  app.patch('/v1/imports/:id', async req => im.rename(req.user, id(req), req.body));
  app.delete('/v1/imports/:id', async (req, reply) => { await im.remove(req.user, id(req)); return reply.status(204).send(); });
}
