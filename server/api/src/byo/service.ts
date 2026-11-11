// Bring your own provider (WS5, plans/api.md "Bring your own provider"). The owner connects a provider account with an
// API key (validated, then stored AES-256-GCM encrypted), browses that provider's models, adds the ones they want, names
// them and switches them on. Enabled video models join the Suite registry as custom models (ids "c_…"), so shots on them
// go through the normal estimate → confirm → hold → settle flow and the daily caps; enabled image models run Photo. Members
// see every enabled custom model by the owner's display name unless the owner hides it from members (4c: the switch lives
// in suite_settings.models, engines/members.ts; `members` here is "shown to members", the old column is no longer read).
import crypto from 'node:crypto';
import fs from 'node:fs';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { sleep } from '../lib/util.js';
import { ReplicateError } from '../replicate/client.js';
import { aspectFor, ImageEngineError, type EngineImage, type EngineSelection, type ImageEngine, type ImageRequest, type ImageResult } from '../images/engines.js';
import type { ProviderStatus, StartHooks, VideoProvider } from '../suite/providers.js';
import { customModelsOf, setCustomModels, inputSlotsOf, type ModelSpec, type Resolution } from '../suite/registry.js';
import { adapters, KINDS, ProviderUnreachable, type Price, type ProviderAdapter, type ProviderKind, type RawModel } from './adapters.js';
import type { Analysis, Inputs, Kind } from './classify.js';
import { keyFromSecret, keysUnavailable, last4, openKey, sealKey } from './crypto.js';
import { byoModels, byoProviders } from './schema.js';
import { memberRules, providerLabel, saveMemberRules } from '../engines/members.js';

type ProviderRow = typeof byoProviders.$inferSelect;
type ModelRow = typeof byoModels.$inferSelect;

const AR_ALL = ['9:16', '16:9', '1:1', '4:3', '3:4', '21:9'];
const MAX_PROVIDERS = 10, MAX_MODELS = 100, CACHE_MS = 10 * 60_000, CACHE_MAX = 200, LOAD_MS = 15_000;
const newId = (p: string) => `${p}_${crypto.randomBytes(9).toString('base64url')}`;

const AddBody = z.object({ kind: z.enum(KINDS), apiKey: z.string().trim().min(8).max(500), label: z.string().trim().min(1).max(60).optional() }).strict();
const PatchBody = z.object({ apiKey: z.string().trim().min(8).max(500).optional(), label: z.string().trim().min(1).max(60).optional() }).strict();
const AddModelBody = z.object({ ref: z.string().trim().min(3).max(200), displayName: z.string().trim().min(1).max(60).optional() }).strict();
const PriceBody = z.object({ basis: z.enum(['per_run', 'per_second']), costUsd: z.number().min(0).max(50) }).strict();
const PatchModelBody = z.object({
  enabled: z.boolean().optional(), displayName: z.string().trim().min(1).max(60).optional(), members: z.boolean().optional(),
  price: PriceBody.nullable().optional(), priceScale: z.number().min(0.5).max(3).optional(), kind: z.enum(['image', 'video']).optional(),
  fixedInputs: z.record(z.string().max(80), z.union([z.string().max(2000), z.number(), z.boolean(), z.null()])).optional(),
}).strict();
const parse = <T>(s: z.ZodType<T>, body: unknown): T => {
  const r = s.safeParse(body ?? {});
  if (!r.success) throw badRequest(`Invalid request: ${r.error.issues[0]?.path.join('.')} ${r.error.issues[0]?.message}`);
  return r.data;
};

/** What's still needed before a model can run: unknown required fields not given a fixed value, and its kind. */
export function setupOf(r: Pick<ModelRow, 'analysis' | 'fixedInputs' | 'kind'>) {
  const fixed = r.fixedInputs ?? {};
  const missing = r.analysis.missing.filter(f => fixed[f] === undefined || fixed[f] === null || fixed[f] === '');
  if (!r.kind) missing.unshift('kind');
  return { missing, ready: missing.length === 0 };
}
const shortSide = (r: string) => { const m = /(\d+)\s*[pP]/.exec(r); if (m) return Number(m[1]); if (/4k/i.test(r)) return 2160; if (/2k/i.test(r)) return 1440; return 720; };

