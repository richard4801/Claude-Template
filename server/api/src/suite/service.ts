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
import { clips, jobs, models, outfits, uploads, type ImageRef } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { dayStart, round2 } from '../lib/util.js';
import * as P from '../pricing.js';
import { replicateReferencesFor } from '../services/jobs.js';
import { cameraCatalog, CameraSpecSchema, resolvePreset } from './camera.js';
import { shotLook } from './looks.js';
import { compileCamera } from './compile.js';
import { buildRecastPlan, pickRecast } from './recast.js';
import { buildPlan, needOf, pickModel, shotLabel, ShotRequestSchema, type Character, type ShotPlan, type ShotRequest, type SuitePrefs } from './plan.js';
import { FalProvider, MockProvider, ReplicateProvider, type VideoProvider } from './providers.js';
import { DEFAULT_LADDER, inputSlotsOf, MODELS, modelById, modelView, MOCK_MODEL, TIER_INFO, TIERS, type ProviderId, type Tier } from './registry.js';
import { SuiteRunner } from './runner.js';
import { suiteSettings } from './schema.js';

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
  constructor(private ctx: Ctx, fetchFn?: typeof fetch) {
    this.mock = new MockProvider(ctx);
    this.providers = { replicate: new ReplicateProvider(ctx), fal: new FalProvider(ctx, fetchFn), mock: this.mock };
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
    if (this.mode === 'mock') return new Set(['replicate', 'fal', 'mock']);
    const s = new Set<ProviderId>();
    if (this.providers.replicate.configured()) s.add('replicate');
    if (this.providers.fal.configured()) s.add('fal');
    return s;
  }

  // ------------------------------------------------------------------ settings (owner)
  async prefs(studioId: string): Promise<SuitePrefs> {
    const [r] = await this.ctx.db.select().from(suiteSettings).where(eq(suiteSettings.studioId, studioId));
    return r ? { models: r.models, ladder: r.ladder ?? undefined, capPerJob: r.capPerJob, capPerDay: r.capPerDay } : {};
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
      if (!m || m.id === 'mock') throw badRequest(`Unknown model ${id}`);
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
            if (!m || m.id === 'mock' || !m.resolutions.some(r => r.id === s?.resolution)) throw badRequest(`ladder.${tier}: unknown model or resolution`);
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
    return { enabled: this.mode !== 'off', test: this.mode === 'mock', defaultQuality: 'draft', tiers, modes: ['text', 'image', 'reference', 'swap', 'recast'], recastMaxPeople: 4,
      aspectRatios: ['9:16', '16:9', '1:1', '4:3', '3:4', '21:9'], takesMax: 4, camera: cameraCatalog() };
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
    if ((r.data.engineModel || r.data.resolution) && u.role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can pick the engine');
    return r.data;
  }

  /** Plans the shot. Throws engine_unavailable / nothing_fits. Swap shots return the existing engine's estimate. */
  async plan(u: AuthUser, r: ShotRequest) {
    if (this.mode === 'off') throw new ApiError(400, 'engine_unavailable', "The AI suite isn't switched on yet");
    if (r.mode === 'swap') return { swap: true as const, ...(await this.swapEstimate(u, r)) };
    if (r.mode === 'recast' || r.cast?.length) return this.recastPlan(u, r);
    const prefs = await this.prefs(u.studioId);
    const character = await this.character(u.studioId, r.modelId, r.outfitId);
    const need = needOf(r, character);
    if (need.mode === 'image' && !need.start && !need.end) throw badRequest('Keyframe shots need a start or end frame');
    if (need.mode === 'reference' && !character?.images.length && !need.extraImages) throw badRequest('Reference shots need a character with a sheet, or reference images');
    if (need.mode === 'text' && !r.prompt.trim()) throw badRequest('Describe the shot');
    const pick = pickModel(r.quality, need, { prefs, providers: this.available(), engineModel: r.engineModel, resolution: r.resolution });
    if ('error' in pick) {
      const e = new ApiError(400, 'nothing_fits', `${TIER_INFO[r.quality].label} can't make this shot · try another quality, a shorter length or fewer references`);
      (e as any).tried = pick.tried;
      throw e;
    }
    const texts = await this.ctx.prompts.texts(u.studioId);
    const talk = await this.resolveSpeaking(u.studioId, r);
    const plan = buildPlan(r, need, pick, character, { texts, priceScale: prefs.models?.[pick.model.id]?.priceScale, speaking: talk.speaking,
      separationUsd: SEPARATION_ESTIMATE_USD });
    return { swap: false as const, plan, pick, prefs, tried: pick.tried, talk };
  }

  /**
   * Recast (same take, new cast): up to 4 people in the source clip, each → a studio character. Speaking per person:
   * its switch; else, with one person, the clip's (switch → upload → detection); else unknown (the mouth follows the clip).
   */
  private async recastPlan(u: AuthUser, r: ShotRequest) {
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
    const pick = pickRecast(r.quality, need, { prefs, providers: this.available(), engineModel: r.engineModel, resolution: r.resolution });
    if ('error' in pick) {
      const e = new ApiError(400, 'nothing_fits', `${TIER_INFO[r.quality].label} can't recast this clip · try another quality, fewer people or a clip of 5–30 s`);
      (e as any).tried = pick.tried;
      throw e;
    }
    const plan = buildRecastPlan(r, members, pick, { key: clip.storageKey, seconds: clip.durationSec }, { texts, priceScale: prefs.models?.[pick.model.id]?.priceScale });
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
      quality: plan.tier, label: shotLabel(plan.tier, plan.resolution, plan.mode === 'recast' ? 'Recast' : 'Shot'), resolution: res, seconds: plan.seconds, takes: plan.takes, mode: plan.mode,
      estimate: round2(plan.estimate), priceLine: `about ${P.money(plan.estimate)} · ${plan.seconds} s${plan.takes > 1 ? ` · ${plan.takes} takes` : ''}`,
      buttonLabel: `Generate · ${plan.seconds} s · ${P.money(plan.estimate)}${plan.takes > 1 ? ` · ${plan.takes} takes` : ''}`,
      caps, ok: caps.ok, code: caps.code, message: caps.message, warnings: [...plan.notes, ...plan.camera.notes], camera: { moves: plan.camera.moves, guideUsed: plan.camera.usesGuide },
      ...(plan.recast ? { cast: plan.recast.people, keepAudio: plan.recast.keepAudio } : {}),
      prompt: plan.prompt, test: this.mode === 'mock',
      look: plan.recast ? null : shotLook(r.camera ? resolvePreset(r.camera) : undefined, r.gradeLook),
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
  private async swapEstimate(u: AuthUser, r: ShotRequest) {
    const req = this.swapRequest(r);
    if (!this.ctx.replicate.configured) throw new ApiError(400, 'engine_unavailable', "Swap isn't available right now");
    const [clip] = await this.ctx.db.select().from(clips).where(and(eq(clips.id, req.clipId), eq(clips.studioId, u.studioId)));
    if (!clip) throw notFound('Clip');
    const rr: P.RenderReq = { engine: 'replicate', quality: req.quality, takes: req.takes, clipSeconds: clip?.durationSec, pricePerSec: this.ctx.jobs.qualityPrice(req.quality) };
    const est = P.totalCost(rr);
    return { req, view: { quality: r.quality, mode: 'swap', label: P.engineLabel(rr), seconds: P.replicateSeconds(rr.clipSeconds), takes: req.takes, estimate: round2(est), priceLine: P.priceLine(rr),
      buttonLabel: P.genLabel(rr), ok: true, warnings: r.quality === 'cinema' ? ['Swap tops out at HD'] : [], test: false } };
  }

  // ------------------------------------------------------------------ create
  /** POST /v1/suite/shots → the render Job (or, with dryRun, the estimate). */
  async create(u: AuthUser, body: unknown) {
    const r = this.parse(body, u);
    const p = await this.plan(u, r);
    if (p.swap) {
      if (r.dryRun) return { dryRun: true, estimate: p.view };
      return this.ctx.jobs.create(u, p.req);
    }
    const { plan, prefs } = p;
    const caps = await this.checkCaps(u.studioId, plan.estimate, prefs);
    if (r.dryRun) return { dryRun: true, estimate: { ...this.estimateView(u, r, plan, caps, p.tried), speaking: p.talk } };
    if (!caps.ok) throw new ApiError(402, caps.code!, caps.message!);
    if (!(await this.runner.toolsReady())) throw new ApiError(400, 'engine_unavailable', "The AI suite isn't available right now");
    await this.checkMedia(u.studioId, plan);
    const label = shotLabel(plan.tier, plan.resolution, plan.mode === 'recast' ? 'Recast' : 'Shot');
    const request = {
      engine: 'suite', mode: plan.mode, quality: plan.tier, label, engineLabel: label, takeLabel: TIER_INFO[plan.tier].label, seconds: plan.seconds, takes: plan.takes, aspectRatio: plan.aspect, audio: plan.audio, speaking: p.talk.speaking, speakingSource: p.talk.source,
      prompt: r.prompt, direction: r.direction, camera: r.camera, frames: r.frames, references: r.references, modelId: r.modelId ?? plan.recast?.people[0]?.characterId, outfitId: r.outfitId,
      keepAudio: plan.recast?.keepAudio ?? true, ...(plan.recast ? { clipId: r.clipId, cast: plan.recast.people } : {}),
      // The take's Look (suite/looks.ts): the Edit suite opens with this LUT applied (reversible).
      look: plan.recast ? null : shotLook(r.camera ? resolvePreset(r.camera) : undefined, r.gradeLook),
    };
    const perTake = 45 + plan.seconds * 10 * (plan.tier === 'draft' ? 0.6 : plan.tier === 'cinema' ? 2 : plan.tier === 'hd' ? 1.5 : 1);
    const seed = r.seed ?? 1000 + Math.floor(Math.random() * 99000);
    const leadId = r.modelId ?? plan.recast?.people[0]?.characterId;
    const [mrow] = leadId ? await this.ctx.db.select({ name: models.name, slots: models.slots }).from(models).where(eq(models.id, leadId)) : [];
    const thumb = (plan.images.start ?? plan.images.refs.find(x => x.role === 'character')?.image ?? mrow?.slots?.[0]?.image ?? null) as ImageRef | null;
    const job = await this.ctx.jobs.createInternal(u, {
      kind: 'render', title: r.title ?? (plan.recast ? 'Recast' : 'Untitled shot'), modelId: leadId ?? '', modelName: mrow?.name ?? '', outfitId: r.outfitId ?? '', request,
      cost: round2(plan.estimate * 10000) / 10000, prompt: plan.prompt, seed, thumb, totalSeconds: perTake * plan.takes, totalSteps: plan.takes, phase: 'Queued',
      stats: { suite: { plan, mode: this.mode } },
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
        if (!row && !clip) throw badRequest('That video isn’t in this studio');
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
