// Every script (plans/prompt-scripts.md §3). The default rules reproduce the prompts exactly as the builders made them
// before scripts (the shared fixtures keep passing); the new branches are the lip-sync fix and the audio lines.
import type { Cond, InputDef, Rule, Script, Section } from './types.js';

// ---------------------------------------------------------------- helpers
const bool = (name: string, label: string, description: string, sample = true): InputDef => ({ name, label, description, type: 'bool', sample });
const num = (name: string, label: string, description: string, sample: number): InputDef => ({ name, label, description, type: 'number', sample });
const en = (name: string, label: string, description: string, options: [string, string][], sample?: string): InputDef =>
  ({ name, label, description, type: 'enum', options: options.map(([id, l]) => ({ id, label: l })), sample: sample ?? options[0]![0] });
const sec = (id: string, label: string, extra: Partial<Section> = {}): Section => ({ id, label, kind: 'system', pick: 'first', ...extra });
const R = (id: string, label: string, target: string, block: string, when: Cond[] = [], extra: Partial<Rule> = {}): Rule => ({ id, label, target, when, block, ...extra });
const is = (input: string, value: boolean | string | number): Cond => ({ input, op: 'is', value });

/**
 * One sample set for every preview (Settings → Prompts): three images of her (face, face ¾, body = images/panels 1–3),
 * the outfit (4) and one reference image (5) guiding the pose, look and scene. The prompt library's previews use it too.
 */
export const SAMPLE = {
  name: 'Demo model', look: 'young woman, shoulder-length dark brown hair, brown eyes, light olive skin', refCount: 3, outfitPanel: 4, refIndex: 5,
  style: 'realistic smartphone photo, natural skin texture, true-to-life colour, no beauty filter, no AI gloss',
  never: 'tattoos, rings, logos, extra fingers, warped jewellery',
  /** The cinematic variant: what a rig with a cinema body, lens and look puts in the prompt. */
  cinematic: {
    style: 'natural skin texture, true-to-life colour, no beauty filter, no AI gloss',
    grade: 'tungsten-balanced cinema film stock, cool shadows, glowing practicals',
    direction: 'Shot on 35mm motion-picture film, fine grain, gentle halation, organic colour; anamorphic lens, oval bokeh, horizontal blue lens flares.',
    camera: 'anamorphic cinema lens, 35mm motion-picture film',
  },
} as const;

const PRESETS = bool('presets', 'Presets on', 'The Presets switch. Off removes the optional style blocks (scene, camera, light, style, never-add).');
const REFS: InputDef = {
  name: 'refs', label: 'Reference images', description: 'The reference images sent (after her own), each with what it guides.', type: 'list',
  fields: [
    { name: 'refIndex', label: 'Image number', description: 'Its 1-based number among the images sent.', type: 'number', sample: 5 },
    { name: 'guides', label: 'Guides', description: 'What it guides.', type: 'list', options: [{ id: 'pose', label: 'Pose & framing' }, { id: 'look', label: 'Look & colour' }, { id: 'scene', label: 'Scene' }], sample: ['pose', 'look', 'scene'] },
  ],
  sample: [{ refIndex: 5, guides: ['pose', 'look', 'scene'] }],
};
const OUTFIT_SOURCE = en('outfitSource', 'Outfit', 'Where the outfit comes from.', [['set', 'Reference set (photos)'], ['described', 'Described in words'], ['product', 'Product photo']]);
const identity = (target = 'identity') => R('identity', 'Who she is', target, 'shoot.identity', [], { locked: true });
const outfitRules = (): Rule[] => [
  R('outfit.described', 'Outfit described in words', 'outfit', 'shoot.outfit.described', [is('outfitSource', 'described')]),
  R('outfit.product', 'Outfit from a product photo', 'outfit', 'shoot.outfit.product', [is('outfitSource', 'product')]),
  R('outfit.set', 'Outfit reference set', 'outfit', 'shoot.outfit.set'),
];
const refSection = () => sec('reference', 'Reference images', { each: 'refs', pick: 'all', join: ' ' });
const refRules = (): Rule[] => [
  R('refs.pose', 'Guides pose & framing', 'reference', 'refs.pose', [{ input: 'item.guides', op: 'has', value: 'pose' }]),
  R('refs.look', 'Guides look & colour', 'reference', 'refs.look', [{ input: 'item.guides', op: 'has', value: 'look' }]),
  R('refs.scene', 'Guides the scene', 'reference', 'refs.scene', [{ input: 'item.guides', op: 'has', value: 'scene' }]),
  R('refs.guard', 'Never her face, body or clothes from a reference', 'reference', 'refs.guard', [], { locked: true }),
];
const SHOOT_VARS = [
  { name: 'name', description: 'her name', sample: SAMPLE.name }, { name: 'look', description: 'her written look', sample: SAMPLE.look },
  { name: 'refCount', description: 'how many images of her are sent', sample: String(SAMPLE.refCount) }, { name: 'lora', description: '" + LoRA demo_v2 (photo)" or empty', sample: '' },
  { name: 'outfit', description: 'the outfit', sample: 'green set' },
  { name: 'style', description: 'the house style: camera feel (unless the shot has its own camera) and realism (script "House style")', sample: SAMPLE.style },
  { name: 'never', description: 'her never-add list plus the base list', sample: SAMPLE.never },
];
const OWN_CAMERA = bool('ownCamera', 'Has its own camera', 'A rig or preset sets a camera body, lens, grade or look. Then the camera feel and the default grade are left out and its own words stand.', false);

