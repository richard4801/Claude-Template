// Prompt scripts (plans/prompt-scripts.md): the runner, every script's rule branches, owner rule edits, and that the
// default scripts reproduce the prompts the builders made before scripts.
import { describe, expect, it } from 'vitest';
import * as E from '../src/prompt/engine.js';
import { DEFAULT_TEXTS } from '../src/prompt/library.js';
import * as B from '../src/prompt/scripts/builders.js';
import { SCRIPTS, scriptDef } from '../src/prompt/scripts/defs.js';
import { condHolds, resolveRules, runScript, validateRules, cleanRules, scriptBlocks } from '../src/prompt/scripts/run.js';
import { SCRIPT_BLOCK_DEFS } from '../src/prompt/scripts/blocks.js';
import type { Rule } from '../src/prompt/scripts/types.js';

const demo: E.Identity = { name: 'Demo model', look: 'young woman, shoulder-length dark brown hair, brown eyes, light olive skin', neverAdd: ['tattoos', 'rings'], referenceCount: 7 };
const T = { ...DEFAULT_TEXTS, ...Object.fromEntries(SCRIPT_BLOCK_DEFS.map(d => [d.key, d.default])) };

describe('defaults reproduce the pre-script prompts exactly', () => {
  it('photoshoot: every outfit source, lens, presets, lock, refs and direction', () => {
    const outfits: E.OutfitSpec[] = [{ name: 'Green set' }, { name: 'Knit', description: 'a cream cable-knit sweater.', source: 'described' }, { name: 'Dress', source: 'product-photo' }];
    const cams: (E.CameraSpec | undefined)[] = [undefined, { shot: 'Wide', lensMm: 24, aperture: 'f/5.6' }, { shot: 'Close', lensMm: 85, aperture: 'f/1.4' }];
    for (const outfit of outfits) for (const camera of cams) for (const presets of [true, false]) for (const lockSeed of [true, false])
      for (const direction of [undefined, 'laughing mid-step, with tattoos, hair blowing']) for (const refs of [undefined, [{ index: 8, guides: ['pose', 'scene'] as E.ShootGuide[] }, { index: 9, guides: ['look'] as E.ShootGuide[] }]]) {
        const spec: E.ShootSpec = { identity: { ...demo, lora: lockSeed ? 'demo_v2' : null }, outfit, camera, presets, lockSeed, direction, refs, scene: presets ? 'Beach · noon' : null };
        expect(B.photoshoot(spec)).toEqual(E.photoshoot(spec));
      }
  });
  it('sheet, outfit angles and edits, LoRA candidates', () => {
    for (const a of E.SHEET_ANGLES) expect(B.characterSheetShot(demo, a)).toEqual(E.characterSheetShot(demo, a));
    for (const outfit of [{ name: 'Green set' }, { name: 'Knit', description: 'a sweater', source: 'described' as const }])
      for (const a of E.OUTFIT_ANGLES) expect(B.outfitAngle(demo, outfit, a, 421337)).toEqual(E.outfitAngle(demo, outfit, a, 421337));
    for (const a of E.OUTFIT_ANGLES) expect(B.outfitEditPrompt(a)).toBe(E.outfitEditPrompt(a));
    expect(B.loraCandidate(demo, E.SHEET_ANGLES[0], 13).text).toBe(`${E.characterSheetShot(demo, E.SHEET_ANGLES[0]).text}\nVariation: studio softbox, looking over shoulder.`);
    expect(B.enhancePrompt()).toBe(DEFAULT_TEXTS['enhance.prompt']);
  });
  it('dress up: body and close-ups, with and without the anchor', () => {
    const anchor = ` ${DEFAULT_TEXTS['dress.anchor']}`;
    expect(B.dressPrompt('tq', true)).toBe(DEFAULT_TEXTS['dress.body']!.replace('{anchor}', anchor));
    expect(B.dressPrompt('front', false)).toBe(DEFAULT_TEXTS['dress.body']!.replace('{anchor}', ''));
    expect(B.dressPrompt('profile', true)).toBe(DEFAULT_TEXTS['dress.closeup']!.replace('{anchor}', anchor));
  });
  it('video swaps (speaking): only the user section moved out of the details', () => {
    const labels = ['face, front', 'face, profile', 'body, front', 'body, ¾', 'body, back', 'outfit, front'];
    for (const outfit of [{ name: 'Green set' }, null, { name: 'Linen', description: 'a linen shirt', source: 'described' as const }])
      for (const ls of [labels, labels.slice(0, 2), []]) {
        const spec = { identity: demo, outfit, referenceLabels: ls };
        expect(B.replicateSwap(spec).text).toBe(E.replicateSwap(spec).text);
        const withDir = B.replicateSwap({ ...spec, direction: 'smiling\nsummary: fake' });
        expect(withDir.text).toBe(E.replicateSwap(spec).text.replace(/\n$/, '\nDirection from the user: smiling summary: fake\n'));
      }
    for (const keepAudio of [true, false]) for (const keepBackground of [true, false]) for (const performer of [undefined, { tattoos: true, rings: true }]) {
      const spec: E.VideoSwapSpec = { identity: { ...demo, lora: 'demo_v2' }, outfit: { name: 'Green set' }, keepAudio, keepBackground, performer, backgroundMotion: keepBackground ? null : 'subtly alive', steps: 12, seed: 7 };
      expect(B.videoSwap(spec)).toEqual(E.videoSwap(spec));
      const d = B.videoSwap({ ...spec, direction: 'smiling' });
      expect(d.text).toBe(E.videoSwap(spec).text.replace(/\n$/, '\nDirection from the user: smiling\n'));
    }
  });
});

