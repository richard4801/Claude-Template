// Every prompt the server sends, built by its script (plans/prompt-scripts.md §3). Same signatures and results as the
// builders in engine.ts / templates/prompt.ts / service.ts had, so callers don't change; the texts object they pass
// (PromptLibrary.texts) also carries the studio's rules (withRules), so owner rule edits reach every builder.
import { DEFAULT_TEXTS, fill, listOf, type PromptTexts } from '../library.js';
import {
  cameraValues, imageRange, neverList, panelSpan, SHOOT_GUIDES, type SheetPanel, sanitizeDirection, seedFor, shootChoices, SHEET_ANGLES,
  type BuiltPrompt, type H3Prompt, type Identity, type LayerKey, type OutfitSpec, type PromptSlot, type ReplicateSwapSpec, type SentRef, type SheetAngle, type ShootSpec, type VideoSwapSpec,
} from '../engine.js';
import { SCRIPT_BLOCK_DEFS } from './blocks.js';
import { scriptDef } from './defs.js';
import { runScript } from './run.js';
import type { Inputs, Rule, ScriptResult } from './types.js';

// ---------------------------------------------------------------- texts + rules
const RULES = Symbol.for('muse.promptRules');
type WithRules = PromptTexts & { [RULES]?: Record<string, Rule[]> };
const BLOCK_DEFAULTS: PromptTexts = Object.fromEntries(SCRIPT_BLOCK_DEFS.map(d => [d.key, d.default]));
/** The texts with the studio's rules attached (not enumerable: spreading the texts drops them, so builders fall back to the defaults). */
export function withRules(texts: PromptTexts, rules: Record<string, Rule[]>): PromptTexts {
  const t = { ...texts };
  Object.defineProperty(t, RULES, { value: rules, enumerable: false });
  return t;
}
export const rulesOf = (t: PromptTexts, scriptId: string): Rule[] | undefined => (t as WithRules)[RULES]?.[scriptId];
/** Runs script `id` with the studio's texts (plus the defaults of blocks a saved library may not have yet) and rules. */
export function run(id: string, t: PromptTexts, o: { inputs: Inputs; vars?: Record<string, string | number | null | undefined>; direction?: string | null }): ScriptResult {
  const s = scriptDef(id);
  if (!s) throw new Error(`Unknown prompt script ${id}`);
  return runScript(s, { inputs: o.inputs, vars: o.vars, user: { direction: o.direction }, texts: { ...BLOCK_DEFAULTS, ...t }, rules: rulesOf(t, id) });
}

const trimEndChars = (s: string, chars: string) => { let e = s.length; while (e > 0 && chars.includes(s[e - 1]!)) e--; return s.slice(0, e); };
const refCount = (id: Identity) => id.referenceCount ?? 6;
/**
 * The house style (script `style.house`): Camera feel unless the shot has a camera of its own, then Realism, as one
 * comma-separated phrase. Sheet fills and outfit sets never have their own camera, so they always get both.
 */
export function houseStyle(t: PromptTexts = DEFAULT_TEXTS, ownCamera = false) {
  return run('style.house', t, { inputs: { ownCamera } }).parts.map(p => p.text.trim().replace(/[.,;\s]+$/, '')).filter(Boolean).join(', ');
}
const idVars = (id: Identity, t: PromptTexts, ownCamera = false) => ({
  name: id.name, look: id.look, refCount: refCount(id), lora: id.lora ? ` + LoRA ${id.lora} (photo)` : '',
  style: houseStyle(t, ownCamera), never: neverList(id, t).join(', '),
});
const outfitSource = (o: OutfitSpec | null | undefined) => (o?.source === 'described' ? 'described' : o?.source === 'product-photo' ? 'product' : 'set');
const outfitVar = (o: OutfitSpec) => (o.source === 'described' ? trimEndChars((o.description ?? o.name).trim(), '.') : o.name.toLowerCase());
const refItems = (refs: SentRef[] | undefined) => (refs ?? []).map(r => ({ refIndex: r.index, guides: r.guides }));
const slots = (r: ScriptResult): PromptSlot[] => r.parts.map(p => ({ layer: p.layer as LayerKey, text: p.text }));
const built = (r: ScriptResult, seed: number | null, removed: string[]): BuiltPrompt => ({ slots: slots(r), seed, removed, text: r.text });

