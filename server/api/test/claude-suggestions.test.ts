// Live suggestion chips (claude/suggest.ts): the chips over Claude's input follow the screen and what just happened.
// Rules per page and state, the tools each chip leads to, stable order, members never offered owner-only tools.
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { editFacts, outsideSafe, suggest, suiteFacts, type Facts } from '../src/claude/suggest.js';
import { CHAT_REGISTRY, registryByName } from '../src/claude/registry.js';
import { editSessions } from '../src/editor/schema.js';
import * as M from '../src/editor/model.js';
import { makeApp, people, type Client } from './helpers.js';

const all = () => true;
const memberCan = (t: string) => !!registryByName.get(t)?.members;
const labels = (f: Partial<Facts>) => suggest({ can: all, ...f } as Facts).map(c => c.label);

/** A small edit: one main clip, optional music (with or without marked beats), optional captions, optional text. */
function project(o: { captions?: boolean; music?: boolean; beats?: boolean; textAt?: [number, number]; blank?: boolean } = {}): M.EditProject {
  const tracks: M.Track[] = [{ id: 'tr_main', kind: 'main', items: o.blank ? [] : [{ id: 'clip_1', asset: 'a_v', inSec: 0, outSec: 8, speed: 1 } as M.VideoClip] }];
  if (o.music) tracks.push({ id: 'tr_music', kind: 'music', items: [{ id: 'mus_1', asset: 'a_m', startSec: 0, inSec: 0, outSec: 8, ...(o.beats ? { strongBeats: [1, 2] } : {}) } as M.AudioClip] });
  if (o.textAt) tracks.push({ id: 'tr_text', kind: 'text', items: [{ id: 'txt_1', startSec: 0, durationSec: 2, text: 'Hi', transform: { x: o.textAt[0], y: o.textAt[1] },
    style: { font: 'sans', weight: 700, sizePct: 0.05, color: '#fff', align: 'center' } } as M.TextItem] });
  if (o.captions) tracks.push({ id: 'tr_cap', kind: 'caption', items: [], caption: { asset: 'a_v', words: [{ text: 'hello', startSec: 0, endSec: 0.5 }],
    style: { font: 'sans', weight: 700, sizePct: 0.05, color: '#fff', align: 'center', preset: 'plain', highlightColor: '#ff0' } } });
  return { version: 2, sourceTakeId: o.blank ? 'blank' : 'take_1', canvas: { width: 1080, height: 1920, fps: 30 }, assets: [], tracks };
}
const edit = (o: Parameters<typeof project>[0] = {}) => editFacts('es_1', project(o));

