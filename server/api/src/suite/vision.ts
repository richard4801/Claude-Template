// Claude sees the cast (owner bug 5A.5): small JPEG thumbnails of a model's reference images and an outfit's angle
// images, sent to Claude as image content, plus each outfit's date so two outfits with the same name can be told apart.
// Studio-scoped like every cast read; thumbnails are cached in memory. Written for the Suite; the Edit and Recreate
// Claude tools can call the same helpers later (one-Claude plan, HANDOVER §6).
import fs from 'node:fs';
import path from 'node:path';
import { and, eq, isNull } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { models, outfits, type ImageRef } from '../db/schema.js';
import { ASSET_DIR, ASSET_KEYS } from '../images/service.js';

export const SEE_EDGE = 512, LIST_EDGE = 256;
const MAX_SOURCE_BYTES = 15 * 1024 * 1024, CACHE_MAX = 200;
export type SeeBlock = { type: 'image'; data: string; mimeType: 'image/jpeg' } | { type: 'text'; text: string };

const cache = new Map<string, string>(); // `${studio}|${edge}|${ref}` → base64 JPEG (oldest first)

async function refBytes(ctx: Ctx, ref: ImageRef): Promise<Buffer | null> {
  if (ref.asset && ASSET_KEYS.includes(ref.asset)) return fs.readFileSync(path.join(ASSET_DIR, `${ref.asset}.jpg`));
  const key = ctx.images.keyOf(ref);
  if (key) {
    const obj = await ctx.storage.get(key);
    if (!obj) return null;
    const parts: Buffer[] = [];
    let size = 0;
    for await (const ch of obj.body) { size += (ch as Buffer).length; if (size > MAX_SOURCE_BYTES) return null; parts.push(ch as Buffer); }
    return Buffer.concat(parts);
  }
  if (ref.url && /^https:\/\//.test(ref.url)) {
    try {
      const r = await fetch(ref.url, { signal: AbortSignal.timeout(15_000) });
      if (!r.ok || Number(r.headers.get('content-length') ?? 0) > MAX_SOURCE_BYTES) return null;
      const b = Buffer.from(await r.arrayBuffer());
      return b.length > MAX_SOURCE_BYTES ? null : b;
    } catch { return null; }
  }
  return null;
}

/** A small upright JPEG (long edge ≤ `edge`), base64; null when the image can't be read. Cached. */
export async function thumbOf(ctx: Ctx, ref: ImageRef | null | undefined, studioId: string, edge = SEE_EDGE): Promise<string | null> {
  if (!ref || (!ref.asset && !ref.url)) return null;
  const k = `${studioId}|${edge}|${ref.asset ?? ref.url}`;
  const hit = cache.get(k);
  if (hit) { cache.delete(k); cache.set(k, hit); return hit; }
  const src = await refBytes(ctx, ref);
  if (!src) return null;
  try {
    const sharp = (await import('sharp')).default;
    const out = await sharp(src).rotate().resize(edge, edge, { fit: 'inside', withoutEnlargement: true }).flatten({ background: '#ffffff' }).jpeg({ quality: 80 }).toBuffer();
    const b64 = out.toString('base64');
    cache.set(k, b64);
    while (cache.size > CACHE_MAX) cache.delete(cache.keys().next().value!);
    return b64;
  } catch { return null; }
}

/** Labelled image blocks ("label" text, then the image), images that can't be read left out. */
export async function seeBlocks(ctx: Ctx, studioId: string, items: { label: string; ref: ImageRef | null | undefined }[], edge = SEE_EDGE): Promise<SeeBlock[]> {
  const thumbs = await Promise.all(items.map(i => thumbOf(ctx, i.ref, studioId, edge)));
  return items.flatMap((i, n) => (thumbs[n] ? [{ type: 'text' as const, text: i.label }, { type: 'image' as const, data: thumbs[n]!, mimeType: 'image/jpeg' as const }] : []));
}

