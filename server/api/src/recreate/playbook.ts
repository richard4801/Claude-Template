// Claude follows the studio's playbook (workstream 1, on workstream 3's learning editor, plans/api.md "Learning
// editor"). The owner's PINNED rules that say something checkable become directives: Recreate's assembly builds within
// them, and any change of Claude's that breaks one is refused (EditSessions.applyClaude). Other rules are handed to
// Claude to follow itself. Rules are matched conservatively: a qualified rule ("no text over faces") is never turned
// into a blanket ban; it is listed for Claude instead.
import { ApiError } from '../errors.js';
import type { AuthUser, Ctx } from '../ctx.js';
import type * as M from '../editor/model.js';
import { learningOf } from '../editor/learn.js';

export type Directives = { speed?: false; camera?: false; text?: false; look?: false; transitions?: false; maxTransitionSec?: number };
export type Rule = { id: string | number; text: string; area?: string | null; pinned: boolean };
export type Followed = { ruleId: string | number; text: string; effect: string };

const NEG = String.raw`(?:no|never(?:\s+(?:use|add))?|don'?t(?:\s+(?:use|add))?|do\s+not(?:\s+(?:use|add))?|avoid|without)`;
const TAIL = String.raw`(?:\s+(?:in|on|for)\s+(?:my|our|the|any)?\s*(?:edits?|videos?|reels?|recreates?|posts?|clips?))?`;
const whole = (nouns: string) => new RegExp(String.raw`^\s*${NEG}\s+(?:any\s+|more\s+)?(?:${nouns})${TAIL}\s*[.!]?\s*$`, 'i');

const RULES: { key: Exclude<keyof Directives, 'maxTransitionSec'>; effect: string; res: RegExp[] }[] = [
  { key: 'speed', effect: 'no speed ramps', res: [whole(String.raw`speed\s+ramps?|speed[- ]?ramping|ramps?|speed\s+changes?|slow[- ]?mo(?:tion)?`),
    /^\s*keep\s+(?:clips\s+at\s+|the\s+)?(?:normal|real[- ]?time|1x)\s+speed\s*[.!]?\s*$/i] },
  { key: 'camera', effect: 'no camera moves', res: [whole(String.raw`camera\s+(?:moves?|motion|movements?)|zooms?|pans?|punch[- ]?ins?|ken\s+burns(?:\s+moves?)?`),
    /^\s*keep\s+(?:the\s+)?(?:camera|frame|shots?)\s+(?:still|static|steady|locked(?:\s+off)?)\s*[.!]?\s*$/i] },
  { key: 'text', effect: 'no on-screen text', res: [whole(String.raw`(?:on[- ]screen\s+)?text|captions?|titles?|subtitles?|text\s+overlays?`)] },
  { key: 'look', effect: 'no looks or grades', res: [whole(String.raw`looks?|luts?|grades?|grading|colou?r\s+grad(?:e|ing)|filters?`),
    /^\s*keep\s+(?:the\s+)?(?:natural|original)\s+colou?rs?\s*[.!]?\s*$/i] },
  { key: 'transitions', effect: 'hard cuts only', res: [whole(String.raw`(?:fancy\s+)?transitions?`),
    /^\s*(?:(?:only\s+)?hard\s+cuts(?:\s+only)?|cuts\s+only|only\s+cuts)\s*[.!]?\s*$/i] },
];
const MAX_TR = /\btransitions?\s+(?:under|shorter\s+than|at\s+most|no\s+longer\s+than|max(?:imum)?(?:\s+of)?|≤|<=|<)\s*(\d+(?:\.\d+)?)\s*(?:s|secs?|seconds?)\b/i;

/** The directives in the owner's pinned rules, which rules gave them, and the pinned rules Claude must follow itself. */
export function directivesOf(rules: Rule[]): { directives: Directives; followed: Followed[]; toFollow: { ruleId: string | number; text: string }[] } {
  const directives: Directives = {}, followed: Followed[] = [], toFollow: { ruleId: string | number; text: string }[] = [];
  for (const r of rules.filter(x => x.pinned)) {
    const text = r.text.replace(/[’‘]/g, "'");
    const hit = RULES.find(x => x.res.some(re => re.test(text)));
    if (hit) { directives[hit.key] = false; followed.push({ ruleId: r.id, text: r.text, effect: hit.effect }); continue; }
    const m = MAX_TR.exec(text);
    if (m) {
      const v = Number(m[1]);
      directives.maxTransitionSec = Math.min(directives.maxTransitionSec ?? Infinity, v);
      followed.push({ ruleId: r.id, text: r.text, effect: `transitions at most ${v} s` });
      continue;
    }
    toFollow.push({ ruleId: r.id, text: r.text });
  }
  return { directives, followed, toFollow };
}

type Item = Record<string, any>;
const itemsOf = (p: M.EditProject) => {
  const m = new Map<string, { kind: string; item: Item }>();
  for (const t of p.tracks) for (const it of t.items as Item[]) m.set(it.id, { kind: t.kind, item: it });
  return m;
};
const same = (a: unknown, b: unknown) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
const CAMERA_PROPS = ['x', 'y', 'scale', 'rotation'];