// ---------------------------------------------------------------- house style (owner 2026-11-11)
/** The house style of every photo: Camera feel only when the shot has no camera of its own, then Realism (always). */
const houseStyle: Script = {
  id: 'style.house', group: 'photoshoot', title: 'House style',
  description: 'The {style} of shoots, template shoots, sheet fills and outfit sets: Camera feel, unless a rig or preset sets its own camera body, lens, grade or look, then Realism. Video Suite shots don’t use it.',
  format: 'lines', inputs: [OWN_CAMERA],
  sections: [sec('camera', 'Camera feel'), sec('realism', 'Realism')],
  rules: [
    R('camera.feel', 'Camera feel (the shot has no camera of its own)', 'camera', 'style.camera', [is('ownCamera', false)]),
    R('realism', 'Realism (always)', 'realism', 'style.realism', [], { locked: true }),
  ],
};

// ---------------------------------------------------------------- photo scripts
const photoshoot: Script = {
  id: 'photoshoot', group: 'photoshoot', title: 'Photo', description: 'Every still of the Photo tool (no template).', format: 'lines',
  inputs: [PRESETS, bool('lockSeed', 'Lock look', 'Lock look is on (a fixed seed for her).', false), OUTFIT_SOURCE,
    num('lens', 'Lens (mm)', 'The lens in mm.', 35), REFS, OWN_CAMERA,
    bool('noGrade', 'No grade', 'No grade was picked and the shot has its own camera, lens or look: the default grade is left out.', false)],
  sections: [sec('identity', 'Identity'), sec('outfit', 'Outfit'), sec('scene', 'Scene'), sec('camera', 'Camera'), sec('light', 'Light'),
    { id: 'direction', label: 'Direction from the user', kind: 'user', pick: 'first' }, refSection(), sec('style', 'Style'), sec('negative', 'Never add'), sec('seed', 'Seed')],
  values: [{ name: 'lensNote', label: 'Lens note' }],
  rules: [
    identity(), ...outfitRules(),
    R('scene', 'The place', 'scene', 'shoot.scene', [], { optional: true }),
    R('camera', 'Shot size, lens and aperture', 'camera', 'shoot.camera', [], { optional: true }),
    R('lens.wide', 'Wide lens note (24 mm and wider)', '@lensNote', 'shoot.camera.wide', [{ input: 'lens', op: 'atMost', value: 24 }]),
    R('lens.tele', 'Long lens note (85 mm and longer)', '@lensNote', 'shoot.camera.tele', [{ input: 'lens', op: 'atLeast', value: 85 }]),
    R('light.only', 'Light without a grade (its own camera sets the colour)', 'light', 'shoot.light.only', [is('noGrade', true)], { optional: true }),
    R('light', 'Light and grade', 'light', 'shoot.light', [], { optional: true }),
    R('direction', 'The user’s direction', 'direction', 'shoot.direction', [], { locked: true }),
    ...refRules(),
    R('style', 'House style', 'style', 'shoot.style', [], { optional: true }),
    R('never', 'Never add', 'negative', 'shoot.never', [], { optional: true, locked: true }),
    R('seed.locked', 'Lock look on', 'seed', 'shoot.seed.locked', [is('lockSeed', true)]),
    R('seed.new', 'New look each shot', 'seed', 'shoot.seed.new'),
  ],
  vars: [...SHOOT_VARS, { name: 'scene', description: 'the scene, lower case', sample: 'rooftop · golden hour' }, { name: 'shot', description: 'close, medium, full or wide', sample: 'medium' },
    { name: 'aperture', description: 'f/2.8 …', sample: 'f/2.8' }, { name: 'light', description: 'the light, lower case', sample: 'golden hour' }, { name: 'grade', description: 'the grade, lower case (the default grade unless the shot has its own camera)', sample: 'phone-natural' }],
};

