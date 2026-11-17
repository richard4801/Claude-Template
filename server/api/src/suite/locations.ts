// AI suite · places (composer `@location`, plans/api.md "AI suite"; "her world" phase 1, plans/model-world.md §1).
// A place is a named spot with up to 8 photos (one the cover), an @tag and a description. It belongs to one character
// (`modelId`, hers alone, "Copy to another model") or to the studio (`modelId` null: "Studio places", shared as before).
// In a Shot or Photo, `placeId` or an `@tag` in the prompt sends its cover as the scene reference after her identity
// images; with no room for it, it is described in words (resolvePlace / placeWords below).
import { and, desc, eq, isNull, sql } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { models } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { PhotoError } from '../images/service.js';
import { uid } from '../lib/util.js';
import { whoOf } from '../money/money.js';
import { suiteLocations, type PlaceImage, type PlaceImageSource } from './schema.js';

export const MAX_LOCATIONS = 200;
/** Photos one place keeps (plans/model-world.md §1). */
export const MAX_PLACE_IMAGES = 8;
export const MIN_CHARGE_USD = 0.01;

const ImageIn = z.object({ asset: z.string().max(80).optional(), url: z.string().max(2000).optional() }).strict()
  .refine(v => !!v.asset || !!v.url, 'an image needs asset or url')
  .refine(v => !v.url || /^https:\/\//.test(v.url) || /\/uploads\//.test(v.url), 'The image must be an upload or an https link');
const TagIn = z.string().trim().transform(v => v.replace(/^@/, '').toLowerCase()).pipe(z.string().regex(/^[a-z0-9][a-z0-9_-]{0,29}$/, 'A tag is 1–30 letters, digits, - or _'));
const LocationBody = z.object({
  name: z.string().trim().min(1, 'Give the place a name').max(60),
  /** One photo (older apps): it becomes the first. A studio place needs one; her own place may start empty. */
  image: ImageIn.optional(),
  images: z.array(ImageIn).max(MAX_PLACE_IMAGES).optional(),
  /** Hers alone (a MUSE model of the studio); left out = a studio place. */
  modelId: z.string().min(1).max(80).optional(),
  tag: TagIn.optional(),
  description: z.string().trim().max(600).optional(),
}).strict();
const PatchBody = z.object({
  name: z.string().trim().min(1, 'Give the place a name').max(60).optional(),
  tag: TagIn.optional(),
  description: z.string().trim().max(600).optional(),
  cover: z.number().int().min(0).max(MAX_PLACE_IMAGES - 1).optional(),
}).strict();
export const GenerateBody = z.object({
  /** random: another view of this place; description: from words; reference: rebuilt from a picture. */
  mode: z.enum(['random', 'description', 'reference']),
  description: z.string().trim().max(600).optional(),
  reference: ImageIn.optional(),
  /** The price the person approved (the estimate's `estimate`): never charged above it; a higher price is refused. */
  maxUsd: z.number().min(0).max(100).optional(),
}).strict();
export type GenerateRequest = z.infer<typeof GenerateBody>;

type Row = typeof suiteLocations.$inferSelect;
const parse = <T>(s: z.ZodType<T>, body: unknown): T => {
  const p = s.safeParse(body ?? {});
  if (!p.success) throw badRequest(p.error.issues.map(i => `${i.path.length ? `${i.path.join('.')}: ` : ''}${i.message}`).join('; '));
  return p.data;
};
const strip = (i: { asset?: string; url?: string }) => ({ ...(i.asset ? { asset: i.asset } : {}), ...(i.url ? { url: i.url } : {}) });
/** "Café by the gym" → "cafe-by-the-gym" (an @tag). */
export const slugTag = (name: string) => name.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 30).replace(/-+$/, '') || 'place';
/** Its photos (older rows: the one `image`). */
export const imagesOf = (r: Pick<Row, 'images' | 'image'>): PlaceImage[] => (r.images?.length ? r.images : r.image && (r.image.asset || r.image.url) ? [{ ...strip(r.image), source: 'upload' as const }] : []);
/** The cover photo (the one sent), or null for a place with no photos yet. */
export const coverOf = (r: Pick<Row, 'images' | 'image' | 'cover'>) => { const l = imagesOf(r); const c = l[Math.min(Math.max(0, r.cover ?? 0), l.length - 1)]; return c ? strip(c) : null; };
export const tagOf = (r: Pick<Row, 'tag' | 'name'>) => r.tag ?? slugTag(r.name);

