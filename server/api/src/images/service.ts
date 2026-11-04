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

/** Member-safe messages (plans/api.md "App clean-up" §1). The engine's own words go to the log only. */
export const PHOTO_FAILED = "Something went wrong making the photos · you weren't charged";
export const PHOTO_REFUSED = "This photo was refused by the content filter · you weren't charged";
export const PHOTO_BUSY = "Busy right now · you weren't charged. Try again in a minute.";
export const OUT_OF_CREDIT = "Something went wrong · you weren't charged. The studio owner has been told.";

/** An ApiError from a photo call, carrying what the engine already billed for images that were thrown away. */
export class PhotoError extends ApiError {
  constructor(status: number, code: string, message: string, readonly spentUsd: number) { super(status, code, message); }
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
  replicateSelection(model?: string): EngineSelection {
    const c = this.ctx.config;
    return { provider: 'replicate', model: model ?? c.REPLICATE_IMAGE_MODEL, editModel: c.REPLICATE_IMAGE_EDIT_MODEL };
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
    return { ...p, loraShots: P.LORA_CANDIDATES,
      estimates: { shoot: P.shootEstimate(p, 4, r), outfitSet: P.outfitSetEstimate(p, r), sheetAngle: P.sheetAnglesEstimate(p, 1, r), loraSet: P.loraSetEstimate(p, r) } };
  }
  /** How many references a call will really send (nulls dropped, capped). */
  refCount(refs: (ImageRef | null | undefined)[]) { return Math.min(refs.filter(Boolean).length, this.photoPrices().maxRefs); }

  /** "FLUX.2 [pro] · Replicate", "Simulated", the fal model id, "Custom" (owner Settings → Engines only). */
  label(sel: EngineSelection) {
    return sel.provider === 'replicate' ? `${modelLabel(sel.model)} · Replicate` : sel.provider === 'simulated' ? 'Simulated' : sel.provider === 'fal' ? sel.model : 'Custom';
  }
  /** A shot's engineLabel: always "" since 2026-11-04 (the engine is never shown on a photo). */
  shotLabel(_sel?: EngineSelection) { return ''; }

  async selection(studioId: string, override?: Partial<EngineSelection> | null): Promise<EngineSelection> {
    const [s] = await this.ctx.db.select({ e: studioSettings.imageEngine }).from(studioSettings).where(eq(studioSettings.studioId, studioId));
    const stored = s?.e as EngineSelection | null;
    const base = stored ? (stored.provider === 'replicate' ? this.replicateSelection(stored.model) : stored) : this.defaultSelection();
    if (!override?.provider) return base;
    if (override.provider === 'replicate') return this.replicateSelection(override.model ?? (base.provider === 'replicate' ? base.model : undefined));
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
    bill?: PhotoBill }): Promise<{ images: ImageRef[]; seed?: number; costUsd: number; costs: number[]; selection: EngineSelection }> {
    const sel = await this.selection(o.studioId, o.override);
    const engine = this.engines[sel.provider];
    if (!engine) throw new ApiError(400, 'bad_request', `Unknown image engine ${sel.provider}`);
    const req: ImageRequest = { ...o.req, referenceImages: o.req.referenceImages ?? [] };
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
      if (sel.provider === 'simulated') return o.editOf ? prices.perEdit : P.newShotEstimate(prices, P.outMpFor(o.req.width, o.req.height), this.refCount(o.refs ?? []));
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
}
