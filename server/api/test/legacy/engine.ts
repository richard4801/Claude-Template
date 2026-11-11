// TEST-ONLY: the prompt builders as they were before prompt scripts (copied from src/prompt/engine.ts), the reference the
// script versions are checked against (test/prompt-scripts.test.ts). Never imported by src.
// The layered prompt engine (plans/prompt-system.md), a TypeScript port of android/core PromptEngine.kt.
// Checked against android/core/src/test/resources/prompt_fixture.json and the Kotlin unit tests.
// Every text comes from the prompt library (library.ts): the defaults, or the studio's owner overrides when passed in.
import { DEFAULT_TEXTS, fill, listOf, type PromptTexts } from '../../src/prompt/library.js';
export type { PromptTexts };

export type LayerKey = 'identity' | 'outfit' | 'task' | 'scene' | 'camera' | 'light' | 'direction' | 'reference' | 'style' | 'negative' | 'seed';
export type ShootGuide = 'pose' | 'look' | 'scene';
export const SHOOT_GUIDES: { id: ShootGuide; label: string }[] = [{ id: 'pose', label: 'Pose & framing' }, { id: 'look', label: 'Look & colour' }, { id: 'scene', label: 'Scene' }];
/** A reference image of a shoot, as sent: its 1-based number among the images sent and what it guides. */
export type SentRef = { index: number; guides: ShootGuide[] };

export type Identity = { name: string; look: string; referenceCount?: number; neverAdd?: string[]; lora?: string | null };
export type OutfitSource = 'reference-set' | 'described' | 'product-photo';
export type OutfitSpec = { name: string; description?: string | null; source?: OutfitSource };
export type CameraSpec = { shot: string; lensMm: number; aperture: string };
export type ShootSpec = {
  identity: Identity; outfit: OutfitSpec; scene?: string | null; camera?: CameraSpec; light?: string;
  grade?: string | null; direction?: string | null; lockSeed?: boolean;
  /** false: only identity, outfit, direction, reference and seed lines (the Presets switch). Default true. */
  presets?: boolean;
  /** Reference images that were sent (plans/api.md "Shoot references"). */
  refs?: SentRef[];
};
export type PromptSlot = { layer: LayerKey; text: string };
export type BuiltPrompt = { slots: PromptSlot[]; seed: number | null; removed: string[]; text: string };
export type SourcePerformer = { description?: string; tattoos?: boolean; rings?: boolean; setting?: string };
export type VideoSwapSpec = {
  identity: Identity; outfit: OutfitSpec; performer?: SourcePerformer; keepAudio?: boolean; keepBackground?: boolean;
  backgroundMotion?: string | null; steps?: number; seed?: number; direction?: string | null;
  /** Labels of the reference images actually sent, in <Image n> order ("face, front", "outfit, back"). Default: the sheet order. */
  referenceLabels?: string[];
};
export type H3Prompt = {
  subjectDefinitions: string; summary: string; retentionAnalysis: string; detailedDescription: string;
  audioMode: 'fully_copy' | 'replace'; steps: number; seed: number; removed: string[]; text: string;
};

export const SHEET_ANGLES = [
  { key: 'face', label: 'Face · front', framing: 'head-and-shoulders, facing the camera' },
  { key: 'profile', label: 'Face · profile', framing: 'head-and-shoulders, side profile' },
  { key: 'front', label: 'Body · front', framing: 'full body, facing the camera' },
  { key: 'tq', label: 'Body · ¾', framing: 'full body, three-quarter view' },
  { key: 'side', label: 'Body · side', framing: 'full body, side view' },
  { key: 'back', label: 'Body · back', framing: 'full body, from behind' },
  { key: 'faceTq', label: 'Face · ¾', framing: 'head-and-shoulders, turned three-quarters' },
] as const;
export type SheetAngle = (typeof SHEET_ANGLES)[number];
export const sheetAngle = (key: string) => SHEET_ANGLES.find(a => a.key === key);

export const OUTFIT_ANGLES = [
  { label: 'Front', words: 'full body front view' },
  { label: '¾', words: 'full body three-quarter view' },
  { label: 'Side', words: 'full body side view' },
  { label: 'Back', words: 'full body back view' },
] as const;

