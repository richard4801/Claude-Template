// The prompt library (plans/api.md "Shoot references and the prompt library" §3): every prompt or prompt fragment the
// server sends to a model is a named entry with a default here and an optional owner override per studio. The defaults
// reproduce the prompts exactly as they were before the library, so the shared fixtures keep passing.

import { SUITE_PROMPT_DEFS } from '../suite/prompts.js';

export const PROMPT_GROUPS = [
  { id: 'photoshoot', label: 'Photoshoot' }, { id: 'references', label: 'References' }, { id: 'sheet', label: 'Character sheet' },
  { id: 'outfits', label: 'Outfits' }, { id: 'enhance', label: 'Enhance' }, { id: 'dressup', label: 'Dress up' },
  { id: 'templates', label: 'Templates' }, { id: 'video', label: 'Video' }, { id: 'lora', label: 'LoRA' },
  // AI suite (workstream 1): suite/prompts.ts
  { id: 'suite', label: 'AI suite' },
] as const;
export type PromptGroup = (typeof PROMPT_GROUPS)[number]['id'];

type Ph = [name: string, description: string, required?: true];
export type PromptDef = {
  key: string; group: PromptGroup; title: string; description: string; kind: 'text' | 'list' | 'lines';
  default: string; placeholders: Ph[]; allowEmpty?: boolean;
};
const REPLICATE_SUMMARY = '[video editing + character replacement] <Subject 1> is replaced by <Subject 2>. <Subject 2> copies '
  + "<Subject 1>'s facial performance exactly, frame by frame and with the same intensity: every eye movement, side glance, blink, "
  + 'eyebrow raise, mouth and lip movement and head turn, at the same moments, and the same body motion. The camera, the exact framing '
  + 'and crop, the background and the lighting of <Video 1> stay unchanged. Any caption or on-screen text is removed.';

const d = (key: string, group: PromptGroup, title: string, description: string, def: string, placeholders: Ph[] = [], extra: Partial<PromptDef> = {}): PromptDef =>
  ({ key, group, title, description, kind: 'text', default: def, placeholders, ...extra });

