// Bring your own provider · one adapter per provider kind. Each validates a key with a free read-only call, searches the
// provider's models, reads one model's schema (and price, when the provider publishes it), and runs a prediction with
// the owner's key. Everything happens server-side; keys go only into the Authorization header of calls to the
// provider's own host and never into an error message or a log line. To add a provider (e.g. an OpenAI-compatible image
// endpoint), implement ProviderAdapter and add it to ADAPTERS.
import { CREDIT_RE, errorText, ReplicateError, SAFETY_RE } from '../replicate/client.js';
import { analyse, type Analysis, type Kind } from './classify.js';

export type ProviderKind = 'replicate' | 'fal';
export type Price = { basis: 'per_run' | 'per_second'; costUsd: number; source: 'provider' | 'owner' };
export type RawModel = { ref: string; version: string | null; name: string; description: string | null; analysis: Analysis; price: Price | null };
export type Page = { models: RawModel[]; nextCursor: string | null };
export type RunStatus = { status: 'running' | 'succeeded' | 'failed' | 'canceled'; url?: string; error?: ReplicateError };
export type Urls = { replicate: string; falPlatform: string; falQueue: string };

export interface ProviderAdapter {
  kind: ProviderKind;
  label: string;
  keyHint: string;
  keyUrl: string;
  /** A free read-only call: 'ok', or 'invalid' for a refused key. Throws provider_unreachable otherwise. */
  validate(key: string): Promise<'ok' | 'invalid'>;
  search(key: string, o: { q?: string; kind?: Kind; cursor?: string | null; limit: number }): Promise<Page>;
  model(key: string, ref: string): Promise<RawModel | null>;
  start(key: string, m: { ref: string; version: string | null }, input: Record<string, unknown>): Promise<string>;
  get(key: string, handle: string): Promise<RunStatus>;
  cancel(key: string, handle: string): Promise<void>;
}

export class ProviderUnreachable extends Error { constructor(readonly kind: ProviderKind, why: string) { super(`${kind} unreachable (${why})`); } }

type Fetch = typeof fetch;
const trim = (u: string) => u.replace(/\/$/, '');
const REF_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._/-]*$/;
export const validRef = (ref: string) => REF_RE.test(ref) && ref.length <= 200 && !ref.includes('..');

/** The first URL in a prediction output: a string, a list, or {video|image|images|url}. */
export function firstUrl(o: unknown): string | undefined {
  if (typeof o === 'string') return /^https?:\/\//.test(o) ? o : undefined;
  if (Array.isArray(o)) { for (const x of o) { const u = firstUrl(x); if (u) return u; } return undefined; }
  if (o && typeof o === 'object') {
    const r = o as Record<string, unknown>;
    for (const k of ['video', 'images', 'image', 'output', 'url', 'file']) { const u = firstUrl(r[k]); if (u) return u; }
  }
  return undefined;
}

/** Turns a provider's HTTP refusal at submit into the suite's error kinds (the job failure mapping applies). */
function submitError(label: string, status: number, text: string) {
  if (status === 401) return new ReplicateError(`${label} refused the studio's key`, 'unavailable', status);
  if (status === 402 || CREDIT_RE.test(text)) return new ReplicateError(`${label} is out of credit`, 'out_of_credit', status);
  if (status === 403) return new ReplicateError(`${label} refused the studio's key`, 'unavailable', status);
  if (status === 429) return new ReplicateError(`${label} is busy`, 'rate_limited', status);
  if (status >= 500) return new ReplicateError(`${label} is having trouble (${status})`, 'unavailable', status);
  return new ReplicateError(`${label} rejected the request (${status}: ${text.slice(0, 200)})`, SAFETY_RE.test(text) ? 'refused' : 'failed', status);
}

async function call(f: Fetch, kind: ProviderKind, url: string, init: RequestInit, ms = 30_000) {
  return f(url, { ...init, signal: AbortSignal.timeout(ms) }).catch(e => { throw new ProviderUnreachable(kind, (e as Error).name); });
}