export const locationView = (r: Row) => ({
  id: r.id, name: r.name, tag: tagOf(r), modelId: r.modelId ?? null, scope: r.modelId ? 'model' as const : 'studio' as const, description: r.description ?? '',
  images: imagesOf(r), cover: Math.min(r.cover ?? 0, Math.max(0, imagesOf(r).length - 1)), image: coverOf(r) ?? r.image, createdBy: r.createdBy, createdAt: r.createdAt, updatedAt: r.updatedAt ?? r.createdAt,
});
export type PlaceView = ReturnType<typeof locationView>;

async function modelOf(ctx: Ctx, u: AuthUser, id: string) {
  const [m] = await ctx.db.select({ id: models.id, name: models.name, archivedAt: models.archivedAt }).from(models).where(and(eq(models.id, id), eq(models.studioId, u.studioId)));
  if (!m) throw notFound('Model');
  if (m.archivedAt) throw new ApiError(409, 'model_archived', 'This model is archived · restore her in Settings → Archived models');
  return m;
}
/** Her places and the studio's (the @tag namespace a prompt for her sees). */
async function scopeRows(ctx: Ctx, u: AuthUser, modelId: string | null) {
  return ctx.db.select().from(suiteLocations).where(and(eq(suiteLocations.studioId, u.studioId), modelId ? eq(suiteLocations.modelId, modelId) : isNull(suiteLocations.modelId)));
}
/** A tag free in the place's scope: the one asked for (409 when taken), else from the name with -2, -3… */
async function freeTag(ctx: Ctx, u: AuthUser, modelId: string | null, want: string | undefined, name: string, self?: string) {
  const taken = new Set((await scopeRows(ctx, u, modelId)).filter(r => r.id !== self).map(tagOf));
  if (want) { if (taken.has(want)) throw new ApiError(409, 'tag_taken', `@${want} is already used · pick another tag`); return want; }
  const base = slugTag(name);
  for (let i = 1; ; i++) { const t = i === 1 ? base : `${base.slice(0, 27)}-${i}`; if (!taken.has(t)) return t; }
}

/** Every place (studio places and each model's), or one model's first then the studio's (`?modelId=`). Newest first. */
export async function listLocations(ctx: Ctx, u: AuthUser, q: { modelId?: string } = {}) {
  const rows = await ctx.db.select().from(suiteLocations).where(eq(suiteLocations.studioId, u.studioId)).orderBy(desc(suiteLocations.createdAt));
  if (!q.modelId) return rows.map(locationView);
  return [...rows.filter(r => r.modelId === q.modelId), ...rows.filter(r => !r.modelId)].map(locationView);
}

export async function getLocation(ctx: Ctx, u: AuthUser, id: string) {
  const [r] = await ctx.db.select().from(suiteLocations).where(and(eq(suiteLocations.id, id), eq(suiteLocations.studioId, u.studioId)));
  if (!r) throw notFound('Place');
  return r;
}

export async function createLocation(ctx: Ctx, u: AuthUser, body: unknown) {
  const b = parse(LocationBody, body);
  const images = [...(b.image ? [b.image] : []), ...(b.images ?? [])].map(i => ({ ...strip(i), source: 'upload' as const, at: Date.now() }));
  if (images.length > MAX_PLACE_IMAGES) throw badRequest(`A place keeps up to ${MAX_PLACE_IMAGES} photos`);
  if (!b.modelId && !images.length) throw badRequest('A studio place needs a photo');
  if (b.modelId) await modelOf(ctx, u, b.modelId);
  const [{ n }] = await ctx.db.select({ n: sql<number>`count(*)::int` }).from(suiteLocations).where(eq(suiteLocations.studioId, u.studioId));
  if (Number(n) >= MAX_LOCATIONS) throw new ApiError(409, 'too_many_locations', `A studio can keep ${MAX_LOCATIONS} places · delete one first`);
  const modelId = b.modelId ?? null, now = Date.now();
  const tag = await freeTag(ctx, u, modelId, b.tag, b.name);
  const row = { id: uid('loc'), studioId: u.studioId, name: b.name, image: images[0] ? strip(images[0]) : {}, modelId, tag, description: b.description ?? '', images, cover: 0,
    createdBy: u.id, createdAt: now, updatedAt: now };
  await ctx.db.insert(suiteLocations).values(row);
  return locationView(row as Row);
}

