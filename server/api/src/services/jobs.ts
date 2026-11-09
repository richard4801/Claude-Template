// Jobs: render requests from the apps and LoRA training runs, from request to takes.
//
// Life of a job: POST /v1/jobs → hold the estimate from the requester's wallet (caps + balance checked first) →
// GPU queue (state "running", gpuState "pending") → a GPU slot claims it (fair round-robin between users) →
// progress → done (takes created, hold settled to the actual cost) or failed (hold released in full).
// `queue: true` parks a job as "queued" (nothing held) until POST /v1/queue/run.
import { and, desc, eq, inArray, isNull, sql } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { clips, jobs, loras, models, outfits, takes, type ImageRef } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { whoOf } from '../money/money.js';
import * as P from '../pricing.js';
import { loraToken } from '../prompt/engine.js';
import { replicateSwap, videoSwap } from '../prompt/scripts/builders.js';
import { resolveSpeaking } from '../audio/service.js';
import { gpuCanRun, type JobRow } from '../gpu/controller.js';
import { pods } from '../db/schema.js';
import { shotPromptFor } from '../templates/service.js';
import { OUT_OF_CREDIT as OUT_OF_CREDIT_MESSAGE } from '../images/service.js';
import { draftOf } from '../suite/drafts.js';
import { applySwapEngine, modelChoice, type Choice } from '../engines/service.js'; // WS13: model choice everywhere

export const JobRequestSchema = z.object({
  title: z.string().max(200).optional(),
  modelId: z.string(),
  outfitId: z.string().optional().default(''),
  clipId: z.string().optional().default(''),
  /** Absent: the server's default engine (VIDEO_ENGINE_DEFAULT). */
  engine: z.enum(['replicate', 'h3', 'viggle']).nullish().transform(v => v ?? undefined),
  /** Absent or null: VIDEO_QUALITY_DEFAULT (draft). */
  quality: z.enum(['draft', 'standard', 'hd']).nullish().transform(v => v ?? undefined),
  steps: z.number().int().optional().default(P.STEPS_DEFAULT),
  use: z.enum(['first', 'full']).optional().default('first'),
  takes: z.number().int().optional().default(1),
  keepAudio: z.boolean().optional().default(true),
  lipSync: z.boolean().optional().default(false),
  background: z.enum(['keep', 'photo']).optional().default('keep'),
  backgroundMotion: z.enum(['still', 'subtle', 'busy']).optional().default('subtle'),
  clipSeconds: z.number().positive().max(600).nullable().optional(),
  queue: z.boolean().optional(),
  seed: z.number().int().optional(),
  direction: z.string().max(500).optional(),
  /** Prompt scripts: the studio's "Performer is speaking" switch. Absent: the clip's detection. */
  speaking: z.boolean().nullish(),
  /**
   * Edit with `background: "photo"` (workstream 1, Recreate's "Use your own setting"): the new background, sent as the
   * last reference image labelled "background" (the model's own references then stop at 5).
   */
  backgroundImage: z.object({ asset: z.string().max(500).optional(), url: z.string().max(2000).optional() }).strict().optional(),
}).passthrough();

const MOTION_WORDS: Record<string, string> = { still: 'still', subtle: 'subtly alive', busy: 'busy' };
const mins = (s: number) => s >= 60 ? `~${Math.ceil(s / 60)} min` : `~${Math.ceil(s)}s`;
/** Member-facing phases and messages (plans/api.md "App clean-up" §1): no GPU, steps, start-up or provider names. */
export const WAITING_PHASE = 'Waiting to start';
export const SOMETHING_WENT_WRONG = "Something went wrong · you weren't charged";
/** "Waiting to start" (first in line) or "#2 in line", plus " · starts in ~3 min" when known. */
export const linePhase = (position: number, startsIn: number) =>
  `${position > 1 ? `#${position} in line` : WAITING_PHASE}${startsIn > 0 ? ` · starts in ${mins(startsIn)}` : ''}`;

type QueueInfo = { queuePosition: number; etaSeconds: number; startsInSeconds: number };

const isRep = (j: { request: Record<string, any> }) => j.request?.engine === 'replicate';
// AI suite (workstream 1): suite shots run on their own line (suite/runner.ts), never on a pod.
const isSuite = (j: { request: Record<string, any> }) => j.request?.engine === 'suite';
const isHosted = (j: { request: Record<string, any> }) => isRep(j) || isSuite(j);

export class JobService {
  private queueInfo = new Map<string, QueueInfo>();
  /** The Replicate line (kept apart: the GPU queue pass prunes queueInfo to the jobs it saw). */
  private lineInfo = new Map<string, QueueInfo>();
  private loop: NodeJS.Timeout | null = null;
  private ticking = false;
  private current: Promise<void> | null = null;
  /** Nothing waiting and no pod up after the last pass: poll only every IDLE_POLL_SECONDS (lets Neon sleep). */
  private quiet = false;
  private lastPassAt = 0;
  constructor(private ctx: Ctx) {}

