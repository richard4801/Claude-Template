// Photo templates (plans/templates.md, contract in plans/api.md "Photo templates").
// The one rule that matters: a template's `layers` and `variationPool` (and the full prompt and draws of shots made with
// it) are sent only to its owner. Every view in this file goes through `templateView` / `shotPromptFor`.
import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { and, desc, eq, inArray, isNotNull, or, sql } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { POOL_SLOTS, takes, templateFavourites, templates, users, type ImageRef, type TemplateLayers, type VariationPool } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { ASSET_DIR, ASSET_KEYS } from '../images/service.js';
import { putObject } from '../storage/objects.js';
import { applyAfterEffects, GRADES, hasEffects } from './effects.js';
import { buildTemplatePrompt, cleanPool, poolIsEmpty, randomSeed, suggestPool } from './prompt.js';
import { STARTERS } from './starters.js';
import type { Identity, OutfitSpec, SentRef } from '../prompt/engine.js';

type Row = typeof templates.$inferSelect;
type TakeRow = typeof takes.$inferSelect;

import { hasLook, photoLook } from '../editor/photo.js';

const str = (max: number) => z.string().trim().max(max);
export const LayersSchema = z.object({
  style: str(600).optional(), scene: str(600).optional(), camera: str(600).optional(), light: str(600).optional(),
  negative: str(600).optional(), product: str(600).optional(),
  afterEffects: z.object({
    faceMotionBlur: z.number().min(0).max(1).optional(), blurAngle: z.number().min(-360).max(360).optional(),
    grade: z.enum(GRADES).optional(), grain: z.number().min(0).max(1).optional(),
    look: z.unknown().optional().transform(v => photoLook(v, 'afterEffects.look')), // Editor v2 look (workstream 3)
  }).strip().optional(),
}).strip();
export const PoolSchema = z.object(Object.fromEntries(POOL_SLOTS.map(s => [s, z.array(str(200)).max(12).optional()]))).strip();
const Tags = z.array(str(40).min(1)).max(12);
const Visibility = z.enum(['private', 'public']);

const parse = <T>(schema: z.ZodType<T>, body: unknown): T => {
  const r = schema.safeParse(body ?? {});
  if (!r.success) { const i = r.error.issues[0]!; throw badRequest(`${i.path.join('.') || 'body'}: ${i.message}`); }
  return r.data;
};
const cleanLayers = (l: TemplateLayers | undefined): TemplateLayers => {
  const out: TemplateLayers = {};
  for (const k of ['style', 'scene', 'camera', 'light', 'negative', 'product'] as const) if (l?.[k]?.trim()) out[k] = l[k]!.trim();
  const fx = l?.afterEffects;
  if (fx) {
    const f = compact({ faceMotionBlur: fx.faceMotionBlur || undefined, blurAngle: fx.faceMotionBlur ? fx.blurAngle : undefined,
      grade: fx.grade && fx.grade !== 'none' ? fx.grade : undefined, grain: fx.grain || undefined, look: hasLook(fx.look) ? fx.look : undefined });
    if (Object.keys(f).length) out.afterEffects = f;
  }
  return out;
};
const uniqTags = (t: string[] = []) => [...new Map(t.map(x => x.trim()).filter(Boolean).map(x => [x.toLowerCase(), x])).values()];
const ownerName = (email: string) => { const n = email.split('@')[0] ?? email; return n.charAt(0).toUpperCase() + n.slice(1); };

export class TemplateService {
  private seeded = new Set<string>();
  constructor(private ctx: Ctx) {}

  private coverRef(key: string | null): ImageRef | null {
    return key ? { url: `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${key}` } : null;
  }

