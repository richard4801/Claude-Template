// Shared dependencies, built once in app.ts and passed to every service and route.
import type { FastifyBaseLogger } from 'fastify';
import type { Config } from './config.js';
import type { Db } from './db/client.js';
import type { EventHub } from './events.js';
import type { Storage } from './storage/index.js';
import type { Money } from './money/money.js';
import type { ImageService } from './images/service.js';
import type { JobService } from './services/jobs.js';
import type { GpuController } from './gpu/controller.js';
import type { LoraService } from './services/lora.js';
import type { PostScheduler } from './services/posts.js';
import type { RunpodApi } from './gpu/runpodApi.js';
import type { TemplateService } from './templates/service.js';
import type { WarmService } from './services/warm.js';
import type { ReplicateClient } from './replicate/client.js';
import type { ReplicateVideo } from './services/replicateVideo.js';
import type { EngineHealth } from './services/engines.js';
import type { ImageModels } from './images/steps.js';
import type { ToolService } from './services/tools.js';
import type { PromptLibrary } from './prompt/service.js';
import type { SuiteService } from './suite/service.js';

export type Ctx = {
  config: Config;
  db: Db;
  hub: EventHub;
  storage: Storage;
  log: FastifyBaseLogger;
  runpod: RunpodApi;
  money: Money;
  images: ImageService;
  jobs: JobService;
  gpu: GpuController;
  lora: LoraService;
  posts: PostScheduler;
  templates: TemplateService;
  warm: WarmService;
  /** Replicate's HTTP API (video and photos share its rate-limit gate). */
  replicate: ReplicateClient;
  replicateVideo: ReplicateVideo;
  /** Engine status and out-of-credit notices for owner Settings → Engines. */
  engines: EngineHealth;
  /** The model per image step and Replicate's catalog (plans/api.md "Model tools" §2). */
  imageModels: ImageModels;
  /** Enhance and Dress up (plans/api.md "Model tools" §4–6). */
  tools: ToolService;
  /** The studio's prompt library (plans/api.md "Shoot references and the prompt library" §3). */
  prompts: PromptLibrary;
  /** AI suite (workstream 1): video model registry, Shot API, Camera compiler, the suite line (plans/ai-suite.md). */
  suite: SuiteService;
  /** Start-up facts for /health: the build, when it started, the schema migrations applied, the starter seed. */
  boot: { startedAt: number; build: string | null; migrations: { applied: number; latest: string | null }; starters?: { studios: number; added: number } | { error: string } };
  /** Absolute base URL of this API, for image URLs and presigned local-storage URLs. */
  publicBase: () => string;
  /** Timers that stop on shutdown. */
  timers: Set<NodeJS.Timeout>;
  later: (fn: () => void | Promise<void>, ms: number) => NodeJS.Timeout;
};

/** The signed-in user, attached to each authenticated request. */
export type AuthUser = { id: string; studioId: string; email: string; role: 'owner' | 'member'; studioName: string; sessionId: string | null };
