// Import a video from a link (WS12, owner-approved; plans/api.md "Import a video from a link"). A pasted TikTok,
// Instagram, YouTube or (with "Strict link rules" off) other public link becomes an ordinary Library clip, a source for
// the Suite's Swap and Edit and the editor's media bin. The DEVICE downloads (platforms block cloud servers), uploads
// through the normal presign flow, then POST /v1/imports; the server checks the file against the studio's link rules
// and the limits, stores it, makes a poster frame and dedupes by the normalised link per member. A server-side fetch
// (yt-dlp, often blocked) stays as a fallback with the Recreate guardrails: public only, no cookies, TikTok's
// downloads-off honoured under strict rules, one platform request at a time, plain error codes.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { and, desc, eq, inArray, sql } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { clips, jobs, uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import * as P from '../pricing.js';
import { probe, thumbnail } from '../replicate/media.js';
import { analyzeClip, audioView } from '../audio/service.js';
import { putObject } from '../storage/objects.js';
import { checkInfo, FALLBACK, linkError, linkFor, tiktokDownloadsOff, type AnyPlatform } from '../recreate/links.js';
import { MAX_REFERENCE_SEC, recreateOf } from '../recreate/references.js';
import { MODELS } from '../suite/registry.js';

type ClipRow = typeof clips.$inferSelect;
/** What an import keeps in `clips.meta` (no migration: the clip row is the Library item the swap already takes). */
export type ImportMeta = { source: 'import'; sourceUrl?: string | null; platform?: AnyPlatform | null; bytes: number; posterKey?: string | null; uploadId: string; userId: string; via: 'device' | 'server' };

/**
 * The longest source the Suite's swap and recast engines take (registry `recast.sourceSeconds`, and reference videos'
 * `videoSecondsMax`): 30 s today. Imports are for those tools, so they are held to it.
 */
export const IMPORT_MAX_SEC = Math.max(30, ...MODELS.map(m => Math.max((m as { recast?: { sourceSeconds?: [number, number] } }).recast?.sourceSeconds?.[1] ?? 0, m.refs?.videoSecondsMax ?? 0)));
const POSTER_AT = 0.5;

const CreateBody = z.union([
  z.object({ uploadId: z.string().min(1).max(80), sourceUrl: z.string().trim().min(8).max(500).optional(), name: z.string().trim().max(120).optional() }).strict(),
  z.object({ url: z.string().trim().min(8).max(500), name: z.string().trim().max(120).optional() }).strict(),
  // The Mac's spelling of the server fallback: the link as `sourceUrl`, no upload.
  z.object({ sourceUrl: z.string().trim().min(8).max(500), name: z.string().trim().max(120).optional() }).strict(),
]);
const CheckBody = z.object({ url: z.string().trim().min(8).max(500), purpose: z.enum(['import', 'reference']).default('import') }).strict();

function parse<T>(schema: z.ZodType<T>, body: unknown): T {
  const r = schema.safeParse(body ?? {});
  if (!r.success) throw badRequest(r.error.issues.map(i => `${i.path.join('.') || 'body'}: ${i.message}`).join('; '));
  return r.data;
}
const metaOf = (c: Pick<ClipRow, 'meta'>) => (c.meta ?? {}) as Partial<ImportMeta>;
export const isImport = (c: Pick<ClipRow, 'meta'>) => metaOf(c).source === 'import';

export class Imports {
  constructor(private ctx: Ctx) {}
  private get rx() { return recreateOf(this.ctx); }
  private get maxBytes() { return this.ctx.config.IMPORT_MAX_MB * 1048576; }
  private url(key: string) { return `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${key}`; }

  /** The Library clip, with what an import adds: where it came from, its poster and file. */
  view(c: ClipRow, extra: { cached?: boolean } = {}) {
    const m = metaOf(c);
    const out: Record<string, unknown> = {
      id: c.id, name: c.name, durationSec: c.durationSec, width: c.width, height: c.height, fps: P.wireFps(c.fps), checks: c.checks, audio: audioView(c) ?? undefined,
      source: 'import', sourceUrl: m.sourceUrl ?? undefined, platform: m.platform ?? undefined, bytes: m.bytes,
      posterUrl: m.posterKey ? this.url(m.posterKey) : undefined, thumb: m.posterKey ? { url: this.url(m.posterKey) } : undefined /* ImageRef, as on takes */, videoUrl: c.storageKey ? this.url(c.storageKey) : undefined, videoKey: c.storageKey ?? undefined,
      uploadId: m.uploadId, createdBy: c.createdBy ?? undefined, createdAt: c.createdAt, ...(extra.cached ? { cached: true } : {}),
    };
    for (const k of Object.keys(out)) if (out[k] === undefined) delete out[k];
    return out;
  }
  /** Imports go to the member who made it and the owner (like Recreate references). */
  private emit(c: ClipRow) {
    const v = this.view(c);
    void this.ctx.hub.emit(c.studioId, viewer => (viewer.userId === c.createdBy || viewer.role === 'owner' ? { type: 'clip', clip: v } : null));
  }

