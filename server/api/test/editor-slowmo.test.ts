// Smooth slow motion (src/editor/slowmo.ts, kind "slowmo") against a fake fal queue on localhost: no network, no
// spend. The range is cut and sent, fal's answer (fps × factor) is retimed to factor × longer at the source's rate,
// the job settles on fal's reported compute seconds, the cut sent to fal is deleted, failures give the hold back.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import type { AddressInfo } from 'node:net';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq, sql } from 'drizzle-orm';
import { ledger, takes } from '../src/db/schema.js';
import { editorAi } from '../src/editor/service.js';
import { SLOWMO_MODEL, slowmoComputeSec, slowmoUsd } from '../src/editor/slowmo.js';
import { probe } from '../src/replicate/media.js';
import { makeApp, people, until, type Client } from './helpers.js';
import { hasFfmpeg } from './recreate-fixture.js';

describe('slow motion pricing (unit)', () => {
  it('grows with frames made and picture size; at least a cent', () => {
    expect(slowmoComputeSec(2, 30, 4, 1080, 1920)).toBeGreaterThan(slowmoComputeSec(2, 30, 2, 1080, 1920));
    expect(slowmoComputeSec(2, 30, 2, 360, 640)).toBeLessThan(slowmoComputeSec(2, 30, 2, 1080, 1920));
    expect(slowmoUsd(1, 2)).toBe(0.01);
    expect(slowmoUsd(100, 2, 0.0013)).toBeCloseTo(0.26, 6);
  });
});

