// AI suite routes (workstream 1, plans/api.md "AI suite"). Members never see providers or models; owners do.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { ApiError } from '../errors.js';
import { cameraCatalog } from '../suite/camera.js';
import { createLocation, deleteLocation, listLocations } from '../suite/locations.js';

export async function registerSuiteRoutes(app: FastifyInstance, ctx: Ctx) {
  app.get('/v1/suite/catalog', async req => ctx.suite.catalog(req.user));
  app.get('/v1/suite/camera', async () => cameraCatalog());
  app.get('/v1/suite/targets', async req => ctx.suite.targets(req.user));
  app.post('/v1/suite/camera/compile', async req => ctx.suite.compile(req.user, req.body));
  app.post('/v1/suite/rig-check', async req => ctx.suite.rigCheck(req.user, req.body)); // workstream 3
  app.post('/v1/suite/shots/estimate', async (req, reply) => {
    try { return await ctx.suite.estimate(req.user, req.body); }
    catch (e) { return nothingFits(e, req.user.role === 'owner', reply); }
  });
  app.post('/v1/suite/shots', async (req, reply) => {
    try { return await ctx.suite.create(req.user, req.body); }
    catch (e) { return nothingFits(e, req.user.role === 'owner', reply); }
  });
  app.get('/v1/suite/shots/:id', async req => ctx.suite.shot(req.user, (req.params as { id: string }).id));
  // The studio's locations (composer @location).
  app.get('/v1/suite/locations', async req => listLocations(ctx, req.user));
  app.post('/v1/suite/locations', async req => createLocation(ctx, req.user, req.body));
  app.delete('/v1/suite/locations/:id', async req => deleteLocation(ctx, req.user, (req.params as { id: string }).id));
  app.get('/v1/suite/settings', { config: { owner: true } }, async req => ctx.suite.settingsView(req.user.studioId));
  app.patch('/v1/suite/settings', { config: { owner: true } }, async req => ctx.suite.updateSettings(req.user, req.body));
}

/** nothing_fits carries the ladder steps that were tried (owner only: they name models). */
function nothingFits(e: unknown, owner: boolean, reply: any) {
  if (e instanceof ApiError && e.code === 'nothing_fits') return reply.status(400).send({ error: e.message, code: e.code, ...(owner ? { tried: (e as any).tried } : {}) });
  throw e;
}
