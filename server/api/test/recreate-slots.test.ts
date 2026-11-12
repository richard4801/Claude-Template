// Recreate this edit, phase 3 (workstream 1): shot briefs, the slot matcher, filling a slot with a Suite shot (price
// first; the owner approves) and building the edit from the recipe. Mock video provider, no money.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { jobs, takes, users } from '../src/db/schema.js';
import * as M from '../src/editor/model.js';
import { FILTERS } from '../src/editor/presets.js';
import { LOOK_IDS } from '../src/editor/lookpack.js';
import { paletteIds } from '../src/editor/photo.js';
import { editSessionsOf } from '../src/editor/sessions.js';
import type { Recipe } from '../src/recreate/analyze.js';
import { lutFor } from '../src/suite/looks.js';
import { buildProject, editorTransition, freezeCurve, peakInPoint } from '../src/recreate/assemble.js';
import { speedOf } from '../src/recreate/signals.js';
import { RECREATE_TOOLS } from '../src/recreate/mcpTools.js';
import { BriefSchema, matchSlots, promptSource, scoreTake, shotRequestFor, swapDirection, swapSegment, withBriefs, type Candidate } from '../src/recreate/slots.js';
import { putObject } from '../src/storage/objects.js';
import { matchLocation, plateSize, platePrompt, recreateOf } from '../src/recreate/references.js';
import { makeApp, people, until, type Client } from './helpers.js';
import { hasFfmpeg, makeReference } from './recreate-fixture.js';

const cam = (motion: any, keys = [{ t: 0, x: 0, y: 0, scale: 1 }]) => ({ motion, shake: 0, keys, confidence: 0.6 });
const speed = { ramp: 'none' as const, curve: [{ t: 0, speed: 1 }], confidence: 0.5 };
const RECIPE: Recipe = {
  schema: 'muse.recipe/1', analyzer: { version: 'test', tookMs: 0 }, origin: 'reference',
  source: { durationSec: 4.4, width: 1080, height: 1920, fps: 30, aspect: '9:16', hasAudio: true },
  sound: null, pacing: { shots: 3, avgShotSec: 1.47, cutsPerMin: 27, energy: { everySec: 0.5, values: [0] } },
  slots: [
    { id: 's1', index: 0, startSec: 0, endSec: 1.5, durationSec: 1.5, keyframeSec: 0.75, confidence: 0.9, brief: null, rig: { moves: [{ id: 'pan_right' }] },
      camera: cam('pan', [{ t: 0, x: 0, y: 0, scale: 1 }, { t: 0.75, x: -0.3, y: 0, scale: 1 }, { t: 1.467, x: -0.6, y: 0, scale: 1 }]), speed, peaks: [], pose: { status: 'pending' } },
    { id: 's2', index: 1, startSec: 1.5, endSec: 2.65, durationSec: 1.15, keyframeSec: 2.07, confidence: 0.9, brief: null, rig: { moves: [{ id: 'zoom_in' }] },
      camera: cam('zoom_in', [{ t: 0, x: 0, y: 0, scale: 1 }, { t: 1, x: 0, y: 0, scale: 1.1 }]),
      speed: { ramp: 'speed_up', curve: [{ t: 0, speed: 0.5 }, { t: 0.5, speed: 1 }, { t: 1, speed: 2 }], confidence: 0.55 }, peaks: [{ t: 0.4, strength: 1 }], pose: { status: 'pending' } },
    { id: 's3', index: 2, startSec: 2.65, endSec: 4.4, durationSec: 1.75, keyframeSec: 3.5, confidence: 0.9, brief: null, rig: { moves: [{ id: 'static' }] },
      camera: cam('static'), speed, peaks: [], pose: { status: 'pending' } },
  ],
  transitions: [
    { atSec: 1.5, kind: 'cut', durationSec: 0, confidence: 0.9, from: 's1', to: 's2' },
    { atSec: 2.65, kind: 'crossfade', durationSec: 0.5, confidence: 0.7, from: 's2', to: 's3' },
    { atSec: 3.733, kind: 'flash', durationSec: 0.067, confidence: 0.8, from: 's3', to: 's3' },
  ],
  text: [{ id: 'x1', startSec: 3.1, endSec: 4.1, box: { x: 0.125, y: 0.7, w: 0.75, h: 0.07 }, words: null, sizeFrac: 0.042, color: '#FFFFFF', fontId: 'sans', animIn: 'cut', animOut: 'cut', confidence: 0.45 }],
  grade: { swatches: ['#101010', '#404040', '#808080', '#C0C0C0', '#F0F0F0'], contrast: 0.5, saturation: 0.1, warmth: 0, look: { id: 'golden_warmth', kind: 'palette', label: 'Golden warmth', distance: 0.2 }, grade: null, confidence: 0.8 },
  contactSheet: null, gaps: [],
};
const TAKE = (id: string, durationSec = 3) => ({ id, durationSec, width: 720, height: 1280 });

describe('Recreate · assembly (unit)', () => {
  it('cuts land on the reference: each clip carries half of each neighbouring transition; the edit validates', () => {
    const out = buildProject(RECIPE, 'take_src', { s1: TAKE('tA'), s2: TAKE('tB'), s3: TAKE('tC') });
    const p = out.project;
    expect(() => M.validate(p, FILTERS, LOOK_IDS, paletteIds())).not.toThrow();
    expect(p.canvas).toEqual({ width: 1080, height: 1920, fps: 30, background: '#000000' });
    expect(p.assets.map(a => a.take)).toEqual(['tA', 'tB', 'tC']);
    const tl = M.timeline(p);
    expect(tl.map(x => x.startSec)).toEqual([0, 1.5, expect.closeTo(2.4, 4)]); // s3's crossfade starts 0.25 s before the 2.65 s boundary
    expect(out.durationSec).toBeCloseTo(4.4, 3);
    const [c1, c2, c3] = M.mainTrack(p).items as M.VideoClip[];
    expect(c2!.transitionIn).toBeUndefined(); // a cut
    expect(c3!.transitionIn).toEqual({ kind: 'fade', durationSec: 0.5 });
    expect(c1!.keyframes!.x!.at(0)!.v).toBeCloseTo(0.8, 3); // a pan right: the picture slides left across a scaled-up clip
    expect(c1!.keyframes!.x!.at(-1)!.v).toBeCloseTo(0.2, 3);
    expect(c1!.keyframes!.scale![0]!.v).toBeCloseTo(1.6, 3);
    expect(c2!.speedCurve?.preset).toBe('custom');
    expect(M.clipLength(c2!)).toBeCloseTo(1.15 + 0.25, 2); // the ramp still fills exactly the slot (+ half the crossfade)
    expect(c3!.keyframes).toBeUndefined();
    expect(c1!.look).toEqual({ lut: 'pack:warm-honey', strength: 0.8 }); // golden_warmth's pack twin
    const text = p.tracks.find(t => t.kind === 'text')!.items[0] as M.TextItem;
    expect(text).toMatchObject({ startSec: 3.1, durationSec: 1, text: 'Text', transform: { x: 0.5, y: 0.735 } });
    expect(out.notes.join(' ')).toMatch(/says "Text"/);
    expect(text.animIn).toBeUndefined(); // a cut in
    expect(text.style.font).toBe('sans');
    // G4: a caption that typed on and faded out, set in the condensed face.
    const typed = buildProject({ ...RECIPE, text: [{ ...RECIPE.text[0]!, words: 'SUMMER', fontId: 'condensed', animIn: 'typewriter', animInSec: 0.42, animOut: 'fade', animOutSec: 5 }] }, 'take_src', { s1: TAKE('tA'), s2: TAKE('tB'), s3: TAKE('tC') });
    const t2 = typed.project.tracks.find(t => t.kind === 'text')!.items[0] as M.TextItem;
    expect(t2).toMatchObject({ text: 'SUMMER', animIn: { kind: 'typewriter', durationSec: 0.42 }, animOut: { kind: 'fade', durationSec: 2 }, style: { font: 'condensed' } });
  });

  it('options switch parts off; a short take plays slower; slots without a take are left out', () => {
    const off = buildProject(RECIPE, 'take_src', { s1: TAKE('tA'), s3: TAKE('tC', 1) }, { camera: false, speed: false, text: false, look: false });
    expect(off.missing).toEqual(['s2']);
    const [c1, c3] = M.mainTrack(off.project).items as M.VideoClip[];
    expect(c1!.keyframes).toBeUndefined();
    expect(c1!.look).toBeUndefined();
    expect(off.project.tracks.some(t => t.kind === 'text')).toBe(false);
    expect(c3!.speed).toBeCloseTo(1 / 1.75, 3);
    expect(off.notes[0]).toMatch(/s3: the take is shorter than the slot, so it plays at 57%/);
    expect(editorTransition({ ...RECIPE.transitions[0]!, kind: 'whip', durationSec: 0.2 })).toEqual({ kind: 'whip', durationSec: 0.2 });
    expect(editorTransition({ ...RECIPE.transitions[0]!, kind: 'fade', durationSec: 5 })).toEqual({ kind: 'black', durationSec: 2 });
    expect(editorTransition({ ...RECIPE.transitions[0]!, kind: 'unknown' })).toBeUndefined();
  });
});

