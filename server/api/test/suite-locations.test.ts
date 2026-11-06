// AI suite (workstream 1): the studio's locations (composer @location) and their use as a "location" reference.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { makeApp, people, type Client } from './helpers.js';

describe('AI suite · locations', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, other: Client;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock' });
    ({ owner, members: [member, other] } = await people(a, 2) as any);
  });
  afterAll(async () => { await a?.close(); });

  it('members add locations; the list is the studio’s, newest first', async () => {
    const r1 = await member.req('POST', '/v1/suite/locations', { name: '  Corner café ', image: { url: 'https://example.com/cafe.jpg' } });
    expect(r1.status).toBe(200);
    expect(r1.body).toMatchObject({ name: 'Corner café', image: { url: 'https://example.com/cafe.jpg' } });
    expect(r1.body.id).toMatch(/^loc_/);
    await new Promise(r => setTimeout(r, 2));
    const r2 = await owner.req('POST', '/v1/suite/locations', { name: 'Rooftop', image: { asset: 'g_front' } });
    const list = (await other.req('GET', '/v1/suite/locations')).body;
    expect(list.map((l: any) => l.name)).toEqual(['Rooftop', 'Corner café']);
    expect(list[0].id).toBe(r2.body.id);
  });

  it('refuses a bad name or image', async () => {
    expect((await member.req('POST', '/v1/suite/locations', { name: ' ', image: { asset: 'x' } })).status).toBe(400);
    expect((await member.req('POST', '/v1/suite/locations', { name: 'X', image: {} })).status).toBe(400);
    expect((await member.req('POST', '/v1/suite/locations', { name: 'X', image: { url: 'http://insecure/x.jpg' } })).status).toBe(400);
  });

  it('only the person who added it or the owner deletes it', async () => {
    const mine = (await member.req('POST', '/v1/suite/locations', { name: 'Gym', image: { asset: 'g_tq' } })).body;
    expect((await other.req('DELETE', `/v1/suite/locations/${mine.id}`)).status).toBe(403);
    expect((await member.req('DELETE', `/v1/suite/locations/${mine.id}`)).status).toBe(200);
    const again = (await member.req('POST', '/v1/suite/locations', { name: 'Gym', image: { asset: 'g_tq' } })).body;
    expect((await owner.req('DELETE', `/v1/suite/locations/${again.id}`)).status).toBe(200);
    expect((await owner.req('DELETE', `/v1/suite/locations/${again.id}`)).status).toBe(404);
  });

  it('a location goes into a shot as a "location" reference', async () => {
    const loc = (await member.req('GET', '/v1/suite/locations')).body[0];
    const e = await member.req('POST', '/v1/suite/shots/estimate', { prompt: `She walks into ${loc.name}.`, duration: 5, quality: 'standard',
      references: { images: [{ image: loc.image, role: 'location', label: loc.name }] } });
    expect(e.status).toBe(200);
    expect(e.body.warnings.join(' ')).not.toMatch(/left out/);
    const job = await owner.req('POST', '/v1/suite/shots', { prompt: `She walks into ${loc.name}.`, duration: 5, quality: 'standard',
      references: { images: [{ image: loc.image, role: 'location', label: loc.name }] } });
    expect(job.status).toBe(200);
    const plan = ((await a.ctx.jobs.get(job.body.id))!.stats as any).suite.plan;
    expect(plan.images.refs).toEqual([{ label: loc.name, role: 'location', image: loc.image }]);
  });
});