describe('live chips: rules (unit)', () => {
  it('every chip has at most 4 words, a verb first, and leads to tools Claude really has', () => {
    const names = new Set(CHAT_REGISTRY.map(t => t.name));
    const states: Partial<Facts>[] = [
      { page: 'edit', edit: edit(), app: { selKind: 'video', selId: 'clip_1', unsaved: true, overlap: true, imported: 'video', view: 'tiktok' } },
      { page: 'edit', edit: edit({ music: true, captions: true, textAt: [0.5, 0.95] }), app: { selKind: 'text', selId: 'txt_1', view: 'tiktok', imported: 'audio' } },
      { page: 'edit', edit: edit({ music: true, beats: true }), app: { selKind: 'audio', selId: 'mus_1' } },
      { page: 'edit', edit: edit({ blank: true }) },
      { page: 'suite', tool: 'shot', suite: { promptEmpty: false, hasCharacter: true, rigSet: true, hasClip: false, hasOutfit: false } },
      { page: 'suite', tool: 'swap', suite: { promptEmpty: true, hasCharacter: false, rigSet: false, hasClip: false, hasOutfit: false } },
      { page: 'queue', job: { id: 'j1', title: 'Beach', state: 'failed', agoSec: 10, video: true, editor: false } },
      { page: 'home', job: { id: 'j1', title: 'Beach', state: 'done', agoSec: 10, video: true, editor: false }, reply: 'Want me to cut it?' },
    ];
    for (const s of states) for (const c of suggest({ can: all, ...s } as Facts, 30)) {
      expect(c.label.split(/\s+/).length, c.label).toBeLessThanOrEqual(4);
      for (const t of c.tools) expect(names.has(t), `${c.id} → ${t}`).toBe(true);
      expect(c.prompt.length).toBeGreaterThan(5);
    }
  });

  it('Edit: no captions → Add captions; with captions → Restyle the captions instead', () => {
    expect(labels({ page: 'edit', edit: edit() })).toContain('Add captions');
    const withCaps = labels({ page: 'edit', edit: edit({ captions: true }) });
    expect(withCaps).not.toContain('Add captions');
    expect(withCaps).toContain('Restyle the captions');
  });

  it('Edit: music without beats → Cut to the beat; beats marked → Cut to the drop', () => {
    expect(labels({ page: 'edit', edit: edit({ music: true }) })).toContain('Cut to the beat');
    const drop = labels({ page: 'edit', edit: edit({ music: true, beats: true }) });
    expect(drop).toContain('Cut to the drop');
    expect(drop).not.toContain('Cut to the beat');
  });

  it('Edit: a clip just imported, the selection, overlaps and unsaved changes', () => {
    expect(labels({ page: 'edit', edit: edit(), app: { imported: 'video', importedId: 'up_1' } })[0]).toBe('Watch the new clip');
    expect(labels({ page: 'edit', edit: edit(), app: { selKind: 'video', selId: 'clip_1' } })).toContain('Trim this clip');
    expect(labels({ page: 'edit', edit: edit({ music: true }), app: { selKind: 'audio', selId: 'mus_1' } })).toContain('Find the beats');
    expect(labels({ page: 'edit', edit: edit(), app: { overlap: true } })).toContain('Fix the overlap');
    expect(labels({ page: 'edit', edit: edit({ captions: true }), app: { unsaved: true } })).toContain('Save a version');
  });

  it('Edit: text outside the platform\'s safe area (TikTok view) → Fix the safe area; inside or no view → not', () => {
    expect(outsideSafe(edit({ textAt: [0.5, 0.95] }).texts, 'tiktok')).toEqual(['txt_1']);
    expect(outsideSafe(edit({ textAt: [0.5, 0.5] }).texts, 'tiktok')).toEqual([]);
    const c = suggest({ can: all, page: 'edit', edit: edit({ textAt: [0.5, 0.95] }), app: { view: 'tiktok' } });
    expect(c[0]!.label).toBe('Fix the safe area');
    expect(c[0]!.prompt).toMatch(/TikTok.*txt_1/);
    expect(labels({ page: 'edit', edit: edit({ textAt: [0.5, 0.95] }) })).not.toContain('Fix the safe area');
  });

  it('Edit: an empty blank project offers takes, never captions or cuts on nothing', () => {
    const l = labels({ page: 'edit', edit: edit({ blank: true }) });
    expect(l).toContain('Find takes to use');
    expect(l).not.toContain('Add captions');
    expect(l).not.toContain('Cut the silences');
  });

  it('a member on Edit never gets an edit-tool chip (editing with Claude is the owner\'s)', () => {
    const c = suggest({ can: memberCan, page: 'edit', edit: edit({ music: true }), app: { selKind: 'video', selId: 'clip_1' } });
    for (const x of c) for (const t of (x as any).tools ?? []) expect(memberCan(t), `${x.label} → ${t}`).toBe(true);
    expect(c.map(x => x.label)).not.toContain('Cut to the beat');
  });

  it('Shot composer: empty → Write the prompt; idea without rig → Build from my idea; rig set → Make it more cinematic', () => {
    const base = { promptEmpty: true, hasCharacter: false, rigSet: false, hasClip: false, hasOutfit: false };
    expect(labels({ page: 'suite', tool: 'shot', suite: base })).toContain('Write the prompt');
    const idea = labels({ page: 'suite', tool: 'shot', suite: { ...base, promptEmpty: false, hasCharacter: true } });
    expect(idea[0]).toBe('Build from my idea');
    expect(idea).toContain('Check the price');
    expect(labels({ page: 'suite', tool: 'shot', suite: { ...base, promptEmpty: false, hasCharacter: true, rigSet: true } })).toContain('Make it more cinematic');
    expect(labels({ page: 'suite', tool: 'swap', suite: { ...base, hasClip: true } })).toContain('Watch my clip');
    expect(labels({ page: 'suite', tool: 'swap', suite: base })).toContain('Find a clip');
  });

  it('the last job: failed → Why did it fail? first (+ Run it again for video); done → Watch the new take; old ones are ignored', () => {
    const failed = { id: 'job_1', title: 'Beach walk', state: 'failed' as const, agoSec: 30, video: true, editor: false };
    const l = labels({ page: 'home', job: failed });
    expect(l[0]).toBe('Why did it fail?');
    expect(l).toContain('Run it again');
    expect(labels({ page: 'edit', edit: edit(), job: { ...failed, video: false, editor: true } })).not.toContain('Run it again');
    expect(labels({ page: 'home', job: { ...failed, state: 'done' } })[0]).toBe('Watch the new take');
    expect(labels({ page: 'home', job: { ...failed, agoSec: 3600 } })).not.toContain('Why did it fail?');
  });

  it('follow-ups from Claude\'s last reply: a question → Yes, go ahead; numbered options → Go with option 1', () => {
    expect(labels({ page: 'home', reply: 'I found three silences. Shall I cut them?' })).toContain('Yes, go ahead');
    expect(labels({ page: 'home', reply: 'Two ways:\n1. Fast cuts\n2. Slow fades' })).toContain('Go with option 1');
    expect(labels({ page: 'home', reply: 'Done. Captions are on.' })).not.toContain('Yes, go ahead');
  });

  it('always three; the order is the catalog\'s, so a chip that stays keeps its place', () => {
    for (const page of ['home', 'edit', 'suite', 'take', 'queue', 'library'] as const) expect(suggest({ can: all, page }).length).toBe(3);
    const a = suggest({ can: all, page: 'edit', edit: edit({ music: true }) }).map(c => c.id);
    const b = suggest({ can: all, page: 'edit', edit: edit({ music: true }), app: { imported: 'video' } }).map(c => c.id);
    expect(b[0]).toBe('edit.watchNew');
    // The chips both sets share appear in the same relative order.
    const shared = a.filter(x => b.includes(x));
    expect(b.filter(x => shared.includes(x))).toEqual(shared);
    // Same facts, same chips (deterministic).
    expect(suggest({ can: all, page: 'edit', edit: edit({ music: true }) }).map(c => c.id)).toEqual(a);
  });

  it('the Suite draft\'s facts: prompt words, @character, rig, the screen\'s clip', () => {
    expect(suiteFacts({ tool: 'shot', tokens: [{ t: 'mention', kind: 'model', id: 'm1' }, { t: 'text', text: 'She walks' }], rig: { lighting: 'golden' } }))
      .toMatchObject({ promptEmpty: false, hasCharacter: true, rigSet: true, hasClip: false });
    expect(suiteFacts({ tool: 'swap', screen: { inputs: [{ kind: 'video' }] } })).toMatchObject({ promptEmpty: true, hasClip: true, hasCharacter: false });
  });
});

