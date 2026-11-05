// Writes android/app/src/main/resources/prompt_scripts.json and the Mac's test fixture
// (mac/MuseCore/Tests/MuseCoreTests/Fixtures/prompt_scripts_fixture.json: the list + one preview): GET /v1/prompt-scripts as the SERVER answers it for a studio
// that has edited nothing (every script on its default rules). The Android app's demo mode serves it.
// test/prompt-scripts-fixture.test.ts checks the shipped copy is current.
// Run: npx tsx scripts/gen-prompt-scripts.ts
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { AuthUser, Ctx } from '../src/ctx.js';
import { DEFAULT_TEXTS } from '../src/prompt/library.js';
import { PromptScripts } from '../src/prompt/scripts/service.js';

export const PROMPT_SCRIPTS_JSON = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../android/app/src/main/resources/prompt_scripts.json');

/** The Mac's test fixture: the same list plus one preview (video.replicate, performer not speaking). */
export const MAC_FIXTURE_JSON = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../mac/MuseCore/Tests/MuseCoreTests/Fixtures/prompt_scripts_fixture.json');

/** A studio without saved rules or block edits: a database stub that has no rows, and the default library texts. */
const service = () => {
  const none = { select: () => ({ from: () => ({ where: async () => [] }) }) };
  return new PromptScripts({ db: none, prompts: { texts: async () => ({ ...DEFAULT_TEXTS }) } } as unknown as Ctx);
};
export async function defaultPromptScripts() {
  return service().list('studio_default');
}
export async function macFixture() {
  const svc = service();
  const preview = await svc.preview({ studioId: 'studio_default' } as AuthUser, { id: 'video.replicate', inputs: { speaking: false } });
  return { list: await svc.list('studio_default'), preview };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const list = await defaultPromptScripts();
  fs.mkdirSync(path.dirname(PROMPT_SCRIPTS_JSON), { recursive: true });
  fs.writeFileSync(PROMPT_SCRIPTS_JSON, JSON.stringify(list, null, 1) + '\n');
  console.log(`wrote ${list.scripts.length} scripts to ${PROMPT_SCRIPTS_JSON}`);
  fs.writeFileSync(MAC_FIXTURE_JSON, JSON.stringify(await macFixture()));
  console.log(`wrote the Mac fixture to ${MAC_FIXTURE_JSON}`);
}
