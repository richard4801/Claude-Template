// Claude reports its own issues (claude/issues.ts): report_issue stores and dedupes with a count; secrets are scrubbed;
// a failing tool call is captured on its own (rate-limited); only the owner lists and marks them. No Claude calls, no money.
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { registryByName, toolsForUser } from '../src/claude/registry.js';
import { normalise, resetIssueLimits, scrub } from '../src/claude/issues.js';
import { handleRpc } from '../src/mcp/server.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, ownerU: AuthUser, memberU: AuthUser;
const authUser = async (c: Client, role: 'owner' | 'member'): Promise<AuthUser> => {
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, c.id));
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${c.id}`)) as any).rows[0].studio_id;
  return { id: u!.id, studioId, email: u!.email, role, studioName: 'Test Studio', sessionId: null };
};
const report = (u: AuthUser, args: Record<string, unknown>) => registryByName.get('report_issue')!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, args) as Promise<any>;
const settle = () => new Promise(r => setTimeout(r, 50));

beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [member] } = await people(a, 1) as any);
  ownerU = await authUser(owner, 'owner'); memberU = await authUser(member, 'member');
});
beforeEach(() => resetIssueLimits());
afterAll(async () => { await a?.close(); });

describe('report_issue', () => {
  it('is in everyone\'s tools, ungated', () => {
    expect(toolsForUser({ role: 'member' }).map(t => t.name)).toContain('report_issue');
    expect(registryByName.get('report_issue')!.gate).toBe('none');
  });
  it('stores a report and counts repeats of the same problem on the same page (ids and numbers ignored)', async () => {
    const r1 = await report(ownerU, { summary: 'No tool to delete Library item lib_ab12cd', asked: 'Delete three blurry takes', page: 'library', kind: 'missing_tool', tried: 'library_find' });
    const r2 = await report(memberU, { summary: 'No tool to delete Library item lib_zz99yy', asked: 'Delete a take', page: 'library', kind: 'missing_tool', severity: 'high' });
    expect(r1.reported).toBe(true);
    expect(r2.id).toBe(r1.id);
    expect(r2.seen).toBe(2);
    const other = await report(ownerU, { summary: 'No tool to delete Library item', asked: 'x', page: 'edit', kind: 'missing_tool' });
    expect(other.id).not.toBe(r1.id);
    const { body } = await owner.req('GET', '/v1/claude/issues');
    const row = body.issues.find((i: any) => i.id === r1.id);
    expect(row).toMatchObject({ count: 2, severity: 'high', reporter: 'member', status: 'new', kind: 'missing_tool', page: 'library', source: 'claude' });
  });
  it('never stores secrets or emails', async () => {
    const s = scrub('failed with Authorization: Bearer abcdefghijklmnop1234 key=sk-live_ABCDEFGH12345678 for ann@example.com at https://x.io/f?sig=abc', 500)!;
    for (const bad of ['abcdefghijklmnop1234', 'ABCDEFGH12345678', 'ann@example.com', 'sig=abc']) expect(s).not.toContain(bad);
    const r = await report(ownerU, { summary: 'Upload refused', asked: 'upload', kind: 'bug', error: 'token=r8_Abcdefghijklmnopqrstu123 rejected' });
    const { body } = await owner.req('GET', '/v1/claude/issues');
    expect(body.issues.find((i: any) => i.id === r.id).error).not.toContain('r8_Abcdefghijklmnopqrstu123');
    expect(normalise('es_ab12cd failed at 3.2 s')).toBe(normalise('es_zz99yy failed at 5 s'));
  });
});

describe('captured tool errors', () => {
  it('a failing MCP tool call is logged as a bug with the tool and its error, once a minute per error', async () => {
    const call = () => handleRpc(a.ctx, null as any, ownerU, { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_edit', arguments: { sessionId: 'es_nothere' } } });
    await call(); await call(); await settle();
    const { body } = await owner.req('GET', '/v1/claude/issues?source=auto');
    const rows = body.issues.filter((i: any) => i.tool === 'get_edit');
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ kind: 'bug', source: 'auto', count: 1 });
    expect(rows[0].error).toMatch(/not_found/);
  });
});

describe('the owner\'s list', () => {
  it('members get 403; since returns only what changed after it; the owner marks a report', async () => {
    expect((await member.req('GET', '/v1/claude/issues')).status).toBe(403);
    const t = Date.now();
    await new Promise(r => setTimeout(r, 5));
    const r = await report(ownerU, { summary: 'Camera page did not open', asked: 'open camera', kind: 'blocked', page: 'camera' });
    const { body } = await owner.req('GET', `/v1/claude/issues?since=${t}`);
    expect(body.issues.map((i: any) => i.id)).toEqual([r.id]);
    expect((await member.req('POST', `/v1/claude/issues/${r.id}`, { status: 'fixed' })).status).toBe(403);
    const m = await owner.req('POST', `/v1/claude/issues/${r.id}`, { status: 'fixed', note: 'open_page camera added' });
    expect(m.body).toMatchObject({ status: 'fixed', note: 'open_page camera added' });
    const again = await report(ownerU, { summary: 'Camera page did not open', asked: 'open camera', kind: 'blocked', page: 'camera' });
    expect(again.seen).toBe(2);
    expect((await owner.req('GET', '/v1/claude/issues?status=new')).body.issues.map((i: any) => i.id)).toContain(r.id);
  });
  it('the owner\'s MCP connection (the hourly check) lists them; a member\'s does not see the tool', async () => {
    const rpc = (u: AuthUser, name: string, args: unknown) => handleRpc(a.ctx, null as any, u, { jsonrpc: '2.0', id: 9, method: 'tools/call', params: { name, arguments: args } }) as Promise<any>;
    const o = await rpc(ownerU, 'claude_issues', { since: 0, limit: 5 });
    expect(o.result.structuredContent.issues.length).toBeGreaterThan(0);
    expect((await rpc(memberU, 'claude_issues', {})).error.code).toBe(-32602);
  });
});
