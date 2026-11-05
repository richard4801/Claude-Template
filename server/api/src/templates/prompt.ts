// Template prompts (plans/templates.md): the template's hidden layers + the model's identity, outfit and never-add +
// one draw from each variation-pool slot (or the user's direction) + a seed. Two views of the same prompt are built:
// `full` (what the image engine gets, and what the template's owner may see) and `visible` (everyone else: one locked
// "Template: <name>" line in place of the hidden layers).
import { neverList, sanitizeDirection, seedFor, type Identity, type OutfitSpec, type SentRef } from '../prompt/engine.js';
import { templateViews } from '../prompt/scripts/builders.js';
import { DEFAULT_TEXTS, type PromptTexts } from '../prompt/library.js';
import { POOL_SLOTS, type PoolSlot, type TemplateLayers, type VariationDraw, type VariationPool } from '../db/schema.js';

export type TemplateSlot = { layer: string; text: string; locked?: true };
export type TemplatePromptBuild = {
  full: TemplateSlot[]; visible: TemplateSlot[]; fullText: string; visibleText: string;
  seed: number | null; variation: VariationDraw; removed: string[];
};

/** Small deterministic RNG (mulberry32), so a shuffleSeed always gives the same draws. */
export function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
export const randomSeed = () => Math.floor(Math.random() * 2 ** 31);
export const randomImageSeed = () => Math.floor(Math.random() * 1_000_000);

/** One option per non-empty slot. A direction replaces the pose and body-angle draws. Still `index` gets its own draws. */
export function drawVariation(pool: VariationPool, shuffleSeed: number, index = 0, direction?: string): VariationDraw {
  const r = rng((shuffleSeed ^ Math.imul(index + 1, 0x9e3779b1)) >>> 0);
  const out: VariationDraw = {};
  for (const slot of POOL_SLOTS) {
    const opts = (pool[slot] ?? []).map(s => s.trim()).filter(Boolean);
    const pick = opts.length ? opts[Math.floor(r() * opts.length)]! : undefined; // always advance the RNG the same way
    if (direction && (slot === 'pose' || slot === 'bodyAngle')) continue;
    if (pick) out[slot] = pick;
  }
  if (direction) out.direction = direction;
  return out;
}

const dot = (s: string) => { const t = s.trim(); return !t ? '' : /[.!?]$/.test(t) ? t : `${t}.`; };
const join = (...parts: (string | undefined)[]) => parts.map(p => (p ?? '').trim().replace(/[.;,]+$/, '')).filter(Boolean).join('; ');


export function buildTemplatePrompt(o: {
  templateId: string; templateName: string; layers: TemplateLayers; pool: VariationPool;
  identity: Identity; outfit: OutfitSpec | null; direction?: string | null; shuffleSeed: number; index?: number;
  lockSeed?: boolean; seed?: number; hasProduct?: boolean;
  /** Reference images that were sent (their lines show in both views). */
  refs?: SentRef[];
}, t: PromptTexts = DEFAULT_TEXTS): TemplatePromptBuild {
  // Prompt scripts: the words are drawn here; the script `template` (prompt/scripts/defs.ts) assembles both views.
  const { clean: dir, removed } = sanitizeDirection(o.direction, o.identity, t);
  const v = drawVariation(o.pool, o.shuffleSeed, o.index ?? 0, dir || undefined);
  const L = o.layers;
  const id = o.identity;
  const seed = o.lockSeed ? seedFor(`${o.templateId}:${id.name}`) : (o.seed ?? null);
  const never = neverList(id, t);
  const views = templateViews({
    identity: id, outfit: o.outfit, templateName: o.templateName, refs: o.refs, direction: dir ? dot(dir) : '',
    scene: join(L.scene, v.background, v.timeOfDay), camera: join(L.camera, v.framing), light: L.light ? join(L.light) : '',
    pose: join(v.pose, v.bodyAngle, v.expression, v.hands), product: L.product ? { words: join(L.product), photo: !!o.hasProduct } : null,
    style: join(L.style, t['style.house']), neverFull: [...never, ...(L.negative ? [L.negative.trim().replace(/\.$/, '')] : [])], neverVisible: never,
    seed: { mode: o.lockSeed ? 'locked' : seed != null ? 'known' : 'none', value: seed },
  }, t);
  return { ...views, seed, variation: v, removed };
}

