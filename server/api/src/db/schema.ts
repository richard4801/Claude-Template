// Postgres schema (Drizzle). Every studio-owned row carries `studioId`; every action records the `userId` that did it.
// Times are epoch milliseconds (bigint as JS number), money is US dollars (double precision, rounded at the edges).
import { sql } from 'drizzle-orm';
import { bigint, boolean, doublePrecision, index, integer, jsonb, pgTable, primaryKey, serial, text, uniqueIndex } from 'drizzle-orm/pg-core';

const ms = (name: string) => bigint(name, { mode: 'number' });
const money = (name: string) => doublePrecision(name);

export type ImageRef = { asset?: string; url?: string };
export type TemplateAfterEffects = { faceMotionBlur?: number; blurAngle?: number; grade?: string; grain?: number };
export type TemplateLayers = { style?: string; scene?: string; camera?: string; light?: string; negative?: string; product?: string; afterEffects?: TemplateAfterEffects };
export const POOL_SLOTS = ['pose', 'bodyAngle', 'framing', 'expression', 'background', 'hands', 'timeOfDay'] as const;
export type PoolSlot = (typeof POOL_SLOTS)[number];
export type VariationPool = Partial<Record<PoolSlot, string[]>>;
export type VariationDraw = Partial<Record<PoolSlot | 'direction', string>>;
export type SheetSlot = { key: string; image: ImageRef | null; source: 'upload' | 'generated'; busy: boolean };

export const studios = pgTable('studios', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  createdAt: ms('created_at').notNull(),
});

export const users = pgTable('users', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull().references(() => studios.id),
  email: text('email').notNull(),
  passwordHash: text('password_hash').notNull(),
  role: text('role').notNull().$type<'owner' | 'member'>(),
  attestAdultRightsOriginalAt: ms('attest_adult_rights_original_at').notNull(),
  attestLabelAiAt: ms('attest_label_ai_at').notNull(),
  inviteId: text('invite_id'),
  createdAt: ms('created_at').notNull(),
  disabledAt: ms('disabled_at'),
  lastActiveAt: ms('last_active_at'),
  /** Per-user caps set by the owner (null = the studio default). */
  capPerJob: money('cap_per_job'),
  capPerDay: money('cap_per_day'),
}, t => [uniqueIndex('users_email_idx').on(sql`lower(${t.email})`)]);

export const sessions = pgTable('sessions', {
  id: text('id').primaryKey(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  studioId: text('studio_id').notNull(),
  /** sha256 of the bearer token. The token itself is never stored. */
  tokenHash: text('token_hash').notNull(),
  createdAt: ms('created_at').notNull(),
  expiresAt: ms('expires_at').notNull(),
  lastUsedAt: ms('last_used_at'),
  revokedAt: ms('revoked_at'),
}, t => [uniqueIndex('sessions_token_idx').on(t.tokenHash)]);

export const invites = pgTable('invites', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull().references(() => studios.id),
  codeHash: text('code_hash').notNull(),
  /** Optional: only this email can use it. */
  email: text('email'),
  role: text('role').notNull().$type<'owner' | 'member'>(),
  createdBy: text('created_by'),
  createdAt: ms('created_at').notNull(),
  expiresAt: ms('expires_at').notNull(),
  usedAt: ms('used_at'),
  usedBy: text('used_by'),
}, t => [uniqueIndex('invites_code_idx').on(t.codeHash)]);

export const studioSettings = pgTable('studio_settings', {
  studioId: text('studio_id').primaryKey().references(() => studios.id),
  imageEngine: jsonb('image_engine').$type<{ provider: string; model: string; url?: string }>(),
  capPerJob: money('cap_per_job'),
  capPerDay: money('cap_per_day'),
  capPerUserDay: money('cap_per_user_day'),
  /** Stand-in for the RunPod credit when BALANCE_MODE=simulated (dev and tests). */
  simBalance: money('sim_balance').notNull().default(0),
  failNext: boolean('fail_next').notNull().default(false),
  /** Most pods at once (null = MAX_GPUS). */
  maxGpus: integer('max_gpus'),
  /** Who pays GPU warm-up and idle time on a user's pod: "user" (default) or "owner". */
  overheadPayer: text('overhead_payer').$type<'user' | 'owner'>(),
  /** Set while new jobs are paused because the RunPod balance is low. */
  lowBalanceSince: ms('low_balance_since'),
  /** Who may switch on "Keep GPU warm": "everyone" (null = default) or "owner". */
  warmGpuAllowed: text('warm_gpu_allowed').$type<'owner' | 'everyone'>(),
  /** Warm GPU auto-off after this many minutes without a render (null = WARM_IDLE_MINUTES). */
  warmIdleMinutes: integer('warm_idle_minutes'),
  /** Warm GPU session cap in minutes (null = WARM_MAX_MINUTES); "Keep warm" extends it once by the same amount. */
  warmMaxMinutes: integer('warm_max_minutes'),
});

