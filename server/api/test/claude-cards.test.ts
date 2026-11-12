// Claude panel cards (owner's chosen chat reference, 2026-11-12; claude/cards.ts): plan, clip, "What I changed" with
// Undo, and Approve with price lines that add up to the Total. Plain text stays plain; cards are tool lines.
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { balance, breakdownOf, chipsFor, draftChanges, publicCard, undoDraft, type ChangesCard } from '../src/claude/cards.js';
import { approveCard } from '../src/claude/actions.js';
import { controlWords, stepOf } from '../src/claude/uiControl.js';
import { registryByName } from '../src/claude/registry.js';
import { shotBreakdown } from '../src/suite/breakdown.js';
import { suiteOptions } from '../src/suite/assist.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

const sum = (l: { usd: number }[]) => Math.round(l.reduce((a, x) => a + x.usd, 0) * 100) / 100;

describe('cards (unit)', () => {
  it('price lines always add up to the total; zero lines are dropped', () => {
    const l = balance([{ label: 'Video', usd: 0.3333 }, { label: 'Pictures', usd: 0.3333 }, { label: 'Nothing', usd: 0 }], 0.67);
    expect(l.map(x => x.label)).toEqual(['Video', 'Pictures']);
    expect(sum(l)).toBe(0.67);
    expect(balance([], 1)).toEqual([]);
  });
  it('a shot\'s breakdown: the video at its rate, the paid pictures, the voice separation; sums to the estimate', () => {
    const b = shotBreakdown({ perSec: 0.066, billedPerTake: 15, extraPerTake: 0.18, takes: 1, separationUsd: 0, estimate: 1.17, modelId: 'nope' });
    expect(b.totalUsd).toBe(1.17);
    expect(b.lines[0]!.label).toBe('Video, 15 s at $0.066/s');
    expect(b.lines[0]!.usd).toBe(0.99);
    expect(sum(b.lines)).toBe(1.17);
    const two = shotBreakdown({ perSec: 0.1, billedPerTake: 5, extraPerTake: 0, takes: 2, separationUsd: 0.05, estimate: 1.05, modelId: 'nope' });
    expect(two.lines.map(x => x.label)).toEqual(['Video, 2 takes × 5 s at $0.10/s', 'Taking the voice out of the music']);
    expect(sum(two.lines)).toBe(1.05);
    expect(breakdownOf({ estimate: { breakdown: b } })).toEqual(b);
    expect(breakdownOf({ estimateUsd: 1 })).toBeNull();
  });
  it('the Approve card: the button\'s words as its title, the lines and Total, Approve / Decline', () => {
    const c = approveCard('ca_1', 'spend', { summary: 'Run a queued AI Suite shot', method: 'POST', url: '/x', priceUsd: 1.17, title: 'Generate · 15 s · $1.17',
      breakdown: { lines: [{ label: 'Video, 15 s at $0.066/s', usd: 0.99 }, { label: '2 reference images past the 5 included', usd: 0.18 }], totalUsd: 1.17 } });
    expect(c).toMatchObject({ kind: 'approve', title: 'Generate · 15 s · $1.17', subtitle: 'Run a queued AI Suite shot', totalUsd: 1.17, answer: { actionId: 'ca_1' }, approveLabel: 'Approve', declineLabel: 'Decline' });
    expect(c.lines).toHaveLength(2);
    // No breakdown from the screen: one line, the summary at the price.
    expect(approveCard('ca_2', 'delete', { summary: 'Delete the take', method: 'DELETE', url: '/x' })).toMatchObject({ title: 'Delete the take', lines: [], approveLabel: 'Delete' });
    expect(approveCard('ca_3', 'spend', { summary: 'Upscale the take to 4K', method: 'POST', url: '/x', priceUsd: 0.4 }).lines).toEqual([{ label: 'Upscale the take to 4K', usd: 0.4 }]);
  });
  it('"What I changed" rows say what changed in the person\'s words, and each Undo puts back only its part', () => {
    const before = { tool: 'swap', background: 'keep', outfitId: 'of_a', tokens: [{ t: 'mention', kind: 'character', id: 'm1', label: 'Ava' }, { t: 'text', text: ' walks in' }], rig: { lighting: 'window' } };
    const after = { tool: 'swap', background: 'describe', outfitId: 'of_b', tokens: [{ t: 'mention', kind: 'character', id: 'm1', label: 'Ava' }, { t: 'text', text: ' walks in at dusk' }, { t: 'move', id: 'dolly_in', label: 'Dolly in' }],
      rig: { lighting: 'window', focalMm: 35 }, screen: { anything: 1 } };
    const rows = draftChanges('sa_1', before, after, { outfit: id => (id === 'of_b' ? 'Hoodie' : 'Dress') });
    expect(rows.map(r => `${r.what} → ${r.to}`)).toEqual(['Prompt → “walks in at dusk”', 'Movement → Dolly in', 'Outfit → Hoodie', 'Focal length → 35 mm', 'Background → Describe it']);
    // Undo the outfit after a later change elsewhere: only the outfit goes back.
    const later = { ...after, duration: 8 };
    const outfitUndo = undoDraft(later, rows.find(r => r.what === 'Outfit')!.undo!);
    expect(outfitUndo).toMatchObject({ outfitId: 'of_a', background: 'describe', duration: 8 });
    // Undo the move: the words stay as Claude left them.
    const moveUndo = undoDraft(later, rows.find(r => r.what === 'Movement')!.undo!);
    expect((moveUndo.tokens as any[]).map(t => t.t)).toEqual(['mention', 'text']);
    expect((moveUndo.tokens as any[])[1].text).toBe(' walks in at dusk');
    // New Swap toggles, one row each.
    const x = draftChanges('sa_1', { tool: 'remix', remix: { background: { mode: 'describe', words: 'a beach' } } },
      { tool: 'remix', remix: { background: { mode: 'describe', words: 'a beach' }, outfit: { kind: 'words', words: 'a grey hoodie' } } });
    expect(x.map(r => `${r.what} → ${r.to}`)).toEqual(['Outfit → A grey hoodie']);
    expect(undoDraft({ tool: 'remix', remix: { background: { mode: 'describe', words: 'a beach' }, outfit: { kind: 'words', words: 'a grey hoodie' } } }, x[0]!.undo!))
      .toEqual({ tool: 'remix', remix: { background: { mode: 'describe', words: 'a beach' } } });
    expect(draftChanges('sa_1', before, { ...before, screen: { x: 1 } })).toEqual([]);
  });
  it('the app sees the rows, never the before-values', () => {
    const card: ChangesCard = { kind: 'changes', title: 'What I changed', rows: [{ what: 'Outfit', to: 'Hoodie', undo: { kind: 'draft', assistId: 'sa', before: { outfitId: 'of_a' } } }] };
    expect(JSON.stringify(publicCard(card))).not.toContain('of_a');
    expect((publicCard(card) as any).rows[0]).toEqual({ what: 'Outfit', to: 'Hoodie', undoable: true });
  });
  it('chips fit the page; the activity strip\'s steps read as words', () => {
    expect(chipsFor('suite', 'remix').map(c => c.label)).toEqual(['Watch my clip', 'Write the prompt', 'Check the price']);
    expect(chipsFor('edit').length).toBe(3);
    expect(chipsFor(undefined).length).toBe(3);
    expect(controlWords('suite.swap.outfitPicker')).toBe('outfit picker');
    expect(stepOf('act', { action: 'select', target: 'suite.tool', value: 'Swap' })).toBe('Choosing Swap…');
    expect(stepOf('act', { action: 'press', target: 'Open outfit' })).toBe('Pressing open outfit…');
    expect(stepOf('act', { action: 'set_text', target: 'suite.prompt' })).toBe('Typing in prompt…');
    expect(stepOf('snapshot', {})).toBe('Looking at the window…');
  });
});

