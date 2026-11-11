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
import { watchConcurrency } from '../src/claude/watch.js';
import { makeApp, people, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
type App = Awaited<ReturnType<typeof makeApp>>;
type Out = { mcpContent: { type: string; text?: string; data?: string; mimeType?: string }[]; durationSec: number; fps: number; cuts: number[]; frames: number[]; sound: { present: boolean }; everyFrame?: boolean };

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
    await take('take_w1', studioId, 'c/w1.mp4'); await take('take_w2', studioId, 'c/w2.mp4'); await take('take_w3', studioId, 'c/w3.mp4');
    await take('take_other', 'studio_other', 'c/w1.mp4');
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
