// The Android app's demo copy of GET /v1/prompt-scripts (android/app/src/main/resources/prompt_scripts.json) is current.
// Regenerate with: npx tsx scripts/gen-prompt-scripts.ts
import fs from 'node:fs';
import { describe, expect, it } from 'vitest';
import { defaultPromptScripts, MAC_FIXTURE_JSON, macFixture, PROMPT_SCRIPTS_JSON } from '../scripts/gen-prompt-scripts.js';

describe('prompt scripts fixture', () => {
  it("the app's demo copy of the scripts is current", async () => {
    const shipped = JSON.parse(fs.readFileSync(PROMPT_SCRIPTS_JSON, 'utf8'));
    expect(shipped).toEqual(JSON.parse(JSON.stringify(await defaultPromptScripts())));
  });
  it("the Mac's test fixture (list + a not-speaking video preview) is current", async () => {
    const shipped = JSON.parse(fs.readFileSync(MAC_FIXTURE_JSON, 'utf8'));
    expect(shipped).toEqual(JSON.parse(JSON.stringify(await macFixture())));
  });
});