describe('Recreate · assembly under playbook directives (unit)', () => {
  it('cuts only, a transition limit, and a proven recipe\'s look when the reference\'s can\'t be mapped', () => {
    const takes = { s1: TAKE('tA'), s2: TAKE('tB'), s3: TAKE('tC') };
    const cuts = buildProject(RECIPE, 'take_src', takes, { transitions: false });
    expect(M.mainTrack(cuts.project).items.map(c => (c as M.VideoClip).transitionIn)).toEqual([undefined, undefined, undefined]);
    expect(M.timeline(cuts.project)[2]!.startSec).toBeCloseTo(RECIPE.slots[2]!.startSec, 2); // still on the reference's cut
    const short = buildProject(RECIPE, 'take_src', takes, { maxTransitionSec: 0.2 });
    expect((M.mainTrack(short.project).items[2] as M.VideoClip).transitionIn).toEqual({ kind: 'fade', durationSec: 0.2 });
    const far = { ...RECIPE, grade: { ...RECIPE.grade, look: { ...RECIPE.grade.look!, distance: 0.7 } } };
    expect((M.mainTrack(buildProject(far, 'take_src', takes).project).items[0] as M.VideoClip).look).toBeUndefined();
    const borrowed = buildProject(far, 'take_src', takes, { fallbackLook: { id: 'golden_warmth' } });
    expect((M.mainTrack(borrowed.project).items[0] as M.VideoClip).look?.lut).toBe(lutFor('palettes', 'golden_warmth')); // its pack twin
  });
});

describe('Recreate · action peaks line up (unit)', () => {
  const slot = { ...RECIPE.slots[0]!, peaks: [{ t: 0.5, strength: 1 }, { t: 0.2, strength: 0.3 }] };
  it('the take starts where its strongest usable peak plays at the slot\'s peak moment', () => {
    const take = { ...TAKE('tA'), durationSec: 3, peaks: [{ t: 2.0, strength: 0.9 }, { t: 0.3, strength: 0.5 }] };
    expect(peakInPoint(slot, take, { outSec: 1, speed: 1 }, 0)).toBe(1.5); // 2.0 − 0.5
    expect(peakInPoint(slot, take, { outSec: 1, speed: 1 }, 0.2)).toBe(1.3); // half a transition in: the moment is 0.7 s into the clip
    // A peak too late to keep the whole range inside the take falls back to the next one that fits, else 0.
    expect(peakInPoint(slot, { ...take, peaks: [{ t: 2.9, strength: 1 }, { t: 0.9, strength: 0.2 }] }, { outSec: 1, speed: 1 }, 0)).toBe(0.4);
    expect(peakInPoint(slot, { ...take, peaks: [{ t: 0.1, strength: 1 }] }, { outSec: 1, speed: 1 }, 0)).toBe(0);
    expect(peakInPoint(slot, { ...take, peaks: [] }, { outSec: 1, speed: 1 }, 0)).toBe(0);
    expect(peakInPoint({ ...slot, peaks: [] }, take, { outSec: 1, speed: 1 }, 0)).toBe(0);
    // A take that already plays slower to fill the slot has no room to move.
    expect(peakInPoint(slot, take, { outSec: 1, speed: 0.8 }, 0)).toBe(0);
  });
  it('in the built edit: the clip starts at that in-point and keeps its length; off with peaks: false', () => {
    const recipe = { ...RECIPE, slots: RECIPE.slots.map((x, i) => (i === 0 ? { ...x, peaks: [{ t: 0.5, strength: 1 }] } : x)) };
    const takes = { s1: { ...TAKE('tA', 4), peaks: [{ t: 2.5, strength: 1 }] }, s2: TAKE('tB'), s3: TAKE('tC') };
    const on = buildProject(recipe, 'take_src', takes);
    const c1 = M.mainTrack(on.project).items[0] as M.VideoClip;
    expect(c1.inSec).toBe(2);
    const off = buildProject(recipe, 'take_src', takes, { peaks: false });
    const d1 = M.mainTrack(off.project).items[0] as M.VideoClip;
    expect(d1.inSec).toBe(0);
    expect(c1.outSec - c1.inSec).toBeCloseTo(d1.outSec - d1.inSec, 4);
    expect(M.timeline(on.project).map(x => x.startSec)).toEqual(M.timeline(off.project).map(x => x.startSec)); // the cuts don't move
    expect(on.notes.some(n => /s1: starts 2.00 s into the take/.test(n))).toBe(true);
  });
});

