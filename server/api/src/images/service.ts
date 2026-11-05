// Picks the studio's image engine, runs it, stores every image in our storage and records its recipe
// (provider, model, prompt, seed, cost) so any image can be reproduced.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { generatedImages, studioSettings, type ImageRef } from '../db/schema.js';
import { ApiError } from '../errors.js';
import { sha256, uid } from '../lib/util.js';
import { putObject } from '../storage/objects.js';
import { CustomHttpEngine, FalEngine, ImageEngineError, ReplicateImageEngine, SimulatedEngine, type EngineImage, type EngineSelection, type ImageEngine, type ImageRequest } from './engines.js';
import * as P from '../pricing.js';
import type { PhotoBill } from './bill.js';
import { ReplicateError, SAFETY_RE, CREDIT_RE, errorText } from '../replicate/client.js';
import { buildInput, imageCapacity, mapModel, type ImageStep } from '../replicate/mapping.js';
import { SHOOT_GUIDES, type SentRef, type ShootGuide } from '../prompt/engine.js';
import { exactOne } from '../replicate/prices.js';
import type { StepOverrides } from './steps.js';

/** Member-safe messages (plans/api.md "App clean-up" §1). The engine's own words go to the log only. */
export const PHOTO_FAILED = "Something went wrong making the photos · you weren't charged";
export const PHOTO_REFUSED = "This photo was refused by the content filter · you weren't charged";
export const PHOTO_BUSY = "Busy right now · you weren't charged. Try again in a minute.";
export const OUT_OF_CREDIT = "Something went wrong · you weren't charged. The studio owner has been told.";

/** An ApiError from a photo call, carrying what the engine already billed for images that were thrown away. */
export class PhotoError extends ApiError {
  constructor(status: number, code: string, message: string, readonly spentUsd: number) { super(status, code, message); }
}

export type ShootRefIn = { image: ImageRef; guides: ShootGuide[] };
export type ShotPlan = { images: ImageRef[]; sent: SentRef[]; refs: { index: number | null; guides: ShootGuide[]; dropped?: true }[] };
/**
 * The images one new shot sends (plans/api.md "Shoot references" §1): identity/outfit references (most important first,
 * at most `maxIdentity`), then the reference images, all within the model's `capacity`. Identity references go first
 * from the end, never the first (face front); then the last reference images.
 */
export function planShotImages(identity: (ImageRef | null | undefined)[], refs: ShootRefIn[], maxIdentity: number, capacity: number): ShotPlan {
  const id = (identity.filter(Boolean) as ImageRef[]).slice(0, Math.max(0, maxIdentity));
  const cap = Math.max(0, capacity);
  const nRefs = Math.min(refs.length, Math.max(0, id.length ? cap - 1 : cap));
  const nId = Math.min(id.length, cap - nRefs);
  const images = [...id.slice(0, nId), ...refs.slice(0, nRefs).map(r => r.image)];
  const sent: SentRef[] = refs.slice(0, nRefs).map((r, k) => ({ index: nId + k + 1, guides: r.guides }));
  return { images, sent, refs: refs.map((r, k) => (k < nRefs ? { index: nId + k + 1, guides: r.guides } : { index: null, guides: r.guides, dropped: true as const })) };
}

export const ASSET_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../assets/ref');
export const ASSET_KEYS = fs.existsSync(ASSET_DIR) ? fs.readdirSync(ASSET_DIR).filter(f => f.endsWith('.jpg')).map(f => f.slice(0, -4)) : [];
export const PROVIDERS = ['simulated', 'fal', 'custom-http', 'replicate'] as const;

/** Display names for the models we use on Replicate. */
const MODEL_LABELS: Record<string, string> = {
  'black-forest-labs/flux-2-pro': 'FLUX.2 [pro]', 'black-forest-labs/flux-2-dev': 'FLUX.2 [dev]', 'black-forest-labs/flux-2-flex': 'FLUX.2 [flex]',
  'black-forest-labs/flux-2-max': 'FLUX.2 [max]', 'qwen/qwen-image-edit-2511': 'Qwen edit', 'qwen/qwen-image-edit-plus': 'Qwen edit',
};
export const modelLabel = (id: string) => MODEL_LABELS[id] ?? id.split('/').pop() ?? id;

