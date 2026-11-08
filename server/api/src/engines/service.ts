// WS13 · model choice everywhere (plans/model-choice.md, plans/api.md "Model choice"): one owner catalog of every model
// MUSE can run, per purpose; validation of an owner's override (`engineModel` / `imageModel`); and the studio's default
// model per purpose (suite_settings.engine_defaults). Members only ever see custom models the owner made available, by
// display name, never a provider or model ref.
import { eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest } from '../errors.js';
import * as P from '../pricing.js';
import { MODEL_ID_RE } from '../replicate/catalog.js';
import { modelName, type StepOverrides } from '../images/steps.js';
import { customModelsOf, DEFAULT_LADDER, EXTEND_LADDER, inputSlotsOf, MODELS, modelById, NO_INPUTS, RECAST_LADDER, type InputSlots, type ModelSpec } from '../suite/registry.js';
import { suiteSettings } from '../suite/schema.js';
import { editorAi, GPU_SEC } from '../editor/service.js';
import { IMAGE_CANDIDATES, isPurpose, PURPOSE_INFO, PURPOSES, SWAP_ENGINES, swapEngineById, TOOL_MODEL_KIND, videoPurposes, type EngineKind, type Purpose } from './purposes.js';

export type Price = { basis: 'per_second' | 'per_run' | 'per_output_second'; usd: number };
export type Engine = {
  model: string; name: string; kind: EngineKind; purposes: Purpose[]; custom: boolean;
  /** Owner only. */
  provider?: string; notice?: string | null; members?: boolean;
  limits: { minSeconds: number | null; maxSeconds: number | null; allowedSeconds: number[] | null; aspectRatios: string[]; resolutions: { id: string; label: string }[]; maxInputSeconds: number | null };
  resolution: string | null; price: Price | null; inputs: InputSlots;
};
export type Choice = { model: string; source: 'request' | 'studio'; engine: Engine };

const r4 = (v: number) => Math.round(v * 10000) / 10000;
const VIDEO_PURPOSES = PURPOSES.filter(p => PURPOSE_INFO[p].kind === 'video');
const IMAGE_PURPOSES = PURPOSES.filter(p => PURPOSE_INFO[p].kind === 'image');
const LADDER_PURPOSES: Purpose[] = ['shot', 'talking', 'ugc', 'storyboard', 'guide', 'fill', 'recast', 'extend'];
const noLimits = { minSeconds: null, maxSeconds: null, allowedSeconds: null, aspectRatios: [], resolutions: [], maxInputSeconds: null };

const services = new WeakMap<Ctx, ModelChoice>();
export const modelChoice = (ctx: Ctx) => { let s = services.get(ctx); if (!s) { s = new ModelChoice(ctx); services.set(ctx, s); } return s; };

export class ModelChoice {
  constructor(private ctx: Ctx) {}

  // ------------------------------------------------------------------ candidates
  /** Swap engines that can run now (hosted: Replicate set up and the model not switched off; GPU: the pods offer it). */
  private swapUsable(prefs: { models?: Record<string, { enabled?: boolean }> }) {
    const caps = this.ctx.jobs.capabilities();
    return SWAP_ENGINES.filter(e => e.runs === 'replicate' ? this.ctx.replicate.configured && prefs.models?.[e.id]?.enabled !== false : caps.includes(e.capability!));
  }
  /** $ per output second of a swap on `id` at `quality` (hosted: the registry price × priceScale; GPU: Edit/Fast's estimate). */
  swapPrice(id: string, quality: string, clipSeconds: number | null | undefined, priceScale = 1): { perSec: number; resolution: string | null; rr: P.RenderReq } {
    const e = swapEngineById(id)!;
    const q = (P.QUALITY_IDS as string[]).includes(quality) ? quality as P.Quality : 'standard';
    if (e.runs === 'gpu') {
      const rr: P.RenderReq = { engine: e.gpuEngine!, use: 'full', steps: P.STEPS_DEFAULT, takes: 1, clipSeconds: clipSeconds ?? P.SAMPLE_CLIP_SEC };
      return { perSec: r4(P.estCost(rr) / Math.max(1, P.lengthSec(rr))), resolution: null, rr };
    }
    const m = modelById(e.id)!;
    const want = P.QUALITY_INFO[q].resolution;
    const res = m.resolutions.find(r => r.id === want) ?? m.resolutions.at(-1)!;
    const perSec = r4(res.perSec * priceScale);
    return { perSec, resolution: res.id, rr: { engine: 'replicate', quality: q, takes: 1, clipSeconds, pricePerSec: perSec } };
  }

