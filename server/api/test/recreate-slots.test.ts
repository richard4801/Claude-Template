// Recreate this edit, phase 3 (workstream 1): shot briefs, the slot matcher, filling a slot with a Suite shot (price
// first; the owner approves) and building the edit from the recipe. Mock video provider, no money.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { takes, users } from '../src/db/schema.js';
import * as M from '../src/editor/model.js';
import { FILTERS } from '../src/editor/presets.js';
import { LOOK_IDS } from '../src/editor/lookpack.js';
import { paletteIds } from '../src/editor/photo.js';
import { editSessionsOf } from '../src/editor/sessions.js';
import type { Recipe } from '../src/recreate/analyze.js';
import { buildProject, editorTransition } from '../src/recreate/assemble.js';
import { RECREATE_TOOLS } from '../src/recreate/mcpTools.js';
import { BriefSchema, matchSlots, scoreTake, shotRequestFor, withBriefs, type Candidate } from '../src/recreate/slots.js';
import { putObject } from '../src/storage/objects.js';
import { makeApp, people, until, type Client } from './helpers.js';
import { hasFfmpeg, makeReference } from './recreate-fixture.js';

const cam = (motion: any, keys = [{ t: 0, x: 0, y: 0, scale: 1 }]) => ({ motion, shake: 0, keys, confidence: 0.6 });
const speed = { ramp: 'none' as const, curve: [{ t: 0, speed: 1 }], confidence: 0.5 };
const RECIPE: Recipe = {
  schema: 'muse.recipe/1', analyzer: { version: 'test', tookMs: 0 },
  source: { durationSec: 4.4, width: 1080, height: 1920, fps: 30, aspect: '9:16', hasAudio: true },
  sound: null, pacing: { shots: 3, avgShotSec: 1.47, cutsPerMin: 27, energy: { everySec: 0.5, values: [0] } },
  slots: [
    { id: 's1', index: 0, startSec: 0, endSec: 1.5, durationSec: 1.5, keyframeSec: 0.75, confidence: 0.9, brief: null, rig: { moves: [{ id: 'pan_right' }] },
      camera: cam('pan', [{ t: 0, x: 0, y: 0, scale: 1 }, { t: 0.75, x: -0.3, y: 0, scale: 1 }, { t: 1.467, x: -0.6, y: 0, scale: 1 }]), speed, peaks: [], pose: { status: 'pending' } },
    { id: 's2', index: 1, startSec: 1.5, endSec: 2.65, durationSec: 1.15, keyframeSec: 2.07, confidence: 0.9, brief: null, rig: { moves: [{ id: 'zoom_in' }] },
      camera: cam('zoom_in', [{ t: 0, x: 0, y: 0, scale: 1 }, { t: 1, x: 0, y: 0, scale: 1.1 }]),
      speed: { ramp: 'speed_up', curve: [{ t: 0, speed: 0.5 }, { t: 0.5, speed: 1 }, { t: 1, speed: 2 }], confidence: 0.55 }, peaks: [{ t: 0.4, strength: 1 }], pose: { status: 'pending' } },
    { id: 's3', index: 2, startSec: 2.65, endSec: 4.4, durationSec: 1.75, keyframeSec: 3.5, confidence: 0.9, brief: null, rig: { moves: [{ id: 'static' }] },
      camera: cam('static'), speed, peaks: [], pose: { status: 'pending' } },
  ],
  transitions: [
    { atSec: 1.5, kind: 'cut', durationSec: 0, confidence: 0.9, from: 's1', to: 's2' },
    { atSec: 2.65, kind: 'crossfade', durationSec: 0.5, confidence: 0.7, from: 's2', to: 's3' },
    { atSec: 3.733, kind: 'flash', durationSec: 0.067, confidence: 0.8, from: 's3', to: 's3' },
  ],
  text: [{ id: 'x1', startSec: 3.1, endSec: 4.1, box: { x: 0.125, y: 0.7, w: 0.75, h: 0.07 }, words: null, sizeFrac: 0.042, color: '#FFFFFF', animIn: 'cut', animOut: 'cut', confidence: 0.45 }],
  grade: { swatches: ['#101010', '#404040', '#808080', '#C0C0C0', '#F0F0F0'], contrast: 0.5, saturation: 0.1, warmth: 0, look: { id: 'golden_warmth', kind: 'palette', label: 'Golden warmth', distance: 0.2 }, grade: null, confidence: 0.8 },
  contactSheet: null, gaps: [],
};
const TAKE = (id: string, durationSec = 3) => ({ id, durationSec, width: 720, height: 1280 });