// ------------------------------------------------------------------------------------------------------------ Replicate
// https://replicate.com/docs/reference/http · Authorization: Bearer <token>. Replicate's API publishes no prices, so
// every Replicate model needs the owner's per-run estimate before it can be switched on.
export class ReplicateAdapter implements ProviderAdapter {
  kind = 'replicate' as const;
  label = 'Replicate';
  keyHint = 'An API token from replicate.com → Account → API tokens (starts with r8_)';
  keyUrl = 'https://replicate.com/account/api-tokens';
  constructor(private base: () => string, private f: Fetch = fetch) {}
  private h(key: string) { return { authorization: `Bearer ${key}`, 'content-type': 'application/json', accept: 'application/json' }; }

  async validate(key: string) {
    const r = await call(this.f, 'replicate', `${trim(this.base())}/account`, { headers: this.h(key) });
    if (r.status === 401 || r.status === 403) return 'invalid' as const;
    if (!r.ok) throw new ProviderUnreachable('replicate', String(r.status));
    return 'ok' as const;
  }

  private raw(m: any, hintKind?: Kind): RawModel | null {
    const ref = m?.owner && m?.name ? `${m.owner}/${m.name}` : null;
    if (!ref) return null;
    const doc = m.latest_version?.openapi_schema ?? {};
    const schemas = doc.components?.schemas ?? {};
    const analysis = analyse(doc, schemas.Input, { category: hintKind ? `x-to-${hintKind}` : null, text: `${m.name} ${m.description ?? ''}`, output: schemas.Output ?? null });
    return { ref, version: m.latest_version?.id ?? null, name: m.name, description: m.description ?? null, analysis, price: null };
  }

  async model(key: string, ref: string) {
    if (!validRef(ref) || ref.split('/').length !== 2) return null;
    const r = await call(this.f, 'replicate', `${trim(this.base())}/models/${ref}`, { headers: this.h(key) });
    if (r.status === 404) return null;
    if (!r.ok) throw new ProviderUnreachable('replicate', String(r.status));
    return this.raw(await r.json());
  }

  async search(key: string, o: { q?: string; kind?: Kind; cursor?: string | null; limit: number }) {
    const off = Math.max(0, Number(o.cursor) || 0);
    let items: any[] = [];
    let hint: Kind | undefined;
    if (o.q?.trim()) {
      const r = await call(this.f, 'replicate', `${trim(this.base())}/search?query=${encodeURIComponent(o.q.trim())}&limit=50`, { headers: this.h(key) });
      if (!r.ok) throw new ProviderUnreachable('replicate', String(r.status));
      const b = (await r.json()) as any;
      items = (b.models ?? b.results ?? []).map((x: any) => x?.model ?? x);
    } else {
      // No query: the provider's own text-to-video / text-to-image collections.
      const slugs = o.kind === 'image' ? ['text-to-image'] : o.kind === 'video' ? ['text-to-video', 'image-to-video'] : ['text-to-video', 'image-to-video', 'text-to-image'];
      for (const s of slugs) {
        const r = await call(this.f, 'replicate', `${trim(this.base())}/collections/${s}`, { headers: this.h(key) });
        if (!r.ok) continue;
        const b = (await r.json()) as any;
        items.push(...(b.models ?? []).map((m: any) => ({ ...m, _kind: s.endsWith('video') ? 'video' : 'image' })));
      }
      hint = o.kind;
    }
    const seen = new Set<string>();
    items = items.filter(m => { const k = `${m?.owner}/${m?.name}`; if (!m?.owner || seen.has(k)) return false; seen.add(k); return true; });
    const page = items.slice(off, off + o.limit);
    const out = await Promise.all(page.map(async m => {
      // Search results may come without the schema: read the model itself.
      const full = m.latest_version?.openapi_schema ? m : await this.detail(key, `${m.owner}/${m.name}`).catch(() => null);
      return this.raw({ ...(full ?? m), description: m.description ?? full?.description }, m._kind ?? hint);
    }));
    const models = out.filter((x): x is RawModel => !!x).filter(x => !o.kind || x.analysis.kind === o.kind || x.analysis.kind === null);
    return { models, nextCursor: off + o.limit < items.length ? String(off + o.limit) : null };
  }
  private async detail(key: string, ref: string) {
    const r = await call(this.f, 'replicate', `${trim(this.base())}/models/${ref}`, { headers: this.h(key) });
    return r.ok ? r.json() as Promise<any> : null;
  }