const template: Script = {
  id: 'template', group: 'templates', title: 'Template shoot', description: 'A still made from a photo template. Two views: the full prompt (sent, and shown to the template’s maker) and the visible one (everyone else).',
  format: 'lines',
  inputs: [en('view', 'View', 'Which view is built.', [['full', 'Full (sent to the model)'], ['visible', 'Visible to members']]),
    en('outfitSource', 'Outfit', 'Where the outfit comes from.', [['set', 'Reference set'], ['described', 'Described in words'], ['none', 'No outfit']]),
    bool('hasScene', 'Has a scene', 'The template or the draw gives a scene, background or time of day.'), bool('hasCamera', 'Has a camera', 'The template or the draw gives camera words.'),
    bool('hasLight', 'Has light', 'The template gives light words.'), bool('hasPose', 'Has a pose', 'The draw gives a pose, body angle, expression or hands.'),
    en('product', 'Product', 'The template’s product layer.', [['none', 'No product'], ['photo', 'With a product photo'], ['noPhoto', 'No product photo']]),
    en('seed', 'Seed', 'How the seed is chosen.', [['locked', 'Lock look'], ['known', 'A new seed, known'], ['none', 'No seed yet']]), REFS,
    { ...OWN_CAMERA, description: 'The template’s camera words name a camera that is not a phone, or its style is cinematic: the camera feel is left out of the house style.' }],
  sections: [sec('identity', 'Identity'), sec('outfit', 'Outfit'), sec('scene', 'Scene'), sec('camera', 'Camera'), sec('light', 'Light'), sec('pose', 'Pose'),
    sec('template', 'Locked template line'), { id: 'direction', label: 'Direction from the user', kind: 'user', pick: 'first' }, refSection(),
    sec('product', 'Product'), sec('style', 'Style'), sec('negative', 'Never add'), sec('seed', 'Seed')],
  rules: [
    identity(),
    R('outfit.described', 'Outfit described in words', 'outfit', 'shoot.outfit.described', [is('outfitSource', 'described')]),
    R('outfit.set', 'Outfit reference set', 'outfit', 'shoot.outfit.set', [is('outfitSource', 'set')]),
    R('scene', 'Scene', 'scene', 'template.scene', [is('view', 'full'), is('hasScene', true)]),
    R('camera', 'Camera', 'camera', 'template.camera', [is('view', 'full'), is('hasCamera', true)]),
    R('light', 'Light', 'light', 'template.light', [is('view', 'full'), is('hasLight', true)]),
    R('pose', 'Pose', 'pose', 'template.pose', [is('view', 'full'), is('hasPose', true)]),
    R('locked', 'Members see one locked line', 'template', 'template.locked', [is('view', 'visible')], { locked: true }),
    R('direction', 'The user’s direction', 'direction', 'shoot.direction', [], { locked: true }),
    ...refRules(),
    R('product.photo', 'Product with a photo', 'product', 'template.product', [is('view', 'full'), is('product', 'photo')]),
    R('product.none', 'Product without a photo', 'product', 'template.product.none', [is('view', 'full'), is('product', 'noPhoto')]),
    R('style', 'Template style + house style', 'style', 'template.style', [is('view', 'full')]),
    R('never', 'Never add', 'negative', 'shoot.never', [], { locked: true }),
    R('seed.locked', 'Lock look on', 'seed', 'template.seed.locked', [is('seed', 'locked')]),
    R('seed.known', 'New seed each shot', 'seed', 'template.seed.new', [is('seed', 'known')]),
    R('seed.none', 'No seed yet', 'seed', 'shoot.seed.new'),
  ],
  vars: [...SHOOT_VARS, { name: 'scene', description: 'scene words', sample: 'bedroom mirror' }, { name: 'camera', description: 'camera words', sample: 'phone in hand' },
    { name: 'pose', description: 'pose words', sample: 'mid-step' }, { name: 'product', description: 'product words', sample: 'held up' }, { name: 'seed', description: 'the seed', sample: '421337' }],
};