describe.skipIf(!hasFfmpeg)('slow motion job (fake fal)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, fal: http.Server, base = '';
  const requests: { url: string; auth?: string; body?: any }[] = [];
  let fail = false, polls = 0, rangeSec = 2;
  const files = new Map<string, string>();

  beforeAll(async () => {
    fal = http.createServer((req, res) => {
      let body = '';
      req.on('data', c => { body += c; });
      req.on('end', () => {
        const url = req.url ?? '';
        requests.push({ url, auth: req.headers.authorization, body: body ? JSON.parse(body) : undefined });
        const json = (o: unknown, status = 200) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (req.method === 'POST' && url === `/${SLOWMO_MODEL.ref}`) {
          const n = JSON.parse(body).num_frames as number, id = `req${requests.length}`;
          // What RIFE gives back: the same length, (num_frames + 1) × the frames.
          const f = path.join(a.dir, `${id}.mp4`);
          execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', `testsrc2=s=360x640:r=${30 * (n + 1)}:d=${rangeSec}`, '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-y', f]);
          files.set(id, f);
          const r = `${base}/fal-ai/rife/requests/${id}`;
          return json({ request_id: id, status_url: `${r}/status`, response_url: r, cancel_url: `${r}/cancel` });
        }
        const m = /^\/fal-ai\/rife\/requests\/(\w+)(\/status|\/cancel)?$/.exec(url);
        if (m && m[2] === '/status') {
          if (++polls % 2 === 1) return json({ status: 'IN_PROGRESS' });
          return fail ? json({ status: 'FAILED', error: 'runner crashed' }) : json({ status: 'COMPLETED', metrics: { inference_time: 12.5 } });
        }
        if (m && m[2] === '/cancel') return json({ status: 'OK' });
        if (m) return json({ video: { url: `${base}/files/${m[1]}.mp4`, content_type: 'video/mp4' } });
        const fm = /^\/files\/(\w+)\.mp4$/.exec(url);
        if (fm && files.has(fm[1]!)) { res.writeHead(200, { 'content-type': 'video/mp4' }); return fs.createReadStream(files.get(fm[1]!)!).pipe(res); }
        json({ detail: 'not found' }, 404);
      });
    });
    await new Promise<void>(r => fal.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(fal.address() as AddressInfo).port}`;
    a = await makeApp({ FAL_KEY: 'test-fal-key', FAL_QUEUE_URL: base });
    const p = await people(a, 1);
    owner = p.owner; member = p.members[0]!;
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: (member as any).id, tokens: 1000, note: 'test' });
    editorAi(a.ctx).falPollMs = 20;
  }, 60_000);
  afterAll(async () => { await a?.close(); await new Promise(r => fal?.close(r)); });

  const take = async () => {
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id as string;
    const id = `take_${Math.random().toString(16).slice(2, 10)}`, f = path.join(a.dir, `${id}.mp4`);
    execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=360x640:r=30:d=4', '-f', 'lavfi', '-i', 'sine=frequency=330:duration=4',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', '-y', f]);
    await a.ctx.storage.put(`c/${id}.mp4`, fs.readFileSync(f), 'video/mp4');
    await a.ctx.db.insert(takes).values({ id, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 't', label: 'HD', engineLabel: 'HD', cost: 1, seed: 1,
      status: 'final', thumb: null, prompt: 'p', mediaKey: `c/${id}.mp4`, media: { durationSec: 4, width: 360, height: 640, fps: 30, contentType: 'video/mp4' }, createdAt: Date.now() });
    return id;
  };
  const done = (c: Client, id: string) => until(async () => { const x = (await c.req('GET', `/v1/editor/jobs/${id}`)).body; return x.state !== 'running' ? x : null; });
  const leftovers = () => fs.existsSync(path.join(a.dir, 't')) ? fs.readdirSync(path.join(a.dir, 't')).filter(f => f.startsWith('slowin')) : [];

  it('estimates, runs on fal, retimes to factor × longer at the source rate, and settles on fal’s compute seconds', async () => {
    const src = await take();
    expect((await owner.req('GET', '/v1/editor/features')).body.slowmo).toMatchObject({ available: true, factors: [2, 4] });
    const bad = async (options: unknown) => (await owner.req('POST', '/v1/editor/estimate', { kind: 'slowmo', source: { takeId: src }, options })).body.error;
    expect(await bad({ factor: 3, startSec: 0, endSec: 1 })).toMatch(/2 or 4/);
    expect(await bad({ factor: 2, startSec: 1, endSec: 1.1 })).toMatch(/range must be/);
    expect(await bad({ factor: 2, startSec: 0, endSec: 11 })).toMatch(/range must be/);
    expect(await bad({ factor: 2, startSec: 3, endSec: 5 })).toMatch(/within the clip/);

    const options = { factor: 2, startSec: 1, endSec: 3 };
    const est = (await owner.req('POST', '/v1/editor/estimate', { kind: 'slowmo', source: { takeId: src }, options })).body;
    expect(est.usd).toBeCloseTo(slowmoUsd(slowmoComputeSec(2, 30, 2, 360, 640), 2), 6);
    rangeSec = 2;
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'slowmo', source: { takeId: src }, options })).body;
    expect(j.models).toEqual([SLOWMO_MODEL.ref]);
    const r = await done(owner, j.id);
    expect(r.state, JSON.stringify(r)).toBe('done');
    expect(r.result).toMatchObject({ factor: 2, startSec: 1, endSec: 3, fps: 30, hasAudio: false, durationSec: 4, reused: false });
    const sent = requests.find(x => x.body?.video_url)!;
    expect(sent.auth).toBe('Key test-fal-key');
    expect(sent.body).toMatchObject({ num_frames: 1, use_calculated_fps: true });
    // The stored clip: 4 s at 30 fps, every interpolated frame kept, no sound.
    const key = new URL(r.result.asset.url, 'http://x').pathname.replace(/^\/uploads\//, '');
    const out = path.join(a.dir, 'out.mp4');
    fs.writeFileSync(out, Buffer.concat(await (async () => { const o = await a.ctx.storage.get(key); const bs: Buffer[] = []; for await (const c of o!.body as any) bs.push(c); return bs; })()));
    const info = await probe('ffprobe', out);
    expect(Math.abs(info.duration - 4)).toBeLessThan(0.1); expect(Math.round(info.fps)).toBe(30); expect(info.audioCodec).toBeNull();
    expect(r.costUsd).toBeCloseTo(slowmoUsd(12.5, 2), 6);
    expect((await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id))).map(x => x.kind).sort()).toEqual(['hold', 'settle']);
    expect(leftovers()).toEqual([]);

    // The same range again is reused, free; a member never sees the model or the vendor.
    const again = (await member.req('POST', '/v1/editor/estimate', { kind: 'slowmo', source: { takeId: src }, options })).body;
    expect(again.usd).toBe(0);
    rangeSec = 1;
    const m = (await member.req('POST', '/v1/editor/jobs', { kind: 'slowmo', source: { takeId: src }, options: { factor: 4, startSec: 0.5, endSec: 1.5 } })).body;
    expect(m.models).toBeUndefined();
    const mr = await done(member, m.id);
    expect(mr.state, JSON.stringify(mr)).toBe('done');
    expect(mr.result).toMatchObject({ factor: 4, durationSec: 4 });
    expect(requests.filter(x => x.body?.video_url).at(-1)!.body.num_frames).toBe(3);
    expect(JSON.stringify(mr)).not.toMatch(/\b(fal|rife|film)\b|fal-ai|fal\.run/i);
  }, 120_000);

  it('a fal failure fails the job, gives the hold back and leaves nothing behind; the owner’s switch stops it', async () => {
    const src = await take();
    fail = true; rangeSec = 1;
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'slowmo', source: { takeId: src }, options: { factor: 2, startSec: 0, endSec: 1 } })).body;
    const r = await done(owner, j.id);
    fail = false;
    expect(r.state).toBe('failed');
    expect((await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id))).map(x => x.kind).sort()).toEqual(['hold', 'release']);
    expect(leftovers()).toEqual([]);
    await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'off' });
    expect((await owner.req('POST', '/v1/editor/jobs', { kind: 'slowmo', source: { takeId: src }, options: { factor: 2, startSec: 0, endSec: 1 } })).status).toBe(503);
    expect((await owner.req('GET', '/v1/editor/features')).body.slowmo.available).toBe(false);
    await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'on' });
  }, 120_000);
});