/** The old single house style: since the split (2026-11-11), Camera feel then Realism (the same words at their defaults). */
export const houseText = (t: PromptTexts) => [t['style.camera'], t['style.realism']].map(x => (x ?? '').trim()).filter(Boolean).join(', ');
export const HOUSE_STYLE = houseText(DEFAULT_TEXTS);
export const GLOBAL_NEVER = listOf(DEFAULT_TEXTS['never.base']!);
export const DEFAULT_SCENE = DEFAULT_TEXTS['shoot.default.scene']!;
export const DEFAULT_GRADE = DEFAULT_TEXTS['shoot.default.grade']!;
export const DEFAULT_CAMERA: CameraSpec = { shot: 'Medium', lensMm: 35, aperture: 'f/2.8' };

/** Words that would change who she is. A direction clause containing one is dropped. */
const IDENTITY_OVERRIDE = /\b(blonde|brunette|redhead|ginger|bald|(blue|green|brown|hazel|grey|gray) eyes|eye colou?r|hair colou?r|dyed hair|skin tone|different (face|person|woman|girl|model)|another (face|person|woman|model)|older|younger|look like)\b/i;

/** Identity LoRA naming: first name, lower case, plus the version ("demo_v2"). */
export function loraToken(modelName: string, version: number) {
  const first = modelName.trim().split(/\s+/)[0] ?? '';
  const clean = [...first.toLowerCase()].filter(ch => /[\p{L}\p{N}]/u.test(ch)).join('');
  return `${clean || 'model'}_v${version}`;
}

const trimEndChars = (s: string, chars: string) => { let e = s.length; while (e > 0 && chars.includes(s[e - 1]!)) e--; return s.slice(0, e); };
const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** The never-add list: her own items, then the global defaults, de-duplicated (case-insensitive). */
export function neverList(id: Identity, t: PromptTexts = DEFAULT_TEXTS): string[] {
  const seen = new Set<string>(), out: string[] = [];
  for (const raw of [...(id.neverAdd ?? []), ...listOf(t['never.base'] ?? '')]) {
    const t = raw.trim();
    if (!t || seen.has(t.toLowerCase())) continue;
    seen.add(t.toLowerCase()); out.push(t);
  }
  return out;
}

function stem(s: string) {
  const w = s.toLowerCase().trim();
  if (w.endsWith('ies')) return w.slice(0, -3);
  if (w.endsWith('es') && (w.endsWith('ches') || w.endsWith('shes') || w.endsWith('xes'))) return w.slice(0, -2);
  if (w.endsWith('s') && !w.endsWith('ss')) return w.slice(0, -1);
  return w;
}

/** "Direction never overrides identity or never-add": returns the cleaned direction and the dropped clauses. */
export function sanitizeDirection(direction: string | null | undefined, id: Identity, t: PromptTexts = DEFAULT_TEXTS): { clean: string; removed: string[] } {
  const raw = (direction ?? '').trim();
  if (!raw) return { clean: '', removed: [] };
  const never = neverList(id, t).map(stem);
  const clauses = raw.split(/(?<=[,.;])\s*|\s+and\s+(?=with\b)/).map(c => c.trim()).filter(Boolean);
  const kept: string[] = [], removed: string[] = [];
  for (const c of clauses) {
    const words = c.toLowerCase();
    const hitsNever = never.some(n => new RegExp(`\\b${escapeRe(n)}`).test(words));
    if (hitsNever || IDENTITY_OVERRIDE.test(c)) removed.push(trimEndChars(c, ',;.').trim()); else kept.push(c);
  }
  if (!removed.length) return { clean: raw, removed: [] };
  return { clean: trimEndChars(kept.join(' ').trim(), ',;').trim(), removed };
}

const build = (slots: PromptSlot[], seed: number | null = null, removed: string[] = []): BuiltPrompt =>
  ({ slots, seed, removed, text: slots.map(s => s.text).join('\n') });
export const slotText = (p: BuiltPrompt, layer: LayerKey) => p.slots.find(s => s.layer === layer)?.text;
/** The slot body without its "Label: " prefix. */
export const slotBody = (s: PromptSlot) => s.text.replace(/^[A-Za-z ]+: /, '');

