// AI suite · the service behind /v1/suite: catalog, settings, estimate, shots (as render jobs on the existing
// job/wallet pipeline: hold → run → exact settle, or full refund), and the suite line that runs them.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { and, eq, gte, ne, sql } from 'drizzle-orm';
import { detectTalking } from '../audio/detect.js';
import { resolveSpeaking } from '../audio/service.js';
import type { AuthUser, Ctx } from '../ctx.js';
import { clips, jobs, models, outfits, takes, uploads, type ImageRef } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { dayStart, round2 } from '../lib/util.js';
import * as P from '../pricing.js';
import { replicateReferencesFor } from '../services/jobs.js';
import { cameraCatalog, CameraSpecSchema, resolvePreset } from './camera.js';
import { shotLook } from './looks.js';
import { compileCamera } from './compile.js';
import { buildExtendPlan, pickExtend } from './extend.js';
import { buildRecastPlan, pickRecast } from './recast.js';
import { buildPlan, needOf, pickModel, shotLabel, ShotRequestSchema, type Character, type ShotPlan, type ShotRequest, type SuitePrefs } from './plan.js';
import { FalProvider, HiggsfieldProvider, MockProvider, ReplicateProvider, type VideoProvider } from './providers.js';
import { customModelsOf, DEFAULT_LADDER, EXTEND_LADDER, inputSlotsOf, MODELS, NO_INPUTS, modelById, modelView, MOCK_MODEL, TIER_INFO, TIERS, type ProviderId, type Tier } from './registry.js';
import { SuiteRunner } from './runner.js';
import { suiteSettings } from './schema.js';
import { rigCheck } from './rigcheck.js';
import { draftOf } from './drafts.js';
import { ByoService } from '../byo/service.js'; // WS5: bring your own provider
import { modelName } from '../images/steps.js';
import { applySwapEngine, modelChoice, type Choice } from '../engines/service.js'; // WS13: model choice everywhere
import { purposeOfShot, SWAP_ENGINES, swapEngineById, videoPurposes } from '../engines/purposes.js';

/** WS13: the studio's default model can't make this shot, so the quality ladder picked one (member-safe). */
export const STUDIO_DEFAULT_SKIPPED = 'The studio’s chosen engine can’t make this shot · the quality’s usual engine is used';

/**
 * Estimate for removing the vocals of an audio reference (beat-only audio), held with the shot; the job settles the
 * separator's exact cost. About 5 s of GPU on the separation model (2026-11-05 list price). Kept here so the suite
 * doesn't depend on which service runs the separation (workstream 4 / 3).
 */
export const SEPARATION_ESTIMATE_USD = 0.0066;

export const isSuiteJob = (j: { request?: Record<string, any> | null }) => j.request?.engine === 'suite';

export class SuiteService {
  readonly mock: MockProvider;
  readonly providers: Record<Exclude<ProviderId, 'runpod'>, VideoProvider>;
  readonly runner: SuiteRunner;
  /** WS5: owner-added providers and models (custom models join the registry per studio). */
  readonly byo: ByoService;
  constructor(private ctx: Ctx, fetchFn?: typeof fetch) {
    this.mock = new MockProvider(ctx);
    this.byo = new ByoService(ctx, fetchFn);
    this.providers = { replicate: new ReplicateProvider(ctx), fal: new FalProvider(ctx, fetchFn), higgsfield: new HiggsfieldProvider(ctx, fetchFn), mock: this.mock, byo: this.byo.video };
    this.runner = new SuiteRunner(ctx, this);
  }

  get mode() { return this.ctx.config.suiteMode; }
  /** The provider that really runs a plan: the mock in mock mode, else the plan's own. */
  providerFor(p: Pick<ShotPlan, 'provider'>): VideoProvider {
    if (this.mode === 'mock') return this.mock;
    const pr = this.providers[p.provider as keyof typeof this.providers];
    if (!pr) throw new ApiError(400, 'engine_unavailable', "That quality isn't available right now");
    return pr;
  }
  /** Providers a shot may be planned on. In mock mode every hosted one counts (the mock stands in, nothing is spent). */
  available(): Set<ProviderId> {
    if (this.mode === 'off') return new Set();
    // Higgsfield counts in mock mode only when its key is set, so test prices match what live mode would run.
    if (this.mode === 'mock') return new Set<ProviderId>(['replicate', 'fal', 'mock', 'byo', ...(this.providers.higgsfield.configured() ? ['higgsfield' as const] : [])]);
    const s = new Set<ProviderId>();
    if (this.providers.replicate.configured()) s.add('replicate');
    if (this.providers.fal.configured()) s.add('fal');
    if (this.providers.higgsfield.configured() && !this.isDown('higgsfield')) s.add('higgsfield');
    if (this.byo.ready) s.add('byo'); // WS5: each custom model runs on its studio's own key
    return s;
  }
  /** A provider that refused at start (out of credit, bad key, down) is skipped for new shots for a while. */
  private down = new Map<ProviderId, number>();
  markDown(p: ProviderId, ms = 30 * 60_000) { this.down.set(p, Date.now() + ms); }
  isDown(p: ProviderId) { return (this.down.get(p) ?? 0) > Date.now(); }

