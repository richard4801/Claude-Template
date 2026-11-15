// One-time database move (src/db/copy.ts, plans/db-move-railway.md): the boot-time copy from the old database
// (MIGRATE_FROM_DATABASE_URL) into the new one (DATABASE_URL). Needs a real Postgres (COPY over the wire): TEST_DATABASE_URL
// or local Postgres binaries; the pure helpers run everywhere.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterAll, describe, expect, it } from 'vitest';
import pg from 'pg';
import { MIGRATIONS_DIR, openDb } from '../src/db/client.js';
import { openPg, normalizePgUrl } from '../src/db/pg.js';
import { CopyError, copyDatabase, dbCopyStatus, dbCopyView, directNeonUrl, fkOrder, resetDbCopyStatus, runBootCopy, sameDatabase,
  scrub, startHoldingServer, MARKER_TABLE } from '../src/db/copy.js';
import { client, makeApp, people } from './helpers.js';
import { startTempPg } from './tempPg.js';

// ------------------------------------------------------------------------------------------------ pure helpers
describe('copy helpers', () => {
  it('scrub removes passwords, users, hosts and URLs', () => {
    const src = 'postgresql://neondb_owner:npg_S3cretPw@ep-cool-name-a1b2-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require';
    const tgt = 'postgresql://postgres:RailPw123@postgres.railway.internal:5432/railway';
    const msg = `getaddrinfo ENOTFOUND ep-cool-name-a1b2.eu-central-1.aws.neon.tech; auth for neondb_owner npg_S3cretPw at postgres.railway.internal ${src} 10.1.2.3:5432`;
    const s = scrub(msg, [src, tgt]);
    for (const bad of ['npg_S3cretPw', 'neondb_owner', 'neon.tech', 'railway.internal', 'RailPw123', '10.1.2.3', 'postgresql://']) expect(s).not.toContain(bad);
    expect(s).toContain('ENOTFOUND');
  });
  it('directNeonUrl drops -pooler for Neon only; sameDatabase ignores it', () => {
    expect(directNeonUrl('postgresql://u:p@ep-x-pooler.us-east-2.aws.neon.tech/db?sslmode=require')).toBe('postgresql://u:p@ep-x.us-east-2.aws.neon.tech/db?sslmode=require');
    expect(directNeonUrl('postgresql://u:p@postgres.railway.internal:5432/railway')).toBe('postgresql://u:p@postgres.railway.internal:5432/railway');
    expect(sameDatabase('postgresql://u:p@ep-x-pooler.a.neon.tech/db', 'postgresql://u:p@ep-x.a.neon.tech/db?sslmode=require')).toBe(true);
    expect(sameDatabase('postgresql://u:p@postgres.railway.internal:5432/railway', 'postgresql://u:p@ep-x.a.neon.tech/neondb')).toBe(false);
    expect(sameDatabase(undefined, 'postgres://a@b/c')).toBe(false);
  });
  it('a Railway private URL (no sslmode) connects without TLS; a Neon URL keeps verified TLS and channel binding', () => {
    const r = normalizePgUrl('postgresql://postgres:pw@postgres.railway.internal:5432/railway');
    expect(r.ssl).toBe(false); expect(new URL(r.connectionString).searchParams.has('sslmode')).toBe(false);
    const n = normalizePgUrl('postgresql://u:p@ep-x-pooler.a.aws.neon.tech/neondb?sslmode=require&channel_binding=require');
    expect(n.ssl).toBe(true); expect(n.enableChannelBinding).toBe(true);
  });
  it('fkOrder puts parents first, ignores self-references, reports cycles', () => {
    const t = (name: string) => ({ schema: 'public', name });
    const o = fkOrder([t('c'), t('b'), t('a')], [{ child: 'public.c', parent: 'public.b' }, { child: 'public.b', parent: 'public.a' }, { child: 'public.a', parent: 'public.a' }]);
    expect(o!.map(x => x.name)).toEqual(['a', 'b', 'c']);
    expect(fkOrder([t('a'), t('b')], [{ child: 'public.a', parent: 'public.b' }, { child: 'public.b', parent: 'public.a' }])).toBeNull();
  });
  it('/health on the normal app shows dbCopy idle', async () => {
    resetDbCopyStatus();
    const a = await makeApp();
    try {
      const r = await client(a)('GET', '/health');
      expect(r.body.dbCopy).toMatchObject({ state: 'idle', tables: 0, rowsCopied: 0 });
    } finally { await a.close(); }
  });
});

// ------------------------------------------------------------------------------------------------ real Postgres
const tp = await startTempPg();
afterAll(async () => { await tp?.stop(); });

