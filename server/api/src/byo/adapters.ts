// Bring your own provider · one adapter per provider kind. Each validates a key with a free read-only call, searches the
// provider's models, reads one model's schema (and price, when the provider publishes it), and runs a prediction with
// the owner's key. Everything happens server-side; keys go only into the auth header (Authorization, or Muapi's x-api-key)
// of calls to the provider's own host and never into an error message or a log line. To add a provider (e.g. an
// OpenAI-compatible image endpoint), implement ProviderAdapter and add it to KINDS and adapters().
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CREDIT_RE, errorText, ReplicateError, SAFETY_RE } from '../replicate/client.js';
import { analyse, type Analysis, type Kind } from './classify.js';

export type ProviderKind = 'replicate' | 'fal' | 'muapi' | 'higgsfield';
export type Price = { basis: 'per_run' | 'per_second'; costUsd: number; source: 'provider' | 'owner' };
export type RawModel = { ref: string; version: string | null; name: string; description: string | null; analysis: Analysis; price: Price | null };
export type Page = { models: RawModel[]; nextCursor: string | null };
export type RunStatus = { status: 'running' | 'succeeded' | 'failed' | 'canceled'; url?: string; error?: ReplicateError };
export type Urls = { replicate: string; falPlatform: string; falQueue: string; muapi: string; higgsfield: string };

export interface ProviderAdapter {
  kind: ProviderKind;
  label: string;
  keyHint: string;
  keyUrl: string;
  /** Whether `ref` has this provider's model-id shape (checked before any call; refuses path tricks). */
  validRef(ref: string): boolean;
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
/** An `owner/name[/…]` model id (Replicate, fal). */
export const validRef = (ref: string) => REF_RE.test(ref) && ref.length <= 200 && !ref.includes('..');
const SEGMENT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
/** A single path segment (Muapi model names and endpoints): no slash, no `..`. */
export const validSegment = (ref: string) => SEGMENT_RE.test(ref) && ref.length <= 100 && !ref.includes('..');

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
  validRef(ref: string) { return validRef(ref) && ref.split('/').length === 2; }
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
  validRef(ref: string) { return validRef(ref); }
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

// ---------------------------------------------------------------------------------------------------------------- Muapi
// https://muapi.ai/llms.txt · https://api.muapi.ai/openapi.json · auth header `x-api-key: <key>`. The model list
// (GET /models), one model's schema (GET /models/{name}) and price quotes (POST /models/{name}/estimate-cost) are public,
// so they're called WITHOUT the key; the key goes only on the balance check, submits, polls and cancels, all on Muapi's
// own host. A model's ref is its catalog name (one path segment, e.g. "seedance-2-t2v"); a run POSTs to its
// `endpoint_url` (e.g. "seedance-v2.0-t2v"), kept as the model's version. Results: GET /predictions/{id}/result.
const MUAPI_CATEGORIES: Record<string, Kind> = { 'text to video': 'video', 'image to video': 'video', 'text to image': 'image', 'image to image': 'image' };
const MUAPI_TYPES: Record<string, string> = { int: 'integer', integer: 'integer', float: 'number', double: 'number', number: 'number', bool: 'boolean', boolean: 'boolean', str: 'string', string: 'string', list: 'array', array: 'array' };
const MUAPI_SINGLE_URL = /(_url|_uri)$|^(image|start_image|end_image|first_image|last_image|first_frame|last_frame|start_frame|end_frame)$/;
/** Muapi fields that are always lists: a single URL MUSE sends there goes in as a one-item list. */
const MUAPI_LIST = /(_list|_urls)$|^(reference_images|images)$/;
/** Muapi's own words for an account that can't pay (its docs don't publish them; CREDIT_RE covers the usual ones). */
const MUAPI_CREDIT_RE = /\b(insufficient|not enough (credits?|balance|funds)|low balance|top[ -]?up|out of credits?)\b|INSUFFICIENT_[A-Z_]+/i;
const MUAPI_KEY_RE = /not authori[sz]ed|invalid (api[ _-]?)?key|missing or invalid credentials|unauthori[sz]ed/i;
const MUAPI_TTL = 10 * 60_000;

/**
 * One Muapi input schema in JSON Schema terms, so classify.ts reads it like Replicate's and fal's: its `int`/`float`/`bool`
 * types, `minValue`/`maxValue` (and `step`, as an enum when short), URL fields (they carry no `format`) marked as URIs,
 * and, on a video model, a list that takes exactly one image read as the start frame.
 */
export function muapiSchema(raw: any, kind: Kind | null): { type: 'object'; properties: Record<string, any>; required: string[] } {
  const props: Record<string, any> = {};
  for (const [n, v0] of Object.entries((raw?.properties ?? {}) as Record<string, any>)) {
    if (!v0 || typeof v0 !== 'object') continue;
    const v: Record<string, any> = { ...v0 };
    if (typeof v.type === 'string') v.type = MUAPI_TYPES[v.type.toLowerCase()] ?? v.type;
    if (v.minimum === undefined && Number.isFinite(Number(v.minValue))) v.minimum = Number(v.minValue);
    if (v.maximum === undefined && Number.isFinite(Number(v.maxValue))) v.maximum = Number(v.maxValue);
    const step = Number(v.step);
    if (!Array.isArray(v.enum) && (v.type === 'integer' || v.type === 'number') && step > 0 && Number.isFinite(v.minimum) && Number.isFinite(v.maximum)
      && v.maximum >= v.minimum && (v.maximum - v.minimum) / step <= 30) {
      v.enum = Array.from({ length: Math.floor((v.maximum - v.minimum) / step + 1e-9) + 1 }, (_, i) => Math.round((v.minimum + i * step) * 1000) / 1000);
    }
    if (v.type === 'string' && !Array.isArray(v.enum) && !v.format && MUAPI_SINGLE_URL.test(n)) v.format = 'uri';
    if (v.type === 'array' && /image/.test(n)) v.items = { ...(v.items ?? {}), type: 'string', format: 'uri' };
    if (kind === 'video' && v.type === 'array' && /image/.test(n) && Number(v.maxItems) === 1 && MUAPI_LIST.test(n))
      Object.assign(v, { type: 'string', format: 'uri', items: undefined, maxItems: undefined });
    props[n] = v;
  }
  return { type: 'object', properties: props, required: Array.isArray(raw?.required) ? raw.required.filter((x: unknown) => typeof x === 'string') : [] };
}

/** At most `n` at a time. */
async function pool<T, R>(items: T[], n: number, f: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => { while (i < items.length) { const k = i++; out[k] = await f(items[k]!); } }));
  return out;
}

