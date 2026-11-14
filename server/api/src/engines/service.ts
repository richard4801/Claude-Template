// WS13 · model choice everywhere (plans/model-choice.md, plans/api.md "Model choice"): one owner catalog of every model
// MUSE can run, per purpose; validation of an owner's override (`engineModel` / `imageModel`); and the studio's default
// model per purpose (suite_settings.engine_defaults). 4c (owner 2026-11-11): members see and pick every video and image
// model the owner hasn't hidden from them, with the provider's company name while "Show provider names to members" is
// on (engines/members.ts); tools, studio defaults, licence lines and arbitrary Replicate refs stay owner only.
import { ASSEMBLY_MAX_RATE, ASSEMBLY_MODEL } from '../editor/assemblyai.js';
import { eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest } from '../errors.js';
import * as P from '../pricing.js';
import { MODEL_ID_RE } from '../replicate/catalog.js';
import { estimateOne } from '../replicate/prices.js';

/** How many of Replicate's image models the picker lists beyond the curated ones. */
const BROWSE_IMAGE_MODELS = 40;
import { modelName, type StepOverrides } from '../images/steps.js';
import { sideOf } from '../suite/plan.js';
import { memberRules, saveMemberRules, type MemberRules } from './members.js';
import { labelList } from './labels.js';
import { DEFAULT_LADDER, EXTEND_LADDER, familyOf, inputSlotsOf, modelById, NO_INPUTS, RECAST_LADDER, type InputSlots, type ModelSpec } from '../suite/registry.js';
import { suiteSettings } from '../suite/schema.js';
import { adaptedExtend } from '../suite/extend.js';
import { remixSupport } from '../suite/remix.js';
import { editorAi, GPU_SEC } from '../editor/service.js';
import { IMAGE_CANDIDATES, isPurpose, toPurpose, PURPOSE_INFO, PURPOSES, SWAP_ENGINES, swapEngineById, HF_SWAP_MIN_SEC, GENJUTSU_KEEPS, GENJUTSU_RES, TOOL_MODEL_KIND, videoPurposes, type EngineKind, type Purpose } from './purposes.js';

export type Price = { basis: 'per_second' | 'per_run' | 'per_output_second'; usd: number };
export type Engine = {
  model: string; name: string; kind: EngineKind; purposes: Purpose[]; custom: boolean;
  /** What to show: "<Model> · <Provider>" (engines/labels.ts); `name` is the model's own name without the provider. */
  label?: string;
  /** Owner only (members: `provider` + `providerName` while the studio shows provider names). */
  provider?: string; providerName?: string; notice?: string | null;
  /** Shown to members (owner view; video and image models). */
  members?: boolean;
  /** Internal: one of Replicate's popular image models the picker lists for the owner (not a model the owner added). */
  browsed?: boolean;
  limits: { minSeconds: number | null; maxSeconds: number | null; allowedSeconds: number[] | null; aspectRatios: string[]; resolutions: { id: string; label: string }[]; maxInputSeconds: number | null };
  resolution: string | null; price: Price | null; inputs: InputSlots;
  /** Genjutsu: what it keeps from the clip and what it changes (plain words for the picker), and when Auto picks it. */
  keeps?: typeof GENJUTSU_KEEPS; bestFor?: string;
  /**
   * Owner 2026-11-12 ("every model on every mode"): `native` = made for this purpose; `adapted` = MUSE adapts what it
   * can't take natively and says so in the plan (`fitNote` is the picker's one line). Only in a purpose's list.
   */
  fit?: 'native' | 'adapted'; fitNote?: string;
  /** Priced live from the provider's free quote (Wan 3.0 on Higgsfield): `price` is null until a request is planned. */
  livePrice?: boolean;
  /**
   * Owner 2026-11-14 (one model, several providers): every resolution the model makes across its providers, each with
   * its $/s and the provider (and full label) it runs on. 0 with `livePrice` = priced when a shot is planned.
   */
  resolutions?: ResolutionPrice[];
  /** With ?resolution=: whether this model makes it, else the nearest it makes (picking it moves there), in words. */
  resolutionFit?: { asked: string; has: boolean; resolution: string; note: string | null };
};
export type ResolutionPrice = { id: string; label: string; perSec: number; provider?: string; providerName?: string; modelLabel?: string; livePrice?: boolean };
export type Choice = { model: string; source: 'request' | 'studio'; engine: Engine };

const r4 = (v: number) => Math.round(v * 10000) / 10000;