export const models = pgTable('models', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  name: text('name').notNull(),
  age: integer('age').notNull(),
  niche: text('niche').notNull(),
  look: text('look').notNull().default(''),
  neverAdd: jsonb('never_add').$type<string[]>().notNull(),
  slots: jsonb('slots').$type<SheetSlot[]>().notNull(),
  outfitIds: jsonb('outfit_ids').$type<string[]>().notNull(),
  personality: text('personality'),
  notes: text('notes'),
  createdBy: text('created_by'),
  createdAt: ms('created_at').notNull(),
}, t => [index('models_studio_idx').on(t.studioId)]);

export const outfits = pgTable('outfits', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  modelId: text('model_id').notNull(),
  name: text('name').notNull(),
  mode: text('mode').notNull(),
  description: text('description').notNull().default(''),
  angles: jsonb('angles').$type<(ImageRef | null)[]>().notNull(),
  state: text('state').notNull(),
  prompt: text('prompt').notNull().default(''),
  seed: integer('seed'),
  createdBy: text('created_by'),
  createdAt: ms('created_at').notNull(),
}, t => [index('outfits_studio_idx').on(t.studioId)]);

/** Every object we store (uploads, generated images, bundled stills copied to storage), with size and hash. */
export const uploads = pgTable('uploads', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  kind: text('kind').notNull().$type<'image' | 'clip' | 'generated' | 'asset' | 'output'>(),
  storageKey: text('storage_key').notNull(),
  contentType: text('content_type').notNull(),
  bytes: bigint('bytes', { mode: 'number' }),
  /** sha256 of the stored bytes, sent to GPU workers so they can verify downloads. */
  sha256: text('sha256'),
  state: text('state').notNull().$type<'pending' | 'ready'>(),
  createdBy: text('created_by'),
  createdAt: ms('created_at').notNull(),
});

export type ClipCheck = { label: string; value: string; status: 'good' | 'bad' | 'info'; fix?: string };
export const clips = pgTable('clips', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  name: text('name').notNull(),
  durationSec: doublePrecision('duration_sec').notNull(),
  width: integer('width').notNull(),
  height: integer('height').notNull(),
  fps: doublePrecision('fps').notNull(),
  meta: jsonb('meta').$type<Record<string, unknown>>().notNull(),
  checks: jsonb('checks').$type<ClipCheck[]>().notNull(),
  storageKey: text('storage_key'),
  createdBy: text('created_by'),
  createdAt: ms('created_at').notNull(),
}, t => [index('clips_studio_idx').on(t.studioId)]);

/**
 * Render jobs (kind "render") and LoRA training runs (kind "lora-train"). The app-facing state is queued|running|done|failed;
 * `gpuState` tracks the worker side: pending (waiting for a worker) → claimed → done|failed.
 */
