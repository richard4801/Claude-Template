// The learning editor (workstream 3, plans/recreate-edit.md §5, plans/api.md "Learning editor"): corrections captured from
// edit sessions, the recipe library (references + finished edits) with search, nearest and Posts performance, the
// owner-editable playbook, the gap list and the context Claude reads. No money, no model calls.
import fs from 'node:fs';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { posts, takes, users } from '../src/db/schema.js';
import type { AuthUser } from '../src/ctx.js';
import { recreateReferences } from '../src/recreate/schema.js';
import type { Recipe } from '../src/recreate/analyze.js';
import { areaFor, deriveTags, distance, features, recipeFromProject, sameThing, touched } from '../src/editor/learn.js';
import { LOOK_IDS } from '../src/editor/lookpack.js';
import * as M from '../src/editor/model.js';
import { editSessionsOf } from '../src/editor/sessions.js';
import { makeApp, people, until, type Client } from './helpers.js';

const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures');
const fixtureRecipe = () => (JSON.parse(fs.readFileSync(path.join(FIX, 'recipe-v1.json'), 'utf8')) as { recipe: Recipe }).recipe;

function project(): M.EditProject {
  return { version: 2, sourceTakeId: 't_src', canvas: { width: 1080, height: 1920, fps: 30 },
    assets: [{ id: 'a', kind: 'video', take: 't_src', durationSec: 12 }, { id: 'm', kind: 'audio', library: 'beat', durationSec: 12 }],
    tracks: [
      { id: 'main', kind: 'main', items: [
        { id: 'c1', asset: 'a', inSec: 0, outSec: 3, speed: 1, look: { lut: 'palette:golden_warmth', strength: 1 } } as M.VideoClip,
        { id: 'c2', asset: 'a', inSec: 3, outSec: 6, speed: 1, transitionIn: { kind: 'dissolve' as M.TransitionKind, durationSec: 0.4 },
          speedCurve: { preset: 'hero' as M.SpeedPreset, points: [[0, 1], [0.5, 0.3], [1, 1.5]] } } as M.VideoClip,
        { id: 'c3', asset: 'a', inSec: 6, outSec: 8, speed: 1 } as M.VideoClip] },
      { id: 'txt', kind: 'text', items: [{ id: 'x1', startSec: 0, durationSec: 2, text: 'Wait for it', style: { font: 'marker', weight: 700, sizePct: 0.06, color: '#FFFFFF', align: 'center' },
        transform: { x: 0.5, y: 0.2 } } as M.TextItem] },
      { id: 'mus', kind: 'music', items: [{ id: 'mu', asset: 'm', startSec: 0, inSec: 0, outSec: 8, beats: [0, 0.5, 1, 1.5, 2, 2.5], strongBeats: [0, 2] } as M.AudioClip] },
    ] };
}

