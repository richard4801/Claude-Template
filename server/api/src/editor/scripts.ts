// Which languages the server's export can draw (plans/edit-xl-options.md §4, "nothing half-works", 2026-11-09). The
// render draws text with opentype.js; its fallback face is DejaVu Sans (Latin, Cyrillic, Greek, Vietnamese). Chinese,
// Japanese and Korean draw with the Noto CJK faces (step 2); Arabic, Hebrew, Devanagari (Hindi) and Thai with their
// Noto faces, shaped by HarfBuzz and put in right-to-left order where needed (step 3) — each only when its faces are
// installed (assets/cjk, scripts/cjk-fonts.mjs). Translate offers only the languages the export draws, and captions in
// the others (Bengali, Tamil, …) say plainly that the export can't draw them yet.
import fs from 'node:fs';
import { cjkFile, scriptFile, type ShapedKind } from './textdraw.js';

/** Languages the export draws with DejaVu Sans alone. */
const BASE_LANGUAGES = ['en', 'es', 'fr', 'de', 'it', 'pt', 'nl', 'ru', 'uk', 'pl', 'tr', 'id', 'vi', 'sv', 'da', 'no', 'fi', 'cs', 'ro', 'el', 'ms', 'fil'];
const CJK_LANGUAGES = ['ja', 'zh', 'ko'];
/** Shaped languages and the script face each needs. */
const SHAPED_LANGUAGES: Record<string, ShapedKind> = { ar: 'arabic', fa: 'arabic', ur: 'arabic', he: 'hebrew', hi: 'devanagari', mr: 'devanagari', ne: 'devanagari', th: 'thai' };

let cjk: boolean | null = null;
const shaped = new Map<ShapedKind, boolean>();
/** Whether the six Noto CJK faces are installed (checked once; `recheck` looks again). */
export function cjkReady(recheck = false): boolean {
  if (cjk === null || recheck) cjk = (['sc', 'jp', 'kr'] as const).every(k => fs.existsSync(cjkFile(k, false)) && fs.existsSync(cjkFile(k, true)));
  return cjk;
}
/** Whether a shaped script's two faces are installed (checked once). */
export function scriptReady(k: ShapedKind): boolean {
  if (!shaped.has(k)) shaped.set(k, fs.existsSync(scriptFile(k, false)) && fs.existsSync(scriptFile(k, true)));
  return shaped.get(k)!;
}
/** Languages whose captions the export draws correctly on this server. */
export function exportLanguages(): Set<string> {
  return new Set([...BASE_LANGUAGES, ...(cjkReady() ? CJK_LANGUAGES : []), ...Object.entries(SHAPED_LANGUAGES).filter(([, k]) => scriptReady(k)).map(([l]) => l)]);
}

const NAMES: Record<string, string> = { ja: 'Japanese', zh: 'Chinese', ko: 'Korean', ar: 'Arabic', fa: 'Persian', ur: 'Urdu', he: 'Hebrew', hi: 'Hindi', mr: 'Marathi', ne: 'Nepali', th: 'Thai', bn: 'Bengali', ta: 'Tamil', te: 'Telugu', gu: 'Gujarati', pa: 'Punjabi', kn: 'Kannada', ml: 'Malayalam', si: 'Sinhala' };

const cls = (ranges: [number, number][]) => new RegExp(`[${ranges.map(([a, b]) => `${String.fromCodePoint(a)}-${String.fromCodePoint(b)}`).join('')}]`, 'u');
/** Letters DejaVu can't draw: CJK, kana, hangul, Arabic, Hebrew, the Indic scripts, Thai (and presentation forms). */
const UNDRAWABLE = cls([[0x0590, 0x05ff], [0x0600, 0x06ff], [0x0750, 0x077f], [0x08a0, 0x08ff], [0x0900, 0x0dff], [0x0e00, 0x0e7f], [0x1100, 0x11ff],
  [0x3040, 0x30ff], [0x3130, 0x318f], [0x3400, 0x4dbf], [0x4e00, 0x9fff], [0xa8e0, 0xa8ff], [0xac00, 0xd7af], [0xf900, 0xfaff], [0xfb1d, 0xfdff], [0xfe70, 0xfeff]]);
/** Of those, what an installed face draws: Han, kana and hangul (CJK); Arabic, Hebrew, Devanagari, Thai (shaped). */
const DRAWN: [() => boolean, RegExp][] = [
  [() => cjkReady(), cls([[0x1100, 0x11ff], [0x3040, 0x30ff], [0x3130, 0x318f], [0x3400, 0x4dbf], [0x4e00, 0x9fff], [0xac00, 0xd7af], [0xf900, 0xfaff]])],
  [() => scriptReady('arabic'), cls([[0x0600, 0x06ff], [0x0750, 0x077f], [0x08a0, 0x08ff], [0xfb50, 0xfdff], [0xfe70, 0xfeff]])],
  [() => scriptReady('hebrew'), cls([[0x0590, 0x05ff], [0xfb1d, 0xfb4f]])],
  [() => scriptReady('devanagari'), cls([[0x0900, 0x097f], [0xa8e0, 0xa8ff]])],
  [() => scriptReady('thai'), cls([[0x0e00, 0x0e7f]])],
];
const drawable = (ch: string) => !UNDRAWABLE.test(ch) || DRAWN.some(([ready, re]) => re.test(ch) && ready());

/** A plain message when captions in [language] (or with these words) can't be drawn by the export yet, else null. */
export function exportNotice(language: string | null | undefined, words: { text: string }[] = []): string | null {
  const lang = (language ?? '').toLowerCase().split(/[-_]/)[0]!;
  if (NAMES[lang] && !exportLanguages().has(lang)) return `Captions in ${NAMES[lang]} show in the app, but exports can't draw them yet`;
  if (words.some(w => ![...w.text].every(drawable))) return "Some caption letters show in the app, but exports can't draw them yet";
  return null;
}