export const jobs = pgTable('jobs', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id'),
  kind: text('kind').notNull().$type<'render' | 'lora-train'>(),
  title: text('title').notNull(),
  modelId: text('model_id').notNull(),
  modelName: text('model_name').notNull(),
  outfitId: text('outfit_id').notNull().default(''),
  request: jsonb('request').$type<Record<string, any>>().notNull(),
  state: text('state').notNull().$type<'queued' | 'running' | 'done' | 'failed'>(),
  progress: doublePrecision('progress').notNull().default(0),
  take: integer('take').notNull().default(1),
  step: integer('step').notNull().default(0),
  totalSteps: integer('total_steps').notNull().default(0),
  phase: text('phase').notNull().default(''),
  secondsLeft: doublePrecision('seconds_left').notNull().default(0),
  totalSeconds: doublePrecision('total_seconds').notNull().default(0),
  cost: money('cost').notNull(),
  refunded: money('refunded').notNull().default(0),
  /** Tokens held from the requester's wallet while the job runs. */
  holdTokens: bigint('hold_tokens', { mode: 'number' }).notNull().default(0),
  /** GPU warm-up and idle time charged with this job (user-pays mode). */
  warmupCost: money('warmup_cost').notNull().default(0),
  /** Claimed on (or running when its user took) a warm GPU: GPU time inside the warm session is paid by the "Warm GPU" line. */
  warmSessionId: text('warm_session_id'),
  error: text('error'),
  retryable: boolean('retryable'),
  prompt: text('prompt').notNull().default(''),
  seed: integer('seed').notNull(),
  thumb: jsonb('thumb').$type<ImageRef | null>(),
  createdAt: ms('created_at').notNull(),
  startedAt: ms('started_at'),
  finishedAt: ms('finished_at'),
  hiddenAt: ms('hidden_at'),
  /** Why a waiting job isn't starting ("owner_balance_low"), or null. */
  blocked: text('blocked'),
  /** When it joined the GPU queue (charged and waiting). */
  queuedAt: ms('queued_at'),
  gpuState: text('gpu_state').$type<'pending' | 'claimed' | 'done' | 'failed' | 'cancelled'>(),
  podId: text('pod_id'),
  claimedAt: ms('claimed_at'),
  lastProgressAt: ms('last_progress_at'),
  gpuSeconds: doublePrecision('gpu_seconds'),
  actualCost: money('actual_cost'),
  outputs: jsonb('outputs').$type<Record<string, unknown>[]>(),
  /** Worker timing stats from done: {load_s, gen_s, step_times_s, peak_vram_gb, attention}. */
  stats: jsonb('stats').$type<Record<string, unknown>>(),
}, t => [index('jobs_studio_idx').on(t.studioId, t.createdAt), index('jobs_gpu_idx').on(t.gpuState, t.createdAt)]);

export const takes = pgTable('takes', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id'),
  kind: text('kind').notNull().$type<'take' | 'shot'>(),
  jobId: text('job_id'),
  modelId: text('model_id'),
  index: integer('index').notNull(),
  of: integer('of').notNull(),
  title: text('title').notNull(),
  label: text('label').notNull(),
  engineLabel: text('engine_label').notNull().default(''),
  cost: money('cost').notNull(),
  seed: integer('seed').notNull(),
  status: text('status').notNull().$type<'test' | 'final'>(),
  thumb: jsonb('thumb').$type<ImageRef | null>(),
  prompt: text('prompt').notNull().default(''),
  /** Storage key of the rendered video (renders) or still (shots). */
  mediaKey: text('media_key'),
  /** What the GPU really produced: {width, height, fps, durationSec, bytes} (renders are 768×1344). */
  media: jsonb('media').$type<Record<string, unknown>>(),
  /** Photoshoot stills: the layers that made it (template layers, or scene/camera/light of a plain shoot). Never sent to apps. */
  layers: jsonb('layers').$type<TemplateLayers>(),
  /** Template shots: the template, its owner (who alone sees the hidden prompt), the variation options drawn and the draw seed. */
  templateId: text('template_id'),
  templateName: text('template_name'),
  templateOwnerId: text('template_owner_id'),
  variation: jsonb('variation').$type<VariationDraw>(),
  shuffleSeed: integer('shuffle_seed'),
  /** The prompt as non-owners of the template see it ("Template: <name>" plus their own layers). */
  publicPrompt: text('public_prompt'),
  createdAt: ms('created_at').notNull(),
}, t => [index('takes_studio_idx').on(t.studioId, t.createdAt), index('takes_template_idx').on(t.templateId, t.createdAt)]);

/** Every generated image, with the recipe to reproduce it. */
export const generatedImages = pgTable('generated_images', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id'),
  purpose: text('purpose').notNull(),
  refId: text('ref_id'),
  provider: text('provider').notNull(),
  model: text('model').notNull(),
  prompt: text('prompt').notNull(),
  negative: text('negative'),
  seed: bigint('seed', { mode: 'number' }),
  costUsd: money('cost_usd').notNull().default(0),
  image: jsonb('image').$type<ImageRef>().notNull(),
  storageKey: text('storage_key'),
  createdAt: ms('created_at').notNull(),
});