/** The picker's line for a model used outside the purposes it's made for: what MUSE does with it there. */
export function adaptNote(id: string, fallbackName: string, purpose: Purpose): string {
  const m = modelById(id);
  const n = m?.byo?.displayName ?? m?.name ?? fallbackName;
  if (!m) return `${n}: MUSE adapts what it can't take, and says what it changed`;
  const shots = m.modes.text || m.modes.image || m.modes.reference;
  switch (purpose) {
    case 'swap': case 'recast': return `${n} runs as a New Swap with her as Character (one person): ${remixSupport(m, { character: { kind: 'model', modelId: '' } }).notes[0] ?? 'it edits the clip'}`;
    case 'extend': return adaptedExtend(m)?.note ?? `${n} edits a clip in place or takes words only: it can't add new seconds`;
    default:
      if (!shots) return `${n} edits an existing video: it can't make a shot from words or pictures · use it in New Swap`;
      if (purpose === 'talking' && m.refs.audios === 0) return `${n} takes no voice track: MUSE writes the words to say in the prompt`;
      if (purpose === 'ugc' && m.refs.images === 0) return `${n} takes no product photo: MUSE describes the product in words`;
      if (purpose === 'guide') return `${n} takes no guide clip: MUSE describes the camera move in words`;
      return `${n}: MUSE adapts what it can't take (frames, references, length) and says what it changed`;
  }
}
const VIDEO_PURPOSES = PURPOSES.filter(p => PURPOSE_INFO[p].kind === 'video');
const IMAGE_PURPOSES = PURPOSES.filter(p => PURPOSE_INFO[p].kind === 'image');
const LADDER_PURPOSES: Purpose[] = ['shot', 'talking', 'ugc', 'storyboard', 'guide', 'fill', 'recast', 'extend'];
const noLimits = { minSeconds: null, maxSeconds: null, allowedSeconds: null, aspectRatios: [], resolutions: [], maxInputSeconds: null };

const services = new WeakMap<Ctx, ModelChoice>();
export const modelChoice = (ctx: Ctx) => { let s = services.get(ctx); if (!s) { s = new ModelChoice(ctx); services.set(ctx, s); } return s; };

export class ModelChoice {
  constructor(private ctx: Ctx) {}

  /** The studio's suite settings (model switches, price corrections, ladders). */
  prefs(studioId: string) { return this.ctx.suite.prefs(studioId); }

  // ------------------------------------------------------------------ candidates
  /** Swap engines that can run now (hosted: Replicate set up and the model not switched off; GPU: the pods offer it). */
  private swapUsable(prefs: { models?: Record<string, { enabled?: boolean }> }) {
    const caps = this.ctx.jobs.capabilities();
    return SWAP_ENGINES.filter(e => e.runs === 'replicate' ? this.ctx.replicate.configured && prefs.models?.[e.id]?.enabled !== false
      : e.runs === 'higgsfield' ? this.ctx.suite.providers.higgsfield.configured() && prefs.models?.[e.id]?.enabled !== false
      : caps.includes(e.capability!));
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
    const want = e.genjutsu ? GENJUTSU_RES[q]! : P.QUALITY_INFO[q].resolution;
    const res = m.resolutions.find(r => r.id === want) ?? m.resolutions.at(-1)!;
    const perSec = r4(res.perSec * priceScale);
    const range = e.genjutsu ? { minSec: e.genjutsu.minSec, maxSec: e.genjutsu.maxSec, resolutionLabel: res.label } : {};
    return { perSec, resolution: res.id, rr: { engine: 'replicate', quality: q, takes: 1, clipSeconds, pricePerSec: perSec, ...range } };
  }

  /** The quote for a swap on a chosen engine: its `RenderReq` (priced like /v1/jobs prices it) for `takes` of a clip. */
  /**
   * Owner 2026-11-14 (one model, several providers): MiniMax H3's swap at HD (2K) runs on Higgsfield (half Replicate's
   * 2K rate) when its key is set, it hasn't refused in the last 30 minutes and the owner hasn't switched it off; a clip
   * shorter than Higgsfield's 5 s minimum stays on Replicate (padding would bill seconds that aren't there).
   */
  swapRoute(id: string, quality: string | undefined, prefs: { models?: Record<string, { enabled?: boolean }> }, clipSeconds?: number | null): string {
    if (id !== 'h3' || quality !== 'hd' || (clipSeconds != null && clipSeconds < HF_SWAP_MIN_SEC)) return id;
    const hf = this.ctx.suite.providers.higgsfield;
    return hf.configured() && !this.ctx.suite.isDown('higgsfield') && prefs.models?.['h3-hf']?.enabled !== false ? 'h3-hf' : id;
  }