  /** The quote for a swap on a chosen engine: its `RenderReq` (priced like /v1/jobs prices it) for `takes` of a clip. */
  async swapQuote(studioId: string, id: string, quality: string | undefined, clipSeconds: number | null | undefined, takes = 1) {
    const prefs = await this.ctx.suite.prefs(studioId);
    const q = this.swapPrice(id, quality ?? 'standard', clipSeconds, prefs.models?.[id]?.priceScale ?? 1);
    const e = swapEngineById(id)!;
    const rr: P.RenderReq = e.runs === 'gpu' ? { ...q.rr, takes, clipSeconds } : { ...q.rr, takes };
    return { ...q, rr, cost: P.totalCost(rr) };
  }

  private videoEntry(m: ModelSpec, purposes: Purpose[], scale: number, resolution?: string): Engine {
    const res = (resolution && m.resolutions.find(r => r.id === resolution)) || m.resolutions.at(-1)!;
    const perRun = m.byo?.perRunUsd ? r4(m.byo.perRunUsd * scale) : null;
    return { model: m.id, name: m.byo?.displayName ?? m.name, kind: 'video', purposes, custom: !!m.byo, provider: m.byo ? m.byo.providerKind : m.provider,
      notice: m.licence.notice ?? null, ...(m.byo ? { members: m.byo.members } : {}),
      limits: { minSeconds: m.duration.min, maxSeconds: m.duration.max, allowedSeconds: m.duration.allowed ?? null, aspectRatios: m.aspectRatios,
        resolutions: m.resolutions.map(r => ({ id: r.id, label: r.label })), maxInputSeconds: m.recast?.sourceSeconds[1] ?? m.extend?.sourceSeconds[1] ?? m.refs.videoSecondsMax ?? null },
      resolution: res.id, price: perRun != null ? { basis: 'per_run', usd: perRun } : { basis: 'per_second', usd: r4(res.perSec * scale) }, inputs: inputSlotsOf([m]) };
  }

  private async videoEngines(studioId: string): Promise<Engine[]> {
    const suite = this.ctx.suite;
    const p = await suite.prefs(studioId);
    const avail = suite.mode === 'off' ? new Set() : suite.available();
    const ladderRes = (id: string) => { for (const t of ['draft', 'standard', 'hd', 'cinema'] as const) { const s = (p.ladder?.[t]?.length ? p.ladder[t]! : DEFAULT_LADDER[t]).find(x => x.model === id); if (s) return s.resolution; } return undefined; };
    const out = new Map<string, Engine>();
    for (const m of [...MODELS, ...customModelsOf(studioId)]) {
      const pref = p.models?.[m.id];
      if (m.status === 'removed' || m.licence.blockNewFeatures || pref?.enabled === false || (m.licence.requiresAck && !pref?.acknowledgedAt) || !avail.has(m.provider)) continue;
      const purposes = videoPurposes(m);
      if (purposes.length) out.set(m.id, this.videoEntry(m, purposes, pref?.priceScale ?? 1, ladderRes(m.id)));
    }
    // Character swap (and Recreate swap fills): the hosted H3 family joins with "swap"; Edit / Fast on our GPU are added.
    for (const e of this.swapUsable(p)) {
      const cur = out.get(e.id);
      if (e.runs === 'replicate') {
        const m = modelById(e.id)!, sp = this.swapPrice(e.id, 'standard', null, p.models?.[e.id]?.priceScale ?? 1);
        const base = cur ?? this.videoEntry(m, [], p.models?.[e.id]?.priceScale ?? 1, sp.resolution ?? undefined);
        out.set(e.id, { ...base, purposes: PURPOSES.filter(x => base.purposes.includes(x) || x === 'swap' || x === 'fill'),
          limits: { ...base.limits, minSeconds: P.REPLICATE_MIN_SEC, maxInputSeconds: P.REPLICATE_MAX_SEC } });
      } else {
        const sp = this.swapPrice(e.id, 'standard', P.SAMPLE_CLIP_SEC);
        out.set(e.id, { model: e.id, name: e.name, kind: 'video', purposes: ['swap', 'fill'], custom: false, provider: 'runpod', notice: e.notice ?? null,
          limits: { ...noLimits, maxSeconds: P.MAX_CLIP_SEC, aspectRatios: ['9:16'], maxInputSeconds: P.MAX_CLIP_SEC },
          resolution: null, price: { basis: 'per_second', usd: sp.perSec }, inputs: NO_INPUTS });
      }
    }
    return [...out.values()];
  }

