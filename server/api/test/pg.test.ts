// Neon-style Postgres handling (src/db/pg.ts): retry logic (unit), URL normalisation, and, when TEST_DATABASE_URL points
// at a real Postgres (SSL off locally), the locked migration, a database that refuses the first connections (as a
// sleeping Neon compute can), and the health check that must not wake the database.
import net from 'node:net';
import { afterAll, describe, expect, it, vi } from 'vitest';
import pg from 'pg';
import { createPool, describePgUrl, isTransientDbError, migrateWithLock, normalizePgUrl, openPg, withRetry } from '../src/db/pg.js';
import { MIGRATIONS_DIR } from '../src/db/client.js';
import { makeApp } from './helpers.js';

const err = (code: string | undefined, message = 'x') => Object.assign(new Error(message), code ? { code } : {});

describe('isTransientDbError', () => {
  it('retries what a sleeping or waking database throws', () => {
    for (const e of [err('ECONNREFUSED'), err('ECONNRESET'), err('ETIMEDOUT'), err('EAI_AGAIN'), err('57P01', 'terminating connection due to administrator command'),
      err('57P03', 'the database system is starting up'), err('08006'), err(undefined, 'Connection terminated unexpectedly'),
      err(undefined, 'timeout exceeded when trying to connect'), err('XX000', "Couldn't connect to compute node")]) {
      expect(isTransientDbError(e), e.message).toBe(true);
    }
  });
  it('does not retry mistakes that another try cannot fix', () => {
    for (const e of [err('28P01', 'password authentication failed'), err('3D000', 'database "x" does not exist'), err('42P01', 'relation "x" does not exist'),
      err('23505', 'duplicate key'), err('XX000', 'some other internal error'), err(undefined, 'syntax error')]) {
      expect(isTransientDbError(e), e.message).toBe(false);
    }
    expect(isTransientDbError(undefined)).toBe(false);
  });
});

describe('withRetry', () => {
  const noSleep = { sleep: async () => {} };
  it('retries transient errors with growing waits, then succeeds', async () => {
    const waits: number[] = [];
    let n = 0;
    const r = await withRetry(async () => { if (++n < 4) throw err('ECONNREFUSED'); return 'ok'; },
      { attempts: 5, baseMs: 100, maxMs: 10_000, sleep: async ms => { waits.push(ms); } });
    expect(r).toBe('ok'); expect(n).toBe(4);
    expect(waits.length).toBe(3);
    // exponential with ±25 % jitter: ~100, ~200, ~400
    expect(waits[0]).toBeGreaterThanOrEqual(75); expect(waits[0]).toBeLessThanOrEqual(125);
    expect(waits[2]).toBeGreaterThanOrEqual(300); expect(waits[2]).toBeLessThanOrEqual(500);
  });
  it('gives up after the attempts when there is no time budget', async () => {
    let n = 0;
    await expect(withRetry(async () => { n++; throw err('ECONNRESET'); }, { attempts: 3, ...noSleep })).rejects.toThrow();
    expect(n).toBe(3);
  });
  it('keeps going while the time budget lasts', async () => {
    let t = 0, n = 0;
    await expect(withRetry(async () => { n++; throw err('ETIMEDOUT'); },
      { attempts: 2, budgetMs: 10_000, baseMs: 1000, maxMs: 1000, now: () => t, sleep: async ms => { t += ms; } })).rejects.toThrow();
    expect(n).toBeGreaterThanOrEqual(9); expect(n).toBeLessThanOrEqual(14); // ~10 s of ~1 s waits
  });
  it('never retries a non-transient error', async () => {
    let n = 0;
    await expect(withRetry(async () => { n++; throw err('28P01', 'password authentication failed'); }, { attempts: 5, ...noSleep })).rejects.toThrow(/password/);
    expect(n).toBe(1);
  });
  it('caps each wait at maxMs', async () => {
    const waits: number[] = [];
    await withRetry(async () => { if (waits.length < 6) throw err('ECONNRESET'); }, { attempts: 10, baseMs: 1000, maxMs: 2000, sleep: async ms => { waits.push(ms); } });
    expect(Math.max(...waits)).toBeLessThanOrEqual(2500);
  });
});

describe('normalizePgUrl', () => {
  it("takes Neon's pooled string as pasted", () => {
    const n = normalizePgUrl('postgresql://u:p@ep-cool-name-a1b2c3-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require&channel_binding=require');
    const u = new URL(n.connectionString);
    expect(u.searchParams.get('sslmode')).toBe('verify-full'); // what pg does today, without the deprecation warning
    expect(u.searchParams.has('channel_binding')).toBe(false);
    expect(n.enableChannelBinding).toBe(true); expect(n.ssl).toBe(true);
    expect(describePgUrl('postgresql://u:secret@ep-x-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require')).toEqual(
      { host: 'ep-x-pooler.eu-central-1.aws.neon.tech', database: 'neondb', pooled: true, sslmode: 'require' });
  });
  it('adds TLS for a Neon host without sslmode, leaves a local sslmode=disable alone', () => {
    expect(new URL(normalizePgUrl('postgres://u:p@ep-x.us-east-2.aws.neon.tech/db').connectionString).searchParams.get('sslmode')).toBe('verify-full');
    const local = normalizePgUrl('postgres://muse:muse@localhost:5432/muse?sslmode=disable');
    expect(local.ssl).toBe(false); expect(new URL(local.connectionString).searchParams.get('sslmode')).toBe('disable');
    expect(normalizePgUrl('postgres://a@h/d?uselibpqcompat=true&sslmode=require').connectionString).toContain('sslmode=require');
  });
});

