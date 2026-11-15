// One-time database move (plans/db-move-railway.md): copies every row from the old database (MIGRATE_FROM_DATABASE_URL,
// the Neon string) into the new one (DATABASE_URL, Railway Postgres) at boot, before the normal migrations and starters.
//
// Safety rules:
//   - The source is only read: one REPEATABLE READ READ ONLY transaction, so every table comes from the same snapshot.
//   - Everything on the target happens in ONE transaction (schema up to the source's migration, truncate, COPY, sequences,
//     count check, marker row). Any error rolls all of it back, so a retry starts from a clean target.
//   - A target that already has users and no marker is refused: never merge, never overwrite.
//   - The marker table (_muse_copy_state) makes every later boot a no-op that does not even contact the source.
//   - Connection strings, hosts and user names are never logged or returned. Logs carry table names and row counts.
import pg from 'pg';
import { pipeline } from 'node:stream/promises';
import { from as copyFrom, to as copyTo } from 'pg-copy-streams';
import { readMigrationFiles } from 'drizzle-orm/migrator';
import { LOCK_KEY, normalizePgUrl, withRetry, isTransientDbError } from './pg.js';

type Log = { info: (o: object, m?: string) => void; warn: (o: object, m?: string) => void; error: (o: object, m?: string) => void };
const quiet: Log = { info() {}, warn() {}, error() {} };

export type CopyState = 'idle' | 'running' | 'done' | 'failed' | 'refused';
/** What /health shows. Numbers and a category only: never a URL, host, user name or raw error text. */
export type CopyStatus = {
  state: CopyState; tables: number; tablesDone: number; rowsCopied: number; rowsTotal: number;
  error?: string; willRetry?: boolean; attempts: number; startedAt?: number; finishedAt?: number;
};
export const dbCopyStatus: CopyStatus = { state: 'idle', tables: 0, tablesDone: 0, rowsCopied: 0, rowsTotal: 0, attempts: 0 };
export function resetDbCopyStatus() {
  Object.assign(dbCopyStatus, { state: 'idle', tables: 0, tablesDone: 0, rowsCopied: 0, rowsTotal: 0, attempts: 0,
    error: undefined, willRetry: undefined, startedAt: undefined, finishedAt: undefined });
}

export const MARKER_TABLE = '_muse_copy_state';
/** Schemas copied. Others (e.g. Neon's neon_auth) are reported as skipped. */
const SCHEMAS = ['public', 'drizzle'];

/** A failure with a category safe to show on /health. `transient` = worth trying again later (source asleep, over quota). */
export class CopyError extends Error {
  constructor(public category: string, message: string, public transient = false) { super(message); }
}

// ---------------------------------------------------------------------------------------------------- urls and redaction
/** Neon's pooled host (ep-x-pooler.region...) → the direct host (ep-x.region...): COPY in one long transaction wants it. */
export function directNeonUrl(raw: string): string {
  try {
    const u = new URL(raw.trim());
    if (/\.neon\.tech$/i.test(u.hostname)) u.hostname = u.hostname.replace(/-pooler\./i, '.');
    return u.toString();
  } catch { return raw; }
}

function urlParts(raw: string | undefined): string[] {
  if (!raw) return [];
  const parts = [raw, raw.trim()];
  try {
    const u = new URL(raw.trim());
    parts.push(u.toString(), u.host, u.hostname, u.hostname.replace(/-pooler\./i, '.'));
    if (u.password) parts.push(u.password, decodeURIComponent(u.password));
    if (u.username && u.username.length >= 4) parts.push(u.username, decodeURIComponent(u.username));
  } catch { /* nothing more */ }
  return [...new Set(parts.filter(p => p && p.length >= 3))].sort((a, b) => b.length - a.length);
}

/** Removes every piece of the given connection strings (and any postgres:// URL) from a message. */
export function scrub(msg: string, urls: (string | undefined)[]): string {
  let s = String(msg ?? '');
  for (const p of urls.flatMap(urlParts)) s = s.split(p).join('[redacted]');
  s = s.replace(/postgres(ql)?:\/\/\S+/gi, '[redacted-url]');
  // Host names and IPs the driver puts in network errors (getaddrinfo ENOTFOUND x, connect ECONNREFUSED 1.2.3.4:5432).
  s = s.replace(/\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b/g, '[ip]').replace(/\b[a-z0-9-]+(\.[a-z0-9-]+)+\.(tech|internal|net|com|app|io|cloud|dev)\b/gi, '[host]');
  return s.slice(0, 300);
}

