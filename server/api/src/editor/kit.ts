// Style kits (plans/edit-parity.md, M "Save your own edit as a template / style kit"): an edit's look, colour,
// transition, caption and text styles and canvas background, saved by name and applied to another edit. Pure and
// shared: Android (core Kit.kt) and the Mac match kitOf / applyKit / validateKit through functions.json → kits.
import * as M from './model.js';
import type { Look } from './look.js';
import { CAPTION_STYLES, HOOKS } from './presets.js';

export type StyleKit = {
  version: 1;
  look?: Look; filter?: M.FilterRef; adjust?: M.Adjust;
  transition?: M.Transition;
  captionStyle?: M.CaptionStyle; textStyle?: M.TextStyle;
  background?: string; fill?: 'color' | 'blur';
};
export const KIT_KEYS = ['version', 'look', 'filter', 'adjust', 'transition', 'captionStyle', 'textStyle', 'background', 'fill'] as const;

const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v)) as T;
const portableLut = (lut?: string) => !lut || lut.startsWith('pack:') || lut.startsWith('palette:');

/**
 * The style of [p] as a kit: the first main clip's look (a LUT only when it's a pack or palette look, since an
 * uploaded .cube belongs to its edit), filter and adjust (no keyframes); the first transition; the caption style; the
 * first text item's style; the canvas background and fill. Absent parts are left out.
 */
export function kitOf(p: M.EditProject): StyleKit {
  const main = M.mainTrack(p).items as M.VideoClip[];
  const c = main[0];
  const kit: StyleKit = { version: 1 };
  if (c?.look) {
    const look = clone(c.look);
    if (!portableLut(look.lut)) { delete look.lut; delete look.strength; }
    if (Object.keys(look).length) kit.look = look;
  }
  if (c?.filter) kit.filter = clone(c.filter);
  if (c?.adjust && Object.keys(c.adjust).length) kit.adjust = clone(c.adjust);
  const tr = main.find(x => x.transitionIn)?.transitionIn;
  if (tr) kit.transition = clone(tr);
  const cap = p.tracks.find(t => t.kind === 'caption' && t.caption)?.caption?.style;
  if (cap) kit.captionStyle = clone(cap);
  const txt = p.tracks.find(t => t.kind === 'text' && t.items.length)?.items[0] as M.TextItem | undefined;
  if (txt) kit.textStyle = clone(txt.style);
  if (p.canvas.background !== undefined) kit.background = p.canvas.background;
  if (p.canvas.fill !== undefined) kit.fill = p.canvas.fill;
  return kit;
}

/**
 * [kit] applied to [p] (a new project): every main clip takes the kit's look, filter and adjust (their keyframes stay);
 * every cut gets the kit's transition, at most half of each clip beside it (cuts too short for 0.1 s stay cuts); the
 * caption track (when there is one) and every text item take the kit's styles (their words and text stay); the canvas
 * takes its background and fill. Parts the kit leaves out are left as they are.
 */
export function applyKit(p: M.EditProject, kit: StyleKit): M.EditProject {
  const q = clone(p);
  const main = M.mainTrack(q).items as M.VideoClip[];
  for (const c of main) {
    if (kit.look !== undefined) c.look = clone(kit.look);
    if (kit.filter !== undefined) c.filter = clone(kit.filter);
    if (kit.adjust !== undefined) c.adjust = clone(kit.adjust);
  }
  if (kit.transition) {
    for (let i = 1; i < main.length; i++) {
      const d = Math.floor(Math.min(kit.transition.durationSec, M.clipLength(main[i]!) / 2, M.clipLength(main[i - 1]!) / 2) * 1000) / 1000;
      if (d >= M.LIMITS.minTransitionSec) main[i]!.transitionIn = { kind: kit.transition.kind, durationSec: d };
    }
  }
  for (const t of q.tracks) {
    if (t.kind === 'caption' && t.caption && kit.captionStyle) t.caption.style = clone(kit.captionStyle);
    if (t.kind === 'text' && kit.textStyle) for (const it of t.items as M.TextItem[]) it.style = clone(kit.textStyle);
  }
  if (kit.background !== undefined) q.canvas.background = kit.background;
  if (kit.fill !== undefined) q.canvas.fill = kit.fill;
  return q;
}

