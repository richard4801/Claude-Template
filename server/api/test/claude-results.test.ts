// Results arrive in the chat (owner, 2026-11-11): a job started while a Claude chat was open reports back to that chat.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { sql } from 'drizzle-orm';
import sharp from 'sharp';
import { jobs, takes } from '../src/db/schema.js';
import { seePhotos } from '../src/claude/watch.js';
import { registryByName } from '../src/claude/registry.js';
import { resultsOf } from '../src/claude/results.js';
import { linkChat } from '../src/services/jobs.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, studioId: string;

beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [member] } = await people(a, 1) as { owner: Client; members: Client[] });
  studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
});
afterAll(async () => { await a.close(); });

const row = (id: string, userId: string, request: Record<string, unknown>, state: 'done' | 'failed', extra: Record<string, unknown> = {}) => ({
  id, studioId, userId, kind: 'render' as const, title: 'Shot · Beach walk', modelId: 'm', modelName: 'M', request, state, cost: 1, prompt: '', seed: 1,
  createdAt: Date.now(), finishedAt: Date.now(), ...extra,
});

describe('results to the chat', () => {
  it('the open chat rides on the job (x-muse-chat), and is not shown in job views', async () => {
    expect(linkChat({ id: 'u', studioId, email: '', role: 'owner', studioName: '', sessionId: null, chatId: 'ct_1' }, { request: { tool: 'shot' } }))
      .toEqual({ request: { tool: 'shot', chatId: 'ct_1' } });
    expect(linkChat({ id: 'u', studioId, email: '', role: 'owner', studioName: '', sessionId: null }, { request: { tool: 'shot' } })).toEqual({ request: { tool: 'shot' } });
    const [j] = await a.ctx.db.insert(jobs).values(row('j_view', owner.id, { tool: 'shot', chatId: 'ct_x' }, 'done')).returning();
    expect(a.ctx.jobs.view(j!).request).toEqual({ tool: 'shot' });
  });

  it('a finished job tells its chat owner once, with the takes; failures carry the error; others\' chats never', async () => {
    const chat = (await owner.req('POST', '/v1/claude/chats', { title: 'Beach' })).body;
    const spy = vi.spyOn(a.ctx.hub, 'emitTo');
    const results = () => spy.mock.calls.filter(c => (c[1] as any)?.op === 'result').map(c => ({ to: c[0], ...(c[1] as any).result }));

    const [done] = await a.ctx.db.insert(jobs).values(row('j_done', owner.id, { tool: 'shot', chatId: chat.id }, 'done')).returning();
    a.ctx.jobs.emitJob(done!, { takes: [{ id: 't_j_done_1' }, { id: 't_j_done_2' }] });
    a.ctx.jobs.emitJob(done!, { takes: [{ id: 't_j_done_1' }] }); // a repeat never tells twice
    await vi.waitFor(() => expect(results()).toHaveLength(1));
    expect(results()[0]).toMatchObject({ to: owner.id, chatId: chat.id, jobId: 'j_done', kind: 'shot', status: 'done', title: 'Shot · Beach walk', takeIds: ['t_j_done_1', 't_j_done_2'] });

    const [failed] = await a.ctx.db.insert(jobs).values(row('j_fail', owner.id, { engine: 'photo', chatId: chat.id }, 'failed', { error: 'Out of credit' })).returning();
    a.ctx.jobs.emitJob(failed!);
    await vi.waitFor(() => expect(results()).toHaveLength(2));
    expect(results()[1]).toMatchObject({ jobId: 'j_fail', kind: 'photo', status: 'failed', error: 'Out of credit' });

    // A member's job naming the owner's chat: not theirs, nothing is sent. No chat: nothing either.
    const [other] = await a.ctx.db.insert(jobs).values(row('j_other', member.id, { tool: 'shot', chatId: chat.id }, 'done')).returning();
    a.ctx.jobs.emitJob(other!);
    const [plain] = await a.ctx.db.insert(jobs).values(row('j_plain', owner.id, { tool: 'shot' }, 'done')).returning();
    a.ctx.jobs.emitJob(plain!);
    await new Promise(r => setTimeout(r, 50));
    expect(results()).toHaveLength(2);
    spy.mockRestore();
  });

  it('see_photos shows photo stills (free, studio only); videos go to watch', async () => {
    const png = await sharp({ create: { width: 2000, height: 1000, channels: 3, background: '#c33' } }).png().toBuffer();
    await a.ctx.storage.put('s/p1.png', png, 'image/png');
    const t = (id: string, kind: 'shot' | 'take', sid = studioId) => a.ctx.db.insert(takes).values({ id, studioId: sid, userId: null, kind, jobId: null, modelId: null, index: 1, of: 1,
      title: 'Photo · Beach', label: 'Beach · 1', engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: 's/p1.png', createdAt: Date.now() });
    await t('s_p1', 'shot'); await t('t_v1', 'take'); await t('s_other', 'shot', 'studio_other');
    const r = await seePhotos(a.ctx, { studioId }, ['s_p1']) as any;
    expect(r.mcpContent[0]).toEqual({ type: 'text', text: 's_p1 · Photo · Beach · Beach · 1' });
    expect(r.mcpContent[1].mimeType).toBe('image/jpeg');
    expect((await sharp(Buffer.from(r.mcpContent[1].data, 'base64')).metadata()).width).toBe(1024);
    await expect(seePhotos(a.ctx, { studioId }, ['t_v1'])).rejects.toThrow(/watch it instead/);
    await expect(seePhotos(a.ctx, { studioId }, ['s_other'])).rejects.toThrow(/not found/i);
    expect(registryByName.get('see_photos')?.members).toBe(true);
  });

  it('outfits, Dress up, Enhance, sheet fills and Edit jobs report the same way; one Mac claims each result', async () => {
    const chat = (await owner.req('POST', '/v1/claude/chats', { title: 'Looks' })).body;
    const spy = vi.spyOn(a.ctx.hub, 'emitTo');
    const sent = () => spy.mock.calls.filter(c => (c[1] as any)?.op === 'result').map(c => (c[1] as any).result);
    const u = { id: owner.id, studioId, email: '', role: 'owner' as const, studioName: '', sessionId: null };
    const r = resultsOf(a.ctx);
    r.link({ ...u, chatId: chat.id }, 'outfit-o_1');
    r.link(u, 'tool-t_1'); // no chat open: nothing is linked
    await r.report('outfit-o_1', { kind: 'outfit', status: 'done', title: 'Outfit · Red dress', modelId: 'm_1', outfitId: 'o_1' });
    await r.report('outfit-o_1', { kind: 'outfit', status: 'done' }); // once
    await r.report('tool-t_1', { kind: 'enhance', status: 'done' });
    expect(sent()).toEqual([expect.objectContaining({ id: 'outfit-o_1', chatId: chat.id, kind: 'outfit', status: 'done', title: 'Outfit · Red dress', modelId: 'm_1', outfitId: 'o_1' })]);

    expect((await member.req('POST', '/v1/claude/results/outfit-o_1/claim')).status).toBe(410); // not theirs
    expect((await owner.req('POST', '/v1/claude/results/outfit-o_1/claim')).body).toEqual({ ok: true });
    expect((await owner.req('POST', '/v1/claude/results/outfit-o_1/claim')).body.code).toBe('already_claimed');
    expect((await owner.req('POST', '/v1/claude/results/nope/claim')).status).toBe(410);
    // Jobs-table results are claimable too.
    expect((await owner.req('POST', '/v1/claude/results/j_done/claim')).body).toEqual({ ok: true });
    spy.mockRestore();
  });
});