async function save(ctx: Ctx, r: Row, f: Partial<Row>) {
  const next = { ...r, ...f, updatedAt: Date.now() };
  const imgs = imagesOf(next), cover = Math.min(Math.max(0, next.cover ?? 0), Math.max(0, imgs.length - 1));
  const [row] = await ctx.db.update(suiteLocations).set({ ...f, images: imgs, cover, image: imgs[cover] ? strip(imgs[cover]!) : r.image, updatedAt: next.updatedAt })
    .where(eq(suiteLocations.id, r.id)).returning();
  return locationView(row!);
}

/** Rename, re-tag, describe or pick the cover. Anyone in the studio (as her page). */
export async function updateLocation(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  const b = parse(PatchBody, body);
  const r = await getLocation(ctx, u, id);
  const f: Partial<Row> = {};
  if (b.name !== undefined) f.name = b.name;
  if (b.description !== undefined) f.description = b.description;
  if (b.tag !== undefined) f.tag = await freeTag(ctx, u, r.modelId, b.tag, b.name ?? r.name, r.id);
  else if (!r.tag) f.tag = await freeTag(ctx, u, r.modelId, undefined, r.name, r.id); // an older place gets its tag kept
  if (b.cover !== undefined) {
    if (b.cover >= imagesOf(r).length) throw badRequest('cover: no such photo');
    f.cover = b.cover;
  }
  return save(ctx, r, f);
}

async function appendImage(ctx: Ctx, r: Row, image: { asset?: string; url?: string }, source: PlaceImageSource) {
  const imgs = imagesOf(r);
  if (imgs.length >= MAX_PLACE_IMAGES) throw new ApiError(409, 'place_full', `A place keeps up to ${MAX_PLACE_IMAGES} photos · remove one first`);
  return save(ctx, r, { images: [...imgs, { ...strip(image), source, at: Date.now() }] });
}
/** Add an uploaded photo (Add photo → Upload). */
export async function addLocationImage(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  const b = parse(z.object({ image: ImageIn }).strict(), body);
  return appendImage(ctx, await getLocation(ctx, u, id), b.image, 'upload');
}
/** Remove a photo. The person who added the place or the owner (as deleting it); the last photo of a studio place stays. */
export async function removeLocationImage(ctx: Ctx, u: AuthUser, id: string, index: number) {
  const r = await getLocation(ctx, u, id);
  if (u.role !== 'owner' && r.createdBy !== u.id) throw new ApiError(403, 'forbidden', 'Only the person who added it or the studio owner can remove its photos');
  const imgs = imagesOf(r);
  if (!Number.isInteger(index) || index < 0 || index >= imgs.length) throw notFound('Photo');
  if (!r.modelId && imgs.length === 1) throw new ApiError(409, 'last_photo', 'A studio place keeps at least one photo · delete the place instead');
  const cover = r.cover > index ? r.cover - 1 : r.cover === index ? 0 : r.cover;
  return save(ctx, r, { images: imgs.filter((_, i) => i !== index), cover });
}

/** Copy to another model (decision 1): the photos, tag and description, as hers; the tag is kept when it's free. */
export async function copyLocation(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  const b = parse(z.object({ modelId: z.string().min(1).max(80) }).strict(), body);
  const r = await getLocation(ctx, u, id);
  await modelOf(ctx, u, b.modelId);
  if (r.modelId === b.modelId) throw badRequest('This place is already hers');
  const taken = new Set((await scopeRows(ctx, u, b.modelId)).map(tagOf));
  const tag = taken.has(tagOf(r)) ? await freeTag(ctx, u, b.modelId, undefined, r.name) : tagOf(r);
  return createLocationRow(ctx, u, { ...r, modelId: b.modelId, tag });
}
async function createLocationRow(ctx: Ctx, u: AuthUser, r: Row) {
  const [{ n }] = await ctx.db.select({ n: sql<number>`count(*)::int` }).from(suiteLocations).where(eq(suiteLocations.studioId, u.studioId));
  if (Number(n) >= MAX_LOCATIONS) throw new ApiError(409, 'too_many_locations', `A studio can keep ${MAX_LOCATIONS} places · delete one first`);
  const now = Date.now();
  const row = { ...r, id: uid('loc'), images: imagesOf(r), createdBy: u.id, createdAt: now, updatedAt: now };
  await ctx.db.insert(suiteLocations).values(row);
  return locationView(row);
}

