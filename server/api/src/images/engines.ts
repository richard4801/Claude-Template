// The image engine: one request shape, one adapter per provider (plans/backend.md, "Image engine contract").
import { sleep } from '../lib/util.js';
import { outputUrl, ReplicateError, SAFETY_RE, CREDIT_RE, errorText, type ReplicateClient } from '../replicate/client.js';
import { outMpFor, type PhotoMetrics } from '../pricing.js';

export type ImageRequest = {
  prompt: string;
  negative?: string;
  /** Loadable URLs of reference images (character sheet, outfit, product photo). */
  referenceImages: string[];
  width: number;
  height: number;
  seed?: number;
  count: number;
  /** Simulated engine only: which bundled stills to return, in order (cycled). */
  simAssets?: string[];
  /** An edit of this photo (URL) rather than a new shot: Replicate uses its edit model. */
  editOf?: string;
  /** Replicate: megapixels of each reference (after shrinking), for the cost estimate. */
  referenceMp?: number[];
  /** How many references to send at most (default: the engine's reference limit). Shoots with reference images pass their planned count. */
  maxImages?: number;
};
/** What one prediction is billed on (Replicate): the service computes the exact cost once the output's size is known. */
export type PhotoBillInfo = { kind: 'shot' | 'edit'; inMp: number; outMp: number; metrics?: PhotoMetrics | null };
export type EngineImage = { url?: string; b64?: string; asset?: string; bill?: PhotoBillInfo };
export type ImageResult = { images: EngineImage[]; seed?: number; costUsd?: number };
export type EngineSelection = { provider: 'simulated' | 'fal' | 'custom-http' | 'replicate' | 'byo' /* WS5: an owner-added model, `model` = its id */; model: string; url?: string;
  /** Replicate: the model for edits of an existing photo. */
  editModel?: string };

export interface ImageEngine {
  readonly provider: EngineSelection['provider'];
  generate(req: ImageRequest, sel: EngineSelection): Promise<ImageResult>;
}

/** `code` turns into the API error: a safety refusal (422) or a rate limit that outlasted the wait (429). */
export class ImageEngineError extends Error {
  /** Images the engine had already made (and been billed for) before it failed. */
  partial: EngineImage[] = [];
  constructor(message: string, readonly code?: 'provider_refused' | 'provider_rate_limited' | 'engine_unavailable' | 'provider_out_of_credit') { super(message); }
}

/** Returns the bundled reference stills (assets/ref/*.jpg, the same ones the apps bundle) after GEN_MS. Free. */
export class SimulatedEngine implements ImageEngine {
  readonly provider = 'simulated' as const;
  constructor(private delayMs: () => number) {}
  async generate(req: ImageRequest): Promise<ImageResult> {
    await sleep(this.delayMs());
    const pool = req.simAssets?.length ? req.simAssets : ['g_front', 'c_face', 'face', 'g_tq'];
    return { images: Array.from({ length: req.count }, (_, i) => ({ asset: pool[i % pool.length] })), seed: req.seed ?? 0, costUsd: 0 };
  }
}

/** Any endpoint that follows our contract: POST {prompt, negative?, referenceImages, width, height, seed?, count} → {images, seed?, costUsd?}. */
export class CustomHttpEngine implements ImageEngine {
  readonly provider = 'custom-http' as const;
  constructor(private timeoutMs: number, private fetchFn: typeof fetch = fetch) {}
  async generate(req: ImageRequest, sel: EngineSelection): Promise<ImageResult> {
    if (!sel.url) throw new ImageEngineError('The custom image engine has no URL. Set it in Settings.');
    const { simAssets: _ignored, ...body } = req;
    const res = await this.fetchFn(sel.url, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ...body, model: sel.model }),
      signal: AbortSignal.timeout(this.timeoutMs),
    }).catch(e => { throw new ImageEngineError(`Image engine unreachable (${(e as Error).name})`); });
    if (!res.ok) throw new ImageEngineError(`Image engine error ${res.status}`);
    const out = (await res.json()) as ImageResult;
    if (!Array.isArray(out.images) || !out.images.length) throw new ImageEngineError('Image engine returned no images');
    return out;
  }
}