/** Same database? Hosts compared without Neon's "-pooler", plus the database name. */
export function sameDatabase(a: string | undefined, b: string | undefined): boolean {
  if (!a || !b) return false;
  try {
    const x = new URL(a.trim()), y = new URL(b.trim());
    const h = (u: URL) => u.hostname.toLowerCase().replace(/-pooler\./, '.');
    return h(x) === h(y) && (x.port || '5432') === (y.port || '5432') && x.pathname === y.pathname;
  } catch { return false; }
}

function categorize(e: unknown, side: 'source' | 'target'): CopyError {
  if (e instanceof CopyError) return e;
  const err = e as { code?: string; message?: string };
  const msg = String(err?.message ?? '');
  if (err?.code === '28P01' || err?.code === '28000' || /password authentication failed/i.test(msg)) return new CopyError(`${side}_auth`, msg);
  if (err?.code === '3D000') return new CopyError(`${side}_database_missing`, msg);
  if (/quota|exceeded the|data transfer limit|compute time/i.test(msg)) return new CopyError(`${side}_quota`, msg, true);
  if (isTransientDbError(e) || /ENOTFOUND|EAI_AGAIN|ECONNREFUSED|timeout/i.test(msg)) return new CopyError(`${side}_unreachable`, msg, true);
  return new CopyError(`${side}_error`, msg);
}

// ---------------------------------------------------------------------------------------------------- sql helpers
const qi = (s: string) => `"${s.replace(/"/g, '""')}"`;
const qt = (t: TableRef) => `${qi(t.schema)}.${qi(t.name)}`;
type TableRef = { schema: string; name: string };
const key = (t: TableRef) => `${t.schema}.${t.name}`;

async function connect(url: string, side: 'source' | 'target', o: { connectTimeoutMs: number; retryBudgetMs: number; log: Log; urls: string[] }) {
  const n = normalizePgUrl(url);
  return withRetry(async () => {
    const c = new pg.Client({ connectionString: n.connectionString, enableChannelBinding: n.enableChannelBinding, keepAlive: true,
      connectionTimeoutMillis: o.connectTimeoutMs, application_name: `muse-db-copy-${side}` } as pg.ClientConfig);
    c.on('error', () => {}); // a dropped socket surfaces on the running query instead
    try { await c.connect(); } catch (e) { await c.end().catch(() => {}); throw e; }
    // Same text rendering on both sides, so COPY's text format round-trips exactly (timestamps, floats, bytea).
    await c.query(`set client_encoding = 'UTF8'; set timezone = 'UTC'; set datestyle = 'ISO, YMD'; set intervalstyle = 'postgres';
      set extra_float_digits = 3; set bytea_output = 'hex'; set statement_timeout = 0; set idle_in_transaction_session_timeout = 0`);
    return c;
  }, {
    budgetMs: o.retryBudgetMs, attempts: 3, baseMs: 1000, maxMs: 8000,
    onRetry: (e, attempt, waitMs) => o.log.warn({ side, attempt, waitMs, err: scrub((e as Error).message, o.urls) }, 'database copy: connect failed, retrying'),
  }).catch(e => { throw categorize(e, side); });
}

async function listTables(c: pg.Client): Promise<TableRef[]> {
  const { rows } = await c.query<{ schema: string; name: string }>(
    `select n.nspname as schema, c.relname as name from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'r' and n.nspname <> 'pg_catalog' and n.nspname <> 'information_schema' and n.nspname not like 'pg\\_%'
     order by 1, 2`);
  return rows;
}

async function listColumns(c: pg.Client, t: TableRef): Promise<string[]> {
  const { rows } = await c.query<{ name: string }>(
    `select a.attname as name from pg_attribute a where a.attrelid = $1::regclass and a.attnum > 0 and not a.attisdropped
     and a.attgenerated = '' order by a.attnum`, [qt(t)]);
  return rows.map(r => r.name);
}