export class ImageService {
  engines: Record<EngineSelection['provider'], ImageEngine>;
  constructor(private ctx: Ctx, fetchFn: typeof fetch = fetch) {
    const c = ctx.config;
    this.engines = {
      simulated: new SimulatedEngine(() => ctx.config.GEN_MS),
      fal: new FalEngine(c.FAL_KEY, c.FAL_QUEUE_URL, c.FAL_COST_PER_IMAGE, c.IMAGE_TIMEOUT_SEC * 1000, fetchFn),
      'custom-http': new CustomHttpEngine(c.IMAGE_TIMEOUT_SEC * 1000, fetchFn),
      replicate: new ReplicateImageEngine(ctx.replicate, () => {
        const k = ctx.config;
        return { editModel: k.REPLICATE_IMAGE_EDIT_MODEL, runUsd: k.REPLICATE_IMAGE_RUN_USD, mpUsd: k.REPLICATE_IMAGE_MP_USD, editUsd: k.REPLICATE_IMAGE_EDIT_USD,
          maxRefs: k.REPLICATE_IMAGE_MAX_REFS, safety: k.REPLICATE_IMAGE_SAFETY, pollMs: Math.min(k.REPLICATE_POLL_MS, 1500), timeoutMs: k.IMAGE_TIMEOUT_SEC * 1000,
          maxWaitMs: k.REPLICATE_IMAGE_MAX_WAIT_SEC * 1000, loraUrl: k.REPLICATE_IMAGE_LORA_URL, loraScale: k.REPLICATE_IMAGE_LORA_SCALE };
      }),
    };
  }
  /** Shrunk references already in storage: storage key → megapixels. */
  private refMp = new Map<string, number>();

  defaultSelection(): EngineSelection {
    const c = this.ctx.config;
    if (c.IMAGE_PROVIDER === 'replicate') return this.replicateSelection();
    return { provider: c.IMAGE_PROVIDER, model: c.IMAGE_PROVIDER === 'simulated' ? 'bundled-stills' : c.IMAGE_MODEL, ...(c.IMAGE_CUSTOM_URL ? { url: c.IMAGE_CUSTOM_URL } : {}) };
  }
  replicateSelection(model?: string, editModel?: string): EngineSelection {
    const c = this.ctx.config;
    return { provider: 'replicate', model: model ?? c.REPLICATE_IMAGE_MODEL, editModel: editModel ?? c.REPLICATE_IMAGE_EDIT_MODEL };
  }
  /** Photo prices from config (plans/api.md "App clean-up" §3). */
  photoPrices(): P.PhotoPrices {
    const c = this.ctx.config;
    return { perRun: c.REPLICATE_IMAGE_RUN_USD, perInputMp: c.REPLICATE_IMAGE_MP_USD, perOutputMp: c.REPLICATE_IMAGE_MP_USD, perEdit: c.REPLICATE_IMAGE_EDIT_USD,
      refMp: P.PHOTO_REF_MP, maxRefs: c.REPLICATE_IMAGE_MAX_REFS };
  }
  /** `features.photo` for the apps. */
  photoFeatures() {
    const p = this.photoPrices(), r = p.maxRefs;
    return { ...p, loraShots: P.LORA_CANDIDATES, maxInputs: this.ctx.config.REPLICATE_IMAGE_MAX_INPUTS,
      references: { max: 3, guides: SHOOT_GUIDES.map(g => ({ ...g })) },
      estimates: { shoot: P.shootEstimate(p, 4, r), outfitSet: P.outfitSetEstimate(p, r), sheetAngle: P.sheetAnglesEstimate(p, 1, r), loraSet: P.loraSetEstimate(p, r) } };
  }
  /** Estimate of one new shot on the studio's shot model (the tested default: the config formula, "App clean-up" §3). */
  async newShotCost(studioId: string, outMp: number, refs: number, models?: StepOverrides | null) {
    const sel = await this.selection(studioId, null, models);
    if (sel.provider !== 'replicate' || this.ctx.imageModels.isRecipe('shot', sel.model)) return P.newShotEstimate(this.photoPrices(), outMp, refs);
    return this.ctx.imageModels.estimate(sel.model, { outMp, inMp: P.PHOTO_REF_MP * Math.min(refs, this.photoPrices().maxRefs) });
  }
  /** How many images one new shot can send on the studio's shot model (plans/api.md "Shoot references" §1). */
  async shotCapacity(studioId: string, override?: Partial<EngineSelection> | null, models?: StepOverrides | null) {
    const sel = await this.selection(studioId, override, models);
    const max = this.ctx.config.REPLICATE_IMAGE_MAX_INPUTS;
    if (sel.provider !== 'replicate' || this.ctx.imageModels.isRecipe('shot', sel.model) || !this.toolsLive) return max;
    try { return imageCapacity(mapModel(await this.ctx.imageModels.info(sel.model), 'shot').mapping); } catch { return max; }
  }
  /** A shoot's images and the estimate of one still that sends them all. */
  async shotPlan(studioId: string, identity: (ImageRef | null | undefined)[], refs: ShootRefIn[], outMp: number, override?: Partial<EngineSelection> | null, models?: StepOverrides | null) {
    const plan = planShotImages(identity, refs, this.photoPrices().maxRefs, await this.shotCapacity(studioId, override, models));
    const sel = await this.selection(studioId, override, models);
    const n = plan.images.length;
    const perShot = sel.provider !== 'replicate' || this.ctx.imageModels.isRecipe('shot', sel.model) ? P.newShotEstimateImages(this.photoPrices(), outMp, n)
      : await this.ctx.imageModels.estimate(sel.model, { outMp, inMp: P.PHOTO_REF_MP * n });
    return { ...plan, perShot };
  }
  /** Estimate of one edit on the studio's edit model. */
  async editCost(studioId: string, models?: StepOverrides | null) {
    const sel = await this.selection(studioId, null, models);
    const em = sel.editModel ?? this.ctx.config.REPLICATE_IMAGE_EDIT_MODEL;
    if (sel.provider !== 'replicate' || this.ctx.imageModels.isRecipe('edit', em)) return this.photoPrices().perEdit;
    return this.ctx.imageModels.estimate(em, { outMp: 1, inMp: P.PHOTO_REF_MP * 2 });
  }
  /** How many references a call will really send (nulls dropped, capped). */
  refCount(refs: (ImageRef | null | undefined)[]) { return Math.min(refs.filter(Boolean).length, this.photoPrices().maxRefs); }