  // ------------------------------------------------------------------ settings (owner)
  async prefs(studioId: string): Promise<SuitePrefs> {
    await this.byo.ensure(studioId); // WS5: the studio's custom models are in the registry before anything is planned
    const [r] = await this.ctx.db.select().from(suiteSettings).where(eq(suiteSettings.studioId, studioId));
    const p: SuitePrefs = r ? { models: r.models, ladder: r.ladder ?? undefined, capPerJob: r.capPerJob, capPerDay: r.capPerDay } : {};
    // WS5: a custom model's markup is set on the model itself (Settings → Providers).
    const custom = customModelsOf(studioId);
    if (custom.length) p.models = { ...(p.models ?? {}), ...Object.fromEntries(custom.map(m => [m.id, { ...(p.models?.[m.id] ?? {}), priceScale: m.byo!.priceScale }])) };
    return p;
  }
  caps(p: SuitePrefs) { return { perJob: p.capPerJob ?? this.ctx.config.SUITE_CAP_PER_JOB_USD, perDay: p.capPerDay ?? this.ctx.config.SUITE_CAP_PER_DAY_USD }; }
  async settingsView(studioId: string) {
    const p = await this.prefs(studioId);
    const avail = this.available();
    return {
      mode: this.mode, caps: this.caps(p), spentToday: round2(await this.spentToday(studioId)),
      ladder: Object.fromEntries(TIERS.map(t => [t, p.ladder?.[t]?.length ? p.ladder[t] : DEFAULT_LADDER[t]])), defaultLadder: DEFAULT_LADDER,
      models: MODELS.map(m => modelView(m, p.models?.[m.id], avail.has(m.provider))),
      providers: { replicate: this.providers.replicate.configured(), fal: this.providers.fal.configured(), runpod: false },
    };
  }
  async updateSettings(u: AuthUser, body: unknown) {
    const b = (body ?? {}) as { models?: Record<string, { enabled?: unknown; acknowledge?: unknown; priceScale?: unknown }>; ladder?: unknown; capPerJob?: unknown; capPerDay?: unknown };
    const cur = await this.prefs(u.studioId);
    const next: Required<Pick<SuitePrefs, 'models'>> & SuitePrefs = { ...cur, models: { ...(cur.models ?? {}) } };
    for (const [id, v] of Object.entries(b.models ?? {})) {
      const m = modelById(id);
      if (!m || m.id === 'mock' || (m.byo && m.byo.studioId !== u.studioId)) throw badRequest(`Unknown model ${id}`);
      const e = { ...(next.models[id] ?? {}) };
      if (v.enabled !== undefined) {
        if (typeof v.enabled !== 'boolean') throw badRequest('enabled: true or false');
        if (v.enabled && (m.licence.blockNewFeatures || m.status === 'removed')) throw new ApiError(409, 'model_blocked', `${m.name} can't be switched on (${m.status === 'removed' ? 'removed' : 'licence'})`);
        e.enabled = v.enabled;
      }
      if (v.acknowledge !== undefined) e.acknowledgedAt = v.acknowledge ? Date.now() : null;
      if (v.priceScale !== undefined) {
        if (typeof v.priceScale !== 'number' || !(v.priceScale >= 0.5 && v.priceScale <= 3)) throw badRequest('priceScale: 0.5–3');
        e.priceScale = v.priceScale;
      }
      next.models[id] = e;
    }
    if (b.ladder !== undefined) {
      if (b.ladder === null) next.ladder = undefined;
      else {
        const l = b.ladder as Record<string, unknown>;
        const out: SuitePrefs['ladder'] = {};
        for (const [tier, steps] of Object.entries(l)) {
          if (!TIERS.includes(tier as Tier)) throw badRequest(`Unknown quality ${tier}`);
          if (!Array.isArray(steps) || steps.length > 10) throw badRequest(`ladder.${tier}: up to 10 steps`);
          out[tier as Tier] = steps.map((s: any) => {
            const m = modelById(String(s?.model));
            if (!m || m.id === 'mock' || (m.byo && m.byo.studioId !== u.studioId) || !m.resolutions.some(r => r.id === s?.resolution)) throw badRequest(`ladder.${tier}: unknown model or resolution`);
            return { model: m.id, resolution: String(s.resolution) };
          });
        }
        next.ladder = out;
      }
    }
    for (const k of ['capPerJob', 'capPerDay'] as const) {
      const v = b[k];
      if (v === undefined) continue;
      if (v !== null && (typeof v !== 'number' || !(v >= 0 && v <= 1000))) throw badRequest(`${k}: 0–1000 or null`);
      next[k] = v as number | null;
    }
    const row = { studioId: u.studioId, models: next.models, ladder: next.ladder ?? null, capPerJob: next.capPerJob ?? null, capPerDay: next.capPerDay ?? null, updatedBy: u.id, updatedAt: Date.now() };
    await this.ctx.db.insert(suiteSettings).values(row).onConflictDoUpdate({ target: suiteSettings.studioId, set: row });
    return this.settingsView(u.studioId);
  }