describe('Recreate · swap fills (unit, G2)', () => {
  it('the segment: the slot plus half of each neighbouring transition, widened evenly to the engine minimum inside the reference', () => {
    const [s1, s2, s3] = RECIPE.slots as [Recipe['slots'][number], Recipe['slots'][number], Recipe['slots'][number]];
    expect(swapSegment(RECIPE, s2)).toEqual({ startSec: 1.2, endSec: 3.2 }); // 1.5–2.9 (half the 0.5 s crossfade out), to 2 s
    expect(swapSegment(RECIPE, s2, 4)).toEqual({ startSec: 0.2, endSec: 4.2 });
    expect(swapSegment(RECIPE, s3, 4)).toEqual({ startSec: 0.4, endSec: 4.4 }); // held at the reference's end
    expect(swapSegment(RECIPE, s1, 1)).toEqual({ startSec: 0, endSec: 1.5 });
    expect(swapDirection(s2, true)).toMatch(/^Remove every caption/);
    // Your own setting: the studio location the brief names (whole words; the longest name wins), and the plate's size.
    const locs = [{ name: 'Roof' }, { name: 'Rooftop' }, { name: 'Rooftop bar' }, { name: 'Kitchen' }];
    expect(matchLocation('a rooftop at sunset', locs)).toEqual({ name: 'Rooftop' });
    expect(matchLocation('the rooftop bar, night', locs)).toEqual({ name: 'Rooftop bar' });
    expect(matchLocation('a beach', locs)).toBeNull();
    expect(plateSize('9:16')).toEqual([752, 1328]);
    expect(plateSize('16:9')).toEqual([1328, 752]);
    expect(platePrompt('a rooftop at sunset')).toMatch(/^An empty background plate of a rooftop at sunset, .*No people, no text/);
    expect(swapDirection({ ...s2, brief: { location: 'a rooftop at sunset' } }, false)).toMatch(/New setting: a rooftop at sunset\./);
  });
  it('a swapped slot plays its segment at 1× from the slot\'s moment: no camera keys, ramp or look a second time; the others keep theirs', () => {
    const out = buildProject(RECIPE, 'take_src', { s1: TAKE('tA'), s2: TAKE('tSwap', 2), s3: TAKE('tC') }, { baked: { s2: { startSec: 1.2 } } });
    const [c1, c2, c3] = M.mainTrack(out.project).items as M.VideoClip[];
    expect(c2).toMatchObject({ inSec: 0.3, speed: 1 });
    expect(c2!.outSec).toBeCloseTo(0.3 + 1.15 + 0.25, 4); // the slot plus half the crossfade out, as any clip
    expect(c2!.keyframes).toBeUndefined();
    expect(c2!.speedCurve).toBeUndefined();
    expect(c2!.look).toBeUndefined();
    expect(c1!.keyframes).toBeTruthy();
    expect(c1!.look).toBeTruthy();
    expect(c3!.transitionIn).toEqual({ kind: 'fade', durationSec: 0.5 });
    const plain = M.timeline(buildProject(RECIPE, 'take_src', { s1: TAKE('tA'), s2: TAKE('tB'), s3: TAKE('tC') }).project);
    M.timeline(out.project).forEach((x, i) => expect(x.startSec).toBeCloseTo(plain[i]!.startSec, 3)); // the cuts don't move
  });
});

describe('Recreate · freezes (unit)', () => {
  it('the analysis says where the freeze is', () => {
    const fps = 30, energy = Array.from({ length: 90 }, (_, i) => (i >= 31 && i < 46 ? 0.0005 : 0.05)); // frames 31–45 identical
    const sp = speedOf({ startSec: 0, endSec: 3, startFrame: 0, endFrame: 90 }, { fps, energy } as never);
    expect(sp.ramp).toBe('freeze');
    expect(sp.freeze).toEqual({ t: 1, durationSec: 0.5 }); // differences 31..45 → the hold starts at frame 30 (1.0 s), 15 frames
  });
  it('a freeze plays at 0.1× for its length at its moment; the clip keeps the slot\'s length and the cuts stay', () => {
    const slot = { ...RECIPE.slots[2]!, speed: { ramp: 'freeze' as const, curve: [{ t: 0, speed: 1 }], confidence: 0.55, freeze: { t: 0.4, durationSec: 0.5 } } };
    const recipe = { ...RECIPE, slots: [RECIPE.slots[0]!, RECIPE.slots[1]!, slot] };
    const out = buildProject(recipe, 'take_src', { s1: TAKE('tA'), s2: TAKE('tB'), s3: TAKE('tC', 4) }, { peaks: false });
    const c = M.mainTrack(out.project).items[2] as M.VideoClip;
    expect(c.speedCurve?.preset).toBe('custom');
    const tl = M.timeline(out.project);
    expect(tl[2]!.endSec - tl[2]!.startSec).toBeCloseTo(slot.durationSec + 0.25, 1); // + half the crossfade before it
    // Rendered as the editor's pieces: about 0.5 s of output at ≤ 0.2×, starting around 0.4 s after the slot's start.
    let t = 0, slow = 0, firstSlow = -1;
    for (const p of M.speedPieces(c)) { const len = (p.outSec - p.inSec) / p.speed; if (p.speed <= 0.2) { slow += len; if (firstSlow < 0) firstSlow = t; } t += len; }
    expect(slow).toBeGreaterThan(0.3); expect(slow).toBeLessThan(0.7);
    expect(Math.abs(firstSlow - (0.25 + 0.4))).toBeLessThan(0.15);
    expect(out.notes.some(n => /s3: the reference holds a frame for 0.50 s/.test(n))).toBe(true);
    expect(freezeCurve({ t: 0, durationSec: 0.05 }, 1)).toBeUndefined(); // too short to show
    expect(buildProject(recipe, 'take_src', { s1: TAKE('tA'), s2: TAKE('tB'), s3: TAKE('tC', 4) }, { speed: false, peaks: false }).project.tracks[0]!.items.every(x => !(x as M.VideoClip).speedCurve)).toBe(true);
  });
});