  /** "FLUX.2 [pro] · Replicate", "Simulated", the fal model id, "Custom" (owner Settings → Engines only). */
  label(sel: EngineSelection) {
    return sel.provider === 'replicate' ? `${modelLabel(sel.model)} · Replicate` : sel.provider === 'simulated' ? 'Simulated' : sel.provider === 'fal' ? sel.model : 'Custom';
  }
  /** A shot's engineLabel: always "" since 2026-11-04 (the engine is never shown on a photo). */
  shotLabel(_sel?: EngineSelection) { return ''; }

  async selection(studioId: string, override?: Partial<EngineSelection> | null, models?: StepOverrides | null): Promise<EngineSelection> {
    const [s] = await this.ctx.db.select({ e: studioSettings.imageEngine, m: studioSettings.imageModels }).from(studioSettings).where(eq(studioSettings.studioId, studioId));
    const stored = s?.e as EngineSelection | null;
    // The owner's image models (plans/api.md "Model tools" §2) win over the older single image-engine model.
    const im = (s?.m ?? {}) as Record<string, { model: string }>;
    const shot = models?.shot ?? im.shot?.model, edit = models?.edit ?? im.edit?.model;
    const base = stored ? (stored.provider === 'replicate' ? this.replicateSelection(shot ?? stored.model, edit) : stored)
      : this.ctx.config.IMAGE_PROVIDER === 'replicate' ? this.replicateSelection(shot, edit) : this.defaultSelection();
    if (!override?.provider) return base;
    if (override.provider === 'replicate') return this.replicateSelection(override.model ?? (base.provider === 'replicate' ? base.model : undefined), edit);
    const def = this.defaultSelection();
    return { provider: override.provider, model: override.model ?? (override.provider === base.provider ? base.model : def.provider === override.provider ? def.model : override.provider === 'simulated' ? 'bundled-stills' : this.ctx.config.IMAGE_MODEL), url: override.url ?? base.url };
  }

  available() {
    return { simulated: true, fal: !!this.ctx.config.FAL_KEY, 'custom-http': true, replicate: this.ctx.replicate.configured };
  }

