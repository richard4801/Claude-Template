// The layered prompt engine (plans/prompt-system.md), a TypeScript port of android/core PromptEngine.kt.
// Checked against android/core/src/test/resources/prompt_fixture.json and the Kotlin unit tests.

export type LayerKey = 'identity' | 'outfit' | 'task' | 'scene' | 'camera' | 'light' | 'direction' | 'style' | 'negative' | 'seed';

export type Identity = { name: string; look: string; referenceCount?: number; neverAdd?: string[]; lora?: string | null };
export type OutfitSource = 'reference-set' | 'described' | 'product-photo';
export type OutfitSpec = { name: string; description?: string | null; source?: OutfitSource };
export type CameraSpec = { shot: string; lensMm: number; aperture: string };
export type ShootSpec = {
  identity: Identity; outfit: OutfitSpec; scene?: string | null; camera?: CameraSpec; light?: string;
  grade?: string | null; direction?: string | null; lockSeed?: boolean;
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
] as const;
export type SheetAngle = (typeof SHEET_ANGLES)[number];
export const sheetAngle = (key: string) => SHEET_ANGLES.find(a => a.key === key);

export const OUTFIT_ANGLES = [
  { label: 'Front', words: 'full body front view' },
  { label: '¾', words: 'full body three-quarter view' },
  { label: 'Side', words: 'full body side view' },
  { label: 'Back', words: 'full body back view' },
] as const;

export const HOUSE_STYLE = 'realistic smartphone photo, natural skin texture, true-to-life colour, no beauty filter, no AI gloss';
export const GLOBAL_NEVER = ['logos', 'extra fingers', 'warped jewellery'];
export const DEFAULT_SCENE = 'Rooftop · golden hour';
export const DEFAULT_GRADE = 'Phone-natural';
export const DEFAULT_CAMERA: CameraSpec = { shot: 'Medium', lensMm: 35, aperture: 'f/2.8' };

/** Words that would change who she is. A direction clause containing one is dropped. */
const IDENTITY_OVERRIDE = /\b(blonde|brunette|redhead|ginger|bald|(blue|green|brown|hazel|grey|gray) eyes|eye colou?r|hair colou?r|dyed hair|skin tone|different (face|person|woman|girl|model)|another (face|person|woman|model)|older|younger|look like)\b/i;

/** Identity LoRA naming: first name, lower case, plus the version ("sienna_v2"). */
export function loraToken(modelName: string, version: number) {
  const first = modelName.trim().split(/\s+/)[0] ?? '';
  const clean = [...first.toLowerCase()].filter(ch => /[\p{L}\p{N}]/u.test(ch)).join('');
  return `${clean || 'model'}_v${version}`;
}

