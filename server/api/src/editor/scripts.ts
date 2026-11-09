// Which languages the server's export can draw (plans/edit-xl-options.md §4, "nothing half-works", 2026-11-09). The
// render draws text with opentype.js; its fallback face is DejaVu Sans (Latin, Cyrillic, Greek, Vietnamese). It has no
// CJK, Devanagari or Thai letters, and no shaping or right-to-left ordering, so Arabic and Hebrew would come out as
// separate letters in the wrong order. Until CJK fonts (step 2) and shaping (step 3) land, translate offers only the
// languages here, and captions in the others say plainly that the export can't draw them yet.

/** Languages whose captions the export draws correctly today. */
export const EXPORT_LANGUAGES = new Set(['en', 'es', 'fr', 'de', 'it', 'pt', 'nl', 'ru', 'uk', 'pl', 'tr', 'id', 'vi', 'sv', 'da', 'no', 'fi', 'cs', 'ro', 'el', 'ms', 'fil']);

const NAMES: Record<string, string> = { ja: 'Japanese', zh: 'Chinese', ko: 'Korean', ar: 'Arabic', he: 'Hebrew', hi: 'Hindi', th: 'Thai', fa: 'Persian', ur: 'Urdu', bn: 'Bengali', ta: 'Tamil' };

/**
 * Letters the export can't draw yet: CJK, kana, hangul, Arabic, Hebrew, Indic and Thai scripts (and the Arabic/Hebrew
 * presentation forms). Latin, Cyrillic and Greek are drawn.
 */
const RANGES: [number, number][] = [[0x0590, 0x05ff], [0x0600, 0x06ff], [0x0750, 0x077f], [0x08a0, 0x08ff], [0x0900, 0x0dff], [0x0e00, 0x0e7f], [0x1100, 0x11ff],
  [0x3040, 0x30ff], [0x3130, 0x318f], [0x3400, 0x4dbf], [0x4e00, 0x9fff], [0xac00, 0xd7af], [0xf900, 0xfaff], [0xfb1d, 0xfdff], [0xfe70, 0xfeff]];
const UNDRAWABLE = new RegExp(`[${RANGES.map(([a, b]) => `${String.fromCodePoint(a)}-${String.fromCodePoint(b)}`).join('')}]`, 'u');

/** A plain message when captions in [language] (or with these words) can't be drawn by the export yet, else null. */
export function exportNotice(language: string | null | undefined, words: { text: string }[] = []): string | null {
  const lang = (language ?? '').toLowerCase().split(/[-_]/)[0]!;
  if (NAMES[lang]) return `Captions in ${NAMES[lang]} show in the app, but exports can't draw them yet`;
  if (words.some(w => UNDRAWABLE.test(w.text))) return "Some caption letters show in the app, but exports can't draw them yet";
  return null;
}
