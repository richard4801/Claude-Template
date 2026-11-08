// Claude follows the playbook (workstream 1 on workstream 3's learning editor): the owner's pinned rules become
// directives that change Claude's plan and refuse Claude's changes that break them; open_edit hands Claude the playbook;
// the studio's own posted edit is found as a starting point. No money, no model calls.
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { posts, takes, users } from '../src/db/schema.js';
import { recipeFromProject } from '../src/editor/learn.js';
import { EDIT_TOOLS } from '../src/editor/mcpTools.js';
import * as M from '../src/editor/model.js';
import { editSessionsOf } from '../src/editor/sessions.js';
import { directivesOf, provenStart, START_FROM_MAX_DISTANCE, violations } from '../src/recreate/playbook.js';
import { recreateReferences } from '../src/recreate/schema.js';
import { makeApp, people, type Client } from './helpers.js';

const pin = (text: string, id: string | number = text) => ({ id, text, pinned: true });

describe('Playbook directives (unit)', () => {
  it('only pinned, plainly worded rules become directives; qualified ones are left for Claude', () => {
    const r = directivesOf([
      pin('No speed ramps.'), pin('Hard cuts only'), pin('Keep the camera still'), pin('Never use text on my reels'), pin('Keep the natural colours'),
      pin('Keep transitions under 0.25 s'),
      pin('Never put text over her face'), pin('Open on her face'), { id: 'u', text: 'No zooms', pinned: false },
    ]);
    expect(r.directives).toEqual({ speed: false, transitions: false, camera: false, text: false, look: false, maxTransitionSec: 0.25 });
    expect(r.followed.map(f => f.effect)).toEqual(['no speed ramps', 'hard cuts only', 'no camera moves', 'no on-screen text', 'no looks or grades', 'transitions at most 0.25 s']);
    expect(r.toFollow.map(f => f.text)).toEqual(['Never put text over her face', 'Open on her face']);
    expect(directivesOf([pin('Don’t use zooms'), pin('avoid slow-mo')]).directives).toEqual({ camera: false, speed: false });
    expect(directivesOf([pin('Captions sit above the lower third')]).directives).toEqual({});
  });

  it('a change breaks a directive only by what it adds or alters', () => {
    const before: M.EditProject = { version: 2, sourceTakeId: 't', canvas: { width: 1080, height: 1920, fps: 30 }, assets: [{ id: 'a', kind: 'video', take: 't', durationSec: 9 }],
      tracks: [{ id: 'main', kind: 'main', items: [
        { id: 'c1', asset: 'a', inSec: 0, outSec: 3, speed: 1, speedCurve: { preset: 'hero', points: [[0, 1], [1, 1.5]] } } as M.VideoClip,
        { id: 'c2', asset: 'a', inSec: 3, outSec: 6, speed: 1 } as M.VideoClip] }] };
    const after = structuredClone(before);
    const c2 = after.tracks[0]!.items[1] as M.VideoClip;
    expect(violations(before, after, { speed: false })).toEqual([]); // the owner's ramp on c1 was already there
    c2.speedCurve = { preset: 'hero', points: [[0, 1], [1, 1.5]] };
    c2.transitionIn = { kind: 'fade', durationSec: 0.6 };
    c2.keyframes = { scale: [{ t: 0, v: 1 }, { t: 2, v: 1.3 }], opacity: [{ t: 0, v: 0 }, { t: 1, v: 1 }] };
    after.tracks.push({ id: 'text', kind: 'text', items: [{ id: 'x1', startSec: 0, durationSec: 1, text: 'Hi', style: {} } as M.TextItem] });
    expect(violations(before, after, { speed: false, camera: false, text: false, transitions: false }).map(v => v.key)).toEqual(['speed', 'camera', 'transitions', 'text']);
    expect(violations(before, after, { maxTransitionSec: 0.3 }).map(v => v.what)).toEqual(['a 0.6 s transition into c2']);
    expect(violations(before, after, { look: false })).toEqual([]);
  });
});