  async swapQuote(studioId: string, id0: string, quality: string | undefined, clipSeconds: number | null | undefined, takes = 1) {
    const prefs = await this.ctx.suite.prefs(studioId);
    const id = this.swapRoute(id0, quality, prefs, clipSeconds);
    const q = this.swapPrice(id, quality ?? 'standard', clipSeconds, prefs.models?.[id]?.priceScale ?? 1);
    const e = swapEngineById(id)!;
    const rr: P.RenderReq = e.runs === 'gpu' ? { ...q.rr, takes, clipSeconds } : { ...q.rr, takes };
    return { ...q, rr, cost: P.totalCost(rr) };
  }

  private videoEntry(m: ModelSpec, purposes: Purpose[], scale: number, resolution?: string, rs?: ResolutionPrice[], provider?: string): Engine {
    const list: ResolutionPrice[] = rs ?? m.resolutions.map(r => ({ id: r.id, label: r.label, perSec: m.livePrice ? 0 : r4(r.perSec * scale) }));
    const at = (resolution && list.find(r => r.id === resolution)) || list.at(-1)!;
    const perRun = m.byo?.perRunUsd ? r4(m.byo.perRunUsd * scale) : null;
    const live = rs ? !!at.livePrice && !at.perSec : !!m.livePrice;
    return { model: m.id, name: m.byo?.displayName ?? m.name, kind: 'video', purposes, custom: !!m.byo, provider: provider ?? (m.byo ? m.byo.providerKind : m.provider),
      notice: m.licence.notice ?? null,
      limits: { minSeconds: m.duration.min, maxSeconds: m.duration.max, allowedSeconds: m.duration.allowed ?? null, aspectRatios: m.aspectRatios,
        resolutions: list.map(r => ({ id: r.id, label: r.label })), maxInputSeconds: m.recast?.sourceSeconds[1] ?? m.extend?.sourceSeconds[1] ?? m.refs.videoSecondsMax ?? null },
      resolution: at.id, price: live ? null : perRun != null ? { basis: 'per_run', usd: perRun } : { basis: 'per_second', usd: at.perSec }, inputs: inputSlotsOf([m]),
      ...(rs ? { resolutions: rs } : {}), ...(live ? { livePrice: true } : {}) };
  }

  /** `quotes` false: no live display quotes (a check or a default lookup needs the list, not its prices). */
  private async videoEngines(studioId: string, quotes = true): Promise<Engine[]> {
    const suite = this.ctx.suite;
    // The studio's custom video models, freshly loaded (an added, renamed or switched-on model shows straight away).
    await suite.byo.ensure(studioId).catch(() => {});
    const p = await suite.prefs(studioId);
    // Every model is listed (owner 2026-11-12): a provider that refused recently stays (Auto skips it, not the picker).
    const avail = suite.mode === 'off' ? new Set() : suite.configured();
    const ladderRes = (id: string) => { for (const t of ['draft', 'standard', 'hd', 'cinema'] as const) { const s = (p.ladder?.[t]?.length ? p.ladder[t]! : DEFAULT_LADDER[t]).find(x => familyOf(x.model) === id); if (s) return s.resolution; } return undefined; };
    const out = new Map<string, Engine>();
    // Owner 2026-11-14: one entry per model, its resolutions across its providers (suite/service.ts pickerModels).
    for (const f of suite.mode === 'off' ? [] : await suite.pickerModels(studioId, p, avail as Set<ModelSpec['provider']>, quotes)) {
      // Every video model is listed (owner 2026-11-12), also one made only for New Swap (Wan 2.7 Edit): its purposes
      // are the ones it's made for; the others adapt (candidates).
      const purposes = PURPOSES.filter(x => f.routes.some(m => videoPurposes(m).includes(x)));
      const e = this.videoEntry({ ...f.spec, id: f.head.id }, purposes, p.models?.[f.head.id]?.priceScale ?? 1, ladderRes(f.head.id), f.resolutions, f.provider);
      out.set(f.head.id, { ...e, inputs: inputSlotsOf(f.routes) });
    }
    // Character swap (and Recreate swap fills): the hosted H3 family joins with "swap"; Edit / Fast on our GPU are added.
    // A provider route of a listed model (MiniMax H3 on Higgsfield) gives that model "swap" instead of a second entry.
    for (const e of this.swapUsable(p)) {
      const fam = familyOf(e.id), cur = out.get(fam);
      if (e.runs !== 'gpu') {
        const m = modelById(fam)!, sp = this.swapPrice(e.id, 'standard', null, p.models?.[e.id]?.priceScale ?? 1);
        // A swap-only model (Genjutsu) is listed at its swap resolution and price.
        const base = cur && cur.purposes.length ? cur : this.videoEntry(m, cur?.purposes ?? [], p.models?.[e.id]?.priceScale ?? 1, sp.resolution ?? undefined);
        const hf = e.runs === 'higgsfield' && fam === e.id;
        out.set(fam, { ...base, purposes: PURPOSES.filter(x => base.purposes.includes(x) || x === 'swap' || x === 'fill'),
          ...(e.genjutsu ? { keeps: GENJUTSU_KEEPS, bestFor: 'Same moves, new look or scene: a new outfit or background, added characters or products' } : {}),
          limits: { ...base.limits, minSeconds: e.genjutsu?.minSec ?? (hf ? HF_SWAP_MIN_SEC : cur?.limits.minSeconds ?? P.REPLICATE_MIN_SEC), maxInputSeconds: e.genjutsu?.maxSec ?? P.REPLICATE_MAX_SEC } });
      } else {
        const sp = this.swapPrice(e.id, 'standard', P.SAMPLE_CLIP_SEC);
        out.set(e.id, { model: e.id, name: e.name, kind: 'video', purposes: ['swap', 'fill'], custom: false, provider: 'runpod', notice: e.notice ?? null,
          limits: { ...noLimits, maxSeconds: P.MAX_CLIP_SEC, aspectRatios: ['9:16'], maxInputSeconds: P.MAX_CLIP_SEC },
          resolution: null, price: { basis: 'per_second', usd: sp.perSec }, inputs: NO_INPUTS });
      }
    }
    return [...out.values()];
  }

