// Editor v2: the multitrack edit project (plans/video-editor.md "Editor v2"). This file is the REFERENCE implementation:
// the Kotlin (android/core/.../core/edit) and Swift (mac/MuseCore/.../Edit) ports must give the same answers for every
// case in test/fixtures/editor/*.json (scripts/editor-fixtures.ts writes them from these functions). Pure: no I/O.

import { hash01, lookProblem, type Look } from './look.js';

// ------------------------------------------------------------------ types
export type Ease = 'linear' | 'easeIn' | 'easeOut' | 'easeInOut' | 'hold';
export type Keyframe = { t: number; v: number; ease?: Ease };
export type KfProp = 'x' | 'y' | 'scale' | 'rotation' | 'opacity' | 'volume' | ColorKfProp | MaskKfProp | LookKfProp;
/** Mask keyframes (M): replace the mask's field over time (`maskAt`); only on items with a mask. */
export type MaskKfProp = 'maskX' | 'maskY' | 'maskWidth' | 'maskHeight' | 'maskRotation' | 'maskFeather';
export const MASK_KF_PROPS: MaskKfProp[] = ['maskX', 'maskY', 'maskWidth', 'maskHeight', 'maskRotation', 'maskFeather'];
/** Look keyframes (M): the finishing effects' amounts over time (`lookAt`); keying one the look lacks adds it. */
export type LookKfProp = 'vignette' | 'grain' | 'leak';
export const LOOK_KF_PROPS: LookKfProp[] = ['vignette', 'grain', 'leak'];
/** Colour keyframes (M): replace the adjust field's static value over time (`adjustAt`). Video clips and images. */
export type ColorKfProp = 'exposure' | 'contrast' | 'saturation' | 'temperature' | 'tint';
export const COLOR_KF_PROPS: ColorKfProp[] = ['exposure', 'contrast', 'saturation', 'temperature', 'tint'];
export type Keyframes = Partial<Record<KfProp, Keyframe[]>>;
/** flipX / flipY (wave 1, mirror): the picture mirrored about its own centre, after the crop and before scale and rotation. */
export type Transform = { x?: number; y?: number; scale?: number; rotation?: number; flipX?: boolean; flipY?: boolean };
/** Wave 1: how a picture on an overlay track combines with the layers below it (blendPixel). */
export type BlendMode = 'normal' | 'multiply' | 'screen' | 'overlay' | 'softLight' | 'darken' | 'lighten' | 'add';
export type Crop = { left?: number; top?: number; right?: number; bottom?: number };
export type Adjust = { exposure?: number; contrast?: number; saturation?: number; temperature?: number;
  /** Green (−1) ↔ magenta (+1), right after temperature in the colour matrix. */ tint?: number;
  /** Edit suite (phase 2): tone, applied after the colour matrix (`toneAdjust`). */ highlights?: number; shadows?: number };
export type FilterRef = { id: string; amount: number };
export type Chroma = { color: string; similarity?: number; smoothness?: number; spill?: number };
export type TransitionKind = 'fade' | 'black' | 'white' | 'slideLeft' | 'slideRight' | 'slideUp' | 'slideDown' | 'zoom' | 'whip' | 'spin' | 'glitch'
  // Content pack (2026-11-09): made of the same layer values.
  | 'zoomOut' | 'whipRight' | 'coverLeft' | 'coverRight' | 'coverUp' | 'coverDown' | 'splitFade';
export type SpeedPreset = 'montage' | 'hero' | 'bullet' | 'flashIn' | 'flashOut' | 'custom';
/** A speed curve over the clip's source: points [x 0–1 of the kept source, speed 0.1–10], x from 0 to 1. */
export type SpeedCurve = { preset: SpeedPreset; points: [number, number][] };
export type MaskShape = 'linear' | 'mirror' | 'circle' | 'rect' | 'heart' | 'star';
export type Mask = { shape: MaskShape; x?: number; y?: number; width?: number; height?: number; rotation?: number; feather?: number; invert?: boolean };
export type VoiceEffect = 'none' | 'warm' | 'radio' | 'phone' | 'deep';
export type Transition = { kind: TransitionKind; durationSec: number };
export type AnimKind = 'none' | 'fade' | 'pop' | 'slideUp' | 'slideDown' | 'zoom' | 'typewriter';
export type Anim = { kind: AnimKind; durationSec: number };
export type Fit = 'cover' | 'contain';

export type Asset = { id: string; kind: 'video' | 'image' | 'audio' | 'lut' /* an imported .cube (Looks) */ | 'font' /* the member's own .ttf/.otf */; take?: string; upload?: string; library?: string;
  durationSec?: number; width?: number; height?: number; hasAudio?: boolean; url?: string;
  /** A video asset that is another video asset played backwards (the Reverse helper's copy); see reverseClip. */
  reverseOf?: string;
  /**
   * A video asset made from another by a helper (owner-approved 2026-11-09). stabilize: the whole source steadied, the
   * same length and timing, so a clip switches with only its asset changing (deriveClip). slowmo: the source range
   * [startSec, endSec] with frames interpolated, factor× as long and silent; a clip is split around it (applySlowmo).
   * Chains are allowed (steadied then reversed), never cycles; see sourceOf, derivedOps.
   */
  derivedFrom?: DerivedFrom;
  /** A font asset's family and style, read from the file (display only). */
  name?: string };

export type DerivedOp = 'stabilize' | 'slowmo';
export type DerivedFrom = { asset: string; op: 'stabilize' } | { asset: string; op: 'slowmo'; startSec: number; endSec: number; factor: 2 | 4 };
export const DERIVED_OPS: readonly DerivedOp[] = ['stabilize', 'slowmo'];
export const SLOWMO = { factors: [2, 4] as const, minRangeSec: 0.3, maxRangeSec: 10 };

type Visual = { fit?: Fit; transform?: Transform; crop?: Crop; opacity?: number; keyframes?: Keyframes; filter?: FilterRef; adjust?: Adjust; look?: Look; mask?: Mask };
/** Voice processing on a clip with sound (Edit suite audio panel). */
type Voice = { voiceEffect?: VoiceEffect; enhance?: boolean };
export type VideoClip = Visual & Voice & { id: string; asset: string; inSec: number; outSec: number; speed: number; speedCurve?: SpeedCurve; startSec?: number;
  volume?: number; muted?: boolean; fadeInSec?: number; fadeOutSec?: number; audioAsset?: string; chroma?: Chroma; transitionIn?: Transition;
  /** workstream 1: an alpha matte video (grey, white = keep) aligned with this clip's own asset, applied as its alpha. */
  alphaMatte?: AlphaMatte;
  /** Wave 1, freeze frame: the clip shows the single source frame at inSec for holdSec seconds, silent (clipLength = holdSec). */
  holdSec?: number;
  /** Wave 1: overlay tracks only. */
  blend?: BlendMode;
  /** In / out animation (as images: fade, pop, slideUp, slideDown, zoom), main or overlay; [animState] over clipLength. */
  animIn?: Anim; animOut?: Anim;
  /** A repeating animation while it's on screen (overlay clips only; text and images have it too). */
  animLoop?: AnimLoop };
/** Background removal's result: a video asset the same length as the clip's source; its luma is the clip's alpha (invert: the reverse). */
export type AlphaMatte = { asset: string; invert?: boolean };
export type ImageItem = Visual & { id: string; asset: string; startSec: number; durationSec: number; animIn?: Anim; animOut?: Anim; blend?: BlendMode; animLoop?: AnimLoop };
/** The six bundled families, then the content library's (catalog `fonts` pack; Cyrillic and Latin Extended). */
export type FontFamily = 'sans' | 'serif' | 'rounded' | 'condensed' | 'mono' | 'marker'
  | 'inter' | 'montserrat' | 'robotoCondensed' | 'playfair' | 'unbounded' | 'rubik' | 'jetbrainsMono' | 'caveat' | 'oswald';
export type TextStyle = { font: FontFamily; weight: 400 | 700 | 900; sizePct: number; color: string;
  align: 'left' | 'center' | 'right'; maxWidthPct?: number; lineHeight?: number; letterSpacing?: number; uppercase?: boolean;
  stroke?: { color: string; widthPct: number }; shadow?: { color: string; opacity: number; blurPct: number; dyPct: number };
  background?: { color: string; opacity: number; paddingPct: number; radiusPct: number };
  /** Text items only: a `font` asset to draw with (its own face; `weight` is not synthesised). `font` stays the fallback. */
  fontAsset?: string };
export type TextItem = { id: string; startSec: number; durationSec: number; text: string; style: TextStyle; transform?: Transform; opacity?: number;
  keyframes?: Keyframes; animIn?: Anim; animOut?: Anim; template?: string; animLoop?: AnimLoop };
export type AudioClip = Voice & { id: string; asset: string; strongBeats?: number[]; startSec: number; inSec: number; outSec: number; speed?: number; volume?: number; muted?: boolean;
  fadeInSec?: number; fadeOutSec?: number; keyframes?: Keyframes; beats?: number[] };
export type CaptionPreset = 'plain' | 'highlight' | 'box' | 'karaoke' | 'pop' | 'single' | 'highlighter' | 'neon';
export type CaptionStyle = TextStyle & { preset: CaptionPreset; highlightColor: string; y?: number; wordsPerPage?: number; maxLines?: number };
export type CaptionWord = { text: string; startSec: number; endSec: number };
/**
 * Captions on the timeline. Translated captions (owner-approved 2026-11-09): [language] is the words' language (a
 * language code, e.g. "es"); [original] keeps the words they were translated from, so the apps can switch back
 * (swapCaptionOriginal). The translated words come timed from the server; nothing is spread on the device.
 */
export type CaptionTrack = { asset: string; words: CaptionWord[]; style: CaptionStyle; language?: string; original?: CaptionOriginal };
export type CaptionOriginal = { language?: string; words: CaptionWord[] };
export const LANGUAGE_CODE = /^[a-z]{2,3}(-[A-Z]{2})?$/;
/** Languages written without spaces between words: their caption pages join words with nothing between. */
export const UNSPACED_LANGUAGES: readonly string[] = ['ja', 'zh', 'th', 'lo', 'km', 'my'];
/** Languages written right to left (a caption page reads from the right; the words keep their order). */
export const RTL_LANGUAGES: readonly string[] = ['ar', 'he', 'fa', 'ur'];
const baseLang = (language?: string) => language?.split('-')[0];
/** What goes between a caption page's words: nothing for unspaced languages, else a space. */
export const captionJoiner = (language?: string) => UNSPACED_LANGUAGES.includes(baseLang(language) ?? '') ? '' : ' ';
export const isRtlLanguage = (language?: string) => RTL_LANGUAGES.includes(baseLang(language) ?? '');
/** A caption page's text in [language] (words joined by captionJoiner). */
export const captionText = (words: { text: string }[], language?: string) => words.map(w => w.text).join(captionJoiner(language));
/** The caption track shown in its original words (and back): words and language swap with [original]'s. Unchanged without one. */
export function swapCaptionOriginal(ct: CaptionTrack): CaptionTrack {
  if (!ct.original) return ct;
  const { language: _l, original, ...rest } = ct;
  return { ...rest, words: original.words, ...(original.language !== undefined ? { language: original.language } : {}),
    original: { ...(ct.language !== undefined ? { language: ct.language } : {}), words: ct.words } };
}
/** The caption track with translated [words] in [language]; the first original is kept (translating again replaces the translation). */
export function translateCaptions(ct: CaptionTrack, language: string, words: CaptionWord[], sourceLanguage?: string): CaptionTrack {
  const lang = ct.language ?? sourceLanguage;
  const original = ct.original ?? { ...(lang !== undefined ? { language: lang } : {}), words: ct.words };
  return { ...ct, words, language, original };
}
export type Duck = { level?: number; fadeSec?: number; attackSec?: number; releaseSec?: number; under: ('voice' | 'speech')[] };
export type TrackKind = 'main' | 'video' | 'image' | 'text' | 'caption' | 'music' | 'voice' | 'sfx' | 'adjust';
/**
 * An adjustment layer (M): while on screen, its colour (adjust and filter, mixed with the identity by its strength
 * `opacity`) applies to the whole composed picture under the text and captions (`adjustLayerMatrix`).
 */
export type AdjustItem = { id: string; startSec: number; durationSec: number; adjust?: Adjust; filter?: FilterRef; keyframes?: Keyframes; opacity?: number };
export type Item = VideoClip | ImageItem | TextItem | AudioClip | AdjustItem;
export type Track = { id: string; kind: TrackKind; name?: string; muted?: boolean; hidden?: boolean; volume?: number; items: Item[];
  caption?: CaptionTrack; duck?: Duck };
/** fill (wave 1): what shows where a contain-fitted main clip leaves the frame empty: the background colour (default) or a blurred copy of the clip (blurFill). */
export type Canvas = { width: number; height: number; fps: number; background?: string; fill?: 'color' | 'blur' };
export type EditProject = { version: 2; sourceTakeId: string; canvas: Canvas; assets: Asset[]; tracks: Track[]; mute?: boolean };