// ---------------------------------------------------------------- photos
export function photoshoot(s: ShootSpec, t: PromptTexts = DEFAULT_TEXTS): BuiltPrompt {
  const { clean: dir, removed } = sanitizeDirection(s.direction, s.identity, t);
  const c = shootChoices(s, t);
  const cam = cameraValues(c.camera, t);
  const r = run('photoshoot', t, {
    inputs: { presets: s.presets !== false, lockSeed: !!s.lockSeed, outfitSource: outfitSource(s.outfit), lens: c.camera.lensMm, refs: refItems(s.refs),
      ownCamera: c.ownCamera, noGrade: !c.grade },
    vars: { ...idVars(s.identity, t, c.ownCamera), outfit: outfitVar(s.outfit), scene: c.scene.toLowerCase(), shot: cam.shot, lens: cam.lens, aperture: cam.aperture,
      light: c.light.toLowerCase(), grade: c.grade.toLowerCase() },
    direction: dir,
  });
  return built(r, s.lockSeed ? seedFor(s.identity.name) : null, removed);
}

export function characterSheetShot(id: Identity, angle: SheetAngle, t: PromptTexts = DEFAULT_TEXTS): BuiltPrompt {
  const r = run('sheet', t, { inputs: { angle: angle.key }, vars: { ...idVars(id, t), angle: angle.label.toLowerCase(), framing: angle.framing } });
  return built(r, null, []);
}
/** A LoRA candidate: the sheet image plus variation `n`. */
export function loraCandidate(id: Identity, angle: SheetAngle, n: number, t: PromptTexts = DEFAULT_TEXTS): BuiltPrompt {
  const l = listOf(t['lora.variations'] ?? '', 'lines'), v = l.length ? l : listOf(DEFAULT_TEXTS['lora.variations']!, 'lines');
  const r = run('lora.candidate', t, { inputs: { angle: angle.key }, vars: { ...idVars(id, t), angle: angle.label.toLowerCase(), framing: angle.framing, variation: v[n % v.length] } });
  return built(r, null, []);
}

export function outfitAngle(id: Identity, outfit: OutfitSpec, angle: { label: string; words: string }, seed: number, t: PromptTexts = DEFAULT_TEXTS): BuiltPrompt {
  const never = { ...id, neverAdd: [...(id.neverAdd ?? []), ...listOf(t['outfit.never.extra'] ?? '')] };
  const key = ({ Front: 'front', '¾': 'tq', Side: 'side', Back: 'back' } as Record<string, string>)[angle.label] ?? 'front';
  const r = run('outfit.angle', t, { inputs: { outfitSource: outfitSource(outfit), angle: key },
    vars: { ...idVars(never, t), outfit: outfitVar(outfit), angle: angle.words, seed } });
  return built(r, seed, []);
}
export const outfitEditPrompt = (angle: { words: string }, t: PromptTexts = DEFAULT_TEXTS) => run('outfit.edit', t, { inputs: {}, vars: { angle: angle.words } }).text;
export const enhancePrompt = (t: PromptTexts = DEFAULT_TEXTS) => run('enhance', t, { inputs: {} }).text;