describe('Playbook · Claude\'s edits', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, studioId: string, ownerUser: AuthUser, sid: string;
  const takeId = 'take_pb1';
  const tool = (n: string) => EDIT_TOOLS.find(t => t.name === n)!;
  const env = () => ({ ctx: a.ctx, user: ownerUser, source: 'mcp' as const });
  const rev = async () => (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.revision as number;
  beforeAll(async () => {
    a = await makeApp();
    ({ owner } = await people(a, 1) as any);
    const [u] = await a.ctx.db.select().from(users).where(eq(users.role, 'owner'));
    studioId = u!.studioId;
    ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    await a.ctx.db.insert(takes).values({ id: takeId, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'Street walk', label: 'HD',
      engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: `c/${takeId}.mp4`, media: { durationSec: 6, width: 1080, height: 1920, fps: 30 }, createdAt: Date.now() });
  });
  afterAll(async () => { await a?.close(); });

  it('open_edit gives Claude the playbook: enforced rules, rules to follow itself, the rest', async () => {
    for (const [text, pinned] of [['No speed ramps', true], ['Open on her face', true], ['Short hooks do better', false]] as const)
      expect((await owner.req('POST', '/v1/learn/playbook', { text, pinned })).status).toBe(200);
    const o = await tool('open_edit').run(env(), { takeId }) as any;
    sid = o.sessionId;
    expect(o.playbook.enforced).toEqual([expect.objectContaining({ text: 'No speed ramps', effect: 'no speed ramps' })]);
    expect(o.playbook.followYourself.map((r: any) => r.text)).toEqual(['Open on her face']);
    expect(o.playbook.otherRules.map((r: any) => r.text)).toEqual(['Short hooks do better']);
  });

  it('a pinned rule refuses Claude\'s change that breaks it (any tool); other changes and the owner\'s own go through', async () => {
    const before = await rev();
    const bad = tool('apply_edit_ops').run(env(), { sessionId: sid, baseRevision: before, ops: [{ op: 'split', at: 3 }, { op: 'speed', clipId: 'c1', curve: 'hero' }] });
    await expect(bad).rejects.toMatchObject({ status: 409, code: 'playbook_rule', message: expect.stringMatching(/pinned rule “No speed ramps”: a speed ramp on c1/) });
    expect(await rev()).toBe(before); // nothing applied
    // A plain patch can't slip one in either.
    await expect(editSessionsOf(a.ctx).applyClaude(ownerUser, sid, { baseRevision: before, ops: [{ op: 'patch', patch: [{ op: 'add', path: '/tracks/0/items/0/speedCurve', value: { preset: 'hero', points: [[0, 1], [1, 2]] } }] }] }))
      .rejects.toMatchObject({ code: 'playbook_rule' });
    const ok = await tool('apply_edit_ops').run(env(), { sessionId: sid, baseRevision: before, ops: [{ op: 'split', at: 3 }] }) as any;
    expect(ok.revision).toBe(before + 1);
    // The owner, in the app, may do what the rule keeps Claude from doing.
    const own = await owner.req('POST', `/v1/edit-sessions/${sid}/patch`, { baseRevision: ok.revision, device: 'mac', patch: [{ op: 'add', path: '/tracks/0/items/0/speedCurve', value: { preset: 'hero', points: [[0, 1], [1, 2]] } }] });
    expect(own.status).toBe(200);
    // Unpinned, the rule is advice again.
    const rules = (await owner.req('GET', '/v1/learn/playbook')).body as any[];
    await owner.req('PATCH', `/v1/learn/playbook/${rules.find(r => r.text === 'No speed ramps').id}`, { pinned: false });
    const now = await tool('apply_edit_ops').run(env(), { sessionId: sid, baseRevision: await rev(), ops: [{ op: 'speed', clipId: 'c2', curve: 'hero' }] }) as any;
    expect(now.changes[0]).toMatch(/Speed curve/);
  });

  it('the nearest posted edit that fits is the start for a new recreate (with its look); none without posts', async () => {
    const proj: M.EditProject = { version: 2, sourceTakeId: takeId, canvas: { width: 1080, height: 1920, fps: 30 }, assets: [{ id: 'a', kind: 'video', take: takeId, durationSec: 9 }],
      tracks: [{ id: 'main', kind: 'main', items: [0, 1, 2].map(i => ({ id: `c${i + 1}`, asset: 'a', inSec: i * 1.5, outSec: i * 1.5 + 1.5, speed: 1, look: { lut: 'palette:golden_warmth', strength: 0.8 } }) as M.VideoClip) }] };
    const now = Date.now();
    await a.ctx.db.insert(takes).values({ id: 'take_edit_pb', studioId, userId: null, kind: 'edit' as never, jobId: null, modelId: null, index: 1, of: 1, title: 'Golden cut', label: 'Edit',
      engineLabel: '', cost: 0, seed: 0, status: 'final', thumb: null, prompt: '', mediaKey: 'c/take_edit_pb.mp4', media: { durationSec: 4.5, parentTakeId: takeId, edits: proj } as never, createdAt: now });
    // The reference: the same pacing and look as that edit.
    const ref = { ...recipeFromProject(proj, { takeId: 'take_edit_pb' } as never), origin: 'reference' } as never;
    await a.ctx.db.insert(recreateReferences).values({ id: 'rx_pb', studioId, userId: ownerUser.id, name: 'Golden ref', state: 'ready', recipe: ref, createdAt: now, expiresAt: now + 86_400_000 });
    expect(await provenStart(a.ctx, ownerUser, 'rx_pb')).toBeNull(); // not posted yet
    await a.ctx.db.insert(posts).values({ id: 'post_pb', studioId, userId: ownerUser.id, modelId: 'm1', takeId: 'take_edit_pb', title: 'Golden cut', thumb: null, platforms: ['tiktok'],
      caption: '', when: 'now', dueAt: now, state: 'posted', createdAt: now, stats: { views: 5000, likes: 300, comments: 9 } as never });
    const s = await provenStart(a.ctx, ownerUser, 'rx_pb');
    expect(s).toMatchObject({ name: 'Golden cut', look: { id: 'golden_warmth' }, performance: { posts: 1, views: 5000 } });
    expect(s!.distance).toBeLessThanOrEqual(START_FROM_MAX_DISTANCE);
    expect(await provenStart(a.ctx, { ...ownerUser, role: 'member' }, 'rx_pb')).toBeNull();
  });
});