  // ------------------------------------------------------------------ views
  view(j: JobRow, takesOut?: unknown[]) {
    const q = j.state === 'running' && j.gpuState === 'pending' ? this.queueInfo.get(j.id) ?? this.lineInfo.get(j.id) : undefined;
    return compact({
      id: j.id, title: j.title, modelId: j.modelId, modelName: j.modelName, outfitId: j.outfitId, request: j.request, state: j.state,
      progress: j.progress, take: j.take, step: j.step, totalSteps: j.totalSteps, phase: j.phase, secondsLeft: q ? q.etaSeconds : j.secondsLeft,
      totalSeconds: j.totalSeconds, cost: j.cost, refunded: j.refunded, error: j.error, createdAt: j.createdAt, finishedAt: j.finishedAt,
      prompt: j.prompt, seed: j.seed, thumb: j.thumb ?? undefined, queuePosition: q?.queuePosition, etaSeconds: q?.etaSeconds,
      blocked: j.blocked, userId: j.userId, warmupCost: j.warmupCost || undefined, warm: j.warmSessionId ? true : undefined,
      engineLabel: j.kind === 'render' ? (isSuite(j) ? j.request.engineLabel : P.engineLabel(j.request)) : undefined, errorCode: (j.stats as any)?.errorCode,
      billedSeconds: j.state === 'done' ? (j.stats as any)?.replicate?.billedSeconds ?? (j.stats as any)?.suite?.billedSeconds : undefined,
      draft: j.draft ?? undefined, // AI suite (workstream 1): the composer draft, for "Reuse settings"
    });
  }
  emitJob(j: JobRow, extra: Record<string, unknown> = {}) {
    if (j.kind !== 'render' || j.hiddenAt) return;
    this.ctx.hub.emit(j.studioId, { type: 'job', job: this.view(j), ...extra });
  }

  async list(studioId: string) {
    const rows = await this.ctx.db.select().from(jobs)
      .where(and(eq(jobs.studioId, studioId), eq(jobs.kind, 'render'), isNull(jobs.hiddenAt))).orderBy(desc(jobs.createdAt));
    return rows.map(r => this.view(r));
  }
  async get(id: string) { return (await this.ctx.db.select().from(jobs).where(eq(jobs.id, id)))[0] ?? null; }