/** Parents before children (foreign keys). Self-references are fine inside one COPY. Returns null on a cycle. */
export function fkOrder(tables: TableRef[], edges: { child: string; parent: string }[]): TableRef[] | null {
  const byKey = new Map(tables.map(t => [key(t), t]));
  const deps = new Map<string, Set<string>>(tables.map(t => [key(t), new Set<string>()]));
  for (const e of edges) if (e.child !== e.parent && byKey.has(e.child) && byKey.has(e.parent)) deps.get(e.child)!.add(e.parent);
  const out: TableRef[] = [];
  const done = new Set<string>();
  while (out.length < tables.length) {
    const ready = tables.filter(t => !done.has(key(t)) && [...deps.get(key(t))!].every(p => done.has(p)));
    if (!ready.length) return null;
    for (const t of ready) { done.add(key(t)); out.push(t); }
  }
  return out;
}

async function fkEdges(c: pg.Client) {
  const { rows } = await c.query<{ child: string; parent: string }>(
    `select cn.nspname || '.' || cc.relname as child, pn.nspname || '.' || pc.relname as parent
     from pg_constraint k join pg_class cc on cc.oid = k.conrelid join pg_namespace cn on cn.oid = cc.relnamespace
     join pg_class pc on pc.oid = k.confrelid join pg_namespace pn on pn.oid = pc.relnamespace where k.contype = 'f'`);
  return rows;
}

const exists = async (c: pg.Client, rel: string) => (await c.query<{ r: string | null }>('select to_regclass($1) as r', [rel])).rows[0]?.r != null;

// ---------------------------------------------------------------------------------------------------- the copy
export type CopyOptions = {
  sourceUrl: string;
  targetUrl: string;
  migrationsFolder: string;
  log?: Log;
  connectTimeoutMs?: number;
  /** How long to keep retrying a connection (a Neon compute that is waking up). */
  retryBudgetMs?: number;
  /** Tests: called after each table is copied, inside the target transaction (throw to simulate a failure). */
  afterTable?: (table: string, done: number) => void | Promise<void>;
};
export type CopyResult = { state: 'done' | 'refused'; skipped: boolean; tables: number; rows: number; perTable: Record<string, number> };