describe('Recreate · briefs, matching and the fill request (unit)', () => {
  const cand = (id: string, o: Partial<Candidate> = {}): Candidate => ({ id, modelId: 'm1', durationSec: 3, width: 720, height: 1280, status: 'test', createdAt: 0, draft: null, title: id, ...o });
  it('briefs are checked and add framing and angle to the rig', () => {
    expect(BriefSchema.safeParse({ shotSize: 'huge' }).success).toBe(false);
    expect(BriefSchema.safeParse({ angle: 'low', subject: 'Zelphira', extra: 1 }).success).toBe(false);
    const r = withBriefs(RECIPE, { s2: { shotSize: 'cu', angle: 'low', subject: 'She', action: 'flips her hair' } });
    expect(r.slots[1]!.rig).toEqual({ moves: [{ id: 'zoom_in' }], shotSize: 'cu', height: 'low' });
    expect(() => withBriefs(RECIPE, { s9: {} })).toThrow(/no slot s9/);
  });

  it('a suggestion outside a slot\'s top few still carries its score and reasons (equal takes, each used once)', () => {
    const four: Candidate[] = ['a', 'b', 'c', 'd'].map(id => ({ id, modelId: null, durationSec: 5, width: 720, height: 1280, status: 'final', createdAt: 1, draft: null, title: id }));
    const recipe = { ...RECIPE, slots: [...RECIPE.slots, { ...RECIPE.slots[2]!, id: 's4' }] };
    const m = matchSlots(recipe, four, { top: 3 });
    expect(Object.keys(m.assignment)).toHaveLength(4);
    for (const s of m.slots) expect(s.suggestion).toMatchObject({ takeId: s.suggested, score: expect.any(Number), reasons: expect.any(Array) });
    expect(m.slots.some(s => !s.candidates.some(c => c.takeId === s.suggested))).toBe(true); // the case that used to crash
  });

  it('scores length, shape, move, framing and the lead; each take is suggested once; nothing good = to generate', () => {
    const r = withBriefs(RECIPE, { s2: { shotSize: 'cu' } });
    const good = scoreTake(r.slots[1]!, '9:16', cand('a', { draft: { v: 1, tool: 'shot', rig: { moves: [{ id: 'zoom_in' }], shotSize: 'cu' } } as any }), { leadModelId: 'm1' });
    const bad = scoreTake(r.slots[1]!, '9:16', cand('b', { durationSec: 0.4, width: 1920, height: 1080, modelId: 'm2' }), { leadModelId: 'm1' });
    expect(good.score).toBeGreaterThan(0.9);
    expect(good.reasons).toEqual(expect.arrayContaining(['long enough', 'same move (zoom_in)', 'same framing (cu)', 'your lead']));
    expect(bad.score).toBeLessThan(0.5);
    const m = matchSlots(r, [cand('a', { draft: { v: 1, tool: 'shot', rig: { moves: [{ id: 'zoom_in' }] } } as any }), cand('b', { draft: { v: 1, tool: 'shot', rig: { moves: [{ id: 'pan_right' }] } } as any })],
      { leadModelId: 'm1', minScore: 0.7 });
    expect(m.assignment).toEqual({ s2: 'a', s1: 'b' });
    expect(m.slots.find(s => s.slotId === 's3')).toMatchObject({ suggested: null, toGenerate: true });
    expect(new Set(Object.values(m.assignment)).size).toBe(Object.values(m.assignment).length);
  });

  it('the fill request: the brief as the prompt, the shape, framing, angle and move, whole seconds at least the minimum', () => {
    const r = withBriefs(RECIPE, { s2: { shotSize: 'cu', angle: 'low', subject: 'she', action: 'flips her hair', location: 'a rooftop at dusk' } });
    const q = shotRequestFor(r, r.slots[1]!, { modelId: 'm1', quality: 'hd', referenceName: 'Tuff edit' });
    expect(q).toMatchObject({ modelId: 'm1', quality: 'hd', duration: 2, aspectRatio: '9:16', takes: 1, prompt: 'She, flips her hair, in a rooftop at dusk.', title: 'Tuff edit · s2',
      camera: { angle: { height: 'low', shotSize: 'cu' }, move: { id: 'zoom_in', intensity: 0.5 } }, draft: { tool: 'shot', recreate: { slotId: 's2' } } });
    expect(shotRequestFor(r, r.slots[2]!, { modelId: 'm1', quality: 'draft', minSeconds: 4 }).duration).toBe(4);
    // No brief yet: never an empty prompt. The reference's summary, else a neutral line; the framing and move still apply.
    expect(promptSource(r, r.slots[1]!)).toBe('brief');
    expect(shotRequestFor(r, r.slots[0]!, { modelId: 'm1', quality: 'hd' }).prompt).toBe('The model moves naturally, matching the reference shot.');
    expect(promptSource(r, r.slots[0]!)).toBe('default');
    const withSummary = { ...r, summary: 'A mirror outfit check with a hair flip' };
    expect(shotRequestFor(withSummary, withSummary.slots[0]!, { modelId: 'm1', quality: 'hd' }).prompt).toBe('A mirror outfit check with a hair flip.');
    expect(promptSource(withSummary, withSummary.slots[0]!)).toBe('summary');
  });
});

