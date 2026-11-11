// Delete chats (owner, 2026-11-11: "messages are piling up"): own chats only; messages, turns, waiting approvals and
// result links go; memory and made things stay; several at once by id or by age; Claude asks first (gated).
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { claudeMessages, claudeThreads } from '../src/camera/schema.js';
import { claudeActions } from '../src/claude/schema.js';
import { registryByName } from '../src/claude/registry.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, ownerU: AuthUser;
const run = (u: AuthUser, name: string, args: Record<string, unknown> = {}) => registryByName.get(name)!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, args) as Promise<any>;
const msgs = async (id: string) => (await a.ctx.db.select().from(claudeMessages).where(eq(claudeMessages.threadId, id))).length;
const chat = async (c: Client, title: string) => (await c.req('POST', '/v1/claude/chats', { title })).body;

beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [member] } = await people(a, 1) as any);
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
  ownerU = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test', sessionId: null };
});
afterAll(async () => { await a?.close(); });

describe('delete chats', () => {
  it('own chats only; the chat, its messages and waiting approvals go; memory stays', async () => {
    const c = await chat(owner, 'Beach');
    await a.ctx.db.insert(claudeMessages).values({ id: 'cm_d1', threadId: c.id, role: 'user', source: 'api', text: 'hi', createdAt: Date.now() });
    await a.ctx.db.insert(claudeActions).values({ id: 'ca_d1', studioId: ownerU.studioId, userId: owner.id, chatId: c.id, tool: 'take_discard', gate: 'delete', summary: 'x',
      call: { method: 'DELETE', url: '/v1/takes/x' }, status: 'waiting', createdAt: Date.now(), updatedAt: Date.now(), expiresAt: Date.now() + 60_000 });
    const rule = (await owner.req('POST', '/v1/claude/memory', { text: 'Always warm light', area: 'style' })).body;
    expect((await member.req('DELETE', `/v1/claude/chats/${c.id}`)).status).toBe(404);
    expect((await owner.req('DELETE', `/v1/claude/chats/${c.id}`)).body).toEqual({ ok: true, deleted: [c.id] });
    expect(await a.ctx.db.select().from(claudeThreads).where(eq(claudeThreads.id, c.id))).toEqual([]);
    expect(await msgs(c.id)).toBe(0);
    expect(await a.ctx.db.select().from(claudeActions).where(eq(claudeActions.id, 'ca_d1'))).toEqual([]);
    expect((await owner.req('GET', '/v1/claude/memory')).body.rules.map((r: any) => r.id)).toContain(rule.id);
    expect((await owner.req('DELETE', `/v1/claude/chats/${c.id}`)).status).toBe(404);
  });

  it('several at once by id (all must be theirs) and every chat older than N days', async () => {
    const [x, y, old] = [await chat(owner, 'X'), await chat(owner, 'Y'), await chat(owner, 'Old')];
    const theirs = await chat(member, 'Theirs');
    await a.ctx.db.update(claudeThreads).set({ updatedAt: Date.now() - 40 * 86_400_000 }).where(eq(claudeThreads.id, old.id));
    expect((await owner.req('POST', '/v1/claude/chats/delete', { ids: [x.id, theirs.id] })).status).toBe(404); // nothing deleted
    expect((await owner.req('GET', '/v1/claude/chats')).body.chats.map((c: any) => c.id)).toContain(x.id);
    expect((await owner.req('POST', '/v1/claude/chats/delete', {})).status).toBe(400);
    const r = (await owner.req('POST', '/v1/claude/chats/delete', { ids: [x.id], olderThanDays: 30 })).body;
    expect(r.deleted.sort()).toEqual([x.id, old.id].sort());
    const left = (await owner.req('GET', '/v1/claude/chats')).body.chats.map((c: any) => c.id);
    expect(left).toContain(y.id);
    expect(left).not.toContain(old.id);
    expect((await member.req('GET', '/v1/claude/chats')).body.chats.map((c: any) => c.id)).toContain(theirs.id);
  });

  it('Claude asks first: chats_delete is gated and waits for Approve', async () => {
    const c = await chat(owner, 'Z');
    expect(registryByName.get('chats_delete')!.gate).toBe('delete');
    expect(registryByName.get('chats_delete')!.members).toBe(true);
    const look = await run(ownerU, 'chats_delete', { ids: [c.id] });
    expect(look.needsConfirmation).toBe(true);
    const ask = await run(ownerU, 'chats_delete', { ids: [c.id], confirm: true });
    expect(ask.waitingForApproval).toBe(true);
    expect((await owner.req('GET', '/v1/claude/chats')).body.chats.map((x: any) => x.id)).toContain(c.id);
    await owner.req('POST', `/v1/claude/actions/${ask.actionId}`, { approve: true });
    expect((await owner.req('GET', '/v1/claude/chats')).body.chats.map((x: any) => x.id)).not.toContain(c.id);
  });
});