export const PROMPT_DEFS: PromptDef[] = [
  // ---------------------------------------------------------------- photoshoot
  d('style.house', 'photoshoot', 'House style', 'The look every photo asks for. Used in the style line of shoots, template shoots, sheet fills and outfit sets.',
    'realistic smartphone photo, natural skin texture, true-to-life colour, no beauty filter, no AI gloss', [], { allowEmpty: false }),
  d('never.base', 'photoshoot', 'Never add (every model)', 'Comma-separated. Added after each model’s own never-add list in every photo and video prompt.',
    'logos, extra fingers, warped jewellery', [], { kind: 'list' }),
  d('shoot.default.scene', 'photoshoot', 'Default scene', 'Used when a shoot sends no scene.', 'Rooftop · golden hour', [], { allowEmpty: false }),
  d('shoot.default.light', 'photoshoot', 'Default light', 'Used when a shoot sends no light.', 'Golden hour', [], { allowEmpty: false }),
  d('shoot.default.grade', 'photoshoot', 'Default grade', 'Used when a shoot sends no grade.', 'Phone-natural', [], { allowEmpty: false }),
  d('shoot.identity', 'photoshoot', 'Identity line', 'Who she is. First line of every photo prompt (shoots, templates, sheet fills, outfit sets, LoRA sets).',
    '{name}: {look}. Identity from {refCount} locked reference images{lora}.',
    [['name', 'her name'], ['look', 'her written look'], ['refCount', 'how many sheet images she has'], ['lora', '" + LoRA demo_v2 (photo)" when her LoRA is on, else empty']]),
  d('shoot.outfit.set', 'photoshoot', 'Outfit · reference set', 'An outfit with photos.', 'Wearing: {outfit} (outfit reference set).', [['outfit', 'the outfit name, lower case', true]]),
  d('shoot.outfit.described', 'photoshoot', 'Outfit · described', 'An outfit described in words, with no photos yet.', 'Wearing: {outfit}.', [['outfit', 'the description', true]]),
  d('shoot.outfit.product', 'photoshoot', 'Outfit · product photo', 'An outfit from a product photo.', 'Wearing: the outfit from the product photo reference ({outfit}).', [['outfit', 'the outfit name, lower case']]),
  d('shoot.scene', 'photoshoot', 'Scene line', 'The place.', 'Scene: {scene}.', [['scene', 'the chosen scene, lower case', true]]),
  d('shoot.camera', 'photoshoot', 'Camera line', 'Shot size, lens and aperture.', 'Camera: {shot} shot, {lens}mm lens, {aperture}{lensNote}.',
    [['shot', 'close, medium, full or wide'], ['lens', 'the lens in mm'], ['aperture', 'f/2.8 …'], ['lensNote', 'the wide or long lens note below, or empty']]),
  d('shoot.camera.wide', 'photoshoot', 'Camera · wide lens note', 'Added to the camera line at 24 mm and wider.', ', slight wide-angle distortion'),
  d('shoot.camera.tele', 'photoshoot', 'Camera · long lens note', 'Added to the camera line at 85 mm and longer.', ', compressed background, creamy bokeh'),
  d('shoot.light', 'photoshoot', 'Light line', 'Light and colour grade.', 'Light: {light}; grade: {grade}.', [['light', 'the chosen light, lower case'], ['grade', 'the chosen grade, lower case']]),
  d('shoot.direction', 'photoshoot', 'Direction line', 'The user’s own words (anything that would change her identity is removed first).', 'Direction: {direction}',
    [['direction', 'the user’s direction', true]]),
  d('shoot.style', 'photoshoot', 'Style line', 'The house style line.', 'Style: {style}.', [['style', 'the house style', true]]),
  d('shoot.never', 'photoshoot', 'Never-add line', 'What must never appear.', 'Never add: {never}.', [['never', 'her never-add list plus the base list', true]]),
  d('shoot.seed.locked', 'photoshoot', 'Seed line · Lock look', 'When Lock look is on.', 'Seed: locked (variations keep the same look).'),
  d('shoot.seed.new', 'photoshoot', 'Seed line · new each shot', 'When Lock look is off.', 'Seed: new each shot.'),
  // ---------------------------------------------------------------- references
  d('refs.pose', 'references', 'Pose & framing', 'For a reference image that guides the pose.', 'Copy the pose and framing from image {refIndex}.', [['refIndex', 'the image’s number in the images sent', true]]),
  d('refs.look', 'references', 'Look & colour', 'For a reference image that guides the look.', 'Copy the light, colour grade and camera feel from image {refIndex}.', [['refIndex', 'the image’s number in the images sent', true]]),
  d('refs.scene', 'references', 'Scene', 'For a reference image that guides the place.', 'Use the place and background from image {refIndex}.', [['refIndex', 'the image’s number in the images sent', true]]),
  d('refs.guard', 'references', 'Guard line', 'Ends every reference line: her face and body come only from her own sheet.', 'Do not take the face, body, hair or clothes from image {refIndex}.',
    [['refIndex', 'the image’s number in the images sent', true]]),
  // ---------------------------------------------------------------- character sheet
  d('sheet.task', 'sheet', 'Sheet shot task', 'One character-sheet image (fill angles, LoRA sets).',
    'Task: {angle} shot on a plain light-grey studio background, even soft light, neutral expression, {framing}.',
    [['angle', 'face · front, body · ¾ …'], ['framing', 'head-and-shoulders, facing the camera …']]),
  // ---------------------------------------------------------------- outfits
  d('outfit.task', 'outfits', 'Outfit angle task', 'One angle of an outfit set.', 'Task: {angle}, plain studio background.', [['angle', 'full body front view …', true]]),
  d('outfit.never.extra', 'outfits', 'Never add (outfit sets)', 'Comma-separated. Added to never-add for outfit sets.', 'visible brand logos', [], { kind: 'list' }),
  d('outfit.seed', 'outfits', 'Outfit seed line', 'The shared seed of the four angles.', 'Seed: {seed} (shared by all four angles).', [['seed', 'the seed']]),
  d('outfit.edit', 'outfits', 'Other angles (edit)', 'The ¾, side and back are made as edits of the front with this prompt.',
    'Show the same person in exactly the same outfit, on the same plain studio background, as a {angle}. Keep the face, hair, body and every detail of the clothes exactly the same. Realistic smartphone photo, natural skin texture.',
    [['angle', 'full body three-quarter view …', true]], { allowEmpty: false }),
  // ---------------------------------------------------------------- enhance
  d('enhance.prompt', 'enhance', 'Realism prompt', 'One prompt for every image of the sheet in Enhance step 1.',
    'candid smartphone photo, natural skin texture with visible pores and fine lines, true-to-life colour, soft natural light, no retouching, no beauty filter', [], { allowEmpty: false }),
  // ---------------------------------------------------------------- dress up
  d('dress.body', 'dressup', 'Full-body images', 'Dress up for the four full-body sheet images.',
    'Dress the person in the first image in the outfit from the second image: every garment, shoe and accessory, with the same colours, prints, fabrics and details.{anchor} Keep the face, hair, body, skin, pose, framing, camera angle and background exactly as in the first image. Realistic photo, natural skin texture.',
    [['anchor', 'a space and the anchor sentence when the new front is sent too, else empty']], { allowEmpty: false }),
  d('dress.closeup', 'dressup', 'Face close-ups', 'Dress up for the three face close-ups: only what shows at that distance.',
    'Add to the person in the first image only what shows of the outfit from the second image at this distance: earrings, necklace, glasses, hat or hair pieces, and the neckline of the top.{anchor} Keep the face, expression, hair, skin, pose, framing and background exactly as in the first image. Realistic close-up photo, natural skin texture.',
    [['anchor', 'a space and the anchor sentence when the new front is sent too, else empty']], { allowEmpty: false }),
  d('dress.anchor', 'dressup', 'Anchor sentence', 'Added when the newly dressed front is sent as a third image.',
    'The last image shows the same outfit already worn: match its colours, prints and details exactly.'),
  // ---------------------------------------------------------------- templates
  d('template.scene', 'templates', 'Scene line', 'Template scene plus the drawn background and time of day.', 'Scene: {scene}.', [['scene', 'the scene words', true]]),
  d('template.camera', 'templates', 'Camera line', 'Template camera plus the drawn framing.', 'Camera: {camera}.', [['camera', 'the camera words', true]]),
  d('template.light', 'templates', 'Light line', 'Template light.', 'Light: {light}.', [['light', 'the light words', true]]),
  d('template.pose', 'templates', 'Pose line', 'The drawn pose, body angle, expression and hands.', 'Pose: {pose}.', [['pose', 'the pose words', true]]),
  d('template.product', 'templates', 'Product line', 'With a product photo.', 'Product: {product}.', [['product', 'how the product is used', true]]),
  d('template.product.none', 'templates', 'Product line · no photo', 'Without a product photo.', 'Product: {product} (no product photo: a plausible unbranded product).', [['product', 'how the product is used', true]]),
  d('template.style', 'templates', 'Style line', 'Template style plus the house style.', 'Style: {style}.', [['style', 'the style words', true]]),
  d('template.locked', 'templates', 'Locked line', 'What anyone but the template’s maker sees in place of its hidden layers.', 'Template: {name}', [['name', 'the template name', true]]),
  d('template.seed.locked', 'templates', 'Seed line · Lock look', 'Lock look on.', 'Seed: {seed} (locked look).', [['seed', 'the seed']]),
  d('template.seed.new', 'templates', 'Seed line · new each shot', 'Lock look off.', 'Seed: {seed} (new each shot).', [['seed', 'the seed']]),
  // ---------------------------------------------------------------- video
  d('video.replicate.subjects', 'video', 'Draft/Standard/HD · subjects', 'subject_definitions of the short prompt.',
    '<Subject 1> is the person in <Video 1>.\n<Subject 2> is {subject}, no tattoos.\n<Video 1> is the source video.',
    [['subject', 'the person in <Image 1> to <Image n>: her look', true]], { allowEmpty: false }),
  d('video.replicate.summary', 'video', 'Draft/Standard/HD · summary', 'summary of the short prompt.', REPLICATE_SUMMARY, [], { allowEmpty: false }),
  d('video.replicate.retention', 'video', 'Draft/Standard/HD · retention', 'retention_analysis of the short prompt.',
    '<Video 1>: fully_preserved - camera motion, framing and crop, background, lighting and timing.\n'
    + '<Subject 1>: replaced - only the facial expressions, mouth movements and body motion are kept, not the face, hair, tattoos, jewellery or clothes.\n'
    + '<Subject 2>: reference - {reference}.', [['reference', 'face, body and outfit image ranges and the never-add list', true]], { allowEmpty: false }),
  d('video.replicate.detailed', 'video', 'Draft/Standard/HD · details', 'detailed_description of the short prompt (the user’s direction is added after it).',
    'Casual phone video, realistic. [Shot 1] <Subject 2> in the same place, framed exactly like <Subject 1>: keep the exact '
    + 'framing and crop of <Video 1>, the camera does not pull back. The face is fully alive and mirrors every expression of <Subject 1> '
    + 'and the words being mouthed. Sharp face matching {faceRef}, natural skin texture, no beauty filter. No text anywhere.',
    [['faceRef', '<Image 1>, or "the description"']], { allowEmpty: false }),
  d('video.edit.subjects', 'video', 'Edit · subjects', 'subject_definitions of the structured Edit prompt.',
    '<Subject 1> is {performer} in <Video 1>, in {setting}.\n<Subject 2> is {name}: {look}, with NO tattoos, shown in {refs}{lora}.\n<Video 1> is the source video for the editing task.{audio}',
    [['performer', 'the source performer'], ['setting', 'the source setting'], ['name', 'her name'], ['look', 'her look'], ['refs', '<Image 1> (face, front), …'],
      ['lora', '", with LoRA demo_v2 video" or empty'], ['audio', 'the audio-track line when the audio is kept, else empty']], { allowEmpty: false }),
  d('video.edit.summary', 'video', 'Edit · summary', 'summary of the structured Edit prompt.',
    '[video editing + character replacement{audioTag}] The target video is an edited version of <Video 1> in which <Subject 1> is replaced by <Subject 2>. '
    + 'Every movement, pose, gesture, hand position, head turn, facial expression and mouth movement of <Subject 1> is kept exactly, frame by frame, at exactly the same moments. {background}{audio}',
    [['audioTag', '" + audio reuse" when the audio is kept'], ['background', 'the background sentence'], ['audio', '" <Audio 1> is fully reused." when the audio is kept']], { allowEmpty: false }),
  d('video.edit.retention', 'video', 'Edit · retention', 'retention_analysis of the structured Edit prompt.',
    '<Video 1> (source video editing): {video}\n<Subject 1>: replaced - identity, face, hair, skin, {tattoos}body and clothing are all replaced by <Subject 2>; only motion and expressions are kept.{clean}\n'
    + '<Subject 2>: reference - identity, face, hair, clean tattoo-free skin, body shape and outfit follow <Image 1>-<Image {n}> and the {outfit} outfit reference set. She wears no {never}.\n<Audio 1>: {audio}',
    [['video', 'what is kept of the source'], ['tattoos', '"tattoos, " when the performer has them'], ['clean', 'tattoo/ring removal sentences'], ['n', 'how many images'],
      ['outfit', 'the outfit name'], ['never', 'never-add items joined with ", no "'], ['audio', 'fully_copy or replaced']], { allowEmpty: false }),
  d('video.edit.detailed', 'video', 'Edit · details', 'detailed_description of the structured Edit prompt (the user’s direction is added after it).',
    'The target video is in realistic photographic style, like a casual smartphone video. [Shot 1] <Subject 2> performs exactly the same motion as <Subject 1> with the same timing, wearing the {outfit}. '
    + 'Her skin is smooth and clean with no tattoos. Her face is sharp and detailed and matches <Image 1>, with natural skin texture, natural expressions, stable eyes, natural lips and teeth, and realistic hands with five fingers.',
    [['outfit', 'the outfit name']], { allowEmpty: false }),
  // ---------------------------------------------------------------- LoRA
  d('lora.variations', 'lora', 'Candidate variations', 'One per line. The 30 LoRA training candidates cycle through them.',
    ['window light, soft smile', 'golden hour outdoors, laughing', 'overcast street, neutral expression', 'studio softbox, looking over shoulder',
      'evening city lights, candid', 'bright kitchen, relaxed', 'beach at noon, full body', 'gym mirror, full body athletic wear', 'cafe table, three-quarter', 'night flash photo, close-up'].join('\n'),
    [], { kind: 'lines', allowEmpty: false }),
  d('lora.variation', 'lora', 'Variation line', 'Added under the sheet prompt of each candidate.', 'Variation: {variation}.', [['variation', 'one line of the list above', true]]),
  // AI suite (workstream 1): camera vocabulary and shot prompt parts, suite/prompts.ts
  ...SUITE_PROMPT_DEFS,
];