export type V1Segment = { inSec: number; outSec: number; speed: number; muted?: boolean };
export type EditListV1 = { version: 1; sourceTakeId: string; sourceDurationSec: number; segments: V1Segment[]; mute: boolean };

export const LIMITS = {
  maxJsonBytes: 256 * 1024, maxTracks: 16, maxItemsPerTrack: 300, maxItems: 600, maxAssets: 60, maxWords: 3000, maxKeyframes: 100,
  minClipSourceSec: 0.1, minItemSec: 0.05, minOutputSec: 0.5, maxOutputSec: 600, minSpeed: 0.1, maxSpeed: 10, endSlackSec: 0.05,
  minTransitionSec: 0.1, maxTransitionSec: 2, maxText: 500, overlapSlackSec: 0.001,
} as const;
export const V1_SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2];
export const TRANSITIONS: TransitionKind[] = ['fade', 'black', 'white', 'slideLeft', 'slideRight', 'slideUp', 'slideDown', 'zoom', 'whip', 'spin', 'glitch',
  'zoomOut', 'whipRight', 'coverLeft', 'coverRight', 'coverUp', 'coverDown', 'splitFade'];
export const MASK_SHAPES: MaskShape[] = ['linear', 'mirror', 'circle', 'rect', 'heart', 'star'];
export const BLEND_MODES: BlendMode[] = ['normal', 'multiply', 'screen', 'overlay', 'softLight', 'darken', 'lighten', 'add'];
/** Freeze frame: a hold lasts 0.1–30 s. */
export const HOLD_MIN_SEC = 0.1, HOLD_MAX_SEC = 30;
export const VOICE_EFFECTS: VoiceEffect[] = ['none', 'warm', 'radio', 'phone', 'deep'];
export const CURVE_PIECES = 48;
/** Speed-curve presets (x = position in the clip's kept source, speed ×). */
export const SPEED_PRESETS: Record<Exclude<SpeedPreset, 'custom'>, [number, number][]> = {
  montage: [[0, 1], [0.2, 4], [0.4, 0.5], [0.6, 4], [0.8, 0.5], [1, 1]],
  hero: [[0, 1], [0.3, 1], [0.42, 6], [0.58, 6], [0.7, 1], [1, 1]],
  bullet: [[0, 4], [0.35, 4], [0.45, 0.2], [0.55, 0.2], [0.65, 4], [1, 4]],
  flashIn: [[0, 6], [0.4, 6], [0.6, 1], [1, 1]],
  flashOut: [[0, 1], [0.4, 1], [0.6, 6], [1, 6]],
};
export const ANIMS: AnimKind[] = ['none', 'fade', 'pop', 'slideUp', 'slideDown', 'zoom', 'typewriter'];
/** A project's reference to a content library item (catalog pack and item ids). */
export const CONTENT_REF = /^content:[a-z0-9-]+\/[a-z0-9_.-]+$/;
export const FONTS = ['sans', 'serif', 'rounded', 'condensed', 'mono', 'marker', 'inter', 'montserrat', 'robotoCondensed', 'playfair', 'unbounded', 'rubik', 'jetbrainsMono', 'caveat', 'oswald'] as const;
/** The built-in family a content font draws in until its file is on the device. */
export const FONT_FALLBACK: Record<FontFamily, FontFamily> = { sans: 'sans', serif: 'serif', rounded: 'rounded', condensed: 'condensed', mono: 'mono', marker: 'marker',
  inter: 'sans', montserrat: 'sans', robotoCondensed: 'condensed', playfair: 'serif', unbounded: 'sans', rubik: 'rounded', jetbrainsMono: 'mono', caveat: 'marker', oswald: 'condensed' };
export const CAPTION_PRESETS: CaptionPreset[] = ['plain', 'highlight', 'box', 'karaoke', 'pop', 'single', 'highlighter', 'neon'];
/** Caption paging constants (plans/video-editor.md "Text, hooks and captions"). */
export const CAPTION_GAP_SEC = 0.6, CAPTION_TAIL_SEC = 0.4, SPEECH_JOIN_SEC = 0.4;

const r6 = (v: number) => Math.round(v * 1e6) / 1e6;
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

// ------------------------------------------------------------------ easing and keyframes
export function ease(kind: Ease | undefined, p: number): number {
  p = clamp(p, 0, 1);
  switch (kind ?? 'linear') {
    case 'easeIn': return p * p;
    case 'easeOut': return 1 - (1 - p) * (1 - p);
    case 'easeInOut': return p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
    case 'hold': return 0;
    default: return p;
  }
}

/** The value of a keyframed property at item-local time t (keys sorted by t). */
export function keyframeValue(keys: Keyframe[], t: number): number {
  if (keys.length === 0) return NaN;
  if (t <= keys[0]!.t) return keys[0]!.v;
  const last = keys[keys.length - 1]!;
  if (t >= last.t) return last.v;
  for (let k = 0; k < keys.length - 1; k++) {
    const a = keys[k]!, b = keys[k + 1]!;
    if (t >= a.t && t < b.t) {
      const span = b.t - a.t;
      if (span <= 0) return b.v;
      return a.v + (b.v - a.v) * ease(a.ease, (t - a.t) / span);
    }
  }
  return last.v;
}

/** A property at item-local t: its keyframes when it has any, else the static value. */
export function propAt(item: { keyframes?: Keyframes }, prop: KfProp, fallback: number, t: number) {
  const k = item.keyframes?.[prop];
  return k && k.length ? keyframeValue(k, t) : fallback;
}

/** The item's adjust at item-local t: each keyed colour property ([COLOR_KF_PROPS]) at its keyframes' value there. */
export function adjustAt(item: { adjust?: Adjust; keyframes?: Keyframes }, t: number): Adjust | undefined {
  const keyed = COLOR_KF_PROPS.filter(p => item.keyframes?.[p]?.length);
  if (!keyed.length) return item.adjust;
  const out: Adjust = { ...(item.adjust ?? {}) };
  for (const p of keyed) out[p] = r6(propAt(item, p, item.adjust?.[p] ?? 0, t));
  return out;
}

/**
 * Auto adjust (M): one frame's levels ([rgb]: r, g, b, … straight sRGB 0–1, e.g. the frame at 96 px) → a gentle adjust
 * for the colour matrix, over [base] (its other fields kept). Exposure moves the mean luma towards 0.45 (±0.6 stop);
 * contrast the 2–98 % spread towards 0.85 (−0.3…0.4); temperature and tint balance red/blue and green half-way;
 * saturation lifts flat footage (+0.15) and calms very saturated footage (−0.1). Fields that come out 0 are left out.
 */
export function autoAdjust(rgb: number[], base?: Adjust): Adjust {
  const n = Math.floor(rgb.length / 3);
  if (n === 0) return { ...(base ?? {}) };
  let r = 0, g = 0, b = 0, chroma = 0;
  const luma: number[] = new Array(n);
  for (let i = 0; i < n; i++) {
    const R = rgb[i * 3]!, G = rgb[i * 3 + 1]!, B = rgb[i * 3 + 2]!;
    r += R; g += G; b += B;
    luma[i] = 0.2126 * R + 0.7152 * G + 0.0722 * B;
    chroma += Math.max(R, G, B) - Math.min(R, G, B);
  }
  r /= n; g /= n; b /= n; chroma /= n;
  luma.sort((x, y) => x - y);
  const mean = luma.reduce((s, v) => s + v, 0) / n;
  const lo = luma[clamp(Math.floor(n * 0.02), 0, n - 1)]!, hi = luma[clamp(Math.floor(n * 0.98), 0, n - 1)]!;
  const r2 = (v: number) => Math.round(v * 100) / 100;
  const e = mean > 1e-3 ? clamp(Math.log(0.45 / mean) / Math.log(2), -0.6, 0.6) : 0.6;
  const spread = hi - lo;
  const c = spread > 1e-3 ? clamp(0.85 / spread - 1, -0.3, 0.4) : 0;
  const rb = (r + b) / 2;
  const t = r + b > 1e-3 ? clamp((b - r) / (0.1 * (r + b)) * 0.5, -1, 1) : 0;
  const tn = g > 1e-3 ? clamp((g - rb) / (0.1 * g + 0.05 * rb) * 0.5, -1, 1) : 0;
  const s = chroma < 0.08 ? 0.15 : chroma > 0.35 ? -0.1 : 0;
  const out: Adjust = { ...(base ?? {}) };
  const set = (k: 'exposure' | 'contrast' | 'saturation' | 'temperature' | 'tint', v: number) => { const x = r2(v); if (x !== 0) out[k] = x; else delete out[k]; };
  set('exposure', e); set('contrast', c); set('saturation', s); set('temperature', t); set('tint', tn);
  return out;
}

const keyed = (item: { keyframes?: Keyframes }, p: KfProp) => !!item.keyframes?.[p]?.length;

/** The item's mask at item-local t: each keyed mask field ([MASK_KF_PROPS]) at its keyframes' value there. */
export function maskAt(item: { mask?: Mask; keyframes?: Keyframes }, t: number): Mask | undefined {
  const m = item.mask;
  if (!m || !MASK_KF_PROPS.some(p => keyed(item, p))) return m;
  const out: Mask = { ...m };
  const f: [MaskKfProp, 'x' | 'y' | 'width' | 'height' | 'rotation' | 'feather', number][] = [
    ['maskX', 'x', 0.5], ['maskY', 'y', 0.5], ['maskWidth', 'width', 0.5], ['maskHeight', 'height', 0.5], ['maskRotation', 'rotation', 0], ['maskFeather', 'feather', 0.1]];
  for (const [p, k, d] of f) if (keyed(item, p)) out[k] = r6(propAt(item, p, m[k] ?? d, t));
  return out;
}

/**
 * The item's look at item-local t: each keyed finishing amount ([LOOK_KF_PROPS]) at its keyframes' value there. A keyed
 * effect the look lacks is added with only its amount (a leak as kind 'warm'), so the renderer's defaults apply.
 */
export function lookAt(item: { look?: Look; keyframes?: Keyframes }, t: number): Look | undefined {
  if (!LOOK_KF_PROPS.some(p => keyed(item, p))) return item.look;
  const out: Look = { ...(item.look ?? {}) };
  if (keyed(item, 'vignette')) out.vignette = { ...(out.vignette ?? {}), amount: r6(propAt(item, 'vignette', out.vignette?.amount ?? 0, t)) };
  if (keyed(item, 'grain')) out.grain = { ...(out.grain ?? {}), amount: r6(propAt(item, 'grain', out.grain?.amount ?? 0, t)) };
  if (keyed(item, 'leak')) out.leak = { kind: 'warm', ...(out.leak ?? {}), amount: r6(propAt(item, 'leak', out.leak?.amount ?? 0, t)) };
  return out;
}

// ------------------------------------------------------------------ timeline
/** Speed at x (0–1) of a curve: smoothstep between points in log speed. */
export function curveSpeed(c: SpeedCurve, x: number): number {
  const pts = c.points;
  if (x <= pts[0]![0]) return pts[0]![1];
  for (let k = 0; k < pts.length - 1; k++) {
    const a = pts[k]!, b = pts[k + 1]!;
    if (x <= b[0]) { const t = b[0] > a[0] ? (x - a[0]) / (b[0] - a[0]) : 1, e = t * t * (3 - 2 * t); return Math.exp(Math.log(a[1]) + (Math.log(b[1]) - Math.log(a[1])) * e); }
  }
  return pts[pts.length - 1]![1];
}
export type Piece = { inSec: number; outSec: number; speed: number };
/** A clip as constant-speed pieces: one piece, or CURVE_PIECES equal source pieces of a speed curve (each at the curve's speed at its middle). Engines render these. */
type Timed = { inSec: number; outSec: number; speed?: number; speedCurve?: SpeedCurve; holdSec?: number };
export function speedPieces(c: Timed): Piece[] {
  if (c.holdSec !== undefined) return [{ inSec: c.inSec, outSec: c.inSec, speed: 1 }];
  if (!c.speedCurve) return [{ inSec: c.inSec, outSec: c.outSec, speed: c.speed ?? 1 }];
  const n = CURVE_PIECES, len = (c.outSec - c.inSec) / n;
  return Array.from({ length: n }, (_, i) => ({ inSec: r6(c.inSec + i * len), outSec: r6(i === n - 1 ? c.outSec : c.inSec + (i + 1) * len), speed: r6(curveSpeed(c.speedCurve!, (i + 0.5) / n)) }));
}
/**
 * A clip switched to the reversed copy [reversed] of a source [durationSec] long (or back to the original): the same
 * stretch of the source, mirrored (in' = D − out, out' = D − in), a speed curve mirrored in x (custom unless symmetric). Keyframes, look and the
 * rest are timeline-local and stay; alphaMatte and audioAsset (aligned to the original's frames) are dropped. Null for a freeze frame (holdSec), which has nothing to reverse.
 */