  /** The one place a template becomes JSON. Hidden fields only when the viewer owns it. */
  async views(rows: Row[], viewer: AuthUser): Promise<Record<string, unknown>[]> {
    if (!rows.length) return [];
    const ids = rows.map(r => r.id);
    const favs = new Set((await this.ctx.db.select({ id: templateFavourites.templateId }).from(templateFavourites)
      .where(and(eq(templateFavourites.userId, viewer.id), inArray(templateFavourites.templateId, ids)))).map(f => f.id));
    const ownerIds = [...new Set(rows.map(r => r.ownerId))];
    const owners = new Map((await this.ctx.db.select({ id: users.id, email: users.email }).from(users).where(inArray(users.id, ownerIds))).map(u => [u.id, ownerName(u.email)]));
    return rows.map(t => {
      const mine = t.ownerId === viewer.id;
      return compact({
        id: t.id, name: t.name, tags: t.tags, visibility: t.visibility, ownerId: t.ownerId, ownerName: owners.get(t.ownerId) ?? 'Someone',
        isOwner: mine, uses: t.uses, favourite: favs.has(t.id), cover: this.coverRef(t.coverKey), acceptsProduct: !!t.layers.product,
        starter: t.slug ?? undefined, createdFromShotId: t.createdFromShotId ?? undefined, createdAt: t.createdAt, updatedAt: t.updatedAt,
        ...(mine ? { layers: t.layers, variationPool: t.variationPool } : {}),
      });
    });
  }
  async view(t: Row, viewer: AuthUser) { return (await this.views([t], viewer))[0]!; }

  /**
   * Live `template` events: each viewer gets their own view (layers and pool only to the template's owner); someone who
   * can't see it (a private template of someone else, or one just made private) gets a delete for its id.
   */
  emitChange(t: Row) {
    return this.ctx.hub.emit(t.studioId, async v => {
      if (t.ownerId !== v.userId && t.visibility !== 'public') return { type: 'template', op: 'delete', id: t.id };
      const viewer = { id: v.userId, studioId: v.studioId, role: v.role, email: '', studioName: '', sessionId: null } as AuthUser;
      return { type: 'template', template: await this.view(t, viewer) };
    });
  }

  /** A template this user may see: their own, or a public one in their studio. Anything else is not_found. */
  async visible(u: AuthUser, id: string): Promise<Row> {
    const [t] = await this.ctx.db.select().from(templates).where(and(eq(templates.id, id), eq(templates.studioId, u.studioId)));
    if (!t || (t.ownerId !== u.id && t.visibility !== 'public')) throw notFound('Template');
    return t;
  }
  async owned(u: AuthUser, id: string): Promise<Row> {
    const t = await this.visible(u, id);
    if (t.ownerId !== u.id) throw new ApiError(403, 'owner_only', 'Only the person who made this template can change it');
    return t;
  }

  async list(u: AuthUser, q: { scope?: string; q?: string; tag?: string }) {
    await this.ensureStarters(u.studioId);
    const scope = q.scope || 'all';
    if (!['all', 'mine', 'public', 'favourites'].includes(scope)) throw badRequest('scope must be all, mine, public or favourites');
    const canSee = or(eq(templates.ownerId, u.id), eq(templates.visibility, 'public'))!;
    const conds = [eq(templates.studioId, u.studioId)];
    if (scope === 'mine') conds.push(eq(templates.ownerId, u.id));
    else if (scope === 'public') conds.push(eq(templates.visibility, 'public'));
    else conds.push(canSee);
    if (scope === 'favourites') conds.push(sql`exists (select 1 from ${templateFavourites} f where f.template_id = ${templates.id} and f.user_id = ${u.id})`);
    const text = q.q?.trim().toLowerCase();
    if (text) conds.push(sql`(lower(${templates.name}) like ${`%${text}%`} or exists (select 1 from jsonb_array_elements_text(${templates.tags}) tg where lower(tg) like ${`%${text}%`}))`);
    const tag = q.tag?.trim().toLowerCase();
    if (tag) conds.push(sql`exists (select 1 from jsonb_array_elements_text(${templates.tags}) tg where lower(tg) = ${tag})`);
    const rows = await this.ctx.db.select().from(templates).where(and(...conds)).orderBy(desc(templates.updatedAt), templates.name);
    return this.views(rows, u);
  }

  async detail(u: AuthUser, id: string) {
    const t = await this.visible(u, id);
    const recent = await this.ctx.db.select({ id: takes.id, thumb: takes.thumb, createdAt: takes.createdAt }).from(takes)
      .where(and(eq(takes.templateId, t.id), eq(takes.studioId, u.studioId), isNotNull(takes.thumb))).orderBy(desc(takes.createdAt)).limit(6);
    return { ...(await this.view(t, u)), recent };
  }