export type LoraCandidate = { id: string; image: ImageRef; label: string; flag?: string; keep: boolean };
export type LoraPart = { state: string; progress: number };
export const loras = pgTable('loras', {
  modelId: text('model_id').primaryKey(),
  studioId: text('studio_id').notNull(),
  version: integer('version').notNull().default(0),
  state: text('state').notNull(),
  use: boolean('use').notNull().default(true),
  candidates: jsonb('candidates').$type<LoraCandidate[]>().notNull(),
  progress: doublePrecision('progress').notNull().default(0),
  photo: jsonb('photo').$type<LoraPart>().notNull(),
  video: jsonb('video').$type<LoraPart>().notNull(),
  cost: money('cost').notNull().default(0),
  trainedOn: integer('trained_on'),
  jobId: text('job_id'),
  /** Storage keys of trained weights per version: [{version, photo, video}] */
  weights: jsonb('weights').$type<{ version: number; photo?: string; video?: string }[]>().notNull().default([]),
});

export const accounts = pgTable('accounts', {
  studioId: text('studio_id').notNull(),
  modelId: text('model_id').notNull(),
  platform: text('platform').notNull(),
  handle: text('handle').notNull(),
  connectedAt: ms('connected_at').notNull(),
  canPostDirect: boolean('can_post_direct').notNull().default(false),
  /** Encrypted platform token (stage 2). Never sent to clients. */
  tokenEnc: text('token_enc'),
  connectedBy: text('connected_by'),
}, t => [primaryKey({ columns: [t.modelId, t.platform] })]);

export const posts = pgTable('posts', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id'),
  modelId: text('model_id').notNull(),
  takeId: text('take_id').notNull(),
  title: text('title').notNull(),
  thumb: jsonb('thumb').$type<ImageRef | null>(),
  platforms: jsonb('platforms').$type<string[]>().notNull(),
  caption: text('caption').notNull().default(''),
  aiLabel: boolean('ai_label').notNull().default(false),
  paidPartnership: boolean('paid_partnership').notNull().default(false),
  when: text('when').notNull(),
  dueAt: ms('due_at').notNull(),
  state: text('state').notNull().$type<'scheduled' | 'handoff' | 'posted' | 'failed'>(),
  createdAt: ms('created_at').notNull(),
  handoffAt: ms('handoff_at'),
  postedAt: ms('posted_at'),
  stats: jsonb('stats').$type<{ views: number; likes: number; comments: number }>(),
}, t => [index('posts_due_idx').on(t.state, t.dueAt)]);

/**
 * Per-user token wallets (1 token = TOKEN_USD, default $0.01). `tokens` is spendable, `held` is reserved for running jobs.
 * Members are funded by the owner. Owners have no stored tokens: an owner's wallet is the RunPod balance minus every
 * member's unspent tokens minus the owners' holds; `held` still tracks the owner's running jobs.
 */
export const wallets = pgTable('wallets', {
  userId: text('user_id').primaryKey(),
  studioId: text('studio_id').notNull(),
  tokens: bigint('tokens', { mode: 'number' }).notNull().default(0),
  held: bigint('held', { mode: 'number' }).notNull().default(0),
  updatedAt: ms('updated_at').notNull(),
});

/**
 * Every token movement and every dollar spent. `userId` is whose wallet moved, `actorId` who caused it.
 * kinds: transfer (owner → member, +) | reclaim (member → owner, −) | hold (−spendable, +held) | release (hold returned on
 * failure) | settle (hold turned into spend at the actual cost; `amountUsd` = the spend) | charge (fixed-price work, spend)
 * | overhead (pod idle/start-up, studio spend with no user) | topup (dev: simulated RunPod credit).
 * "Today" and "this month" are sums of `amountUsd` over settle, charge and overhead rows.
 */
export const ledger = pgTable('ledger', {
  id: serial('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id'),
  actorId: text('actor_id'),
  jobId: text('job_id'),
  kind: text('kind').notNull(),
  tokens: bigint('tokens', { mode: 'number' }).notNull().default(0),
  amountUsd: money('amount_usd').notNull().default(0),
  note: text('note'),
  createdAt: ms('created_at').notNull(),
}, t => [index('ledger_studio_time_idx').on(t.studioId, t.createdAt), index('ledger_user_time_idx').on(t.userId, t.createdAt)]);

/**
 * GPU pods (RunPod, or virtual ones in simulated mode). One pod per user: a user's jobs run FIFO on their own pod.
 * An idle warm pod can be handed to another user (`assignedUserId` changes while idle).
 */