describe('learning editor · recipes from edits, tags, nearest (unit)', () => {
  it('an edit becomes a recipe in the reference schema', () => {
    const r = recipeFromProject(project(), { takeId: 't_edit', versionId: 't_src', name: 'Café cut' });
    expect(r).toMatchObject({ schema: 'muse.recipe/1', origin: 'edit', takeId: 't_edit', versionId: 't_src', summary: 'Café cut',
      source: { width: 1080, height: 1920, fps: 30, aspect: '9:16' }, sound: { bpm: 120 } });
    expect(r.slots.map(s => s.id)).toEqual(['s1', 's2', 's3']);
    expect(r.slots.map(s => s.durationSec)).toEqual(M.timeline(project()).map(x => Math.round((x.endSec - x.startSec) * 1000) / 1000)); // the hero curve slows s2
    const len2 = r.slots[1]!.durationSec;
    expect(r.slots[1]!.speed).toMatchObject({ ramp: 'speed_up', curve: [{ t: 0, speed: 1 }, { t: Math.round(len2 / 2 * 1000) / 1000, speed: 0.3 }, { t: len2, speed: 1.5 }] });
    expect(r.transitions.map(t => t.kind)).toEqual(['crossfade', 'cut']);
    expect(r.text[0]).toMatchObject({ words: 'Wait for it', fontId: 'marker', sizeFrac: 0.06, startSec: 0, endSec: 2 });
    expect(r.grade.look).toMatchObject({ id: 'golden_warmth', kind: 'palette', distance: 0 });
    expect(r.grade.swatches).toHaveLength(5);
    expect(r.pacing.shots).toBe(3);
    const tags = deriveTags(r);
    expect(tags).toEqual(expect.arrayContaining(['own-edit', 'short', 'tempo-mid', 'transition-crossfade', 'text', 'speed-ramps', 'look-golden-warmth']));
  });

  it('nearest: the same recipe is 0 away; different pacing and tags are further', () => {
    const a = recipeFromProject(project(), { takeId: 'a' }), ref = fixtureRecipe();
    const fa = { features: features(a), tags: deriveTags(a) }, fr = { features: features(ref), tags: deriveTags(ref) };
    expect(distance(fa, fa)).toBe(0);
    expect(distance(fa, fr)).toBeGreaterThan(0.3);
    const b = project(); (b.tracks[0]!.items as M.VideoClip[]).push({ id: 'c4', asset: 'a', inSec: 8, outSec: 9, speed: 1 } as M.VideoClip);
    const fb = recipeFromProject(b, { takeId: 'b' });
    expect(distance(fa, { features: features(fb), tags: deriveTags(fb) })).toBeLessThan(distance(fa, fr));
  });

  it('what a change touched, item by item, and what it is about', () => {
    const a = project(), b = structuredClone(a);
    (b.tracks[0]!.items[0] as M.VideoClip).look = { lut: 'pack:film-gold', strength: 0.5 };
    (b.tracks[0]!.items[1] as M.VideoClip).transitionIn = { kind: 'fade' as M.TransitionKind, durationSec: 0.3 };
    b.tracks.unshift({ id: 'hooks', kind: 'text', items: [{ id: 'h1', startSec: 0, durationSec: 2, text: 'POV', style: { font: 'sans', weight: 900, sizePct: 0.07, color: '#FFF', align: 'center' } } as M.TextItem] });
    b.canvas.width = 1080; b.canvas.height = 1080;
    expect(touched(a, b).sort()).toEqual(['c1/look', 'c2/transitionIn', 'canvas/height', 'h1/*', 'track:hooks/id', 'track:hooks/kind'].sort());
    // Adding a whole track shifts every index, but only what really changed is touched.
    expect(touched(a, b)).not.toContain('c3/inSec');
    expect(sameThing('c1/look', 'c1/look')).toBe(true);
    expect(sameThing('c1/look', 'c1/outSec')).toBe(false);
    expect(sameThing('h1/*', 'h1/text')).toBe(true);
    expect(sameThing('c1/look', 'c10/look')).toBe(false);
    expect(areaFor('main', 'transitionIn')).toBe('transition');
    expect(areaFor('main', 'look')).toBe('look');
    expect(areaFor('main', 'transform')).toBe('motion');
    expect(areaFor('main', 'speedCurve')).toBe('speed');
    expect(areaFor('main', 'outSec')).toBe('timing');
    expect(areaFor('text', 'transform')).toBe('text');
    expect(areaFor('music', 'volume')).toBe('audio');
    expect(areaFor('caption', 'caption')).toBe('captions');
    expect(areaFor('canvas', 'width')).toBe('ratio');
  });
});

