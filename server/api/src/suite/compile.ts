// AI suite · Camera compiler: a CameraSpec → what one model can consume (prompt block, parameters, negatives, guide use).
// Data-driven: wording from the prompt library (suite.camera.*), grammar per model family (suite.camera.format.<vocab>),
// parameters only where a model has a real field (LTX camera_motion, fps). Notes are for the owner/debug view.
import { DEFAULT_TEXTS, fill, type PromptTexts } from '../prompt/library.js';
import { APERTURES, BODIES, canMix, canonicalSpec, ERAS, focalWords, FRAME_RATES, GENRES, HEIGHTS, LENSES, LIGHTING, LOOKS, MOVES, PALETTES, resolvePreset, SHOT_SIZES, SHUTTERS, TEMPOS, UGC_FORMATS,
  type CameraSpec, type MoveOption } from './camera.js';
import { wordings } from './prompts.js';
import { run } from '../prompt/scripts/builders.js';
import type { ModelSpec } from './registry.js';

export type CompiledCamera = {
  /** The camera text block for the prompt ('' when nothing was chosen). */
  text: string;
  /** Model parameters (e.g. camera_motion, fps). */
  params: Record<string, unknown>;
  /** Things to avoid, for a negative prompt or an "Avoid:" line. */
  avoid: string[];
  /** The guide clip is sent as a reference video to this model. */
  usesGuide: boolean;
  /** Move ids that made it into the shot. */
  moves: string[];
  /** Why something was changed or dropped (owner view, estimate warnings). */
  notes: string[];
};

const scale = (intensity: number, [a, b, unit]: [number, number, string]) => {
  const v = a + (b - a) * intensity;
  return unit === '°' ? `about ${Math.round(v / 5) * 5}°` : `about ${v < 1 ? v.toFixed(2).replace(/0$/, '') : v.toFixed(1)} ${unit}`;
};
const intensityWord = (i: number) => (i < 0.34 ? 'subtle' : i > 0.7 ? 'bold' : '');
const speedWord = (s: string) => (s === 'slow' ? 'slow' : s === 'fast' ? 'fast' : '');
const easeWord = (e: string) => (e === 'in' ? ', easing in' : e === 'out' ? ', easing out' : e === 'linear' ? ', constant speed' : '');