const trimEndChars = (s: string, chars: string) => { let e = s.length; while (e > 0 && chars.includes(s[e - 1]!)) e--; return s.slice(0, e); };
const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** The never-add list: her own items, then the global defaults, de-duplicated (case-insensitive). */
export function neverList(id: Identity): string[] {
  const seen = new Set<string>(), out: string[] = [];
  for (const raw of [...(id.neverAdd ?? []), ...GLOBAL_NEVER]) {
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
export function sanitizeDirection(direction: string | null | undefined, id: Identity): { clean: string; removed: string[] } {
  const raw = (direction ?? '').trim();
  if (!raw) return { clean: '', removed: [] };
  const never = neverList(id).map(stem);
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
const identitySlot = (id: Identity): PromptSlot =>
  ({ layer: 'identity', text: `${id.name}: ${id.look}. Identity from ${refCount(id)} locked reference images${id.lora ? ` + LoRA ${id.lora} (photo)` : ''}.` });
const negativeSlot = (id: Identity): PromptSlot => ({ layer: 'negative', text: `Never add: ${neverList(id).join(', ')}.` });
const styleSlot = (): PromptSlot => ({ layer: 'style', text: `Style: ${HOUSE_STYLE}.` });

function cameraWords(c: CameraSpec) {
  const extra = c.lensMm <= 24 ? ', slight wide-angle distortion' : c.lensMm >= 85 ? ', compressed background, creamy bokeh' : '';
  return `Camera: ${c.shot.toLowerCase()} shot, ${c.lensMm}mm lens, ${c.aperture}${extra}.`;
}
function outfitWords(o: OutfitSpec) {
  switch (o.source ?? 'reference-set') {
    case 'described': return `Wearing: ${trimEndChars((o.description ?? o.name).trim(), '.')}.`;
    case 'product-photo': return `Wearing: the outfit from the product photo reference (${o.name.toLowerCase()}).`;
    default: return `Wearing: ${o.name.toLowerCase()} (outfit reference set).`;
  }
}

/** Java's String.hashCode, so Lock look gives the same seed as the Kotlin and Swift apps. */
function javaHash(s: string) { let h = 0; for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) | 0; return h; }
/** Deterministic seed from a name, used when Lock look is on. */
export const seedFor = (key: string) => (javaHash(key) & 0x7fffffff) % 1_000_000;

/** Photoshoot: all layers. */
export function photoshoot(s: ShootSpec): BuiltPrompt {
  const { clean: dir, removed } = sanitizeDirection(s.direction, s.identity);
  const scene = s.scene && s.scene.trim() ? s.scene : DEFAULT_SCENE;
  const slots: PromptSlot[] = [
    identitySlot(s.identity),
    { layer: 'outfit', text: outfitWords(s.outfit) },
    { layer: 'scene', text: `Scene: ${scene.toLowerCase()}.` },
    { layer: 'camera', text: cameraWords(s.camera ?? DEFAULT_CAMERA) },
    { layer: 'light', text: `Light: ${(s.light ?? 'Golden hour').toLowerCase()}; grade: ${(s.grade ?? DEFAULT_GRADE).toLowerCase()}.` },
    { layer: 'direction', text: dir ? `Direction: ${dir}` : '' },
    styleSlot(),
    negativeSlot(s.identity),
    { layer: 'seed', text: s.lockSeed ? 'Seed: locked (variations keep the same look).' : 'Seed: new each shot.' },
  ].filter(x => x.text.trim()) as PromptSlot[];
  return build(slots, s.lockSeed ? seedFor(s.identity.name) : null, removed);
}

/** Character-sheet shot: identity + task + house style + never add. */
export function characterSheetShot(id: Identity, angle: SheetAngle): BuiltPrompt {
  return build([
    identitySlot(id),
    { layer: 'task', text: `Task: ${angle.label.toLowerCase()} shot on a plain light-grey studio background, even soft light, neutral expression, ${angle.framing}.` },
    styleSlot(),
    negativeSlot(id),
  ]);
}

/** One outfit-set angle. All four angles share `seed`. */
export function outfitAngle(id: Identity, outfit: OutfitSpec, angle: (typeof OUTFIT_ANGLES)[number], seed: number): BuiltPrompt {
  const never = { ...id, neverAdd: [...(id.neverAdd ?? []), 'visible brand logos'] };
  return build([
    identitySlot(id),
    { layer: 'outfit', text: outfitWords(outfit) },
    { layer: 'task', text: `Task: ${angle.words}, plain studio background.` },
    styleSlot(),
    negativeSlot(never),
    { layer: 'seed', text: `Seed: ${seed} (shared by all four angles).` },
  ], seed);
}
export const outfitSet = (id: Identity, outfit: OutfitSpec, seed = seedFor(outfit.name)) => OUTFIT_ANGLES.map(a => outfitAngle(id, outfit, a, seed));

/** The structured H3 Ref2VA prompt for a character swap. */
export function videoSwap(v: VideoSwapSpec): H3Prompt {
  const id = v.identity;
  const n = v.referenceLabels?.length ? Math.min(6, v.referenceLabels.length) : Math.min(6, Math.max(1, refCount(id)));
  const keepAudio = v.keepAudio ?? true, keepBackground = v.keepBackground ?? true;
  const perf = { description: 'the person', tattoos: false, rings: false, setting: 'the room', ...v.performer };
  const labels = v.referenceLabels?.length ? v.referenceLabels.slice(0, n) : SHEET_ANGLES.slice(0, n).map(a => a.label.toLowerCase().replace(' · ', ', '));
  const refs = labels.map((l, i) => `<Image ${i + 1}> (${l})`);
  const refList = refs.length === 1 ? refs[0] : refs.slice(0, -1).join(', ') + ' and ' + refs[refs.length - 1];
  const extras = [perf.tattoos && 'tattoos', perf.rings && 'rings'].filter(Boolean) as string[];
  const performer = perf.description + (extras.length ? ` with ${extras.join(' and ')}` : '');
  const never = neverList(id);
  const { clean: dir, removed } = sanitizeDirection(v.direction, id);
  const outfitName = v.outfit.name.toLowerCase();

  let subjects = `<Subject 1> is ${performer} in <Video 1>, in ${perf.setting}.\n`;
  subjects += `<Subject 2> is ${id.name}: ${id.look}, with NO tattoos, shown in ${refList}`;
  if (id.lora) subjects += `, with LoRA ${id.lora} video`;
  subjects += '.\n<Video 1> is the source video for the editing task.';
  if (keepAudio) subjects += '\n<Audio 1> is the synchronized audio track of <Video 1>.';

  let summary = `[video editing + character replacement${keepAudio ? ' + audio reuse' : ''}] The target video is an edited version of <Video 1> in which <Subject 1> is replaced by <Subject 2>. `;
  summary += 'Every movement, pose, gesture, hand position, head turn, facial expression and mouth movement of <Subject 1> is kept exactly, frame by frame, at exactly the same moments. ';
  summary += keepBackground ? 'The camera, framing, background, lighting and timing of <Video 1> are unchanged.'
    : `The camera, framing and timing of <Video 1> are unchanged; the background is replaced by the background reference photo${v.backgroundMotion ? ` (${v.backgroundMotion})` : ''}.`;
  if (keepAudio) summary += ' <Audio 1> is fully reused.';

  const clean = [perf.tattoos && "None of <Subject 1>'s tattoos remain.", perf.rings && "None of <Subject 1>'s rings remain."].filter(Boolean).join(' ');
  let retention = '<Video 1> (source video editing): ';
  retention += keepBackground ? 'fully_preserved - the background, camera position, lighting and the full body motion and timing are maintained exactly.\n'
    : 'motion_preserved - the full body motion and timing are maintained exactly; the background is replaced.\n';
  retention += `<Subject 1>: replaced - identity, face, hair, skin, ${perf.tattoos ? 'tattoos, ' : ''}body and clothing are all replaced by <Subject 2>; only motion and expressions are kept.`;
  if (clean) retention += ` ${clean}`;
  retention += `\n<Subject 2>: reference - identity, face, hair, clean tattoo-free skin, body shape and outfit follow <Image 1>-<Image ${n}>`;
  retention += ` and the ${outfitName} outfit reference set. She wears no ${never.join(', no ')}.`;
  retention += '\n<Audio 1>: ' + (keepAudio ? 'fully_copy - the original audio is kept unchanged.' : 'replaced - a new audio track is supplied.');

  let detailed = 'The target video is in realistic photographic style, like a casual smartphone video. ';
  detailed += `[Shot 1] <Subject 2> performs exactly the same motion as <Subject 1> with the same timing, wearing the ${outfitName}. `;
  detailed += 'Her skin is smooth and clean with no tattoos. Her face is sharp and detailed and matches <Image 1>, with natural skin texture, natural expressions, stable eyes, natural lips and teeth, and realistic hands with five fingers.';
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

export function replicateSwap(v: ReplicateSwapSpec): { text: string; removed: string[] } {
  const id = v.identity;
  const labels = v.referenceLabels.slice(0, 9);
  const all = labels.map((_, i) => i + 1);
  const where = (prefix: string) => labels.map((l, i) => (l.startsWith(prefix) ? i + 1 : 0)).filter(Boolean);
  const faces = where('face'), body = where('body'), outfitRefs = where('outfit');
  const never = neverList(id);
  const { clean: dir, removed } = sanitizeDirection(v.direction, id);
  const look = trimEndChars(id.look.trim(), '.');

  const s2 = all.length ? `the person in ${imageRange(all)}: ${look}` : look;
  const subjects = `<Subject 1> is the person in <Video 1>.\n<Subject 2> is ${s2}, no tattoos.\n<Video 1> is the source video.`;

  const summary = '[video editing + character replacement] <Subject 1> is replaced by <Subject 2>. <Subject 2> copies '
    + "<Subject 1>'s facial performance exactly, frame by frame and with the same intensity: every eye movement, side glance, blink, "
    + 'eyebrow raise, mouth and lip movement and head turn, at the same moments, and the same body motion. The camera, the exact framing '
    + 'and crop, the background and the lighting of <Video 1> stay unchanged. Any caption or on-screen text is removed.';

  const o = v.outfit;
  const outfitName = (o?.name ?? '').trim().toLowerCase();
  let outfit: string;
  if (outfitRefs.length) outfit = `${outfitName ? `the ${outfitName} outfit` : 'the outfit'} from ${imageRange(outfitRefs)}`;
  else if (o && (o.source === 'described' || o.source === 'product-photo') && (o.description ?? '').trim())
    outfit = `wearing ${trimEndChars(o.description!.trim(), '.')}${body.length ? `, not the clothes in ${imageRange(body)}` : ''}`;
  else outfit = body.length ? `the outfit from ${imageRange(body)}` : 'an everyday outfit';
  const parts = [faces.length ? `face and identity from ${imageRange(faces)}` : 'face and identity as described',
    ...(body.length ? [`body shape from ${imageRange(body)}`] : []), outfit, `no ${never.join(', no ')}`];
  const retention = '<Video 1>: fully_preserved - camera motion, framing and crop, background, lighting and timing.\n'
    + "<Subject 1>: replaced - only the facial expressions, mouth movements and body motion are kept, not the face, hair, tattoos, jewellery or clothes.\n"
    + `<Subject 2>: reference - ${parts.join('; ')}.`;

  let detailed = 'Casual phone video, realistic. [Shot 1] <Subject 2> in the same place, framed exactly like <Subject 1>: keep the exact '
    + 'framing and crop of <Video 1>, the camera does not pull back. The face is fully alive and mirrors every expression of <Subject 1> '
    + `and the words being mouthed. Sharp face matching ${faces.length ? `<Image ${faces[0]}>` : 'the description'}, natural skin texture, no beauty filter. No text anywhere.`;
  if (dir) detailed += ` ${dir}`;

  const text = `subject_definitions:\n${subjects}\n\nsummary:\n${summary}\n\nretention_analysis:\n${retention}\n\ndetailed_description:\n${detailed}\n`;
  return { text, removed };
}
