// Claude in Edit on a new edit whose only video is an Edit upload (owner report 2026-11-12): a 23 s 9:16 mp4 with sound,
// uploaded with POST /v1/editor/uploads/presign + PUT and never confirmed (the apps have no confirm step), no take.
// watch, get_contact_sheet, find_action_peaks and listen must all work on it.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { uploads, users } from '../src/db/schema.js';
import { EDIT_TOOLS } from '../src/editor/mcpTools.js';
import * as M from '../src/editor/model.js';
import { registryByName, toolsForUser } from '../src/claude/registry.js';
import { WATCH_TOOLS } from '../src/claude/watch.js';
import { LISTEN_TOOLS } from '../src/claude/listen.js';
import { makeApp, people, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
type App = Awaited<ReturnType<typeof makeApp>>;
const tool = (name: string) => [...EDIT_TOOLS, ...WATCH_TOOLS, ...LISTEN_TOOLS].find(t => t.name === name)!;
// Bass hits (55 Hz bursts) at these seconds over a quiet 2 kHz bed: the drops the audio tool must find.
const HITS = [4, 9.5, 15, 19];

describe.skipIf(!hasFfmpeg)('Claude tools on an Edit upload (new edit, no take)', () => {
  let a: App, owner: Client, u: AuthUser, dir: string, uploadId: string, fileUrl: string, sid: string;
  const env = () => ({ ctx: a.ctx, user: u, source: 'mcp' as const });

  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock' });
    ({ owner } = await people(a, 0, { topUp: 0 }) as any);
    const [row] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    u = { id: row!.id, studioId, email: row!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-edit-up-'));
    // 23 s 9:16 with sound, no metadata tags at all (as a phone or screen recorder might make it), the audio stream FIRST.
    const file = path.join(dir, 'clip.mp4');
    const bass = HITS.map(t => `between(t,${t},${t + 0.6})*0.9*sin(2*PI*55*t)*exp(-3*(t-${t}))`).join('+');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', `aevalsrc='${bass}+0.03*sin(2*PI*2000*t)':s=44100:d=23`,
      '-f', 'lavfi', '-i', 'testsrc2=s=144x256:d=23:r=30', '-map', '0:a', '-map', '1:v', '-map_metadata', '-1', '-fflags', '+bitexact',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', file]);
    // The app's Edit upload: presign + PUT, nothing after.
    const buf = fs.readFileSync(file);
    const p = (await owner.req('POST', '/v1/editor/uploads/presign', { contentType: 'video/mp4', bytes: buf.length })).body;
    const url = new URL(p.url);
    await a.app.inject({ method: 'PUT', url: url.pathname + url.search, headers: { 'content-type': 'video/mp4' }, payload: buf });
    uploadId = p.uploadId; fileUrl = p.fileUrl;
    // A new (blank) edit with that upload on the timeline, as the Mac builds it (asset {upload, durationSec, width, height, hasAudio}).
    const project = M.blankProject();
    project.assets.push({ id: 'v1', kind: 'video', upload: uploadId, durationSec: 23, width: 144, height: 256, hasAudio: true });
    (project.tracks[0]!.items as M.VideoClip[]).push({ id: 'c1', asset: 'v1', inSec: 0, outSec: 23, speed: 1 });
    sid = (await owner.req('POST', '/v1/edit-sessions', { takeId: M.BLANK_SOURCE, project })).body.id;
  }, 60_000);
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  it('an Edit upload left pending is watched (the file is there), by its upload id, /uploads/ link, or the edit\'s clip', async () => {
    // As on prod before this fix: the row left pending (opening the edit now records it ready, see the next test).
    await new Promise(res => setTimeout(res, 200));
    await a.ctx.db.update(uploads).set({ state: 'pending', bytes: null }).where(eq(uploads.id, uploadId));
    const r = await tool('watch').run(env(), { id: uploadId }) as any;
    expect(r.durationSec).toBeCloseTo(23, 0);
    expect(r.sound.present).toBe(true);
    const [after] = await a.ctx.db.select().from(uploads).where(eq(uploads.id, uploadId));
    expect(after!.state).toBe('ready');
    expect(after!.bytes).toBeGreaterThan(0);
    expect((await tool('watch').run(env(), { id: fileUrl }) as any).durationSec).toBeCloseTo(23, 0);
    // The timeline's own ids: the clip (c1) or the asset (v1) of the edit session.
    expect((await tool('watch').run(env(), { sessionId: sid, itemId: 'c1' }) as any).id).toBe(uploadId);
    expect((await tool('watch').run(env(), { sessionId: sid, id: 'v1' }) as any).id).toBe(uploadId);
    const closer = await tool('watch_closer').run(env(), { sessionId: sid, itemId: 'c1', fromSec: 1, toSec: 1.2 }) as any;
    expect(closer.everyFrame).toBe(true);
  }, 90_000);

  it('putting an Edit upload on the timeline records it ready (the apps have no confirm step)', async () => {
    const buf = fs.readFileSync(path.join(dir, 'clip.mp4'));
    const p = (await owner.req('POST', '/v1/editor/uploads/presign', { contentType: 'video/mp4', bytes: buf.length })).body;
    const url = new URL(p.url);
    await a.app.inject({ method: 'PUT', url: url.pathname + url.search, headers: { 'content-type': 'video/mp4' }, payload: buf });
    const s = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body;
    const r = await owner.req('POST', `/v1/edit-sessions/${sid}/patch`, { baseRevision: s.revision, patch: [{ op: 'add', path: '/assets/-', value: { id: 'v9', kind: 'video', upload: p.uploadId, durationSec: 23, hasAudio: true } }] });
    expect(r.status).toBe(200);
    for (let i = 0; i < 50; i++) {
      const [row] = await a.ctx.db.select().from(uploads).where(eq(uploads.id, p.uploadId));
      if (row!.state === 'ready') { expect(row!.bytes).toBe(buf.length); return; }
      await new Promise(res => setTimeout(res, 50));
    }
    throw new Error('the upload stayed pending');
  });

  it('a pending upload whose file never arrived is still "not ready", and stays pending', async () => {
    const p = (await owner.req('POST', '/v1/editor/uploads/presign', { contentType: 'video/mp4', bytes: 10 })).body;
    await expect(tool('watch').run(env(), { id: p.uploadId })).rejects.toMatchObject({ status: 409 });
    const [row] = await a.ctx.db.select().from(uploads).where(eq(uploads.id, p.uploadId));
    expect(row!.state).toBe('pending');
  });

  it('get_edit names the watchable id of every clip', async () => {
    const r = await tool('get_edit').run(env(), { sessionId: sid, full: false }) as any;
    const item = r.summary.tracks[0].items[0];
    expect(item.source).toBe(`upload ${uploadId}`);
    expect(item.watchId).toBe(uploadId);
  });

  it('get_contact_sheet and get_frame draw the upload\'s real frames (no server error)', async () => {
    const sheet = await tool('get_contact_sheet').run(env(), { sessionId: sid }) as any;
    expect(sheet.structuredContent.times.length).toBe(23);
    expect(sheet.structuredContent.unread ?? 0).toBe(0);
    const f = await tool('get_frame').run(env(), { sessionId: sid, t: 5 }) as any;
    expect(f.structuredContent.note).not.toMatch(/could not be read/);
  }, 90_000);

  it('find_action_peaks works on the upload (no take, no source durationSec needed)', async () => {
    const p0 = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.project;
    delete p0.assets[0].durationSec; // an older app may leave it out
    const s2 = (await owner.req('POST', '/v1/edit-sessions', { takeId: M.BLANK_SOURCE, project: p0 })).body.id;
    for (const id of [sid, s2]) {
      const r = await tool('find_action_peaks').run(env(), { sessionId: id }) as any;
      expect(r.durationSec).toBeCloseTo(23, 0);
      expect(Array.isArray(r.peaks)).toBe(true);
    }
  }, 90_000);

  it('listen: loudness, a bass curve every 0.1 s and the drops at the bass hits', async () => {
    const t = registryByName.get('listen');
    expect(t).toBeTruthy();
    expect(t!.pages).toEqual(['any']);
    expect(toolsForUser({ role: 'member' }).map(x => x.name)).toContain('listen');
    expect(tool('listen')).toMatchObject({ scope: 'edit:read', readOnly: true });
    for (const args of [{ id: uploadId }, { sessionId: sid }]) {
      const r = await tool('listen').run(env(), args) as any;
      expect(r.durationSec).toBeCloseTo(23, 0);
      expect(r.stepSec).toBe(0.1);
      expect(r.curves.bass.length).toBeGreaterThanOrEqual(225);
      expect(r.curves.bass.length).toBe(r.curves.all.length);
      expect(r.curves.mid.length).toBe(r.curves.bass.length);
      expect(typeof r.loudness.integratedLufs).toBe('number');
      for (const h of HITS) expect(r.drops.some((d: { t: number }) => Math.abs(d.t - h) <= 0.25), `drop at ${h}`).toBe(true);
      expect(r.drops.length).toBeLessThanOrEqual(HITS.length + 2);
      for (const h of HITS) expect(r.bassHits.some((b: { t: number }) => Math.abs(b.t - h) <= 0.25), `hit at ${h}`).toBe(true);
      expect(r.curves.highs.length).toBe(r.curves.bass.length);
      expect(JSON.stringify(r).length).toBeLessThan(20_000); // compact: numbers, not images
    }
  }, 90_000);

  it('listen: an edit\'s sound follows the timeline (a clip trimmed to start at 3.5 s moves every hit 3.5 s earlier)', async () => {
    const p0 = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.project;
    p0.tracks[0].items[0].inSec = 3.5;
    const s3 = (await owner.req('POST', '/v1/edit-sessions', { takeId: M.BLANK_SOURCE, project: p0 })).body.id;
    const r = await tool('listen').run(env(), { sessionId: s3 }) as any;
    expect(r.durationSec).toBeCloseTo(19.5, 0);
    expect(r.bassHits.some((d: { t: number }) => Math.abs(d.t - 0.5) <= 0.25)).toBe(true);
    for (const h of HITS.slice(1)) expect(r.drops.some((d: { t: number }) => Math.abs(d.t - (h - 3.5)) <= 0.25), `drop at ${h - 3.5}`).toBe(true);
  }, 90_000);

  it('listen: part of a file (fromSec/toSec) in the file\'s seconds, with a graph', async () => {
    const r = await tool('listen').run(env(), { id: uploadId, fromSec: 6, toSec: 12, graph: true }) as any;
    expect(r.structuredContent.fromSec).toBe(6);
    expect(r.structuredContent.curves.bass.length).toBeGreaterThanOrEqual(58);
    expect(r.structuredContent.bassHits.every((h: { t: number }) => h.t >= 6 && h.t <= 12)).toBe(true);
    expect(r.structuredContent.drops.some((d: { t: number }) => Math.abs(d.t - 9.5) <= 0.25)).toBe(true);
    expect(r.mcpContent.some((b: { type: string; mimeType?: string }) => b.type === 'image' && b.mimeType === 'image/png')).toBe(true);
  }, 60_000);

  it('listen on a video with no sound says so', async () => {
    const f = path.join(dir, 'silent.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=64x64:d=2:r=10', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', f]);
    await a.ctx.storage.put('c/silent.mp4', fs.readFileSync(f), 'video/mp4');
    await a.ctx.db.insert(uploads).values({ id: 'up_silent', studioId: u.studioId, kind: 'asset', storageKey: 'c/silent.mp4', contentType: 'video/mp4', bytes: 1, state: 'pending', createdAt: Date.now() });
    await expect(tool('listen').run(env(), { id: 'up_silent' })).rejects.toThrow(/no sound/);
  });

  it('the media lane is re-entrant: work inside it may ask for it again without waiting on itself', async () => {
    const { oneAtATime } = await import('../src/lib/mediaLane.js');
    const v = await Promise.race([oneAtATime(() => oneAtATime(async () => 7)), new Promise(res => setTimeout(() => res('deadlock'), 2000))]);
    expect(v).toBe(7);
  });

  it('reverse_clip: a piece plays backwards, rewind adds a reversed copy after it; one undoable step, copy reused', async () => {
    const get = async () => (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body;
    let s = await get();
    const before = M.durationSec(s.project);
    const r1 = await tool('reverse_clip').run(env(), { sessionId: sid, baseRevision: s.revision, clipId: 'c1', fromSec: 2, toSec: 3 }) as any;
    expect(r1.changes.join(' ')).toMatch(/Changed the project|Reversed/);
    s = await get();
    const rev = s.project.assets.find((x: any) => x.reverseOf === 'v1');
    expect(rev?.upload).toBeTruthy();
    // The apps download an upload's file from its url: without it the reversed piece played black on the Mac.
    expect(rev.url).toMatch(/\/uploads\/.+\.mp4$/);
    // Every upload asset gets its link on a change of Claude's (repairs an edit made before this fix).
    expect(s.project.assets.filter((x: any) => x.upload && !x.take).every((x: any) => typeof x.url === 'string' && x.url.includes('/uploads/'))).toBe(true);
    const main = s.project.tracks.find((t: any) => t.kind === 'main').items;
    const piece = main.find((x: any) => x.asset === rev.id);
    expect(piece.inSec).toBeCloseTo(23 - 3, 2);
    expect(piece.outSec).toBeCloseTo(23 - 2, 2);
    expect(M.durationSec(s.project)).toBeCloseTo(before, 2);
    // Rewind on the piece after it: a reversed copy is inserted, the edit gets longer by the piece; the copy is reused.
    const later = main.find((x: any) => x.asset === 'v1' && x.inSec >= 2.9);
    const r2 = await tool('reverse_clip').run(env(), { sessionId: sid, baseRevision: s.revision, clipId: later.id, fromSec: 3, toSec: 3.5, mode: 'rewind' }) as any;
    expect(r2.revision).toBe(s.revision + 1);
    const s2 = await get();
    expect(s2.project.assets.filter((x: any) => x.reverseOf === 'v1').length).toBe(1);
    expect(M.durationSec(s2.project)).toBeCloseTo(before + 0.5, 1);
    // One step each: undo puts it back.
    await tool('undo_edit').run(env(), { sessionId: sid });
    expect(M.durationSec((await get()).project)).toBeCloseTo(before, 1);
  }, 120_000);
});