  async start(key: string, m: { ref: string; version: string | null }, input: Record<string, unknown>) {
    const url = m.version ? `${trim(this.base())}/predictions` : `${trim(this.base())}/models/${m.ref}/predictions`;
    const r = await call(this.f, 'replicate', url, { method: 'POST', headers: this.h(key), body: JSON.stringify(m.version ? { version: m.version, input } : { input }) }, 60_000)
      .catch(e => { throw e instanceof ProviderUnreachable ? new ReplicateError(e.message, 'unavailable') : e; });
    const text = await r.text().catch(() => '');
    if (!r.ok) throw submitError('Replicate', r.status, text);
    const j = JSON.parse(text) as { id: string };
    return JSON.stringify({ id: j.id });
  }
  async get(key: string, handle: string): Promise<RunStatus> {
    const { id } = JSON.parse(handle) as { id: string };
    const r = await this.f(`${trim(this.base())}/predictions/${encodeURIComponent(id)}`, { headers: this.h(key), signal: AbortSignal.timeout(30_000) }).catch(() => null);
    if (!r || !r.ok) return { status: 'running' };
    const p = (await r.json().catch(() => ({}))) as { status?: string; output?: unknown; error?: unknown };
    if (p.status === 'succeeded') {
      const url = firstUrl(p.output);
      return url ? { status: 'succeeded', url } : { status: 'failed', error: new ReplicateError('no output came back', 'failed') };
    }
    if (p.status === 'failed') { const t = errorText(p.error ?? 'failed'); return { status: 'failed', error: new ReplicateError(t, SAFETY_RE.test(t) ? 'refused' : CREDIT_RE.test(t) ? 'out_of_credit' : 'failed') }; }
    if (p.status === 'canceled') return { status: 'canceled' };
    return { status: 'running' };
  }
  async cancel(key: string, handle: string) {
    const { id } = JSON.parse(handle) as { id: string };
    await this.f(`${trim(this.base())}/predictions/${encodeURIComponent(id)}/cancel`, { method: 'POST', headers: this.h(key), signal: AbortSignal.timeout(30_000) }).catch(() => null);
  }
}

// ------------------------------------------------------------------------------------------------------------------ fal
// https://fal.ai/docs/platform-apis/v1/models · Authorization: Key <key>. The model list takes no key (it only lifts rate
// limits); pricing needs one, so a pricing read is the key check. Runs go through the queue (queue.fal.run).
export class FalAdapter implements ProviderAdapter {
  kind = 'fal' as const;
  label = 'fal.ai';
  keyHint = 'An API key from fal.ai → Dashboard → API keys';
  keyUrl = 'https://fal.ai/dashboard/keys';
  constructor(private urls: () => Pick<Urls, 'falPlatform' | 'falQueue'>, private f: Fetch = fetch) {}
  private h(key: string) { return { authorization: `Key ${key}`, 'content-type': 'application/json', accept: 'application/json' }; }

  async validate(key: string) {
    const r = await call(this.f, 'fal', `${trim(this.urls().falPlatform)}/models/pricing?endpoint_id=fal-ai/flux/dev`, { headers: this.h(key) });
    if (r.status === 401 || r.status === 403) return 'invalid' as const;
    if (!r.ok) throw new ProviderUnreachable('fal', String(r.status));
    return 'ok' as const;
  }

