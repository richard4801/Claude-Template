// Writes android/app/src/main/resources/prompt_scripts.json: GET /v1/prompt-scripts as the SERVER answers it for a studio
// that has edited nothing (every script on its default rules). The Android app's demo mode serves it.
// test/prompt-scripts-fixture.test.ts checks the shipped copy is current.
// Run: npx tsx scripts/gen-prompt-scripts.ts
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Ctx } from '../src/ctx.js';
import { PromptScripts } from '../src/prompt/scripts/service.js';

export const PROMPT_SCRIPTS_JSON = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../android/app/src/main/resources/prompt_scripts.json');

/** The list for a studio without saved rules: a database stub that has no rows. */
export async function defaultPromptScripts() {
  const none = { select: () => ({ from: () => ({ where: async () => [] }) }) };
  return new PromptScripts({ db: none } as unknown as Ctx).list('studio_default');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const list = await defaultPromptScripts();
  fs.mkdirSync(path.dirname(PROMPT_SCRIPTS_JSON), { recursive: true });
  fs.writeFileSync(PROMPT_SCRIPTS_JSON, JSON.stringify(list, null, 1) + '\n');
  console.log(`wrote ${list.scripts.length} scripts to ${PROMPT_SCRIPTS_JSON}`);
}
