// Edit style kits: storage and the /v1/editor/kits routes (plans/edit-parity.md, M). The kit itself is editor/kit.ts.
import type { FastifyInstance } from 'fastify';
import { and, desc, eq } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { editKits } from '../db/schema.js';
import { badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import * as M from './model.js';
import { validateKit } from './kit.js';
import { FILTERS } from './presets.js';
import { LOOK_IDS } from './lookpack.js';
import { paletteIds } from './photo.js';

/** A studio keeps at most this many kits (each is a few kB). */
export const MAX_KITS = 200;

type Row = typeof editKits.$inferSelect;
const view = (r: Row) => ({ id: r.id, name: r.name, kit: r.kit, createdBy: r.createdBy, createdAt: r.createdAt, updatedAt: r.updatedAt });

function parse<T>(schema: z.ZodType<T>, body: unknown): T {
  const r = schema.safeParse(body ?? {});
  if (!r.success) throw badRequest(r.error.issues.map(i => `${i.path.join('.') || 'body'}: ${i.message}`).join('; '));
  return r.data;
}
const Name = z.string().trim().min(1).max(60);
function checkKit(kit: unknown) {
  try { return validateKit(kit, FILTERS, LOOK_IDS, paletteIds()); } catch (e) { if (e instanceof M.EditProblem) throw badRequest(e.message); throw e; }
}

export class EditKits {
  constructor(private ctx: Ctx) {}
  /** Members: their own; the owner: the studio's. Newest first. */
  async list(u: AuthUser) {
    const rows = await this.ctx.db.select().from(editKits)
      .where(and(eq(editKits.studioId, u.studioId), ...(u.role === 'owner' ? [] : [eq(editKits.createdBy, u.id)]))).orderBy(desc(editKits.updatedAt));
    return { kits: rows.map(view) };
  }
  private async row(u: AuthUser, id: string) {
    const [r] = await this.ctx.db.select().from(editKits).where(and(eq(editKits.id, id), eq(editKits.studioId, u.studioId)));
    if (!r || (u.role !== 'owner' && r.createdBy !== u.id)) throw notFound('Style kit');
    return r;
  }
  async create(u: AuthUser, body: unknown) {
    const b = parse(z.object({ name: Name, kit: z.unknown() }).strict(), body);
    const kit = checkKit(b.kit);
    const mine = await this.ctx.db.select({ id: editKits.id }).from(editKits).where(eq(editKits.studioId, u.studioId));
    if (mine.length >= MAX_KITS) throw badRequest(`A studio keeps at most ${MAX_KITS} style kits · delete one first`);
    const now = Date.now();
    const [r] = await this.ctx.db.insert(editKits).values({ id: uid('kit'), studioId: u.studioId, createdBy: u.id, name: b.name, kit, createdAt: now, updatedAt: now }).returning();
    return view(r!);
  }
  /** Rename and/or replace the kit. */
  async update(u: AuthUser, id: string, body: unknown) {
    const b = parse(z.object({ name: Name.optional(), kit: z.unknown().optional() }).strict(), body);
    const r = await this.row(u, id);
    const kit = b.kit !== undefined ? checkKit(b.kit) : undefined;
    const [n] = await this.ctx.db.update(editKits).set({ ...(b.name ? { name: b.name } : {}), ...(kit ? { kit } : {}), updatedAt: Date.now() }).where(eq(editKits.id, r.id)).returning();
    return view(n!);
  }
  async remove(u: AuthUser, id: string) {
    const r = await this.row(u, id);
    await this.ctx.db.delete(editKits).where(eq(editKits.id, r.id));
  }
}

export async function registerKitRoutes(app: FastifyInstance, ctx: Ctx) {
  const k = new EditKits(ctx);
  const id = (req: { params: unknown }) => (req.params as { id: string }).id;
  app.get('/v1/editor/kits', async req => k.list(req.user));
  app.post('/v1/editor/kits', async req => k.create(req.user, req.body));
  app.patch('/v1/editor/kits/:id', async req => k.update(req.user, id(req), req.body));
  app.delete('/v1/editor/kits/:id', async (req, reply) => { await k.remove(req.user, id(req)); return reply.status(204).send(); });
}