  // ------------------------------------------------------------------ create
  /** `opts.swapChoice`: a swap engine the caller (the Suite, Recreate) already chose and checked; undefined = choose here. */
  async create(user: AuthUser, body: unknown, opts: { swapChoice?: Choice | null } = {}) {
    const parsed = JobRequestSchema.safeParse(body);
    if (!parsed.success) throw badRequest(`Invalid job: ${parsed.error.issues[0]?.path.join('.')} ${parsed.error.issues[0]?.message}`);
    const draft = draftOf(body); // AI suite (workstream 1): the composer's draft, for "Reuse settings"
    const { engineModel: requested, ...data } = parsed.data as typeof parsed.data & { engineModel?: unknown };
    if (requested !== undefined && (typeof requested !== 'string' || requested.length > 40)) throw badRequest('engineModel: a model id');
    // WS13: the swap engine (`engineModel`, owner only; else the studio's Swap default for the hosted swap).
    const r = { ...data, engine: parsed.data.engine ?? this.ctx.config.videoEngineDefault };
    await applySwapEngine(modelChoice(this.ctx), user, r as Record<string, any>, requested as string | undefined, opts.swapChoice);
    const [archived] = await this.ctx.db.select({ at: models.archivedAt }).from(models).where(and(eq(models.id, r.modelId), eq(models.studioId, user.studioId)));
    if (archived?.at) throw new ApiError(409, 'model_archived', 'This model is archived · restore her in Settings → Archived models');
    r.takes = Math.min(P.TAKES_MAX, Math.max(1, r.takes));
    const replicate = r.engine === 'replicate';
    if (replicate) {
      if (!this.ctx.replicate.configured) throw new ApiError(400, 'engine_unavailable', "Draft, Standard and HD aren't available right now · try Edit");
      if (r.lipSync) throw badRequest('Lip sync is only on Edit');
      if (r.background === 'photo') throw badRequest('A new background photo is only on Edit for now');
      if (!(await this.ctx.replicateVideo.toolsReady())) throw new ApiError(400, 'engine_unavailable', "Draft, Standard and HD aren't available right now · try Edit");
      r.use = 'full';
      r.quality = r.quality ?? this.ctx.config.VIDEO_QUALITY_DEFAULT;
      const swapEngine = (r as Record<string, any>).swapEngine as string | undefined;
      (r as P.RenderReq).pricePerSec = swapEngine ? (await modelChoice(this.ctx).swapQuote(user.studioId, swapEngine, r.quality, null)).perSec : this.qualityPrice(r.quality);
    } else delete r.quality;
    const [clip] = r.clipId ? await this.ctx.db.select().from(clips).where(and(eq(clips.id, r.clipId), eq(clips.studioId, user.studioId))) : [];
    // Clip checks are advice only (owner decision): a clip that fails them can still be rendered; the apps show a
    // disclaimer. Over 15 s, only the first 15 s are used (the engines' limit).
    if (r.engine === 'h3' && (r.steps < P.STEPS_MIN || r.steps > P.STEPS_MAX)) throw badRequest('Steps must be 4–30');
    if (replicate && !clip?.storageKey) throw badRequest('Upload the clip file first');
    if (!replicate && this.ctx.gpu.mode === 'runpod' && !clip?.storageKey) throw badRequest('Upload the clip file first');
    if (r.clipSeconds == null && clip) r.clipSeconds = clip.durationSec;
    const [m] = await this.ctx.db.select().from(models).where(and(eq(models.id, r.modelId), eq(models.studioId, user.studioId)));
    if (!m) throw notFound('Model');
    if (m.archivedAt) throw new ApiError(409, 'model_archived', 'This model is archived · restore her in Settings → Archived models');
    const [o] = r.outfitId ? await this.ctx.db.select().from(outfits).where(and(eq(outfits.id, r.outfitId), eq(outfits.studioId, user.studioId))) : [];
    const cost = P.totalCost(r);
    const [l] = await this.ctx.db.select().from(loras).where(eq(loras.modelId, m.id));
    const lora = l && l.version > 0 && l.use ? loraToken(m.name, l.version) : null;
    const seed = r.seed ?? 1000 + Math.floor(Math.random() * 99000);
    if (!replicate && this.ctx.gpu.mode === 'runpod') this.requireCapabilities(r.engine === 'viggle' ? 'viggle' : 'h3', r.lipSync);
    // GPU: references in the order the H3 setup was tested with (≤ 6): face front, face profile, then the outfit set's
    // front, ¾ and back if it has them, otherwise the body slots. Replicate: the five locked shots, then the outfit (≤ 9).
    // <Image n> in the prompt follows this order.
    const references = replicate ? replicateReferencesFor(m, o) : referencesFor(m, o);
    if (!replicate && r.background === 'photo' && r.backgroundImage && (r.backgroundImage.asset || r.backgroundImage.url))
      references.splice(5, references.length, { label: 'background', image: r.backgroundImage });
    const texts = await this.ctx.prompts.texts(user.studioId);
    // Lip-sync fix: speaking decides the prompt's mouth wording and whether the model hears the clip's audio.
    const sp = await resolveSpeaking(this.ctx, clip, r.speaking);
    (r as Record<string, unknown>).speaking = sp.speaking;
    (r as Record<string, unknown>).speakingSource = sp.source;
    const prompt = replicate ? replicateSwap({ speaking: sp.speaking,
      identity: { name: m.name, look: m.look || `${m.age}-year-old woman`, neverAdd: m.neverAdd },
      outfit: o ? { name: o.name, description: o.description, source: o.mode === 'describe' && !o.angles.some(Boolean) ? 'described' : 'reference-set' } : null,
      referenceLabels: references.map(x => x.label), direction: r.direction,
    }, texts).text : videoSwap({ speaking: sp.speaking,
      identity: { name: m.name, look: m.look || `${m.age}-year-old woman`, referenceCount: Math.max(1, references.length), neverAdd: m.neverAdd, lora },
      referenceLabels: references.length ? references.map(x => x.label) : undefined,
      outfit: { name: o?.name ?? 'outfit' }, keepAudio: r.keepAudio, keepBackground: r.background === 'keep',
      backgroundMotion: MOTION_WORDS[r.backgroundMotion], steps: r.steps, seed, direction: r.direction,
    }, texts).text;
    const { queue, draft: _draft, ...request } = r as typeof r & { draft?: unknown }; // the draft is stored on its own (jobs.draft)
    const p0 = P.progressAt(request, 0);
    const row: typeof jobs.$inferInsert = {
      id: uid('j'), studioId: user.studioId, userId: user.id, kind: 'render', title: r.title ?? 'Untitled', modelId: m.id, modelName: m.name,
      outfitId: r.outfitId ?? '', request: { ...request, ...(queue ? { queue } : {}), ...(lora ? { lora } : {}), references }, state: 'queued', ...p0, phase: 'Queued',
      totalSeconds: P.totalSeconds(request), cost, refunded: 0, prompt, seed, thumb: o?.angles?.[0] ?? m.slots[0]?.image ?? null, createdAt: Date.now(),
      ...(draft ? { draft } : {}),
    };
    if (queue) {
      const [ins] = await this.ctx.db.insert(jobs).values(row).returning();
      this.emitJob(ins!);
      return this.view(ins!);
    }
    return this.view(await this.startNew(user, row));
  }

  /** $ per output second for a Replicate quality (config). */
  qualityPrice(q: string) {
    const c = this.ctx.config;
    return q === 'draft' ? c.REPLICATE_PRICE_DRAFT : q === 'hd' ? c.REPLICATE_PRICE_HD : c.REPLICATE_PRICE_STANDARD;
  }
  private holdNote(row: { kind?: string; request?: Record<string, any> }) {
    if (row.kind === 'render' && row.request && isSuite(row as any)) return `Video · ${row.request.engineLabel} · ${row.request.seconds} s${(row.request.takes ?? 1) > 1 ? ` · ${row.request.takes} takes` : ''} · hold`;
    return row.kind === 'render' && row.request && isRep(row as any) ? `${P.videoNote(row.request, [P.replicateSeconds(row.request.clipSeconds)])}${(row.request.takes ?? 1) > 1 ? ` · ${row.request.takes} takes` : ''} · hold` : undefined;
  }

  /** Holds the price, then puts the job in the GPU queue. Nothing is written if the hold is refused. */
  private async startNew(user: AuthUser, row: typeof jobs.$inferInsert) {
    const hold = await this.ctx.money.hold(whoOf(user), row.id!, row.cost!, { perJob: row.kind === 'render', note: this.holdNote(row) });
    try {
      const [ins] = await this.ctx.db.insert(jobs).values({ ...row, ...this.pendingFields(hold) }).returning();
      this.emitJob(ins!);
      this.kick();
      return ins!;
    } catch (e) {
      await this.ctx.money.release(user.studioId, user.id, row.id!, hold, 'could not queue');
      throw e;
    }
  }
  private pendingFields(hold: number) {
    const now = Date.now();
    return { state: 'running' as const, gpuState: 'pending' as const, holdTokens: hold, queuedAt: now, startedAt: now, phase: WAITING_PHASE };
  }