const refCount = (id: Identity) => id.referenceCount ?? 6;
/** The identity line (every photo prompt). */
export const identityLine = (id: Identity, t: PromptTexts = DEFAULT_TEXTS) =>
  fill(t['shoot.identity']!, { name: id.name, look: id.look, refCount: refCount(id), lora: id.lora ? ` + LoRA ${id.lora} (photo)` : '' });
const identitySlot = (id: Identity, t: PromptTexts): PromptSlot => ({ layer: 'identity', text: identityLine(id, t) });
export const neverLine = (items: string[], t: PromptTexts = DEFAULT_TEXTS) => fill(t['shoot.never']!, { never: items.join(', ') });
const negativeSlot = (id: Identity, t: PromptTexts): PromptSlot => ({ layer: 'negative', text: neverLine(neverList(id, t), t) });
const styleSlot = (t: PromptTexts): PromptSlot => ({ layer: 'style', text: fill(t['shoot.style']!, { style: houseText(t) }) });

/** The camera words without the "Camera: " label (a shot's stored layer). */
export function cameraValues(c: CameraSpec, t: PromptTexts = DEFAULT_TEXTS) {
  const lensNote = c.lensMm <= 24 ? t['shoot.camera.wide']! : c.lensMm >= 85 ? t['shoot.camera.tele']! : '';
  return { shot: c.shot.toLowerCase(), lens: c.lensMm, aperture: c.aperture, lensNote };
}
function cameraWords(c: CameraSpec, t: PromptTexts) { return fill(t['shoot.camera']!, cameraValues(c, t)); }
/** The outfit line (shoots, outfit sets, templates). */
export function outfitWords(o: OutfitSpec, t: PromptTexts = DEFAULT_TEXTS) {
  switch (o.source ?? 'reference-set') {
    case 'described': return fill(t['shoot.outfit.described']!, { outfit: trimEndChars((o.description ?? o.name).trim(), '.') });
    case 'product-photo': return fill(t['shoot.outfit.product']!, { outfit: o.name.toLowerCase() });
    default: return fill(t['shoot.outfit.set']!, { outfit: o.name.toLowerCase() });
  }
}
/** One reference image's line: its guide lines (pose, look, scene) and the guard line. */
export function referenceLine(r: SentRef, t: PromptTexts = DEFAULT_TEXTS) {
  const v = { refIndex: r.index };
  const parts = SHOOT_GUIDES.filter(g => r.guides.includes(g.id)).map(g => fill(t[`refs.${g.id}`]!, v));
  parts.push(fill(t['refs.guard']!, v));
  return parts.map(p => p.trim()).filter(Boolean).join(' ');
}
/** One panel of a reference sheet (images/collage.ts): who or what it shows, and for a reference image its guides. */
export type SheetPanel = { label: string; role: 'person' | 'outfit' | 'product' | 'ref'; guides?: ShootGuide[] };
const GUIDE_WORDS: Record<ShootGuide, string> = { pose: 'pose & framing', look: 'look & colour', scene: 'scene' };
/** The label printed on a reference image's panel: "ref: look & colour". */
export const refPanelLabel = (guides: ShootGuide[]) => `ref: ${SHOOT_GUIDES.filter(g => guides.includes(g.id)).map(g => GUIDE_WORDS[g.id]).join(' & ')}`;
/** "panel 1 shows", "panels 1–3 show", "panels 1, 3 and 4 show". */
const span = (ns: number[]) => {
  if (ns.length === 1) return `panel ${ns[0]} shows`;
  const run = ns.every((n, i) => i === 0 || n === ns[i - 1]! + 1);
  return `${run ? `panels ${ns[0]}–${ns[ns.length - 1]}` : `panels ${ns.slice(0, -1).join(', ')} and ${ns[ns.length - 1]}`} show`;
};
/** The line that tells a one-image model its input is a reference sheet (prompt library `refs.collage`). */
export function collageLine(panels: SheetPanel[], t: PromptTexts = DEFAULT_TEXTS) {
  const person = panels.map((p, i) => (p.role === 'person' ? i + 1 : 0)).filter(Boolean);
  const rest = panels.map((p, i) => {
    const k = i + 1;
    if (p.role === 'outfit') return `panel ${k} shows the outfit to wear`;
    if (p.role === 'product') return `panel ${k} shows the product`;
    if (p.role === 'ref') return `panel ${k} guides the ${SHOOT_GUIDES.filter(g => p.guides?.includes(g.id)).map(g => GUIDE_WORDS[g.id]).join(' and the ')} only`;
    return '';
  }).filter(Boolean);
  return fill(t['refs.collage']!, { person: span(person.length ? person : [1]), panels: rest.map(r => `; ${r}`).join('') }).trim();
}
/** Layers kept when Presets is off. */
export const OWN_LAYERS: LayerKey[] = ['identity', 'outfit', 'direction', 'reference', 'seed'];