  // ------------------------------------------------------------------ catalog
  async catalog(u: AuthUser) {
    const p = await this.prefs(u.studioId);
    const avail = this.available();
    const tiers = TIERS.map(t => {
      const steps = p.ladder?.[t]?.length ? p.ladder[t]! : DEFAULT_LADDER[t];
      const usable = steps.map(s => ({ s, m: modelById(s.model) })).filter(x => x.m && x.m.status !== 'removed' && !x.m.licence.blockNewFeatures
        && p.models?.[x.m.id]?.enabled !== false && avail.has(x.m.provider) && x.m.resolutions.some(r => r.id === x.s.resolution));
      const first = usable[0];
      const res = first?.m!.resolutions.find(r => r.id === first.s.resolution);
      const base = { id: t, label: TIER_INFO[t].label, detail: TIER_INFO[t].detail, available: !!first,
        resolution: res?.label.split(' ')[0] ?? null, fromPerSec: usable.length ? round2(Math.min(...usable.map(x => x.m!.resolutions.find(r => r.id === x.s.resolution)!.perSec * (p.models?.[x.m!.id]?.priceScale ?? 1))) * 1000) / 1000 : null,
        maxSeconds: usable.length ? Math.max(...usable.map(x => x.m!.duration.max)) : null,
        minSeconds: usable.length ? Math.min(...usable.map(x => x.m!.duration.min)) : null,
        canKeyframes: usable.some(x => x.m!.modes.image), canReferences: usable.some(x => x.m!.modes.reference), canGuide: usable.some(x => x.m!.camera.referenceVideo), inputs: inputSlotsOf(usable.map(x => x.m!)) };
      return u.role === 'owner' ? { ...base, models: usable.map(x => ({ model: x.m!.id, name: x.m!.name, resolution: x.s.resolution, inputs: inputSlotsOf([x.m!]) })) } : base;
    });
    // Composer tools (plans/video-composer.md "Tools on the shell"): which the apps can offer now. Talking and UGC ad are
    // shots (audio / product references); Extend continues a finished take.
    const on = this.mode !== 'off', any = (f: (i: ReturnType<typeof inputSlotsOf>) => boolean) => tiers.some(t => t.available && f(t.inputs));
    const tools = [
      { id: 'shot', available: on }, { id: 'swap', available: on }, { id: 'recast', available: on }, { id: 'storyboard', available: on },
      { id: 'talking', available: on && any(i => i.audio) }, { id: 'ugc_ad', available: on && any(i => i.images > 0) },
      // Extend (suite/extend.ts): live when a tier has a model that continues clips. Upscale stays the take's add-on.
      { id: 'extend', available: on && TIERS.some(t => EXTEND_LADDER[t].some(st => { const m = modelById(st.model); return !!m && avail.has(m.provider) && p.models?.[m.id]?.enabled !== false; })) },
      // Photo (workstream 3): stills on the shoot pipeline (POST /v1/suite/photos), so it doesn't depend on the video engines.
      { id: 'photo', available: true },
    ];
    // WS5: owner-added models (members: only those the owner made available, by display name).
    const custom = this.mode === 'off' ? [] : await this.byo.catalog(u);
    const engines = u.role === 'owner' && this.mode !== 'off' ? await this.ownerEngines(u.studioId, p, avail) : undefined; // WS5: the owner's model picker
    return { enabled: this.mode !== 'off', test: this.mode === 'mock', defaultQuality: 'draft', tiers, tools, custom, ...(engines ? { engines } : {}), modes: ['text', 'image', 'reference', 'swap', 'recast'], recastMaxPeople: 4,
      aspectRatios: ['9:16', '16:9', '1:1', '4:3', '3:4', '21:9'], takesMax: 4, camera: cameraCatalog() };
  }

  /**
   * WS5 · the owner's model picker: every engine the owner can pick for a shot or a photo, flat across tiers. Video: each
   * usable registry model that makes shots (enabled, licensed, its provider set up) and each enabled custom video model.
   * Image: the studio's photo model and each enabled custom image model. Prices are after the model's priceScale.
   */
  async ownerEngines(studioId: string, p: SuitePrefs, avail: Set<ProviderId>) {
    const tiersOf = (id: string) => TIERS.filter(t => (p.ladder?.[t]?.length ? p.ladder[t]! : DEFAULT_LADDER[t]).some(s => s.model === id));
    const ladderRes = (id: string) => { for (const t of TIERS) { const s = (p.ladder?.[t]?.length ? p.ladder[t]! : DEFAULT_LADDER[t]).find(x => x.model === id); if (s) return s.resolution; } return undefined; };
    const video = [...MODELS, ...customModelsOf(studioId)].filter(m => m.status !== 'removed' && !m.licence.blockNewFeatures && p.models?.[m.id]?.enabled !== false
      && !(m.licence.requiresAck && !p.models?.[m.id]?.acknowledgedAt) && avail.has(m.provider) && (m.modes.text || m.modes.image || m.modes.reference))
      .map(m => {
        const scale = p.models?.[m.id]?.priceScale ?? 1, tiers = tiersOf(m.id);
        const resolution = ladderRes(m.id) && m.resolutions.some(r => r.id === ladderRes(m.id)) ? ladderRes(m.id)! : m.resolutions.at(-1)!.id;
        // WS13: what this model can be picked for (plans/model-choice.md); the hosted H3 family also swaps.
        const purposes = [...videoPurposes(m), ...(SWAP_ENGINES.some(e => e.id === m.id && (e.runs === 'replicate' ? this.ctx.replicate.configured : e.runs === 'higgsfield' && this.providers.higgsfield.configured())) ? ['swap' as const] : [])];
        return { model: m.id, name: m.name, kind: 'video' as const, custom: !!m.byo, purposes, tier: tiers[0] ?? null, tiers, resolution,
          resolutions: m.resolutions.map(r => ({ id: r.id, label: r.label, perSec: Math.round(r.perSec * scale * 10000) / 10000 })),
          perSec: Math.round((m.resolutions.find(r => r.id === resolution)?.perSec ?? 0) * scale * 10000) / 10000,
          perRun: m.byo?.perRunUsd ? Math.round(m.byo.perRunUsd * scale * 10000) / 10000 : null,
          minSeconds: m.duration.min, maxSeconds: m.duration.max, allowedSeconds: m.duration.allowed ?? null, aspectRatios: m.aspectRatios, inputs: inputSlotsOf([m]) };
      });
    // The studio's photo model (the Photo tool's default) and its price for one photo with the usual 3 identity images.
    const shot = await this.ctx.imageModels.resolve(studioId, 'shot').catch(() => null);
    const image: Record<string, unknown>[] = [];
    if (shot) {
      const n = 3, inMp = P.PHOTO_REF_MP * n;
      const perRun = this.ctx.imageModels.isRecipe('shot', shot.model) ? P.newShotEstimateImages(this.ctx.images.photoPrices(), 2, n)
        : await this.ctx.imageModels.estimate(shot.model, { outMp: 2, inMp }).catch(() => null);
      image.push({ model: shot.model, name: modelName(shot.model), kind: 'image', custom: false, purposes: ['photo', 'outfit', 'character', 'plate'], tier: null, tiers: [], resolution: null, resolutions: [], perSec: null,
        perRun: perRun == null ? null : Math.round(perRun * 10000) / 10000, minSeconds: null, maxSeconds: null, allowedSeconds: null, aspectRatios: [],
        inputs: { ...NO_INPUTS, images: Math.min(6, this.ctx.config.REPLICATE_IMAGE_MAX_INPUTS) } });
    }
    for (const c of await this.byo.catalog({ studioId, role: 'owner' } as AuthUser)) if (c.kind === 'image')
      image.push({ model: c.id, name: c.name, kind: 'image', custom: true, purposes: ['photo'], tier: null, tiers: [], resolution: null, resolutions: [], perSec: null, perRun: c.price.usd,
        minSeconds: null, maxSeconds: null, allowedSeconds: null, aspectRatios: c.aspectRatios, inputs: c.inputs });
    // One price per entry for the picker: per run for per-run custom models and image models, else per second.
    return [...video, ...image].map(e => ({ ...e, price: e.perRun != null ? { basis: 'per_run' as const, usd: e.perRun as number }
      : e.perSec != null ? { basis: 'per_second' as const, usd: e.perSec as number } : null }));
  }

