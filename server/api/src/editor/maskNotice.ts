// Mask announcements (owner, 2026-11-11, after the "oval" bug: an inverted mask hidden on a clip): when one of Claude's
// changes adds, changes or removes a mask, Invert, a green-screen key or a cut-out matte, the change says so in one plain
// line ("Added an inverted oval mask to clip 2"). It rides on the history entry (meta.notice) so every app shows it with
// Undo, and on apply_edit_ops' result so Claude mentions it.
import * as M from './model.js';

type Keyed = { mask?: M.Mask; chroma?: M.Chroma; alphaMatte?: M.AlphaMatte };
const SHAPE: Record<M.MaskShape, string> = { linear: 'linear', mirror: 'mirror', circle: 'oval', rect: 'rectangle', heart: 'heart', star: 'star' };
const same = (a: unknown, b: unknown) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
const an = (w: string) => (/^[aeiou]/i.test(w) ? `an ${w}` : `a ${w}`);
const maskWords = (m: M.Mask) => `${m.invert ? 'inverted ' : ''}${SHAPE[m.shape] ?? m.shape} mask`;

/** Every item by id with how the person knows it: "clip 2" on the main track, "overlay 1", "image 1", "text 1". */
function items(p: M.EditProject): Map<string, { name: string; item: Keyed }> {
  const out = new Map<string, { name: string; item: Keyed }>();
  const n: Record<string, number> = {};
  for (const t of p.tracks) {
    const word = t.kind === 'main' ? 'clip' : t.kind === 'video' ? 'overlay' : t.kind;
    for (const it of t.items) { n[word] = (n[word] ?? 0) + 1; out.set(it.id, { name: `${word} ${n[word]}`, item: it as Keyed }); }
  }
  return out;
}

/** The plain lines for what changed in masks, Invert, green-screen keys and cut-outs between two projects. */
export function maskNotices(before: M.EditProject, after: M.EditProject): string[] {
  const was = items(before), now = items(after), lines: string[] = [];
  const old = [...was.values()].map(v => v.item);
  for (const [id, { name, item: b }] of now) {
    const prev = was.get(id)?.item;
    // A new item (a split's right half, a copy) that only carries settings already in the edit is not a new change.
    const a: Keyed = prev ?? {
      mask: old.some(o => same(o.mask, b.mask)) ? b.mask : undefined,
      chroma: old.some(o => same(o.chroma, b.chroma)) ? b.chroma : undefined,
      alphaMatte: old.some(o => same(o.alphaMatte, b.alphaMatte)) ? b.alphaMatte : undefined,
    };
    if (!same(a.mask, b.mask)) {
      if (!b.mask) lines.push(`Removed the ${maskWords(a.mask!)} from ${name}`);
      else if (!a.mask) lines.push(`Added ${an(maskWords(b.mask))} to ${name}`);
      else if (!!a.mask.invert !== !!b.mask.invert && a.mask.shape === b.mask.shape) lines.push(`Turned ${b.mask.invert ? 'on' : 'off'} Invert on the ${SHAPE[b.mask.shape]} mask of ${name}`);
      else lines.push(`Changed the mask on ${name} (now ${an(maskWords(b.mask))})`);
    }
    if (!same(a.chroma, b.chroma)) {
      lines.push(!b.chroma ? `Removed the green-screen key from ${name}` : !a.chroma ? `Added a green-screen key (${b.chroma.color}) to ${name}` : `Changed the green-screen key on ${name}`);
    }
    if (!same(a.alphaMatte, b.alphaMatte)) {
      const inv = (m?: M.AlphaMatte) => (m?.invert ? 'inverted cut-out' : 'cut-out');
      lines.push(!b.alphaMatte ? `Removed the ${inv(a.alphaMatte)} from ${name}` : !a.alphaMatte ? `Added ${an(inv(b.alphaMatte))} (background removed) to ${name}`
        : !!a.alphaMatte.invert !== !!b.alphaMatte.invert ? `Turned ${b.alphaMatte.invert ? 'on' : 'off'} Invert on the cut-out of ${name}` : `Changed the cut-out on ${name}`);
    }
  }
  return lines;
}
