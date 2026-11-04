// Postgres over the network, tuned for a serverless database that sleeps (Neon's free tier suspends the compute after
// ~5 idle minutes and wakes it on the next connection, which takes a moment and can fail the first try):
//   - the connection string is normalised (TLS verified, channel binding honoured) and never logged
//   - a small pool (≤ 5) whose idle connections close after 10 s, so nothing holds the database awake
//   - connecting retries transient errors with backoff (the database waking up, a dropped TCP connection)
//   - migrations run in ONE transaction under a transaction-scoped advisory lock: safe with two instances starting
//     at once and through a transaction-mode pooler (Neon's "-pooler" host), where session locks don't work
import pg from 'pg';
import { readMigrationFiles } from 'drizzle-orm/migrator';

export type PgOptions = {
  /** Most connections at once. Neon's free tier and a 512 MB instance both want this small. */
  poolMax?: number;
  /** Close a connection after this long unused, so the database can go to sleep. */
  idleTimeoutMs?: number;
  /** Give up on one connection attempt after this long (a waking Neon compute takes a few seconds). */
  connectTimeoutMs?: number;
  /** Keep retrying the first connection for this long at start-up. */
  startupRetryMs?: number;
  /**
   * Optional direct (non-pooled) URL for migrations, Neon's DATABASE_URL_UNPOOLED. Not required: the migration runs as
   * one transaction under a transaction-scoped lock, which also works through Neon's transaction-mode pooler.
   */
  migrationUrl?: string;
  log?: { info: (o: object, m?: string) => void; warn: (o: object, m?: string) => void; error: (o: object, m?: string) => void };
};

// ---------------------------------------------------------------------------------------------------- connection string
/**
 * pg-specific clean-up of a libpq-style URL, so the pasted Neon string just works:
 *  - `sslmode=require|prefer|verify-ca` → `verify-full`. node-postgres already treats them as verify-full today (with a
 *    deprecation warning), and v9 will weaken them to "encrypt but don't check the certificate". Neon's certificates are
 *    publicly trusted, so full verification works and stays the behaviour.
 *  - a `*.neon.tech` host without sslmode gets `sslmode=verify-full` (Neon refuses plain connections anyway).
 *  - `channel_binding=require` (in Neon's default strings) → pg's `enableChannelBinding`; the parameter is removed.
 *  - `sslmode=disable` (a local Postgres) is left alone.
 */
export function normalizePgUrl(raw: string): { connectionString: string; enableChannelBinding: boolean; ssl: boolean } {
  const u = new URL(raw);
  const q = u.searchParams;
  const libpqCompat = q.get('uselibpqcompat') === 'true';
  const mode = q.get('sslmode');
  if (!libpqCompat && (mode === 'require' || mode === 'prefer' || mode === 'verify-ca')) q.set('sslmode', 'verify-full');
  if (!mode && /\.neon\.tech$/i.test(u.hostname)) q.set('sslmode', 'verify-full');
  const cb = q.get('channel_binding');
  q.delete('channel_binding');
  const final = q.get('sslmode');
  return { connectionString: u.toString(), enableChannelBinding: cb === 'require', ssl: !!final && final !== 'disable' };
}