/**
 * fal.ai queue API: POST https://queue.fal.run/{model} → {request_id, status_url, response_url}; poll status until
 * COMPLETED; GET response_url → {images: [{url}], seed}. Edit models (Seedream edit, Nano Banana edit) take image_urls.
 */
export class FalEngine implements ImageEngine {
  readonly provider = 'fal' as const;
  constructor(private key: string | undefined, private base: string, private costPerImage: number, private timeoutMs: number,
    private fetchFn: typeof fetch = fetch, private pollMs = 1000) {}
  private headers() { return { authorization: `Key ${this.key}`, 'content-type': 'application/json' }; }
  async generate(req: ImageRequest, sel: EngineSelection): Promise<ImageResult> {
    if (!this.key) throw new ImageEngineError('FAL_KEY is not set on the server');
    const input: Record<string, unknown> = {
      prompt: req.prompt, num_images: req.count, image_size: { width: req.width, height: req.height },
      enable_safety_checker: true,
    };
    if (req.seed != null) input.seed = req.seed;
    if (req.negative) input.negative_prompt = req.negative;
    if (req.referenceImages.length) input.image_urls = req.referenceImages;
    const submit = await this.fetchFn(`${this.base}/${sel.model}`, { method: 'POST', headers: this.headers(), body: JSON.stringify(input) });
    if (!submit.ok) throw new ImageEngineError(`fal rejected the request (${submit.status})`);
    const q = (await submit.json()) as { request_id: string; status_url?: string; response_url?: string };
    const statusUrl = q.status_url ?? `${this.base}/${sel.model}/requests/${q.request_id}/status`;
    const responseUrl = q.response_url ?? `${this.base}/${sel.model}/requests/${q.request_id}`;
    const t0 = Date.now();
    for (;;) {
      const s = await this.fetchFn(statusUrl, { headers: this.headers() });
      const st = (await s.json().catch(() => ({}))) as { status?: string };
      if (st.status === 'COMPLETED') break;
      if (st.status === 'FAILED' || st.status === 'ERROR') throw new ImageEngineError('fal could not make the image');
      if (Date.now() - t0 > this.timeoutMs) throw new ImageEngineError('fal took too long');
      await sleep(this.pollMs);
    }
    const r = await this.fetchFn(responseUrl, { headers: this.headers() });
    if (!r.ok) throw new ImageEngineError(`fal result error ${r.status}`);
    const out = (await r.json()) as { images?: { url: string }[]; seed?: number };
    if (!out.images?.length) throw new ImageEngineError('fal returned no images');
    return { images: out.images.map(i => ({ url: i.url })), seed: out.seed ?? req.seed, costUsd: this.costPerImage * out.images.length };
  }
}

export type ReplicateImageConfig = {
  editModel: string; runUsd: number; mpUsd: number; editUsd: number; maxRefs: number; safety: number;
  pollMs: number; timeoutMs: number; maxWaitMs: number; loraUrl?: string; loraScale: number;
};
const RATIOS: [string, number][] = [['9:16', 9 / 16], ['3:4', 3 / 4], ['2:3', 2 / 3], ['4:5', 4 / 5], ['1:1', 1], ['5:4', 5 / 4], ['4:3', 4 / 3], ['3:2', 3 / 2], ['16:9', 16 / 9]];
/** The nearest aspect ratio FLUX.2 accepts. */
export const aspectFor = (w: number, h: number) => RATIOS.reduce((a, b) => (Math.abs(Math.log(b[1] / (w / h))) < Math.abs(Math.log(a[1] / (w / h))) ? b : a))[0];

