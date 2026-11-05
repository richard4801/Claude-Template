// Builds the Fastify app and every service. `buildApp` is used by index.ts (production), the test server and vitest.
import Fastify, { type FastifyInstance, type FastifyRequest } from 'fastify';
import multipart from '@fastify/multipart';
import rateLimit from '@fastify/rate-limit';
import { describeConfig, type Config } from './config.js';
import type { AuthUser, Ctx } from './ctx.js';
import { openDb, type DbHandle } from './db/client.js';
import { ApiError } from './errors.js';
import { EventHub } from './events.js';
import { RunpodApi } from './gpu/runpodApi.js';
import { RunpodGpu, SimulatedGpu } from './gpu/pool.js';
import { ImageService } from './images/service.js';
import { Money } from './money/money.js';
import { authenticate, bootstrapOwnerInvite } from './auth/auth.js';
import { JobService } from './services/jobs.js';
import { LoraService } from './services/lora.js';
import { PostScheduler } from './services/posts.js';
import { createStorage } from './storage/index.js';
import { registerRoutes } from './routes/index.js';
import { registerWorkerRoutes } from './routes/worker.js';
import { registerVersionRoutes } from './routes/versions.js';
import { registerEditorAiRoutes } from './routes/editorAi.js'; // Editor v2 (workstream 3)
import { seedDev } from './seed.js';
import { TemplateService } from './templates/service.js';
import { WarmService } from './services/warm.js';
import { schemaState } from './db/client.js';
import { ReplicateClient } from './replicate/client.js';
import { ReplicateVideo } from './services/replicateVideo.js';
import { ImageModels } from './images/steps.js';
import { PromptLibrary } from './prompt/service.js';
import { ToolService } from './services/tools.js';
import { EngineHealth } from './services/engines.js';

declare module 'fastify' {
  interface FastifyRequest { user: AuthUser }
  interface FastifyContextConfig { public?: boolean; owner?: boolean }
}

export type BuildOptions = { db?: DbHandle; fetchFn?: typeof fetch; runpod?: RunpodApi; logger?: boolean; startLoops?: boolean;
  /** Tests: Replicate's backoff without real waiting. */
  replicateTime?: { sleep: (ms: number) => Promise<void>; now: () => number } };
export type App = { app: FastifyInstance; ctx: Ctx; close: () => Promise<void> };