/**
 * A price from a provider's quote call: quoted at the shortest and longest durations at every resolution (up to 4), and
 * the dearest rate is kept so a run never costs the studio more than it charges: per second when the cost grows with the
 * duration, per run when it doesn't. Any failed quote: null (the owner sets the price).
 */
export async function dearestPrice(a: Analysis, base: Record<string, unknown>, quote: (body: Record<string, unknown>) => Promise<number | null>): Promise<Price | null> {
  const d = a.kind === 'video' && a.map.duration ? a.inputs.duration : null;
  const durs = d ? [...new Set(d.allowed?.length ? [d.allowed[0]!, d.allowed.at(-1)!] : [d.min, d.max])] : [null];
  const res = a.map.resolution && a.inputs.resolutions.length ? a.inputs.resolutions.slice(0, 4) : [null];
  const shape = (v: number) => a.shapes.duration === 'string' ? String(v) : a.shapes.duration === 'integer' ? Math.round(v) : v;
  const cases = durs.flatMap(s => res.map(r => ({ s, r })));
  const quotes = await pool(cases, 4, async c => {
    const body: Record<string, unknown> = { ...base };
    if (c.s != null) body[a.map.duration!] = shape(c.s);
    if (c.r != null) body[a.map.resolution!] = c.r;
    return { ...c, cost: await quote(body) };
  });
  if (quotes.some(q => q.cost == null)) return null;
  const round = (x: number) => Math.round(x * 1e6) / 1e6;
  const most = Math.max(...quotes.map(q => q.cost!));
  if (!d || durs.length < 2) return { basis: 'per_run', costUsd: round(most), source: 'provider' };
  const flat = res.every(r => { const [lo, hi] = durs.map(s => quotes.find(q => q.s === s && q.r === r)!.cost!); return Math.abs(hi! - lo!) <= 0.01 * Math.max(hi!, 1e-9); });
  if (flat) return { basis: 'per_run', costUsd: round(most), source: 'provider' };
  return { basis: 'per_second', costUsd: round(Math.max(...quotes.map(q => q.cost! / q.s!))), source: 'provider' };
}

