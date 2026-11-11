// One Claude (plans/one-claude.md), the parts that need a test: the one tool registry (every tool once, every paid tool
// gated), the member permission gates (own chats only, no owner-only tools, memory read + learn but never pin, edit or
// delete), and migration 0029 carrying old per-place chats into the one list. No Claude calls, no money.
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { CHAT_REGISTRY, GATES, claudeSchema, registryByName, toolsForUser } from '../src/claude/registry.js';
import { EDIT_TOOLS } from '../src/editor/mcpTools.js';
import { assistantOf } from '../src/recreate/assistant.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, ownerU: AuthUser, memberU: AuthUser;
const authUser = async (c: Client, role: 'owner' | 'member'): Promise<AuthUser> => {
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, c.id));
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${c.id}`)) as any).rows[0].studio_id;
  return { id: u!.id, studioId, email: u!.email, role, studioName: 'Test Studio', sessionId: null };
};
const DRAFT = { v: 1, tool: 'photo', quality: 'draft', aspect: '9:16', duration: 5, takes: 1, sound: true };

beforeAll(async () => {
  a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
  ({ owner, members: [member] } = await people(a, 1, { topUp: 10 }) as any);
  ownerU = await authUser(owner, 'owner'); memberU = await authUser(member, 'member');
});
afterAll(async () => { await a?.close(); });

describe('the one registry', () => {
  it('holds every Suite, Edit, Recreate and chat tool once, each with pages, a gate and a members flag', () => {
    const names = CHAT_REGISTRY.map(t => t.name);
    expect(new Set(names).size).toBe(names.length);
    for (const n of ['where_am_i', 'open_page', 'memory_read', 'memory_add', 'chats_list', 'chat_read', 'suite_set_draft', 'apply_edit_ops', 'get_recipe']) expect(names).toContain(n);
    for (const t of CHAT_REGISTRY) { expect(t.pages.length).toBeGreaterThan(0); expect(['none', 'spend', 'delete', 'post', 'settings']).toContain(t.gate); expect(typeof t.members).toBe('boolean'); }
    for (const n of Object.keys(GATES)) expect(registryByName.has(n)).toBe(true);
  });
  it('every tool that takes confirm (asks the person to pay) is gated', () => {
    for (const t of CHAT_REGISTRY) {
      const props = (t.inputSchema as { properties?: Record<string, unknown> }).properties ?? {};
      if ('confirm' in props) expect(t.gate, t.name).not.toBe('none');
    }
  });
  it('the ids a page fills in are optional for Claude, and the chat id is never shown', () => {
    const s = claudeSchema(registryByName.get('suite_get_draft')!) as { required: string[] };
    expect(s.required).not.toContain('assistId');
    const o = claudeSchema(registryByName.get('open_page')!) as { properties: Record<string, unknown>; required: string[] };
    expect(o.properties.chatId).toBeUndefined();
    expect(o.required).toEqual(['page']);
  });
});

describe('members: their own chats and only their tools', () => {
  it('a member has no Edit or owner-only Recreate tools; the owner has all', () => {
    const m = toolsForUser({ role: 'member' }).map(t => t.name);
    for (const t of EDIT_TOOLS) expect(m).not.toContain(t.name);
    for (const n of ['apply_recipe', 'replace_slot', 'playbook_add', 'playbook_read']) expect(m).not.toContain(n);
    for (const n of ['suite_set_draft', 'memory_add', 'open_page']) expect(m).toContain(n);
    expect(toolsForUser({ role: 'owner' }).length).toBe(CHAT_REGISTRY.length);
  });

  it('each person sees and opens only their own chats', async () => {
    const mine = (await owner.req('POST', '/v1/claude/chats', { title: 'Summer drop' })).body;
    const theirs = (await member.req('POST', '/v1/claude/chats', { title: 'Member work' })).body;
    expect(mine.kind).toBe('chat');
    const mList = (await member.req('GET', '/v1/claude/chats')).body.chats.map((c: { id: string }) => c.id);
    expect(mList).toContain(theirs.id);
    expect(mList).not.toContain(mine.id);
    expect((await owner.req('GET', '/v1/claude/chats')).body.chats.map((c: { id: string }) => c.id)).not.toContain(theirs.id);
    expect((await member.req('GET', `/v1/claude/chats/${mine.id}`)).status).toBe(404);
    expect((await owner.req('GET', `/v1/claude/chats/${theirs.id}`)).status).toBe(404);
    expect((await member.req('PUT', `/v1/claude/chats/${mine.id}/page`, { page: { name: 'home' } })).status).toBe(404);
    expect((await member.req('PATCH', `/v1/claude/chats/${mine.id}`, { title: 'x' })).status).toBe(404);
    // Claude in a member's chat can't read the owner's chats either.
    await expect(assistantOf(a.ctx).runChatTool(memberU, theirs.id, 'chat_read', { otherChatId: mine.id })).rejects.toMatchObject({ status: 404 });
    const listed = await assistantOf(a.ctx).runChatTool(memberU, theirs.id, 'chats_list', {}) as { chats: { id: string }[] };
    expect(listed.chats.map(c => c.id)).not.toContain(mine.id);
    // A chat tool always acts as the chat it runs in, whatever id Claude passes.
    const where = await assistantOf(a.ctx).runChatTool(memberU, theirs.id, 'where_am_i', { chatId: mine.id }) as { line: string };
    expect(where.line).toBe('no page reported');
  });

  it('a member\'s chat refuses owner-only tools; the in-app turn needs the studio switch', async () => {
    const c = (await member.req('POST', '/v1/claude/chats', {})).body;
    await expect(assistantOf(a.ctx).runChatTool(memberU, c.id, 'get_edit', { sessionId: 'es_x' })).rejects.toMatchObject({ status: 403 });
    await expect(assistantOf(a.ctx).runChatTool(memberU, c.id, 'playbook_add', { text: 'x' })).rejects.toMatchObject({ status: 403 });
    const r = await member.req('POST', `/v1/claude/chats/${c.id}/turn`, { text: 'hello' });
    expect(r.status).toBe(409);
    expect(r.body.code).toBe('fallback_off');
  });

  it('members read the memory and Claude learns from them, but only the owner pins, edits or deletes', async () => {
    const c = (await member.req('POST', '/v1/claude/chats', {})).body;
    const r = await assistantOf(a.ctx).runChatTool(memberU, c.id, 'memory_add', { text: 'No slow-motion hair flips', area: 'rejected', pinned: true }) as { id: string; pinned: boolean; source: string };
    expect(r.pinned).toBe(false);
    expect(r.source).toBe('claude');
    const mem = (await member.req('GET', '/v1/claude/memory')).body;
    expect(mem.canEdit).toBe(false);
    expect(mem.rules.map((x: { id: string }) => x.id)).toContain(r.id);
    expect((await member.req('PATCH', `/v1/learn/playbook/${r.id}`, { pinned: true })).status).toBe(403);
    expect((await member.req('DELETE', `/v1/learn/playbook/${r.id}`)).status).toBe(403);
    expect((await member.req('POST', '/v1/learn/playbook', { text: 'mine', area: 'style' })).status).toBe(403);
    // The member's line has no Undo (only the owner deletes); the owner can pin it and add figure rules.
    const line = (await member.req('GET', `/v1/claude/chats/${c.id}`)).body.messages.find((m: { tool?: { name: string } }) => m.tool?.name === 'memory_add');
    expect(line.tool.ui).toMatchObject({ remembered: r.id, undo: false });
    expect((await owner.req('PATCH', `/v1/learn/playbook/${r.id}`, { pinned: true })).status).toBe(200);
    expect((await owner.req('POST', '/v1/learn/playbook', { text: 'Waist and hips as in her photos', area: 'figure' })).status).toBe(200);
  });
});

describe('the page and the old chats', () => {
  it('the page fills the open ids; with nothing open the tool says what to open', async () => {
    const draft = (await owner.req('POST', '/v1/suite/assist', { draft: DRAFT })).body as { id: string };
    const c = (await owner.req('POST', '/v1/claude/chats', { page: { name: 'suite', tool: 'photo', ids: { assistId: draft.id } } })).body;
    expect(c.lastOn).toBe('AI Suite, Photo');
    const page = { name: 'suite' as const, ids: { assistId: draft.id } };
    const got = await assistantOf(a.ctx).runChatTool(ownerU, c.id, 'suite_get_draft', {}, page) as { id: string };
    expect(got.id).toBe(draft.id);
    await expect(assistantOf(a.ctx).runChatTool(ownerU, c.id, 'suite_get_draft', {}, { name: 'home' })).rejects.toMatchObject({ status: 400, code: 'nothing_open' });
  });

  it('open_page leaves a line the app acts on, and asks when the person is busy', async () => {
    const c = (await owner.req('POST', '/v1/claude/chats', {})).body;
    await owner.req('PUT', `/v1/claude/chats/${c.id}/page`, { page: { name: 'edit', label: 'Beach reel', busy: true, ids: { sessionId: 'es_1' } } });
    const r = await assistantOf(a.ctx).runChatTool(ownerU, c.id, 'open_page', { page: 'take', id: 'tk_1', label: 'Sunset walk 3' }) as { asked: boolean };
    expect(r.asked).toBe(true);
    const line = (await owner.req('GET', `/v1/claude/chats/${c.id}`)).body.messages.find((m: { tool?: { name: string } }) => m.tool?.name === 'open_page');
    expect(line.tool.ui).toMatchObject({ page: 'take', id: 'tk_1', ask: true, from: { name: 'edit', label: 'Beach reel' } });
  });

  it('old per-place chats (migration 0029) are in the one list, starting on their page', async () => {
    const draft = (await owner.req('POST', '/v1/suite/assist', { draft: DRAFT })).body as { id: string };
    const old = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'suite', contextId: draft.id })).body;
    const listed = (await owner.req('GET', '/v1/claude/chats')).body.chats.find((c: { id: string }) => c.id === old.id);
    expect(listed).toMatchObject({ kind: 'suite', page: { name: 'suite', tool: 'photo', ids: { assistId: draft.id } }, lastOn: 'AI Suite, Photo' });
    // Opened in the one panel (the Mac opens {contextKind: 'chat', contextId}), it becomes a chat that follows the owner.
    const opened = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'chat', contextId: old.id })).body;
    expect(opened).toMatchObject({ id: old.id, contextKind: 'chat', brief: { chatId: old.id } });
    expect((await member.req('POST', '/v1/claude/threads', { contextKind: 'chat', contextId: old.id })).status).toBe(403);
    // Archived chats leave the list but are kept.
    await owner.req('PATCH', `/v1/claude/chats/${old.id}`, { archived: true });
    expect((await owner.req('GET', '/v1/claude/chats')).body.chats.map((c: { id: string }) => c.id)).not.toContain(old.id);
    expect((await owner.req('GET', '/v1/claude/chats?archived=1')).body.chats.map((c: { id: string }) => c.id)).toContain(old.id);
  });
});
