// Recreate this edit · assembly (workstream 1, plans/recreate-edit.md "Rebuilding with our content"): a recipe plus a
// take per slot becomes an ordinary edit project — main-track clips cut to the reference's timing, transitions, speed
// ramps, camera moves as transform keyframes, text, and the Look — so every part stays editable and undoable.
import * as M from '../editor/model.js';
import { lutFor } from '../suite/looks.js';
import type { Recipe, RecipeTransition } from './analyze.js';

export type TakeInfo = { id: string; durationSec: number; width: number; height: number; hasAudio?: boolean;
  /** The take's own action peaks (source seconds), for lining them up with the slot's (find_action_peaks's detector). */
  peaks?: { t: number; strength: number }[] };
export type AssembleOptions = {
  /** Replay the reference's camera moves (pan, zoom, shake) as keyframes on each clip (default true). */
  camera?: boolean;
  /** Apply the reference's speed ramps (default true). */
  speed?: boolean;
  /** Add the reference's text items (default true); words not read yet become "Text". */
  text?: boolean;
  /** Grade every clip with the nearest Look (default true). */
  look?: boolean;
  /** Keep the reference's transitions (default true); false = hard cuts only. */
  transitions?: boolean;
  /** The longest a transition may be (seconds); longer ones are shortened. */
  maxTransitionSec?: number;
  /** Line each take's strongest action peak up with its slot's (default true; needs the takes' peaks). */
  peaks?: boolean;
  /** A palette to grade with when the reference's own look is too far to map (from a proven recipe). */
  fallbackLook?: { id: string; label?: string };
};

const CANVAS: Record<string, [number, number]> = { '9:16': [1080, 1920], '16:9': [1920, 1080], '1:1': [1080, 1080], '4:5': [1080, 1350], '3:4': [1080, 1440], '4:3': [1440, 1080], '21:9': [2520, 1080] };
const r4 = (x: number) => Math.round(x * 10000) / 10000;
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** The editor transition for a recipe transition (cuts and unknown ones get none). */
export function editorTransition(t: RecipeTransition | undefined): M.Transition | undefined {
  if (!t) return undefined;
  const kind: M.TransitionKind | null = t.kind === 'crossfade' ? 'fade' : t.kind === 'fade' ? 'black' : t.kind === 'flash' ? 'white'
    : t.kind === 'whip' ? 'whip' : t.kind === 'zoom' ? 'zoom' : t.kind === 'glitch' ? 'glitch' : null;
  return kind ? { kind, durationSec: r4(clamp(t.durationSec || 0.2, M.LIMITS.minTransitionSec, M.LIMITS.maxTransitionSec)) } : undefined;
}

/** The source range that plays for exactly `len` seconds with this speed curve (binary search on the source length). */
export function rangeFor(inSec: number, len: number, available: number, curve?: M.SpeedCurve): { outSec: number; speed: number; curve?: M.SpeedCurve } {
  if (!curve) {
    if (available - inSec >= len) return { outSec: r4(inSec + len), speed: 1 };
    // A take shorter than its slot plays slower to fill it.
    const speed = clamp((available - inSec) / len, M.LIMITS.minSpeed, 1);
    return { outSec: r4(inSec + len * speed), speed: r4(speed) };
  }
  let lo = 0.05, hi = available - inSec;
  if (M.clipLength({ inSec, outSec: inSec + hi, speedCurve: curve }) < len) return rangeFor(inSec, len, available); // too short for the ramp
  for (let i = 0; i < 40; i++) {
    const mid = (lo + hi) / 2;
    if (M.clipLength({ inSec, outSec: inSec + mid, speedCurve: curve }) < len) lo = mid; else hi = mid;
  }
  return { outSec: r4(inSec + hi), speed: 1, curve };
}

/**
 * Where to start a take so its strongest usable action peak plays at the moment of the slot's strongest peak: the
 * source offset of that moment in the clip's shape (speed and ramp included), and a take peak that leaves the whole
 * range inside the take. 0 when the slot or take has no peak, or none fits.
 */
export function peakInPoint(slot: Recipe['slots'][number], take: TakeInfo, range: { outSec: number; speed: number; curve?: M.SpeedCurve }, offSec: number): number {
  const target = [...(slot.peaks ?? [])].sort((a, b) => b.strength - a.strength)[0];
  if (!target || !take.peaks?.length || range.speed < 1) return 0;
  const shape = { inSec: 0, outSec: range.outSec, speed: range.speed, ...(range.curve ? { speedCurve: range.curve } : {}) };
  const at = M.clipSourceAt(shape, Math.min(offSec + target.t, M.clipLength(shape))); // source seconds from the in-point
  const room = take.durationSec - range.outSec;
  const fit = take.peaks.filter(p => p.t - at >= 0 && p.t - at <= room + 1e-6).sort((a, b) => b.strength - a.strength)[0];
  return fit ? r4(fit.t - at) : 0;
}

/**
 * The project for `recipe` with `takes[slotId]` in each slot. A clip with a transition in starts that much before the
 * previous one ends, so each clip is lengthened by half of each neighbouring transition: transitions stay centred on
 * the reference's boundaries and every cut lands on the reference's time. Slots without a take are left out (listed
 * in `missing`).
 */
