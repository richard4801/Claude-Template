// Edited versions of a take (plans/api.md "Video editor"): the app uploads an MP4 it encoded on the device; the server
// checks the edit list, links it to its source and tells the studio. No encoding, no charge.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { takes } from '../src/db/schema.js';
import { checkEditList, outputSeconds, type EditList } from '../src/routes/versions.js';
import { eq, sql } from 'drizzle-orm';
import { makeApp, people, sse, until, type Client } from './helpers.js';

type A = Awaited<ReturnType<typeof makeApp>>;
const studioOf = async (a: A) => ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows?.[0]?.studio_id as string;

async function videoTake(a: A, studioId: string, o: { id?: string; kind?: 'take' | 'shot'; durationSec?: number } = {}) {
  const id = o.id ?? `take_src${Math.random().toString(16).slice(2, 8)}`;
  await a.ctx.storage.put(`c/${id}.mp4`, Buffer.from('source video'), 'video/mp4');
  await a.ctx.db.insert(takes).values({ id, studioId, userId: null, kind: o.kind ?? 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'Beach walk',
    label: 'HD', engineLabel: 'HD · 2K', cost: 1.2, seed: 7, status: 'final', thumb: { url: '/uploads/g/src.jpg' }, prompt: 'p', mediaKey: `c/${id}.mp4`,
    media: { durationSec: o.durationSec ?? 10, width: 1440, height: 2560, fps: 30 }, createdAt: Date.now() - 1000 });
  return id;
}

/** presign → PUT (local storage) → the uploadId. */
async function upload(a: A, c: Client, kind: 'clip' | 'image', body: Buffer, contentType = kind === 'clip' ? 'video/mp4' : 'image/jpeg') {
  const p = (await c.req('POST', '/v1/uploads/presign', { kind, contentType, bytes: body.length })).body;
  const u = new URL(p.url);
  const r = await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': contentType }, payload: body });
  expect(r.statusCode).toBe(200);
  return p.uploadId as string;
}

const edits = (sourceTakeId: string, segments: EditList['segments'] = [{ inSec: 0, outSec: 3, speed: 1 }, { inSec: 4, outSec: 8, speed: 2 }], mute = false): EditList =>
  ({ version: 1, sourceTakeId, sourceDurationSec: 10, segments, mute });

describe('edit list rules', () => {
  it('output seconds: each kept part divided by its speed', () => {
    expect(outputSeconds(edits('t'))).toBe(5);
    expect(outputSeconds({ segments: [{ inSec: 0, outSec: 2, speed: 1 }, { inSec: 2, outSec: 4, speed: 0.5 }, { inSec: 4, outSec: 10, speed: 1 }] })).toBe(12);
    expect(checkEditList(edits('t'))).toBe(5);
  });
  it('rejects overlap, out of order, too short, past the end', () => {
    expect(() => checkEditList(edits('t', [{ inSec: 0, outSec: 5, speed: 1 }, { inSec: 4, outSec: 8, speed: 1 }]))).toThrow(/order and not overlap/);
    expect(() => checkEditList(edits('t', [{ inSec: 5, outSec: 8, speed: 1 }, { inSec: 0, outSec: 2, speed: 1 }]))).toThrow(/order/);
    expect(() => checkEditList(edits('t', [{ inSec: 1, outSec: 1.05, speed: 1 }, { inSec: 2, outSec: 4, speed: 1 }]))).toThrow(/at least 0.1/);
    expect(() => checkEditList(edits('t', [{ inSec: 0, outSec: 10.2, speed: 1 }]))).toThrow(/past the end/);
    expect(() => checkEditList(edits('t', [{ inSec: 0, outSec: 0.6, speed: 2 }]))).toThrow(/at least 0.5 s/);
    expect(checkEditList(edits('t', [{ inSec: 0, outSec: 10.04, speed: 1 }]))).toBeCloseTo(10.04);
  });
});