  /**
   * Replicate's image models the owner can run straight from the picker (owner 2026-11-09: "direct access to all the
   * available models"): the text-to-image and image-editing collections, most-run first, those the input mapping can
   * drive. Cached by the catalog; a slow or unreachable catalog just leaves the curated list.
   */
  private async replicateImageModels(): Promise<{ id: string; name: string }[]> {
    const cat = this.ctx.imageModels.catalog;
    if (!cat.configured) return [];
    try {
      const l = await Promise.race([cat.list('shot'), new Promise<null>(r => setTimeout(() => r(null), 4000))]);
      if (!l) return [];
      return l.models.filter(m => m.compatible !== false).slice(0, BROWSE_IMAGE_MODELS).map(m => ({ id: m.id, name: m.name }));
    } catch { return []; }
  }

  private async imageEngines(studioId: string, u: AuthUser): Promise<Engine[]> {
    const im = this.ctx.imageModels;
    const shot = await im.resolve(studioId, 'shot').catch(() => null);
    const browse = await this.replicateImageModels();
    const ids = [...new Set([shot?.model, this.ctx.config.REPLICATE_IMAGE_MODEL, ...IMAGE_CANDIDATES, ...browse.map(b => b.id)].filter((x): x is string => !!x))];
    const names = new Map(browse.map(b => [b.id, b.name]));
    const n = 3, inMp = P.PHOTO_REF_MP * n;
    const inputs = { ...NO_INPUTS, images: Math.min(6, this.ctx.config.REPLICATE_IMAGE_MAX_INPUTS) };
    const curated = new Set([shot?.model, this.ctx.config.REPLICATE_IMAGE_MODEL, ...IMAGE_CANDIDATES]);
    const out: Engine[] = [];
    for (const id of ids) {
      // Curated models are priced now; browsed ones from the catalog's price cache (filled as the list loads), else no price yet.
      const cached = curated.has(id) ? null : im.catalog.cachedPrice(id);
      const usd = im.isRecipe('shot', id) ? P.newShotEstimateImages(this.ctx.images.photoPrices(), 2, n)
        : curated.has(id) ? await im.estimate(id, { outMp: 2, inMp }).catch(() => null)
        : cached ? (() => { try { return estimateOne(cached, { outMp: 2, inMp }, im.estOpts()); } catch { return null; } })() : null;
      const nm = modelName(id);
      out.push({ model: id, name: nm !== id ? nm : names.get(id) ? `${names.get(id)} (${id.split('/')[0]})` : id, kind: 'image', purposes: [...IMAGE_PURPOSES], custom: false, provider: 'replicate', notice: null,
        ...(curated.has(id) ? {} : { browsed: true }),
        limits: noLimits, resolution: null, price: usd == null ? null : { basis: 'per_run', usd: r4(usd) }, inputs });
    }
    // WS5: the studio's custom image models, for every image purpose (Photo, Outfits, Character photos, Background plates).
    for (const c of await this.ctx.suite.byo.catalog({ ...u, studioId, role: 'owner' } as AuthUser)) if (c.kind === 'image') {
      const cc = c as typeof c & { provider?: string };
      out.push({ model: c.id, name: c.name, kind: 'image', purposes: [...IMAGE_PURPOSES], custom: true, provider: cc.provider, notice: null,
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
      out.push({ model: 'seedvr2', name: 'SeedVR2', kind: 'tool', purposes: ['upscale'], custom: false, provider: 'runpod', notice: null,
        limits: { ...noLimits, resolutions: sizes.map(z => ({ id: z.id, label: z.label })) }, resolution: sizes[0]!.id,
        price: { basis: 'per_output_second', usd: Math.min(...sizes.map(z => prices[z.id]!.usdPerSec)) }, inputs: NO_INPUTS });
    const ed = editorAi(this.ctx), pr = ed.provider;
    // AssemblyAI first: with its key set it is the built-in default for captions (and cuts).
    if (ed.assembly.configured())
      out.push({ model: ASSEMBLY_MODEL, name: 'AssemblyAI Universal', kind: 'tool', purposes: ['captions'], custom: false, provider: 'assemblyai', notice: null,
        limits: noLimits, resolution: null, price: { basis: 'per_second', usd: r4(ASSEMBLY_MAX_RATE * ed.markup) }, inputs: NO_INPUTS });
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
  async all(u: AuthUser, kinds: EngineKind[] = ['video', 'image', 'tool'], o: { quotes?: boolean } = {}): Promise<Engine[]> {
    return labelList([
      ...(kinds.includes('video') ? await this.videoEngines(u.studioId, o.quotes ?? true) : []),
      ...(kinds.includes('image') ? await this.imageEngines(u.studioId, u) : []),
      ...(kinds.includes('tool') ? this.toolEngines() : []),
    ], { showProviders: true }) as Engine[];
  }
  /**
   * The candidates for one purpose (owner view). Owner 2026-11-12: "Every model in our app should be available on every
   * mode … the default models are mostly on top of the list". Video purposes list every video model: the ones made for
   * the purpose first, then the rest, which MUSE adapts (`fit: 'adapted'` with a one-line `fitNote`). Image purposes
   * already list every image model. Tools stay per job (a matte model can't caption).
   */
  async candidates(u: AuthUser, purpose: Purpose, o: { quotes?: boolean } = {}) {
    const all = await this.all(u, [PURPOSE_INFO[purpose].kind], o);
    if (PURPOSE_INFO[purpose].kind !== 'video') return all.filter(e => e.purposes.includes(purpose));
    const native = all.filter(e => e.purposes.includes(purpose));
    // Our GPU's swap engines (Edit, Fast) run only the classic swap: they can't be adapted to other purposes.
    const rest = all.filter(e => !e.purposes.includes(purpose) && e.provider !== 'runpod');
    return [...native.map(e => ({ ...e, fit: 'native' as const })), ...rest.map(e => ({ ...e, fit: 'adapted' as const, fitNote: adaptNote(e.model, e.name, purpose) }))];
  }

  // ------------------------------------------------------------------ defaults
  /** What runs when nothing is picked: a fixed model, or the quality ladder (first usable step of the default quality). */
  async builtin(u: AuthUser, purpose: Purpose, cands?: Engine[]): Promise<{ model: string | null; rule: 'fixed' | 'ladder' }> {
    const list = cands ?? await this.candidates(u, purpose);
    const has = (id: string) => list.some(e => e.model === id);
    if (LADDER_PURPOSES.includes(purpose)) {
      const prefs = await this.ctx.suite.prefs(u.studioId);
      const steps = purpose === 'recast' ? RECAST_LADDER.draft : purpose === 'extend' ? EXTEND_LADDER.draft : (prefs.ladder?.draft?.length ? prefs.ladder.draft : DEFAULT_LADDER.draft);
      return { model: steps.map(s => familyOf(s.model)).find(has) ?? null, rule: 'ladder' };
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
  async setDefaults(u: AuthUser, body0: unknown) {
    if (!body0 || typeof body0 !== 'object' || Array.isArray(body0)) throw badRequest('Send {purpose: model or null}');
    // Also {purpose, model} (one at a time, WS7's form); purpose aliases are accepted.
    const b0 = body0 as Record<string, unknown>;
    const one = typeof b0.purpose === 'string' && Object.keys(b0).every(k => k === 'purpose' || k === 'model');
    const raw = one ? { [b0.purpose as string]: b0.model ?? null } : b0;
    const body = Object.fromEntries(Object.entries(raw).map(([k, v]) => [toPurpose(k) ?? k, v]));
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
  /** The owner's member switches (engines/members.ts). */
  memberRules(studioId: string) { return memberRules(this.ctx, studioId); }

  /** Whether members may see and pick this engine: a video or image model the owner added or MUSE offers, not hidden. */
  static forMembers(e: Engine, rules: MemberRules) {
    return (e.kind === 'video' || e.kind === 'image') && !e.browsed && !rules.hidden.has(e.model);
  }

  /**
   * What a member may see of a list: name, limits, price as charged; the provider while the studio shows it. Labels are
   * redone for the member's list (engines/labels.ts): with provider names hidden, the bare name, and "· Option n" for
   * models that would otherwise look the same.
   */
  private memberViews(list: Engine[], rules: MemberRules): Engine[] {
    return labelList(list.filter(e => ModelChoice.forMembers(e, rules)).map(e => {
      const { provider, notice: _n, members: _m, browsed: _b, providerName: _pn, label: _l, ...rest } = e;
      if (rules.showProviderNames && provider) return { ...rest, provider };
      return rest.resolutions ? { ...rest, resolutions: rest.resolutions.map(({ provider: _p, providerName: _rp, modelLabel: _ml, ...r }) => r) } : rest;
    }), { showProviders: rules.showProviderNames }) as Engine[];
  }
  /** The owner's view of an entry: every field, `members` (shown to members) on video and image models. */
  private ownerView(e: Engine, rules: MemberRules): Engine {
    const { browsed: _b, ...rest } = e;
    return { ...rest, ...(e.kind !== 'tool' ? { members: ModelChoice.forMembers(e, rules) } : {}) };
  }

  /** GET /v1/engines/members (owner): the studio's "Show provider names to members" and the models hidden from members. */
  async membersView(u: AuthUser) {
    const rules = await this.memberRules(u.studioId);
    const engines = await this.all(u, ['video', 'image']);
    return { showProviderNames: rules.showProviderNames,
      models: engines.filter(e => !e.browsed).map(e => ({ model: e.model, name: e.name, label: e.label, kind: e.kind, custom: e.custom, provider: e.provider ?? null, members: ModelChoice.forMembers(e, rules) })) };
  }
  /** PATCH /v1/engines/members (owner): {showProviderNames?: boolean, hidden?: {model: true | false}}. */
  async setMembers(u: AuthUser, body0: unknown) {
    const b = (body0 ?? {}) as { showProviderNames?: unknown; hidden?: unknown };
    if (typeof body0 !== 'object' || Array.isArray(body0) || Object.keys(b).some(k => k !== 'showProviderNames' && k !== 'hidden')) throw badRequest('Send {showProviderNames?, hidden?: {model: true or false}}');
    if (b.showProviderNames !== undefined && typeof b.showProviderNames !== 'boolean') throw badRequest('showProviderNames: true or false');
    let hidden: Record<string, boolean> | undefined;
    if (b.hidden !== undefined) {
      if (!b.hidden || typeof b.hidden !== 'object' || Array.isArray(b.hidden)) throw badRequest('hidden: {model: true or false}');
      hidden = {};
      const known = new Set((await this.all(u, ['video', 'image'], { quotes: false })).map(e => e.model));
      for (const [id, v] of Object.entries(b.hidden as Record<string, unknown>)) {
        if (typeof v !== 'boolean') throw badRequest(`hidden.${id}: true or false`);
        if (!known.has(id) && !(await this.ctx.suite.byo.isStudioModel(u.studioId, id))) throw badRequest(`Unknown model ${id}`);
        hidden[id] = v;
      }
    }
    await saveMemberRules(this.ctx, u, { showProviderNames: b.showProviderNames as boolean | undefined, hidden });
    await this.ctx.suite.byo.ensure(u.studioId, true); // custom models' "available to members" follows at once
    return this.membersView(u);
  }

  /** GET /v1/engines[?purpose=]. */
  /**
   * The flat fields the apps' existing model picker reads (the /v1/suite/catalog engines[] shape, WS5), so WS6/WS7 reuse
   * it unchanged: tier/tiers, per-resolution $/s, perSec/perRun, seconds and aspect ratios.
   */
  private async pickerFields(u: AuthUser, e: Engine) {
    const m = e.kind === 'video' ? modelById(e.model) : undefined;
    const prefs = m ? await this.ctx.suite.prefs(u.studioId) : undefined;
    const scale = (m && prefs?.models?.[m.id]?.priceScale) ?? 1;
    const tiers = m ? (['draft', 'standard', 'hd', 'cinema'] as const).filter(t => (prefs?.ladder?.[t]?.length ? prefs.ladder[t]! : DEFAULT_LADDER[t]).some(s => familyOf(s.model) === m.id)) : [];
    return { tier: tiers[0] ?? null, tiers,
      resolutions: e.resolutions ?? (m ? m.resolutions.map(r => ({ id: r.id, label: r.label, perSec: r4(r.perSec * scale) })) : e.limits.resolutions.map(r => ({ ...r, perSec: null }))),
      perSec: e.price?.basis === 'per_second' ? e.price.usd : null, perRun: e.price?.basis === 'per_run' ? e.price.usd : null,
      minSeconds: e.limits.minSeconds, maxSeconds: e.limits.maxSeconds, allowedSeconds: e.limits.allowedSeconds, aspectRatios: e.limits.aspectRatios };
  }

  async list(u: AuthUser, purpose?: unknown, resolution?: unknown) {
    if (purpose !== undefined && purpose !== '' && !toPurpose(purpose)) throw badRequest(`purpose: one of ${PURPOSES.join(', ')}`);
    if (resolution !== undefined && (typeof resolution !== 'string' || resolution.length > 20)) throw badRequest('resolution: a resolution id such as 1080p');
    const only = toPurpose(purpose);
    const studio = await this.studioDefaults(u.studioId);
    const engines = only ? await this.candidates(u, only) : await this.all(u);
    const purposes = [];
    for (const p of only ? [only] : PURPOSES) {
      const cands = only ? engines : engines.filter(e => e.purposes.includes(p));
      const b = await this.builtin(u, p, cands);
      const st = studio[p] && cands.some(e => e.model === familyOf(studio[p]!)) ? familyOf(studio[p]!) : studio[p] && cands.some(e => e.model === studio[p]) ? studio[p]! : null;
      purposes.push({ id: p, label: PURPOSE_INFO[p].label, kind: PURPOSE_INFO[p].kind, default: st ?? b.model, studioDefault: u.role === 'owner' ? st : null, rule: st ? 'fixed' : b.rule });
    }
    const def = only ? purposes[0]!.default : null;
    const rules = await this.memberRules(u.studioId);
    const shown = u.role === 'owner' ? engines.map(e => this.ownerView(e, rules)) : this.memberViews(engines, rules);
    const view = [];
    // The default first, then the others in candidate order (made for this purpose, then adapted).
    const ordered = only && def ? [...shown.filter(e => e.model === def), ...shown.filter(e => e.model !== def)] : shown;
    for (const e of ordered) {
      const rf = typeof resolution === 'string' && resolution ? resolutionFit(e, resolution) : undefined;
      view.push({ ...(await this.pickerFields(u, e)), ...e, ...(only ? { default: e.model === def } : {}), ...(rf ? { resolutionFit: rf } : {}) });
    }
    const ps = u.role === 'owner' ? purposes : purposes.map(p => ({ ...p, default: null }));
    // With ?purpose: also `purpose`, `default` and `models` (= engines), the shape WS7 proposed.
    return { ...(only ? { purpose: only, default: ps[0]!.default, models: view } : {}), purposes: ps, engines: view,
      ...(u.role === 'owner' ? { memberSettings: { showProviderNames: rules.showProviderNames } } : {}) };
  }

  /**
   * An override for a purpose: allowed for this user and a candidate (image purposes also take any Replicate "owner/name",
   * checked against its schema when it runs, owner only). Members: any video or image candidate the owner hasn't hidden
   * from them (4c), else 403 owner_only (tools, hidden models, other refs); 400 engine_not_allowed with the valid list otherwise.
   */
  async check(u: AuthUser, purpose: Purpose, model: string): Promise<Engine> {
    const cands = await this.candidates(u, purpose, { quotes: false });
    // An old id of a provider route ("h3-hf") is its model's entry (owner 2026-11-14: one entry per model).
    const e = cands.find(x => x.model === model) ?? cands.find(x => x.model === familyOf(model));
    if (u.role !== 'owner') {
      const rules = await this.memberRules(u.studioId);
      if (e && ModelChoice.forMembers(e, rules)) return e;
      if (!e && PURPOSE_INFO[purpose].kind !== 'tool' && !MODEL_ID_RE.test(model)) {
        const err = new ApiError(400, 'engine_not_allowed', `That model can't be used for ${PURPOSE_INFO[purpose].label}`);
        (err as ApiError & { extra?: unknown }).extra = { purpose, valid: cands.filter(x => ModelChoice.forMembers(x, rules)).map(x => x.model) };
        throw err;
      }
      throw new ApiError(403, 'owner_only', 'Only the studio owner can pick that model');
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
    if (!c) return base; // a custom "c_…" model runs on the byo engine (ImageService.selection)
    return { ...(base ?? {}), shot: c.model };
  }

  /** The model for a run: the request's override (checked), else the studio's default when still a candidate, else none. */
  async choose(u: AuthUser, purpose: Purpose, requested?: string | null): Promise<Choice | null> {
    if (requested) return { model: requested, source: 'request', engine: await this.check(u, purpose, requested) };
    const d = (await this.studioDefaults(u.studioId))[purpose];
    if (!d) return null;
    const e = (await this.candidates(u, purpose, { quotes: false })).find(x => x.model === d || x.model === familyOf(d));
    // A member runs on the studio's default too, unless it's a custom model the owner hid from members.
    if (!e || (u.role !== 'owner' && e.custom && !ModelChoice.forMembers(e, await this.memberRules(u.studioId)))) return null;
    return { model: d, source: 'studio', engine: e };
  }
}

export { VIDEO_PURPOSES };

/**
 * Owner 2026-11-14: a resolution picked first never forces a model. Every model stays listed; this says whether it
 * makes `asked`, else the one it would use (the nearest it makes, larger on a tie) and what it makes, in words.
 */
export function resolutionFit(e: Engine, asked: string): Engine['resolutionFit'] | undefined {
  const rs = e.resolutions ?? e.limits.resolutions;
  if (e.kind !== 'video' || !rs.length) return undefined;
  const same = rs.find(r => r.id.toLowerCase() === asked.toLowerCase());
  if (same) return { asked, has: true, resolution: same.id, note: null };
  const want = sideOf(asked);
  const near = [...rs].sort((a, b) => Math.abs(sideOf(a.id) - want) - Math.abs(sideOf(b.id) - want) || sideOf(b.id) - sideOf(a.id))[0]!;
  const words = (l: string) => l.split(' ')[0]!;
  return { asked, has: false, resolution: near.id, note: `Makes ${rs.map(r => words(r.label)).join(', ')} · picking it uses ${words(near.label)}` };
}

/**
 * Character swap on a chosen engine (POST /v1/jobs, the Suite's swap mode, Recreate swap fills). Mutates the jobs request:
 * the engine (hosted, or Edit / Fast on our GPU), the hosted model ref and the swap engine id. A request that names Edit or
 * Fast itself (engine "h3" / "viggle") keeps it unless it also asks for a model; the studio default applies to the hosted
 * swap. `pre`: a choice the caller already made (undefined: choose now). Returns the choice, or null (built-in behaviour).
 */
const u0Prefs = (mc: ModelChoice, u: AuthUser) => mc.prefs(u.studioId);
export async function applySwapEngine(mc: ModelChoice, u: AuthUser, r: Record<string, any>, requested?: string | null, pre?: Choice | null): Promise<Choice | null> {
  for (const k of ['swapEngine', 'videoModel', 'videoNoResolution', 'minSec', 'maxSec', 'resolutionLabel']) delete r[k]; // never taken from the client
  if (!requested && pre === undefined && r.engine && r.engine !== 'replicate') return null;
  const choice = pre !== undefined ? pre : await mc.choose(u, 'swap', requested);
  if (!choice) return null;
  // MiniMax H3 is one entry on two providers (owner 2026-11-14): HD runs on Higgsfield when it can (ModelChoice.swapRoute).
  const e = swapEngineById(swapEngineById(choice.model) ? mc.swapRoute(choice.model, r.quality, await u0Prefs(mc, u)) : choice.model);
  // Every model can be picked for Swap (owner 2026-11-12); a non-swap model runs as a New Swap in the AI suite's
  // planner. This classic job pipeline can't adapt one: a picked one is said plainly; a studio default is skipped here.
  if (!e && choice.source === 'request') throw Object.assign(new ApiError(400, 'engine_not_allowed', `${choice.engine.label ?? choice.engine.name} isn’t a swap model: generate it from the AI suite’s Swap, where it runs as a New Swap`), { extra: { purpose: 'swap', valid: SWAP_ENGINES.map(x => x.id) } });
  if (!e) return null;
  if (e.runs === 'gpu') { r.engine = e.gpuEngine; r.use = 'full'; delete r.quality; }
  else { r.engine = 'replicate'; r.videoModel = e.ref; if (e.noResolution) r.videoNoResolution = true; } // Higgsfield runs on the hosted line too (swapEngine h3-hf)
  r.swapEngine = e.id;
  if (e.genjutsu) { r.minSec = e.genjutsu.minSec; r.maxSec = e.genjutsu.maxSec; } // its 4–30 s range (the resolution label comes with the price)
  return choice;
}
