// Which languages the server's export can draw (plans/edit-xl-options.md §4, "nothing half-works", 2026-11-09). The
// render draws text with opentype.js; its fallback face is DejaVu Sans (Latin, Cyrillic, Greek, Vietnamese). It has no
// Devanagari or Thai letters, and no shaping or right-to-left ordering, so Arabic and Hebrew would come out as separate
// letters in the wrong order. Chinese, Japanese and Korean draw with the Noto CJK faces (step 2) when they're installed
// (assets/cjk). Until shaping (step 3) lands, translate offers only the languages the export draws, and captions in
// the others say plainly that the export can't draw them yet.
import fs from 'node:fs';
import { cjkFile } from './textdraw.js';

/** Languages the export draws with DejaVu Sans alone. */
const BASE_LANGUAGES = ['en', 'es', 'fr', 'de', 'it', 'pt', 'nl', 'ru', 'uk', 'pl', 'tr', 'id', 'vi', 'sv', 'da', 'no', 'fi', 'cs', 'ro', 'el', 'ms', 'fil'];
const CJK_LANGUAGES = ['ja', 'zh', 'ko'];
let cjk: boolean | null = null;
/** Whether the six Noto CJK faces are installed (checked once; tests can reset with `cjkReady(true)`). */
export function cjkReady(recheck = false): boolean {
  if (cjk === null || recheck) cjk = (['sc', 'jp', 'kr'] as const).every(k => fs.existsSync(cjkFile(k, false)) && fs.existsSync(cjkFile(k, true)));
  return cjk;
}
/** Languages whose captions the export draws correctly on this server. */
export function exportLanguages(): Set<string> { return new Set([...BASE_LANGUAGES, ...(cjkReady() ? CJK_LANGUAGES : [])]); }

const NAMES: Record<string, string> = { ja: 'Japanese', zh: 'Chinese', ko: 'Korean', ar: 'Arabic', he: 'Hebrew', hi: 'Hindi', th: 'Thai', fa: 'Persian', ur: 'Urdu', bn: 'Bengali', ta: 'Tamil' };

/**
 * Letters the export can't draw yet: CJK, kana, hangul, Arabic, Hebrew, Indic and Thai scripts (and the Arabic/Hebrew
 * presentation forms). Latin, Cyrillic and Greek are drawn.
 */
const RANGES: [number, number][] = [[0x0590, 0x05ff], [0x0600, 0x06ff], [0x0750, 0x077f], [0x08a0, 0x08ff], [0x0900, 0x0dff], [0x0e00, 0x0e7f], [0x1100, 0x11ff],
  [0x3040, 0x30ff], [0x3130, 0x318f], [0x3400, 0x4dbf], [0x4e00, 0x9fff], [0xac00, 0xd7af], [0xf900, 0xfaff], [0xfb1d, 0xfdff], [0xfe70, 0xfeff]];
/** Han, kana and hangul: drawn once the CJK faces are installed. */
const CJK_CHAR = new RegExp(`[${[[0x1100, 0x11ff], [0x3040, 0x30ff], [0x3130, 0x318f], [0x3400, 0x4dbf], [0x4e00, 0x9fff], [0xac00, 0xd7af], [0xf900, 0xfaff]].map(([a, b]) => `${String.fromCodePoint(a!)}-${String.fromCodePoint(b!)}`).join('')}]`, 'u');
const UNDRAWABLE = new RegExp(`[${RANGES.map(([a, b]) => `${String.fromCodePoint(a)}-${String.fromCodePoint(b)}`).join('')}]`, 'u');

/** A plain message when captions in [language] (or with these words) can't be drawn by the export yet, else null. */
export function exportNotice(language: string | null | undefined, words: { text: string }[] = []): string | null {
  const lang = (language ?? '').toLowerCase().split(/[-_]/)[0]!;
  const ok = exportLanguages();
  if (NAMES[lang] && !ok.has(lang)) return `Captions in ${NAMES[lang]} show in the app, but exports can't draw them yet`;
  if (words.some(w => [...w.text].some(ch => UNDRAWABLE.test(ch) && !(cjkReady() && CJK_CHAR.test(ch))))) return "Some caption letters show in the app, but exports can't draw them yet";
  return null;
}