export class ByoService {
  readonly adapters: Record<ProviderKind, ProviderAdapter>;
  private cache = new Map<string, { at: number; value: unknown }>();
  private loadedAt = new Map<string, number>();
  readonly video: VideoProvider;
  readonly image: ImageEngine;
  constructor(private ctx: Ctx, private fetchFn: typeof fetch = fetch) {
    const c = ctx.config;
    this.adapters = adapters(() => ({ replicate: c.REPLICATE_API_URL, falPlatform: c.FAL_PLATFORM_URL, falQueue: c.FAL_QUEUE_URL, muapi: c.MUAPI_API_URL }), fetchFn);
    this.video = this.videoProvider();
    this.image = this.imageEngine();
  }
  private get secret() { return keyFromSecret(this.ctx.config.PROVIDER_KEYS_SECRET); }
  /** Keys can be stored (and used). */
  get ready() { return !!this.secret; }

  // ------------------------------------------------------------------------------------------- providers (owner)
  kinds() {
    return { kinds: KINDS.map(k => ({ kind: k, label: this.adapters[k].label, keyHint: this.adapters[k].keyHint, keyUrl: this.adapters[k].keyUrl })), keysReady: this.ready };
  }
  private async providerRow(u: AuthUser, id: string) {
    const [p] = await this.ctx.db.select().from(byoProviders).where(and(eq(byoProviders.id, id), eq(byoProviders.studioId, u.studioId)));
    if (!p) throw notFound('Provider');
    return p;
  }
  private async providerView(p: ProviderRow) {
    const ms = await this.ctx.db.select({ enabled: byoModels.enabled }).from(byoModels).where(eq(byoModels.providerId, p.id));
    return { id: p.id, kind: p.kind as ProviderKind, label: p.label, keyLast4: p.keyLast4, status: p.status as 'ok' | 'invalid', checkedAt: p.checkedAt, createdAt: p.createdAt,
      models: { added: ms.length, enabled: ms.filter(m => m.enabled).length } };
  }
  async list(u: AuthUser) {
    const rows = await this.ctx.db.select().from(byoProviders).where(eq(byoProviders.studioId, u.studioId));
    return { providers: await Promise.all(rows.sort((a, b) => a.createdAt - b.createdAt).map(p => this.providerView(p))), keysReady: this.ready };
  }
  /** Checks a key with the provider's free read-only call. Bad key → 400 invalid_key (nothing stored). */
  private async check(kind: ProviderKind, key: string) {
    let v: 'ok' | 'invalid';
    try { v = await this.adapters[kind].validate(key); }
    catch (e) {
      if (e instanceof ProviderUnreachable) throw new ApiError(502, 'provider_unreachable', `Couldn't reach ${this.adapters[kind].label} to check the key · try again`);
      throw e;
    }
    if (v === 'invalid') throw new ApiError(400, 'invalid_key', `${this.adapters[kind].label} didn't accept that key`);
  }
  async add(u: AuthUser, body: unknown) {
    const b = parse(AddBody, body);
    if (!this.secret) throw keysUnavailable();
    const n = (await this.ctx.db.select({ id: byoProviders.id }).from(byoProviders).where(eq(byoProviders.studioId, u.studioId))).length;
    if (n >= MAX_PROVIDERS) throw badRequest(`At most ${MAX_PROVIDERS} providers`);
    await this.check(b.kind, b.apiKey);
    const id = newId('prv'), now = Date.now();
    const row: ProviderRow = { id, studioId: u.studioId, kind: b.kind, label: b.label ?? this.adapters[b.kind].label, keyEnc: sealKey(this.secret, b.apiKey, id),
      keyLast4: last4(b.apiKey), status: 'ok', checkedAt: now, createdBy: u.id, createdAt: now, updatedAt: now };
    await this.ctx.db.insert(byoProviders).values(row);
    this.ctx.log.info({ provider: id, kind: b.kind }, 'byo provider added'); // never the key
    return this.providerView(row);
  }
  async patch(u: AuthUser, id: string, body: unknown) {
    const b = parse(PatchBody, body);
    const p = await this.providerRow(u, id);
    const set: Partial<ProviderRow> = { updatedAt: Date.now() };
    if (b.label) set.label = b.label;
    if (b.apiKey) {
      if (!this.secret) throw keysUnavailable();
      await this.check(p.kind as ProviderKind, b.apiKey);
      Object.assign(set, { keyEnc: sealKey(this.secret, b.apiKey, p.id), keyLast4: last4(b.apiKey), status: 'ok', checkedAt: Date.now() });
      this.dropCache(p.id);
    }
    await this.ctx.db.update(byoProviders).set(set).where(eq(byoProviders.id, p.id));
    return this.providerView({ ...p, ...set });
  }
  async remove(u: AuthUser, id: string) {
    const p = await this.providerRow(u, id);
    await this.ctx.db.delete(byoModels).where(eq(byoModels.providerId, p.id));
    await this.ctx.db.delete(byoProviders).where(eq(byoProviders.id, p.id));
    this.dropCache(p.id);
    await this.ensure(u.studioId, true);
  }
  /** The provider's key, decrypted for one call. Never returned, logged or stored in plain text. */
  private async keyOf(providerId: string): Promise<{ key: string; p: ProviderRow }> {
    const [p] = await this.ctx.db.select().from(byoProviders).where(eq(byoProviders.id, providerId));
    if (!p) throw new ReplicateError('the provider was removed', 'unavailable');
    if (!this.secret) throw new ReplicateError("provider keys can't be read on this server", 'unavailable');
    try { return { key: openKey(this.secret, p.keyEnc, p.id), p }; }
    catch { throw new ReplicateError("the provider's key can't be read", 'unavailable'); }
  }
  /** A refused key during use: shown to the owner as "invalid" until they add a new one. */
  private async markInvalid(providerId: string) {
    await this.ctx.db.update(byoProviders).set({ status: 'invalid', checkedAt: Date.now() }).where(eq(byoProviders.id, providerId)).catch(() => undefined);
  }

