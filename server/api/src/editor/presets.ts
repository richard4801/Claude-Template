// Editor v2 shared presets: filters, caption styles, hook-text templates (plans/video-editor.md "Editor v2").
// The apps carry the same tables (checked against test/fixtures/editor/presets.json, which this file generates).
import type { Anim, CaptionPreset, CaptionStyle, FilterPreset, TextStyle, Transform } from './model.js';

export const FILTERS: FilterPreset[] = [
  { id: 'none', label: 'Original', adjust: {} },
  { id: 'warm', label: 'Warm', adjust: { temperature: 0.6, saturation: 0.1 } },
  { id: 'cool', label: 'Cool', adjust: { temperature: -0.6, contrast: 0.05 } },
  { id: 'vivid', label: 'Vivid', adjust: { saturation: 0.35, contrast: 0.15 } },
  { id: 'mono', label: 'Mono', adjust: { saturation: -1, contrast: 0.1 } },
  { id: 'fade', label: 'Faded', adjust: { contrast: -0.25, saturation: -0.2, exposure: 0.05 } },
  { id: 'film', label: 'Film', adjust: { contrast: 0.1, saturation: -0.15, temperature: 0.2 }, tint: { color: '#F2C48D', strength: 0.08 } },
  { id: 'moody', label: 'Moody', adjust: { exposure: -0.2, contrast: 0.2, saturation: -0.3, temperature: -0.25 } },
  { id: 'golden', label: 'Golden hour', adjust: { exposure: 0.05, temperature: 0.8, saturation: 0.15 }, tint: { color: '#FFB347', strength: 0.1 } },
  { id: 'pastel', label: 'Pastel', adjust: { exposure: 0.15, contrast: -0.2, saturation: -0.1 }, tint: { color: '#FADADD', strength: 0.08 } },
  { id: 'noir', label: 'Noir', adjust: { saturation: -1, contrast: 0.45, exposure: -0.1 } },
  { id: 'punch', label: 'Punch', adjust: { contrast: 0.3, saturation: 0.25, exposure: 0.05 } },
];

const base = (o: Partial<TextStyle> = {}): TextStyle => ({ font: 'sans', weight: 900, sizePct: 0.045, color: '#FFFFFF', align: 'center', maxWidthPct: 0.85, lineHeight: 1.15, ...o });

/** Default style per caption preset (apps start a caption track from these). */
export const CAPTION_STYLES: Record<CaptionPreset, CaptionStyle> = {
  plain: { ...base({ weight: 700, sizePct: 0.035, shadow: { color: '#000000', opacity: 0.6, blurPct: 0.15, dyPct: 0.04 } }), preset: 'plain', highlightColor: '#FFFFFF', y: 0.8, wordsPerPage: 6, maxLines: 2 },
  highlight: { ...base({ stroke: { color: '#000000', widthPct: 0.12 } }), preset: 'highlight', highlightColor: '#FFE600', y: 0.72, wordsPerPage: 3, maxLines: 2 },
  box: { ...base({ weight: 700, sizePct: 0.042 }), preset: 'box', highlightColor: '#7C3AED', y: 0.72, wordsPerPage: 3, maxLines: 2 },
  karaoke: { ...base({ stroke: { color: '#000000', widthPct: 0.1 } }), preset: 'karaoke', highlightColor: '#22D3EE', y: 0.72, wordsPerPage: 4, maxLines: 2 },
  pop: { ...base({ sizePct: 0.05, uppercase: true, stroke: { color: '#000000', widthPct: 0.14 } }), preset: 'pop', highlightColor: '#FFE600', y: 0.7, wordsPerPage: 2, maxLines: 1 },
  single: { ...base({ sizePct: 0.065, uppercase: true, stroke: { color: '#000000', widthPct: 0.14 } }), preset: 'single', highlightColor: '#FFFFFF', y: 0.6, wordsPerPage: 1, maxLines: 1 },
  /** Active word gets a marker stripe (highlightColor, lower 45 % of the line) behind it. */
  highlighter: { ...base({ weight: 900, sizePct: 0.045, uppercase: true, color: '#FFFFFF', stroke: { color: '#000000', widthPct: 0.08 } }), preset: 'highlighter', highlightColor: '#22C55E', y: 0.72, wordsPerPage: 3, maxLines: 2 },
  /** Text glows in highlightColor (shadow blur, no offset); the active word is pure highlightColor. */
  neon: { ...base({ weight: 900, sizePct: 0.045, uppercase: true, color: '#FFD1E8', shadow: { color: '#FF2D87', opacity: 0.9, blurPct: 0.5, dyPct: 0 } }), preset: 'neon', highlightColor: '#FF2D87', y: 0.72, wordsPerPage: 3, maxLines: 2 },
};
/** The names the Edit suite shows (design E1/E3, EM2), in its order; `highlight` and `single` stay for older projects. */
export const CAPTION_STYLE_LABELS: [CaptionPreset, string][] = [['pop', 'Word pop'], ['karaoke', 'Karaoke'], ['box', 'Bold box'], ['plain', 'Minimal'], ['highlighter', 'Highlighter'], ['neon', 'Neon'], ['highlight', 'Highlight'], ['single', 'One word']];
/** Transition names in the Edit suite (design E2): Cut = no transition. */
export const TRANSITION_LABELS: [string, string][] = [['cut', 'Cut'], ['fade', 'X-fade'], ['zoom', 'Zoom'], ['whip', 'Whip'], ['slideLeft', 'Slide'], ['white', 'Flash'], ['glitch', 'Glitch'], ['spin', 'Spin'], ['black', 'Dip to black']];