/** What a change from `before` to `after` does that the directives forbid (only what the change adds or alters). */
export function violations(before: M.EditProject, after: M.EditProject, d: Directives): { key: keyof Directives; what: string }[] {
  const out: { key: keyof Directives; what: string }[] = [];
  const was = itemsOf(before);
  for (const [id, { kind, item }] of itemsOf(after)) {
    const old = was.get(id)?.item;
    if (d.speed === false && item.speedCurve && !same(item.speedCurve, old?.speedCurve)) out.push({ key: 'speed', what: `a speed ramp on ${id}` });
    if (d.camera === false && item.keyframes) {
      const moved = CAMERA_PROPS.filter(k => item.keyframes[k]?.length >= 2 && !same(item.keyframes[k], old?.keyframes?.[k]));
      if (moved.length) out.push({ key: 'camera', what: `a camera move (${moved.join(', ')}) on ${id}` });
    }
    if (d.text === false && (kind === 'text' || kind === 'caption') && !old) out.push({ key: 'text', what: `new text ${id}` });
    if (d.look === false && item.look && !same(item.look, old?.look)) out.push({ key: 'look', what: `a look on ${id}` });
    const tr = item.transitionIn as M.Transition | undefined;
    if (tr && !same(tr, old?.transitionIn)) {
      if (d.transitions === false) out.push({ key: 'transitions', what: `a ${tr.kind} transition into ${id}` });
      else if (d.maxTransitionSec != null && tr.durationSec > d.maxTransitionSec + 1e-6) out.push({ key: 'maxTransitionSec', what: `a ${tr.durationSec} s transition into ${id}` });
    }
  }
  return out;
}

/** The owner's pinned rules as directives (none for members or on any error: the rules are the owner's tool). */
export async function pinnedDirectives(ctx: Ctx, u: AuthUser) {
  if (u.role !== 'owner') return directivesOf([]);
  try { return directivesOf((await learningOf(ctx).playbook(u)).filter(r => r.pinned)); } catch { return directivesOf([]); }
}

/** Refuses a change of Claude's that breaks a pinned rule (409 playbook_rule, naming the rule). */
export async function guardClaudeChange(ctx: Ctx, u: AuthUser, before: M.EditProject, after: M.EditProject) {
  const { directives, followed } = await pinnedDirectives(ctx, u);
  if (!followed.length) return;
  const v = violations(before, after, directives);
  if (!v.length) return;
  const rule = (k: keyof Directives) => followed.find(f => directivesOf([{ id: f.ruleId, text: f.text, pinned: true }]).directives[k] !== undefined);
  const first = v[0]!, r = rule(first.key);
  throw new ApiError(409, 'playbook_rule', `This breaks the owner's pinned rule “${r?.text ?? first.key}”: ${v.map(x => x.what).slice(0, 3).join('; ')}. Leave it out, or ask the owner to change the rule.`);
}

/** What Claude reads before editing: the owner's pinned rules (and which are enforced), other rules, top lessons. */
export async function playbookBrief(ctx: Ctx, u: AuthUser, o: { takeId?: string; referenceId?: string } = {}) {
  if (u.role !== 'owner') return null;
  try {
    const c = await learningOf(ctx).context(u, o) as { playbook: Rule[]; lessons: unknown[]; gaps: unknown[]; recipes: unknown[] };
    const { followed, toFollow } = directivesOf(c.playbook);
    return {
      note: 'The studio\'s playbook. Pinned rules are the owner\'s: follow every one. Changes that break an enforced rule are refused. Read the rest as advice; add what you learn with playbook_add.',
      enforced: followed, followYourself: toFollow, otherRules: c.playbook.filter(r => !r.pinned).slice(0, 8).map(r => ({ id: r.id, text: r.text, area: r.area })),
      lessons: c.lessons.slice(0, 3),
    };
  } catch { return null; }
}

/** How close a proven recipe must be (the learning editor's distance) to start a recreate from it. */
export const START_FROM_MAX_DISTANCE = 0.6;

/**
 * The nearest of the studio's own posted edits to a reference, when it is close enough and has performed (posts with
 * views): its look is used when the reference's own is too far to map. Null when nothing fits.
 */
export async function provenStart(ctx: Ctx, u: AuthUser, referenceId: string) {
  if (u.role !== 'owner') return null;
  try {
    const l = learningOf(ctx);
    const n = (await l.nearest(u, { referenceId, k: 5, origin: 'edit' })).nearest as (Item & { distance: number })[];
    const fit = n.filter(x => x.distance <= START_FROM_MAX_DISTANCE && (x.performance?.posts ?? 0) > 0)
      .sort((a, b) => a.distance - b.distance || (b.performance?.views ?? 0) - (a.performance?.views ?? 0))[0];
    if (!fit) return null;
    const full = await l.recipe(u, fit.id) as Item;
    const look = full.recipe?.grade?.look as { id: string; label?: string } | null | undefined;
    return { recipeId: fit.id as string, name: fit.name as string, distance: fit.distance, tags: fit.tags as string[], performance: fit.performance,
      look: look?.id ? { id: look.id, label: look.label } : null };
  } catch { return null; }
}
