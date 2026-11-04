// The image engine: one request shape, one adapter per provider (plans/backend.md, "Image engine contract").
import { sleep } from '../lib/util.js';

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
};
export type EngineImage = { url?: string; b64?: string; asset?: string };
export type ImageResult = { images: EngineImage[]; seed?: number; costUsd?: number };
export type EngineSelection = { provider: 'simulated' | 'fal' | 'custom-http'; model: string; url?: string };

export interface ImageEngine {
  readonly provider: EngineSelection['provider'];
  generate(req: ImageRequest, sel: EngineSelection): Promise<ImageResult>;
}

export class ImageEngineError extends Error {}

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