export class MuapiAdapter implements ProviderAdapter {
  kind = 'muapi' as const;
  label = 'Muapi';
  keyHint = 'An API key from muapi.ai → Access keys';
  keyUrl = 'https://muapi.ai/access-keys';
  private list: { at: number; models: any[] } | null = null;
  private details = new Map<string, { at: number; value: RawModel | null }>();
  constructor(private base: () => string, private f: Fetch = fetch) {}
  validRef(ref: string) { return validSegment(ref); }
  /** The key goes only here (x-api-key), on calls to Muapi's own host. */
  private h(key: string) { return { 'x-api-key': key, 'content-type': 'application/json', accept: 'application/json' }; }
  private get pub() { return { 'content-type': 'application/json', accept: 'application/json' }; }

  /** GET /account/balance: free and read-only. Muapi answers 403 (sometimes 401) to a missing or refused key. */
  async validate(key: string) {
    const r = await call(this.f, 'muapi', `${trim(this.base())}/account/balance`, { headers: this.h(key) });
    if (r.status === 401 || r.status === 403) return 'invalid' as const;
    if (!r.ok) throw new ProviderUnreachable('muapi', String(r.status));
    return 'ok' as const;
  }

  /** The public catalog, image and video generators only (cached 10 min: it's one ~600 KB list). */
  private async catalog(): Promise<any[]> {
    if (this.list && Date.now() - this.list.at < MUAPI_TTL) return this.list.models;
    const r = await call(this.f, 'muapi', `${trim(this.base())}/models`, { headers: this.pub });
    if (!r.ok) throw new ProviderUnreachable('muapi', String(r.status));
    const b = (await r.json().catch(() => ({}))) as { models?: any[] };
    const models = (Array.isArray(b) ? b : b.models ?? []).filter((m: any) => typeof m?.name === 'string' && validSegment(m.name)
      && MUAPI_CATEGORIES[String(m.category ?? '').toLowerCase()] && (m.domain ?? 'ai') === 'ai' && m.is_enabled !== 0 && m.is_enabled !== false && !m.is_coming_soon);
    this.list = { at: Date.now(), models };
    return models;
  }

  /** One price quote at Muapi's own list price (no key, so no account discount: never below what the owner pays). */
  private async quote(name: string, body: Record<string, unknown>): Promise<number | null> {
    const r = await call(this.f, 'muapi', `${trim(this.base())}/models/${encodeURIComponent(name)}/estimate-cost`, { method: 'POST', headers: this.pub, body: JSON.stringify(body) }).catch(() => null);
    if (!r?.ok) return null;
    const b = (await r.json().catch(() => ({}))) as { cost?: unknown; currency?: string };
    const c = Number(b.cost);
    return (b.currency && b.currency.toUpperCase() !== 'USD') || !Number.isFinite(c) || c < 0 ? null : c;
  }

  /**
   * Muapi publishes a USD price per model. A fixed price is used as is (per run). A dynamic one (it depends on duration,
   * resolution…) is quoted by dearestPrice. No quote, no price: the owner sets one (Price corrections).
   */
  private async price(m: any, a: Analysis): Promise<Price | null> {
    if (m.cost_currency && String(m.cost_currency).toUpperCase() !== 'USD') return null;
    const base = Number(m.cost);
    if (m.dynamic_pricing === false || m.cost_strategy === 'fixed_cost') return Number.isFinite(base) && base >= 0 ? { basis: 'per_run', costUsd: base, source: 'provider' } : null;
    return dearestPrice(a, { prompt: 'x' }, body => this.quote(m.name, body));
  }