  // ------------------------------------------------------------------------------------------- catalog (owner)
  private dropCache(providerId: string) { for (const k of this.cache.keys()) if (k.startsWith(`${providerId}|`)) this.cache.delete(k); }
  private async cached<T>(k: string, f: () => Promise<T>): Promise<T> {
    const hit = this.cache.get(k);
    if (hit && Date.now() - hit.at < CACHE_MS) return hit.value as T;
    const value = await f();
    this.cache.set(k, { at: Date.now(), value });
    if (this.cache.size > CACHE_MAX) this.cache.delete(this.cache.keys().next().value!);
    return value;
  }
  private catalogView(m: RawModel, added?: ModelRow) {
    const s = setupOf({ analysis: m.analysis, fixedInputs: {}, kind: m.analysis.kind });
    return { ref: m.ref, name: m.name, description: m.description, kind: m.analysis.kind, inputs: m.analysis.inputs, missing: s.missing, ready: s.ready, price: m.price,
      added: added ? { id: added.id, enabled: added.enabled } : null };
  }
  async browse(u: AuthUser, providerId: string, query: unknown) {
    const p = await this.providerRow(u, providerId);
    const q = (query ?? {}) as Record<string, string | undefined>;
    const kind = q.kind === 'image' || q.kind === 'video' ? q.kind : undefined;
    const limit = Math.max(1, Math.min(50, Number(q.limit) || 20));
    const text = (q.q ?? '').toString().slice(0, 100);
    const cursor = q.cursor ? String(q.cursor).slice(0, 500) : null;
    const { key } = await this.keyOf(p.id).catch(() => { throw keysUnavailable(); });
    let page;
    try { page = await this.cached(`${p.id}|${text}|${kind ?? ''}|${cursor ?? ''}|${limit}`, () => this.adapters[p.kind as ProviderKind].search(key, { q: text, kind, cursor, limit })); }
    catch (e) { if (e instanceof ProviderUnreachable) throw new ApiError(502, 'provider_unreachable', `Couldn't reach ${this.adapters[p.kind as ProviderKind].label} · try again`); throw e; }
    const added = await this.ctx.db.select().from(byoModels).where(eq(byoModels.providerId, p.id));
    return { models: page.models.map(m => this.catalogView(m, added.find(a => a.ref === m.ref))), nextCursor: page.nextCursor };
  }