/** Runs the one-time copy (or does nothing when the marker says it is done). Throws a CopyError on failure. */
export async function copyDatabase(o: CopyOptions): Promise<CopyResult> {
  const log = o.log ?? quiet;
  const urls = [o.sourceUrl, o.targetUrl, directNeonUrl(o.sourceUrl)];
  const cOpts = { connectTimeoutMs: o.connectTimeoutMs ?? 30_000, retryBudgetMs: o.retryBudgetMs ?? 90_000, log, urls };
  if (sameDatabase(o.sourceUrl, o.targetUrl)) throw new CopyError('same_database', 'MIGRATE_FROM_DATABASE_URL and DATABASE_URL point at the same database');

  const target = await connect(o.targetUrl, 'target', cOpts);
  let source: pg.Client | null = null;
  try {
    // 1. Already done? Then the source is never contacted again.
    if (await exists(target, `public.${MARKER_TABLE}`)) {
      const { rows } = await target.query(`select status, tables, rows from public.${qi(MARKER_TABLE)} where id = 1`);
      if (rows[0]?.status === 'done') {
        log.info({ tables: rows[0].tables, rows: Number(rows[0].rows) }, 'database copy: already done earlier (marker present), nothing to do');
        return { state: 'done', skipped: true, tables: rows[0].tables, rows: Number(rows[0].rows), perTable: {} };
      }
    }
    // 2. Never merge into a database that already has people in it.
    if (await exists(target, 'public.users')) {
      const { rows } = await target.query('select count(*)::int as n from public.users');
      if (rows[0].n > 0) {
        log.error({ users: rows[0].n }, 'DATABASE COPY REFUSED: the new database (DATABASE_URL) already has users and no completed copy marker. ' +
          'Nothing was copied or changed. If this database is the one to keep, remove MIGRATE_FROM_DATABASE_URL.');
        return { state: 'refused', skipped: false, tables: 0, rows: 0, perTable: {} };
      }
    }

    // 3. Source: one read-only snapshot.
    source = await connect(directNeonUrl(o.sourceUrl), 'source', cOpts);
    const src = source;
    await src.query('begin isolation level repeatable read read only').catch(e => { throw categorize(e, 'source'); });
    if (!(await exists(src, 'drizzle.__drizzle_migrations'))) throw new CopyError('source_has_no_schema', 'the old database has no migrations table');
    const { rows: srcMig } = await src.query<{ created_at: string }>('select created_at from drizzle.__drizzle_migrations order by created_at');
    const sourceLast = srcMig.length ? Number(srcMig.at(-1)!.created_at) : -Infinity;
    const migrations = readMigrationFiles({ migrationsFolder: o.migrationsFolder });
    const ourLast = migrations.at(-1)?.folderMillis ?? -Infinity;
    if (sourceLast > ourLast) throw new CopyError('source_schema_newer', 'the old database has migrations this build does not know');
    const sourceVersion = migrations.filter(m => m.folderMillis <= sourceLast).length;
    log.info({ sourceMigrations: srcMig.length, sourceVersion, latest: migrations.length }, 'database copy: old database schema read');

    const srcTables = (await listTables(src)).filter(t => SCHEMAS.includes(t.schema) && t.name !== MARKER_TABLE);
    const skipped = (await listTables(src)).filter(t => !SCHEMAS.includes(t.schema));
    for (const t of skipped) {
      const { rows } = await src.query(`select count(*)::bigint as n from ${qt(t)}`);
      log.warn({ table: key(t), rows: Number(rows[0].n) }, 'database copy: table outside public/drizzle is not copied');
    }
    const counts: Record<string, number> = {};
    for (const t of srcTables) counts[key(t)] = Number((await src.query(`select count(*)::bigint as n from ${qt(t)}`)).rows[0].n);
    const rowsTotal = Object.values(counts).reduce((a, b) => a + b, 0);
    Object.assign(dbCopyStatus, { tables: srcTables.length, rowsTotal, tablesDone: 0, rowsCopied: 0 });

    // 4. Target: one transaction for everything.
    await target.query('begin');
    try {
      await target.query('select pg_advisory_xact_lock($1)', [LOCK_KEY]);
      await target.query('create schema if not exists drizzle');
      await target.query('create table if not exists drizzle.__drizzle_migrations (id serial primary key, hash text not null, created_at bigint)');
      const { rows: tr } = await target.query<{ c: string | null }>('select max(created_at) as c from drizzle.__drizzle_migrations');
      const targetLast = tr[0]?.c != null ? Number(tr[0].c) : -Infinity;
      if (targetLast > sourceLast) throw new CopyError('target_schema_newer', 'the new database is on a newer schema than the old one');
      let applied = 0;
      for (const m of migrations) {
        if (m.folderMillis <= targetLast || m.folderMillis > sourceLast) continue;
        for (const stmt of m.sql) if (stmt.trim()) await target.query(stmt);
        await target.query('insert into drizzle.__drizzle_migrations (hash, created_at) values ($1, $2)', [m.hash, m.folderMillis]);
        applied++;
      }
      log.info({ applied, upTo: sourceVersion }, 'database copy: new database schema brought to the old one\'s version');

      // Same tables and columns on both sides, or stop.
      const tgtTables = (await listTables(target)).filter(t => SCHEMAS.includes(t.schema) && t.name !== MARKER_TABLE);
      const sk = new Set(srcTables.map(key)), tk = new Set(tgtTables.map(key));
      const onlySrc = [...sk].filter(k => !tk.has(k)), onlyTgt = [...tk].filter(k => !sk.has(k));
      if (onlySrc.length || onlyTgt.length) {
        log.error({ onlyInOld: onlySrc, onlyInNew: onlyTgt }, 'database copy: table lists differ');
        throw new CopyError('schema_mismatch', 'table lists differ');
      }
      const cols = new Map<string, string[]>();
      for (const t of srcTables) {
        const a = await listColumns(src, t), b = await listColumns(target, t);
        if (a.length !== b.length || [...a].sort().join(',') !== [...b].sort().join(',')) {
          log.error({ table: key(t), onlyInOld: a.filter(x => !b.includes(x)), onlyInNew: b.filter(x => !a.includes(x)) }, 'database copy: columns differ');
          throw new CopyError('schema_mismatch', `columns differ in ${key(t)}`);
        }
        cols.set(key(t), a);
      }

      let order = fkOrder(srcTables, await fkEdges(target));
      if (!order) {
        // A foreign-key cycle: load with triggers (and so FK checks) off, which needs a superuser (Railway's postgres is).
        await target.query('set local session_replication_role = replica').catch(() => { throw new CopyError('fk_cycle', 'foreign-key cycle and no permission to defer checks'); });
        order = srcTables;
      }

      // Clear what the migrations seeded (and anything else) so the copy is exact. Users is empty (checked above).
      await target.query(`truncate table ${tgtTables.map(qt).join(', ')} restart identity cascade`);

      const perTable: Record<string, number> = {};
      for (const t of order) {
        const list = cols.get(key(t))!.map(qi).join(', ');
        const out = src.query(copyTo(`copy ${qt(t)} (${list}) to stdout`));
        const inn = target.query(copyFrom(`copy ${qt(t)} (${list}) from stdin`));
        await pipeline(out, inn);
        perTable[key(t)] = inn.rowCount;
        dbCopyStatus.tablesDone++;
        dbCopyStatus.rowsCopied += inn.rowCount;
        log.info({ table: key(t), rows: inn.rowCount }, 'database copy: table copied');
        await o.afterTable?.(key(t), dbCopyStatus.tablesDone);
      }

      // Sequences: the old values, and never below the column's max.
      const { rows: seqs } = await src.query<{ s: string; n: string; v: string | null }>(
        `select schemaname as s, sequencename as n, last_value::text as v from pg_sequences where schemaname = any($1)`, [SCHEMAS]);
      for (const q of seqs) {
        if (q.v == null) continue;
        if (!(await exists(target, `${qi(q.s)}.${qi(q.n)}`))) continue;
        await target.query('select setval($1::regclass, $2::bigint, true)', [`${qi(q.s)}.${qi(q.n)}`, q.v]);
      }
      const { rows: owned } = await target.query<{ ss: string; sn: string; tbl: string; col: string }>(
        `select sn.nspname as ss, s.relname as sn, format('%I.%I', tn.nspname, t.relname) as tbl, quote_ident(a.attname) as col
         from pg_depend d join pg_class s on s.oid = d.objid and s.relkind = 'S' join pg_namespace sn on sn.oid = s.relnamespace
         join pg_class t on t.oid = d.refobjid join pg_namespace tn on tn.oid = t.relnamespace
         join pg_attribute a on a.attrelid = t.oid and a.attnum = d.refobjsubid
         where d.deptype in ('a', 'i') and tn.nspname = any($1)`, [SCHEMAS]);
      for (const r of owned) {
        await target.query(`select setval($1::regclass, m, true) from (select max(${r.col})::bigint as m from ${r.tbl}) x
          where m is not null and m > coalesce((select last_value from pg_sequences where schemaname = $2 and sequencename = $3), 0)`,
          [`${qi(r.ss)}.${qi(r.sn)}`, r.ss, r.sn]);
      }

      // Verify: every table's row count equals the old one's.
      const bad: { table: string; old: number; copied: number; now: number }[] = [];
      for (const t of srcTables) {
        const now = Number((await target.query(`select count(*)::bigint as n from ${qt(t)}`)).rows[0].n);
        if (now !== counts[key(t)] || perTable[key(t)] !== counts[key(t)]) bad.push({ table: key(t), old: counts[key(t)]!, copied: perTable[key(t)] ?? -1, now });
      }
      if (bad.length) {
        log.error({ tables: bad }, 'database copy: row counts differ, rolling back');
        throw new CopyError('count_mismatch', 'row counts differ');
      }

      await target.query(`create table if not exists public.${qi(MARKER_TABLE)} (id int primary key, status text not null, finished_at timestamptz not null default now(),
        tables int not null, rows bigint not null, source_migrations int not null)`);
      await target.query(`insert into public.${qi(MARKER_TABLE)} (id, status, tables, rows, source_migrations) values (1, 'done', $1, $2, $3)
        on conflict (id) do update set status = excluded.status, finished_at = now(), tables = excluded.tables, rows = excluded.rows, source_migrations = excluded.source_migrations`,
        [srcTables.length, rowsTotal, srcMig.length]);
      await target.query('commit');
      log.info({ tables: srcTables.length, rows: rowsTotal }, 'database copy: DONE, every table\'s row count matches the old database');
      return { state: 'done', skipped: false, tables: srcTables.length, rows: rowsTotal, perTable };
    } catch (e) {
      await target.query('rollback').catch(() => {});
      throw e;
    }
  } catch (e) {
    throw e instanceof CopyError ? e : categorize(e, source ? 'source' : 'target');
  } finally {
    if (source) { await source.query('rollback').catch(() => {}); await source.end().catch(() => {}); }
    await target.end().catch(() => {});
  }
}

