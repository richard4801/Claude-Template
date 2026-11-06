// AI suite · owner-editable wording (prompt library group "suite"). Camera vocab lists are "lines" entries, one
// "id: wording" per line; a line the owner deletes falls back to the default, an unknown id is ignored.
import type { PromptDef } from '../prompt/library.js';
// The suite's prompt scripts register with workstream 4's engine when this module loads.
import './scripts.js';
import { APERTURES, BODIES, ERAS, FRAME_RATES, GENRES, HEIGHTS, LENSES, LIGHTING, LOOKS, MOVES, PALETTES, SHOT_SIZES, SHUTTERS, TEMPOS, UGC_FORMATS, type Option } from './camera.js';

type Ph = [name: string, description: string, required?: true];
const def = (key: string, title: string, description: string, d: string, placeholders: Ph[] = [], extra: Partial<PromptDef> = {}): PromptDef =>
  ({ key, group: 'suite' as PromptDef['group'], title, description, kind: 'text', default: d, placeholders, ...extra });
const lines = (key: string, title: string, list: Option[], placeholders: Ph[] = []) =>
  def(key, `Camera · ${title}`, 'One per line: "id: wording". Delete a line to go back to its default; the ids are fixed.',
    list.filter(x => x.wording).map(x => `${x.id}: ${x.wording}`).join('\n'), placeholders, { kind: 'lines', allowEmpty: true });

const FMT_PH: Ph[] = [['move', 'the camera move(s)'], ['framing', 'angle and shot size'], ['rig', 'body, lens, focal length, aperture, look, frame rate'],
  ['light', 'lighting'], ['palette', 'colour palette'], ['style', 'genre, era and tempo'], ['performance', 'the emotion line']];