  /** Whether members see this model (4c: shown unless the owner hid it). */
  private async shown(studioId: string) { const h = (await memberRules(this.ctx, studioId)).hidden; return (id: string) => !h.has(id); }
  async isStudioModel(studioId: string, id: string) {
    return (await this.ctx.db.select({ id: byoModels.id }).from(byoModels).where(and(eq(byoModels.id, id), eq(byoModels.studioId, studioId)))).length > 0;
  }

  modelView(r: ModelRow, p: Pick<ProviderRow, 'kind'> | undefined, shown: (id: string) => boolean) {
    const s = setupOf(r);
    return { id: r.id, providerId: r.providerId, providerKind: (p?.kind ?? null) as ProviderKind | null, ref: r.ref, providerName: r.providerName, displayName: r.displayName,
      kind: r.kind, enabled: r.enabled, members: shown(r.id), status: s.ready ? 'ready' as const : 'needs_setup' as const, missing: s.missing, inputs: r.analysis.inputs,
      fields: r.analysis.fields, fixedInputs: r.fixedInputs, price: r.price, priceScale: r.priceScale,
      memberPrice: r.price ? { basis: r.price.basis, usd: Math.round(r.price.costUsd * r.priceScale * 10000) / 10000 } : null, createdAt: r.createdAt, updatedAt: r.updatedAt };
  }
  private async modelRow(u: AuthUser, id: string) {
    const [r] = await this.ctx.db.select().from(byoModels).where(and(eq(byoModels.id, id), eq(byoModels.studioId, u.studioId)));
    if (!r) throw notFound('Model');
    return r;
  }
  async addModel(u: AuthUser, providerId: string, body: unknown) {
    const b = parse(AddModelBody, body);
    const p = await this.providerRow(u, providerId);
    if (!this.adapters[p.kind as ProviderKind]?.validRef(b.ref)) throw badRequest('That isn’t a model id on this provider');
    const [dup] = await this.ctx.db.select().from(byoModels).where(and(eq(byoModels.providerId, p.id), eq(byoModels.ref, b.ref)));
    if (dup) return this.modelView(dup, p, await this.shown(u.studioId));
    const n = (await this.ctx.db.select({ id: byoModels.id }).from(byoModels).where(eq(byoModels.studioId, u.studioId))).length;
    if (n >= MAX_MODELS) throw badRequest(`At most ${MAX_MODELS} custom models`);
    const { key } = await this.keyOf(p.id).catch(() => { throw keysUnavailable(); });
    let m: RawModel | null;
    try { m = await this.cached(`${p.id}|model|${b.ref}`, () => this.adapters[p.kind as ProviderKind].model(key, b.ref)); }
    catch (e) { if (e instanceof ProviderUnreachable) throw new ApiError(502, 'provider_unreachable', `Couldn't reach ${this.adapters[p.kind as ProviderKind].label} · try again`); throw e; }
    if (!m) throw notFound('Model on this provider');
    const now = Date.now();
    const row: ModelRow = { id: newId('c'), studioId: u.studioId, providerId: p.id, ref: m.ref, version: m.version, providerName: m.name,
      displayName: b.displayName ?? m.name.slice(0, 60), kind: m.analysis.kind, enabled: false, members: true, analysis: m.analysis, fixedInputs: {},
      price: m.price, priceScale: 1, createdAt: now, updatedAt: now };
    await this.ctx.db.insert(byoModels).values(row);
    return this.modelView(row, p, await this.shown(u.studioId));
  }
  async models(u: AuthUser) {
    const rows = await this.ctx.db.select().from(byoModels).where(eq(byoModels.studioId, u.studioId));
    const ps = await this.ctx.db.select({ id: byoProviders.id, kind: byoProviders.kind }).from(byoProviders).where(eq(byoProviders.studioId, u.studioId));
    const shown = await this.shown(u.studioId);
    return { models: rows.sort((a, b) => a.createdAt - b.createdAt).map(r => this.modelView(r, ps.find(p => p.id === r.providerId), shown)) };
  }
  async patchModel(u: AuthUser, id: string, body: unknown) {
    const b = parse(PatchModelBody, body);
    const r = await this.modelRow(u, id);
    const next: ModelRow = { ...r, updatedAt: Date.now() };
    if (b.displayName !== undefined) next.displayName = b.displayName;
    if (b.priceScale !== undefined) next.priceScale = b.priceScale;
    if (b.kind !== undefined) next.kind = b.kind;
    if (b.price !== undefined) next.price = b.price ? { ...b.price, source: 'owner' } : null;
    if (b.fixedInputs !== undefined) {
      const known = new Set(r.analysis.fields), mapped = new Set(Object.values(r.analysis.map));
      for (const k of Object.keys(b.fixedInputs)) {
        if (!known.has(k)) throw badRequest(`fixedInputs.${k}: not an input of this model`);
        if (mapped.has(k)) throw badRequest(`fixedInputs.${k}: MUSE fills this one`);
      }
      next.fixedInputs = Object.fromEntries(Object.entries({ ...r.fixedInputs, ...b.fixedInputs }).filter(([, v]) => v !== null && v !== ''));
    }
    if (next.kind === 'image' && next.price?.basis === 'per_second') throw badRequest('An image model is priced per run');
    if (b.enabled !== undefined) next.enabled = b.enabled;
    if (next.enabled) {
      const s = setupOf(next);
      if (!s.ready) throw new ApiError(409, 'needs_setup', `Set up ${s.missing.join(', ')} first`, );
      if (!next.price) throw new ApiError(400, 'price_required', 'Give this model a price (per run or per second) before switching it on');
      if (next.kind === 'video' && !next.analysis.inputs.prompt) throw new ApiError(409, 'needs_setup', 'This model takes no prompt');
    }
    const { id: _id, studioId: _s, ...set } = next;
    await this.ctx.db.update(byoModels).set(set).where(eq(byoModels.id, r.id));
    // The old "available to members" switch (apps before 4c) is now the model's hide-from-members flag.
    if (b.members !== undefined) await saveMemberRules(this.ctx, u, { hidden: { [r.id]: !b.members } });
    await this.ensure(u.studioId, true);
    const [p] = await this.ctx.db.select({ kind: byoProviders.kind }).from(byoProviders).where(eq(byoProviders.id, r.providerId));
    return this.modelView(next, p, await this.shown(u.studioId));
  }
  async removeModel(u: AuthUser, id: string) {
    const r = await this.modelRow(u, id);
    await this.ctx.db.delete(byoModels).where(eq(byoModels.id, r.id));
    await this.ensure(u.studioId, true);
  }