describe('POST/GET /v1/takes/{id}/versions', () => {
  let a: A, owner: Client, member: Client, studioId: string, src: string;
  beforeAll(async () => {
    a = await makeApp();
    ({ owner, members: [member] } = await people(a, 1) as any);
    studioId = await studioOf(a);
    src = await videoTake(a, studioId);
  });
  afterAll(async () => { await a.close(); });

  it('a member saves an edited version: new take kind "edit", linked, free, live to everyone', async () => {
    await a.app.listen({ port: 0, host: '127.0.0.1' });
    const base = `http://127.0.0.1:${(a.app.server.address() as any).port}`;
    const oEs = await sse(base, owner.token);
    const before = (await member.req('GET', '/v1/balance')).body;
    const up = await upload(a, member, 'clip', Buffer.from('edited mp4 bytes'));
    const th = await upload(a, member, 'image', Buffer.from('jpeg'));
    const r = await member.req('POST', `/v1/takes/${src}/versions`, { uploadId: up, thumbUploadId: th, edits: edits(src), durationSec: 5.02, width: 1440, height: 2560, fps: 30 });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ kind: 'edit', parentTakeId: src, label: 'Edited', cost: 0, status: 'test', title: 'Beach walk', engineLabel: 'HD · 2K',
      durationSec: 5.02, width: 1440, height: 2560, fps: 30, edits: edits(src) });
    expect(r.body.videoUrl).toMatch(/\/uploads\/c\/up_[0-9a-f]+\.mp4$/);
    expect(r.body.thumb.url).toMatch(/\/uploads\/u\/up_[0-9a-f]+\.jpg$/);
    expect(r.body.jobId ?? null).toBeNull();
    const ev = await until(() => oEs.events.find(e => e.type === 'take' && e.take?.id === r.body.id));
    expect(ev.take).toMatchObject({ kind: 'edit', parentTakeId: src });
    await oEs.stop();
    // Free: nothing moved.
    expect((await member.req('GET', '/v1/balance')).body.balance).toBe(before.balance);
    // Listed under its source, and in the gallery; the source is unchanged.
    const vs = (await owner.req('GET', `/v1/takes/${src}/versions`)).body;
    expect(vs.map((t: any) => t.id)).toEqual([r.body.id]);
    const all = (await owner.req('GET', '/v1/takes')).body;
    expect(all.find((t: any) => t.id === r.body.id)).toMatchObject({ kind: 'edit', parentTakeId: src });
    expect(all.find((t: any) => t.id === src)).toMatchObject({ kind: 'take', status: 'final', durationSec: 10 });
    expect(all.find((t: any) => t.id === src).parentTakeId).toBeUndefined();
    // Same take rules: approve and discard.
    expect((await owner.req('PATCH', `/v1/takes/${r.body.id}`, { status: 'final' })).body.status).toBe('final');
  });

  it('the same upload cannot be saved twice; a missing PUT is upload_missing', async () => {
    const up = await upload(a, owner, 'clip', Buffer.from('v2'));
    const body = { uploadId: up, edits: edits(src), durationSec: 5, width: 1440, height: 2560 };
    expect((await owner.req('POST', `/v1/takes/${src}/versions`, body)).status).toBe(200);
    const again = await owner.req('POST', `/v1/takes/${src}/versions`, body);
    expect(again).toMatchObject({ status: 409, body: { code: 'upload_used' } });
    const p = (await owner.req('POST', '/v1/uploads/presign', { kind: 'clip', contentType: 'video/mp4' })).body;
    expect(await owner.req('POST', `/v1/takes/${src}/versions`, { ...body, uploadId: p.uploadId })).toMatchObject({ status: 409, body: { code: 'upload_missing' } });
    // Two versions now, newest first.
    const vs = (await owner.req('GET', `/v1/takes/${src}/versions`)).body;
    expect(vs.length).toBe(2);
    expect(vs[0].createdAt).toBeGreaterThanOrEqual(vs[1].createdAt);
  });

  it('validation: edit list schema, max segments, speeds, duration match, sizes', async () => {
    const up = await upload(a, owner, 'clip', Buffer.from('v3'));
    const ok = { uploadId: up, edits: edits(src), durationSec: 5, width: 1440, height: 2560 };
    const bad = async (patch: Record<string, unknown>, msg: RegExp) => {
      const r = await owner.req('POST', `/v1/takes/${src}/versions`, { ...ok, ...patch });
      expect(r.status, JSON.stringify(r.body)).toBe(400);
      expect(r.body.code).toBe('bad_request');
      expect(r.body.error).toMatch(msg);
    };
    await bad({ edits: undefined }, /edits/);
    await bad({ edits: { ...edits(src), version: 3 } }, /edits\.version/);
    await bad({ edits: { ...edits(src), segments: [] } }, /edits\.segments/);
    await bad({ edits: edits(src, [{ inSec: 0, outSec: 3, speed: 3 as any }]) }, /edits\.segments\.0\.speed: must be one of 0.5, 0.75, 1, 1.25, 1.5, 2/);
    await bad({ edits: edits(src, [{ inSec: 0, outSec: 3, speed: 1, extra: 1 } as any]) }, /edits\.segments\.0/);
    const many = Array.from({ length: 51 }, (_, i) => ({ inSec: i * 0.15, outSec: i * 0.15 + 0.1, speed: 1 as const }));
    await bad({ edits: edits(src, many) }, /at most 50 segments/);
    await bad({ edits: edits(src, [{ inSec: 0, outSec: 5, speed: 1 }, { inSec: 4, outSec: 8, speed: 1 }]) }, /overlap/);
    await bad({ edits: { ...edits(src), sourceTakeId: 'take_other' } }, /sourceTakeId/);
    await bad({ durationSec: 9 }, /durationSec.*doesn't match/);
    await bad({ width: 8000 }, /width/);
    await bad({ edits: { ...edits(src), note: 'x'.repeat(20_000) } }, /KB/);
    await bad({ thumb: { asset: 'g_front' } }, /thumb/);
    await bad({ thumb: { url: 'https://example.com/x.jpg' } }, /thumb/);
  });

  it('50 segments are allowed', async () => {
    const up = await upload(a, owner, 'clip', Buffer.from('v50'));
    const fifty = Array.from({ length: 50 }, (_, i) => ({ inSec: i * 0.15, outSec: i * 0.15 + 0.1, speed: 1 as const }));
    const r = await owner.req('POST', `/v1/takes/${src}/versions`, { uploadId: up, edits: edits(src, fifty), durationSec: 5, width: 1440, height: 2560 });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.edits.segments.length).toBe(50);
    expect(r.body.thumb).toEqual({ url: '/uploads/g/src.jpg' }); // no client thumb: the source's (a frame may replace it later)
  });

  it('ownership: another studio\'s take or upload is not found; photos and image uploads are refused', async () => {
    const other = await videoTake(a, 'st_someone_else');
    const up = await upload(a, owner, 'clip', Buffer.from('v4'));
    const body = (id: string) => ({ uploadId: up, edits: edits(id), durationSec: 5, width: 1440, height: 2560 });
    expect(await owner.req('POST', `/v1/takes/${other}/versions`, body(other))).toMatchObject({ status: 404, body: { code: 'not_found' } });
    expect((await owner.req('GET', `/v1/takes/${other}/versions`)).status).toBe(404);
    expect((await owner.req('GET', `/v1/takes/take_nope/versions`)).status).toBe(404);
    const shot = await videoTake(a, studioId, { kind: 'shot' });
    await a.ctx.db.update(takes).set({ mediaKey: null }).where(eq(takes.id, shot));
    expect(await owner.req('POST', `/v1/takes/${shot}/versions`, body(shot))).toMatchObject({ status: 400, body: { error: 'Edit works on a video take' } });
    const img = await upload(a, owner, 'image', Buffer.from('jpeg'));
    expect(await owner.req('POST', `/v1/takes/${src}/versions`, { ...body(src), uploadId: img })).toMatchObject({ status: 400, body: { error: 'uploadId: must be a video upload' } });
    // An upload row of another studio.
    await a.ctx.db.execute(sql`update uploads set studio_id = 'st_someone_else' where id = ${up}`);
    expect(await owner.req('POST', `/v1/takes/${src}/versions`, body(src))).toMatchObject({ status: 404 });
    expect((await owner.req('POST', `/v1/takes/${src}/versions`, body(src))).body.error).toBe('Upload not found');
    // No session.
    expect((await a.app.inject({ method: 'GET', url: `/v1/takes/${src}/versions` })).statusCode).toBe(401);
  });

  it('a version of a version (its source deleted): parent is the version; deleting a source keeps its versions', async () => {
    const s2 = await videoTake(a, studioId);
    const v1 = (await owner.req('POST', `/v1/takes/${s2}/versions`, { uploadId: await upload(a, owner, 'clip', Buffer.from('a')), edits: edits(s2), durationSec: 5, width: 1440, height: 2560 })).body;
    expect((await owner.req('DELETE', `/v1/takes/${s2}`)).status).toBe(204);
    expect((await owner.req('GET', '/v1/takes')).body.find((t: any) => t.id === v1.id)).toMatchObject({ parentTakeId: s2 });
    const e2 = { version: 1, sourceTakeId: v1.id, sourceDurationSec: 5, segments: [{ inSec: 0, outSec: 4, speed: 1 }], mute: true };
    const v2 = await owner.req('POST', `/v1/takes/${v1.id}/versions`, { uploadId: await upload(a, owner, 'clip', Buffer.from('b')), edits: e2, durationSec: 4, width: 1440, height: 2560 });
    expect(v2.status, JSON.stringify(v2.body)).toBe(200);
    expect(v2.body).toMatchObject({ kind: 'edit', parentTakeId: v1.id, edits: { mute: true } });
    expect((await owner.req('GET', `/v1/takes/${v1.id}/versions`)).body.map((t: any) => t.id)).toEqual([v2.body.id]);
  });
});

