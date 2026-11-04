// Picks the studio's image engine, runs it, stores every image in our storage and records its recipe
// (provider, model, prompt, seed, cost) so any image can be reproduced.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { generatedImages, studioSettings, type ImageRef } from '../db/schema.js';
import { ApiError } from '../errors.js';
import { uid } from '../lib/util.js';
import { putObject } from '../storage/objects.js';
import { CustomHttpEngine, FalEngine, ImageEngineError, SimulatedEngine, type EngineSelection, type ImageEngine, type ImageRequest } from './engines.js';

export const ASSET_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../assets/ref');
export const ASSET_KEYS = fs.existsSync(ASSET_DIR) ? fs.readdirSync(ASSET_DIR).filter(f => f.endsWith('.jpg')).map(f => f.slice(0, -4)) : [];
export const PROVIDERS = ['simulated', 'fal', 'custom-http'] as const;

export class ImageService {
  engines: Record<EngineSelection['provider'], ImageEngine>;
  constructor(private ctx: Ctx, fetchFn: typeof fetch = fetch) {
    const c = ctx.config;
    this.engines = {
      simulated: new SimulatedEngine(() => ctx.config.GEN_MS),
      fal: new FalEngine(c.FAL_KEY, c.FAL_QUEUE_URL, c.FAL_COST_PER_IMAGE, c.IMAGE_TIMEOUT_SEC * 1000, fetchFn),
      'custom-http': new CustomHttpEngine(c.IMAGE_TIMEOUT_SEC * 1000, fetchFn),
    };
  }

  defaultSelection(): EngineSelection {
    const c = this.ctx.config;
    return { provider: c.IMAGE_PROVIDER, model: c.IMAGE_PROVIDER === 'simulated' ? 'bundled-stills' : c.IMAGE_MODEL, ...(c.IMAGE_CUSTOM_URL ? { url: c.IMAGE_CUSTOM_URL } : {}) };
  }

  async selection(studioId: string, override?: Partial<EngineSelection> | null): Promise<EngineSelection> {
    const [s] = await this.ctx.db.select({ e: studioSettings.imageEngine }).from(studioSettings).where(eq(studioSettings.studioId, studioId));
    const base = (s?.e as EngineSelection | null) ?? this.defaultSelection();
    if (!override?.provider) return base;
    return { provider: override.provider, model: override.model ?? (override.provider === base.provider ? base.model : this.defaultSelection().model), url: override.url ?? base.url };
  }

  available() {
    return { simulated: true, fal: !!this.ctx.config.FAL_KEY, 'custom-http': true };
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
  async generate(o: { studioId: string; userId: string | null; purpose: string; refId?: string; req: ImageRequest; override?: Partial<EngineSelection> | null }): Promise<{ images: ImageRef[]; seed?: number; costUsd: number; selection: EngineSelection }> {
    const sel = await this.selection(o.studioId, o.override);
    const engine = this.engines[sel.provider];
    if (!engine) throw new ApiError(400, 'bad_request', `Unknown image engine ${sel.provider}`);
    let out;
    try {
      out = await engine.generate(o.req, sel);
    } catch (e) {
      this.ctx.log.warn({ provider: sel.provider, model: sel.model, err: (e as Error).message }, 'image engine failed');
      throw new ApiError(502, 'image_engine_failed', e instanceof ImageEngineError ? e.message : 'The image engine failed');
    }
    const per = (out.costUsd ?? 0) / Math.max(1, out.images.length);
    const refs: ImageRef[] = [];
    for (const img of out.images.slice(0, o.req.count)) {
      const id = uid('img');
      let ref: ImageRef, storageKey: string | null = null;
      if (img.asset) ref = { asset: img.asset, url: this.assetUrl(img.asset) };
      else if (img.b64) {
        storageKey = `g/${id}.png`;
        await putObject(this.ctx, { key: storageKey, body: Buffer.from(img.b64, 'base64'), studioId: o.studioId, kind: 'generated', userId: o.userId, contentType: 'image/png' });
        ref = { url: `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${storageKey}` };
      } else if (img.url) {
        ref = { url: img.url };
        try {
          const r = await fetch(img.url, { signal: AbortSignal.timeout(30_000) });
          if (r.ok) {
            const ct = r.headers.get('content-type') ?? 'image/jpeg';
            storageKey = `g/${id}.${ct.includes('png') ? 'png' : ct.includes('webp') ? 'webp' : 'jpg'}`;
            await putObject(this.ctx, { key: storageKey, body: Buffer.from(await r.arrayBuffer()), studioId: o.studioId, kind: 'generated', userId: o.userId, contentType: ct });
            ref = { url: `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${storageKey}` };
          }
        } catch { /* keep the provider's URL */ }
      } else continue;
      await this.ctx.db.insert(generatedImages).values({
        id, studioId: o.studioId, userId: o.userId, purpose: o.purpose, refId: o.refId ?? null, provider: sel.provider, model: sel.model,
        prompt: o.req.prompt, negative: o.req.negative ?? null, seed: out.seed ?? o.req.seed ?? null, costUsd: per, image: ref, storageKey, createdAt: Date.now(),
      });
      refs.push(ref);
    }
    if (!refs.length) throw new ApiError(502, 'image_engine_failed', 'The image engine returned no images');
    return { images: refs, seed: out.seed, costUsd: out.costUsd ?? 0, selection: sel };
  }
}