  private async imageEngines(studioId: string, u: AuthUser): Promise<Engine[]> {
    const im = this.ctx.imageModels;
    const shot = await im.resolve(studioId, 'shot').catch(() => null);
    const ids = [...new Set([shot?.model, this.ctx.config.REPLICATE_IMAGE_MODEL, ...IMAGE_CANDIDATES].filter((x): x is string => !!x))];
    const n = 3, inMp = P.PHOTO_REF_MP * n;
    const inputs = { ...NO_INPUTS, images: Math.min(6, this.ctx.config.REPLICATE_IMAGE_MAX_INPUTS) };
    const out: Engine[] = [];
    for (const id of ids) {
      const usd = im.isRecipe('shot', id) ? P.newShotEstimateImages(this.ctx.images.photoPrices(), 2, n) : await im.estimate(id, { outMp: 2, inMp }).catch(() => null);
      out.push({ model: id, name: modelName(id), kind: 'image', purposes: [...IMAGE_PURPOSES], custom: false, provider: 'replicate', notice: null,
        limits: noLimits, resolution: null, price: usd == null ? null : { basis: 'per_run', usd: r4(usd) }, inputs });
    }
    // WS5: the studio's custom image models (Photo runs them; the other image paths use the image engine's step models).
    for (const c of await this.ctx.suite.byo.catalog({ ...u, studioId, role: 'owner' } as AuthUser)) if (c.kind === 'image') {
      const cc = c as typeof c & { members?: boolean; provider?: string };
      out.push({ model: c.id, name: c.name, kind: 'image', purposes: ['photo'], custom: true, provider: cc.provider, members: !!cc.members, notice: null,
        limits: { ...noLimits, aspectRatios: c.aspectRatios }, resolution: null, price: c.price as Price, inputs: c.inputs });
    }
    return out;
  }

  private toolEngines(): Engine[] {
    const out: Engine[] = [];
    const caps = this.ctx.jobs.capabilities();
    const prices = P.upscalePrices(this.ctx.config.UPSCALE_PRICES);
    const sizes = P.UPSCALE_SIZES.filter(z => prices[z.id]);
    if (caps.includes('upscale') && sizes.length)
      out.push({ model: 'seedvr2', name: 'SeedVR2 (own GPU)', kind: 'tool', purposes: ['upscale'], custom: false, provider: 'runpod', notice: null,
        limits: { ...noLimits, resolutions: sizes.map(z => ({ id: z.id, label: z.label })) }, resolution: sizes[0]!.id,
        price: { basis: 'per_output_second', usd: Math.min(...sizes.map(z => prices[z.id]!.usdPerSec)) }, inputs: NO_INPUTS });
    const ed = editorAi(this.ctx), pr = ed.provider;
    for (const purpose of ['matte', 'track', 'captions', 'denoise'] as const) {
      const k = TOOL_MODEL_KIND[purpose], model = pr.models[k];
      // $ per second of source media, for a one-minute clip (start-up included), after the editor markup.
      const usd = r4(GPU_SEC[k](60) / 60 * pr.rates[k] * ed.markup);
      out.push({ model, name: modelName(model), kind: 'tool', purposes: [purpose], custom: false, provider: pr.name, notice: null,
        limits: noLimits, resolution: null, price: { basis: 'per_second', usd }, inputs: NO_INPUTS });
    }
    return out;
  }

  /** Every engine of the studio (owner view), or only those of one kind. */
  async all(u: AuthUser, kinds: EngineKind[] = ['video', 'image', 'tool']): Promise<Engine[]> {
    return [
      ...(kinds.includes('video') ? await this.videoEngines(u.studioId) : []),
      ...(kinds.includes('image') ? await this.imageEngines(u.studioId, u) : []),
      ...(kinds.includes('tool') ? this.toolEngines() : []),
    ];
  }
  /** The candidates for one purpose (owner view). */
  async candidates(u: AuthUser, purpose: Purpose) {
    return (await this.all(u, [PURPOSE_INFO[purpose].kind])).filter(e => e.purposes.includes(purpose));
  }