/** Java's String.hashCode, so Lock look gives the same seed as the Kotlin and Swift apps. */
function javaHash(s: string) { let h = 0; for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) | 0; return h; }
/** Deterministic seed from a name, used when Lock look is on. */
export const seedFor = (key: string) => (javaHash(key) & 0x7fffffff) % 1_000_000;

/** The scene, light and grade a shoot really used (defaults from the library). */
export function shootChoices(s: ShootSpec, t: PromptTexts = DEFAULT_TEXTS) {
  const scene = s.scene && s.scene.trim() ? s.scene.trim() : t['shoot.default.scene']!;
  const light = s.light && s.light.trim() ? s.light.trim() : t['shoot.default.light']!;
  const grade = s.grade && s.grade.trim() ? s.grade.trim() : t['shoot.default.grade']!;
  return { scene, light, grade, camera: s.camera ?? DEFAULT_CAMERA };
}

/** Photoshoot: all layers (Presets off: identity, outfit, direction, references and seed only). */
export function photoshoot(s: ShootSpec, t: PromptTexts = DEFAULT_TEXTS): BuiltPrompt {
  const { clean: dir, removed } = sanitizeDirection(s.direction, s.identity, t);
  const c = shootChoices(s, t);
  let slots: PromptSlot[] = [
    identitySlot(s.identity, t),
    { layer: 'outfit', text: outfitWords(s.outfit, t) },
    { layer: 'scene', text: fill(t['shoot.scene']!, { scene: c.scene.toLowerCase() }) },
    { layer: 'camera', text: cameraWords(c.camera, t) },
    { layer: 'light', text: fill(t['shoot.light']!, { light: c.light.toLowerCase(), grade: c.grade.toLowerCase() }) },
    { layer: 'direction', text: dir ? fill(t['shoot.direction']!, { direction: dir }) : '' },
    ...(s.refs ?? []).map(r => ({ layer: 'reference' as const, text: referenceLine(r, t) })),
    styleSlot(t),
    negativeSlot(s.identity, t),
    { layer: 'seed', text: s.lockSeed ? t['shoot.seed.locked']! : t['shoot.seed.new']! },
  ].filter(x => x.text.trim()) as PromptSlot[];
  if (s.presets === false) slots = slots.filter(x => OWN_LAYERS.includes(x.layer));
  return build(slots, s.lockSeed ? seedFor(s.identity.name) : null, removed);
}

/** Character-sheet shot: identity + task + house style + never add. */
export function characterSheetShot(id: Identity, angle: SheetAngle, t: PromptTexts = DEFAULT_TEXTS): BuiltPrompt {
  return build([
    identitySlot(id, t),
    { layer: 'task', text: fill(t['sheet.task']!, { angle: angle.label.toLowerCase(), framing: angle.framing }) },
    styleSlot(t),
    negativeSlot(id, t),
  ].filter(x => x.text.trim()) as PromptSlot[]);
}