// -------------------------------------------------------------------------------------------- real Postgres
const URL_ = process.env.TEST_DATABASE_URL;
const withSslOff = (u: string) => { const x = new URL(u); x.searchParams.set('sslmode', 'disable'); return x.toString(); };

describe.skipIf(!URL_)('against a real Postgres (TEST_DATABASE_URL, SSL off)', () => {
  const url = URL_ ? withSslOff(URL_) : '';
  const reset = async () => {
    const c = new pg.Client({ connectionString: url });
    await c.connect();
    await c.query('drop schema if exists public cascade; drop schema if exists drizzle cascade; create schema public;');
    await c.end();
  };
  const closers: (() => Promise<void>)[] = [];
  afterAll(async () => { for (const c of closers) await c(); });

  it('two instances starting at once migrate exactly once (advisory lock), and a restart is a no-op', async () => {
    await reset();
    const [a, b] = await Promise.all([openPg(url, MIGRATIONS_DIR, { poolMax: 2 }), openPg(url, MIGRATIONS_DIR, { poolMax: 2 })]);
    closers.push(() => a.end(), () => b.end());
    const { rows } = await a.query('select count(*)::int as n from drizzle.__drizzle_migrations');
    expect(rows[0].n).toBe(1);
    expect(await migrateWithLock(a, MIGRATIONS_DIR)).toBe(0);
    const t = await a.query("select count(*)::int as n from information_schema.tables where table_schema = 'public'");
    expect(t.rows[0].n).toBeGreaterThan(5);
  });

  it('pool settings: at most 5 connections, idle ones closed quickly', async () => {
    const pool = createPool(url, { poolMax: 5, idleTimeoutMs: 200 });
    closers.push(() => pool.end());
    await Promise.all(Array.from({ length: 12 }, () => pool.query('select pg_sleep(0.05)')));
    expect(pool.totalCount).toBeLessThanOrEqual(5);
    await new Promise(r => setTimeout(r, 600));
    expect(pool.totalCount).toBe(0); // nothing left open to keep a Neon compute awake
  });

  it('survives a database that drops the first connections while it wakes up', async () => {
    const real = new URL(url);
    let refused = 0;
    const proxy = net.createServer(sock => {
      if (refused < 3) { refused++; sock.destroy(); return; } // like a compute that isn't up yet
      const up = net.connect(Number(real.port || 5432), real.hostname);
      sock.pipe(up).pipe(sock);
      up.on('error', () => sock.destroy()); sock.on('error', () => up.destroy());
    });
    await new Promise<void>(r => proxy.listen(0, '127.0.0.1', () => r()));
    closers.push(() => new Promise(r => proxy.close(() => r())));
    const via = new URL(url);
    via.hostname = '127.0.0.1'; via.port = String((proxy.address() as net.AddressInfo).port);
    const warn = vi.fn();
    const pool = await openPg(via.toString(), MIGRATIONS_DIR, { log: { info() {}, warn, error() {} }, startupRetryMs: 30_000, idleTimeoutMs: 100 });
    closers.push(() => pool.end());
    expect(refused).toBe(3);
    expect(warn).toHaveBeenCalled();
    expect((await pool.query('select 1 as one')).rows[0].one).toBe(1);
    // ...and later, after the idle connections are gone (the database went back to sleep), a query still works:
    // the pool's connect() retries the refused connection instead of failing the request.
    await new Promise(r => setTimeout(r, 200));
    refused = 1;
    expect((await pool.query('select 2 as two')).rows[0].two).toBe(2);
  });

  it('the API starts with Neon-style settings, and /health does not touch the database', async () => {
    await reset();
    const a = await makeApp({ DB_POOL_MAX: '3', DB_IDLE_TIMEOUT_MS: '500' });
    closers.push(() => a.close());
    const health = await a.app.inject({ method: 'GET', url: '/health' });
    expect(health.statusCode).toBe(200);
    expect(JSON.parse(health.body)).toMatchObject({ ok: true, db: 'unchecked' });
    const deep = await a.app.inject({ method: 'GET', url: '/health?db=1' });
    expect(JSON.parse(deep.body)).toMatchObject({ ok: true, db: true });
  });
});

describe('quiet background loops (let a serverless database sleep)', () => {
  it('with nothing to do, the dispatcher and post scheduler stop polling the database every tick', async () => {
    const a = await makeApp({ DISPATCH_MS: '20', SCHEDULER_MS: '20', IDLE_POLL_SECONDS: '600' });
    try {
      const jobsTick = vi.spyOn(a.ctx.jobs, 'tick');
      const postsTick = vi.spyOn(a.ctx.posts, 'tick');
      await new Promise(r => setTimeout(r, 600)); // ~30 timer ticks each
      expect(jobsTick.mock.calls.length).toBeLessThanOrEqual(2);
      expect(postsTick.mock.calls.length).toBeLessThanOrEqual(2);
      // /health does not count as database work either
      for (let i = 0; i < 5; i++) await a.app.inject({ method: 'GET', url: '/health' });
      a.ctx.jobs.kick(); // new work wakes the dispatcher at once
      await new Promise(r => setTimeout(r, 50));
      expect(jobsTick.mock.calls.length).toBeGreaterThan(0);
    } finally { await a.close(); }
  });

  it('IDLE_POLL_SECONDS=0 keeps the old always-poll behaviour', async () => {
    const a = await makeApp({ DISPATCH_MS: '20', SCHEDULER_MS: '20', IDLE_POLL_SECONDS: '0' });
    try {
      const jobsTick = vi.spyOn(a.ctx.jobs, 'tick');
      await new Promise(r => setTimeout(r, 400));
      expect(jobsTick.mock.calls.length).toBeGreaterThan(5);
    } finally { await a.close(); }
  });
});
