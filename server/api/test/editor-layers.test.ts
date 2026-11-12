// Layers (plans/layers-edit.md, Phase 1; owner decisions 2026-11-11). The checks the owner can't do by hand: the shared
// contract (layers.json), the paid run's price, its ask-first gate above $1, the 60 s limit and the daily cap, the job's
// wiring (one tracking run per object, a matte and a box track per layer, reuse for free), and Claude's go-ahead gate
// (price first, the owner approves in the app, then the layers land on the edit) plus the free layer ops.
import fs from 'node:fs';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq, sql } from 'drizzle-orm';
import { takes, users } from '../src/db/schema.js';
import type { AuthUser } from '../src/ctx.js';
import { EDIT_TOOLS } from '../src/editor/mcpTools.js';
import * as M from '../src/editor/model.js';
import { applyOps } from '../src/editor/ops.js';
import { FILTERS } from '../src/editor/presets.js';
import { LOOK_IDS } from '../src/editor/lookpack.js';
import { GPU_SEC, editorAi } from '../src/editor/service.js';
import { boxPoints, parseObjects } from '../src/editor/layers.js';
import { editSessionsOf } from '../src/editor/sessions.js';
import type { Hooks, MockProvider, TrackPoint } from '../src/editor/providers.js';
import { registryByName } from '../src/claude/registry.js';
import { makeApp, people, until, type Client } from './helpers.js';

const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures/editor');
const fx = JSON.parse(fs.readFileSync(path.join(FIX, 'layers.json'), 'utf8'));
const tool = (name: string) => EDIT_TOOLS.find(t => t.name === name)!;

describe('layers contract (layers.json)', () => {
  it('every validation case gives the expected result and field', () => {
    for (const v of fx.validation as { name: string; project: M.EditProject; ok: boolean; field?: string }[]) {
      let got: { ok: boolean; field?: string } = { ok: true };
      try { M.validate(v.project, FILTERS, LOOK_IDS); } catch (e) { got = { ok: false, field: (e as M.EditProblem).field }; }
      expect(got, v.name).toEqual(v.ok ? { ok: true } : { ok: false, field: v.field });
    }
  });
  it('a box becomes taps inside it (kept) and just outside it (left out); objects are checked', () => {
    const pts = boxPoints({ x: 0.2, y: 0.3, w: 0.4, h: 0.4, t: 1 });
    expect(pts.filter(p => p.keep)).toHaveLength(5);
    expect(pts.filter(p => p.keep).every(p => p.x > 0.2 && p.x < 0.6 && p.y > 0.3 && p.y < 0.7 && p.t === 1)).toBe(true);
    expect(pts.filter(p => !p.keep).every(p => p.x < 0.2 || p.x > 0.6 || p.y < 0.3 || p.y > 0.7)).toBe(true);
    expect(() => parseObjects([], 60)).toThrow(/1 to 5/);
    expect(() => parseObjects(Array.from({ length: 6 }, () => ({ name: 'x', points: [{ x: 0.5, y: 0.5 }] })), 60)).toThrow(/1 to 5/);
    expect(() => parseObjects([{ name: 'x', points: [{ x: 0.5, y: 0.5, keep: false }] }], 60)).toThrow(/tap it or draw a box/);
    expect(() => parseObjects([{ name: 'x', box: { x: 0.8, y: 0, w: 0.4, h: 0.2 } }], 60)).toThrow(/inside the frame/);
    expect(parseObjects([{ name: ' Her ', points: [{ x: 0.5, y: 0.25, t: 2 }] }], 60)).toEqual([{ name: 'Her', points: [{ x: 0.5, y: 0.25, t: 2, keep: true }] }]);
  });
});