export function reverseClip(c: VideoClip, reversed: string, durationSec: number): VideoClip | null {
  if (c.holdSec !== undefined) return null;
  const out: VideoClip = { ...c, asset: reversed, inSec: r6(Math.max(0, durationSec - c.outSec)), outSec: r6(Math.min(durationSec, durationSec - c.inSec)) };
  // Lined up frame for frame with the original, so they'd play the wrong way: dropped (the apps say so).
  delete out.alphaMatte; delete out.audioAsset;
  if (c.speedCurve) {
    const points = c.speedCurve.points.map(([x, v]) => [r6(1 - x), v] as [number, number]).sort((a, b) => a[0] - b[0]);
    const same = points.length === c.speedCurve.points.length && points.every((q, i) => q[0] === c.speedCurve!.points[i]![0] && q[1] === c.speedCurve!.points[i]![1]);
    out.speedCurve = { preset: same ? c.speedCurve.preset : 'custom', points }; // a mirrored preset is no longer that preset
  }
  return out;
}

/**
 * A clip switched to a steadied copy [copy] (op 'stabilize') or back to its original (op null): only the asset
 * changes, since the copy has the same length and timing. The steadied frames are moved, so an alpha matte lined up
 * with the original is dropped (the apps say so).
 */
export function deriveClip(c: VideoClip, copy: string, op: 'stabilize' | null): VideoClip {
  const out: VideoClip = { ...c, asset: copy };
  if (op === 'stabilize') delete out.alphaMatte;
  return out;
}

/** Keyframes of the item-local window [a, b]: the value at each edge plus the keys between, times from a × scale. */
function sliceKeys(k: Keyframes | undefined, a: number, b: number, scale: number): Keyframes | undefined {
  if (!k) return undefined;
  const out: Keyframes = {};
  for (const [prop, keys] of Object.entries(k) as [KfProp, Keyframe[]][]) {
    if (!keys?.length) continue;
    const ease = [...keys].reverse().find(x => x.t <= a + 1e-9)?.ease;
    out[prop] = [{ t: 0, v: r6(keyframeValue(keys, a)), ...(ease ? { ease } : {}) },
      ...keys.filter(x => x.t > a + 1e-9 && x.t < b - 1e-9).map(x => ({ ...x, t: r6((x.t - a) * scale) })),
      { t: r6((b - a) * scale), v: r6(keyframeValue(keys, b)) }];
  }
  return out;
}
/**
 * Smooth slow motion: the main clip [clipId] split around the source range of the slowmo copy [slowId] (made from the
 * clip's own asset, the range inside the clip), the middle piece playing the copy (in 0, out range × factor, speed 1,
 * muted; no alpha matte or separate sound, which were lined up with the original). Side pieces under 0.1 s of source
 * are dropped. The first piece keeps the id, transition, fade and animation in; the last the fade and animation out;
 * keyframes are sliced per piece (the middle's stretched). New ids are the next free `<id>.N`. Null when it can't apply
 * (a freeze frame, a speed curve, another asset, the range outside the clip).
 */
export function applySlowmo(p: EditProject, clipId: string, slowId: string): { project: EditProject; id: string } | null {
  const main = mainTrack(p);
  const i = main.items.findIndex(x => x.id === clipId);
  const c = main.items[i] as VideoClip | undefined;
  const slow = p.assets.find(a => a.id === slowId);
  const d = slow?.derivedFrom;
  if (!c || !slow || !d || d.op !== 'slowmo' || d.asset !== c.asset || c.holdSec !== undefined || c.speedCurve) return null;
  if (d.startSec < c.inSec - 1e-6 || d.endSec > c.outSec + 1e-6 || d.endSec - d.startSec < LIMITS.minClipSourceSec) return null;
  const speed = c.speed ?? 1;
  const midLen = r6(Math.min((d.endSec - d.startSec) * d.factor, slow.durationSec ?? Infinity));
  const la = (d.startSec - c.inSec) / speed, lb = (d.endSec - c.inSec) / speed, len = clipLength(c);
  const ids = new Set(p.tracks.flatMap(t => t.items.map(x => x.id)));
  const nextId = () => { let n = 2; while (ids.has(`${c.id}.${n}`)) n++; const id = `${c.id}.${n}`; ids.add(id); return id; };
  const { transitionIn, fadeInSec, fadeOutSec, animIn, animOut, keyframes, ...base } = c;
  const hasBefore = d.startSec - c.inSec >= LIMITS.minClipSourceSec - 1e-9;
  const hasAfter = c.outSec - d.endSec >= LIMITS.minClipSourceSec - 1e-9;
  const pieces: VideoClip[] = [];
  const first = (v: VideoClip) => ({ ...v, ...(transitionIn ? { transitionIn } : {}), ...(fadeInSec !== undefined ? { fadeInSec } : {}), ...(animIn ? { animIn } : {}) });
  const last = (v: VideoClip) => ({ ...v, ...(fadeOutSec !== undefined ? { fadeOutSec } : {}), ...(animOut ? { animOut } : {}) });
  const withKeys = (v: VideoClip, a: number, b: number, scale: number): VideoClip => { const k = sliceKeys(keyframes, a, b, scale); return k ? { ...v, keyframes: k } : v; };
  if (hasBefore) pieces.push(withKeys({ ...base, outSec: r6(d.startSec) }, 0, la, 1));
  const { alphaMatte: _m, audioAsset: _a, ...plain } = base;
  const midId = hasBefore ? nextId() : c.id;
  pieces.push(withKeys({ ...plain, id: midId, asset: slowId, inSec: 0, outSec: midLen, speed: 1, muted: true }, la, lb, lb > la ? midLen / (lb - la) : 1));
  if (hasAfter) pieces.push(withKeys({ ...base, id: nextId(), inSec: r6(d.endSec) }, lb, len, 1));
  pieces[0] = first(pieces[0]!); pieces[pieces.length - 1] = last(pieces[pieces.length - 1]!);
  const items = [...main.items.slice(0, i), ...pieces, ...main.items.slice(i + 1)];
  return { project: { ...p, tracks: p.tracks.map(t => (t === main ? { ...t, items } : t)) }, id: midId };
}

/** The helper steps from the original to [assetId], in the order applied ('stabilize' | 'slowmo' | 'reverse'). */
export function derivedOps(p: Pick<EditProject, 'assets'>, assetId: string): (DerivedOp | 'reverse')[] {
  const byId = new Map(p.assets.map(a => [a.id, a]));
  const ops: (DerivedOp | 'reverse')[] = [];
  let a = byId.get(assetId);
  for (let n = 0; a && n < 8; n++) {
    if (a.derivedFrom) { ops.push(a.derivedFrom.op); a = byId.get(a.derivedFrom.asset); }
    else if (a.reverseOf !== undefined) { ops.push('reverse'); a = byId.get(a.reverseOf); }
    else break;
  }
  return ops.reverse();
}
/** The original video an asset was made from (itself when it's not a copy). */
export function sourceOf(p: Pick<EditProject, 'assets'>, assetId: string): string {
  const byId = new Map(p.assets.map(a => [a.id, a]));
  let id = assetId;
  for (let n = 0; n < 8; n++) {
    const a = byId.get(id);
    const next = a?.derivedFrom?.asset ?? a?.reverseOf;
    if (next === undefined || !byId.has(next)) break;
    id = next;
  }
  return id;
}
/** The clip's helper label in the order applied, e.g. "Steadied, reversed" or "Steadied, smooth 4×"; "" for an original. */
export function derivedLabel(p: Pick<EditProject, 'assets'>, assetId: string): string {
  const byId = new Map(p.assets.map(a => [a.id, a]));
  const words: string[] = [];
  let a = byId.get(assetId);
  for (let n = 0; a && n < 8; n++) {
    const d: DerivedFrom | undefined = a.derivedFrom;
    if (d) { words.push(d.op === 'stabilize' ? 'steadied' : `smooth ${d.factor}×`); a = byId.get(d.asset); }
    else if (a.reverseOf !== undefined) { words.push('reversed'); a = byId.get(a.reverseOf); }
    else break;
  }
  const s = words.reverse().join(', ');
  return s ? s[0]!.toUpperCase() + s.slice(1) : '';
}

/** A hold (freeze frame) lasts holdSec whatever its source range. */
export const clipLength = (c: Timed) => c.holdSec !== undefined ? c.holdSec :
  c.speedCurve ? speedPieces(c).reduce((s, p) => s + (p.outSec - p.inSec) / p.speed, 0) : (c.outSec - c.inSec) / (c.speed ?? 1);
/** Seconds from the clip's start on the timeline at source time `sec` (clamped to the clip). */
export function clipTimeAt(c: Timed, sec: number): number {
  if (c.holdSec !== undefined) return 0;
  let acc = 0;
  for (const p of speedPieces(c)) {
    if (sec <= p.outSec) return acc + Math.max(0, sec - p.inSec) / p.speed;
    acc += (p.outSec - p.inSec) / p.speed;
  }
  return acc;
}
/** Source time at `t` seconds from the clip's start on the timeline (the inverse of clipTimeAt; clamped to the clip). */
export function clipSourceAt(c: Timed, t: number): number {
  if (c.holdSec !== undefined) return c.inSec;
  let acc = 0;
  for (const p of speedPieces(c)) {
    const len = (p.outSec - p.inSec) / p.speed;
    if (t <= acc + len) return Math.min(p.outSec, p.inSec + Math.max(0, t - acc) * p.speed);
    acc += len;
  }
  return c.outSec;
}
/** A curve cut down to the source range [x0, x1] of its clip, rescaled to 0–1 (preset becomes custom). */
export function subCurve(c: SpeedCurve, x0: number, x1: number): SpeedCurve {
  const inner = c.points.filter(p => p[0] > x0 + 1e-9 && p[0] < x1 - 1e-9).map(p => [r6((p[0] - x0) / (x1 - x0)), p[1]] as [number, number]);
  return { preset: 'custom', points: [[0, r6(curveSpeed(c, x0))], ...inner, [1, r6(curveSpeed(c, x1))]] };
}
export const mainTrack = (p: EditProject) => p.tracks.find(t => t.kind === 'main')!;

export type MainSpan = { id: string; index: number; startSec: number; endSec: number; transitionSec: number };
/** Each main clip's place on the timeline. A clip with transitionIn starts that much before the previous clip ends. */
export function timeline(p: EditProject): MainSpan[] {
  const out: MainSpan[] = [];
  let end = 0;
  mainTrack(p).items.forEach((it, i) => {
    const c = it as VideoClip;
    const tr = i > 0 && c.transitionIn ? c.transitionIn.durationSec : 0;
    const start = Math.max(0, end - tr);
    const len = clipLength(c);
    out.push({ id: c.id, index: i, startSec: r6(start), endSec: r6(start + len), transitionSec: tr });
    end = start + len;
  });
  return out;
}
export const durationSec = (p: EditProject) => { const t = timeline(p); return t.length ? t[t.length - 1]!.endSec : 0; };

/** Timeline start/end of any item (main clips through timeline(); others from startSec). */
export function itemSpan(p: EditProject, track: Track, item: Item): { startSec: number; endSec: number } {
  if (track.kind === 'main') { const s = timeline(p).find(x => x.id === item.id)!; return { startSec: s.startSec, endSec: s.endSec }; }
  const start = (item as { startSec: number }).startSec;
  const len = 'inSec' in item ? clipLength(item as AudioClip) : (item as ImageItem).durationSec;
  return { startSec: r6(start), endSec: r6(start + len) };
}

// ------------------------------------------------------------------ v1 <-> v2
export function fromV1(v1: EditListV1, info: { width: number; height: number; fps: number; hasAudio?: boolean }): EditProject {
  const asset: Asset = { id: 'src', kind: 'video', take: v1.sourceTakeId, durationSec: v1.sourceDurationSec, width: info.width, height: info.height, hasAudio: info.hasAudio ?? true };
  return {
    version: 2, sourceTakeId: v1.sourceTakeId, canvas: { width: info.width, height: info.height, fps: info.fps, background: '#000000' },
    assets: [asset],
    tracks: [{ id: 'main', kind: 'main', items: v1.segments.map((s, i) => ({ id: `c${i + 1}`, asset: 'src', inSec: s.inSec, outSec: s.outSec, speed: s.speed, ...(s.muted ? { muted: true } : {}) })) }],
    ...(v1.mute ? { mute: true } : {}),
  };
}