export type PromptKey = string;
export type PromptTexts = Record<PromptKey, string>;
const BY_KEY = new Map(PROMPT_DEFS.map(p => [p.key, p]));
export const promptDef = (key: string) => BY_KEY.get(key);
export const DEFAULT_TEXTS: PromptTexts = Object.freeze(Object.fromEntries(PROMPT_DEFS.map(p => [p.key, p.default]))) as PromptTexts;
export const allowEmpty = (p: PromptDef) => p.allowEmpty ?? !p.placeholders.some(x => x[2]);

const PH_RE = /\{([A-Za-z][A-Za-z0-9]*)\}/g;
export const MAX_PROMPT_CHARS = 4000;

/** Why `text` can't be saved for `key`, or null. Messages are shown as-is in the editor. */
export function validatePrompt(key: string, text: string): string | null {
  const def = BY_KEY.get(key);
  if (!def) return 'Unknown prompt';
  if (text.length > MAX_PROMPT_CHARS) return `Keep it under ${MAX_PROMPT_CHARS} characters`;
  const allowed = def.placeholders.map(p => p[0]);
  const used = new Set<string>();
  for (const m of text.matchAll(PH_RE)) {
    if (!allowed.includes(m[1]!)) {
      return allowed.length ? `Unknown placeholder {${m[1]}} · this prompt can use ${allowed.map(a => `{${a}}`).join(', ')}`
        : `Unknown placeholder {${m[1]}} · this prompt has no placeholders`;
    }
    used.add(m[1]!);
  }
  for (const [name, , req] of def.placeholders) if (req && !used.has(name)) return `Keep {${name}} · this prompt needs it`;
  if (!text.trim() && !allowEmpty(def)) return 'This prompt can’t be empty';
  return null;
}

/** Puts the values in. A placeholder with no value becomes empty. */
export const fill = (text: string, values: Record<string, string | number | null | undefined> = {}) =>
  text.replace(PH_RE, (_, k: string) => { const v = values[k]; return v == null ? '' : String(v); });

/** A "list" entry as items (comma-separated) or a "lines" entry (one per line). */
export const listOf = (text: string, kind: 'list' | 'lines' = 'list') =>
  text.split(kind === 'lines' ? /\r?\n/ : /,|\r?\n/).map(s => s.trim()).filter(Boolean);

/** Resolved texts: the defaults with the overrides that still name a known entry and still validate. */
export function resolveTexts(overrides: Record<string, string>): PromptTexts {
  const out: PromptTexts = { ...DEFAULT_TEXTS };
  for (const [k, v] of Object.entries(overrides)) if (BY_KEY.has(k) && validatePrompt(k, v) == null) out[k] = v;
  return out;
}
