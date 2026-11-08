// workstream 1: reference images attached to Claude chat messages (phone → Mac turn, Mac mirror, API fallback as image
// blocks) and suite_add_reference putting one into the Suite draft. Mock providers and a fake Claude: nothing is spent.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { assistantOf } from '../src/recreate/assistant.js';
import { SUITE_TOOLS } from '../src/suite/mcpTools.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
// A 64×48 HEIC (made with heif-enc); decoding it needs heif-convert with an HEVC decoder (the server image has one).
const HEIC = path.resolve(__dirname, 'fixtures/tiny-64x48.heic');
const hasHeif = (() => { const d = fs.mkdtempSync(path.join(os.tmpdir(), 'heic-probe-')); try { execFileSync('heif-convert', [HEIC, path.join(d, 'x.jpg')], { stdio: 'ignore' }); return true; } catch { return false; } finally { fs.rmSync(d, { recursive: true, force: true }); } })();
const READY = { claudeCode: { installed: true, signedIn: true, version: '2.1.300 (Claude Code)' } };
const img = (w: number, h: number, fmt: 'png' | 'jpeg' | 'webp', color = '#c08040') => sharp({ create: { width: w, height: h, channels: 3, background: color } })[fmt]().toBuffer();

let a: App, owner: Client, ownerUser: AuthUser, model: { id: string; name: string };
async function upload(c: Client, body: Buffer, contentType: string, kind: 'image' | 'clip' = 'image', put = true) {
  const p = (await c.req('POST', '/v1/uploads/presign', { kind, contentType, bytes: body.length })).body;
  if (put) {
    const u = new URL(p.url);
    const r = await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': contentType }, payload: body });
    expect(r.statusCode).toBe(200);
    expect((await c.req('POST', `/v1/uploads/${p.uploadId}/confirm`, kind === 'clip' ? { meta: { title: 'x', durationSec: 2 } } : {})).status).toBeLessThan(300);
  }
  return p.uploadId as string;
}
const fetchSigned = async (url: string) => { const u = new URL(url); return a.app.inject({ method: 'GET', url: u.pathname + u.search }); };
const tool = (n: string) => SUITE_TOOLS.find(t => t.name === n)!;
const env = () => ({ ctx: a.ctx, user: ownerUser, source: 'chat' as const });

beforeAll(async () => {
  a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10', ANTHROPIC_API_KEY: 'test-not-a-real-key' });
  ({ owner } = await people(a, 0, { topUp: 50 }) as any);
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
  ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
  model = await demoModel(owner) as any;
});
afterAll(async () => { await a?.close(); });