const sheetSections = () => [sec('identity', 'Identity'), sec('task', 'Task'), sec('style', 'Style'), sec('negative', 'Never add')];
const sheetRules = () => [identity(), R('task', 'Sheet shot', 'task', 'sheet.task'), R('style', 'House style', 'style', 'shoot.style'), R('never', 'Never add', 'negative', 'shoot.never', [], { locked: true })];
const ANGLE = en('angle', 'Angle', 'Which sheet image.', [['face', 'Face · front'], ['profile', 'Face · profile'], ['front', 'Body · front'], ['tq', 'Body · ¾'], ['side', 'Body · side'], ['back', 'Body · back'], ['faceTq', 'Face · ¾']], 'front');
const sheet: Script = {
  id: 'sheet', group: 'sheet', title: 'Character sheet image', description: 'One image of her character sheet (fill angles).', format: 'lines',
  inputs: [ANGLE], sections: sheetSections(), rules: sheetRules(),
  vars: [...SHOOT_VARS, { name: 'angle', description: 'body · front …', sample: 'body · front' }, { name: 'framing', description: 'full body, facing the camera …', sample: 'full body, facing the camera' }],
};
const loraCandidate: Script = {
  id: 'lora.candidate', group: 'lora', title: 'LoRA candidate', description: 'One of the 30 LoRA training candidates: a sheet image plus a variation.', format: 'lines',
  inputs: [ANGLE], sections: [...sheetSections(), sec('variation', 'Variation')],
  rules: [...sheetRules(), R('variation', 'Variation', 'variation', 'lora.variation')],
  vars: [...sheet.vars!, { name: 'variation', description: 'one line of the variations list', sample: 'window light, soft smile' }],
};
const outfitAngle: Script = {
  id: 'outfit.angle', group: 'outfits', title: 'Outfit set angle', description: 'One angle of an outfit set (made from scratch).', format: 'lines',
  inputs: [OUTFIT_SOURCE, en('angle', 'Angle', 'Which angle.', [['front', 'Front'], ['tq', '¾'], ['side', 'Side'], ['back', 'Back']])],
  sections: [sec('identity', 'Identity'), sec('outfit', 'Outfit'), sec('task', 'Task'), sec('style', 'Style'), sec('negative', 'Never add'), sec('seed', 'Seed')],
  rules: [identity(), ...outfitRules(), R('task', 'Angle task', 'task', 'outfit.task'), R('style', 'House style', 'style', 'shoot.style'),
    R('never', 'Never add', 'negative', 'shoot.never', [], { locked: true }), R('seed', 'Shared seed', 'seed', 'outfit.seed')],
  vars: [...SHOOT_VARS, { name: 'angle', description: 'full body front view …', sample: 'full body front view' }, { name: 'seed', description: 'the seed', sample: '421337' }],
};
const single = (id: string, group: string, title: string, description: string, block: string, inputs: InputDef[] = []): Script =>
  ({ id, group, title, description, format: 'lines', inputs, sections: [sec('prompt', 'Prompt')], rules: [R('prompt', title, 'prompt', block)] });