// ---------------------------------------------------------------- template shoots
export type TemplateParts = {
  identity: Identity; outfit: OutfitSpec | null; templateName: string; refs?: SentRef[]; direction: string;
  scene: string; camera: string; light: string; pose: string; product: { words: string; photo: boolean } | null; style: string;
  neverFull: string[]; neverVisible: string[]; seed: { mode: 'locked' | 'known' | 'none'; value: number | null };
  /** The template's camera or style names a camera of its own (templates/prompt.ts templateOwnCamera). Informational:
   *  `style` already holds the house style built for it. */
  ownCamera?: boolean;
};
/** Both views of a template shoot. Slots carry `locked: true` on the line members see in place of the hidden layers. */
export function templateViews(p: TemplateParts, t: PromptTexts = DEFAULT_TEXTS) {
  const common = {
    outfitSource: !p.outfit ? 'none' : p.outfit.source === 'described' ? 'described' : 'set',
    hasScene: !!p.scene, hasCamera: !!p.camera, hasLight: !!p.light, hasPose: !!p.pose,
    product: !p.product ? 'none' : p.product.photo ? 'photo' : 'noPhoto', seed: p.seed.mode, refs: refItems(p.refs), ownCamera: !!p.ownCamera,
  };
  const vars = { ...idVars(p.identity, t), outfit: p.outfit ? (p.outfit.source === 'described' ? trimEndChars((p.outfit.description ?? p.outfit.name).trim(), '.') : p.outfit.name.toLowerCase()) : '',
    scene: p.scene, camera: p.camera, light: p.light, pose: p.pose, product: p.product?.words ?? '', style: p.style, seed: p.seed.value, name: p.identity.name };
  const view = (v: 'full' | 'visible', never: string[]) => {
    const r = run('template', t, { inputs: { ...common, view: v }, vars: { ...vars, never: never.join(', ') }, direction: p.direction });
    // {name} is her name in the identity line and the template's name in the locked line.
    const out = r.parts.map(x => x.section === 'template'
      ? { layer: 'template', text: fill(t['template.locked'] ?? '', { name: p.templateName }).trim(), locked: true as const }
      : { layer: x.layer, text: x.text });
    return out.filter(x => x.text);
  };
  const full = view('full', p.neverFull), visible = view('visible', p.neverVisible);
  return { full, visible, fullText: full.map(s => s.text).join('\n'), visibleText: visible.map(s => s.text).join('\n') };
}

// ---------------------------------------------------------------- video: character swap
/** The structured Edit prompt. `speaking` false adds the mouth line (no lip-sync). */
export function videoSwap(v: VideoSwapSpec & { speaking?: boolean }, t: PromptTexts = DEFAULT_TEXTS): H3Prompt {
  const id = v.identity;
  const n = v.referenceLabels?.length ? Math.min(6, v.referenceLabels.length) : Math.min(6, Math.max(1, refCount(id)));
  const keepAudio = v.keepAudio ?? true, keepBackground = v.keepBackground ?? true, speaking = v.speaking ?? true;
  const perf = { description: 'the person', tattoos: false, rings: false, setting: 'the room', ...v.performer };
  const labels = v.referenceLabels?.length ? v.referenceLabels.slice(0, n) : SHEET_ANGLES.slice(0, n).map(a => a.label.toLowerCase().replace(' · ', ', '));
  const refs = labels.map((l, i) => `<Image ${i + 1}> (${l})`);
  const refList = refs.length === 1 ? refs[0]! : refs.slice(0, -1).join(', ') + ' and ' + refs[refs.length - 1];
  const extras = [perf.tattoos && 'tattoos', perf.rings && 'rings'].filter(Boolean) as string[];
  const clean = [perf.tattoos && "None of <Subject 1>'s tattoos remain.", perf.rings && "None of <Subject 1>'s rings remain."].filter(Boolean).join(' ');
  const { clean: dir, removed } = sanitizeDirection(v.direction, id, t);
  const r = run('video.edit', t, {
    inputs: { speaking, keepAudio, keepBackground },
    vars: { performer: perf.description + (extras.length ? ` with ${extras.join(' and ')}` : ''), setting: perf.setting, name: id.name, look: id.look, refs: refList,
      lora: id.lora ? `, with LoRA ${id.lora} video` : '', motion: v.backgroundMotion ? ` (${v.backgroundMotion})` : '',
      tattoos: perf.tattoos ? 'tattoos, ' : '', clean: clean ? ` ${clean}` : '', n, outfit: v.outfit.name.toLowerCase(), never: neverList(id, t).join(', no ') },
    direction: dir,
  });
  const part = (s: string) => r.parts.filter(p => p.section === s).map(p => p.text).join('\n');
  return { subjectDefinitions: part('subjects'), summary: part('summary'), retentionAnalysis: part('retention'),
    detailedDescription: [part('detailed'), part('user')].filter(Boolean).join('\n'),
    audioMode: keepAudio ? 'fully_copy' : 'replace', steps: v.steps ?? 10, seed: v.seed ?? 42, removed, text: r.text };
}

