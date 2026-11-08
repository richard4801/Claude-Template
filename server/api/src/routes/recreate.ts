// Recreate this edit routes (workstream 1, plans/api.md "Recreate this edit"): references and their recipes.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { RECREATE_TOOLS } from '../recreate/mcpTools.js';
import { recreateOf } from '../recreate/references.js';
import * as mcpTools from '../mcp/tools.js';

export async function registerRecreateRoutes(app: FastifyInstance, ctx: Ctx) {
  const rx = recreateOf(ctx);
  const id = (req: { params: unknown }) => (req.params as { id: string }).id;
  // Claude's tools on MUSE's MCP server (workstream 2's registry).
  const register = (mcpTools as { registerMcpTools?: (tools: unknown[]) => void }).registerMcpTools;
  if (register) register(RECREATE_TOOLS);
  app.get('/v1/recreate/references', async req => rx.list(req.user));
  app.post('/v1/recreate/references', async req => rx.create(req.user, req.body));
  app.get('/v1/recreate/references/:id', async req => rx.view(await rx.row(req.user, id(req))));
  app.patch('/v1/recreate/references/:id', async req => rx.patch(req.user, id(req), req.body));
  app.delete('/v1/recreate/references/:id', async (req, reply) => { await rx.remove(req.user, id(req)); return reply.status(204).send(); });
  // Slots (phase 3): briefs, matching to takes, filling with Suite shots, building the edit in a session.
  const slot = (req: { params: unknown }) => (req.params as { slotId: string }).slotId;
  app.put('/v1/recreate/references/:id/briefs', async req => rx.setBriefs(req.user, id(req), req.body));
  app.post('/v1/recreate/references/:id/match', async req => rx.match(req.user, id(req), req.body));
  app.post('/v1/recreate/references/:id/slots/:slotId/estimate', async req => rx.estimateSlot(req.user, id(req), slot(req), req.body));
  app.post('/v1/recreate/references/:id/slots/:slotId/fill', async req => rx.fillSlot(req.user, id(req), slot(req), req.body));
  app.post('/v1/recreate/references/:id/apply', async req => {
    const { device, ...body } = (req.body ?? {}) as { device?: string };
    return rx.apply(req.user, id(req), body, { by: 'app', device });
  });
  app.get('/v1/recreate/references/:id/contact-sheet', async (req, reply) => {
    const obj = await rx.contactSheet(req.user, id(req));
    return reply.header('content-type', 'image/png').header('cache-control', 'private, max-age=3600').send(obj.body);
  });
}