  // ------------------------------------------------------------------ link rules (shared with Recreate)
  /** GET /v1/links/settings: the studio's link rules and the import limits, for the apps to apply on the device. */
  async settings(u: AuthUser) {
    const strict = await this.rx.strictLinks(u.studioId);
    return { strictLinks: strict, platforms: strict ? ['tiktok', 'instagram', 'youtube'] : ['any'], tiktokDownloadsOff: strict ? 'refuse' : 'allow',
      maxSec: IMPORT_MAX_SEC, maxMb: this.ctx.config.IMPORT_MAX_MB, serverFetch: this.ctx.config.RECREATE_LINKS, cookies: false, canEdit: u.role === 'owner',
      reference: { maxSec: MAX_REFERENCE_SEC, maxMb: this.ctx.config.RECREATE_LINK_MAX_MB } };
  }
  /** POST /v1/links/check {url, purpose}: the link under the studio's rules, and this member's import (or reference) from it. */
  async check(u: AuthUser, body: unknown) {
    const b = parse(CheckBody, body);
    if (b.purpose === 'reference') return { ...(await this.rx.checkLink(u, { url: b.url })), purpose: 'reference' };
    try {
      const n = linkFor(b.url, { strict: await this.rx.strictLinks(u.studioId) });
      const hit = await this.cached(u, n.url);
      return { allowed: true, url: n.url, platform: n.platform, purpose: 'import', ...(hit ? { cached: this.view(hit, { cached: true }) } : {}) };
    } catch (e) {
      if (e instanceof ApiError) return { allowed: false, code: e.code, reason: e.message };
      throw e;
    }
  }
  /** This member's import from the same normalised link, if it is still here. */
  private async cached(u: AuthUser, url: string) {
    const [c] = await this.ctx.db.select().from(clips).where(and(eq(clips.studioId, u.studioId), eq(clips.createdBy, u.id),
      sql`${clips.meta}->>'source' = 'import'`, sql`${clips.meta}->>'sourceUrl' = ${url}`)).orderBy(desc(clips.createdAt)).limit(1);
    return c?.storageKey ? c : null;
  }

  // ------------------------------------------------------------------ CRUD
  async list(u: AuthUser) {
    const rows = await this.ctx.db.select().from(clips).where(and(eq(clips.studioId, u.studioId), sql`${clips.meta}->>'source' = 'import'`,
      ...(u.role === 'owner' ? [] : [eq(clips.createdBy, u.id)]))).orderBy(desc(clips.createdAt));
    return rows.map(r => this.view(r));
  }
  async row(u: AuthUser, id: string) {
    const [c] = await this.ctx.db.select().from(clips).where(and(eq(clips.id, id), eq(clips.studioId, u.studioId)));
    if (!c || !isImport(c) || (u.role !== 'owner' && c.createdBy !== u.id)) throw notFound('Import');
    return c;
  }
  async rename(u: AuthUser, id: string, body: unknown) {
    const b = parse(z.object({ name: z.string().trim().min(1).max(120) }).strict(), body);
    const c = await this.row(u, id);
    const [n] = await this.ctx.db.update(clips).set({ name: b.name }).where(eq(clips.id, c.id)).returning();
    this.emit(n!);
    return this.view(n!);
  }
  /** Deletes the clip, its file and poster; refused while a queued or running job uses it. */
  async remove(u: AuthUser, id: string) {
    const c = await this.row(u, id);
    const [busy] = await this.ctx.db.select({ id: jobs.id }).from(jobs).where(and(eq(jobs.studioId, u.studioId), inArray(jobs.state, ['queued', 'running']),
      sql`${jobs.request}->>'clipId' = ${c.id}`)).limit(1);
    if (busy) throw new ApiError(409, 'import_in_use', 'A video being made uses this clip · delete it when that finishes');
    await this.ctx.db.delete(clips).where(eq(clips.id, c.id));
    const m = metaOf(c);
    for (const key of [c.storageKey, m.posterKey]) if (key) {
      await this.ctx.storage.delete(key).catch(() => undefined);
      await this.ctx.db.delete(uploads).where(and(eq(uploads.storageKey, key), eq(uploads.studioId, c.studioId))).catch(() => undefined);
    }
    void this.ctx.hub.emit(c.studioId, viewer => (viewer.userId === c.createdBy || viewer.role === 'owner' ? { type: 'clip', op: 'delete', id: c.id } : null));
  }