  // ------------------------------------------------------------------ character
  async character(studioId: string, modelId?: string, outfitId?: string): Promise<Character | null> {
    if (!modelId) return null;
    const [m] = await this.ctx.db.select().from(models).where(and(eq(models.id, modelId), eq(models.studioId, studioId)));
    if (!m) throw notFound('Model');
    if (m.archivedAt) throw new ApiError(409, 'model_archived', 'This model is archived · restore her in Settings → Archived models');
    const [o] = outfitId ? await this.ctx.db.select().from(outfits).where(and(eq(outfits.id, outfitId), eq(outfits.studioId, studioId))) : [];
    if (outfitId && !o) throw notFound('Outfit');
    const refs = replicateReferencesFor(m, o);
    return { name: m.name, look: m.look || `${m.age}-year-old woman`, neverAdd: m.neverAdd,
      images: refs.filter(r => !r.label.startsWith('outfit')),
      outfit: o ? { name: o.name, description: o.description || undefined, images: refs.filter(r => r.label.startsWith('outfit')) } : null };
  }

  // ------------------------------------------------------------------ planning and estimate
  parse(body: unknown, u: AuthUser): ShotRequest {
    const r = ShotRequestSchema.safeParse(body ?? {});
    if (!r.success) throw badRequest(`Invalid shot: ${r.error.issues[0]?.path.join('.')} ${r.error.issues[0]?.message}`);
    // WS5: members may pick a custom model the owner made available (checked when planning); nothing else.
    const memberCustom = !!r.data.engineModel?.startsWith('c_') && !r.data.resolution;
    if ((r.data.engineModel || r.data.resolution) && u.role !== 'owner' && !memberCustom) throw new ApiError(403, 'owner_only', 'Only the studio owner can pick the engine');
    return r.data;
  }

  /** Plans the shot. Throws engine_unavailable / nothing_fits. Swap shots return the existing engine's estimate. */
  async plan(u: AuthUser, r: ShotRequest) {
    if (this.mode === 'off') throw new ApiError(400, 'engine_unavailable', "The AI suite isn't switched on yet");
    if (r.engineModel?.startsWith('c_')) { // WS5: a custom model makes plain shots only
      if (r.mode === 'swap' || r.mode === 'recast' || r.mode === 'extend' || r.cast?.length || r.extend) throw badRequest('That model makes shots only');
      await this.byo.checkUse(u, r.engineModel, 'video');
    }
    // The apps send Character swap as a one-person Recast (mode "recast", cast[0] = who she becomes). With a swap model
    // picked (H3, H3 Lite, Highspeed, Higgsfield, Edit, Fast) that isn't a Recast model, it IS a swap: run it as one.
    if (r.mode !== 'swap' && r.cast?.length === 1 && !r.extend && r.engineModel && swapEngineById(r.engineModel)
      && !(await modelChoice(this.ctx).candidates(u, 'recast')).some(e => e.model === r.engineModel)) {
      const c = r.cast[0]!;
      Object.assign(r, { mode: 'swap', modelId: c.characterId, outfitId: c.outfitId ?? r.outfitId, cast: undefined });
    }
    // WS13: the owner's override for this purpose (checked: a candidate, owner only), else the studio's default for it.
    const choice = await modelChoice(this.ctx).choose(u, purposeOfShot(r), r.engineModel);
    if (r.mode === 'swap') return { swap: true as const, ...(await this.swapEstimate(u, r, choice)) };
    if (r.mode === 'recast' || r.cast?.length) return this.recastPlan(u, r, choice);
    if (r.mode === 'extend' || r.extend) return this.extendPlan(u, r, choice);
    const prefs = await this.prefs(u.studioId);
    const character = await this.character(u.studioId, r.modelId, r.outfitId);
    const need = needOf(r, character);
    if (need.mode === 'image' && !need.start && !need.end) throw badRequest('Keyframe shots need a start or end frame');
    if (need.mode === 'reference' && !character?.images.length && !need.extraImages) throw badRequest('Reference shots need a character with a sheet, or reference images');
    if (need.mode === 'text' && !r.prompt.trim()) throw badRequest('Describe the shot');
    const o = { prefs, providers: this.available(), studioId: u.studioId };
    let pick = pickModel(r.quality, need, { ...o, engineModel: choice?.model, resolution: choice?.source === 'request' ? r.resolution : undefined });
    const skipped = 'error' in pick && choice?.source === 'studio';
    if (skipped) pick = pickModel(r.quality, need, o);
    if ('error' in pick) {
      const e = new ApiError(400, 'nothing_fits', `${TIER_INFO[r.quality].label} can't make this shot · try another quality, a shorter length or fewer references`);
      (e as any).tried = pick.tried;
      throw e;
    }
    const texts = await this.ctx.prompts.texts(u.studioId);
    const talk = await this.resolveSpeaking(u.studioId, r);
    const plan = buildPlan(r, need, pick, character, { texts, priceScale: prefs.models?.[pick.model.id]?.priceScale, speaking: talk.speaking,
      separationUsd: SEPARATION_ESTIMATE_USD });
    if (skipped) plan.notes.push(STUDIO_DEFAULT_SKIPPED);
    return { swap: false as const, plan, pick, prefs, tried: pick.tried, talk };
  }

