// The learning editor's routes (plans/api.md "Learning editor", workstream 3). Owner only.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { learningOf } from './learn.js';

type Q = Record<string, string | undefined>;
const list = (v?: string) => (v ? v.split(',').map(x => x.trim()).filter(Boolean) : undefined);

export function registerLearnRoutes(app: FastifyInstance, ctx: Ctx) {
  const L = learningOf(ctx);
  const body = (b: unknown) => (b ?? {}) as Record<string, unknown>;
  type P = { Params: { id: string } };
  // Recipe library
  app.get<{ Querystring: Q }>('/v1/learn/recipes', async req => L.recipes(req.user, { q: req.query.q, tags: list(req.query.tags), origin: req.query.origin, limit: Number(req.query.limit) || undefined }));
  app.get<{ Querystring: Q }>('/v1/learn/recipes/nearest', async req => L.nearest(req.user, { recipeId: req.query.recipeId, referenceId: req.query.referenceId, takeId: req.query.takeId,
    k: Number(req.query.k) || undefined, origin: req.query.origin }));
  app.get<{ Querystring: Q }>('/v1/learn/tags', async req => L.topTags(req.user, Number(req.query.limit) || 8));
  app.get<P>('/v1/learn/recipes/:id', async req => L.recipe(req.user, req.params.id));
  app.patch<P>('/v1/learn/recipes/:id', async req => L.updateRecipe(req.user, req.params.id, body(req.body)));
  app.delete<P>('/v1/learn/recipes/:id', async (req, reply) => { await L.removeRecipe(req.user, req.params.id); return reply.status(204).send(); });
  // Corrections
  app.get<{ Querystring: Q }>('/v1/learn/corrections', async req => L.corrections(req.user, { limit: Number(req.query.limit) || undefined, sessionId: req.query.sessionId, area: req.query.area }));
  app.get('/v1/learn/lessons', async req => L.lessons(req.user));
  // Playbook
  app.get<{ Querystring: Q }>('/v1/learn/playbook', async req => L.playbookForApp(req.user, { area: req.query.area }));
  app.post('/v1/learn/playbook', async req => L.addRule(req.user, body(req.body), 'owner'));
  app.patch<P>('/v1/learn/playbook/:id', async req => L.updateRule(req.user, req.params.id, body(req.body)));
  app.delete<P>('/v1/learn/playbook/:id', async (req, reply) => { await L.removeRule(req.user, req.params.id); return reply.status(204).send(); });
  // Gaps
  app.get<{ Querystring: Q }>('/v1/learn/gaps', async req => L.gaps(req.user, Number(req.query.limit) || 50));
  app.post('/v1/learn/gaps', async req => L.addGap(req.user, body(req.body)));
  // What Claude reads before an edit (the playbook_read tool)
  app.get<{ Querystring: Q }>('/v1/learn/context', async req => L.context(req.user, { recipeId: req.query.recipeId, referenceId: req.query.referenceId, takeId: req.query.takeId, area: req.query.area }));
}
