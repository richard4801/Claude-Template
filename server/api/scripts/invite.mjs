// `npm run invite -- email@example.com [--owner|--member] [--studio "Name"] [--days 14]`
// Runs the compiled CLI (dist/, as in the Docker image on Railway) or, in a dev checkout, the TypeScript source via tsx.
import fs from 'node:fs';

const compiled = new URL('../dist/cli/invite.js', import.meta.url);
if (fs.existsSync(compiled)) await import(compiled.href);
else {
  const { register } = await import('tsx/esm/api');
  register();
  await import(new URL('../src/cli/invite.ts', import.meta.url).href);
}