export const dateOf = (ms: number) => new Date(ms).toISOString().slice(0, 16).replace('T', ' ') + ' UTC';
const MODEL_SLOTS: [string, string][] = [['face', 'face'], ['faceTq', 'face ¾'], ['profile', 'profile'], ['front', 'body front'], ['tq', 'body ¾'], ['side', 'body side'], ['back', 'body back']];
/** An outfit's 7 slots as outfit_reorder names them, with the words a person reads (owner 2026-11-12: labelled slots). */
const OUTFIT_SLOTS: [string, string][] = [['front', 'front'], ['tq', '¾'], ['side', 'side'], ['back', 'back'], ['face', 'face front'], ['faceTq', 'face ¾'], ['profile', 'face side']];
const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n)}…` : s);

/**
 * What a model and/or outfit look like: the facts (names, the outfit's description and date) and the images.
 * `modelFull` / `outfitFull`: every reference / every angle and face; otherwise the model's face, the outfit's front.
 */
export async function lookOf(ctx: Ctx, u: AuthUser, o: { modelId?: string | null; outfitId?: string | null; modelFull?: boolean; outfitFull?: boolean }) {
  const meta: Record<string, unknown> = {};
  const items: { label: string; ref: ImageRef | null | undefined }[] = [];
  if (o.modelId) {
    const [m] = await ctx.db.select().from(models).where(and(eq(models.id, o.modelId), eq(models.studioId, u.studioId)));
    if (m) {
      meta.model = { id: m.id, name: m.name, look: m.look || undefined };
      const slot = (k: string) => m.slots.find(s => s.key === k)?.image;
      for (const [k, label] of o.modelFull ? MODEL_SLOTS : MODEL_SLOTS.slice(0, 1)) if (slot(k)) items.push({ label: `@${m.name} · ${label}`, ref: slot(k) });
    } else meta.model = { id: o.modelId, missing: true };
  }
  if (o.outfitId) {
    const [f] = await ctx.db.select().from(outfits).where(and(eq(outfits.id, o.outfitId), eq(outfits.studioId, u.studioId)));
    if (f) {
      meta.outfit = { id: f.id, name: f.name, created: dateOf(f.createdAt), description: clip(f.description, 400) || undefined, modelId: f.modelId, state: f.state };
      const tag = `outfit “${f.name}” (${dateOf(f.createdAt)})`;
      // Each picture with its slot, so a misplaced one can be fixed with outfit_reorder (slot side holding the back view).
      const pics = [...[0, 1, 2, 3].map(i => f.angles[i] ?? null), ...[0, 1, 2].map(i => f.faces?.[i] ?? null)];
      pics.forEach((r, i) => { if (r && (o.outfitFull || i === 0)) items.push({ label: `${tag} · slot ${OUTFIT_SLOTS[i]![0]} (${OUTFIT_SLOTS[i]![1]})`, ref: r }); });
      if (o.outfitFull) (meta.outfit as Record<string, unknown>).emptySlots = OUTFIT_SLOTS.filter((_, i) => !pics[i]).map(x => x[0]);
    } else meta.outfit = { id: o.outfitId, missing: true };
  }
  return { meta, blocks: await seeBlocks(ctx, u.studioId, items) };
}

/** The studio's models and their ready outfits (newest first), each with its date and one small thumbnail. */
export async function castOf(ctx: Ctx, u: AuthUser, o: { modelId?: string; maxImages?: number } = {}) {
  const ms = (await ctx.db.select().from(models).where(and(eq(models.studioId, u.studioId), isNull(models.archivedAt))))
    .filter(m => !o.modelId || m.id === o.modelId);
  const fs_ = (await ctx.db.select().from(outfits).where(eq(outfits.studioId, u.studioId)))
    .filter(f => f.state === 'ready' && ms.some(m => m.id === f.modelId)).sort((a, b) => b.createdAt - a.createdAt);
  const items: { label: string; ref: ImageRef | null | undefined }[] = [];
  const cast = ms.map(m => {
    const face = m.slots.find(s => s.key === 'face')?.image;
    if (face) items.push({ label: `@${m.name} (model ${m.id}) · face`, ref: face });
    const mine = fs_.filter(f => f.modelId === m.id);
    const dup = (n: string) => mine.filter(f => f.name.trim().toLowerCase() === n.trim().toLowerCase()).length > 1;
    for (const f of mine) if (f.angles[0]) items.push({ label: `outfit “${f.name}” (${f.id}, ${dateOf(f.createdAt)}) · front`, ref: f.angles[0] });
    return { id: m.id, name: m.name, outfits: mine.map(f => ({ id: f.id, name: f.name, created: dateOf(f.createdAt), ...(dup(f.name) ? { sameNameAsAnother: true } : {}), description: clip(f.description, 160) || undefined })) };
  });
  const max = o.maxImages ?? 24;
  return { cast, blocks: await seeBlocks(ctx, u.studioId, items.slice(0, max), LIST_EDGE), imagesLeftOut: Math.max(0, items.length - max) };
}

/** A tool result with images: the JSON first (structured for the apps and tests), then the labelled images. */
export const withLook = <T extends Record<string, unknown>>(data: T, blocks: SeeBlock[]) =>
  (blocks.length ? { ...data, mcpContent: [{ type: 'text' as const, text: JSON.stringify(data) }, ...blocks], structuredContent: data } : data);