  /** Starts a job that is already in the database (queued → running, or a LoRA training row). */
  async startExisting(user: AuthUser, j: JobRow) {
    const hold = await this.ctx.money.hold(whoOf(user), j.id, j.cost, { perJob: j.kind === 'render', note: this.holdNote(j) });
    const [u] = await this.ctx.db.update(jobs).set(this.pendingFields(hold)).where(eq(jobs.id, j.id)).returning();
    this.emitJob(u!);
    this.kick();
    return u!;
  }

  /** Internal jobs (LoRA training): held from the user's wallet, never shown in GET /v1/jobs. */
  async createInternal(user: AuthUser, row: Omit<typeof jobs.$inferInsert, 'id' | 'studioId' | 'userId' | 'state' | 'createdAt'>) {
    return this.startNew(user, { ...row, id: uid('jl'), studioId: user.studioId, userId: user.id, state: 'queued', createdAt: Date.now() });
  }

  async runQueue(user: AuthUser) {
    const queued = await this.ctx.db.select().from(jobs)
      .where(and(eq(jobs.studioId, user.studioId), eq(jobs.state, 'queued'), eq(jobs.kind, 'render'), isNull(jobs.hiddenAt))).orderBy(jobs.createdAt);
    const started: JobRow[] = [];
    let firstError: unknown = null;
    for (const j of queued) {
      try { started.push(await this.startExisting(user, j)); } catch (e) { firstError = e; break; } // the rest stay queued
    }
    if (queued.length && !started.length && firstError) throw firstError;
    return started.map(j => this.view(j));
  }

  async remove(user: AuthUser, id: string) {
    const j = await this.get(id);
    if (!j || j.studioId !== user.studioId || j.hiddenAt) throw notFound('Job');
    await this.ctx.db.update(jobs).set({ hiddenAt: Date.now() }).where(eq(jobs.id, id));
    if (j.state === 'running') await this.cancel(j, 'Removed');
  }

  /** Stops a running job and returns its hold. */
  async cancel(j: JobRow, why: string) {
    const [u] = await this.ctx.db.update(jobs).set({ state: 'failed', gpuState: 'cancelled', error: why, refunded: j.cost, finishedAt: Date.now(), phase: why })
      .where(and(eq(jobs.id, j.id), eq(jobs.state, 'running'))).returning();
    if (!u) return;
    if (isRep(j)) this.ctx.replicateVideo.cancel(j.id); else if (isSuite(j)) this.ctx.suite.runner.cancel(j.id); else await this.ctx.gpu.cancel(j.id);
    if (u.userId) await this.ctx.money.release(u.studioId, u.userId, u.id, u.holdTokens, why);
    this.queueInfo.delete(j.id); this.lineInfo.delete(j.id);
  }

  /** Capabilities of the pod image (runpod mode) or everything (simulated). */
  capabilities(): string[] {
    if (this.ctx.gpu.mode === 'simulated') return ['h3', 'viggle', 'latentsync', 'lora-train', 'upscale'];
    return this.ctx.config.RUNPOD_WORKER_CAPABILITIES.split(',').map(x => x.trim()).filter(Boolean);
  }
  /** What the apps can offer right now. Replace-audio isn't wired on the GPU yet (keepAudio:false gives a silent take). */
  features() {
    const caps = this.capabilities();
    const replicate = this.ctx.replicate.configured;
    // Render (Draft / Standard / HD) and the add-ons (Edit, Fast · beta, Upscale): plans/api.md "App clean-up" §2.
    const options = P.QUALITY_IDS.map(q => ({ id: q, label: P.QUALITY_INFO[q].label, detail: P.QUALITY_INFO[q].detail, engine: 'replicate', quality: q,
      resolution: P.QUALITY_INFO[q].resolution, pricePerSec: this.qualityPrice(q), available: replicate }));
    const addons = [
      { id: 'edit', label: P.EDIT.label, detail: P.EDIT.detail, available: caps.includes('h3'), sends: { engine: 'h3', use: 'full', steps: P.STEPS_DEFAULT } },
      { id: 'fast', label: P.FAST.label, detail: P.FAST.detail, available: caps.includes('viggle'), sends: { engine: 'viggle', use: 'full' } },
      // Upscale: offered per size once it is priced (UPSCALE_PRICES, measured) and the pods can run it. `price` = $/output second.
      ...(() => {
        const prices = P.upscalePrices(this.ctx.config.UPSCALE_PRICES), can = caps.includes('upscale');
        const sizes = P.UPSCALE_SIZES.map(z => ({ ...z, available: can && !!prices[z.id], price: can ? prices[z.id]?.usdPerSec ?? null : null }));
        const on = sizes.some(z => z.available);
        return [{ id: 'upscale', label: P.UPSCALE.label, detail: P.UPSCALE.detail, available: on, ...(on ? {} : { comingSoon: true }), sizes }];
      })(),
    ];
    const video = { defaultEngine: this.ctx.config.videoEngineDefault === 'viggle' ? 'h3' : this.ctx.config.videoEngineDefault, defaultQuality: this.ctx.config.VIDEO_QUALITY_DEFAULT,
      minSeconds: P.REPLICATE_MIN_SEC, maxSeconds: P.REPLICATE_MAX_SEC, options, addons };
    return { standard: caps.includes('h3'), fastBeta: caps.includes('viggle'), lipSync: caps.includes('latentsync'), loraTraining: caps.includes('lora-train'),
      replaceAudio: false, outputSize: { width: 768, height: 1344 }, maxClipSec: P.MAX_CLIP_SEC, replicate, video };
  }
  /** Refuse before any GPU starts when the pod image can't run this. */
  requireCapabilities(kind: 'h3' | 'viggle' | 'lora-train', lipSync = false) {
    const caps = this.capabilities();
    if (kind === 'viggle' && !caps.includes('viggle')) throw new ApiError(400, 'engine_unavailable', "Fast · beta isn't available yet · use Draft, Standard or HD");
    if (kind === 'lora-train' && !caps.includes('lora-train')) throw new ApiError(400, 'engine_unavailable', "LoRA training isn't available yet");
    if (kind === 'h3' && !caps.includes('h3')) throw new ApiError(400, 'engine_unavailable', "Edit isn't available right now");
    if (lipSync && !caps.includes('latentsync')) throw new ApiError(400, 'engine_unavailable', "Lip sync isn't available yet · turn it off to render");
  }