export const pods = pgTable('pods', {
  id: text('id').primaryKey(),
  runpodId: text('runpod_id'),
  simulated: boolean('simulated').notNull().default(false),
  studioId: text('studio_id').notNull(),
  workerTokenHash: text('worker_token_hash').notNull(),
  state: text('state').notNull().$type<'starting' | 'running' | 'stopping' | 'stopped' | 'failed'>(),
  gpuType: text('gpu_type').notNull(),
  assignedUserId: text('assigned_user_id'),
  /** The job that made us start it (its user pays the warm-up). */
  startedForJobId: text('started_for_job_id'),
  currentJobId: text('current_job_id'),
  /** What the worker advertised in its last claim (h3, latentsync, viggle, ...). */
  capabilities: jsonb('capabilities').$type<string[]>(),
  /** Worker-reported state from heartbeats (idle | loading | <phase> | stopping). */
  workerState: text('worker_state'),
  costPerHr: doublePrecision('cost_per_hr').notNull().default(0),
  startedAt: ms('started_at').notNull(),
  readyAt: ms('ready_at'),
  lastHeartbeatAt: ms('last_heartbeat_at'),
  busy: boolean('busy').notNull().default(false),
  /** When it last became idle (no job). Idle time since then is charged to the assigned user. */
  idleSince: ms('idle_since'),
  warmupCharged: boolean('warmup_charged').notNull().default(false),
  stoppedAt: ms('stopped_at'),
  error: text('error'),
  /** Held by a "Keep GPU warm" session: no idle shutdown, no hand-over, no warm-up/idle lines (the session pays). */
  warmSessionId: text('warm_session_id'),
}, t => [index('pods_state_idx').on(t.state)]);

/**
 * "Keep GPU warm" sessions (plans/backend.md): a user holds a dedicated pod and pays its wall time per minute.
 * One active session (state starting | warm | stopping) per user.
 */
export const warmSessions = pgTable('warm_sessions', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id').notNull(),
  podId: text('pod_id'),
  state: text('state').notNull().$type<'starting' | 'warm' | 'stopping' | 'off'>(),
  startedAt: ms('started_at').notNull(),
  readyAt: ms('ready_at'),
  /** The idle clock: when it became ready, the last time a render was seen on it, or the last "Keep warm". */
  lastActiveAt: ms('last_active_at'),
  /** Wall time up to here is charged. */
  settledUntil: ms('settled_until').notNull(),
  costUsd: money('cost_usd').notNull().default(0),
  ratePerHr: money('rate_per_hr').notNull(),
  idleMinutes: integer('idle_minutes').notNull(),
  maxMinutes: integer('max_minutes').notNull(),
  extended: boolean('extended').notNull().default(false),
  /** `<reason>:<autoOffAt>` of the last warning sent, so each one goes out once. */
  warnedFor: text('warned_for'),
  endedAt: ms('ended_at'),
  endReason: text('end_reason'),
}, t => [index('warm_sessions_user_idx').on(t.userId, t.startedAt), index('warm_sessions_state_idx').on(t.state)]);

/**
 * Photo templates (plans/templates.md): a reusable look. `layers` and `variationPool` are hidden from everyone but the owner.
 * Starter-pack templates carry a stable `slug` (unique per studio) so the start-up seed can add missing ones idempotently.
 */
export const templates = pgTable('templates', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  ownerId: text('owner_id').notNull(),
  visibility: text('visibility').notNull().$type<'private' | 'public'>(),
  name: text('name').notNull(),
  tags: jsonb('tags').$type<string[]>().notNull(),
  layers: jsonb('layers').$type<TemplateLayers>().notNull(),
  variationPool: jsonb('variation_pool').$type<VariationPool>().notNull(),
  /** Storage key (R2) of the cover image. */
  coverKey: text('cover_key'),
  createdFromShotId: text('created_from_shot_id'),
  slug: text('slug'),
  uses: integer('uses').notNull().default(0),
  createdAt: ms('created_at').notNull(),
  updatedAt: ms('updated_at').notNull(),
}, t => [index('templates_studio_idx').on(t.studioId, t.updatedAt), uniqueIndex('templates_slug_idx').on(t.studioId, t.slug)]);

export const templateFavourites = pgTable('template_favourites', {
  userId: text('user_id').notNull(),
  templateId: text('template_id').notNull().references(() => templates.id, { onDelete: 'cascade' }),
  createdAt: ms('created_at').notNull(),
}, t => [primaryKey({ columns: [t.userId, t.templateId] })]);
