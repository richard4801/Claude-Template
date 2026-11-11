// Blocks added with prompt scripts (plans/prompt-scripts.md §4). They join the prompt library (library.ts concatenates
// them), so the owner edits them in Settings → Prompts like every other entry. Keys of existing entries never change,
// so saved owner overrides keep working.
import type { PromptDef } from '../library.js';

type Ph = [name: string, description: string, required?: true];
const b = (key: string, title: string, description: string, def: string, placeholders: Ph[] = [], extra: Partial<PromptDef> = {}): PromptDef =>
  ({ key, group: 'video', title, description, kind: 'text', default: def, placeholders, ...extra });

export const SCRIPT_BLOCK_DEFS: PromptDef[] = [
  // ---- the reference sheet line (refs.collage): what each non-person panel shows (were fixed in code)
  { key: 'refs.collage.outfit', group: 'references', title: 'Reference sheet · outfit panel', description: 'In the reference sheet line, for a panel with the outfit.',
    kind: 'text', default: 'panel {panel} shows the outfit to wear', placeholders: [['panel', 'the panel number', true]], allowEmpty: false },
  { key: 'refs.collage.product', group: 'references', title: 'Reference sheet · product panel', description: 'In the reference sheet line, for a panel with the product.',
    kind: 'text', default: 'panel {panel} shows the product', placeholders: [['panel', 'the panel number', true]], allowEmpty: false },
  { key: 'refs.collage.ref', group: 'references', title: 'Reference sheet · reference panel', description: 'In the reference sheet line, for a reference image’s panel.',
    kind: 'text', default: 'panel {panel} guides the {guides} only', placeholders: [['panel', 'the panel number', true], ['guides', '"pose & framing and the look & colour" …', true]], allowEmpty: false },
  // ---- the user's own words in video prompts (a delimited user section; system text never rewrites it)
  b('video.user.direction', 'User section', 'The user’s own direction, after every system section (anything that would change her identity is removed first).',
    'Direction from the user: {direction}', [['direction', 'the user’s direction', true]], { allowEmpty: false }),
  // ---- performer not speaking (lip-sync fix): the clip is sent without audio and the audio is put back afterwards
  b('video.replicate.summary.silent', 'Draft/Standard/HD · summary (not speaking)', 'summary of the short prompt when the performer does not speak or sing.',
    '[video editing + character replacement] <Subject 1> is replaced by <Subject 2>. <Subject 2> copies '
    + "<Subject 1>'s facial performance exactly, frame by frame and with the same intensity: every eye movement, side glance, blink, "
    + 'eyebrow raise and head turn, at the same moments, and the same body motion. '
    + 'The camera, the exact framing and crop, the background and the lighting of <Video 1> stay unchanged. Any caption or on-screen text is removed.', [], { allowEmpty: false }),
  // ---- Swap background "Describe it" (owner 2026-11-11): the moves and timing stay; the user's words set the new place.
  b('video.replicate.summary.describe', 'Draft/Standard/HD · summary (new background described)', 'summary of the short prompt when the background is set to “Describe it” (the performer speaks).',
    '[video editing + character replacement + new background] <Subject 1> is replaced by <Subject 2>. <Subject 2> copies '
    + "<Subject 1>'s facial performance exactly, frame by frame and with the same intensity: every eye movement, side glance, blink, "
    + 'eyebrow raise, mouth and lip movement and head turn, at the same moments, and the same body motion. The camera, the exact framing '
    + 'and crop and the timing of <Video 1> stay unchanged; the background and setting are replaced by the place described in the direction '
    + 'from the user, with lighting that matches it. Any caption or on-screen text is removed.', [], { allowEmpty: false }),
  b('video.replicate.summary.describe.silent', 'Draft/Standard/HD · summary (new background described, not speaking)', 'summary of the short prompt when the background is set to “Describe it” and the performer does not speak or sing.',
    '[video editing + character replacement + new background] <Subject 1> is replaced by <Subject 2>. <Subject 2> copies '
    + "<Subject 1>'s facial performance exactly, frame by frame and with the same intensity: every eye movement, side glance, blink, "
    + 'eyebrow raise and head turn, at the same moments, and the same body motion. The camera, the exact framing and crop and the timing '
    + 'of <Video 1> stay unchanged; the background and setting are replaced by the place described in the direction from the user, with '
    + 'lighting that matches it. Any caption or on-screen text is removed.', [], { allowEmpty: false }),
  b('video.replicate.retention.describe', 'Draft/Standard/HD · retention (new background described)', 'retention_analysis of the short prompt when the background is set to “Describe it”.',
    '<Video 1>: motion_preserved - camera motion, framing and crop and the full body motion and timing are kept; the background and setting are not kept, they are replaced by the place the user describes.\n'
    + '<Subject 1>: replaced - only the facial expressions, mouth movements and body motion are kept, not the face, hair, tattoos, jewellery, clothes, body shape or proportions.\n'
    + '<Subject 2>: reference - {reference}.', [['reference', 'face, body and outfit image ranges and the never-add list', true]], { allowEmpty: false }),
  b('video.replicate.detailed.describe', 'Draft/Standard/HD · details (new background described)', 'detailed_description of the short prompt when the background is set to “Describe it”.',
    'Casual phone video, realistic. [Shot 1] <Subject 2> in the new place the user describes, framed exactly like <Subject 1>: keep the exact '
    + 'framing and crop of <Video 1>, the camera does not pull back. The face is fully alive and mirrors every expression of <Subject 1>. '
    + 'Sharp face matching {faceRef}, natural skin texture, no beauty filter. No text anywhere.',
    [['faceRef', '<Image 1>, or "the description"']], { allowEmpty: false }),
  b('video.replicate.detailed.silent', 'Draft/Standard/HD · details (not speaking)', 'detailed_description of the short prompt when the performer does not speak or sing.',
    'Casual phone video, realistic. [Shot 1] <Subject 2> in the same place, framed exactly like <Subject 1>: keep the exact '
    + 'framing and crop of <Video 1>, the camera does not pull back. The face is fully alive and mirrors every expression of <Subject 1>. '
    + 'Sharp face matching {faceRef}, natural skin texture, no beauty filter. No text anywhere.',
    [['faceRef', '<Image 1>, or "the description"']], { allowEmpty: false }),
  b('video.mouth.speaking', 'Mouth line (speaking)', 'Ends the details of a character swap when “Performer is speaking” is on (the clip is sent with its sound).',
    "<Subject 2>'s mouth follows <Video 1> and is in sync with <Audio 1>'s speech."),
  b('video.mouth.silent', 'Mouth line (not speaking)', 'Ends the details of a character swap when “Performer is speaking” is off (the clip is sent without sound).',
    "<Subject 2>'s mouth follows <Video 1> exactly; she does not speak, sing or mouth words."),
  // ---- the Edit prompt's audio and background sentences (were fixed in code)
  b('video.edit.audio.subjects', 'Edit · audio track line', 'Ends subject_definitions when the clip’s audio is sent.', '<Audio 1> is the synchronized audio track of <Video 1>.'),
  b('video.edit.audio.tag', 'Edit · audio tag', 'Added to the summary’s task tag when the audio is kept.', '+ audio reuse'),
  b('video.edit.audio.summary', 'Edit · audio sentence', 'Ends the summary when the audio is kept.', '<Audio 1> is fully reused.'),
  b('video.edit.audio.kept', 'Edit · audio kept', 'retention_analysis: <Audio 1> when the audio is kept.', 'fully_copy - the original audio is kept unchanged.', [], { allowEmpty: false }),
  b('video.edit.audio.replaced', 'Edit · audio replaced', 'retention_analysis: <Audio 1> when the audio is not kept.', 'replaced - a new audio track is supplied.', [], { allowEmpty: false }),
  b('video.edit.background.keep', 'Edit · background kept', 'The summary’s background sentence when the background is kept.',
    'The camera, framing, background, lighting and timing of <Video 1> are unchanged.', [], { allowEmpty: false }),
  b('video.edit.background.photo', 'Edit · background photo', 'The summary’s background sentence with a new background photo.',
    'The camera, framing and timing of <Video 1> are unchanged; the background is replaced by the background reference photo{motion}.',
    [['motion', '" (subtly alive)" …, or empty']], { allowEmpty: false }),
  b('video.edit.background.describe', 'Edit · background described', 'The summary’s background sentence when the background is set to “Describe it” (the user’s words set the new place).',
    'The camera, framing and timing of <Video 1> are unchanged; the background is replaced by the place described in the direction from the user{motion}.',
    [['motion', '" (subtly alive)" …, or empty']], { allowEmpty: false }),
  b('video.edit.video.describe', 'Edit · source, background described', 'retention_analysis: <Video 1> when the background is set to “Describe it”.',
    'motion_preserved - the full body motion and timing are maintained exactly; the background is not kept, it is replaced by the place the user describes.', [], { allowEmpty: false }),
  b('video.edit.video.keep', 'Edit · source kept', 'retention_analysis: <Video 1> when the background is kept.',
    'fully_preserved - the background, camera position, lighting and the full body motion and timing are maintained exactly.', [], { allowEmpty: false }),
  b('video.edit.video.photo', 'Edit · source, new background', 'retention_analysis: <Video 1> with a new background photo.',
    'motion_preserved - the full body motion and timing are maintained exactly; the background is replaced.', [], { allowEmpty: false }),
  // ---- audio lines for generation without a motion source (the AI suite builds its shot prompts with these)
  b('audio.lipsync', 'Audio · speaking', 'The performer speaks or sings to the reference audio.',
    '{subject} speaks in sync with {audio}: the lips match every word exactly.', [['subject', '<Subject 1> …'], ['audio', '<Audio 1> …']]),
  b('audio.beat', 'Audio · beat only', 'Music drives the rhythm but nobody sings or speaks (the instrumental is sent).',
    '{subject} moves to the beat of {audio}; she does not sing, speak or mouth lyrics.', [['subject', '<Subject 1> …'], ['audio', '<Audio 1> …']]),
  b('audio.silent', 'Audio · none', 'No audio is sent.', '{subject} does not speak, sing or mouth words.', [['subject', '<Subject 1> …']]),
];
