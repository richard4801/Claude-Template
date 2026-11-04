// Production entry point: node dist/index.js (Railway runs this from the Dockerfile).
import { buildApp } from './app.js';
import { loadConfig } from './config.js';

const config = loadConfig();
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