describe('live chips: GET /v1/claude/suggestions', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [member] } = await people(a, 1) as any);
  });
  afterAll(async () => { await a?.close(); });

  it('reads the open edit: different chips with and without captions; members get no edit chips', async () => {
    const s = (await owner.req('POST', '/v1/edit-sessions', { takeId: 'blank' })).body;
    expect(s.id).toBeTruthy();
    const get = async (c: Client, q: string) => (await c.req('GET', `/v1/claude/suggestions?page=edit&sessionId=${s.id}${q}`));
    const empty = await get(owner, '');
    expect(empty.status, JSON.stringify(empty.body)).toBe(200);
    expect(empty.body.chips.map((c: any) => c.label)).toContain('Find takes to use');
    await a.ctx.db.update(editSessions).set({ project: project({ music: true }) as unknown as Record<string, unknown> }).where(eq(editSessions.id, s.id));
    const noCaps = (await get(owner, '')).body;
    expect(noCaps.chips.map((c: any) => c.label)).toEqual(expect.arrayContaining(['Add captions', 'Cut to the beat']));
    expect(noCaps.key).toBe(noCaps.chips.map((c: any) => c.id).join('|'));
    await a.ctx.db.update(editSessions).set({ project: project({ music: true, captions: true }) as unknown as Record<string, unknown> }).where(eq(editSessions.id, s.id));
    const caps = (await get(owner, '&selKind=video&selId=clip_1')).body.chips.map((c: any) => c.label);
    expect(caps).not.toContain('Add captions');
    expect(caps).toContain('Trim this clip');
    const m = (await get(member, '')).body.chips.map((c: any) => c.label);
    expect(m).not.toContain('Add captions');
    expect(m).toHaveLength(3);
  });

  it('the Suite draft and Claude\'s last reply; bad input is refused', async () => {
    const assistId = (await owner.req('POST', '/v1/suite/assist', {})).body.id;
    const r = (await owner.req('GET', `/v1/claude/suggestions?page=suite&tool=shot&assistId=${assistId}`)).body.chips.map((c: any) => c.label);
    expect(r).toContain('Write the prompt');
    expect((await owner.req('GET', '/v1/claude/suggestions?page=nowhere')).status).toBe(400);
    expect((await owner.req('GET', '/v1/claude/suggestions?page=edit&view=myspace')).status).toBe(400);
    // Someone else's draft reads as nothing (no leak), still three chips.
    expect((await member.req('GET', `/v1/claude/suggestions?page=suite&tool=shot&assistId=${assistId}`)).body.chips).toHaveLength(3);
  });
});

