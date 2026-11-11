// Deleting is for the studio owner or whoever made it: takes, characters, jobs, posts, Dress up/Enhance runs. Another
// member gets 403 and the thing stays. (Outfits, collections, imports, locations, rigs, references already were.)
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { takes } from '../src/db/schema.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, m1: Client, m2: Client, studioId: string;

beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [m1, m2] } = await people(a, 2) as any);
  studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${m1.id}`)) as any).rows[0].studio_id;
});
afterAll(async () => { await a?.close(); });

const take = async (id: string, userId: string | null) => {
  await a.ctx.db.insert(takes).values({ id, studioId, userId, kind: 'shot', jobId: null, modelId: null, index: 1, of: 1, title: 'T', label: 'T', cost: 0, seed: 0, status: 'test', createdAt: Date.now() } as any);
};

describe('who may delete', () => {
  it('a take: its maker or the owner; another member 403; an old take with no maker: the owner only', async () => {
    await take('s_m1', m1.id); await take('s_m1b', m1.id); await take('s_old', null);
    expect((await m2.req('DELETE', '/v1/takes/s_m1')).status).toBe(403);
    expect((await m2.req('DELETE', '/v1/takes/s_old')).status).toBe(403);
    expect((await m1.req('DELETE', '/v1/takes/s_m1')).status).toBe(204);
    expect((await owner.req('DELETE', '/v1/takes/s_m1b')).status).toBe(204);
    expect((await owner.req('DELETE', '/v1/takes/s_old')).status).toBe(204);
  });
  it('a character: its maker or the owner', async () => {
    const made = await m1.req('POST', '/v1/models', { name: 'Ana' });
    expect(made.status).toBeLessThan(300);
    expect((await m2.req('DELETE', `/v1/models/${made.body.id}`)).status).toBe(403);
    expect((await m1.req('DELETE', `/v1/models/${made.body.id}`)).status).toBe(204);
  });
});