export function buildProject(recipe: Recipe, sourceTakeId: string, takes: Record<string, TakeInfo | undefined>, o: AssembleOptions = {}) {
  const [cw, ch] = CANVAS[recipe.source.aspect] ?? [1080, 1920];
  const fps = clamp(Math.round(recipe.source.fps || 30), 24, 60);
  const assets: M.Asset[] = [];
  const assetOf = (t: TakeInfo) => {
    let a = assets.find(x => x.take === t.id);
    if (!a) { a = { id: `a${assets.length + 1}`, kind: 'video', take: t.id, durationSec: t.durationSec, width: t.width, height: t.height, hasAudio: t.hasAudio ?? true }; assets.push(a); }
    return a;
  };
  const used = recipe.slots.filter(s => takes[s.id]);
  const missing = recipe.slots.filter(s => !takes[s.id]).map(s => s.id);
  const trIn0 = (slotId: string, prev?: string) => recipe.transitions.find(t => t.to === slotId && t.from === prev && t.from !== t.to);
  // Playbook directives (workstream 1): cuts only, or transitions no longer than a limit.
  const trIn = (slotId: string, prev?: string) => {
    const t = trIn0(slotId, prev);
    if (!t || o.transitions === false) return undefined;
    return o.maxTransitionSec != null ? { ...t, durationSec: Math.min(t.durationSec || 0.2, o.maxTransitionSec) } : t;
  };
  const ownLook = recipe.grade.look && recipe.grade.look.distance < 0.4 ? recipe.grade.look.id : null;
  const lutId = o.look === false ? null : ownLook ? lutFor('palettes', ownLook) : o.fallbackLook ? lutFor('palettes', o.fallbackLook.id) : null;
  const notes: string[] = [];

  const clips: M.VideoClip[] = used.map((s, i) => {
    const t = takes[s.id]!;
    const into = i > 0 ? editorTransition(trIn(s.id, used[i - 1]!.id)) : undefined;
    const next = used[i + 1] ? editorTransition(trIn(used[i + 1]!.id, s.id)) : undefined;
    const len = s.durationSec + (into ? into.durationSec / 2 : 0) + (next ? next.durationSec / 2 : 0);
    const curve = o.speed !== false && s.speed.ramp !== 'none' && s.speed.ramp !== 'freeze' && s.speed.curve.length >= 2
      ? { preset: 'custom' as const, points: s.speed.curve.map(p => [r4(clamp(p.t / Math.max(s.durationSec, 0.001), 0, 1)), r4(clamp(p.speed, 0.25, 4))] as [number, number]) }
      : undefined;
    if (curve) { curve.points[0]![0] = 0; curve.points[curve.points.length - 1]![0] = 1; }
    const r = rangeFor(0, len, t.durationSec, curve);
    if (r.speed < 1) notes.push(`${s.id}: the take is shorter than the slot, so it plays at ${Math.round(r.speed * 100)}%`);
    // Plan §3 "action peaks snap to the beat": start the take so its own strongest peak plays when the slot's does.
    const inSec = o.peaks === false ? 0 : peakInPoint(s, t, r, into ? into.durationSec / 2 : 0);
    if (inSec > 0) notes.push(`${s.id}: starts ${inSec.toFixed(2)} s into the take, so its action lands on the reference's`);
    const clip: M.VideoClip = { id: `c${i + 1}`, asset: assetOf(t).id, inSec, outSec: r4(inSec + r.outSec), speed: r.speed, ...(r.curve ? { speedCurve: r.curve } : {}),
      ...(into ? { transitionIn: into } : {}), ...(lutId ? { look: { lut: lutId, strength: 0.8 } } : {}) };
    // The reference's camera move, replayed by moving and scaling the clip (the frame stays covered).
    const keys = s.camera.keys;
    if (o.camera !== false && keys.length >= 2 && s.camera.motion !== 'static' && s.camera.motion !== 'mixed') {
      const off = into ? into.durationSec / 2 : 0;
      const last = keys.at(-1)!;
      const X = last.x, Y = last.y;
      const base = s.camera.motion === 'shake' ? 1.08 : clamp(1 + Math.max(Math.abs(X), Math.abs(Y)), 1, 2);
      const step = Math.max(1, Math.ceil(keys.length / 40));
      const pick = keys.filter((_, k) => k % step === 0 || k === keys.length - 1);
      const kf = (f: (k: (typeof keys)[number]) => number) => pick.map(k => ({ t: r4(off + k.t), v: r4(f(k)), ease: 'linear' as const }));
      clip.keyframes = {
        x: kf(k => 0.5 + k.x - X / 2), y: kf(k => 0.5 + k.y - Y / 2),
        scale: kf(k => clamp(base * k.scale, 0.05, 10)),
      };
    }
    return clip;
  });

  const tracks: M.Track[] = [{ id: 'main', kind: 'main', items: clips }];
  if (o.text !== false && recipe.text.length) {
    const firstStart = used[0]?.startSec ?? 0;
    tracks.push({ id: 'text', kind: 'text', items: recipe.text.map((x, i): M.TextItem => ({
      id: `x${i + 1}`, startSec: r4(Math.max(0, x.startSec - firstStart)), durationSec: r4(Math.max(M.LIMITS.minItemSec, x.endSec - x.startSec)),
      text: x.words?.trim() || 'Text',
      style: { font: 'sans', weight: 900, sizePct: r4(clamp(x.sizeFrac, 0.015, 0.25)), color: x.color, align: 'center', maxWidthPct: r4(clamp(x.box.w + 0.05, 0.1, 1)),
        ...(x.color === '#FFFFFF' ? { stroke: { color: '#000000', widthPct: 0.08 } } : {}) },
      transform: { x: r4(x.box.x + x.box.w / 2), y: r4(x.box.y + x.box.h / 2) },
    })) });
    if (recipe.text.some(x => !x.words)) notes.push('Text the analysis couldn’t read says "Text": change the words');
  }
  const project: M.EditProject = { version: 2, sourceTakeId, canvas: { width: cw, height: ch, fps, background: '#000000' }, assets, tracks };
  return { project, missing, notes, durationSec: M.durationSec(project) };
}