  /** One model with its schema and price (cached 10 min). */
  private async detail(name: string): Promise<RawModel | null> {
    const hit = this.details.get(name);
    if (hit && Date.now() - hit.at < MUAPI_TTL) return hit.value;
    const r = await call(this.f, 'muapi', `${trim(this.base())}/models/${encodeURIComponent(name)}`, { headers: this.pub });
    if (r.status === 404) return null;
    if (!r.ok) throw new ProviderUnreachable('muapi', String(r.status));
    const m = (await r.json().catch(() => null)) as any;
    if (!m || m.name !== name || m.is_coming_soon === true || m.is_enabled === 0 || m.is_enabled === false) return null; // can't run yet
    const endpoint = typeof m.endpoint_url === 'string' ? m.endpoint_url.replace(/^\/?(api\/v1\/)?/, '') : name;
    if (!validSegment(endpoint)) return null;
    const kind = MUAPI_CATEGORIES[String(m.category ?? '').toLowerCase()] ?? null;
    const input = muapiSchema(m.input_schema?.schemas?.input_data ?? m.input_schema ?? {}, kind);
    const analysis = analyse({}, input, { category: kind ? `x-to-${kind}` : String(m.category ?? '').toLowerCase().replace(/\s+/g, '-'), text: `${m.name} ${m.description ?? ''}` });
    const value: RawModel = { ref: name, version: endpoint, name, description: m.description ?? null, analysis, price: await this.price(m, analysis) };
    // A missing price may be a quote that failed for now: kept 30 s, not 10 min.
    this.details.set(name, { at: value.price ? Date.now() : Date.now() - MUAPI_TTL + 30_000, value });
    if (this.details.size > 500) this.details.delete(this.details.keys().next().value!);
    return value;
  }

  async model(_key: string, ref: string) {
    if (!validSegment(ref)) return null;
    return this.detail(ref);
  }

  /** Muapi has no text search: the catalog is filtered here (every word, in the name, description, family or category). */
  async search(_key: string, o: { q?: string; kind?: Kind; cursor?: string | null; limit: number }) {
    const off = Math.max(0, Number(o.cursor) || 0);
    const words = (o.q ?? '').toLowerCase().split(/\s+/).filter(Boolean);
    const all = (await this.catalog()).filter(m => (!o.kind || MUAPI_CATEGORIES[String(m.category).toLowerCase()] === o.kind)
      && words.every(w => `${m.name} ${m.description ?? ''} ${m.family ?? ''} ${m.category ?? ''}`.toLowerCase().includes(w)));
    const page = all.slice(off, off + o.limit);
    const out = await pool(page, 6, m => this.detail(m.name).catch(() => null));
    const models = out.filter((x): x is RawModel => !!x).filter(x => !o.kind || x.analysis.kind === o.kind || x.analysis.kind === null);
    return { models, nextCursor: off + o.limit < all.length ? String(off + o.limit) : null };
  }