  // ------------------------------------------------------------------ create
  async create(u: AuthUser, body: unknown) {
    const b = parse(CreateBody, body);
    if (!('uploadId' in b)) return this.fromServerFetch(u, { url: 'url' in b ? b.url : b.sourceUrl, name: b.name });
    const [up] = await this.ctx.db.select().from(uploads).where(and(eq(uploads.id, b.uploadId), eq(uploads.studioId, u.studioId)));
    if (!up) throw notFound('Upload');
    if (!up.contentType.startsWith('video/')) throw badRequest('uploadId: must be a video');
    // The same upload again (a retry): the import it already made.
    const [prev] = await this.ctx.db.select().from(clips).where(and(eq(clips.studioId, u.studioId), eq(clips.storageKey, up.storageKey)));
    if (prev) {
      if (isImport(prev) && prev.createdBy === u.id) return this.view(prev);
      throw new ApiError(409, 'upload_used', 'This upload is already in the Library');
    }
    const head = await this.ctx.storage.head(up.storageKey);
    if (!head) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it first');
    let link: { url: string; platform: AnyPlatform } | null = null;
    if (b.sourceUrl) {
      link = linkFor(b.sourceUrl, { strict: await this.rx.strictLinks(u.studioId) });
      const hit = await this.cached(u, link.url);
      if (hit) { await this.dropUpload(up); return this.view(hit, { cached: true }); }
    }
    if (head.size > this.maxBytes) throw this.tooBig(head.size);
    return this.withLocal(up.storageKey, file => this.store(u, { file, key: up.storageKey, uploadId: up.id, bytes: head.size, link, name: b.name, via: 'device' }));
  }

