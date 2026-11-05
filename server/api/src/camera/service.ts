// Camera sessions (plans/api.md "MCP & camera sessions"): create, read, update, cast, camera path and blocking, guide
// assets through presigned uploads, the shared transcript and Shot drafts. Used by REST, the MCP server and the chat.
import crypto from 'node:crypto';
import { and, asc, desc, eq, inArray, lt } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { models, uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import type { BlenderRelayHub } from './relay.js';
import { cameraAssets, cameraMessages, cameraSessions, type Blocking, type CameraAssetKind, type CameraPath, type CastMember } from './schema.js';
import { createShotDraft, DEFAULT_TARGET } from './shots.js';
import { ASSET_RULES, CreateSession, extOf, NewAsset, parse, PatchSession, SetPath, ShotDraftIn } from './validate.js';

type SessionRow = typeof cameraSessions.$inferSelect;
type AssetRow = typeof cameraAssets.$inferSelect;
type MessageRow = typeof cameraMessages.$inferSelect;
export type Source = 'app' | 'mcp' | 'relay' | 'chat';

const GUIDE_KEYS: Partial<Record<CameraAssetKind, string>> = {
  greybox: 'greybox', depth: 'depth', pose: 'pose', tracks: 'tracks', keyframe_start: 'keyframeStart', keyframe_mid: 'keyframeMid', keyframe_end: 'keyframeEnd',
};
export const DEFAULT_HEIGHT_M = 1.68;

export const messageView = (m: MessageRow) => compact({ id: m.id, role: m.role, source: m.source, text: m.text, tool: m.tool ?? undefined, createdAt: m.createdAt });

export class CameraService {
  constructor(private ctx: Ctx, private relay: BlenderRelayHub) {}
  private get db() { return this.ctx.db; }

  // ------------------------------------------------------------------ reads
  async row(u: AuthUser, id: string): Promise<SessionRow> {
    const [s] = await this.db.select().from(cameraSessions).where(and(eq(cameraSessions.id, id), eq(cameraSessions.studioId, u.studioId)));
    if (!s) throw notFound('Camera session');
    return s;
  }

  private async assets(sessionIds: string[]) {
    if (!sessionIds.length) return [] as AssetRow[];
    return this.db.select().from(cameraAssets).where(inArray(cameraAssets.sessionId, sessionIds)).orderBy(asc(cameraAssets.createdAt));
  }

  async assetView(a: AssetRow) {
    return compact({ id: a.id, kind: a.kind, label: a.label ?? undefined, state: a.state, contentType: a.contentType, bytes: a.bytes ?? undefined, source: a.source,
      url: a.state === 'ready' ? await this.ctx.storage.presignGet(a.storageKey, 3600) : undefined, createdAt: a.createdAt });
  }

  /** The directed part of the CameraSpec: the newest ready asset of each guide kind, the trajectories and the camera keys. */
  cameraSpec(s: SessionRow, assets: AssetRow[]) {
    const guideAssets: Record<string, string> = {};
    const trajectories: Record<string, string> = {};
    for (const a of assets) {
      if (a.state !== 'ready') continue;
      const g = GUIDE_KEYS[a.kind];
      if (g) guideAssets[g] = a.id;
      if (a.kind === 'camera_json') trajectories.camera = a.id;
      if (a.kind === 'characters_json') trajectories.characters = a.id;
    }
    return { mode: 'directed', ...(Object.keys(s.presets).length ? { presets: s.presets } : {}),
      directed: { cameraSessionId: s.id, guideAssets, trajectories, keyframes: s.cameraPath?.keyframes ?? [] } };
  }

  private async names(u: AuthUser, cast: CastMember[]) {
    if (!cast.length) return new Map<string, string>();
    const rows = await this.db.select({ id: models.id, name: models.name }).from(models).where(and(eq(models.studioId, u.studioId), inArray(models.id, cast.map(c => c.modelId))));
    return new Map(rows.map(r => [r.id, r.name]));
  }

  async view(u: AuthUser, s: SessionRow, opts: { messages?: boolean; assets?: AssetRow[] } = {}) {
    const assets = opts.assets ?? await this.assets([s.id]);
    const names = await this.names(u, s.characters);
    const v: Record<string, unknown> = compact({
      id: s.id, title: s.title, brief: s.brief, status: s.status, aspect: s.aspect, fps: s.fps, durationSec: s.durationSec, targetModel: s.targetModel ?? undefined,
      presets: s.presets, characters: s.characters.map(c => compact({ modelId: c.modelId, name: names.get(c.modelId) ?? 'Unknown model', role: c.role, heightM: c.heightM ?? DEFAULT_HEIGHT_M })),
      cameraPath: s.cameraPath ?? undefined, blocking: s.blocking ?? undefined, assets: await Promise.all(assets.map(a => this.assetView(a))),
      shotDraft: s.shotDraft ?? undefined, camera: this.cameraSpec(s, assets), revision: s.revision, relay: this.relay.status(s.ownerId),
      createdAt: s.createdAt, updatedAt: s.updatedAt,
    });
    if (opts.messages) v.messages = (await this.messages(u, s.id, { limit: 50 }));
    return v;
  }

  async get(u: AuthUser, id: string) { return this.view(u, await this.row(u, id), { messages: true }); }

  async list(u: AuthUser, o: { status?: string; limit?: number } = {}) {
    const where = o.status ? and(eq(cameraSessions.studioId, u.studioId), eq(cameraSessions.status, o.status as SessionRow['status'])) : eq(cameraSessions.studioId, u.studioId);
    const rows = await this.db.select().from(cameraSessions).where(where).orderBy(desc(cameraSessions.updatedAt)).limit(Math.min(Math.max(o.limit ?? 50, 1), 200));
    const all = await this.assets(rows.map(r => r.id));
    return Promise.all(rows.map(r => this.view(u, r, { assets: all.filter(a => a.sessionId === r.id) })));
  }

  async messages(u: AuthUser, id: string, o: { before?: number; limit?: number } = {}) {
    await this.row(u, id);
    const limit = Math.min(Math.max(o.limit ?? 100, 1), 200);
    const where = o.before ? and(eq(cameraMessages.sessionId, id), lt(cameraMessages.createdAt, o.before)) : eq(cameraMessages.sessionId, id);
    const rows = await this.db.select().from(cameraMessages).where(where).orderBy(desc(cameraMessages.createdAt)).limit(limit);
    return rows.reverse().map(messageView);
  }

  // ------------------------------------------------------------------ writes
  private async checkCast(u: AuthUser, cast: CastMember[]) {
    const ids = [...new Set(cast.map(c => c.modelId))];
    if (ids.length !== cast.length) throw badRequest('characters: each model only once');
    if (!ids.length) return;
    const rows = await this.db.select({ id: models.id, archivedAt: models.archivedAt }).from(models).where(and(eq(models.studioId, u.studioId), inArray(models.id, ids)));
    for (const id of ids) {
      const m = rows.find(r => r.id === id);
      if (!m) throw badRequest(`characters: no model ${id}`);
      if (m.archivedAt) throw new ApiError(409, 'model_archived', 'That model is archived · restore her in Settings → Archived models');
    }
  }

  private emit(u: AuthUser, v: Record<string, unknown>) {
    const { messages: _m, ...session } = v;
    void this.ctx.hub.emitTo(u.id, { type: 'camera', op: 'upsert', session });
  }

  /** Saves a change (+1 revision) and tells the owner's devices. */
  private async save(u: AuthUser, s: SessionRow, patch: Partial<SessionRow>) {
    const [n] = await this.db.update(cameraSessions).set({ ...patch, revision: s.revision + 1, updatedAt: Date.now() })
      .where(and(eq(cameraSessions.id, s.id), eq(cameraSessions.revision, s.revision))).returning();
    if (!n) throw new ApiError(409, 'stale_revision', 'This camera session changed meanwhile · reload it and try again');
    const v = await this.view(u, n);
    this.emit(u, v);
    return v;
  }

  async create(u: AuthUser, body: unknown) {
    const b = parse(CreateSession, body);
    const cast = b.characters ?? [];
    await this.checkCast(u, cast);
    const now = Date.now();
    const [s] = await this.db.insert(cameraSessions).values({
      id: `cs_${crypto.randomBytes(12).toString('hex')}`, studioId: u.studioId, ownerId: u.id,
      title: b.title || 'Untitled shot', brief: b.brief ?? '', status: 'drafting', aspect: b.aspect ?? '9:16', fps: b.fps ?? 24, durationSec: b.durationSec ?? 6,
      targetModel: b.targetModel ?? null, presets: b.presets ?? {}, characters: cast, createdAt: now, updatedAt: now,
    }).returning();
    const v = await this.view(u, s!);
    this.emit(u, v);
    return v;
  }

  async patch(u: AuthUser, id: string, body: unknown) {
    const b = parse(PatchSession, body);
    const s = await this.row(u, id);
    if (b.revision !== undefined && b.revision !== s.revision) throw new ApiError(409, 'stale_revision', 'This camera session changed meanwhile · reload it and try again');
    const { revision: _r, characters, ...rest } = b;
    const patch: Partial<SessionRow> = { ...rest };
    if (characters) {
      await this.checkCast(u, characters);
      patch.characters = characters;
      // Blocking for characters no longer in the cast goes.
      if (s.blocking) patch.blocking = { characters: s.blocking.characters.filter(c => characters.some(k => k.modelId === c.modelId)) };
    }
    if (rest.title !== undefined && !rest.title) patch.title = 'Untitled shot';
    return this.save(u, s, patch);
  }

  async remove(u: AuthUser, id: string) {
    const s = await this.row(u, id);
    const assets = await this.assets([s.id]);
    await this.db.delete(cameraSessions).where(eq(cameraSessions.id, s.id));
    for (const a of assets) {
      await this.db.delete(uploads).where(eq(uploads.storageKey, a.storageKey));
      await this.ctx.storage.delete(a.storageKey).catch(() => {});
    }
    void this.ctx.hub.emitTo(u.id, { type: 'camera', op: 'delete', id: s.id });
  }

  async setPath(u: AuthUser, id: string, body: unknown) {
    const b = parse(SetPath, body);
    if (!b.camera && !b.characters) throw badRequest('Send camera, characters or both');
    const s = await this.row(u, id);
    const patch: Partial<SessionRow> = {};
    if (b.camera) {
      const late = b.camera.keyframes.find(k => k.t > s.durationSec + 0.01);
      if (late) throw badRequest(`camera.keyframes: t ${late.t} is after the clip's end (${s.durationSec} s)`);
      patch.cameraPath = b.camera as CameraPath;
    }
    if (b.characters) {
      for (const c of b.characters) {
        if (!s.characters.some(k => k.modelId === c.modelId)) throw badRequest(`characters: ${c.modelId} is not in the cast · add her first`);
        if (c.keyframes.some(k => k.t > s.durationSec + 0.01)) throw badRequest(`characters: ${c.modelId} has keys after the clip's end (${s.durationSec} s)`);
      }
      // Characters not named keep their blocking.
      const kept = (s.blocking?.characters ?? []).filter(c => !b.characters!.some(n => n.modelId === c.modelId));
      patch.blocking = { characters: [...kept, ...b.characters] } as Blocking;
    }
    if (s.status === 'drafting') patch.status = 'blocking';
    return this.save(u, s, patch);
  }

  async newAsset(u: AuthUser, id: string, body: unknown, source: Source) {
    const b = parse(NewAsset, body);
    const rule = ASSET_RULES[b.kind];
    if (!rule.types.includes(b.contentType)) throw badRequest(`contentType: ${b.kind} takes ${rule.types.join(', ')}`);
    if (b.bytes && b.bytes > rule.maxBytes) throw badRequest(`bytes: ${b.kind} files are at most ${Math.round(rule.maxBytes / 1024 ** 2)} MB`);
    const s = await this.row(u, id);
    const assetId = uid('ca');
    const key = `cam/${s.id}/${assetId}.${extOf(b.contentType)}`;
    const ttl = 3600;
    const signed = await this.ctx.storage.presignPut(key, b.contentType, ttl);
    const [a] = await this.db.insert(cameraAssets).values({ id: assetId, sessionId: s.id, studioId: u.studioId, kind: b.kind, label: b.label ?? null, storageKey: key,
      contentType: b.contentType, bytes: b.bytes ?? null, state: 'pending', source, createdBy: u.id, createdAt: Date.now() }).returning();
    return { asset: await this.assetView(a!), upload: { method: 'PUT', url: signed.url, headers: signed.headers, expiresAt: Date.now() + ttl * 1000 } };
  }

  private async assetRow(u: AuthUser, sessionId: string, assetId: string) {
    const [a] = await this.db.select().from(cameraAssets).where(and(eq(cameraAssets.id, assetId), eq(cameraAssets.sessionId, sessionId), eq(cameraAssets.studioId, u.studioId)));
    if (!a) throw notFound('Asset');
    return a;
  }

  async confirmAsset(u: AuthUser, sessionId: string, assetId: string) {
    const s = await this.row(u, sessionId);
    const a = await this.assetRow(u, s.id, assetId);
    if (a.state === 'ready') return this.assetView(a);
    const head = await this.ctx.storage.head(a.storageKey);
    if (!head) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it to the URL first');
    const rule = ASSET_RULES[a.kind];
    if (head.size > rule.maxBytes) {
      await this.ctx.storage.delete(a.storageKey).catch(() => {});
      throw badRequest(`${a.kind} files are at most ${Math.round(rule.maxBytes / 1024 ** 2)} MB`);
    }
    if (a.contentType === 'application/json') {
      const obj = await this.ctx.storage.get(a.storageKey);
      const chunks: Buffer[] = [];
      for await (const c of obj!.body) chunks.push(c as Buffer);
      try { JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw badRequest(`${a.kind} is not valid JSON`); }
    }
    const [n] = await this.db.update(cameraAssets).set({ state: 'ready', bytes: head.size }).where(eq(cameraAssets.id, a.id)).returning();
    // Guide videos and stills are also recorded as studio uploads: the suite's Shot API only takes references it knows.
    if (/^(video|image)\//.test(a.contentType)) {
      await this.db.insert(uploads).values({ id: uid('up'), studioId: u.studioId, kind: 'output', storageKey: a.storageKey, contentType: a.contentType, bytes: head.size,
        state: 'ready', createdBy: u.id, createdAt: Date.now() });
    }
    const view = await this.assetView(n!);
    void this.ctx.hub.emitTo(u.id, { type: 'camera', op: 'asset', sessionId: s.id, asset: view });
    // A greybox guide makes the session ready to generate.
    const patch: Partial<SessionRow> = a.kind === 'greybox' && ['drafting', 'blocking', 'rendering'].includes(s.status) ? { status: 'ready' } : {};
    await this.save(u, await this.row(u, s.id), patch);
    return view;
  }

  async removeAsset(u: AuthUser, sessionId: string, assetId: string) {
    const s = await this.row(u, sessionId);
    const a = await this.assetRow(u, s.id, assetId);
    await this.db.delete(cameraAssets).where(eq(cameraAssets.id, a.id));
    await this.db.delete(uploads).where(eq(uploads.storageKey, a.storageKey));
    await this.ctx.storage.delete(a.storageKey).catch(() => {});
    await this.save(u, s, {});
  }

  /** Bytes of a ready image asset (the chat shows Blender screenshots to Claude). */
  async assetBytes(u: AuthUser, sessionId: string, assetId: string, maxBytes = 5 * 1024 ** 2) {
    const a = await this.assetRow(u, sessionId, assetId);
    if (a.state !== 'ready' || (a.bytes ?? 0) > maxBytes) return null;
    const obj = await this.ctx.storage.get(a.storageKey);
    if (!obj) return null;
    const chunks: Buffer[] = [];
    for await (const c of obj.body) chunks.push(c as Buffer);
    return { contentType: a.contentType, kind: a.kind, data: Buffer.concat(chunks) };
  }

  async postMessage(u: AuthUser, sessionId: string, m: { role: MessageRow['role']; source: MessageRow['source']; text: string; tool?: MessageRow['tool'] }) {
    const text = m.text.trim().slice(0, 20_000);
    if (!text && !m.tool) throw badRequest('text: write something');
    const [row] = await this.db.insert(cameraMessages).values({ id: uid('cm'), sessionId, role: m.role, source: m.source, text, tool: m.tool ?? null, createdAt: Date.now() }).returning();
    const message = messageView(row!);
    void this.ctx.hub.emitTo(u.id, { type: 'camera', op: 'message', sessionId, message });
    return message;
  }

  async note(u: AuthUser, sessionId: string, body: unknown, source: 'app' | 'mcp') {
    const text = typeof (body as { text?: unknown })?.text === 'string' ? (body as { text: string }).text : '';
    await this.row(u, sessionId);
    return this.postMessage(u, sessionId, { role: source === 'app' ? 'user' : 'assistant', source, text });
  }

  /** A Shot draft with a cost estimate. Never spends. */
  async shotDraft(u: AuthUser, id: string, body: unknown) {
    const b = parse(ShotDraftIn, body);
    const s = await this.row(u, id);
    const assets = await this.assets([s.id]);
    const durationSec = b.durationSec ?? s.durationSec;
    const prompt = (b.prompt ?? s.brief ?? '').trim() || s.title;
    const newest = (kind: CameraAssetKind) => assets.filter(x => x.kind === kind && x.state === 'ready').at(-1);
    const still = async (kind: CameraAssetKind) => { const x = newest(kind); return x ? this.ctx.storage.presignGet(x.storageKey, 24 * 3600) : undefined; };
    const draft = await createShotDraft(this.ctx, u, {
      prompt, targetModel: b.targetModel ?? s.targetModel ?? DEFAULT_TARGET, durationSec, aspect: s.aspect, camera: this.cameraSpec(s, assets),
      characters: s.characters.map(c => ({ modelId: c.modelId, role: c.role })), cameraSessionId: s.id,
      guide: { videoKey: newest('greybox')?.storageKey, seconds: s.durationSec, start: await still('keyframe_start'), middle: await still('keyframe_mid'), end: await still('keyframe_end') },
    });
    await this.save(u, s, { shotDraft: draft });
    return draft;
  }

  /** The chat's Claude conversation (stored append-only). */
  async history(u: AuthUser, id: string) { return (await this.row(u, id)).directorHistory; }
  async setHistory(id: string, history: unknown[]) {
    await this.db.update(cameraSessions).set({ directorHistory: history }).where(eq(cameraSessions.id, id));
  }
}
