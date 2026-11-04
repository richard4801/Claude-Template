// Starts the API for the apps' contract tests: embedded Postgres in memory, local storage in a temp dir,
// simulated GPU and image engine, dev seed (same data as server/mock), DEV_MODE on. Prints "MUSE API ... mock server
// compatible" when ready, which is what HttpMuseApiTest waits for.
// Usage: PORT=8799 SPEED=2400 GEN_MS=50 npx tsx scripts/test-server.ts
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-api-test-'));
const config = loadConfig({
  DEV_MODE: 'true', DEV_SEED: 'true', DATABASE_URL: 'pglite://memory', UPLOAD_DIR: dir, LOG_LEVEL: 'warn', BALANCE_MODE: 'simulated',
  AUTH_RATE_PER_MIN: '1000', ...process.env,
});
const { app, close } = await buildApp(config);
await app.listen({ port: config.PORT, host: '127.0.0.1' });
console.log(`MUSE API on http://127.0.0.1:${config.PORT} (mock server compatible, dev mode, speed ${config.SPEED}x)`);
const stop = () => close().finally(() => { fs.rmSync(dir, { recursive: true, force: true }); process.exit(0); });
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
// The Android contract test runs this under sh/npx: when it closes our stdin, we stop too.
if (process.env.MUSE_EXIT_ON_STDIN_CLOSE === '1') { process.stdin.on('end', stop); process.stdin.on('close', stop); process.stdin.resume(); }