  // ------------------------------------------------------------------ GPU side
  private async waitingJobs(studioId?: string) {
    const conds = [eq(jobs.state, 'running'), eq(jobs.gpuState, 'pending')];
    if (studioId) conds.push(eq(jobs.studioId, studioId));
    return (await this.ctx.db.select().from(jobs).where(and(...conds))).sort(fifo);
  }

  /** The next job for a pod: its assigned user's oldest waiting job that its GPU can run (FIFO per user). */
  /**
   * `caps`: what the worker advertised. A job needs its kind ("h3", "viggle", "lora-train") and, for lip sync, "latentsync".
   * `anyUser`: a manual dev worker (static WORKER_TOKEN) may take anyone's job.
   */
  async claimFor(pod: { id: string; assignedUserId: string | null; gpuType: string }, caps?: string[], anyUser = false): Promise<JobRow | null> {
    if (!pod.assignedUserId && !anyUser) return null;
    const can = (j: JobRow) => !caps || (caps.includes(this.workerKind(j)) && (!j.request.lipSync || caps.includes('latentsync')));
    const mine = (await this.waitingJobs()).filter(j => !isHosted(j) && (anyUser || j.userId === pod.assignedUserId) && !j.blocked
      && (anyUser || gpuCanRun(this.ctx.config, pod.gpuType, this.workerKind(j))) && can(j));
    for (const j of mine) {
      const c = await this.claim(j.id, pod.id);
      if (c) return c;
    }
    return null;
  }
  async claim(jobId: string, podId: string) {
    const now = Date.now();
    const [u] = await this.ctx.db.update(jobs).set({ gpuState: 'claimed', podId, claimedAt: now, lastProgressAt: now })
      .where(and(eq(jobs.id, jobId), eq(jobs.gpuState, 'pending'), eq(jobs.state, 'running'), isNull(jobs.blocked))).returning();
    if (!u) return null;
    this.queueInfo.delete(u.id);
    this.lineInfo.delete(u.id);
    const p = isSuite(u) ? { progress: 0, phase: 'Starting' } : u.kind === 'render' ? P.progressAt(u.request, 0) : { phase: 'Getting ready' };
    const [v] = await this.ctx.db.update(jobs).set({ ...p, blocked: null }).where(eq(jobs.id, u.id)).returning();
    this.emitJob(v!);
    if (v!.kind === 'lora-train') await this.ctx.lora.onProgress(v!, 0);
    return v!;
  }
  workerKind(j: JobRow): 'h3' | 'viggle' | 'lora-train' | 'upscale' { return j.kind === 'lora-train' ? 'lora-train' : j.request.engine === 'viggle' ? 'viggle' : j.request.engine === 'upscale' ? 'upscale' : 'h3'; }

  /** Progress for a claimed job. Returns false if the job is no longer running (deleted or failed): the GPU should stop. */
  async progress(jobId: string, fields: { progress: number; take?: number; step?: number; totalSteps?: number; phase?: string; secondsLeft?: number }) {
    const [u] = await this.ctx.db.update(jobs).set({ ...fields, lastProgressAt: Date.now() })
      .where(and(eq(jobs.id, jobId), eq(jobs.state, 'running'), eq(jobs.gpuState, 'claimed'))).returning();
    if (!u) return false;
    if (u.kind === 'lora-train') await this.ctx.lora.onProgress(u, fields.progress);
    else this.emitJob(u);
    return true;
  }