const q = async (url: string, text: string, params: unknown[] = []) => {
  const c = new pg.Client({ connectionString: url }); await c.connect();
  try { return (await c.query(text, params)).rows; } finally { await c.end(); }
};
const tables = async (url: string) => (await q(url, `select table_schema as s, table_name as n from information_schema.tables
  where table_schema in ('public', 'drizzle') and table_type = 'BASE TABLE' and table_name <> '${MARKER_TABLE}' order by 1, 2`)).map(r => `"${r.s}"."${r.n}"`);
const countsOf = async (url: string) => {
  const out: Record<string, number> = {};
  for (const t of await tables(url)) out[t] = Number((await q(url, `select count(*) as n from ${t}`))[0].n);
  return out;
};
const silent = { info() {}, warn() {}, error() {} };

const TRICKY = { s: 'quote " backslash \\ tab \t newline \n unicode é 漢字 🎬 nul-ish \\u0000', n: 1.0000000000000002, big: 9007199254740993, neg: -0.0,
  nested: { a: [1, 'two', null, true, { deep: [[]] }], empty: {} }, keyOrder: { z: 1, a: 2 } };

/** A source database migrated to `upTo` migrations (all by default) with real app data in it. */
async function makeSource(name: string, upTo?: number) {
  const url = await tp!.createDb(name);
  let folder = MIGRATIONS_DIR;
  if (upTo != null) {
    folder = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-mig-'));
    for (const f of fs.readdirSync(MIGRATIONS_DIR)) if (f.endsWith('.sql')) fs.copyFileSync(path.join(MIGRATIONS_DIR, f), path.join(folder, f));
    fs.mkdirSync(path.join(folder, 'meta'));
    const j = JSON.parse(fs.readFileSync(path.join(MIGRATIONS_DIR, 'meta/_journal.json'), 'utf8'));
    j.entries = j.entries.slice(0, upTo);
    fs.writeFileSync(path.join(folder, 'meta/_journal.json'), JSON.stringify(j));
    const pool = await openPg(url, folder, { poolMax: 1 });
    await pool.end();
    // Old-schema data, written by hand (the app's code expects the latest schema).
    await q(url, `insert into studios (id, name, created_at) values ('st_old', 'Old Studio', 1700000000000)`);
    await q(url, `insert into studio_settings (studio_id, image_engine) values ('st_old', $1::jsonb)`, [JSON.stringify(TRICKY)]);
    return { url, folder };
  }
  const db = await openDb(url);
  const a = await makeApp({}, { db });
  try {
    const { owner } = await people(a, 2);
    // jsonb with every awkward thing, a float that needs full precision.
    await q(url, `update studio_settings set image_engine = $1::jsonb, sim_balance = 0.1 + 0.2 where studio_id = (select studio_id from users where id = $2)`,
      [JSON.stringify(TRICKY), owner.id]);
    // A ledger row deleted at the end: the sequence must stay ahead of max(id) (no id reuse).
    const [{ id }] = await q(url, `insert into ledger (studio_id, kind, tokens, amount_usd, created_at) select studio_id, 'adjust', 1, 0.01, 1 from users where id = $1 returning id`, [owner.id]);
    await q(url, `delete from ledger where id = $1`, [id]);
  } finally { await a.close(); await db.close(); }
  return { url, folder };
}

