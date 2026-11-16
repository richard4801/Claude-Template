// The Edit pipeline skill (editor/pipelineSkill.ts): versioning and rollback, small vs big, scoring and promotion, the
// core budget, dedupe, taste folding, template hints, owner-only access, and the tools/prompt wiring. No money.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { users } from '../src/db/schema.js';
import type { AuthUser } from '../src/ctx.js';
import { editSessions } from '../src/editor/schema.js';
import { playbookRules } from '../src/editor/learnSchema.js';
import { registryByName } from '../src/claude/registry.js';
import { threadBrief } from '../src/camera/claude.js';
import { EDIT_PROMPT } from '../src/recreate/assistant.js';
import {
  applyChange, classify, fileSeed, pipelineOf, SEED_EVIDENCE, contradicts, coreRules, failingRun, PIPELINE_LIMITS, PROVEN_AFTER, rescore, seedSnapshot, similarity, skillFiles,
  type Change, type Page, type Snapshot,
} from '../src/editor/pipelineSkill.js';
import { makeApp, people, sql, type Client } from './helpers.js';

const snap = (o: Partial<Snapshot> = {}): Snapshot => ({ ...seedSnapshot(), core: '# Core\n- Cut on the strong beats\n- Captions sit above the lower third\n\n## Learned\n', ...o });
const page = (o: Partial<Page> = {}): Page => ({ name: 'whip-pan', title: 'Whip pan between shots', body: 'Use a 0.2 s whip pan between two moving shots, direction matching the motion.',
  evidence: [], score: 0, status: 'trial', createdAt: 0, updatedAt: 0, ...o });
const ch = (o: Partial<Change> & { op: Change['op'] }): Change => ({ why: 'test', ...o });