  // ------------------------------------------------------------------------------------------- the Suite registry
  /** A ready, enabled, priced video model as a Suite registry entry (priced in cost; the plan applies priceScale). */
  specOf(r: ModelRow, p: Pick<ProviderRow, 'id' | 'kind'>): ModelSpec {
    const a = r.analysis, price = r.price!, perSec = price.basis === 'per_second' ? price.costUsd : 0;
    const resolutions: Resolution[] = (a.inputs.resolutions.length ? a.inputs.resolutions : ['auto']).map(x => ({ id: x, label: x === 'auto' ? 'Auto' : x, shortSide: shortSide(x), perSec }));
    return {
      id: r.id, name: r.displayName, provider: 'byo', ref: r.id, adapter: 'byo',
      modes: { text: a.inputs.prompt && !a.startRequired, image: a.inputs.startImage, reference: a.inputs.referenceImages > 0 },
      frames: { start: a.inputs.startImage, end: a.inputs.endImage, middle: 0, withRefs: a.inputs.startImage && a.inputs.referenceImages > 0 },
      refs: { images: a.inputs.referenceImages, videos: 0, audios: 0 },
      duration: a.inputs.duration ?? { min: 1, max: 60 }, resolutions, aspectRatios: a.inputs.aspectRatios.length ? a.inputs.aspectRatios : AR_ALL,
      audio: a.map.audio ? 'flag' : 'none', negativePrompt: a.inputs.negativePrompt, seed: a.inputs.seed,
      camera: { vocab: 'generic', refStyle: 'none', referenceVideo: false }, lora: false,
      licence: { kind: 'hosted', name: 'Owner-added model' }, status: 'active',
      byo: { studioId: r.studioId, providerId: p.id, providerKind: p.kind, providerRef: r.ref, version: r.version, displayName: r.displayName, members: r.members,
        analysis: a, fixed: r.fixedInputs, perRunUsd: price.basis === 'per_run' ? price.costUsd : 0, perSecUsd: perSec, priceScale: r.priceScale },
    };
  }
  private usable = new Map<string, ModelRow & { providerKind: string }>();
  /** Loads the studio's enabled custom models into the Suite registry (again after `force` or every few seconds). */
  async ensure(studioId: string, force = false) {
    if (!force && Date.now() - (this.loadedAt.get(studioId) ?? 0) < LOAD_MS) return;
    const rows = await this.ctx.db.select().from(byoModels).where(and(eq(byoModels.studioId, studioId), eq(byoModels.enabled, true)));
    const ps = await this.ctx.db.select({ id: byoProviders.id, kind: byoProviders.kind }).from(byoProviders).where(eq(byoProviders.studioId, studioId));
    const shown = await this.shown(studioId);
    for (const [k, v] of this.usable) if (v.studioId === studioId) this.usable.delete(k);
    const video: ModelSpec[] = [];
    for (const r of rows) {
      const p = ps.find(x => x.id === r.providerId);
      if (!p || !r.price || !setupOf(r).ready) continue;
      const row = { ...r, members: shown(r.id) };
      this.usable.set(r.id, { ...row, providerKind: p.kind });
      if (r.kind === 'video') video.push(this.specOf(row, p));
    }
    setCustomModels(studioId, video);
    this.loadedAt.set(studioId, Date.now());
  }
  /** The enabled custom models this user may pick (members: those the owner hasn't hidden), member-safe. */
  async catalog(u: AuthUser) {
    await this.ensure(u.studioId);
    const rows = [...this.usable.values()].filter(r => r.studioId === u.studioId && (u.role === 'owner' || r.members));
    const names = u.role !== 'owner' && (await memberRules(this.ctx, u.studioId)).showProviderNames;
    return rows.sort((a, b) => a.createdAt - b.createdAt).map(r => {
      const spec = r.kind === 'video' ? customModelsOf(u.studioId).find(m => m.id === r.id) : undefined;
      const price = { basis: r.price!.basis, usd: Math.round(r.price!.costUsd * r.priceScale * 10000) / 10000 };
      const base = { id: r.id, name: r.displayName, kind: r.kind as Kind, price,
        inputs: spec ? inputSlotsOf([spec]) : { start: false, end: false, middle: 0, images: Math.min(6, r.analysis.inputs.referenceImages), videos: 0, audio: false, framesWithRefs: false },
        minSeconds: spec?.duration.min ?? null, maxSeconds: spec?.duration.max ?? null, aspectRatios: spec?.aspectRatios ?? r.analysis.inputs.aspectRatios };
      return u.role === 'owner' ? { ...base, members: r.members, provider: r.providerKind, providerName: providerLabel(r.providerKind) }
        : names ? { ...base, provider: r.providerKind, providerName: providerLabel(r.providerKind) } : base;
    });
  }
  /** Whether this user may run this custom model now (throws otherwise). */
  async checkUse(u: AuthUser, id: string, kind: Kind) {
    await this.ensure(u.studioId);
    const r = this.usable.get(id);
    if (!r || r.studioId !== u.studioId || r.kind !== kind || (u.role !== 'owner' && !r.members)) throw new ApiError(400, 'engine_unavailable', 'That model isn’t available');
    return r;
  }