  /** The shot behind "Save as template": its layers, unless they belong to someone else's template. */
  private async shotSource(u: AuthUser, shotId: string) {
    const [s] = await this.ctx.db.select().from(takes).where(and(eq(takes.id, shotId), eq(takes.studioId, u.studioId)));
    if (!s) throw notFound('Shot');
    if (s.templateId && s.templateOwnerId !== u.id) {
      throw new ApiError(403, 'template_hidden', 'This photo was made with someone else’s template, so its look can’t be saved. Use that template instead.');
    }
    let layers = cleanLayers(s.layers ?? undefined);
    let pool: VariationPool = {};
    let name = s.templateName ?? s.title.replace(/^Shoot · /, '');
    let tags: string[] = [];
    if (s.templateId) {
      const [t] = await this.ctx.db.select().from(templates).where(eq(templates.id, s.templateId));
      if (t) { layers = cleanLayers({ ...t.layers, ...layers }); pool = t.variationPool; tags = t.tags; name = t.name; }
    }
    if (!Object.keys(layers).length && s.prompt) layers = layersFromPrompt(s.prompt);
    if (poolIsEmpty(pool)) {
      pool = suggestPool(layers, name);
      // The shot's own direction (or drawn pose) is the first pose option, so the saved look starts from that moment.
      const first = s.variation?.direction ?? s.variation?.pose ?? directionFromPrompt(s.prompt);
      if (first) pool.pose = [first, ...(pool.pose ?? []).filter(p => p !== first)].slice(0, 12);
    }
    return { shot: s, layers, pool: cleanPool(pool), name: name.slice(0, 80) || 'My look', tags };
  }

  async draft(u: AuthUser, body: unknown) {
    const b = parse(z.object({ fromShotId: z.string() }), body);
    const src = await this.shotSource(u, b.fromShotId);
    return { name: src.name, tags: src.tags, layers: src.layers, variationPool: src.pool, cover: src.shot.thumb ?? null, fromShotId: src.shot.id };
  }

  async create(u: AuthUser, body: unknown) {
    const b = parse(z.object({
      name: str(80).min(1), tags: Tags.optional(), visibility: Visibility.optional(), layers: LayersSchema.optional(), variationPool: PoolSchema.optional(),
      coverTakeId: z.string().optional(), fromShotId: z.string().optional(),
    }), body);
    let layers = cleanLayers(b.layers as TemplateLayers);
    let pool = cleanPool(b.variationPool as VariationPool);
    let coverKey: string | null = null, fromShot: string | null = null;
    let tags = uniqTags(b.tags);
    if (b.fromShotId) {
      const src = await this.shotSource(u, b.fromShotId);
      layers = src.layers;
      if (poolIsEmpty(pool)) pool = src.pool;
      if (!b.tags) tags = src.tags;
      coverKey = await this.copyCover(src.shot, u.studioId);
      fromShot = src.shot.id;
    } else {
      if (poolIsEmpty(pool)) pool = suggestPool(layers, b.name);
      if (b.coverTakeId) {
        const [t] = await this.ctx.db.select().from(takes).where(and(eq(takes.id, b.coverTakeId), eq(takes.studioId, u.studioId)));
        if (!t) throw notFound('Take');
        coverKey = await this.copyCover(t, u.studioId);
      }
    }
    const now = Date.now();
    const [t] = await this.ctx.db.insert(templates).values({
      id: uid('tpl'), studioId: u.studioId, ownerId: u.id, visibility: b.visibility ?? 'private', name: b.name, tags,
      layers, variationPool: pool, coverKey, createdFromShotId: fromShot, createdAt: now, updatedAt: now,
    }).returning();
    void this.emitChange(t!);
    return this.view(t!, u);
  }

  private async copyCover(t: TakeRow, studioId: string) {
    return t.mediaKey && t.kind === 'shot' ? t.mediaKey : await this.ctx.images.storedKey(t.thumb, studioId);
  }

  async patch(u: AuthUser, id: string, body: unknown) {
    const t = await this.owned(u, id);
    const b = parse(z.object({ name: str(80).min(1).optional(), tags: Tags.optional(), visibility: Visibility.optional(),
      layers: LayersSchema.optional(), variationPool: PoolSchema.optional() }), body);
    const [r] = await this.ctx.db.update(templates).set(compact({
      name: b.name, tags: b.tags ? uniqTags(b.tags) : undefined, visibility: b.visibility,
      layers: b.layers ? cleanLayers(b.layers as TemplateLayers) : undefined, variationPool: b.variationPool ? cleanPool(b.variationPool as VariationPool) : undefined,
      updatedAt: Date.now(),
    })).where(eq(templates.id, t.id)).returning();
    void this.emitChange(r!);
    return this.view(r!, u);
  }