  /** Our input URLs are public https (presigned), which Muapi takes as is: nothing is uploaded to /upload_file. */
  async start(key: string, m: { ref: string; version: string | null }, input: Record<string, unknown>) {
    const endpoint = m.version ?? m.ref;
    if (!validSegment(endpoint)) throw new ReplicateError('not a Muapi model', 'failed');
    const body = Object.fromEntries(Object.entries(input).map(([k, v]) => [k, typeof v === 'string' && MUAPI_LIST.test(k) ? [v] : v]));
    const r = await call(this.f, 'muapi', `${trim(this.base())}/${endpoint}`, { method: 'POST', headers: this.h(key), body: JSON.stringify(body) }, 60_000)
      .catch(e => { throw e instanceof ProviderUnreachable ? new ReplicateError(e.message, 'unavailable') : e; });
    const text = await r.text().catch(() => '');
    if (!r.ok) throw muapiError(r.status, text);
    let id: unknown;
    try { id = (JSON.parse(text) as { request_id?: unknown; id?: unknown }).request_id ?? (JSON.parse(text) as { id?: unknown }).id; } catch { id = null; }
    if (typeof id !== 'string' || !id) throw new ReplicateError('Muapi gave no request id', 'failed');
    return JSON.stringify({ id });
  }
  async get(key: string, handle: string): Promise<RunStatus> {
    const { id } = JSON.parse(handle) as { id: string };
    const r = await this.f(`${trim(this.base())}/predictions/${encodeURIComponent(id)}/result`, { headers: this.h(key), signal: AbortSignal.timeout(30_000) }).catch(() => null);
    if (r && (r.status === 401 || r.status === 403)) return { status: 'failed', error: new ReplicateError("Muapi refused the studio's key", 'unavailable', r.status) };
    if (!r || !r.ok) return { status: 'running' };
    const p = (await r.json().catch(() => ({}))) as { status?: string; outputs?: unknown[]; error?: unknown; has_nsfw_contents?: unknown[] };
    const st = String(p.status ?? '').toLowerCase();
    if (st === 'completed' || st === 'succeeded') {
      const outs = Array.isArray(p.outputs) ? p.outputs : [];
      const flags = Array.isArray(p.has_nsfw_contents) ? p.has_nsfw_contents : [];
      // Muapi flags outputs it thinks are NSFW: those aren't used; all flagged is a refusal.
      const url = firstUrl(outs.filter((_, i) => flags[i] !== true));
      if (url) return { status: 'succeeded', url };
      if (flags.some(x => x === true)) return { status: 'failed', error: new ReplicateError('Muapi flagged the result as NSFW', 'refused') };
      return { status: 'failed', error: new ReplicateError('no output came back', 'failed') };
    }
    if (st === 'failed' || st === 'error') {
      const t = errorText(p.error ?? 'failed');
      return { status: 'failed', error: new ReplicateError(t, SAFETY_RE.test(t) ? 'refused' : CREDIT_RE.test(t) || MUAPI_CREDIT_RE.test(t) ? 'out_of_credit' : 'failed') };
    }
    if (st === 'cancelled' || st === 'canceled') return { status: 'canceled' };
    return { status: 'running' }; // queued, pending, processing
  }
  /** Best effort: Muapi documents no cancel in its public API; its dashboard's POST /app/cancel_prediction/{id} is tried. */
  async cancel(key: string, handle: string) {
    const { id } = JSON.parse(handle) as { id: string };
    const root = trim(this.base()).replace(/\/api\/v1$/, '');
    await this.f(`${root}/app/cancel_prediction/${encodeURIComponent(id)}`, { method: 'POST', headers: this.h(key), signal: AbortSignal.timeout(30_000) }).catch(() => null);
  }
}

/** A Muapi refusal at submit as the suite's error kinds. Muapi answers 403 (not 401) to a refused key. */
export function muapiError(status: number, text: string) {
  const t = text.slice(0, 500);
  if (status === 402 || CREDIT_RE.test(t) || MUAPI_CREDIT_RE.test(t)) return new ReplicateError('Muapi is out of credit', 'out_of_credit', status);
  if (SAFETY_RE.test(t)) return new ReplicateError(`Muapi refused the request (${t.slice(0, 200)})`, 'refused', status);
  if (status === 401 || (status === 403 && (MUAPI_KEY_RE.test(t) || !t.trim()))) return new ReplicateError("Muapi refused the studio's key", 'unavailable', status);
  if (status === 429) return new ReplicateError('Muapi is busy', 'rate_limited', status);
  if (status >= 500) return new ReplicateError(`Muapi is having trouble (${status})`, 'unavailable', status);
  return new ReplicateError(`Muapi rejected the request (${status}: ${t.slice(0, 200)})`, 'failed', status);
}