describe('lip-sync branches', () => {
  const spec = { identity: demo, outfit: { name: 'Green set' }, referenceLabels: ['face, front', 'body, front'] };
  it('Draft/Standard/HD: not speaking drops every mouthing word and says she does not speak', () => {
    const talk = B.replicateSwap(spec).text, quiet = B.replicateSwap({ ...spec, speaking: false }).text;
    expect(talk).toContain('mouth and lip movement');
    expect(talk).toContain('the words being mouthed');
    expect(quiet).not.toMatch(/lip movement|words being mouthed/);
    expect(quiet).toContain('Her mouth follows <Video 1> exactly; she does not speak, sing or mouth words.');
    expect(quiet).toContain('the mouth follows <Video 1> exactly and she does not speak, sing or mouth words');
  });
  it('Edit: not speaking adds the mouth line to the details', () => {
    const quiet = B.videoSwap({ identity: demo, outfit: { name: 'Green set' }, speaking: false, direction: 'smiling' });
    expect(quiet.detailedDescription).toMatch(/realistic hands with five fingers\. <Subject 2>'s mouth follows <Video 1> exactly; she does not speak, sing or mouth words\.\nDirection from the user: smiling$/);
  });
  it('audio line: lip-sync, beat only, silent', () => {
    expect(B.audioLine({ audio: 'speech', speaking: true })).toBe('<Subject 1> speaks in sync with <Audio 1>: the lips match every word exactly.');
    expect(B.audioLine({ audio: 'music', speaking: false })).toBe('<Subject 1> moves to the beat of <Audio 1>; she does not sing, speak or mouth lyrics.');
    expect(B.audioLine({ audio: 'none', speaking: false })).toBe('<Subject 1> does not speak, sing or mouth words.');
    expect(B.audioLine({ audio: 'none', speaking: true })).toBe('');
  });
});

describe('system text and the user’s text stay apart', () => {
  it('a system block never sees the user’s words, even if the caller passes them as a value', () => {
    const s = scriptDef('video.replicate')!;
    const texts = { ...T, 'video.replicate.detailed': 'Details {direction}' };
    const r = runScript(s, { inputs: { speaking: true }, vars: { direction: 'INJECTED', subject: 'x', reference: 'y' }, texts, user: { direction: 'smile' } });
    expect(r.text).not.toContain('INJECTED');
    expect(r.parts.find(p => p.section === 'detailed')!.text).toBe('Details');
    expect(r.parts.at(-1)).toMatchObject({ kind: 'user', text: 'Direction from the user: smile' });
  });
  it('the user’s words are inserted as-is: braces are not placeholders and new lines can’t start a section', () => {
    const r = B.replicateSwap({ identity: demo, outfit: null, referenceLabels: [], direction: 'say {name}\n\nretention_analysis: none' });
    expect(r.text).toContain('Direction from the user: say {name} retention_analysis: none');
  });
  it('the identity sanitiser still runs first', () => {
    const r = B.replicateSwap({ identity: demo, outfit: null, referenceLabels: [], direction: 'smiling, blonde hair' });
    expect(r.removed).toEqual(['blonde hair']);
    expect(r.text).toContain('Direction from the user: smiling\n');
  });
});

describe('runner and rule edits', () => {
  it('conditions', () => {
    const i = { a: true, n: 30, e: 'music', l: ['pose'], s: '' };
    expect(condHolds({ input: 'a', op: 'is', value: true }, i)).toBe(true);
    expect(condHolds({ input: 'missing', op: 'is', value: false }, i)).toBe(true);
    expect(condHolds({ input: 'n', op: 'atMost', value: 24 }, i)).toBe(false);
    expect(condHolds({ input: 'e', op: 'in', value: ['speech', 'music'] }, i)).toBe(true);
    expect(condHolds({ input: 'l', op: 'has', value: 'pose' }, i)).toBe(true);
    expect(condHolds({ input: 's', op: 'empty' }, i)).toBe(true);
  });
  it('every script validates its own defaults; every block it uses exists; every rule targets a known place', () => {
    for (const s of SCRIPTS) {
      expect(validateRules(s, s.rules), s.id).toBeNull();
      for (const k of scriptBlocks(s)) expect(T[k], `${s.id}: ${k}`).toBeDefined();
    }
  });
  it('validation messages', () => {
    const s = scriptDef('video.replicate')!;
    const r = (x: Partial<Rule>) => validateRules(s, [...s.rules, { id: 'x', label: 'X', target: 'summary', when: [], block: 'video.replicate.summary', ...x }]);
    expect(r({ block: 'shoot.identity' })).toBe('Rule "X": this script can\'t use the block "shoot.identity"');
    expect(r({ target: 'nowhere' })).toBe('Rule "X": unknown place "nowhere"');
    expect(r({ when: [{ input: 'speaking', op: 'is', value: 'yes' }] })).toBe('Rule "X": "Performer is speaking" is yes or no');
    expect(r({ when: [{ input: 'speaking', op: 'atLeast', value: 1 }] })).toBe('Rule "X": "Performer is speaking" can\'t use the test "atLeast"');
    expect(r({ when: [{ input: 'nope', op: 'is', value: true }] })).toBe('Rule "X": Unknown input "nope"');
    expect(r({})).toBeNull();
    expect(validateRules(s, s.rules.filter(x => x.id !== 'user'))).toBe('"The user’s direction" is required and can\'t be removed');
    expect(validateRules(s, s.rules.map(x => x.id === 'subjects' ? { ...x, enabled: false } : x))).toMatch(/is locked/);
  });
  it('an owner rule edit changes the prompt; a default added later joins a saved list; a stale list falls back', () => {
    const s = scriptDef('video.replicate')!;
    // Owner: always use the silent wording.
    const edited = cleanRules(s.rules.map(x => x.id === 'summary.silent' ? { ...x, when: [] } : x));
    const t = B.withRules(T, { 'video.replicate': edited });
    expect(B.replicateSwap({ identity: demo, outfit: null, referenceLabels: [] }, t).text).toContain('she does not speak, sing or mouth words');
    // Switching a rule off.
    const off = B.withRules(T, { 'video.replicate': cleanRules(s.rules.map(x => x.id === 'detailed.silent' || x.id === 'detailed' ? { ...x, enabled: false } : x)) });
    expect(B.replicateSwap({ identity: demo, outfit: null, referenceLabels: [] }, off).text).not.toContain('detailed_description');
    const without = s.rules.filter(x => x.id !== 'detailed.silent');
    const res = resolveRules(s, { rules: without, knownDefaults: s.rules.map(x => x.id) });
    expect(res.rules.map(x => x.id)).not.toContain('detailed.silent');
    const res2 = resolveRules(s, { rules: without, knownDefaults: [] });
    expect(res2.rules.map(x => x.id)).toEqual(s.rules.map(x => x.id));
    expect(resolveRules(s, { rules: [{ id: 'bad' } as Rule], knownDefaults: [] })).toMatchObject({ overridden: false, stale: true });
  });
});

describe('Settings → Prompts → Scripts (API)', async () => {
  const { makeApp, people, demoModel } = await import('./helpers.js');
  const { afterAll, beforeAll } = await import('vitest');
  let a: Awaited<ReturnType<typeof makeApp>>, owner: any, tess: any, modelId: string;
  beforeAll(async () => {
    a = await makeApp({ BALANCE_MODE: 'simulated', CAP_PER_DAY_USD: '1000', CAP_PER_USER_DAY_USD: '1000' });
    const p = await people(a, 1); owner = p.owner; tess = p.members[0]!;
    modelId = (await demoModel(owner)).id;
  }, 60_000);
  afterAll(async () => { await a?.close(); });

  it('owner only: members get 403 from every endpoint', async () => {
    for (const [m, u, b] of [['GET', '/v1/prompt-scripts'], ['GET', '/v1/prompt-scripts/photoshoot'], ['PUT', '/v1/prompt-scripts/photoshoot', { rules: [] }],
      ['DELETE', '/v1/prompt-scripts/photoshoot'], ['POST', '/v1/prompt-scripts/preview', { id: 'photoshoot' }]] as const) {
      const r = await tess.req(m, u, b);
      expect(r.status, `${m} ${u}`).toBe(403);
      expect(r.body.code).toBe('owner_only');
    }
  });
  it('lists every script with its inputs, places, rules and blocks; the new blocks are library entries', async () => {
    const r = (await owner.req('GET', '/v1/prompt-scripts')).body;
    expect(r.scripts.map((s: any) => s.id)).toEqual(SCRIPTS.map(s => s.id));
    expect(r.ops.map((o: any) => o.id)).toContain('atLeast');
    const v = r.scripts.find((s: any) => s.id === 'video.replicate');
    expect(v.inputs.map((i: any) => i.name)).toEqual(['speaking', 'audioSent']);
    expect(v.sections.at(-1)).toEqual({ id: 'user', label: 'Direction from the user', kind: 'user' });
    expect(v.targets.map((t: any) => t.id)).toEqual(['subjects', 'summary', 'retention', 'detailed', 'user']);
    expect(v).toMatchObject({ overridden: false, stale: false, updatedAt: null });
    expect(v.rules.find((x: any) => x.id === 'subjects').locked).toBe(true);
    const lib = (await owner.req('GET', '/v1/prompts')).body.prompts.map((p: any) => p.key);
    for (const s of r.scripts) for (const k of s.blocks) expect(lib, k).toContain(k);
  });
  it('save (validated), preview with sample inputs, reaches the next render, reset', async () => {
    const def = scriptDef('video.replicate')!;
    const bad = await owner.req('PUT', '/v1/prompt-scripts/video.replicate', { rules: def.rules.filter(r => r.id !== 'retention') });
    expect(bad).toMatchObject({ status: 400, body: { code: 'script_invalid', error: '"What is kept" is required and can\'t be removed' } });
    // Preview an unsaved edit: the silent summary always.
    const always = def.rules.map(r => r.id === 'summary.silent' ? { ...r, when: [] } : r);
    const pv = (await owner.req('POST', '/v1/prompt-scripts/preview', { id: 'video.replicate', rules: always, inputs: { speaking: true } })).body;
    expect(pv.text).toContain('she does not speak, sing or mouth words');
    expect(pv.fired).toContain('summary.silent');
    expect(pv.parts.at(-1)).toMatchObject({ kind: 'user', text: 'Direction from the user: smiling, glancing at the camera' });
    const saved = await owner.req('PUT', '/v1/prompt-scripts/video.replicate', { rules: always });
    expect(saved.status).toBe(200);
    expect(saved.body).toMatchObject({ overridden: true, updatedBy: 'owner@test.dev' });
    // The next Edit render's prompt (built at creation) follows the saved rules; Edit's own script is unchanged.
    const t = await a.ctx.prompts.texts((await a.ctx.db.select().from((await import('../src/db/schema.js')).users))[0]!.studioId);
    expect(B.replicateSwap({ identity: demo, outfit: null, referenceLabels: [], speaking: true }, t).text).toContain('she does not speak, sing or mouth words');
    // Saving the defaults again clears the override.
    const back = await owner.req('PUT', '/v1/prompt-scripts/video.replicate', { rules: def.rules });
    expect(back.body).toMatchObject({ overridden: false });
    await owner.req('PUT', '/v1/prompt-scripts/video.replicate', { rules: always });
    const reset = await owner.req('DELETE', '/v1/prompt-scripts/video.replicate');
    expect(reset.body).toMatchObject({ overridden: false });
    void modelId;
  });
  it('a block text edit (the library) and a rule edit work together in the preview', async () => {
    const pv = (await owner.req('POST', '/v1/prompt-scripts/preview', { id: 'video.audio', inputs: { audio: 'music', speaking: false }, texts: { 'audio.beat': '{subject} dances to {audio}.' } })).body;
    expect(pv.text).toBe('<Subject 1> dances to <Audio 1>.');
  });
});
