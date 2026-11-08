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
  /** Unused since 2026-11-04 (app clean-up): nothing pauses on a provider balance. Kept so old env files still parse. */
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
  /**
   * Upscale (SeedVR2 on the add-on GPU; plans/app-cleanup.md decision 6), measured per size:
   * {"1080p": {"usdPerSec": 0.05, "gpuSecPerSec": 20}, "2k": {…}, "4k": {…}} = dollars and GPU seconds per output second.
   * Empty: Upscale stays "coming soon". A size is offered only when it is priced and the pods can run "upscale".
   */
  UPSCALE_PRICES: z.string().default(''),
  /** Optional static worker token for running a worker by hand (dev). Pods get their own per-pod token. */
  WORKER_TOKEN: str(),
  PRESIGN_TTL_SEC: num(3600),

  // Replicate (plans/backend.md "Replicate"): hosted MiniMax H3 video (Draft / Standard / HD) and photos.
  REPLICATE_API_TOKEN: str(),
  REPLICATE_API_URL: z.string().default('https://api.replicate.com/v1'),
  /** Engine for a job that names none: "replicate" (falls back to "h3" without a token), "h3" or "viggle". */
  VIDEO_ENGINE_DEFAULT: z.enum(['replicate', 'h3', 'viggle']).default('replicate'),
  /** Quality for a replicate job that names none (owner's choice 2026-11-04: Draft). */
  VIDEO_QUALITY_DEFAULT: z.enum(['draft', 'standard', 'hd']).default('draft'),
  REPLICATE_VIDEO_MODEL: z.string().default('minimax/h3'),
  REPLICATE_VIDEO_DRAFT_MODEL: z.string().default('minimax/h3-lite'),
  /** Dollars per output second, per quality. */
  REPLICATE_PRICE_DRAFT: num(0.02),
  REPLICATE_PRICE_STANDARD: num(0.08),
  REPLICATE_PRICE_HD: num(0.13),
  /** Replicate jobs running at once, across the studio (Replicate allows a burst of 1 on a small balance). */
  REPLICATE_MAX_CONCURRENT: num(1),
  REPLICATE_POLL_MS: num(5000),
  /** A video job fails (provider_rate_limited) only after waiting this long on 429s. */
  REPLICATE_MAX_RATE_WAIT_SEC: num(1800),
  /** A photo call gives up on 429s after this long (the charge is refunded). */
  REPLICATE_IMAGE_MAX_WAIT_SEC: num(120),
  REPLICATE_PREDICTION_TIMEOUT_SEC: num(1800),
  /** Presigned R2 GET links handed to Replicate. */
  REPLICATE_INPUT_URL_TTL_SEC: num(7200),
  REPLICATE_IMAGE_MODEL: z.string().default('black-forest-labs/flux-2-pro'),
  REPLICATE_IMAGE_EDIT_MODEL: z.string().default('qwen/qwen-image-edit-2511'),
  /** FLUX.2 [pro] on Replicate: per run, plus per input and per output megapixel. */
  REPLICATE_IMAGE_RUN_USD: num(0.015),
  REPLICATE_IMAGE_MP_USD: num(0.015),
  /** Qwen-Image-Edit 2511: per output image. */
  REPLICATE_IMAGE_EDIT_USD: num(0.03),
  REPLICATE_IMAGE_MAX_REFS: num(6),
  /** Most images one new shot sends (identity references + a shoot's reference images) on the default shot model and other engines. */
  REPLICATE_IMAGE_MAX_INPUTS: num(8),
  /** References are shrunk to fit inside this many pixels per side before they're sent. */
  REPLICATE_IMAGE_REF_MAX_PX: num(1024),
  /** FLUX.2 / Kontext `safety_tolerance` (owner decision 2026-11-05: 5, the most permissive FLUX.2 allows); capped per model by its schema. */
  REPLICATE_IMAGE_SAFETY: num(5),
  /** Photo LoRA hook (later): passed to the edit model as lora_weights when set. */
  REPLICATE_IMAGE_LORA_URL: str(),
  REPLICATE_IMAGE_LORA_SCALE: num(1),
  // Model tools (plans/api.md "Model tools"): default models per image step, the catalog and pricing of any model.
  REPLICATE_REALISM_MODEL: z.string().default('black-forest-labs/flux-krea-dev'),
  REPLICATE_UPSCALE_MODEL: z.string().default('philz1337x/clarity-upscaler'),
  REPLICATE_DRESS_A_MODEL: z.string().default('qwen/qwen-image-edit-2511'),
  REPLICATE_DRESS_B_MODEL: z.string().default('black-forest-labs/flux-2-pro'),
  /** Model pages (prices) live on the website, not the API. */
  REPLICATE_WEB_URL: z.string().default('https://replicate.com'),
  REPLICATE_CATALOG_TTL_SEC: num(43200),
  REPLICATE_SCHEMA_TTL_SEC: num(21600),
  REPLICATE_PRICE_TTL_SEC: num(86400),
  /** Time-billed models without a typical run on their page: estimate this many seconds. */
  REPLICATE_TIME_EST_SEC: num(20),
  /** A model whose price can't be read: estimate (and settle on) this much per image. */
  REPLICATE_UNKNOWN_EST_USD: num(0.05),
  FFMPEG_PATH: z.string().default('ffmpeg'),
  FFPROBE_PATH: z.string().default('ffprobe'),
  /** Recreate this edit reads on-screen words with it (workstream 1); empty = off, the words stay null. */
  TESSERACT_PATH: z.string().default('tesseract'),
  /** Body poses for Recreate this edit (MoveNet in a child process, about 150 MB while it runs); skipped below this much free memory. */
  RECREATE_POSE: bool(true),
  RECREATE_POSE_MIN_FREE_MB: num(200),
  /** References from a link (TikTok, Instagram Reels, YouTube Shorts) through yt-dlp (pinned in the Dockerfile); off = files only. */
  RECREATE_LINKS: bool(true),
  YTDLP_PATH: z.string().default('yt-dlp'),
  RECREATE_LINK_MAX_MB: num(80),

  // Images
  /** Unset: "replicate" when REPLICATE_API_TOKEN is set, else "simulated". */
  IMAGE_PROVIDER: z.enum(['simulated', 'fal', 'custom-http', 'replicate']).optional(),
  IMAGE_MODEL: z.string().default('fal-ai/bytedance/seedream/v4/edit'),
  IMAGE_CUSTOM_URL: str(),
  FAL_KEY: str(),
  FAL_QUEUE_URL: z.string().default('https://queue.fal.run'),
  // Higgsfield API (owner's account): "key-id:key-secret". Unset = Higgsfield models are skipped (Replicate runs them).
  HF_CREDENTIALS: str(),
  HIGGSFIELD_API_URL: z.string().default('https://api.higgsfield.ai'),
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

  // AI suite (workstream 1, plans/ai-suite.md). SUITE_MODE: "off" (no shots), "mock" (the test renderer: no provider
  // calls, no spend) or "live" (Replicate / fal). Unset: "mock" outside production, "off" in production.
  SUITE_MODE: z.enum(['off', 'mock', 'live']).optional(),
  /** Suite shots running at once across the server. */
  SUITE_MAX_CONCURRENT: num(2),
  SUITE_POLL_MS: num(5000),
  SUITE_PREDICTION_TIMEOUT_SEC: num(1800),
  /** The suite's own caps (studio owner can change them in suite settings), on top of the wallet caps. */
  SUITE_CAP_PER_JOB_USD: num(5),
  SUITE_CAP_PER_DAY_USD: num(25),
  /** Mock renders settle to their estimate instead of $0 (dev: to exercise the money path). */
  SUITE_MOCK_CHARGE: bool(false),

  // ---- Workstream 2: camera sessions, "Direct with Claude" chat, MUSE MCP server (plans/mcp-bridge.md)
  /** Claude API key for the in-app Direct with Claude chat. Unset: the chat answers director_unavailable. */
  ANTHROPIC_API_KEY: str(),
  DIRECTOR_MODEL: z.string().default('claude-opus-5-5'),
  DIRECTOR_EFFORT: z.enum(['low', 'medium', 'high', 'xhigh', 'max']).default('high'),
  DIRECTOR_MAX_TOKENS: num(32000),
  /** Most model turns (tool rounds) in one chat message. */
  DIRECTOR_MAX_STEPS: num(24),
  /** Server-side refusal fallbacks ("default" routing) on the chat's requests. */
  DIRECTOR_FALLBACKS: bool(true),
  /** How long a relayed Blender call waits for the owner's Mac. */
  BLENDER_CALL_TIMEOUT_SEC: num(300),
  MCP_ENABLED: bool(true),
});

