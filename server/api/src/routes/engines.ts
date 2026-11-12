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
  // ?schema=1 also asks each Genjutsu motion-transfer model what its request must look like: a body that can't pass
  // validation, answered with a 422 naming the fields (free: nothing can start). Light's schema isn't published.
  app.get('/v1/engines/genjutsu/access', { config: { owner: true } }, async req => {
    const hf = ctx.suite.providers.higgsfield as { genjutsuPresets?: () => Promise<{ access: string; presets: unknown[]; detail?: string }>;
      probeSchema?: (ref: string) => Promise<{ status: number | null; fields: unknown[]; detail: string }> };
    const r = await hf.genjutsuPresets?.() ?? { access: 'unknown', presets: [], detail: 'Higgsfield isn’t set up on the server' };
    const want = (req.query as { schema?: string } | undefined)?.schema;
    const schema = want && hf.probeSchema ? Object.fromEntries(await Promise.all(['higgsfield/genjutsu-light/motion-transfer/v1.0', 'higgsfield/genjutsu/motion-transfer/v1.0']
      .map(async ref => [ref, await hf.probeSchema!(ref)] as const))) : undefined;
    return { access: r.access, presets: r.presets.length, ...(r.detail ? { detail: r.detail } : {}), ...(schema ? { schema } : {}),
      note: 'Checked with the free restyle preset list (and, with ?schema=1, a request Higgsfield must refuse, which names the fields it wants). Nothing is generated or charged.' };
  });
}
