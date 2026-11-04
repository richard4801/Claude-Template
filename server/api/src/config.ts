// Environment configuration. Values are validated once at start-up. Secrets are kept in this object only and are
// never logged: `describeConfig()` prints which secrets are present, never their values.
import { z } from 'zod';

const bool = (def: boolean) =>
  z.preprocess(v => (v === undefined || v === '' ? def : ['1', 'true', 'yes', 'on'].includes(String(v).toLowerCase())), z.boolean());
const num = (def: number) => z.preprocess(v => (v === undefined || v === '' ? def : Number(v)), z.number().finite());
const str = () => z.preprocess(v => (v === '' ? undefined : v), z.string().optional());

const Env = z.object({
  NODE_ENV: z.string().default('development'),
  /** Koyeb's default is 8000 (the Dockerfile sets it); 8787 for `npm run dev`. */
  PORT: num(8787),
  HOST: z.string().default('0.0.0.0'),
  /** Public base URL of this API (https://muse-api-<org>.koyeb.app). Used for absolute image URLs and the worker's API_URL. */
  PUBLIC_URL: str(),
  LOG_LEVEL: z.string().default('info'),

  /** postgres://… (Neon: the pooled string, with sslmode=require; Railway sets this itself). Unset or "pglite://memory" = embedded in-memory Postgres (dev and tests only). */
  DATABASE_URL: str(),
  /** Optional direct (non-pooled) Neon URL used only for start-up migrations. The pooled DATABASE_URL works too. */
  DATABASE_URL_UNPOOLED: str(),
  /** Pool size. Keep it small (≤ 5): Neon's free tier and a 512 MB instance both prefer few connections. */
  DB_POOL_MAX: num(5),
  /** Close idle connections after this long so a serverless database (Neon) can suspend. */
  DB_IDLE_TIMEOUT_MS: num(10_000),
  /** One connection attempt's timeout; a sleeping Neon compute takes a few seconds to wake. */
  DB_CONNECT_TIMEOUT_MS: num(15_000),
  /** How long start-up keeps retrying the database (asleep, waking, briefly unreachable) before giving up. */
  DB_STARTUP_RETRY_SECONDS: num(90),
  /**
   * With nothing queued, no pod running and no post due, the background loops look at the database only this often
   * (instead of every DISPATCH_MS / SCHEDULER_MS), so Neon can suspend and the free compute hours last. Everything
   * that creates work in this process wakes the loops at once, so this is only a safety net. 0 = always poll.
   */
  IDLE_POLL_SECONDS: num(600),

  // Dev mode: seed data, /v1/dev/* endpoints, sign-up without an invite. Never turn on in production.
  DEV_MODE: bool(false),
  DEV_SEED: bool(false),
  DEV_OWNER_EMAIL: z.string().default('jen@studio.com'),
  DEV_OWNER_PASSWORD: z.string().default('x'),

  // Storage: "local" (disk, dev) or "s3" (Cloudflare R2 or MinIO).
  STORAGE: z.enum(['local', 's3']).optional(),
  UPLOAD_DIR: z.string().default('./data/uploads'),
  R2_ACCOUNT_ID: str(),
  R2_ACCESS_KEY_ID: str(),
  R2_SECRET_ACCESS_KEY: str(),
  R2_BUCKET: str(),
  /** Override the S3 endpoint (MinIO: http://localhost:9000). Defaults to https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com. */
  S3_ENDPOINT: str(),
  S3_REGION: z.string().default('auto'),
  S3_FORCE_PATH_STYLE: bool(false),
  DIRECT_UPLOAD_MAX_MB: num(50),

  // Money
  BALANCE_MODE: z.enum(['runpod', 'simulated']).optional(),
  SIM_START_BALANCE: num(6.07),
  CAP_PER_JOB_USD: num(5),
  CAP_PER_DAY_USD: num(15),
  CAP_PER_USER_DAY_USD: num(10),
  /** Dollars per wallet token. */
  TOKEN_USD: num(0.01),
  BALANCE_CACHE_SEC: num(30),

  // GPU
  GPU_MODE: z.enum(['simulated', 'runpod']).default('simulated'),
  /** Simulated renders run this many times faster than real time (the mock's SPEED). */
  SPEED: num(24),
  /** Simulated image generation time (ms), like the mock's GEN_MS. */
  GEN_MS: num(1600),
  RUNPOD_API_KEY: str(),
  RUNPOD_GRAPHQL_URL: z.string().default('https://api.runpod.io/graphql'),
  RUNPOD_NETWORK_VOLUME_ID: str(),
  RUNPOD_DATACENTER_ID: str(),
  RUNPOD_IMAGE: z.string().default('runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04'),
  RUNPOD_CONTAINER_DISK_GB: num(40),
  RUNPOD_START_CMD: str(),
  /** Lowest host driver CUDA version a pod may get (the worker venv is torch cu130). Empty: any. */
  RUNPOD_MIN_CUDA: z.string().default('13.0'),
  GPU_HOURLY_USD: num(3.99),
  /** Stop a pod this long after its last job. */
  IDLE_SHUTDOWN_SECONDS: num(180),
  /** Keep GPU warm: auto-off after this many minutes without a render, and the session cap (owner can change both). */
  WARM_IDLE_MINUTES: num(20),
  WARM_MAX_MINUTES: num(120),
  /** The warning goes out this long before an idle or cap auto-off. */
  WARM_WARNING_MINUTES: num(5),
  /** Warm GPU turns off when the user's credit can't cover this many more minutes. */
  WARM_MIN_CREDIT_MINUTES: num(10),
  /** Most pods at once (the owner can change it in settings). */
  MAX_GPUS: num(3),
  /**
   * Which GPU each job kind needs, best first, as JSON. A pod only takes jobs its GPU type is listed for.
   * H3 fits in 80 GB; Viggle peaked at 90.7 GB in testing, so it needs an H200.
   */
  GPU_TABLE: z.string().default(JSON.stringify({
    h3: ['NVIDIA H100 80GB HBM3', 'NVIDIA H100 NVL', 'NVIDIA H100 PCIe', 'NVIDIA H200 NVL', 'NVIDIA H200'],
    viggle: ['NVIDIA H200 NVL', 'NVIDIA H200'],
    'lora-train': ['NVIDIA H100 80GB HBM3', 'NVIDIA H100 NVL', 'NVIDIA H200 NVL', 'NVIDIA H200'],
  })),
  /** Pause new jobs when the RunPod balance minus the queued work drops below this. */
  RUNPOD_MIN_BALANCE_USD: num(2),
  DISPATCH_MS: num(250),
  WORKER_HEARTBEAT_TIMEOUT_SEC: num(60),
  POD_BOOT_TIMEOUT_SEC: num(900),
  /**
   * What the pod image's worker can do (it advertises the same list on claim). Jobs that need anything else are refused
   * at submit time in runpod mode instead of starting a GPU that would refuse them. Lip sync is an h3 post-pass and
   * needs "latentsync". Add "viggle" once an H200 image exists, "lora-train" once training is wired.
   */
  RUNPOD_WORKER_CAPABILITIES: z.string().default('h3,latentsync'),
  /** Optional static worker token for running a worker by hand (dev). Pods get their own per-pod token. */
  WORKER_TOKEN: str(),
  PRESIGN_TTL_SEC: num(3600),

  // Images
  IMAGE_PROVIDER: z.enum(['simulated', 'fal', 'custom-http']).default('simulated'),
  IMAGE_MODEL: z.string().default('fal-ai/bytedance/seedream/v4/edit'),
  IMAGE_CUSTOM_URL: str(),
  FAL_KEY: str(),
  FAL_QUEUE_URL: z.string().default('https://queue.fal.run'),
  FAL_COST_PER_IMAGE: num(0.03),
  IMAGE_TIMEOUT_SEC: num(180),

  // Socials: "simulated" marks handed-off posts posted with made-up stats (dev only). "stub" leaves them at handoff.
  SOCIAL_MODE: z.enum(['simulated', 'stub']).optional(),
  SCHEDULER_MS: num(1000),

  /**
   * First owner without a terminal: pick a code (12+ characters), set it here, sign up with it in the app, then delete
   * the variable. Only works while the studio has no owner.
   */
  OWNER_INVITE_CODE: str(),
  OWNER_EMAIL: str(),
  STUDIO_NAME: z.string().default('MUSE Studio'),
  AUTH_RATE_PER_MIN: num(10),
  SESSION_DAYS: num(90),
  MIN_PASSWORD: num(8),
});

