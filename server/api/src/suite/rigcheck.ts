// AI suite · the rig check (plans/video-composer.md "Rig check"). Before Generate, the composer warns when choices clash
// with each other or with the prompt: one line of reason and a one-tap fix. It never blocks Generate. Pure (no database,
// no model calls): the prompt is read with a keyword map, so the estimate, the apps and the tests all agree.
//
// A fix is a JSON Merge Patch (RFC 7386) over the shot request the composer sends: objects merge, a value replaces,
// null removes. Fixes never use null where a preset would fill the gap back in (they pick an explicit option instead).
import { APERTURES, BODIES, HEIGHTS, LOOKS, MOVES, PALETTES, SHOT_SIZES, canonicalSpec, resolvePreset, type CameraSpec, type MoveOption, type Option } from './camera.js';

export type RigFix = { label: string; patch: Record<string, unknown> };
export type RigWarning = {
  /** Stable rule id (one warning per rule). */
  id: 'deep_focus' | 'wide_close' | 'worm_close' | 'look_clash' | 'prompt_move' | 'prompt_angle' | 'prompt_size' | 'no_reveal' | 'talk_move';
  /** warn: the shot won't come out as chosen. tip: a taste clash worth a look. */
  severity: 'warn' | 'tip';
  /** One member-facing line. */
  reason: string;
  /** The one-tap fix. */
  fix: RigFix;
  /** A second way out, when there is a natural one. */
  alt?: RigFix;
};
export type RigInput = { prompt?: string; camera?: CameraSpec; speaking?: boolean };

const label = (list: Option[], id?: string) => list.find(x => x.id === id)?.label ?? id ?? '';
const moveOf = (id?: string) => (id ? MOVES.find(m => m.id === id) : undefined);
const cam = (c: Record<string, unknown>) => ({ camera: c });
const setMove = (id: string) => cam({ move: { id } });

// ---------------------------------------------------------------- tables
/** Small sensors or fixed-focus optics: everything is in focus whatever the aperture says. */
const DEEP_FOCUS_BODIES = ['camcorder', 'phone', 'webcam', 'security_cam'];
const SHALLOW_APERTURES = ['f1.2', 'f1.4', 'f2', 'f2.8'];
const CLOSE_SIZES = ['cu', 'ecu'];
const WORM_CLOSE_SIZES = ['mcu', 'cu', 'ecu'];

/** Colour character of each look and palette, for the clash rule. */
type Tone = 'mono' | 'warm' | 'cold' | 'saturated' | 'muted';
const LOOK_TONES: Record<string, Tone[]> = {
  phone_hdr: ['saturated'], portrait_negative: ['warm'], tungsten_stock: ['cold'], slide_film: ['saturated'], bw_film: ['mono'],
  bleach_bypass: ['muted'], cross_process: ['saturated'], reversal_16: ['saturated'], faded_print: ['muted'],
};
const PALETTE_TONES: Record<string, Tone[]> = {
  bleached_warm: ['warm', 'muted'], hyper_neon: ['saturated'], teal_orange: ['saturated'], sodium_decay: ['warm'], cold_steel: ['cold', 'muted'],
  bleach_bypass: ['muted'], classic_bw: ['mono'], muted_earth: ['muted'], golden_warmth: ['warm'], moody_blue: ['cold'], vintage_fade: ['muted'],
  cyber_magenta: ['saturated'], desert_sand: ['warm'], retro_80s: ['saturated'], nineties_mall: ['saturated', 'warm'], y2k_gloss: ['cold'],
  candy_pop: ['saturated'], autumn: ['warm'], winter_frost: ['cold'], sepia: ['mono'], kodachrome_like: ['saturated'], matte_film: ['muted'],
};
const OPPOSITE: [Tone, Tone, string][] = [
  ['mono', 'saturated', 'black and white can’t carry'], ['mono', 'warm', 'black and white can’t carry'], ['mono', 'cold', 'black and white can’t carry'],
  ['warm', 'cold', 'pull the colour opposite ways:'], ['saturated', 'muted', 'pull the colour opposite ways:'],
];

/**
 * What a prompt says about the camera. Each entry: the words, and the move ids that do what the words describe (the
 * first is the fix). Order matters: more specific phrases first ("crash zoom" before "zoom in").
 */
