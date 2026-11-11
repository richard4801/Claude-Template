// Claude announces mask / Invert / green-screen / cut-out changes (owner, 2026-11-11, after the hidden inverted "oval").
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { takes, users } from '../src/db/schema.js';
import { EDIT_TOOLS } from '../src/editor/mcpTools.js';
import { makeApp, people, type Client } from './helpers.js';

describe('Claude\'s mask changes carry a notice and their undo id', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, u: AuthUser;
  const tool = (n: string) => EDIT_TOOLS.find(t => t.name === n)!;
  const env = () => ({ ctx: a.ctx, user: u, source: 'mcp' as const });
  beforeAll(async () => {
    a = await makeApp();
    ({ owner } = await people(a, 1) as any);
    const [o] = await a.ctx.db.select().from(users).where(eq(users.role, 'owner'));
    u = { id: o!.id, studioId: o!.studioId, email: o!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    await a.ctx.db.insert(takes).values({ id: 'take_mn', studioId: u.studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'Walk', label: 'HD',
      engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: 'c/take_mn.mp4', media: { durationSec: 6, width: 1080, height: 1920, fps: 30 }, createdAt: Date.now() });
  });
  afterAll(async () => { await a?.close(); });

  it('an inverted oval mask is announced; Undo of that entry removes exactly it; other changes say nothing', async () => {
    const o = await tool('open_edit').run(env(), { takeId: 'take_mn' }) as any;
    const r = await tool('apply_edit_ops').run(env(), { sessionId: o.sessionId, baseRevision: o.revision, ops: [{ op: 'mask', itemId: 'c1', mask: { shape: 'circle', invert: true } }] }) as any;
    expect(r.notice).toBe('Added an inverted oval mask to clip 1');
    expect(r.undoEntryId).toBe(r.entry.id);
    expect(r.entry.notice).toBe(r.notice);
    const plain = await tool('apply_edit_ops').run(env(), { sessionId: o.sessionId, baseRevision: r.revision, ops: [{ op: 'split', at: 3 }] }) as any;
    expect(plain.notice).toBeUndefined(); // the right half keeps the same mask: not a new change
    await tool('undo_edit').run(env(), { sessionId: o.sessionId, entryId: plain.entry.id });
    await tool('undo_edit').run(env(), { sessionId: o.sessionId, entryId: r.undoEntryId });
    const s = (await owner.req('GET', `/v1/edit-sessions/${o.sessionId}`)).body;
    expect(s.project.tracks[0].items.map((c: any) => c.mask)).toEqual([undefined]);
  });
});
