// Edit sessions shared with Claude (plans/claude-editing.md A): revisions and conflicts, every op and its undo, Claude's
// tools (paid helpers wait for the owner, free ones apply), exact frames from an online app and the approximate fallback,
// save/export requests. No money: the mock AI provider.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq, sql } from 'drizzle-orm';
import sharp from 'sharp';
import { takes, users } from '../src/db/schema.js';
import type { AuthUser } from '../src/ctx.js';
import { applyPatch, diff, jsonEqual } from '../src/editor/jsonpatch.js';
import { EDIT_TOOLS } from '../src/editor/mcpTools.js';
import * as M from '../src/editor/model.js';
import { applyOps, OP_NAMES, type EditOp } from '../src/editor/ops.js';
import { editSessionsOf } from '../src/editor/sessions.js';
import { editSessions as editSessionsTable } from '../src/editor/schema.js';
import { repairSourceMatteVersions, stripSourceMattes } from '../src/editor/repair.js';
import { makeApp, people, until, type Client } from './helpers.js';

type A = Awaited<ReturnType<typeof makeApp>>;
const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures/editor');
const tool = (name: string) => EDIT_TOOLS.find(t => t.name === name)!;

describe('JSON Patch (shared fixture)', () => {
  it('diff, apply and inverse give the expected patches and round-trip', () => {
    for (const c of JSON.parse(fs.readFileSync(path.join(FIX, 'jsonpatch.json'), 'utf8')) as { name: string; a: unknown; b: unknown; patch: unknown; inverse: unknown }[]) {
      expect(diff(c.a, c.b), c.name).toEqual(c.patch);
      expect(jsonEqual(applyPatch(c.a, c.patch as never), c.b), c.name).toBe(true);
      expect(jsonEqual(applyPatch(c.b, c.inverse as never), c.a), c.name).toBe(true);
    }
  });
});

describe('edit ops', () => {
  const base = (JSON.parse(fs.readFileSync(path.join(FIX, 'projects.json'), 'utf8')) as { project: M.EditProject }[])[8]!.project;
  const opsFor: Record<string, EditOp[]> = {
    trim: [{ op: 'trim', clipId: 'c1', inSec: 1, outSec: 8 }],
    split: [{ op: 'split', at: 4 }],
    delete: [{ op: 'split', at: 4 }, { op: 'delete', itemId: 'c2' }],
    move: [{ op: 'move', itemId: 't2', startSec: 6 }],
    speed: [{ op: 'speed', clipId: 'c1', curve: 'hero' }],
    add_text: [{ op: 'add_text', text: 'Hello', startSec: 7, durationSec: 2 }],
    add_hook: [{ op: 'add_hook', template: 'hook-stop' }],
    edit_text: [{ op: 'edit_text', itemId: 't1', text: 'New hook', style: { color: '#FFE600' } }],
    caption_style: [],
    look: [{ op: 'look', itemId: 'all', look: 'film-gold', strength: 0.6, grain: { amount: 0.3 } }],
    adjust: [{ op: 'adjust', itemId: 'c1', exposure: 0.2, highlights: -0.3 }],
    transition: [{ op: 'split', at: 4 }, { op: 'transition', clipId: 'all', kind: 'whip', durationSec: 0.3 }],
    mask: [{ op: 'mask', itemId: 'p1', mask: { shape: 'circle', feather: 0.2 } }],
    transform: [{ op: 'transform', itemId: 'p1', transform: { x: 0.3 } }],
    keyframe: [{ op: 'keyframe', itemId: 'p1', prop: 'opacity', t: 1, v: 0.5, ease: 'easeOut' }],
    remove_keyframe: [{ op: 'remove_keyframe', itemId: 'p1', prop: 'scale', t: 0.5 }],
    volume: [{ op: 'volume', itemId: 'c1', volume: 0.6, fadeInSec: 0.5 }],
    duck: [{ op: 'add_music', asset: { upload: 'up_music', durationSec: 30 }, startSec: 0 }, { op: 'duck', levelDb: -12, attackSec: 0.2, releaseSec: 0.6 }],
    voice: [{ op: 'voice', itemId: 'c1', effect: 'radio', enhance: true }],
    add_music: [{ op: 'add_music', asset: { upload: 'up_music', durationSec: 30 }, startSec: 1 }],
    ratio: [{ op: 'ratio', ratio: '1:1' }],
    patch: [{ op: 'patch', patch: [{ op: 'replace', path: '/canvas/background', value: '#111111' }] }],
    flip: [{ op: 'flip', itemId: 'p1', x: true }, { op: 'flip', itemId: 'i1', y: true }],
    freeze: [{ op: 'freeze', at: 2, durationSec: 1.2 }],
    blend: [{ op: 'blend', itemId: 'p1', mode: 'overlay' }],
    fill: [{ op: 'fill', kind: 'blur', color: '#202020' }],
  };
  it('every op changes the project, stays valid, and its inverse patch restores it', () => {
    for (const name of OP_NAMES) {
      const ops = opsFor[name]!;
      if (!ops.length) continue;
      const { project, labels } = applyOps(base, ops);
      expect(labels, name).toHaveLength(ops.length);
      expect(jsonEqual(project, base), name).toBe(false);
      expect(() => M.validate(project), name).not.toThrow();
      expect(jsonEqual(applyPatch(project, diff(project, base)), base), name).toBe(true);
    }
  });
  it('bad ops are refused with the op named', () => {
    expect(() => applyOps(base, [{ op: 'warp' }])).toThrow(/ops\.0\.op: one of/);
    expect(() => applyOps(base, [{ op: 'split', at: 0.01 }])).toThrow(/ops\.0\.split\.at/);
    expect(() => applyOps(base, [{ op: 'caption_style', preset: 'pop' }])).toThrow(/no captions yet/);
    expect(() => applyOps(base, [{ op: 'look', itemId: 'c1', look: 'nope' }])).toThrow(/look id from list_looks/);
    // No music library yet (2026-11-08 audit): a library track would be silent in every app.
    expect(() => applyOps(base, [{ op: 'add_music', asset: { library: 'music_x', durationSec: 30 } }])).toThrow(/no music library yet/);
  });
});