const V1_CLIP_KEYS = new Set(['id', 'asset', 'inSec', 'outSec', 'speed', 'muted']);
/** The v1 edit list for a project that only uses v1 features (one source, main track only, v1 speeds, in order); else null. */
export function toV1(p: EditProject): EditListV1 | null {
  if (p.tracks.length !== 1 || p.tracks[0]!.kind !== 'main') return null;
  const t = p.tracks[0]!;
  if (t.muted || t.hidden || (t.volume != null && t.volume !== 1)) return null;
  const src = p.assets.find(a => a.take === p.sourceTakeId && a.kind === 'video');
  if (!src || src.durationSec == null) return null;
  let prev = 0;
  const segs: V1Segment[] = [];
  for (const it of t.items as VideoClip[]) {
    if (it.asset !== src.id || !V1_SPEEDS.includes(it.speed) || it.inSec < prev - 1e-9) return null;
    if (Object.keys(it).some(k => !V1_CLIP_KEYS.has(k) && (it as Record<string, unknown>)[k] !== undefined)) return null;
    prev = it.outSec;
    segs.push({ inSec: it.inSec, outSec: it.outSec, speed: it.speed, ...(it.muted ? { muted: true } : {}) });
  }
  if (segs.length > 50) return null;
  return { version: 1, sourceTakeId: p.sourceTakeId, sourceDurationSec: src.durationSec, segments: segs, mute: !!p.mute };
}

// ------------------------------------------------------------------ cuts (silence / filler removal)
export type Range = { startSec: number; endSec: number };
/** Merges and sorts source ranges. */
export function mergeRanges(rs: Range[], joinGap = 0): Range[] {
  const s = rs.filter(r => r.endSec > r.startSec).map(r => ({ ...r })).sort((a, b) => a.startSec - b.startSec);
  const out: Range[] = [];
  for (const r of s) {
    const last = out[out.length - 1];
    if (last && r.startSec <= last.endSec + joinGap) last.endSec = Math.max(last.endSec, r.endSec);
    else out.push({ startSec: r.startSec, endSec: r.endSec });
  }
  return out;
}

/**
 * Removes source ranges of `assetId` from every main clip of that asset (silence/filler suggestions). Clips are split
 * around the cuts; pieces shorter than 0.1 s of source are dropped; looks and speed carry over; a transition stays only
 * on the first piece of a clip that kept its start. Ids: a split clip's pieces are `<id>`, `<id>.2`, `<id>.3`… Returns
 * the project unchanged when every clip would disappear.
 */
export function applyCuts(p: EditProject, assetId: string, cuts: Range[]): EditProject {
  const rs = mergeRanges(cuts);
  const main = mainTrack(p);
  const items: VideoClip[] = [];
  for (const it of main.items as VideoClip[]) {
    if (it.asset !== assetId) { items.push(it); continue; }
    // A hold (freeze frame) has no source span: it goes when a cut covers its frame, else it stays as it is.
    if (it.holdSec !== undefined) { if (!rs.some(r => it.inSec >= r.startSec && it.inSec < r.endSec)) items.push(it); continue; }
    let pieces: Range[] = [{ startSec: it.inSec, endSec: it.outSec }];
    for (const r of rs) {
      pieces = pieces.flatMap(pc => {
        if (r.endSec <= pc.startSec || r.startSec >= pc.endSec) return [pc];
        const keep: Range[] = [];
        if (r.startSec > pc.startSec) keep.push({ startSec: pc.startSec, endSec: r.startSec });
        if (r.endSec < pc.endSec) keep.push({ startSec: r.endSec, endSec: pc.endSec });
        return keep;
      });
    }
    pieces = pieces.filter(pc => pc.endSec - pc.startSec >= LIMITS.minClipSourceSec - 1e-9);
    pieces.forEach((pc, k) => {
      const { transitionIn, ...rest } = it;
      const keepsStart = k === 0 && Math.abs(pc.startSec - it.inSec) < 1e-9;
      const curve = it.speedCurve ? { speedCurve: subCurve(it.speedCurve, (pc.startSec - it.inSec) / (it.outSec - it.inSec), (pc.endSec - it.inSec) / (it.outSec - it.inSec)) } : {};
      items.push({ ...rest, ...curve, id: k === 0 ? it.id : `${it.id}.${k + 1}`, inSec: r6(pc.startSec), outSec: r6(pc.endSec),
        ...(transitionIn && keepsStart ? { transitionIn } : {}) });
    });
  }
  if (!items.length) return p;
  // A transition may now be on the first clip, or longer than its new neighbours allow: drop those.
  const fixed = items.map((c, i) => {
    if (!c.transitionIn) return c;
    const prev = items[i - 1];
    const ok = i > 0 && c.transitionIn.durationSec <= clipLength(c) / 2 + 1e-9 && prev && c.transitionIn.durationSec <= clipLength(prev) / 2 + 1e-9;
    if (ok) return c;
    const { transitionIn: _drop, ...rest } = c;
    return rest;
  });
  return { ...p, tracks: p.tracks.map(t => (t === main ? { ...t, items: fixed } : t)) };
}

// ------------------------------------------------------------------ captions
export type TimedWord = { text: string; startSec: number; endSec: number; index: number };
/** Caption words on the timeline: each source word mapped through every main clip of the caption asset that keeps its midpoint. */
export function captionWords(p: EditProject): TimedWord[] {
  const ct = p.tracks.find(t => t.kind === 'caption' && t.caption)?.caption;
  if (!ct) return [];
  const spans = timeline(p);
  const out: TimedWord[] = [];
  (mainTrack(p).items as VideoClip[]).forEach((c, i) => {
    if (c.asset !== ct.asset || c.holdSec !== undefined) return; // a hold has no speech
    const s = spans[i]!;
    ct.words.forEach((w, idx) => {
      const mid = (w.startSec + w.endSec) / 2;
      if (mid < c.inSec || mid >= c.outSec) return;
      const a = Math.max(w.startSec, c.inSec), b = Math.min(w.endSec, c.outSec);
      out.push({ text: w.text, startSec: r6(s.startSec + clipTimeAt(c, a)), endSec: r6(s.startSec + clipTimeAt(c, b)), index: idx });
    });
  });
  return out.sort((a, b) => a.startSec - b.startSec || a.index - b.index);
}

export type CaptionPage = { startSec: number; endSec: number; words: TimedWord[] };
export function captionPages(p: EditProject): CaptionPage[] {
  const ct = p.tracks.find(t => t.kind === 'caption' && t.caption)?.caption;
  if (!ct) return [];
  const per = ct.style.preset === 'single' ? 1 : clamp(Math.round(ct.style.wordsPerPage ?? 3), 1, 8);
  const words = captionWords(p);
  const pages: TimedWord[][] = [];
  let cur: TimedWord[] = [];
  words.forEach((w, i) => {
    cur.push(w);
    const next = words[i + 1];
    const brk = cur.length >= per || !next || next.startSec - w.endSec > CAPTION_GAP_SEC || /[.!?]["')\]]*$/.test(w.text.trim());
    if (brk) { pages.push(cur); cur = []; }
  });
  return pages.map((ws, i) => {
    const next = pages[i + 1];
    const tail = ws[ws.length - 1]!.endSec + CAPTION_TAIL_SEC;
    return { startSec: ws[0]!.startSec, endSec: r6(next ? Math.min(next[0]!.startSec, tail) : tail), words: ws };
  });
}

/** The page shown at t and its active word (index into page.words), or null. */
export function captionAt(p: EditProject, t: number): { page: number; word: number } | null {
  const pages = captionPages(p);
  for (let i = 0; i < pages.length; i++) {
    const pg = pages[i]!;
    if (t >= pg.startSec && t < pg.endSec) {
      let w = 0;
      pg.words.forEach((x, k) => { if (x.startSec <= t) w = k; });
      return { page: i, word: w };
    }
  }
  return null;
}

// ------------------------------------------------------------------ transitions and animations
/** rotation in degrees clockwise; blur 0–1 (motion blur along the move, up to 4 % of the canvas); rgbSplit 0–1 (channel offset up to 2 %). */
export type LayerState = { opacity: number; dx: number; dy: number; scale: number; rotation: number; blur: number; rgbSplit: number };
export type TransitionState = { a: LayerState; b: LayerState; color: string | null };
export function transitionState(kind: TransitionKind, p: number): TransitionState {
  p = clamp(p, 0, 1);
  const e = ease('easeInOut', p);
  const L = (o: Partial<LayerState> = {}): LayerState => ({ opacity: 1, dx: 0, dy: 0, scale: 1, rotation: 0, blur: 0, rgbSplit: 0, ...o });
  const e3 = p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2, peak = Math.sin(Math.PI * p);
  const jit = (seed: number) => (hash01(Math.floor(p * 24), seed, 7) - 0.5) * 2;
  switch (kind) {
    case 'fade': return { a: L(), b: L({ opacity: p }), color: null };
    case 'black': case 'white': return { a: L({ opacity: Math.max(0, 1 - 2 * p) }), b: L({ opacity: Math.max(0, 2 * p - 1) }), color: kind === 'black' ? '#000000' : '#FFFFFF' };
    case 'slideLeft': return { a: L({ dx: -e }), b: L({ dx: 1 - e }), color: null };
    case 'slideRight': return { a: L({ dx: e }), b: L({ dx: -(1 - e) }), color: null };
    case 'slideUp': return { a: L({ dy: -e }), b: L({ dy: 1 - e }), color: null };
    case 'slideDown': return { a: L({ dy: e }), b: L({ dy: -(1 - e) }), color: null };
    case 'zoom': return { a: L({ scale: 1 + 0.25 * e, opacity: 1 - p }), b: L({ opacity: p }), color: null };
    case 'whip': return { a: L({ dx: -e3, blur: peak }), b: L({ dx: 1 - e3, blur: peak }), color: null };
    case 'spin': return { a: L({ rotation: 180 * e, scale: 1 - 0.6 * e, opacity: p < 0.5 ? 1 : 0 }), b: L({ rotation: -180 * (1 - e), scale: 0.4 + 0.6 * e, opacity: p < 0.5 ? 0 : 1 }), color: null };
    case 'glitch': return { a: L({ opacity: p < 0.5 ? 1 : 0, dx: 0.04 * peak * jit(1), rgbSplit: peak }), b: L({ opacity: p < 0.5 ? 0 : 1, dx: 0.04 * peak * jit(2), rgbSplit: peak }), color: null };
    case 'zoomOut': return { a: L({ scale: 1 - 0.2 * e, opacity: 1 - p }), b: L({ scale: 1.2 - 0.2 * e, opacity: p }), color: null };
    case 'whipRight': return { a: L({ dx: e3, blur: peak }), b: L({ dx: -(1 - e3), blur: peak }), color: null };
    // Cover: the incoming clip slides over the outgoing one, which stays still and fully shown underneath.
    case 'coverLeft': return { a: L(), b: L({ dx: 1 - e }), color: null };
    case 'coverRight': return { a: L(), b: L({ dx: -(1 - e) }), color: null };
    case 'coverUp': return { a: L(), b: L({ dy: 1 - e }), color: null };
    case 'coverDown': return { a: L(), b: L({ dy: -(1 - e) }), color: null };
    case 'splitFade': return { a: L({ rgbSplit: peak }), b: L({ opacity: p, rgbSplit: peak }), color: null };
  }
}

export type AnimState = { opacity: number; scale: number; dy: number; chars: number | null };

/** Loop animations (M): a repeating move while the item is on screen. */
export type LoopKind = 'pulse' | 'sway' | 'float' | 'spin' | 'blink';
export const LOOP_KINDS: LoopKind[] = ['pulse', 'sway', 'float', 'spin', 'blink'];
export type AnimLoop = { kind: LoopKind; periodSec: number; amount?: number };
export type LoopState = { scale: number; rotation: number; dy: number; opacity: number };
/**
 * A loop at item-local t: scale ×, rotation + (degrees), dy + (canvas heights, negative up), opacity ×. Every kind is at
 * rest at t = 0; [amount] defaults to 0.5 (spin ignores it).
 */
export function loopState(loop: AnimLoop | undefined, t: number): LoopState {
  const st: LoopState = { scale: 1, rotation: 0, dy: 0, opacity: 1 };
  if (!loop || !(loop.periodSec > 0)) return st;
  const a = clamp(loop.amount ?? 0.5, 0, 1), ph = (2 * Math.PI * t) / loop.periodSec, wave = 0.5 - 0.5 * Math.cos(ph);
  switch (loop.kind) {
    case 'pulse': st.scale = 1 + 0.12 * a * wave; break;
    case 'sway': st.rotation = 8 * a * Math.sin(ph); break;
    case 'float': st.dy = -0.03 * a * Math.sin(ph); break;
    case 'spin': st.rotation = ((360 * t) / loop.periodSec) % 360; break;
    case 'blink': st.opacity = 1 - a * wave; break;
  }
  return { scale: r6(st.scale), rotation: r6(st.rotation), dy: r6(st.dy), opacity: r6(st.opacity) };
}
/** In/out animation of an image or text item at item-local t (chars: how many characters typewriter shows, else null). */
export function animState(item: { durationSec: number; animIn?: Anim; animOut?: Anim; text?: string }, t: number): AnimState {
  const st: AnimState = { opacity: 1, scale: 1, dy: 0, chars: null };
  const n = item.text != null ? [...item.text].length : 0;
  const apply = (a: Anim | undefined, p: number) => {
    if (!a || a.kind === 'none') return;
    const e = ease('easeOut', p);
    switch (a.kind) {
      case 'fade': st.opacity *= e; break;
      case 'pop': st.opacity *= e; st.scale *= p < 0.7 ? 0.6 + (1.08 - 0.6) * (p / 0.7) : 1.08 + (1 - 1.08) * ((p - 0.7) / 0.3); break;
      case 'slideUp': st.opacity *= e; st.dy += 0.05 * (1 - e); break;
      case 'slideDown': st.opacity *= e; st.dy -= 0.05 * (1 - e); break;
      case 'zoom': st.opacity *= e; st.scale *= 1.3 + (1 - 1.3) * e; break;
      case 'typewriter': st.chars = Math.min(st.chars ?? n, Math.ceil(clamp(p, 0, 1) * n)); break;
    }
  };
  if (item.animIn) apply(item.animIn, item.animIn.durationSec > 0 ? clamp(t / item.animIn.durationSec, 0, 1) : 1);
  if (item.animOut) apply(item.animOut, item.animOut.durationSec > 0 ? clamp((item.durationSec - t) / item.animOut.durationSec, 0, 1) : 1);
  return { opacity: r6(st.opacity), scale: r6(st.scale), dy: r6(st.dy), chars: st.chars };
}

// ------------------------------------------------------------------ colour
export type FilterPreset = { id: string; label: string; adjust: Adjust; tint?: { color: string; strength: number } };
export const hexRgb = (h: string): [number, number, number] => {
  const n = parseInt(h.slice(1), 16);
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
};
type M = number[]; // 3×4 row-major: [r0 r1 r2 r3, g0.., b0..]; out = M · (r, g, b, 1)
const ID: M = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0];
/** a ∘ b: apply b first, then a. */
function mul(a: M, b: M): M {
  const o: M = new Array(12).fill(0);
  for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 4; j++) {
      let s = 0;
      for (let k = 0; k < 3; k++) s += a[i * 4 + k]! * b[k * 4 + j]!;
      if (j === 3) s += a[i * 4 + 3]!;
      o[i * 4 + j] = s;
    }
  }
  return o;
}
const LUMA = [0.2126, 0.7152, 0.0722];
/** The adjust an item ends up with: its own plus amount × the filter preset's (each clamped to ±1), and the tint. */
export function effectiveAdjust(adjust: Adjust | undefined, filter: FilterRef | undefined, presets: FilterPreset[]): { adjust: Required<Pick<Adjust, 'exposure' | 'contrast' | 'saturation' | 'temperature'>>; tint: { color: string; strength: number } | null } {
  const a = { exposure: adjust?.exposure ?? 0, contrast: adjust?.contrast ?? 0, saturation: adjust?.saturation ?? 0, temperature: adjust?.temperature ?? 0 };
  const pr = filter ? presets.find(x => x.id === filter.id) : undefined;
  let tint: { color: string; strength: number } | null = null;
  if (pr && filter) {
    const k = clamp(filter.amount, 0, 1);
    for (const key of ['exposure', 'contrast', 'saturation', 'temperature'] as const) a[key] = clamp(a[key] + k * (pr.adjust[key] ?? 0), -1, 1);
    if (pr.tint && k > 0) tint = { color: pr.tint.color, strength: pr.tint.strength * k };
  }
  return { adjust: a, tint };
}
/**
 * Highlights/shadows (Adjust, −1…1) on one channel value, after the colour matrix: shadows move values around 1/3,
 * highlights around 2/3 (weights 4v(1−v)² and 4v²(1−v), at most ±0.25·0.6).
 */