export type Config = Omit<z.infer<typeof Env>, 'IMAGE_PROVIDER'> & {
  IMAGE_PROVIDER: 'simulated' | 'fal' | 'custom-http' | 'replicate';
  /** The engine used when a job names none (VIDEO_ENGINE_DEFAULT, or h3 when Replicate isn't set up). */
  videoEngineDefault: 'replicate' | 'h3' | 'viggle';
  storage: 'local' | 's3';
  balanceMode: 'runpod' | 'simulated';
  socialMode: 'simulated' | 'stub';
  /** AI suite (workstream 1): SUITE_MODE resolved. */
  suiteMode: 'off' | 'mock' | 'live';
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
  const IMAGE_PROVIDER = c.IMAGE_PROVIDER ?? (c.REPLICATE_API_TOKEN ? 'replicate' : 'simulated');
  const videoEngineDefault = c.VIDEO_ENGINE_DEFAULT === 'replicate' && !c.REPLICATE_API_TOKEN ? 'h3' : c.VIDEO_ENGINE_DEFAULT;
  const suiteMode = c.SUITE_MODE ?? (c.NODE_ENV === 'production' && !c.DEV_MODE ? 'off' : 'mock'); // AI suite (workstream 1)
  return { ...c, IMAGE_PROVIDER, videoEngineDefault, storage, balanceMode, socialMode, suiteMode };
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
    videoEngine: c.videoEngineDefault,
    socials: c.socialMode,
    suite: c.suiteMode,
    secrets: {
      RUNPOD_API_KEY: !!c.RUNPOD_API_KEY,
      FAL_KEY: !!c.FAL_KEY, HF_CREDENTIALS: !!c.HF_CREDENTIALS,
      REPLICATE_API_TOKEN: !!c.REPLICATE_API_TOKEN,
      R2_SECRET_ACCESS_KEY: !!c.R2_SECRET_ACCESS_KEY,
      WORKER_TOKEN: !!c.WORKER_TOKEN,
      OWNER_INVITE_CODE: !!c.OWNER_INVITE_CODE,
      ANTHROPIC_API_KEY: !!c.ANTHROPIC_API_KEY,
    },
  };
}