  /** The server fetches the link itself (often blocked by the platforms; the apps' device download comes first). */
  private async fromServerFetch(u: AuthUser, b: { url: string; name?: string }) {
    if (!this.ctx.config.RECREATE_LINKS) throw linkError('link_blocked', FALLBACK);
    const rx = this.rx, strict = await rx.strictLinks(u.studioId);
    const n = linkFor(b.url, { strict });
    const hit = await this.cached(u, n.url);
    if (hit) return this.view(hit, { cached: true });
    if (n.platform === 'other') await rx.publicHost(n.url);
    const info = await rx.serial(() => rx.links.info(n.url)).catch(e => { rx.logLinkFailure(n.platform, 'info', e); throw e; });
    let url = n.url;
    try { if (info.webpage_url) url = linkFor(info.webpage_url, { strict }).url; } catch { /* keep the pasted form */ }
    if (url !== n.url) { const again = await this.cached(u, url); if (again) return this.view(again, { cached: true }); }
    checkInfo(info, { maxSec: IMPORT_MAX_SEC, maxBytes: this.maxBytes, what: 'Imports' });
    if (n.platform === 'tiktok' && strict) {
      const html = await rx.serial(() => rx.fetchPage(url)).catch(e => { throw e instanceof ApiError ? e : linkError('link_blocked', FALLBACK); });
      if (tiktokDownloadsOff(html) === true) throw linkError('link_downloads_off', 'The creator turned downloads off for this video, so MUSE won’t fetch it. Use another video, or ask the creator');
    }
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'import-'));
    try {
      const infoFile = path.join(dir, 'info.json');
      fs.writeFileSync(infoFile, JSON.stringify(info));
      const file = await rx.serial(() => rx.links.download(infoFile, dir, { maxBytes: this.maxBytes, ffmpeg: this.ctx.config.FFMPEG_PATH }))
        .catch(e => { rx.logLinkFailure(n.platform, 'download', e); throw e; });
      const size = fs.statSync(file).size;
      if (size > this.maxBytes) throw this.tooBig(size);
      const id = uid('up'), key = `c/${id}.mp4`;
      // Probed before it is stored, so a file that fails the checks leaves nothing behind.
      await this.probeChecked(file);
      await this.ctx.storage.putStream(key, fs.createReadStream(file), 'video/mp4', size);
      await this.ctx.db.insert(uploads).values({ id, studioId: u.studioId, kind: 'clip', storageKey: key, contentType: 'video/mp4', bytes: size, state: 'ready', createdBy: u.id, createdAt: Date.now() });
      const name = b.name || (info.title ?? '').trim().slice(0, 80) || undefined;
      return await this.store(u, { file, key, uploadId: id, bytes: size, link: { url, platform: n.platform }, name, via: 'server' });
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  }

  private tooBig(bytes: number) {
    return linkError('link_too_big', `This video is too big (${Math.round(bytes / 1048576)} MB; the limit is ${this.ctx.config.IMPORT_MAX_MB} MB)`);
  }
  private async probeChecked(file: string) {
    const info = await probe(this.ctx.config.FFPROBE_PATH, file).catch(() => null);
    if (!info?.width) throw badRequest('That file isn’t a video MUSE can read');
    if (info.duration > IMPORT_MAX_SEC + 0.5) throw new ApiError(400, 'too_long', `Imports can be up to ${IMPORT_MAX_SEC} s (this one is ${Math.round(info.duration)} s)`);
    return info;
  }

  /** Probes, checks, makes the poster and the Library clip. */
  private async store(u: AuthUser, o: { file: string; key: string; uploadId: string; bytes: number; link: { url: string; platform: AnyPlatform } | null; name?: string; via: 'device' | 'server' }) {
    const info = await this.probeChecked(o.file);
    await this.ctx.db.update(uploads).set({ state: 'ready', bytes: o.bytes }).where(eq(uploads.id, o.uploadId));
    const id = uid('clip');
    let posterKey: string | null = null;
    const jpg = path.join(os.tmpdir(), `${id}_poster.jpg`);
    try {
      await thumbnail(this.ctx.config.FFMPEG_PATH, o.file, jpg, Math.min(POSTER_AT, Math.max(0, info.duration / 2)));
      posterKey = `c/${id}_poster.jpg`;
      await putObject(this.ctx, { key: posterKey, body: fs.readFileSync(jpg), studioId: u.studioId, kind: 'image', userId: u.id, contentType: 'image/jpeg' });
    } catch (e) {
      posterKey = null;
      this.ctx.log?.warn({ clip: id, err: String((e as Error)?.message ?? e).slice(0, 200) }, 'import poster failed');
    } finally { fs.rmSync(jpg, { force: true }); }
    const fps = Math.round((info.fps || 30) * 1000) / 1000, durationSec = Math.round(info.duration * 1000) / 1000;
    const meta: ImportMeta & Record<string, unknown> = { source: 'import', sourceUrl: o.link?.url ?? null, platform: o.link?.platform ?? null, bytes: o.bytes, posterKey,
      uploadId: o.uploadId, userId: u.id, via: o.via, name: o.name || 'Imported video', durationSec, width: info.width, height: info.height, fps, people: null, watermark: null };
    const [c] = await this.ctx.db.insert(clips).values({ id, studioId: u.studioId, name: o.name || defaultName(o.link?.platform), durationSec, width: info.width, height: info.height, fps,
      meta, checks: P.clipChecks({ durationSec, width: info.width, height: info.height, fps, people: null, watermark: null }), storageKey: o.key, createdBy: u.id, createdAt: Date.now() }).returning();
    this.emit(c!);
    // Whether the performer talks (free, in the background); a second clip event carries `audio`.
    void analyzeClip(this.ctx, id, row => this.emit(row));
    return this.view(c!);
  }

  /** A device upload that turned out to be a duplicate (the member's import from the same link is reused). */
  private async dropUpload(up: typeof uploads.$inferSelect) {
    await this.ctx.storage.delete(up.storageKey).catch(() => undefined);
    await this.ctx.db.delete(uploads).where(eq(uploads.id, up.id)).catch(() => undefined);
  }
  private async withLocal<T>(key: string, fn: (file: string) => Promise<T>): Promise<T> {
    const obj = await this.ctx.storage.get(key);
    if (!obj) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it first');
    const file = path.join(os.tmpdir(), `${uid('imp')}${path.extname(key) || '.mp4'}`);
    try {
      await pipeline(obj.body as NodeJS.ReadableStream, fs.createWriteStream(file));
      return await fn(file);
    } finally { fs.rmSync(file, { force: true }); }
  }
}

const defaultName = (p?: AnyPlatform | null) => p === 'tiktok' ? 'TikTok video' : p === 'instagram' ? 'Instagram video' : p === 'youtube' ? 'YouTube video' : 'Imported video';

const services = new WeakMap<Ctx, Imports>();
export const importsOf = (ctx: Ctx) => { let s = services.get(ctx); if (!s) { s = new Imports(ctx); services.set(ctx, s); } return s; };