  async remove(u: AuthUser, id: string) {
    const t = await this.owned(u, id);
    await this.ctx.db.delete(templates).where(eq(templates.id, t.id));
    void this.ctx.hub.emit(t.studioId, { type: 'template', op: 'delete', id: t.id });
  }

  async duplicate(u: AuthUser, id: string) {
    const t = await this.owned(u, id);
    const now = Date.now();
    const [r] = await this.ctx.db.insert(templates).values({
      ...t, id: uid('tpl'), name: `${t.name} copy`.slice(0, 80), visibility: 'private', slug: null, uses: 0, createdAt: now, updatedAt: now,
    }).returning();
    void this.emitChange(r!);
    return this.view(r!, u);
  }

  async favourite(u: AuthUser, id: string, on: boolean) {
    const t = await this.visible(u, id);
    if (on) await this.ctx.db.insert(templateFavourites).values({ userId: u.id, templateId: t.id, createdAt: Date.now() }).onConflictDoNothing();
    else await this.ctx.db.delete(templateFavourites).where(and(eq(templateFavourites.userId, u.id), eq(templateFavourites.templateId, t.id)));
    const view = await this.view(t, u);
    // A favourite is personal: only this user's devices hear about it.
    void this.ctx.hub.emitTo(u.id, { type: 'template', template: view });
    return view;
  }

  /** The prompt view: what the first still of a shoot would get. Non-owners see only the visible slots. */
  async preview(u: AuthUser, id: string, body: unknown, resolve: (modelId: string, outfitId?: string) => Promise<{ identity: Identity; outfit: OutfitSpec | null }>,
    extra: { refs?: SentRef[] } = {}) {
    const t = await this.visible(u, id);
    const b = parse(z.object({ modelId: z.string(), outfitId: z.string().optional(), direction: str(500).optional(),
      shuffleSeed: z.number().int().min(0).optional(), lockSeed: z.boolean().optional() }).passthrough(), body);
    const { identity, outfit } = await resolve(b.modelId, b.outfitId);
    const shuffleSeed = b.shuffleSeed ?? randomSeed();
    const p = buildTemplatePrompt({ templateId: t.id, templateName: t.name, layers: t.layers, pool: t.variationPool, identity, outfit,
      direction: b.direction, shuffleSeed, lockSeed: b.lockSeed, hasProduct: false, refs: extra.refs }, await this.ctx.prompts.texts(u.studioId));
    const mine = t.ownerId === u.id;
    return compact({ slots: mine ? p.full : p.visible, text: mine ? p.fullText : p.visibleText, seed: p.seed, shuffleSeed, variation: mine ? p.variation : undefined, removed: p.removed.length ? p.removed : undefined });
  }

  /** Runs a still through the template's after-effects; returns a stored ref (or the original when there's nothing to do). */
  async postProcess(ref: ImageRef, layers: TemplateLayers, o: { studioId: string; userId: string }): Promise<{ ref: ImageRef; key: string | null }> {
    const fx = layers.afterEffects;
    const key0 = this.ctx.images.keyOf(ref);
    if (!hasEffects(fx)) return { ref, key: key0 };
    const bytes = await this.bytesOf(ref, o.studioId);
    if (!bytes) return { ref, key: key0 };
    const out = await applyAfterEffects(bytes, fx!);
    const key = `g/${uid('fx')}.jpg`;
    await putObject(this.ctx, { key, body: out, studioId: o.studioId, kind: 'generated', userId: o.userId, contentType: 'image/jpeg' });
    return { ref: { url: `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${key}` }, key };
  }

