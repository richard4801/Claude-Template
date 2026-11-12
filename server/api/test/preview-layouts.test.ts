// The take viewer's safe zones (plans/swap-viewer-design.md §B2): one table for both apps, signed in only.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PREVIEW_ZONES } from '../src/suite/previewLayouts.js';
import { makeApp, people, type Client } from './helpers.js';

describe('GET /v1/preview/layouts', () => {
  let app: Awaited<ReturnType<typeof makeApp>>;
  let member: Client;
  beforeAll(async () => {
    app = await makeApp();
    member = (await people(app, 1)).members[0]!;
  });
  afterAll(async () => { await app.close(); });

  it('gives every member the phone layouts with zones that leave a safe box', async () => {
    const r = await member.req('GET', '/v1/preview/layouts');
    expect(r.status).toBe(200);
    expect(Object.keys(r.body.zones).sort()).toEqual(['facebook', 'reels', 'shorts', 'tiktok']);
    expect(r.body.note).toMatch(/Approximate/);
    for (const z of Object.values(PREVIEW_ZONES)) {
      for (const v of Object.values(z)) expect(v).toBeGreaterThanOrEqual(0);
      expect(z.top + z.bottom).toBeLessThan(0.6);
      expect(z.left + z.right).toBeLessThan(0.5);
    }
  });

  it('needs a signed-in person', async () => {
    const r = await app.app.inject({ method: 'GET', url: '/v1/preview/layouts' });
    expect(r.statusCode).toBe(401);
  });
});