describe('pipeline skill (unit)', () => {
  it('similarity and contradiction', () => {
    expect(similarity('Cut on the strong beats', 'cut on the strong beats')).toBe(1);
    expect(similarity('Cut on the strong beats', 'Captions sit above the lower third')).toBeLessThan(0.2);
    expect(contradicts('Never cut on the strong beats', 'Cut on the strong beats')).toBe(true);
    expect(contradicts('Make the intro cuts slower', 'Make the intro cuts faster')).toBe(true);
    expect(contradicts('Cut on the strong beats', 'Captions sit above the lower third')).toBe(false);
    expect(contradicts('Cut on the strong beats', 'Cut on the strong beats in the chorus')).toBe(false);
  });

  it('small vs big: adds and evidence are small; changing core rules, retiring/deleting pages, touching house style, editing proven pages are big', () => {
    const s = snap({ pages: [page(), page({ name: 'glow', title: 'Soft glow', body: 'Bloom 0.3 on highlights', status: 'proven' })],
      houseStyle: [{ id: 'hs_1', text: 'Avoid: “too fast” (the intro)', sentiment: 'dislike', evidence: [] }] });
    expect(classify(s, ch({ op: 'core_add', text: 'Hold the first shot at least 1.2 s' })).kind).toBe('small');
    expect(classify(s, ch({ op: 'page_add', name: 'flash-cut', title: 'Flash cut', body: 'A 2-frame white flash on the drop' })).kind).toBe('small');
    expect(classify(s, ch({ op: 'page_evidence', name: 'whip-pan', result: 'worked' })).kind).toBe('small');
    expect(classify(s, ch({ op: 'page_edit', name: 'whip-pan', body: 'Use a 0.25 s whip' })).kind).toBe('small');
    expect(classify(s, ch({ op: 'style_add', text: 'Owner likes warm skin tones' })).kind).toBe('small');
    for (const c of [ch({ op: 'core_edit', line: 'Cut on the strong beats', text: 'Cut on every beat' }), ch({ op: 'core_remove', line: 'Cut on the strong beats' }),
      ch({ op: 'page_delete', name: 'whip-pan' }), ch({ op: 'page_retire', name: 'whip-pan' }), ch({ op: 'style_edit', id: 'hs_1', text: 'x' }), ch({ op: 'style_remove', id: 'hs_1' }),
      ch({ op: 'page_edit', name: 'glow', body: 'Bloom 0.5' })])
      expect(classify(s, c).kind, c.op).toBe('big');
  });

  it('drift guard: a change that contradicts a core rule, a proven page or house style is big', () => {
    const s = snap({ pages: [page({ name: 'glow', title: 'Soft glow on highlights', body: 'Add bloom on the highlights at 0.3', status: 'proven' })] });
    expect(classify(s, ch({ op: 'core_add', text: 'Never cut on the strong beats' }))).toMatchObject({ kind: 'big', reason: expect.stringContaining('core rule') });
    expect(classify(s, ch({ op: 'page_add', name: 'no-glow', title: 'Plain highlights', body: 'Never add bloom on the highlights' }))).toMatchObject({ kind: 'big', reason: expect.stringContaining('proven') });
    expect(classify(s, ch({ op: 'style_add', text: 'Owner likes a new font', contradicts: 'the core' })).kind).toBe('big');
  });

  it('dedupe: near-identical lessons are skipped; a page name that exists becomes an edit', () => {
    const s = snap({ pages: [page()], houseStyle: [{ id: 'hs_1', text: 'Owner likes warm skin tones', sentiment: 'like', evidence: [] }] });
    expect(classify(s, ch({ op: 'core_add', text: 'Cut on the strong beats.' })).kind).toBe('skip');
    expect(classify(s, ch({ op: 'page_add', name: 'whip-2', title: 'Whip pans', body: 'Use a 0.2 s whip pan between two moving shots, direction matching the motion' })).kind).toBe('skip');
    expect(classify(s, ch({ op: 'style_add', text: 'owner likes warm skin tones' })).kind).toBe('skip');
    expect(classify(s, ch({ op: 'page_add', name: 'whip-pan', title: 'x', body: 'Shorter whip' }))).toMatchObject({ kind: 'convert', to: { op: 'page_edit' } });
  });

  it('core budget: a rule that would overflow the core goes to a page; nothing can push the core over', () => {
    const full = snap({ core: `# Core\n${'- a long rule about something particular in the edit\n'.repeat(Math.floor((PIPELINE_LIMITS.coreChars - 40) / 53))}## Learned\n` });
    expect(full.core.length).toBeLessThanOrEqual(PIPELINE_LIMITS.coreChars);
    const k = classify(full, ch({ op: 'core_add', text: 'Hold the hero shot for two full bars before the first cut lands' }));
    expect(k).toMatchObject({ kind: 'convert', to: { op: 'page_add', body: 'Hold the hero shot for two full bars before the first cut lands' } });
    expect(() => applyChange(full, ch({ op: 'core_add', text: 'Hold the hero shot for two full bars before the first cut lands' }))).toThrow(/budget/);
  });

  it('scoring: one vote per edit; proven after PROVEN_AFTER edits; failing twice in a row is a retire candidate', () => {
    let s = snap({ pages: [page()] });
    const vote = (editId: string, result: 'worked' | 'failed') => { s = applyChange(s, ch({ op: 'page_evidence', name: 'whip-pan', result, editId })).snapshot; return s.pages[0]!; };
    vote('es_1', 'worked'); vote('es_1', 'worked'); vote('es_1', 'worked');
    expect(s.pages[0]).toMatchObject({ status: 'trial', score: 1 }); // the same edit three times is one vote
    vote('es_2', 'worked');
    expect(vote('es_3', 'worked')).toMatchObject({ status: 'proven', score: PROVEN_AFTER });
    vote('es_4', 'failed');
    expect(failingRun(s.pages[0]!)).toBe(false);
    expect(vote('es_5', 'failed')).toMatchObject({ status: 'proven', score: 1 });
    expect(failingRun(s.pages[0]!)).toBe(true);
    expect(rescore(page({ evidence: [{ editId: 'a', result: 'failed', note: '', at: 0 }] }))).toMatchObject({ score: -1, status: 'trial' });
  });

  it('core rules and skill files', () => {
    expect(coreRules(snap().core)).toEqual(['Cut on the strong beats', 'Captions sit above the lower third']);
    const files = skillFiles(snap({ pages: [page(), page({ name: 'old', title: 'Old', status: 'retired' })], houseStyle: [{ id: 'h', text: 'Owner likes warm', sentiment: 'like', evidence: [] }] }), 7);
    expect(files.map(f => f.path)).toEqual(['SKILL.md', 'reference/house-style.md', 'reference/whip-pan.md']);
    expect(files[0]!.text).toMatch(/^---\nname: muse-edit-pipeline\n/);
    expect(files[0]!.text).toContain('House style');
    expect(files[0]!.text).toContain('reference/whip-pan.md');
  });

  it('the Edit prompt and the Mac edit brief carry the pipeline (short)', () => {
    expect(EDIT_PROMPT).toContain('pipeline_skill_read');
    expect(EDIT_PROMPT).toContain('pipeline_propose');
    const line = EDIT_PROMPT.split('\n').find(l => l.startsWith('Edit pipeline skill'))!;
    expect(line.length).toBeLessThan(400);
    expect(threadBrief('edit', 'es_x')!.tools).toEqual(expect.arrayContaining(['pipeline_skill_read', 'pipeline_log', 'pipeline_taste', 'pipeline_propose']));
    for (const n of ['pipeline_skill_read', 'pipeline_log', 'pipeline_taste', 'pipeline_propose']) expect(registryByName.get(n)?.members, n).toBe(false);
  });
});