  // ------------------------------------------------------------------------------------------- running (server only)
  private videoProvider(): VideoProvider {
    const self = this;
    return {
      id: 'byo',
      configured: () => self.ready,
      async start(ref: string, input: Record<string, unknown>, hooks: StartHooks) {
        if (hooks.cancelled()) throw new ReplicateError('Cancelled', 'cancelled');
        const [r] = await self.ctx.db.select().from(byoModels).where(eq(byoModels.id, ref));
        if (!r || !r.enabled) throw new ReplicateError('the model was switched off', 'unavailable');
        const { key, p } = await self.keyOf(r.providerId);
        try {
          const h = await self.adapters[p.kind as ProviderKind].start(key, { ref: r.ref, version: r.version }, input);
          return JSON.stringify({ p: p.id, h });
        } catch (e) {
          if (e instanceof ReplicateError && (e.status === 401 || e.status === 403) && e.kind === 'unavailable') await self.markInvalid(p.id);
          throw e;
        }
      },
      async get(id: string): Promise<ProviderStatus> {
        const { p, h } = JSON.parse(id) as { p: string; h: string };
        const k = await self.keyOf(p);
        const s = await self.adapters[k.p.kind as ProviderKind].get(k.key, h);
        return { status: s.status, url: s.url ?? null, billedSeconds: null, error: s.error };
      },
      async cancel(id: string) {
        try { const { p, h } = JSON.parse(id) as { p: string; h: string }; const k = await self.keyOf(p); await self.adapters[k.p.kind as ProviderKind].cancel(k.key, h); }
        catch (e) { self.ctx.log.warn({ err: (e as Error).message }, 'byo cancel failed'); }
      },
      download: (url: string, file: string) => self.download(url, file),
    };
  }
  /** Outputs are public result URLs: fetched without any key. */
  async download(url: string, file: string) {
    if (!/^https?:\/\//.test(url)) throw new ReplicateError('the provider returned no file', 'failed');
    const res = await this.fetchFn(url, { signal: AbortSignal.timeout(10 * 60_000) }).catch(e => { throw new ReplicateError(`Couldn't download the result (${(e as Error).name})`, 'failed'); });
    if (!res.ok || !res.body) throw new ReplicateError(`Couldn't download the result (${res.status})`, 'failed', res.status);
    await pipeline(Readable.fromWeb(res.body as any), fs.createWriteStream(file));
  }

  /** One photo's price on a custom image model: its per-run cost × the markup. */
  async photoPerShot(studioId: string, id: string) {
    await this.ensure(studioId);
    const r = this.usable.get(id);
    if (!r || r.studioId !== studioId || r.kind !== 'image') throw new ApiError(400, 'engine_unavailable', 'That model isn’t available');
    return Math.round(r.price!.costUsd * r.priceScale * 10000) / 10000;
  }
  async photoCapacity(studioId: string, id: string) {
    await this.ensure(studioId);
    return Math.max(0, this.usable.get(id)?.analysis.inputs.referenceImages ?? 0);
  }
  /** Photos on a custom image model (ImageService's "byo" engine). In the suite's test mode nothing is called. */
  private imageEngine(): ImageEngine {
    const self = this;
    return {
      provider: 'byo' as EngineSelection['provider'],
      async generate(req: ImageRequest, sel: EngineSelection): Promise<ImageResult> {
        const [r] = await self.ctx.db.select().from(byoModels).where(eq(byoModels.id, sel.model));
        if (!r || !r.enabled || r.kind !== 'image' || !r.price) throw new ImageEngineError('That model isn’t available', 'engine_unavailable');
        const perImage = Math.round(r.price.costUsd * r.priceScale * 10000) / 10000;
        if (self.ctx.config.suiteMode === 'mock') {
          const pool = ['g_front', 'c_face', 'face', 'g_tq'];
          return { images: Array.from({ length: req.count }, (_, i) => ({ asset: pool[i % pool.length] })), seed: req.seed ?? 0, costUsd: self.ctx.config.SUITE_MOCK_CHARGE ? perImage * req.count : 0 };
        }
        let k;
        try { k = await self.keyOf(r.providerId); } catch { throw new ImageEngineError("The provider's key can't be used", 'engine_unavailable'); }
        const ad = self.adapters[k.p.kind as ProviderKind];
        const images: EngineImage[] = [];
        const fail = (e: ImageEngineError) => { e.partial = images.slice(); return e; };
        // Owner 2026-11-09: the largest size the model offers; a size it refuses for this shape (e.g. 2K at 9:16) steps down.
        const sizes = largestFirst(r.analysis, r.fixedInputs);
        for (let i = 0; i < req.count; i++) {
          for (let si = 0; ; si++) {
            const input = imageInput(r.analysis, r.fixedInputs, req, i);
            if (sizes.length && r.analysis.map.resolution) input[r.analysis.map.resolution] = sizes[si];
            const more = si + 1 < sizes.length;
            let h: string;
            try { h = await ad.start(k.key, { ref: r.ref, version: r.version }, input); }
            catch (e) {
              const re = e as ReplicateError;
              if (re.status === 401 || re.status === 403) await self.markInvalid(k.p.id);
              if (more && re.kind === 'failed' && (re.status ?? 0) >= 400 && (re.status ?? 0) < 500) continue;
              throw fail(new ImageEngineError(re.message, re.kind === 'refused' ? 'provider_refused' : re.kind === 'rate_limited' ? 'provider_rate_limited' : re.kind === 'unavailable' ? 'engine_unavailable' : undefined));
            }
            const t0 = Date.now();
            let retry = false;
            for (;;) {
              const s = await ad.get(k.key, h);
              if (s.status === 'succeeded') { images.push({ url: s.url }); break; }
              if (s.status === 'failed' && more && s.error?.kind !== 'refused' && s.error?.kind !== 'out_of_credit') { retry = true; break; }
              if (s.status === 'failed' || s.status === 'canceled') throw fail(new ImageEngineError(s.error?.message ?? 'failed', s.error?.kind === 'refused' ? 'provider_refused' : undefined));
              if (Date.now() - t0 > self.ctx.config.IMAGE_TIMEOUT_SEC * 1000) { await ad.cancel(k.key, h); throw fail(new ImageEngineError('timed out')); }
              await sleep(Math.min(1500, self.ctx.config.REPLICATE_POLL_MS));
            }
            if (!retry) break;
          }
        }
        return { images, seed: req.seed, costUsd: perImage * images.length };
      },
    };
  }
}

/** Pixels a resolution id stands for ("2K", "1080p", "4 MP", "1024x1536"); 0 when unknown. */
export function resolutionRank(id: string): number {
  const s = id.trim().toLowerCase();
  let m = /^(\d+(?:\.\d+)?)\s*k$/.exec(s); if (m) return Number(m[1]) * 1000 * 1000;
  m = /^(\d+)\s*p$/.exec(s); if (m) return Number(m[1]) * Number(m[1]) * 16 / 9;
  m = /^(\d+(?:\.\d+)?)\s*mp$/.exec(s); if (m) return Number(m[1]) * 1e6;
  m = /^(\d+)\s*[x×*]\s*(\d+)$/.exec(s); if (m) return Number(m[1]) * Number(m[2]);
  return 0;
}
/** The model's sizes, largest first (only when it has a size choice and the owner didn't fix one). */
export function largestFirst(a: Analysis, fixed: Record<string, unknown>): string[] {
  if (!a.map.resolution || fixed[a.map.resolution] !== undefined) return [];
  const known = a.inputs.resolutions.filter(x => resolutionRank(x) > 0);
  return known.sort((x, y) => resolutionRank(y) - resolutionRank(x));
}

/** One photo's inputs on a custom image model. */
export function imageInput(a: Analysis, fixed: Record<string, unknown>, req: Pick<ImageRequest, 'prompt' | 'negative' | 'referenceImages' | 'width' | 'height' | 'seed'>, i = 0) {
  const map = a.map, input: Record<string, unknown> = { ...fixed };
  if (map.prompt) input[map.prompt] = req.prompt;
  if (map.negativePrompt && req.negative) input[map.negativePrompt] = req.negative;
  if (map.referenceImages && req.referenceImages.length)
    input[map.referenceImages] = a.shapes.referenceImages === 'single' ? req.referenceImages[0] : req.referenceImages.slice(0, Math.max(1, a.inputs.referenceImages));
  if (map.width && map.height) { input[map.width] = req.width; input[map.height] = req.height; }
  if (map.aspectRatio) {
    const ar = aspectFor(req.width, req.height);
    if (!a.inputs.aspectRatios.length || a.inputs.aspectRatios.includes(ar)) input[map.aspectRatio] = ar;
  }
  if (map.seed && req.seed != null) input[map.seed] = req.seed + i;
  return input;
}

export type { Inputs, Price };