describe('attachments on a phone message reach the Mac turn', () => {
  let threadId: string, pngId: string, jpgId: string;
  it('stored privately on the thread, normalised, listed on the message and the turn', async () => {
    const assist = (await owner.req('POST', '/v1/suite/assist', {})).body;
    threadId = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'suite', contextId: assist.id })).body.id;
    await owner.req('POST', '/v1/claude/mac/heartbeat', READY);
    pngId = await upload(owner, await img(300, 200, 'png'), 'image/png');
    jpgId = await upload(owner, await img(3000, 1500, 'jpeg'), 'image/jpeg');
    const r = await owner.req('POST', `/v1/claude/threads/${threadId}/messages`, { text: '', attachments: [{ uploadId: pngId }, { uploadId: jpgId }] });
    expect(r.status, JSON.stringify(r.body)).toBe(202);
    const atts = r.body.message.attachments;
    expect(atts).toEqual([
      expect.objectContaining({ uploadId: pngId, mimeType: 'image/png', width: 300, height: 200, url: expect.any(String) }),
      expect.objectContaining({ uploadId: jpgId, mimeType: 'image/jpeg', width: 2048, height: 1024 }),
    ]);
    expect(JSON.stringify(atts)).not.toMatch(/"key"/);
    const got = await fetchSigned(atts[1].url);
    expect(got.statusCode).toBe(200);
    expect((await sharp(got.rawPayload).metadata()).width).toBe(2048);
    // Not served by the public /uploads route.
    const [row] = (await a.ctx.db.execute(sql`select attachments from claude_messages where thread_id = ${threadId}`) as any).rows;
    expect(row.attachments[0].key).toMatch(/^ca\//);
    expect((await a.app.inject({ method: 'GET', url: `/uploads/${row.attachments[0].key}` })).statusCode).toBe(404);
    // The Mac sees them on the pending turn and the claim.
    const pend = (await owner.req('GET', '/v1/claude/turns')).body;
    expect(pend[0].attachments.map((x: any) => x.uploadId)).toEqual([pngId, jpgId]);
    const claimed = (await owner.req('POST', `/v1/claude/turns/${r.body.turn.id}/claim`)).body;
    expect(claimed.attachments).toHaveLength(2);
    await owner.req('POST', `/v1/claude/threads/${threadId}/events`, { turnId: claimed.id, events: [{ type: 'done', ok: true }] });
    const t = (await owner.req('GET', `/v1/claude/threads/${threadId}`)).body;
    expect(t.messages[0].attachments).toHaveLength(2);
  });

  it('refuses what it can\'t take: too many, not an image, not confirmed, another studio\'s, over 10 MB, nothing at all', async () => {
    const send = (body: unknown) => owner.req('POST', `/v1/claude/threads/${threadId}/messages`, body);
    expect((await send({ text: '' })).status).toBe(400);
    const five = await send({ text: 'x', attachments: Array.from({ length: 5 }, () => ({ uploadId: pngId })) });
    expect([five.status, five.body.error]).toEqual([400, expect.stringMatching(/at most 4/)]);
    const clip = await upload(owner, Buffer.from('not a video'), 'video/mp4', 'clip', false);
    expect((await send({ text: 'x', attachments: [{ uploadId: clip }] })).status).toBe(409); // still pending
    const pending = await upload(owner, await img(10, 10, 'png'), 'image/png', 'image', false);
    expect((await send({ text: 'x', attachments: [{ uploadId: pending }] })).body.code).toBe('upload_not_ready');
    const theirs = await upload(owner, await img(10, 10, 'png'), 'image/png');
    await a.ctx.db.execute(sql`update uploads set studio_id = 'st_someone_else' where id = ${theirs}`);
    expect((await send({ text: 'x', attachments: [{ uploadId: theirs }] })).status).toBe(404);
    const gif = await upload(owner, Buffer.from('GIF89a'), 'image/gif');
    expect((await send({ text: 'x', attachments: [{ uploadId: gif }] })).status).toBe(400);
    const big = await upload(owner, Buffer.alloc(10 * 1024 * 1024 + 10, 1), 'image/jpeg');
    const tooBig = await send({ text: 'x', attachments: [{ uploadId: big }] });
    expect([tooBig.status, tooBig.body.error]).toEqual([400, expect.stringMatching(/10 MB/)]);
    const fake = await upload(owner, Buffer.from('not really a png'), 'image/png');
    expect((await send({ text: 'x', attachments: [{ uploadId: fake }] })).status).toBe(400);
    expect((await owner.req('GET', '/v1/claude/turns')).body).toHaveLength(0); // nothing queued by a refused message
  });

  it.skipIf(!hasHeif)('HEIC becomes JPEG', async () => {
    const id = await upload(owner, fs.readFileSync(HEIC), 'image/heic');
    const r = await owner.req('POST', `/v1/claude/threads/${threadId}/messages`, { text: 'from my phone', attachments: [{ uploadId: id }] });
    expect(r.status, JSON.stringify(r.body)).toBe(202);
    expect(r.body.message.attachments[0]).toMatchObject({ uploadId: id, mimeType: 'image/jpeg', width: 64, height: 48 });
    await owner.req('POST', `/v1/claude/turns/${r.body.turn.id}/stop`);
  });

  it('a message typed on the Mac can carry images too', async () => {
    const id = await upload(owner, await img(40, 40, 'webp'), 'image/webp');
    expect((await owner.req('POST', `/v1/claude/threads/${threadId}/events`, { events: [{ type: 'user', text: 'this pose', attachments: [{ uploadId: id }] }] })).status).toBe(200);
    const t = (await owner.req('GET', `/v1/claude/threads/${threadId}`)).body;
    expect(t.messages.at(-1)).toMatchObject({ role: 'user', source: 'mac', text: 'this pose', attachments: [expect.objectContaining({ uploadId: id, mimeType: 'image/webp' })] });
  });
});

