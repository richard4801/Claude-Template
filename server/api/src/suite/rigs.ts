// AI suite · saved rigs (workstream 1, plans/ai-suite-design.md build step 2; plans/api.md "Saved rigs"): a named set of
// rig rows (camera, angle, light, look, style, optionally moves) applied in one click. Every member keeps their own;
// the owner sees, renames and deletes the whole studio's.
import { and, asc, desc, eq, sql } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { RigSchema } from './drafts.js';
import { suiteRigs } from './schema.js';

export const MAX_RIGS_PER_USER = 100;

const Name = z.string().trim().min(1, 'Give the rig a name').max(60);
const CreateBody = z.object({ name: Name, rig: RigSchema }).strict();
const PatchBody = z.object({ name: Name.optional(), rig: RigSchema.optional() }).strict();

const parse = <T>(s: z.ZodType<T>, body: unknown): T => {
  const r = s.safeParse(body ?? {});
  if (!r.success) throw badRequest(r.error.issues.map(i => (i.path.length ? `${i.path.join('.')}: ` : '') + i.message).join('; '));
  return r.data;
};

type Row = typeof suiteRigs.$inferSelect;
export const rigView = (r: Row, u: AuthUser) => ({ id: r.id, name: r.name, rig: r.rig, userId: r.userId, mine: r.userId === u.id, createdAt: r.createdAt, updatedAt: r.updatedAt });

/** A member's own rigs (most recently used/changed first); the owner gets every rig in the studio, theirs first. */
export async function listRigs(ctx: Ctx, u: AuthUser) {
  const where = u.role === 'owner' ? eq(suiteRigs.studioId, u.studioId) : and(eq(suiteRigs.studioId, u.studioId), eq(suiteRigs.userId, u.id));
  const rows = await ctx.db.select().from(suiteRigs).where(where).orderBy(desc(suiteRigs.updatedAt), asc(suiteRigs.id));
  return rows.map(r => rigView(r, u)).sort((a, b) => Number(b.mine) - Number(a.mine));
}

export async function createRig(ctx: Ctx, u: AuthUser, body: unknown) {
  const b = parse(CreateBody, body);
  const [{ n }] = await ctx.db.select({ n: sql<number>`count(*)::int` }).from(suiteRigs).where(and(eq(suiteRigs.studioId, u.studioId), eq(suiteRigs.userId, u.id)));
  if (Number(n) >= MAX_RIGS_PER_USER) throw new ApiError(409, 'too_many_rigs', `You can keep ${MAX_RIGS_PER_USER} rigs · delete one first`);
  const now = Date.now();
  const [r] = await ctx.db.insert(suiteRigs).values({ id: uid('rig'), studioId: u.studioId, userId: u.id, name: b.name, rig: b.rig, createdAt: now, updatedAt: now }).returning();
  return rigView(r!, u);
}

/** A rig this user may change: their own, or any in the studio for the owner. Others' rigs read as not found. */
async function editable(ctx: Ctx, u: AuthUser, id: string) {
  const [r] = await ctx.db.select().from(suiteRigs).where(and(eq(suiteRigs.id, id), eq(suiteRigs.studioId, u.studioId)));
  if (!r || (u.role !== 'owner' && r.userId !== u.id)) throw notFound('Rig');
  return r;
}

export async function patchRig(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  const b = parse(PatchBody, body);
  const r = await editable(ctx, u, id);
  if (b.name === undefined && b.rig === undefined) return rigView(r, u);
  const [n] = await ctx.db.update(suiteRigs).set({ ...(b.name !== undefined ? { name: b.name } : {}), ...(b.rig !== undefined ? { rig: b.rig } : {}), updatedAt: Date.now() })
    .where(eq(suiteRigs.id, r.id)).returning();
  return rigView(n!, u);
}

export async function deleteRig(ctx: Ctx, u: AuthUser, id: string) {
  const r = await editable(ctx, u, id);
  await ctx.db.delete(suiteRigs).where(eq(suiteRigs.id, r.id));
}
