// Silence, filler-word and repeated-word cuts from word timestamps (plans/api.md "Editor v2" → cuts). Pure; the
// reference for the fixture `functions.json` → suggestCuts. Times are SOURCE seconds of the transcribed media.
export type Word = { text: string; startSec: number; endSec: number; score?: number };
export type CutReason = 'silence' | 'filler' | 'repeat';
export type Cut = { startSec: number; endSec: number; reason: CutReason; text?: string };
export type CutOptions = { minSilenceSec?: number; keepPadSec?: number; fillers?: boolean; repeats?: boolean; extraFillers?: string[] };

export const FILLERS = ['um', 'umm', 'uh', 'uhh', 'uhm', 'er', 'erm', 'ah', 'hmm', 'mm', 'mhm'];
export const CUT_DEFAULTS = { minSilenceSec: 0.7, keepPadSec: 0.12, fillers: true, repeats: false } as const;
const r3 = (v: number) => Math.round(v * 1000) / 1000;
export const normWord = (s: string) => s.toLowerCase().replace(/[^\p{L}\p{N}']+/gu, '');

export function suggestCuts(words: Word[], durationSec: number, o: CutOptions = {}): { cuts: Cut[]; savedSec: number } {
  const minSil = o.minSilenceSec ?? CUT_DEFAULTS.minSilenceSec, pad = o.keepPadSec ?? CUT_DEFAULTS.keepPadSec;
  const fillers = new Set([...FILLERS, ...(o.extraFillers ?? []).map(normWord)].filter(Boolean));
  const ws = [...words].sort((a, b) => a.startSec - b.startSec);
  const raw: Cut[] = [];
  const silence = (a: number, b: number) => { const s = a + pad, e = b - pad; if (b - a >= minSil && e - s >= 0.1) raw.push({ startSec: s, endSec: e, reason: 'silence' }); };
  if (ws.length === 0) return { cuts: [], savedSec: 0 };
  // Leading and trailing silence keep no pad on the outer side.
  if (ws[0]!.startSec >= minSil && ws[0]!.startSec - pad >= 0.1) raw.push({ startSec: 0, endSec: ws[0]!.startSec - pad, reason: 'silence' });
  for (let i = 1; i < ws.length; i++) silence(ws[i - 1]!.endSec, ws[i]!.startSec);
  const last = ws[ws.length - 1]!;
  if (durationSec - last.endSec >= minSil && durationSec - (last.endSec + pad) >= 0.1) raw.push({ startSec: last.endSec + pad, endSec: durationSec, reason: 'silence' });
  ws.forEach((w, i) => {
    const n = normWord(w.text);
    if ((o.fillers ?? CUT_DEFAULTS.fillers) && fillers.has(n)) raw.push({ startSec: w.startSec, endSec: w.endSec, reason: 'filler', text: w.text });
    const next = ws[i + 1];
    if ((o.repeats ?? CUT_DEFAULTS.repeats) && next && n && normWord(next.text) === n && next.startSec - w.endSec < 1)
      raw.push({ startSec: w.startSec, endSec: next.startSec, reason: 'repeat', text: w.text });
  });
  raw.sort((a, b) => a.startSec - b.startSec || a.endSec - b.endSec);
  const out: Cut[] = [];
  for (const c of raw) {
    const prev = out[out.length - 1];
    if (prev && c.startSec <= prev.endSec + 1e-9) { prev.endSec = Math.max(prev.endSec, c.endSec); if (c.text && !prev.text) prev.text = c.text; continue; }
    out.push({ ...c });
  }
  const cuts = out.map(c => ({ ...c, startSec: r3(Math.max(0, c.startSec)), endSec: r3(Math.min(durationSec, c.endSec)) })).filter(c => c.endSec - c.startSec >= 0.05);
  return { cuts, savedSec: r3(cuts.reduce((s, c) => s + c.endSec - c.startSec, 0)) };
}