describe('server thumbnail when the app sends none (single frame, no re-encode)', () => {
  const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version'], { stdio: 'ignore' }); execFileSync('ffprobe', ['-version'], { stdio: 'ignore' }); return true; } catch { return false; } })();
  it.runIf(hasFfmpeg)('grabs a frame and sends a take event with the new thumb', async () => {
    const a = await makeApp();
    try {
      const { owner } = await people(a, 0);
      await a.app.listen({ port: 0, host: '127.0.0.1' });
      const base = `http://127.0.0.1:${(a.app.server.address() as any).port}`;
      const studioId = await studioOf(a);
      const src = await videoTake(a, studioId);
      const mp4 = path.join(a.dir, 'tiny.mp4');
      execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=64x112:d=1:r=10', '-pix_fmt', 'yuv420p', mp4]);
      const up = await upload(a, owner, 'clip', fs.readFileSync(mp4));
      const es = await sse(base, owner.token);
      const r = await owner.req('POST', `/v1/takes/${src}/versions`, { uploadId: up, edits: edits(src, [{ inSec: 0, outSec: 1, speed: 1 }]), durationSec: 1, width: 64, height: 112 });
      expect(r.status).toBe(200);
      const ev = await until(() => es.events.find(e => e.type === 'take' && e.take?.id === r.body.id && /\/uploads\/g\/thumb_/.test(e.take.thumb?.url ?? '')), 20_000);
      expect(ev.take.kind).toBe('edit');
      await es.stop();
    } finally { await a.close(); }
  });
});
