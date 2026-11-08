// Recreate this edit · shot briefs written on the server (workstream 1, gap G8; owner decision). Opt-in and paid: the
// price first, then a confirmed run; gated by the owner's Claude API switch, the AI editing switch and the daily cap.
// A fake client stands in for the Claude API: no calls, no spend.
import { eq, sql } from 'drizzle-orm';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { editorJobs } from '../src/editor/schema.js';
import type { Recipe } from '../src/recreate/analyze.js';
import { BRIEF_SYSTEM, briefFacts, briefsOf, briefUsd, cleanBriefs, expectedTokens, type BriefClient } from '../src/recreate/briefs.js';
import { recreateReferences } from '../src/recreate/schema.js';
import { makeApp, people, type Client } from './helpers.js';

const cam = (motion: any) => ({ motion, shake: 0, keys: [{ t: 0, x: 0, y: 0, scale: 1 }], confidence: 0.6 });
const speed = { ramp: 'none' as const, curve: [{ t: 0, speed: 1 }], confidence: 0.5 };
const slot = (id: string, i: number, a: number, b: number, motion = 'static') => ({ id, index: i, startSec: a, endSec: b, durationSec: b - a, keyframeSec: (a + b) / 2, confidence: 0.9, brief: null,
  rig: { moves: [] }, camera: cam(motion), speed, peaks: [], pose: { status: 'pending' as const } });
const RECIPE = {
  schema: 'muse.recipe/1', analyzer: { version: 'test', tookMs: 0 }, origin: 'reference',
  source: { durationSec: 4, width: 1080, height: 1920, fps: 30, aspect: '9:16', hasAudio: true },
  sound: { bpm: 120, beats: [], strong: [], confidence: 0.7 }, pacing: { shots: 2, avgShotSec: 2, cutsPerMin: 30, energy: { everySec: 0.5, values: [0] } },
  slots: [slot('s1', 0, 0, 2, 'pan'), slot('s2', 1, 2, 4)],
  transitions: [{ atSec: 2, kind: 'crossfade', durationSec: 0.4, confidence: 0.7, from: 's1', to: 's2' }],
  text: [{ id: 'x1', startSec: 2.2, endSec: 3.5, box: { x: 0.1, y: 0.7, w: 0.8, h: 0.07 }, words: 'SUMMER', sizeFrac: 0.04, color: '#FFFFFF', fontId: 'sans', animIn: 'cut', animOut: 'cut', confidence: 0.8 }],
  grade: { swatches: [], contrast: 0.5, saturation: 0.1, warmth: 0, look: null, grade: null }, gaps: [], contactSheet: null,
} as unknown as Recipe;

describe('shot briefs (unit)', () => {
  it('the facts per shot, the expected tokens and the price (cost × markup, at least a cent)', () => {
    const f = briefFacts(RECIPE);
    expect(f).toMatch(/^9:16 · 4\.0 s · 2 shots · 120 bpm/);
    expect(f).toMatch(/s1 \(1\) · 0\.00–2\.00 s · camera pan/);
    expect(f).toMatch(/s2 \(2\) · 2\.00–4\.00 s · camera static · comes in with a crossfade · on-screen text "SUMMER"/);
    const t = expectedTokens(RECIPE, { width: 1000, height: 236 });
    expect(t).toEqual({ input: 1100 + 140 + Math.ceil(1000 * 236 / 750), output: 120 + 300 });
    expect(expectedTokens(RECIPE, { width: 3136, height: 400 }).input).toBe(1240 + Math.ceil(1568 * 200 / 750)); // sized down like the API does
    expect(briefUsd('claude-sonnet-5-5', { input: 1_000_000, output: 100_000 }, 2)).toBe(6); // ($2 + $1) × 2
    expect(briefUsd('claude-sonnet-5-5', { input: 10, output: 10 }, 2)).toBe(0.01);
    expect(BRIEF_SYSTEM).toMatch(/never by name/);
  });
  it('keeps what the briefs accept: bad fields, unknown shots and odd tags are dropped, not the run', () => {
    const out = cleanBriefs(RECIPE, { slots: { s1: { shotSize: 'mcu', angle: 'sideways', subject: ' she ', action: '' }, s9: { subject: 'x' }, s2: 'nope' },
      summary: '  A summer walk  ', tags: ['Summer', 'summer', 'golden hour', '#bad', 7] });
    expect(out).toEqual({ slots: { s1: { shotSize: 'mcu', subject: 'she' } }, summary: 'A summer walk', tags: ['summer', 'golden hour'] });
  });
});

