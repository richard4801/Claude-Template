// Recreate this edit routes (workstream 1, plans/api.md "Recreate this edit"): references and their recipes.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { recreateOf } from '../recreate/references.js';

export async function registerRecreateRoutes(app: FastifyInstance, ctx: Ctx) {
  const rx = recreateOf(ctx);
  const id = (req: { params: unknown }) => (req.params as { id: string }).id;
  app.get('/v1/recreate/references', async req => rx.list(req.user));
  app.post('/v1/recreate/references', async req => rx.create(req.user, req.body));
  app.get('/v1/recreate/references/:id', async req => rx.view(await rx.row(req.user, id(req))));
  app.patch('/v1/recreate/references/:id', async req => rx.patch(req.user, id(req), req.body));
  app.delete('/v1/recreate/references/:id', async (req, reply) => { await rx.remove(req.user, id(req)); return reply.status(204).send(); });
  app.get('/v1/recreate/references/:id/contact-sheet', async (req, reply) => {
    const obj = await rx.contactSheet(req.user, id(req));
    return reply.header('content-type', 'image/png').header('cache-control', 'private, max-age=3600').send(obj.body);
  });
}