export function toneAdjust(v: number, shadows = 0, highlights = 0): number {
  if (!shadows && !highlights) return v;
  return clamp(v + 0.25 * (shadows * 4 * v * (1 - v) * (1 - v) + highlights * 4 * v * v * (1 - v)), 0, 1);
}

// ------------------------------------------------------------------ masks
/** Mask opacity (0–1) at u, v of the item's own frame (0–1). Distances are in item fractions; feather is the soft edge width. */
export function maskAlpha(m: Mask, u: number, v: number): number {
  const cx = m.x ?? 0.5, cy = m.y ?? 0.5, w = Math.max(0.01, m.width ?? 0.5), h = Math.max(0.01, m.height ?? 0.5), f = Math.max(1e-4, m.feather ?? 0.1);
  const a = ((m.rotation ?? 0) * Math.PI) / 180, du = u - cx, dv = v - cy;
  const x = du * Math.cos(a) + dv * Math.sin(a), y = -du * Math.sin(a) + dv * Math.cos(a); // into mask space
  const soft = (d: number) => 1 - smoothstep(-f / 2, f / 2, d); // d < 0 inside
  let alpha: number;
  switch (m.shape) {
    case 'linear': alpha = soft(y); break;                                   // visible above the line
    case 'mirror': alpha = soft(Math.abs(y) - h / 2); break;                 // a band h tall
    case 'circle': { const r = Math.hypot(x / (w / 2), y / (h / 2)); alpha = soft((r - 1) * Math.min(w, h) / 2); break; }
    case 'rect': alpha = soft(Math.max(Math.abs(x) - w / 2, Math.abs(y) - h / 2)); break;
    case 'heart': {
      const X = (x / (w / 2)) * 1.15, Y = (-y / (h / 2)) * 1.15 + 0.25;
      const F = Math.pow(X * X + Y * Y - 1, 3) - X * X * Y * Y * Y;            // < 0 inside
      alpha = soft(F * 0.6 * Math.min(w, h)); break;
    }
    case 'star': {
      const X = x / (w / 2), Y = y / (h / 2), r = Math.hypot(X, Y);
      const ang = ((Math.atan2(X, -Y) * 180) / Math.PI + 360) % 72, t = Math.abs(ang - 36) / 36; // 0 at an inner corner, 1 at a point
      const edge = 0.45 + 0.55 * t;
      alpha = soft((r - edge) * Math.min(w, h) / 2); break;
    }
  }
  return r6(m.invert ? 1 - alpha : alpha);
}
const smoothstep = (a: number, b: number, x: number) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };

// ------------------------------------------------------------------ SRT
const srtTime = (t: number) => { const ms = Math.round(Math.max(0, t) * 1000); const h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60, s = Math.floor(ms / 1000) % 60;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')},${String(ms % 1000).padStart(3, '0')}`; };
/** The captions as an .srt file (one cue per caption page; upper case when the style says so). Empty without captions. */
// ------------------------------------------------------------------ wave 1: mirror, blend modes, blur fill
/** One channel of the W3C compositing blend functions: top = the item (Cs), below = the backdrop (Cb), both 0–1. */
export function blendChannel(mode: BlendMode, top: number, below: number): number {
  const s = top, b = below;
  switch (mode) {
    case 'normal': return s;
    case 'multiply': return b * s;
    case 'screen': return b + s - b * s;
    case 'overlay': return b <= 0.5 ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s);           // = hard-light with the layers swapped
    case 'softLight': {
      if (s <= 0.5) return b - (1 - 2 * s) * b * (1 - b);
      const d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : Math.sqrt(b);
      return b + (2 * s - 1) * (d - b);
    }
    case 'darken': return Math.min(b, s);
    case 'lighten': return Math.max(b, s);
    case 'add': return Math.min(1, b + s);
  }
}
/**
 * A pixel of a blended item over what is below it: the blend on straight (not premultiplied) sRGB 0–1, then mixed in by the
 * item's coverage a = alpha (chroma key / matte / mask) × opacity: result = below + (blend − below) × a.
 */
export function blendPixel(mode: BlendMode, top: [number, number, number], below: [number, number, number], a: number): [number, number, number] {
  return [0, 1, 2].map(i => r6(below[i]! + (clamp(blendChannel(mode, top[i]!, below[i]!), 0, 1) - below[i]!) * clamp(a, 0, 1))) as [number, number, number];
}
/**
 * Where an item's picture corners land on the canvas (pixels): the picture (after its crop, w × h px) is fitted (cover / contain)
 * to the canvas, mirrored about its centre (flipX / flipY), scaled, rotated clockwise and moved to (x, y). Corners are the
 * picture's own top-left, top-right, bottom-right, bottom-left, so a flip shows as swapped corners. Order: crop → flip → scale → rotate → move.
 */
export function itemCorners(canvas: { width: number; height: number }, w: number, h: number, fit: Fit, t: Transform = {}): [number, number][] {
  const k = fit === 'cover' ? Math.max(canvas.width / w, canvas.height / h) : Math.min(canvas.width / w, canvas.height / h);
  const sc = t.scale ?? 1, hw = (w * k * sc) / 2, hh = (h * k * sc) / 2;
  const fx = t.flipX ? -1 : 1, fy = t.flipY ? -1 : 1;
  const a = ((t.rotation ?? 0) * Math.PI) / 180, cos = Math.cos(a), sin = Math.sin(a);
  const cx = (t.x ?? 0.5) * canvas.width, cy = (t.y ?? 0.5) * canvas.height;
  return ([[-1, -1], [1, -1], [1, 1], [-1, 1]] as const).map(([u, v]) => {
    const px = u * hw * fx, py = v * hh * fy;
    return [r6(cx + px * cos - py * sin), r6(cy + px * sin + py * cos)] as [number, number];
  });
}
/** Blur fill: the box-blur radius in pixels for a canvas (applied once, separable, clamp to edge), then RGB × BLUR_FILL_DARKEN. */
export const blurFillRadius = (canvas: { width: number; height: number }) => Math.max(1, Math.round(0.04 * Math.min(canvas.width, canvas.height)));
export const BLUR_FILL_DARKEN = 0.85;
/**
 * The blur fill of a frame (wave 1): the main clip's picture cover-fitted to the canvas (its look applied, not its transform),
 * box-blurred and darkened. During a transition it is the incoming clip's frame once progress ≥ 0.5, else the outgoing one's.
 * rgb: w × h × 3 floats 0–1 (the cover-fitted frame); returns the fill, same layout.
 */
export function blurFill(rgb: number[], w: number, h: number, radius: number): number[] {
  const box = (src: number[], horiz: boolean): number[] => {
    const out = new Array(src.length).fill(0);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let c = 0; c < 3; c++) {
      let sum = 0;
      for (let k = -radius; k <= radius; k++) {
        const xx = horiz ? clamp(x + k, 0, w - 1) : x, yy = horiz ? y : clamp(y + k, 0, h - 1);
        sum += src[(yy * w + xx) * 3 + c]!;
      }
      out[(y * w + x) * 3 + c] = sum / (2 * radius + 1);
    }
    return out;
  };
  return box(box(rgb, true), false).map(v => r6(v * BLUR_FILL_DARKEN));
}
/** The timeline time whose main-clip frame the blur fill uses at t (the incoming clip from half-way through a transition). */
export function blurFillClip(p: EditProject, t: number): { clipId: string; local: number } | null {
  const spans = timeline(p);
  let pick: MainSpan | undefined;
  for (let i = 0; i < spans.length; i++) {
    const s = spans[i]!;
    if (t < s.startSec - 1e-9 || t > s.endSec + 1e-9) continue;
    const next = spans[i + 1];
    if (next && t >= next.startSec && next.transitionSec > 0) { pick = (t - next.startSec) / next.transitionSec >= 0.5 ? next : s; break; }
    pick = s; break;
  }
  return pick ? { clipId: pick.id, local: r6(t - pick.startSec) } : null;
}

export function toSrt(p: EditProject): string {
  const ct = p.tracks.find(t => t.kind === 'caption' && t.caption)?.caption;
  if (!ct) return '';
  return captionPages(p).map((pg, i) => {
    const text = captionText(pg.words, ct.language);
    return `${i + 1}\n${srtTime(pg.startSec)} --> ${srtTime(pg.endSec)}\n${ct.style.uppercase ? text.toUpperCase() : text}\n`;
  }).join('\n');
}

/**
 * The adjustment layers' colour at timeline t: for each adjust item on screen (tracks in order, lower first), its
 * matrix mixed with the identity by its strength, multiplied together (the upper applied last). Null when none is on
 * screen or the result is the identity.
 *
 * Drawing order (every engine): text and captions are always drawn above video and image tracks; adjustment layers
 * apply after the pictures, before text. The composed matrix is not clamped between layers, only at the end.
 */
