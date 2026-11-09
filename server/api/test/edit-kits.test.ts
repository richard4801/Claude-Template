// WS8 · edit style kits (plans/edit-parity.md, M): the shared kit functions and /v1/editor/kits (members their own, the
// owner the studio's). No providers involved.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as M from '../src/editor/model.js';
import { applyKit, kitOf, validateKit, type StyleKit } from '../src/editor/kit.js';
import { CAPTION_STYLES, FILTERS, HOOKS } from '../src/editor/presets.js';
import { makeApp, people, type Client } from './helpers.js';

const project = (): M.EditProject => ({
  version: 2, sourceTakeId: 'take_1', canvas: { width: 1080, height: 1920, fps: 30, background: '#101010' },
  assets: [{ id: 'src', kind: 'video', take: 'take_1', durationSec: 15, width: 1080, height: 1920, hasAudio: true }, { id: 'cube', kind: 'lut', upload: 'up_1' }],
  tracks: [
    { id: 'main', kind: 'main', items: [
      { id: 'c1', asset: 'src', inSec: 0, outSec: 5, speed: 1, look: { lut: 'cube', strength: 0.7, vignette: { amount: 0.3 } }, adjust: { exposure: 0.2 }, keyframes: { exposure: [{ t: 0, v: 0 }, { t: 2, v: 0.4 }] } },
      { id: 'c2', asset: 'src', inSec: 5, outSec: 5.15, speed: 1 },
      { id: 'c3', asset: 'src', inSec: 6, outSec: 10, speed: 1, transitionIn: { kind: 'zoom', durationSec: 0.05 } },
    ] },
    { id: 'txt', kind: 'text', items: [{ id: 't1', startSec: 0, durationSec: 2, text: 'Hi', style: HOOKS[1]!.style }] },
    { id: 'cap', kind: 'caption', items: [], caption: { asset: 'src', words: [{ text: 'hi', startSec: 0, endSec: 0.4 }], style: CAPTION_STYLES.box } },
  ],
} as unknown as M.EditProject);