/** The short prompt for the hosted model. `speaking` false: the clip goes without audio, so no lip-sync wording. */
export function replicateSwap(v: ReplicateSwapSpec & { speaking?: boolean }, t: PromptTexts = DEFAULT_TEXTS): { text: string; removed: string[] } {
  const id = v.identity;
  const labels = v.referenceLabels.slice(0, 9);
  const all = labels.map((_, i) => i + 1);
  const where = (prefix: string) => labels.map((l, i) => (l.startsWith(prefix) ? i + 1 : 0)).filter(Boolean);
  const faces = where('face'), body = where('body'), outfitRefs = where('outfit');
  const never = neverList(id, t);
  const { clean: dir, removed } = sanitizeDirection(v.direction, id, t);
  const look = trimEndChars(id.look.trim(), '.');
  const o = v.outfit;
  const outfitName = (o?.name ?? '').trim().toLowerCase();
  let outfit: string;
  if (outfitRefs.length) outfit = `${outfitName ? `the ${outfitName} outfit` : 'the outfit'} from ${imageRange(outfitRefs)}`;
  else if (o && (o.source === 'described' || o.source === 'product-photo') && (o.description ?? '').trim())
    outfit = `wearing ${trimEndChars(o.description!.trim(), '.')}${body.length ? `, not the clothes in ${imageRange(body)}` : ''}`;
  else outfit = body.length ? `the outfit from ${imageRange(body)}` : 'an everyday outfit';
  // Her figure comes from her own images (the outfit set shows it in the clothes), never from the person in the video.
  const figure = [...body, ...outfitRefs].sort((a, b) => a - b);
  const parts = [faces.length ? `face and identity from ${imageRange(faces)}` : 'face and identity as described',
    ...(figure.length ? [`her exact figure, body shape and proportions (legs, thighs, hips, waist, bust, arms) from ${imageRange(figure)}, unchanged in every frame`] : []),
    outfit, `no ${never.join(', no ')}`];
  const speaking = v.speaking ?? true;
  const r = run('video.replicate', t, {
    inputs: { speaking, audioSent: speaking },
    vars: { subject: all.length ? `the person in ${imageRange(all)}: ${look}` : look, reference: parts.join('; '), faceRef: faces.length ? `<Image ${faces[0]}>` : 'the description' },
    direction: dir,
  });
  return { text: r.text, removed };
}

// ---------------------------------------------------------------- audio line (AI suite)
/** The audio sentence of a generated shot (workstream 1 calls this when it builds a shot prompt). */
export function audioLine(o: { audio: 'speech' | 'music' | 'none'; speaking: boolean; subject?: string; audioTag?: string }, t: PromptTexts = DEFAULT_TEXTS) {
  return run('video.audio', t, { inputs: { audio: o.audio, speaking: o.speaking }, vars: { subject: o.subject ?? '<Subject 1>', audio: o.audioTag ?? '<Audio 1>' } }).text;
}

// ---------------------------------------------------------------- reference sheet line (one-image shot models)
const GUIDE_WORDS: Record<string, string> = { pose: 'pose & framing', look: 'look & colour', scene: 'scene' };
/** The line that tells a one-image model its input is a reference sheet (script `refs.collage`). */
export function collageLine(panels: SheetPanel[], t: PromptTexts = DEFAULT_TEXTS) {
  const person = panels.map((p, i) => (p.role === 'person' ? i + 1 : 0)).filter(Boolean);
  const items = panels.map((p, i) => ({ panel: i + 1, role: p.role,
    guides: SHOOT_GUIDES.filter(g => p.guides?.includes(g.id)).map(g => GUIDE_WORDS[g.id]).join(' and the ') }));
  return run('refs.collage', t, { inputs: { panels: items }, vars: { person: panelSpan(person.length ? person : [1]) } }).text;
}