/** Host and database only, for logs. */
export function describePgUrl(raw: string) {
  try {
    const u = new URL(raw);
    return { host: u.hostname, database: u.pathname.replace(/^\//, ''), pooled: /-pooler\./.test(u.hostname), sslmode: u.searchParams.get('sslmode') ?? 'none' };
  } catch { return { host: 'unparseable' }; }
}

// ---------------------------------------------------------------------------------------------------- retry
const TRANSIENT_CODES = new Set([
  'ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'EPIPE', 'EHOSTUNREACH', 'ENETUNREACH', 'EAI_AGAIN', 'ENOTFOUND', 'ECONNABORTED',
  '57P01', // admin_shutdown: the compute was suspended under us
  '57P02', // crash_shutdown
  '57P03', // cannot_connect_now: starting up
  '53300', // too_many_connections
  '08000', '08001', '08003', '08004', '08006', // connection exceptions
  'XX000', // Neon proxy "internal error" while waking a compute (only retried when the message says so, below)
]);
const TRANSIENT_MESSAGES = [
  /connection terminated/i, /timeout exceeded when trying to connect/i, /connection timeout/i, /server closed the connection/i,
  /couldn'?t connect to compute node/i, /compute (node )?is (starting|waking)/i, /endpoint .* (is )?(not ready|starting)/i,
  /the database system is starting up/i, /too many connections/i, /socket hang up/i, /read ECONNRESET/i,
];

/** Errors worth another try: the database is asleep, waking or briefly unreachable. Not: bad password, bad SQL. */
export function isTransientDbError(err: unknown): boolean {
  const e = err as { code?: string; message?: string } | undefined;
  if (!e) return false;
  const msg = String(e.message ?? '');
  if (e.code === 'XX000') return TRANSIENT_MESSAGES.some(r => r.test(msg));
  if (e.code && TRANSIENT_CODES.has(e.code)) return true;
  if (e.code === '28P01' || e.code === '28000' || e.code === '3D000') return false; // auth, unknown database
  return TRANSIENT_MESSAGES.some(r => r.test(msg));
}

export type RetryOptions = {
  /** Total time budget (ms), counting waits. At least `attempts` tries are made either way. */
  budgetMs?: number;
  attempts?: number;
  baseMs?: number;
  maxMs?: number;
  isRetryable?: (e: unknown) => boolean;
  onRetry?: (e: unknown, attempt: number, waitMs: number) => void;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
};

/** Runs `fn`, retrying transient failures with exponential backoff (and jitter) until the budget is spent. */
export async function withRetry<T>(fn: () => Promise<T>, o: RetryOptions = {}): Promise<T> {
  const { budgetMs = 0, attempts = 3, baseMs = 250, maxMs = 5000, isRetryable = isTransientDbError } = o;
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>(r => setTimeout(r, ms)));
  const now = o.now ?? Date.now;
  const t0 = now();
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (e) {
      const wait = Math.min(maxMs, baseMs * 2 ** (attempt - 1)) * (0.75 + Math.random() * 0.5);
      const withinBudget = attempt < attempts || now() - t0 + wait <= budgetMs;
      if (!isRetryable(e) || !withinBudget) throw e;
      o.onRetry?.(e, attempt, Math.round(wait));
      await sleep(wait);
    }
  }
}

// ---------------------------------------------------------------------------------------------------- pool
type Log = NonNullable<PgOptions['log']>;
const quiet: Log = { info() {}, warn() {}, error() {} };

/** Health without waking the database: when a query last worked, and the last connection error. */
export const dbStatus = { lastOkAt: 0, lastErrorAt: 0, lastError: '' };

/**
 * A pg Pool whose connect() retries transient errors. Safe: no query has been sent when connect fails, so nothing runs
 * twice. Queries that fail after connecting are not retried (they might not be idempotent).
 */
class WakingPool extends pg.Pool {
  constructor(cfg: pg.PoolConfig, private retry: RetryOptions) { super(cfg); }
  connect(): Promise<pg.PoolClient>;
  connect(cb: (err: Error | undefined, client: pg.PoolClient | undefined, done: (release?: any) => void) => void): void;
  connect(cb?: any): any {
    const p = withRetry(() => super.connect(), this.retry).then(
      c => { dbStatus.lastOkAt = Date.now(); return c; },
      e => { dbStatus.lastErrorAt = Date.now(); dbStatus.lastError = String((e as Error).message).slice(0, 200); throw e; },
    );
    if (!cb) return p;
    p.then(c => cb(undefined, c, (r?: any) => c.release(r)), e => cb(e, undefined, () => {}));
  }
}

