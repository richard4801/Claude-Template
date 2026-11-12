// Claude watches videos (plans/claude-video-vision.md Stage 1): the watch tool returns timestamped contact sheets of
// motion-picked frames for a fixture video, only within the person's studio, one ffmpeg pipeline at a time; a video
// attached to a chat is watched by its uploadId.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { takes, uploads, users } from '../src/db/schema.js';
import { assistantOf } from '../src/recreate/assistant.js';
import { attachmentLine, imageBlocks, storeAttachments } from '../src/camera/claudeAttachments.js';
import { registryByName, toolsForUser } from '../src/claude/registry.js';
import { budgetFor, CLOSER_SWEEP_MAX, IMAGE_CAP, MAX_SHEETS, SWEEP_MAX, SWEEP_TILES, sweepFps, sweepFrames, sweepWindows, watchConcurrency } from '../src/claude/watch.js';
import { makeApp, people, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
type App = Awaited<ReturnType<typeof makeApp>>;
type Sweep = { frames: number; fps?: number; sheets: number; fromSec?: number; toSec?: number; windows?: { fromSec: number; toSec: number; frames: number }[]; note?: string };
type Out = { mcpContent: { type: string; text?: string; data?: string; mimeType?: string }[]; durationSec: number; fps: number; cuts: number[]; frames: number[]; sound: { present: boolean }; everyFrame?: boolean; sweep: Sweep; sheets: number };

describe.skipIf(!hasFfmpeg)('Claude watches videos', () => {
  let a: App, owner: Client, member: Client, memberU: AuthUser, ownerU: AuthUser, studioId: string, dir: string;
  const authUser = async (c: Client, role: 'owner' | 'member'): Promise<AuthUser> => {
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, c.id));
    studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${c.id}`)) as any).rows[0].studio_id;
    return { id: u!.id, studioId, email: u!.email, role, studioName: 'Test Studio', sessionId: null };
  };
  const take = (id: string, sid: string, key: string) => a.ctx.db.insert(takes).values({ id, studioId: sid, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: `Take ${id}`,
    label: 'HD', engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: key, media: { durationSec: 4 }, createdAt: Date.now() });
  const call = (u: AuthUser, name: string, input: Record<string, unknown>) => assistantOf(a.ctx).runChatTool(u, 'chat_x', name, input) as Promise<Out>;

  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 0 }) as any);
    ownerU = await authUser(owner, 'owner'); memberU = await authUser(member, 'member');
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-watch-t-'));
    // 4 s portrait, 30 fps, a tone: a box that moves fast at 1.0–1.3 s, then a hard cut at 2.0 s to another picture.
    const x = "if(between(t,1,1.3),40+(t-1)*300,if(gt(t,1.3),130,10))";
    const file = path.join(dir, 'v.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=gray:s=180x320:d=2:r=30', '-f', 'lavfi', '-i', 'color=c=white:s=40x40:d=2:r=30',
      '-f', 'lavfi', '-i', 'testsrc2=s=180x320:d=2:r=30', '-f', 'lavfi', '-i', 'sine=f=440:d=4',
      '-filter_complex', `[0][1]overlay=x='${x}':y=140:eval=frame[a];[a][2]concat=n=2:v=1[v]`, '-map', '[v]', '-map', '3:a',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-r', '30', '-c:a', 'aac', '-shortest', file]);
    const buf = fs.readFileSync(file);
    for (const k of ['c/w1.mp4', 'c/w2.mp4', 'c/w3.mp4', 'u/w4.mp4']) await a.ctx.storage.put(k, buf, 'video/mp4');
    // A 23 s clip (the owner's case) and a 65 s one (past the sweep cap), small and quick to make.
    for (const [k, d, r] of [['c/w23.mp4', 23, 30], ['c/w65.mp4', 65, 10]] as const) {
      const f = path.join(dir, path.basename(k));
      execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', `testsrc2=s=160x288:d=${d}:r=${r}`, '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', f]);
      await a.ctx.storage.put(k, fs.readFileSync(f), 'video/mp4');
    }
    await take('take_w1', studioId, 'c/w1.mp4'); await take('take_w2', studioId, 'c/w2.mp4'); await take('take_w3', studioId, 'c/w3.mp4');
    await take('take_other', 'studio_other', 'c/w1.mp4');
    await take('take_23', studioId, 'c/w23.mp4'); await take('take_65', studioId, 'c/w65.mp4');
    await a.ctx.db.insert(uploads).values({ id: 'up_vid', studioId, kind: 'clip', storageKey: 'u/w4.mp4', contentType: 'video/mp4', bytes: buf.length, state: 'ready', createdAt: Date.now() });
  }, 60_000);
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  it('is in the one registry for owner and members, and tells Claude to watch before judging', () => {
    for (const n of ['watch', 'watch_closer']) {
      expect(registryByName.get(n)?.pages).toEqual(['any']);
      expect(toolsForUser({ role: 'member' }).map(t => t.name)).toContain(n);
    }
    expect(registryByName.get('watch')!.description).toMatch(/ALWAYS watch a video before you judge/);
  });

  it('watch: a flip book of timestamped JPEG contact sheets, the cut, the length, fps and sound', async () => {
    const r = await call(memberU, 'watch', { id: 'take_w1' });
    expect(r.durationSec).toBeCloseTo(4, 0);
    expect(r.fps).toBe(30);
    expect(r.sound.present).toBe(true);
    expect(r.cuts.some(t => Math.abs(t - 2) < 0.05)).toBe(true);
    const imgs = r.mcpContent.filter(b => b.type === 'image');
    expect(imgs.length).toBeGreaterThanOrEqual(1);
    expect(imgs.every(b => b.mimeType === 'image/jpeg' && Buffer.from(b.data!, 'base64').length < 300_000)).toBe(true);
    expect(r.mcpContent.some(b => /Sheet 1\/\d: 0:00\.00–/.test(b.text ?? ''))).toBe(true);
    // Motion-picked: the fast 1.0–1.3 s move gets more frames than the still 0–1 s stretch, and both sides of the cut are there.
    const inMove = r.frames.filter(t => t >= 1 && t <= 1.35).length, inStill = r.frames.filter(t => t > 0.05 && t < 0.95).length;
    expect(inMove).toBeGreaterThan(inStill);
    expect(r.frames.some(t => Math.abs(t - 2) < 0.04) && r.frames.some(t => Math.abs(t - 1.967) < 0.04)).toBe(true);
  }, 60_000);

  it('watch_closer: every frame of a short window, each labelled', async () => {
    const r = await call(ownerU, 'watch_closer', { id: 'take_w1', fromSec: 1, toSec: 1.3 });
    expect(r.everyFrame).toBe(true);
    expect(r.frames.length).toBe(10);
    expect(r.mcpContent.filter(b => b.type === 'image').length).toBe(1);
    const one = await call(ownerU, 'watch_closer', { id: 'take_w1', fromSec: 2.5 });
    expect(one.frames).toHaveLength(1);
  }, 60_000);

  it('the sweep rate and frame count by length: dense for short clips, lighter for long, none past 60 s', () => {
    const at = (sec: number) => ({ fps: Math.round(sweepFps(sec, 30) * 10) / 10, frames: sweepFrames(sec, 30).length });
    expect(at(6)).toEqual({ fps: 8, frames: 48 });
    expect(at(15)).toEqual({ fps: 8, frames: 120 });
    expect(at(23)).toEqual({ fps: 8, frames: 184 });
    expect(at(30).fps).toBeGreaterThanOrEqual(6); expect(at(30).frames).toBe(SWEEP_MAX);
    expect(at(60)).toEqual({ fps: 3.2, frames: SWEEP_MAX });
    expect(at(300)).toEqual({ fps: 0, frames: 0 });
    // Never above the video's own rate; never fewer frames than the overview had alone.
    expect(sweepFrames(10, 6).length).toBe(60);
    for (const sec of [1, 3, 6, 15, 23, 30, 45, 60]) {
      const f = sweepFrames(sec, 30);
      expect(f.length + budgetFor(sec)).toBeGreaterThan(budgetFor(sec));
      expect(f[0]).toBe(0); expect(f.at(-1)).toBe(Math.floor(sec * 30) - 1);
      expect(Math.ceil(f.length / SWEEP_TILES) + MAX_SHEETS).toBeLessThanOrEqual(IMAGE_CAP);
      expect(sweepFrames(sec, 30)).toEqual(f);
    }
    // Long: consecutive windows that cover every second.
    const w = sweepWindows(300);
    expect(w).toHaveLength(10);
    expect(w[0]).toEqual({ fromSec: 0, toSec: 30, frames: CLOSER_SWEEP_MAX });
    for (let i = 1; i < w.length; i++) expect(w[i]!.fromSec).toBe(w[i - 1]!.toSec);
    expect(w.at(-1)!.toSec).toBe(300);
    expect(sweepWindows(65).map(x => x.toSec)).toEqual([30, 60, 65]);
  });

  it('a 23 s clip is swept whole, about 8 frames a second, beside the overview, under the image cap', async () => {
    const t0 = Date.now();
    const r = await call(ownerU, 'watch', { id: 'take_23' });
    const ms = Date.now() - t0;
    expect(r.durationSec).toBeCloseTo(23, 0);
    expect(r.sweep.frames).toBe(184);
    expect(r.sweep.fps).toBeGreaterThanOrEqual(7.9);
    expect(r.sweep.fromSec).toBe(0); expect(r.sweep.toSec).toBeGreaterThan(22.9);
    expect(r.sweep.sheets).toBe(8);
    expect(r.frames.length).toBe(budgetFor(23));
    const imgs = r.mcpContent.filter(b => b.type === 'image');
    expect(imgs.length).toBe(r.sheets + r.sweep.sheets);
    expect(imgs.length).toBeLessThanOrEqual(IMAGE_CAP);
    expect(imgs.every(b => Buffer.from(b.data!, 'base64').length < 300_000)).toBe(true);
    expect(r.mcpContent.some(b => /^Sweep 1\/8: 0:00\.00–/.test(b.text ?? ''))).toBe(true);
    expect(r.mcpContent.some(b => /^Sweep 8\/8: .*–0:2[23]\./.test(b.text ?? ''))).toBe(true);
    console.log(`watch 23 s clip: ${ms} ms, ${imgs.length} images, ${Math.round(imgs.reduce((s, b) => s + b.data!.length, 0) / 1024)} KB base64`);
    // Same input, same output (and cached).
    expect(await call(ownerU, 'watch', { id: 'take_23' })).toEqual(r);
  }, 120_000);

  it('past 60 s: the overview and a note to sweep every window with watch_closer; a window sweep works', async () => {
    const r = await call(ownerU, 'watch', { id: 'take_65' });
    expect(r.sweep.frames).toBe(0);
    expect(r.sweep.windows!.map(w => [w.fromSec, w.toSec])).toEqual([[0, 30], [30, 60], [60, 65]]);
    expect(r.sweep.note).toMatch(/watch_closer.*every second/);
    expect(r.mcpContent.filter(b => b.type === 'image').length).toBe(r.sheets);
    const w = await call(ownerU, 'watch_closer', { id: 'take_65', fromSec: 30, toSec: 60, frames: CLOSER_SWEEP_MAX });
    expect(w.frames.length).toBe(CLOSER_SWEEP_MAX);
    expect(w.mcpContent.filter(b => b.type === 'image').length).toBe(CLOSER_SWEEP_MAX / SWEEP_TILES);
  }, 180_000);

  it('only the person\'s own studio', async () => {
    await expect(call(memberU, 'watch', { id: 'take_other' })).rejects.toMatchObject({ status: 404 });
  });

  it('runs one ffmpeg pipeline at a time', async () => {
    await Promise.all([call(ownerU, 'watch', { id: 'take_w2' }), call(ownerU, 'watch', { id: 'take_w3' })]);
    expect(watchConcurrency()).toBe(1);
  }, 60_000);

  it('a video attached to a chat is kept as the upload and watched by its uploadId', async () => {
    const att = await storeAttachments(a.ctx, ownerU, 'th_x', [{ uploadId: 'up_vid' }]);
    expect(att[0]).toMatchObject({ uploadId: 'up_vid', video: true, key: 'u/w4.mp4' });
    expect(await imageBlocks(a.ctx, att)).toEqual([]);
    expect(attachmentLine(att)).toMatch(/Attached video: uploadId up_vid .*watch/);
    const r = await call(ownerU, 'watch', { id: 'up_vid' });
    expect(r.frames.length).toBeGreaterThan(5);
  }, 60_000);
});