describe('live chips: the page fillers', () => {
  it('every fixed page chip names tools Claude has (FILL_TOOLS covers chipsFor)', async () => {
    const { FILL_TOOLS } = await import('../src/claude/suggest.js');
    const { chipsFor } = await import('../src/claude/cards.js');
    const { PAGES } = await import('../src/claude/page.js');
    const names = new Set(CHAT_REGISTRY.map(t => t.name));
    for (const p of [...PAGES, undefined]) for (const tool of [undefined, 'swap', 'photo']) for (const c of chipsFor(p, tool)) {
      expect(FILL_TOOLS[c.label], c.label).toBeDefined();
      for (const t of FILL_TOOLS[c.label]!) expect(names.has(t), `${c.label} → ${t}`).toBe(true);
    }
  });
});

describe('live chips: icons', () => {
  it('every chip icon is in both apps\' Phosphor sets (Mac asset catalog, Android PhosphorIcons.kt)', async () => {
    const fs = await import('node:fs'), path = await import('node:path');
    const src = fs.readFileSync(path.join(__dirname, '../src/claude/suggest.ts'), 'utf8');
    const icons = [...new Set([...src.matchAll(/icon: '([a-z-]+)'/g)].map(m => m[1]!))];
    const mac = path.join(__dirname, '../../../mac/Muse/Resources/Phosphor.xcassets');
    const kt = path.join(__dirname, '../../../android/app/src/main/kotlin/studio/muse/app/ui/theme/PhosphorIcons.kt');
    if (!fs.existsSync(mac) || !fs.existsSync(kt)) return; // the server alone (deploy image): nothing to check against
    const android = fs.readFileSync(kt, 'utf8');
    for (const i of icons) {
      expect(fs.existsSync(path.join(mac, `ph.${i}.imageset`)), `Mac: ${i}`).toBe(true);
      expect(android.includes(`"${i}" to`), `Android: ${i}`).toBe(true);
    }
  });
});