// ---------------------------------------------------------------------------------------------------- boot driver
export type BootCopyOptions = Omit<CopyOptions, 'log'> & {
  log: Log;
  /** Waits between retries of a transient failure (the old database asleep or still over its quota). */
  retryDelaysMs?: number[];
  sleep?: (ms: number) => Promise<void>;
  /** Stop retrying (tests, shutdown). */
  maxAttempts?: number;
};

/**
 * Runs the copy for boot, updating dbCopyStatus. Resolves to the final state: 'done' (start the app), 'refused' (start the
 * app on the new database as it is), or 'failed' (do NOT start the app: it would seed rows into the empty database).
 * Transient failures (old database unreachable or over quota) are retried with growing waits.
 */
export async function runBootCopy(o: BootCopyOptions): Promise<CopyState> {
  const delays = o.retryDelaysMs ?? [15_000, 30_000, 60_000, 120_000];
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>(r => setTimeout(r, ms)));
  const urls = [o.sourceUrl, o.targetUrl, directNeonUrl(o.sourceUrl)];
  dbCopyStatus.startedAt = Date.now();
  for (let attempt = 1; ; attempt++) {
    Object.assign(dbCopyStatus, { state: 'running', attempts: attempt, error: undefined, willRetry: undefined, tablesDone: 0, rowsCopied: 0 });
    try {
      const r = await copyDatabase({ ...o, log: o.log });
      Object.assign(dbCopyStatus, { state: r.state, finishedAt: Date.now() });
      if (r.state === 'done') Object.assign(dbCopyStatus, { tables: r.tables, tablesDone: r.tables, rowsCopied: r.rows, rowsTotal: r.rows });
      if (r.state === 'refused') dbCopyStatus.error = 'target_not_empty';
      return r.state;
    } catch (e) {
      const ce = e instanceof CopyError ? e : new CopyError('unknown', String((e as Error)?.message ?? e));
      const retry = ce.transient && (o.maxAttempts == null || attempt < o.maxAttempts);
      Object.assign(dbCopyStatus, { state: 'failed', error: ce.category, willRetry: retry, finishedAt: Date.now() });
      const wait = delays[Math.min(attempt - 1, delays.length - 1)]!;
      o.log.error({ category: ce.category, attempt, willRetry: retry, retryInSec: retry ? Math.round(wait / 1000) : undefined,
        detail: scrub(ce.message, urls) }, 'database copy FAILED; the new database was left unchanged');
      if (!retry) return 'failed';
      await sleep(wait);
    }
  }
}