describe.skipIf(!tp)('copy into a real Postgres', () => {
  let n = 0;
  const fresh = async () => tp!.createDb(`muse_copy_t${++n}_${process.pid}`);

  it('copies into an empty target: same tables, same counts, exact jsonb and floats, sequences ahead; the app then runs on it', async () => {
    const { url: src } = await makeSource(`muse_copy_src_a_${process.pid}`);
    const tgt = await fresh();
    const before = await countsOf(src);
    const r = await copyDatabase({ sourceUrl: src, targetUrl: tgt, migrationsFolder: MIGRATIONS_DIR, log: silent });
    expect(r.state).toBe('done'); expect(r.skipped).toBe(false);
    expect(await countsOf(tgt)).toEqual(before);
    expect(r.rows).toBe(Object.values(before).reduce((x, y) => x + y, 0));
    expect(before['"public"."users"']).toBe(3);

    // jsonb and double precision byte-for-byte
    const sq = `select studio_id, image_engine::text as j, sim_balance::text as b from studio_settings order by studio_id`;
    expect(await q(tgt, sq)).toEqual(await q(src, sq));
    const [row] = await q(tgt, `select image_engine from studio_settings where image_engine is not null`);
    expect(row.image_engine.s).toBe(TRICKY.s); expect(row.image_engine.nested).toEqual(TRICKY.nested);
    // every table's full contents, as text
    for (const t of await tables(src)) expect(await q(tgt, `select md5(string_agg(x::text, '|' order by x::text)) as h from ${t} x`), t)
      .toEqual(await q(src, `select md5(string_agg(x::text, '|' order by x::text)) as h from ${t} x`));

    // sequences: next ledger id on the target = next on the source (past the deleted row), and > max(id)
    const [{ v: tNext }] = await q(tgt, `select nextval('ledger_id_seq')::int as v`);
    const [{ v: sNext }] = await q(src, `select nextval('ledger_id_seq')::int as v`);
    expect(tNext).toBe(sNext);
    const [{ m }] = await q(tgt, 'select max(id)::int as m from ledger');
    expect(tNext).toBeGreaterThan(m);
    const [{ v: jNext }] = await q(tgt, `select nextval('drizzle.__drizzle_migrations_id_seq')::int as v`);
    const [{ m: jm }] = await q(tgt, 'select max(id)::int as m from drizzle.__drizzle_migrations');
    expect(jNext).toBeGreaterThan(jm);

    // marker row
    expect(await q(tgt, `select status, tables, rows::int from ${MARKER_TABLE}`)).toEqual([{ status: 'done', tables: Object.keys(before).length, rows: r.rows }]);

    // second boot: a no-op that never contacts the source (an unreachable source URL is fine)
    const again = await copyDatabase({ sourceUrl: 'postgres://x:y@127.0.0.1:1/none?sslmode=disable', targetUrl: tgt, migrationsFolder: MIGRATIONS_DIR, log: silent, retryBudgetMs: 0 });
    expect(again).toMatchObject({ state: 'done', skipped: true });
    expect(await countsOf(tgt)).toEqual(before);

    // the real app on the copied database: migrations up to date, the owner signs in, starters do not duplicate
    const db = await openDb(tgt);
    const a = await makeApp({}, { db });
    try {
      const s = await client(a)('POST', '/v1/auth/signin', { email: 'owner@test.dev', password: 'correct horse' });
      expect(s.status).toBe(200);
      expect(a.ctx.boot.migrations.applied).toBe(before['"drizzle"."__drizzle_migrations"']);
    } finally { await a.close(); await db.close(); }
  });

  it('refuses a target that already has users, and changes nothing', async () => {
    const { url: src } = await makeSource(`muse_copy_src_b_${process.pid}`);
    const tgt = await fresh();
    const db = await openDb(tgt);
    const a = await makeApp({}, { db });
    try { await people(a, 0, { topUp: 0 }); } finally { await a.close(); await db.close(); }
    const before = await countsOf(tgt);
    const r = await copyDatabase({ sourceUrl: src, targetUrl: tgt, migrationsFolder: MIGRATIONS_DIR, log: silent });
    expect(r.state).toBe('refused');
    expect(await countsOf(tgt)).toEqual(before);
    expect((await q(tgt, `select to_regclass('${MARKER_TABLE}') as r`))[0].r).toBeNull();

    resetDbCopyStatus();
    expect(await runBootCopy({ sourceUrl: src, targetUrl: tgt, migrationsFolder: MIGRATIONS_DIR, log: silent })).toBe('refused');
    expect(dbCopyView()).toMatchObject({ state: 'refused', error: 'target_not_empty' });
  });

  it('a failure mid-copy leaves the target as it was; the retry then succeeds', async () => {
    const { url: src } = await makeSource(`muse_copy_src_c_${process.pid}`);
    const tgt = await fresh();
    const err = await copyDatabase({ sourceUrl: src, targetUrl: tgt, migrationsFolder: MIGRATIONS_DIR, log: silent,
      afterTable: (_t, done) => { if (done === 6) throw new Error('boom: connection lost'); } }).catch(e => e);
    expect(err).toBeInstanceOf(CopyError);
    // nothing at all: no tables, no journal, no marker
    expect(await q(tgt, `select table_schema, table_name from information_schema.tables where table_schema in ('public', 'drizzle')`)).toEqual([]);
    const r = await copyDatabase({ sourceUrl: src, targetUrl: tgt, migrationsFolder: MIGRATIONS_DIR, log: silent });
    expect(r.state).toBe('done');
    expect(await countsOf(tgt)).toEqual(await countsOf(src));
  });

  it('a source on an older schema: the target is built to that version, the copy matches, then normal start-up migrates the rest', async () => {
    const all = JSON.parse(fs.readFileSync(path.join(MIGRATIONS_DIR, 'meta/_journal.json'), 'utf8')).entries.length;
    const { url: src, folder } = await makeSource(`muse_copy_src_d_${process.pid}`, all - 3);
    try {
      const tgt = await fresh();
      const r = await copyDatabase({ sourceUrl: src, targetUrl: tgt, migrationsFolder: MIGRATIONS_DIR, log: silent });
      expect(r.state).toBe('done');
      expect(await countsOf(tgt)).toEqual(await countsOf(src));
      expect((await q(tgt, 'select count(*)::int as n from drizzle.__drizzle_migrations'))[0].n).toBe(all - 3);
      const pool = await openPg(tgt, MIGRATIONS_DIR, { poolMax: 1 });
      await pool.end();
      expect((await q(tgt, 'select count(*)::int as n from drizzle.__drizzle_migrations'))[0].n).toBe(all);
      expect((await q(tgt, `select image_engine::text as j from studio_settings where studio_id = 'st_old'`))[0].j)
        .toBe((await q(src, `select image_engine::text as j from studio_settings where studio_id = 'st_old'`))[0].j);
    } finally { fs.rmSync(folder, { recursive: true, force: true }); }
  });

  it('a target that was started once on its own (seeded rows, no users) is cleared and filled exactly', async () => {
    const { url: src } = await makeSource(`muse_copy_src_e_${process.pid}`);
    const tgt = await fresh();
    const db = await openDb(tgt);
    const a = await makeApp({ OWNER_INVITE_CODE: 'owner-code-123456' }, { db }); // creates a studio and an invite, no users
    await a.close(); await db.close();
    expect((await q(tgt, 'select count(*)::int as n from studios'))[0].n).toBe(1);
    const r = await copyDatabase({ sourceUrl: src, targetUrl: tgt, migrationsFolder: MIGRATIONS_DIR, log: silent });
    expect(r.state).toBe('done');
    expect(await countsOf(tgt)).toEqual(await countsOf(src));
  });

  it('boot driver: an unreachable source is retried, logs and /health carry no secrets, the target stays untouched', async () => {
    const tgt = await fresh();
    const lines: string[] = [];
    const log = { info: (o: object, m?: string) => lines.push(JSON.stringify(o) + m), warn: (o: object, m?: string) => lines.push(JSON.stringify(o) + m),
      error: (o: object, m?: string) => lines.push(JSON.stringify(o) + m) };
    const waits: number[] = [];
    resetDbCopyStatus();
    const state = await runBootCopy({ sourceUrl: 'postgresql://neon_user:VerySecretPw@127.0.0.1:1/neondb?sslmode=disable', targetUrl: tgt,
      migrationsFolder: MIGRATIONS_DIR, log, retryBudgetMs: 0, connectTimeoutMs: 2000, maxAttempts: 2, sleep: async ms => { waits.push(ms); } });
    expect(state).toBe('failed');
    expect(waits.length).toBe(1);
    expect(dbCopyView()).toMatchObject({ state: 'failed', error: 'source_unreachable', willRetry: false, attempts: 2 });
    const all = lines.join('\n') + JSON.stringify(dbCopyView());
    for (const bad of ['VerySecretPw', 'neon_user', '127.0.0.1', 'postgresql://', tgt]) expect(all).not.toContain(bad);
    expect(await q(tgt, `select table_name from information_schema.tables where table_schema in ('public', 'drizzle')`)).toEqual([]);

    // wrong password on the target: not transient, no retry
    resetDbCopyStatus();
    const bad = new URL(tgt); bad.username = 'nobody_here';
    expect(await runBootCopy({ sourceUrl: 'postgres://a:b@127.0.0.1:1/other?sslmode=disable', targetUrl: bad.toString(), migrationsFolder: MIGRATIONS_DIR, log,
      retryBudgetMs: 0, sleep: async () => {} })).toBe('failed');
    expect(dbCopyView()).toMatchObject({ state: 'failed', error: 'target_auth', willRetry: false, attempts: 1 });
  });

  it('the holding server answers /health with progress only and 503 elsewhere', async () => {
    resetDbCopyStatus();
    Object.assign(dbCopyStatus, { state: 'running', tables: 40, tablesDone: 12, rowsCopied: 1234, rowsTotal: 5000, attempts: 1 });
    const h = await startHoldingServer(0, '127.0.0.1');
    try {
      const r = await fetch(`http://127.0.0.1:${h.port}/health`);
      expect(r.status).toBe(200);
      expect(await r.json()).toEqual({ ok: true, phase: 'database_copy', dbCopy: { state: 'running', tables: 40, tablesDone: 12, rowsCopied: 1234, rowsTotal: 5000, attempts: 1 } });
      expect((await fetch(`http://127.0.0.1:${h.port}/v1/auth/me`)).status).toBe(503);
    } finally { await h.close(); resetDbCopyStatus(); }
  });
});