/** The person who added it, or the owner, can delete a place. */
export async function deleteLocation(ctx: Ctx, u: AuthUser, id: string) {
  const r = await getLocation(ctx, u, id);
  if (u.role !== 'owner' && r.createdBy !== u.id) throw new ApiError(403, 'forbidden', 'Only the person who added it or the studio owner can delete it');
  await ctx.db.delete(suiteLocations).where(eq(suiteLocations.id, id));
  return { ok: true };
}

// ------------------------------------------------------------------ generating a place photo (priced, Approve)
const NO_PEOPLE = 'No people, no text, no logos. Natural light, realistic photo, eye-level, the whole place in focus, for a vertical phone video.';
export function placePrompt(r: Pick<Row, 'name' | 'description'>, b: GenerateRequest) {
  const words = (b.description ?? '').trim() || (r.description ?? '').trim();
  if (b.mode === 'random') return `Another view of this same place (${r.name}${words ? `: ${words}` : ''}), from a different angle in the same light. Keep its layout, materials and colours. ${NO_PEOPLE}`;
  if (b.mode === 'reference') return `Rebuild this picture as ${r.name}${words ? `: ${words}` : ''}. Keep its place, layout and light; remove every person. ${NO_PEOPLE}`;
  return `A photo of ${r.name}: ${words}. ${NO_PEOPLE}`;
}
type GenPlan = { usd: number; prompt: string; editOf: { asset?: string; url?: string } | null; refs: { asset?: string; url?: string }[] };
async function genPlan(ctx: Ctx, u: AuthUser, r: Row, b: GenerateRequest, quote = false): Promise<GenPlan> {
  const imgs = imagesOf(r).map(strip);
  if (imgs.length >= MAX_PLACE_IMAGES) throw new ApiError(409, 'place_full', `A place keeps up to ${MAX_PLACE_IMAGES} photos · remove one first`);
  const prompt = placePrompt(r, b);
  let base: number, editOf: GenPlan['editOf'] = null, refs: GenPlan['refs'] = [];
  if (b.mode === 'random') {
    const cover = coverOf(r);
    if (!cover) throw new ApiError(409, 'needs_a_photo', 'A random view starts from the place’s photos · add one, or generate from a description');
    editOf = cover; refs = imgs.filter(i => i !== cover && !(i.asset === cover.asset && i.url === cover.url)).slice(0, 2);
    base = await ctx.images.editCost(u.studioId);
  } else if (b.mode === 'reference') {
    if (!b.reference && !quote) throw badRequest('reference: the picture to rebuild from');
    editOf = b.reference ? strip(b.reference) : null;
    base = await ctx.images.editCost(u.studioId);
  } else {
    if (!(b.description ?? '').trim() && !(r.description ?? '').trim() && !quote) throw badRequest('Describe the place');
    refs = imgs.slice(0, 2);
    base = (await ctx.images.shotPlan(u.studioId, [], refs.map(image => ({ image, guides: ['scene' as const] })), 1)).perShot;
  }
  const usd = Math.max(MIN_CHARGE_USD, Math.round(base * 10000) / 10000);
  return { usd, prompt, editOf, refs };
}
const money = (v: number) => `$${v.toFixed(2)}`;
/** The price shown on the button first ("Generate · $0.03"): one photo per click. */
export async function estimateLocationImage(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  const b = parse(GenerateBody, body);
  const r = await getLocation(ctx, u, id);
  // The Add photo menu prices each way before anything is typed or picked (mockup 2).
  const p = await genPlan(ctx, u, r, b, true);
  return { tool: 'place_photo', mode: b.mode, count: 1, estimate: p.usd, estimateUsd: p.usd, priceLine: `about ${money(p.usd)} · 1 photo`, buttonLabel: `Generate · ${money(p.usd)}`, prompt: p.prompt };
}
/**
 * Makes one photo and adds it to the place. Held at the estimate first; charged what it cost, never more than the
 * estimate (or `maxUsd`, the price approved: a higher price is refused with the new one, nothing made).
 */
