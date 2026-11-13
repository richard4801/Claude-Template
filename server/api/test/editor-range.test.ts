// Owner report ci_238dd2979f5a (2026-11-13): Remove background on a 1.8 s piece of a 102 s source was estimated on the
// whole source and settled at twice the estimate. Now an item-scoped helper sends (and prices) the item's window, the
// result is put back at its place in the source, and a settle never exceeds the approved estimate. Mock provider: no money.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { and, eq, sql } from 'drizzle-orm';
import { ledger, takes, users } from '../src/db/schema.js';
import type { AuthUser } from '../src/ctx.js';
import { EDIT_TOOLS } from '../src/editor/mcpTools.js';
import { RANGE, clipWindow, padToSource, parseRange, sourceSec, trimRange } from '../src/editor/range.js';
import { editorAi } from '../src/editor/service.js';
import { editorJobs } from '../src/editor/schema.js';
import { makeApp, people, until, type Client } from './helpers.js';

type A = Awaited<ReturnType<typeof makeApp>>;
const tool = (name: string) => EDIT_TOOLS.find(t => t.name === name)!;
const RATE = 0.000975, MARKUP = 2;
const mattePrice = (sec: number) => Math.round((10 + 4 * sec) * RATE * MARKUP * 10000) / 10000;

describe('source windows (range.ts)', () => {
  it('a 1.8 s piece of a 102 s source is sent as itself plus a small pad', () => {
    const w = clipWindow([{ inSec: 40, outSec: 41.8 }], 102)!;
    expect(w).toEqual({ startSec: 40 - RANGE.padSec, endSec: 41.8 + RANGE.padSec });
    expect(sourceSec({ durationSec: 102, range: w })).toBeCloseTo(2.3, 6);
    expect(clipWindow([{ inSec: 0, outSec: 102 }], 102)).toBeNull(); // the whole source: no window
    expect(clipWindow([{ inSec: 101.9, outSec: 102 }], 102)).toEqual({ startSec: 101, endSec: 102 }); // at least 1 s, inside the source
    expect(clipWindow([{ inSec: 3, outSec: 4 }, { inSec: 10, outSec: 12 }], 102)).toEqual({ startSec: 2.75, endSec: 12.25 }); // several clips: their union
  });
  it('parseRange checks and clamps', () => {
    expect(parseRange(undefined, 10)).toBeUndefined();
    expect(parseRange({ startSec: 2, endSec: 12 }, 10)).toEqual({ startSec: 2, endSec: 10 });
    expect(parseRange({ startSec: 0, endSec: 10 }, 10)).toBeUndefined();
    expect(() => parseRange({ startSec: 5, endSec: 4 }, 10)).toThrow(/source.range/);
    expect(() => parseRange({ startSec: 'a' }, 10)).toThrow(/source.range/);
  });
  it('trims the window and pads a result back to the source length, in place', async () => {
    let ok = true;
    const dir = fs.mkdtempSync(path.join(process.env.TMPDIR ?? '/tmp', 'rng-'));
    const src = path.join(dir, 'src.mp4'), cut = path.join(dir, 'cut.mp4'), back = path.join(dir, 'back.mp4');
    try { execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'color=white:size=64x64:rate=30:duration=10', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', src]); } catch { ok = false; }
    if (!ok) return;
    const w = { startSec: 4, endSec: 6.5 };
    await trimRange('ffmpeg', src, cut, w, 'video');
    const dur = (f: string) => Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f]).toString());
    expect(dur(cut)).toBeCloseTo(2.5, 1);
    await padToSource('ffmpeg', cut, back, w, 10, 'video');
    expect(dur(back)).toBeCloseTo(10, 1);
    // Black before and after the window, white (the "matte") inside it.
    const luma = (t: number) => execFileSync('ffmpeg', ['-v', 'error', '-ss', String(t), '-i', back, '-frames:v', '1', '-vf', 'scale=1:1,format=gray', '-f', 'rawvideo', '-'])[0]!;
    expect(luma(2)).toBeLessThan(30);
    expect(luma(5)).toBeGreaterThan(220);
    expect(luma(8)).toBeLessThan(30);
    const aud = path.join(dir, 'a.wav'), audBack = path.join(dir, 'ab.wav');
    execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=300:duration=2.5', '-y', aud]);
    await padToSource('ffmpeg', aud, audBack, w, 10, 'audio');
    expect(dur(audBack)).toBeCloseTo(10, 1);
    fs.rmSync(dir, { recursive: true, force: true });
  }, 60_000);
});