const outfitEdit = single('outfit.edit', 'outfits', 'Outfit set · other angles', 'The ¾, side and back of an outfit set, as edits of the front.', 'outfit.edit');
const enhance = single('enhance', 'enhance', 'Enhance', 'Enhance step 1, for every image of the sheet.', 'enhance.prompt');

// ---------------------------------------------------------------- video: character swap (motion from a source clip)
const SPEAKING = bool('speaking', 'Performer is speaking', 'The performer speaks or sings in the clip (detected from its audio; the user can switch it). Off: the clip is sent without audio and its audio is put back afterwards.');
const userSection = (): Section => ({ id: 'user', label: 'Direction from the user', kind: 'user', pick: 'first' });
const userRule = () => R('user', 'The user’s direction', 'user', 'video.user.direction', [], { locked: true });

const videoReplicate: Script = {
  id: 'video.replicate', group: 'video', title: 'Character swap · Draft/Standard/HD', description: 'The short prompt for the hosted video model: her face, body and outfit replace the performer of the clip.',
  format: 'sections',
  inputs: [SPEAKING, bool('audioSent', 'Clip audio sent', 'The clip is sent with its audio (only when the performer speaks).'),
    bool('newBackground', 'Background: Describe it', 'The user’s direction describes a new place; the clip’s moves and timing are kept, not its background.', false)],
  sections: [sec('subjects', 'Subjects', { heading: 'subject_definitions:' }), sec('summary', 'Summary', { heading: 'summary:' }),
    sec('retention', 'Retention', { heading: 'retention_analysis:' }), sec('detailed', 'Details', { heading: 'detailed_description:', pick: 'all', join: ' ' }), userSection()],
  rules: [
    R('subjects', 'Who is who', 'subjects', 'video.replicate.subjects', [], { locked: true }),
    R('summary.describe.silent', 'New background, not speaking', 'summary', 'video.replicate.summary.describe.silent', [is('newBackground', true), is('speaking', false)]),
    R('summary.describe', 'New background from the direction', 'summary', 'video.replicate.summary.describe', [is('newBackground', true)]),
    R('summary.silent', 'Not speaking: no lip-sync', 'summary', 'video.replicate.summary.silent', [is('speaking', false)]),
    R('summary', 'Copy the facial performance', 'summary', 'video.replicate.summary'),
    R('retention.describe', 'What is kept (new background)', 'retention', 'video.replicate.retention.describe', [is('newBackground', true)], { locked: true }),
    R('retention', 'What is kept', 'retention', 'video.replicate.retention', [], { locked: true }),
    R('detailed.describe', 'Details (new background)', 'detailed', 'video.replicate.detailed.describe', [is('newBackground', true)]),
    R('detailed.silent', 'Not speaking: no mouthed words', 'detailed', 'video.replicate.detailed.silent', [is('speaking', false), is('newBackground', false)]),
    R('detailed', 'Details', 'detailed', 'video.replicate.detailed', [is('speaking', true), is('newBackground', false)]),
    R('mouth.speaking', 'Speaking: mouth in sync with the speech', 'detailed', 'video.mouth.speaking', [is('speaking', true)]),
    R('mouth.silent', 'Not speaking: mouth follows the clip, no words', 'detailed', 'video.mouth.silent', [is('speaking', false)]),
    userRule(),
  ],
  vars: [{ name: 'subject', description: 'the person in <Image 1> to <Image n>: her look', sample: 'the person in <Image 1> to <Image 5>: young woman' },
    { name: 'reference', description: 'face, body and outfit image ranges and the never-add list', sample: 'face and identity from <Image 1> and <Image 2>' },
    { name: 'faceRef', description: '<Image 1>, or "the description"', sample: '<Image 1>' }],
};