  /** Prices for up to 50 endpoints (a missing or non-USD price is left out). */
  private async prices(key: string, ids: string[]): Promise<Map<string, Price>> {
    const out = new Map<string, Price>();
    if (!ids.length) return out;
    const r = await call(this.f, 'fal', `${trim(this.urls().falPlatform)}/models/pricing?${ids.slice(0, 50).map(i => `endpoint_id=${encodeURIComponent(i)}`).join('&')}`, { headers: this.h(key) }).catch(() => null);
    if (!r?.ok) return out;
    const b = (await r.json().catch(() => ({}))) as { prices?: { endpoint_id: string; unit_price: number; unit: string; currency: string }[] };
    for (const p of b.prices ?? []) {
      if (p.currency && p.currency.toUpperCase() !== 'USD') continue;
      const c = Number(p.unit_price);
      if (!(c >= 0) || !Number.isFinite(c)) continue;
      const unit = String(p.unit ?? '').toLowerCase();
      const basis = /^(second|seconds|sec|s)$/.test(unit) ? 'per_second' : /^(image|images|video|videos|request|requests|generation|generations|run|runs)$/.test(unit) ? 'per_run' : null;
      if (basis) out.set(p.endpoint_id, { basis, costUsd: c, source: 'provider' });
    }
    return out;
  }

  private raw(m: any, price: Price | null): RawModel | null {
    const ref = m?.endpoint_id;
    if (typeof ref !== 'string') return null;
    const doc = m.openapi && !m.openapi.error ? m.openapi : {};
    const paths: Record<string, any> = doc.paths ?? {};
    const post = paths[`/${ref}`]?.post ?? Object.entries(paths).find(([p, v]: [string, any]) => v?.post && !p.includes('{'))?.[1]?.post;
    const input = post?.requestBody?.content?.['application/json']?.schema
      ?? Object.entries(doc.components?.schemas ?? {}).find(([k]) => /Input$/.test(k))?.[1];
    const resultPath = Object.entries(paths).find(([p, v]: [string, any]) => /\/requests\/\{request_id\}$/.test(p) && v?.get)?.[1] as any;
    const output = resultPath?.get?.responses?.['200']?.content?.['application/json']?.schema
      ?? Object.entries(doc.components?.schemas ?? {}).find(([k]) => /Output$/.test(k))?.[1] ?? null;
    const md = m.metadata ?? {};
    const analysis = analyse(doc, input as any, { category: md.category ?? null, text: `${md.display_name ?? ''} ${md.description ?? ''}`, output: output as any });
    return { ref, version: null, name: md.display_name ?? ref, description: md.description ?? null, analysis, price };
  }

  async model(key: string, ref: string) {
    if (!validRef(ref)) return null;
    const r = await call(this.f, 'fal', `${trim(this.urls().falPlatform)}/models?endpoint_id=${encodeURIComponent(ref)}&expand=openapi-3.0`, { headers: this.h(key) });
    if (!r.ok) throw new ProviderUnreachable('fal', String(r.status));
    const b = (await r.json()) as { models?: any[] };
    const m = (b.models ?? []).find(x => x?.endpoint_id === ref);
    if (!m) return null;
    return this.raw(m, (await this.prices(key, [ref])).get(ref) ?? null);
  }

