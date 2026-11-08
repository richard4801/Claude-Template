// AI suite routes (workstream 1, plans/api.md "AI suite"). Members never see providers or models; owners do.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { ApiError } from '../errors.js';
import { cameraCatalog } from '../suite/camera.js';
import { feed } from '../suite/feed.js';
import { registerRecreateRoutes } from './recreate.js';
import { createLocation, deleteLocation, listLocations } from '../suite/locations.js';
import { createRig, deleteRig, listRigs, patchRig } from '../suite/rigs.js';
import { addToCollection, collectionsOf, createCollection, deleteCollection, getCollection, listCollections, removeFromCollection, renameCollection } from '../suite/collections.js';
import { discardQueued, listQueue, queueEstimate, queueShot, runQueued } from '../suite/queue.js';

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
  // The new Suite (plans/ai-suite-design.md build step 2): saved rigs (each member's own; the owner sees all) and the takes feed.
  app.get('/v1/suite/rigs', async req => listRigs(ctx, req.user));
  app.post('/v1/suite/rigs', async req => createRig(ctx, req.user, req.body));
  app.patch('/v1/suite/rigs/:id', async req => patchRig(ctx, req.user, (req.params as { id: string }).id, req.body));
  app.delete('/v1/suite/rigs/:id', async (req, reply) => { await deleteRig(ctx, req.user, (req.params as { id: string }).id); return reply.status(204).send(); });
  app.get('/v1/suite/feed', async req => feed(ctx, req.user, req.query));
  // The Suite queue (ai-suite-design.md "Refinements" 1): saved shots, run on demand through the normal path.
  const qid = (req: { params: unknown }) => (req.params as { id: string }).id;
  app.get('/v1/suite/queue', async req => listQueue(ctx, req.user));
  app.post('/v1/suite/queue', async (req, reply) => {
    try { return await queueShot(ctx, req.user, req.body); }
    catch (e) { return nothingFits(e, req.user.role === 'owner', reply); }
  });
  app.post('/v1/suite/queue/:id/estimate', async (req, reply) => {
    try { return await queueEstimate(ctx, req.user, qid(req)); }
    catch (e) { return nothingFits(e, req.user.role === 'owner', reply); }
  });
  app.post('/v1/suite/queue/:id/run', async (req, reply) => {
    try { return await runQueued(ctx, req.user, qid(req), req.body); }
    catch (e) { return nothingFits(e, req.user.role === 'owner', reply); }
  });
  app.delete('/v1/suite/queue/:id', async (req, reply) => { await discardQueued(ctx, req.user, qid(req)); return reply.status(204).send(); });
  // Library collections ("Refinements" 6): the studio's named groups of takes and photos.
  app.get('/v1/library/collections', async req => listCollections(ctx, req.user));
  app.post('/v1/library/collections', async req => createCollection(ctx, req.user, req.body));
  app.get('/v1/library/collections/:id', async req => getCollection(ctx, req.user, qid(req)));
  app.patch('/v1/library/collections/:id', async req => renameCollection(ctx, req.user, qid(req), req.body));
  app.delete('/v1/library/collections/:id', async (req, reply) => { await deleteCollection(ctx, req.user, qid(req)); return reply.status(204).send(); });
  app.post('/v1/library/collections/:id/items', async req => addToCollection(ctx, req.user, qid(req), req.body));
  app.post('/v1/library/collections/:id/items/remove', async req => removeFromCollection(ctx, req.user, qid(req), req.body));
  app.get('/v1/library/takes/:id/collections', async req => collectionsOf(ctx, req.user, qid(req)));
  await registerRecreateRoutes(app, ctx); // Recreate this edit (workstream 1)
  app.get('/v1/suite/settings', { config: { owner: true } }, async req => ctx.suite.settingsView(req.user.studioId));
  app.patch('/v1/suite/settings', { config: { owner: true } }, async req => ctx.suite.updateSettings(req.user, req.body));
}

/** nothing_fits carries the ladder steps that were tried (owner only: they name models). */
function nothingFits(e: unknown, owner: boolean, reply: any) {
  if (e instanceof ApiError && e.code === 'nothing_fits') return reply.status(400).send({ error: e.message, code: e.code, ...(owner ? { tried: (e as any).tried } : {}) });
  throw e;
}
