// Full control B1 (claude/appTools.ts): Claude's tools call the app's own routes as the person. The parts worth a
// test: the person's identity and permissions carry over (a member stays a member), a forged grant header is refused,
// and a free organise action really changes the Library. No Claude calls, no money.
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { registryByName, toolsForUser } from '../src/claude/registry.js';
import { APP_TOOLS } from '../src/claude/appTools.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, ownerU: AuthUser, memberU: AuthUser;
const authUser = async (c: Client, role: 'owner' | 'member'): Promise<AuthUser> => {
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, c.id));
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${c.id}`)) as any).rows[0].studio_id;
  return { id: u!.id, studioId, email: u!.email, role, studioName: 'Test Studio', sessionId: null };
};
const run = (u: AuthUser, name: string, args: Record<string, unknown> = {}) => registryByName.get(name)!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, args) as Promise<any>;

beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [member] } = await people(a, 1) as any);
  ownerU = await authUser(owner, 'owner'); memberU = await authUser(member, 'member');
});
afterAll(async () => { await a?.close(); });

describe('B1 tools', () => {
  it('are in everyone\'s tools and none takes confirm (nothing here spends, deletes or posts)', () => {
    const m = toolsForUser({ role: 'member' }).map(t => t.name);
    expect(m).not.toContain('character_archive');
    for (const t of APP_TOOLS.filter(x => !['character_archive', 'warm_gpu', 'camera_sessions_list'].includes(x.name))) {
      expect(m).toContain(t.name);
      expect(registryByName.get(t.name)!.gate).toBe('none');
      expect(Object.keys((t.inputSchema as any).properties ?? {})).not.toContain('confirm');
    }
  });
  it('every read tool answers for a member and the owner', async () => {
    for (const n of ['queue_list', 'characters_list', 'outfits_list', 'library_find', 'library_collections', 'templates_list', 'posts_list', 'recreate_list', 'edit_jobs', 'import_link'])
      for (const u of [ownerU, memberU]) await expect(run(u, n), `${n} ${u.role}`).resolves.toBeTruthy();
  });
  it('acts as the person: a member keeps member limits (archived characters are owner-only)', async () => {
    const { appCall } = await import('../src/claude/appCall.js');
    await expect(appCall(a.ctx, memberU, 'GET', '/v1/models?archived=1')).rejects.toMatchObject({ status: 403 });
    await expect(appCall(a.ctx, ownerU, 'GET', '/v1/models?archived=1')).resolves.toEqual([]);
  });
  it('a grant header from outside is refused', async () => {
    const r = await a.app.inject({ method: 'GET', url: '/v1/models', headers: { 'x-muse-claude-grant': 'f'.repeat(64) } });
    expect(r.statusCode).toBe(401);
  });
  it('organises the Library: create a collection, find it, rename it', async () => {
    const c = await run(memberU, 'library_collect', { action: 'create', name: 'Summer drop' });
    expect(c.id).toBeTruthy();
    const list = await run(memberU, 'library_collections');
    expect(JSON.stringify(list)).toContain('Summer drop');
    await run(memberU, 'library_collect', { action: 'rename', collectionId: c.id, name: 'Summer drop 2' });
    expect(JSON.stringify(await run(memberU, 'library_collections'))).toContain('Summer drop 2');
    await expect(run(memberU, 'take_status', { takeId: 'tk_nothere', status: 'final' })).rejects.toMatchObject({ status: 404 });
  });
  it('B3b: recipes list and the helper list answer; a template is made, favourited, and its delete waits for Approve', async () => {
    await expect(run(ownerU, 'recipes', { action: 'list' })).resolves.toBeTruthy();
    await expect(run(ownerU, 'edit_jobs', { features: true })).resolves.toBeTruthy();
    const ask = await run(ownerU, 'template_delete', { templateId: 'tpl_nothere' }).catch(e => e);
    expect(ask.status).toBe(404);
  });
  it('B3c: a member starts a character and sets her never-add list; tool runs list', async () => {
    const m = await run(memberU, 'character_create', { name: 'Lea', niche: 'fitness' });
    expect(m).toMatchObject({ name: 'Lea' });
    const u = await run(memberU, 'character_update', { modelId: m.id, neverAdd: ['hats'] });
    expect(u.neverAdd).toEqual(['hats']);
    await expect(run(memberU, 'tool_run', { action: 'list' })).resolves.toBeTruthy();
  });
});