export function createPool(url: string, o: PgOptions = {}) {
  const log = o.log ?? quiet;
  const n = normalizePgUrl(url);
  const pool = new WakingPool({
    connectionString: n.connectionString,
    enableChannelBinding: n.enableChannelBinding,
    max: Math.max(1, Math.min(o.poolMax ?? 5, 20)),
    idleTimeoutMillis: o.idleTimeoutMs ?? 10_000,
    connectionTimeoutMillis: o.connectTimeoutMs ?? 15_000,
    keepAlive: true,
    application_name: 'muse-api',
    allowExitOnIdle: false,
  } as pg.PoolConfig, {
    attempts: 4, baseMs: 300, maxMs: 3000,
    onRetry: (e, attempt, waitMs) => log.warn({ attempt, waitMs, err: (e as Error).message }, 'database connect failed, retrying (asleep or waking?)'),
  });
  // An idle connection that the server drops (Neon suspending, a pooler restart) emits 'error' on the pool. Without a
  // listener that would crash the process. The pool discards that client and opens a new one on the next query.
  pool.on('error', e => log.warn({ err: e.message }, 'idle database connection closed by the server'));
  return pool;
}

// ---------------------------------------------------------------------------------------------------- migrations
/** Same bookkeeping as drizzle's migrator (drizzle.__drizzle_migrations), so databases migrated either way agree. */
const LOCK_KEY = 7_365_847_210; // arbitrary, fixed: "muse migrations"

export async function migrateWithLock(pool: pg.Pool, migrationsFolder: string, log: Log = quiet) {
  const migrations = readMigrationFiles({ migrationsFolder });
  const client = await pool.connect();
  try {
    await client.query('begin');
    // Transaction-scoped: released by commit/rollback, and works through a transaction-mode pooler.
    await client.query('select pg_advisory_xact_lock($1)', [LOCK_KEY]);
    await client.query('create schema if not exists drizzle');
    await client.query('create table if not exists drizzle.__drizzle_migrations (id serial primary key, hash text not null, created_at bigint)');
    const { rows } = await client.query<{ created_at: string }>('select created_at from drizzle.__drizzle_migrations order by created_at desc limit 1');
    const last = rows[0] ? Number(rows[0].created_at) : -Infinity;
    let applied = 0;
    for (const m of migrations) {
      if (m.folderMillis <= last) continue;
      for (const stmt of m.sql) if (stmt.trim()) await client.query(stmt);
      await client.query('insert into drizzle.__drizzle_migrations (hash, created_at) values ($1, $2)', [m.hash, m.folderMillis]);
      applied++;
    }
    await client.query('commit');
    log.info({ applied, total: migrations.length }, applied ? 'database migrated' : 'database schema up to date');
    return applied;
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

/** Open the pool, wait for the database (it may be asleep), migrate. Retries the whole start-up on transient errors. */
export async function openPg(url: string, migrationsFolder: string, o: PgOptions = {}) {
  const log = o.log ?? quiet;
  const pool = createPool(url, o);
  log.info({ db: describePgUrl(url), poolMax: o.poolMax ?? 5, idleTimeoutMs: o.idleTimeoutMs ?? 10_000 }, 'connecting to Postgres');
  const migPool = o.migrationUrl ? createPool(o.migrationUrl, { ...o, poolMax: 1 }) : pool;
  try {
    await withRetry(() => migrateWithLock(migPool, migrationsFolder, log), {
      budgetMs: o.startupRetryMs ?? 60_000, attempts: 3, baseMs: 1000, maxMs: 8000,
      onRetry: (e, attempt, waitMs) => log.warn({ attempt, waitMs, err: (e as Error).message }, 'database not ready at start-up, retrying'),
    });
  } catch (e) {
    await pool.end().catch(() => {});
    throw e;
  } finally {
    if (migPool !== pool) await migPool.end().catch(() => {});
  }
  return pool;
}