export async function buildApp(config: Config, opts: BuildOptions = {}): Promise<App> {
  const app = Fastify({
    logger: opts.logger === false ? false : {
      level: config.LOG_LEVEL,
      // No secrets in logs: auth headers are redacted and URLs lose their query string (SSE ?token=, presigned signatures).
      redact: { paths: ['req.headers.authorization', 'req.headers.cookie', '*.password', '*.token', '*.inviteCode'], censor: '[redacted]' },
      serializers: {
        req: (r: FastifyRequest) => ({ method: r.method, url: r.url.split('?')[0], ip: r.ip }),
      },
    },
    bodyLimit: 1024 * 1024,
    trustProxy: true,
  });

  const dbh = opts.db ?? await openDb(config.DATABASE_URL, undefined, {
    poolMax: config.DB_POOL_MAX, idleTimeoutMs: config.DB_IDLE_TIMEOUT_MS, connectTimeoutMs: config.DB_CONNECT_TIMEOUT_MS,
    startupRetryMs: config.DB_STARTUP_RETRY_SECONDS * 1000, migrationUrl: config.DATABASE_URL_UNPOOLED, log: app.log,
  });
  const hub = new EventHub();
  hub.onError = e => app.log.warn({ err: (e as Error)?.message }, 'live event failed');
  const timers = new Set<NodeJS.Timeout>();
  let boundPort = config.PORT;
  const publicBase = () => (config.PUBLIC_URL ?? `http://localhost:${boundPort}`).replace(/\/$/, '');
  const ctx = {
    config, db: dbh.db, hub, log: app.log, publicBase, timers,
    storage: createStorage(config, publicBase),
    runpod: opts.runpod ?? new RunpodApi(config.RUNPOD_API_KEY, config.RUNPOD_GRAPHQL_URL, opts.fetchFn),
    later: (fn: () => void | Promise<void>, ms: number) => {
      const t = setTimeout(() => { timers.delete(t); void Promise.resolve().then(fn).catch(e => app.log.error({ err: (e as Error).message }, 'timer failed')); }, ms);
      timers.add(t);
      return t;
    },
  } as Ctx;
  ctx.replicate = new ReplicateClient({ token: config.REPLICATE_API_TOKEN, base: config.REPLICATE_API_URL, fetchFn: opts.fetchFn, log: app.log,
    ...(opts.replicateTime ?? {}) });
  ctx.replicateVideo = new ReplicateVideo(ctx);
  ctx.engines = new EngineHealth(ctx);
  ctx.money = new Money(ctx);
  ctx.imageModels = new ImageModels(ctx, opts.fetchFn);
  ctx.images = new ImageService(ctx, opts.fetchFn);
  ctx.tools = new ToolService(ctx);
  ctx.prompts = new PromptLibrary(ctx);
  ctx.jobs = new JobService(ctx);
  ctx.lora = new LoraService(ctx);
  ctx.posts = new PostScheduler(ctx);
  ctx.templates = new TemplateService(ctx);
  ctx.warm = new WarmService(ctx);
  ctx.boot = { startedAt: Date.now(), build: (process.env.RAILWAY_GIT_COMMIT_SHA ?? process.env.KOYEB_GIT_SHA ?? process.env.GIT_SHA ?? '').slice(0, 12) || null,
    migrations: await schemaState(ctx.db) };
  ctx.gpu = config.GPU_MODE === 'runpod' ? new RunpodGpu(ctx, ctx.runpod) : new SimulatedGpu(ctx);

  app.log.info({ config: describeConfig(config) }, 'MUSE API configuration');
  if (config.NODE_ENV === 'production' && config.storage === 'local' && !config.DEV_MODE) {
    app.log.warn('STORAGE IS LOCAL DISK: uploads and renders are lost on every redeploy. Set the R2_* variables.');
  }
  if (config.DEV_SEED) await seedDev(ctx, { onlyIfEmpty: true });
  await bootstrapOwnerInvite(ctx);
  // Starter templates: add any missing ones to every studio that has an owner (idempotent, keyed by slug).
  try {
    ctx.boot.starters = await ctx.templates.seedAllStarters();
    app.log.info({ ...ctx.boot.starters, migrations: ctx.boot.migrations }, 'starter templates checked');
  } catch (e) {
    ctx.boot.starters = { error: (e as Error).message.slice(0, 200) };
    app.log.error({ err: (e as Error).message }, 'starter templates failed');
  }

  // Empty JSON bodies are fine ({}); bad JSON is a contract error.
  app.removeContentTypeParser('application/json');
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_req, body, done) => {
    const s = (body as string).trim();
    if (!s) return done(null, {});
    try { done(null, JSON.parse(s)); } catch { done(new ApiError(400, 'bad_json', 'Body is not valid JSON'), undefined); }
  });
  await app.register(multipart, { limits: { fileSize: config.DIRECT_UPLOAD_MAX_MB * 1024 * 1024, files: 2, fields: 10, fieldSize: 64 * 1024 } });
  await app.register(rateLimit, {
    global: false,
    errorResponseBuilder: (_req, c) => ({ statusCode: 429, error: `Too many tries · wait ${Math.ceil(c.ttl / 1000)}s`, code: 'rate_limited' }),
  });

  // Auth for everything under /v1 unless the route is public. Owner-only routes say so in their config.
  app.addHook('preHandler', async req => {
    const cfg = req.routeOptions.config;
    if (!req.url.startsWith('/v1/') || cfg?.public) return;
    req.user = await authenticate(ctx, req);
    if (cfg?.owner && req.user.role !== 'owner') throw new ApiError(403, 'owner_only', 'Only the studio owner can do that');
  });

  app.setErrorHandler((err: any, req, reply) => {
    if (err instanceof ApiError) return reply.status(err.status).send({ error: err.message, code: err.code });
    if (err?.name === 'ZodError') return reply.status(400).send({ error: `Invalid request: ${err.issues?.[0]?.path?.join('.') ?? ''} ${err.issues?.[0]?.message ?? ''}`.trim(), code: 'bad_request' });
    if (err?.statusCode === 429) return reply.status(429).send({ error: err.error ?? 'Too many requests', code: 'rate_limited' });
    if (err?.code === 'FST_REQ_FILE_TOO_LARGE' || err?.statusCode === 413) return reply.status(413).send({ error: 'That file is too large · use the presigned upload', code: 'too_large' });
    if (err?.validation || err?.statusCode === 400) return reply.status(400).send({ error: err.message ?? 'Bad request', code: 'bad_request' });
    req.log.error({ err: { message: err?.message, stack: err?.stack } }, 'unhandled error');
    return reply.status(500).send({ error: 'Something went wrong on the server', code: 'server_error' });
  });
  app.setNotFoundHandler((_req, reply) => reply.status(404).send({ error: 'No such endpoint', code: 'not_found' }));

  await registerRoutes(app, ctx);
  await registerWorkerRoutes(app, ctx);
  await registerVersionRoutes(app, ctx);
  await registerEditorAiRoutes(app, ctx); // Editor v2 (workstream 3)

  app.addHook('onListen', async () => {
    const a = app.server.address();
    if (a && typeof a === 'object') boundPort = a.port;
  });
  if (opts.startLoops !== false) {
    ctx.jobs.start();
    ctx.posts.start();
  }

  const close = async () => {
    ctx.jobs.stop();
    ctx.posts.stop();
    for (const t of timers) clearTimeout(t);
    await ctx.replicateVideo.idle();
    await ctx.gpu.shutdown();
    await app.close();
    if (!opts.db) await dbh.close();
  };
  return { app, ctx, close };
}