/** The /health view: state, counts and an error category. Nothing else. */
export function dbCopyView() {
  const s = dbCopyStatus;
  return { state: s.state, tables: s.tables, tablesDone: s.tablesDone, rowsCopied: s.rowsCopied, rowsTotal: s.rowsTotal,
    ...(s.error ? { error: s.error } : {}), ...(s.willRetry != null ? { willRetry: s.willRetry } : {}), attempts: s.attempts,
    ...(s.startedAt ? { startedAt: s.startedAt } : {}), ...(s.finishedAt ? { finishedAt: s.finishedAt } : {}) };
}

// ---------------------------------------------------------------------------------------------------- holding server
/**
 * While the copy runs (the app is not built yet), answer the host's health check so Railway does not kill the deploy
 * mid-copy (its health check gives up after 60 s). GET /health → 200 with dbCopy; everything else → 503.
 */
export async function startHoldingServer(port: number, host: string) {
  const http = await import('node:http');
  const server = http.createServer((req, res) => {
    const path = (req.url ?? '/').split('?')[0];
    res.setHeader('content-type', 'application/json');
    res.setHeader('cache-control', 'no-store');
    if (req.method === 'GET' && path === '/health') {
      res.statusCode = 200;
      res.end(JSON.stringify({ ok: dbCopyStatus.state !== 'failed', phase: 'database_copy', dbCopy: dbCopyView() }));
    } else {
      res.statusCode = 503;
      res.end(JSON.stringify({ error: 'The server is moving its database. Try again in a minute.', code: 'database_copy_in_progress' }));
    }
  });
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(port, host, () => resolve()); });
  return { port: (server.address() as { port: number }).port, close: () => new Promise<void>(r => { server.closeAllConnections?.(); server.close(() => r()); }) };
}
