// Production entry point: node dist/index.js (Koyeb or Railway run this from the Dockerfile).
import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { runBootCopy, startHoldingServer, dbCopyStatus } from './db/copy.js';
import { MIGRATIONS_DIR } from './db/client.js';

let config;
try { config = loadConfig(); } catch (e) {
  // Configuration problems print one clear line (names only, never values) instead of a stack trace.
  console.error(`MUSE API cannot start: ${(e as Error).message}`);
  process.exit(2);
}

// One-time database move (plans/db-move-railway.md): copy the old database into the new one before anything touches it
// (migrations, starter templates, the owner invite). A /health-only server answers meanwhile.
if (config.MIGRATE_FROM_DATABASE_URL) {
  const pino = (await import('pino')).default;
  const log = pino({ level: config.LOG_LEVEL });
  const holding = await startHoldingServer(config.PORT, config.HOST);
  let state: string;
  if (!config.DATABASE_URL || config.DATABASE_URL.startsWith('pglite')) {
    Object.assign(dbCopyStatus, { state: 'failed', error: 'target_not_postgres' });
    log.error('database copy: MIGRATE_FROM_DATABASE_URL is set but DATABASE_URL is not a Postgres database. Nothing was copied.');
    state = 'failed';
  } else {
    state = await runBootCopy({ sourceUrl: config.MIGRATE_FROM_DATABASE_URL, targetUrl: config.DATABASE_URL, migrationsFolder: MIGRATIONS_DIR, log });
  }
  if (state === 'failed') {
    // Do not start the app on an empty database (it would seed rows and block a later copy). Keep /health up so the owner
    // can read what went wrong; fixing the variable redeploys.
    log.error('database copy failed: the app stays stopped. See /health (dbCopy.error) and plans/db-move-railway.md.');
    await new Promise(() => {});
  }
  await holding.close();
}
const { app, close } = await buildApp(config);
await app.listen({ port: config.PORT, host: config.HOST });
app.log.info(`MUSE API listening on port ${config.PORT}`);

let stopping = false;
for (const sig of ['SIGINT', 'SIGTERM'] as const) {
  process.on(sig, () => {
    if (stopping) return;
    stopping = true;
    app.log.info({ sig }, 'shutting down');
    close().then(() => process.exit(0), () => process.exit(1));
  });
}