export function adjustLayerMatrix(p: EditProject, t: number, presets: FilterPreset[]): number[] | null {
  let m: M = ID, any = false;
  for (const tr of p.tracks) {
    if (tr.kind !== 'adjust' || tr.hidden) continue;
    for (const it of tr.items as AdjustItem[]) {
      if (t < it.startSec - 1e-9 || t >= it.startSec + it.durationSec - 1e-9) continue;
      const local = t - it.startSec;
      const s = clamp(propAt(it, 'opacity', it.opacity ?? 1, local), 0, 1);
      const c = colorMatrix(adjustAt(it, local), it.filter, presets);
      m = mul(c.map((v, i) => ID[i]! + s * (v - ID[i]!)), m);
      any = true;
    }
  }
  if (!any) return null;
  const out = m.map(r6);
  return out.every((v, i) => Math.abs(v - ID[i]!) < 1e-9) ? null : out;
}

/** One 3×4 affine RGB matrix for the item's look (exposure → temperature → green/magenta tint → contrast → saturation → preset tint). */
export function colorMatrix(adjust: Adjust | undefined, filter: FilterRef | undefined, presets: FilterPreset[]): number[] {
  const { adjust: a, tint } = effectiveAdjust(adjust, filter, presets);
  let m = ID;
  const ex = Math.pow(2, a.exposure);
  m = mul([ex, 0, 0, 0, 0, ex, 0, 0, 0, 0, ex, 0], m);
  m = mul([1 + 0.1 * a.temperature, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 - 0.1 * a.temperature, 0], m);
  const g = clamp(adjust?.tint ?? 0, -1, 1);
  if (g !== 0) m = mul([1 + 0.05 * g, 0, 0, 0, 0, 1 - 0.1 * g, 0, 0, 0, 0, 1 + 0.05 * g, 0], m);
  const c = 1 + a.contrast, off = 0.5 * (1 - c);
  m = mul([c, 0, 0, off, 0, c, 0, off, 0, 0, c, off], m);
  const s = 1 + a.saturation;
  const sat: M = [];
  for (let i = 0; i < 3; i++) { for (let j = 0; j < 3; j++) sat.push((1 - s) * LUMA[j]! + (i === j ? s : 0)); sat.push(0); }
  m = mul(sat, m);
  if (tint && tint.strength > 0) {
    const [tr, tg, tb] = hexRgb(tint.color), k = clamp(tint.strength, 0, 1);
    m = mul([1 - k, 0, 0, tr * k, 0, 1 - k, 0, tg * k, 0, 0, 1 - k, tb * k], m);
  }
  return m.map(r6);
}

/**
 * The chroma key on 0–1 RGB → [r, g, b, alpha] (not premultiplied). d = distance between the pixel's and the key's
 * (Cb, Cr) (BT.601); base = d − similarity; alpha = clamp(base / smoothness)^1.5; spill s = clamp(base / spill)^1.5 and
 * colour = luma(709) + (colour − luma)·s, so pixels near the key lose its tint.
 */
export function chromaKey(r: number, g: number, b: number, key: Chroma): [number, number, number, number] {
  const cbcr = (r: number, g: number, b: number) => [-0.168736 * r - 0.331264 * g + 0.5 * b, 0.5 * r - 0.418688 * g - 0.081312 * b] as const;
  const [kr, kg, kb] = hexRgb(key.color);
  const [cb, cr] = cbcr(r, g, b), [kcb, kcr] = cbcr(kr, kg, kb);
  const base = Math.hypot(cb - kcb, cr - kcr) - (key.similarity ?? 0.4);
  const alpha = Math.pow(clamp(base / Math.max(key.smoothness ?? 0.08, 1e-4), 0, 1), 1.5);
  const s = Math.pow(clamp(base / Math.max(key.spill ?? 0.5, 1e-4), 0, 1), 1.5);
  const l = LUMA[0]! * r + LUMA[1]! * g + LUMA[2]! * b;
  return [r6(l + (r - l) * s), r6(l + (g - l) * s), r6(l + (b - l) * s), r6(alpha)];
}

// ------------------------------------------------------------------ audio
export type GainPoint = { t: number; gain: number };
/** Timeline ranges where speech/voice is heard, for ducking. */
export function duckRegions(p: EditProject, duck: Duck): Range[] {
  const rs: Range[] = [];
  if (duck.under.includes('voice')) {
    for (const t of p.tracks) if (t.kind === 'voice' && !t.muted) for (const it of t.items) { const s = itemSpan(p, t, it); rs.push({ startSec: s.startSec, endSec: s.endSec }); }
  }
  if (duck.under.includes('speech')) for (const w of captionWords(p)) rs.push({ startSec: w.startSec, endSec: w.endSec });
  return mergeRanges(rs, SPEECH_JOIN_SEC);
}

/** Base gain of a clip at timeline t, without ducking (volume, keyframes, fades, transition crossfade). */
function baseGain(p: EditProject, track: Track, item: VideoClip | AudioClip, t: number): number {
  if (p.mute || track.muted || item.muted || ('holdSec' in item && item.holdSec !== undefined)) return 0; // a hold is silent
  const span = itemSpan(p, track, item);
  if (t < span.startSec - 1e-9 || t > span.endSec + 1e-9) return 0;
  const local = t - span.startSec, len = span.endSec - span.startSec;
  let g = (track.volume ?? 1) * propAt(item, 'volume', item.volume ?? 1, local);
  if (item.fadeInSec && item.fadeInSec > 0) g *= clamp(local / item.fadeInSec, 0, 1);
  if (item.fadeOutSec && item.fadeOutSec > 0) g *= clamp((len - local) / item.fadeOutSec, 0, 1);
  if (track.kind === 'main') {
    const spans = timeline(p);
    const i = spans.findIndex(s => s.id === item.id);
    const me = spans[i]!, next = spans[i + 1];
    if (me.transitionSec > 0) g *= clamp(local / me.transitionSec, 0, 1);
    if (next && next.transitionSec > 0) g *= clamp((me.endSec - t) / next.transitionSec, 0, 1);
  }
  return g;
}

/** Ramp down (attack, before speech) and back up (release, after it): attackSec/releaseSec, else fadeSec for both. */
export const duckTimes = (d: Duck): [number, number] => {
  const f = d.fadeSec ?? 0.25;
  return [Math.max(0.05, d.attackSec ?? f), Math.max(0.05, d.releaseSec ?? f)];
};
/** Ducking multiplier at t for a music track with `duck`. */
function duckGain(regions: Range[], duck: Duck, t: number): number {
  const level = clamp(duck.level ?? 0.3, 0.05, 1), [att, rel] = duckTimes(duck);
  let m = 1;
  for (const r of regions) {
    let d: number;
    if (t >= r.startSec && t <= r.endSec) d = 1;
    else if (t < r.startSec) d = clamp(1 - (r.startSec - t) / att, 0, 1);
    else d = clamp(1 - (t - r.endSec) / rel, 0, 1);
    m = Math.min(m, 1 - (1 - level) * d);
  }
  return m;
}

/**
 * A clip's gain over the timeline as piecewise-linear points (t ascending, timeline seconds, from the clip's start to
 * its end). Points are placed at every corner (fades, transitions, keyframes, duck ramps), so linear interpolation
 * between them is exact except inside eased keyframes, which are sampled every 0.1 s.
 */
export function audioEnvelope(p: EditProject, trackId: string, itemId: string): GainPoint[] {
  const track = p.tracks.find(t => t.id === trackId);
  const item = track?.items.find(i => i.id === itemId) as VideoClip | AudioClip | undefined;
  if (!track || !item) return [];
  const span = itemSpan(p, track, item);
  const end = Math.min(span.endSec, durationSec(p));
  if (end <= span.startSec) return [];
  const ts = new Set<number>([span.startSec, end]);
  const add = (t: number) => { if (t > span.startSec && t < end) ts.add(r6(t)); };
  if (item.fadeInSec) add(span.startSec + item.fadeInSec);
  if (item.fadeOutSec) add(span.endSec - item.fadeOutSec);
  if (track.kind === 'main') {
    const spans = timeline(p), i = spans.findIndex(s => s.id === item.id), me = spans[i]!, next = spans[i + 1];
    if (me.transitionSec) add(me.startSec + me.transitionSec);
    if (next?.transitionSec) add(next.startSec);
  }
  const kv = item.keyframes?.volume ?? [];
  kv.forEach((k, idx) => {
    add(span.startSec + k.t);
    const nk = kv[idx + 1];
    if (nk && k.ease && k.ease !== 'linear') {
      if (k.ease === 'hold') add(span.startSec + nk.t - 1e-4);
      else for (let s = k.t + 0.1; s < nk.t - 1e-9; s += 0.1) add(span.startSec + s);
    }
  });
  let regions: Range[] = [];
  if (track.kind === 'music' && track.duck) {
    regions = duckRegions(p, track.duck);
    const [att, rel] = duckTimes(track.duck);
    for (const r of regions) { add(r.startSec - att); add(r.startSec); add(r.endSec); add(r.endSec + rel); }
  }
  return [...ts].sort((a, b) => a - b).map(t => {
    let g = baseGain(p, track, item, t);
    if (regions.length && track.duck) g *= duckGain(regions, track.duck, t);
    return { t: r6(t), gain: r6(g) };
  });
}

// ------------------------------------------------------------------ validation
export class EditProblem extends Error { constructor(public field: string, message: string) { super(`${field}: ${message}`); } }
const HEX = /^#[0-9A-Fa-f]{6}$/;
const isNum = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