export type Config = z.infer<typeof Env> & {
  storage: 'local' | 's3';
  balanceMode: 'runpod' | 'simulated';
  socialMode: 'simulated' | 'stub';
};

export function loadConfig(env: Record<string, string | undefined> = process.env): Config {
  const r = Env.safeParse(env);
  if (!r.success) {
    // Only the variable names and the problem, never the values.
    const msg = r.error.issues.map(i => `${i.path.join('.')}: ${i.message}`).join('; ');
    throw new Error(`Bad configuration: ${msg}`);
  }
  const c = r.data;
  // In production an unset DATABASE_URL would silently run on the embedded in-memory database and lose everything on the
  // next restart. Refuse to start instead (dev mode may still use it).
  if (c.NODE_ENV === 'production' && !c.DEV_MODE && (!c.DATABASE_URL || c.DATABASE_URL === 'pglite://memory')) {
    throw new Error('Bad configuration: DATABASE_URL is required in production (the Neon pooled connection string)');
  }
  const storage = c.STORAGE ?? (c.R2_BUCKET ? 's3' : 'local');
  const balanceMode = c.BALANCE_MODE ?? (c.GPU_MODE === 'simulated' && c.DEV_MODE ? 'simulated' : 'runpod');
  const socialMode = c.SOCIAL_MODE ?? (c.DEV_MODE ? 'simulated' : 'stub');
  return { ...c, storage, balanceMode, socialMode };
}

/** Safe summary for the start-up log: modes and which secrets are set (true/false), never their values. */
export function describeConfig(c: Config) {
  return {
    env: c.NODE_ENV,
    devMode: c.DEV_MODE,
    database: !c.DATABASE_URL || c.DATABASE_URL.startsWith('pglite') ? 'embedded' : 'postgres',
    storage: c.storage,
    gpu: c.GPU_MODE,
    balance: c.balanceMode,
    imageProvider: c.IMAGE_PROVIDER,
    socials: c.socialMode,
    secrets: {
      RUNPOD_API_KEY: !!c.RUNPOD_API_KEY,
      FAL_KEY: !!c.FAL_KEY,
      R2_SECRET_ACCESS_KEY: !!c.R2_SECRET_ACCESS_KEY,
      WORKER_TOKEN: !!c.WORKER_TOKEN,
      OWNER_INVITE_CODE: !!c.OWNER_INVITE_CODE,
    },
  };
}
