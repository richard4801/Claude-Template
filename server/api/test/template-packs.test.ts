// Template pack intake (editor/templatePacks.ts): the owner's Claude sends a pack in parts (they merge), scripts keep
// their text with credentials redacted, previews must be finished uploads of the studio, members never see the tools,
// and gaps_list returns every gap (playbook_read only shows the top 5). No Claude calls, no money.
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { uploads, users } from '../src/db/schema.js';
import { registryByName, toolsForUser } from '../src/claude/registry.js';
import { redactCredentials } from '../src/editor/templatePacks.js';
import { handleRpc } from '../src/mcp/server.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, ownerU: AuthUser, memberU: AuthUser;
const authUser = async (c: Client, role: 'owner' | 'member'): Promise<AuthUser> => {
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, c.id));
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${c.id}`)) as any).rows[0].studio_id;
  return { id: u!.id, studioId, email: u!.email, role, studioName: 'Test Studio', sessionId: null };
};
const run = (name: string, u: AuthUser, args: Record<string, unknown>) => registryByName.get(name)!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, args) as Promise<any>;
const upload = async (u: AuthUser, id: string, state: 'ready' | 'pending' = 'ready') => a.ctx.db.insert(uploads).values({
  id, studioId: u.studioId, kind: 'clip', storageKey: `k/${id}`, contentType: 'video/mp4', state, createdAt: Date.now() });

beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [member] } = await people(a, 1) as any);
  ownerU = await authUser(owner, 'owner'); memberU = await authUser(member, 'member');
});
afterAll(async () => { await a?.close(); });

describe('template packs', () => {
  it('are the owner\'s: not in a member\'s tools, refused if called', async () => {
    const memberTools = toolsForUser({ role: 'member' }).map(t => t.name);
    for (const n of ['gaps_list', 'template_pack_send', 'template_pack_read']) {
      expect(toolsForUser({ role: 'owner' }).map(t => t.name)).toContain(n);
      expect(memberTools).not.toContain(n);
    }
    await expect(run('template_pack_read', memberU, {})).rejects.toMatchObject({ status: 403 });
  });

  it('merges parts sent in several calls and says which templates still lack a preview', async () => {
    const manifest = { templates: [{ id: 'glitch-rgb', kind: 'effect' }, { id: 'white-flash', kind: 'transition' }, { id: 'storm-end-card', kind: 'text' }] };
    const r1 = await run('template_pack_send', ownerU, { pack: 'icon-storyboard', manifest, files: [{ path: 'README.md', text: '# Pack' }, { path: 'scripts/glitch.py', text: 'print(1)' }] });
    expect(r1).toMatchObject({ pack: 'icon-storyboard', templates: 3, files: 2, media: 0, missingPreviews: ['glitch-rgb', 'white-flash', 'storm-end-card'] });
    await upload(ownerU, 'up_prev1');
    const r2 = await run('template_pack_send', ownerU, { pack: 'icon-storyboard', files: [{ path: './scripts/glitch.py', text: 'print(2)' }],
      media: [{ templateId: 'glitch-rgb', uploadId: 'up_prev1', role: 'preview' }] });
    expect(r2).toMatchObject({ packId: r1.packId, files: 2, media: 1, missingPreviews: ['white-flash', 'storm-end-card'] });
    const full = await run('template_pack_read', ownerU, { pack: 'icon-storyboard' });
    expect(full.manifest).toEqual(manifest);
    expect(full.fileList.map((f: any) => f.path).sort()).toEqual(['README.md', 'scripts/glitch.py']);
    expect((await run('template_pack_read', ownerU, { pack: 'icon-storyboard', path: 'scripts/glitch.py' })).text).toBe('print(2)');
    expect((await run('template_pack_read', ownerU, {})).packs).toHaveLength(1);
  });

  it('redacts credentials in scripts but keeps ordinary code', async () => {
    const code = 'API_KEY = "sk-live_ABCDEFGH12345678"\nheaders={"Authorization": "Bearer abcdefghijklmnopqrstuvwx"}\nkey = os.environ["FAL_KEY"]\nsha = "3f2a9c0d1e"\n';
    const r = redactCredentials(code);
    expect(r.redacted).toBe(2);
    for (const bad of ['ABCDEFGH12345678', 'abcdefghijklmnopqrstuvwx']) expect(r.text).not.toContain(bad);
    expect(r.text).toContain('os.environ["FAL_KEY"]');
    expect(r.text).toContain('sha = "3f2a9c0d1e"');
    const out = await run('template_pack_send', ownerU, { pack: 'p2', files: [{ path: 'scripts/x.py', text: code }] });
    expect(out.redacted).toBe(2);
  });

  it('refuses unsafe paths, binary text, and uploads that are not finished or not the studio\'s', async () => {
    await expect(run('template_pack_send', ownerU, { pack: 'p3', files: [{ path: '../etc/passwd', text: 'x' }] })).rejects.toMatchObject({ status: 400 });
    await expect(run('template_pack_send', ownerU, { pack: 'p3', files: [{ path: 'a.mp4', text: 'ab\u0000cd' }] })).rejects.toMatchObject({ status: 400 });
    await upload(ownerU, 'up_pending', 'pending');
    await expect(run('template_pack_send', ownerU, { pack: 'p3', media: [{ templateId: 't', uploadId: 'up_pending' }] })).rejects.toMatchObject({ status: 400 });
    await expect(run('template_pack_send', ownerU, { pack: 'p3', media: [{ templateId: 't', uploadId: 'up_nothere' }] })).rejects.toMatchObject({ status: 400 });
    await expect(run('template_pack_send', ownerU, { pack: '../x' })).rejects.toMatchObject({ status: 400 });
  });

  it('gaps_list returns every gap, past the 5 playbook_read shows, filtered by kind and words', async () => {
    for (let i = 0; i < 7; i++) await run('report_gap', ownerU, { key: `effect:fx-${i}`, kind: 'effect', what: `Effect ${i}`, note: i === 3 ? 'pack id storm-end-card' : 'x' });
    await run('report_gap', ownerU, { key: 'transition:page-turn', kind: 'transition', what: 'Page turn' });
    const all = await run('gaps_list', ownerU, {});
    expect(all.total).toBeGreaterThanOrEqual(8);
    expect((await run('gaps_list', ownerU, { kind: 'transition' })).gaps.map((g: any) => g.key)).toEqual(['transition:page-turn']);
    expect((await run('gaps_list', ownerU, { query: 'storm-end-card' })).gaps.map((g: any) => g.key)).toEqual(['effect:fx-3']);
  });

  it('is on the owner\'s MCP server', async () => {
    const r: any = await handleRpc(a.ctx, null as any, ownerU, { jsonrpc: '2.0', id: 1, method: 'tools/list' });
    const names = r.result.tools.map((t: any) => t.name);
    expect(names).toEqual(expect.arrayContaining(['gaps_list', 'template_pack_send', 'template_pack_read']));
  });
});