  /** Finished: create takes, settle the hold to the actual cost. */
  async complete(jobId: string, o: { outputs?: Record<string, unknown>[]; gpuSeconds?: number; costPerHr?: number; simulated?: boolean; stats?: Record<string, unknown> | null;
    /** Hosted engines: the exact cost (Replicate: price × billed seconds) and the ledger line. */
    actualCostUsd?: number; settleNote?: string }) {
    const now = Date.now();
    const j = await this.get(jobId);
    if (!j || j.state !== 'running') return null;
    const full = o.actualCostUsd != null ? o.actualCostUsd : o.simulated || o.gpuSeconds == null ? j.cost : o.gpuSeconds / 3600 * (o.costPerHr ?? this.ctx.config.GPU_HOURLY_USD);
    // On a warm GPU the "Warm GPU" line already pays the pod's time: only the part after the session ended is charged.
    const actual = await this.ctx.warm.uncoveredCost(j, full, now);
    const outputs = mergeOutputs(j.outputs ?? [], o.outputs ?? []);
    const [u] = await this.ctx.db.update(jobs).set({
      state: 'done', gpuState: 'done', progress: 100, step: j.totalSteps, take: j.kind === 'render' ? (j.request.takes ?? 1) : 1, phase: 'Done', secondsLeft: 0,
      finishedAt: now, gpuSeconds: o.gpuSeconds ?? null, actualCost: actual, outputs, stats: o.stats ?? null,
    }).where(and(eq(jobs.id, jobId), eq(jobs.state, 'running'))).returning();
    if (!u) return null;
    if (u.userId) await this.ctx.money.settle(u.studioId, u.userId, u.id, u.holdTokens, actual, o.settleNote);
    if (u.kind === 'lora-train') { await this.ctx.lora.onDone(u); this.kick(); return u; }
    const n = u.request.takes ?? 1;
    const [o2] = u.outfitId ? await this.ctx.db.select().from(outfits).where(eq(outfits.id, u.outfitId)) : [];
    const angles = (o2?.angles ?? []).filter(Boolean) as ImageRef[];
    const rows = Array.from({ length: n }, (_, i) => ({
      id: `t_${u.id}_${i + 1}`, studioId: u.studioId, userId: u.userId, kind: 'take' as const, jobId: u.id, modelId: u.modelId, index: i + 1, of: n, title: u.title,
      label: isSuite(u) ? u.request.takeLabel ?? u.request.engineLabel : P.takeLabel(u.request), engineLabel: isSuite(u) ? u.request.engineLabel : P.engineLabel(u.request), cost: (o.actualCostUsd ?? u.cost) / n, seed: u.seed + i, status: 'test' as const,
      thumb: (outputs.find(x => x.name === `take_${i + 1}.mp4`)?.thumb as ImageRef | undefined) ?? (angles.length ? angles[i % angles.length]! : u.thumb), prompt: u.prompt,
      mediaKey: (outputs.find(x => x.name === `take_${i + 1}.mp4`)?.key as string | undefined) ?? null,
      // AI suite (workstream 1): a suite take keeps the Look it is graded with (the Edit suite opens with it applied).
      media: withLook(mediaOf(outputs.find(x => x.name === `take_${i + 1}.mp4`)), isSuite(u) ? (u.request as { look?: unknown }).look : null), createdAt: now,
      draft: u.draft ?? null, // AI suite (workstream 1): "Reuse settings" from the take
    }));
    const inserted = await this.ctx.db.insert(takes).values(rows).returning();
    this.emitJob(u, { takes: inserted.map(t => takeView(t, this.ctx.config.PUBLIC_URL)) });
    if (u.kind === 'render' && !u.hiddenAt) for (const t of inserted) void this.ctx.hub.emit(t.studioId, v => ({ type: 'take', take: takeView(t, this.ctx.config.PUBLIC_URL, v.userId) }));
    this.kick();
    return u;
  }

  /** Failed: the hold goes back in full; the apps get a failed job event and then a balance event. */
  async fail(jobId: string, error: string, retryable = false, errorCode?: string) {
    const j = await this.get(jobId);
    if (!j || j.state !== 'running') return null;
    const [u] = await this.ctx.db.update(jobs).set({
      state: 'failed', gpuState: 'failed', error, retryable, refunded: j.cost, finishedAt: Date.now(), phase: 'Failed',
      ...(errorCode ? { stats: { ...((j.stats as object | null) ?? {}), errorCode } } : {}),
    }).where(and(eq(jobs.id, jobId), eq(jobs.state, 'running'))).returning();
    if (!u) return null;
    this.queueInfo.delete(u.id); this.lineInfo.delete(u.id);
    if (u.kind === 'lora-train') await this.ctx.lora.onFailed(u);
    else this.emitJob(u);
    if (u.userId) await this.ctx.money.release(u.studioId, u.userId, u.id, u.holdTokens, `failed: ${error}`);
    this.kick();
    return u;
  }

  // ------------------------------------------------------------------ dispatcher
  start() {
    if (this.loop) return;
    this.loop = setInterval(() => { if (!this.current && this.due()) void this.tick(); }, this.ctx.config.DISPATCH_MS);
    this.loop.unref?.();
  }
  stop() { if (this.loop) clearInterval(this.loop); this.loop = null; }
  /** Run a tick soon (after a job is queued or a GPU frees up). */
  kick() { this.quiet = false; setImmediate(() => { if (!this.current) void this.tick(); }); }
  /** Whether the timer should run a pass now. Every code path that creates GPU work calls kick(), so when quiet the
   * slow poll is only a safety net. */
  private due() {
    const idleMs = this.ctx.config.IDLE_POLL_SECONDS * 1000;
    return !this.quiet || !idleMs || Date.now() - this.lastPassAt >= idleMs;
  }

  /** One dispatcher pass. If a pass is running, waits for it and runs another (so callers see a fresh pass). */
  async tick(now?: number): Promise<void> {
    while (this.current) await this.current.catch(() => {});
    this.current = this.pass(now ?? Date.now());
    try { await this.current; } finally { this.current = null; }
  }