/** One outfit-set angle. All four angles share `seed`. */
export function outfitAngle(id: Identity, outfit: OutfitSpec, angle: (typeof OUTFIT_ANGLES)[number], seed: number, t: PromptTexts = DEFAULT_TEXTS): BuiltPrompt {
  const never = { ...id, neverAdd: [...(id.neverAdd ?? []), ...listOf(t['outfit.never.extra'] ?? '')] };
  return build([
    identitySlot(id, t),
    { layer: 'outfit', text: outfitWords(outfit, t) },
    { layer: 'task', text: fill(t['outfit.task']!, { angle: angle.words }) },
    styleSlot(t),
    negativeSlot(never, t),
    { layer: 'seed', text: fill(t['outfit.seed']!, { seed }) },
  ].filter(x => x.text.trim()) as PromptSlot[], seed);
}
export const outfitSet = (id: Identity, outfit: OutfitSpec, seed = seedFor(outfit.name), t: PromptTexts = DEFAULT_TEXTS) => OUTFIT_ANGLES.map(a => outfitAngle(id, outfit, a, seed, t));
/** The ¾ / side / back of an outfit set, as edits of the front. */
export const outfitEditPrompt = (angle: (typeof OUTFIT_ANGLES)[number], t: PromptTexts = DEFAULT_TEXTS) => fill(t['outfit.edit']!, { angle: angle.words });

/** The structured H3 Ref2VA prompt for a character swap. */
export function videoSwap(v: VideoSwapSpec, t: PromptTexts = DEFAULT_TEXTS): H3Prompt {
  const id = v.identity;
  const n = v.referenceLabels?.length ? Math.min(6, v.referenceLabels.length) : Math.min(6, Math.max(1, refCount(id)));
  const keepAudio = v.keepAudio ?? true, keepBackground = v.keepBackground ?? true;
  const perf = { description: 'the person', tattoos: false, rings: false, setting: 'the room', ...v.performer };
  const labels = v.referenceLabels?.length ? v.referenceLabels.slice(0, n) : SHEET_ANGLES.slice(0, n).map(a => a.label.toLowerCase().replace(' · ', ', '));
  const refs = labels.map((l, i) => `<Image ${i + 1}> (${l})`);
  const refList = refs.length === 1 ? refs[0] : refs.slice(0, -1).join(', ') + ' and ' + refs[refs.length - 1];
  const extras = [perf.tattoos && 'tattoos', perf.rings && 'rings'].filter(Boolean) as string[];
  const performer = perf.description + (extras.length ? ` with ${extras.join(' and ')}` : '');
  const never = neverList(id, t);
  const { clean: dir, removed } = sanitizeDirection(v.direction, id, t);
  const outfitName = v.outfit.name.toLowerCase();

  const subjects = fill(t['video.edit.subjects']!, { performer, setting: perf.setting, name: id.name, look: id.look, refs: refList,
    lora: id.lora ? `, with LoRA ${id.lora} video` : '', audio: keepAudio ? '\n<Audio 1> is the synchronized audio track of <Video 1>.' : '' });

  const background = keepBackground ? 'The camera, framing, background, lighting and timing of <Video 1> are unchanged.'
    : `The camera, framing and timing of <Video 1> are unchanged; the background is replaced by the background reference photo${v.backgroundMotion ? ` (${v.backgroundMotion})` : ''}.`;
  const summary = fill(t['video.edit.summary']!, { audioTag: keepAudio ? ' + audio reuse' : '', background, audio: keepAudio ? ' <Audio 1> is fully reused.' : '' });

  const clean = [perf.tattoos && "None of <Subject 1>'s tattoos remain.", perf.rings && "None of <Subject 1>'s rings remain."].filter(Boolean).join(' ');
  const retention = fill(t['video.edit.retention']!, {
    video: keepBackground ? 'fully_preserved - the background, camera position, lighting and the full body motion and timing are maintained exactly.'
      : 'motion_preserved - the full body motion and timing are maintained exactly; the background is replaced.',
    tattoos: perf.tattoos ? 'tattoos, ' : '', clean: clean ? ` ${clean}` : '', n, outfit: outfitName, never: never.join(', no '),
    audio: keepAudio ? 'fully_copy - the original audio is kept unchanged.' : 'replaced - a new audio track is supplied.' });

  let detailed = fill(t['video.edit.detailed']!, { outfit: outfitName });
  if (dir) detailed += ` ${dir}`;

  const text = `subject_definitions:\n${subjects}\n\nsummary:\n${summary}\n\nretention_analysis:\n${retention}\n\ndetailed_description:\n${detailed}\n`;
  return { subjectDefinitions: subjects, summary, retentionAnalysis: retention, detailedDescription: detailed,
    audioMode: keepAudio ? 'fully_copy' : 'replace', steps: v.steps ?? 10, seed: v.seed ?? 42, removed, text };
}

