// The stored file behind an edit's asset (2026-11-12), for the server tools that read it (approximate frames, contact
// sheets, action peaks, watch, audio energy). An asset names a take (its video) or an upload. Edit's uploads are never
// confirmed by the apps (presign + PUT only), so a pending upload whose file is stored is made ready here
// (storage/objects.ts readyIfStored) instead of being treated as missing.
import { and, eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { takes, uploads } from '../db/schema.js';
import { ApiError, badRequest } from '../errors.js';
import { readyIfStored } from '../storage/objects.js';
import * as M from './model.js';

export type AssetMedia = { key: string; contentType: string; takeId?: string; uploadId?: string };

/** The stored media of an asset in this studio; null when it has none (yet). */
export async function assetMedia(ctx: Pick<Ctx, 'db' | 'storage'>, studioId: string, a: M.Asset): Promise<AssetMedia | null> {
  if (a.take) {
    const [t] = await ctx.db.select().from(takes).where(and(eq(takes.id, a.take), eq(takes.studioId, studioId)));
    if (!t?.mediaKey) return null;
    return { key: t.mediaKey, contentType: String((t.media as { contentType?: string } | null)?.contentType ?? 'video/mp4'), takeId: t.id };
  }
  if (a.upload) {
    const [up] = await ctx.db.select().from(uploads).where(and(eq(uploads.id, a.upload), eq(uploads.studioId, studioId)));
    if (!up || !(await readyIfStored(ctx, up))) return null;
    return { key: up.storageKey, contentType: up.contentType, uploadId: up.id };
  }
  return null;
}

/** The asset an id names inside an edit: a timeline item (clip, music, voice-over, overlay) or an asset id. */
export function assetIn(p: M.EditProject, id: string): M.Asset | null {
  const direct = p.assets.find(a => a.id === id);
  if (direct) return direct;
  for (const t of p.tracks) {
    const it = (t.items as { id: string; asset?: string }[]).find(i => i.id === id);
    if (it?.asset) return p.assets.find(a => a.id === it.asset) ?? null;
  }
  return null;
}

/** Like assetMedia, but throws a plain reason when the asset has no readable file. */
export async function requireAssetMedia(ctx: Pick<Ctx, 'db' | 'storage'>, studioId: string, a: M.Asset): Promise<AssetMedia> {
  if (!a.take && !a.upload) throw badRequest(`${a.id} has no stored file to read (a built-in ${a.kind})`);
  const m = await assetMedia(ctx, studioId, a);
  if (!m) throw new ApiError(409, 'not_ready', `${a.id}: its file (${a.take ? `take ${a.take}` : `upload ${a.upload}`}) hasn't arrived on the server yet`);
  return m;
}