describe('Recreate · assembly (unit)', () => {
  it('cuts land on the reference: each clip carries half of each neighbouring transition; the edit validates', () => {
    const out = buildProject(RECIPE, 'take_src', { s1: TAKE('tA'), s2: TAKE('tB'), s3: TAKE('tC') });
    const p = out.project;
    expect(() => M.validate(p, FILTERS, LOOK_IDS, paletteIds())).not.toThrow();
    expect(p.canvas).toEqual({ width: 1080, height: 1920, fps: 30, background: '#000000' });
    expect(p.assets.map(a => a.take)).toEqual(['tA', 'tB', 'tC']);
    const tl = M.timeline(p);
    expect(tl.map(x => x.startSec)).toEqual([0, 1.5, expect.closeTo(2.4, 4)]); // s3's crossfade starts 0.25 s before the 2.65 s boundary
    expect(out.durationSec).toBeCloseTo(4.4, 3);
    const [c1, c2, c3] = M.mainTrack(p).items as M.VideoClip[];
    expect(c2!.transitionIn).toBeUndefined(); // a cut
    expect(c3!.transitionIn).toEqual({ kind: 'fade', durationSec: 0.5 });
    expect(c1!.keyframes!.x!.at(0)!.v).toBeCloseTo(0.8, 3); // a pan right: the picture slides left across a scaled-up clip
    expect(c1!.keyframes!.x!.at(-1)!.v).toBeCloseTo(0.2, 3);
    expect(c1!.keyframes!.scale![0]!.v).toBeCloseTo(1.6, 3);
    expect(c2!.speedCurve?.preset).toBe('custom');
    expect(M.clipLength(c2!)).toBeCloseTo(1.15 + 0.25, 2); // the ramp still fills exactly the slot (+ half the crossfade)
    expect(c3!.keyframes).toBeUndefined();
    expect(c1!.look).toEqual({ lut: 'pack:warm-honey', strength: 0.8 }); // golden_warmth's pack twin
    const text = p.tracks.find(t => t.kind === 'text')!.items[0] as M.TextItem;
    expect(text).toMatchObject({ startSec: 3.1, durationSec: 1, text: 'Text', transform: { x: 0.5, y: 0.735 } });
    expect(out.notes.join(' ')).toMatch(/says "Text"/);
  });

  it('options switch parts off; a short take plays slower; slots without a take are left out', () => {
    const off = buildProject(RECIPE, 'take_src', { s1: TAKE('tA'), s3: TAKE('tC', 1) }, { camera: false, speed: false, text: false, look: false });
    expect(off.missing).toEqual(['s2']);
    const [c1, c3] = M.mainTrack(off.project).items as M.VideoClip[];
    expect(c1!.keyframes).toBeUndefined();
    expect(c1!.look).toBeUndefined();
    expect(off.project.tracks.some(t => t.kind === 'text')).toBe(false);
    expect(c3!.speed).toBeCloseTo(1 / 1.75, 3);
    expect(off.notes[0]).toMatch(/s3: the take is shorter than the slot, so it plays at 57%/);
    expect(editorTransition({ ...RECIPE.transitions[0]!, kind: 'whip', durationSec: 0.2 })).toEqual({ kind: 'whip', durationSec: 0.2 });
    expect(editorTransition({ ...RECIPE.transitions[0]!, kind: 'fade', durationSec: 5 })).toEqual({ kind: 'black', durationSec: 2 });
    expect(editorTransition({ ...RECIPE.transitions[0]!, kind: 'unknown' })).toBeUndefined();
  });
});

