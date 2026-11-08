// Bring your own provider routes (WS5, plans/api.md "Bring your own provider"). Owner only. Keys are accepted here and
// never returned: responses carry the last 4 characters and a status.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';

export async function registerProviderRoutes(app: FastifyInstance, ctx: Ctx) {
  const owner = { config: { owner: true } };
  const byo = ctx.suite.byo;
  app.get('/v1/providers/kinds', owner, async () => byo.kinds());
  app.get('/v1/providers', owner, async req => byo.list(req.user));
  app.post('/v1/providers', owner, async (req, reply) => reply.status(201).send(await byo.add(req.user, req.body)));
  // Models across all the studio's providers (before /:id so "models" isn't taken for an id).
  app.get('/v1/providers/models', owner, async req => byo.models(req.user));
  app.patch<{ Params: { mid: string } }>('/v1/providers/models/:mid', owner, async req => byo.patchModel(req.user, req.params.mid, req.body));
  app.delete<{ Params: { mid: string } }>('/v1/providers/models/:mid', owner, async (req, reply) => { await byo.removeModel(req.user, req.params.mid); return reply.status(204).send(); });
  app.patch<{ Params: { id: string } }>('/v1/providers/:id', owner, async req => byo.patch(req.user, req.params.id, req.body));
  app.delete<{ Params: { id: string } }>('/v1/providers/:id', owner, async (req, reply) => { await byo.remove(req.user, req.params.id); return reply.status(204).send(); });
  app.get<{ Params: { id: string } }>('/v1/providers/:id/models', owner, async req => byo.browse(req.user, req.params.id, req.query));
  app.post<{ Params: { id: string } }>('/v1/providers/:id/models', owner, async (req, reply) => reply.status(201).send(await byo.addModel(req.user, req.params.id, req.body)));
}
