// AI suite · the studio's locations (composer `@location`, plans/api.md "AI suite"): a named place with a reference image.
// In a shot it is sent as `references.images[] {image, role: "location", label: name}`; nothing else is special about it.
import { and, desc, eq, sql } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { suiteLocations } from './schema.js';

export const MAX_LOCATIONS = 200;

const LocationBody = z.object({
  name: z.string().trim().min(1, 'Give the location a name').max(60),
  image: z.object({ asset: z.string().max(80).optional(), url: z.string().max(2000).optional() })
    .refine(v => !!v.asset || !!v.url, 'an image needs asset or url')
    .refine(v => !v.url || /^https:\/\//.test(v.url) || /\/uploads\//.test(v.url), 'The image must be an upload or an https link'),
});

type Row = typeof suiteLocations.$inferSelect;
export const locationView = (r: Row) => ({ id: r.id, name: r.name, image: r.image, createdAt: r.createdAt });

export async function listLocations(ctx: Ctx, u: AuthUser) {
  const rows = await ctx.db.select().from(suiteLocations).where(eq(suiteLocations.studioId, u.studioId)).orderBy(desc(suiteLocations.createdAt));
  return rows.map(locationView);
}

export async function createLocation(ctx: Ctx, u: AuthUser, body: unknown) {
  const p = LocationBody.safeParse(body);
  if (!p.success) throw badRequest(p.error.issues.map(i => i.message).join('; '));
  const [{ n }] = await ctx.db.select({ n: sql<number>`count(*)::int` }).from(suiteLocations).where(eq(suiteLocations.studioId, u.studioId));
  if (Number(n) >= MAX_LOCATIONS) throw new ApiError(409, 'too_many_locations', `A studio can keep ${MAX_LOCATIONS} locations · delete one first`);
  const row = { id: uid('loc'), studioId: u.studioId, name: p.data.name, image: p.data.image, createdBy: u.id, createdAt: Date.now() };
  await ctx.db.insert(suiteLocations).values(row);
  return locationView(row);
}

/** The person who added it, or the owner, can delete a location. */
export async function deleteLocation(ctx: Ctx, u: AuthUser, id: string) {
  const [r] = await ctx.db.select().from(suiteLocations).where(and(eq(suiteLocations.id, id), eq(suiteLocations.studioId, u.studioId)));
  if (!r) throw notFound('Location');
  if (u.role !== 'owner' && r.createdBy !== u.id) throw new ApiError(403, 'forbidden', 'Only the person who added it or the studio owner can delete it');
  await ctx.db.delete(suiteLocations).where(eq(suiteLocations.id, id));
  return { ok: true };
}