/** Words for a CameraSpec on a model. `durationS` drives the one-move rule; `audio` says whether the shot talks. */
export function compileCamera(input: CameraSpec | undefined, model: Pick<ModelSpec, 'camera' | 'fps'>, o: { texts?: PromptTexts; durationS?: number; talking?: boolean } = {}): CompiledCamera {
  const t = o.texts ?? DEFAULT_TEXTS;
  const out: CompiledCamera = { text: '', params: {}, avoid: [], usesGuide: false, moves: [], notes: [] };
  if (!input) return out;
  const spec = canonicalSpec(resolvePreset(input));
  const w = (key: string, list: Parameters<typeof wordings>[1]) => wordings(t[key], list);
  const word = (key: string, list: Parameters<typeof wordings>[1], id?: string) => (id ? w(key, list).get(id) ?? '' : '');

  // ---- moves (one primary move per shot; a mix only on models that take compound moves and shots ≥ 5 s)
  const moveText = (mv: NonNullable<CameraSpec['move']>) => {
    const def = MOVES.find(x => x.id === mv.id) as MoveOption;
    const wording = word('suite.camera.moves', MOVES, mv.id);
    const amount = def.amount ? scale(mv.intensity, def.amount) : '';
    const range = mv.startS != null || mv.endS != null ? ` from ${mv.startS ?? 0}s to ${mv.endS ?? o.durationS ?? 'the end'}s` : '';
    const still = def.category === 'static';
    const lead = still ? '' : [speedWord(mv.speed), intensityWord(mv.intensity)].filter(Boolean).join(', ');
    return `${lead ? `${lead} ` : ''}${fill(wording, { amount }).replace(/\s+/g, ' ').trim()}${still ? '' : easeWord(mv.ease)}${range}`;
  };
  const moves: string[] = [];
  if (spec.move) {
    const def = MOVES.find(x => x.id === spec.move!.id)!;
    moves.push(moveText(spec.move)); out.moves.push(def.id);
    if (def.avoid) out.avoid.push(def.avoid);
    if (def.editorBetter) out.notes.push(`"${def.label}" is usually cleaner as an editor effect between two shots`);
    if (o.talking && !def.talkSafe) out.notes.push(`"${def.label}" can fight lip sync; a locked or handheld camera talks best`);
    if (model.camera.enumField && model.camera.enumValues) {
      if (def.ltx && model.camera.enumValues.includes(def.ltx)) out.params[model.camera.enumField] = def.ltx;
      else out.notes.push(`no ${model.camera.enumField} value for "${def.label}": described in words only`);
    }
  }
  if (spec.mix && spec.move) {
    const a = MOVES.find(x => x.id === spec.move!.id)!, b = MOVES.find(x => x.id === spec.mix!.id)!;
    if (!canMix(a, b)) out.notes.push(`"${b.label}" can't be mixed with "${a.label}": dropped`);
    else if (model.camera.vocab === 'seedance' || model.camera.vocab === 'ltx') out.notes.push(`one camera move per shot on this model: "${b.label}" dropped`);
    else if ((o.durationS ?? 5) < 5) out.notes.push(`shots under 5 s keep one move: "${b.label}" dropped`);
    else { moves.push(moveText(spec.mix)); out.moves.push(b.id); if (b.avoid) out.avoid.push(b.avoid); }
  }

  // ---- framing, rig, light, palette, style, performance
  const a = spec.angle ?? {};
  const framing = [word('suite.camera.shotSizes', SHOT_SIZES, a.shotSize), word('suite.camera.heights', HEIGHTS, a.height),
    a.dutchDeg ? `Dutch angle tilted ${Math.round(a.dutchDeg)}°` : ''].filter(Boolean).join(', ');
  const r = spec.rig ?? {};
  const rig = [word('suite.camera.bodies', BODIES, r.body), r.focalMm ? focalWords(r.focalMm) : '', word('suite.camera.lenses', LENSES, r.lens),
    word('suite.camera.apertures', APERTURES, r.aperture), word('suite.camera.looks', LOOKS, r.look), word('suite.camera.frameRates', FRAME_RATES, r.fps),
    word('suite.camera.shutters', SHUTTERS, r.shutter)].filter(Boolean).join(', ');
  if (r.fps && model.fps?.length) {
    const want = r.fps === 'slowmo' ? Math.max(...model.fps) : Number(r.fps);
    const best = model.fps.reduce((p, c) => (Math.abs(c - want) < Math.abs(p - want) ? c : p));
    out.params.fps = best;
  }
  const L = spec.lighting ?? {};
  const light = [word('suite.camera.lighting', LIGHTING, L.preset), L.direction ? `key light from the ${L.direction === 'below' ? 'below' : L.direction}` : '',
    L.temperatureK ? `${L.temperatureK}K ${L.temperatureK < 4000 ? 'warm' : L.temperatureK > 6000 ? 'cool' : 'neutral'} colour temperature` : '',
    L.intensity === 'low' ? 'dim, low-key exposure' : L.intensity === 'high' ? 'bright, high-key exposure' : ''].filter(Boolean).join(', ');
  const p = spec.palette ?? {};
  const palette = [word('suite.camera.palettes', PALETTES, p.preset), p.colors?.length ? `palette built on ${p.colors.join(', ')}` : ''].filter(Boolean).join(', ');
  const s = spec.style ?? {};
  const style = [word('suite.camera.ugcFormats', UGC_FORMATS, s.format), word('suite.camera.genres', GENRES, s.genre), word('suite.camera.eras', ERAS, s.era), word('suite.camera.tempos', TEMPOS, s.tempo)].filter(Boolean).join(', ');
  const perf = spec.performance;
  const performance = perf ? `Performance: ${perf.intensity > 0.7 ? 'strong' : perf.intensity < 0.34 ? 'subtle' : 'clear'} ${perf.emotion}${perf.to ? `, turning to ${perf.to}${perf.atS != null ? ` at ${perf.atS}s` : ''}` : ''}.` : '';

  // ---- guide clip
  if (spec.guide) {
    if (model.camera.referenceVideo) out.usesGuide = true;
    else out.notes.push('this model takes no reference video: the guide clip is not sent, the camera is described in words');
  }

  const parts = { move: moves.join(', combined with '), framing, rig, light, palette, style, performance };
  if (!Object.values(parts).some(Boolean)) return out;
  // The block's grammar is the prompt script suite.camera (owner-editable rules and format blocks).
  const vocab = ['kling', 'seedance', 'h3', 'veo'].includes(model.camera.vocab) ? model.camera.vocab : 'generic';
  out.text = tidy(run('suite.camera', t, { inputs: { vocab }, vars: parts }).text);
  return out;
}

/** Removes the labels and punctuation left behind by empty parts. */
export function tidy(s: string) {
  return s
    .replace(/\[[A-Za-z]+\]\s*(?=\[|$)/g, '')            // "[Light] [Color]" → drop empty tagged blocks
    .replace(/\b(Camera|Lighting|Light|Colour|Color|Cinematography|Shot with):\s*[.;,]/g, '')
    .replace(/\b(Camera|Lighting|Light|Colour|Color|Cinematography):\s*$/g, '')
    .replace(/\bShot with\s*\./g, '')
    .replace(/\s+([.,;])/g, '$1').replace(/([.,;])(\s*[.,;])+/g, '$1')
    .replace(/\b(with|by)\s*,/g, '$1').replace(/,\s*,/g, ',')
    .replace(/\s{2,}/g, ' ').replace(/^[\s.,;]+|[\s,;]+$/g, '').trim()
    .replace(/(^|[.!?]\s+)([a-z])/g, (_, a: string, b: string) => a + b.toUpperCase());
}
