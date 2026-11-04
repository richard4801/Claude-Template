// Database connection: node-postgres for a real DATABASE_URL, PGlite (Postgres compiled to WASM, in-process) when
// DATABASE_URL is unset or "pglite://memory" (dev and tests without Docker). Migrations in ./drizzle run on start.
// The Postgres side (pool size, idle timeouts, retries while a sleeping Neon database wakes, the migration lock) is in pg.ts.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { PgDatabase } from 'drizzle-orm/pg-core';
import * as schema from './schema.js';
import { openPg, type PgOptions } from './pg.js';

export type Db = PgDatabase<any, typeof schema>;
export type DbHandle = { db: Db; close: () => Promise<void>; kind: 'postgres' | 'pglite' };

export const MIGRATIONS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../drizzle');

export async function openDb(url: string | undefined, migrationsFolder = MIGRATIONS_DIR, pgOptions: PgOptions = {}): Promise<DbHandle> {
  if (!url || url.startsWith('pglite')) {
    const { PGlite } = await import('@electric-sql/pglite');
    const { drizzle } = await import('drizzle-orm/pglite');
    const { migrate } = await import('drizzle-orm/pglite/migrator');
    const dir = url?.startsWith('pglite://') && url !== 'pglite://memory' ? url.slice('pglite://'.length) : undefined;
    const client = new PGlite(dir);
    const db = drizzle(client, { schema });
    await migrate(db, { migrationsFolder });
    return { db: db as unknown as Db, close: () => client.close(), kind: 'pglite' };
  }
  const { drizzle } = await import('drizzle-orm/node-postgres');
  const pool = await openPg(url, migrationsFolder, pgOptions);
  const db = drizzle(pool, { schema });
  return { db: db as unknown as Db, close: () => pool.end(), kind: 'postgres' };
}