  /**
   * Recast (same take, new cast): up to 4 people in the source clip, each → a studio character. Speaking per person:
   * its switch; else, with one person, the clip's (switch → upload → detection); else unknown (the mouth follows the clip).
   */
  /** Extend's source: a take, clip or upload in this studio, with its length (stored, else the client's `seconds`). */
  private async extendSource(studioId: string, v: NonNullable<ShotRequest['extend']>['video']) {
    const key = this.runner.storageKeyOf(v);
    if (!key) throw badRequest('Extend needs a take, clip or upload of this studio');
    const [t] = await this.ctx.db.select({ media: takes.media }).from(takes).where(and(eq(takes.mediaKey, key), eq(takes.studioId, studioId)));
    if (t) return { key, seconds: Number((t.media as any)?.durationSec) || v.seconds || 0 };
    const [c] = await this.ctx.db.select({ seconds: clips.durationSec }).from(clips).where(and(eq(clips.storageKey, key), eq(clips.studioId, studioId)));
    if (c) return { key, seconds: c.seconds || v.seconds || 0 };
    const [up] = await this.ctx.db.select({ id: uploads.id }).from(uploads).where(and(eq(uploads.storageKey, key), eq(uploads.studioId, studioId)));
    if (up) return { key, seconds: v.seconds ?? 0 };
    throw badRequest('That video isn’t in this studio');
  }

  private async extendPlan(u: AuthUser, r: ShotRequest, choice: Choice | null = null) {
    if (!r.extend) throw badRequest('Extend needs the video to continue (extend.video)');
    const source = await this.extendSource(u.studioId, r.extend.video);
    if (!(source.seconds > 0)) throw badRequest('Extend needs the video’s length (extend.video.seconds)');
    const prefs = await this.prefs(u.studioId);
    const need = { direction: r.extend.direction, sourceSeconds: source.seconds, seconds: r.duration, aspect: r.aspectRatio };
    let pick = pickExtend(r.quality, need, { prefs, providers: this.available(), engineModel: choice?.model, resolution: choice?.source === 'request' ? r.resolution : undefined });
    const skipped = 'error' in pick && choice?.source === 'studio';
    if (skipped) pick = pickExtend(r.quality, need, { prefs, providers: this.available() });
    if ('error' in pick) {
      const e = new ApiError(400, 'nothing_fits', `${TIER_INFO[r.quality].label} can't extend this clip ${r.extend.direction === 'before' ? 'backwards' : 'forwards'} · try another quality or length`);
      (e as any).tried = pick.tried;
      throw e;
    }
    const texts = await this.ctx.prompts.texts(u.studioId);
    const plan = buildExtendPlan(r, pick, source, { texts, priceScale: prefs.models?.[pick.model.id]?.priceScale });
    if (skipped) plan.notes.push(STUDIO_DEFAULT_SKIPPED);
    return { swap: false as const, plan, pick: { ...pick, seconds: plan.seconds }, prefs, tried: pick.tried, talk: { speaking: false, source: 'default' as const } };
  }

  private async recastPlan(u: AuthUser, r: ShotRequest, choice: Choice | null = null) {
    if (!r.clipId) throw badRequest('Recast needs the source clip (clipId)');
    if (!r.cast?.length) throw badRequest('Recast needs a cast: who in the clip becomes which character');
    const [clip] = await this.ctx.db.select().from(clips).where(and(eq(clips.id, r.clipId), eq(clips.studioId, u.studioId)));
    if (!clip) throw notFound('Clip');
    if (!clip.storageKey) throw badRequest('Upload the clip file first');
    const seen = new Set<string>();
    for (const c of r.cast) {
      const k = c.personIndex ? `i${c.personIndex}` : c.personHint ? `h${c.personHint}` : '';
      if (k && seen.has(k)) throw badRequest('Two cast entries point at the same person');
      if (k) seen.add(k);
    }
    const prefs = await this.prefs(u.studioId);
    const texts = await this.ctx.prompts.texts(u.studioId);
    const clipTalk = r.cast.length === 1 && r.cast[0]!.speaking === undefined ? await resolveSpeaking(this.ctx, clip, undefined) : null;
    const members = [];
    for (const c of r.cast) {
      const character = await this.character(u.studioId, c.characterId, c.outfitId);
      if (!character?.images.length) throw badRequest('Each recast character needs a character sheet');
      const speaking: 'yes' | 'no' | 'unknown' = typeof c.speaking === 'boolean' ? (c.speaking ? 'yes' : 'no')
        : clipTalk && clipTalk.source !== 'default' ? (clipTalk.speaking ? 'yes' : 'no') : 'unknown';
      members.push({ cast: c, character, speaking });
    }
    const need = { people: r.cast.length, seconds: clip.durationSec, crops: r.cast.filter(c => c.faceCrop).length };
    let pick = pickRecast(r.quality, need, { prefs, providers: this.available(), engineModel: choice?.model, resolution: choice?.source === 'request' ? r.resolution : undefined });
    const skipped = 'error' in pick && choice?.source === 'studio';
    if (skipped) pick = pickRecast(r.quality, need, { prefs, providers: this.available() });
    if ('error' in pick) {
      const e = new ApiError(400, 'nothing_fits', `${TIER_INFO[r.quality].label} can't recast this clip · try another quality, fewer people or a clip of 5–30 s`);
      (e as any).tried = pick.tried;
      throw e;
    }
    const plan = buildRecastPlan(r, members, pick, { key: clip.storageKey, seconds: clip.durationSec }, { texts, priceScale: prefs.models?.[pick.model.id]?.priceScale });
    if (skipped) plan.notes.push(STUDIO_DEFAULT_SKIPPED);
    const talk = { speaking: plan.speaking, source: (r.cast.some(c => typeof c.speaking === 'boolean') ? 'switch' : clipTalk?.source ?? 'default') as 'switch' | 'upload' | 'detected' | 'default' };
    return { swap: false as const, plan, pick: { ...pick, seconds: plan.seconds }, prefs, tried: pick.tried, talk };
  }

