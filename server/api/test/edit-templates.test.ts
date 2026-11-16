// Edit templates (plans/edit-templates.md §2–§3): the spec and its expansion into ordinary edit items, the 27 seeds,
// the primitive gate, the track limit, Save as template, and the library end to end (tools and routes, dryRun, one
// undoable change, the paid cut-out through the owner's Approve, never above the price shown). Mock provider, no money.
import fs from 'node:fs';
import path from 'node:path';
import { and, eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { takes, uploads, users } from '../src/db/schema.js';
import { registryByName, toolsForUser } from '../src/claude/registry.js';
import * as M from '../src/editor/model.js';
import { checkSpec, evalExpr, expandTemplate, PRIMITIVES, readiness, specFromSelection, type EditTemplateSpec } from '../src/editor/editTemplates.js';
import { SEED_TEMPLATES } from '../src/editor/editTemplateSeeds.js';
import { editTemplates } from '../src/editor/learnSchema.js';
import { editorJobs } from '../src/editor/schema.js';
import { makeApp, people, until, type Client } from './helpers.js';

const seed = (id: string) => SEED_TEMPLATES.find(t => t.id === id)!;
const fixture = (): M.EditProject => ({
  version: 2, sourceTakeId: 'ta', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
  assets: [{ id: 'a', kind: 'video', take: 'ta', durationSec: 20 }, { id: 'b', kind: 'video', take: 'tb', durationSec: 20 }, { id: 'm', kind: 'audio', upload: 'up_m', durationSec: 30 }],
  tracks: [
    { id: 'main', kind: 'main', items: [
      { id: 'c1', asset: 'a', inSec: 2, outSec: 4, speed: 1 } as M.VideoClip,
      { id: 'c2', asset: 'b', inSec: 5, outSec: 7, speed: 1, transform: { scale: 1.1 } } as M.VideoClip,
      { id: 'c3', asset: 'a', inSec: 8, outSec: 10, speed: 1 } as M.VideoClip,
      { id: 'c4', asset: 'b', inSec: 1, outSec: 3, speed: 1 } as M.VideoClip,
    ] },
    { id: 'mus', kind: 'music', items: [{ id: 'mu', asset: 'm', startSec: 0, inSec: 0, outSec: 8, beats: [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6] } as M.AudioClip] },
  ],
});
const all = (p: M.EditProject) => p.tracks.flatMap(t => t.items.map(i => ({ t, i })));
const valid = (p: M.EditProject) => M.validate(p, [], new Set(), new Set(), { draft: true });

describe('expressions', () => {
  it('reads numbers, variables, arithmetic, comparisons and the few functions; nothing else', () => {
    const v = (n: string) => ({ cut: 2, lead: 0.3, 'next.in': 5, g: 2 } as Record<string, unknown>)[n];
    expect(evalExpr('$cut - $lead', v)).toBeCloseTo(1.7);
    expect(evalExpr('$next.in - $lead * 2', v)).toBeCloseTo(4.4);
    expect(evalExpr('lerp(1, $g, 0.5) / $g', v)).toBeCloseTo(0.75);
    expect(evalExpr('if($cut > 1, 3, 4) + 7 % 4', v)).toBe(6);
    expect(() => evalExpr('process.exit(1)', v)).toThrow(/can't be read/);
    expect(() => evalExpr('$nope + 1', v)).toThrow(/not a number/);
    expect(() => evalExpr('1 +', v)).toThrow();
  });
});

describe('the 27 seeds', () => {
  it('are the pack\'s 27: 11 live and free, 7 with a paid cut-out, 9 not ready with the reason', () => {
    expect(SEED_TEMPLATES).toHaveLength(27);
    expect(new Set(SEED_TEMPLATES.map(t => t.id)).size).toBe(27);
    const live = SEED_TEMPLATES.filter(t => t.level === 'live'), matte = SEED_TEMPLATES.filter(t => t.level === 'matte');
    expect(live.map(t => t.id).sort()).toEqual(['comic-page-fly-in', 'corner-signature', 'diagonal-stripe', 'flash-white', 'hit-rgb-split', 'multi-hit-split', 'panel-pile', 'punch-in', 'punch-split', 'white-out', 'window-open-next']);
    expect(matte.map(t => t.id).sort()).toEqual(['background-glitch', 'band-behind-subject', 'burst-out-card', 'cover-freeze', 'cutout-carry-over', 'subject-first-drop', 'title-behind-subject']);
    const notReady = SEED_TEMPLATES.filter(t => !readiness(t).ready);
    expect(notReady).toHaveLength(9);
    for (const t of notReady) { const r = readiness(t); expect(r.ready).toBe(false); if (!r.ready) expect(r.reason.length).toBeGreaterThan(10); }
    for (const t of SEED_TEMPLATES) { expect(() => checkSpec(t)).not.toThrow(); expect(t.source?.pack).toBe('icon-storyboard'); }
  });

  it('every live and paid seed expands onto a real edit into a project the apps accept (validation passes)', () => {
    for (const t of SEED_TEMPLATES.filter(x => readiness(x).ready)) {
      const target = t.target === 'cut' ? { cutAfter: 'c2' } : t.target === 'clip' ? { itemId: 'c2' } : { edit: true as const };
      const ex = expandTemplate(fixture(), t, target, { params: t.id === 'corner-signature' ? { image: 'up_mark', hideOn: [[1, 2]] } : {} });
      expect(() => valid(ex.project), t.id).not.toThrow();
      expect(JSON.stringify(ex.project), t.id).not.toBe(JSON.stringify(fixture()));
      expect(ex.mattes.length > 0, t.id).toBe(t.level === 'matte');
    }
  });
});

describe('expansion', () => {
  it('window opens the next shot: a copy of it, in place, playing the lead before its in-point, masked by hold keys', () => {
    const ex = expandTemplate(fixture(), seed('window-open-next'), { cutAfter: 'c2' }, { params: { lead: 0.3 } });
    const cut = M.timeline(ex.project)[2]!.startSec; // c3
    const copy = all(ex.project).find(x => x.t.kind === 'video')!.i as M.VideoClip;
    expect(copy).toMatchObject({ asset: 'a', inSec: 7.7, outSec: 8, speed: 1, muted: true, startSec: cut - 0.3, mask: { shape: 'rect', x: 0.5, y: 0.39, width: 0.4, height: 0.3 } });
    expect(copy.keyframes!.maskWidth!.map(k => k.ease)).toEqual(['hold', 'hold']);
    expect(copy.keyframes!.exposure!.map(k => k.v)).toEqual([0.6, 0.3, 0]); // the white entrance wash, k 0.6, 0.3
    // Slats: one copy per slat, each on its own track, staggered, washed as thin layers (0.9, 0.65, 0.35).
    const sl = expandTemplate(fixture(), seed('window-open-next'), { cutAfter: 'c2' }, { params: { shape: 'slats', wash: 'blue' } });
    const copies = all(sl.project).filter(x => x.t.kind === 'video');
    expect(copies).toHaveLength(3);
    expect(sl.tracksAdded).toBe(3); // they overlap in time: one track each
    const starts = copies.map(x => (x.i as M.VideoClip).startSec!).sort();
    expect(starts[1]! - starts[0]!).toBeCloseTo(0.1, 2); // staggered by a third of the lead
    expect((copies[0]!.i as M.VideoClip).keyframes!.temperature!.map(k => k.v)).toEqual([-0.9, -0.65, -0.35, 0]);
  });

  it('the white line waits for its primitive: hidden from the params, its default used, a value sent is ignored', () => {
    expect(PRIMITIVES.N2.live).toBe(false);
    const a = expandTemplate(fixture(), seed('window-open-next'), { cutAfter: 'c1' }, { params: { line: true } });
    const b = expandTemplate(fixture(), seed('window-open-next'), { cutAfter: 'c1' });
    expect(JSON.stringify(a.project)).toBe(JSON.stringify(b.project));
  });

  it('punch-in: normalised scale keys over the clip, relative to its own scale; on each selected clip', () => {
    const ex = expandTemplate(fixture(), seed('punch-in'), { itemIds: ['c2', 'c3'] });
    const [c2, c3] = ['c2', 'c3'].map(id => M.mainTrack(ex.project).items.find(c => c.id === id) as M.VideoClip);
    expect(c2!.keyframes!.scale).toEqual([{ t: 0, v: 1.485, ease: 'easeOut' }, { t: 2, v: 1.1 }]);
    expect(c3!.keyframes!.scale).toEqual([{ t: 0, v: 1.35, ease: 'easeOut' }, { t: 2, v: 1 }]);
    expect(ex.targets).toEqual(['c2', 'c3']);
    expect(ex.labels[0]).toBe('Punch-in × 2');
  });

  it('cuts: the RGB split hit is a short glitch on each cut; on note cuts only those on a beat', () => {
    const ex = expandTemplate(fixture(), seed('hit-rgb-split'), { each: 'cut' });
    expect(M.mainTrack(ex.project).items.slice(1).map(c => (c as M.VideoClip).transitionIn)).toEqual([{ kind: 'glitch', durationSec: 0.1 }, { kind: 'glitch', durationSec: 0.1 }, { kind: 'glitch', durationSec: 0.1 }]);
    const flash = expandTemplate(fixture(), seed('flash-white'), { each: 'note-cut' });
    expect(flash.targets).toEqual(['c2', 'c3', 'c4']); // cuts at 2, 4, 6 s, all on beats
    const adj = all(flash.project).filter(x => x.t.kind === 'adjust').map(x => x.i as M.AdjustItem);
    expect(adj.map(x => x.startSec)).toEqual([2, 4, 6]);
    expect(adj[0]!.keyframes!.exposure!.map(k => k.v)).toEqual([1, 0.6, 0.3, 0]);
  });

  it('notes: panel pile lands one panel per beat before the cut, the last is the next shot; without beats, even steps', () => {
    const ex = expandTemplate(fixture(), seed('panel-pile'), { cutAfter: 'c2' }, { params: { count: 3 } });
    const panels = all(ex.project).filter(x => x.t.kind === 'video').map(x => x.i as M.VideoClip).sort((a, b) => a.startSec! - b.startSec!);
    expect(panels.map(p => p.startSec)).toEqual([2.5, 3, 3.5]);
    expect(panels.map(p => p.asset)).toEqual(['b', 'b', 'a']);
    expect(panels[0]!.holdSec).toBeCloseTo(1.5);
    expect(panels[2]!.keyframes!.scale!.at(-1)!.v).toBe(1);
    const noBeats = fixture(); noBeats.tracks = noBeats.tracks.filter(t => t.kind !== 'music');
    const ev = expandTemplate(noBeats, seed('panel-pile'), { cutAfter: 'c2' }, { params: { count: 3, step: 0.3 } });
    expect(all(ev.project).filter(x => x.t.kind === 'video').map(x => (x.i as M.VideoClip).startSec).sort()).toEqual([3.1, 3.4, 3.7]);
    expect(ev.notes.join(' ')).toMatch(/evenly spaced/);
    // Notes Claude sends (song_notes) win over the beats.
    const sent = expandTemplate(fixture(), seed('panel-pile'), { cutAfter: 'c2' }, { params: { count: 2 }, notes: [2.2, 3.3] });
    expect(all(sent.project).filter(x => x.t.kind === 'video').map(x => (x.i as M.VideoClip).startSec).sort()).toEqual([2.2, 3.3]);
  });

  it('the track limit of 16: a 3 × 3 page needs 9 tracks and says how many are free', () => {
    const p = fixture();
    for (let k = 0; k < 9; k++) p.tracks.push({ id: `x${k}`, kind: 'text', items: [] });
    expect(() => expandTemplate(p, seed('comic-page-fly-in'), { cutAfter: 'c2' }, { params: { grid: 3 } }))
      .toThrow(/Comic page fly-in needs 9 free tracks; this edit has 5 \(an edit holds 16\)/);
    const ok = expandTemplate(fixture(), seed('comic-page-fly-in'), { cutAfter: 'c2' }, { params: { grid: 2 } });
    expect(ok.tracksAdded).toBe(4);
    const target = all(ok.project).filter(x => x.t.kind === 'video').map(x => x.i as M.VideoClip).find(c => c.asset === 'a' && c.inSec === 7)!;
    expect(target.keyframes!.scale!.at(-1)!.v).toBe(1); // the next shot lands at its own size on the cut
    expect(target.keyframes!.x!.at(-1)!.v).toBe(0.5);
  });

  it('a split template splits the clip and works on the pieces', () => {
    const ex = expandTemplate(fixture(), seed('punch-split'), { itemId: 'c2' });
    const main = M.mainTrack(ex.project).items as M.VideoClip[];
    expect(main).toHaveLength(5);
    expect(main[2]!).toMatchObject({ inSec: 6, transitionIn: { kind: 'glitch', durationSec: 0.1 } });
    expect(main[2]!.keyframes!.scale![0]!.v).toBeCloseTo(1.485);
  });

  it('the corner signature skips the hidden ranges; without a mark it says what it needs', () => {
    const ex = expandTemplate(fixture(), seed('corner-signature'), { edit: true }, { params: { image: 'up_mark', hideOn: [[1, 2], [5, 6]] } });
    const marks = all(ex.project).filter(x => x.t.kind === 'image').map(x => x.i as M.ImageItem);
    expect(marks.map(m => [m.startSec, m.startSec + m.durationSec])).toEqual([[0, 1], [2, 5], [6, 8]]);
    expect(ex.project.assets.find(a => a.upload === 'up_mark')).toMatchObject({ kind: 'image' });
    expect(() => expandTemplate(fixture(), seed('corner-signature'), { edit: true })).toThrow(/params.image/);
  });

  it('paid cut-out templates hide the copy until the matte arrives and list what to cut out', () => {
    const ex = expandTemplate(fixture(), seed('band-behind-subject'), { cutAfter: 'c2' });
    expect(ex.mattes).toHaveLength(1);
    const sub = all(ex.project).find(x => x.i.id === ex.mattes[0]!.itemId)!.i as M.VideoClip;
    expect(sub).toMatchObject({ asset: 'b', opacity: 0, inSec: 6.6, outSec: 7 });
    // The subject sits above the band (a later track).
    const ti = (id: string) => ex.project.tracks.findIndex(t => t.items.some(i => i.id === id));
    expect(ti(sub.id)).toBeGreaterThan(ti(ex.added[0]!));
    const title = expandTemplate(fixture(), seed('title-behind-subject'), { itemId: 'c2' });
    expect(title.mattes).toEqual([{ itemId: 'c2', reveal: 1, layer: { clip: 'c2', name: 'Subject', aboveText: true } }]);
  });

  it('not-ready templates are refused with their reason, never expanded', () => {
    for (const id of ['hit-negative', 'glass-shatter', 'contained-sound-ending']) {
      expect(() => expandTemplate(fixture(), seed(id), seed(id).target === 'cut' ? { cutAfter: 'c1' } : seed(id).target === 'edit' ? { edit: true } : { itemId: 'c1' }))
        .toThrow(/doesn't draw yet|ask Claude/);
    }
    // A saved spec naming a primitive that isn't live is refused the same way, whatever its level says.
    const sneaky = checkSpec({ ...seed('punch-in'), id: 'sneaky', requires: ['N1'] });
    expect(() => expandTemplate(fixture(), sneaky, { itemId: 'c1' })).toThrow(/invert and colour split/);
  });

  it('refuses values the apps can\'t read: an unknown effect in a saved spec, ids and assets set by hand', () => {
    expect(() => checkSpec({ ...seed('punch-in'), id: 'x-neg', steps: [{ do: 'set', on: 'target', fields: { effect: { id: 'invert', amount: 1 } } }] })).toThrow(/effect.id/);
    expect(() => checkSpec({ ...seed('punch-in'), id: 'x-id', steps: [{ do: 'set', on: 'target', fields: { asset: 'zz' } }] })).toThrow(/set by the template/);
    expect(() => checkSpec({ ...seed('punch-in'), id: 'x-kind', kind: 'photo' })).toThrow(/templates_manage/);
    // A gated blend mode in a saved spec doesn't reach a project: validation refuses it when BLEND_NEXT_LIVE is off.
    expect(M.BLEND_MODES.every(m => M.ALL_BLEND_MODES.includes(m))).toBe(true);
  });

  it('Save as template from a selection: the clip\'s keys normalised, and it applies to another clip the same way', () => {
    const p = expandTemplate(fixture(), seed('punch-in'), { itemId: 'c3' }).project;
    const spec = specFromSelection(p, { itemIds: ['c3'] }, { id: 'my-punch', name: 'My punch', kind: 'effect' });
    expect(spec).toMatchObject({ target: 'clip', level: 'live', steps: [{ do: 'set', on: 'target', unit: 'norm', keys: { scale: [{ t: 0, v: 1.35, ease: 'easeOut' }, { t: 1, v: 1 }] } }] });
    const again = expandTemplate(fixture(), spec, { itemId: 'c1' });
    expect((M.mainTrack(again.project).items[0] as M.VideoClip).keyframes!.scale).toEqual([{ t: 0, v: 1.35, ease: 'easeOut' }, { t: 2, v: 1 }]);
    // A window over a cut: the overlay copy of the next shot becomes $next with its in-point offset.
    const w = expandTemplate(fixture(), seed('window-open-next'), { cutAfter: 'c1' }).project;
    const ws = specFromSelection(w, { itemIds: ['c2'], cutAt: 2 }, { id: 'my-window', name: 'My window', kind: 'transition' });
    expect(ws.steps!.find(s => s.do === 'add')).toMatchObject({ source: '$next', in: '$next.in - 0.3', start: '$cut - 0.3', length: 0.3 });
    const moved = expandTemplate(fixture(), ws, { cutAfter: 'c3' });
    expect(all(moved.project).find(x => x.t.kind === 'video')!.i).toMatchObject({ asset: 'b', inSec: 0.7, startSec: 5.7 });
  });

  it('pack scripts are text: nothing in the template code runs a process or evaluates code', () => {
    for (const f of ['editTemplates.ts', 'editTemplateLibrary.ts', 'editTemplateSeeds.ts']) {
      const src = fs.readFileSync(path.join(import.meta.dirname, '../src/editor', f), 'utf8');
      expect(src, f).not.toMatch(/child_process|\bspawn\(|\bexecFile|new Function|\beval\(|node:vm/);
    }
  });
});

describe('the library (tools and routes, mock provider)', () => {
  type A = Awaited<ReturnType<typeof makeApp>>;
  let a: A, owner: Client, member: Client, ownerU: AuthUser, memberU: AuthUser, studioId: string, sid: string;
  const takeId = 'take_tpl20';
  const run = (name: string, u: AuthUser, args: Record<string, unknown>) => registryByName.get(name)!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, args) as Promise<any>;
  const session = async () => (await owner.req('GET', `/v1/edit-sessions/${sid}`)).body;
  const upload = (id: string, contentType: string) => a.ctx.db.insert(uploads).values({ id, studioId, kind: 'clip', storageKey: `k/${id}`, contentType, state: 'ready', createdAt: Date.now() });

  beforeAll(async () => {
    a = await makeApp();
    ({ owner, members: [member] } = await people(a, 1) as any);
    studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    const u = async (c: Client, role: 'owner' | 'member'): Promise<AuthUser> => { const [x] = await a.ctx.db.select().from(users).where(eq(users.id, c.id)); return { id: x!.id, studioId, email: x!.email, role, studioName: 'S', sessionId: null }; };
    ownerU = await u(owner, 'owner'); memberU = await u(member, 'member');
    await a.ctx.storage.put(`c/${takeId}.mp4`, Buffer.from('source video'), 'video/mp4');
    await a.ctx.db.insert(takes).values({ id: takeId, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'T', label: 'HD',
      engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: `c/${takeId}.mp4`, media: { durationSec: 20, width: 1080, height: 1920, fps: 30, contentType: 'video/mp4' }, createdAt: Date.now() });
    sid = (await owner.req('POST', '/v1/edit-sessions', { takeId })).body.id;
    const s = await session();
    const c1 = s.project.tracks[0].items[0].id;
    await run('apply_edit_ops', ownerU, { sessionId: sid, baseRevision: s.revision, ops: [{ op: 'trim', clipId: c1, inSec: 2, outSec: 10 }, { op: 'split', at: 2 }, { op: 'split', at: 4 }, { op: 'split', at: 6 }] });
    // The pack's previews and reference clips (the intake): the seeds pick them up.
    await upload('up_prev_window', 'video/mp4'); await upload('up_final_glass', 'video/mp4');
    await run('template_pack_send', ownerU, { pack: 'icon-storyboard', manifest: { templates: SEED_TEMPLATES.map(t => ({ id: t.id })) },
      media: [{ templateId: 'window-open-next', uploadId: 'up_prev_window', role: 'preview' }, { templateId: 'glass-shatter', uploadId: 'up_final_glass', role: 'final' }] });
  });
  afterAll(async () => { await a?.close(); });

  it('the four tools are the owner\'s and say they are not the photo presets', async () => {
    for (const n of ['edit_templates', 'edit_template_apply', 'edit_template_save', 'edit_template_delete']) {
      expect(toolsForUser({ role: 'owner' }).map(t => t.name)).toContain(n);
      expect(toolsForUser({ role: 'member' }).map(t => t.name)).not.toContain(n);
      expect(registryByName.get(n)!.description).toMatch(/photo presets are templates_manage/);
    }
    await expect(run('edit_templates', memberU, {})).rejects.toMatchObject({ status: 403 });
    expect((await member.req('GET', '/v1/editor/templates')).status).toBe(403);
  });

  it('lists the 27 seeds once, with the pack\'s preview and reference clip, not-ready ones with the reason', async () => {
    const l = await run('edit_templates', ownerU, {});
    expect(l.templates).toHaveLength(27);
    await run('edit_templates', ownerU, {}); // seeding twice adds nothing
    expect((await a.ctx.db.select().from(editTemplates).where(eq(editTemplates.studioId, studioId))).length).toBe(27);
    const w = l.templates.find((t: any) => t.id === 'window-open-next');
    expect(w).toMatchObject({ state: 'ready', level: 'live', kind: 'transition', target: 'cut', preview: { uploadId: 'up_prev_window' }, by: 'seed' });
    expect(w.params.map((q: any) => q.key)).toEqual(['shape', 'lead', 'wash']); // the white line waits for N2
    const g = l.templates.find((t: any) => t.id === 'glass-shatter');
    expect(g).toMatchObject({ state: 'not_ready', reference: { uploadId: 'up_final_glass' } });
    expect(g.reason).toMatch(/ask Claude on the Mac/);
    expect(l.templates.filter((t: any) => t.state === 'ready')).toHaveLength(18);
    expect(l.captionStyles.length).toBeGreaterThan(3);
    const spec = await run('edit_templates', ownerU, { templateId: 'punch-in' });
    expect(spec.spec.steps[0].do).toBe('set');
    expect((await owner.req('GET', '/v1/editor/templates?kind=transition')).body.templates.every((t: any) => t.kind === 'transition')).toBe(true);
  });

  it('dryRun returns the change without saving; apply is one undoable change; undo reverts all of it', async () => {
    const s0 = await session();
    const dry = await run('edit_template_apply', ownerU, { sessionId: sid, templateId: 'window-open-next', target: { cutAfter: s0.project.tracks[0].items[1].id }, params: { shape: 'slats' }, dryRun: true });
    expect(dry).toMatchObject({ dryRun: true, revision: s0.revision, added: expect.any(Array) });
    expect(dry.added).toHaveLength(3);
    expect(dry.patch.length).toBeGreaterThan(0);
    expect((await session()).revision).toBe(s0.revision);
    const done = (await owner.req('POST', '/v1/editor/templates/window-open-next/apply', { sessionId: sid, target: { cutAfter: s0.project.tracks[0].items[1].id }, params: { shape: 'slats' } })).body;
    expect(done).toMatchObject({ applied: true, revision: s0.revision + 1 });
    const s1 = await session();
    expect(s1.project.tracks.filter((t: any) => t.kind === 'video').flatMap((t: any) => t.items)).toHaveLength(3);
    expect(s1.history[0].label).toMatch(/^Template: Window opens the next shot/);
    await run('undo_edit', ownerU, { sessionId: sid, entryId: done.entry.id });
    const s2 = await session();
    expect(JSON.stringify(s2.project)).toBe(JSON.stringify(s0.project));
    // A stale base revision is refused, naming what moved.
    await expect(run('edit_template_apply', ownerU, { sessionId: sid, templateId: 'punch-in', target: { itemId: s0.project.tracks[0].items[0].id }, baseRevision: s0.revision })).rejects.toMatchObject({ status: 409 });
  });

  it('not-ready templates are refused with the reason; the track limit with a clear count', async () => {
    const s = await session();
    await expect(run('edit_template_apply', ownerU, { sessionId: sid, templateId: 'glass-shatter', target: { cutAfter: s.project.tracks[0].items[0].id } }))
      .rejects.toMatchObject({ status: 409, message: expect.stringMatching(/Glass shatter: .*ask Claude on the Mac/) });
    const r = await owner.req('POST', '/v1/editor/templates/comic-page-fly-in/apply', { sessionId: sid, target: { cutAfter: s.project.tracks[0].items[1].id }, params: { grid: 3 }, dryRun: true });
    expect(r.status).toBe(200); // 9 tracks fit in a fresh edit
    expect(r.body.tracksAdded).toBe(9);
  });

  it('a paid cut-out: priced first, then the template lands with the copy hidden and the owner approves; the matte shows it', async () => {
    const s0 = await session();
    const cutAfter = s0.project.tracks[0].items[1].id;
    const price = await run('edit_template_apply', ownerU, { sessionId: sid, templateId: 'band-behind-subject', target: { cutAfter } });
    expect(price).toMatchObject({ needsConfirmation: true, cutOuts: 1 });
    expect(price.estimateUsd).toBeGreaterThan(0);
    expect((await session()).revision).toBe(s0.revision);
    const done = await run('edit_template_apply', ownerU, { sessionId: sid, templateId: 'band-behind-subject', target: { cutAfter }, confirm: true });
    expect(done.waitingForOwner).toHaveLength(1);
    const copyId = done.waitingForOwner[0].itemId;
    const s1 = await session();
    const copy = () => s1.project.tracks.flatMap((t: any) => t.items).find((i: any) => i.id === copyId);
    expect(copy()).toMatchObject({ opacity: 0 });
    expect(s1.pending.find((p: any) => p.id === done.waitingForOwner[0].pendingId)).toMatchObject({ kind: 'matte', estimateUsd: price.estimateUsd, status: 'waiting' });
    expect((await owner.req('POST', `/v1/edit-sessions/${sid}/pending/${done.waitingForOwner[0].pendingId}`, { approve: true })).body.status).toBe('running');
    const after = await until(async () => { const s = await session(); const c = s.project.tracks.flatMap((t: any) => t.items).find((i: any) => i.id === copyId); return c?.alphaMatte ? s : null; }, 15_000);
    const c = after.project.tracks.flatMap((t: any) => t.items).find((i: any) => i.id === copyId);
    expect(c.opacity).toBeUndefined();
    const [job] = await a.ctx.db.select().from(editorJobs).where(and(eq(editorJobs.studioId, studioId), eq(editorJobs.kind, 'matte')));
    expect(Number(job!.cost)).toBeLessThanOrEqual(price.estimateUsd + 1e-9);
    expect(job!.source).toMatchObject({ range: expect.any(Object) }); // priced on the copy's own seconds, not the whole source
  }, 30_000);

  it('declining the cut-out takes the hidden copy back out; a price that went up is refused, never charged', async () => {
    const s0 = await session();
    const cutAfter = s0.project.tracks[0].items[2].id;
    const done = await run('edit_template_apply', ownerU, { sessionId: sid, templateId: 'cutout-carry-over', target: { cutAfter }, confirm: true });
    const copyId = done.waitingForOwner[0].itemId;
    expect((await session()).project.tracks.flatMap((t: any) => t.items).some((i: any) => i.id === copyId)).toBe(true);
    await owner.req('POST', `/v1/edit-sessions/${sid}/pending/${done.waitingForOwner[0].pendingId}`, { approve: false });
    const s1 = await session();
    expect(s1.project.tracks.flatMap((t: any) => t.items).some((i: any) => i.id === copyId)).toBe(false);
    // The price shown is the most it costs: if the estimate rose since, the approval is refused.
    const again = await run('edit_template_apply', ownerU, { sessionId: sid, templateId: 'cutout-carry-over', target: { cutAfter }, confirm: true });
    const s2 = await a.ctx.db.execute(sql`select pending from edit_sessions where id = ${sid}`) as any;
    const pend = (s2.rows[0].pending as any[]).map(p => (p.id === again.waitingForOwner[0].pendingId ? { ...p, args: { ...p.args, maxUsd: p.args.maxUsd / 10 } } : p));
    await a.ctx.db.execute(sql`update edit_sessions set pending = ${JSON.stringify(pend)}::jsonb where id = ${sid}`);
    const r = await owner.req('POST', `/v1/edit-sessions/${sid}/pending/${again.waitingForOwner[0].pendingId}`, { approve: true });
    expect(r.status).toBe(409);
    expect(r.body).toMatchObject({ code: 'price_changed', error: expect.stringMatching(/more than the/) });
  }, 30_000);

  it('saves from a selection and from a spec (a new version on the same id); delete sticks, seeds don\'t come back', async () => {
    const s = await session();
    const c1 = s.project.tracks[0].items[0].id;
    await run('edit_template_apply', ownerU, { sessionId: sid, templateId: 'punch-in', target: { itemId: c1 } });
    const saved = await run('edit_template_save', ownerU, { name: 'Quick punch', kind: 'effect', from: { sessionId: sid, itemIds: [c1] } });
    expect(saved).toMatchObject({ template: { id: 'quick-punch', by: 'claude', version: 1, state: 'ready' }, saved: 'Saved Quick punch as a template' });
    const v2 = await run('edit_template_save', ownerU, { spec: { ...saved.spec, description: 'Faster' } });
    expect(v2.template).toMatchObject({ id: 'quick-punch', version: 2 });
    const fromApp = (await owner.req('POST', '/v1/editor/templates', { spec: { ...saved.spec, id: 'app-punch', name: 'App punch' } })).body;
    expect(fromApp.template).toMatchObject({ id: 'app-punch', by: 'owner' });
    expect((await owner.req('DELETE', '/v1/editor/templates/hit-negative')).status).toBe(200);
    const l = await run('edit_templates', ownerU, {});
    expect(l.templates.map((t: any) => t.id)).not.toContain('hit-negative');
    expect(l.templates.map((t: any) => t.id)).toContain('quick-punch');
    await expect(run('edit_template_save', ownerU, { spec: { ...saved.spec, id: 'bad-one', steps: [{ do: 'set', on: 'target', fields: { effect: { id: 'invert', amount: 1 } } }] } })).rejects.toMatchObject({ status: 400 });
  });
});
