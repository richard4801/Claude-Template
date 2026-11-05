// Enhance and Dress up for a model's character sheet (plans/api.md "Model tools" §4–6). One hold for the whole run (the
// sum of per-image estimates), images one after another through the shared Replicate gate, each image's exact cost added,
// one settle at the end; then the user reviews every image (keep / reject / retry one) and applies what they kept.
import { and, desc, eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { models, outfits, toolRuns, type ImageRef, type SheetSlot, type SheetVersion, type ToolItem } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { whoOf } from '../money/money.js';
import { PhotoBill } from '../images/bill.js';
import { PhotoError, PHOTO_FAILED } from '../images/service.js';
import { modelName, type StepOverrides } from '../images/steps.js';
import type { ImageStep } from '../replicate/mapping.js';
import { PHOTO_REF_MP, money } from '../pricing.js';
import { randomImageSeed } from '../templates/prompt.js';

type Run = typeof toolRuns.$inferSelect;
type ModelRow = typeof models.$inferSelect;

/** The 7 sheet images in the order apps show them (plans/api.md "Model tools" §1). */
export const SHEET_SLOTS: { key: string; label: string; kind: 'face' | 'body' }[] = [
  { key: 'face', label: 'Face · front', kind: 'face' }, { key: 'faceTq', label: 'Face · ¾', kind: 'face' }, { key: 'profile', label: 'Face · profile', kind: 'face' },
  { key: 'front', label: 'Full body · front', kind: 'body' }, { key: 'tq', label: 'Full body · ¾', kind: 'body' }, { key: 'side', label: 'Full body · side', kind: 'body' },
  { key: 'back', label: 'Full body · back', kind: 'body' },
];
const slotInfo = (k: string) => SHEET_SLOTS.find(s => s.key === k)!;
/** Dress up renders the full-body front first, so the other images can match it. */
const DRESS_ORDER = ['front', 'tq', 'side', 'back', 'face', 'faceTq', 'profile'];

export const REALISM = { off: 0, subtle: 0.25, balanced: 0.35, strong: 0.5 } as const;
export type RealismId = keyof typeof REALISM;
export const UPSCALE = { off: 0, '2x': 2, '4x': 4 } as const;
export type UpscaleId = keyof typeof UPSCALE;
export const ENHANCE_PROMPT = 'candid smartphone photo, natural skin texture with visible pores and fine lines, true-to-life colour, soft natural light, no retouching, no beauty filter';
export const DRESS_OPTIONS = [
  { id: 'a', label: 'Option A', detail: 'Keeps each photo closest' },
  { id: 'b', label: 'Option B', detail: 'Richer detail' },
  { id: 'both', label: 'Both', detail: 'Makes both · pick per photo' },
] as const;
const stepOf = (e: 'a' | 'b'): ImageStep => (e === 'a' ? 'dressA' : 'dressB');

/** The Dress up prompt for one sheet image. */
export function dressPrompt(slot: string, withAnchor: boolean) {
  const anchor = withAnchor ? ' The last image shows the same outfit already worn: match its colours, prints and details exactly.' : '';
  if (slotInfo(slot).kind === 'body') {
    return 'Dress the person in the first image in the outfit from the second image: every garment, shoe and accessory, with the same colours, prints, fabrics and details.'
      + anchor + ' Keep the face, hair, body, skin, pose, framing, camera angle and background exactly as in the first image. Realistic photo, natural skin texture.';
  }
  return 'Add to the person in the first image only what shows of the outfit from the second image at this distance: earrings, necklace, glasses, hat or hair pieces, and the neckline of the top.'
    + anchor + ' Keep the face, expression, hair, skin, pose, framing and background exactly as in the first image. Realistic close-up photo, natural skin texture.';
}

const ENHANCE_BODY = (b: any) => ({
  realism: (b?.realism ?? 'balanced') as RealismId, upscale: (b?.upscale ?? '2x') as UpscaleId,
  slots: Array.isArray(b?.slots) ? (b.slots as unknown[]).filter((x): x is string => typeof x === 'string') : null,
});

export class ToolService {
  /** Runs being stopped (discarded while running). */
  private stopping = new Set<string>();
  constructor(private ctx: Ctx) {}

  features(role: string) {
    const enhance: Record<string, unknown> = { available: true,
      realism: [{ id: 'off', label: 'Off' }, { id: 'subtle', label: 'Subtle' }, { id: 'balanced', label: 'Balanced' }, { id: 'strong', label: 'Strong' }],
      upscale: [{ id: 'off', label: 'Off' }, { id: '2x', label: '2×' }, { id: '4x', label: '4×' }] };
    const dressUp: Record<string, unknown> = { available: true, options: DRESS_OPTIONS.map(o => ({ ...o })) };
    void role;
    return { enhance, dressUp };
  }
  /** Owner extra for features.tools: the current default per step (names only for the owner). */
  async ownerModels(studioId: string) {
    const all = await this.ctx.imageModels.resolveAll(studioId);
    const pick = (s: ImageStep) => ({ model: all[s].model, name: modelName(all[s].model) });
    return { enhance: { realism: pick('realism'), upscale: pick('upscale') }, dressUp: { dressA: pick('dressA'), dressB: pick('dressB') } };
  }

  // ------------------------------------------------------------------ helpers
  async modelFor(u: AuthUser, id: string, forWork = true) {
    const [m] = await this.ctx.db.select().from(models).where(and(eq(models.id, id), eq(models.studioId, u.studioId)));
    if (!m) throw notFound('Model');
    if (forWork && m.archivedAt) throw new ApiError(409, 'model_archived', 'This model is archived · restore her in Settings → Archived models');
    return m;
  }
  private filled(m: ModelRow, only?: string[] | null) {
    return SHEET_SLOTS.filter(s => (!only || only.includes(s.key)) && m.slots.find(x => x.key === s.key)?.image && !m.slots.find(x => x.key === s.key)?.busy)
      .map(s => ({ ...s, image: m.slots.find(x => x.key === s.key)!.image! }));
  }
  private async row(u: AuthUser, id: string) {
    const [r] = await this.ctx.db.select().from(toolRuns).where(and(eq(toolRuns.id, id), eq(toolRuns.studioId, u.studioId)));
    if (!r) throw notFound('Run');
    return r;
  }
  view(r: Run, role: string) {
    return compact({ id: r.id, kind: r.kind, modelId: r.modelId, state: r.state, options: r.options, engines: r.engines, items: r.items, estimate: r.estimate,
      cost: r.cost, progress: Math.round(r.progress * 10) / 10, phase: r.phase, error: r.error ?? undefined, createdAt: r.createdAt, finishedAt: r.finishedAt ?? undefined,
      appliedAt: r.appliedAt ?? undefined, outfitId: r.outfitId ?? undefined, models: role === 'owner' ? r.models : undefined });
  }
  private async save(id: string, patch: Partial<Run>) {
    const [r] = await this.ctx.db.update(toolRuns).set(patch).where(eq(toolRuns.id, id)).returning();
    if (r) this.ctx.hub.emit(r.studioId, { type: 'tool', tool: this.view(r, 'member') });
    return r!;
  }
  private label(n: number, est: number, options = 1) { return `${n} image${n === 1 ? '' : 's'}${options > 1 ? ` · ${options} options` : ''} · about ${money(est)}`; }

  // ------------------------------------------------------------------ estimates
  private async enhancePerImage(studioId: string, realism: RealismId, upscale: UpscaleId, ov?: StepOverrides) {
    const im = this.ctx.imageModels;
    let v = 0;
    if (realism !== 'off') v += await im.estimate((await im.resolve(studioId, 'realism', ov)).model, { outMp: 1, inMp: PHOTO_REF_MP });
    if (upscale !== 'off') v += await im.estimate((await im.resolve(studioId, 'upscale', ov)).model, { outMp: 4, inMp: PHOTO_REF_MP, scale: UPSCALE[upscale] });
    return v;
  }
  async enhanceEstimate(u: AuthUser, modelId: string, body: unknown) {
    const m = await this.modelFor(u, modelId);
    const ov = this.ctx.imageModels.overridesFrom(u.role, (body ?? {}) as any);
    const b = this.checkEnhance(body);
    const n = this.filled(m, b.slots).length;
    const per = await this.enhancePerImage(u.studioId, b.realism, b.upscale, ov);
    const est = per * n;
    return { images: n, estimate: est, perImage: per, label: this.label(n, est) };
  }
  private checkEnhance(body: unknown) {
    const b = ENHANCE_BODY(body);
    if (!(b.realism in REALISM)) throw badRequest('realism: off, subtle, balanced or strong');
    if (!(b.upscale in UPSCALE)) throw badRequest('upscale: off, 2x or 4x');
    if (b.realism === 'off' && b.upscale === 'off') throw badRequest('Turn on realism or upscale');
    return b;
  }
  private dressEngines(e: unknown): ('a' | 'b')[] {
    const v = e ?? 'a';
    if (v === 'both') return ['a', 'b'];
    if (v === 'a' || v === 'b') return [v];
    throw badRequest('engine: a, b or both');
  }
  private async dressPerEngine(studioId: string, eng: 'a' | 'b', n: number, ov?: StepOverrides) {
    const model = (await this.ctx.imageModels.resolve(studioId, stepOf(eng), ov)).model;
    // The front sends 2 images (sheet + outfit), every other image 3 (+ the new front).
    let v = 0;
    for (let i = 0; i < n; i++) v += await this.ctx.imageModels.estimate(model, { outMp: 1, inMp: PHOTO_REF_MP * (i === 0 ? 2 : 3) });
    return v;
  }
  async dressEstimate(u: AuthUser, modelId: string, body: unknown) {
    const m = await this.modelFor(u, modelId);
    const b = (body ?? {}) as any;
    const ov = this.ctx.imageModels.overridesFrom(u.role, b);
    const engines = this.dressEngines(b.engine);
    const n = this.filled(m).length;
    let est = 0;
    for (const e of engines) est += await this.dressPerEngine(u.studioId, e, n, ov);
    return { images: n, estimate: est, label: this.label(n, est, engines.length) };
  }

  // ------------------------------------------------------------------ start
  async startEnhance(u: AuthUser, modelId: string, body: unknown) {
    const m = await this.modelFor(u, modelId);
    const ov = this.ctx.imageModels.overridesFrom(u.role, (body ?? {}) as any);
    const b = this.checkEnhance(body);
    const slots = this.filled(m, b.slots);
    if (!slots.length) throw badRequest('Add photos to the character sheet first');
    const per = await this.enhancePerImage(u.studioId, b.realism, b.upscale, ov);
    const all = await this.ctx.imageModels.resolveAll(u.studioId, ov);
    const id = uid('tool');
    const bill = await new PhotoBill(this.ctx, whoOf(u), id, per * slots.length, `Enhance · ${slots.length} image${slots.length === 1 ? '' : 's'}`).start();
    const items: ToolItem[] = slots.map(s => ({ slot: s.key, label: s.label, before: s.image, results: {}, state: 'waiting', decision: 'pending', pick: null, cost: 0 }));
    const usedModels: Record<string, string> = {};
    if (b.realism !== 'off') usedModels.realism = all.realism.model;
    if (b.upscale !== 'off') usedModels.upscale = all.upscale.model;
    const [r] = await this.ctx.db.insert(toolRuns).values({ id, studioId: u.studioId, modelId: m.id, kind: 'enhance', state: 'running',
      options: { realism: b.realism, upscale: b.upscale, seed: randomImageSeed() }, engines: ['a'], models: usedModels, items, estimate: per * slots.length,
      phase: `Enhancing · 1 of ${items.length}`, createdBy: u.id, createdAt: Date.now() }).returning();
    void this.run(r!, u, bill).catch(e => this.ctx.log.error({ err: (e as Error).message }, 'enhance failed'));
    return this.view(r!, u.role);
  }

  async startDressUp(u: AuthUser, modelId: string, body: unknown) {
    const m = await this.modelFor(u, modelId);
    const b = (body ?? {}) as any;
    const ov = this.ctx.imageModels.overridesFrom(u.role, b);
    const engines = this.dressEngines(b.engine);
    const outfitImage = b.outfitImage as ImageRef | undefined;
    if (!outfitImage || (!outfitImage.url && !outfitImage.asset)) throw badRequest('Add the outfit photo');
    if (typeof b.name === 'string' && b.name.length > 80) throw badRequest('name: at most 80 characters');
    const slots = this.filled(m);
    if (!slots.length) throw badRequest('Add photos to the character sheet first');
    let est = 0;
    for (const e of engines) est += await this.dressPerEngine(u.studioId, e, slots.length, ov);
    const all = await this.ctx.imageModels.resolveAll(u.studioId, ov);
    const id = uid('tool');
    const bill = await new PhotoBill(this.ctx, whoOf(u), id, est, `Dress up · ${slots.length} image${slots.length === 1 ? '' : 's'}${engines.length > 1 ? ' · 2 options' : ''}`).start();
    const ordered = DRESS_ORDER.map(k => slots.find(s => s.key === k)).filter(Boolean) as typeof slots;
    const items: ToolItem[] = ordered.map(s => ({ slot: s.key, label: s.label, before: s.image, results: {}, state: 'waiting', decision: 'pending', pick: null, cost: 0 }));
    const usedModels: Record<string, string> = {};
    for (const e of engines) usedModels[stepOf(e)] = all[stepOf(e)].model;
    const name = typeof b.name === 'string' && b.name.trim() ? b.name.trim() : null;
    const [r] = await this.ctx.db.insert(toolRuns).values({ id, studioId: u.studioId, modelId: m.id, kind: 'dressup', state: 'running',
      options: { engine: engines.length > 1 ? 'both' : engines[0], name, outfitImage, seed: randomImageSeed() }, engines, models: usedModels, items, estimate: est,
      phase: `Dressing up · 1 of ${items.length * engines.length}`, createdBy: u.id, createdAt: Date.now() }).returning();
    void this.run(r!, u, bill).catch(e => this.ctx.log.error({ err: (e as Error).message }, 'dress up failed'));
    return this.view(r!, u.role);
  }

  // ------------------------------------------------------------------ running
  /** One image of a run on one engine (a = the only result for Enhance). Returns its image and exact cost. */
  private async one(run: Run, u: { id: string; studioId: string }, item: ToolItem, eng: 'a' | 'b', seed: number, anchor: ImageRef | null) {
    const im = this.ctx.imageModels, imgs = this.ctx.images;
    const o = run.options as any;
    const cancelled = () => this.stopping.has(run.id);
    if (run.kind === 'enhance') {
      let img = item.before!, cost = 0;
      try {
        if (o.realism !== 'off') {
          const ch = await im.resolve(u.studioId, 'realism', { realism: run.models.realism });
          const r = await imgs.runModel({ studioId: u.studioId, userId: u.id, purpose: 'enhance', refId: run.id, step: 'realism', model: ch.model, extra: ch.extra,
            prompt: ENHANCE_PROMPT, refs: [img], fullSize: true, strength: REALISM[o.realism as RealismId], seed, outMp: 1, cancelled });
          img = r.image; cost += r.cost;
        }
        if (o.upscale !== 'off') {
          const ch = await im.resolve(u.studioId, 'upscale', { upscale: run.models.upscale });
          const r = await imgs.runModel({ studioId: u.studioId, userId: u.id, purpose: 'enhance', refId: run.id, step: 'upscale', model: ch.model, extra: ch.extra,
            refs: [img], fullSize: true, scale: UPSCALE[o.upscale as UpscaleId], strength: 0.2, seed, outMp: 4, cancelled });
          img = r.image; cost += r.cost;
        }
      } catch (e) { throw e instanceof PhotoError ? new PhotoError(e.status, e.code, e.message, e.spentUsd + cost) : e; }
      return { image: img, cost };
    }
    const step = stepOf(eng);
    const ch = await im.resolve(u.studioId, step, { [step]: run.models[step] });
    const useAnchor = !!anchor && item.slot !== 'front';
    const r = await imgs.runModel({ studioId: u.studioId, userId: u.id, purpose: 'dressup', refId: run.id, step, model: ch.model, extra: ch.extra,
      prompt: dressPrompt(item.slot, useAnchor), refs: [item.before, o.outfitImage as ImageRef, ...(useAnchor ? [anchor] : [])], matchInput: true, seed, outMp: 1,
      simulate: item.before, cancelled });
    return { image: r.image, cost: r.cost };
  }

  private async run(start: Run, u: AuthUser, bill: PhotoBill) {
    const items = start.items.map(i => ({ ...i, results: { ...i.results } }));
    const seed = Number((start.options as any).seed ?? 0);
    const total = items.length * start.engines.length;
    let done = 0, firstError: PhotoError | null = null, fatal = false, cost = 0;
    for (const eng of start.engines) {
      let anchor: ImageRef | null = null;
      for (const item of items) {
        if (this.stopping.has(start.id) || fatal) break;
        item.state = 'running';
        await this.save(start.id, { items, phase: `${start.kind === 'enhance' ? 'Enhancing' : 'Dressing up'} · ${done + 1} of ${total}`, progress: done / total * 100 });
        try {
          const r = await this.one(start, u, item, eng, seed, anchor);
          item.results[eng] = r.image;
          item.cost += r.cost; cost += r.cost;
          bill.add(r.cost);
          if (item.slot === 'front' || (!anchor && slotInfo(item.slot).kind === 'body')) anchor = r.image;
        } catch (e) {
          const pe = e instanceof PhotoError ? e : await this.ctx.images.photoError(start.studioId, e, 0);
          bill.waste(pe.spentUsd);
          item.results[eng] = null;
          firstError ??= pe;
          if (['provider_out_of_credit', 'provider_rate_limited', 'engine_unavailable'].includes(pe.code)) fatal = true;
        }
        done++;
        const finished = start.engines.every(en => en in item.results) || this.stopping.has(start.id) || fatal;
        if (finished || start.engines.length === 1) item.state = Object.values(item.results).some(Boolean) ? 'done' : 'failed';
        else item.state = 'waiting';
        if (item.state === 'failed') item.error = firstError?.message ?? PHOTO_FAILED;
      }
    }
    for (const item of items) {
      if (item.state === 'running' || item.state === 'waiting') item.state = Object.values(item.results).some(Boolean) ? 'done' : 'failed';
      if (item.state === 'failed') item.error ??= firstError?.message ?? PHOTO_FAILED;
    }
    const stopped = this.stopping.has(start.id);
    this.stopping.delete(start.id);
    const any = items.some(i => i.state === 'done');
    if (any && !stopped) await bill.finish(); else await bill.fail();
    await this.save(start.id, {
      items, cost: any && !stopped ? bill.spent : 0, progress: 100, finishedAt: Date.now(),
      state: stopped ? 'discarded' : any ? 'review' : 'failed', phase: stopped ? 'Discarded' : any ? 'Ready to review' : 'Failed',
      error: any || stopped ? null : firstError?.message ?? PHOTO_FAILED,
    });
    void cost;
  }

  // ------------------------------------------------------------------ review
  async list(u: AuthUser, q: { modelId?: string; kind?: string }) {
    const conds = [eq(toolRuns.studioId, u.studioId)];
    if (q.modelId) conds.push(eq(toolRuns.modelId, q.modelId));
    if (q.kind === 'enhance' || q.kind === 'dressup') conds.push(eq(toolRuns.kind, q.kind));
    const rows = await this.ctx.db.select().from(toolRuns).where(and(...conds)).orderBy(desc(toolRuns.createdAt)).limit(20);
    return rows.map(r => this.view(r, u.role));
  }
  async get(u: AuthUser, id: string) { return this.view(await this.row(u, id), u.role); }

  private inReview(r: Run) { if (r.state !== 'review') throw badRequest(r.state === 'running' ? 'Still working · wait for it to finish' : 'This run is closed'); }

  async decide(u: AuthUser, id: string, slot: string, body: unknown) {
    const r = await this.row(u, id);
    this.inReview(r);
    const b = (body ?? {}) as { decision?: string; pick?: string };
    if (b.decision !== 'keep' && b.decision !== 'reject') throw badRequest('decision: keep or reject');
    const items = r.items.map(i => ({ ...i }));
    const it = items.find(i => i.slot === slot);
    if (!it) throw notFound('Image');
    if (b.decision === 'reject') { it.decision = 'reject'; it.pick = null; }
    else {
      const pick = (b.pick ?? (it.results.a ? 'a' : it.results.b ? 'b' : null)) as 'a' | 'b' | null;
      if (pick !== 'a' && pick !== 'b') throw badRequest('Nothing to keep for this image');
      if (!it.results[pick]) throw badRequest('That option has no image');
      it.decision = 'keep'; it.pick = pick;
    }
    return this.view(await this.save(r.id, { items }), u.role);
  }
  async pickAll(u: AuthUser, id: string, body: unknown) {
    const r = await this.row(u, id);
    this.inReview(r);
    const pick = (body as any)?.pick;
    if (pick !== 'a' && pick !== 'b') throw badRequest('pick: a or b');
    const items = r.items.map(i => (i.results[pick as 'a' | 'b'] ? { ...i, decision: 'keep' as const, pick: pick as 'a' | 'b' } : { ...i }));
    return this.view(await this.save(r.id, { items }), u.role);
  }

  async retry(u: AuthUser, id: string, slot: string, body: unknown) {
    const r = await this.row(u, id);
    this.inReview(r);
    await this.modelFor(u, r.modelId);
    const eng = ((body as any)?.engine ?? r.engines[0]) as 'a' | 'b';
    if (!r.engines.includes(eng)) throw badRequest('engine: an option this run used');
    const it = r.items.find(i => i.slot === slot);
    if (!it) throw notFound('Image');
    const o = r.options as any;
    const est = r.kind === 'enhance' ? await this.enhancePerImage(u.studioId, o.realism, o.upscale, r.models as StepOverrides)
      : await this.ctx.imageModels.estimate(r.models[stepOf(eng)]!, { outMp: 1, inMp: PHOTO_REF_MP * (slot === 'front' ? 2 : 3) });
    const bill = await new PhotoBill(this.ctx, whoOf(u), `${r.id}_${uid('r')}`, est, `${r.kind === 'enhance' ? 'Enhance' : 'Dress up'} · retry 1 image`).start();
    const items = r.items.map(i => (i.slot === slot ? { ...i, state: 'running' as const, decision: 'pending' as const, pick: null, error: undefined } : { ...i }));
    const saved = await this.save(r.id, { items });
    void (async () => {
      const cur = items.find(i => i.slot === slot)!;
      const front = r.items.find(i => i.slot === 'front')?.results[eng] ?? null;
      try {
        const res = await this.one(r, u, cur, eng, randomImageSeed(), slot === 'front' ? null : front);
        bill.add(res.cost);
        await bill.finish();
        const [now] = await this.ctx.db.select().from(toolRuns).where(eq(toolRuns.id, r.id));
        const next = now!.items.map(i => (i.slot === slot ? { ...i, state: 'done' as const, results: { ...i.results, [eng]: res.image }, cost: i.cost + res.cost, error: undefined } : i));
        await this.save(r.id, { items: next, cost: now!.cost + res.cost });
      } catch (e) {
        const pe = e instanceof PhotoError ? e : await this.ctx.images.photoError(r.studioId, e, 0);
        bill.waste(pe.spentUsd);
        await bill.fail();
        const [now] = await this.ctx.db.select().from(toolRuns).where(eq(toolRuns.id, r.id));
        const next = now!.items.map(i => (i.slot === slot ? { ...i, state: (Object.values(i.results).some(Boolean) ? 'done' : 'failed') as ToolItem['state'], error: pe.message } : i));
        await this.save(r.id, { items: next });
      }
    })().catch(e => this.ctx.log.error({ err: (e as Error).message }, 'retry failed'));
    return this.view(saved, u.role);
  }

  async apply(u: AuthUser, id: string, body: unknown) {
    const r = await this.row(u, id);
    this.inReview(r);
    if (r.items.some(i => i.state === 'running')) throw badRequest('Still working · wait for the retry to finish');
    const m = await this.modelFor(u, r.modelId);
    const kept = new Map<string, ImageRef>();
    for (const i of r.items) if (i.decision === 'keep' && i.pick && i.results[i.pick]) kept.set(i.slot, i.results[i.pick]!);
    if (!kept.size) throw badRequest('Keep at least one image');
    const now = Date.now();
    if (r.kind === 'enhance') {
      const version: SheetVersion = { id: uid('sv'), createdAt: now, reason: 'enhance', slots: m.slots };
      const slots: SheetSlot[] = m.slots.map(s => (kept.has(s.key) ? { ...s, image: kept.get(s.key)!, source: 'generated', busy: false } : s));
      const [mm] = await this.ctx.db.update(models).set({ slots, sheetVersions: [version, ...(m.sheetVersions ?? [])].slice(0, 10) }).where(eq(models.id, m.id)).returning();
      const run = await this.save(r.id, { state: 'applied', appliedAt: now, phase: 'Saved' });
      this.ctx.hub.emit(u.studioId, { type: 'model', model: modelViewOf(mm!) });
      return { run: this.view(run, u.role), model: modelViewOf(mm!) };
    }
    const b = (body ?? {}) as { name?: unknown };
    if (b.name != null && (typeof b.name !== 'string' || b.name.length > 80)) throw badRequest('name: at most 80 characters');
    const name = (typeof b.name === 'string' && b.name.trim()) || ((r.options as any).name as string | null) || 'Dressed look';
    const oid = uid('o');
    const [o] = await this.ctx.db.insert(outfits).values({ id: oid, studioId: u.studioId, modelId: m.id, name, mode: 'dressup', description: '',
      angles: ['front', 'tq', 'side', 'back'].map(k => kept.get(k) ?? null), faces: ['face', 'faceTq', 'profile'].map(k => kept.get(k) ?? null),
      state: 'ready', prompt: dressPrompt('front', false), seed: Number((r.options as any).seed ?? 0) || null, cost: r.cost, createdBy: u.id, createdAt: now }).returning();
    const [mm] = await this.ctx.db.update(models).set({ outfitIds: [...m.outfitIds, oid] }).where(eq(models.id, m.id)).returning();
    const run = await this.save(r.id, { state: 'applied', appliedAt: now, phase: 'Saved', outfitId: oid });
    const ov = outfitViewOf(o!);
    this.ctx.hub.emit(u.studioId, { type: 'outfit', outfit: ov });
    this.ctx.hub.emit(u.studioId, { type: 'model', model: modelViewOf(mm!) });
    return { run: this.view(run, u.role), model: modelViewOf(mm!), outfit: ov };
  }

  async discard(u: AuthUser, id: string) {
    const r = await this.row(u, id);
    if (r.state === 'running') { this.stopping.add(r.id); return; }
    if (r.state === 'review') await this.save(r.id, { state: 'discarded', phase: 'Discarded' });
  }

  // ------------------------------------------------------------------ sheet versions
  async versions(u: AuthUser, modelId: string) {
    const m = await this.modelFor(u, modelId, false);
    return m.sheetVersions ?? [];
  }
  async restore(u: AuthUser, modelId: string, vid: string) {
    const m = await this.modelFor(u, modelId);
    const v = (m.sheetVersions ?? []).find(x => x.id === vid);
    if (!v) throw notFound('Version');
    const cur: SheetVersion = { id: uid('sv'), createdAt: Date.now(), reason: 'restore', slots: m.slots };
    // The version's slots, with any slot added since (faceTq) kept as it is now.
    const slots = m.slots.map(s => v.slots.find(x => x.key === s.key) ?? s).map(s => ({ ...s, busy: false }));
    const [mm] = await this.ctx.db.update(models).set({ slots, sheetVersions: [cur, ...(m.sheetVersions ?? []).filter(x => x.id !== vid)].slice(0, 10) }).where(eq(models.id, m.id)).returning();
    this.ctx.hub.emit(u.studioId, { type: 'model', model: modelViewOf(mm!) });
    return modelViewOf(mm!);
  }
}

// Set by routes (avoids an import cycle): the API views of a model and an outfit.
let modelViewOf: (m: ModelRow) => unknown = m => m;
let outfitViewOf: (o: typeof outfits.$inferSelect) => unknown = o => o;
export function setViews(mv: typeof modelViewOf, ov: typeof outfitViewOf) { modelViewOf = mv; outfitViewOf = ov; }
