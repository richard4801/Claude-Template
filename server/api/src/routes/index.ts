// App-facing routes: plans/api.md, plus invites, wallets/members, settings and presigned uploads.
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { and, desc, eq, inArray, isNull, ne, sql } from 'drizzle-orm';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { accounts, clips, invites, jobs, ledger, loras, models, outfits, posts, sessions, studioSettings, takes, uploads, users, wallets, type ImageRef, type SheetSlot } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, dayStart, monthStart, uid } from '../lib/util.js';
import { whoOf } from '../money/money.js';
import * as P from '../pricing.js';
import { characterSheetShot, outfitSet, photoshoot, sheetAngle, loraToken, OUTFIT_ANGLES } from '../prompt/engine.js';
import { createInvite, revokeSession, signin, signup } from '../auth/auth.js';
import { accountView, PLATFORMS, platformOf } from '../services/posts.js';
import { takeView } from '../services/jobs.js';
import { ASSET_DIR, ASSET_KEYS, PROVIDERS } from '../images/service.js';
import { LocalStorage, contentTypeFor } from '../storage/index.js';
import { objectInfo, putObject } from '../storage/objects.js';
import { seedDev, SLOT_SAMPLE } from '../seed.js';
import { buildTemplatePrompt, randomImageSeed, randomSeed } from '../templates/prompt.js';
import { layersFromPrompt } from '../templates/service.js';
import { dbStatus } from '../db/pg.js';
import { inviteShareText, registerReleaseRoutes } from './releases.js';

/** SSE comment interval: well under any hosting proxy's idle timeout (Koyeb, Railway, Cloudflare: 60-100 s). */
export const SSE_KEEPALIVE_MS = 15_000;

const SLOT_KEYS = ['face', 'profile', 'front', 'tq', 'side', 'back'];
const parse = <T>(schema: z.ZodType<T>, body: unknown): T => {
  const r = schema.safeParse(body ?? {});
  if (!r.success) { const i = r.error.issues[0]!; throw badRequest(`${i.path.join('.') || 'body'}: ${i.message}`); }
  return r.data;
};
const jsonOr400 = (s: string) => { try { return JSON.parse(s); } catch { throw new ApiError(400, 'bad_json', 'meta is not valid JSON'); } };
const ImageRefSchema = z.object({ asset: z.string().max(100).optional(), url: z.string().max(2000).optional() });

export function modelView(m: typeof models.$inferSelect) {
  return compact({ id: m.id, name: m.name, age: m.age, niche: m.niche, look: m.look, neverAdd: m.neverAdd, slots: m.slots, outfitIds: m.outfitIds, personality: m.personality, notes: m.notes });
}
export const outfitView = (o: typeof outfits.$inferSelect) =>
  ({ id: o.id, modelId: o.modelId, name: o.name, mode: o.mode, description: o.description, angles: o.angles, state: o.state, prompt: o.prompt });
const clipView = (c: typeof clips.$inferSelect) => compact({ id: c.id, name: c.name, durationSec: c.durationSec, width: c.width, height: c.height, fps: c.fps, checks: c.checks });

