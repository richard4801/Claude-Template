// Recreate this edit routes (workstream 1, plans/api.md "Recreate this edit"): references and their recipes.
import { briefsOf } from '../recreate/briefs.js';
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { RECREATE_TOOLS } from '../recreate/mcpTools.js';
import { recreateOf } from '../recreate/references.js';
import { rendersOf } from '../editor/renders.js';
import { notFound } from '../errors.js';
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
  app.post('/v1/recreate/references/:id/retry', async req => rx.retry(req.user, id(req))); // workstream 1: after a failed (or crashed) analysis
  // Slots (phase 3): briefs, matching to takes, filling with Suite shots, building the edit in a session.
  const slot = (req: { params: unknown }) => (req.params as { slotId: string }).slotId;
  app.put('/v1/recreate/references/:id/briefs', async req => rx.setBriefs(req.user, id(req), req.body));
  app.post('/v1/recreate/references/:id/match', async req => rx.match(req.user, id(req), req.body));
  // "Strict link rules" (owner) and the link check before a device downloads (Release 1 fix: platforms block server IPs).
  app.get('/v1/recreate/settings', async req => rx.settings(req.user));
  app.patch('/v1/recreate/settings', async req => rx.patchSettings(req.user, req.body));
  app.post('/v1/recreate/links/check', async req => rx.checkLink(req.user, req.body));
  // Shot briefs written on the server (G8): the price first, then a confirmed run.
  app.post('/v1/recreate/references/:id/briefs/estimate', async req => briefsOf(ctx).estimate(req.user, id(req)));
  app.post('/v1/recreate/references/:id/briefs/write', async req => briefsOf(ctx).write(req.user, id(req), req.body));
  app.post('/v1/recreate/references/:id/slots/:slotId/estimate', async req => rx.estimateSlot(req.user, id(req), slot(req), req.body));
  app.post('/v1/recreate/references/:id/slots/:slotId/fill', async req => rx.fillSlot(req.user, id(req), slot(req), req.body));
  // "Fix this shot": one slot's clip swapped in place (plan §4).
  app.post('/v1/recreate/references/:id/slots/:slotId/replace', async req => {
    const { device, ...body } = (req.body ?? {}) as { device?: string };
    return rx.replaceSlot(req.user, id(req), slot(req), body, { by: 'app', device });
  });
  app.post('/v1/recreate/references/:id/apply', async req => {
    const { device, ...body } = (req.body ?? {}) as { device?: string };
    return rx.apply(req.user, id(req), body, { by: 'app', device });
  });
  app.get('/v1/recreate/references/:id/contact-sheet', async (req, reply) => {
    const obj = await rx.contactSheet(req.user, id(req));
    return reply.header('content-type', 'image/png').header('cache-control', 'private, max-age=3600').send(obj.body);
  });
  // For the apps' side-by-side view (workstream 2): the reference video, its poster, each slot's thumbnail, fill state.
  app.get('/v1/recreate/references/:id/video', async (req, reply) => {
    const v = await rx.video(req.user, id(req));
    if ('redirect' in v) return reply.redirect(v.redirect, 302);
    return reply.header('content-type', v.contentType).header('cache-control', 'private, max-age=3600').send(v.body);
  });
  const png = (reply: import('fastify').FastifyReply, b: Buffer) => reply.header('content-type', 'image/png').header('cache-control', 'private, max-age=3600').send(b);
  app.get('/v1/recreate/references/:id/poster', async (req, reply) => png(reply, await rx.thumb(req.user, id(req), null)));
  app.get('/v1/recreate/references/:id/slots/:slotId/thumb', async (req, reply) => png(reply, await rx.thumb(req.user, id(req), slot(req))));
  app.get('/v1/recreate/references/:id/fill', async req => rx.fillView(req.user, id(req)));
  // Export (plan step 7): the built edit as long as the reference, with its sound as a guide track or silent.
  app.post('/v1/recreate/references/:id/export', async req => rx.exportEdit(req.user, id(req), req.body));
  app.get('/v1/recreate/references/:id/export', async req => rx.exportState(req.user, id(req), req.query));
  app.get('/v1/recreate/references/:id/export.mp4', async (req, reply) => {
    const f = await rx.exportFile(req.user, id(req), req.query);
    if ('redirect' in f) return reply.redirect(f.redirect, 302);
    return reply.header('content-type', f.contentType).header('content-disposition', 'attachment; filename="recreated.mp4"').send(f.body);
  });
  // Server renders of edit sessions (workstream 1, Release 1): "Your edit" in Compare plays the real built edit.
  const renders = rendersOf(ctx);
  const rev = (req: { query: unknown }) => { const r = Number((req.query as { revision?: string } | undefined)?.revision); return Number.isInteger(r) && r >= 0 ? r : undefined; };
  app.post('/v1/edit-sessions/:id/preview', async req => renders.preview(req.user, id(req)));
  app.get('/v1/edit-sessions/:id/preview', async req => renders.previewState(req.user, id(req), rev(req)));
  app.get('/v1/edit-sessions/:id/preview.mp4', async (req, reply) => {
    const f = await renders.previewFile(req.user, id(req), rev(req));
    if (!f) throw notFound('Preview');
    if ('redirect' in f) return reply.redirect(f.redirect, 302);
    return reply.header('content-type', f.contentType).header('cache-control', 'private, max-age=3600').send(f.body);
  });
}