describe('style kits · shared functions', () => {
  it('kitOf takes the edit\'s style; an uploaded cube stays behind', () => {
    const k = kitOf(project());
    expect(k).toEqual({ version: 1, look: { vignette: { amount: 0.3 } }, adjust: { exposure: 0.2 }, transition: { kind: 'zoom', durationSec: 0.05 },
      captionStyle: CAPTION_STYLES.box, textStyle: HOOKS[1]!.style, background: '#101010' });
    expect(kitOf({ ...project(), tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c', asset: 'src', inSec: 0, outSec: 2, speed: 1 }] }] } as M.EditProject)).toEqual({ version: 1, background: '#101010' });
  });
  it('applyKit styles every clip, cut, caption and text; short cuts stay cuts; keyframes and words stay', () => {
    const kit: StyleKit = { version: 1, look: { lut: 'pack:film-gold', strength: 0.6 }, filter: { id: 'warm', amount: 0.5 }, adjust: { contrast: 0.1 },
      transition: { kind: 'fade', durationSec: 0.8 }, captionStyle: CAPTION_STYLES.neon, textStyle: HOOKS[3]!.style, fill: 'blur' };
    const q = applyKit(project(), kit);
    const main = M.mainTrack(q).items as M.VideoClip[];
    expect(main.every(c => c.look?.lut === 'pack:film-gold' && c.filter?.id === 'warm' && c.adjust?.contrast === 0.1)).toBe(true);
    expect(main[0]!.keyframes?.exposure?.length).toBe(2);
    expect(main[1]!.transitionIn).toBeUndefined(); // 0.15 s clip: half is under 0.1 s
    expect(main[2]!.transitionIn).toEqual({ kind: 'zoom', durationSec: 0.05 }); // its neighbour is too short for a fade: as it was
    expect((q.tracks[2]!.caption!).style).toEqual(CAPTION_STYLES.neon);
    expect((q.tracks[2]!.caption!).words).toEqual([{ text: 'hi', startSec: 0, endSec: 0.4 }]);
    expect((q.tracks[1]!.items[0] as M.TextItem).text).toBe('Hi');
    expect(q.canvas).toMatchObject({ background: '#101010', fill: 'blur' });
    // A longer edit gets the transition, at most half of each clip.
    const long = applyKit({ ...project(), tracks: [{ id: 'main', kind: 'main', items: [{ id: 'a', asset: 'src', inSec: 0, outSec: 1, speed: 1 }, { id: 'b', asset: 'src', inSec: 1, outSec: 6, speed: 1 }] }] } as M.EditProject, kit);
    expect((M.mainTrack(long).items[1] as M.VideoClip).transitionIn).toEqual({ kind: 'fade', durationSec: 0.5 });
  });
  it('validateKit: known keys, version 1, the edit rules, and portable looks only', () => {
    expect(validateKit({ version: 1 })).toEqual({ version: 1 });
    const bad = (k: unknown) => { try { validateKit(k, FILTERS); return 'ok'; } catch (e) { return (e as M.EditProblem).field; } };
    expect(bad(null)).toBe('kit');
    expect(bad({ version: 2 })).toBe('kit.version');
    expect(bad({ version: 1, mask: {} })).toBe('kit.mask');
    expect(bad({ version: 1, adjust: { tint: 2 } })).toBe('kit.adjust.tint');
    expect(bad({ version: 1, transition: { kind: 'fade', durationSec: 5 } })).toBe('kit.transition.durationSec');
    expect(bad({ version: 1, look: { lut: 'cube' } })).toBe('kit.look.lut');
    expect(bad({ version: 1, captionStyle: { ...CAPTION_STYLES.pop, highlightColor: 'yellow' } })).toBe('kit.captionStyle.highlightColor');
    expect(bad({ version: 1, textStyle: { ...HOOKS[0]!.style, sizePct: 9 } })).toBe('kit.textStyle.sizePct');
    expect(bad({ version: 1, fill: 'mirror' })).toBe('kit.fill');
    expect(bad({ version: 1, filter: { id: 'nope', amount: 1 } })).toBe('kit.filter.id');
  });
});

describe('style kits · /v1/editor/kits', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, other: Client;
  beforeAll(async () => {
    a = await makeApp();
    ({ owner, members: [member, other] } = await people(a, 2) as any);
  });
  afterAll(async () => { await a?.close?.(); });

  it('saves, lists (own for members, all for the owner), renames, replaces and deletes', async () => {
    const kit = { ...kitOf(project()), transition: { kind: 'zoom', durationSec: 0.3 } }; // (the sample's 0.05 s cut is below 0.1 s)
    const r = await member.req('POST', '/v1/editor/kits', { name: '  Warm vlog ', kit });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ name: 'Warm vlog', kit, createdBy: member.id });
    const id = r.body.id as string;
    await other.req('POST', '/v1/editor/kits', { name: 'Theirs', kit: { version: 1, fill: 'blur' } });
    expect((await member.req('GET', '/v1/editor/kits')).body.kits.map((k: any) => k.name)).toEqual(['Warm vlog']);
    expect((await owner.req('GET', '/v1/editor/kits')).body.kits.map((k: any) => k.name).sort()).toEqual(['Theirs', 'Warm vlog']);
    // Another member can't see, change or delete it; the owner can.
    expect((await other.req('PATCH', `/v1/editor/kits/${id}`, { name: 'Mine now' })).status).toBe(404);
    expect((await other.req('DELETE', `/v1/editor/kits/${id}`)).status).toBe(404);
    const ren = await owner.req('PATCH', `/v1/editor/kits/${id}`, { name: 'Warm vlog 2', kit: { version: 1, adjust: { saturation: 0.2 } } });
    expect(ren.status).toBe(200);
    expect(ren.body).toMatchObject({ name: 'Warm vlog 2', kit: { version: 1, adjust: { saturation: 0.2 } } });
    expect((await member.req('DELETE', `/v1/editor/kits/${id}`)).status).toBe(204);
    expect((await member.req('GET', '/v1/editor/kits')).body.kits).toEqual([]);
  });

  it('refuses a bad kit or name with the field', async () => {
    const r = await member.req('POST', '/v1/editor/kits', { name: 'X', kit: { version: 1, adjust: { exposure: 3 } } });
    expect(r.status).toBe(400);
    expect(JSON.stringify(r.body)).toContain('kit.adjust.exposure');
    expect((await member.req('POST', '/v1/editor/kits', { name: '', kit: { version: 1 } })).status).toBe(400);
    expect((await member.req('POST', '/v1/editor/kits', { name: 'X', kit: { version: 1 }, extra: 1 })).status).toBe(400);
    expect((await member.req('PATCH', '/v1/editor/kits/kit_nope', { name: 'Y' })).status).toBe(404);
  });

  it('needs a signed-in user', async () => {
    const r = await a.app.inject({ method: 'GET', url: '/v1/editor/kits' });
    expect(r.statusCode).toBe(401);
  });
});