describe('learning editor · API', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, studioId: string, ownerUser: AuthUser, sid: string;
  const takeId = 'take_learn1';
  beforeAll(async () => {
    a = await makeApp();
    ({ owner, members: [member] } = await people(a, 1) as any);
    const [u] = await a.ctx.db.select().from(users).where(eq(users.role, 'owner'));
    studioId = u!.studioId;
    ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    await a.ctx.db.insert(takes).values({ id: takeId, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'Street walk', label: 'HD',
      engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: `c/${takeId}.mp4`, media: { durationSec: 6, width: 1080, height: 1920, fps: 30 }, createdAt: Date.now() });
    sid = (await owner.req('POST', '/v1/edit-sessions', { takeId, device: 'mac' })).body.id;
  });
  afterAll(async () => { await a?.close(); });
  const S = () => editSessionsOf(a.ctx);
  const rev = async () => (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.revision as number;
  const corrections = () => owner.req('GET', '/v1/learn/corrections').then(r => r.body as any[]);

  it('the owner changing what Claude changed is a correction, with the recipe element from meta', async () => {
    const lookId = LOOK_IDS.values().next().value as string;
    await S().applyClaude(ownerUser, sid, { baseRevision: await rev(), ops: [{ op: 'look', itemId: 'c1', look: lookId }],
      meta: { sources: { c1: { recipeId: 'rcp_ref', slotId: 's1' } } } });
    const p = (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body.project as M.EditProject;
    expect((p.tracks[0]!.items[0] as M.VideoClip).look).toBeTruthy();
    const r = await owner.req('POST', `/v1/edit-sessions/${sid}/patch`, { baseRevision: await rev(), device: 'mac',
      patch: [{ op: 'replace', path: '/tracks/0/items/0/look/strength', value: 0.4 }], label: 'Look strength' });
    expect(r.status).toBe(200);
    const list = await until(async () => { const c = await corrections(); return c.length ? c : null; });
    expect(list[0]).toMatchObject({ kind: 'change', area: 'look', takeId, what: expect.stringMatching(/^Changed the look after Claude's “/),
      context: { itemId: 'c1', source: { recipeId: 'rcp_ref', slotId: 's1' }, touched: ['c1/look'] } });
    expect(JSON.parse(list[0].context.after)).toMatchObject({ strength: 0.4 });
    // A second nudge of the same thing within the minute is the same lesson.
    await owner.req('POST', `/v1/edit-sessions/${sid}/patch`, { baseRevision: await rev(), patch: [{ op: 'replace', path: '/tracks/0/items/0/look/strength', value: 0.5 }] });
    await new Promise(r => setTimeout(r, 300));
    expect((await corrections()).length).toBe(1);
  });

  it('undoing Claude\'s change is a correction; Claude\'s own changes and unrelated owner edits are not', async () => {
    const before = (await corrections()).length;
    const c = await S().applyClaude(ownerUser, sid, { baseRevision: await rev(), ops: [{ op: 'add_text', text: 'Wait for it', startSec: 0, durationSec: 2 }] });
    await S().applyClaude(ownerUser, sid, { baseRevision: await rev(), ops: [{ op: 'add_text', text: 'Again', startSec: 3, durationSec: 1 }] });
    await new Promise(r => setTimeout(r, 300));
    expect((await corrections()).length).toBe(before); // Claude correcting itself isn't a lesson
    // Unrelated: the owner trims the clip end (Claude only touched the look and the text track).
    await owner.req('POST', `/v1/edit-sessions/${sid}/patch`, { baseRevision: await rev(), patch: [{ op: 'replace', path: '/tracks/0/items/0/outSec', value: 5 }] });
    await new Promise(r => setTimeout(r, 300));
    expect((await corrections()).length).toBe(before);
    expect((await owner.req('POST', `/v1/edit-sessions/${sid}/undo`, { entryId: c.entry!.id, device: 'mac' })).status).toBe(200);
    const list = await until(async () => { const l = await corrections(); return l.length > before ? l : null; });
    expect(list[0]).toMatchObject({ kind: 'undo', area: 'text', what: expect.stringMatching(/^Undid Claude's “/) });
    const lessons = (await owner.req('GET', '/v1/learn/lessons')).body;
    expect(lessons.map((l: any) => l.area).sort()).toEqual(['look', 'text']);
    expect(lessons.find((l: any) => l.area === 'text')).toMatchObject({ count: 1, undos: 1 });
  });

  it('the library: references and finished edits, tags, search, performance from Posts, nearest; gaps counted once per recipe', async () => {
    const now = Date.now(), base = fixtureRecipe();
    const gap = (at: number) => ({ key: `transition:unknown@${at}`, kind: 'transition', what: 'A transition the editor can’t make yet', atSec: at, note: 'spin blur' });
    for (const [id, name, at, tags] of [['ref_a', 'Street dance', 2.4, ['dance', 'street']], ['ref_b', 'Outfit flip', 5.1, ['outfit-transition']]] as const) {
      await a.ctx.db.insert(recreateReferences).values({ id, studioId, userId: ownerUser.id, name, state: 'ready', recipe: { ...base, tags: [...tags], summary: `${name} summary`, gaps: [gap(at)] } as never,
        createdAt: now - 1000, expiresAt: now + 86_400_000 });
    }
    // A finished edit (an edited version with a v2 project) and a post made from it.
    await a.ctx.db.insert(takes).values({ id: 'take_edit1', studioId, userId: null, kind: 'edit' as never, jobId: null, modelId: null, index: 1, of: 1, title: 'Café cut', label: 'Edit',
      engineLabel: '', cost: 0, seed: 0, status: 'final', thumb: null, prompt: '', mediaKey: 'c/take_edit1.mp4', media: { durationSec: 8, parentTakeId: takeId, edits: project() } as never, createdAt: now });
    await a.ctx.db.insert(posts).values({ id: 'post_1', studioId, userId: ownerUser.id, modelId: 'm1', takeId: 'take_edit1', title: 'Café cut', thumb: null, platforms: ['tiktok'],
      caption: '', when: 'now', dueAt: now, state: 'posted', createdAt: now, stats: { views: 1200, likes: 80, comments: 4, saves: 12, watchTimeSec: 6.5, completion: 0.42 } as never });

    const all = (await owner.req('GET', '/v1/learn/recipes')).body;
    expect(all.map((r: any) => r.name).sort()).toEqual(['Café cut', 'Outfit flip', 'Street dance']);
    const edit = all.find((r: any) => r.origin === 'edit');
    expect(edit).toMatchObject({ takeId: 'take_edit1', performance: { posts: 1, views: 1200, likes: 80, comments: 4, saves: 12, avgWatchSec: 6.5, completion: 0.42 } });
    expect(edit.recipe).toBeUndefined();
    expect(all.find((r: any) => r.name === 'Street dance').tags).toEqual(expect.arrayContaining(['reference', 'dance', 'street']));
    expect((await owner.req('GET', '/v1/learn/recipes?q=outfit')).body.map((r: any) => r.name)).toEqual(['Outfit flip']);
    expect((await owner.req('GET', '/v1/learn/recipes?tags=dance,street')).body.map((r: any) => r.name)).toEqual(['Street dance']);
    expect((await owner.req('GET', '/v1/learn/recipes?origin=edit')).body).toHaveLength(1);
    const one = (await owner.req('GET', `/v1/learn/recipes/${edit.id}`)).body;
    expect(one.recipe).toMatchObject({ origin: 'edit', takeId: 'take_edit1', schema: 'muse.recipe/1' });

    // Syncing again copies nothing twice and counts no gap twice.
    expect((await owner.req('GET', '/v1/learn/recipes')).body).toHaveLength(3);
    const gaps = (await owner.req('GET', '/v1/learn/gaps')).body;
    expect(gaps[0]).toMatchObject({ key: 'transition:unknown', kind: 'transition', count: 2 });
    expect(gaps[0].examples.map((e: any) => e.atSec).sort()).toEqual([2.4, 5.1]);
    const asked = (await owner.req('POST', '/v1/learn/gaps', { key: 'effect:lens-flare', kind: 'effect', what: 'Lens flare', note: 'asked in chat' })).body;
    expect(asked).toMatchObject({ key: 'effect:lens-flare', count: 1 });
    expect((await owner.req('POST', '/v1/learn/gaps', { key: 'not a key!' })).status).toBe(400);

    const near = (await owner.req('GET', '/v1/learn/recipes/nearest?referenceId=ref_a&k=2')).body;
    expect(near.nearest).toHaveLength(2);
    expect(near.nearest[0].name).toBe('Outfit flip'); // the other reference is closer than the own edit
    expect(near.nearest[0].distance).toBeLessThan(near.nearest[1].distance);
    expect((await owner.req('GET', '/v1/learn/recipes/nearest?referenceId=nope')).status).toBe(404);

    const renamed = (await owner.req('PATCH', `/v1/learn/recipes/${edit.id}`, { name: 'Café cut v2', tags: ['Cafe', 'cafe', 'hook-first'] })).body;
    expect(renamed).toMatchObject({ name: 'Café cut v2', tags: ['cafe', 'hook-first'] });
    expect((await owner.req('PATCH', `/v1/learn/recipes/${edit.id}`, { tags: 'x' })).status).toBe(400);
  });

  it('the playbook: the owner reads, adds, edits, pins and deletes; Claude-written rules are marked; checks', async () => {
    const r1 = (await owner.req('POST', '/v1/learn/playbook', { text: 'Captions above the chin', area: 'captions',
      evidence: [{ kind: 'correction', id: 1, note: 'moved 3 times' }] })).body;
    expect(r1).toMatchObject({ text: 'Captions above the chin', area: 'captions', source: 'owner', pinned: false, evidence: [{ kind: 'correction', id: 1, note: 'moved 3 times' }] });
    const { learningOf } = await import('../src/editor/learn.js');
    const r2 = await learningOf(a.ctx).addRule(ownerUser, { text: 'First cut by 0.8 s', area: 'pacing' }, 'claude');
    expect(r2).toMatchObject({ source: 'claude', pinned: false });
    expect((await owner.req('PATCH', `/v1/learn/playbook/${r2.id}`, { pinned: true, text: 'First cut by 0.8 s at most' })).body).toMatchObject({ pinned: true, text: 'First cut by 0.8 s at most' });
    const list = (await owner.req('GET', '/v1/learn/playbook')).body;
    expect(list.map((r: any) => r.id)).toEqual([r2.id, r1.id]); // pinned first
    expect((await owner.req('GET', '/v1/learn/playbook?area=captions')).body.map((r: any) => r.id)).toEqual([r1.id]);
    for (const bad of [{ text: '' }, { text: 'x'.repeat(301) }, { text: 'ok', area: 'colour' }, { text: 'ok', evidence: [{ kind: 'gossip' }] }])
      expect((await owner.req('POST', '/v1/learn/playbook', bad)).status).toBe(400);
    expect((await owner.req('PATCH', `/v1/learn/playbook/${r1.id}`, { pinned: 'yes' })).status).toBe(400);
    expect((await owner.req('DELETE', `/v1/learn/playbook/${r1.id}`)).status).toBe(204);
    expect((await owner.req('DELETE', `/v1/learn/playbook/${r1.id}`)).status).toBe(404);
  });

  it('what the screens need: tile picture and badge, source still there, top tags, gap counts, evidence takes, lessons already ruled', async () => {
    const all = (await owner.req('GET', '/v1/learn/recipes')).body as any[];
    const ref = all.find(r => r.referenceId === 'ref_a'), edit = all.find(r => r.origin === 'edit');
    expect(ref).toMatchObject({ picture: { poster: '/v1/recreate/references/ref_a/poster' }, available: true, durationSec: expect.any(Number), cuts: expect.any(Number) });
    expect(ref.cuts).toBe(Math.max(0, ref.features.shots - 1));
    expect(edit).toMatchObject({ available: true, picture: null }); // the take has no thumbnail
    await a.ctx.db.update(recreateReferences).set({ state: 'expired' }).where(eq(recreateReferences.id, 'ref_b'));
    expect((await owner.req('GET', '/v1/learn/recipes')).body.find((r: any) => r.referenceId === 'ref_b').available).toBe(false);

    const tags = (await owner.req('GET', '/v1/learn/tags?limit=3')).body;
    expect(tags).toHaveLength(3);
    // Both references share their derived tags (the edit's were replaced above): most used first, ties alphabetical.
    expect(tags.map((t: any) => t.count)).toEqual([2, 2, 2]);
    expect(tags.map((t: any) => t.tag)).toEqual([...tags.map((t: any) => t.tag)].sort());

    const gaps = (await owner.req('GET', '/v1/learn/gaps')).body;
    expect(gaps.find((g: any) => g.key === 'transition:unknown')).toMatchObject({ count: 2, references: 2, asks: 0 });
    expect(gaps.find((g: any) => g.key === 'effect:lens-flare')).toMatchObject({ count: 1, references: 0, asks: 1 });

    const cs = await corrections();
    expect(cs.every(c => c.takeExists === true)).toBe(true);
    const lesson = (await owner.req('GET', '/v1/learn/lessons')).body.find((l: any) => l.area === 'look');
    expect(lesson.ruleId).toBeUndefined();
    const rule = (await owner.req('POST', '/v1/learn/playbook', { text: 'Leave the look strength as set', area: 'look',
      evidence: lesson.ids.map((id: number) => ({ kind: 'correction', id, note: 'from a suggestion' })) })).body;
    expect((await owner.req('GET', '/v1/learn/lessons')).body.find((l: any) => l.area === 'look').ruleId).toBe(rule.id);
    const shown = (await owner.req('GET', '/v1/learn/playbook')).body.find((r: any) => r.id === rule.id);
    expect(shown.evidence[0]).toMatchObject({ kind: 'correction', takeId, takeExists: true });
    await owner.req('DELETE', `/v1/learn/playbook/${rule.id}`);
  });

  it('the context Claude reads: playbook, nearest proven recipes, corrections, lessons, gaps', async () => {
    const c = (await owner.req('GET', '/v1/learn/context?referenceId=ref_b')).body;
    expect(c.playbook[0]).toMatchObject({ text: 'First cut by 0.8 s at most', pinned: true });
    expect(c.recipes.length).toBeGreaterThan(0);
    expect(c.recipes.some((r: any) => r.name === 'Street dance')).toBe(true);
    expect(c.corrections.map((x: any) => x.area)).toEqual(expect.arrayContaining(['look', 'text']));
    expect(c.lessons.length).toBe(2);
    expect(c.gaps[0]).toMatchObject({ key: 'transition:unknown', count: 2 });
    const plain = (await owner.req('GET', '/v1/learn/context')).body;
    expect(plain.recipes.map((r: any) => r.origin)).toEqual(['edit']); // no recipe at hand: the latest own edits
  });

  it('owner only', async () => {
    for (const [m, p] of [['GET', '/v1/learn/recipes'], ['GET', '/v1/learn/playbook'], ['POST', '/v1/learn/playbook'], ['GET', '/v1/learn/gaps'], ['GET', '/v1/learn/context'], ['GET', '/v1/learn/corrections'], ['GET', '/v1/learn/tags']] as const)
      expect((await member.req(m, p, m === 'POST' ? { text: 'x' } : undefined)).status, `${m} ${p}`).toBe(403);
  });
});