// ----------------------------------------------------------------------------------------------------------- Higgsfield
// https://docs.higgsfield.ai (llms-full.txt) · auth `Authorization: Key <key_id>:<key_secret>` on api.higgsfield.ai only.
// Higgsfield has NO model-list or schema API: the catalog is assets/higgsfield/catalog.json, built from the "Complete JSON
// schema" on each model page of its docs (scripts/higgsfield-catalog.py; refresh when Higgsfield adds models). Prices
// come live from POST /estimate/{endpoint} (free, keyed, priced for this account). A run is POST /{endpoint} with the
// flat input, polled at its status_url (GET /requests/{id}/status: queued, in_progress, completed, failed, nsfw,
// canceled; result images[].url or video.url); cancel is POST /requests/{id}/cancel (queued only). Money: a prepaid USD
// balance; 403 means no balance (or an expired/disabled key: code api_key_expired / api_key_disabled), 401 a bad key.
export const HIGGSFIELD_CATALOG = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../assets/higgsfield/catalog.json');
export type HfEntry = { ref: string; name: string; kind: Kind; docs: string; schema: { type?: string; properties?: Record<string, any>; required?: string[] } };
let hfCatalog: HfEntry[] | null = null;
/** The documented Higgsfield models (read once). */
export function higgsfieldCatalog(file = HIGGSFIELD_CATALOG): HfEntry[] {
  if (hfCatalog && file === HIGGSFIELD_CATALOG) return hfCatalog;
  const list = ((JSON.parse(fs.readFileSync(file, 'utf8')) as { models?: HfEntry[] }).models ?? [])
    .filter(m => typeof m?.ref === 'string' && validRef(m.ref) && (m.kind === 'image' || m.kind === 'video') && m.schema && typeof m.schema === 'object');
  if (file === HIGGSFIELD_CATALOG) hfCatalog = list;
  return list;
}
const HF_KEY_RE = /api_key_(expired|disabled)|invalid credentials/i;
/** Higgsfield's words for an empty balance (403 "Not enough credits" in its SDKs; "insufficient balance" in its docs). */
const HF_CREDIT_RE = /not enough (credits?|balance|funds)|insufficient (balance|credits?|funds)|top[ -]?up/i;
/** Placeholder media for price quotes (the estimate prices the request; it fetches nothing). */
const HF_SAMPLE = { image: 'https://example.com/muse-estimate.jpg', video: 'https://example.com/muse-estimate.mp4', audio: 'https://example.com/muse-estimate.wav' };

/** A Higgsfield refusal at submit (or quote) as the suite's error kinds. */
export function higgsfieldError(status: number, text: string) {
  const t = text.slice(0, 500);
  if (status === 401 || (status === 403 && HF_KEY_RE.test(t))) return new ReplicateError("Higgsfield refused the studio's key", 'unavailable', status);
  if (status === 402 || status === 403 || CREDIT_RE.test(t) || HF_CREDIT_RE.test(t)) return new ReplicateError('Higgsfield is out of credit', 'out_of_credit', status);
  if (SAFETY_RE.test(t)) return new ReplicateError(`Higgsfield refused the request (${t.slice(0, 200)})`, 'refused', status);
  if (status === 429) return new ReplicateError('Higgsfield is busy', 'rate_limited', status);
  if (status === 423 || status === 503) return new ReplicateError('Higgsfield has paused this model for now', 'unavailable', status);
  if (status >= 500) return new ReplicateError(`Higgsfield is having trouble (${status})`, 'unavailable', status);
  return new ReplicateError(`Higgsfield rejected the request (${status}: ${t.slice(0, 200)})`, 'failed', status);
}

/** A request body with every required field filled with a sample value (for the free estimate). */
export function higgsfieldSample(schema: HfEntry['schema'], a: Analysis): Record<string, unknown> {
  const props = schema.properties ?? {}, out: Record<string, unknown> = {};
  const media = (n: string) => /video/.test(n) ? HF_SAMPLE.video : /audio/.test(n) ? HF_SAMPLE.audio : HF_SAMPLE.image;
  const want = new Set([...(schema.required ?? []), ...[a.map.prompt, a.map.startImage].filter((x): x is string => !!x)]);
  for (const n of want) {
    const p = props[n];
    if (!p) continue;
    if (p.default !== undefined && p.default !== null) { out[n] = p.default; continue; }
    if (Array.isArray(p.enum) && p.enum.length) { out[n] = p.enum[0]; continue; }
    if (p.type === 'array') { const it = p.items ?? {}; out[n] = Array.from({ length: Math.max(1, Number(p.minItems) || 1) }, () => it.format === 'uri' ? media(n) : it.type === 'string' ? 'x' : {}); continue; }
    if (p.type === 'string') { out[n] = p.format === 'uri' ? media(n) : p.format === 'uuid' ? '00000000-0000-0000-0000-000000000000' : 'x'; continue; }
    if (p.type === 'integer' || p.type === 'number') { out[n] = Number.isFinite(Number(p.minimum)) ? Number(p.minimum) : 1; continue; }
    if (p.type === 'boolean') out[n] = false;
  }
  return out;
}