// ------------------------------------------------------------------------------------------------ suggested pools
type Rule = { match: RegExp; pool: VariationPool };
const RULES: Rule[] = [
  { match: /mirror|selfie/i, pool: {
    pose: ['phone held up covering the face', 'phone held low at the chest, face visible over it', 'one hip popped, phone at eye level', 'leaning a shoulder on the door frame'],
    bodyAngle: ['three-quarter turn to the mirror', 'square to the mirror', 'side-on, looking at the screen'],
    framing: ['full length in the mirror', 'mirror cropped at the knees', 'tight on the torso and phone'],
    hands: ['free hand tugging the hem', 'free hand in her hair', 'free hand resting on the sink'],
    background: ['unmade bed in the corner', 'clothes on a chair', 'a bathroom shelf with bottles'] } },
  { match: /motion|blur|drag/i, pool: {
    pose: ['turning her head quickly', 'mid-laugh, head tipping back', 'spinning round towards the camera'],
    bodyAngle: ['three-quarter to camera', 'side-on, head turning back'],
    framing: ['waist up', 'head and shoulders', 'three-quarter length'] } },
  { match: /sun|close-?up|harsh|shadow/i, pool: {
    pose: ['chin lifted to the sun', 'eyes half closed against the light', 'looking just past the lens'],
    framing: ['extreme close-up, cropped at the forehead', 'lips and jaw only', 'one eye and cheek, very tight'],
    expression: ['squinting slightly', 'soft, lips parted', 'small closed-mouth smile'] } },
  { match: /low.?light|moody|night|dark/i, pool: {
    pose: ['sitting on the edge of the bed', 'leaning on a window frame', 'curled on a sofa'],
    expression: ['distant, unsmiling', 'tired half smile', 'eyes down'],
    background: ['a lamp glowing out of focus', 'city lights through the window', 'a TV glow off frame'] } },
  { match: /reflect|glass|water|puddle/i, pool: {
    pose: ['leaning over the surface', 'crouched beside it', 'standing with her reflection below her'],
    framing: ['subject top, reflection bottom', 'reflection only, subject cropped out at the top', 'off-centre, reflection on the right'],
    background: ['a wet street', 'a glossy car roof', 'a shop window'] } },
  { match: /product|bottle|hold/i, pool: {
    pose: ['product held up next to the cheek', 'product in hand at the hip', 'applying it'],
    framing: ['product sharp in the foreground, her face soft behind', 'hand and product only, her body cropped', 'product on a surface, her hand entering'],
    hands: ['fingertips around the cap', 'product resting on the palm', 'both hands holding it'] } },
  { match: /pov|candid|hands entering/i, pool: {
    pose: ['reaching for the camera', 'walking ahead, glancing back', 'sitting across a café table'],
    framing: ['off-centre left, lots of space', 'tilted horizon', 'cut at the chin'],
    hands: ['the photographer’s hand entering frame', 'her hand covering part of the lens', 'holding a drink towards the lens'] } },
];
const GENERIC: VariationPool = {
  pose: ['weight on one leg, relaxed', 'mid-step', 'sitting, legs crossed', 'leaning on a wall'],
  bodyAngle: ['three-quarter to camera', 'facing camera', 'side profile'],
  framing: ['full body', 'three-quarter length', 'waist up'],
  expression: ['easy smile', 'neutral, looking away', 'laughing'],
  hands: ['one hand in her hair', 'hands in pockets', 'adjusting her sleeve'],
  timeOfDay: ['early in that light', 'late in that light'],
};

/** A variation pool suggested from a template's style words; the creator can edit it. */
export function suggestPool(layers: TemplateLayers, name = ''): VariationPool {
  const text = [name, layers.style, layers.scene, layers.camera, layers.light, layers.product].filter(Boolean).join(' ');
  const out: VariationPool = {};
  for (const r of RULES) if (r.match.test(text)) for (const s of POOL_SLOTS) if (r.pool[s] && !out[s]) out[s] = [...r.pool[s]!];
  for (const s of POOL_SLOTS) if (!out[s] && GENERIC[s] && (s === 'pose' || s === 'bodyAngle' || s === 'framing' || s === 'expression')) out[s] = [...GENERIC[s]!];
  return out;
}

export function cleanPool(p: VariationPool | null | undefined): VariationPool {
  const out: VariationPool = {};
  for (const s of POOL_SLOTS) {
    const v = (p?.[s] ?? []).map(x => String(x).trim()).filter(Boolean).slice(0, 12);
    if (v.length) out[s] = v;
  }
  return out;
}
export const poolIsEmpty = (p: VariationPool) => POOL_SLOTS.every(s => !p[s]?.length);
export type { PoolSlot };
