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
    duck: [{ op: 'add_music', asset: { library: 'music_x', durationSec: 30 }, startSec: 0 }, { op: 'duck', levelDb: -12, attackSec: 0.2, releaseSec: 0.6 }],
    voice: [{ op: 'voice', itemId: 'c1', effect: 'radio', enhance: true }],
    add_music: [{ op: 'add_music', asset: { library: 'music_x', durationSec: 30 }, startSec: 1 }],
    ratio: [{ op: 'ratio', ratio: '1:1' }],
    patch: [{ op: 'patch', patch: [{ op: 'replace', path: '/canvas/background', value: '#111111' }] }],
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

  it('owner opens a session (one per take), members are refused', async () => {
    const s = (await owner.req('POST', '/v1/edit-sessions', { takeId, device: 'mac-1' })).body;
    expect(s).toMatchObject({ takeId, revision: 0, durationSec: 6 });
    expect(s.id).toMatch(/^es_/);
    expect((await owner.req('POST', '/v1/edit-sessions', { takeId })).body.id).toBe(s.id);
    expect((await member.req('POST', '/v1/edit-sessions', { takeId })).status).toBe(403);
    expect((await owner.req('GET', `/v1/edit-sessions?takeId=${takeId}`)).body).toHaveLength(1);
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
    expect(approx.structuredContent).toMatchObject({ approximate: true, t: 1.5 });
    expect(approx.mcpContent[0]).toMatchObject({ type: 'image', mimeType: 'image/png' });
    const meta = await sharp(Buffer.from(approx.mcpContent[0].data, 'base64')).metadata();
    expect(meta.width).toBe(120);
    if (hasFfmpeg) expect(approx.structuredContent.note).not.toMatch(/could not be read/);
    // An app comes online and answers the frame request.
    await owner.req('POST', `/v1/edit-sessions/${sid}/presence`, { device: 'mac-1', label: 'MacBook', platform: 'mac', canRender: true });
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
    const est = await tool('remove_background').run(env(), { sessionId: sid }) as any;
    expect(est).toMatchObject({ needsConfirmation: true });
    expect(est.estimateUsd).toBeGreaterThan(0);
    const asked = await tool('remove_background').run(env(), { sessionId: sid, confirm: true }) as any;
    expect(asked).toMatchObject({ waitingForOwner: true });
    const pend = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.pending;
    expect(pend).toHaveLength(1);
    const rev0 = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.revision;
    expect((await owner.req('POST', `/v1/edit-sessions/${sid}/pending/${asked.pendingId}`, { approve: true })).body.status).toBe('running');
    const after = await until(async () => { const s = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body; return s.revision > rev0 ? s : null; }, 15_000);
    const c = after.project.tracks[0].items[0];
    expect(c.chroma).toMatchObject({ color: '#00FF00' });
    expect(c.audioAsset).toBe('src');
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

  it('every Claude call is logged; read tools are edit:read, the rest edit:write; nothing deletes takes', async () => {
    const sid = (await owner.req('POST', '/v1/edit-sessions', { takeId })).body.id;
    const h = (await owner.req('GET', `/v1/edit-sessions/${sid}/history`)).body;
    expect(h.some((e: any) => e.kind === 'tool' && /Opened the edit|Started Cut silences/.test(e.label))).toBe(true);
    expect(EDIT_TOOLS.every(t => t.scope === (t.readOnly ? 'edit:read' : 'edit:write'))).toBe(true);
    expect(EDIT_TOOLS.map(t => t.name)).not.toContain('delete_take');
  });
});
