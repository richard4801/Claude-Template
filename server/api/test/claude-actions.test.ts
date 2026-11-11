// Full control B2 (claude/actions.ts): a gated action never acts on Claude's word. Without confirm nothing changes;
// with confirm it waits for the person's Approve; only that person can answer, once; Approve runs it as them.
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { CHAT_REGISTRY, registryByName } from '../src/claude/registry.js';
import { ACTION_TOOLS, SETTINGS_TOOLS, priceOf } from '../src/claude/actions.js';
import { toolsForUser } from '../src/claude/registry.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, ownerU: AuthUser, memberU: AuthUser;
const authUser = async (c: Client, role: 'owner' | 'member'): Promise<AuthUser> => {
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, c.id));
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${c.id}`)) as any).rows[0].studio_id;
  return { id: u!.id, studioId, email: u!.email, role, studioName: 'Test Studio', sessionId: null };
};
const run = (u: AuthUser, name: string, args: Record<string, unknown> = {}) => registryByName.get(name)!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, args) as Promise<any>;
const names = async (c: Client) => JSON.stringify((await c.req('GET', '/v1/library/collections')).body);

beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [member] } = await people(a, 1) as any);
  ownerU = await authUser(owner, 'owner'); memberU = await authUser(member, 'member');
});
afterAll(async () => { await a?.close(); });

describe('gated actions', () => {
  it('every action tool is gated in the registry, and no tool can approve', () => {
    for (const t of ACTION_TOOLS) expect(registryByName.get(t.name)!.gate, t.name).not.toBe('none');
    expect(CHAT_REGISTRY.some(t => /approve/.test(t.name))).toBe(false);
    expect(priceOf({ estimate: { usd: 1.3 } })).toBe(1.3);
  });
  it('without confirm nothing happens; with confirm it waits; only the person approves, once, and then it runs as them', async () => {
    const c = await run(memberU, 'library_collect', { action: 'create', name: 'Old drafts' });
    const look = await run(memberU, 'collection_delete', { collectionId: c.id });
    expect(look.needsConfirmation).toBe(true);
    expect(await names(member)).toContain('Old drafts');
    const ask = await run(memberU, 'collection_delete', { collectionId: c.id, confirm: true });
    expect(ask.waitingForApproval).toBe(true);
    expect(await names(member)).toContain('Old drafts');
    expect((await member.req('GET', '/v1/claude/actions?status=waiting')).body.actions.map((x: any) => x.id)).toContain(ask.actionId);
    expect((await owner.req('POST', `/v1/claude/actions/${ask.actionId}`, { approve: true })).status).toBe(404); // not hers
    const ok = await member.req('POST', `/v1/claude/actions/${ask.actionId}`, { approve: true });
    expect(ok.body.status).toBe('done');
    expect(await names(member)).not.toContain('Old drafts');
    expect((await member.req('POST', `/v1/claude/actions/${ask.actionId}`, { approve: true })).status).toBe(409);
  });
  it('declined actions never run', async () => {
    const c = await run(ownerU, 'library_collect', { action: 'create', name: 'Keep me' });
    const ask = await run(ownerU, 'collection_delete', { collectionId: c.id, confirm: true });
    expect((await owner.req('POST', `/v1/claude/actions/${ask.actionId}`, { approve: false })).body.status).toBe('declined');
    expect(await names(owner)).toContain('Keep me');
  });
});

describe('B3: priced makes and settings', () => {
  it('a paid make only prices without confirm (fill-angles of a character with an empty sheet)', async () => {
    const m = await owner.req('POST', '/v1/models', { name: 'Ivy' });
    const look = await run(ownerU, 'character_fill_angles', { modelId: m.body.id });
    expect(look.needsConfirmation).toBe(true);
    expect(look.would).toMatch(/Fill \d+ missing angle/);
    expect(typeof look.estimateUsd).toBe('number');
    const after = await owner.req('GET', '/v1/models');
    expect(after.body.find((x: any) => x.id === m.body.id).slots.every((sl: any) => !sl.busy)).toBe(true);
  });
  it('settings: owner only, never keys or prices, changed only after her Approve', async () => {
    const mine = toolsForUser({ role: 'member' }).map(t => t.name);
    for (const t of SETTINGS_TOOLS) expect(mine).not.toContain(t.name);
    await expect(run(ownerU, 'settings_change', { area: 'studio', changes: { apiKey: 'x' } })).rejects.toMatchObject({ code: 'not_through_claude' });
    const before = await run(ownerU, 'settings_read', { area: 'recreate' });
    const ask = await run(ownerU, 'settings_change', { area: 'recreate', changes: { strictLinks: !before.strictLinks }, confirm: true });
    expect((await run(ownerU, 'settings_read', { area: 'recreate' })).strictLinks).toBe(before.strictLinks);
    expect((await owner.req('POST', `/v1/claude/actions/${ask.actionId}`, { approve: true })).body.status).toBe('done');
    expect((await run(ownerU, 'settings_read', { area: 'recreate' })).strictLinks).toBe(!before.strictLinks);
  });
});