  /**
   * Whether she speaks (workstream 4's order): the request's switch, else the uploaded audio's talking flag or its
   * detection (a clip upload, via the clip's stored analysis; any other upload is analysed here), else no.
   */
  private detected = new Map<string, boolean>();
  async resolveSpeaking(studioId: string, r: ShotRequest): Promise<{ speaking: boolean; source: 'switch' | 'upload' | 'detected' | 'default' }> {
    if (typeof r.speaking === 'boolean') return { speaking: r.speaking, source: 'switch' };
    const a = r.references?.audio?.audio;
    const key = a ? this.runner.storageKeyOf(a) : undefined;
    if (!key) return { speaking: false, source: 'default' };
    const [clip] = await this.ctx.db.select().from(clips).where(and(eq(clips.storageKey, key), eq(clips.studioId, studioId)));
    if (clip) return resolveSpeaking(this.ctx, clip, undefined);
    const [up] = await this.ctx.db.select({ id: uploads.id }).from(uploads).where(and(eq(uploads.storageKey, key), eq(uploads.studioId, studioId)));
    if (!up) return { speaking: false, source: 'default' };
    if (this.detected.has(key)) return { speaking: this.detected.get(key)!, source: 'detected' };
    const obj = await this.ctx.storage.get(key).catch(() => null);
    if (!obj) return { speaking: false, source: 'default' };
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-suite-talk-'));
    try {
      const file = path.join(dir, 'audio');
      await pipeline(obj.body, fs.createWriteStream(file));
      const d = await detectTalking(this.ctx.config.FFMPEG_PATH, file);
      this.detected.set(key, d.speaking);
      return { speaking: d.speaking, source: 'detected' };
    } catch { return { speaking: false, source: 'default' }; }
    finally { fs.rmSync(dir, { recursive: true, force: true }); }
  }

  async spentToday(studioId: string) {
    const rows = await this.ctx.db.select({ cost: jobs.cost, actual: jobs.actualCost, state: jobs.state }).from(jobs)
      .where(and(eq(jobs.studioId, studioId), gte(jobs.createdAt, dayStart()), ne(jobs.state, 'failed'), sql`${jobs.request}->>'engine' = 'suite'`));
    return rows.reduce((a, r) => a + (r.state === 'done' && r.actual != null ? r.actual : r.cost), 0);
  }
  /** The suite's own caps (the wallet caps are checked again by the hold). */
  async checkCaps(studioId: string, cost: number, prefs: SuitePrefs) {
    const caps = this.caps(prefs), spent = await this.spentToday(studioId);
    const out = { perJob: caps.perJob, perDay: caps.perDay, spentToday: round2(spent), leftToday: round2(Math.max(0, caps.perDay - spent)), ok: true, code: null as string | null, message: null as string | null };
    if (cost > caps.perJob + 1e-9) Object.assign(out, { ok: false, code: 'suite_over_job_limit', message: `Over the studio's ${P.money(caps.perJob)} per-shot limit` });
    else if (spent + cost > caps.perDay + 1e-9) Object.assign(out, { ok: false, code: 'suite_over_day_limit', message: `Over the studio's ${P.money(caps.perDay)} daily AI suite limit · ${P.money(out.leftToday)} left today` });
    return out;
  }

  /** POST /v1/suite/rig-check: the rig check alone (free, no planning), so the composer can warn even when no engine fits. */
  rigCheck(u: AuthUser, body: unknown) {
    const r = this.parse(body, u);
    return { rig: r.mode === 'swap' || r.mode === 'recast' ? [] : rigCheck({ prompt: r.prompt, camera: r.camera, speaking: r.speaking ?? false }) };
  }

  /** POST /v1/suite/shots/estimate: price, caps and (owner) the engine. Never holds or runs anything. */
  async estimate(u: AuthUser, body: unknown) {
    const r = this.parse(body, u);
    const p = await this.plan(u, r);
    if (p.swap) return p.view;
    const { plan, prefs } = p;
    const caps = await this.checkCaps(u.studioId, plan.estimate, prefs);
    return { ...this.estimateView(u, r, plan, caps, p.tried), speaking: p.talk };
  }
  estimateView(u: AuthUser, r: ShotRequest, plan: ShotPlan, caps: Awaited<ReturnType<SuiteService['checkCaps']>>, tried: { model: string; resolution: string; why: string }[]) {
    const res = plan.resolution.replace(/P$/, 'p');
    const base = {
      quality: plan.tier, label: shotLabel(plan.tier, plan.resolution, plan.mode === 'recast' ? 'Recast' : plan.mode === 'extend' ? 'Extend' : 'Shot'), resolution: res, seconds: plan.seconds, takes: plan.takes, mode: plan.mode,
      estimate: round2(plan.estimate), priceLine: `about ${P.money(plan.estimate)} · ${plan.seconds} s${plan.takes > 1 ? ` · ${plan.takes} takes` : ''}`,
      buttonLabel: `Generate · ${Math.round(plan.seconds * 10) / 10} s · ${P.money(plan.estimate)}${plan.takes > 1 ? ` · ${plan.takes} takes` : ''}`,
      caps, ok: caps.ok, code: caps.code, message: caps.message, warnings: [...plan.notes, ...plan.camera.notes], camera: { moves: plan.camera.moves, guideUsed: plan.camera.usesGuide },
      ...(plan.recast ? { cast: plan.recast.people, keepAudio: plan.recast.keepAudio } : {}),
      prompt: plan.prompt, test: this.mode === 'mock',
      look: shotLook(r.camera ? resolvePreset(r.camera) : undefined, r.gradeLook),
      // Rig check (workstream 3): clashes between the choices and with the prompt; never blocks Generate.
      rig: plan.mode === 'recast' ? [] : rigCheck({ prompt: r.prompt, camera: r.camera, speaking: plan.speaking }),
    };
    if (u.role !== 'owner') return base;
    const m = modelById(plan.modelId)!;
    return { ...base, engine: { model: m.id, name: m.name, provider: m.provider, ref: plan.ref, resolution: plan.resolution, perSec: plan.perSec, billedPerTake: plan.billedPerTake,
      licence: m.licence, notice: m.licence.notice ?? null }, input: { negative: plan.negative ?? null, params: plan.params, images: plan.images, videos: plan.videos, audio: plan.audioRef ?? null }, tried };
  }

