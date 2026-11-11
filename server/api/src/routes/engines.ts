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
  // Genjutsu (Higgsfield): does the server's key have access? Free (reads the restyle preset list; no generation, no spend).
  app.get('/v1/engines/genjutsu/access', { config: { owner: true } }, async () => {
    const r = await (ctx.suite.providers.higgsfield as { genjutsuPresets?: () => Promise<{ access: string; presets: unknown[]; detail?: string }> }).genjutsuPresets?.()
      ?? { access: 'unknown', presets: [], detail: 'Higgsfield isn’t set up on the server' };
    return { access: r.access, presets: r.presets.length, ...(r.detail ? { detail: r.detail } : {}),
      note: 'Checked with the free restyle preset list. Motion transfer and object swap are confirmed on their first real run.' };
  });
}