describe('live chips: the app\'s own view of the edit', () => {
  it('app facts win over the server\'s copy and work without a shared session (a member\'s edit)', async () => {
    const { withAppEdit, SuggestQuery } = await import('../src/claude/suggest.js');
    const q = (o: Record<string, string>) => SuggestQuery.parse({ page: 'edit', ...o });
    const alone = withAppEdit(undefined, q({ clips: '1', captions: '0', musicId: 'mus_9' }))!;
    expect(alone).toMatchObject({ mainClips: 1, hasCaptions: false, musicId: 'mus_9', beatsMarked: false });
    expect(suggest({ can: all, page: 'edit', edit: alone }).map(c => c.label)).toEqual(expect.arrayContaining(['Add captions', 'Cut to the beat']));
    const over = withAppEdit(edit({ music: true }), q({ captions: '1', beats: '1' }))!;
    expect(over).toMatchObject({ hasCaptions: true, beatsMarked: true, musicId: 'mus_1' });
    expect(withAppEdit(edit(), q({}))).toEqual(edit());
    // The app's safe-area ids are used as they are.
    const c = suggest({ can: all, page: 'edit', edit: edit(), app: { view: 'reels', offSafe: ['txt_7'] } });
    expect(c[0]!.prompt).toMatch(/Reels.*txt_7/);
    expect(() => q({ offSafe: 'a,b;drop' })).toThrow();
  });

  it('over HTTP: the Mac\'s query (no captions vs captions) gives different chips', async () => {
    const a = await makeApp();
    try {
      const { owner } = await people(a, 0);
      const get = async (q: string) => (await owner.req('GET', `/v1/claude/suggestions?page=edit&clips=1&musicId=mus_1${q}`)).body.chips.map((c: any) => c.label);
      const no = await get('&captions=0'), yes = await get('&captions=1&beats=1');
      expect(no).toContain('Add captions');
      expect(yes).not.toContain('Add captions');
      expect(yes).toContain('Cut to the drop');
      expect(no).not.toEqual(yes);
    } finally { await a.close(); }
  }, 60_000);   // its own app: slow under the full suite's load
});

describe('live chips: never impossible', () => {
  it('an edit without music never gets "Cut to the beat"; with captions never "Add captions" (fillers included)', () => {
    for (const o of [{}, { captions: true }, { textAt: [0.5, 0.5] as [number, number] }]) {
      const l = labels({ page: 'edit', edit: edit(o) });
      expect(l).not.toContain('Cut to the beat');
      expect(l).toHaveLength(3);
    }
    expect(labels({ page: 'edit', edit: edit({ captions: true }) })).not.toContain('Add captions');
    expect(labels({ page: 'suite', tool: 'swap', suite: { promptEmpty: true, hasCharacter: true, rigSet: false, hasClip: false, hasOutfit: false } })).not.toContain('Watch my clip');
  });
});

describe('live chips: every preview skin (Mac EditPreview, bundle-10)', () => {
  it('Facebook and YouTube views are accepted; YouTube has no box; Clean is no view', async () => {
    expect(outsideSafe(edit({ textAt: [0.5, 0.95] }).texts, 'facebook')).toEqual(['txt_1']);
    expect(outsideSafe(edit({ textAt: [0.5, 0.95] }).texts, 'youtube')).toEqual([]);
    // The app's own ids still drive the chip on a view the server has no box for.
    const c = suggest({ can: all, page: 'edit', edit: edit(), app: { view: 'youtube', offSafe: ['txt_2'] } });
    expect(c[0]!.prompt).toMatch(/YouTube view.*txt_2/);
    const a = await makeApp();
    try {
      const { owner } = await people(a, 0);
      for (const v of ['tiktok', 'reels', 'shorts', 'facebook', 'youtube', 'clean', 'off']) {
        const r = await owner.req('GET', `/v1/claude/suggestions?page=edit&clips=1&captions=1&view=${v}&offSafe=txt_1`);
        expect(r.status, v).toBe(200);
        const labels = r.body.chips.map((x: any) => x.label);
        if (v === 'clean' || v === 'off') expect(labels, v).not.toContain('Fix the safe area');
        else expect(labels[0], v).toBe('Fix the safe area');
      }
    } finally { await a.close(); }
  }, 60_000);
});