  /**
   * A reference for Replicate: shrunk to fit inside REPLICATE_IMAGE_REF_MAX_PX (keeps the per-megapixel price and the
   * 9 MP input limit in check), stored once under rx/, and handed over as a short-lived signed link.
   */
  async replicateRef(ref: ImageRef | null | undefined, studioId: string): Promise<{ url: string; mp: number } | null> {
    if (!ref) return null;
    const c = this.ctx.config, px = c.REPLICATE_IMAGE_REF_MAX_PX;
    const key = await this.storedKey(ref, studioId);
    const src = key ?? (ref.url && /^https?:\/\//.test(ref.url) ? ref.url : null);
    if (!src) return null;
    const rx = `rx/${sha256(`${src}|${px}`).slice(0, 32)}.jpg`;
    let mp = this.refMp.get(rx);
    if (mp == null || !(await this.ctx.storage.head(rx))) {
      let buf: Buffer;
      if (key) {
        const obj = await this.ctx.storage.get(key);
        if (!obj) return null;
        const parts: Buffer[] = [];
        for await (const ch of obj.body) parts.push(ch as Buffer);
        buf = Buffer.concat(parts);
      } else {
        const r = await fetch(src, { signal: AbortSignal.timeout(30_000) }).catch(() => null);
        if (!r?.ok) return null;
        buf = Buffer.from(await r.arrayBuffer());
      }
      const sharp = (await import('sharp')).default;
      const { data, info } = await sharp(buf).rotate().resize(px, px, { fit: 'inside', withoutEnlargement: true }).jpeg({ quality: 90 }).toBuffer({ resolveWithObject: true });
      await putObject(this.ctx, { key: rx, body: data, studioId, kind: 'generated', contentType: 'image/jpeg' });
      mp = info.width * info.height / 1e6;
      this.refMp.set(rx, mp);
    }
    return { url: await this.ctx.storage.presignGet(rx, c.REPLICATE_INPUT_URL_TTL_SEC), mp };
  }

  /** An absolute URL for an image ref (used for asset stills in API responses). */
  assetUrl(key: string) { return `${this.ctx.config.PUBLIC_URL ?? ''}/assets/ref/${key}.jpg`; }

  /** Storage key behind an /uploads/... URL, if it is one of ours. */
  keyOf(ref: ImageRef | null | undefined): string | null {
    const m = ref?.url ? /\/uploads\/([A-Za-z0-9][A-Za-z0-9._\/-]*)$/.exec(ref.url) : null;
    return m?.[1] ?? null;
  }

  /** The storage key holding this image; bundled stills are copied into storage on first use. Null for outside URLs. */
  async storedKey(ref: ImageRef | null | undefined, studioId = 'shared'): Promise<string | null> {
    if (!ref) return null;
    const key = this.keyOf(ref);
    if (key) return key;
    if (ref.asset && ASSET_KEYS.includes(ref.asset)) {
      const k = `assets/ref/${ref.asset}.jpg`;
      if (!(await this.ctx.storage.head(k))) await putObject(this.ctx, { key: k, body: fs.readFileSync(path.join(ASSET_DIR, `${ref.asset}.jpg`)), studioId, kind: 'asset', contentType: 'image/jpeg' });
      return k;
    }
    return null;
  }

  /** A URL an outside service (fal, a GPU worker) can GET: a presigned storage URL, or the image's own https URL. */
  async loadableUrl(ref: ImageRef | null | undefined, ttlSec = this.ctx.config.PRESIGN_TTL_SEC): Promise<string | null> {
    const key = await this.storedKey(ref);
    if (key) return this.ctx.storage.presignGet(key, ttlSec);
    return ref?.url && /^https?:\/\//.test(ref.url) ? ref.url : null;
  }

  /**
   * Generates `req.count` images and returns refs the apps can show. Throws ApiError(502, image_engine_failed) on failure;
   * the caller refunds.
   */
  async generate(o: { studioId: string; userId: string | null; purpose: string; refId?: string; req: Omit<ImageRequest, 'referenceImages'> & { referenceImages?: string[] };
    override?: Partial<EngineSelection> | null;
    /** References as image refs, most important first (face, profile, outfit or product, body); turned into URLs here. */
    refs?: (ImageRef | null | undefined)[];
    /** Edit this photo instead of making a new shot (Replicate's edit model; other engines treat it as the first reference). */
    editOf?: ImageRef | null;
    /** The action's bill: each image's exact cost is added; images billed but thrown away on a failure are recorded. */
    bill?: PhotoBill;
    /** Owner's per-run model choice (plans/api.md "Model tools" §2). */
    models?: StepOverrides | null;
    /** Send up to this many references (a shoot's planned images); default: the reference limit. */
    maxImages?: number }): Promise<{ images: ImageRef[]; seed?: number; costUsd: number; costs: number[]; selection: EngineSelection }> {
    const sel = await this.selection(o.studioId, o.override, o.models);
    // Any model other than the two tested defaults runs through the schema mapping.
    const step: ImageStep = o.editOf ? 'edit' : 'shot';
    const stepModel = o.editOf ? sel.editModel ?? this.ctx.config.REPLICATE_IMAGE_EDIT_MODEL : sel.model;
    if (sel.provider === 'replicate' && !this.ctx.imageModels.isRecipe(step, stepModel)) {
      const { extra } = await this.ctx.imageModels.resolve(o.studioId, step, { [step]: stepModel });
      const images: ImageRef[] = [], costs: number[] = [];
      for (let i = 0; i < o.req.count; i++) {
        try {
          const r = await this.runModel({ studioId: o.studioId, userId: o.userId, purpose: o.purpose, refId: o.refId, step, model: stepModel, extra,
            prompt: o.req.prompt, refs: o.editOf ? [o.editOf, ...(o.refs ?? []).slice(0, 2)] : (o.refs ?? []), width: o.req.width, height: o.req.height,
            matchInput: !!o.editOf, outMp: P.outMpFor(o.req.width, o.req.height), seed: o.req.seed != null ? o.req.seed + i : undefined });
          images.push(r.image); costs.push(r.cost);
        } catch (e) {
          const spent = costs.reduce((a, b) => a + b, 0) + (e instanceof PhotoError ? e.spentUsd : 0);
          o.bill?.waste(spent);
          throw e instanceof PhotoError ? new PhotoError(e.status, e.code, e.message, spent) : e;
        }
      }
      const total = costs.reduce((a, b) => a + b, 0);
      o.bill?.add(total);
      return { images, seed: o.req.seed, costUsd: total, costs, selection: { ...sel, model: stepModel } };
    }
    const engine = this.engines[sel.provider];
    if (!engine) throw new ApiError(400, 'bad_request', `Unknown image engine ${sel.provider}`);
    const req: ImageRequest = { ...o.req, referenceImages: o.req.referenceImages ?? [], ...(o.maxImages != null ? { maxImages: o.maxImages } : {}) };
    if (o.refs || o.editOf) {
      const list = [...(o.editOf && sel.provider !== 'replicate' ? [o.editOf] : []), ...(o.refs ?? [])];
      if (sel.provider === 'replicate') {
        const prepared = (await Promise.all(list.map(r => this.replicateRef(r, o.studioId).catch(() => null)))).filter(Boolean) as { url: string; mp: number }[];
        req.referenceImages = prepared.map(x => x.url);
        req.referenceMp = prepared.map(x => x.mp);
        if (o.editOf) {
          const edit = await this.replicateRef(o.editOf, o.studioId).catch(() => null);
          if (edit) req.editOf = edit.url;
        }
      } else req.referenceImages = (await Promise.all(list.map(r => this.loadableUrl(r)))).filter(Boolean) as string[];
    }
    const prices = this.photoPrices();
    const edit = !!o.editOf && sel.provider === 'replicate';
    /** Cost of one image: Replicate's billing info (exact), the engine's own figure, or (simulated) the estimate. */
    const costOf = (img: EngineImage, outMp?: number) => {
      if (img.bill) return P.photoPredictionCost(prices, img.bill.kind, { inMp: img.bill.inMp, outMp: outMp ?? img.bill.outMp, outputs: 1 }, img.bill.metrics);
      if (sel.provider === 'simulated') {
        if (o.editOf) return prices.perEdit;
        const outMp = P.outMpFor(o.req.width, o.req.height);
        return o.maxImages != null ? P.newShotEstimateImages(prices, outMp, Math.min(o.maxImages, (o.refs ?? []).filter(Boolean).length)) : P.newShotEstimate(prices, outMp, this.refCount(o.refs ?? []));
      }
      return null;
    };
    let out;
    try {
      out = await engine.generate(req, sel);
    } catch (e) {
      this.ctx.log.warn({ provider: sel.provider, model: sel.model, err: (e as Error).message }, 'image engine failed');
      const partial = e instanceof ImageEngineError ? e.partial : [];
      const spent = partial.reduce((a, img) => a + (costOf(img) ?? 0), 0);
      o.bill?.waste(spent);
      const code = e instanceof ImageEngineError ? e.code : undefined;
      if (code === 'provider_refused') throw new PhotoError(422, 'provider_refused', PHOTO_REFUSED, spent);
      if (code === 'provider_rate_limited') throw new PhotoError(429, 'provider_rate_limited', PHOTO_BUSY, spent);
      if (code === 'provider_out_of_credit') {
        await this.ctx.engines.outOfCredit(o.studioId, 'replicate', (e as Error).message);
        throw new PhotoError(503, 'provider_out_of_credit', OUT_OF_CREDIT, spent);
      }
      if (code === 'engine_unavailable') throw new PhotoError(400, 'engine_unavailable', "Photos aren't available right now", spent);
      throw new PhotoError(502, 'image_engine_failed', PHOTO_FAILED, spent);
    }
    if (sel.provider === 'replicate') this.ctx.engines.worked('replicate');
    const images = out.images.slice(0, o.req.count);
    const engineTotal = out.costUsd;
    const refs: ImageRef[] = [];
    const costs: number[] = [];
    for (const img of images) {
      const id = uid('img');
      let ref: ImageRef, storageKey: string | null = null, outMp: number | undefined;
      const measure = async (buf: Buffer) => {
        try { const sharp = (await import('sharp')).default; const m = await sharp(buf).metadata(); if (m.width && m.height) outMp = m.width * m.height / 1e6; } catch { /* keep the requested size */ }
      };
      if (img.asset) ref = { asset: img.asset, url: this.assetUrl(img.asset) };
      else if (img.b64) {
        storageKey = `g/${id}.png`;
        const buf = Buffer.from(img.b64, 'base64');
        if (img.bill) await measure(buf);
        await putObject(this.ctx, { key: storageKey, body: buf, studioId: o.studioId, kind: 'generated', userId: o.userId, contentType: 'image/png' });
        ref = { url: `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${storageKey}` };
      } else if (img.url) {
        ref = { url: img.url };
        try {
          const r = await fetch(img.url, { signal: AbortSignal.timeout(30_000) });
          if (r.ok) {
            const ct = r.headers.get('content-type') ?? 'image/jpeg';
            const buf = Buffer.from(await r.arrayBuffer());
            if (img.bill) await measure(buf);
            storageKey = `g/${id}.${ct.includes('png') ? 'png' : ct.includes('webp') ? 'webp' : 'jpg'}`;
            await putObject(this.ctx, { key: storageKey, body: buf, studioId: o.studioId, kind: 'generated', userId: o.userId, contentType: ct });
            ref = { url: `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${storageKey}` };
          }
        } catch { /* keep the provider's URL */ }
      } else continue;
      const cost = costOf(img, outMp) ?? (engineTotal ?? 0) / Math.max(1, images.length);
      costs.push(cost);
      await this.ctx.db.insert(generatedImages).values({
        id, studioId: o.studioId, userId: o.userId, purpose: o.purpose, refId: o.refId ?? null, provider: sel.provider,
        model: req.editOf || edit ? sel.editModel ?? sel.model : sel.model, prompt: o.req.prompt, negative: o.req.negative ?? null, seed: out.seed ?? o.req.seed ?? null, costUsd: cost, image: ref, storageKey, createdAt: Date.now(),
      });
      refs.push(ref);
    }
    const total = costs.reduce((a, b) => a + b, 0);
    if (!refs.length) { o.bill?.waste(total); throw new PhotoError(502, 'image_engine_failed', PHOTO_FAILED, total); }
    o.bill?.add(total);
    return { images: refs, seed: out.seed, costUsd: total, costs, selection: sel };
  }

  // ------------------------------------------------------------------ any Replicate model (plans/api.md "Model tools")
  /** Model tools run on Replicate when the server has its token; otherwise they're simulated (dev, tests). */
  get toolsLive() { return this.ctx.replicate.configured; }

  private fullInfo = new Map<string, { w: number; h: number }>();
  /** An image at its own size (Enhance must not shrink it), as a short-lived signed link, with its size. */
  async prepareFull(ref: ImageRef | null | undefined, studioId: string): Promise<{ url: string; mp: number; w: number; h: number } | null> {
    if (!ref) return null;
    const key = await this.storedKey(ref, studioId);
    if (!key) {
      if (ref.url && /^https?:\/\//.test(ref.url)) return { url: ref.url, mp: P.PHOTO_REF_MP, w: 768, h: 1024 };
      return null;
    }
    let dim = this.fullInfo.get(key);
    if (!dim) {
      const obj = await this.ctx.storage.get(key);
      if (!obj) return null;
      const parts: Buffer[] = [];
      for await (const ch of obj.body) parts.push(ch as Buffer);
      try {
        const sharp = (await import('sharp')).default;
        const m = await sharp(Buffer.concat(parts)).rotate().metadata();
        const turned = (m.orientation ?? 1) >= 5;
        dim = { w: (turned ? m.height : m.width) ?? 768, h: (turned ? m.width : m.height) ?? 1024 };
      } catch { dim = { w: 768, h: 1024 }; }
      this.fullInfo.set(key, dim);
    }
    return { url: await this.ctx.storage.presignGet(key, this.ctx.config.REPLICATE_INPUT_URL_TTL_SEC), mp: dim.w * dim.h / 1e6, w: dim.w, h: dim.h };
  }

  /** Downloads an output into our storage (g/…); keeps the provider URL if that fails. */
  async storeOutput(url: string, studioId: string, userId: string | null): Promise<{ ref: ImageRef; key: string | null; outMp?: number }> {
    const id = uid('img');
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(60_000) });
      if (r.ok) {
        const ct = r.headers.get('content-type') ?? 'image/jpeg';
        const buf = Buffer.from(await r.arrayBuffer());
        let outMp: number | undefined;
        try { const sharp = (await import('sharp')).default; const m = await sharp(buf).metadata(); if (m.width && m.height) outMp = m.width * m.height / 1e6; } catch { /* unknown size */ }
        const key = `g/${id}.${ct.includes('png') ? 'png' : ct.includes('webp') ? 'webp' : 'jpg'}`;
        await putObject(this.ctx, { key, body: buf, studioId, kind: 'generated', userId, contentType: ct });
        return { ref: { url: `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${key}` }, key, outMp };
      }
    } catch { /* keep the provider's URL */ }
    return { ref: { url }, key: null };
  }

  /** A member-safe PhotoError for an engine failure (the engine's own words go to the log). */
  async photoError(studioId: string, e: unknown, spent: number, ctxInfo: Record<string, unknown> = {}): Promise<PhotoError> {
    if (e instanceof PhotoError) return e;
    if (e instanceof ApiError) return new PhotoError(e.status, e.code, e.message, spent);
    const msg = (e as Error)?.message ?? String(e);
    this.ctx.log.warn({ ...ctxInfo, err: msg.slice(0, 300) }, 'image model failed');
    const kind = e instanceof ReplicateError ? e.kind : e instanceof ImageEngineError ? e.code : undefined;
    if (kind === 'refused' || kind === 'provider_refused') return new PhotoError(422, 'provider_refused', PHOTO_REFUSED, spent);
    if (kind === 'rate_limited' || kind === 'provider_rate_limited') return new PhotoError(429, 'provider_rate_limited', PHOTO_BUSY, spent);
    if (kind === 'out_of_credit' || kind === 'provider_out_of_credit') {
      await this.ctx.engines.outOfCredit(studioId, 'replicate', msg);
      return new PhotoError(503, 'provider_out_of_credit', OUT_OF_CREDIT, spent);
    }
    if (kind === 'unavailable' || kind === 'engine_unavailable') return new PhotoError(400, 'engine_unavailable', "Photos aren't available right now", spent);
    return new PhotoError(502, 'image_engine_failed', PHOTO_FAILED, spent);
  }

  /**
   * One prediction on any Replicate model for a step: inputs from the model's schema (mapping.ts) plus the owner's extra
   * inputs, official models by name and community models by their latest version; the output is stored and its exact
   * cost worked out from the model's price (prices.ts). Simulated (no token): returns `simulate` (or the first image)
   * after GEN_MS at the estimate. Throws PhotoError (member-safe).
   */
  async runModel(o: { studioId: string; userId: string | null; purpose: string; refId?: string; step: ImageStep; model: string; extra?: Record<string, unknown>;
    prompt?: string; refs: (ImageRef | null | undefined)[]; fullSize?: boolean; width?: number; height?: number; matchInput?: boolean; outMp?: number;
    seed?: number; strength?: number; scale?: number; simulate?: ImageRef | null; cancelled?: () => boolean | Promise<boolean> }): Promise<{ image: ImageRef; cost: number; estimated: boolean }> {
    const c = this.ctx.config, im = this.ctx.imageModels;
    const refs = o.refs.filter(Boolean) as ImageRef[];
    const outMp = o.outMp ?? 1;
    if (!this.toolsLive) {
      await new Promise(r => setTimeout(r, c.GEN_MS));
      const cost = await im.estimate(o.model, { outMp, inMp: P.PHOTO_REF_MP * refs.length, scale: o.scale });
      const image = o.simulate ?? refs[0] ?? { asset: 'face' };
      await this.ctx.db.insert(generatedImages).values({ id: uid('img'), studioId: o.studioId, userId: o.userId, purpose: o.purpose, refId: o.refId ?? null,
        provider: 'simulated', model: o.model, prompt: o.prompt ?? '', negative: null, seed: o.seed ?? null, costUsd: cost, image, storageKey: this.keyOf(image), createdAt: Date.now() });
      return { image, cost, estimated: false };
    }
    let raw;
    try { raw = await im.info(o.model); } catch (e) { throw await this.photoError(o.studioId, e, 0, { model: o.model, step: o.step }); }
    const map = mapModel(raw, o.step);
    if (!map.compatible) throw await this.photoError(o.studioId, new Error(`model ${o.model} can't do ${o.step}: ${map.reasons.join(', ')}`), 0, { model: o.model });
    const prepared = (await Promise.all(refs.map(r => (o.fullSize ? this.prepareFull(r, o.studioId) : this.replicateRef(r, o.studioId)).catch(() => null))))
      .filter(Boolean) as { url: string; mp: number; w?: number; h?: number }[];
    if (o.step !== 'shot' && !prepared.length) throw await this.photoError(o.studioId, new Error('no input image could be prepared'), 0, { model: o.model });
    const first = prepared[0];
    const w = o.width ?? first?.w ?? 768, h = o.height ?? first?.h ?? 1024;
    const known: Record<string, unknown> = {};
    // FLUX.2 keeps the tested safety tolerance (this is not the safety checker switch, which is never sent).
    if (map.inputs.some(i => i.name === 'safety_tolerance') && o.model.startsWith('black-forest-labs/flux-2')) known.safety_tolerance = c.REPLICATE_IMAGE_SAFETY;
    // Low creativity for the default upscaler, so the face stays the same.
    if (o.model === 'philz1337x/clarity-upscaler') known.resemblance = 1;
    const input = buildInput(map.mapping, { prompt: o.prompt, images: prepared.map(p => p.url), width: w, height: h, matchInput: o.matchInput, outMp,
      seed: o.seed, strength: o.strength, scale: o.scale }, { ...known, ...(o.extra ?? {}) });
    const inMp = prepared.slice(0, map.mapping.image?.array ? (map.mapping.image.max ?? prepared.length) : 1 + (map.mapping.extraImageFields?.length ?? 0)).reduce((a, p) => a + p.mp, 0);
    const price = await im.price(o.model).catch(() => ({ kind: 'unknown' } as const));
    let done;
    try {
      for (let attempt = 0; ; attempt++) {
        const p = await this.ctx.replicate.create(o.model, input, { maxWaitMs: c.REPLICATE_IMAGE_MAX_WAIT_SEC * 1000, cancelled: o.cancelled,
          ...(raw.is_official ? {} : { version: raw.latest_version?.id }) });
        done = p.status === 'succeeded' ? p : await this.ctx.replicate.wait(p.id, { pollMs: Math.min(c.REPLICATE_POLL_MS, 1500), timeoutMs: c.IMAGE_TIMEOUT_SEC * 1000, cancelled: o.cancelled });
        if (done.status === 'succeeded') break;
        const t = errorText(done.error);
        // The model takes fewer images than we sent (its limit wasn't in the schema): keep the first N and try once more.
        const limM = TOO_MANY_IMAGES_RE.exec(t), lim = limM ? Number(limM[1] ?? limM[2]) : 0;
        const field = map.mapping.image?.array ? map.mapping.image.field : null;
        if (attempt === 0 && lim > 0 && field && Array.isArray(input[field]) && (input[field] as unknown[]).length > lim) {
          this.ctx.log.warn({ model: o.model, sent: (input[field] as unknown[]).length, max: lim }, 'model takes fewer images · retrying with fewer');
          input[field] = (input[field] as unknown[]).slice(0, lim);
          continue;
        }
        throw new ReplicateError(t || 'prediction failed', SAFETY_RE.test(t) ? 'refused' : CREDIT_RE.test(t) ? 'out_of_credit' : 'failed');
      }
    } catch (e) { throw await this.photoError(o.studioId, e, 0, { model: o.model, step: o.step }); }
    this.ctx.engines.worked('replicate');
    const url = firstUri(done.output);
    if (!url) throw await this.photoError(o.studioId, new Error('no image in the output'), 0, { model: o.model });
    const stored = await this.storeOutput(url, o.studioId, o.userId);
    const measured = { outMp: stored.outMp ?? outMp, inMp, scale: o.scale };
    const ex = exactOne(price, (done.metrics ?? null) as Record<string, unknown> | null, measured, im.estOpts());
    if (ex.estimated) this.ctx.log.warn({ model: o.model, step: o.step, usd: ex.usd }, 'price unknown · settled on estimate');
    await this.ctx.db.insert(generatedImages).values({ id: uid('img'), studioId: o.studioId, userId: o.userId, purpose: o.purpose, refId: o.refId ?? null,
      provider: 'replicate', model: o.model, prompt: o.prompt ?? '', negative: null, seed: o.seed ?? null, costUsd: ex.usd, image: stored.ref, storageKey: stored.key, createdAt: Date.now() });
    return { image: stored.ref, cost: ex.usd, estimated: ex.estimated };
  }
}

/** "Maximum 5 input images allowed, but 7 were provided" and similar wordings. */
const TOO_MANY_IMAGES_RE = /(?:maximum|max|at most|up to)\s+(\d{1,2})\s+(?:input\s+|reference\s+)?images?\b[^]*?(?:allowed|provided|exceed|supported)|only\s+(?:supports?|accepts?)\s+(\d{1,2})\s+images?/i;

/** The first image URL in a prediction's output: a string, a list, or an object holding one. */
export function firstUri(o: unknown): string | null {
  if (typeof o === 'string') return /^(https?:|data:)/.test(o) ? o : null;
  if (Array.isArray(o)) { for (const x of o) { const u = firstUri(x); if (u) return u; } return null; }
  if (o && typeof o === 'object') { for (const v of Object.values(o as Record<string, unknown>)) { const u = firstUri(v); if (u) return u; } }
  return null;
}
