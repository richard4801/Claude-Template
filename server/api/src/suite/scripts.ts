// AI suite prompts as prompt scripts (workstream 4's engine, plans/prompt-scripts.md): typed inputs → owner-editable
// rules → owner-editable blocks. `suite.camera` assembles the Camera block per model family; `suite.shot` the whole
// shot prompt. System sections never see the user's words; the scene section (kind "user") is the only one that does.
// The per-model limits (one-move rule, reference subsets, tokens, enums) stay in code and arrive as vars and inputs.
import { registerScript } from '../prompt/scripts/defs.js';
import type { Cond, InputDef, Rule, Script, Section } from '../prompt/scripts/types.js';

const bool = (name: string, label: string, description: string, sample = true): InputDef => ({ name, label, description, type: 'bool', sample });
const en = (name: string, label: string, description: string, options: [string, string][], sample?: string): InputDef =>
  ({ name, label, description, type: 'enum', options: options.map(([id, l]) => ({ id, label: l })), sample: sample ?? options[0]![0] });
const sec = (id: string, label: string, extra: Partial<Section> = {}): Section => ({ id, label, kind: 'system', pick: 'first', ...extra });
const R = (id: string, label: string, target: string, block: string, when: Cond[] = [], extra: Partial<Rule> = {}): Rule => ({ id, label, target, when, block, ...extra });
const is = (input: string, value: boolean | string | number): Cond => ({ input, op: 'is', value });

export const SUITE_CAMERA_SCRIPT: Script = {
  id: 'suite.camera', group: 'suite', title: 'Camera block (AI suite)', format: 'lines',
  description: 'The Camera block of a generated shot, in the wording style the shot’s model reads best. The option wording is in the suite.camera.* lists.',
  inputs: [en('vocab', 'Model family', 'Which wording style the shot’s model gets.',
    [['kling', 'Short commands'], ['seedance', 'Tagged blocks'], ['h3', 'Camera vocabulary'], ['veo', 'Descriptive sentence'], ['generic', 'Other']], 'kling')],
  sections: [sec('camera', 'Camera')],
  rules: [
    R('kling', 'Short commands', 'camera', 'suite.camera.format.kling', [is('vocab', 'kling')]),
    R('seedance', 'Tagged blocks', 'camera', 'suite.camera.format.seedance', [is('vocab', 'seedance')]),
    R('h3', 'Camera vocabulary', 'camera', 'suite.camera.format.h3', [is('vocab', 'h3')]),
    R('veo', 'Descriptive sentence', 'camera', 'suite.camera.format.veo', [is('vocab', 'veo')]),
    R('generic', 'Everything else', 'camera', 'suite.camera.format.generic'),
  ],
  vars: [
    { name: 'move', description: 'the camera move(s), with intensity and speed', sample: 'slow physical dolly-in toward the subject about 1.4 m' },
    { name: 'framing', description: 'shot size and camera height', sample: 'medium close-up from the chest up, eye-level camera' },
    { name: 'rig', description: 'body, focal length, lens, aperture, look, frame rate', sample: '35mm motion-picture film, 50mm lens (natural perspective), f/2, shallow depth of field' },
    { name: 'light', description: 'lighting', sample: 'low golden-hour sun, long warm shadows' },
    { name: 'palette', description: 'colour palette', sample: 'teal-and-orange blockbuster grade' },
    { name: 'style', description: 'genre, era, tempo', sample: 'dramatic, calm lingering pacing' },
    { name: 'performance', description: 'the emotion line', sample: 'Performance: clear hope, turning to joy at 3s.' },
  ],
};

const REFS: InputDef = {
  name: 'refs', label: 'Extra references', description: 'Product, location, style, prop or person images sent after hers.', type: 'list',
  fields: [
    en('kind', 'Kind', 'What the image is.', [['product', 'Product'], ['location', 'Location'], ['style', 'Style'], ['prop', 'Prop'], ['person', 'Another person']]),
    { name: 'ref', label: 'Token', description: 'How the prompt names the image (<Image 6>, @image_6, [Image6]).', type: 'text', sample: '<Image 6>' },
    { name: 'role', label: 'Role words', description: '"the product (the perfume bottle)".', type: 'text', sample: 'the product' },
    { name: 'use', label: 'Use', description: 'What to take from it.', type: 'text', sample: 'shape, colours, packaging and label' },
  ],
  sample: [{ kind: 'product', ref: '<Image 6>', role: 'the product (the perfume bottle)', use: 'shape, colours, packaging and label' }],
};
const VIDEOS: InputDef = {
  name: 'videos', label: 'Guide and reference videos', description: 'The guide clip first, then other reference videos.', type: 'list',
  fields: [
    en('kind', 'Use', 'What is taken from it.', [['camera', 'Camera'], ['blocking', 'Camera and blocking'], ['motion', 'Motion'], ['style', 'Style']]),
    { name: 'video', label: 'Token', description: 'How the prompt names the video.', type: 'text', sample: '<Video 1>' },
    { name: 'use', label: 'Use words', description: '"camera movement and framing".', type: 'text', sample: 'camera movement and framing' },
  ],
  sample: [{ kind: 'blocking', video: '<Video 1>', use: 'camera movement, framing, blocking and positions' }],
};
const SPEAKING = bool('speaking', 'Performer is speaking', 'She speaks or sings on camera (the switch, else the uploaded audio’s talking flag, else detection, else no).', false);
const AUDIO = en('audio', 'Audio sent', 'The reference audio sent with the shot.', [['speech', 'Speech or singing'], ['music', 'Music (instrumental only)'], ['none', 'None']], 'none');

