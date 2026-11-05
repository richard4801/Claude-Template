// Replicate's model catalog for owner Settings → Engines → "Image models" (plans/api.md "Model tools" §2). Read-only and
// free: collections (their models come with the latest version's schema), search (beta; results carry no schema, so each
// is read with GET /models/{owner}/{name}), single models, and prices from the model's web page. Everything is cached in
// memory. The token only ever goes in the Authorization header of api.replicate.com calls; it is never logged.
import { mapModel, STEP_LABELS, type ImageStep, type RawModel } from './mapping.js';
import { parseModelPage, priceLine, type PriceInfo } from './prices.js';

export const STEP_COLLECTIONS: Record<ImageStep, string[]> = {
  shot: ['text-to-image', 'image-editing'], edit: ['image-editing'], realism: ['image-editing', 'text-to-image'],
  upscale: ['super-resolution', 'ai-image-restoration'], dressA: ['image-editing'], dressB: ['image-editing'],
};

/** Prices we know without reading a page (checked 2026-11-04 on the model pages), for when the page can't be read. */
export const KNOWN_PRICES: Record<string, PriceInfo> = {
  'black-forest-labs/flux-2-pro': { kind: 'per-unit', source: 'config', units: [
    { metric: 'run_count', usd: 0.015, label: 'per run' }, { metric: 'image_input_megapixel_count', usd: 0.015, label: 'per input image megapixel' },
    { metric: 'image_output_megapixel_count', usd: 0.015, label: 'per output image megapixel' }] },
  'qwen/qwen-image-edit-2511': { kind: 'per-unit', source: 'config', units: [{ metric: 'image_output_count', usd: 0.03, label: 'per output image' }] },
  'black-forest-labs/flux-krea-dev': { kind: 'per-unit', source: 'config', units: [{ metric: 'image_output_count', usd: 0.025, label: 'per output image' }] },
  'philz1337x/clarity-upscaler': { kind: 'per-second', source: 'config', usdPerSecond: 0.00115, hardware: 'A100 (40GB)', typicalUsd: 0.018 },
  'topazlabs/image-upscale': { kind: 'per-unit', source: 'config', units: [{ metric: 'unspecified_billing_metric', usd: 0.08, label: 'per unit' }] },
};

export type CatalogModel = {
  id: string; owner: string; name: string; description: string; runCount: number; official: boolean; coverUrl: string | null;
  price: PriceInfo | null; priceLine: string; compatible: boolean | null; reasons: string[]; warnings: string[];
};

type Entry<T> = { at: number; value: T };
export type CatalogOptions = { token?: string; apiBase: string; webBase: string; listTtlMs: number; modelTtlMs: number; priceTtlMs: number;
  fetchFn?: typeof fetch; log?: { warn: (o: object, m: string) => void } };

export class CatalogError extends Error {
  constructor(message: string, readonly status = 502) { super(message); }
}

export const MODEL_ID_RE = /^[a-z0-9][a-z0-9_.-]{0,63}\/[a-z0-9][a-z0-9_.-]{0,99}$/i;

export class ReplicateCatalog {
  private fetchFn: typeof fetch;
  private lists = new Map<string, Entry<any>>();
  private models = new Map<string, Entry<RawModel>>();
  private prices = new Map<string, Entry<PriceInfo>>();
  constructor(private o: CatalogOptions) { this.fetchFn = o.fetchFn ?? fetch; }
  get configured() { return !!this.o.token; }
  private api = () => this.o.apiBase.replace(/\/$/, '');

  private fresh<T>(m: Map<string, Entry<T>>, k: string, ttl: number) { const e = m.get(k); return e && Date.now() - e.at < ttl ? e.value : undefined; }

  private async getJson(path: string): Promise<any> {
    if (!this.o.token) throw new CatalogError("Replicate isn't set up on the server", 400);
    const res = await this.fetchFn(`${this.api()}${path}`, { headers: { authorization: `Bearer ${this.o.token}` }, signal: AbortSignal.timeout(20_000) })
      .catch(e => { throw new CatalogError(`Replicate unreachable (${(e as Error).name})`); });
    if (res.status === 404) throw new CatalogError('Replicate has no such model', 404);
    if (!res.ok) throw new CatalogError(`Replicate answered ${res.status}`);
    return res.json();
  }

  async collections(): Promise<{ slug: string; name: string; description: string }[]> {
    const hit = this.fresh(this.lists, 'collections', this.o.listTtlMs);
    if (hit) return hit;
    const out: { slug: string; name: string; description: string }[] = [];
    let path: string | null = '/collections';
    for (let i = 0; path && i < 10; i++) {
      const j: any = await this.getJson(path);
      for (const c of j.results ?? []) out.push({ slug: c.slug, name: c.name, description: c.description ?? '' });
      path = typeof j.next === 'string' && j.next && j.next !== 'null' ? j.next.replace(/^https?:\/\/[^/]+\/v1/, '') : null;
    }
    this.lists.set('collections', { at: Date.now(), value: out });
    return out;
  }

  async collection(slug: string): Promise<RawModel[]> {
    if (!/^[a-z0-9-]{1,80}$/.test(slug)) throw new CatalogError('Unknown collection', 404);
    const k = `col:${slug}`, hit = this.fresh(this.lists, k, this.o.listTtlMs);
    if (hit) return hit;
    const j = await this.getJson(`/collections/${slug}`);
    const models: RawModel[] = (j.models ?? []).filter((m: RawModel) => m.visibility !== 'private');
    this.lists.set(k, { at: Date.now(), value: models });
    for (const m of models) if (m.latest_version?.openapi_schema) this.models.set(`${m.owner}/${m.name}`, { at: Date.now(), value: m });
    return models;
  }