/** All the rules of plans/video-editor.md "Rules". Throws EditProblem (field path + message) on the first one broken. */
export function validate(p: EditProject, presets: FilterPreset[] = [], lookIds: Set<string> = new Set(), paletteIds: Set<string> = new Set()): { durationSec: number } {
  const bad = (f: string, m: string): never => { throw new EditProblem(f, m); };
  const num = (f: string, v: unknown, lo: number, hi: number, optional = true) => {
    if (v === undefined && optional) return;
    if (!isNum(v) || v < lo || v > hi) bad(f, `must be a number from ${lo} to ${hi}`);
  };
  const color = (f: string, v: unknown, optional = true) => { if (v === undefined && optional) return; if (typeof v !== 'string' || !HEX.test(v)) bad(f, 'must be a colour like #FF0000'); };
  const id = (f: string, v: unknown) => { if (typeof v !== 'string' || v.length < 1 || v.length > 64) bad(f, 'must be an id of 1–64 characters'); };
  if (!p || typeof p !== 'object') bad('edits', 'must be an object');
  if (p.version !== 2) bad('edits.version', 'must be 2');
  if (typeof p.sourceTakeId !== 'string' || !p.sourceTakeId) bad('edits.sourceTakeId', 'is required');
  const cv = p.canvas;
  if (!cv || typeof cv !== 'object') bad('edits.canvas', 'is required');
  num('edits.canvas.width', cv.width, 16, 4096, false); num('edits.canvas.height', cv.height, 16, 4096, false); num('edits.canvas.fps', cv.fps, 1, 120, false);
  color('edits.canvas.background', cv.background);
  if (cv.fill !== undefined && cv.fill !== 'color' && cv.fill !== 'blur') bad('edits.canvas.fill', 'must be color or blur');
  if (!Array.isArray(p.assets) || p.assets.length > LIMITS.maxAssets) bad('edits.assets', `must be a list of at most ${LIMITS.maxAssets}`);
  const assets = new Map<string, Asset>();
  p.assets.forEach((a, i) => {
    const f = `edits.assets.${i}`;
    id(`${f}.id`, a.id);
    if (assets.has(a.id)) bad(`${f}.id`, 'is used twice');
    if (!['video', 'image', 'audio', 'lut', 'font'].includes(a.kind)) bad(`${f}.kind`, 'must be video, image, audio, lut or font');
    if (a.kind === 'lut' && a.upload === undefined) bad(f, 'a lut asset must be an upload');
    if (a.kind === 'font') {
      if (a.upload === undefined) bad(f, 'a font asset must be an upload');
      for (const k of ['durationSec', 'width', 'height', 'hasAudio'] as const) if (a[k] !== undefined) bad(`${f}.${k}`, 'is not part of a font asset');
    }
    if (a.name !== undefined && (typeof a.name !== 'string' || !a.name.trim() || a.name.length > 80)) bad(`${f}.name`, 'must be 1–80 characters');
    const refs = [a.take, a.upload, a.library].filter(x => x !== undefined);
    if (refs.length !== 1 || refs.some(r => typeof r !== 'string' || !r || r.length > 100)) bad(f, 'needs exactly one of take, upload or library');
    // The content library (catalog items): `content:<pack>/<item>`, for stickers (image) and sound effects (audio).
    if (typeof a.library === 'string' && a.library.startsWith('content:') && (!CONTENT_REF.test(a.library) || (a.kind !== 'image' && a.kind !== 'audio'))) bad(`${f}.library`, 'unknown content');
    num(`${f}.durationSec`, a.durationSec, 0.01, 36_000);
    num(`${f}.width`, a.width, 1, 16384); num(`${f}.height`, a.height, 1, 16384);
    assets.set(a.id, a);
  });
  // Helper copies: a reversed copy of a video (not of another reversed copy: switching back un-reverses), or a derived
  // copy (stabilize/smooth) of a video not made with the same step; at most one of the two, chains of up to 4, no cycles.
  p.assets.forEach((a, i) => {
    const f = `edits.assets.${i}`;
    if (a.reverseOf !== undefined && a.derivedFrom !== undefined) bad(f, 'is either a reversed or a derived copy');
    if (a.reverseOf !== undefined) {
      const o = typeof a.reverseOf === 'string' ? assets.get(a.reverseOf) : undefined;
      if (a.kind !== 'video' || !o || o.kind !== 'video' || o.reverseOf !== undefined || o.id === a.id) bad(`${f}.reverseOf`, 'must be a video asset');
    }
    if (a.derivedFrom !== undefined) {
      const d = a.derivedFrom;
      if (!d || typeof d !== 'object' || !DERIVED_OPS.includes(d.op)) bad(`${f}.derivedFrom.op`, 'must be stabilize or slowmo');
      const o = typeof d.asset === 'string' ? assets.get(d.asset) : undefined;
      if (a.kind !== 'video' || !o || o.kind !== 'video' || o.id === a.id || o.derivedFrom?.op === d.op) bad(`${f}.derivedFrom.asset`, 'must be a video asset');
      const r = d as { startSec?: unknown; endSec?: unknown; factor?: unknown };
      if (d.op === 'stabilize') {
        for (const k of ['startSec', 'endSec', 'factor'] as const) if (r[k] !== undefined) bad(`${f}.derivedFrom.${k}`, 'is not part of a steadied copy');
      } else {
        if (!(SLOWMO.factors as readonly unknown[]).includes(r.factor)) bad(`${f}.derivedFrom.factor`, 'must be 2 or 4');
        num(`${f}.derivedFrom.startSec`, r.startSec as number, 0, 36_000, false);
        num(`${f}.derivedFrom.endSec`, r.endSec as number, 0, 36_000, false);
        const len = (r.endSec as number) - (r.startSec as number);
        if (len < SLOWMO.minRangeSec - 1e-9 || len > SLOWMO.maxRangeSec + 1e-9) bad(`${f}.derivedFrom.endSec`, `the range must be ${SLOWMO.minRangeSec}–${SLOWMO.maxRangeSec} s`);
        if (o?.durationSec !== undefined && (r.endSec as number) > o.durationSec + 0.01) bad(`${f}.derivedFrom.endSec`, 'is past the end of the video');
      }
    }
    let id: string | undefined = a.id;
    for (let n = 0; id !== undefined; n++) {
      if (n > 4) bad(f, 'too many helper copies in a row');
      const x = assets.get(id);
      id = x?.derivedFrom?.asset ?? x?.reverseOf;
    }
  });
  if (!Array.isArray(p.tracks) || p.tracks.length < 1 || p.tracks.length > LIMITS.maxTracks) bad('edits.tracks', `must have 1–${LIMITS.maxTracks} tracks`);
  if (p.tracks[0]!.kind !== 'main') bad('edits.tracks.0.kind', 'the first track must be the main track');
  if (p.tracks.filter(t => t.kind === 'main').length !== 1) bad('edits.tracks', 'needs exactly one main track');
  if (p.tracks.filter(t => t.kind === 'caption').length > 1) bad('edits.tracks', 'at most one caption track');
  const ids = new Set<string>();
  const assetKinds = new Map([...assets.values()].map(a => [a.id, a.kind as string]));
  let total = 0;
  const filterIds = new Set(presets.map(x => x.id));

  const kfs = (f: string, k: Keyframes | undefined, len: number, allowed: KfProp[], hasMask = false) => {
    if (k === undefined) return;
    if (typeof k !== 'object' || k === null) bad(f, 'must be an object');
    for (const [prop, list] of Object.entries(k)) {
      if (!allowed.includes(prop as KfProp)) bad(`${f}.${prop}`, 'is not a keyframe property here');
      if ((MASK_KF_PROPS as string[]).includes(prop) && !hasMask) bad(`${f}.${prop}`, 'needs a mask');
      if (!Array.isArray(list) || list.length > LIMITS.maxKeyframes) bad(`${f}.${prop}`, `at most ${LIMITS.maxKeyframes} keyframes`);
      let prev = -Infinity;
      (list as Keyframe[]).forEach((kf, j) => {
        const g = `${f}.${prop}.${j}`;
        num(`${g}.t`, kf.t, 0, len + LIMITS.endSlackSec, false);
        if (kf.t < prev) bad(`${g}.t`, 'keyframes must be in time order');
        prev = kf.t;
        const range: Record<KfProp, [number, number]> = { x: [-2, 3], y: [-2, 3], scale: [0.05, 10], rotation: [-3600, 3600], opacity: [0, 1], volume: [0, 2],
          exposure: [-1, 1], contrast: [-1, 1], saturation: [-1, 1], temperature: [-1, 1], tint: [-1, 1],
          maskX: [-1, 2], maskY: [-1, 2], maskWidth: [0.01, 3], maskHeight: [0.01, 3], maskRotation: [-360, 360], maskFeather: [0, 1],
          vignette: [-1, 1], grain: [0, 1], leak: [0, 1] };
        num(`${g}.v`, kf.v, range[prop as KfProp][0], range[prop as KfProp][1], false);
        if (kf.ease !== undefined && !['linear', 'easeIn', 'easeOut', 'easeInOut', 'hold'].includes(kf.ease)) bad(`${g}.ease`, 'unknown ease');
      });
    }
  };
  const visual = (f: string, it: Visual, len: number) => {
    if (it.fit !== undefined && it.fit !== 'cover' && it.fit !== 'contain') bad(`${f}.fit`, 'must be cover or contain');
    if (it.transform !== undefined) {
      num(`${f}.transform.x`, it.transform.x, -2, 3); num(`${f}.transform.y`, it.transform.y, -2, 3);
      num(`${f}.transform.scale`, it.transform.scale, 0.05, 10); num(`${f}.transform.rotation`, it.transform.rotation, -3600, 3600);
      flips(`${f}.transform`, it.transform);
    }
    if (it.crop !== undefined) for (const s of ['left', 'top', 'right', 'bottom'] as const) num(`${f}.crop.${s}`, it.crop[s], 0, 0.45);
    num(`${f}.opacity`, it.opacity, 0, 1);
    if (it.adjust !== undefined) for (const s of ['exposure', 'contrast', 'saturation', 'temperature', 'tint', 'highlights', 'shadows'] as const) num(`${f}.adjust.${s}`, it.adjust[s], -1, 1);
    if (it.mask !== undefined) {
      if (!it.mask || !MASK_SHAPES.includes(it.mask.shape)) bad(`${f}.mask.shape`, `one of ${MASK_SHAPES.join(', ')}`);
      num(`${f}.mask.x`, it.mask.x, -1, 2); num(`${f}.mask.y`, it.mask.y, -1, 2); num(`${f}.mask.width`, it.mask.width, 0.01, 3); num(`${f}.mask.height`, it.mask.height, 0.01, 3);
      num(`${f}.mask.rotation`, it.mask.rotation, -360, 360); num(`${f}.mask.feather`, it.mask.feather, 0, 1);
      if (it.mask.invert !== undefined && typeof it.mask.invert !== 'boolean') bad(`${f}.mask.invert`, 'must be true or false');
    }
    if (it.filter !== undefined) {
      if (typeof it.filter.id !== 'string' || (filterIds.size && !filterIds.has(it.filter.id))) bad(`${f}.filter.id`, 'unknown filter');
      num(`${f}.filter.amount`, it.filter.amount, 0, 1, false);
    }
    const lp = lookProblem(it.look, assetKinds, lookIds, paletteIds);
    if (lp) bad(lp.field ? `${f}.look.${lp.field}` : `${f}.look`, lp.message);
  };
  const flips = (f: string, t: Transform) => {
    if (t.flipX !== undefined && typeof t.flipX !== 'boolean') bad(`${f}.flipX`, 'must be true or false');
    if (t.flipY !== undefined && typeof t.flipY !== 'boolean') bad(`${f}.flipY`, 'must be true or false');
  };
  const blend = (f: string, b: BlendMode | undefined, overlay: boolean) => {
    if (b === undefined) return;
    if (!BLEND_MODES.includes(b)) bad(`${f}.blend`, `one of ${BLEND_MODES.join(', ')}`);
    if (!overlay) bad(`${f}.blend`, 'only on overlay tracks (video, image)');
  };
  const loop = (f: string, l: AnimLoop | undefined) => {
    if (l === undefined) return;
    if (!l || typeof l !== 'object' || !LOOP_KINDS.includes(l.kind)) bad(`${f}.kind`, 'unknown loop animation');
    num(`${f}.periodSec`, l.periodSec, 0.2, 5, false); num(`${f}.amount`, l.amount, 0, 1);
  };
  const anim = (f: string, a: Anim | undefined, text: boolean) => {
    if (a === undefined) return;
    if (!ANIMS.includes(a.kind) || (a.kind === 'typewriter' && !text)) bad(`${f}.kind`, 'unknown animation');
    num(`${f}.durationSec`, a.durationSec, 0.1, 2, false);
  };
  const clipBase = (f: string, c: VideoClip | AudioClip, kinds: Asset['kind'][]) => {
    const a = assets.get(c.asset);
    if (!a) bad(`${f}.asset`, 'is not in assets');
    if (!kinds.includes(a!.kind)) bad(`${f}.asset`, `must be ${kinds.join(' or ')}`);
    num(`${f}.inSec`, c.inSec, 0, 36_000, false); num(`${f}.outSec`, c.outSec, 0, 36_000, false);
    if (c.outSec - c.inSec < LIMITS.minClipSourceSec - 1e-9) bad(`${f}.outSec`, `a clip must keep at least ${LIMITS.minClipSourceSec} s of its source`);
    if (a!.durationSec != null && c.outSec > a!.durationSec + LIMITS.endSlackSec) bad(`${f}.outSec`, 'is past the end of its source');
    num(`${f}.volume`, c.volume, 0, 2); num(`${f}.fadeInSec`, c.fadeInSec, 0, 10); num(`${f}.fadeOutSec`, c.fadeOutSec, 0, 10);
    if (c.muted !== undefined && typeof c.muted !== 'boolean') bad(`${f}.muted`, 'must be true or false');
    if (c.voiceEffect !== undefined && !VOICE_EFFECTS.includes(c.voiceEffect)) bad(`${f}.voiceEffect`, `one of ${VOICE_EFFECTS.join(', ')}`);
    if (c.enhance !== undefined && typeof c.enhance !== 'boolean') bad(`${f}.enhance`, 'must be true or false');
  };

  p.tracks.forEach((t, ti) => {
    const f = `edits.tracks.${ti}`;
    id(`${f}.id`, t.id);
    if (ids.has(t.id)) bad(`${f}.id`, 'is used twice');
    ids.add(t.id);
    if (!['main', 'video', 'image', 'text', 'caption', 'music', 'voice', 'sfx', 'adjust'].includes(t.kind)) bad(`${f}.kind`, 'unknown track kind');
    num(`${f}.volume`, t.volume, 0, 2);
    if (!Array.isArray(t.items) || t.items.length > LIMITS.maxItemsPerTrack) bad(`${f}.items`, `at most ${LIMITS.maxItemsPerTrack} items`);
    total += t.items.length;
    if (total > LIMITS.maxItems) bad(`${f}.items`, `at most ${LIMITS.maxItems} items in all`);
    if (t.kind === 'main' && t.items.length < 1) bad(`${f}.items`, 'the main track needs at least one clip');
    if (t.kind === 'caption') {
      if (t.items.length) bad(`${f}.items`, 'a caption track has no items');
      const c = t.caption;
      if (!c) bad(`${f}.caption`, 'is required');
      const a = assets.get(c!.asset);
      if (!a || (a.kind !== 'video' && a.kind !== 'audio')) bad(`${f}.caption.asset`, 'must be a video or audio asset');
      if (!Array.isArray(c!.words) || c!.words.length > LIMITS.maxWords) bad(`${f}.caption.words`, `at most ${LIMITS.maxWords} words`);
      const words = (ws: CaptionWord[], g: string) => ws.forEach((w, j) => {
        if (typeof w.text !== 'string' || w.text.length < 1 || w.text.length > 60) bad(`${g}.${j}.text`, 'must be 1–60 characters');
        num(`${g}.${j}.startSec`, w.startSec, 0, 36_000, false);
        num(`${g}.${j}.endSec`, w.endSec, w.startSec, 36_000, false);
      });
      words(c!.words, `${f}.caption.words`);
      if (c!.language !== undefined && (typeof c!.language !== 'string' || !LANGUAGE_CODE.test(c!.language))) bad(`${f}.caption.language`, 'must be a language code');
      if (c!.original !== undefined) {
        const o = c!.original;
        if (!o || typeof o !== 'object' || !Array.isArray(o.words) || o.words.length > LIMITS.maxWords) bad(`${f}.caption.original.words`, `at most ${LIMITS.maxWords} words`);
        words(o.words, `${f}.caption.original.words`);
        if (o.language !== undefined && (typeof o.language !== 'string' || !LANGUAGE_CODE.test(o.language))) bad(`${f}.caption.original.language`, 'must be a language code');
      }
      textStyle(`${f}.caption.style`, c!.style, false);
      if (!CAPTION_PRESETS.includes(c!.style.preset)) bad(`${f}.caption.style.preset`, 'unknown preset');
      color(`${f}.caption.style.highlightColor`, c!.style.highlightColor, false);
      num(`${f}.caption.style.y`, c!.style.y, 0, 1); num(`${f}.caption.style.wordsPerPage`, c!.style.wordsPerPage, 1, 8); num(`${f}.caption.style.maxLines`, c!.style.maxLines, 1, 2);
    } else if (t.caption !== undefined) bad(`${f}.caption`, 'only on a caption track');
    if (t.duck !== undefined) {
      if (t.kind !== 'music') bad(`${f}.duck`, 'only on a music track');
      num(`${f}.duck.level`, t.duck.level, 0.05, 1); num(`${f}.duck.fadeSec`, t.duck.fadeSec, 0.05, 2);
      num(`${f}.duck.attackSec`, t.duck.attackSec, 0.05, 2); num(`${f}.duck.releaseSec`, t.duck.releaseSec, 0.05, 3);
      if (!Array.isArray(t.duck.under) || !t.duck.under.length || t.duck.under.some(u => u !== 'voice' && u !== 'speech')) bad(`${f}.duck.under`, 'must list voice and/or speech');
    }
    let prevEnd = -Infinity;
    t.items.forEach((it, ii) => {
      const g = `${f}.items.${ii}`;
      id(`${g}.id`, it.id);
      if (ids.has(it.id)) bad(`${g}.id`, 'is used twice');
      ids.add(it.id);
      if (t.kind === 'main' || t.kind === 'video') {
        const c = it as VideoClip;
        clipBase(g, c, ['video']);
        num(`${g}.speed`, c.speed, LIMITS.minSpeed, LIMITS.maxSpeed, false);
        if (c.holdSec !== undefined) {
          num(`${g}.holdSec`, c.holdSec, HOLD_MIN_SEC, HOLD_MAX_SEC, false);
          if (c.speed !== 1 || c.speedCurve !== undefined) bad(`${g}.holdSec`, 'a freeze frame plays at 1× without a speed curve');
        }
        blend(g, c.blend, t.kind === 'video');
        if (c.speedCurve !== undefined) {
          const sc = c.speedCurve;
          if (!sc || !['montage', 'hero', 'bullet', 'flashIn', 'flashOut', 'custom'].includes(sc.preset)) bad(`${g}.speedCurve.preset`, 'unknown preset');
          if (!Array.isArray(sc.points) || sc.points.length < 2 || sc.points.length > 16) bad(`${g}.speedCurve.points`, '2–16 points');
          sc.points.forEach((pt, j) => {
            if (!Array.isArray(pt) || pt.length !== 2 || !isNum(pt[0]) || !isNum(pt[1]) || pt[0] < 0 || pt[0] > 1 || pt[1] < LIMITS.minSpeed || pt[1] > LIMITS.maxSpeed)
              bad(`${g}.speedCurve.points.${j}`, `must be [x 0–1, speed ${LIMITS.minSpeed}–${LIMITS.maxSpeed}]`);
            if (j > 0 && pt[0] <= sc.points[j - 1]![0]) bad(`${g}.speedCurve.points.${j}`, 'x must increase');
          });
          if (sc.points[0]![0] !== 0 || sc.points[sc.points.length - 1]![0] !== 1) bad(`${g}.speedCurve.points`, 'must start at x 0 and end at x 1');
        }
        visual(g, c, clipLength(c));
        kfs(`${g}.keyframes`, c.keyframes, clipLength(c), ['x', 'y', 'scale', 'rotation', 'opacity', 'volume', ...COLOR_KF_PROPS, ...MASK_KF_PROPS, ...LOOK_KF_PROPS], !!c.mask);
        if (c.audioAsset !== undefined) { const a = assets.get(c.audioAsset); if (!a || (a.kind !== 'video' && a.kind !== 'audio')) bad(`${g}.audioAsset`, 'must be an audio or video asset'); }
        if (c.alphaMatte !== undefined) {
          const m = c.alphaMatte as AlphaMatte;
          if (!m || typeof m !== 'object' || typeof m.asset !== 'string') bad(`${g}.alphaMatte`, 'must be {asset, invert?}');
          else {
            const a = assets.get(m.asset);
            if (!a || a.kind !== 'video') bad(`${g}.alphaMatte.asset`, 'must be a video asset');
            if (m.invert !== undefined && typeof m.invert !== 'boolean') bad(`${g}.alphaMatte.invert`, 'true or false');
          }
        }
        anim(`${g}.animIn`, c.animIn, false); anim(`${g}.animOut`, c.animOut, false);
        if (c.animLoop !== undefined && t.kind === 'main') bad(`${g}.animLoop`, 'loop animations are for overlays, images and text');
        loop(`${g}.animLoop`, c.animLoop);
        if (c.chroma !== undefined) {
          color(`${g}.chroma.color`, c.chroma.color, false);
          num(`${g}.chroma.similarity`, c.chroma.similarity, 0, 1); num(`${g}.chroma.smoothness`, c.chroma.smoothness, 0, 1); num(`${g}.chroma.spill`, c.chroma.spill, 0, 1);
        }
        if (t.kind === 'main') {
          if (c.startSec !== undefined) bad(`${g}.startSec`, 'main clips play back to back (no startSec)');
          if (c.transitionIn !== undefined) {
            if (ii === 0) bad(`${g}.transitionIn`, 'the first clip has no transition');
            if (!TRANSITIONS.includes(c.transitionIn.kind)) bad(`${g}.transitionIn.kind`, 'unknown transition');
            num(`${g}.transitionIn.durationSec`, c.transitionIn.durationSec, LIMITS.minTransitionSec, LIMITS.maxTransitionSec, false);
            const prev = t.items[ii - 1] as VideoClip;
            if (c.transitionIn.durationSec > clipLength(c) / 2 + 1e-9 || c.transitionIn.durationSec > clipLength(prev) / 2 + 1e-9)
              bad(`${g}.transitionIn.durationSec`, 'at most half of each clip');
          }
        } else {
          if (c.transitionIn !== undefined) bad(`${g}.transitionIn`, 'transitions are on the main track only');
          num(`${g}.startSec`, c.startSec, 0, 600, false);
        }
      } else if (t.kind === 'image') {
        const im = it as ImageItem;
        const a = assets.get(im.asset);
        if (!a) bad(`${g}.asset`, 'is not in assets');
        if (a!.kind !== 'image') bad(`${g}.asset`, 'must be image');
        num(`${g}.startSec`, im.startSec, 0, 600, false); num(`${g}.durationSec`, im.durationSec, LIMITS.minItemSec, 600, false);
        visual(g, im, im.durationSec);
        blend(g, im.blend, true);
        kfs(`${g}.keyframes`, im.keyframes, im.durationSec, ['x', 'y', 'scale', 'rotation', 'opacity', ...COLOR_KF_PROPS, ...MASK_KF_PROPS, ...LOOK_KF_PROPS], !!im.mask);
        anim(`${g}.animIn`, im.animIn, false); anim(`${g}.animOut`, im.animOut, false); loop(`${g}.animLoop`, im.animLoop);
      } else if (t.kind === 'text') {
        const tx = it as TextItem;
        if (typeof tx.text !== 'string' || tx.text.length < 1 || tx.text.length > LIMITS.maxText) bad(`${g}.text`, `must be 1–${LIMITS.maxText} characters`);
        num(`${g}.startSec`, tx.startSec, 0, 600, false); num(`${g}.durationSec`, tx.durationSec, LIMITS.minItemSec, 600, false);
        textStyle(`${g}.style`, tx.style, true);
        if (tx.transform !== undefined) visual(g, { transform: tx.transform }, tx.durationSec);
        num(`${g}.opacity`, tx.opacity, 0, 1);
        kfs(`${g}.keyframes`, tx.keyframes, tx.durationSec, ['x', 'y', 'scale', 'rotation', 'opacity']);
        anim(`${g}.animIn`, tx.animIn, true); anim(`${g}.animOut`, tx.animOut, true); loop(`${g}.animLoop`, tx.animLoop);
      } else if (t.kind === 'adjust') {
        const ad = it as AdjustItem & Record<string, unknown>;
        for (const k of ['look', 'mask', 'transform', 'crop', 'fit', 'asset'] as const) if (ad[k] !== undefined) bad(`${g}.${k}`, 'is not part of an adjustment layer');
        num(`${g}.startSec`, ad.startSec, 0, 600, false); num(`${g}.durationSec`, ad.durationSec, LIMITS.minItemSec, 600, false);
        for (const k of ['highlights', 'shadows'] as const) if (ad.adjust?.[k] !== undefined) bad(`${g}.adjust.${k}`, 'is not part of an adjustment layer');
        visual(g, { adjust: ad.adjust, filter: ad.filter, opacity: ad.opacity }, ad.durationSec);
        kfs(`${g}.keyframes`, ad.keyframes, ad.durationSec, ['opacity', ...COLOR_KF_PROPS]);
      } else if (t.kind === 'music' || t.kind === 'voice' || t.kind === 'sfx') {
        const c = it as AudioClip;
        clipBase(g, c, ['audio', 'video']);
        num(`${g}.startSec`, c.startSec, 0, 600, false);
        // Audio speed (M): 0.5–2×, pitch kept (time stretch); timeline length = (outSec − inSec) / speed.
        num(`${g}.speed`, c.speed, 0.5, 2);
        kfs(`${g}.keyframes`, c.keyframes, clipLength(c), ['volume']);
        for (const k of ['beats', 'strongBeats'] as const) { const bs = c[k]; if (bs !== undefined && (!Array.isArray(bs) || bs.length > 2000 || bs.some(b => !isNum(b) || b < 0))) bad(`${g}.${k}`, 'must be up to 2000 times'); }
      }
      if (t.kind !== 'main') {
        const s = (it as { startSec: number }).startSec;
        if (s < prevEnd - LIMITS.overlapSlackSec) bad(`${g}.startSec`, 'items on a track must be in order and not overlap');
        const span = itemSpan(p, t, it);
        prevEnd = span.endSec;
      }
    });
  });
  function textStyle(f: string, s: TextStyle, ownFont: boolean) {
    if (!s || typeof s !== 'object') bad(f, 'is required');
    if (s.fontAsset !== undefined) {
      if (!ownFont) bad(`${f}.fontAsset`, 'captions use the built-in fonts');
      if (typeof s.fontAsset !== 'string' || assets.get(s.fontAsset)?.kind !== 'font') bad(`${f}.fontAsset`, 'must be a font asset');
    }
    if (!FONTS.includes(s.font)) bad(`${f}.font`, 'unknown font');
    if (![400, 700, 900].includes(s.weight)) bad(`${f}.weight`, 'must be 400, 700 or 900');
    num(`${f}.sizePct`, s.sizePct, 0.015, 0.25, false);
    color(`${f}.color`, s.color, false);
    if (!['left', 'center', 'right'].includes(s.align)) bad(`${f}.align`, 'must be left, center or right');
    num(`${f}.maxWidthPct`, s.maxWidthPct, 0.1, 1); num(`${f}.lineHeight`, s.lineHeight, 0.8, 2); num(`${f}.letterSpacing`, s.letterSpacing, -0.1, 0.5);
    if (s.stroke !== undefined) { color(`${f}.stroke.color`, s.stroke.color, false); num(`${f}.stroke.widthPct`, s.stroke.widthPct, 0, 0.3, false); }
    if (s.shadow !== undefined) { color(`${f}.shadow.color`, s.shadow.color, false); num(`${f}.shadow.opacity`, s.shadow.opacity, 0, 1, false); num(`${f}.shadow.blurPct`, s.shadow.blurPct, 0, 1, false); num(`${f}.shadow.dyPct`, s.shadow.dyPct, -1, 1, false); }
    if (s.background !== undefined) { color(`${f}.background.color`, s.background.color, false); num(`${f}.background.opacity`, s.background.opacity, 0, 1, false); num(`${f}.background.paddingPct`, s.background.paddingPct, 0, 1, false); num(`${f}.background.radiusPct`, s.background.radiusPct, 0, 1, false); }
  }
  const d = durationSec(p);
  if (d < LIMITS.minOutputSec - 1e-9) bad('edits', `the edited video must be at least ${LIMITS.minOutputSec} s`);
  if (d > LIMITS.maxOutputSec + 1e-9) bad('edits', `the edited video must be at most ${LIMITS.maxOutputSec} s`);
  return { durationSec: d };
}
