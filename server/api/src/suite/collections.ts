// Library collections (workstream 1; plans/ai-suite-design.md "Refinements" 6; plans/api.md "Library collections"):
// named groups of the studio's takes and photos. Everyone in the studio sees them, like the library itself; the member
// who made a collection, or the owner, renames it, deletes it and changes what is in it. The feed lists a collection
// with `?collection=<id>`.
import { and, desc, eq, inArray, sql } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { takes } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { libraryCollectionItems as items, libraryCollections as cols } from './schema.js';

export const COLLECTION_LIMITS = { maxPerStudio: 200, maxItems: 2000, maxPerCall: 200, nameMax: 60 } as const;
type Row = typeof cols.$inferSelect;

const Name = z.string().trim().min(1, 'name: give it a name').max(COLLECTION_LIMITS.nameMax);
const Ids = z.array(z.string().min(1).max(80)).min(1).max(COLLECTION_LIMITS.maxPerCall);
const parse = <T>(s: z.ZodType<T>, body: unknown): T => {
  const r = s.safeParse(body ?? {});
  if (!r.success) throw badRequest(r.error.issues.map(i => (i.path.length ? `${i.path.join('.')}: ` : '') + i.message.replace(/^name: /, '')).join('; '));
  return r.data;
};

async function view(ctx: Ctx, u: AuthUser, rows: Row[]) {
  if (!rows.length) return [];
  const ids = rows.map(r => r.id);
  // Counts and the newest item's thumb, from the takes that still exist.
  const stats = await ctx.db.select({ id: items.collectionId, n: sql<number>`count(*)::int` })
    .from(items).innerJoin(takes, eq(items.takeId, takes.id)).where(inArray(items.collectionId, ids)).groupBy(items.collectionId);
  const latest = await ctx.db.select({ id: items.collectionId, thumb: takes.thumb, at: items.addedAt })
    .from(items).innerJoin(takes, eq(items.takeId, takes.id)).where(inArray(items.collectionId, ids)).orderBy(desc(items.addedAt));
  return rows.map(r => ({
    id: r.id, name: r.name, userId: r.userId, mine: r.userId === u.id, canEdit: r.userId === u.id || u.role === 'owner',
    count: stats.find(s => s.id === r.id)?.n ?? 0, cover: latest.find(l => l.id === r.id)?.thumb ?? null,
    createdAt: r.createdAt, updatedAt: r.updatedAt,
  }));
}
const emit = (ctx: Ctx, studioId: string, e: Record<string, unknown>) => ctx.hub.emit(studioId, { type: 'collection', ...e });

async function row(ctx: Ctx, u: AuthUser, id: string, edit = false) {
  const [r] = await ctx.db.select().from(cols).where(and(eq(cols.id, id), eq(cols.studioId, u.studioId)));
  if (!r) throw notFound('Collection');
  if (edit && r.userId !== u.id && u.role !== 'owner') throw new ApiError(403, 'not_yours', 'Only the one who made this collection, or the owner, can change it');
  return r;
}
/** The studio's takes and photos among `ids`; any other id is refused. */
async function studioTakes(ctx: Ctx, u: AuthUser, ids: string[]) {
  const uniq = [...new Set(ids)];
  const found = await ctx.db.select({ id: takes.id }).from(takes).where(and(eq(takes.studioId, u.studioId), inArray(takes.id, uniq)));
  const missing = uniq.filter(x => !found.some(f => f.id === x));
  if (missing.length) throw badRequest(`takeIds: no take or photo ${missing.slice(0, 3).join(', ')}`);
  return uniq;
}