describe('pipeline skill (service, tools and routes)', () => {
  type A = Awaited<ReturnType<typeof makeApp>>;
  let a: A, owner: Client, member: Client, ownerU: AuthUser, memberU: AuthUser, studioId: string;
  const run = (name: string, u: AuthUser, args: Record<string, unknown>) => registryByName.get(name)!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, args) as Promise<any>;
  const edit = async (id: string) => { await a.ctx.db.insert(editSessions).values({ id, studioId, ownerId: owner.id, takeId: 'take_x', project: {}, updatedBy: owner.id, createdAt: Date.now(), updatedAt: Date.now() }); return id; };

  beforeAll(async () => {
    a = await makeApp();
    ({ owner, members: [member] } = await people(a, 1) as any);
    studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    const u = async (c: Client, role: 'owner' | 'member'): Promise<AuthUser> => { const [x] = await a.ctx.db.select().from(users).where(eq(users.id, c.id)); return { id: x!.id, studioId, email: x!.email, role, studioName: 'S', sessionId: null }; };
    ownerU = await u(owner, 'owner'); memberU = await u(member, 'member');
    // These flows start from the short placeholder; the real version 1 (the Icon edit's files) has its own test.
    pipelineOf(a.ctx).seed = () => ({ snapshot: seedSnapshot(), line: 'placeholder' });
  });
  afterAll(async () => { await a?.close?.(); });

  it('owner only: members are refused by every tool and route; other studios\' edits are not found', async () => {
    const es = await edit('es_member1');
    await expect(run('pipeline_skill_read', memberU, {})).rejects.toMatchObject({ status: 403 });
    await expect(run('pipeline_log', memberU, { editId: es, entry: { tried: 'x', result: 'note' } })).rejects.toMatchObject({ status: 403 });
    await expect(run('pipeline_taste', memberU, { editId: es, reaction: 'nice' })).rejects.toMatchObject({ status: 403 });
    await expect(run('pipeline_propose', memberU, { editId: es })).rejects.toMatchObject({ status: 403 });
    for (const [m, p] of [['GET', '/v1/pipeline-skill'], ['GET', '/v1/pipeline-skill/versions'], ['POST', '/v1/pipeline-skill/undo'], ['GET', '/v1/pipeline-skill/pending'], ['PUT', '/v1/pipeline-skill']] as const)
      expect((await member.req(m, p, m === 'GET' ? undefined : {})).status, p).toBe(403);
    await expect(run('pipeline_log', { ...ownerU, studioId: 'st_other' }, { editId: es, entry: { tried: 'x', result: 'note' } })).rejects.toMatchObject({ status: 404 });
  });

  it('first read seeds the placeholder core (version 1); pages are read on demand', async () => {
    const r = await run('pipeline_skill_read', ownerU, {});
    expect(r).toMatchObject({ version: 1, pages: [], houseStyle: [] });
    expect(r.core).toContain('MUSE Edit Pipeline');
    await expect(run('pipeline_skill_read', ownerU, { page: 'nope' })).rejects.toMatchObject({ status: 404 });
  });

  it('a full edit: log, taste, propose → small changes apply as a new version, big ones wait; secrets are redacted', async () => {
    const es = await edit('es_flow1');
    await run('pipeline_log', ownerU, { sessionId: es, entry: { tried: 'Whip pan at 0.2 s between shots 2 and 3', result: 'worked', why: 'motion matched', settings: { durationSec: 0.2, apiKey: 'sk-ant-abcdefghijklmnop1234567890' }, ms: 1200 } });
    await run('pipeline_log', ownerU, { editId: es, entry: { tried: 'Glitch on the drop', result: 'failed', why: 'too noisy' } });
    await expect(run('pipeline_log', ownerU, { editId: es, entry: { tried: 'x', result: 'maybe' } })).rejects.toMatchObject({ status: 400 });
    expect((await run('pipeline_taste', ownerU, { editId: es, reaction: 'too fast', context: 'the intro cuts' }))).toMatchObject({ sentiment: 'dislike' });
    await run('pipeline_taste', ownerU, { editId: es, reaction: 'love this transition', context: 'whip pan' });

    const draft = await run('pipeline_propose', ownerU, { editId: es });
    expect(draft.log).toHaveLength(2);
    expect(JSON.stringify(draft.log)).not.toContain('sk-ant-abcdefghijklmnop');
    expect(draft.reactions.map((r: any) => r.reaction)).toEqual(['too fast', 'love this transition']);
    expect(draft.next).toContain('changes');

    const res = await run('pipeline_propose', ownerU, { editId: es, changes: [
      { op: 'page_add', name: 'whip-pan', title: 'Whip pan between moving shots', body: 'A 0.2 s whip pan, direction matching the motion.', why: 'worked in this edit' },
      { op: 'core_add', text: 'Keep the intro cuts at least 0.8 s apart', why: 'owner said too fast', reactionIds: [] },
      { op: 'core_remove', line: 'Watch and listen before you judge timing, pacing or sound.', why: 'testing' },
      { op: 'core_add', text: 'Start from get_edit; change the edit in small undoable steps and say what each one does.', why: 'dup' },
    ] });
    expect(res.applied.map((x: any) => x.op)).toEqual(['page_add', 'core_add', 'style_add', 'style_add']);
    expect(res.pending).toEqual([expect.objectContaining({ op: 'core_remove', reason: 'changes a core rule', before: expect.stringContaining('Watch and listen') })]);
    expect(res.skipped).toEqual([expect.objectContaining({ op: 'core_add', reason: expect.stringContaining('already in the core') })]);
    expect(res.folded).toBe(2);
    expect(res.version).toBe(2);
    expect(res.summary).toBe('Updated the edit pipeline: 4 small changes, 1 waiting for you');

    const st = (await owner.req('GET', '/v1/pipeline-skill')).body;
    expect(st).toMatchObject({ version: 2, coreBudget: PIPELINE_LIMITS.coreChars, pages: [expect.objectContaining({ name: 'whip-pan', status: 'trial' })] });
    expect(st.houseStyle.map((e: any) => e.text)).toEqual(['Avoid: “too fast” (the intro cuts)', 'Owner likes: “love this transition” (whip pan)']);
    expect(st.core).toContain('- Keep the intro cuts at least 0.8 s apart');
    expect(st.pending).toHaveLength(1);

    // proposing again for the same edit: reactions are already folded, the big change isn't asked twice
    const again = await run('pipeline_propose', ownerU, { editId: es, changes: [{ op: 'core_remove', line: 'Watch and listen before you judge timing, pacing or sound.', why: 'testing' }] });
    expect(again).toMatchObject({ applied: [], folded: 0, version: 2 });
    expect(again.pending[0].id).toBe(st.pending[0].id);
  });

  it('approve / decline a big change; changelog and diff; rollback and undo make new versions and keep the old ones', async () => {
    const pend = (await owner.req('GET', '/v1/pipeline-skill/pending')).body;
    const ok = (await owner.req('POST', `/v1/pipeline-skill/pending/${pend[0].id}/approve`)).body;
    expect(ok).toMatchObject({ status: 'approved', version: 3 });
    expect((await owner.req('POST', `/v1/pipeline-skill/pending/${pend[0].id}/approve`)).status).toBe(409);
    expect((await owner.req('GET', '/v1/pipeline-skill')).body.core).not.toContain('Watch and listen');
    const diff = (await owner.req('GET', '/v1/pipeline-skill/versions/3/diff')).body;
    expect(diff.changes).toEqual([expect.objectContaining({ section: 'core', before: expect.stringContaining('Watch and listen'), after: expect.not.stringContaining('Watch and listen') })]);
    expect(diff.changelog[0]).toMatchObject({ kind: 'big', why: expect.stringContaining('approved by the owner') });

    const vs = (await owner.req('GET', '/v1/pipeline-skill/versions')).body;
    expect(vs.map((v: any) => v.version)).toEqual([3, 2, 1]);
    expect(vs[1].changelog.length).toBe(4);
    expect(vs[1].changelog[0]).toMatchObject({ kind: 'small', editId: 'es_flow1' });

    const rb = (await owner.req('POST', '/v1/pipeline-skill/rollback', { version: 1 })).body;
    expect(rb).toMatchObject({ version: 4, rolledBackTo: 1, changed: true });
    const now = (await owner.req('GET', '/v1/pipeline-skill')).body;
    expect(now).toMatchObject({ version: 4, pages: [], houseStyle: [] });
    expect(now.core).toContain('Watch and listen');
    expect((await owner.req('GET', '/v1/pipeline-skill/versions/2')).body.snapshot.pages[0].name).toBe('whip-pan'); // old versions are kept
    const undo = (await owner.req('POST', '/v1/pipeline-skill/undo')).body;
    expect(undo).toMatchObject({ version: 5, rolledBackTo: 3 });
    expect((await owner.req('GET', '/v1/pipeline-skill')).body.pages[0].name).toBe('whip-pan');
    expect((await owner.req('POST', '/v1/pipeline-skill/rollback', { version: 99 })).status).toBe(404);

    // decline: nothing changes
    const es = await edit('es_flow2');
    const r = await run('pipeline_propose', ownerU, { editId: es, changes: [{ op: 'page_delete', name: 'whip-pan', why: 'not needed' }] });
    const no = (await owner.req('POST', `/v1/pipeline-skill/pending/${r.pending[0].id}/decline`)).body;
    expect(no).toMatchObject({ status: 'declined' });
    expect((await owner.req('GET', '/v1/pipeline-skill')).body.pages[0].name).toBe('whip-pan');
  });

  it('scoring through edits: logged techniques vote once per edit, promotion to proven, template hint, repeated failures propose retiring', async () => {
    for (const id of ['es_s1', 'es_s2', 'es_s3']) {
      await edit(id);
      await run('pipeline_log', ownerU, { editId: id, entry: { tried: 'whip pan', result: 'worked', technique: 'whip-pan' } });
      await run('pipeline_log', ownerU, { editId: id, entry: { tried: 'whip pan again', result: 'worked', technique: 'whip-pan' } });
      const r = await run('pipeline_propose', ownerU, { editId: id, changes: id === 'es_s3' ? [{ op: 'page_edit', name: 'whip-pan', repeatable: true, why: 'same move every time' }] : [] });
      expect(r.applied.some((x: any) => x.op === 'page_evidence')).toBe(true);
    }
    let st = (await owner.req('GET', '/v1/pipeline-skill')).body;
    expect(st.pages[0]).toMatchObject({ name: 'whip-pan', status: 'proven', score: 3, uses: 3, repeatable: true });
    expect(st.templateHints).toEqual([expect.objectContaining({ name: 'whip-pan' })]);
    // a proven page: editing it is big now
    const e4 = await edit('es_s4');
    const big = await run('pipeline_propose', ownerU, { editId: e4, changes: [{ op: 'page_edit', name: 'whip-pan', body: 'Use 0.3 s', why: 'x' }] });
    expect(big.pending[0]).toMatchObject({ op: 'page_edit', reason: 'changes a proven technique' });
    expect(big.summary).toContain('could be a template');
    for (const id of ['es_f1', 'es_f2']) {
      await edit(id);
      await run('pipeline_log', ownerU, { editId: id, entry: { tried: 'whip pan', result: 'failed', why: 'jarring', technique: 'whip-pan' } });
      const r = await run('pipeline_propose', ownerU, { editId: id, changes: [] });
      if (id === 'es_f2') expect(r.pending).toEqual(expect.arrayContaining([expect.objectContaining({ op: 'page_retire', target: 'page whip-pan' })]));
    }
    st = (await owner.req('GET', '/v1/pipeline-skill')).body;
    expect(st.pages[0]).toMatchObject({ status: 'proven', score: 1 });
    expect(st.pending.filter((p: any) => p.op === 'page_retire')).toHaveLength(1);
  });

  it('taste folding: a repeated reaction adds evidence to its entry; a reaction already in memory is not copied; Claude can phrase one', async () => {
    const es = await edit('es_t1');
    await run('pipeline_taste', ownerU, { editId: es, reaction: 'too fast', context: 'the intro cuts' });
    const before = (await owner.req('GET', '/v1/pipeline-skill')).body;
    const r = await run('pipeline_propose', ownerU, { editId: es, changes: [] });
    expect(r.folded).toBe(1);
    const after = (await owner.req('GET', '/v1/pipeline-skill')).body;
    expect(after.houseStyle.length).toBe(before.houseStyle.length);
    expect(after.houseStyle.find((e: any) => e.text.includes('too fast')).times).toBe(2);

    await a.ctx.db.insert(playbookRules).values({ id: 'rule_mem1', studioId, text: 'No lens flares ever', area: 'look', source: 'owner', pinned: true, evidence: [], createdAt: 1, updatedAt: 1 });
    const es2 = await edit('es_t2');
    const t1 = await run('pipeline_taste', ownerU, { editId: es2, reaction: 'no lens flares ever' });
    const t2 = await run('pipeline_taste', ownerU, { editId: es2, reaction: 'yes the colour pops', context: 'the grade' });
    const r2 = await run('pipeline_propose', ownerU, { editId: es2, changes: [{ op: 'style_add', text: 'Saturated, punchy grade on product shots', why: 'owner reaction', reactionIds: [t2.recorded], sentiment: 'like' }] });
    expect(r2.folded).toBe(2);
    const st = (await owner.req('GET', '/v1/pipeline-skill')).body;
    expect(st.houseStyle.map((e: any) => e.text)).toContain('Saturated, punchy grade on product shots');
    expect(st.houseStyle.some((e: any) => /lens flare/i.test(e.text))).toBe(false);
    expect(t1.recorded).toBeTypeOf('number');
  });

  it('a chat gets the "Updated the edit pipeline" card when Claude proposes from it', async () => {
    const chat = (await owner.req('POST', '/v1/claude/chats', {})).body;
    const es = await edit('es_card1');
    const r = await run('pipeline_propose', ownerU, { editId: es, chatId: chat.id, changes: [
      { op: 'page_add', name: 'speed-ramp-drop', title: 'Speed ramp into the drop', body: 'Ramp 1x to 0.4x over the last beat before the drop.', why: 'owner loved it' },
      { op: 'core_remove', line: 'Step one', why: 'not needed' }] });
    expect(r.summary).toMatch(/^Updated the edit pipeline: 1 small change, 1 waiting for you/);
    const msgs = (await a.ctx.db.execute(sql`select tool from claude_messages where thread_id = ${chat.id}`) as any).rows.map((x: any) => x.tool);
    expect(msgs).toEqual([expect.objectContaining({ name: 'pipeline_update', summary: r.summary, ui: expect.objectContaining({ small: 1, big: 1, summary: r.summary }) })]);
  });

  it('the owner writes content (core within budget, pages); the skill files follow the version', async () => {
    expect((await owner.req('PUT', '/v1/pipeline-skill', { core: 'x'.repeat(PIPELINE_LIMITS.coreChars + 1) })).status).toBe(400);
    const w = (await owner.req('PUT', '/v1/pipeline-skill', { core: '# Pipeline\n- Step one\n', pages: [{ name: 'beat-cuts', title: 'Beat cuts', body: 'Cut on the downbeat.', status: 'proven' }], note: 'brief v1' })).body;
    const files = (await owner.req('GET', '/v1/pipeline-skill/skill-files')).body;
    expect(files.version).toBe(w.version);
    expect(files.files.map((f: any) => f.path)).toEqual(expect.arrayContaining(['SKILL.md', 'reference/beat-cuts.md', 'reference/whip-pan.md']));
    const vs = (await owner.req('GET', '/v1/pipeline-skill/versions')).body;
    expect(vs[0].changelog[0]).toMatchObject({ kind: 'owner', why: 'brief v1' });
  });
});