export const SUITE_SHOT_SCRIPT: Script = {
  id: 'suite.shot', group: 'suite', title: 'Shot (AI suite)', format: 'lines',
  description: 'Every shot from the AI suite: who she is, her outfit, extra references, keyframes, the user’s scene, guide clips, the Camera block, the audio line.',
  inputs: [
    bool('hasCharacter', 'Has a character', 'A MUSE model is in the shot.'),
    bool('characterImages', 'Her images are sent', 'Her sheet images go to the model (some models take none, or keyframes carry her look).'),
    bool('hasOutfit', 'Has an outfit', 'An outfit is chosen.'),
    REFS, bool('mixedRoles', 'Several kinds of reference', 'More than one kind of reference image is sent (her, a product, a location …).', false),
    bool('hasFrames', 'Keyframes', 'Start, middle or end frames are sent.', false),
    VIDEOS, bool('hasCamera', 'Camera set', 'The Camera control produced a block.'),
    AUDIO, SPEAKING, bool('hasAvoid', 'Things to avoid', 'The camera move has things the model must not do instead (no zoom …).', false),
  ],
  sections: [
    sec('character', 'Character'), sec('outfit', 'Outfit', { alias: { refs: 'outfitRefs' } }), sec('reference', 'Extra references', { each: 'refs', pick: 'all' }), sec('lock', 'Reference lock'),
    sec('frames', 'Keyframes'), { id: 'scene', label: 'The user’s scene', kind: 'user', pick: 'first' }, sec('guide', 'Guide clips', { each: 'videos', pick: 'all' }),
    sec('camera', 'Camera'), sec('audio', 'Audio'), sec('avoid', 'Avoid'), sec('footer', 'Closing line'),
  ],
  rules: [
    R('character.images', 'Who she is (with her images)', 'character', 'suite.shot.character', [is('characterImages', true)], { locked: true }),
    R('character.words', 'Who she is (in words)', 'character', 'suite.shot.character.words', [is('hasCharacter', true)], { locked: true }),
    R('outfit', 'Her outfit', 'outfit', 'suite.shot.outfit', [is('hasOutfit', true)]),
    R('reference', 'An extra reference', 'reference', 'suite.shot.reference'),
    R('lock', 'References keep their roles', 'lock', 'suite.shot.lock', [is('mixedRoles', true)]),
    R('frames', 'Keyframes', 'frames', 'suite.shot.frames', [is('hasFrames', true)]),
    R('scene', 'The user’s scene', 'scene', 'suite.shot.scene', [], { locked: true }),
    R('guide', 'A guide or reference video', 'guide', 'suite.shot.guide'),
    R('camera', 'The Camera block', 'camera', 'suite.shot.camera', [is('hasCamera', true)]),
    // Mouth and speech wording comes only from these audio rules (the lip-sync fix, workstream 4).
    R('audio.lipsync', 'Speaking: lip-sync to the audio', 'audio', 'audio.lipsync', [{ input: 'audio', op: 'isNot', value: 'none' }, is('speaking', true)]),
    R('audio.beat', 'Music, not speaking: beat only', 'audio', 'audio.beat', [is('audio', 'music'), is('speaking', false)]),
    R('audio.dialogue', 'Speaking, no audio sent: says the quoted lines', 'audio', 'suite.audio.dialogue', [is('audio', 'none'), is('speaking', true)]),
    R('audio.silent', 'Not speaking', 'audio', 'audio.silent', [is('speaking', false)]),
    R('avoid', 'Things to avoid', 'avoid', 'suite.shot.avoid', [is('hasAvoid', true)]),
    R('footer', 'Closing line', 'footer', 'suite.shot.footer'),
  ],
  vars: [
    { name: 'name', description: 'her name', sample: 'Demo model' }, { name: 'look', description: 'her look', sample: 'young woman, dark hair' },
    { name: 'refs', description: 'her image tokens', sample: '<Image 1>, <Image 2> and <Image 3>' }, { name: 'never', description: 'the never-add sentence', sample: ' She never has: tattoos.' },
    { name: 'outfit', description: 'the outfit', sample: 'green set' }, { name: 'outfitRefs', description: '" as shown in <Image 4>" or empty', sample: ' as shown in <Image 4>' },
    { name: 'start', description: 'the start frame words', sample: 'the start frame' }, { name: 'middle', description: 'the middle frames words', sample: '' },
    { name: 'end', description: 'the end frame words', sample: ' and ends exactly on the end frame' }, { name: 'camera', description: 'the Camera block (script suite.camera)', sample: 'Camera: slow dolly-in.' },
    { name: 'subject', description: 'who speaks or moves', sample: 'Demo model' }, { name: 'audio', description: 'the audio token', sample: '<Audio 1>' },
    { name: 'avoid', description: 'the things to avoid', sample: 'No zoom.' },
  ],
};