const videoEdit: Script = {
  id: 'video.edit', group: 'video', title: 'Character swap · Edit', description: 'The structured prompt for Edit: her face, body and outfit replace the performer of the clip.',
  format: 'sections',
  inputs: [SPEAKING, bool('keepAudio', 'Keep audio', 'The clip’s audio is kept (and sent with the clip).'), bool('keepBackground', 'Keep background', 'The background of the clip is kept (else a background photo replaces it).'),
    bool('describeBackground', 'Background: Describe it', 'The user’s direction describes the new place (no photo).', false)],
  sections: [sec('subjects', 'Subjects', { heading: 'subject_definitions:', alias: { audio: 'audioSubjects' } }),
    sec('summary', 'Summary', { heading: 'summary:', alias: { audio: 'audioSummary' } }),
    sec('retention', 'Retention', { heading: 'retention_analysis:', alias: { audio: 'audioRetention' } }),
    sec('detailed', 'Details', { heading: 'detailed_description:', pick: 'all', join: ' ' }), userSection()],
  values: [{ name: 'audioSubjects', label: 'Audio track line', prefix: '\n' }, { name: 'audioTag', label: 'Audio tag', prefix: ' ' },
    { name: 'audioSummary', label: 'Audio sentence', prefix: ' ' }, { name: 'audioRetention', label: 'Audio retention' },
    { name: 'background', label: 'Background sentence' }, { name: 'video', label: 'Source retention' }],
  rules: [
    R('audio.subjects', 'Audio track line (audio kept)', '@audioSubjects', 'video.edit.audio.subjects', [is('keepAudio', true)]),
    R('audio.tag', 'Audio tag (audio kept)', '@audioTag', 'video.edit.audio.tag', [is('keepAudio', true)]),
    R('audio.summary', 'Audio sentence (audio kept)', '@audioSummary', 'video.edit.audio.summary', [is('keepAudio', true)]),
    R('audio.kept', 'Audio kept', '@audioRetention', 'video.edit.audio.kept', [is('keepAudio', true)]),
    R('audio.replaced', 'Audio replaced', '@audioRetention', 'video.edit.audio.replaced'),
    R('background.keep', 'Background kept', '@background', 'video.edit.background.keep', [is('keepBackground', true)]),
    R('background.describe', 'Background described', '@background', 'video.edit.background.describe', [is('describeBackground', true)]),
    R('background.photo', 'Background photo', '@background', 'video.edit.background.photo'),
    R('video.keep', 'Source kept', '@video', 'video.edit.video.keep', [is('keepBackground', true)]),
    R('video.describe', 'Source, background described', '@video', 'video.edit.video.describe', [is('describeBackground', true)]),
    R('video.photo', 'Source, new background', '@video', 'video.edit.video.photo'),
    R('subjects', 'Who is who', 'subjects', 'video.edit.subjects', [], { locked: true }),
    R('summary', 'Copy every movement', 'summary', 'video.edit.summary'),
    R('retention', 'What is kept', 'retention', 'video.edit.retention', [], { locked: true }),
    R('detailed', 'Details', 'detailed', 'video.edit.detailed'),
    R('mouth.speaking', 'Speaking: mouth in sync with the speech', 'detailed', 'video.mouth.speaking', [is('speaking', true)]),
    R('mouth.silent', 'Not speaking: mouth follows the clip, no words', 'detailed', 'video.mouth.silent', [is('speaking', false)]),
    userRule(),
  ],
  vars: [{ name: 'performer', description: 'the source performer', sample: 'the person' }, { name: 'setting', description: 'the source setting', sample: 'the room' },
    { name: 'refs', description: '<Image 1> (face, front), …', sample: '<Image 1> (face, front)' }, { name: 'motion', description: '" (subtly alive)" or empty', sample: '' },
    { name: 'tattoos', description: '"tattoos, " or empty', sample: '' }, { name: 'clean', description: 'tattoo/ring removal sentences', sample: '' },
    { name: 'n', description: 'how many images', sample: '6' }],
};

