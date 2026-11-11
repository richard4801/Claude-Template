// WS13 · model choice everywhere (plans/api.md "Model choice"): the owner's model catalog per purpose and the studio's
// default model per purpose. GET /v1/models is the character list, so the catalog lives at /v1/engines.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { modelChoice } from '../engines/service.js';

export async function registerEngineRoutes(app: FastifyInstance, ctx: Ctx) {
  const mc = modelChoice(ctx);
  app.get('/v1/engines', async req => mc.list(req.user, (req.query as { purpose?: string } | undefined)?.purpose));
  app.get('/v1/engines/defaults', { config: { owner: true } }, async req => mc.defaultsView(req.user));
  app.patch('/v1/engines/defaults', { config: { owner: true } }, async req => mc.setDefaults(req.user, req.body));
  // 4c: "Show provider names to members" and the per-model "hide from members" switches (owner).
  app.get('/v1/engines/members', { config: { owner: true } }, async req => mc.membersView(req.user));
  app.patch('/v1/engines/members', { config: { owner: true } }, async req => mc.setMembers(req.user, req.body));
}