export async function generateLocationImage(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  const b = parse(GenerateBody, body);
  const r = await getLocation(ctx, u, id);
  const p = await genPlan(ctx, u, r, b);
  if (b.maxUsd != null && p.usd > b.maxUsd + 1e-9) throw new ApiError(409, 'price_changed', `The price is now ${money(p.usd)} · approve the new price to make it`);
  const cap = Math.min(p.usd, b.maxUsd ?? p.usd);
  const refId = uid('plc');
  const hold = await ctx.money.hold(whoOf(u), refId, cap, { perJob: false, note: `Place photo · ${r.name} · hold` });
  let settled = false;
  try {
    const out = await ctx.images.generate({ studioId: u.studioId, userId: u.id, purpose: 'place_photo', refId: r.id,
      req: { prompt: p.prompt, width: 768, height: 1344, count: 1 }, refs: p.refs, ...(p.editOf ? { editOf: p.editOf } : {}) });
    const image = out.images[0];
    if (!image) throw new Error('no image');
    const actual = Math.min(cap, Math.max(MIN_CHARGE_USD, Math.round(out.costUsd * 10000) / 10000));
    await ctx.money.settle(u.studioId, u.id, refId, hold, actual, `Place photo · ${r.name}`);
    settled = true;
    const view = await appendImage(ctx, await getLocation(ctx, u, id), image, b.mode);
    return { place: view, chargedUsd: actual };
  } catch (e) {
    if (settled) throw e;
    await ctx.money.release(u.studioId, u.id, refId, hold, 'place photo not made').catch(() => undefined);
    const spent = e instanceof PhotoError ? e.spentUsd : 0;
    if (spent > 1e-9) await ctx.money.overhead(u.studioId, spent, 'Place photo that didn’t finish').catch(() => undefined);
    if (e instanceof ApiError && e.status < 500) throw e;
    ctx.log?.warn({ err: String((e as Error)?.message ?? e) }, 'place photo');
    throw new ApiError(502, 'place_photo_failed', 'Couldn’t make the place photo · you weren’t charged · try again');
  }
}

// ------------------------------------------------------------------ @tag in a Shot or Photo
export type ResolvedPlace = { id: string; name: string; tag: string; description: string; image: { asset?: string; url?: string } | null };
/** `@tag` words in a prompt (not e-mail addresses). */
const TAG_RE = /(^|[^A-Za-z0-9_.])@([A-Za-z0-9][A-Za-z0-9_-]{0,29})/g;
/**
 * The place a Shot or Photo names: `placeId`, else the first `@tag` in the prompt that is one of her places (then the
 * studio's). The prompt comes back with that @tag as the place's name. No place: the prompt as is.
 */
export async function resolvePlace(ctx: Ctx, u: AuthUser, o: { placeId?: string; prompt: string; modelId?: string | null }): Promise<{ place: ResolvedPlace | null; prompt: string }> {
  const rows = await ctx.db.select().from(suiteLocations).where(eq(suiteLocations.studioId, u.studioId));
  const visible = rows.filter(r => !r.modelId || r.modelId === o.modelId);
  let row: Row | undefined;
  if (o.placeId) {
    row = rows.find(r => r.id === o.placeId);
    if (!row) throw badRequest('placeId: no such place in the studio');
  }
  const byTag = (t: string) => visible.filter(r => tagOf(r) === t.toLowerCase()).sort((a, b) => (a.modelId ? 0 : 1) - (b.modelId ? 0 : 1))[0];
  if (!row) for (const m of o.prompt.matchAll(TAG_RE)) { row = byTag(m[2]!); if (row) break; }
  if (!row) return { place: null, prompt: o.prompt };
  const tag = tagOf(row), name = row.name;
  const prompt = o.prompt.replace(TAG_RE, (all, pre: string, t: string) => (t.toLowerCase() === tag ? `${pre}${name}` : all));
  return { place: { id: row.id, name, tag, description: (row.description ?? '').trim(), image: coverOf(row) }, prompt };
}
/** The place in words, when its photo isn't sent ("Setting: corner café with a striped awning."). */
export const placeSetting = (p: ResolvedPlace) => {
  const d = p.description.replace(/\.+$/, '');
  return d ? `Setting: ${p.name}, ${d.charAt(0).toLowerCase()}${d.slice(1)}.` : `Setting: ${p.name}.`;
};