/** A small valid edit every part of a kit lands on, for [validateKit]. */
const PROBE: M.EditProject = {
  version: 2, sourceTakeId: 'kit', canvas: { width: 1080, height: 1920, fps: 30 },
  assets: [{ id: 'v', kind: 'video', take: 'kit', durationSec: 10, width: 1080, height: 1920, hasAudio: true }],
  tracks: [
    { id: 'main', kind: 'main', items: [{ id: 'c1', asset: 'v', inSec: 0, outSec: 4, speed: 1 }, { id: 'c2', asset: 'v', inSec: 4, outSec: 8, speed: 1 }] },
    { id: 'txt', kind: 'text', items: [{ id: 't1', startSec: 0, durationSec: 2, text: 'Kit', style: HOOKS[0]!.style }] },
    { id: 'cap', kind: 'caption', items: [], caption: { asset: 'v', words: [{ text: 'kit', startSec: 0, endSec: 0.5 }], style: CAPTION_STYLES.pop } },
  ],
} as unknown as M.EditProject;

/** Where each probe path came from in the kit. */
const FIELD_MAP: [RegExp, string][] = [
  [/^edits\.tracks\.0\.items\.\d+\.transitionIn/, 'kit.transition'],
  [/^edits\.tracks\.0\.items\.\d+\.(look|filter|adjust)/, 'kit.$1'],
  [/^edits\.tracks\.1\.items\.0\.style/, 'kit.textStyle'],
  [/^edits\.tracks\.2\.caption\.style/, 'kit.captionStyle'],
  [/^edits\.canvas\.(background|fill)/, 'kit.$1'],
];

/**
 * Checks a kit (throws [M.EditProblem] with a `kit.…` field): an object of the known keys at version 1, a transition
 * of a known kind at 0.1–2 s, and every other part valid where it lands (the edit rules, on a small probe edit).
 */
export function validateKit(kit: unknown, presets: M.FilterPreset[] = [], lookIds: Set<string> = new Set(), paletteIds: Set<string> = new Set()): StyleKit {
  const bad = (f: string, m: string): never => { throw new M.EditProblem(f, m); };
  if (!kit || typeof kit !== 'object' || Array.isArray(kit)) bad('kit', 'must be an object');
  const k = kit as Record<string, unknown>;
  for (const key of Object.keys(k)) if (!(KIT_KEYS as readonly string[]).includes(key)) bad(`kit.${key}`, 'is not part of a style kit');
  if (k.version !== 1) bad('kit.version', 'must be 1');
  const tr = k.transition as M.Transition | undefined;
  if (tr !== undefined) {
    if (!tr || typeof tr !== 'object' || !M.TRANSITIONS.includes(tr.kind)) bad('kit.transition.kind', 'unknown transition');
    if (typeof tr.durationSec !== 'number' || !(tr.durationSec >= M.LIMITS.minTransitionSec && tr.durationSec <= M.LIMITS.maxTransitionSec))
      bad('kit.transition.durationSec', `must be a number from ${M.LIMITS.minTransitionSec} to ${M.LIMITS.maxTransitionSec}`);
  }
  if (typeof k.look === 'object' && k.look && !portableLut((k.look as Look).lut)) bad('kit.look.lut', 'a kit can only carry a pack or palette look');
  try {
    M.validate(applyKit(PROBE, k as StyleKit), presets, lookIds, paletteIds);
  } catch (e) {
    if (!(e instanceof M.EditProblem)) throw e;
    const m = FIELD_MAP.find(([re]) => re.test(e.field));
    throw new M.EditProblem(m ? e.field.replace(m[0], m[1]) : 'kit', e.message.slice(e.field.length + 2));
  }
  return k as StyleKit;
}
