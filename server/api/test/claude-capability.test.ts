// A chat hears about tools shipped since its last turn (claude/capability.ts): a chat with replies gets one note listing
// what is new or changed, then nothing until the list changes again; a chat with no replies just records the list.
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { claudeMessages, claudeThreads } from '../src/camera/schema.js';
import { capabilityNote, capabilityVersion, toolHashes } from '../src/claude/capability.js';
import { handleRpc } from '../src/mcp/server.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, ownerU: AuthUser, memberU: AuthUser;
const authUser = async (c: Client, role: 'owner' | 'member'): Promise<AuthUser> => {
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, c.id));
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${c.id}`)) as any).rows[0].studio_id;
  return { id: u!.id, studioId, email: u!.email, role, studioName: 'Test Studio', sessionId: null };
};

beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [member] } = await people(a, 1) as any);
  ownerU = await authUser(owner, 'owner'); memberU = await authUser(member, 'member');
});
afterAll(async () => { await a?.close(); });

describe('capability version', () => {
  it('differs for the owner and a member, and is stable', () => {
    expect(capabilityVersion(ownerU)).not.toBe(capabilityVersion(memberU));
    expect(capabilityVersion(ownerU)).toBe(capabilityVersion(ownerU));
    expect(Object.keys(toolHashes(memberU))).not.toContain('get_edit');
  });
  it('an old chat that said "I can\'t" hears what is new once; a fresh chat hears nothing', async () => {
    const c = (await owner.req('POST', '/v1/claude/chats', {})).body;
    expect(await capabilityNote(a.ctx, ownerU, c.id)).toBeNull(); // no reply yet: just records
    await a.ctx.db.insert(claudeMessages).values({ id: 'cm_t1', threadId: c.id, role: 'assistant', source: 'api', text: 'I can\'t upload that.', createdAt: Date.now() } as any);
    // Pretend the chat last saw MUSE without report_issue and with an older open_page.
    const seen = toolHashes(ownerU); delete seen.report_issue; seen.open_page = 'old';
    await a.ctx.db.update(claudeThreads).set({ toolsSeen: seen }).where(eq(claudeThreads.id, c.id));
    const note = await capabilityNote(a.ctx, ownerU, c.id);
    expect(note).toMatch(/MUSE was updated/);
    expect(note).toMatch(/new: report_issue/);
    expect(note).toMatch(/changed: open_page/);
    expect(await capabilityNote(a.ctx, ownerU, c.id)).toBeNull();
    // On MCP the note rides on the first tool result naming the chat.
    await a.ctx.db.update(claudeThreads).set({ toolsSeen: null }).where(eq(claudeThreads.id, c.id));
    const r = await handleRpc(a.ctx, null as any, ownerU, { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'where_am_i', arguments: { chatId: c.id } } }) as any;
    expect(r.result.content.at(-1).text).toMatch(/check your current tools again/);
  });
  it('someone else\'s chat gets nothing', async () => {
    const c = (await owner.req('POST', '/v1/claude/chats', {})).body;
    expect(await capabilityNote(a.ctx, memberU, c.id)).toBeNull();
  });
});
