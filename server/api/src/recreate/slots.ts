// Recreate this edit · slots (workstream 1, plans/recreate-edit.md "Matching" and "Generating missing shots"): Claude's
// shot briefs, matching each slot to the studio's takes, and the Suite shot that would fill a slot. Pure.
import { z } from 'zod';
import { HEIGHTS, MOVES, SHOT_SIZES } from '../suite/camera.js';
import type { Draft } from '../suite/drafts.js';
import type { Recipe, Slot } from './analyze.js';
import { aspectName } from './analyze.js';

const ids = (l: { id: string }[]) => new Set(l.map(x => x.id));
const SIZE_IDS = ids(SHOT_SIZES), HEIGHT_IDS = ids(HEIGHTS);
/** Framing order, wide → close, for "near enough" scores. */
const SIZE_ORDER = ['els', 'ls', 'full', 'cowboy', 'ms', 'two_shot', 'ots', 'pov', 'mcu', 'cu', 'ecu', 'insert'];

export const BriefSchema = z.object({
  shotSize: z.string().refine(v => SIZE_IDS.has(v), v => ({ message: `unknown shot size "${v}" (${[...SIZE_IDS].join(', ')})` })).optional(),
  angle: z.string().refine(v => HEIGHT_IDS.has(v), v => ({ message: `unknown angle "${v}" (${[...HEIGHT_IDS].join(', ')})` })).optional(),
  subject: z.string().trim().max(200).optional(),
  action: z.string().trim().max(300).optional(),
  location: z.string().trim().max(200).optional(),
  notes: z.string().trim().max(500).optional(),
}).strict();
export type Brief = z.infer<typeof BriefSchema>;

/** Briefs onto a recipe's slots: the brief, and the framing and angle added to the slot's rig. */
export function withBriefs(recipe: Recipe, briefs: Record<string, Brief>): Recipe {
  const unknown = Object.keys(briefs).filter(k => !recipe.slots.some(s => s.id === k));
  if (unknown.length) throw new Error(`no slot ${unknown.join(', ')}`);
  return { ...recipe, slots: recipe.slots.map(s => {
    const b = briefs[s.id];
    if (!b) return s;
    const brief = { ...(s.brief ?? {}), ...b };
    return { ...s, brief, rig: { ...(s.rig ?? {}), ...(brief.shotSize ? { shotSize: brief.shotSize } : {}), ...(brief.angle ? { height: brief.angle } : {}) } };
  }) };
}

export type Candidate = { id: string; modelId: string | null; durationSec: number; width: number; height: number; status: 'test' | 'final'; createdAt: number; draft: Draft | null; title: string };
export type Scored = { takeId: string; score: number; reasons: string[] };

const category = (moveId?: string) => MOVES.find(m => m.id === moveId)?.category;

/**
 * How well a take fits a slot, 0–1, with the reasons: long enough, the right shape, the same move, the same framing
 * and angle (from the take's draft), the chosen lead, kept takes first. Claude makes the final choice.
 */
export function scoreTake(slot: Slot, aspect: string, t: Candidate, o: { leadModelId?: string } = {}): Scored {
  const reasons: string[] = [];
  let s = 0, w = 0;
  const add = (weight: number, v: number, why?: string) => { s += weight * v; w += weight; if (why) reasons.push(why); };
  const len = t.durationSec / Math.max(0.1, slot.durationSec);
  add(3, Math.min(1, len), len >= 1 ? 'long enough' : `${Math.round(len * 100)}% of the slot's length`);
  const shape = aspectName(t.width || 1080, t.height || 1920) === aspect;
  add(2, shape ? 1 : 0.4, shape ? `${aspect}` : 'another shape (it will be cropped)');
  const rig = (t.draft?.rig ?? {}) as Record<string, any>;
  const want = slot.rig?.moves?.[0]?.id, has = rig.moves?.[0]?.id as string | undefined;
  if (want && want !== 'static') add(2, has === want ? 1 : has && category(has) === category(want) ? 0.6 : 0.2, has === want ? `same move (${want})` : has ? `move ${has}` : undefined);
  else if (want === 'static') add(1, !has || has === 'static' ? 1 : 0.4);
  const size = slot.brief?.shotSize;
  if (size && rig.shotSize) {
    const d = Math.abs(SIZE_ORDER.indexOf(size) - SIZE_ORDER.indexOf(rig.shotSize));
    add(2, d === 0 ? 1 : d === 1 ? 0.6 : 0.2, d === 0 ? `same framing (${size})` : undefined);
  }
  if (slot.brief?.angle && rig.height) add(1, rig.height === slot.brief.angle ? 1 : 0.3, rig.height === slot.brief.angle ? `same angle (${rig.height})` : undefined);
  if (o.leadModelId) add(3, t.modelId === o.leadModelId ? 1 : 0, t.modelId === o.leadModelId ? 'your lead' : undefined);
  if (t.status === 'final') add(0.5, 1, 'kept');
  return { takeId: t.id, score: Math.round((s / Math.max(w, 1)) * 1000) / 1000, reasons };
}