registerScript(SUITE_CAMERA_SCRIPT);
registerScript(SUITE_SHOT_SCRIPT);

// ---------------------------------------------------------------- Recast: up to 4 people in one source clip
const PEOPLE: InputDef = {
  name: 'people', label: 'People recast', description: 'Each person in the source clip and the character who replaces them, in order.', type: 'list',
  fields: [
    { name: 'who', label: 'Who in the clip', description: '"the person on the left", "the second person to appear" …', type: 'text', sample: 'the person on the left' },
    { name: 'name', label: 'Character', description: 'Her name.', type: 'text', sample: 'Mia' },
    { name: 'refs', label: 'Her images', description: 'Her image tokens.', type: 'text', sample: '<Image 1> and <Image 2>' },
    { name: 'look', label: 'Her look', description: 'Her written look.', type: 'text', sample: 'young woman, dark hair' },
    { name: 'outfit', label: 'Outfit words', description: '" She wears the green set (<Image 3>)." or empty.', type: 'text', sample: ' She wears the green set (<Image 3>).' },
    { name: 'never', label: 'Never-add', description: '" She never has: tattoos." or empty.', type: 'text', sample: '' },
    { name: 'faceRef', label: 'Face crop', description: 'The token of a crop showing which person this is, or empty.', type: 'text', sample: '' },
    en('speaking', 'Speaking', 'Whether this person speaks or sings in the clip.', [['yes', 'Speaking'], ['no', 'Not speaking'], ['unknown', 'Unknown (follow the clip)']], 'unknown'),
  ],
  sample: [{ who: 'the person on the left', name: 'Mia', refs: '<Image 1> and <Image 2>', look: 'young woman, dark hair', outfit: '', never: '', faceRef: '', speaking: 'yes' },
    { who: 'the person on the right', name: 'Leo', refs: '<Image 3>', look: 'young man, short hair', outfit: '', never: '', faceRef: '<Image 4>', speaking: 'no' }],
};
export const SUITE_RECAST_SCRIPT: Script = {
  id: 'suite.recast', group: 'suite', title: 'Recast (AI suite)', format: 'lines',
  description: 'Same take, new cast: up to 4 people in one clip replaced by studio characters; motion, camera, cuts and the original audio are kept.',
  inputs: [
    PEOPLE, bool('several', 'Several people', 'More than one person is recast.', true),
    bool('keepsCuts', 'Keep cuts', 'The model keeps the clip’s cuts and shot changes (multi-shot clips).'),
  ],
  sections: [
    sec('task', 'Task'), sec('person', 'Each person', { each: 'people', pick: 'all', join: ' ' }), sec('identify', 'Who is who', { each: 'people', pick: 'all' }),
    sec('lock', 'Cast lock'), sec('mouth', 'Mouths and voices', { each: 'people', pick: 'first' }), sec('cuts', 'Cuts'),
    { id: 'direction', label: 'Direction from the user', kind: 'user', pick: 'first' }, sec('footer', 'Closing line'),
  ],
  rules: [
    R('task', 'What recast does', 'task', 'suite.recast.task', [], { locked: true }),
    R('person', 'Who replaces whom', 'person', 'suite.recast.person', [], { locked: true }),
    R('identify', 'A face crop says who is who', 'identify', 'suite.recast.identify', [{ input: 'item.faceRef', op: 'notEmpty' }]),
    R('lock', 'Nobody swaps looks', 'lock', 'suite.recast.lock', [is('several', true)]),
    // Mouth wording per person only from these rules (the lip-sync fix): never invent speech for someone who doesn't talk.
    R('mouth.speaking', 'Speaking: lips match the original audio', 'mouth', 'suite.recast.mouth.speaking', [is('item.speaking', 'yes')]),
    R('mouth.silent', 'Not speaking: does not speak or mouth words', 'mouth', 'suite.recast.mouth.silent', [is('item.speaking', 'no')]),
    R('mouth.follow', 'Unknown: the mouth follows the clip', 'mouth', 'suite.recast.mouth.follow', [is('item.speaking', 'unknown')]),
    R('cuts', 'Keep every cut', 'cuts', 'suite.recast.cuts', [is('keepsCuts', true)]),
    R('direction', 'The user’s direction', 'direction', 'suite.recast.direction', [], { locked: true }),
    R('footer', 'Closing line', 'footer', 'suite.shot.footer'),
  ],
  vars: [
    { name: 'source', description: 'the source clip token', sample: '<Video 1>' },
    { name: 'count', description: '"one person" / "2 people"', sample: '2 people' },
  ],
};
registerScript(SUITE_RECAST_SCRIPT);