describe('shot briefs on the server (fake client)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, ownerUser: AuthUser, refId: string;
  const calls: Record<string, any>[] = [];
  let reply: (p: Record<string, any>) => any = () => ({
    content: [{ type: 'tool_use', name: 'write_briefs', input: { slots: { s1: { shotSize: 'ms', angle: 'eye', subject: 'she', action: 'walks past the camera', location: 'a sunny street' },
      s2: { shotSize: 'cu', subject: 'her face', action: 'smiles' } }, summary: 'A summer walk with a smile to camera', tags: ['summer', 'walk'] } }],
    usage: { input_tokens: 2000, output_tokens: 400 }, stop_reason: 'tool_use' });
  const fake: BriefClient = { messages: { create: async p => { calls.push(p); return reply(p); } } };
  const wallet = async () => (await owner.req('GET', '/v1/wallet')).body;

  beforeAll(async () => {
    a = await makeApp({});
    ({ owner } = await people(a, 0, { topUp: 100 }) as any);
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    refId = 'rx_briefs';
    const sheet = await sharp({ create: { width: 400, height: 236, channels: 3, background: '#808080' } }).png().toBuffer();
    await a.ctx.storage.put(`rx/${studioId}/${refId}/contact.png`, sheet, 'image/png');
    await a.ctx.db.insert(recreateReferences).values({ id: refId, studioId, userId: owner.id, name: 'Summer walk', state: 'ready', progress: 1, phase: 'Ready', recipe: RECIPE,
      contactSheetKey: `rx/${studioId}/${refId}/contact.png`, createdAt: Date.now(), expiresAt: Date.now() + 86_400_000 });
    briefsOf(a.ctx).setClient(fake);
  });
  afterAll(async () => { await a?.close(); });

  it('off until the owner turns on Claude on the server; the price is shown either way and nothing is held', async () => {
    const e = (await owner.req('POST', `/v1/recreate/references/${refId}/briefs/estimate`, {})).body;
    expect(e).toMatchObject({ available: false, slots: 2 });
    expect(e.reason).toMatch(/Settings → Claude/);
    expect(e.label).toMatch(/^Write the shot briefs · about \$\d+\.\d\d$/);
    expect(e.estimateUsd).toBe(briefUsd('claude-sonnet-5-5', expectedTokens(RECIPE, { width: 400, height: 236 }), 2));
    expect(JSON.stringify(e)).not.toMatch(/sonnet|claude-|anthropic/i); // the model isn't named to the app
    const w = (await owner.req('POST', `/v1/recreate/references/${refId}/briefs/write`, { confirm: true }));
    expect([w.status, w.body.code]).toEqual([503, 'briefs_unavailable']);
    expect(calls).toHaveLength(0);
    expect((await wallet()).heldTokens).toBe(0);
  });

  it('confirmed: one call with the sheet and the facts; the briefs, summary and tags are saved; charged the actual cost × 2', async () => {
    expect((await owner.req('PATCH', '/v1/claude/settings', { apiFallback: true })).status).toBe(200);
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/briefs/estimate`, {})).body.available).toBe(true);
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/briefs/write`, {})).status).toBe(400); // confirm first
    const before = await wallet();
    const r = await owner.req('POST', `/v1/recreate/references/${refId}/briefs/write`, { confirm: true });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(calls).toHaveLength(1);
    const p = calls[0]!;
    expect(p).toMatchObject({ model: 'claude-sonnet-5-5', tool_choice: { type: 'tool', name: 'write_briefs' }, system: BRIEF_SYSTEM });
    expect(p.messages[0].content[0]).toMatchObject({ type: 'image', source: { type: 'base64', media_type: 'image/png' } });
    expect(p.messages[0].content[1].text).toMatch(/s2 \(2\) · 2\.00–4\.00 s/);
    expect(p.thinking).toBeUndefined(); // a forced tool call
    const cost = briefUsd('claude-sonnet-5-5', { input: 2000, output: 400 }, 2);
    expect(r.body).toMatchObject({ written: ['s1', 's2'], costUsd: cost });
    const ref = (await owner.req('GET', `/v1/recreate/references/${refId}`)).body;
    expect(ref.recipe.slots[0].brief).toEqual({ shotSize: 'ms', angle: 'eye', subject: 'she', action: 'walks past the camera', location: 'a sunny street' });
    expect(ref.recipe.slots[0].rig).toMatchObject({ shotSize: 'ms', height: 'eye' });
    expect(ref.recipe).toMatchObject({ summary: 'A summer walk with a smile to camera', tags: ['summer', 'walk'] });
    expect((await wallet()).heldTokens).toBe(before.heldTokens); // the hold is settled
    const [row] = await a.ctx.db.select().from(editorJobs).where(eq(editorJobs.kind, 'briefs'));
    expect(row).toMatchObject({ state: 'done', cost, models: ['claude-sonnet-5-5'] });
    // In the day's AI editing spend, but not in the editor's job list.
    expect((await owner.req('GET', '/v1/editor/settings')).body.todayUsd).toBeCloseTo(cost, 4);
    expect((await owner.req('GET', '/v1/editor/jobs')).body.some((j: any) => j.kind === 'briefs')).toBe(false);
  });

  it('the AI editing switch and the daily cap apply; a failed call is refunded', async () => {
    expect((await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'off' })).status).toBe(200);
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/briefs/write`, { confirm: true })).body.code).toBe('editor_paid_off');
    await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'on', capPerDayUsd: 0.001 });
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/briefs/write`, { confirm: true })).body.code).toBe('editor_daily_cap');
    await owner.req('PATCH', '/v1/editor/settings', { capPerDayUsd: null });
    const n = calls.length;
    reply = () => ({ content: [{ type: 'text', text: 'Sorry' }], usage: { input_tokens: 10, output_tokens: 5 }, stop_reason: 'end_turn' });
    const r = await owner.req('POST', `/v1/recreate/references/${refId}/briefs/write`, { confirm: true });
    expect([r.status, r.body.code]).toEqual([502, 'briefs_failed']);
    expect(calls.length).toBe(n + 1);
    expect((await wallet()).heldTokens).toBe(0); // released
    const rows = await a.ctx.db.select().from(editorJobs).where(eq(editorJobs.kind, 'briefs'));
    expect(rows.map(x => [x.state, x.cost]).sort()).toEqual([['done', briefUsd('claude-sonnet-5-5', { input: 2000, output: 400 }, 2)], ['failed', 0]]);
    expect(ownerUser.role).toBe('owner');
  });
});