export class HiggsfieldAdapter implements ProviderAdapter {
  kind = 'higgsfield' as const;
  label = 'Higgsfield';
  keyHint = 'An API key from console.higgsfield.ai, as KEY_ID:KEY_SECRET';
  keyUrl = 'https://console.higgsfield.ai';
  private details = new Map<string, { at: number; value: RawModel | null }>();
  constructor(private base: () => string, private f: Fetch = fetch, private catalogFile = HIGGSFIELD_CATALOG) {}
  validRef(ref: string) { return validRef(ref) && ref.split('/').length <= 6; }
  private h(key: string) { return { authorization: `Key ${key}`, 'content-type': 'application/json', accept: 'application/json' }; }
  private entries() { return higgsfieldCatalog(this.catalogFile); }

  /** The free estimate of a cheap image model: 401 (or an expired/disabled key) is a refused key. */
  async validate(key: string) {
    const r = await call(this.f, 'higgsfield', `${trim(this.base())}/estimate/higgsfield-ai/soul/v2/standard`, { method: 'POST', headers: this.h(key), body: JSON.stringify({ prompt: 'x' }) });
    const text = await r.text().catch(() => '');
    if (r.status === 401 || (r.status === 403 && HF_KEY_RE.test(text))) return 'invalid' as const;
    if (r.ok || r.status === 403 || r.status === 422) return 'ok' as const; // an empty balance or a picky body is still a good key
    throw new ProviderUnreachable('higgsfield', String(r.status));
  }

  /** One quote for this account (USD), or null. */
  private async quote(key: string, ref: string, body: Record<string, unknown>): Promise<number | null> {
    const r = await call(this.f, 'higgsfield', `${trim(this.base())}/estimate/${ref}`, { method: 'POST', headers: this.h(key), body: JSON.stringify(body) }).catch(() => null);
    if (!r?.ok) return null;
    const b = (await r.json().catch(() => ({}))) as { usd?: unknown; currency?: string };
    const c = Number(b.usd);
    return (b.currency && b.currency.toUpperCase() !== 'USD') || !Number.isFinite(c) || c < 0 ? null : c;
  }

  /** One documented model with its schema and this account's price (cached 10 min; a missing price 30 s). */
  private async detail(key: string, e: HfEntry): Promise<RawModel> {
    const hit = this.details.get(e.ref);
    if (hit?.value && Date.now() - hit.at < MUAPI_TTL) return hit.value;
    const analysis = analyse({}, e.schema as any, { category: `x-to-${e.kind}`, text: e.name });
    const price = await dearestPrice(analysis, higgsfieldSample(e.schema, analysis), body => this.quote(key, e.ref, body));
    const value: RawModel = { ref: e.ref, version: null, name: e.name, description: e.docs, analysis, price };
    this.details.set(e.ref, { at: price ? Date.now() : Date.now() - MUAPI_TTL + 30_000, value });
    return value;
  }

  async model(key: string, ref: string) {
    if (!this.validRef(ref)) return null;
    const e = this.entries().find(x => x.ref === ref);
    return e ? this.detail(key, e) : null;
  }

  /** The documented catalog, filtered here (every word, in the name or endpoint id). */
  async search(key: string, o: { q?: string; kind?: Kind; cursor?: string | null; limit: number }) {
    const off = Math.max(0, Number(o.cursor) || 0);
    const words = (o.q ?? '').toLowerCase().split(/\s+/).filter(Boolean);
    const all = this.entries().filter(e => (!o.kind || e.kind === o.kind) && words.every(w => `${e.name} ${e.ref}`.toLowerCase().includes(w)));
    const page = all.slice(off, off + o.limit);
    const models = await pool(page, 4, e => this.detail(key, e));
    return { models, nextCursor: off + o.limit < all.length ? String(off + o.limit) : null };
  }