describe('Find layers (mock provider)', () => {
  type A = Awaited<ReturnType<typeof makeApp>>;
  let a: A, owner: Client, studioId: string, ownerUser: AuthUser;
  const tracked: TrackPoint[][] = [];
  const take = async (durationSec: number) => {
    const id = `take_${Math.random().toString(16).slice(2, 10)}`;
    await a.ctx.storage.put(`c/${id}.mp4`, Buffer.from('source video'), 'video/mp4');
    await a.ctx.db.insert(takes).values({ id, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 't', label: 'HD', engineLabel: '', cost: 0, seed: 0,
      status: 'final', thumb: null, prompt: '', mediaKey: `c/${id}.mp4`, media: { durationSec, width: 1080, height: 1920, fps: 30, contentType: 'video/mp4' }, createdAt: Date.now() });
    return id;
  };
  const objects = [{ name: 'Her', points: [{ x: 0.5, y: 0.25, t: 2 }, { x: 0.1, y: 0.9, keep: false }] }, { name: 'Dog', box: { x: 0.6, y: 0.6, w: 0.3, h: 0.3, t: 1 } }];
  const done = (id: string) => until(async () => { const r = (await owner.req('GET', `/v1/editor/jobs/${id}`)).body; return r.state !== 'running' ? r : null; }, 20_000);
  beforeAll(async () => {
    a = await makeApp();
    ({ owner } = await people(a, 0) as any);
    studioId = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id;
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    const mock = editorAi(a.ctx).provider as MockProvider;
    const orig = mock.track.bind(mock);
    mock.track = async (url: string, d: number, pts: TrackPoint[], h: Hooks) => { tracked.push(pts); return orig(url, d, pts, h); };
  }, 60_000);
  afterAll(async () => { await a.close(); });

  it('is priced per object × length × 2; above $1 asks first; over 60 s is refused; the daily cap holds', async () => {
    const t10 = await take(10), t60 = await take(60), t61 = await take(61);
    const est = (await owner.req('POST', '/v1/editor/estimate', { kind: 'layers', source: { takeId: t10 }, options: { objects } })).body;
    expect(est.usd).toBeCloseTo(GPU_SEC.layers(10, 2) * 0.000975 * 2, 4); // ≈ $0.18 for two layers of a 10 s clip
    expect(GPU_SEC.layers(10, 2)).toBe(2 * GPU_SEC.track(10));
    const five = Array.from({ length: 5 }, (_, i) => ({ name: `T${i}`, points: [{ x: 0.1 + i * 0.1, y: 0.5 }] }));
    const big = (await owner.req('POST', '/v1/editor/estimate', { kind: 'layers', source: { takeId: t60 }, options: { objects: five } })).body;
    expect(big.usd).toBeGreaterThan(1); // 5 layers of a 60 s clip ≈ $1.90
    const asked = await owner.req('POST', '/v1/editor/jobs', { kind: 'layers', source: { takeId: t60 }, options: { objects: five } });
    expect(asked.status).toBe(409);
    expect(asked.body).toMatchObject({ code: 'price_confirm', usd: big.usd });
    expect(String(asked.body.error)).toContain(`$${big.usd.toFixed(2)}`);
    expect((await owner.req('POST', '/v1/editor/jobs', { kind: 'layers', source: { takeId: t60 }, options: { objects: five }, acceptUsd: big.usd - 0.5 })).status).toBe(409);
    const ok = (await owner.req('POST', '/v1/editor/jobs', { kind: 'layers', source: { takeId: t60 }, options: { objects: five }, acceptUsd: big.usd })).body;
    expect(ok.state).toBe('running');
    expect((await done(ok.id)).state).toBe('done');
    const long = await owner.req('POST', '/v1/editor/estimate', { kind: 'layers', source: { takeId: t61 }, options: { objects } });
    expect(long.status).toBe(400);
    expect(JSON.stringify(long.body)).toMatch(/up to 60 s/);
    // The owner's daily cap counts layer runs like any paid helper.
    await owner.req('PATCH', '/v1/editor/settings', { capPerDayUsd: 0.05 });
    try {
      const capped = await owner.req('POST', '/v1/editor/jobs', { kind: 'layers', source: { takeId: t10 }, options: { objects } });
      expect(capped.status).toBe(402);
      expect(capped.body.code).toBe('editor_daily_cap');
    } finally { await owner.req('PATCH', '/v1/editor/settings', { capPerDayUsd: null }); }
  }, 60_000);

  it('runs the tracker once per object (pixels, frames), stores a matte and a box track per layer, and reuses it for free', async () => {
    const t = await take(10);
    tracked.length = 0;
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'layers', source: { takeId: t }, options: { objects } })).body;
    const r = await done(j.id);
    expect(r.state, JSON.stringify(r)).toBe('done');
    expect(tracked).toHaveLength(2);
    expect(tracked[0]).toEqual([{ x: 0.5 * 1079, y: 0.25 * 1919, frame: 60, keep: true }, { x: 0.1 * 1079, y: 0.9 * 1919, frame: 0, keep: false }]);
    expect(tracked[1]!.filter(p => p.keep)).toHaveLength(5);
    expect(tracked[1]!.every(p => p.frame === 30)).toBe(true);
    expect(r.result.layers.map((l: any) => l.name)).toEqual(['Her', 'Dog']);
    for (const l of r.result.layers) {
      expect(l.asset).toMatchObject({ kind: 'video', upload: expect.stringMatching(/^up_/) });
      expect(l.track.fps).toBe(5);
      expect(l.track.boxes[0]).toEqual([0, 0, 1, 1]); // the mock's matte keeps everything
    }
    expect(r.costUsd).toBeGreaterThan(0);
    const again = await owner.req('POST', '/v1/editor/estimate', { kind: 'layers', source: { takeId: t }, options: { objects } });
    expect(again.body.usd).toBe(0);
    const reused = await done((await owner.req('POST', '/v1/editor/jobs', { kind: 'layers', source: { takeId: t }, options: { objects } })).body.id);
    expect(reused.result).toMatchObject({ reused: true, layers: [{ asset: { upload: r.result.layers[0].asset.upload } }, { name: 'Dog' }] });
    expect(tracked).toHaveLength(2); // nothing ran again
  }, 60_000);

  it('Claude: price first, the owner approves in the app, the layers land on the clip; then free layer ops', async () => {
    expect(registryByName.get('find_layers')?.gate).toBe('spend');
    for (const n of ['set_layer', 'layer_base', 'text_behind', 'pin_text']) expect(registryByName.get(n)?.gate, n).toBe('none');
    const t = await take(8);
    const env = { ctx: a.ctx, user: ownerUser, source: 'mcp' as const };
    const sid = (await owner.req('POST', '/v1/edit-sessions', { takeId: t })).body.id;
    const objs = [{ name: 'Her', points: [{ x: 0.4, y: 0.3, t: 1 }] }];
    const price = await tool('find_layers').run(env, { sessionId: sid, objects: objs }) as any;
    expect(price).toMatchObject({ needsConfirmation: true });
    expect(price.estimateUsd).toBeGreaterThan(0);
    const asked = await tool('find_layers').run(env, { sessionId: sid, objects: objs, confirm: true }) as any;
    expect(asked).toMatchObject({ waitingForOwner: true });
    const s0 = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body;
    expect(s0.pending[0]).toMatchObject({ kind: 'layers', status: 'waiting', args: { acceptUsd: price.estimateUsd } });
    // Claude's marks are where it saw them on get_frame (canvas, timeline seconds), mapped onto the source frame.
    expect(s0.pending[0].args.options.objects[0].points[0]).toEqual({ x: 0.4, y: 0.3, t: 1 });
    expect(await editorAi(a.ctx).list(ownerUser, { takeId: t })).toHaveLength(0); // nothing runs on Claude's word
    expect((await owner.req('POST', `/v1/edit-sessions/${sid}/pending/${asked.pendingId}`, { approve: true })).body.status).toBe('running');
    const after = await until(async () => { const s = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body; return s.revision > s0.revision ? s : null; }, 15_000);
    const clip = after.project.tracks[0].items[0] as M.VideoClip;
    expect(clip.layers).toMatchObject([{ id: 'l1', name: 'Her', track: { fps: 5 } }]);
    expect(after.project.assets.find((x: M.Asset) => x.id === clip.layers![0]!.matte)).toMatchObject({ kind: 'video' });
    expect(clip.layerSource?.job).toMatch(/^edj_/);
    // Free ops: recolour, text behind, a title pinned to her, the background blurred.
    await tool('set_layer').run(env, { sessionId: sid, itemId: clip.id, layer: 'her', recolor: { color: '#1B2A6B', amount: 0.8 } });
    await tool('text_behind').run(env, { sessionId: sid, itemId: clip.id, layer: 'l1' });
    await tool('layer_base').run(env, { sessionId: sid, itemId: clip.id, blur: 0.6 });
    const svc = editSessionsOf(a.ctx);
    const s1 = await svc.row(ownerUser, sid);
    await svc.applyClaude(ownerUser, sid, { baseRevision: s1.revision, ops: [{ op: 'add_text', text: 'Hi', startSec: 0, durationSec: 2 }] });
    const textId = ((await svc.row(ownerUser, sid)).project as M.EditProject).tracks.find(x => x.kind === 'text')!.items[0]!.id;
    await tool('pin_text').run(env, { sessionId: sid, textId, itemId: clip.id, layer: 'Her', anchor: 'top' });
    const p = (await svc.row(ownerUser, sid)).project as M.EditProject;
    const c = p.tracks[0]!.items[0] as M.VideoClip;
    expect(c.layers![0]).toMatchObject({ recolor: { color: '#1B2A6B', amount: 0.8 }, aboveText: true });
    expect(c.layerBase).toEqual({ blur: 0.6 });
    expect(p.tracks.find(x => x.kind === 'text')!.items[0]).toMatchObject({ pin: { clip: c.id, layer: 'l1', anchor: 'top' } });
    expect(() => M.validate(p)).not.toThrow();
    // A layer op on a clip without layers says what to do.
    expect(() => applyOps(p, [{ op: 'set_layer', itemId: 'nope', layer: 'x' }])).toThrow();
  }, 60_000);
});
