// The model behind each image step (plans/api.md "Model tools" §2): the owner's choice per studio (studio_settings.
// image_models), a per-run override from the owner's own flows, or the default. Prices: config for the two original
// defaults, the model page for anything else (prices.ts), the known table when the page can't be read.
import { eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { studioSettings } from '../db/schema.js';
import { ApiError, badRequest } from '../errors.js';
import { CatalogError, KNOWN_PRICES, MODEL_ID_RE, ReplicateCatalog } from '../replicate/catalog.js';
import { IMAGE_STEPS, isSafetySwitch, mapModel, STEP_LABELS, type ImageStep, type RawModel } from '../replicate/mapping.js';
import { estimateOne, priceLine, type CostCtx, type PriceInfo } from '../replicate/prices.js';

export type StepChoice = { model: string; extra: Record<string, unknown>; isDefault: boolean };
export type StepOverrides = Partial<Record<ImageStep, string>>;

/** Display names for models we know; anything else shows its owner/name. */
const MODEL_NAMES: Record<string, string> = {
  'black-forest-labs/flux-2-pro': 'FLUX.2 [pro]', 'black-forest-labs/flux-2-dev': 'FLUX.2 [dev]', 'black-forest-labs/flux-2-max': 'FLUX.2 [max]',
  'black-forest-labs/flux-2-flex': 'FLUX.2 [flex]', 'qwen/qwen-image-edit-2511': 'Qwen Image Edit 2511', 'qwen/qwen-image-edit-plus': 'Qwen Image Edit Plus',
  'black-forest-labs/flux-krea-dev': 'FLUX.1 Krea [dev]', 'philz1337x/clarity-upscaler': 'Clarity Upscaler', 'topazlabs/image-upscale': 'Topaz Image Upscale',
};
export const modelName = (id: string) => MODEL_NAMES[id] ?? id;

export class ImageModels {
  readonly catalog: ReplicateCatalog;
  constructor(private ctx: Ctx, fetchFn?: typeof fetch) {
    const c = ctx.config;
    this.catalog = new ReplicateCatalog({ token: c.REPLICATE_API_TOKEN, apiBase: c.REPLICATE_API_URL, webBase: c.REPLICATE_WEB_URL,
      listTtlMs: c.REPLICATE_CATALOG_TTL_SEC * 1000, modelTtlMs: c.REPLICATE_SCHEMA_TTL_SEC * 1000, priceTtlMs: c.REPLICATE_PRICE_TTL_SEC * 1000,
      fetchFn, log: ctx.log });
  }

  defaults(): Record<ImageStep, string> {
    const c = this.ctx.config;
    return { shot: c.REPLICATE_IMAGE_MODEL, edit: c.REPLICATE_IMAGE_EDIT_MODEL, realism: c.REPLICATE_REALISM_MODEL, upscale: c.REPLICATE_UPSCALE_MODEL,
      dressA: c.REPLICATE_DRESS_A_MODEL, dressB: c.REPLICATE_DRESS_B_MODEL };
  }
  estOpts() { return { timeEstSec: this.ctx.config.REPLICATE_TIME_EST_SEC, unknownUsd: this.ctx.config.REPLICATE_UNKNOWN_EST_USD }; }

  private async stored(studioId: string) {
    const [s] = await this.ctx.db.select({ m: studioSettings.imageModels }).from(studioSettings).where(eq(studioSettings.studioId, studioId));
    return (s?.m ?? {}) as Record<string, { model: string; extra?: Record<string, unknown> }>;
  }

  /** The model for a step: the per-run override, else the studio's choice, else the default. */
  async resolve(studioId: string, step: ImageStep, overrides?: StepOverrides | null): Promise<StepChoice> {
    const st = (await this.stored(studioId))[step];
    const def = this.defaults()[step];
    const o = overrides?.[step];
    if (o) return { model: o, extra: o === st?.model ? st?.extra ?? {} : {}, isDefault: o === def };
    if (st?.model) return { model: st.model, extra: st.extra ?? {}, isDefault: st.model === def };
    return { model: def, extra: {}, isDefault: true };
  }
  async resolveAll(studioId: string, overrides?: StepOverrides | null) {
    const out = {} as Record<ImageStep, StepChoice>;
    for (const s of IMAGE_STEPS) out[s] = await this.resolve(studioId, s, overrides);
    return out;
  }

  /** The two original defaults run on their tested inputs and config prices (plans/api.md "App clean-up" §3). */
  isRecipe(step: ImageStep, model: string) {
    const c = this.ctx.config;
    return (step === 'shot' && model === c.REPLICATE_IMAGE_MODEL) || (step === 'edit' && model === c.REPLICATE_IMAGE_EDIT_MODEL);
  }

  /** The price of a model: config for the original defaults, its page, the known table, or unknown. */
  async price(model: string): Promise<PriceInfo> {
    const c = this.ctx.config;
    if (model === c.REPLICATE_IMAGE_MODEL) return { kind: 'per-unit', source: 'config', units: [
      { metric: 'run_count', usd: c.REPLICATE_IMAGE_RUN_USD, label: 'per run' }, { metric: 'image_input_megapixel_count', usd: c.REPLICATE_IMAGE_MP_USD, label: 'per input image megapixel' },
      { metric: 'image_output_megapixel_count', usd: c.REPLICATE_IMAGE_MP_USD, label: 'per output image megapixel' }] };
    if (model === c.REPLICATE_IMAGE_EDIT_MODEL) return { kind: 'per-unit', source: 'config', units: [{ metric: 'image_output_count', usd: c.REPLICATE_IMAGE_EDIT_USD, label: 'per output image' }] };
    if (!this.catalog.configured) return KNOWN_PRICES[model] ?? { kind: 'unknown' };
    return this.catalog.price(model);
  }

  async estimate(model: string, cc: CostCtx) { return estimateOne(await this.price(model), cc, this.estOpts()); }

  /** A model with its schema; outside the catalog (no token) a stand-in for the known defaults. */
  async info(model: string): Promise<RawModel> {
    try { return await this.catalog.model(model); }
    catch (e) {
      if (e instanceof CatalogError && e.status === 404) throw new ApiError(404, 'not_found', `Replicate has no model ${model}`);
      throw e;
    }
  }

  /** Owner override map from a request body: owner only; each value must look like owner/name. */
  overridesFrom(role: string, body: { models?: unknown }): StepOverrides | undefined {
    const m = body.models;
    if (m == null) return undefined;
    if (role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can choose models');
    if (typeof m !== 'object' || Array.isArray(m)) throw badRequest('models: expected {step: "owner/name"}');
    const out: StepOverrides = {};
    for (const [k, v] of Object.entries(m as Record<string, unknown>)) {
      if (!(IMAGE_STEPS as readonly string[]).includes(k)) throw badRequest(`models: unknown step ${k}`);
      if (v == null || v === '') continue;
      if (typeof v !== 'string' || !MODEL_ID_RE.test(v)) throw badRequest(`models.${k}: use owner/name`);
      out[k as ImageStep] = v;
    }
    return out;
  }

  /** One step's view for owner Settings → Engines → Image models. */
  async view(studioId: string, step: ImageStep) {
    const ch = await this.resolve(studioId, step);
    const def = this.defaults()[step];
    const price = await this.price(ch.model).catch(() => ({ kind: 'unknown' } as PriceInfo));
    let raw: RawModel | null = null;
    try { raw = this.catalog.configured ? await this.catalog.model(ch.model) : null; } catch { raw = null; }
    const map = raw ? mapModel(raw, step) : null;
    return { step, label: STEP_LABELS[step], model: ch.model, defaultModel: def, isDefault: ch.model === def, name: modelName(ch.model),
      official: raw ? !!raw.is_official : ch.model !== 'philz1337x/clarity-upscaler', description: (raw?.description ?? '').slice(0, 200),
      price, priceLine: priceLine(price), compatible: map ? map.compatible : true, reasons: map?.reasons ?? [], warnings: map?.warnings ?? [],
      mapping: map?.mapping ?? {}, extra: ch.extra };
  }
  /** The steps the owner picks models for (Dress up's dressA / dressB stay stored but hidden: the feature was removed 2026-11-11). */
  async views(studioId: string) { return { steps: await Promise.all(IMAGE_STEPS.filter(s => s !== 'dressA' && s !== 'dressB').map(s => this.view(studioId, s))) }; }

  /** Owner picks a model for a step (checked against its schema), with optional extra inputs. */
  async set(studioId: string, step: ImageStep, model: string, extra?: Record<string, unknown>) {
    if (!MODEL_ID_RE.test(model)) throw badRequest('model: use owner/name');
    if (!this.catalog.configured) throw new ApiError(400, 'engine_unavailable', "Replicate isn't set up on the server");
    const raw = await this.info(model);
    const map = mapModel(raw, step);
    if (!map.compatible) throw new ApiError(400, 'model_incompatible', `This model can't do ${STEP_LABELS[step]}: ${map.reasons.join(', ')}`);
    const ex = extra ?? {};
    if (JSON.stringify(ex).length > 4096) throw badRequest('extra: at most 4 KB');
    const names = new Set(map.inputs.map(i => i.name));
    for (const k of Object.keys(ex)) {
      if (isSafetySwitch(k)) throw badRequest(`extra: ${k} can't be changed`);
      if (!names.has(k)) throw badRequest(`extra: ${model} has no input ${k}`);
    }
    await this.ctx.money.settings(studioId);
    const cur = await this.stored(studioId);
    await this.ctx.db.update(studioSettings).set({ imageModels: { ...cur, [step]: { model, extra: ex } } }).where(eq(studioSettings.studioId, studioId));
    return this.view(studioId, step);
  }
  async reset(studioId: string, step: ImageStep) {
    await this.ctx.money.settings(studioId);
    const cur = { ...(await this.stored(studioId)) };
    delete cur[step];
    await this.ctx.db.update(studioSettings).set({ imageModels: cur }).where(eq(studioSettings.studioId, studioId));
    return this.view(studioId, step);
  }

  /** One model in full, for the owner's "paste any owner/model" and advanced view. */
  async detail(id: string, step: ImageStep) {
    const raw = await this.info(id);
    const price = await this.price(id).catch(() => ({ kind: 'unknown' } as PriceInfo));
    const map = mapModel(raw, step);
    return { ...this.catalog.view(raw, step, price), mapping: map.mapping, inputs: map.inputs, version: raw.latest_version?.id ?? null };
  }
}