describe('Recreate · briefs, matching and the fill request (unit)', () => {
  const cand = (id: string, o: Partial<Candidate> = {}): Candidate => ({ id, modelId: 'm1', durationSec: 3, width: 720, height: 1280, status: 'test', createdAt: 0, draft: null, title: id, ...o });
  it('briefs are checked and add framing and angle to the rig', () => {
    expect(BriefSchema.safeParse({ shotSize: 'huge' }).success).toBe(false);
    expect(BriefSchema.safeParse({ angle: 'low', subject: 'Zelphira', extra: 1 }).success).toBe(false);
    const r = withBriefs(RECIPE, { s2: { shotSize: 'cu', angle: 'low', subject: 'She', action: 'flips her hair' } });
    expect(r.slots[1]!.rig).toEqual({ moves: [{ id: 'zoom_in' }], shotSize: 'cu', height: 'low' });
    expect(() => withBriefs(RECIPE, { s9: {} })).toThrow(/no slot s9/);
  });

  it('scores length, shape, move, framing and the lead; each take is suggested once; nothing good = to generate', () => {
    const r = withBriefs(RECIPE, { s2: { shotSize: 'cu' } });
    const good = scoreTake(r.slots[1]!, '9:16', cand('a', { draft: { v: 1, tool: 'shot', rig: { moves: [{ id: 'zoom_in' }], shotSize: 'cu' } } as any }), { leadModelId: 'm1' });
    const bad = scoreTake(r.slots[1]!, '9:16', cand('b', { durationSec: 0.4, width: 1920, height: 1080, modelId: 'm2' }), { leadModelId: 'm1' });
    expect(good.score).toBeGreaterThan(0.9);
    expect(good.reasons).toEqual(expect.arrayContaining(['long enough', 'same move (zoom_in)', 'same framing (cu)', 'your lead']));
    expect(bad.score).toBeLessThan(0.5);
    const m = matchSlots(r, [cand('a', { draft: { v: 1, tool: 'shot', rig: { moves: [{ id: 'zoom_in' }] } } as any }), cand('b', { draft: { v: 1, tool: 'shot', rig: { moves: [{ id: 'pan_right' }] } } as any })],
      { leadModelId: 'm1', minScore: 0.7 });
    expect(m.assignment).toEqual({ s2: 'a', s1: 'b' });
    expect(m.slots.find(s => s.slotId === 's3')).toMatchObject({ suggested: null, toGenerate: true });
    expect(new Set(Object.values(m.assignment)).size).toBe(Object.values(m.assignment).length);
  });

  it('the fill request: the brief as the prompt, the shape, framing, angle and move, whole seconds at least the minimum', () => {
    const r = withBriefs(RECIPE, { s2: { shotSize: 'cu', angle: 'low', subject: 'she', action: 'flips her hair', location: 'a rooftop at dusk' } });
    const q = shotRequestFor(r, r.slots[1]!, { modelId: 'm1', quality: 'hd', referenceName: 'Tuff edit' });
    expect(q).toMatchObject({ modelId: 'm1', quality: 'hd', duration: 2, aspectRatio: '9:16', takes: 1, prompt: 'She, flips her hair, in a rooftop at dusk.', title: 'Tuff edit · s2',
      camera: { angle: { height: 'low', shotSize: 'cu' }, move: { id: 'zoom_in', intensity: 0.5 } }, draft: { tool: 'shot', recreate: { slotId: 's2' } } });
    expect(shotRequestFor(r, r.slots[2]!, { modelId: 'm1', quality: 'draft', minSeconds: 4 }).duration).toBe(4);
  });
});