const MOVE_WORDS: { re: RegExp; ids: string[] }[] = [
  { re: /\bwhip[- ]?pans?\b/, ids: ['whip_pan'] },
  { re: /\bcrash[- ]?zooms?\b/, ids: ['crash_zoom'] },
  { re: /\b(dolly[- ]?zoom|vertigo (shot|effect))\b/, ids: ['dolly_zoom'] },
  { re: /\b(rack(s|ing)? focus|focus (pull|rack)s?|pulls? focus)\b/, ids: ['rack_focus'] },
  { re: /\b(360|full circle|all the way around)\b/, ids: ['orbit_360', 'bullet_time'] },
  { re: /\b(orbit(s|ing)?|circles? (around|round)|arcs? (around|round))\b/, ids: ['orbit_right', 'orbit_left', 'orbit_360', 'top_down_spin', 'bullet_time'] },
  { re: /\bfpv\b/, ids: ['fpv'] },
  { re: /\b(drone|aerial|fly ?over|flies over)\b/, ids: ['drone_reveal', 'flyover', 'fpv'] },
  { re: /\b(pull(s|ing)? back|dolly(ing)? out|dollies out|backs? away)\b/, ids: ['dolly_out', 'drone_reveal', 'zoom_out'] },
  { re: /\b(push(es|ing)? in|dolly(ing)? in|dollies in|moves? in (on|toward|towards))\b/, ids: ['dolly_in', 'micro_push', 'dutch_push', 'zoom_in'] },
  { re: /\bzoom(s|ing)? in\b/, ids: ['zoom_in', 'crash_zoom', 'dolly_zoom'] },
  { re: /\bzoom(s|ing)? out\b/, ids: ['zoom_out', 'dolly_zoom'] },
  { re: /\bpan(s|ning)? (to the )?left\b/, ids: ['pan_left', 'whip_pan'] },
  { re: /\bpan(s|ning)? (to the )?right\b/, ids: ['pan_right', 'whip_pan'] },
  { re: /\btilt(s|ing)? up\b/, ids: ['tilt_up', 'crane_up'] },
  { re: /\btilt(s|ing)? down\b/, ids: ['tilt_down', 'crane_up'] },
  { re: /\b(crane(s|ing)? (up|over)|jib(s|bing)? up|camera rises)\b/, ids: ['crane_up', 'pedestal_up', 'crane_overhead', 'drone_reveal'] },
  { re: /\b(crane(s|ing)? down|jib(s|bing)? down|camera (descends|lowers))\b/, ids: ['crane_down', 'pedestal_down'] },
  { re: /\b(follow(s|ing)? (her|him|them|the|behind)|tracking shot|track(s|ing)? (with|alongside|behind))\b/, ids: ['follow', 'track_side', 'lead', 'steadicam', 'handheld', 'handheld_run', 'selfie', 'fpv'] },
  { re: /\bselfie\b/, ids: ['selfie', 'handheld'] },
  { re: /\b(handheld|hand-held|shaky cam)\b/, ids: ['handheld', 'handheld_run', 'selfie'] },
  { re: /\b(static|locked[- ]off|on a tripod|still camera|camera (stays|is) still)\b/, ids: ['static', 'rack_focus', 'micro_push'] },
];
const ANGLE_WORDS: { re: RegExp; ids: string[] }[] = [
  { re: /\bworm[’']?s[- ]eye\b/, ids: ['worm', 'ground'] },
  { re: /\b(bird[’']?s[- ]eye|top[- ]down|overhead (shot|view))\b/, ids: ['overhead'] },
  { re: /\b(low[- ]angle|from below|looking up at)\b/, ids: ['low', 'worm', 'ground', 'hip'] },
  { re: /\b(high[- ]angle|from above|looking down (at|on))\b/, ids: ['high', 'overhead'] },
  { re: /\beye[- ]level\b/, ids: ['eye', 'shoulder'] },
];
const SIZE_WORDS: { re: RegExp; ids: string[] }[] = [
  { re: /\bextreme close[- ]?ups?\b/, ids: ['ecu', 'insert', 'cu'] },
  { re: /\b(close[- ]?ups?|closeups?)\b/, ids: ['cu', 'ecu', 'mcu', 'insert'] },
  { re: /\b(extreme wide|establishing shot)\b/, ids: ['els', 'ls'] },
  { re: /\bwide shot\b/, ids: ['ls', 'els', 'full'] },
];
/** "Open on the street, then find her" / "reveal": the camera has to start somewhere else and discover the subject. */
const REVEAL_WORDS = /\b(open(s|ing)? on|start(s|ing)? on|begin(s|ning)? on|reveal(s|ed|ing)?|comes? into view|to find (her|him|them))\b/;
/** Moves that start on the subject (or never leave it), so they can't open elsewhere and reveal. */
const NO_REVEAL = ['static', 'micro_push', 'dolly_in', 'dutch_push', 'zoom_in', 'crash_zoom', 'crane_up', 'crane_overhead', 'snorricam', 'selfie', 'top_down_spin', 'bullet_time'];

/** Prompt words, lower-cased, with the composer's own #tokens (option labels) and any negated phrase taken out. */
export function promptWords(prompt: string) {
  let p = ` ${prompt.toLowerCase().replace(/[“”]/g, '"')} `;
  const labels = [...MOVES, ...HEIGHTS, ...SHOT_SIZES].map(x => x.label.toLowerCase()).sort((a, b) => b.length - a.length);
  for (const l of labels) p = p.split(`#${l}`).join(' ');
  // "no zoom", "without a pan", "don't tilt up" say what NOT to do.
  return p.replace(/\b(no|not|never|without|don[’']?t|doesn[’']?t|avoid)\b( (a|an|any|the))? [a-z’'-]+( [a-z’'-]+)?/g, ' ');
}
const firstHit = (words: string, table: { re: RegExp; ids: string[] }[]) => table.find(t => t.re.test(words));
const quoteOf = (words: string, re: RegExp) => words.match(re)?.[0] ?? '';

// ---------------------------------------------------------------- the check
/** The clashes in a shot, most serious first. The camera is read with its preset underneath (as the shot compiles). */
export function rigCheck(shot: RigInput): RigWarning[] {
  const out: RigWarning[] = [];
  const c = shot.camera ? canonicalSpec(resolvePreset(shot.camera)) : undefined;
  const body = c?.rig?.body, aperture = c?.rig?.aperture, focal = c?.rig?.focalMm;
  const height = c?.angle?.height, size = c?.angle?.shotSize;
  const move = moveOf(c?.move?.id), mix = moveOf(c?.mix?.id);
  const moves = [move, mix].filter((m): m is MoveOption => !!m);
  const words = shot.prompt ? promptWords(shot.prompt) : '';

  // 1 · Deep-focus cameras can't show shallow focus or a focus pull.
  if (body && DEEP_FOCUS_BODIES.includes(body)) {
    const rack = moves.find(m => m.id === 'rack_focus');
    const shallow = aperture && SHALLOW_APERTURES.includes(aperture);
    if (rack || shallow) {
      const what = rack ? 'the rack focus won’t show' : `${label(APERTURES, aperture)} won’t blur the background`;
      out.push({ id: 'deep_focus', severity: 'warn', reason: `${label(BODIES, body)} keeps everything in focus, so ${what}`,
        fix: { label: 'Use Cinema camera', patch: cam({ rig: { body: 'cinema_digital' } }) },
        alt: rack ? { label: 'Drop the rack focus', patch: dropMove('rack_focus', c!) } : { label: 'Use f/11', patch: cam({ rig: { aperture: 'f11' } }) } });
    }
  }
  // 2 · A wide lens this close distorts the face.
  if (focal != null && focal <= 24 && size && CLOSE_SIZES.includes(size) && c?.rig?.lens !== 'fisheye') {
    out.push({ id: 'wide_close', severity: 'warn', reason: `A ${focal}mm lens this close stretches the face`,
      fix: { label: 'Use 85mm', patch: cam({ rig: { focalMm: 85 } }) }, alt: { label: 'Medium shot', patch: cam({ angle: { shotSize: 'ms' } }) } });
  }
  // 3 · From the ground you can't frame chest-up.
  if (height === 'worm' && size && WORM_CLOSE_SIZES.includes(size)) {
    out.push({ id: 'worm_close', severity: 'warn', reason: `Worm’s-eye from the ground can’t frame a ${label(SHOT_SIZES, size).toLowerCase()}`,
      fix: { label: 'Low angle', patch: cam({ angle: { height: 'low' } }) }, alt: { label: 'Full body', patch: cam({ angle: { shotSize: 'full' } }) } });
  }
  // 4 · Looks that pull the colour opposite ways.
  const look = c?.rig?.look, palette = c?.palette?.preset;
  if (look && palette && look !== palette) {
    const a = LOOK_TONES[look] ?? [], b = PALETTE_TONES[palette] ?? [];
    const hit = OPPOSITE.find(([x, y]) => (a.includes(x) && b.includes(y)) || (a.includes(y) && b.includes(x)));
    if (hit) {
      const L = label(LOOKS, look), P = label(PALETTES, palette);
      const reason = hit[0] === 'mono' ? (a.includes('mono') ? `${L} is black and white, so ${P} won’t show` : `${P} is black and white, so ${L} won’t show`)
        : `${L} and ${P} pull the colour opposite ways`;
      out.push({ id: 'look_clash', severity: 'tip', reason,
        fix: { label: `Keep ${L}`, patch: cam({ palette: { preset: 'naturalistic' } }) }, alt: { label: `Keep ${P}`, patch: cam({ rig: { look: 'digital_clean' } }) } });
    }
  }
  if (words) {
    // 5 · The prompt describes a different move, angle or size from the chips.
    const mw = firstHit(words, MOVE_WORDS);
    if (mw && move && !moves.some(m => mw.ids.includes(m.id))) {
      const to = moveOf(mw.ids[0])!;
      out.push({ id: 'prompt_move', severity: 'warn', reason: `The prompt says “${quoteOf(words, mw.re)}” but the move is ${move.label}`,
        fix: { label: `Use ${to.label}`, patch: setMove(to.id) } });
    }
    const aw = firstHit(words, ANGLE_WORDS);
    if (aw && height && !aw.ids.includes(height)) {
      out.push({ id: 'prompt_angle', severity: 'warn', reason: `The prompt says “${quoteOf(words, aw.re)}” but the angle is ${label(HEIGHTS, height)}`,
        fix: { label: `Use ${label(HEIGHTS, aw.ids[0])}`, patch: cam({ angle: { height: aw.ids[0] } }) } });
    }
    const sw = firstHit(words, SIZE_WORDS);
    if (sw && size && !sw.ids.includes(size)) {
      out.push({ id: 'prompt_size', severity: 'tip', reason: `The prompt says “${quoteOf(words, sw.re)}” but the framing is ${label(SHOT_SIZES, size)}`,
        fix: { label: `Use ${label(SHOT_SIZES, sw.ids[0])}`, patch: cam({ angle: { shotSize: sw.ids[0] } }) } });
    }
    // 6 · "Open on X / reveal" needs a move that starts away from the subject.
    if (move && REVEAL_WORDS.test(words) && NO_REVEAL.includes(move.id) && !(mix && !NO_REVEAL.includes(mix.id))) {
      const to = revealFor(move.id);
      out.push({ id: 'no_reveal', severity: 'warn', reason: `The prompt opens on something else, but ${move.label} ${move.id === 'crane_up' || move.id === 'crane_overhead' ? 'starts at the subject' : 'can’t reveal'}`,
        fix: { label: `Use ${to.label}`, patch: setMove(to.id) } });
    }
  }
  // 7 · Speaking shots need a move that won't fight lip sync.
  if (shot.speaking && moves.some(m => !m.talkSafe)) {
    const bad = moves.find(m => !m.talkSafe)!;
    out.push({ id: 'talk_move', severity: 'warn', reason: `${bad.label} can fight lip sync on a speaking shot`,
      fix: bad === mix ? { label: `Drop ${bad.label}`, patch: cam({ mix: null }) } : { label: 'Lock it off', patch: setMove('static') },
      ...(bad === move ? { alt: { label: 'Handheld UGC', patch: setMove('handheld') } } : {}) });
  }
  // A reveal clash already names the move to use, so a second "use this move" line would only compete with it.
  return out.some(w => w.id === 'no_reveal') ? out.filter(w => w.id !== 'prompt_move') : out;
}

/** Take one move out without letting a preset put another back: the mix is removed, or the main move becomes the mix / static. */
function dropMove(id: string, c: CameraSpec): Record<string, unknown> {
  if (c.mix?.id === id) return cam({ mix: null });
  if (c.mix) return cam({ move: { ...c.mix }, mix: null });
  return setMove('static');
}
/** The reveal that fits: a rise when the move was a rise ("Rise to reveal" once it exists, else tilt up), else a pull back. */
function revealFor(id: string): MoveOption {
  const rise = MOVES.find(m => /^rise.*reveal|reveal.*rise/.test(m.id));
  if (id === 'crane_up' || id === 'crane_overhead') return rise ?? moveOf('tilt_up')!;
  return moveOf('dolly_out')!;
}