  // ------------------------------------------------------------------ defaults
  /** What runs when nothing is picked: a fixed model, or the quality ladder (first usable step of the default quality). */
  async builtin(u: AuthUser, purpose: Purpose, cands?: Engine[]): Promise<{ model: string | null; rule: 'fixed' | 'ladder' }> {
    const list = cands ?? await this.candidates(u, purpose);
    const has = (id: string) => list.some(e => e.model === id);
    if (LADDER_PURPOSES.includes(purpose)) {
      const prefs = await this.ctx.suite.prefs(u.studioId);
      const steps = purpose === 'recast' ? RECAST_LADDER.draft : purpose === 'extend' ? EXTEND_LADDER.draft : (prefs.ladder?.draft?.length ? prefs.ladder.draft : DEFAULT_LADDER.draft);
      return { model: steps.map(s => s.model).find(has) ?? null, rule: 'ladder' };
    }
    if (purpose === 'swap') {
      const id = SWAP_ENGINES.find(e => e.ref === this.ctx.config.REPLICATE_VIDEO_MODEL)?.id ?? 'h3';
      return { model: has(id) ? id : list[0]?.model ?? null, rule: 'fixed' };
    }
    if (PURPOSE_INFO[purpose].kind === 'image') return { model: (await this.ctx.imageModels.resolve(u.studioId, 'shot').catch(() => null))?.model ?? null, rule: 'fixed' };
    return { model: list[0]?.model ?? null, rule: 'fixed' };
  }

  async studioDefaults(studioId: string): Promise<Partial<Record<Purpose, string>>> {
    const [r] = await this.ctx.db.select({ d: suiteSettings.engineDefaults }).from(suiteSettings).where(eq(suiteSettings.studioId, studioId));
    return Object.fromEntries(Object.entries(r?.d ?? {}).filter(([k, v]) => isPurpose(k) && typeof v === 'string')) as Partial<Record<Purpose, string>>;
  }

  /** GET /v1/engines/defaults (owner). */
  async defaultsView(u: AuthUser) {
    const d = await this.studioDefaults(u.studioId);
    const builtin: Record<string, string | null> = {};
    for (const p of PURPOSES) builtin[p] = (await this.builtin(u, p)).model;
    return { defaults: Object.fromEntries(PURPOSES.map(p => [p, d[p] ?? null])), builtin };
  }
  /** PATCH /v1/engines/defaults (owner): {purpose: model | null}. Each model must be a candidate for its purpose. */
  async setDefaults(u: AuthUser, body: unknown) {
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw badRequest('Send {purpose: model or null}');
    const cur = await this.studioDefaults(u.studioId);
    const next: Record<string, string> = { ...cur };
    for (const [k, v] of Object.entries(body as Record<string, unknown>)) {
      if (!isPurpose(k)) throw badRequest(`Unknown purpose ${k} · one of ${PURPOSES.join(', ')}`);
      if (v === null || v === '') { delete next[k]; continue; }
      if (typeof v !== 'string') throw badRequest(`${k}: a model id or null`);
      next[k] = (await this.check(u, k, v)).model;
    }
    await this.ctx.suite.prefs(u.studioId); // the studio's custom models are loaded
    const row = { studioId: u.studioId, models: {}, engineDefaults: next, updatedBy: u.id, updatedAt: Date.now() };
    await this.ctx.db.insert(suiteSettings).values(row).onConflictDoUpdate({ target: suiteSettings.studioId, set: { engineDefaults: next, updatedBy: u.id, updatedAt: row.updatedAt } });
    return this.defaultsView(u);
  }

  // ------------------------------------------------------------------ views and checks
  /** What a member may see of an entry: custom models the owner made available, no provider or licence line. */
  private memberView(e: Engine): Engine | null {
    if (!e.custom || !e.members) return null;
    const { provider: _p, notice: _n, members: _m, ...rest } = e;
    return rest;
  }

  /** GET /v1/engines[?purpose=]. */
  async list(u: AuthUser, purpose?: unknown) {
    if (purpose !== undefined && purpose !== '' && !isPurpose(purpose)) throw badRequest(`purpose: one of ${PURPOSES.join(', ')}`);
    const only = isPurpose(purpose) ? purpose : null;
    const studio = await this.studioDefaults(u.studioId);
    const engines = only ? await this.candidates(u, only) : await this.all(u);
    const purposes = [];
    for (const p of only ? [only] : PURPOSES) {
      const cands = only ? engines : engines.filter(e => e.purposes.includes(p));
      const b = await this.builtin(u, p, cands);
      const st = studio[p] && cands.some(e => e.model === studio[p]) ? studio[p]! : null;
      purposes.push({ id: p, label: PURPOSE_INFO[p].label, kind: PURPOSE_INFO[p].kind, default: st ?? b.model, studioDefault: u.role === 'owner' ? st : null, rule: st ? 'fixed' : b.rule });
    }
    const def = only ? purposes[0]!.default : null;
    const shown = u.role === 'owner' ? engines : engines.map(e => this.memberView(e)).filter((e): e is Engine => !!e);
    const view = shown.map(e => ({ ...e, ...(only ? { default: e.model === def } : {}) }));
    if (u.role !== 'owner') return { purposes: purposes.map(p => ({ ...p, default: null, rule: p.rule })), engines: view };
    return { purposes, engines: view };
  }

