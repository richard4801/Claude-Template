// App-facing routes: plans/api.md, plus invites, wallets/members, settings and presigned uploads.
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { and, desc, eq, inArray, isNotNull, isNull, ne, sql } from 'drizzle-orm';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { accounts, clips, invites, jobs, ledger, loras, models, outfits, posts, sessions, studioSettings, takes, uploads, users, wallets, type ImageRef, type SheetSlot } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, dayStart, monthStart, uid } from '../lib/util.js';
import { whoOf } from '../money/money.js';
import * as P from '../pricing.js';
import { cameraValues, characterSheetShot, collageLine, outfitEditPrompt, outfitSet, photoshoot, sheetAngle, shootChoices, loraToken, OUTFIT_ANGLES } from '../prompt/engine.js';
import { BODY_SLOTS, bodySlotOf, identityRefs, IDENTITY_REFS_MAX, IDENTITY_REFS_MIN, type IdentityRef } from '../images/identity.js';
import { createInvite, revokeSession, signin, signup } from '../auth/auth.js';
import { accountView, PLATFORMS, platformOf } from '../services/posts.js';
import { takeView } from '../services/jobs.js';
import { ASSET_DIR, ASSET_KEYS, PROVIDERS, type ShootRefIn } from '../images/service.js';
import { PhotoBill } from '../images/bill.js';
import { MODEL_ID_RE } from '../replicate/catalog.js'; // WS5
import type { EngineSelection } from '../images/engines.js'; // WS5
import { LocalStorage, contentTypeFor } from '../storage/index.js';
import { objectInfo, putObject } from '../storage/objects.js';
import { seedDev, SLOT_SAMPLE } from '../seed.js';
import { buildTemplatePrompt, randomImageSeed, randomSeed } from '../templates/prompt.js';
import { analyzeClip, audioView } from '../audio/service.js';
import { dbStatus } from '../db/pg.js';
import { inviteShareText, registerReleaseRoutes } from './releases.js';
import { setViews } from '../services/tools.js';
import { IMAGE_STEPS, type ImageStep } from '../replicate/mapping.js';
import { CatalogError } from '../replicate/catalog.js';
import { photoLook } from '../editor/photo.js'; // Editor v2 (workstream 3)
import type { Look } from '../editor/look.js';
import { PhotoRequestSchema, photoButton, photoFilter, photoRigCheck, stillRig, type StillRig } from '../suite/photo.js'; // AI suite Photo tool (workstream 3)
import { draftOf, RigSchema, type Draft } from '../suite/drafts.js';
import { referencesOf } from '../suite/assist.js';
import { modelChoice } from '../engines/service.js'; // WS13: model choice everywhere
import type { StepOverrides } from '../images/steps.js'; // WS13

/** SSE comment interval: well under any hosting proxy's idle timeout (Koyeb, Railway, Cloudflare: 60-100 s). */
export const SSE_KEEPALIVE_MS = 10_000;

/** The 7 sheet images (faceTq appended last, plans/api.md "Model tools" §1). */
export const SLOT_KEYS = ['face', 'profile', 'front', 'tq', 'side', 'back', 'faceTq'];
const parse = <T>(schema: z.ZodType<T>, body: unknown): T => {
  const r = schema.safeParse(body ?? {});
  if (!r.success) { const i = r.error.issues[0]!; throw badRequest(`${i.path.join('.') || 'body'}: ${i.message}`); }
  return r.data;
};
const jsonOr400 = (s: string) => { try { return JSON.parse(s); } catch { throw new ApiError(400, 'bad_json', 'meta is not valid JSON'); } };
const ImageRefSchema = z.object({ asset: z.string().max(100).optional(), url: z.string().max(2000).optional() });

export function modelView(m: typeof models.$inferSelect) {
  // Every model shows the 7 sheet images, also a row written before faceTq existed.
  const slots = SLOT_KEYS.map(k => m.slots.find(s => s.key === k) ?? { key: k, image: null, source: 'upload' as const, busy: false });
  return compact({ id: m.id, name: m.name, age: m.age, niche: m.niche, look: m.look, neverAdd: m.neverAdd, slots, outfitIds: m.outfitIds, personality: m.personality, notes: m.notes,
    identityBodySlot: bodySlotOf(m), archived: !!m.archivedAt, archivedAt: m.archivedAt ?? undefined,
    defaultRig: m.defaultRig ?? undefined /* AI suite (workstream 1): filled into rows still on Auto when she's @-mentioned */ });
}
export const outfitView = (o: typeof outfits.$inferSelect) =>
  compact({ id: o.id, modelId: o.modelId, name: o.name, mode: o.mode, description: o.description, angles: o.angles, faces: o.faces ?? undefined, state: o.state, prompt: o.prompt, cost: o.cost ?? undefined });
setViews(modelView, outfitView);
const clipView = (c: typeof clips.$inferSelect) => compact({ id: c.id, name: c.name, durationSec: c.durationSec, width: c.width, height: c.height, fps: P.wireFps(c.fps), checks: c.checks,
  /* prompt scripts: talking detection */ audio: audioView(c) ?? undefined });