describe.skipIf(!hasFfmpeg)('Recreate · the flow through the API and Claude\'s tools (mock provider)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, ownerUser: AuthUser, dir: string, refId: string, sessionId: string, model: { id: string };
  const env = () => ({ ctx: a.ctx, user: ownerUser, source: 'mcp' as const });
  const tool = (n: string) => RECREATE_TOOLS.find(t => t.name === n)!;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    model = (await owner.req('POST', '/v1/models', { name: 'Zelphira', age: 24, niche: 'Fashion' })).body;
    for (const [k, asset] of Object.entries({ face: 'face', profile: 'profile', front: 'g_front', tq: 'g_tq', side: 'g_side', back: 'g_back', faceTq: 'c_face' }))
      await owner.req('PUT', `/v1/models/${model.id}/slots/${k}`, { image: { asset }, source: 'upload' });
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-recreate-slots-'));
    const ref = fs.readFileSync(makeReference(dir));
    await putObject(a.ctx, { key: 'u/rx/flow.mp4', body: ref, studioId, kind: 'clip', contentType: 'video/mp4' });
    // Two of her takes: a pan (2 s) and a static shot (4 s), with drafts.
    for (const [id, move, d] of [['t_pan', 'pan_right', 2], ['t_static', 'static', 4]] as const) {
      await putObject(a.ctx, { key: `c/${id}.mp4`, body: ref, studioId, kind: 'clip', contentType: 'video/mp4' });
      await a.ctx.db.insert(takes).values({ id, studioId, userId: owner.id, kind: 'take', jobId: null, modelId: model.id, index: 1, of: 1, title: id, label: 'HD', engineLabel: '', cost: 0, seed: 0,
        status: 'test', thumb: null, prompt: '', mediaKey: `c/${id}.mp4`, media: { durationSec: d, width: 180, height: 320, fps: 30 }, draft: { v: 1, tool: 'shot', rig: { moves: [{ id: move }] } } as any, createdAt: Date.now() });
    }
    sessionId = (await owner.req('POST', '/v1/edit-sessions', { takeId: 't_static' })).body.id;
  });
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  it('analyze_reference (free, waits) and get_recipe with the contact sheet image', async () => {
    const [up] = await a.ctx.db.execute(sql`select id from uploads where storage_key = 'u/rx/flow.mp4'`).then((r: any) => r.rows ?? r);
    const r = await tool('analyze_reference').run(env(), { uploadId: up.id, name: 'Tuff edit' }) as any;
    expect(r).toMatchObject({ state: 'ready', summary: { shots: 3, aspect: '9:16' } });
    expect(r.summary.slots.map((s: any) => s.move)).toEqual(['pan_right', 'zoom_in', 'static']);
    refId = r.referenceId;
    const g = await tool('get_recipe').run(env(), { referenceId: refId }) as any;
    expect(g.mcpContent[0]).toMatchObject({ type: 'image', mimeType: 'image/png' });
    expect(g.structuredContent.recipe.slots).toHaveLength(3);
    expect((await tool('get_recipe').run(env(), { referenceId: refId, contactSheet: false }) as any).recipe.schema).toBe('muse.recipe/1');
    // Members can't drive it with Claude; an owner's member-made reference is still theirs only through the app.
    await expect(tool('get_recipe').run({ ...env(), user: { ...ownerUser, role: 'member' } }, { referenceId: refId })).rejects.toThrow(/studio owner/);
  }, 60_000);

  it('briefs, then matching: her pan and static takes go to s1 and s3; s2 (a close-up zoom) is to generate', async () => {
    const b = await tool('set_slot_briefs').run(env(), { referenceId: refId, slots: { s2: { shotSize: 'cu', subject: 'she', action: 'flips her hair' } } }) as any;
    expect(b.summary.slots[1].brief).toMatchObject({ shotSize: 'cu' });
    expect((await owner.req('PUT', `/v1/recreate/references/${refId}/briefs`, { slots: { s2: { shotSize: 'gigantic' } } })).status).toBe(400);
    const m = await tool('match_slots').run(env(), { referenceId: refId, modelId: model.id }) as any;
    expect(m.assignment).toMatchObject({ s1: 't_pan', s3: 't_static' });
    expect(m.slots.find((s: any) => s.slotId === 's2').toGenerate).toBe(true);
    // A plain summary and tags ride along with the briefs.
    const sb = await owner.req('PUT', `/v1/recreate/references/${refId}/briefs`, { slots: {}, summary: 'Three beats: a pan, a hair flip, a still.', tags: ['tuff', 'hair'] });
    expect(sb.status).toBe(200);
    expect(sb.body.recipe).toMatchObject({ summary: 'Three beats: a pan, a hair flip, a still.', tags: ['tuff', 'hair'] });
    // The fill state remembers the match.
    const f = (await owner.req('GET', `/v1/recreate/references/${refId}/fill`)).body;
    expect(f.slots.map((x: any) => [x.slotId, x.state, x.takeId ?? null])).toEqual([['s1', 'matched', 't_pan'], ['s2', 'to_generate', null], ['s3', 'matched', 't_static']]);
    expect(f.slots[0].score).toBeGreaterThan(0.6);
    expect(f.slots[0].reason).toMatch(/long enough/);
  });

  it('fill_slot: the price first; confirm asks the owner in the session; their yes starts a Suite job', async () => {
    const est = await tool('fill_slot').run(env(), { referenceId: refId, slotId: 's2', modelId: model.id, quality: 'draft', sessionId, method: 'generate' }) as any;
    expect(est).toMatchObject({ needsConfirmation: true, method: 'generate', seconds: 2, prompt: 'She, flips her hair.' });
    expect(est.estimateUsd).toBeGreaterThanOrEqual(0);
    const ask = await tool('fill_slot').run(env(), { referenceId: refId, slotId: 's2', modelId: model.id, quality: 'draft', sessionId, method: 'generate', confirm: true }) as any;
    expect(ask.waitingForOwner).toBe(true);
    const pend = (await owner.req('GET', `/v1/edit-sessions/${sessionId}`)).body.pending;
    expect(pend[0]).toMatchObject({ kind: 'recreate_fill', label: 'Generate s2 for “Tuff edit”' });
    const yes = (await owner.req('POST', `/v1/edit-sessions/${sessionId}/pending/${ask.pendingId}`, { approve: true })).body;
    expect(yes.status).toBe('done');
    const job = await until(async () => { const j = await a.ctx.jobs.get(yes.jobId); return j?.state === 'done' || j?.state === 'failed' ? j : null; }, 30_000);
    expect(job.state).toBe('done');
    expect(job.request).toMatchObject({ engine: 'suite', aspectRatio: '9:16', seconds: 2 });
    expect(job.draft).toMatchObject({ tool: 'shot', recreate: { slotId: 's2' } });
    const ref = (await owner.req('GET', `/v1/recreate/references/${refId}`)).body;
    expect(ref.recipe.slots[1].fill.jobId).toBe(yes.jobId);
    const ready = (await owner.req('GET', `/v1/recreate/references/${refId}/fill`)).body.slots[1];
    expect(ready).toMatchObject({ slotId: 's2', state: 'ready', jobId: yes.jobId });
    expect(ready.takeId).toBeTruthy();

    // apply_recipe with the two takes and the finished job: one undoable change, cuts on the reference's times.
    const before = await editSessionsOf(a.ctx).row(ownerUser, sessionId);
    const out = await tool('apply_recipe').run(env(), { referenceId: refId, sessionId, slots: { s1: 't_pan', s2: yes.jobId, s3: 't_static' } }) as any;
    expect(out).toMatchObject({ applied: true, missing: [], waiting: [] });
    expect(out.match.perSlot.map((x: any) => x.slotId)).toEqual(['s1', 's2', 's3']);
    expect(out.match.perSlot[1].score).toBe(0.85); // generated for the slot
    expect(out.match.cuts).toBeGreaterThan(0.9);
    for (const k of ['overall', 'cuts', 'text', 'ramps', 'grade', 'shots']) { expect(out.match[k]).toBeGreaterThanOrEqual(0); expect(out.match[k]).toBeLessThanOrEqual(1); }
    expect(out.sources).toMatchObject({ c1: { recipeId: refId, slotId: 's1' }, c2: { slotId: 's2' }, c3: { slotId: 's3' } });
    expect((await owner.req('GET', `/v1/recreate/references/${refId}/fill`)).body).toMatchObject({ applied: { sessionId, slots: { s1: 't_pan', s3: 't_static' } }, match: out.match });
    // The op carries the sources (for workstream 3's corrections), next to its own `touched`.
    const { editOps } = await import('../src/editor/schema.js');
    const { desc, eq: eq2 } = await import('drizzle-orm');
    const [op] = await a.ctx.db.select().from(editOps).where(eq2(editOps.sessionId, sessionId)).orderBy(desc(editOps.id)).limit(1);
    expect((op!.meta as any).sources).toEqual(out.sources);
    expect((op!.meta as any).touched).toBeTruthy();
    const after = await editSessionsOf(a.ctx).row(ownerUser, sessionId);
    expect(after.revision).toBe(before.revision + 1);
    const p = after.project as M.EditProject;
    expect(M.mainTrack(p).items).toHaveLength(3);
    const tl = M.timeline(p);
    expect(tl[1]!.startSec).toBeCloseTo(ref.recipe.slots[1].startSec, 2);
    expect(out.durationSec).toBeCloseTo(ref.recipe.source.durationSec, 1);
    const hist = (await owner.req('GET', `/v1/edit-sessions/${sessionId}/history`)).body;
    const entry = hist.find((h: any) => h.label === 'Recreated “Tuff edit”');
    expect(entry).toMatchObject({ byClaude: true });
    // Undo restores the edit as it was.
    expect((await owner.req('POST', `/v1/edit-sessions/${sessionId}/undo`, {})).status).toBe(400);
    const undo = await owner.req('POST', `/v1/edit-sessions/${sessionId}/undo`, { entryId: entry.id });
    expect(undo.status).toBe(200);
    expect(M.mainTrack((await editSessionsOf(a.ctx).row(ownerUser, sessionId)).project as M.EditProject).items).toHaveLength(M.mainTrack(before.project as M.EditProject).items.length);
  }, 90_000);

  it('the app: estimate and apply over HTTP; a slot nothing filled is reported missing; checks', async () => {
    const e = (await owner.req('POST', `/v1/recreate/references/${refId}/slots/s3/estimate`, { modelId: model.id, quality: 'draft', method: 'generate' })).body;
    expect(e).toMatchObject({ slotId: 's3', method: 'generate', request: { duration: 2 } });
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/slots/s9/estimate`, { modelId: model.id })).status).toBe(404);
    const s = (await owner.req('GET', `/v1/edit-sessions/${sessionId}`)).body;
    const r = await owner.req('POST', `/v1/recreate/references/${refId}/apply`, { sessionId, baseRevision: s.revision, slots: { s1: 't_pan', s3: 't_static' }, device: 'mac' });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ missing: ['s2'], label: 'Recreated “Tuff edit”' });
    // Slots without a take are skipped: the second clip came from s3.
    expect(r.body.sources).toMatchObject({ c1: { slotId: 's1' }, c2: { slotId: 's3' } });
    expect(r.body.sources.c3).toBeUndefined();
    expect(r.body.match.perSlot[1]).toEqual({ slotId: 's2', score: 0 });
    expect(r.body.match.cuts).toBeLessThan(1);
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/apply`, { sessionId, slots: { s1: 'nope' } })).body.error).toMatch(/slots.s1: no video take or job nope/);
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/apply`, { sessionId, slots: { s7: 't_pan' } })).body.error).toMatch(/no slot s7/);
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/apply`, { sessionId, baseRevision: 0, slots: { s1: 't_pan' } })).status).toBe(409); // stale
    expect((await member.req('POST', `/v1/recreate/references/${refId}/match`, {})).status).toBe(404); // the owner's reference
  }, 60_000);

  it('fix one shot in place: another take for s1, the timeline and the owner\'s other edits kept, one undoable change', async () => {
    const row = () => editSessionsOf(a.ctx).row(ownerUser, sessionId);
    let p = (await row()).project as M.EditProject;
    const before = M.timeline(p);
    // The owner turns c2 (shot s3) down by hand first.
    const s0 = await row();
    const vol = await owner.req('POST', `/v1/edit-sessions/${sessionId}/patch`, { baseRevision: s0.revision, device: 'mac', patch: [{ op: 'add', path: '/tracks/0/items/1/volume', value: 0.3 }] });
    expect(vol.status).toBe(200);
    const r = await owner.req('POST', `/v1/recreate/references/${refId}/slots/s1/replace`, { sessionId, take: 't_static', device: 'mac' });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body).toMatchObject({ slotId: 's1', itemId: 'c1', takeId: 't_static', label: 'Replaced shot s1 in “Tuff edit”' });
    p = (await row()).project as M.EditProject;
    const c1 = M.mainTrack(p).items[0] as M.VideoClip, c2 = M.mainTrack(p).items[1] as M.VideoClip;
    expect(p.assets.find(x => x.id === c1.asset)!.take).toBe('t_static');
    expect(c2.volume).toBe(0.3); // the hand edit stays
    M.timeline(p).forEach((x, i) => expect(x.startSec).toBeCloseTo(before[i]!.startSec, 4)); // nothing moves
    expect((await owner.req('GET', `/v1/recreate/references/${refId}/fill`)).body.applied.slots.s1).toBe('t_static');
    // One undoable change.
    const hist = (await owner.req('GET', `/v1/edit-sessions/${sessionId}/history`)).body;
    expect(hist[0]).toMatchObject({ label: 'Replaced shot s1 in “Tuff edit”' });
    // Checks: a shot that isn't in this build, another session, an unknown take or shot.
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/replace`, { sessionId, take: 't_pan' })).body.code).toBe('slot_not_in_edit');
    const other = (await owner.req('POST', '/v1/edit-sessions', { takeId: 't_pan' })).body.id;
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/slots/s1/replace`, { sessionId: other, take: 't_pan' })).body.code).toBe('not_built_here');
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/slots/s1/replace`, { sessionId, take: 'nope' })).status).toBe(400);
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/slots/s9/replace`, { sessionId, take: 't_pan' })).status).toBe(404);
    // Claude's tool does the same, as Claude's change.
    const back = await tool('replace_slot').run(env(), { referenceId: refId, slotId: 's1', sessionId, take: 't_pan' }) as any;
    expect(back).toMatchObject({ takeId: 't_pan' });
    expect((await owner.req('GET', `/v1/edit-sessions/${sessionId}/history`)).body[0]).toMatchObject({ byClaude: true });
  });

  it('G2 swap: the model swapped into the reference\'s own segment; no second zoom, ramp or look on that slot; replaced back restores them', async () => {
    // The price: swap by default (the reference video is here, Edit is available), with the segment and what it carries.
    const e = (await owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/estimate`, { modelId: model.id, quality: 'draft' })).body;
    expect(e).toMatchObject({ slotId: 's2', method: 'swap', keepBackground: true, baked: ['camera', 'speed', 'look'],
      request: { engine: 'h3', use: 'full', keepAudio: false, background: 'keep', takes: 1 }, estimate: { method: 'swap', label: 'Edit', ok: true } });
    expect(e.request.direction).toMatch(/Remove every caption/);
    expect(e.request.clipId).toBeUndefined(); // nothing is cut or stored for a price
    expect(e.estimate.estimate).toBeGreaterThan(0);
    expect(e.estimate.buttonLabel).toMatch(/^Swap in · /);
    // The segment: the slot plus half of each neighbouring transition (s2 → s3 is a 0.5 s crossfade), at least 2 s.
    const s2 = (await owner.req('GET', `/v1/recreate/references/${refId}`)).body.recipe.slots[1];
    expect(e.segment.startSec).toBeLessThanOrEqual(s2.startSec + 1e-6);
    expect(e.segment.endSec).toBeGreaterThanOrEqual(s2.endSec);
    expect(e.segment.endSec - e.segment.startSec).toBeGreaterThanOrEqual(2 - 1e-6);
    // Your own setting: the slot's brief names the place; generate is still there on request.
    const own = (await owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/estimate`, { modelId: model.id, keepBackground: false })).body;
    expect(own.request).toMatchObject({ background: 'photo' });
    expect(own.request.direction).toMatch(/New setting: /);
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/estimate`, { modelId: model.id, method: 'generate' })).body.method).toBe('generate');
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/estimate`, { modelId: 'nope', method: 'swap' })).status).toBe(404);

    // Fill: the segment becomes a private clip under the reference (rx/…), and an ordinary Edit job runs on it.
    const f = await owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/fill`, { modelId: model.id, quality: 'draft' });
    expect(f.status, JSON.stringify(f.body)).toBe(200);
    expect(f.body).toMatchObject({ slotId: 's2', method: 'swap' });
    const job = await a.ctx.jobs.get(f.body.job.id);
    expect(job!.request).toMatchObject({ engine: 'h3', keepAudio: false, background: 'keep' });
    const { clips } = await import('../src/db/schema.js');
    const { eq: eq3 } = await import('drizzle-orm');
    const [clip] = await a.ctx.db.select().from(clips).where(eq3(clips.id, job!.request.clipId));
    expect(clip!.storageKey).toMatch(new RegExp(`^rx/.+/${refId}/swap-s2-`));
    expect(clip!.durationSec).toBeCloseTo(e.segment.endSec - e.segment.startSec, 2);
    expect(await a.ctx.storage.head(clip!.storageKey!)).toBeTruthy();
    expect((await owner.req('GET', `/v1/recreate/references/${refId}/fill`)).body.slots[1]).toMatchObject({ slotId: 's2', state: 'generating', method: 'swap' });

    // The job's take (the simulated pod isn't run here): the swapped segment, as long as the segment.
    const segLen = e.segment.endSec - e.segment.startSec;
    await a.ctx.db.update(jobs).set({ state: 'done', gpuState: 'done' }).where(eq3(jobs.id, job!.id));
    await a.ctx.db.insert(takes).values({ id: 't_swap', studioId: ownerUser.studioId, userId: owner.id, kind: 'take', jobId: job!.id, modelId: model.id, index: 1, of: 1, title: 't_swap', label: 'Edit', engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '',
      mediaKey: 'c/t_static.mp4', media: { durationSec: segLen, width: 180, height: 320, fps: 30 }, createdAt: Date.now() });
    expect((await owner.req('GET', `/v1/recreate/references/${refId}/fill`)).body.slots[1]).toMatchObject({ state: 'ready', method: 'swap', takeId: 't_swap' });

    // Built: s2's clip plays the swap at 1× from the slot's moment, with no camera keys, ramp or look; s1 keeps its own.
    const s = (await owner.req('GET', `/v1/edit-sessions/${sessionId}`)).body;
    const out = (await owner.req('POST', `/v1/recreate/references/${refId}/apply`, { sessionId, baseRevision: s.revision, slots: { s1: 't_pan', s2: job!.id, s3: 't_static' } })).body;
    expect(out.baked).toEqual({ s2: ['camera', 'speed', 'look'] });
    const p = (await editSessionsOf(a.ctx).row(ownerUser, sessionId)).project as M.EditProject;
    const [c1, c2] = M.mainTrack(p).items as M.VideoClip[];
    expect(c1!.keyframes).toBeTruthy(); // s1's pan is still replayed on an ordinary take
    expect(c2!.keyframes).toBeUndefined();
    expect(c2!.speedCurve).toBeUndefined();
    expect(c2!.look).toBeUndefined();
    expect(c2!.speed).toBe(1);
    expect(c2!.inSec).toBeCloseTo(s2.startSec - e.segment.startSec, 3); // the slot's moment in the segment
    expect(out.notes.join(' ')).toMatch(/s2: swapped into the reference’s own shot/);
    expect(out.match.perSlot[1].score).toBe(0.95);
    expect(out.match.ramps).toBe(1); // s2's ramp is in its pixels
    expect((await owner.req('GET', `/v1/recreate/references/${refId}/fill`)).body.applied.baked).toEqual({ s2: ['camera', 'speed', 'look'] });

    // Fix this shot with an ordinary take: the reference's ramp comes back on it; with the swap again, it goes.
    const back = (await owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/replace`, { sessionId, take: 't_static' })).body;
    expect(back.baked).toBeUndefined();
    let c = M.mainTrack((await editSessionsOf(a.ctx).row(ownerUser, sessionId)).project as M.EditProject).items[1] as M.VideoClip;
    // s2 is the slow zoom in: its camera keys (and a ramp, if the analysis found one) come back.
    expect(s2.camera.motion).toBe('zoom_in');
    expect(c.keyframes?.scale?.length).toBeGreaterThan(1);
    if (s2.speed.ramp !== 'none' && s2.speed.ramp !== 'freeze') expect(c.speedCurve?.preset).toBe('custom');
    const again = (await owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/replace`, { sessionId, take: 't_swap' })).body;
    expect(again.baked).toEqual(['camera', 'speed', 'look']);
    c = M.mainTrack((await editSessionsOf(a.ctx).row(ownerUser, sessionId)).project as M.EditProject).items[1] as M.VideoClip;
    expect(c.speedCurve).toBeUndefined();
    expect(c.keyframes).toBeUndefined();

    // A failed swap is refunded and offers a generated shot instead.
    await a.ctx.db.update(jobs).set({ state: 'failed' }).where(eq3(jobs.id, job!.id));
    await a.ctx.db.delete(takes).where(eq3(takes.id, 't_swap'));
    expect((await owner.req('GET', `/v1/recreate/references/${refId}/fill`)).body.slots[1]).toMatchObject({ state: 'to_generate', fallback: 'generate', failedJobId: job!.id });

    // No swap engine right now: the default price is a generated shot (and says why); asking for a swap is refused.
    const caps = a.ctx.jobs.capabilities;
    a.ctx.jobs.capabilities = () => [];
    try {
      const g = (await owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/estimate`, { modelId: model.id })).body;
      expect(g).toMatchObject({ method: 'generate', swapUnavailable: expect.stringMatching(/Swapping isn’t available/) });
      const no = await owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/estimate`, { modelId: model.id, method: 'swap' });
      expect([no.status, no.body.code]).toEqual([409, 'swap_unavailable']);
    } finally { a.ctx.jobs.capabilities = caps; }

    // Your own setting (Edit only): a studio location the brief names (free), a picked one, else a plate made from
    // the brief (its price in the same button; reused for free once made). It goes to the pod as the last reference.
    await owner.req('PUT', `/v1/recreate/references/${refId}/briefs`, { slots: { s1: { location: 'a rooftop at sunset' } } });
    const roof = (await owner.req('POST', '/v1/suite/locations', { name: 'Rooftop', image: { asset: 'g_front' } })).body;
    const loc = (await owner.req('POST', '/v1/suite/locations', { name: 'Kitchen', image: { asset: 'g_tq' } })).body;
    const est = (o: object) => owner.req('POST', `/v1/recreate/references/${refId}/slots/s1/estimate`, { modelId: model.id, keepBackground: false, ...o }).then(x => x.body);
    const plain = (await owner.req('POST', `/v1/recreate/references/${refId}/slots/s1/estimate`, { modelId: model.id })).body;
    const m1 = await est({});
    expect(m1.background).toEqual({ source: 'location', locationId: roof.id, name: 'Rooftop', matched: true, usd: 0 });
    expect(m1.estimate.estimate).toBe(plain.estimate.estimate); // free
    expect((await est({ locationId: loc.id })).background).toMatchObject({ source: 'location', locationId: loc.id, matched: false });
    expect((await owner.req('POST', `/v1/recreate/references/${refId}/slots/s1/estimate`, { modelId: model.id, keepBackground: false, locationId: 'nope' })).status).toBe(400);
    await owner.req('DELETE', `/v1/suite/locations/${roof.id}`);
    const gen = await est({});
    expect(gen.background).toMatchObject({ source: 'generated', setting: 'a rooftop at sunset' });
    expect(gen.background.usd).toBeGreaterThan(0);
    expect(gen.estimate.estimate).toBeCloseTo(plain.estimate.estimate + gen.background.usd, 2);
    expect(gen.estimate.buttonLabel).toBe(`Swap in · ${gen.estimate.seconds.toFixed(1)} s · $${gen.estimate.estimate.toFixed(2)}`);
    const f2 = await owner.req('POST', `/v1/recreate/references/${refId}/slots/s1/fill`, { modelId: model.id, keepBackground: false });
    expect(f2.status, JSON.stringify(f2.body)).toBe(200);
    expect(f2.body.background).toMatchObject({ source: 'generated' });
    const j2 = await a.ctx.jobs.get(f2.body.job.id);
    expect(j2!.request).toMatchObject({ engine: 'h3', background: 'photo' });
    const refs = j2!.request.references as { label: string }[];
    expect(refs.at(-1)!.label).toBe('background');
    expect(refs.length).toBeLessThanOrEqual(6);
    expect(refs.filter(x => x.label !== 'background').length).toBeLessThanOrEqual(5);
    expect(j2!.prompt).toMatch(/background/);
    expect((await est({})).background).toMatchObject({ source: 'generated', usd: 0, reused: true }); // made once

    // Edit refuses at the last moment: the hosted swap has its own price, so it only runs within the confirmed one.
    const create0 = a.ctx.jobs.create.bind(a.ctx.jobs);
    Object.defineProperty(a.ctx.replicate, 'configured', { get: () => true, configurable: true });
    (a.ctx.jobs as any).create = async (u: any, body: any) => {
      if (body.engine === 'h3') throw Object.assign(new (await import('../src/errors.js')).ApiError(400, 'engine_unavailable', "Edit isn't available right now"));
      return { id: 'j_hosted', cost: 0.5, request: body };
    };
    try {
      const pc = await owner.req('POST', `/v1/recreate/references/${refId}/slots/s3/fill`, { modelId: model.id });
      expect([pc.status, pc.body.code]).toEqual([409, 'price_changed']);
      expect(pc.body.totalUsd).toBeGreaterThan(0);
      expect(pc.body.estimate.seconds).toBeGreaterThanOrEqual(4); // the hosted swap's minimum
      const ok = await owner.req('POST', `/v1/recreate/references/${refId}/slots/s3/fill`, { modelId: model.id, maxUsd: pc.body.totalUsd });
      expect(ok.status, JSON.stringify(ok.body)).toBe(200);
      expect(ok.body.job.request.engine).toBe('replicate');
    } finally { (a.ctx.jobs as any).create = create0; delete (a.ctx.replicate as any).configured; }
    // Every segment made is remembered, re-fills and refused ones included, so all of them go with the reference.
    const rowNow = (await a.ctx.db.select().from((await import('../src/recreate/schema.js')).recreateReferences).where(eq3((await import('../src/recreate/schema.js')).recreateReferences.id, refId)))[0]!;
    expect(rowNow.fill!.clips!.length).toBeGreaterThanOrEqual(4);

    // The segment is the reference's pixels: it goes when the reference does (only the fill part purged here).
    const { recreateReferences } = await import('../src/recreate/schema.js');
    const [row] = await a.ctx.db.select().from(recreateReferences).where(eq3(recreateReferences.id, refId));
    await (recreateOf(a.ctx) as any).purge({ ...row, storageKey: null, contactSheetKey: null, sourceUrl: null, uploadId: null, fill: { jobs: row!.fill!.jobs, clips: row!.fill!.clips } });
    expect(await a.ctx.storage.head(clip!.storageKey!)).toBeFalsy();
    for (const c of row!.fill!.clips!) expect(await a.ctx.storage.head(c.key)).toBeFalsy();
    expect(await a.ctx.db.select().from(clips).where(eq3(clips.id, clip!.id))).toEqual([]);
  }, 60_000);

  it('WS13 model choice: a swap fill on a chosen swap engine, a generate fill on a chosen shot model, a plate model; refused otherwise', async () => {
    const est = (o: object) => owner.req('POST', `/v1/recreate/references/${refId}/slots/s2/estimate`, { modelId: model.id, quality: 'draft', ...o });
    const fast = (await est({ engineModel: 'viggle' })).body;
    expect(fast).toMatchObject({ method: 'swap', request: { engine: 'viggle' }, estimate: { label: 'Fast · beta' } });
    const edit = (await est({})).body;
    expect(fast.estimate.estimate).not.toBe(edit.estimate.estimate); // priced on Fast, not Edit
    const gen = (await est({ engineModel: 'kling-v4', resolution: undefined })).body;
    expect(gen).toMatchObject({ method: 'generate', request: { engineModel: 'kling-v4' } });
    expect(gen.estimate.engine.model).toBe('kling-v4');
    // A non-swap model asked to swap generates the slot on it instead (owner 2026-11-12: every model on every mode).
    const other = await est({ engineModel: 'kling-v4', method: 'swap' });
    expect(other.status, JSON.stringify(other.body)).toBe(200);
    expect(other.body).toMatchObject({ method: 'generate', request: { engineModel: 'kling-v4' } });
    // Fast can't take a new background: own setting with Fast falls back to generating, saying why.
    expect((await est({ engineModel: 'viggle', keepBackground: false })).body.method).toBe('generate');
    // The background plate on a picked image model (owner only).
    await owner.req('PUT', `/v1/recreate/references/${refId}/briefs`, { slots: { s2: { location: 'a neon arcade' } } });
    const plate = (await est({ keepBackground: false, imageModel: 'black-forest-labs/flux-2-dev' })).body;
    expect(plate.background).toMatchObject({ source: 'generated', setting: 'a neon arcade' });
    expect((await est({ keepBackground: false, imageModel: 'not a model' })).body.code).toBe('engine_not_allowed');
  });

  it('pinned rules change Claude\'s plan: cuts only and a still camera; the owner\'s own options in the app win; gaps reported once', async () => {
    const pinRule = async (text: string) => (await owner.req('POST', '/v1/learn/playbook', { text, pinned: true })).body.id;
    const slots = { s1: 't_pan', s3: 't_static' };
    const plain = await tool('apply_recipe').run(env(), { referenceId: refId, sessionId, slots, baseRevision: (await editSessionsOf(a.ctx).row(ownerUser, sessionId)).revision }) as any;
    const p0 = (await editSessionsOf(a.ctx).row(ownerUser, sessionId)).project as M.EditProject;
    expect(plain.playbook).toEqual({ followed: [], followYourself: [] });
    expect((M.mainTrack(p0).items[0] as M.VideoClip).keyframes?.x?.length).toBeGreaterThan(1); // the pan is replayed

    const ids = [await pinRule('Hard cuts only'), await pinRule('Keep the camera still'), await pinRule('Open on her face')];
    const out = await tool('apply_recipe').run(env(), { referenceId: refId, sessionId, slots, options: { camera: true, transitions: true } }) as any;
    expect(out.playbook.followed.map((f: any) => f.effect).sort()).toEqual(['hard cuts only', 'no camera moves']);
    expect(out.playbook.followYourself.map((f: any) => f.text)).toEqual(['Open on her face']);
    const p1 = (await editSessionsOf(a.ctx).row(ownerUser, sessionId)).project as M.EditProject;
    for (const c of M.mainTrack(p1).items as M.VideoClip[]) { expect(c.transitionIn).toBeUndefined(); expect(c.keyframes?.x).toBeUndefined(); }
    // Claude can't add one back afterwards.
    await expect(editSessionsOf(a.ctx).applyClaude(ownerUser, sessionId, { baseRevision: out.revision, ops: [{ op: 'transition', clipId: 'all', kind: 'fade', durationSec: 0.3 }] }))
      .rejects.toMatchObject({ code: 'playbook_rule' });

    // The owner, in the app, asks for the camera moves explicitly: their choice wins over their own rule.
    const app = (await owner.req('POST', `/v1/recreate/references/${refId}/apply`, { sessionId, baseRevision: out.revision, slots, options: { camera: true } })).body;
    expect(app.playbook.followed).toHaveLength(2);
    const p2 = (await editSessionsOf(a.ctx).row(ownerUser, sessionId)).project as M.EditProject;
    expect((M.mainTrack(p2).items[0] as M.VideoClip).keyframes?.x?.length).toBeGreaterThan(1);

    // The flash inside s3 is something the editor can't do: one gap, however many times the recipe is applied.
    const gaps = (await owner.req('GET', '/v1/learn/gaps')).body as any[];
    expect(gaps.find(g => g.key === 'effect:flash-in-shot')).toMatchObject({ count: 1, kind: 'effect' });
    for (const id of ids) await owner.req('DELETE', `/v1/learn/playbook/${id}`);
  });

  it('the playbook tools call the learning editor: read, add a rule (unpinned), report a gap; owner only', async () => {
    const add = await tool('playbook_add').run(env(), { text: 'Captions sit above the lower third on talking shots', area: 'text', evidence: [{ kind: 'note', note: 'Tuff edit' }] }) as any;
    expect(add).toMatchObject({ text: 'Captions sit above the lower third on talking shots', pinned: false });
    await tool('report_gap').run(env(), { key: 'effect:lens-flare', kind: 'effect', what: 'Lens flare', note: 'Tuff edit, s2' });
    const ctx = await tool('playbook_read').run(env(), { referenceId: refId }) as any;
    expect(ctx.playbook.map((r: any) => r.text)).toContain('Captions sit above the lower third on talking shots');
    expect(Object.keys(ctx)).toEqual(expect.arrayContaining(['playbook', 'recipes', 'corrections', 'lessons', 'gaps']));
    expect(JSON.stringify(ctx.gaps)).toContain('effect:lens-flare');
    const memberEnv = { ...env(), user: { ...ownerUser, role: 'member' as const } };
    await expect(tool('playbook_read').run(memberEnv, {})).rejects.toMatchObject({ status: 403 });
  });
});