/**
 * Replicate (plans/backend.md "Replicate"): new shots on FLUX.2 [pro] with the model's reference shots, edits of an
 * existing photo on Qwen-Image-Edit 2511. One prediction per image, through the shared rate-limit gate. The cost is
 * settled exactly by ImageService from each prediction's billing info (FLUX.2 [pro]: per run + per input and output megapixel).
 */
export class ReplicateImageEngine implements ImageEngine {
  readonly provider = 'replicate' as const;
  constructor(private client: ReplicateClient, private cfg: () => ReplicateImageConfig) {}
  async generate(req: ImageRequest, sel: EngineSelection): Promise<ImageResult> {
    const c = this.cfg();
    if (!this.client.configured) throw new ImageEngineError("Replicate isn't set up on the server", 'engine_unavailable');
    const images: EngineImage[] = [];
    const fail = (e: ImageEngineError) => { e.partial = images.slice(); return e; };
    for (let i = 0; i < req.count; i++) {
      const seed = req.seed != null ? req.seed + i : undefined;
      let model: string, input: Record<string, unknown>, bill: PhotoBillInfo;
      if (req.editOf) {
        model = sel.editModel || c.editModel;
        input = { prompt: req.prompt, image: [req.editOf, ...req.referenceImages.slice(0, 2)], aspect_ratio: 'match_input_image', output_format: 'jpg', output_quality: 95,
          ...(seed != null ? { seed } : {}), ...(c.loraUrl ? { lora_weights: c.loraUrl, lora_scale: c.loraScale } : {}) };
        bill = { kind: 'edit', inMp: 0, outMp: 0 };
      } else {
        model = sel.model;
        const refs = req.referenceImages.slice(0, req.maxImages ?? c.maxRefs);
        const outMp = outMpFor(req.width, req.height);
        input = { prompt: req.prompt, input_images: refs, aspect_ratio: aspectFor(req.width, req.height), resolution: `${outMp} MP`, output_format: 'jpg', output_quality: 95,
          safety_tolerance: Math.max(1, Math.min(5, Math.round(c.safety))), ...(seed != null ? { seed } : {}) };
        const inMp = refs.reduce((a, _, k) => a + (req.referenceMp?.[k] ?? 1), 0);
        bill = { kind: 'shot', inMp, outMp };
      }
      try {
        const p = await this.client.create(model, input, { maxWaitMs: c.maxWaitMs });
        const done = p.status === 'succeeded' ? p : await this.client.wait(p.id, { pollMs: c.pollMs, timeoutMs: c.timeoutMs });
        if (done.status !== 'succeeded') {
          const t = errorText(done.error);
          if (SAFETY_RE.test(t)) throw new ImageEngineError(`Replicate's safety filter refused this photo: ${t.slice(0, 200)}`, 'provider_refused');
          if (CREDIT_RE.test(t)) throw new ImageEngineError(`Replicate is out of credit: ${t.slice(0, 200)}`, 'provider_out_of_credit');
          throw new ImageEngineError(`Replicate could not make the image${t ? `: ${t.slice(0, 200)}` : ''}`);
        }
        const url = outputUrl(done.output);
        if (!url) throw new ImageEngineError('Replicate returned no image');
        images.push({ url, bill: { ...bill, metrics: (done.metrics ?? null) as PhotoMetrics | null } });
      } catch (e) {
        if (e instanceof ImageEngineError) throw fail(e);
        if (e instanceof ReplicateError) {
          if (e.kind === 'refused') throw fail(new ImageEngineError(`Replicate's safety filter refused this photo: ${e.message}`, 'provider_refused'));
          if (e.kind === 'rate_limited') throw fail(new ImageEngineError('Replicate is busy (rate limit)', 'provider_rate_limited'));
          if (e.kind === 'out_of_credit') throw fail(new ImageEngineError(e.message, 'provider_out_of_credit'));
          if (e.kind === 'unavailable') throw fail(new ImageEngineError(e.message, 'engine_unavailable'));
          throw fail(new ImageEngineError(e.message));
        }
        throw e;
      }
    }
    return { images, seed: req.seed };
  }
}