  /**
   * An override for a purpose: allowed for this user and a candidate (image purposes also take any Replicate "owner/name",
   * checked against its schema when it runs). 403 owner_only for members (unless a custom model the owner made available);
   * 400 engine_not_allowed with the valid list otherwise.
   */
  async check(u: AuthUser, purpose: Purpose, model: string): Promise<Engine> {
    const cands = await this.candidates(u, purpose);
    const e = cands.find(x => x.model === model);
    if (u.role !== 'owner') {
      if (e?.custom && e.members) return e;
      throw new ApiError(403, 'owner_only', 'Only the studio owner can pick the engine');
    }
    if (e) return e;
    if (PURPOSE_INFO[purpose].kind === 'image' && MODEL_ID_RE.test(model))
      return { model, name: modelName(model), kind: 'image', purposes: [purpose], custom: false, provider: 'replicate', notice: null, limits: noLimits, resolution: null, price: null, inputs: NO_INPUTS };
    const err = new ApiError(400, 'engine_not_allowed', `That model can't be used for ${PURPOSE_INFO[purpose].label}`);
    (err as ApiError & { extra?: unknown }).extra = { purpose, valid: cands.map(x => x.model) };
    throw err;
  }

  /**
   * Image steps for a run of an image purpose (outfits, character photos): the request's `models` map (owner, per step) as
   * before; else `imageModel` (checked) or the studio's default for the purpose, as the new-shot step's model.
   */
  async imageOverrides(u: AuthUser, purpose: Purpose, body: Record<string, unknown>): Promise<StepOverrides | undefined> {
    const base = this.ctx.imageModels.overridesFrom(u.role, body as { models?: unknown });
    if (base?.shot) return base;
    const im = body.imageModel;
    if (im !== undefined && im !== null && (typeof im !== 'string' || im.length > 170)) throw badRequest('imageModel: owner/name');
    const c = await this.choose(u, purpose, (im as string | null | undefined) || undefined);
    if (!c || c.model.startsWith('c_')) return base;
    return { ...(base ?? {}), shot: c.model };
  }

  /** The model for a run: the request's override (checked), else the studio's default when still a candidate, else none. */
  async choose(u: AuthUser, purpose: Purpose, requested?: string | null): Promise<Choice | null> {
    if (requested) return { model: requested, source: 'request', engine: await this.check(u, purpose, requested) };
    const d = (await this.studioDefaults(u.studioId))[purpose];
    if (!d) return null;
    const e = (await this.candidates(u, purpose)).find(x => x.model === d);
    // A member runs on the studio's default too, unless it's a custom model the owner kept to themselves.
    if (!e || (u.role !== 'owner' && e.custom && !e.members)) return null;
    return { model: d, source: 'studio', engine: e };
  }
}

export { VIDEO_PURPOSES };

/**
 * Character swap on a chosen engine (POST /v1/jobs, the Suite's swap mode, Recreate swap fills). Mutates the jobs request:
 * the engine (hosted, or Edit / Fast on our GPU), the hosted model ref and the swap engine id. A request that names Edit or
 * Fast itself (engine "h3" / "viggle") keeps it unless it also asks for a model; the studio default applies to the hosted
 * swap. `pre`: a choice the caller already made (undefined: choose now). Returns the choice, or null (built-in behaviour).
 */
export async function applySwapEngine(mc: ModelChoice, u: AuthUser, r: Record<string, any>, requested?: string | null, pre?: Choice | null): Promise<Choice | null> {
  for (const k of ['swapEngine', 'videoModel', 'videoNoResolution']) delete r[k]; // never taken from the client
  if (!requested && pre === undefined && r.engine && r.engine !== 'replicate') return null;
  const choice = pre !== undefined ? pre : await mc.choose(u, 'swap', requested);
  if (!choice) return null;
  const e = swapEngineById(choice.model);
  if (!e) return null;
  if (e.runs === 'gpu') { r.engine = e.gpuEngine; r.use = 'full'; delete r.quality; }
  else { r.engine = 'replicate'; r.videoModel = e.ref; if (e.noResolution) r.videoNoResolution = true; }
  r.swapEngine = e.id;
  return choice;
}