export type HookTemplate = { id: string; label: string; text: string; durationSec: number; style: TextStyle; transform: Transform; animIn: Anim; animOut?: Anim };
/** Ready hook/text templates: choosing one copies style, position and animations into a TextItem (`template` = id). */
export const HOOKS: HookTemplate[] = [
  { id: 'hook-bold', label: 'Bold hook', text: 'Wait for it…', durationSec: 3, style: base({ sizePct: 0.06, stroke: { color: '#000000', widthPct: 0.14 } }), transform: { x: 0.5, y: 0.2 }, animIn: { kind: 'pop', durationSec: 0.35 } },
  { id: 'hook-box', label: 'Boxed', text: 'POV: you finally tried it', durationSec: 3, style: base({ weight: 700, sizePct: 0.04, color: '#111111', background: { color: '#FFFFFF', opacity: 1, paddingPct: 0.35, radiusPct: 0.25 } }), transform: { x: 0.5, y: 0.18 }, animIn: { kind: 'slideUp', durationSec: 0.3 } },
  { id: 'hook-question', label: 'Question', text: 'Would you try this?', durationSec: 3, style: base({ sizePct: 0.05, color: '#FFE600', stroke: { color: '#000000', widthPct: 0.12 } }), transform: { x: 0.5, y: 0.25 }, animIn: { kind: 'zoom', durationSec: 0.4 } },
  { id: 'hook-typewriter', label: 'Typewriter', text: 'Things nobody tells you about…', durationSec: 4, style: base({ font: 'mono', weight: 700, sizePct: 0.035, align: 'left', background: { color: '#000000', opacity: 0.6, paddingPct: 0.3, radiusPct: 0.1 } }), transform: { x: 0.5, y: 0.2 }, animIn: { kind: 'typewriter', durationSec: 1.5 } },
  { id: 'hook-list', label: 'Top 3', text: '3 things I wish I knew', durationSec: 3, style: base({ font: 'condensed', sizePct: 0.06, uppercase: true, stroke: { color: '#000000', widthPct: 0.1 } }), transform: { x: 0.5, y: 0.15 }, animIn: { kind: 'slideDown', durationSec: 0.3 } },
  { id: 'hook-marker', label: 'Marker', text: 'honestly obsessed', durationSec: 3, style: base({ font: 'marker', weight: 400, sizePct: 0.06, color: '#FF4D8D' }), transform: { x: 0.5, y: 0.3, rotation: -6 }, animIn: { kind: 'pop', durationSec: 0.3 } },
  { id: 'hook-before', label: 'Before / after', text: 'BEFORE', durationSec: 2, style: base({ font: 'condensed', sizePct: 0.07, background: { color: '#EF4444', opacity: 1, paddingPct: 0.25, radiusPct: 0.15 } }), transform: { x: 0.5, y: 0.12 }, animIn: { kind: 'fade', durationSec: 0.2 } },
  { id: 'hook-serif', label: 'Elegant', text: 'a little routine', durationSec: 3, style: base({ font: 'serif', weight: 400, sizePct: 0.05, shadow: { color: '#000000', opacity: 0.5, blurPct: 0.2, dyPct: 0.03 } }), transform: { x: 0.5, y: 0.5 }, animIn: { kind: 'fade', durationSec: 0.6 }, animOut: { kind: 'fade', durationSec: 0.4 } },
  { id: 'hook-stop', label: 'Stop scrolling', text: 'STOP SCROLLING', durationSec: 2, style: base({ sizePct: 0.07, color: '#FFFFFF', stroke: { color: '#EF4444', widthPct: 0.16 } }), transform: { x: 0.5, y: 0.45 }, animIn: { kind: 'zoom', durationSec: 0.25 } },
  { id: 'hook-caption', label: 'Lower third', text: 'Day 1 of trying this', durationSec: 3, style: base({ weight: 700, sizePct: 0.035, align: 'left', background: { color: '#111111', opacity: 0.8, paddingPct: 0.3, radiusPct: 0.2 } }), transform: { x: 0.4, y: 0.85 }, animIn: { kind: 'slideUp', durationSec: 0.3 }, animOut: { kind: 'fade', durationSec: 0.3 } },
];