describe.skipIf(!hasFfmpeg)('Recreate · the flow through the API and Claude\'s tools (mock provider)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, ownerUser: AuthUser, dir: string, refId: string, sessionId: string, model: { id: string };
  const env = () => ({ ctx: a.ctx, user: ownerUser, source: 'mcp' as const });
  const tool = (n: string) => RECREATE_TOOLS.find(t => t.name === n)!;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    model = (await owner.req('POST', '/v1/models', { name: 'Zelphira', age: 24, niche: 'Fashion' })).body;
    for (const [k, asset] of Object.entries({ face: 'face', profile: 'profile', front: 'g_front', tq: 'g_tq', side: 'g_side', back: 'g_back', faceTq: 'c_face' }))
      await owner.req('PUT', `/v1/models/${model.id}/slots/${k}`, { image: { asset }, source: 'upload' });
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-recreate-slots-'));
    const ref = fs.readFileSync(makeReference(dir));
    await putObject(a.ctx, { key: 'u/rx/flow.mp4', body: ref, studioId, kind: 'clip', contentType: 'video/mp4' });
    // Two of her takes: a pan (2 s) and a static shot (4 s), with drafts.
    for (const [id, move, d] of [['t_pan', 'pan_right', 2], ['t_static', 'static', 4]] as const) {
      await putObject(a.ctx, { key: `c/${id}.mp4`, body: ref, studioId, kind: 'clip', contentType: 'video/mp4' });
      await a.ctx.db.insert(takes).values({ id, studioId, userId: owner.id, kind: 'take', jobId: null, modelId: model.id, index: 1, of: 1, title: id, label: 'HD', engineLabel: '', cost: 0, seed: 0,
        status: 'test', thumb: null, prompt: '', mediaKey: `c/${id}.mp4`, media: { durationSec: d, width: 180, height: 320, fps: 30 }, draft: { v: 1, tool: 'shot', rig: { moves: [{ id: move }] } } as any, createdAt: Date.now() });
    }
    sessionId = (await owner.req('POST', '/v1/edit-sessions', { takeId: 't_static' })).body.id;
  });
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  it('analyze_reference (free, waits) and get_recipe with the contact sheet image', async () => {
    const [up] = await a.ctx.db.execute(sql`select id from uploads where storage_key = 'u/rx/flow.mp4'`).then((r: any) => r.rows ?? r);
    const r = await tool('analyze_reference').run(env(), { uploadId: up.id, name: 'Tuff edit' }) as any;
    expect(r).toMatchObject({ state: 'ready', summary: { shots: 3, aspect: '9:16' } });
    expect(r.summary.slots.map((s: any) => s.move)).toEqual(['pan_right', 'zoom_in', 'static']);
    refId = r.referenceId;
    const g = await tool('get_recipe').run(env(), { referenceId: refId }) as any;
    expect(g.mcpContent[0]).toMatchObject({ type: 'image', mimeType: 'image/png' });
    expect(g.structuredContent.recipe.slots).toHaveLength(3);
    expect((await tool('get_recipe').run(env(), { referenceId: refId, contactSheet: false }) as any).recipe.schema).toBe('muse.recipe/1');
    // Members can't drive it with Claude; an owner's member-made reference is still theirs only through the app.
    await expect(tool('get_recipe').run({ ...env(), user: { ...ownerUser, role: 'member' } }, { referenceId: refId })).rejects.toThrow(/studio owner/);
  }, 60_000);

  it('briefs, then matching: her pan and static takes go to s1 and s3; s2 (a close-up zoom) is to generate', async () => {
    const b = await tool('set_slot_briefs').run(env(), { referenceId: refId, slots: { s2: { shotSize: 'cu', subject: 'she', action: 'flips her hair' } } }) as any;
    expect(b.summary.slots[1].brief).toMatchObject({ shotSize: 'cu' });
    expect((await owner.req('PUT', `/v1/recreate/references/${refId}/briefs`, { slots: { s2: { shotSize: 'gigantic' } } })).status).toBe(400);
    const m = await tool('match_slots').run(env(), { referenceId: refId, modelId: model.id }) as any;
    expect(m.assignment).toMatchObject({ s1: 't_pan', s3: 't_static' });
    expect(m.slots.find((s: any) => s.slotId === 's2').toGenerate).toBe(true);
  });

  it('fill_slot: the price first; confirm asks the owner in the session; their yes starts a Suite job', async () => {
    const est = await tool('fill_slot').run(env(), { referenceId: refId, slotId: 's2', modelId: model.id, quality: 'draft', sessionId }) as any;
    expect(est).toMatchObject({ needsConfirmation: true, seconds: 2, prompt: 'She, flips her hair.' });
    expect(est.estimateUsd).toBeGreaterThanOrEqual(0);
    const ask = await tool('fill_slot').run(env(), { referenceId: refId, slotId: 's2', modelId: model.id, quality: 'draft', sessionId, confirm: true }) as any;
    expect(ask.waitingForOwner).toBe(true);
    const pend = (await owner.req('GET', `/v1/edit-sessions/${sessionId}`)).body.pending;
    expect(pend[0]).toMatchObject({ kind: 'recreate_fill', label: 'Generate s2 for “Tuff edit”' });
    const yes = (await owner.req('POST', `/v1/edit-sessions/${sessionId}/pending/${ask.pendingId}`, { approve: true })).body;
    expect(yes.status).toBe('done');
    const job = await until(async () => { const j = await a.ctx.jobs.get(yes.jobId); return j?.state === 'done' || j?.state === 'failed' ? j : null; }, 30_000);
    expect(job.state).toBe('done');
    expect(job.request).toMatchObject({ engine: 'suite', aspectRatio: '9:16', seconds: 2 });
    expect(job.draft).toMatchObject({ tool: 'shot', recreate: { slotId: 's2' } });
    const ref = (await owner.req('GET', `/v1/recreate/references/${refId}`)).body;
    expect(ref.recipe.slots[1].fill.jobId).toBe(yes.jobId);

    // apply_recipe with the two takes and the finished job: one undoable change, cuts on the reference's times.
    const before = await editSessionsOf(a.ctx).row(ownerUser, sessionId);
    const out = await tool('apply_recipe').run(env(), { referenceId: refId, sessionId, slots: { s1: 't_pan', s2: yes.jobId, s3: 't_static' } }) as any;
    expect(out).toMatchObject({ applied: true, missing: [], waiting: [] });
    const after = await editSessionsOf(a.ctx).row(ownerUser, sessionId);
    expect(after.revision).toBe(before.revision + 1);
    const p = after.project as M.EditProject;
    expect(M.mainTrack(p).items).toHaveLength(3);
    const tl = M.timeline(p);
    expect(tl[1]!.startSec).toBeCloseTo(ref.recipe.slots[1].startSec, 2);
    expect(out.durationSec).toBeCloseTo(ref.recipe.source.durationSec, 1);
    const hist = (await owner.req('GET', `/v1/edit-sessions/${sessionId}/history`)).body;
    const entry = hist.find((h: any) => h.label === 'Recreated “Tuff edit”');
    expect(entry).toMatchObject({ byClaude: true });
    // Undo restores the edit as it was.
    expect((await owner.req('POST', `/v1/edit-sessions/${sessionId}/undo`, {})).status).toBe(400);
    const undo = await owner.req('POST', `/v1/edit-sessions/${sessionId}/undo`, { entryId: entry.id });
    expect(undo.status).toBe(200);
    expect(M.mainTrack((await editSessionsOf(a.ctx).row(ownerUser, sessionId)).project as M.EditProject).items).toHaveLength(M.mainTrack(before.project as M.EditProject).items.length);
  }, 90_000);

  it('the app: estimate and apply over HTTP; a slot nothing filled is reported missing; checks', async () => {
    const e = (await owner.req('POST', `/v1/recreate/references/${refId}/slots/s3/estimate`, { modelId: model.id, quality: 'draft' })).body;
    expect(e).toMatchObject({ slotId: 's3', request: { duration: 2 } });
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/slots/s9/estimate`, { modelId: model.id })).status).toBe(404);
    const s = (await owner.req('GET', `/v1/edit-sessions/${sessionId}`)).body;
    const r = await owner.req('POST', `/v1/recreate/references/${refId}/apply`, { sessionId, baseRevision: s.revision, slots: { s1: 't_pan', s3: 't_static' }, device: 'mac' });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ missing: ['s2'], label: 'Recreated “Tuff edit”' });
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/apply`, { sessionId, slots: { s1: 'nope' } })).body.error).toMatch(/slots.s1: no video take or job nope/);
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/apply`, { sessionId, slots: { s7: 't_pan' } })).body.error).toMatch(/no slot s7/);
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/apply`, { sessionId, baseRevision: 0, slots: { s1: 't_pan' } })).status).toBe(409); // stale
    expect((await member.req('POST', `/v1/recreate/references/${refId}/match`, {})).status).toBe(404); // the owner's reference
  }, 60_000);
});