  private async pass(now: number) {
    this.ticking = true;
    try {
      const all = await this.waitingJobs();
      // Replicate jobs have their own line (services/replicateVideo.ts), never on a pod.
      const waiting = all.filter(j => !isHosted(j));
      await this.ctx.replicateVideo.dispatch(all.filter(isRep));
      await this.ctx.suite.runner.dispatch(all.filter(isSuite));
      // Nothing pauses on a provider balance any more (2026-11-04): clear any job an older build paused.
      for (const j of waiting) {
        if (j.blocked) {
          const [u] = await this.ctx.db.update(jobs).set({ blocked: null, phase: WAITING_PHASE }).where(eq(jobs.id, j.id)).returning();
          if (u) { Object.assign(j, u); this.emitJob(u); }
        }
      }
      await this.updateQueueInfo(waiting);
      await this.ctx.gpu.dispatch(waiting.filter(j => !j.blocked), now);
      await this.ctx.gpu.tick(now);
      await this.ctx.warm.tick(now);
      const pool = this.ctx.gpu as { activePods?: () => Promise<unknown[]> };
      const wasQuiet = this.quiet;
      this.quiet = all.length === 0 && !this.ctx.replicateVideo.busy() && !this.ctx.suite.runner.busy() && (pool.activePods ? (await pool.activePods()).length === 0 : false);
      if (this.quiet !== wasQuiet) this.ctx.log.debug({ quiet: this.quiet }, this.quiet ? 'dispatcher idle: slow polling' : 'dispatcher busy');
    } catch (e) {
      this.quiet = false;
      this.ctx.log.error({ err: (e as Error).message }, 'dispatcher tick failed');
    } finally {
      this.lastPassAt = Date.now();
      this.ticking = false;
    }
  }

  /** An add-on engine (RunPod) refused to start a pod for lack of credit: fail that user's waiting add-on jobs (refunded). */
  async failForCredit(studioId: string, userId: string | null, kind: string) {
    const waiting = (await this.waitingJobs(studioId)).filter(j => !isHosted(j) && j.userId === userId && this.workerKind(j) === kind);
    for (const j of waiting) await this.fail(j.id, OUT_OF_CREDIT_MESSAGE, true, 'provider_out_of_credit');
    return waiting.length;
  }

  /** The Replicate line's position for a waiting job (services/replicateVideo.ts); a job event goes out when it moves. */
  async setLinePosition(j: JobRow, position: number, startsIn: number) {
    const info = { queuePosition: position, startsInSeconds: startsIn, etaSeconds: startsIn + (j.totalSeconds || 0) };
    const prev = this.lineInfo.get(j.id);
    this.lineInfo.set(j.id, info);
    if (prev && prev.queuePosition === position) return;
    const phase = linePhase(position, startsIn);
    const [u] = await this.ctx.db.update(jobs).set({ phase, blocked: null }).where(and(eq(jobs.id, j.id), eq(jobs.gpuState, 'pending'))).returning();
    if (u) this.emitJob(u);
  }

  /**
   * Queue position and ETA for each waiting job. A user with a pod waits only for their own earlier jobs; a user without
   * one (over MAX_GPUS) waits for the next pod to free up. A job event goes out when a job's position changes.
   */
  private async updateQueueInfo(waiting: JobRow[]) {
    const active = await this.ctx.db.select().from(pods).where(inArray(pods.state, ['starting', 'running']));
    const running = await this.ctx.db.select({ id: jobs.id, secondsLeft: jobs.secondsLeft }).from(jobs).where(and(eq(jobs.state, 'running'), eq(jobs.gpuState, 'claimed')));
    const left = new Map(running.map(r => [r.id, r.secondsLeft]));
    const podLeft = (p: typeof active[number]) => (p.currentJobId ? left.get(p.currentJobId) ?? 0 : 0);
    const soonestFree = active.length ? Math.min(...active.map(podLeft)) : 0;
    const perUser = new Map<string, number>(); // seconds of the user's own work ahead
    const podless: string[] = [];              // users waiting for a pod, in order of their oldest job
    const seen = new Set<string>();
    for (const j of waiting) {
      seen.add(j.id);
      const u = j.userId ?? '';
      const pod = active.find(p => p.assignedUserId === u && gpuCanRun(this.ctx.config, p.gpuType, this.workerKind(j)));
      if (!pod && !podless.includes(u)) podless.push(u);
      const base = pod ? podLeft(pod) + (pod.state === 'starting' ? 60 : 0) : soonestFree;
      const ownAhead = perUser.get(u) ?? 0;
      const ownIndex = waiting.filter(w => w.userId === j.userId && fifo(w, j) < 0).length;
      const position = pod ? ownIndex + 1 : podless.indexOf(u) + 1 + ownIndex;
      const startsIn = base + ownAhead;
      perUser.set(u, ownAhead + j.totalSeconds);
      const info = { queuePosition: position, startsInSeconds: startsIn, etaSeconds: startsIn + j.totalSeconds };
      const prev = this.queueInfo.get(j.id);
      this.queueInfo.set(j.id, info);
      if (!prev || prev.queuePosition !== position) {
        if (!j.blocked) {
          const phase = linePhase(position, startsIn);
          const [u2] = await this.ctx.db.update(jobs).set({ phase }).where(and(eq(jobs.id, j.id), eq(jobs.gpuState, 'pending'))).returning();
          if (u2) this.emitJob(u2);
        } else this.emitJob(j);
      }
    }
    for (const id of this.queueInfo.keys()) if (!seen.has(id)) this.queueInfo.delete(id);
  }
}

