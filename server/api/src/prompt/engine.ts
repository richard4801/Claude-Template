// The layered prompt engine (plans/prompt-system.md), a TypeScript port of android/core PromptEngine.kt.
// Checked against android/core/src/test/resources/prompt_fixture.json and the Kotlin unit tests.
// Every text comes from the prompt library (library.ts): the defaults, or the studio's owner overrides when passed in.
import { DEFAULT_TEXTS, fill, listOf, type PromptTexts } from './library.js';
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
  /** The shot has a camera of its own: the AI suite Photo rig (or its camera preset) sets a camera body, lens character,
   *  look or grade. Then the house style's Camera feel and the default grade are left out. The old Photo tool's grade
   *  picker doesn't count (it isn't a rig). */
  ownCamera?: boolean;
};
export type PromptSlot = { layer: LayerKey; text: string };
export type BuiltPrompt = { slots: PromptSlot[]; seed: number | null; removed: string[]; text: string };
export type SourcePerformer = { description?: string; tattoos?: boolean; rings?: boolean; setting?: string };
export type VideoSwapSpec = {
  identity: Identity; outfit: OutfitSpec; performer?: SourcePerformer; keepAudio?: boolean; keepBackground?: boolean;
  /** Background "Describe it": the direction sets the new place (keepBackground false, no photo). */
  describeBackground?: boolean;
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

/** The house style at its defaults with no camera of the shot's own: Camera feel, then Realism. */
export const HOUSE_STYLE = `${DEFAULT_TEXTS['style.camera']}, ${DEFAULT_TEXTS['style.realism']}`;
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

export const slotText = (p: BuiltPrompt, layer: LayerKey) => p.slots.find(s => s.layer === layer)?.text;
/** The slot body without its "Label: " prefix. */
export const slotBody = (s: PromptSlot) => s.text.replace(/^[A-Za-z ]+: /, '');

const refCount = (id: Identity) => id.referenceCount ?? 6;
/** The identity line (every photo prompt). */
export const identityLine = (id: Identity, t: PromptTexts = DEFAULT_TEXTS) =>
  fill(t['shoot.identity']!, { name: id.name, look: id.look, refCount: refCount(id), lora: id.lora ? ` + LoRA ${id.lora} (photo)` : '' });
export const neverLine = (items: string[], t: PromptTexts = DEFAULT_TEXTS) => fill(t['shoot.never']!, { never: items.join(', ') });

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
export const panelSpan = (ns: number[]) => {
  if (ns.length === 1) return `panel ${ns[0]} shows`;
  const run = ns.every((n, i) => i === 0 || n === ns[i - 1]! + 1);
  return `${run ? `panels ${ns[0]}–${ns[ns.length - 1]}` : `panels ${ns.slice(0, -1).join(', ')} and ${ns[ns.length - 1]}`} show`;
};
/** Layers kept when Presets is off. */
export const OWN_LAYERS: LayerKey[] = ['identity', 'outfit', 'direction', 'reference', 'seed'];

/** Java's String.hashCode, so Lock look gives the same seed as the Kotlin and Swift apps. */
function javaHash(s: string) { let h = 0; for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) | 0; return h; }
/** Deterministic seed from a name, used when Lock look is on. */
export const seedFor = (key: string) => (javaHash(key) & 0x7fffffff) % 1_000_000;

/**
 * The scene, light and grade a shoot really used (defaults from the library). The default grade yields to the shot's own
 * camera, lens or look: then `grade` is empty and the light line goes without one.
 */
export function shootChoices(s: ShootSpec, t: PromptTexts = DEFAULT_TEXTS) {
  // The scene line adds its own full stop: a scene typed as a sentence ("… at dusk.") loses its own, so it can't end "dusk..".
  const typed = trimEndChars((s.scene ?? '').trim(), '.,;: ').trim();
  const scene = typed ? typed : t['shoot.default.scene']!;
  const light = s.light && s.light.trim() ? s.light.trim() : t['shoot.default.light']!;
  const grade = s.grade && s.grade.trim() ? s.grade.trim() : s.ownCamera ? '' : t['shoot.default.grade']!;
  return { scene, light, grade, camera: s.camera ?? DEFAULT_CAMERA, ownCamera: !!s.ownCamera };
}



/** Outfit from her base photos (plans/outfit-head-looks.md §6): which pieces stay, which change. */
export const OUTFIT_PIECES = ['top', 'bottom', 'shoes', 'accessories'] as const;
export type OutfitPiece = typeof OUTFIT_PIECES[number];
export type OutfitKeep = { keep?: Partial<Record<OutfitPiece, boolean>>; note?: string | null };
const andList = (xs: string[]) => xs.length <= 1 ? xs.join('') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`;
export function outfitKeepParts(k: OutfitKeep | null | undefined) {
  const kept = OUTFIT_PIECES.filter(p => k?.keep?.[p]), rest = OUTFIT_PIECES.filter(p => !k?.keep?.[p]);
  const note = (k?.note ?? '').trim().replace(/[.\s]+$/, '');
  const words = (ps: readonly string[]) => andList(ps.map(p => `the ${p}`));
  const keep = kept.length ? words(kept) + (note ? ` (${note})` : '') : note;
  return { keeping: kept.length > 0 || !!note, kept, rest, keep, replace: rest.length ? words(rest) : 'the rest of the clothes' };
}
export const outfitKeepFront = (k: OutfitKeep, outfit: string, t: PromptTexts = DEFAULT_TEXTS) => {
  const p = outfitKeepParts(k);
  return fill(t['outfit.keep.front']!, { keep: p.keep, replace: p.replace, outfit: trimEndChars(outfit.trim(), '.') });
};
export const outfitKeepAngle = (k: OutfitKeep, t: PromptTexts = DEFAULT_TEXTS) => fill(t['outfit.keep.angle']!, { keep: outfitKeepParts(k).keep });

/** The outfit's face close-ups, in the order stored on the outfit (`outfit.faces`): front, ¾, side. */
export const OUTFIT_FACES = [{ key: 'face', label: 'Face · front', words: 'face close-up from the front' }, { key: 'faceTq', label: 'Face · ¾', words: 'face close-up from three-quarter view' },
  { key: 'profile', label: 'Face · side', words: 'face close-up in profile (side view)' }] as const;
export const outfitFacePrompt = (i: number, t: PromptTexts = DEFAULT_TEXTS) => fill(t['outfit.face']!, { angle: OUTFIT_FACES[i]!.words });

export const outfitSet = (id: Identity, outfit: OutfitSpec, seed = seedFor(outfit.name), t: PromptTexts = DEFAULT_TEXTS) => OUTFIT_ANGLES.map(a => outfitAngle(id, outfit, a, seed, t));


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
  /** Background "Describe it": the direction sets the new place; the clip's moves and timing are kept, not its background. */
  newBackground?: boolean;
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


// ---- Prompt scripts (plans/prompt-scripts.md): every builder runs its script. Same signatures and, at default
// settings, the same prompts as before (test/prompt-scripts.test.ts checks them against test/legacy/).
import { photoshoot, characterSheetShot, outfitAngle, outfitEditPrompt, videoSwap, replicateSwap, collageLine, houseStyle } from './scripts/builders.js';
export { photoshoot, characterSheetShot, outfitAngle, outfitEditPrompt, videoSwap, replicateSwap, collageLine, houseStyle };