export async function registerRoutes(app: FastifyInstance, ctx: Ctx) {
  const db = ctx.db;
  const pub = ctx.config.PUBLIC_URL ?? '';
  const uploadUrl = (key: string) => `${pub}/uploads/${key}`;
  const emitModel = (m: typeof models.$inferSelect) => ctx.hub.emit(m.studioId, { type: 'model', model: modelView(m) });
  const emitOutfit = (o: typeof outfits.$inferSelect) => ctx.hub.emit(o.studioId, { type: 'outfit', outfit: outfitView(o) });

  async function model(u: AuthUser, id: string) {
    const [m] = await db.select().from(models).where(and(eq(models.id, id), eq(models.studioId, u.studioId)));
    if (!m) throw notFound('Model');
    return m;
  }
  async function activeLora(m: typeof models.$inferSelect) {
    const [l] = await db.select().from(loras).where(eq(loras.modelId, m.id));
    return l && l.version > 0 && l.use ? loraToken(m.name, l.version) : null;
  }
  const identityOf = async (m: typeof models.$inferSelect) => ({
    name: m.name, look: m.look || `${m.age}-year-old woman`, neverAdd: m.neverAdd,
    referenceCount: Math.max(1, m.slots.filter(s => s.image && !s.busy).length), lora: await activeLora(m),
  });

  // ------------------------------------------------------------------ health
  // The host's health check (Koyeb, Railway) calls this every few seconds. It must not touch the database: a query every
  // few seconds would keep a serverless database (Neon) awake around the clock and use up its free compute hours. It
  // reports the last known database state instead. `/health?db=1` really queries (and wakes) the database.
  app.get('/health', { config: { public: true } }, async (req, reply) => {
    const deep = ['1', 'true'].includes(String((req.query as any)?.db ?? ''));
    let db: boolean | 'unchecked' = 'unchecked';
    if (deep) {
      try { await ctx.db.execute(sql`select 1`); db = true; } catch { db = false; }
    }
    const lastOkAt = dbStatus.lastOkAt || null;
    const body = { ok: db !== false, speed: ctx.config.SPEED, db, dbLastOkAt: lastOkAt, gpu: ctx.gpu.mode, storage: ctx.storage.kind,
      imageEngine: ctx.images.defaultSelection().provider, videoEngine: ctx.config.videoEngineDefault, version: '0.1.0',
      build: ctx.boot.build, startedAt: ctx.boot.startedAt, migrations: ctx.boot.migrations, starters: ctx.boot.starters };
    reply.header('cache-control', 'no-store');
    return db === false ? reply.status(503).send(body) : body;
  });

  // ------------------------------------------------------------------ auth
  const authLimit = { rateLimit: { max: ctx.config.AUTH_RATE_PER_MIN, timeWindow: '1 minute' }, public: true };
  app.post('/v1/auth/signin', { config: authLimit }, async req => signin(ctx, (req.body ?? {}) as any));
  app.post('/v1/auth/signup', { config: authLimit }, async req => signup(ctx, (req.body ?? {}) as any));
  app.post('/v1/auth/signout', async (req, reply) => { if (req.user.sessionId) await revokeSession(ctx, req.user.sessionId); return reply.status(204).send(); });
  app.get('/v1/auth/me', async req => ({ id: req.user.id, email: req.user.email, studioName: req.user.studioName, role: req.user.role }));

  // ------------------------------------------------------------------ invites (owner)
  app.post('/v1/invites', { config: { owner: true } }, async req => {
    const b = parse(z.object({ email: z.string().email().optional(), role: z.enum(['owner', 'member']).optional(), days: z.number().int().min(1).max(90).optional() }), req.body);
    const inv = await createInvite(ctx, { studioId: req.user.studioId, email: b.email, role: b.role ?? 'member', createdBy: req.user.id, days: b.days });
    // shareText: the message to send with the code (the download page, the code, the email).
    return { ...inv, shareText: inviteShareText(ctx.publicBase(), inv.code, inv.email, b.days ?? 14) };
  });
  app.get('/v1/invites', { config: { owner: true } }, async req =>
    (await db.select().from(invites).where(eq(invites.studioId, req.user.studioId)).orderBy(desc(invites.createdAt)))
      .map(i => compact({ id: i.id, email: i.email, role: i.role, createdAt: i.createdAt, expiresAt: i.expiresAt, usedAt: i.usedAt })));

  // ------------------------------------------------------------------ app downloads (/get, /download/*, PUT /v1/releases/*)
  await registerReleaseRoutes(app, ctx);

  // ------------------------------------------------------------------ models and character sheets
  app.get('/v1/models', async req => (await db.select().from(models).where(eq(models.studioId, req.user.studioId)).orderBy(models.createdAt)).map(modelView));
  app.post('/v1/models', async req => {
    const b = parse(z.object({ name: z.string().max(80).optional(), age: z.number().optional(), niche: z.string().max(80).optional() }).passthrough(), req.body);
    const [m] = await db.insert(models).values({
      id: uid('m'), studioId: req.user.studioId, name: b.name?.trim() || 'New model', age: Math.min(70, Math.max(18, Math.round(b.age ?? 27))), niche: b.niche ?? 'Beauty',
      look: '', neverAdd: [], slots: SLOT_KEYS.map(k => ({ key: k, image: null, source: 'upload', busy: false })), outfitIds: [], createdBy: req.user.id, createdAt: Date.now(),
    }).returning();
    return modelView(m!);
  });
  app.patch<{ Params: { id: string } }>('/v1/models/:id', async req => {
    const b = parse(z.object({ name: z.string().max(80).optional(), niche: z.string().max(80).optional(), personality: z.string().max(2000).optional(),
      notes: z.string().max(4000).optional(), neverAdd: z.array(z.string().max(80)).max(50).optional(), look: z.string().max(1000).optional() }).passthrough(), req.body);
    const m = await model(req.user, req.params.id);
    if (typeof b.name === 'string' && !b.name.trim()) throw badRequest('Give her a name');
    const patch: Partial<typeof models.$inferInsert> = {};
    for (const k of ['name', 'niche', 'personality', 'notes', 'look'] as const) if (typeof b[k] === 'string') patch[k] = b[k];
    if (b.neverAdd) patch.neverAdd = b.neverAdd.map(x => x.trim()).filter(Boolean);
    const [u] = Object.keys(patch).length ? await db.update(models).set(patch).where(eq(models.id, m.id)).returning() : [m];
    emitModel(u!);
    return modelView(u!);
  });
  app.delete<{ Params: { id: string } }>('/v1/models/:id', async (req, reply) => {
    const m = await model(req.user, req.params.id);
    // Her outfits, LoRAs and training set, linked accounts and posts that haven't gone out go with her.
    const running = await db.select().from(jobs).where(and(eq(jobs.modelId, m.id), eq(jobs.state, 'running')));
    for (const j of running) await ctx.jobs.cancel(j, 'Model deleted');
    await db.delete(outfits).where(eq(outfits.modelId, m.id));
    await db.delete(loras).where(eq(loras.modelId, m.id));
    await db.delete(accounts).where(eq(accounts.modelId, m.id));
    await db.delete(posts).where(and(eq(posts.modelId, m.id), ne(posts.state, 'posted')));
    await db.delete(models).where(eq(models.id, m.id));
    return reply.status(204).send();
  });
  app.put<{ Params: { id: string; slot: string } }>('/v1/models/:id/slots/:slot', async req => {
    const b = parse(z.object({ image: ImageRefSchema.nullable().optional(), source: z.enum(['upload', 'generated']).optional() }), req.body);
    const m = await model(req.user, req.params.id);
    if (!SLOT_KEYS.includes(req.params.slot)) throw notFound('Slot');
    const slots = m.slots.map(s => (s.key === req.params.slot ? { ...s, image: (b.image as ImageRef | null) ?? null, source: b.source ?? 'upload', busy: false } : s));
    const [u] = await db.update(models).set({ slots }).where(eq(models.id, m.id)).returning();
    return modelView(u!);
  });
  app.post<{ Params: { id: string } }>('/v1/models/:id/fill-angles', async req => {
    const m = await model(req.user, req.params.id);
    const missing = m.slots.filter(s => !s.image && !s.busy);
    const cost = P.fillAnglesCost(missing.length);
    await ctx.money.charge(whoOf(req.user), cost, `fill ${missing.length} angles`, m.id);
    const slots = m.slots.map(s => (missing.includes(s) ? { ...s, busy: true } : s));
    const [u] = await db.update(models).set({ slots }).where(eq(models.id, m.id)).returning();
    const user = req.user;
    void (async () => {
      const identity = await identityOf(u!);
      const refs = m.slots.map(s => s.image);
      const filled: Record<string, ImageRef | null> = {};
      let failed = 0;
      for (const s of missing) {
        try {
          const r = await ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'sheet', refId: m.id, refs,
            req: { prompt: characterSheetShot(identity, sheetAngle(s.key)!).text, width: 768, height: 1024, count: 1, simAssets: [SLOT_SAMPLE[s.key]!] } });
          filled[s.key] = r.images[0]!;
        } catch { filled[s.key] = null; failed++; }
      }
      if (failed) await ctx.money.refundCharge(whoOf(user), P.fillAnglesCost(failed), 'angle fill failed', m.id);
      const [cur] = await db.select().from(models).where(eq(models.id, m.id));
      if (!cur) return;
      const next: SheetSlot[] = cur.slots.map(s => (s.key in filled ? (filled[s.key] ? { ...s, busy: false, image: filled[s.key]!, source: 'generated' } : { ...s, busy: false }) : s));
      const [v] = await db.update(models).set({ slots: next }).where(eq(models.id, m.id)).returning();
      emitModel(v!);
    })().catch(e => ctx.log.error({ err: (e as Error).message }, 'fill angles failed'));
    return { model: modelView(u!), cost };
  });

  // ------------------------------------------------------------------ outfits
  app.get('/v1/outfits', async req => (await db.select().from(outfits).where(eq(outfits.studioId, req.user.studioId)).orderBy(outfits.createdAt)).map(outfitView));
  app.post('/v1/outfits', async req => {
    const b = parse(z.object({ modelId: z.string(), name: z.string().max(80).optional(), mode: z.enum(['describe', 'photo', 'own']).optional(),
      description: z.string().max(1000).optional(), images: z.array(ImageRefSchema).max(4).optional(), imageEngine: ImageEngineOverride.optional() }).passthrough(), req.body);
    const m = await model(req.user, b.modelId);
    const mode = b.mode ?? 'describe';
    const cost = mode === 'own' ? 0 : P.OUTFIT_SET_COST;
    const id = uid('o');
    await ctx.money.charge(whoOf(req.user), cost, 'outfit set', id);
    const identity = await identityOf(m);
    const spec = { name: b.name || 'New outfit', description: b.description, source: mode === 'describe' ? 'described' as const : mode === 'photo' ? 'product-photo' as const : 'reference-set' as const };
    const set = outfitSet(identity, spec);
    const [o] = await db.insert(outfits).values({ id, studioId: req.user.studioId, modelId: m.id, name: spec.name, mode, description: b.description ?? '',
      angles: [null, null, null, null], state: 'generating', prompt: set[0]!.text, seed: set[0]!.seed ?? null, createdBy: req.user.id, createdAt: Date.now() }).returning();
    const user = req.user;
    ctx.later(async () => {
      let angles: (ImageRef | null)[];
      if (mode === 'own' && b.images?.length) angles = [0, 1, 2, 3].map(i => (b.images![i] as ImageRef) ?? null);
      else {
        try {
          // Most important first (Replicate sends at most REPLICATE_IMAGE_MAX_REFS): face, profile, the product photos, body.
          const slot = (k: string) => m.slots.find(x => x.key === k)?.image;
          const refs = [slot('face'), slot('profile'), ...((b.images ?? []) as ImageRef[]), slot('front'), slot('tq'), slot('back'), slot('side')];
          const sel = await ctx.images.selection(user.studioId, b.imageEngine);
          if (sel.provider === 'simulated') {
            angles = (await ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'outfit', refId: id, override: b.imageEngine, refs,
              req: { prompt: set[0]!.text, width: 768, height: 1024, count: 4, seed: set[0]!.seed ?? undefined, simAssets: ['c_front', 'c_tq', 'c_face', 'c_front'] } })).images;
          } else if (sel.provider === 'replicate') {
            // A new front shot, then the ¾, side and back as edits of it, so all four show the same clothes.
            const front = (await ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'outfit', refId: id, override: b.imageEngine, refs,
              req: { prompt: set[0]!.text, width: 768, height: 1024, count: 1, seed: set[0]!.seed ?? undefined } })).images[0]!;
            angles = [front];
            for (const a of OUTFIT_ANGLES.slice(1)) {
              const prompt = `Show the same person in exactly the same outfit, on the same plain studio background, as a ${a.words}. `
                + 'Keep the face, hair, body and every detail of the clothes exactly the same. Realistic smartphone photo, natural skin texture.';
              angles.push((await ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'outfit', refId: id, override: b.imageEngine,
                editOf: front, refs: [slot('face')], req: { prompt, width: 768, height: 1024, count: 1, seed: set[0]!.seed ?? undefined } })).images[0]!);
            }
          } else {
            angles = await Promise.all(set.map(p => ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'outfit', refId: id, override: b.imageEngine, refs,
              req: { prompt: p.text, width: 768, height: 1024, count: 1, seed: p.seed ?? undefined } }).then(r => r.images[0]!)));
          }
        } catch (e) {
          await ctx.money.refundCharge(whoOf(user), cost, 'outfit set failed', id);
          const [f] = await db.update(outfits).set({ state: 'preview', angles: [null, null, null, null] }).where(eq(outfits.id, id)).returning();
          if (f) emitOutfit(f);
          return;
        }
      }
      const [u] = await db.update(outfits).set({ angles, state: 'preview' }).where(and(eq(outfits.id, id), eq(outfits.state, 'generating'))).returning();
      if (u) emitOutfit(u);
    }, mode === 'own' ? 300 : 0);
    return outfitView(o!);
  });
  app.post<{ Params: { id: string } }>('/v1/outfits/:id/save', async req => {
    const [o] = await db.select().from(outfits).where(and(eq(outfits.id, req.params.id), eq(outfits.studioId, req.user.studioId)));
    if (!o) throw notFound('Outfit');
    const m = await model(req.user, o.modelId);
    const [u] = await db.update(outfits).set({ state: 'ready' }).where(eq(outfits.id, o.id)).returning();
    if (!m.outfitIds.includes(o.id)) {
      const [mm] = await db.update(models).set({ outfitIds: [...m.outfitIds, o.id] }).where(eq(models.id, m.id)).returning();
      emitModel(mm!);
    } else emitModel(m);
    return outfitView(u!);
  });

  // ------------------------------------------------------------------ uploads
  const ClipMetaSchema = z.object({ name: z.string().max(200).default('Clip'), durationSec: z.number().nonnegative(), width: z.number().int().positive(), height: z.number().int().positive(),
    fps: z.number().positive(), people: z.number().int().nullable().optional(), watermark: z.string().max(200).nullable().optional(), talking: z.boolean().nullable().optional() }).passthrough();
  const extFor = (ct: string | undefined, name?: string) => (ct ?? '').includes('png') ? 'png' : (ct ?? '').includes('webp') ? 'webp' : (ct ?? '').startsWith('video/') || /\.(mp4|mov)$/i.test(name ?? '') ? ((ct ?? '').includes('quicktime') ? 'mov' : 'mp4') : 'jpg';
  async function makeClip(u: AuthUser, metaRaw: unknown, storageKey: string | null) {
    const meta = parse(ClipMetaSchema, metaRaw);
    const id = uid('clip');
    const [c] = await db.insert(clips).values({ id, studioId: u.studioId, name: meta.name ?? 'Clip', durationSec: meta.durationSec, width: meta.width, height: meta.height, fps: meta.fps,
      meta, checks: P.clipChecks(meta), storageKey, createdBy: u.id, createdAt: Date.now() }).returning();
    return clipView(c!);
  }

  app.post('/v1/uploads/images', async req => {
    if (!req.isMultipart()) throw badRequest('Expected multipart/form-data');
    const f = await req.file();
    if (!f || f.fieldname !== 'file') throw badRequest('Missing file part');
    const buf = await f.toBuffer();
    if (!(f.mimetype ?? '').startsWith('image/') && !/\.(jpe?g|png|webp)$/i.test(f.filename)) throw badRequest('Upload an image');
    const key = `u/${uid('img')}.${extFor(f.mimetype, f.filename)}`;
    await putObject(ctx, { key, body: buf, studioId: req.user.studioId, kind: 'image', userId: req.user.id });
    return { url: uploadUrl(key) };
  });
  app.post('/v1/uploads/clips', async req => {
    if (!req.isMultipart()) throw badRequest('Expected multipart/form-data');
    let meta: unknown = null, key: string | null = null;
    for await (const part of req.parts()) {
      // A JSON-typed field arrives already parsed; a plain one as text; some clients send meta as a file part.
      if (part.type === 'field' && part.fieldname === 'meta') meta = typeof part.value === 'string' ? jsonOr400(part.value) : part.value;
      else if (part.type === 'file' && part.fieldname === 'meta') meta = jsonOr400((await part.toBuffer()).toString('utf8'));
      else if (part.type === 'file' && part.fieldname === 'file') {
        const buf = await part.toBuffer();
        key = `c/${uid('vid')}.${extFor(part.mimetype || 'video/mp4', part.filename)}`;
        await putObject(ctx, { key, body: buf, studioId: req.user.studioId, kind: 'clip', userId: req.user.id });
      } else if (part.type === 'file') await part.toBuffer();
    }
    if (!meta) throw badRequest('Missing meta part');
    return makeClip(req.user, meta, key);
  });
  // Large files: presigned PUT straight to R2, then confirm.
  app.post('/v1/uploads/presign', async req => {
    const b = parse(z.object({ kind: z.enum(['image', 'clip']), contentType: z.string().max(100), bytes: z.number().int().positive().max(2 * 1024 ** 3).optional() }), req.body);
    if (b.kind === 'image' && !b.contentType.startsWith('image/')) throw badRequest('contentType must be an image type');
    if (b.kind === 'clip' && !b.contentType.startsWith('video/')) throw badRequest('contentType must be a video type');
    const id = uid('up'), key = `${b.kind === 'image' ? 'u' : 'c'}/${id}.${extFor(b.contentType)}`;
    const ttl = 3600;
    const signed = await ctx.storage.presignPut(key, b.contentType, ttl);
    await db.insert(uploads).values({ id, studioId: req.user.studioId, kind: b.kind, storageKey: key, contentType: b.contentType, bytes: b.bytes ?? null, state: 'pending', createdBy: req.user.id, createdAt: Date.now() });
    return { uploadId: id, method: 'PUT', url: signed.url, headers: signed.headers, expiresAt: Date.now() + ttl * 1000 };
  });
  app.post<{ Params: { id: string } }>('/v1/uploads/:id/confirm', async req => {
    const [up] = await db.select().from(uploads).where(and(eq(uploads.id, req.params.id), eq(uploads.studioId, req.user.studioId)));
    if (!up) throw notFound('Upload');
    const head = await ctx.storage.head(up.storageKey);
    if (!head) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it to the URL first');
    await db.update(uploads).set({ state: 'ready', bytes: head.size, sha256: null }).where(eq(uploads.id, up.id));
    await objectInfo(ctx, up.storageKey); // records bytes + sha256 for the GPU worker
    if (up.kind === 'image') return { url: uploadUrl(up.storageKey) };
    return makeClip(req.user, (req.body as any)?.meta ?? req.body, up.storageKey);
  });

  // Stored files. Keys are unguessable; image loaders in the apps can't send a bearer token.
  app.get('/uploads/*', { config: { public: true } }, async (req, reply) => {
    const key = (req.params as { '*': string })['*'];
    if (!/^(u|c|g|r|l|t|assets)\/[A-Za-z0-9._\/-]+$/.test(key) || key.includes('..')) throw notFound('Upload');
    if (ctx.storage.kind === 's3') {
      if (!(await ctx.storage.head(key))) throw notFound('Upload');
      return reply.redirect(await ctx.storage.presignGet(key, 3600), 302);
    }
    const obj = await ctx.storage.get(key);
    if (!obj) throw notFound('Upload');
    return reply.header('content-type', obj.contentType).header('cache-control', 'private, max-age=3600').send(obj.body);
  });
  app.get<{ Params: { key: string } }>('/assets/ref/:key', { config: { public: true } }, async (req, reply) => {
    const k = req.params.key.replace(/\.jpg$/, '');
    if (!ASSET_KEYS.includes(k)) throw notFound('Asset');
    return reply.header('content-type', 'image/jpeg').header('cache-control', 'public, max-age=86400').send(fs.createReadStream(path.join(ASSET_DIR, `${k}.jpg`)));
  });
  // Local-storage presigned URLs (dev only; R2 serves its own).
  if (ctx.storage instanceof LocalStorage) {
    const local = ctx.storage;
    app.addContentTypeParser('*', { parseAs: 'buffer', bodyLimit: 2 * 1024 ** 3 }, (_req, body, done) => done(null, body));
    const check = (req: FastifyRequest, method: string) => {
      const key = (req.params as { '*': string })['*'];
      const q = req.query as { exp?: string; sig?: string };
      if (!local.verify(method, key, Number(q.exp), q.sig ?? '')) throw new ApiError(403, 'bad_signature', 'Link expired or not valid');
      return key;
    };
    app.put('/storage/local/*', { config: { public: true }, bodyLimit: 2 * 1024 ** 3 }, async (req, reply) => {
      const key = check(req, 'PUT');
      const body = Buffer.isBuffer(req.body) ? req.body : Buffer.from(typeof req.body === 'string' ? req.body : JSON.stringify(req.body ?? ''));
      await local.put(key, body);
      return reply.status(200).header('etag', `"${createHash('md5').update(body).digest('hex')}"`).send();
    });
    app.get('/storage/local/*', { config: { public: true } }, async (req, reply) => {
      const key = check(req, 'GET');
      const obj = await local.get(key);
      if (!obj) throw notFound('Object');
      return reply.header('content-type', obj.contentType).send(obj.body);
    });
  }

  // ------------------------------------------------------------------ jobs and takes
  app.get('/v1/jobs', async req => ctx.jobs.list(req.user.studioId));
  app.post('/v1/jobs', async req => ctx.jobs.create(req.user, req.body));
  app.delete<{ Params: { id: string } }>('/v1/jobs/:id', async (req, reply) => { await ctx.jobs.remove(req.user, req.params.id); return reply.status(204).send(); });
  app.post('/v1/queue/run', async req => ctx.jobs.runQueue(req.user));

  app.get('/v1/takes', async req => (await db.select().from(takes).where(eq(takes.studioId, req.user.studioId)).orderBy(desc(takes.createdAt))).map(t => takeView(t, pub, req.user.id)));
  app.patch<{ Params: { id: string } }>('/v1/takes/:id', async req => {
    const b = (req.body ?? {}) as { status?: string };
    const [t] = await db.select().from(takes).where(and(eq(takes.id, req.params.id), eq(takes.studioId, req.user.studioId)));
    if (!t) throw notFound('Take');
    if (b.status !== 'test' && b.status !== 'final') throw badRequest('status must be test or final');
    const [u] = await db.update(takes).set({ status: b.status }).where(eq(takes.id, t.id)).returning();
    return takeView(u!, pub, req.user.id);
  });
  app.delete<{ Params: { id: string } }>('/v1/takes/:id', async (req, reply) => {
    await db.delete(takes).where(and(eq(takes.id, req.params.id), eq(takes.studioId, req.user.studioId)));
    return reply.status(204).send();
  });

  const ImageEngineOverride = z.object({ provider: z.enum(PROVIDERS), model: z.string().optional(), url: z.string().url().optional() });
  const outfitOf = async (u: AuthUser, id?: string) => {
    if (!id) return undefined;
    const [o] = await db.select().from(outfits).where(and(eq(outfits.id, id), eq(outfits.studioId, u.studioId)));
    return o;
  };
  const outfitSpec = (o?: typeof outfits.$inferSelect) => o ? { name: o.name, description: o.description, source: o.mode === 'describe' && !o.angles.some(Boolean) ? 'described' as const : 'reference-set' as const } : null;
  /** References for a shot, most important first (Replicate sends only the first REPLICATE_IMAGE_MAX_REFS): face, profile,
   * the outfit's front and ¾, a product photo, then the body shots and the outfit's other angles. */
  const shootRefs = (m: typeof models.$inferSelect, o?: typeof outfits.$inferSelect, extra: (ImageRef | null | undefined)[] = []) => {
    const slot = (k: string) => m.slots.find(x => x.key === k)?.image;
    const a = o?.angles ?? [];
    return [slot('face'), slot('profile'), a[0], a[1], ...extra, slot('front'), slot('tq'), a[3], a[2], slot('back'), slot('side')];
  };

  app.post('/v1/shoots', async req => {
    const b = parse(z.object({ modelId: z.string(), outfitId: z.string().optional(), scene: z.string().max(200).optional(), prompt: z.string().max(4000).optional(),
      seed: z.number().int().nullable().optional(), count: z.number().int().optional(), direction: z.string().max(500).optional(), lockSeed: z.boolean().optional(),
      templateId: z.string().optional(), shuffleSeed: z.number().int().min(0).optional(), productImage: z.object({ asset: z.string().optional(), url: z.string().optional() }).optional(),
      imageEngine: ImageEngineOverride.optional() }).passthrough(), req.body);
    const m = await model(req.user, b.modelId);
    const o = await outfitOf(req.user, b.outfitId);
    const count = Math.min(4, Math.max(1, b.count ?? 4));
    if (b.templateId) return templateShoot(req.user, b, m, o, count);
    const id = uid('shoot');
    await ctx.money.charge(whoOf(req.user), P.SHOOT_COST, 'photoshoot', id);
    const built = photoshoot({ identity: await identityOf(m), outfit: { name: o?.name ?? 'outfit' }, scene: b.scene?.split(' · ')[0], direction: b.direction, lockSeed: b.lockSeed });
    const prompt = b.prompt?.trim() || built.text;
    const seed = b.seed ?? built.seed ?? undefined;
    const refs = shootRefs(m, o);
    let r;
    try {
      r = await ctx.images.generate({ studioId: req.user.studioId, userId: req.user.id, purpose: 'shoot', refId: id, override: b.imageEngine, refs,
        req: { prompt, width: 1080, height: 1920, count, seed, simAssets: [o?.angles?.[0]?.asset ?? 'g_front', 'c_face', 'face', 'g_tq'] } });
    } catch (e) {
      await ctx.money.refundCharge(whoOf(req.user), P.SHOOT_COST, 'photoshoot failed', id);
      throw e;
    }
    const label = (b.scene ?? 'Shoot').split(' · ')[0]!.slice(0, 28);
    const layers = layersFromPrompt(built.text);
    const rows = r.images.map((img, n) => ({
      id: uid('s'), studioId: req.user.studioId, userId: req.user.id, kind: 'shot' as const, jobId: null, modelId: m.id, index: n + 1, of: r.images.length,
      title: `Shoot · ${label}`, label: `${label} · ${n + 1}`, engineLabel: ctx.images.shotLabel(r.selection), cost: P.SHOOT_COST / r.images.length, seed: r.seed ?? seed ?? 0, status: 'test' as const,
      thumb: img, prompt, mediaKey: ctx.images.keyOf(img), layers, createdAt: Date.now() + n,
    }));
    const inserted = await db.insert(takes).values(rows).returning();
    return inserted.map(t => takeView(t, pub, req.user.id));
  });

  /**
   * A template shoot: every still gets its own prompt (template layers + identity/outfit/never-add + its own variation
   * draws, or the user's direction in place of pose and angle), its own seed, and the template's after-effects.
   */
  async function templateShoot(u: AuthUser, b: { templateId?: string; direction?: string; shuffleSeed?: number; lockSeed?: boolean; productImage?: ImageRef; imageEngine?: any },
    m: typeof models.$inferSelect, o: typeof outfits.$inferSelect | undefined, count: number) {
    const t = await ctx.templates.visible(u, b.templateId!);
    const identity = await identityOf(m);
    const product = t.layers.product && (b.productImage?.asset || b.productImage?.url) ? b.productImage! : null;
    const shuffleSeed = b.shuffleSeed ?? randomSeed();
    const id = uid('shoot');
    await ctx.money.charge(whoOf(u), P.SHOOT_COST, 'photoshoot', id);
    const refs = shootRefs(m, o, [product]);
    const now = Date.now();
    const rows: (typeof takes.$inferInsert)[] = [];
    try {
      for (let n = 0; n < count; n++) {
        const p = buildTemplatePrompt({ templateId: t.id, templateName: t.name, layers: t.layers, pool: t.variationPool, identity, outfit: outfitSpec(o),
          direction: b.direction, shuffleSeed, index: n, lockSeed: b.lockSeed, seed: randomImageSeed(), hasProduct: !!product });
        const sim = [o?.angles?.[0]?.asset ?? 'g_front', 'c_face', 'face', 'g_tq'];
        const r = await ctx.images.generate({ studioId: u.studioId, userId: u.id, purpose: 'shoot', refId: id, override: b.imageEngine, refs,
          req: { prompt: p.fullText, width: 1080, height: 1920, count: 1, seed: p.seed ?? undefined, simAssets: [sim[n % sim.length]!] } });
        const fx = await ctx.templates.postProcess(r.images[0]!, t.layers, { studioId: u.studioId, userId: u.id });
        rows.push({
          id: uid('s'), studioId: u.studioId, userId: u.id, kind: 'shot', jobId: null, modelId: m.id, index: n + 1, of: count,
          title: `Shoot · ${t.name}`.slice(0, 60), label: `${t.name.slice(0, 28)} · ${n + 1}`, engineLabel: ctx.images.shotLabel(r.selection), cost: P.SHOOT_COST / count,
          seed: p.seed ?? r.seed ?? 0, status: 'test', thumb: fx.ref, prompt: p.fullText, publicPrompt: p.visibleText, mediaKey: fx.key,
          layers: t.layers, templateId: t.id, templateName: t.name, templateOwnerId: t.ownerId, variation: p.variation, shuffleSeed, createdAt: now + n,
        });
      }
    } catch (e) {
      await ctx.money.refundCharge(whoOf(u), P.SHOOT_COST, 'photoshoot failed', id);
      throw e;
    }
    const inserted = await db.insert(takes).values(rows).returning();
    await ctx.templates.bumpUses(t.id);
    return inserted.map(x => takeView(x, pub, u.id));
  }

  // ------------------------------------------------------------------ photo templates
  app.get('/v1/templates', async req => ctx.templates.list(req.user, (req.query ?? {}) as any));
  app.post('/v1/templates', async req => ctx.templates.create(req.user, req.body));
  app.post('/v1/templates/draft', async req => ctx.templates.draft(req.user, req.body));
  app.get<{ Params: { id: string } }>('/v1/templates/:id', async req => ctx.templates.detail(req.user, req.params.id));
  app.patch<{ Params: { id: string } }>('/v1/templates/:id', async req => ctx.templates.patch(req.user, req.params.id, req.body));
  app.delete<{ Params: { id: string } }>('/v1/templates/:id', async (req, reply) => { await ctx.templates.remove(req.user, req.params.id); return reply.status(204).send(); });
  app.post<{ Params: { id: string } }>('/v1/templates/:id/duplicate', async req => ctx.templates.duplicate(req.user, req.params.id));
  app.post<{ Params: { id: string } }>('/v1/templates/:id/favourite', async req => ctx.templates.favourite(req.user, req.params.id, true));
  app.delete<{ Params: { id: string } }>('/v1/templates/:id/favourite', async req => ctx.templates.favourite(req.user, req.params.id, false));
  app.post<{ Params: { id: string } }>('/v1/templates/:id/prompt', async req => ctx.templates.preview(req.user, req.params.id, req.body, async (modelId, outfitId) => {
    const m = await model(req.user, modelId);
    return { identity: await identityOf(m), outfit: outfitSpec(await outfitOf(req.user, outfitId)) };
  }));

  // ------------------------------------------------------------------ identity LoRA
  app.get<{ Params: { id: string } }>('/v1/models/:id/lora', async req => ctx.lora.get(req.user, req.params.id));
  app.post<{ Params: { id: string } }>('/v1/models/:id/lora/candidates', async req => ctx.lora.buildCandidates(req.user, req.params.id));
  app.patch<{ Params: { id: string; cid: string } }>('/v1/models/:id/lora/candidates/:cid', async req => ctx.lora.keep(req.user, req.params.id, req.params.cid, (req.body as any)?.keep === true));
  app.post<{ Params: { id: string } }>('/v1/models/:id/lora/train', async req => ctx.lora.train(req.user, req.params.id));
  app.patch<{ Params: { id: string } }>('/v1/models/:id/lora', async req => ctx.lora.patch(req.user, req.params.id, (req.body ?? {}) as any));

  // ------------------------------------------------------------------ social accounts and posts
  app.get<{ Params: { id: string } }>('/v1/models/:id/accounts', async req => {
    const m = await model(req.user, req.params.id);
    const rows = await db.select().from(accounts).where(eq(accounts.modelId, m.id));
    return PLATFORMS.map(k => rows.find(a => a.platform === k)).filter(Boolean).map(a => accountView(a!));
  });
  app.post<{ Params: { id: string; platform: string } }>('/v1/models/:id/accounts/:platform/connect', async req => ctx.posts.connect(req.user, req.params.id, req.params.platform));
  app.delete<{ Params: { id: string; platform: string } }>('/v1/models/:id/accounts/:platform', async (req, reply) => {
    const m = await model(req.user, req.params.id);
    await db.delete(accounts).where(and(eq(accounts.modelId, m.id), eq(accounts.platform, platformOf(req.params.platform))));
    return reply.status(204).send();
  });
  app.get('/v1/posts', async req => { const q = req.query as { state?: string; modelId?: string }; return ctx.posts.list(req.user.studioId, q.state || undefined, q.modelId || undefined); });
  app.post('/v1/posts', async req => ctx.posts.create(req.user, req.body));
  app.delete<{ Params: { id: string } }>('/v1/posts/:id', async (req, reply) => { await ctx.posts.remove(req.user, req.params.id); return reply.status(204).send(); });

  // ------------------------------------------------------------------ money
  app.get('/v1/balance', async req => ctx.money.balanceView(whoOf(req.user)));
  app.post('/v1/balance/topup', async req => {
    const b = (req.body ?? {}) as { amount?: number };
    if (ctx.config.balanceMode !== 'simulated') throw new ApiError(400, 'topup_unavailable', 'Top up your RunPod account; MUSE reads the balance from RunPod');
    if (req.user.role !== 'owner') throw new ApiError(403, 'owner_only', 'Ask the studio owner for tokens');
    if (!(typeof b.amount === 'number' && b.amount > 0 && b.amount <= 500)) throw badRequest('Amount must be between $0 and $500');
    await ctx.money.simTopUp(whoOf(req.user), b.amount);
    return ctx.money.balanceView(whoOf(req.user));
  });
  app.get('/v1/wallet', async req => ctx.money.walletView(whoOf(req.user)));
  app.post('/v1/wallets/transfer', { config: { owner: true } }, async req => {
    const b = parse(z.object({ toUserId: z.string(), tokens: z.number().int().positive().max(10_000_000), note: z.string().max(200).optional() }), req.body);
    await ctx.money.transfer(whoOf(req.user), b.toUserId, b.tokens, b.note);
    return { wallet: await ctx.money.walletView(whoOf(req.user)), member: await memberView(req.user.studioId, b.toUserId) };
  });
  app.post('/v1/wallets/reclaim', { config: { owner: true } }, async req => {
    const b = parse(z.object({ fromUserId: z.string(), tokens: z.number().int().positive().max(10_000_000), note: z.string().max(200).optional() }), req.body);
    await ctx.money.reclaim(whoOf(req.user), b.fromUserId, b.tokens, b.note);
    return { wallet: await ctx.money.walletView(whoOf(req.user)), member: await memberView(req.user.studioId, b.fromUserId) };
  });

  async function memberView(studioId: string, id: string) {
    const [u] = await db.select().from(users).where(and(eq(users.id, id), eq(users.studioId, studioId)));
    if (!u) throw notFound('Member');
    const w = await ctx.money.wallet(u.id, studioId);
    const caps = await ctx.money.caps(u);
    return compact({
      id: u.id, email: u.email, role: u.role, tokens: w.tokens, usd: ctx.money.toUsd(w.tokens), heldTokens: w.held,
      todayUsd: await ctx.money.spend(studioId, dayStart(), u.id), monthUsd: await ctx.money.spend(studioId, monthStart(), u.id),
      lastActiveAt: u.lastActiveAt, disabled: !!u.disabledAt, capPerJob: caps.perJob, capPerDay: caps.perUserDay, createdAt: u.createdAt,
    });
  }
  app.get('/v1/members', { config: { owner: true } }, async req => {
    const rows = await db.select().from(users).where(eq(users.studioId, req.user.studioId)).orderBy(users.createdAt);
    return Promise.all(rows.map(u => memberView(req.user.studioId, u.id)));
  });
  app.patch<{ Params: { id: string } }>('/v1/members/:id', { config: { owner: true } }, async req => {
    const b = parse(z.object({ capPerJob: z.number().nonnegative().max(1000).nullable().optional(), capPerDay: z.number().nonnegative().max(10000).nullable().optional(), disabled: z.boolean().optional() }), req.body);
    const [u] = await db.select().from(users).where(and(eq(users.id, req.params.id), eq(users.studioId, req.user.studioId)));
    if (!u) throw notFound('Member');
    if (b.disabled && u.id === req.user.id) throw badRequest("You can't switch off your own account");
    const patch: Partial<typeof users.$inferInsert> = {};
    if (b.capPerJob !== undefined) patch.capPerJob = b.capPerJob;
    if (b.capPerDay !== undefined) patch.capPerDay = b.capPerDay;
    if (b.disabled !== undefined) patch.disabledAt = b.disabled ? Date.now() : null;
    if (Object.keys(patch).length) await db.update(users).set(patch).where(eq(users.id, u.id));
    if (b.disabled) await db.update(sessions).set({ revokedAt: Date.now() }).where(and(eq(sessions.userId, u.id), isNull(sessions.revokedAt)));
    return memberView(req.user.studioId, u.id);
  });
  app.get('/v1/ledger', { config: { owner: true } }, async req => {
    const q = req.query as { limit?: string; userId?: string };
    const conds = [eq(ledger.studioId, req.user.studioId)];
    if (q.userId) conds.push(eq(ledger.userId, q.userId));
    return db.select().from(ledger).where(and(...conds)).orderBy(desc(ledger.id)).limit(Math.min(500, Number(q.limit) || 100));
  });

  // ------------------------------------------------------------------ settings
  const EngineBody = z.object({ provider: z.enum(PROVIDERS), model: z.string().min(1).max(200).optional(), url: z.string().url().max(500).optional() });
  const engineView = async (studioId: string) => { const sel = await ctx.images.selection(studioId); return { ...sel, label: ctx.images.label(sel), available: ctx.images.available() }; };
  app.get('/v1/settings/image-engine', async req => engineView(req.user.studioId));
  app.patch('/v1/settings/image-engine', async req => {
    const b = parse(EngineBody, req.body);
    if (b.provider === 'custom-http') {
      if (!b.url) throw badRequest('The custom engine needs a URL');
      if (!ctx.config.DEV_MODE && !b.url.startsWith('https://')) throw badRequest('Use an https:// URL');
      if (req.user.role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can point MUSE at a custom engine');
    }
    if (b.provider === 'fal' && !ctx.config.FAL_KEY) throw badRequest('fal is not set up on the server (FAL_KEY)');
    if (b.provider === 'replicate' && !ctx.replicate.configured) throw badRequest('Replicate is not set up on the server (REPLICATE_API_TOKEN)');
    const cur = await ctx.images.selection(req.user.studioId);
    const next = b.provider === 'replicate' ? { provider: b.provider, model: b.model ?? (cur.provider === 'replicate' ? cur.model : ctx.config.REPLICATE_IMAGE_MODEL) }
      : { provider: b.provider, model: b.model ?? (b.provider === cur.provider ? cur.model : b.provider === 'simulated' ? 'bundled-stills' : ctx.config.IMAGE_MODEL), ...(b.url ? { url: b.url } : {}) };
    await ctx.money.settings(req.user.studioId);
    await db.update(studioSettings).set({ imageEngine: next }).where(eq(studioSettings.studioId, req.user.studioId));
    return engineView(req.user.studioId);
  });
  const studioSettingsView = async (studioId: string) => {
    const s = await ctx.money.settings(studioId);
    const c = ctx.config;
    return { maxGpus: s.maxGpus ?? c.MAX_GPUS, overheadPayer: s.overheadPayer ?? 'user', capPerJob: s.capPerJob ?? c.CAP_PER_JOB_USD, capPerDay: s.capPerDay ?? c.CAP_PER_DAY_USD,
      capPerUserDay: s.capPerUserDay ?? c.CAP_PER_USER_DAY_USD, tokenUsd: c.TOKEN_USD, minRunpodBalance: c.RUNPOD_MIN_BALANCE_USD, lowBalance: !!s.lowBalanceSince,
      warmGpuAllowed: s.warmGpuAllowed ?? 'everyone', warmIdleMinutes: s.warmIdleMinutes ?? c.WARM_IDLE_MINUTES, warmMaxMinutes: s.warmMaxMinutes ?? c.WARM_MAX_MINUTES,
      features: ctx.jobs.features(), gpu: await ctx.gpu.status() };
  };
  app.get('/v1/settings/studio', async req => studioSettingsView(req.user.studioId));
  app.patch('/v1/settings/studio', { config: { owner: true } }, async req => {
    const b = parse(z.object({ maxGpus: z.number().int().min(0).max(16).optional(), overheadPayer: z.enum(['user', 'owner']).optional(),
      capPerJob: z.number().nonnegative().max(1000).optional(), capPerDay: z.number().nonnegative().max(10000).optional(), capPerUserDay: z.number().nonnegative().max(10000).optional(),
      warmGpuAllowed: z.enum(['owner', 'everyone']).optional(), warmIdleMinutes: z.number().int().min(5).max(120).optional(), warmMaxMinutes: z.number().int().min(30).max(480).optional() }), req.body);
    await ctx.money.settings(req.user.studioId);
    if (Object.keys(b).length) await db.update(studioSettings).set(b).where(eq(studioSettings.studioId, req.user.studioId));
    return studioSettingsView(req.user.studioId);
  });

  // ------------------------------------------------------------------ Keep GPU warm (services/warm.ts)
  app.get('/v1/gpu/warm', async req => ctx.warm.view(whoOf(req.user)));
  app.post('/v1/gpu/warm', async req => {
    const b = parse(z.object({ on: z.boolean().optional(), extend: z.boolean().optional() }), req.body ?? {});
    if (b.extend) return ctx.warm.extend(req.user);
    if (b.on === true) return ctx.warm.turnOn(req.user);
    if (b.on === false) return ctx.warm.turnOff(req.user);
    throw badRequest('Send {on: true}, {on: false} or {extend: true}');
  });

  // ------------------------------------------------------------------ live events
  // Server-sent events through a hosting proxy (Koyeb, Railway): no compression and no buffering anywhere
  // (no-transform, X-Accel-Buffering; this server registers no compression plugin; Nagle off), a comment line every 15 s so the proxy's idle
  // timeout never closes the stream, and the socket's own timeout disabled.
  app.get('/v1/events', async (req, reply) => {
    reply.hijack();
    const res = reply.raw;
    req.raw.socket.setTimeout(0);
    req.raw.socket.setNoDelay(true);
    req.raw.socket.setKeepAlive(true, 30_000);
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache, no-store, no-transform', connection: 'keep-alive',
      'x-accel-buffering': 'no',
    });
    res.flushHeaders();
    // retry: how long a client waits before reconnecting after the stream drops (e.g. an instance restart).
    res.write('retry: 3000\n: connected\n\n');
    const off = ctx.hub.subscribe(req.user.studioId, req.user.id, line => res.write(line));
    const ka = setInterval(() => res.write(': keep-alive\n\n'), SSE_KEEPALIVE_MS);
    req.raw.on('close', () => { clearInterval(ka); off(); });
  });

  // ------------------------------------------------------------------ developer (DEV_MODE only)
  if (ctx.config.DEV_MODE) {
    app.post('/v1/dev/fail-next', async (req, reply) => {
      await ctx.money.settings(req.user.studioId);
      await db.update(studioSettings).set({ failNext: (req.body as any)?.failNext === true }).where(eq(studioSettings.studioId, req.user.studioId));
      return reply.status(204).send();
    });
    app.post('/v1/dev/reset', { config: { public: true } }, async () => { await seedDev(ctx, { reset: true }); return { ok: true }; });
  }
}

export type { FastifyReply };
export { inArray, wallets };