/**
 * The best takes for every slot (top `top` each), and a suggested assignment: best first, each take used once, a slot
 * left "to generate" when nothing scores at least `minScore`.
 */
export function matchSlots(recipe: Recipe, takes: Candidate[], o: { leadModelId?: string; top?: number; minScore?: number } = {}) {
  const top = o.top ?? 3, min = o.minScore ?? 0.6;
  const per = recipe.slots.map(slot => ({ slot, list: takes.map(t => scoreTake(slot, recipe.source.aspect, t, o)).sort((a, b) => b.score - a.score) }));
  const pairs = per.flatMap(p => p.list.map(c => ({ slotId: p.slot.id, ...c }))).sort((a, b) => b.score - a.score);
  const assigned: Record<string, string> = {}, usedTakes = new Set<string>();
  for (const p of pairs) {
    if (p.score < min || assigned[p.slotId] || usedTakes.has(p.takeId)) continue;
    assigned[p.slotId] = p.takeId; usedTakes.add(p.takeId);
  }
  return {
    // The suggestion may rank below the top few (each take is used once), so it carries its own score and reasons.
    slots: per.map(p => {
      const sug = assigned[p.slot.id] ? p.list.find(c => c.takeId === assigned[p.slot.id]) ?? null : null;
      return { slotId: p.slot.id, candidates: p.list.slice(0, top), suggested: assigned[p.slot.id] ?? null, suggestion: sug, toGenerate: !assigned[p.slot.id] };
    }),
    assignment: assigned,
  };
}

/** Where a slot's prompt comes from: its brief, else the reference's summary, else a neutral default (no brief yet). */
export function promptSource(recipe: Recipe, slot: Slot): 'brief' | 'summary' | 'default' {
  const b = slot.brief ?? {};
  if ([b.subject, b.action, b.location, b.notes].some(x => (x ?? '').trim())) return 'brief';
  return recipe.summary?.trim() ? 'summary' : 'default';
}
/** The shot's words: the brief's, else the reference's summary, else a neutral line (the framing and move travel separately in `camera`). */
function promptFor(recipe: Recipe, words: string) {
  const w = words || recipe.summary?.trim() || 'The model moves naturally, matching the reference shot';
  const t = `${w.charAt(0).toUpperCase()}${w.slice(1)}`;
  return /[.!?]$/.test(t) ? t : `${t}.`;
}

/** What Suite length a slot needs: whole seconds, at least the tier's minimum (the clip is cut back to the slot). */
export const slotSeconds = (slot: Slot, minSeconds = 2) => Math.max(minSeconds, Math.ceil(slot.durationSec));

/**
 * The Suite shot request that fills a slot: the brief as the prompt, the reference's shape, the framing, angle and move
 * from the slot's rig, long enough for the slot. Pose guidance joins once the pose engine is approved.
 */
export function shotRequestFor(recipe: Recipe, slot: Slot, o: { modelId: string; quality: string; minSeconds?: number; referenceName?: string }) {
  const b = slot.brief ?? {};
  const words = [b.subject, b.action, b.location ? `in ${b.location}` : '', b.notes].map(x => (x ?? '').trim()).filter(Boolean).join(', ');
  const move = slot.rig?.moves?.[0];
  const camera = {
    ...(slot.rig?.shotSize || slot.rig?.height ? { angle: { ...(slot.rig.height ? { height: slot.rig.height } : {}), ...(slot.rig.shotSize ? { shotSize: slot.rig.shotSize } : {}) } } : {}),
    ...(move ? { move: { id: move.id, intensity: move.intensity ?? 0.5 } } : {}),
  };
  const seconds = slotSeconds(slot, o.minSeconds);
  return {
    modelId: o.modelId, quality: o.quality, duration: seconds, aspectRatio: recipe.source.aspect, takes: 1,
    prompt: promptFor(recipe, words),
    title: `${o.referenceName ?? 'Recreate'} · ${slot.id}`,
    ...(Object.keys(camera).length ? { camera } : {}),
    draft: { v: 1, tool: 'shot', quality: o.quality, aspect: recipe.source.aspect, duration: seconds, takes: 1, rig: slot.rig ?? {}, recreate: { slotId: slot.id } },
  };
}