describe('item-scoped paid helpers price and bill the item (mock provider, no money)', () => {
  let a: A, owner: Client, studioId: string, ownerUser: AuthUser;
  const takeId = 'take_long102';
  beforeAll(async () => {
    a = await makeApp();
    ({ owner } = await people(a, 0) as any);
    studioId = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id;
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    await a.ctx.storage.put(`c/${takeId}.mp4`, Buffer.from('source video'), 'video/mp4');
    await a.ctx.db.insert(takes).values({ id: takeId, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'Long', label: 'HD',
      engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: `c/${takeId}.mp4`, media: { durationSec: 102, width: 1080, height: 1920, fps: 30, contentType: 'video/mp4' }, createdAt: Date.now() });
  });
  afterAll(async () => { await a.close(); });
  const env = () => ({ ctx: a.ctx, user: ownerUser, source: 'mcp' as const });
  const done = (id: string) => until(async () => { const r = (await owner.req('GET', `/v1/editor/jobs/${id}`)).body; return r.state !== 'running' ? r : null; }, 15_000);

  it('remove_background on a 1.8 s piece: the estimate and the charge both price ~2.3 s, not 102 s', async () => {
    const sid = (await owner.req('POST', '/v1/edit-sessions', { takeId })).body.id;
    const s0 = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body;
    const clip = s0.project.tracks.find((t: any) => t.kind === 'main').items[0];
    await tool('apply_edit_ops').run(env(), { sessionId: sid, baseRevision: s0.revision, ops: [{ op: 'trim', clipId: clip.id, inSec: 40, outSec: 41.8 }] });
    const est = await tool('remove_background').run(env(), { sessionId: sid, itemId: clip.id }) as any;
    expect(est).toMatchObject({ needsConfirmation: true });
    expect(est.estimateUsd).toBeCloseTo(mattePrice(1.8 + 2 * RANGE.padSec), 4);
    expect(est.estimateUsd).toBeLessThan(mattePrice(102) / 10);
    const asked = await tool('remove_background').run(env(), { sessionId: sid, itemId: clip.id, confirm: true }) as any;
    const rev0 = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.revision;
    expect((await owner.req('POST', `/v1/edit-sessions/${sid}/pending/${asked.pendingId}`, { approve: true })).body.status).toBe('running');
    const after = await until(async () => { const s = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body; return s.revision > rev0 ? s : null; }, 15_000);
    const [job] = await a.ctx.db.select().from(editorJobs).where(and(eq(editorJobs.studioId, studioId), eq(editorJobs.kind, 'matte')));
    expect(job!.source).toMatchObject({ takeId, durationSec: 102, range: { startSec: 39.75, endSec: 42.05 } });
    expect(job!.cost).toBeCloseTo(est.estimateUsd, 6);
    expect(Number(job!.cost)).toBeLessThanOrEqual(Number(job!.estimate));
    // The matte is aligned to the clip's own asset (the source's full length), as before.
    const c = after.project.tracks.find((t: any) => t.kind === 'main').items[0];
    expect(after.project.assets.find((x: any) => x.id === c.alphaMatte.asset)).toMatchObject({ kind: 'video', durationSec: 102 });
  }, 30_000);

  it('a provider that bills more than the estimate: the charge is capped at the estimate and the excess is studio overhead', async () => {
    const svc = editorAi(a.ctx), p = svc.provider as any, orig = p.matte.bind(p);
    p.matte = async (url: string, d: number, h: any) => ({ ...(await orig(url, d, h)), gpuSec: 2 * (10 + 4 * d) + 7 }); // ran ~2× over
    try {
      const body = { kind: 'matte', source: { takeId, range: { startSec: 10, endSec: 12 } } };
      const est = (await owner.req('POST', '/v1/editor/estimate', body)).body;
      expect(est.usd).toBeCloseTo(mattePrice(2), 4);
      const j = (await owner.req('POST', '/v1/editor/jobs', body)).body;
      const r = await done(j.id);
      expect(r.state).toBe('done');
      expect(r.costUsd).toBeCloseTo(est.usd, 6);
      const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id));
      expect(rows.find(x => x.kind === 'settle')!.amountUsd).toBeCloseTo(est.usd, 6);
      const over = await a.ctx.db.select().from(ledger).where(and(eq(ledger.kind, 'overhead'), sql`${ledger.note} like ${`%${j.id}%`}`));
      expect(over).toHaveLength(1);
      expect(over[0]!.amountUsd).toBeGreaterThan(0);
    } finally { p.matte = orig; }
  }, 30_000);

  it('a range is refused for helpers that take the whole source, and taps must be inside the window', async () => {
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'captions', source: { takeId, range: { startSec: 1, endSec: 3 } } })).body.error).toMatch(/source.range: only for/);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'matte', source: { takeId, range: { startSec: 10, endSec: 12 } }, options: { points: [{ x: 0.5, y: 0.5, t: 50 }] } })).body.error).toMatch(/within the clip/);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'matte', source: { takeId, range: { startSec: 10, endSec: 12 } }, options: { points: [{ x: 0.5, y: 0.5, t: 11 }] } })).status).toBe(200);
  });
});