describe('cards in a chat (Suite, mock provider)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, ownerU: AuthUser, assistId: string, chatId: string, model: { id: string };
  const run = (name: string, args: Record<string, unknown>, u: AuthUser = ownerU) => registryByName.get(name)!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, args) as Promise<any>;
  const cards = async () => ((await owner.req('GET', `/v1/claude/chats/${chatId}`)).body.messages as any[]).filter(m => m.tool?.name === 'card');
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    ownerU = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    model = await demoModel(owner) as any;
    assistId = (await owner.req('POST', '/v1/suite/assist', {})).body.id;
    chatId = (await owner.req('POST', '/v1/claude/chats', { title: 'Cards' })).body.id;
  });
  afterAll(async () => { await a?.close(); });

  it('suite_set_draft puts "What I changed" in the chat; Undo puts the row back, once', async () => {
    const o = suiteOptions();
    await run('suite_set_draft', { assistId, chatId, modelId: model.id, prompt: 'She walks out into golden light.' });
    await run('suite_set_draft', { assistId, chatId, duration: 8, rig: { lighting: o.lighting[0]!.id } });
    const list = await cards();
    expect(list).toHaveLength(2);
    const last = list.at(-1)!;
    expect(last.tool.ui.card.kind).toBe('changes');
    expect(last.tool.ui.card.rows.map((r: any) => r.what)).toEqual(['Lighting', 'Length']);
    expect(last.tool.ui.full).toBeUndefined(); // before-values stay on the server
    const row = last.tool.ui.card.rows.findIndex((r: any) => r.what === 'Length');
    const u = await owner.req('POST', `/v1/claude/cards/${last.id}/undo`, { row });
    expect(u.status, JSON.stringify(u.body)).toBe(200);
    expect(u.body.card.rows[row]).toMatchObject({ undone: true });
    const d = (await owner.req('GET', `/v1/suite/assist/${assistId}`)).body.draft;
    expect(d.duration).toBe(5); // back
    expect(d.rig.lighting).toBe(o.lighting[0]!.id); // the other row stays
    expect((await owner.req('POST', `/v1/claude/cards/${last.id}/undo`, { row })).status).toBe(409);
    expect((await member.req('POST', `/v1/claude/cards/${last.id}/undo`, { row: 0 })).status).toBe(404); // not theirs
  });

  it('suite_request_shot puts an Approve card with lines that add up to the Total; the estimate carries the breakdown', async () => {
    const e = await run('suite_estimate', { assistId });
    expect(e.estimate.breakdown.totalUsd).toBe(e.estimate.estimate);
    expect(sum(e.estimate.breakdown.lines)).toBe(e.estimate.estimate);
    const ask = await run('suite_request_shot', { assistId, chatId, confirm: true });
    const card = (await cards()).at(-1)!.tool.ui.card;
    expect(card).toMatchObject({ kind: 'approve', answer: { assistId, pendingId: ask.pendingId }, approveLabel: 'Approve', declineLabel: 'Decline' });
    expect(card.title).toMatch(/^Generate · /);
    expect(sum(card.lines)).toBe(card.totalUsd);
  });

  it('show_plan ticks steps in place; show_clip needs a video of the studio', async () => {
    await run('show_plan', { chatId, planId: 'swap', title: 'Plan: outfit swap', steps: [{ text: 'Watch the clip' }, { text: 'Swap the outfit' }, { text: 'Render a preview' }] });
    const n = (await cards()).length;
    const r = await run('show_plan', { chatId, planId: 'swap', done: [0, 1] });
    expect(r).toMatchObject({ updated: true, done: 2, of: 3 });
    const all = await cards();
    expect(all).toHaveLength(n); // the same card, updated
    expect(all.at(-1)!.tool.ui.card.steps.map((s: any) => s.done)).toEqual([true, true, false]);
    await expect(run('show_plan', { chatId, planId: 'other' })).rejects.toMatchObject({ code: 'bad_request' });
    await expect(run('show_clip', { chatId, id: 'take_nope', moments: [{ from: 0, label: 'Start' }] })).rejects.toBeTruthy();
    await expect(run('show_plan', { chatId, steps: [{ text: 'x' }] }, { ...ownerU, id: 'someone_else' })).rejects.toBeTruthy();
  });

  it('chips come from the server per page', async () => {
    expect((await owner.req('GET', '/v1/claude/chips?page=suite&tool=swap')).body.chips.map((c: any) => c.label)).toEqual(['Watch my clip', 'Write the prompt', 'Check the price']);
    expect((await owner.req('GET', '/v1/claude/chips?page=nowhere')).status).toBe(400);
  });
});
