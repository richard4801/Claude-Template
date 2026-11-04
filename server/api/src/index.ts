// Production entry point: node dist/index.js (Koyeb or Railway run this from the Dockerfile).
import { buildApp } from './app.js';
import { loadConfig } from './config.js';

let config;
try { config = loadConfig(); } catch (e) {
  // Configuration problems print one clear line (names only, never values) instead of a stack trace.
  console.error(`MUSE API cannot start: ${(e as Error).message}`);
  process.exit(2);
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