// ---- Replicate (hosted MiniMax H3): a SHORT prompt (plans/backend.md "Replicate").
// The owner's tests showed that long prompts make H3 drop details, so this keeps the four sections of the tested v4
// prompt (~230 words) and nothing else: identity, outfit, never-add, captions removed, and the exact framing and crop
// (the hosted model tends to pull the camera back otherwise).

/** Reference roles in the fixed order they are sent to Replicate (≤ 9). */
export type RefRole = 'face, front' | 'face, profile' | 'body, front' | 'body, ¾' | 'body, back' | 'outfit, front' | 'outfit, ¾' | 'outfit, back' | 'outfit, side';
export type ReplicateSwapSpec = {
  identity: Identity; outfit?: OutfitSpec | null;
  /** Roles of the images actually sent, in <Image n> order. */
  referenceLabels: string[];
  direction?: string | null;
};

/** "<Image 3>", "<Image 3> and <Image 4>", "<Image 3> to <Image 5>", "<Image 1>, <Image 3> and <Image 6>". */
export function imageRange(ns: number[]): string {
  if (!ns.length) return '';
  const tag = (n: number) => `<Image ${n}>`;
  if (ns.length === 1) return tag(ns[0]!);
  const contiguous = ns.every((n, i) => i === 0 || n === ns[i - 1]! + 1);
  if (contiguous && ns.length > 2) return `${tag(ns[0]!)} to ${tag(ns[ns.length - 1]!)}`;
  return ns.slice(0, -1).map(tag).join(', ') + ' and ' + tag(ns[ns.length - 1]!);
}

export function replicateSwap(v: ReplicateSwapSpec, t: PromptTexts = DEFAULT_TEXTS): { text: string; removed: string[] } {
  const id = v.identity;
  const labels = v.referenceLabels.slice(0, 9);
  const all = labels.map((_, i) => i + 1);
  const where = (prefix: string) => labels.map((l, i) => (l.startsWith(prefix) ? i + 1 : 0)).filter(Boolean);
  const faces = where('face'), body = where('body'), outfitRefs = where('outfit');
  const never = neverList(id, t);
  const { clean: dir, removed } = sanitizeDirection(v.direction, id, t);
  const look = trimEndChars(id.look.trim(), '.');

  const s2 = all.length ? `the person in ${imageRange(all)}: ${look}` : look;
  const subjects = fill(t['video.replicate.subjects']!, { subject: s2 });
  const summary = t['video.replicate.summary']!;

  const o = v.outfit;
  const outfitName = (o?.name ?? '').trim().toLowerCase();
  let outfit: string;
  if (outfitRefs.length) outfit = `${outfitName ? `the ${outfitName} outfit` : 'the outfit'} from ${imageRange(outfitRefs)}`;
  else if (o && (o.source === 'described' || o.source === 'product-photo') && (o.description ?? '').trim())
    outfit = `wearing ${trimEndChars(o.description!.trim(), '.')}${body.length ? `, not the clothes in ${imageRange(body)}` : ''}`;
  else outfit = body.length ? `the outfit from ${imageRange(body)}` : 'an everyday outfit';
  const parts = [faces.length ? `face and identity from ${imageRange(faces)}` : 'face and identity as described',
    // Owner 2026-11-10 (figure lock): her figure from her body and outfit images; changed here with the live builder.
    ...((() => { const figure = [...body, ...outfitRefs].sort((a, b) => a - b);
      return figure.length ? [`her exact figure, body shape and proportions (legs, thighs, hips, waist, bust, arms) from ${imageRange(figure)}, unchanged in every frame`] : []; })()),
    outfit, `no ${never.join(', no ')}`];
  const retention = fill(t['video.replicate.retention']!, { reference: parts.join('; ') });
  let detailed = fill(t['video.replicate.detailed']!, { faceRef: faces.length ? `<Image ${faces[0]}>` : 'the description' });
  if (dir) detailed += ` ${dir}`;

  const text = `subject_definitions:\n${subjects}\n\nsummary:\n${summary}\n\nretention_analysis:\n${retention}\n\ndetailed_description:\n${detailed}\n`;
  return { text, removed };
}
