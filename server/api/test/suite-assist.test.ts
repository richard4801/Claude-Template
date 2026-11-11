// Claude in the AI Suite (workstream 1): the shared composer draft, Claude's tools (visible options only), the live
// draft, the owner's approval before anything generates, and the API fallback loop. Mock video provider and a fake
// Claude client: no money, no API calls.
import { execFileSync } from 'node:child_process';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { outfits, users } from '../src/db/schema.js';
import { assistantOf } from '../src/recreate/assistant.js';
import { cameraOf, checkVisibleRig, promptText, requestOf, suiteOptions } from '../src/suite/assist.js';
import { APERTURES, FOCAL_STEPS, FOCALS } from '../src/suite/camera.js';
import { PROMPT_SKILL, SKILL_FILE, SUITE_PROMPT, SUITE_TOOLS } from '../src/suite/mcpTools.js';
import { threadBrief } from '../src/camera/claude.js';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { suiteAssists } from '../src/suite/schema.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); return true; } catch { return false; } })();
const tool = (n: string) => SUITE_TOOLS.find(t => t.name === n)!;

describe('Suite assist (unit)', () => {
  it('the options are only the ones members see; a hidden one is refused, naming the visible ones', () => {
    const o = suiteOptions();
    const hidden = APERTURES.filter(x => x.visible === false).map(x => x.id);
    expect(hidden.length).toBeGreaterThan(0);
    for (const h of hidden) expect(o.camera.aperture.some(x => x.id === h)).toBe(false);
    expect(o.camera.focalMm.map(f => f.mm)).toEqual(FOCAL_STEPS.map(f => f.mm));
    expect(() => checkVisibleRig({ aperture: hidden[0]! } as any)).toThrow(/rig.aperture: .* isn't offered · one of /);
    const offFocal = FOCALS.find(mm => !FOCAL_STEPS.some(f => f.mm === mm));
    if (offFocal) expect(() => checkVisibleRig({ focalMm: offFocal })).toThrow(/rig.focalMm/);
    expect(checkVisibleRig({ aperture: o.camera.aperture[0]!.id, focalMm: FOCAL_STEPS[0]!.mm } as any)).toBeTruthy();
  });
  it('the draft becomes the request the composers send: @model first, #moves into camera.move/mix, rows only when set', () => {
    const toks = [{ t: 'mention', kind: 'character', id: 'm1', label: 'Zelphira', key: 1 }, { t: 'text', text: ' walks out to the street , smiling ' },
      { t: 'move', id: 'dolly_in', label: 'Dolly in', category: 'dolly', intensity: 40, key: 2 }] as any;
    expect(promptText(toks)).toBe('Zelphira walks out to the street, smiling');
    expect(cameraOf({}, [])).toBeUndefined();
    expect(cameraOf({ body: 'film_35', focalMm: 85, height: 'low', lighting: 'contre_jour', palette: 'golden_warmth', genre: 'fashion' } as any, [{ id: 'dolly_in', intensity: 0.4 }])).toEqual({
      mode: 'preset', rig: { body: 'film_35', focalMm: 85 }, lighting: { preset: 'contre_jour' }, palette: { preset: 'golden_warmth' }, move: { id: 'dolly_in', intensity: 0.4 },
      angle: { height: 'low' }, style: { genre: 'fashion' } });
    const r = requestOf({ v: 1, tool: 'shot', quality: 'standard', aspect: '16:9', duration: 6, takes: 2, sound: false, rig: { stock: 'kodak_portra', gradeLook: false }, tokens: toks } as any);
    expect(r).toMatchObject({ modelId: 'm1', prompt: 'Zelphira walks out to the street, smiling', quality: 'standard', aspectRatio: '16:9', duration: 6, takes: 2, audio: false, gradeLook: false,
      camera: { rig: { look: 'kodak_portra' }, move: { id: 'dolly_in', intensity: 0.4 } } });
  });
});

describe('Suite brief follows the owner\'s prompt skill (workstream 1)', () => {
  it('the suite brief and the API prompt carry the skeleton, the rig, the lengths, consistency and output rules', () => {
    const brief = threadBrief('suite', 'sa_x') as { prompt: string; tools: string[] };
    expect(brief.prompt).toBe(SUITE_PROMPT);
    for (const h of ['## 3. The prompt skeleton', '## 4. The rig', '## 5. Lengths and formats', '## 6. Consistency rules', '## 7. Output',
      'SUBJECT —', 'LOCATION —', 'ACTION —', 'SHOT 1 (0:00', 'STYLE —', 'CONSTRAINTS —']) expect(brief.prompt).toContain(h);
    expect(brief.prompt).not.toContain('## 8.');
    expect(brief.prompt).not.toMatch(/suite_generate/);
    for (const t of brief.tools) expect(SUITE_TOOLS.some(x => x.name === t)).toBe(true);
    expect(PROMPT_SKILL).toMatch(/suite_request_shot/);
  });
  it('the server copy is the repo skill, and the skill\'s apertures are the ones the composer shows', () => {
    const repo = path.resolve(path.dirname(SKILL_FILE), '../../../../.claude/skills/muse-prompt-structure/SKILL.md');
    if (existsSync(repo)) expect(readFileSync(SKILL_FILE, 'utf8')).toBe(readFileSync(repo, 'utf8'));
    const listed = PROMPT_SKILL.match(/\*\*Aperture:\*\* \*\*(.+?) only\.\*\*/)![1]!.split(' · ');
    expect(listed.sort()).toEqual(suiteOptions().camera.aperture.map(a => a.label).sort());
  });
});

describe.skipIf(!hasFfmpeg)('Claude in the AI Suite (mock provider, fake Claude)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, ownerUser: AuthUser, model: { id: string; name: string }, assistId: string;
  const env = () => ({ ctx: a.ctx, user: ownerUser, source: 'mcp' as const });
  const events: any[] = [];
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10', ANTHROPIC_API_KEY: 'test-not-a-real-key' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    model = await demoModel(owner) as any;
    a.ctx.hub.subscribe(studioId, owner.id, line => { if (line.startsWith('data: ')) { const e = JSON.parse(line.slice(6)); if (e.type === 'suiteAssist') events.push(e); } }, 'owner');
  });
  afterAll(async () => { await a?.close(); });

  it('a shared draft and a "suite" thread with the brief Claude on the Mac starts from', async () => {
    const c = await owner.req('POST', '/v1/suite/assist', {});
    expect(c.status, JSON.stringify(c.body)).toBe(200);
    expect(c.body).toMatchObject({ draft: { tool: 'shot', quality: 'draft', aspect: '9:16', duration: 5 }, revision: 1, pending: [], warnings: [] });
    assistId = c.body.id;
    const t = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'suite', contextId: assistId })).body;
    expect(t).toMatchObject({ contextKind: 'suite', contextId: assistId, brief: { assistId, tools: expect.arrayContaining(['suite_options', 'suite_set_draft', 'suite_request_shot']) } });
    expect(t.brief.prompt).toMatch(/only the ids it lists/);
    expect((await owner.req('POST', '/v1/claude/threads', { contextKind: 'suite', contextId: 'sa_nope' })).status).toBe(404);
    expect((await member.req('GET', `/v1/suite/assist/${assistId}`)).status).toBe(404); // the owner's own
  });

  it('Claude sets up the composer: model, prompt, a visible rig and a move; the app hears it live; hidden options are refused', async () => {
    const o = suiteOptions();
    const rig = { body: o.camera.body[0]!.id, focalMm: o.camera.focalMm.at(-1)!.mm, aperture: o.camera.aperture[0]!.id, height: o.camera.height[0]!.id, lighting: o.lighting[0]!.id };
    events.length = 0;
    const v = await tool('suite_set_draft').run(env(), { assistId, modelId: model.id, prompt: 'She walks out of the café into golden light.', rig, moves: [{ id: 'dolly_in', intensity: 0.4 }], quality: 'draft', duration: 5 }) as any;
    expect(v.request).toMatchObject({ modelId: model.id, quality: 'draft', duration: 5, camera: { rig: { body: rig.body, focalMm: rig.focalMm, aperture: rig.aperture }, angle: { height: rig.height }, lighting: { preset: rig.lighting }, move: { id: 'dolly_in', intensity: 0.4 } } });
    expect(v.request.prompt).toBe(`${model.name} She walks out of the café into golden light.`);
    expect(Array.isArray(v.warnings)).toBe(true);
    expect(v.revision).toBe(2);
    expect(v.draft.tokens[0]).toMatchObject({ t: 'mention', kind: 'character', id: model.id });
    expect(v.draft.tokens.at(-1)).toMatchObject({ t: 'move', id: 'dolly_in', intensity: 40 });
    expect(events.at(-1)).toMatchObject({ type: 'suiteAssist', assist: { id: assistId, revision: 2 } }); // the composer updates live
    const hidden = APERTURES.find(x => x.visible === false)!.id;
    await expect(tool('suite_set_draft').run(env(), { assistId, rig: { aperture: hidden } })).rejects.toThrow(/isn't offered/);
    // The owner's own edit reaches Claude; an edit from an old revision is refused.
    const g = (await owner.req('GET', `/v1/suite/assist/${assistId}`)).body;
    const edited = await owner.req('PATCH', `/v1/suite/assist/${assistId}`, { draft: { ...g.draft, duration: 6 }, baseRevision: g.revision });
    expect(edited.body).toMatchObject({ revision: 3, request: { duration: 6 } });
    expect((await owner.req('PATCH', `/v1/suite/assist/${assistId}`, { draft: g.draft, baseRevision: g.revision })).body.code).toBe('stale');
    expect(((await tool('suite_get_draft').run(env(), { assistId })) as any).request.duration).toBe(6);
  });

  it('Claude sees the cast: outfit angles and her references as images; same-named outfits told apart by date', async () => {
    const mk = (id: string, at: number) => ({ id, studioId: ownerUser.studioId, modelId: model.id, name: 'Product look', mode: 'describe', description: 'A red silk slip dress', angles: [{ asset: 'g_front' }, { asset: 'g_tq' }, null, { asset: 'g_back' }], state: 'ready', createdAt: at });
    await a.ctx.db.insert(outfits).values([mk('of_old', Date.UTC(2026, 9, 1)), mk('of_new', Date.UTC(2026, 10, 10))]);
    const c = await tool('suite_cast').run(env(), {}) as any;
    expect(c.cast[0].outfits.map((o: any) => [o.id, o.created, o.sameNameAsAnother])).toEqual([['of_new', '2026-11-10 00:00 UTC', true], ['of_old', '2026-10-01 00:00 UTC', true]]);
    expect(c.mcpContent.filter((b: any) => b.type === 'image')).toHaveLength(3); // her face + each outfit's front
    const set = await tool('suite_set_draft').run(env(), { assistId, outfitId: 'of_old' }) as any;
    expect(set.request.outfitId).toBe('of_old');
    expect(set.mcpContent.filter((b: any) => b.type === 'image')).toHaveLength(3); // front, ¾, back
    expect(set.mcpContent.some((b: any) => b.type === 'text' && /outfit “Product look” \(2026-10-01 00:00 UTC\) · back/.test(b.text))).toBe(true);
    const see = await tool('suite_see').run(env(), { assistId }) as any;
    expect(see.structuredContent).toMatchObject({ model: { id: model.id }, outfit: { id: 'of_old', created: '2026-10-01 00:00 UTC' }, images: 10 }); // 7 references + 3 angles
    await tool('suite_set_draft').run(env(), { assistId, outfitId: null });
  });

  it('generating waits for the owner: the price first, then an approval in the app; yes runs it, never above that price', async () => {
    const e = await tool('suite_estimate').run(env(), { assistId }) as any;
    expect(e.estimate.ok).toBe(true);
    const priced = await tool('suite_request_shot').run(env(), { assistId }) as any;
    expect(priced).toMatchObject({ needsConfirmation: true });
    expect((await owner.req('GET', '/v1/jobs')).body).toHaveLength(0); // nothing ran
    const ask = await tool('suite_request_shot').run(env(), { assistId, confirm: true }) as any;
    expect(ask).toMatchObject({ waitingForOwner: true, estimateUsd: priced.estimateUsd });
    const v = (await owner.req('GET', `/v1/suite/assist/${assistId}`)).body;
    expect(v.pending).toEqual([expect.objectContaining({ id: ask.pendingId, kind: 'suite_request_shot', status: 'waiting', maxUsd: priced.estimateUsd })]);
    expect((await owner.req('GET', '/v1/jobs')).body).toHaveLength(0);
    // Declined: nothing runs.
    const ask2 = await tool('suite_request_shot').run(env(), { assistId, confirm: true }) as any;
    expect((await owner.req('POST', `/v1/suite/assist/${assistId}/pending/${ask2.pendingId}`, { approve: false })).body.status).toBe('declined');
    // A price that rose above the approved one is refused.
    const [row] = await a.ctx.db.select().from(suiteAssists).where(eq(suiteAssists.id, assistId));
    const pend = (row!.pending as any[]).map(p => (p.id === ask.pendingId ? { ...p, maxUsd: -1 } : p));
    await a.ctx.db.update(suiteAssists).set({ pending: pend }).where(eq(suiteAssists.id, assistId));
    const pc = await owner.req('POST', `/v1/suite/assist/${assistId}/pending/${ask.pendingId}`, { approve: true });
    expect([pc.status, pc.body.code]).toEqual([409, 'price_changed']);
    await a.ctx.db.update(suiteAssists).set({ pending: (row!.pending as any[]) }).where(eq(suiteAssists.id, assistId));
    // Yes: an ordinary Suite job with the draft, through the normal hold path.
    const yes = (await owner.req('POST', `/v1/suite/assist/${assistId}/pending/${ask.pendingId}`, { approve: true })).body;
    expect(yes).toMatchObject({ status: 'done', jobId: expect.any(String) });
    const job = await until(async () => { const j = await a.ctx.jobs.get(yes.jobId); return j?.state === 'done' || j?.state === 'failed' ? j : null; }, 30_000);
    expect(job.state).toBe('done');
    expect(job.request).toMatchObject({ engine: 'suite', seconds: 6 });
    expect(job.draft).toMatchObject({ tool: 'shot', duration: 6 });
    expect((await owner.req('POST', `/v1/suite/assist/${assistId}/pending/${ask.pendingId}`, { approve: true })).status).toBe(404); // answered once
    const f = await tool('suite_feed').run(env(), { limit: 5 }) as any;
    expect(f.items.length).toBeGreaterThan(0);
  }, 60_000);

  it('the API fallback runs the suite loop: the draft filled in, Claude\'s change reaches the composer', async () => {
    const t = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'suite', contextId: assistId })).body;
    await owner.req('PATCH', '/v1/claude/settings', { apiFallback: true });
    const replies = [{ tools: [{ name: 'suite_set_draft', input: { prompt: 'A slow turn to camera.', takes: 2 } }] }, { text: 'Set: a slow turn to camera, two takes.' }];
    const calls: any[] = []; let i = 0;
    assistantOf(a.ctx).setClient({ beta: { messages: { stream: (p: any) => {
      calls.push(structuredClone(p)); const r: any = replies[Math.min(i++, replies.length - 1)];
      const content = [...(r.text ? [{ type: 'text', text: r.text }] : []), ...(r.tools ?? []).map((x: any, k: number) => ({ type: 'tool_use', id: `tu_${i}_${k}`, name: x.name, input: x.input }))];
      return { on(_e: string, cb: (d: string) => void) { if (r.text) cb(r.text); return this; }, finalMessage: async () => ({ content, stop_reason: r.tools ? 'tool_use' : 'end_turn', usage: {} }) };
    } } } } as any);
    const r = await owner.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: 'Make it a slow turn to camera, two takes' });
    expect(r.status).toBe(200);
    expect(String(r.body)).toContain('"name":"suite_set_draft","status":"done"');
    const tools = calls[0].tools as { name: string; input_schema: { properties: Record<string, unknown> } }[];
    expect(tools.map(x => x.name).sort()).toEqual(['suite_add_reference', 'suite_cast', 'suite_estimate', 'suite_feed', 'suite_get_draft', 'suite_models', 'suite_options', 'suite_request_shot', 'suite_see', 'suite_set_draft']);
    expect(tools.find(x => x.name === 'suite_set_draft')!.input_schema.properties.assistId).toBeUndefined(); // the server fills it
    expect(calls[0].system[0].text).toMatch(/shot designer/);
    expect(calls[0].messages.at(-1).content.at(-1).text).toMatch(/^\[Suite shot sa_/);
    expect(calls[0].messages.at(-1).content.some((b: any) => b.type === 'image' && b.source.media_type === 'image/jpeg')).toBe(true); // her face, each turn
    expect((await owner.req('GET', `/v1/suite/assist/${assistId}`)).body.request).toMatchObject({ takes: 2, prompt: `${model.name} A slow turn to camera.` });
  });
});