export async function registerRoutes(app: FastifyInstance, ctx: Ctx) {
  const db = ctx.db;
  const pub = ctx.config.PUBLIC_URL ?? '';
  const uploadUrl = (key: string) => `${pub}/uploads/${key}`;
  const emitModel = (m: typeof models.$inferSelect) => ctx.hub.emit(m.studioId, { type: 'model', model: modelView(m) });
  const emitOutfit = (o: typeof outfits.$inferSelect) => ctx.hub.emit(o.studioId, { type: 'outfit', outfit: outfitView(o) });
  /** New or changed takes: each viewer gets the prompt they may see (a template's hidden layers only to its owner). */
  const emitTakes = (studioId: string, rows: (typeof takes.$inferSelect)[]) => {
    for (const t of rows) void ctx.hub.emit(studioId, v => ({ type: 'take', take: takeView(t, pub, v.userId) }));
  };
  const asUser = (v: { userId: string; studioId: string; role: 'owner' | 'member' }) => ({ id: v.userId, studioId: v.studioId, role: v.role, email: '', studioName: '', sessionId: null }) as AuthUser;

  /** A model of the studio; `forWork` refuses an archived one (plans/api.md "Model tools" §7). */
  async function model(u: AuthUser, id: string, forWork = false) {
    const [m] = await db.select().from(models).where(and(eq(models.id, id), eq(models.studioId, u.studioId)));
    if (!m) throw notFound('Model');
    if (forWork && m.archivedAt) throw new ApiError(409, 'model_archived', 'This model is archived · restore her in Settings → Archived models');
    return m;
  }
  async function activeLora(m: typeof models.$inferSelect) {
    const [l] = await db.select().from(loras).where(eq(loras.modelId, m.id));
    return l && l.version > 0 && l.use ? loraToken(m.name, l.version) : null;
  }
  /** Who she is, for a prompt; `sent` = how many of her own images go with it (default: her sheet images). */
  const identityOf = async (m: typeof models.$inferSelect, sent?: number) => ({
    name: m.name, look: m.look || `${m.age}-year-old woman`, neverAdd: m.neverAdd,
    referenceCount: Math.max(1, sent ?? m.slots.filter(s => s.image && !s.busy).length), lora: await activeLora(m),
  });
  /** Her identity images for a photo step (plans/api.md "Identity images"), with the studio's budget. */
  const idRefs = async (studioId: string, m: typeof models.$inferSelect, o?: typeof outfits.$inferSelect | null, opts: { outfit?: boolean; extra?: IdentityRef[]; count?: number } = {}) =>
    identityRefs(m, o, { count: await ctx.images.identityCount(studioId), ...opts });
  const personCount = (ids: IdentityRef[]) => ids.filter(i => i.role === 'person').length;
  /** "Identity from N locked reference images": the ones a plan really sends (identity images come first). */
  const sentOf = (ids: IdentityRef[], plan: { images: ImageRef[]; sent: unknown[] }) => personCount(ids.slice(0, plan.images.length - plan.sent.length));

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
  app.post('/v1/auth/signup', { config: authLimit }, async req => {
    const r = await signup(ctx, (req.body ?? {}) as any);
    // A new member joined through an invite: the owners' Members and Invites lists follow.
    const u = r.user as { id: string; studioId?: string };
    const [row] = await db.select({ studioId: users.studioId, inviteId: users.inviteId }).from(users).where(eq(users.id, u.id));
    if (row) {
      void ctx.money.memberView(row.studioId, u.id).then(m => ctx.hub.emitOwners(row.studioId, { type: 'member', member: m })).catch(() => {});
      if (row.inviteId) ctx.hub.emitOwners(row.studioId, { type: 'invite', op: 'used', id: row.inviteId });
    }
    return r;
  });
  app.post('/v1/auth/signout', async (req, reply) => { if (req.user.sessionId) await revokeSession(ctx, req.user.sessionId); return reply.status(204).send(); });
  app.get('/v1/auth/me', async req => ({ id: req.user.id, email: req.user.email, studioName: req.user.studioName, role: req.user.role }));

  // ------------------------------------------------------------------ invites (owner)
  app.post('/v1/invites', { config: { owner: true } }, async req => {
    const b = parse(z.object({ email: z.string().email().optional(), role: z.enum(['owner', 'member']).optional(), days: z.number().int().min(1).max(90).optional() }), req.body);
    const inv = await createInvite(ctx, { studioId: req.user.studioId, email: b.email, role: b.role ?? 'member', createdBy: req.user.id, days: b.days });
    ctx.hub.emitOwners(req.user.studioId, { type: 'invite', invite: compact({ id: inv.id, email: inv.email, role: inv.role, createdAt: Date.now(), expiresAt: inv.expiresAt }) });
    // shareText: the message to send with the code (the download page, the code, the email).
    return { ...inv, shareText: inviteShareText(ctx.publicBase(), inv.code, inv.email, b.days ?? 14) };
  });
  app.get('/v1/invites', { config: { owner: true } }, async req =>
    (await db.select().from(invites).where(eq(invites.studioId, req.user.studioId)).orderBy(desc(invites.createdAt)))
      .map(i => compact({ id: i.id, email: i.email, role: i.role, createdAt: i.createdAt, expiresAt: i.expiresAt, usedAt: i.usedAt })));

  // ------------------------------------------------------------------ app downloads (/get, /download/*, PUT /v1/releases/*)
  await registerReleaseRoutes(app, ctx);

  // ------------------------------------------------------------------ models and character sheets
  app.get('/v1/models', async req => {
    const archived = ['1', 'true'].includes(String((req.query as any)?.archived ?? ''));
    if (archived && req.user.role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can see archived models');
    const rows = await db.select().from(models).where(and(eq(models.studioId, req.user.studioId), archived ? isNotNull(models.archivedAt) : isNull(models.archivedAt))).orderBy(models.createdAt);
    return rows.map(modelView);
  });
  // Archive (owner): hidden from every list and picker, nothing deleted.
  for (const [path, on] of [['archive', true], ['unarchive', false]] as const) {
    app.post<{ Params: { id: string } }>(`/v1/models/:id/${path}`, { config: { owner: true } }, async req => {
      const m = await model(req.user, req.params.id);
      const [u] = await db.update(models).set({ archivedAt: on ? m.archivedAt ?? Date.now() : null }).where(eq(models.id, m.id)).returning();
      emitModel(u!);
      return modelView(u!);
    });
  }
  app.post('/v1/models', async req => {
    const b = parse(z.object({ name: z.string().max(80).optional(), age: z.number().optional(), niche: z.string().max(80).optional() }).passthrough(), req.body);
    const [m] = await db.insert(models).values({
      id: uid('m'), studioId: req.user.studioId, name: b.name?.trim() || 'New model', age: Math.min(70, Math.max(18, Math.round(b.age ?? 27))), niche: b.niche ?? 'Beauty',
      look: '', neverAdd: [], slots: SLOT_KEYS.map(k => ({ key: k, image: null, source: 'upload', busy: false })), outfitIds: [], createdBy: req.user.id, createdAt: Date.now(),
    }).returning();
    emitModel(m!);
    return modelView(m!);
  });
  app.patch<{ Params: { id: string } }>('/v1/models/:id', async req => {
    const b = parse(z.object({ name: z.string().max(80).optional(), niche: z.string().max(80).optional(), personality: z.string().max(2000).optional(),
      notes: z.string().max(4000).optional(), neverAdd: z.array(z.string().max(80)).max(50).optional(), look: z.string().max(1000).optional(),
      identityBodySlot: z.enum(BODY_SLOTS).optional(),
      // AI suite (workstream 1): her default rig (suite/drafts.ts RigSchema); null clears it.
      defaultRig: RigSchema.nullable().optional() }).passthrough(), req.body);
    const m = await model(req.user, req.params.id);
    if (typeof b.name === 'string' && !b.name.trim()) throw badRequest('Give her a name');
    const patch: Partial<typeof models.$inferInsert> = {};
    // Which full-body image her photos send: the owner or whoever made her.
    if (b.identityBodySlot) {
      if (req.user.role !== 'owner' && m.createdBy !== req.user.id) throw new ApiError(403, 'owner_only', 'Only the studio owner or her creator can choose this');
      patch.identityBodySlot = b.identityBodySlot;
    }
    for (const k of ['name', 'niche', 'personality', 'notes', 'look'] as const) if (typeof b[k] === 'string') patch[k] = b[k];
    if (b.neverAdd) patch.neverAdd = b.neverAdd.map(x => x.trim()).filter(Boolean);
    if (b.defaultRig !== undefined) patch.defaultRig = b.defaultRig && Object.keys(b.defaultRig).length ? b.defaultRig : null;
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
    // Her outfits and posts went with her: the apps drop them by modelId.
    ctx.hub.emit(m.studioId, { type: 'model', op: 'delete', id: m.id });
    return reply.status(204).send();
  });
  app.put<{ Params: { id: string; slot: string } }>('/v1/models/:id/slots/:slot', async req => {
    const b = parse(z.object({ image: ImageRefSchema.nullable().optional(), source: z.enum(['upload', 'generated']).optional() }), req.body);
    const m = await model(req.user, req.params.id);
    if (!SLOT_KEYS.includes(req.params.slot)) throw notFound('Slot');
    const slots = m.slots.map(s => (s.key === req.params.slot ? { ...s, image: (b.image as ImageRef | null) ?? null, source: b.source ?? 'upload', busy: false } : s));
    const [u] = await db.update(models).set({ slots }).where(eq(models.id, m.id)).returning();
    emitModel(u!);
    return modelView(u!);
  });
  app.post<{ Params: { id: string } }>('/v1/models/:id/fill-angles', async req => {
    const m0 = await model(req.user, req.params.id, true);
    const m = { ...m0, slots: SLOT_KEYS.map(k => m0.slots.find(s => s.key === k) ?? { key: k, image: null, source: 'upload' as const, busy: false }) };
    const missing = m.slots.filter(s => !s.image && !s.busy);
    // Her identity images within the shot model's limit (plans/api.md "Identity images"); one sheet image each.
    const fillIds = await idRefs(req.user.studioId, m);
    const stepModels = await modelChoice(ctx).imageOverrides(req.user, 'character', (req.body ?? {}) as Record<string, unknown>); // WS13: `imageModel`, else the Character photos default
    const fillPlan = await ctx.images.shotPlan(req.user.studioId, fillIds, [], 1, undefined, stepModels);
    const cost = missing.length ? missing.length * fillPlan.perShot : 0;
    const bill = await new PhotoBill(ctx, whoOf(req.user), `sheet_${uid('f')}`, cost, `Character sheet · ${missing.length} angle${missing.length === 1 ? '' : 's'}`).start();
    const slots = m.slots.map(s => (missing.includes(s) ? { ...s, busy: true } : s));
    const [u] = await db.update(models).set({ slots }).where(eq(models.id, m.id)).returning();
    emitModel(u!);
    const user = req.user;
    void (async () => {
      const identity = await identityOf(u!, sentOf(fillIds, fillPlan));
      const texts = await ctx.prompts.texts(user.studioId);
      const refs = fillPlan.images, panels = fillPlan.panels;
      const filled: Record<string, ImageRef | null> = {};
      let failed = 0;
      for (const s of missing) {
        try {
          const r = await ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'sheet', refId: m.id, refs, maxImages: refs.length, panels, bill, models: stepModels,
            req: { prompt: characterSheetShot(identity, sheetAngle(s.key)!, texts).text, width: 768, height: 1024, count: 1, simAssets: [SLOT_SAMPLE[s.key] ?? 'face'] } });
          filled[s.key] = r.images[0]!;
        } catch { filled[s.key] = null; failed++; }
      }
      // Settles to the angles that worked (the ones that failed cost nothing).
      await bill.finish();
      const [cur] = await db.select().from(models).where(eq(models.id, m.id));
      if (!cur) return;
      const curSlots = SLOT_KEYS.map(k => cur.slots.find(s => s.key === k) ?? { key: k, image: null, source: 'upload' as const, busy: false });
      const next: SheetSlot[] = curSlots.map(s => (s.key in filled ? (filled[s.key] ? { ...s, busy: false, image: filled[s.key]!, source: 'generated' } : { ...s, busy: false }) : s));
      const [v] = await db.update(models).set({ slots: next }).where(eq(models.id, m.id)).returning();
      emitModel(v!);
    })().catch(e => ctx.log.error({ err: (e as Error).message }, 'fill angles failed'));
    return { model: modelView(u!), cost };
  });

  // ------------------------------------------------------------------ outfits
  app.get('/v1/outfits', async req => {
    // Outfits of archived models are left out with them.
    const hidden = new Set((await db.select({ id: models.id }).from(models).where(and(eq(models.studioId, req.user.studioId), isNotNull(models.archivedAt)))).map(x => x.id));
    return (await db.select().from(outfits).where(eq(outfits.studioId, req.user.studioId)).orderBy(outfits.createdAt)).filter(o => !hidden.has(o.modelId)).map(outfitView);
  });
  app.post('/v1/outfits', async req => {
    const b = parse(z.object({ modelId: z.string(), name: z.string().max(80).optional(), mode: z.enum(['describe', 'photo', 'own']).optional(),
      description: z.string().max(1000).optional(), images: z.array(ImageRefSchema).max(4).optional(), imageEngine: ImageEngineOverride.optional() }).passthrough(), req.body);
    const m = await model(req.user, b.modelId, true);
    const stepModels = await modelChoice(ctx).imageOverrides(req.user, 'outfit', b); // WS13: `imageModel`, else the Outfits default
    const mode = b.mode ?? 'describe';
    const id = uid('o');
    const slotOf = (k: string) => m.slots.find(x => x.key === k)?.image;
    /** Her body photo of one angle for the ¾/side/back edits; none (only the front is sent already) when it's missing. */
    const angleBody = (k: string) => { const img = slotOf(k); return img && img !== slotOf('front') ? img : null; };
    // Her identity images (face, face ¾, one body image), then the product photos. Each outfit picture gets the body
    // photo of ITS angle (front→front, ¾→tq, side→side, back→back; a missing one falls back to the front), so her
    // figure matches from every side (plans/outfit-head-looks.md §1, owner 2026-11-11).
    const productIds = ((b.images ?? []) as ImageRef[]).filter(i => i && (i.asset || i.url)).map(image => ({ image, label: 'outfit photo', role: 'product' as const }));
    const angleIds = await Promise.all(BODY_SLOTS.map(slot => idRefs(req.user.studioId, { ...m, identityBodySlot: slot }, null, { extra: productIds })));
    const outfitIds = angleIds[0]!;
    // Planned like a shoot's images: within the shot model's limit, the face front never dropped.
    const anglePlans = mode === 'own' ? null : await Promise.all(angleIds.map(ids => ctx.images.shotPlan(req.user.studioId, ids, [], 1, b.imageEngine, stepModels)));
    const outfitPlan = anglePlans?.[0] ?? null;
    const outfitRefs = outfitPlan?.images ?? [], outfitPanels = outfitPlan?.panels ?? [];
    // A custom model makes all four angles as new shots (no edits); else a front shot and three edits of it.
    const byoRun = !b.imageEngine?.provider && !!stepModels?.shot?.startsWith('c_');
    const cost = !outfitPlan ? 0 : byoRun ? 4 * outfitPlan.perShot : outfitPlan.perShot + 3 * await ctx.images.editCost(req.user.studioId, stepModels);
    const bill = await new PhotoBill(ctx, whoOf(req.user), id, cost, 'Outfit set').start();
    const identity = await identityOf(m, outfitPlan ? sentOf(outfitIds, outfitPlan) : personCount(outfitIds));
    const spec = { name: b.name || 'New outfit', description: b.description, source: mode === 'describe' ? 'described' as const : mode === 'photo' ? 'product-photo' as const : 'reference-set' as const };
    const texts = await ctx.prompts.texts(req.user.studioId);
    const set = outfitSet(identity, spec, undefined, texts);
    const [o] = await db.insert(outfits).values({ id, studioId: req.user.studioId, modelId: m.id, name: spec.name, mode, description: b.description ?? '',
      angles: [null, null, null, null], state: 'generating', prompt: set[0]!.text, seed: set[0]!.seed ?? null, createdBy: req.user.id, createdAt: Date.now() }).returning();
    emitOutfit(o!);
    const user = req.user;
    ctx.later(async () => {
      let angles: (ImageRef | null)[];
      if (mode === 'own' && b.images?.length) angles = [0, 1, 2, 3].map(i => (b.images![i] as ImageRef) ?? null);
      else {
        try {
          // Most important first: face, face ¾, one body image, the product photos.
          const slot = slotOf;
          const refs = outfitRefs;
          const sel = await ctx.images.selection(user.studioId, b.imageEngine, stepModels);
          if (sel.provider === 'simulated') {
            angles = (await ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'outfit', refId: id, override: b.imageEngine, models: stepModels, refs, maxImages: refs.length, panels: outfitPanels, bill,
              req: { prompt: set[0]!.text, width: 768, height: 1024, count: 4, seed: set[0]!.seed ?? undefined, simAssets: ['c_front', 'c_tq', 'c_face', 'c_front'] } })).images;
          } else if (sel.provider === 'replicate') {
            // A new front shot, then the ¾, side and back as edits of it, so all four show the same clothes.
            const front = (await ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'outfit', refId: id, override: b.imageEngine, models: stepModels, refs, maxImages: refs.length, panels: outfitPanels, bill,
              req: { prompt: set[0]!.text, width: 768, height: 1024, count: 1, seed: set[0]!.seed ?? undefined } })).images[0]!;
            angles = [front];
            for (const [i, a] of OUTFIT_ANGLES.slice(1).entries()) {
              // Her face, then her own body photo from this angle: the edit takes her figure from it, never its clothes.
              const body = angleBody(BODY_SLOTS[i + 1]!);
              const prompt = outfitEditPrompt(a, texts) + (body ? ' The last image shows her figure from this angle: match her body shape and proportions only, not its clothes or background.' : '');
              angles.push((await ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'outfit', refId: id, override: b.imageEngine, models: stepModels, bill,
                editOf: front, refs: [slot('face'), body].filter((r): r is ImageRef => !!r), req: { prompt, width: 768, height: 1024, count: 1, seed: set[0]!.seed ?? undefined } })).images[0]!);
            }
          } else {
            // New shots (a custom model): each angle with her body photo of that angle.
            angles = await Promise.all(set.map((p, i) => {
              const plan = anglePlans?.[i] ?? outfitPlan!;
              return ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'outfit', refId: id, override: b.imageEngine, models: stepModels, refs: plan.images, maxImages: plan.images.length, panels: plan.panels, bill,
                req: { prompt: p.text, width: 768, height: 1024, count: 1, seed: p.seed ?? undefined } }).then(r => r.images[0]!);
            }));
          }
        } catch (e) {
          await bill.fail();
          const [f] = await db.update(outfits).set({ state: 'preview', angles: [null, null, null, null] }).where(eq(outfits.id, id)).returning();
          if (f) emitOutfit(f);
          return;
        }
      }
      await bill.finish();
      const [u] = await db.update(outfits).set({ angles, state: 'preview', cost: bill.spent }).where(and(eq(outfits.id, id), eq(outfits.state, 'generating'))).returning();
      if (u) emitOutfit(u);
    }, mode === 'own' ? 300 : 0);
    return outfitView(o!);
  });
  app.post<{ Params: { id: string } }>('/v1/outfits/:id/save', async req => {
    const [o] = await db.select().from(outfits).where(and(eq(outfits.id, req.params.id), eq(outfits.studioId, req.user.studioId)));
    if (!o) throw notFound('Outfit');
    const m = await model(req.user, o.modelId);
    const [u] = await db.update(outfits).set({ state: 'ready' }).where(eq(outfits.id, o.id)).returning();
    emitOutfit(u!);
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
    // Prompt scripts: classify the clip's audio (free, well under a second); the answer comes with the clip. If it takes
    // longer than 8 s it finishes in the background and a second clip event carries `audio`.
    let late = false;
    const analysed = storageKey ? analyzeClip(ctx, id, row => { if (late) ctx.hub.emit(u.studioId, { type: 'clip', clip: clipView(row) }); }) : null;
    const row = analysed && (await Promise.race([analysed.then(() => true), new Promise<false>(r => setTimeout(() => r(false), 8000).unref())]))
      ? (await db.select().from(clips).where(eq(clips.id, id)))[0] ?? c! : c!;
    late = true;
    ctx.hub.emit(u.studioId, { type: 'clip', clip: clipView(row) });
    return clipView(row);
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
    // Every prefix the server writes and links as /uploads/<key>: s/ suite takes, cam/ camera-session stills, claude/ chat frames.
    if (!/^(u|c|g|r|l|t|s|cam|claude|assets)\/[A-Za-z0-9._\/-]+$/.test(key) || key.includes('..')) throw notFound('Upload');
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
  app.delete<{ Params: { id: string } }>('/v1/jobs/:id', async (req, reply) => {
    await ctx.jobs.remove(req.user, req.params.id);
    ctx.hub.emit(req.user.studioId, { type: 'job', op: 'delete', id: req.params.id });
    return reply.status(204).send();
  });
  app.post('/v1/queue/run', async req => ctx.jobs.runQueue(req.user));

  app.get('/v1/takes', async req => (await db.select().from(takes).where(eq(takes.studioId, req.user.studioId)).orderBy(desc(takes.createdAt))).map(t => takeView(t, pub, req.user.id)));
  app.patch<{ Params: { id: string } }>('/v1/takes/:id', async req => {
    const b = (req.body ?? {}) as { status?: string };
    const [t] = await db.select().from(takes).where(and(eq(takes.id, req.params.id), eq(takes.studioId, req.user.studioId)));
    if (!t) throw notFound('Take');
    if (b.status !== 'test' && b.status !== 'final') throw badRequest('status must be test or final');
    const [u] = await db.update(takes).set({ status: b.status }).where(eq(takes.id, t.id)).returning();
    emitTakes(u!.studioId, [u!]);
    return takeView(u!, pub, req.user.id);
  });
  // Upscale a finished render (plans/api.md "App clean-up" §2): SeedVR2 on the add-on GPU, priced per output second
  // (UPSCALE_PRICES, measured). A job like any add-on render: held, queued for a pod, settled at the quoted price.
  app.post<{ Params: { id: string } }>('/v1/takes/:id/upscale', async req => {
    const b = parse(z.object({ size: z.enum(P.UPSCALE_SIZES.map(x => x.id) as [P.UpscaleSize, ...P.UpscaleSize[]]), engineModel: z.string().max(40).optional() }), req.body);
    if (b.engineModel) await modelChoice(ctx).check(req.user, 'upscale', b.engineModel); // WS13: today only SeedVR2
    const [t] = await db.select().from(takes).where(and(eq(takes.id, req.params.id), eq(takes.studioId, req.user.studioId)));
    if (!t) throw notFound('Take');
    if (t.kind !== 'take') throw badRequest('Upscale works on a finished video take');
    const up = ctx.jobs.features().video.addons.find(a => a.id === 'upscale') as { sizes?: { id: string; available: boolean }[] } | undefined;
    const size = up?.sizes?.find(x => x.id === b.size);
    const price = P.upscalePrices(ctx.config.UPSCALE_PRICES)[b.size];
    if (!size?.available || !price) throw new ApiError(409, 'upscale_unavailable', 'Upscale is coming soon');
    if (!t.mediaKey) throw badRequest('This take has no video file to upscale');
    const seconds = Math.round((Number(t.media?.durationSec) || 0) * 1000) / 1000;
    if (!(seconds > 0)) throw badRequest('This take has no length on record · it can’t be upscaled');
    const request = { ...P.upscaleRequest(b.size, seconds, price), takeId: t.id, sourceKey: t.mediaKey };
    const job = await ctx.jobs.createInternal(req.user, {
      kind: 'render', title: `${t.title} · ${P.upscaleLabel(b.size)}`, modelId: t.modelId ?? '', modelName: '', outfitId: '', request,
      cost: request.usd, prompt: t.prompt ?? '', seed: t.seed, thumb: t.thumb ?? null, totalSeconds: P.totalSeconds(request), totalSteps: 1, phase: 'Queued',
    });
    return ctx.jobs.view(job);
  });
  app.delete<{ Params: { id: string } }>('/v1/takes/:id', async (req, reply) => {
    const gone = await db.delete(takes).where(and(eq(takes.id, req.params.id), eq(takes.studioId, req.user.studioId))).returning({ id: takes.id });
    if (gone.length) ctx.hub.emit(req.user.studioId, { type: 'take', op: 'delete', id: req.params.id });
    return reply.status(204).send();
  });

  const ImageEngineOverride = z.object({ provider: z.enum(PROVIDERS), model: z.string().optional(), url: z.string().url().optional() });
  const outfitOf = async (u: AuthUser, id?: string) => {
    if (!id) return undefined;
    const [o] = await db.select().from(outfits).where(and(eq(outfits.id, id), eq(outfits.studioId, u.studioId)));
    return o;
  };
  const outfitSpec = (o?: typeof outfits.$inferSelect) => o ? { name: o.name, description: o.description, source: o.mode === 'describe' && !o.angles.some(Boolean) ? 'described' as const : 'reference-set' as const } : null;
  /** Her images for a shot (plans/api.md "Identity images"): face, face ¾, one body image, the outfit's front, a product photo. */
  const shootRefs = (u: AuthUser, m: typeof models.$inferSelect, o?: typeof outfits.$inferSelect, product?: ImageRef | null) =>
    idRefs(u.studioId, m, o, { outfit: !!o, extra: product ? [{ image: product, label: 'product', role: 'product' }] : [] });

  // Photoshoots (plans/api.md "Shoot references and the prompt library"): the server builds the prompt from the choices
  // and the studio's prompt library, unless "Edit as text" sends `prompt`.
  const ShootRefBody = z.object({ image: ImageRefSchema, guides: z.array(z.enum(['pose', 'look', 'scene'])).min(1).max(3) })
    .refine(r => !!(r.image.asset || r.image.url), { message: 'each reference needs an image' })
    .refine(r => new Set(r.guides).size === r.guides.length, { message: 'guides must not repeat' });
  const ShootBody = z.object({ modelId: z.string(), outfitId: z.string().optional(), scene: z.string().max(200).optional(), prompt: z.string().max(4000).optional(),
    seed: z.number().int().nullable().optional(), count: z.number().int().optional(), direction: z.string().max(500).optional(), lockSeed: z.boolean().optional(),
    presets: z.boolean().optional(), camera: z.object({ shot: z.string().min(1).max(20), lens: z.number().int().min(8).max(400), aperture: z.string().min(1).max(10) }).optional(),
    light: z.string().max(80).optional(), grade: z.string().max(80).optional(), refs: z.array(ShootRefBody).max(3).optional(),
    templateId: z.string().optional(), shuffleSeed: z.number().int().min(0).optional(), productImage: z.object({ asset: z.string().optional(), url: z.string().optional() }).optional(),
    imageEngine: ImageEngineOverride.optional() }).passthrough();

  /** Everything a shoot (or its preview) needs: the model, outfit, images to send, the prompt and the estimate. */
  async function planShoot(u: AuthUser, body: unknown, still?: StillRig, engine?: EngineSelection, models?: StepOverrides) {
    const b = parse(ShootBody, body);
    if (engine) (b as { imageEngine?: unknown }).imageEngine = engine; // WS5: a custom image model (checked by the caller)
    const m = await model(u, b.modelId, true);
    const o = await outfitOf(u, b.outfitId);
    const count = Math.min(4, Math.max(1, b.count ?? 4));
    const stepModels = models ?? ctx.imageModels.overridesFrom(u.role, b as { models?: unknown }); // WS13: `models` = already checked
    const texts = await ctx.prompts.texts(u.studioId);
    const refsIn = (b.refs ?? []) as ShootRefIn[];
    if (b.templateId) {
      const t = await ctx.templates.visible(u, b.templateId);
      const product = t.layers.product && (b.productImage?.asset || b.productImage?.url) ? b.productImage as ImageRef : null;
      const ids = await shootRefs(u, m, o, product);
      const plan = await ctx.images.shotPlan(u.studioId, ids, refsIn, 2, b.imageEngine, stepModels);
      const identity = await identityOf(m, sentOf(ids, plan));
      return { kind: 'template' as const, b, m, o, count, stepModels, texts, refsIn, identity, plan, t, product };
    }
    // A custom (provider) model that takes many images gets her whole sheet (up to 7 views; references keep their room), not
    // the default 3; a per-run price, so more images cost nothing more.
    const cap = (await ctx.images.shotInputs(u.studioId, b.imageEngine, stepModels)).capacity;
    const wide = (b.imageEngine as { provider?: string } | undefined)?.provider === 'byo' && cap >= 6 ? Math.min(7, Math.max(await ctx.images.identityCount(u.studioId), cap - refsIn.length)) : undefined;
    const ids = wide ? await idRefs(u.studioId, m, o, { outfit: !!o, count: wide }) : await shootRefs(u, m, o);
    const plan = await ctx.images.shotPlan(u.studioId, ids, refsIn, 2, b.imageEngine, stepModels);
    const identity = await identityOf(m, sentOf(ids, plan));
    const spec = { identity, outfit: outfitSpec(o) ?? { name: 'outfit' }, scene: b.scene, light: b.light, grade: b.grade, direction: b.direction, lockSeed: b.lockSeed,
      presets: b.presets, refs: plan.sent, camera: b.camera ? { shot: b.camera.shot, lensMm: b.camera.lens, aperture: b.camera.aperture } : undefined,
      // AI suite Photo tool (workstream 3): the composer's rig compiled for a still (suite/photo.ts) in place of the shoot pickers.
      ...(still ? { scene: still.scene, light: still.light, grade: still.grade, direction: still.direction, camera: still.camera } : {}) };
    const built = photoshoot(spec, texts);
    const custom = b.prompt?.trim() || null;
    return { kind: 'plain' as const, b, m, o, count, stepModels, texts, refsIn, identity, plan, spec, built, custom };
  }
  const previewRefs = (plan: { images: ImageRef[]; refs: unknown[]; sheet: boolean }) => ({ images: plan.images.length, refs: plan.refs, referenceSheet: plan.sheet });
  /** On a one-image model the prompt starts with the reference-sheet line (as runModel sends it). */
  const withSheet = (s: { plan: { sheet: boolean; panels: Parameters<typeof collageLine>[0] }; texts: Parameters<typeof collageLine>[1] }, text: string) =>
    s.plan.sheet ? [collageLine(s.plan.panels, s.texts), text].filter(x => x.trim()).join('\n') : text;
  const sheetSlot = (s: Parameters<typeof withSheet>[0]) => (s.plan.sheet ? [{ layer: 'sheet', text: collageLine(s.plan.panels, s.texts) }] : []);

  app.post('/v1/shoots/preview', async req => {
    const s = await planShoot(req.user, req.body);
    const estimate = s.count * s.plan.perShot;
    const money = { estimate, estimateLabel: P.aboutMoney(estimate) };
    if (s.kind === 'template') {
      const v = await ctx.templates.preview(req.user, s.t.id, { ...(req.body as object), modelId: s.m.id }, async () => ({ identity: s.identity, outfit: outfitSpec(s.o) }), { refs: s.plan.sent });
      const vv = v as { text?: string; slots?: unknown[] };
      return { ...v, ...(s.plan.sheet && typeof vv.text === 'string' ? { text: withSheet(s, vv.text), slots: [...sheetSlot(s), ...(vv.slots ?? [])] } : {}),
        removed: (v as any).removed ?? [], ...previewRefs(s.plan), ...money, edited: false };
    }
    if (s.custom) return { slots: [...sheetSlot(s), { layer: 'custom', text: s.custom }], text: withSheet(s, s.custom), seed: s.b.seed ?? s.built.seed, removed: [], ...previewRefs(s.plan), ...money, edited: true };
    return { slots: [...sheetSlot(s), ...s.built.slots.map(x => ({ layer: x.layer, text: x.text }))], text: withSheet(s, s.built.text), seed: s.built.seed, removed: s.built.removed, ...previewRefs(s.plan), ...money, edited: false };
  });

  app.post('/v1/shoots', async req => {
    const s = await planShoot(req.user, req.body);
    const filter = photoLook((req.body as { filter?: unknown } | null)?.filter); // Editor v2 look on the stills (workstream 3)
    return runShoot(req, s, filter);
  });

  /** Runs a planned shoot: holds, generates, grades and saves the stills (`/v1/shoots` and the suite's Photo tool). */
  /** `started`: called once the price is held (the photo job then runs on its own); `made`: each still done (template shoots). */
  type ShootHooks = { noun?: string; draft?: Draft | null; started?: () => void; made?: (n: number, of: number) => void };
  async function runShoot(req: { user: AuthUser }, s: Awaited<ReturnType<typeof planShoot>>, filter?: Look, o2: ShootHooks = {}) {
    const noun = o2.noun ?? 'Photo', billNoun = o2.noun ?? 'Photo'; // Photoshoot is gone: legacy /v1/shoots takes are "Photo" too
    if (s.kind === 'template') return templateShoot(req.user, s, filter, noun, billNoun, o2.draft, o2);
    const { b, m, o, count, plan } = s;
    const id = uid('shoot');
    const bill = await new PhotoBill(ctx, whoOf(req.user), id, count * plan.perShot, `${billNoun} · ${count} photo${count === 1 ? '' : 's'}`).start();
    o2.started?.();
    const prompt = s.custom ?? s.built.text;
    const seed = b.seed ?? s.built.seed ?? undefined;
    let r;
    try {
      r = await ctx.images.generate({ studioId: req.user.studioId, userId: req.user.id, purpose: 'shoot', refId: id, override: b.imageEngine, refs: plan.images, maxImages: plan.images.length, panels: plan.panels,
        bill, models: s.stepModels, req: { prompt, width: 1080, height: 1920, count, seed, simAssets: [o?.angles?.[0]?.asset ?? 'g_front', 'c_face', 'face', 'g_tq'] } });
    } catch (e) {
      await bill.fail();
      throw e;
    }
    await bill.finish();
    if (filter) r.images = await Promise.all(r.images.map(async img => (await ctx.templates.postProcess(img, { afterEffects: { look: filter } }, { studioId: req.user.studioId, userId: req.user.id })).ref));
    const ch = shootChoices(s.spec, s.texts);
    const label = (b.scene?.trim() || ch.scene).split(' · ')[0]!.slice(0, 28);
    const cv = cameraValues(ch.camera, s.texts);
    // The shot's own layers (for "Save as template"), from the choices rather than the (owner-editable) prompt wording.
    const layers = b.presets === false ? {} : { scene: ch.scene.toLowerCase(), camera: `${cv.shot} shot, ${cv.lens}mm lens, ${cv.aperture}${cv.lensNote}`, light: `${ch.light.toLowerCase()}; grade: ${ch.grade.toLowerCase()}` };
    const rows = r.images.map((img, n) => ({
      id: uid('s'), studioId: req.user.studioId, userId: req.user.id, kind: 'shot' as const, jobId: null, modelId: m.id, index: n + 1, of: r.images.length,
      title: `${noun} · ${label}`, label: `${label} · ${n + 1}`, engineLabel: ctx.images.shotLabel(r.selection), cost: r.costs[n] ?? 0, seed: r.seed ?? seed ?? 0, status: 'test' as const,
      thumb: img, prompt, mediaKey: ctx.images.keyOf(img), layers, refs: s.refsIn.length ? s.refsIn : null, createdAt: Date.now() + n, draft: o2.draft ?? null,
    }));
    const inserted = await db.insert(takes).values(rows).returning();
    emitTakes(req.user.studioId, inserted);
    return inserted.map(t => takeView(t, pub, req.user.id));
  }

  /**
   * A template shoot: every still gets its own prompt (template layers + identity/outfit/never-add + its own variation
   * draws, or the user's direction in place of pose and angle), its own seed, and the template's after-effects.
   */
  async function templateShoot(u: AuthUser, s: Extract<Awaited<ReturnType<typeof planShoot>>, { kind: 'template' }>, filter?: Look, noun = 'Photo', billNoun = 'Photo', draft: Draft | null = null, hooks: ShootHooks = {}) {
    const { b, m, o, count, plan, identity, product } = s;
    // A `filter` on the request replaces the template's own look for these stills.
    const t = filter ? { ...s.t, layers: { ...s.t.layers, afterEffects: { ...(s.t.layers.afterEffects ?? {}), look: filter } } } : s.t;
    const shuffleSeed = b.shuffleSeed ?? randomSeed();
    const id = uid('shoot');
    const bill = await new PhotoBill(ctx, whoOf(u), id, count * plan.perShot, `${billNoun} · ${count} photo${count === 1 ? '' : 's'}`).start();
    hooks.started?.();
    const now = Date.now();
    const rows: (typeof takes.$inferInsert)[] = [];
    try {
      for (let n = 0; n < count; n++) {
        const p = buildTemplatePrompt({ templateId: t.id, templateName: t.name, layers: t.layers, pool: t.variationPool, identity, outfit: outfitSpec(o),
          direction: b.direction, shuffleSeed, index: n, lockSeed: b.lockSeed, seed: randomImageSeed(), hasProduct: !!product, refs: plan.sent }, s.texts);
        const sim = [o?.angles?.[0]?.asset ?? 'g_front', 'c_face', 'face', 'g_tq'];
        const r = await ctx.images.generate({ studioId: u.studioId, userId: u.id, purpose: 'shoot', refId: id, override: b.imageEngine, refs: plan.images, maxImages: plan.images.length, panels: plan.panels,
          bill, models: s.stepModels, req: { prompt: p.fullText, width: 1080, height: 1920, count: 1, seed: p.seed ?? undefined, simAssets: [sim[n % sim.length]!] } });
        const fx = await ctx.templates.postProcess(r.images[0]!, t.layers, { studioId: u.studioId, userId: u.id });
        rows.push({
          id: uid('s'), studioId: u.studioId, userId: u.id, kind: 'shot', jobId: null, modelId: m.id, index: n + 1, of: count,
          title: `${noun} · ${t.name}`.slice(0, 60), label: `${t.name.slice(0, 28)} · ${n + 1}`, engineLabel: ctx.images.shotLabel(r.selection), cost: r.costUsd,
          seed: p.seed ?? r.seed ?? 0, status: 'test', thumb: fx.ref, prompt: p.fullText, publicPrompt: p.visibleText, mediaKey: fx.key,
          layers: t.layers, templateId: t.id, templateName: t.name, templateOwnerId: t.ownerId, variation: p.variation, shuffleSeed, refs: s.refsIn.length ? s.refsIn : null, createdAt: now + n, draft,
        });
        if (n + 1 < count) hooks.made?.(n + 1, count);
      }
    } catch (e) {
      await bill.fail();
      throw e;
    }
    await bill.finish();
    const inserted = await db.insert(takes).values(rows).returning();
    emitTakes(u.studioId, inserted);
    await ctx.templates.bumpUses(t.id);
    return inserted.map(x => takeView(x, pub, u.id));
  }

  // ------------------------------------------------------------------ AI suite · Photo tool (workstream 3)
  // Photoshoot on the composer (plans/api.md "Photo tool"): the shoot pipeline above with the composer's rig compiled for
  // a still (suite/photo.ts). Same count, pricing and bill as a shoot; `/v1/shoots` stays for older clients.
  const photoPlan = async (u: AuthUser, body: unknown) => {
    const r = PhotoRequestSchema.safeParse(body ?? {});
    if (!r.success) throw badRequest(`Invalid photo: ${r.error.issues[0]?.path.join('.')} ${r.error.issues[0]?.message}`);
    const p = r.data, still = stillRig(p), graded = photoFilter(p);
    // References Claude added to the composer's draft (suite_add_reference) count too, after the ones sent (max 3).
    const fromDraft = referencesOf((draftOf(body) ?? {}) as Draft).map(r => ({ image: { url: r.url }, guides: [r.use === 'pose' ? 'pose' : r.use === 'location' ? 'scene' : 'look'] as ('pose' | 'look' | 'scene')[] }));
    const refsAll = [...(p.references ?? []), ...fromDraft.filter(d => !(p.references ?? []).some(x => x.image?.url === d.image.url))].slice(0, 3);
    const shoot = { modelId: p.modelId, outfitId: p.outfitId, count: p.count, seed: p.seed, lockSeed: p.lockSeed, refs: refsAll.length ? refsAll : undefined, templateId: p.presetId,
      shuffleSeed: p.shuffleSeed, productImage: p.productImage, presets: true };
    // WS5: a custom image model the user may use replaces the studio's image engine for this run.
    // `imageModel` picks the image model for this run (a Replicate "owner/name" or a custom "c_…"): the owner any; 4c: a
    // member any model shown to members (checked, 403 otherwise).
    if (p.imageModel && p.engineModel) throw badRequest('Use imageModel or engineModel, not both');
    if (p.imageModel && u.role !== 'owner') await modelChoice(ctx).check(u, 'photo', p.imageModel);
    // WS13: nothing picked → the studio's Photo default (a Replicate model or a custom one), if it is still available.
    const imageModel = p.imageModel ?? (p.engineModel ? undefined : (await modelChoice(ctx).choose(u, 'photo'))?.model);
    const custom = p.engineModel ?? (imageModel?.startsWith('c_') ? imageModel : undefined);
    const engine = custom ? (await ctx.suite.byo.checkUse(u, custom, 'image'), { provider: 'byo' as const, model: custom }) : undefined;
    if (imageModel && !custom && !MODEL_ID_RE.test(imageModel)) throw badRequest('imageModel: use owner/name or a custom model id');
    // Priced and run on that model (planShoot); passed as checked step models so a member can run on the studio default.
    const s = await planShoot(u, shoot, p.presetId ? undefined : still, engine, imageModel && !custom ? { shot: imageModel } : undefined);
    const notes = [...still.notes, ...(p.presetId && (still.camera || still.light || still.grade || still.direction) ? ['The preset sets its own camera and light'] : [])];
    return { p, s, notes, graded };
  };
  app.post('/v1/suite/photos/estimate', async req => {
    const { p, s, notes, graded } = await photoPlan(req.user, req.body);
    const estimate = s.count * s.plan.perShot, money = P.aboutMoney(estimate);
    return { tool: 'photo', count: s.count, perPhoto: s.plan.perShot, estimate, priceLine: `${money} · ${s.count} photo${s.count === 1 ? '' : 's'}`,
      buttonLabel: photoButton(s.count, P.money(estimate)), ok: true, warnings: notes, rig: photoRigCheck(p), look: graded?.look ?? null,
      ...(s.kind === 'template' ? { preset: { id: s.t.id, name: s.t.name } } : { prompt: s.custom ?? s.built.text }) };
  });
  // Every photo run is a job (WS19): a `render` row with request.engine 'photo', so the Queue, the hub and the Suite's
  // stage show it while it runs, like a video. The stills stay jobless takes (the Library's as before); the job lists
  // their ids. `async: true` (the Mac app) answers with the running job once the price is held; without it the call
  // waits and answers with the takes, as before, plus the job.
  const photoPhase = (count: number, made = 0) => count > 1 ? `Making photo ${made + 1} of ${count}` : 'Making your photo';
  // A restart drops the run: photo jobs still running from before it end as failed (their bill was never finished).
  void db.update(jobs).set({ state: 'failed', error: 'Interrupted · try again', phase: 'Failed', finishedAt: Date.now() })
    .where(and(eq(jobs.state, 'running'), sql`${jobs.request}->>'engine' = 'photo'`)).catch(() => {});
  app.post('/v1/suite/photos', async req => {
    const draft = draftOf(req.body); // AI suite (workstream 1): every still keeps the composer draft ("Reuse settings")
    const { async: background, ...body } = (req.body ?? {}) as Record<string, unknown>;
    const wait = background !== true;
    const { s, graded } = await photoPlan(req.user, body);
    const u = req.user, count = s.count, cost = count * s.plan.perShot, now = Date.now();
    const row: typeof jobs.$inferInsert = {
      id: uid('j'), studioId: u.studioId, userId: u.id, kind: 'render', title: `Photo · ${count} photo${count === 1 ? '' : 's'}`, modelId: s.m.id, modelName: s.m.name,
      outfitId: s.o?.id ?? '', request: { engine: 'photo', tool: 'photo', takes: count, count, engineLabel: 'Photo' }, state: 'running', progress: 2,
      take: 1, totalSteps: count, phase: photoPhase(count), cost, prompt: s.kind === 'template' ? s.t.name : (s.custom ?? s.built.text), seed: 0,
      thumb: s.o?.angles?.[0] ?? s.m.slots[0]?.image ?? null, createdAt: now, startedAt: now, ...(draft ? { draft } : {}),
    };
    const set = async (f: Partial<typeof jobs.$inferInsert>, extra: Record<string, unknown> = {}) => {
      const [j] = await db.update(jobs).set(f).where(and(eq(jobs.id, row.id!), eq(jobs.state, 'running'))).returning();
      if (j) ctx.jobs.emitJob(j, extra);
      return j ?? (await ctx.jobs.get(row.id!));
    };
    let held!: () => void;
    const holding = new Promise<void>(r => { held = r; });
    const run = runShoot(req, s, graded?.filter, { noun: 'Photo', draft, started: () => held(),
      made: (n, of) => { void set({ progress: Math.round((n / of) * 100), take: n + 1, step: n, phase: photoPhase(of, n) }); } });
    await Promise.race([holding, run]); // the bill refused: nothing was held and no job is made (the error goes back)
    const [j0] = await db.insert(jobs).values(row).returning();
    ctx.jobs.emitJob(j0!);
    const finished = run.then(async out => {
      const j = await set({ state: 'done', progress: 100, step: count, phase: 'Done', finishedAt: Date.now(), thumb: out[0]?.thumb ?? row.thumb,
        stats: { photo: { takeIds: out.map(t => t.id) } } }, { takes: out });
      return { out, j };
    }, async e => {
      await set({ state: 'failed', error: String((e as Error)?.message ?? '').slice(0, 200) || 'It didn’t finish', refunded: cost, phase: 'Failed', finishedAt: Date.now() });
      throw e;
    });
    if (!wait) {
      finished.catch(() => {}); // the job carries the failure
      return { tool: 'photo', takes: [], job: ctx.jobs.view(j0!) };
    }
    const { out, j } = await finished;
    return { tool: 'photo', takes: out, job: j ? ctx.jobs.view(j) : undefined };
  });

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
    const m = await model(req.user, modelId), o = await outfitOf(req.user, outfitId);
    return { identity: await identityOf(m, personCount(await shootRefs(req.user, m, o))), outfit: outfitSpec(o) };
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
    ctx.hub.emit(m.studioId, { type: 'account', op: 'delete', modelId: m.id, platform: platformOf(req.params.platform) });
    return reply.status(204).send();
  });
  app.get('/v1/posts', async req => { const q = req.query as { state?: string; modelId?: string }; return ctx.posts.list(req.user.studioId, q.state || undefined, q.modelId || undefined); });
  app.post('/v1/posts', async req => ctx.posts.create(req.user, req.body));
  app.delete<{ Params: { id: string } }>('/v1/posts/:id', async (req, reply) => { await ctx.posts.remove(req.user, req.params.id); return reply.status(204).send(); });

  // ------------------------------------------------------------------ money
  app.get('/v1/balance', async req => ctx.money.balanceView(whoOf(req.user)));
  // The owner-loaded studio balance (plans/api.md "App clean-up" §4).
  const TopUpBody = z.object({ amountUsd: z.number().positive().max(10_000), note: z.string().max(200).nullish(), paidAt: z.number().int().positive().nullish() });
  const topUp = async (u: AuthUser, body: unknown) => {
    const b = parse(TopUpBody, body);
    if (b.paidAt != null && b.paidAt > Date.now() + 60_000) throw badRequest("paidAt can't be in the future");
    if (Math.round(b.amountUsd * 100) <= 0) throw badRequest('Amount must be at least $0.01');
    await ctx.money.recordTopUp(whoOf(u), { amountUsd: b.amountUsd, note: b.note ?? null, at: b.paidAt ?? undefined });
  };
  app.get('/v1/studio/balance', { config: { owner: true } }, async req => ctx.money.studioBalanceView(req.user.studioId));
  app.post('/v1/studio/topups', { config: { owner: true } }, async req => { await topUp(req.user, req.body); return ctx.money.studioBalanceView(req.user.studioId); });
  app.get('/v1/studio/topups', { config: { owner: true } }, async req => ctx.money.topUps(req.user.studioId, Number((req.query as any)?.limit) || 50));
  app.post('/v1/balance/topup', async req => {
    if (req.user.role !== 'owner') throw new ApiError(403, 'owner_only', 'Ask the studio owner for credit');
    const b = (req.body ?? {}) as { amount?: number; note?: string };
    await topUp(req.user, { amountUsd: b.amount, note: b.note });
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

  const memberView = (studioId: string, id: string) => ctx.money.memberView(studioId, id);
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
    const mv = await memberView(req.user.studioId, u.id);
    ctx.hub.emitOwners(req.user.studioId, { type: 'member', member: mv });
    // Their caps changed: their own Credits card (perJobLimit, perDayLimit) follows.
    void ctx.money.notify(req.user.studioId, [u.id]);
    return mv;
  });
  app.get('/v1/ledger', { config: { owner: true } }, async req => {
    const q = req.query as { limit?: string; userId?: string };
    const conds = [eq(ledger.studioId, req.user.studioId)];
    if (q.userId) conds.push(eq(ledger.userId, q.userId));
    return db.select().from(ledger).where(and(...conds)).orderBy(desc(ledger.id)).limit(Math.min(500, Number(q.limit) || 100));
  });

  // ------------------------------------------------------------------ model tools (plans/api.md "Model tools")
  const stepParam = (v: string): ImageStep => { if (!(IMAGE_STEPS as readonly string[]).includes(v)) throw notFound('Step'); return v as ImageStep; };
  const catalogCall = async <T>(fn: () => Promise<T>): Promise<T> => {
    try { return await fn(); }
    catch (e) {
      if (e instanceof CatalogError) throw new ApiError(e.status === 404 ? 404 : e.status === 400 ? 400 : 502, e.status === 404 ? 'not_found' : e.status === 400 ? 'engine_unavailable' : 'catalog_unavailable', e.message);
      throw e;
    }
  };
  app.get('/v1/image-models', { config: { owner: true } }, async req => ctx.imageModels.views(req.user.studioId));
  app.get('/v1/image-models/collections', { config: { owner: true } }, async () => catalogCall(() => ctx.imageModels.catalog.collections()));
  app.get('/v1/image-models/catalog', { config: { owner: true } }, async req => {
    const q = (req.query ?? {}) as { step?: string; q?: string; collection?: string };
    const step = stepParam(q.step ?? 'shot');
    return catalogCall(() => ctx.imageModels.catalog.list(step, { q: q.q?.slice(0, 120), collection: q.collection || undefined }));
  });
  app.get('/v1/image-models/model', { config: { owner: true } }, async req => {
    const q = (req.query ?? {}) as { id?: string; step?: string };
    if (!q.id) throw badRequest('id: owner/name');
    return catalogCall(() => ctx.imageModels.detail(q.id!.trim(), stepParam(q.step ?? 'shot')));
  });
  app.put<{ Params: { step: string } }>('/v1/image-models/:step', { config: { owner: true } }, async req => {
    const b = parse(z.object({ model: z.string().min(3).max(170), extra: z.record(z.unknown()).optional() }), req.body);
    const r = await catalogCall(() => ctx.imageModels.set(req.user.studioId, stepParam(req.params.step), b.model.trim(), b.extra));
    emitImageModels(req.user.studioId);
    return r;
  });
  app.delete<{ Params: { step: string } }>('/v1/image-models/:step', { config: { owner: true } }, async req => {
    const r = await ctx.imageModels.reset(req.user.studioId, stepParam(req.params.step));
    emitImageModels(req.user.studioId);
    return r;
  });
  /** Image models are owner-only (model names never reach a member). */
  const emitImageModels = (studioId: string) => ctx.hub.emitOwners(studioId, async () => ({ type: 'settings', imageModels: await ctx.imageModels.views(studioId) }));

  // ------------------------------------------------------------------ prompt library (owner, plans/api.md "Shoot references and the prompt library" §3)
  app.get('/v1/prompts', { config: { owner: true } }, async req => ctx.prompts.list(req.user.studioId));
  app.put<{ Params: { key: string } }>('/v1/prompts/:key', { config: { owner: true } }, async req => ctx.prompts.set(req.user, req.params.key, req.body));
  app.delete<{ Params: { key: string } }>('/v1/prompts/:key', { config: { owner: true } }, async req => ctx.prompts.reset(req.user, req.params.key));
  app.post('/v1/prompts/preview', { config: { owner: true } }, async req => ctx.prompts.preview(req.user, req.body));

  app.post<{ Params: { id: string } }>('/v1/models/:id/enhance/estimate', async req => ctx.tools.enhanceEstimate(req.user, req.params.id, req.body));
  app.post<{ Params: { id: string } }>('/v1/models/:id/enhance', async req => ctx.tools.startEnhance(req.user, req.params.id, req.body));
  app.post<{ Params: { id: string } }>('/v1/models/:id/dress-up/estimate', async req => ctx.tools.dressEstimate(req.user, req.params.id, req.body));
  app.post<{ Params: { id: string } }>('/v1/models/:id/dress-up', async req => ctx.tools.startDressUp(req.user, req.params.id, req.body));
  app.get('/v1/tool-runs', async req => ctx.tools.list(req.user, (req.query ?? {}) as any));
  app.get<{ Params: { id: string } }>('/v1/tool-runs/:id', async req => ctx.tools.get(req.user, req.params.id));
  app.patch<{ Params: { id: string; slot: string } }>('/v1/tool-runs/:id/items/:slot', async req => ctx.tools.decide(req.user, req.params.id, req.params.slot, req.body));
  app.post<{ Params: { id: string } }>('/v1/tool-runs/:id/pick', async req => ctx.tools.pickAll(req.user, req.params.id, req.body));
  app.post<{ Params: { id: string; slot: string } }>('/v1/tool-runs/:id/items/:slot/retry', async req => ctx.tools.retry(req.user, req.params.id, req.params.slot, req.body));
  app.post<{ Params: { id: string } }>('/v1/tool-runs/:id/apply', async req => ctx.tools.apply(req.user, req.params.id, req.body));
  app.delete<{ Params: { id: string } }>('/v1/tool-runs/:id', async (req, reply) => { await ctx.tools.discard(req.user, req.params.id); return reply.status(204).send(); });
  app.get<{ Params: { id: string } }>('/v1/models/:id/sheet-versions', async req => ctx.tools.versions(req.user, req.params.id));
  app.post<{ Params: { id: string; vid: string } }>('/v1/models/:id/sheet-versions/:vid/restore', async req => ctx.tools.restore(req.user, req.params.id, req.params.vid));

  // ------------------------------------------------------------------ settings
  const EngineBody = z.object({ provider: z.enum(PROVIDERS), model: z.string().min(1).max(200).optional(), url: z.string().url().max(500).optional() });
  const engineView = async (studioId: string) => { const sel = await ctx.images.selection(studioId); return { ...sel, label: ctx.images.label(sel), available: ctx.images.available() }; };
  app.get('/v1/settings/image-engine', async req => engineView(req.user.studioId));
  app.patch('/v1/settings/image-engine', async req => {
    const b = parse(EngineBody, req.body);
    if (req.user.role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can change engines');
    if (b.provider === 'custom-http') {
      if (!b.url) throw badRequest('The custom engine needs a URL');
      if (!ctx.config.DEV_MODE && !b.url.startsWith('https://')) throw badRequest('Use an https:// URL');
    }
    if (b.provider === 'fal' && !ctx.config.FAL_KEY) throw badRequest('fal is not set up on the server (FAL_KEY)');
    if (b.provider === 'replicate' && !ctx.replicate.configured) throw badRequest('Replicate is not set up on the server (REPLICATE_API_TOKEN)');
    const cur = await ctx.images.selection(req.user.studioId);
    const next = b.provider === 'replicate' ? { provider: b.provider, model: b.model ?? (cur.provider === 'replicate' ? cur.model : ctx.config.REPLICATE_IMAGE_MODEL) }
      : { provider: b.provider, model: b.model ?? (b.provider === cur.provider ? cur.model : b.provider === 'simulated' ? 'bundled-stills' : ctx.config.IMAGE_MODEL), ...(b.url ? { url: b.url } : {}) };
    await ctx.money.settings(req.user.studioId);
    await db.update(studioSettings).set({ imageEngine: next }).where(eq(studioSettings.studioId, req.user.studioId));
    const ev = await engineView(req.user.studioId);
    ctx.hub.emitOwners(req.user.studioId, { type: 'settings', imageEngine: ev });
    return ev;
  });
  /** Members get caps, the token rate and features; the owner also gets the add-on GPU settings and Engines (the only
   * place provider names go to an app, plans/api.md "App clean-up" §5). */
  const studioSettingsView = async (u: AuthUser) => {
    const s = await ctx.money.settings(u.studioId);
    const c = ctx.config;
    const base = { capPerJob: s.capPerJob ?? c.CAP_PER_JOB_USD, capPerDay: s.capPerDay ?? c.CAP_PER_DAY_USD, capPerUserDay: s.capPerUserDay ?? c.CAP_PER_USER_DAY_USD,
      tokenUsd: c.TOKEN_USD, features: { ...ctx.jobs.features(), photo: ctx.images.photoFeatures(s.identityRefs ?? undefined), tools: ctx.tools.features(u.role) } };
    if (u.role !== 'owner') return base;
    const om = await ctx.tools.ownerModels(u.studioId);
    base.features.tools.enhance.models = om.enhance;
    base.features.tools.dressUp.models = om.dressUp;
    return { ...base, maxGpus: s.maxGpus ?? c.MAX_GPUS, overheadPayer: s.overheadPayer ?? 'user', identityRefs: base.features.photo.identityRefs,
      warmIdleMinutes: s.warmIdleMinutes ?? c.WARM_IDLE_MINUTES, warmMaxMinutes: s.warmMaxMinutes ?? c.WARM_MAX_MINUTES,
      gpu: await ctx.gpu.status(), engines: await ctx.engines.view(u.studioId) };
  };
  app.get('/v1/settings/studio', async req => studioSettingsView(req.user));
  /** Studio settings changed: owners get the owner view (engines, GPU), members the member view. */
  const emitSettings = (studioId: string) => ctx.hub.emit(studioId, async v => ({ type: 'settings', settings: await studioSettingsView(asUser(v)) }));
  app.patch('/v1/settings/studio', { config: { owner: true } }, async req => {
    const b = parse(z.object({ maxGpus: z.number().int().min(0).max(16).optional(), overheadPayer: z.enum(['user', 'owner']).optional(),
      capPerJob: z.number().nonnegative().max(1000).optional(), capPerDay: z.number().nonnegative().max(10000).optional(), capPerUserDay: z.number().nonnegative().max(10000).optional(),
      warmGpuAllowed: z.enum(['owner', 'everyone']).optional() /* retired: accepted and ignored */, warmIdleMinutes: z.number().int().min(5).max(120).optional(), warmMaxMinutes: z.number().int().min(30).max(480).optional(),
      identityRefs: z.number().int().min(IDENTITY_REFS_MIN).max(IDENTITY_REFS_MAX).optional() }), req.body);
    await ctx.money.settings(req.user.studioId);
    const { warmGpuAllowed: _retired, ...patch } = b;
    if (Object.keys(patch).length) await db.update(studioSettings).set(patch).where(eq(studioSettings.studioId, req.user.studioId));
    emitSettings(req.user.studioId);
    // Caps feed everyone's Credits card.
    void ctx.money.notify(req.user.studioId, []);
    return studioSettingsView(req.user);
  });

  // ------------------------------------------------------------------ Keep add-on engine ready (services/warm.ts): owner only
  app.get('/v1/gpu/warm', { config: { owner: true } }, async req => ctx.warm.view(whoOf(req.user)));
  app.post('/v1/gpu/warm', { config: { owner: true } }, async req => {
    const b = parse(z.object({ on: z.boolean().optional(), extend: z.boolean().optional() }), req.body ?? {});
    if (b.extend) return ctx.warm.extend(req.user);
    if (b.on === true) return ctx.warm.turnOn(req.user);
    if (b.on === false) return ctx.warm.turnOff(req.user);
    throw badRequest('Send {on: true}, {on: false} or {extend: true}');
  });

  // ------------------------------------------------------------------ live events
  // Server-sent events through a hosting proxy (Koyeb, Railway): no compression and no buffering anywhere
  // (no-transform, X-Accel-Buffering; this server registers no compression plugin; Nagle off), a comment line every 10 s so the proxy's idle
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
    const off = ctx.hub.subscribe(req.user.studioId, req.user.id, line => res.write(line), req.user.role);
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