describe('pipeline skill · version 1 from the Icon edit (assets/pipeline-skill)', () => {
  it('the files: the core within budget without its front matter, 13 pages by file name, house-style.md as house style', () => {
    const f = fileSeed()!;
    expect(f.core.length).toBeLessThanOrEqual(PIPELINE_LIMITS.coreChars);
    expect(f.core.startsWith('# MUSE Edit Pipeline (core)')).toBe(true);
    expect(f.pages.map(p => p.name)).toEqual(['checking', 'comic-page', 'cutouts', 'entrance-wash', 'eye-lens', 'hits', 'lyrics', 'muse-mechanics', 'shell', 'sound', 'sources', 'timing', 'windows-panels']);
    for (const p of f.pages) {
      expect(p.title.length, p.name).toBeLessThanOrEqual(PIPELINE_LIMITS.titleChars);
      expect(p.body.length, p.name).toBeGreaterThan(50);
      expect(p.evidence).toEqual([expect.objectContaining({ editId: SEED_EVIDENCE.editId, revision: 166, result: 'worked' })]);
    }
    expect(f.pages.find(p => p.name === 'cutouts')!.status).toBe('proven'); // "→ page `cutouts` [proven]"
    expect(f.pages.find(p => p.name === 'lyrics')!.status).toBe('trial');
    expect(f.houseStyle.length).toBeGreaterThanOrEqual(5);
    expect(f.houseStyle.some(e => e.text.startsWith('These edits are cut like comics'))).toBe(true);
  });

  it('a new studio starts at version 1 with that content; the house-style page reads; the skill files carry it', async () => {
    const a = await makeApp();
    try {
      const { owner } = await people(a, 0) as any;
      const r = (await owner.req('GET', '/v1/pipeline-skill')).body;
      expect(r).toMatchObject({ version: 1 });
      expect(r.pages).toHaveLength(13);
      const [x] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
      const u: AuthUser = { id: x!.id, studioId: x!.studioId, email: x!.email, role: 'owner', studioName: 'S', sessionId: null };
      const run = (name: string, args: Record<string, unknown>) => registryByName.get(name)!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, args) as Promise<any>;
      expect((await run('pipeline_skill_read', {})).core).toContain('## Order of work');
      expect((await run('pipeline_skill_read', { page: 'house-style' })).page.body).toContain('cut like comics');
      expect((await run('pipeline_skill_read', { page: 'hits' })).page).toMatchObject({ name: 'hits', status: 'trial' });
      const files = (await owner.req('GET', '/v1/pipeline-skill/skill-files')).body.files.map((f: any) => f.path);
      expect(files).toEqual(expect.arrayContaining(['SKILL.md', 'reference/cutouts.md', 'reference/house-style.md']));
      expect((await owner.req('GET', '/v1/pipeline-skill/versions')).body[0].changelog[0].what).toContain('Icon edit');
    } finally { await a.close(); }
  });
});