export async function listCollections(ctx: Ctx, u: AuthUser) {
  return view(ctx, u, await ctx.db.select().from(cols).where(eq(cols.studioId, u.studioId)).orderBy(desc(cols.updatedAt)));
}
export async function getCollection(ctx: Ctx, u: AuthUser, id: string) {
  const r = await row(ctx, u, id);
  const its = await ctx.db.select({ takeId: items.takeId }).from(items).innerJoin(takes, eq(items.takeId, takes.id))
    .where(eq(items.collectionId, id)).orderBy(desc(items.addedAt));
  return { ...(await view(ctx, u, [r]))[0]!, takeIds: its.map(x => x.takeId) };
}
export async function createCollection(ctx: Ctx, u: AuthUser, body: unknown) {
  const b = parse(z.object({ name: Name, takeIds: Ids.optional() }).strict(), body);
  const [{ n }] = await ctx.db.select({ n: sql<number>`count(*)::int` }).from(cols).where(eq(cols.studioId, u.studioId)) as [{ n: number }];
  if (n >= COLLECTION_LIMITS.maxPerStudio) throw new ApiError(409, 'too_many_collections', `A studio can have up to ${COLLECTION_LIMITS.maxPerStudio} collections`);
  const ids = b.takeIds ? await studioTakes(ctx, u, b.takeIds) : [];
  const now = Date.now(), id = uid('col');
  await ctx.db.insert(cols).values({ id, studioId: u.studioId, userId: u.id, name: b.name, createdAt: now, updatedAt: now });
  if (ids.length) await ctx.db.insert(items).values(ids.map(t => ({ collectionId: id, takeId: t, addedBy: u.id, addedAt: now }))).onConflictDoNothing();
  const out = await getCollection(ctx, u, id);
  emit(ctx, u.studioId, { collection: { ...out, mine: undefined, canEdit: undefined, takeIds: undefined } });
  return out;
}
export async function renameCollection(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  const b = parse(z.object({ name: Name }).strict(), body);
  await row(ctx, u, id, true);
  await ctx.db.update(cols).set({ name: b.name, updatedAt: Date.now() }).where(eq(cols.id, id));
  const out = await getCollection(ctx, u, id);
  emit(ctx, u.studioId, { collection: { ...out, mine: undefined, canEdit: undefined, takeIds: undefined } });
  return out;
}
/** Deletes the collection; its takes and photos stay in the library. */
export async function deleteCollection(ctx: Ctx, u: AuthUser, id: string) {
  await row(ctx, u, id, true);
  await ctx.db.delete(items).where(eq(items.collectionId, id));
  await ctx.db.delete(cols).where(eq(cols.id, id));
  emit(ctx, u.studioId, { deleted: id });
}
export async function addToCollection(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  const b = parse(z.object({ takeIds: Ids }).strict(), body);
  await row(ctx, u, id, true);
  const ids = await studioTakes(ctx, u, b.takeIds);
  const [{ n }] = await ctx.db.select({ n: sql<number>`count(*)::int` }).from(items).where(eq(items.collectionId, id)) as [{ n: number }];
  if (n + ids.length > COLLECTION_LIMITS.maxItems) throw new ApiError(409, 'collection_full', `A collection holds up to ${COLLECTION_LIMITS.maxItems} takes and photos`);
  const now = Date.now();
  await ctx.db.insert(items).values(ids.map(t => ({ collectionId: id, takeId: t, addedBy: u.id, addedAt: now }))).onConflictDoNothing();
  await ctx.db.update(cols).set({ updatedAt: now }).where(eq(cols.id, id));
  const out = await getCollection(ctx, u, id);
  emit(ctx, u.studioId, { collection: { ...out, mine: undefined, canEdit: undefined, takeIds: undefined } });
  return out;
}
export async function removeFromCollection(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  const b = parse(z.object({ takeIds: Ids }).strict(), body);
  await row(ctx, u, id, true);
  await ctx.db.delete(items).where(and(eq(items.collectionId, id), inArray(items.takeId, b.takeIds)));
  await ctx.db.update(cols).set({ updatedAt: Date.now() }).where(eq(cols.id, id));
  const out = await getCollection(ctx, u, id);
  emit(ctx, u.studioId, { collection: { ...out, mine: undefined, canEdit: undefined, takeIds: undefined } });
  return out;
}
/** The collections a take or photo is in (for its detail sheet). */
export async function collectionsOf(ctx: Ctx, u: AuthUser, takeId: string) {
  const rows = await ctx.db.select({ c: cols }).from(items).innerJoin(cols, eq(items.collectionId, cols.id))
    .where(and(eq(items.takeId, takeId), eq(cols.studioId, u.studioId)));
  return view(ctx, u, rows.map(r => r.c));
}