const fifo = (a: JobRow, b: JobRow) => (a.queuedAt ?? a.createdAt) - (b.queuedAt ?? b.createdAt) || a.createdAt - b.createdAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

/** References for a render (≤ 6, in the tested order). */
export function referencesFor(m: typeof models.$inferSelect, o?: typeof outfits.$inferSelect) {
  const slot = (k: string) => m.slots.find(s => s.key === k && s.image && !s.busy)?.image ?? null;
  const out: { label: string; image: ImageRef }[] = [];
  const push = (label: string, image: ImageRef | null | undefined) => { if (image && out.length < 6) out.push({ label, image }); };
  // A Dress up outfit carries its own face close-ups (with its accessories): they go in place of the model's.
  const faces = o?.faces ?? [];
  push('face, front', faces[0] ?? slot('face'));
  push('face, profile', faces[2] ?? slot('profile'));
  const angles = o?.angles ?? [];
  const outfitRefs = [[0, 'outfit, front'], [1, 'outfit, ¾'], [3, 'outfit, back']].filter(([i]) => angles[i as number]) as [number, string][];
  if (outfitRefs.length) for (const [i, l] of outfitRefs) push(l, angles[i]);
  else { push('body, front', slot('front')); push('body, ¾', slot('tq')); push('body, back', slot('back')); }
  return out;
}

/** References for a Replicate render (≤ 9, fixed order): the model's locked shots, then the outfit set's angles. */
export function replicateReferencesFor(m: typeof models.$inferSelect, o?: typeof outfits.$inferSelect) {
  const slot = (k: string) => m.slots.find(s => s.key === k && s.image && !s.busy)?.image ?? null;
  const out: { label: string; image: ImageRef }[] = [];
  const push = (label: string, image: ImageRef | null | undefined) => { if (image && out.length < 9) out.push({ label, image }); };
  const faces = o?.faces ?? [];
  const angles = o?.angles ?? [];
  if (faces.some(Boolean)) {
    // A Dress up outfit: its own face close-ups (accessories), then its body angles (the model's own body shots wear other clothes).
    push('face, front', faces[0] ?? slot('face'));
    push('face, profile', faces[2] ?? slot('profile'));
    push('face, ¾', faces[1]);
  } else {
    push('face, front', slot('face'));
    push('face, profile', slot('profile'));
    push('body, front', slot('front'));
    push('body, ¾', slot('tq'));
    push('body, back', slot('back'));
  }
  push('outfit, front', angles[0]); push('outfit, ¾', angles[1]); push('outfit, back', angles[3]); push('outfit, side', angles[2]);
  return out;
}

/** AI suite (workstream 1): `media.look` = the suite take's Look {id, kind, label, lut} (absent when grading was off). */
function withLook(m: Record<string, unknown> | null, look: unknown) {
  return look && typeof look === 'object' ? { ...(m ?? {}), look } : m;
}

function mediaOf(o?: Record<string, unknown>) {
  if (!o) return null;
  const m: Record<string, unknown> = {};
  for (const k of ['width', 'height', 'fps', 'durationSec', 'bytes', 'sha256', 'contentType']) if (o[k] != null) m[k] = o[k];
  return Object.keys(m).length ? m : null;
}

function mergeOutputs(planned: Record<string, unknown>[], reported: Record<string, unknown>[]) {
  const out = planned.map(p => ({ ...p }));
  for (const r of reported) {
    const i = out.findIndex(p => p.name === r.name);
    if (i >= 0) out[i] = { ...out[i], ...r, key: out[i]!.key }; else out.push({ ...r });
  }
  return out;
}

/** A take as one viewer may see it. Template shots show their full prompt and draws only to the template's owner. */
export function takeView(t: typeof takes.$inferSelect, publicUrl?: string, viewerId?: string) {
  const shown = shotPromptFor(t, viewerId ?? '');
  return compact({
    id: t.id, kind: t.kind, jobId: t.jobId, index: t.index, of: t.of, title: t.title, label: t.label, engineLabel: t.engineLabel, cost: t.cost,
    seed: t.seed, status: t.status, thumb: t.thumb ?? undefined, prompt: shown.prompt, createdAt: t.createdAt,
    templateId: t.templateId, templateName: t.templateName, shuffleSeed: t.shuffleSeed, variation: shown.variation, refs: t.refs?.length ? t.refs : undefined,
    videoUrl: (t.kind === 'take' || (t.kind as string) === 'edit') && t.mediaKey ? `${publicUrl ?? ''}/uploads/${t.mediaKey}` : undefined,
    durationSec: t.media?.durationSec, width: t.media?.width, height: t.media?.height,
    look: t.kind === 'take' ? t.media?.look : undefined, // AI suite (workstream 1): a suite take's Look
    draft: t.draft ?? undefined, // AI suite (workstream 1): the composer draft it was made with ("Reuse settings")
    // Edited versions (plans/api.md "Video editor"): the source take and the edit list live in `media`.
    ...((t.kind as string) === 'edit' ? { parentTakeId: t.media?.parentTakeId, edits: t.media?.edits, fps: t.media?.fps, ...(t.media?.name ? { name: t.media.name } : {}), ...(t.media?.aiLabel ? { aiLabel: true } : {}) /* Edit suite (workstream 3) */ } : {}),
  }) as Record<string, unknown> & { jobId?: string | null };
}
