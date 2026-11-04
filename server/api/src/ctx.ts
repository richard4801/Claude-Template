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
  /** Absolute base URL of this API, for image URLs and presigned local-storage URLs. */
  publicBase: () => string;
  /** Timers that stop on shutdown. */
  timers: Set<NodeJS.Timeout>;
  later: (fn: () => void | Promise<void>, ms: number) => NodeJS.Timeout;
};

/** The signed-in user, attached to each authenticated request. */
export type AuthUser = { id: string; studioId: string; email: string; role: 'owner' | 'member'; studioName: string; sessionId: string | null };