// ---------------------------------------------------------------- video: audio lines for generation without a motion source
const audioLine: Script = {
  id: 'video.audio', group: 'video', title: 'Audio line (AI suite)', format: 'lines',
  description: 'The audio sentence of a generated shot: lip-sync when she speaks, beat only when music drives the rhythm but nobody sings, nothing when no audio is sent.',
  inputs: [en('audio', 'Audio sent', 'The reference audio sent with the shot.', [['speech', 'Speech or singing'], ['music', 'Music (instrumental only)'], ['none', 'None']]), SPEAKING],
  sections: [sec('audio', 'Audio')],
  rules: [
    R('lipsync', 'Speaking: lip-sync', 'audio', 'audio.lipsync', [{ input: 'audio', op: 'isNot', value: 'none' }, is('speaking', true)]),
    R('beat', 'Music, not speaking: beat only', 'audio', 'audio.beat', [is('audio', 'music'), is('speaking', false)]),
    R('silent', 'Not speaking', 'audio', 'audio.silent', [is('speaking', false)]),
  ],
  vars: [{ name: 'subject', description: '<Subject 1> …', sample: '<Subject 1>' }, { name: 'audio', description: '<Audio 1> …', sample: '<Audio 1>' }],
};

// ---------------------------------------------------------------- reference sheet (one-image shot models)
const collage: Script = {
  id: 'refs.collage', group: 'references', title: 'Reference sheet line', format: 'lines',
  description: 'First line of a photo prompt when the shot model takes one image and MUSE sends one reference sheet of numbered panels.',
  inputs: [{ name: 'panels', label: 'Panels', description: 'The sheet’s panels in order (her own images first).', type: 'list',
    fields: [{ name: 'panel', label: 'Panel number', description: '1-based.', type: 'number', sample: 4 },
      { name: 'role', label: 'Shows', description: 'What the panel shows.', type: 'enum', options: [{ id: 'person', label: 'Her' }, { id: 'outfit', label: 'The outfit' }, { id: 'product', label: 'The product' }, { id: 'ref', label: 'A reference image' }], sample: 'outfit' },
      { name: 'guides', label: 'Guides', description: 'A reference image’s guides, in words.', type: 'text', sample: 'pose & framing' }],
    sample: [{ panel: 1, role: 'person', guides: '' }, { panel: 2, role: 'person', guides: '' }, { panel: 3, role: 'person', guides: '' }, { panel: 4, role: 'outfit', guides: '' }, { panel: 5, role: 'ref', guides: 'pose & framing and the look & colour and the scene' }] }],
  sections: [sec('sheet', 'Reference sheet', { layer: 'sheet' })],
  values: [{ name: 'panels', label: 'Other panels', each: 'panels', itemPrefix: '; ' }],
  rules: [
    R('panel.outfit', 'Outfit panel', '@panels', 'refs.collage.outfit', [is('item.role', 'outfit')]),
    R('panel.product', 'Product panel', '@panels', 'refs.collage.product', [is('item.role', 'product')]),
    R('panel.ref', 'Reference panel', '@panels', 'refs.collage.ref', [is('item.role', 'ref')]),
    R('sheet', 'Reference sheet', 'sheet', 'refs.collage', [], { locked: true }),
  ],
  vars: [{ name: 'person', description: '"panel 1 shows" / "panels 1–3 show"', sample: 'panels 1–3 show' }],
};

export const SCRIPTS: Script[] = [collage, houseStyle, photoshoot, template, sheet, outfitAngle, outfitEdit, enhance, loraCandidate, videoReplicate, videoEdit, audioLine];
const BY_ID = new Map(SCRIPTS.map(s => [s.id, s]));
export const scriptDef = (id: string) => BY_ID.get(id);
/**
 * Adds a script defined elsewhere (the AI suite's shot scripts, workstream 1). Its blocks must be library keys.
 * Registering the same id again replaces it (hot reload, tests).
 */
export function registerScript(s: Script) {
  const i = SCRIPTS.findIndex(x => x.id === s.id);
  if (i >= 0) SCRIPTS[i] = s; else SCRIPTS.push(s);
  BY_ID.set(s.id, s);
}