export const SUITE_PROMPT_DEFS: PromptDef[] = [
  lines('suite.camera.bodies', 'bodies', BODIES),
  lines('suite.camera.lenses', 'lenses', LENSES),
  lines('suite.camera.apertures', 'apertures', APERTURES),
  lines('suite.camera.looks', 'film looks', LOOKS),
  lines('suite.camera.frameRates', 'frame rates', FRAME_RATES),
  lines('suite.camera.shutters', 'shutter', SHUTTERS),
  lines('suite.camera.lighting', 'lighting', LIGHTING),
  lines('suite.camera.palettes', 'palettes', PALETTES),
  lines('suite.camera.moves', 'moves', MOVES, [['amount', 'how far it travels or turns at the chosen intensity, e.g. "about 1.4 m"']]),
  lines('suite.camera.heights', 'angles', HEIGHTS),
  lines('suite.camera.shotSizes', 'shot sizes', SHOT_SIZES),
  lines('suite.camera.genres', 'genres', GENRES),
  lines('suite.camera.eras', 'eras', ERAS),
  lines('suite.camera.tempos', 'tempo', TEMPOS),
  lines('suite.camera.ugcFormats', 'UGC ad formats', UGC_FORMATS),
  // Per-model camera block grammar. Empty parts drop out with their label.
  def('suite.camera.format.kling', 'Camera block · short imperative', 'Used by models that like short camera commands.',
    'Camera: {move}. {framing}. {rig}. Lighting: {light}. Colour: {palette}. {style}. {performance}', FMT_PH),
  def('suite.camera.format.seedance', 'Camera block · tagged blocks', 'Used by models that read tagged blocks (one camera move per shot).',
    '[Camera] {move} [Shot] {framing} [Lens] {rig} [Light] {light} [Color] {palette} [Mood] {style} {performance}', FMT_PH),
  def('suite.camera.format.h3', 'Camera block · camera vocabulary', 'Used by models with a camera-vocabulary prompt guide.',
    'Cinematography: {framing}, {move}. Shot with {rig}. {light}. {palette}. {style}. {performance}', FMT_PH),
  def('suite.camera.format.veo', 'Camera block · descriptive', 'Used by models that prefer a descriptive sentence.',
    'A {framing} with {move}, {rig}, lit by {light}, {palette}, {style}. {performance}', FMT_PH),
  def('suite.camera.format.generic', 'Camera block · default', 'Everything else.',
    'Camera: {move}; {framing}; {rig}. Light: {light}. Colour: {palette}. {style}. {performance}', FMT_PH),
  // Shot prompt parts.
  def('suite.shot.character', 'Shot · character', 'Who is in the shot. {refs} names the character images.',
    '{name} is the woman shown in {refs}: {look}. Keep her face, hair, skin, body and proportions exactly as in those images.{never}',
    [['name', 'her name', true], ['refs', 'the character images, e.g. "<Image 1> and <Image 2>"'], ['look', 'her look'], ['never', '" She never has: tattoos, rings." or empty']], { allowEmpty: false }),
  def('suite.shot.character.words', 'Shot · character (in words)', 'Who is in the shot when her images are not sent.', '{name}: {look}.{never}',
    [['name', 'her name', true], ['look', 'her look'], ['never', '" She never has: tattoos, rings." or empty']], { allowEmpty: false }),
  def('suite.shot.outfit', 'Shot · outfit', 'Her outfit.', 'She wears {outfit}{refs}.', [['outfit', 'the outfit name or description', true], ['refs', '" as shown in <Image 4>" or empty']]),
  def('suite.shot.reference', 'Shot · extra reference', 'One line per extra reference image (product, location, style).', '{ref} is {role}: use only its {use}.',
    [['ref', 'the image token', true], ['role', 'what it is'], ['use', 'what to take from it']]),
  def('suite.shot.lock', 'Shot · reference lock', 'Keeps references from swapping roles.',
    'Each reference keeps its role: never swap appearances, clothing or positions between them.'),
  def('suite.shot.frames', 'Shot · keyframes', 'When start / middle / end frames are given.', 'The shot starts exactly on {start}{middle}{end}.',
    [['start', 'the start frame token'], ['middle', '", passes through …" or empty'], ['end', '" and ends exactly on …" or empty']]),
  def('suite.shot.guide', 'Shot · guide clip', 'When a guide clip (greybox or reference video) is sent.',
    'Take the {use} from {video}; do not copy its look, textures or grey shapes.', [['video', 'the video token', true], ['use', 'camera movement / motion / blocking']]),
  def('suite.shot.scene', 'Shot · the user’s scene', 'The user’s own words (scene, action, dialogue), after her identity and references. Only this block sees them.',
    '{direction}', [['direction', 'the user’s scene and direction', true]], { allowEmpty: false }),
  def('suite.shot.camera', 'Shot · camera line', 'Where the Camera block goes (script suite.camera builds {camera}).', '{camera}', [['camera', 'the Camera block', true]]),
  def('suite.shot.avoid', 'Shot · things to avoid', 'What the camera move must not turn into (models without a negative prompt).', '{avoid}', [['avoid', '"No zoom." …', true]]),
  def('suite.audio.dialogue', 'Shot · speaking, no audio sent', 'She speaks and the model makes the sound itself.',
    '{subject} speaks the lines in quotes; her lips match every word.', [['subject', 'her name']]),
  // Recast (same take, new cast)
  def('suite.recast.task', 'Recast · task', 'What the model must do with the source clip.',
    'Recast {source}: replace {count} with the characters below. Keep each person’s exact motion, timing, gestures and expressions, the camera, the framing, the background and the lighting of {source}.',
    [['source', 'the source clip token', true], ['count', '"one person" / "2 people"']], { allowEmpty: false }),
  def('suite.recast.person', 'Recast · one person', 'One line per person recast.', '{who} in {source} becomes {name}, shown in {refs}: {look}.{outfit}{never}',
    [['who', '"the person on the left" …', true], ['source', 'the source clip token'], ['name', 'her name', true], ['refs', 'her image tokens'], ['look', 'her look'],
      ['outfit', '" She wears … (<Image 3>)." or empty'], ['never', '" She never has: …" or empty']], { allowEmpty: false }),
  def('suite.recast.identify', 'Recast · who is who', 'When a face crop of the person is sent.', '{faceRef} shows which person {who} is.', [['faceRef', 'the crop token', true], ['who', 'who in the clip']]),
  def('suite.recast.lock', 'Recast · cast lock', 'When several people are recast.', 'Each person keeps their own character: never swap faces, hair, clothing or positions between them.'),
  def('suite.recast.mouth.speaking', 'Recast · speaking', 'A person who speaks or sings in the clip.', '{name}’s lips match every word of the original audio.', [['name', 'her name']]),
  def('suite.recast.mouth.silent', 'Recast · not speaking', 'A person who does not speak.', '{name}’s mouth follows {source} exactly; she does not speak, sing or mouth words.', [['name', 'her name'], ['source', 'the source clip token']]),
  def('suite.recast.mouth.follow', 'Recast · speaking unknown', 'When it isn’t known whether the person speaks.', '{name}’s mouth follows {source} exactly.', [['name', 'her name'], ['source', 'the source clip token']]),
  def('suite.recast.cuts', 'Recast · cuts', 'Models that keep a multi-shot clip’s cuts.', 'Keep every cut and shot change of {source} at the same moments.', [['source', 'the source clip token']]),
  def('suite.recast.direction', 'Recast · user direction', 'The user’s own words (anything that would change a character’s look is removed first).', 'Direction: {direction}',
    [['direction', 'the user’s direction', true]], { allowEmpty: false }),
  // Extend (a longer take from a finished one: suite/extend.ts)
  def('suite.extend.after', 'Extend · after (video)', 'Continue the source clip (models that take the clip itself).',
    'Continue {source} seamlessly from its last moment: same people, place, light, colour and camera style, no cut. Next: {direction}',
    [['source', 'the source clip token', true], ['direction', 'what happens next (or "the action carries on naturally")', true]], { allowEmpty: false }),
  def('suite.extend.before', 'Extend · before (video)', 'The moments just before the source clip.',
    'Show the moments just before {source}, ending exactly where {source} begins: same people, place, light, colour and camera style, no cut. Before: {direction}',
    [['source', 'the source clip token', true], ['direction', 'what happens before (or "the action leads naturally into it")', true]], { allowEmpty: false }),
  def('suite.extend.after.frame', 'Extend · after (frame bridge)', 'Models that continue from the source’s last frame.',
    'The shot starts exactly on the given first frame, the last moment of the previous shot, and continues it seamlessly: same people, place, light, colour and camera style. Next: {direction}',
    [['direction', 'what happens next', true]], { allowEmpty: false }),
  def('suite.extend.before.frame', 'Extend · before (frame bridge)', 'Models that end on the source’s first frame.',
    'The shot ends exactly on the given last frame, the first moment of the next shot, and leads into it seamlessly: same people, place, light, colour and camera style. Before: {direction}',
    [['direction', 'what happens before', true]], { allowEmpty: false }),
  def('suite.shot.footer', 'Shot · closing line', 'Added at the end of every shot prompt.', 'Photorealistic. No text, captions, logos or watermarks anywhere.'),
  def('suite.shot.negative', 'Shot · negative prompt', 'Sent as the negative prompt where the model takes one (comma-separated).',
    'text, captions, watermark, logo, extra fingers, deformed hands, distorted face, flicker, cartoon', [], { kind: 'list', allowEmpty: true }),
];

/** "id: wording" lines → map, defaults first so a deleted line falls back. */
export function wordings(text: string | undefined, list: Option[]) {
  const map = new Map(list.map(x => [x.id, x.wording]));
  for (const raw of (text ?? '').split(/\r?\n/)) {
    const i = raw.indexOf(':');
    if (i <= 0) continue;
    const id = raw.slice(0, i).trim(), w = raw.slice(i + 1).trim();
    if (map.has(id) && w) map.set(id, w);
  }
  return map;
}