describe('the API fallback sees the images; suite_add_reference uses one', () => {
  it('image blocks with their uploadIds; Claude puts one in the shot as a pose reference; the next turn still sees it', async () => {
    const assist = (await owner.req('POST', '/v1/suite/assist', {})).body;
    await tool('suite_set_draft').run(env(), { assistId: assist.id, modelId: model.id, prompt: 'She leans on the rail.' });
    const t = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'suite', contextId: assist.id })).body;
    await owner.req('PATCH', '/v1/claude/settings', { apiFallback: true });
    const pose = await upload(owner, await img(400, 600, 'jpeg', '#808080'), 'image/jpeg');
    const replies: any[] = [{ tools: [{ name: 'suite_add_reference', input: { uploadId: pose, use: 'pose', label: 'leaning pose' } }] }, { text: 'Added her pose from your photo.' }, { text: 'Still here.' }];
    const calls: any[] = []; let i = 0;
    assistantOf(a.ctx).setClient({ beta: { messages: { stream: (p: any) => {
      calls.push(structuredClone(p)); const r = replies[Math.min(i++, replies.length - 1)];
      const content = [...(r.text ? [{ type: 'text', text: r.text }] : []), ...(r.tools ?? []).map((x: any, k: number) => ({ type: 'tool_use', id: `tu_${i}_${k}`, name: x.name, input: x.input }))];
      return { on(_e: string, cb: (d: string) => void) { if (r.text) cb(r.text); return this; }, finalMessage: async () => ({ content, stop_reason: r.tools ? 'tool_use' : 'end_turn', usage: {} }) };
    } } } } as any);
    const r = await owner.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: 'Use this pose', attachments: [{ uploadId: pose }] });
    expect(r.status).toBe(200);
    expect(String(r.body)).toContain('"name":"suite_add_reference","status":"done"');
    const first = calls[0].messages.at(-1).content;
    expect(first[0]).toMatchObject({ type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: expect.any(String) } });
    expect(first.at(-1).text).toMatch(/^\[Suite shot sa_[\s\S]*uploadId up_[\s\S]*Use this pose$/);
    expect(calls[0].messages.filter((m: any) => m.content.some((b: any) => b.type === 'image'))).toHaveLength(1); // not sent twice
    expect(calls[0].system[0].text).toMatch(/suite_add_reference/);
    expect(calls[0].tools.map((x: any) => x.name)).toContain('suite_add_reference');
    const v = (await owner.req('GET', `/v1/suite/assist/${assist.id}`)).body;
    expect(v.draft.references).toEqual([{ uploadId: pose, url: expect.stringMatching(/\/uploads\/u\//), use: 'pose', label: 'leaning pose' }]);
    expect(v.request.references.images).toEqual([{ image: { url: v.draft.references[0].url }, role: 'pose', label: 'leaning pose' }]);
    // The engine is told to take only the pose; her own references come first and carry her face.
    const est = await tool('suite_estimate').run(env(), { assistId: assist.id }) as any;
    expect(est.estimate.prompt).toMatch(/pose reference \(leaning pose\): use only its body pose, gesture and framing, never the face/);
    const sent = est.estimate.input.images.refs as { role: string }[];
    expect(sent[0]!.role).toBe('character');
    expect(sent.at(-1)!.role).toBe('pose');
    // The next turn replays the earlier image from the thread.
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: 'still there?' })).status).toBe(200);
    expect(calls.at(-1).messages.some((m: any) => m.role === 'user' && m.content.some((b: any) => b.type === 'image'))).toBe(true);
    // Camera threads stay text-only on the API.
    const cs = (await owner.req('POST', '/v1/camera-sessions', { title: 'cam' })).body.id;
    const ct = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'camera', contextId: cs })).body;
    expect((await owner.req('POST', `/v1/claude/threads/${ct.id}/api-turn`, { text: 'x', attachments: [{ uploadId: pose }] })).status).toBe(400);
  });

  it('suite_add_reference: at most 3, the same image changes its use, remove takes it out, a HEIC is made a studio JPEG', async () => {
    const assist = (await owner.req('POST', '/v1/suite/assist', {})).body;
    const ids = await Promise.all([0, 1, 2, 3].map(async k => upload(owner, await img(20 + k, 20, 'png'), 'image/png')));
    for (const [k, use] of (['pose', 'style', 'location'] as const).entries()) await tool('suite_add_reference').run(env(), { assistId: assist.id, uploadId: ids[k], use });
    await expect(tool('suite_add_reference').run(env(), { assistId: assist.id, uploadId: ids[3], use: 'outfit' })).rejects.toThrow(/at most 3/);
    let v = await tool('suite_add_reference').run(env(), { assistId: assist.id, uploadId: ids[1], use: 'outfit' }) as any;
    expect(v.draft.references.map((x: any) => x.use)).toEqual(['pose', 'outfit', 'location']);
    v = await tool('suite_add_reference').run(env(), { assistId: assist.id, uploadId: ids[0], use: 'pose', remove: true }) as any;
    expect(v.draft.references.map((x: any) => x.uploadId)).toEqual([ids[1], ids[2]]);
    await expect(tool('suite_add_reference').run(env(), { assistId: assist.id, uploadId: ids[0], use: 'pose', remove: true })).rejects.toThrow(/not found/i);
    await expect(tool('suite_add_reference').run(env(), { assistId: assist.id, uploadId: ids[0], use: 'face' })).rejects.toThrow(/use/);
    if (hasHeif) {
      const h = await upload(owner, fs.readFileSync(HEIC), 'image/heic');
      v = await tool('suite_add_reference').run(env(), { assistId: assist.id, uploadId: h, use: 'location' }) as any;
      expect(v.draft.references.at(-1).url).toMatch(/\/uploads\/u\/img_[A-Za-z0-9_-]+\.jpg$/);
      expect((await a.app.inject({ method: 'GET', url: new URL(v.draft.references.at(-1).url, 'http://x').pathname })).statusCode).toBe(200);
    }
  });
});