  // ------------------------------------------------------------------ swap (the existing character swap as a suite mode)
  private swapRequest(r: ShotRequest) {
    if (!r.modelId || !r.clipId) throw badRequest('Swap needs modelId and clipId');
    const quality = r.quality === 'cinema' ? 'hd' : r.quality;
    return { title: r.title, modelId: r.modelId, outfitId: r.outfitId ?? '', clipId: r.clipId, engine: 'replicate', quality, takes: r.takes, keepAudio: r.keepAudio ?? true, direction: r.direction };
  }
  /**
   * WS13: swap runs on the chosen swap engine (`engineModel`, else the studio's Swap default): the hosted H3 family, or
   * Edit / Fast on our GPU. Priced exactly as POST /v1/jobs will price it (the choice is passed on, not chosen again).
   */
  private async swapEstimate(u: AuthUser, r: ShotRequest, choice: Choice | null = null) {
    const req: Record<string, any> = this.swapRequest(r);
    await applySwapEngine(modelChoice(this.ctx), u, req, undefined, choice);
    const hosted = req.engine === 'replicate';
    if (hosted && !this.ctx.replicate.configured) throw new ApiError(400, 'engine_unavailable', "Swap isn't available right now");
    if (!hosted && this.ctx.gpu.mode === 'runpod') this.ctx.jobs.requireCapabilities(req.engine as 'h3' | 'viggle');
    const [clip] = await this.ctx.db.select().from(clips).where(and(eq(clips.id, req.clipId), eq(clips.studioId, u.studioId)));
    if (!clip) throw notFound('Clip');
    const rr: P.RenderReq = !choice ? { engine: 'replicate', quality: req.quality, takes: req.takes, clipSeconds: clip?.durationSec, pricePerSec: this.ctx.jobs.qualityPrice(req.quality) }
      : (await modelChoice(this.ctx).swapQuote(u.studioId, choice.model, req.quality, clip.durationSec, req.takes)).rr;
    const est = P.totalCost(rr);
    const seconds = hosted ? P.replicateSeconds(rr.clipSeconds) : Math.round(P.lengthSec(rr) * 10) / 10;
    const view = { quality: r.quality, mode: 'swap', label: P.engineLabel(rr), seconds, takes: req.takes, estimate: round2(est), priceLine: P.priceLine(rr),
      buttonLabel: P.genLabel(rr), ok: true, warnings: r.quality === 'cinema' && hosted ? ['Swap tops out at HD'] : [], rig: [], test: false };
    if (u.role === 'owner' && choice) Object.assign(view, { engine: { model: choice.model, name: choice.engine.name, provider: choice.engine.provider, source: choice.source, perSec: (rr as { pricePerSec?: number }).pricePerSec ?? null } });
    return { req, choice, view };
  }

  // ------------------------------------------------------------------ create
  /** POST /v1/suite/shots → the render Job (or, with dryRun, the estimate). */
  async create(u: AuthUser, body: unknown) {
    const r = this.parse(body, u);
    const draft = draftOf(body); // the composer's draft (suite/drafts.ts), stored with the job for "Reuse settings"
    const p = await this.plan(u, r);
    if (p.swap) {
      if (r.dryRun) return { dryRun: true, estimate: p.view };
      return this.ctx.jobs.create(u, { ...p.req, ...(draft ? { draft } : {}) }, { swapChoice: p.choice });
    }
    const { plan, prefs } = p;
    const caps = await this.checkCaps(u.studioId, plan.estimate, prefs);
    if (r.dryRun) return { dryRun: true, estimate: { ...this.estimateView(u, r, plan, caps, p.tried), speaking: p.talk } };
    if (!caps.ok) throw new ApiError(402, caps.code!, caps.message!);
    if (!(await this.runner.toolsReady())) throw new ApiError(400, 'engine_unavailable', "The AI suite isn't available right now");
    await this.checkMedia(u.studioId, plan);
    const label = shotLabel(plan.tier, plan.resolution, plan.mode === 'recast' ? 'Recast' : plan.mode === 'extend' ? 'Extend' : 'Shot');
    const request = {
      engine: 'suite', mode: plan.mode, quality: plan.tier, label, engineLabel: label, takeLabel: TIER_INFO[plan.tier].label, seconds: plan.seconds, takes: plan.takes, aspectRatio: plan.aspect, audio: plan.audio, speaking: p.talk.speaking, speakingSource: p.talk.source,
      prompt: r.prompt, direction: r.direction, camera: r.camera, frames: r.frames, references: r.references, modelId: r.modelId ?? plan.recast?.people[0]?.characterId, outfitId: r.outfitId,
      keepAudio: plan.recast?.keepAudio ?? true, ...(plan.recast ? { clipId: r.clipId, cast: plan.recast.people } : {}),
      // The take's Look (suite/looks.ts): the Edit suite opens with this LUT applied (reversible).
      look: shotLook(r.camera ? resolvePreset(r.camera) : undefined, r.gradeLook),
    };
    const perTake = 45 + plan.seconds * 10 * (plan.tier === 'draft' ? 0.6 : plan.tier === 'cinema' ? 2 : plan.tier === 'hd' ? 1.5 : 1);
    const seed = r.seed ?? 1000 + Math.floor(Math.random() * 99000);
    const leadId = r.modelId ?? plan.recast?.people[0]?.characterId;
    const [mrow] = leadId ? await this.ctx.db.select({ name: models.name, slots: models.slots }).from(models).where(eq(models.id, leadId)) : [];
    const thumb = (plan.images.start ?? plan.images.refs.find(x => x.role === 'character')?.image ?? mrow?.slots?.[0]?.image ?? null) as ImageRef | null;
    const job = await this.ctx.jobs.createInternal(u, {
      kind: 'render', title: r.title ?? (plan.recast ? 'Recast' : 'Untitled shot'), modelId: leadId ?? '', modelName: mrow?.name ?? '', outfitId: r.outfitId ?? '', request,
      cost: round2(plan.estimate * 10000) / 10000, prompt: plan.prompt, seed, thumb, totalSeconds: perTake * plan.takes, totalSteps: plan.takes, phase: 'Queued',
      stats: { suite: { plan, mode: this.mode } }, draft,
    });
    return this.ctx.jobs.view(job);
  }