  /** Our input URLs are public https (presigned), which Higgsfield takes as is: nothing goes to /files. */
  async start(key: string, m: { ref: string }, input: Record<string, unknown>) {
    if (!this.validRef(m.ref)) throw new ReplicateError('not a Higgsfield model', 'failed');
    const b = trim(this.base());
    const r = await call(this.f, 'higgsfield', `${b}/${m.ref}`, { method: 'POST', headers: this.h(key), body: JSON.stringify(input) }, 60_000)
      .catch(e => { throw e instanceof ProviderUnreachable ? new ReplicateError(e.message, 'unavailable') : e; });
    const text = await r.text().catch(() => '');
    if (!r.ok) throw higgsfieldError(r.status, text);
    let j: { request_id?: unknown; status_url?: string; cancel_url?: string } = {};
    try { j = JSON.parse(text); } catch { /* below */ }
    if (typeof j.request_id !== 'string' || !j.request_id) throw new ReplicateError('Higgsfield gave no request id', 'failed');
    const req = `${b}/requests/${encodeURIComponent(j.request_id)}`;
    // The key is only ever sent to Higgsfield's own host: URLs pointing anywhere else are replaced by the documented ones.
    const same = (u: string | undefined) => { try { return u && new URL(u).origin === new URL(b).origin ? u : undefined; } catch { return undefined; } };
    return JSON.stringify({ id: j.request_id, s: same(j.status_url) ?? `${req}/status`, c: same(j.cancel_url) ?? `${req}/cancel` });
  }
  async get(key: string, handle: string): Promise<RunStatus> {
    const h = JSON.parse(handle) as { s: string };
    const r = await this.f(h.s, { headers: this.h(key), signal: AbortSignal.timeout(30_000) }).catch(() => null);
    if (r && r.status === 401) return { status: 'failed', error: new ReplicateError("Higgsfield refused the studio's key", 'unavailable', 401) };
    if (!r || !r.ok) return { status: 'running' };
    const st = (await r.json().catch(() => ({}))) as { status?: string; error?: unknown; images?: unknown; video?: unknown };
    const s = String(st.status ?? '').toLowerCase();
    if (s === 'completed') {
      const url = firstUrl({ video: st.video, images: st.images });
      return url ? { status: 'succeeded', url } : { status: 'failed', error: new ReplicateError('Higgsfield finished without a result', 'failed') };
    }
    if (s === 'nsfw') return { status: 'failed', error: new ReplicateError('Higgsfield’s content check refused this', 'refused') };
    if (s === 'failed') { const t = errorText(st.error ?? 'failed'); return { status: 'failed', error: new ReplicateError(t, SAFETY_RE.test(t) ? 'refused' : CREDIT_RE.test(t) || HF_CREDIT_RE.test(t) ? 'out_of_credit' : 'failed') }; }
    if (s === 'canceled' || s === 'cancelled') return { status: 'canceled' };
    return { status: 'running' }; // queued, in_progress
  }
  /** Higgsfield cancels only while queued (a running one answers 400 and finishes; Higgsfield bills it). */
  async cancel(key: string, handle: string) {
    const h = JSON.parse(handle) as { c: string };
    await this.f(h.c, { method: 'POST', headers: this.h(key), signal: AbortSignal.timeout(30_000) }).catch(() => null);
  }
}

export const KINDS = ['replicate', 'fal', 'muapi', 'higgsfield'] as const satisfies readonly ProviderKind[];
export function adapters(urls: () => Urls, f: Fetch = fetch): Record<ProviderKind, ProviderAdapter> {
  return { replicate: new ReplicateAdapter(() => urls().replicate, f), fal: new FalAdapter(() => urls(), f), muapi: new MuapiAdapter(() => urls().muapi, f),
    higgsfield: new HiggsfieldAdapter(() => urls().higgsfield, f) };
}
