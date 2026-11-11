// Claude sets every composer control (owner gap 2026-11-11): Movement → Directed from a camera session (its greybox and
// start/middle/end stills become the request's camera guide), the pinned model and resolution, and back to the chips.
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { cameraAssets } from '../src/camera/schema.js';
import { SUITE_TOOLS } from '../src/suite/mcpTools.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, ownerU: AuthUser;
const tool = (n: string) => SUITE_TOOLS.find(t => t.name === n)!;
const env = () => ({ ctx: a.ctx, user: ownerU, source: 'chat' }) as any;

beforeAll(async () => {
  a = await makeApp({ SUITE_MODE: 'mock' });
  ({ owner } = await people(a, 0) as any);
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
  ownerU = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
});
afterAll(async () => { await a?.close(); });

describe('suite_set_draft: Directed and the pinned model', () => {
  it('a session without guides is refused; with guides the request carries its camera; null goes back to the chips', async () => {
    const assistId = (await owner.req('POST', '/v1/suite/assist', {})).body.id;
    const cs = (await owner.req('POST', '/v1/camera-sessions', { title: 'Gamified Outfit Show · Snap reveal', durationSec: 6 })).body;
    await expect(tool('suite_set_draft').run(env(), { assistId, directed: { cameraSessionId: cs.id } })).rejects.toMatchObject({ code: 'no_guides' });
    const add = (id: string, kind: string, key: string) => a.ctx.db.insert(cameraAssets).values({ id, sessionId: cs.id, studioId: ownerU.studioId, kind: kind as never, storageKey: key,
      contentType: kind === 'greybox' ? 'video/mp4' : 'image/png', state: 'ready', source: 'relay', createdAt: Date.now() });
    await add('ca_g', 'greybox', 'c/grey.mp4'); await add('ca_s', 'keyframe_start', 'c/s.png'); await add('ca_e', 'keyframe_end', 'c/e.png');
    const v = await tool('suite_set_draft').run(env(), { assistId, prompt: 'She spins and the outfit snaps on.', directed: { cameraSessionId: cs.id }, engineModel: 'kling', resolution: '1080p' }) as any;
    expect(v.request.camera).toMatchObject({ mode: 'directed', guide: { video: { key: 'c/grey.mp4' }, use: 'blocking', cameraSessionId: cs.id, keyframes: { start: '/uploads/c/s.png', end: '/uploads/c/e.png' } } });
    expect(v.request).toMatchObject({ engineModel: 'kling', resolution: '1080p' });
    const back = await tool('suite_set_draft').run(env(), { assistId, directed: null, engineModel: null }) as any;
    expect(back.request.camera?.mode).not.toBe('directed');
    expect(back.request.engineModel).toBeUndefined();
  });
});