describe('edit sessions API and Claude tools', () => {
  let a: A, owner: Client, member: Client, studioId: string, takeId: string, ownerUser: AuthUser, hasFfmpeg = true;
  const events: any[] = [];
  beforeAll(async () => {
    a = await makeApp();
    ({ owner, members: [member] } = await people(a, 1) as any);
    studioId = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id;
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    takeId = 'take_edit1';
    const file = path.join(a.dir, 'src.mp4');
    try { execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=180x320:rate=30:duration=6', '-f', 'lavfi', '-i', 'sine=frequency=300:duration=6', '-af', "volume='if(between(t,2,4),0,1)':eval=frame", '-shortest', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-y', file]); }
    catch { hasFfmpeg = false; fs.writeFileSync(file, 'not a video'); }
    await a.ctx.storage.put(`c/${takeId}.mp4`, fs.readFileSync(file), 'video/mp4');
    await a.ctx.db.insert(takes).values({ id: takeId, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'Café review', label: 'HD',
      engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: `c/${takeId}.mp4`, media: { durationSec: 6, width: 180, height: 320, fps: 30, contentType: 'video/mp4' }, createdAt: Date.now() });
    a.ctx.hub.subscribe(studioId, owner.id, line => { if (line.startsWith('data: ')) events.push(JSON.parse(line.slice(6))); }, 'owner');
  });
  afterAll(async () => { await a.close(); });
  const env = () => ({ ctx: a.ctx, user: ownerUser, source: 'mcp' as const });

  it('a live take with 0 or missing facts opens on a sane project (owner blocker 2026-11-07)', async () => {
    for (const [id, media] of [['take_zero', { durationSec: 0, width: 0, height: 0, fps: 0 }], ['take_none', {}], ['take_nan', { durationSec: 'x', width: null, fps: -3 }]] as const) {
      await a.ctx.db.insert(takes).values({ id, studioId: ownerUser.studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 't', label: 'HD',
        engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: `c/${takeId}.mp4`, media: media as never, createdAt: Date.now() });
      const s = (await owner.req('POST', '/v1/edit-sessions', { takeId: id })).body;
      expect(s.project.canvas, id).toEqual({ width: 1080, height: 1920, fps: 30, background: '#000000' });
      expect(s.project.assets[0].durationSec, id).toBe(1);
      expect(s.durationSec, id).toBe(1);
    }
  });

  it('owner opens a session (one per take), members are refused', async () => {
    const s = (await owner.req('POST', '/v1/edit-sessions', { takeId, device: 'mac-1' })).body;
    expect(s).toMatchObject({ takeId, revision: 0, durationSec: 6 });
    expect(s.id).toMatch(/^es_/);
    expect((await owner.req('POST', '/v1/edit-sessions', { takeId })).body.id).toBe(s.id);
    expect((await member.req('POST', '/v1/edit-sessions', { takeId })).status).toBe(403);
    expect((await owner.req('GET', `/v1/edit-sessions?takeId=${takeId}`)).body).toHaveLength(1);
  });

  it('continue a draft: the view (playhead, zoom, tabs, platform view) is kept, and recent lists the last worked on first', async () => {
    const s = (await owner.req('POST', '/v1/edit-sessions', { takeId })).body;
    const blank = (await owner.req('POST', '/v1/edit-sessions', { takeId: M.BLANK_SOURCE })).body;
    // The blank project was made last, so it leads; leaving the take's editor afterwards puts the take first.
    expect((await owner.req('GET', '/v1/edit-sessions?recent=1')).body[0].id).toBe(blank.id);
    const v = await owner.req('POST', `/v1/edit-sessions/${s.id}/view`, { view: { playhead: 2.5, zoom: 120, tab: 'video', binTab: 'uploads', safeArea: null,
      mode: 'timeline', selection: 'c1', title: 'Café review', junk: 'x'.repeat(5000) } });
    expect(v.body.view).toMatchObject({ playhead: 2.5, zoom: 120, tab: 'video', binTab: 'uploads', safeArea: null, mode: 'timeline', selection: 'c1' });
    expect(v.body.view.junk).toBeUndefined();
    const recent = (await owner.req('GET', '/v1/edit-sessions?recent=1&limit=5')).body;
    expect(recent[0]).toMatchObject({ id: s.id, takeId, view: { playhead: 2.5, binTab: 'uploads' } });
    expect(recent[0].lastTouchedAt).toBeGreaterThanOrEqual(recent[1].lastTouchedAt);
    expect(recent.map((r: { id: string }) => r.id)).toContain(blank.id);
    expect(recent[0].history).toBeUndefined();
    // Reopening the take's session brings its view back (another device continues where this one left off).
    expect((await owner.req('GET', `/v1/edit-sessions/${s.id}`)).body.view.zoom).toBe(120);
    // A change that lands later without anyone in the editor (a helper's result, Claude's note) doesn't make an edit the
    // last one worked on: the blank stays behind the take the person just left (run 604).
    await new Promise(r => setTimeout(r, 5));
    const svc = editSessionsOf(a.ctx), row = await svc.row(ownerUser, blank.id);
    await svc.saveView(ownerUser, blank.id, { view: { playhead: 0 } });
    await svc.saveView(ownerUser, s.id, { view: { playhead: 2.5, zoom: 120, binTab: 'uploads', safeArea: null } });
    await svc.log(row, 'Claude looked at the edit');
    await a.ctx.db.update(editSessionsTable).set({ updatedAt: Date.now() + 60_000 }).where(eq(editSessionsTable.id, blank.id)); // a later change from no one in the editor
    expect((await owner.req('GET', '/v1/edit-sessions?recent=1')).body[0].id).toBe(s.id);
    // Out-of-range values are clamped; a non-object is refused; members never see sessions.
    expect((await owner.req('POST', `/v1/edit-sessions/${s.id}/view`, { view: { playhead: -4, zoom: 1e9 } })).body.view).toMatchObject({ playhead: 0, zoom: 2000 });
    expect((await owner.req('POST', `/v1/edit-sessions/${s.id}/view`, { view: [1] })).status).toBe(400);
    expect((await member.req('GET', '/v1/edit-sessions?recent=1')).status).toBe(403);
    expect((await member.req('POST', `/v1/edit-sessions/${s.id}/view`, { view: {} })).status).toBe(403);
    // Closed sessions drop out of the list.
    await owner.req('POST', `/v1/edit-sessions/${blank.id}/close`);
    expect((await owner.req('GET', '/v1/edit-sessions?recent=1')).body.map((r: { id: string }) => r.id)).not.toContain(blank.id);
  });

  it('apps push patches against a revision; a stale one is 409; bad ones are refused; others see it live', async () => {
    const s = (await owner.req('POST', '/v1/edit-sessions', { takeId })).body;
    const next = applyOps(s.project, [{ op: 'trim', clipId: 'c1', inSec: 0.5, outSec: 5.5 }]).project;
    const r = await owner.req('POST', `/v1/edit-sessions/${s.id}/patch`, { baseRevision: 0, patch: diff(s.project, next), label: 'Trim', device: 'phone-1' });
    expect(r.body).toMatchObject({ revision: 1, entry: { author: 'app:phone-1', label: 'Trim', byClaude: false } });
    const ev = await until(() => events.find(e => e.type === 'edit' && e.op === 'patch' && e.revision === 1));
    expect(jsonEqual(applyPatch(s.project, ev.patch), next)).toBe(true);
    expect((await owner.req('POST', `/v1/edit-sessions/${s.id}/patch`, { baseRevision: 0, patch: [] })).body.code).toBe('stale_revision');
    expect((await owner.req('POST', `/v1/edit-sessions/${s.id}/patch`, { baseRevision: 1, patch: [{ op: 'replace', path: '/tracks/0/items/0/speed', value: 50 }] })).body.error).toMatch(/^project\.tracks\.0\.items\.0\.speed/);
    expect((await owner.req('POST', `/v1/edit-sessions/${s.id}/patch`, { baseRevision: 1, patch: [{ op: 'remove', path: '/nope/x' }] })).body.error).toMatch(/^patch: no/);
  });

  it('Claude changes the edit with ops (badged, undoable), refuses stale revisions, and undo restores it', async () => {
    const svc = editSessionsOf(a.ctx);
    const opened = await tool('open_edit').run(env(), { takeId }) as any;
    const before = (await svc.row(ownerUser, opened.sessionId)).project;
    const r = await tool('apply_edit_ops').run(env(), { sessionId: opened.sessionId, baseRevision: opened.revision, ops: [{ op: 'split', at: 2 }, { op: 'look', itemId: 'all', look: 'warm-honey', strength: 0.7 }, { op: 'add_hook', template: 'hook-bold', text: '3 things' }] }) as any;
    expect(r.changes).toEqual(['Split at 0:02.0', 'Look · warm-honey 70 %', 'Added hook “3 things”']);
    expect(r.label).toBe('Split at 0:02.0 · Look · warm-honey 70 % · Added hook “3 things”');
    expect(r.entry).toMatchObject({ author: 'claude', byClaude: true });
    await expect(tool('apply_edit_ops').run(env(), { sessionId: opened.sessionId, baseRevision: opened.revision, ops: [{ op: 'ratio', ratio: '1:1' }] })).rejects.toMatchObject({ code: 'stale_revision' });
    const got = await tool('get_edit').run(env(), { sessionId: opened.sessionId }) as any;
    expect(got.summary.tracks[0].items).toHaveLength(2);
    expect(got.history[0]).toMatchObject({ byClaude: true });
    const u = await tool('undo_edit').run(env(), { sessionId: opened.sessionId }) as any;
    expect(u.entry.label).toMatch(/^Undo: Split/);
    expect(jsonEqual((await svc.row(ownerUser, opened.sessionId)).project, before)).toBe(true);
    // the app's own change can be undone by the app too
    const h = (await owner.req('GET', `/v1/edit-sessions/${opened.sessionId}/history`)).body;
    const appEntry = h.find((e: any) => e.author === 'app:phone-1');
    expect((await owner.req('POST', `/v1/edit-sessions/${opened.sessionId}/undo`, { entryId: appEntry.id, device: 'phone-1' })).body.entry.label).toBe('Undo: Trim');
    expect((await owner.req('POST', `/v1/edit-sessions/${opened.sessionId}/undo`, { entryId: appEntry.id })).body.code).toBe('already_undone');
  });

  it('get_frame: approximate without an app; exact from the app when one is open', async () => {
    const svc = editSessionsOf(a.ctx);
    const sid = (await owner.req('POST', '/v1/edit-sessions', { takeId })).body.id;
    const approx = await tool('get_frame').run(env(), { sessionId: sid, t: 1.5, width: 120 }) as any;
    expect(approx.structuredContent).toMatchObject({ approximate: true, t: 1.5, label: 'Looked at 0:01.5 (approximate)' });
    expect(approx.mcpContent[0]).toMatchObject({ type: 'image', mimeType: 'image/png' });
    const meta = await sharp(Buffer.from(approx.mcpContent[0].data, 'base64')).metadata();
    expect(meta.width).toBe(120);
    if (hasFfmpeg) expect(approx.structuredContent.note).not.toMatch(/could not be read/);
    // An app comes online and answers the frame request.
    await owner.req('POST', `/v1/edit-sessions/${sid}/presence`, { device: 'mac-1', label: 'MacBook', platform: 'mac', canRender: true, preview: { view: 'tiktok', safeArea: true } });
    // Claude sees the view the person previews in (plans/edit-platform-preview.md).
    const seen = await tool('get_edit').run(env(), { sessionId: sid, full: false }) as any;
    expect(seen.preview).toMatchObject({ view: 'tiktok', safeArea: true, unsafe: [] });
    expect(seen.online[0].preview).toEqual({ view: 'tiktok', safeArea: true });
    const pending = tool('get_frame').run(env(), { sessionId: sid, t: 2 });
    const req = await until(() => events.find(e => e.type === 'edit' && e.op === 'frame_request' && e.sessionId === sid));
    const png = await sharp({ create: { width: 64, height: 114, channels: 3, background: '#ff0000' } }).png().toBuffer();
    const p = (await owner.req('POST', '/v1/uploads/presign', { kind: 'image', contentType: 'image/png', bytes: png.length })).body;
    const u = new URL(p.url);
    await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': 'image/png' }, payload: png });
    expect((await owner.req('POST', `/v1/edit-sessions/${sid}/frames/${req.requestId}`, { uploadId: p.uploadId })).body).toEqual({ ok: true });
    const exact = await pending as any;
    expect(exact.structuredContent).toMatchObject({ approximate: false, renderedBy: 'mac-1' });
    expect(Buffer.from(exact.mcpContent[0].data, 'base64').equals(png)).toBe(true);
    const sheet = await tool('get_contact_sheet').run(env(), { sessionId: sid, everySec: 2 }) as any;
    expect(sheet.structuredContent.times).toEqual([0, 2, 4]);
    void svc;
  }, 40_000);

  it('save and export go to an online app; without one Claude is told to ask the owner to open MUSE', async () => {
    const sid = (await owner.req('POST', '/v1/edit-sessions', { takeId })).body.id;
    const saved = await tool('save_version').run(env(), { sessionId: sid, name: 'Cut v2' }) as any;
    expect(saved).toMatchObject({ sent: true, device: 'mac-1' });
    const ev = await until(() => events.find(e => e.type === 'edit' && e.op === 'app_request' && e.request.id === saved.requestId));
    expect(ev.request).toMatchObject({ kind: 'save', name: 'Cut v2' });
    const ex = await tool('export_video').run(env(), { sessionId: sid, preset: { resolution: '1080p', aiLabel: true, c2pa: true } }) as any;
    const evx = await until(() => events.find(e => e.type === 'edit' && e.op === 'app_request' && e.request.id === ex.requestId));
    expect(evx.request.preset).toEqual({ resolution: '1080p' }); // the owner's disclosure switches are not Claude's
    expect((await owner.req('POST', `/v1/edit-sessions/${sid}/requests/${saved.requestId}`, { status: 'done', versionId: 'take_v2' })).body).toMatchObject({ status: 'done', versionId: 'take_v2' });
    await owner.req('DELETE', `/v1/edit-sessions/${sid}/presence/mac-1`);
    expect(await tool('save_version').run(env(), { sessionId: sid }) as any).toMatchObject({ sent: false });
  });

  it('paid helpers: estimate, then the owner approves in the app, then the result lands on the edit', async () => {
    const sid = (await owner.req('POST', '/v1/edit-sessions', { takeId })).body.id;
    // Tap to keep: its own label and price; bad points are refused before anything is asked.
    const tap = await tool('remove_background').run(env(), { sessionId: sid, points: [{ x: 0.5, y: 0.3 }] }) as any;
    expect(tap).toMatchObject({ needsConfirmation: true });
    expect(tap.estimateUsd).toBeGreaterThan(0);
    await expect(tool('remove_background').run(env(), { sessionId: sid, points: [{ x: 0.5, y: 0.3, keep: false }] })).rejects.toMatchObject({ status: 400 });
    // An alpha matte must point at a video asset of the project.
    const bad = structuredClone((await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.project);
    bad.tracks[0].items[0].alphaMatte = { asset: 'nope' };
    expect(() => M.validate(bad)).toThrow(/alphaMatte.asset/);
    const est = await tool('remove_background').run(env(), { sessionId: sid }) as any;
    expect(est).toMatchObject({ needsConfirmation: true });
    expect(String(est.label)).toMatch(/^Remove background · about \$/);
    expect(est.estimateUsd).toBeGreaterThan(0);
    expect(tap.estimateUsd).not.toBe(est.estimateUsd); // tracking has its own price
    const asked = await tool('remove_background').run(env(), { sessionId: sid, confirm: true }) as any;
    expect(asked).toMatchObject({ waitingForOwner: true });
    const pend = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.pending;
    expect(pend).toHaveLength(1);
    const rev0 = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.revision;
    expect((await owner.req('POST', `/v1/edit-sessions/${sid}/pending/${asked.pendingId}`, { approve: true })).body.status).toBe('running');
    const after = await until(async () => { const s = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body; return s.revision > rev0 ? s : null; }, 15_000);
    const c = after.project.tracks[0].items[0];
    // The original clip stays, with the matte as its alpha (no chroma key).
    expect(c.asset).toBe('src');
    expect(c.chroma).toBeUndefined();
    expect(after.project.assets.find((x: any) => x.id === c.alphaMatte.asset)).toMatchObject({ kind: 'video' });
    expect(after.history[0]).toMatchObject({ byClaude: true, label: 'Remove background' });
  }, 30_000);

  it('free helpers run at once and apply (silence cuts from the sound level)', async () => {
    if (!hasFfmpeg) return;
    const opened = await tool('open_edit').run(env(), { takeId, fresh: true }) as any;
    const r = await tool('cut_silences').run(env(), { sessionId: opened.sessionId, minSilenceSec: 1, keepPadSec: 0.1 }) as any;
    expect(r.state).toBe('done');
    expect(r.applied).toBe(true);
    const s = await editSessionsOf(a.ctx).row(ownerUser, opened.sessionId);
    expect((s.project as M.EditProject).tracks[0]!.items.length).toBe(2);
    expect(M.durationSec(s.project as M.EditProject)).toBeLessThan(5);
  }, 30_000);

  // Workstream 1 (plans/recreate-edit.md): action peaks on the session's video, free, changing nothing.
  it('find_action_peaks reads the clip on the server (free, read-only, logged)', async () => {
    if (!hasFfmpeg) return;
    const opened = await tool('open_edit').run(env(), { takeId, fresh: true }) as any;
    const before = await editSessionsOf(a.ctx).row(ownerUser, opened.sessionId);
    const r = await tool('find_action_peaks').run(env(), { sessionId: opened.sessionId, minGapSec: 0.5 }) as any;
    expect(r.fps).toBeGreaterThan(0);
    expect(r.durationSec).toBeGreaterThan(1);
    expect(Array.isArray(r.peaks) && Array.isArray(r.cuts)).toBe(true);
    for (const p of r.peaks) { expect(p.t).toBeGreaterThanOrEqual(0); expect(p.strength).toBeGreaterThan(0); expect(p.strength).toBeLessThanOrEqual(1); }
    expect(r.energy.values.length).toBeLessThanOrEqual(120);
    const after = await editSessionsOf(a.ctx).row(ownerUser, opened.sessionId);
    expect(after.revision).toBe(before.revision);
    expect(tool('find_action_peaks')).toMatchObject({ scope: 'edit:read', readOnly: true });
    await expect(tool('find_action_peaks').run(env(), { sessionId: opened.sessionId, itemId: 'nope' })).rejects.toThrow(/no item nope/);
  }, 30_000);

  it('every Claude call is logged; read tools are edit:read, the rest edit:write; nothing deletes takes', async () => {
    const sid = (await owner.req('POST', '/v1/edit-sessions', { takeId })).body.id;
    const h = (await owner.req('GET', `/v1/edit-sessions/${sid}/history`)).body;
    expect(h.some((e: any) => e.kind === 'tool' && /Opened the edit|Started Cut silences/.test(e.label))).toBe(true);
    expect(EDIT_TOOLS.every(t => t.scope === (t.readOnly ? 'edit:read' : 'edit:write'))).toBe(true);
    expect(EDIT_TOOLS.map(t => t.name)).not.toContain('delete_take');
  });
  it('one-off repair (2026-11-08): cut-outs whose matte is the source itself are removed, once; real mattes stay', async () => {
    const svc = editSessionsOf(a.ctx);
    const s = (await owner.req('POST', '/v1/edit-sessions', { takeId })).body;
    const src = (s.project as M.EditProject).assets.find(x => x.take === takeId)!;
    const next = structuredClone(s.project) as M.EditProject;
    next.assets.push({ id: 'bg_src', kind: 'video', take: takeId, durationSec: 6 } as M.Asset, { id: 'bg_real', kind: 'video', upload: 'up_real', durationSec: 6 } as M.Asset);
    const clips = next.tracks[0]!.items as M.VideoClip[];
    clips[0]!.alphaMatte = { asset: 'bg_src' };
    expect(stripSourceMattes(next).removed).toBe(1);
    const r = await owner.req('POST', `/v1/edit-sessions/${s.id}/patch`, { baseRevision: s.revision, patch: diff(s.project, next), label: 'Remove background' });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(await svc.repairSourceMattes()).toBe(1);
    const after = (await svc.row(ownerUser, s.id)).project as M.EditProject;
    expect((after.tracks[0]!.items[0] as M.VideoClip).alphaMatte).toBeUndefined();
    expect(after.assets.some(x => x.id === src.id)).toBe(true);
    const h = (await owner.req('GET', `/v1/edit-sessions/${s.id}/history`)).body as any[];
    expect(h.some(e => e.label === 'Removed a broken cut-out')).toBe(true);
    expect(await svc.repairSourceMattes()).toBe(0); // idempotent
    // A real matte (its own upload) is left alone.
    const real = structuredClone(after);
    (real.tracks[0]!.items[0] as M.VideoClip).alphaMatte = { asset: 'bg_real' };
    expect(stripSourceMattes(real).removed).toBe(0);
    // Saved edited versions are repaired in place.
    await a.ctx.db.insert(takes).values({ id: 'take_ver_matte', studioId, userId: null, kind: 'edit' as never, jobId: null, modelId: null, index: 1, of: 1, title: 'Matted', label: 'Edit',
      engineLabel: '', cost: 0, seed: 0, status: 'final', thumb: null, prompt: '', mediaKey: null, media: { durationSec: 6, parentTakeId: takeId, edits: next } as never, createdAt: Date.now() });
    expect(await repairSourceMatteVersions(a.ctx)).toBe(1);
    const [v] = await a.ctx.db.select().from(takes).where(eq(takes.id, 'take_ver_matte'));
    expect(((v!.media as any).edits.tracks[0].items[0] as M.VideoClip).alphaMatte).toBeUndefined();
    expect(await repairSourceMatteVersions(a.ctx)).toBe(0);
  });
});