  private async bytesOf(ref: ImageRef, studioId: string): Promise<Buffer | null> {
    if (ref.asset && ASSET_KEYS.includes(ref.asset)) return fs.readFileSync(path.join(ASSET_DIR, `${ref.asset}.jpg`));
    const key = await this.ctx.images.storedKey(ref, studioId);
    if (key) {
      const obj = await this.ctx.storage.get(key);
      if (!obj) return null;
      const chunks: Buffer[] = [];
      for await (const c of obj.body as Readable) chunks.push(c as Buffer);
      return Buffer.concat(chunks);
    }
    if (ref.url && /^https?:\/\//.test(ref.url)) {
      try { const r = await fetch(ref.url, { signal: AbortSignal.timeout(30_000) }); return r.ok ? Buffer.from(await r.arrayBuffer()) : null; } catch { return null; }
    }
    return null;
  }

  async bumpUses(id: string) {
    const [t] = await this.ctx.db.update(templates).set({ uses: sql`${templates.uses} + 1` }).where(eq(templates.id, id)).returning();
    if (t) void this.emitChange(t);
  }

  // ---------------------------------------------------------------------------------------------- starter pack
  /** Adds any missing starter templates to one studio (keyed by slug). Needs a studio owner. Idempotent. */
  async ensureStarters(studioId: string, force = false) {
    if (this.seeded.has(studioId) && !force) return 0;
    const [owner] = await this.ctx.db.select({ id: users.id }).from(users).where(and(eq(users.studioId, studioId), eq(users.role, 'owner'))).orderBy(users.createdAt).limit(1);
    if (!owner) return 0;
    const have = new Set((await this.ctx.db.select({ slug: templates.slug }).from(templates).where(and(eq(templates.studioId, studioId), isNotNull(templates.slug)))).map(r => r.slug));
    let added = 0;
    const now = Date.now();
    for (const [i, s] of STARTERS.entries()) {
      if (have.has(s.slug)) continue;
      const coverKey = `t/${studioId}/starter-${s.slug}.jpg`;
      try {
        if (!(await this.ctx.storage.head(coverKey))) {
          const src = fs.readFileSync(path.join(ASSET_DIR, `${s.coverAsset}.jpg`));
          const body = await applyAfterEffects(src, s.layers.afterEffects ?? {}, { maxWidth: 640 });
          await putObject(this.ctx, { key: coverKey, body, studioId, kind: 'asset', contentType: 'image/jpeg' });
        }
      } catch (e) { this.ctx.log.warn({ slug: s.slug, err: (e as Error).message }, 'starter cover failed'); }
      const r = await this.ctx.db.insert(templates).values({
        id: uid('tpl'), studioId, ownerId: owner.id, visibility: 'public', name: s.name, tags: s.tags, layers: s.layers, variationPool: s.variationPool,
        coverKey, slug: s.slug, createdAt: now - i, updatedAt: now - i,
      }).onConflictDoNothing().returning({ id: templates.id });
      added += r.length;
    }
    this.seeded.add(studioId);
    return added;
  }

  /** On start: every studio with an owner. */
  async seedAllStarters() {
    const studios = await this.ctx.db.selectDistinct({ id: users.studioId }).from(users).where(eq(users.role, 'owner'));
    let added = 0;
    for (const s of studios) added += await this.ensureStarters(s.id, true);
    return { studios: studios.length, added };
  }
  forget(studioId?: string) { if (studioId) this.seeded.delete(studioId); else this.seeded.clear(); }
}

/** Plain shoots store their prompt as "Scene: …\nCamera: …\nLight: …". Pull the copyable layers back out. */
export function layersFromPrompt(prompt: string): TemplateLayers {
  const get = (label: string) => new RegExp(`^${label}: (.+)$`, 'm').exec(prompt)?.[1]?.replace(/\.$/, '').trim();
  const light = get('Light');
  return cleanLayers({ scene: get('Scene'), camera: get('Camera'), light, style: undefined });
}
const directionFromPrompt = (prompt: string) => /^Direction: (.+)$/m.exec(prompt)?.[1]?.replace(/\.$/, '').trim();

/** The prompt a viewer may see for a shot: template shots show the public version to anyone but the template's owner. */
export function shotPromptFor(t: TakeRow, viewerId: string): { prompt: string; variation?: unknown } {
  if (!t.templateId) return { prompt: t.prompt };
  if (t.templateOwnerId === viewerId) return { prompt: t.prompt, variation: t.variation ?? undefined };
  return { prompt: t.publicPrompt ?? `Template: ${t.templateName ?? 'template'}` };
}