  /** Replicate's search (beta): ≤ 20 models; each result is read in full (schema) so compatibility can be shown. */
  async search(q: string): Promise<RawModel[]> {
    const k = `q:${q.toLowerCase()}`, hit = this.fresh(this.lists, k, this.o.listTtlMs);
    if (hit) return hit;
    let found: RawModel[];
    try {
      const j = await this.getJson(`/search?query=${encodeURIComponent(q)}&limit=20`);
      found = (j.models ?? []).map((x: any) => x.model ?? x).filter((m: RawModel) => m?.owner && m?.name);
    } catch (e) {
      // Fallback: QUERY /v1/models (the older search) isn't reachable with fetch in every runtime; an owner/name typed in
      // full is still found below.
      if (!MODEL_ID_RE.test(q.trim())) throw e;
      found = [];
    }
    if (MODEL_ID_RE.test(q.trim()) && !found.some(m => `${m.owner}/${m.name}`.toLowerCase() === q.trim().toLowerCase())) {
      try { found.unshift(await this.model(q.trim())); } catch { /* not a model */ }
    }
    const full = await mapLimit(found.slice(0, 20), 6, m => this.model(`${m.owner}/${m.name}`).catch(() => m));
    this.lists.set(k, { at: Date.now(), value: full });
    return full;
  }

  /** One model with its latest version's schema. */
  async model(id: string): Promise<RawModel> {
    if (!MODEL_ID_RE.test(id)) throw new CatalogError('Use owner/name', 400);
    const hit = this.fresh(this.models, id, this.o.modelTtlMs);
    if (hit) return hit;
    const m = (await this.getJson(`/models/${id}`)) as RawModel;
    this.models.set(id, { at: Date.now(), value: m });
    return m;
  }

  /** The model's price from its web page (cached 24 h); KNOWN_PRICES when the page can't be read; else unknown. */
  async price(id: string): Promise<PriceInfo> {
    const hit = this.fresh(this.prices, id, this.o.priceTtlMs);
    if (hit) return hit;
    let p: PriceInfo | null = null;
    try {
      const res = await this.fetchFn(`${this.o.webBase.replace(/\/$/, '')}/${id}`, { headers: { accept: 'text/html' }, signal: AbortSignal.timeout(15_000) });
      if (res.ok) p = parseModelPage(await res.text());
    } catch (e) { this.o.log?.warn({ model: id, err: (e as Error).message }, 'model page unreachable'); }
    p ??= KNOWN_PRICES[id] ?? { kind: 'unknown' };
    // An unreadable page isn't cached for long, so it is tried again soon.
    this.prices.set(id, { at: p.kind === 'unknown' ? Date.now() - this.o.priceTtlMs + 10 * 60_000 : Date.now(), value: p });
    return p;
  }
  cachedPrice(id: string) { return this.fresh(this.prices, id, this.o.priceTtlMs) ?? null; }

  view(m: RawModel, step: ImageStep, price: PriceInfo | null): CatalogModel {
    const id = `${m.owner}/${m.name}`;
    const map = m.latest_version?.openapi_schema ? mapModel(m, step) : null;
    return {
      id, owner: m.owner, name: m.name, description: (m.description ?? '').slice(0, 200), runCount: m.run_count ?? 0, official: !!m.is_official,
      coverUrl: m.cover_image_url ?? null, price, priceLine: price ? priceLine(price) : 'price on the model page',
      compatible: map ? map.compatible : null, reasons: map?.reasons ?? [], warnings: map?.warnings ?? [],
    };
  }

  /** A step's list: its collections (or one collection, or a search), most-run first, prices filled for the top ones. */
  async list(step: ImageStep, o: { q?: string; collection?: string } = {}) {
    let raw: RawModel[];
    if (o.q?.trim()) raw = await this.search(o.q.trim());
    else {
      const slugs = o.collection ? [o.collection] : STEP_COLLECTIONS[step];
      const lists = await Promise.all(slugs.map(s => this.collection(s).catch(e => { if (o.collection) throw e; return [] as RawModel[]; })));
      const seen = new Set<string>();
      raw = lists.flat().filter(m => { const k = `${m.owner}/${m.name}`; if (seen.has(k)) return false; seen.add(k); return true; })
        .sort((a, b) => (b.run_count ?? 0) - (a.run_count ?? 0));
    }
    // Prices: from the cache, and read now for the first 24 (6 at a time); the rest say "price on the model page".
    const want = o.q ? raw : raw.slice(0, 24);
    await mapLimit(want.filter(m => !this.cachedPrice(`${m.owner}/${m.name}`)), 6, m => this.price(`${m.owner}/${m.name}`).catch(() => null));
    const models = raw.map(m => this.view(m, step, this.cachedPrice(`${m.owner}/${m.name}`)));
    const all = await this.collections().catch(() => []);
    return { step, label: STEP_LABELS[step], collections: all.filter(c => STEP_COLLECTIONS[step].includes(c.slug) || c.slug === o.collection).map(c => ({ slug: c.slug, name: c.name })),
      models, cachedAt: Date.now() };
  }
}

export async function mapLimit<T, R>(items: T[], limit: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (i < items.length) { const k = i++; out[k] = await fn(items[k]!); }
  }));
  return out;
}