  /** Videos must be ours (an upload in this studio) or https; images are checked when they are signed at run time. */
  private async checkMedia(studioId: string, plan: ShotPlan) {
    if (plan.audioRef) {
      const key = this.runner.storageKeyOf(plan.audioRef.ref);
      if (key) {
        const [row] = await this.ctx.db.select({ id: uploads.id }).from(uploads).where(and(eq(uploads.storageKey, key), eq(uploads.studioId, studioId)));
        if (!row) throw badRequest('That audio isn’t in this studio');
      } else if (plan.audioRef.beatOnly) throw badRequest('Upload the audio to use it as a beat (only an upload can have its vocals removed)');
      else if (!/^https:\/\//.test(plan.audioRef.ref.url ?? '')) throw badRequest('Audio must be an upload or an https link');
    }
    for (const v of plan.videos) {
      if (v.video.key) {
        const [row] = await this.ctx.db.select({ id: uploads.id }).from(uploads).where(and(eq(uploads.storageKey, v.video.key), eq(uploads.studioId, studioId)));
        const [clip] = row ? [] : await this.ctx.db.select({ id: clips.id }).from(clips).where(and(eq(clips.storageKey, v.video.key), eq(clips.studioId, studioId)));
        // Extend continues a finished take (its stored video).
        const [take] = row || clip ? [] : await this.ctx.db.select({ id: takes.id }).from(takes).where(and(eq(takes.mediaKey, v.video.key), eq(takes.studioId, studioId)));
        if (!row && !clip && !take) throw badRequest('That video isn’t in this studio');
      } else if (v.video.url && !/^https:\/\//.test(v.video.url) && !/\/uploads\//.test(v.video.url)) throw badRequest('Videos must be uploads or https links');
    }
  }

  /** A shot's details: the job view, plus the plan's engine for the owner. */
  async shot(u: AuthUser, id: string) {
    const j = await this.ctx.jobs.get(id);
    if (!j || j.studioId !== u.studioId || !isSuiteJob(j) || j.hiddenAt) throw notFound('Shot');
    const plan = (j.stats as any)?.suite?.plan as ShotPlan | undefined;
    const view = { job: this.ctx.jobs.view(j), warnings: plan ? [...plan.notes, ...plan.camera.notes] : [] };
    if (u.role !== 'owner' || !plan) return view;
    const m = modelById(plan.modelId);
    return { ...view, engine: { model: plan.modelId, name: m?.name, provider: plan.provider, ref: plan.ref, resolution: plan.resolution, perSec: plan.perSec, test: (j.stats as any)?.suite?.mode === 'mock' },
      runs: (j.stats as any)?.suite?.takes ?? [] };
  }

  /**
   * GET /v1/suite/targets: what a guide clip (Blender render) should be for each quality that can use one: length,
   * reference-video length limits, aspect ratios, output size. The owner also gets the model per step.
   */
  async targets(u: AuthUser) {
    const prefs = await this.prefs(u.studioId);
    const avail = this.available();
    return TIERS.map(t => {
      const steps = (prefs.ladder?.[t]?.length ? prefs.ladder[t]! : DEFAULT_LADDER[t]).map(s => ({ s, m: modelById(s.model) }))
        .filter(x => x.m && x.m.camera.referenceVideo && x.m.status !== 'removed' && !x.m.licence.blockNewFeatures && prefs.models?.[x.m.id]?.enabled !== false && avail.has(x.m.provider));
      const first = steps[0];
      if (!first) return { quality: t, label: TIER_INFO[t].label, available: false };
      const m = first.m!, res = m.resolutions.find(r => r.id === first.s.resolution) ?? m.resolutions[0]!;
      const base = { quality: t, label: TIER_INFO[t].label, available: true, minSeconds: m.duration.min, maxSeconds: m.duration.max,
        guideSeconds: { min: m.refs.videoSecondsMin ?? 1, max: m.refs.videoSecondsMax ?? m.duration.max }, aspectRatios: m.aspectRatios,
        shortSide: res.shortSide, fps: 24, keyframes: { start: m.frames.start, middle: m.frames.middle, end: m.frames.end } };
      return u.role === 'owner' ? { ...base, model: m.id, name: m.name, resolution: res.id } : base;
    });
  }

  /** POST /v1/suite/camera/compile: what a CameraSpec becomes on a quality's model (or, for the owner, any model). */
  async compile(u: AuthUser, body: unknown) {
    const b = (body ?? {}) as { camera?: unknown; quality?: unknown; engineModel?: unknown; duration?: unknown };
    const spec = CameraSpecSchema.safeParse(b.camera ?? {});
    if (!spec.success) throw badRequest(`Invalid camera: ${spec.error.issues[0]?.path.join('.')} ${spec.error.issues[0]?.message}`);
    if (b.engineModel !== undefined && u.role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can pick the engine');
    const tier = (TIERS as string[]).includes(String(b.quality)) ? (b.quality as Tier) : 'cinema';
    const prefs = await this.prefs(u.studioId);
    const id = typeof b.engineModel === 'string' ? b.engineModel : (prefs.ladder?.[tier]?.[0] ?? DEFAULT_LADDER[tier][0]!).model;
    const m = modelById(id);
    if (!m) throw badRequest('Unknown model');
    const c = compileCamera(spec.data, m, { texts: await this.ctx.prompts.texts(u.studioId), durationS: typeof b.duration === 'number' ? b.duration : 5 });
    const base = { text: c.text, moves: c.moves, guideUsed: c.usesGuide, warnings: c.notes };
    return u.role === 'owner' ? { ...base, engine: { model: m.id, name: m.name }, params: c.params, avoid: c.avoid } : base;
  }
}

export { MOCK_MODEL };