  async search(key: string, o: { q?: string; kind?: Kind; cursor?: string | null; limit: number }) {
    const qs = new URLSearchParams({ limit: String(o.limit), expand: 'openapi-3.0', status: 'active' });
    if (o.q?.trim()) qs.set('q', o.q.trim());
    else if (o.kind) qs.set('category', o.kind === 'video' ? 'text-to-video' : 'text-to-image');
    if (o.cursor) qs.set('cursor', o.cursor);
    const r = await call(this.f, 'fal', `${trim(this.urls().falPlatform)}/models?${qs}`, { headers: this.h(key) });
    if (!r.ok) throw new ProviderUnreachable('fal', String(r.status));
    const b = (await r.json()) as { models?: any[]; next_cursor?: string | null; has_more?: boolean };
    const list = b.models ?? [];
    const prices = await this.prices(key, list.map(m => m?.endpoint_id).filter((x): x is string => typeof x === 'string'));
    const models = list.map(m => this.raw(m, prices.get(m?.endpoint_id) ?? null)).filter((x): x is RawModel => !!x)
      .filter(x => !o.kind || x.analysis.kind === o.kind || x.analysis.kind === null);
    return { models, nextCursor: b.has_more === false ? null : b.next_cursor ?? null };
  }

  async start(key: string, m: { ref: string }, input: Record<string, unknown>) {
    const q = trim(this.urls().falQueue);
    const r = await call(this.f, 'fal', `${q}/${m.ref}`, { method: 'POST', headers: this.h(key), body: JSON.stringify(input) }, 60_000)
      .catch(e => { throw e instanceof ProviderUnreachable ? new ReplicateError(e.message, 'unavailable') : e; });
    const text = await r.text().catch(() => '');
    if (!r.ok) throw submitError('fal', r.status, text);
    const j = JSON.parse(text) as { request_id: string; status_url?: string; response_url?: string; cancel_url?: string };
    const base = `${q}/${m.ref.split('/').slice(0, 2).join('/')}/requests/${encodeURIComponent(j.request_id)}`;
    // The key is only ever sent to the queue's own host: URLs pointing anywhere else are replaced by the documented ones.
    const same = (u: string | undefined) => { try { return u && new URL(u).origin === new URL(q).origin ? u : undefined; } catch { return undefined; } };
    return JSON.stringify({ id: j.request_id, s: same(j.status_url) ?? `${base}/status`, r: same(j.response_url) ?? base, c: same(j.cancel_url) ?? `${base}/cancel` });
  }
  async get(key: string, handle: string): Promise<RunStatus> {
    const h = JSON.parse(handle) as { s: string; r: string };
    const res = await this.f(h.s, { headers: this.h(key), signal: AbortSignal.timeout(30_000) }).catch(() => null);
    if (!res || !res.ok) return { status: 'running' };
    const st = (await res.json().catch(() => ({}))) as { status?: string; error?: unknown };
    if (st.status === 'COMPLETED') {
      const out = await this.f(h.r, { headers: this.h(key), signal: AbortSignal.timeout(30_000) }).catch(() => null);
      const body = (await out?.json().catch(() => ({}))) as Record<string, unknown> | undefined;
      const url = firstUrl(body);
      if (!out?.ok || !url) { const t = errorText((body as any)?.detail ?? st.error ?? `status ${out?.status}`); return { status: 'failed', error: new ReplicateError(t, SAFETY_RE.test(t) ? 'refused' : 'failed') }; }
      return { status: 'succeeded', url };
    }
    if (st.status === 'FAILED' || st.error) { const t = errorText(st.error ?? 'failed'); return { status: 'failed', error: new ReplicateError(t, SAFETY_RE.test(t) ? 'refused' : 'failed') }; }
    return { status: 'running' };
  }
  async cancel(key: string, handle: string) {
    const h = JSON.parse(handle) as { c: string };
    await this.f(h.c, { method: 'PUT', headers: this.h(key), signal: AbortSignal.timeout(30_000) }).catch(() => null);
  }
}

export const KINDS: ProviderKind[] = ['replicate', 'fal'];
export function adapters(urls: () => Urls, f: Fetch = fetch): Record<ProviderKind, ProviderAdapter> {
  return { replicate: new ReplicateAdapter(() => urls().replicate, f), fal: new FalAdapter(() => urls(), f) };
}
