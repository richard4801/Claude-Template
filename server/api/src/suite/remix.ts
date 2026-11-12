// AI suite · New Swap (remix, plans/new-swap.md): change parts of a source clip with toggles (background, outfit,
// character, look & light) and keep everything else. Pure planning (no database), like recast.ts: which models can do
// the toggles, Auto's pick and why, the pictures sent, the suite.remix prompt, the part of the clip used and the price.
// Owner 2026-11-12: Wan 2.7 Edit is Auto's first pick for Background / Look; a clip longer than the model takes is
// trimmed by the person first (never silently cut); Character is her under a strict figure lock, and a face swap from
// a photo is optional (face only).
import type { ImageRef } from '../db/schema.js';
import { DEFAULT_TEXTS, type PromptTexts } from '../prompt/library.js';
import { run } from '../prompt/scripts/builders.js';
import { sanitizeDirection } from '../prompt/engine.js';
import { billedSeconds, joinTokens, perSecond, planRefSent, token, type Character, type RemixToggles, type ShotPlan, type ShotRequest, type SuitePrefs } from './plan.js';
import { MODELS, modelById, refFor, type EditDo, type EditToggle, type ModelSpec, type ProviderId } from './registry.js';

/** The toggles that are on, in the order the apps show them (character "face" is the optional face swap). */
export function togglesOn(x: RemixToggles): EditToggle[] {
  const out: EditToggle[] = [];
  if (x.background) out.push('background');
  if (x.outfit) out.push('outfit');
  if (x.character) out.push(x.character.kind === 'face' ? 'face' : 'character');
  if (x.look) out.push('look');
  return out;
}

const TOGGLE_WORDS: Record<EditToggle, string> = { background: 'Background', outfit: 'Outfit', character: 'Character', look: 'Look & light', face: 'Face swap' };
const RANK: Record<EditDo, number> = { yes: 2, prompt: 1, no: 0 };

/** The pictures each toggle needs at least (one per picture-carrying choice). */
export function minImages(x: RemixToggles) {
  return (x.character ? 1 : 0) + (x.outfit && x.outfit.kind !== 'words' ? 1 : 0) + (x.background?.mode === 'photo' ? 1 : 0);
}

export type RemixSupport = { support: EditDo; reason: string | null };
/** Can model `m` make these toggles? "prompt" = by instruction only (works, less reliable). */
export function remixSupport(m: ModelSpec, x: RemixToggles): RemixSupport {
  const e = m.edit;
  if (!e) return { support: 'no', reason: 'doesn’t edit a video' };
  const on = togglesOn(x);
  if (!on.length) return { support: 'no', reason: 'turn on a change' };
  if (e.needsCharacter && x.character?.kind !== 'model') return { support: 'no', reason: 'puts a person from pictures into the clip: turn on Character (her)' };
  let worst: EditDo = 'yes';
  for (const t of on) {
    const d = e.does[t];
    if (d === 'no') return { support: 'no', reason: `can’t do ${TOGGLE_WORDS[t]}` };
    if (RANK[d] < RANK[worst]) worst = d;
  }
  const need = minImages(x);
  if (need > e.maxImages) return { support: 'no', reason: `takes ${e.maxImages} ${e.maxImages === 1 ? 'picture' : 'pictures'}: these changes need ${need}` };
  if (e.prompt === false && on.some(t => t !== 'character' && t !== 'outfit')) return { support: 'no', reason: 'takes no words' };
  return { support: worst, reason: worst === 'prompt' ? `does ${on.filter(t => e.does[t] === 'prompt').map(t => TOGGLE_WORDS[t]).join(' and ')} by instruction only` : null };
}

/** Auto's order for these toggles (owner 2026-11-12: Wan 2.7 Edit first for Background / Look). */
export function autoOrder(x: RemixToggles): string[] {
  if (x.character?.kind === 'model') return ['genjutsu-light', 'genjutsu', 'kling-o1', 'seedance-2.5', 'kling-v4'];
  if (x.outfit && !x.background && !x.look) return ['kling-o1', 'seedance-2.5', 'wan-2.7-edit', 'kling-v4'];
  if (x.outfit) return ['kling-o1', 'seedance-2.5', 'kling-v4', 'wan-2.7-edit'];
  return ['wan-2.7-edit', 'kling-o1', 'kling-v4', 'seedance-2.5'];
}

/** Auto's one-line reason. */
export function whyLine(m: ModelSpec, x: RemixToggles): string {
  const on = togglesOn(x).map(t => TOGGLE_WORDS[t]);
  const what = on.length === 1 ? `${on[0]} only` : on.join(' + ');
  const e = m.edit!;
  const bits = [e.keepsAudio ? 'keeps the sound' : 'MUSE puts the clip’s sound back', `up to ${e.sourceSeconds[1]} s`];
  if (m.id === 'genjutsu-light' || m.id === 'genjutsu') bits.unshift('same moves, new look');
  if (m.id === 'wan-2.7-edit') bits.push('1080p');
  return `${what}: ${m.name} (${bits.join(', ')})`;
}

export type RemixCandidate = { model: ModelSpec; support: RemixSupport };
type PickOpts = { prefs?: SuitePrefs; providers: Set<ProviderId>; engineModel?: string; /** 4c: models the owner hides from this member. */ hidden?: Set<string> };
const usable = (m: ModelSpec, o: PickOpts) => {
  const pref = o.prefs?.models?.[m.id];
  if (m.status === 'removed') return 'removed';
  if (o.hidden?.has(m.id)) return 'not offered to members';
  if (pref?.enabled === false) return 'switched off';
  if (m.licence.requiresAck && !pref?.acknowledgedAt) return 'licence not acknowledged';
  if (!o.providers.has(m.provider)) return `${m.provider} not set up`;
  return null;
};

/** Every model that edits a video, with its support for these toggles (the model pill's list). */
export function remixModels(x: RemixToggles, o: PickOpts): (RemixCandidate & { unavailable: string | null })[] {
  return MODELS.filter(m => m.edit).map(m => ({ model: m, support: remixSupport(m, x), unavailable: usable(m, o) }));
}

export type RemixPick = { model: ModelSpec; support: RemixSupport; why: string | null; tried: { model: string; why: string }[] };
/** The picked model (checked), else Auto's first model that can do the toggles. */
export function pickRemix(x: RemixToggles, o: PickOpts): RemixPick | { error: string; message: string; tried: RemixPick['tried'] } {
  const tried: RemixPick['tried'] = [];
  if (o.engineModel) {
    const m = modelById(o.engineModel);
    if (!m?.edit) return { error: 'remix_unsupported', message: `${m?.name ?? 'That model'} doesn’t edit a video`, tried };
    const off = usable(m, o);
    if (off) return { error: 'engine_unavailable', message: `${m.name} isn’t available: ${off}`, tried };
    const s = remixSupport(m, x);
    if (s.support === 'no') return { error: 'remix_unsupported', message: `${m.name} ${s.reason}`, tried };
    return { model: m, support: s, why: null, tried };
  }
  for (const id of autoOrder(x)) {
    const m = modelById(id);
    if (!m?.edit) { tried.push({ model: id, why: 'unknown model' }); continue; }
    const off = usable(m, o);
    if (off) { tried.push({ model: id, why: off }); continue; }
    const s = remixSupport(m, x);
    if (s.support === 'no') { tried.push({ model: id, why: s.reason ?? 'can’t' }); continue; }
    return { model: m, support: s, why: whyLine(m, x), tried };
  }
  return { error: 'nothing_fits', message: `No model can make these changes right now · ${tried.map(t => `${modelById(t.model)?.name ?? t.model}: ${t.why}`).join('; ')}`, tried };
}

/** What a picture group is: her images, the outfit's, a product / face / background photo. */
type Group = { kind: 'character' | 'outfit' | 'product' | 'face' | 'background'; images: { label: string; image: ImageRef }[] };

/**
 * Fills `max` picture slots: one for each group first (each needs at least one), then the rest group by group in
 * order (her face front and profile before the outfit's angles, the outfit's close-ups last). Kept in group order.
 */
export function fillImages(groups: Group[], max: number) {
  let left = max;
  const take = groups.map(g => { const n = Math.min(1, g.images.length, left); left -= n; return n; });
  for (let i = 0; i < groups.length && left > 0; i++) {
    const more = Math.min(left, groups[i]!.images.length - take[i]!);
    take[i]! += more; left -= more;
  }
  const kept = groups.map((g, i) => ({ ...g, images: g.images.slice(0, take[i]) }));
  const dropped = groups.flatMap((g, i) => g.images.slice(take[i]).map(x => x.label));
  return { groups: kept, dropped };
}

/** The outfit's pictures, most useful first: the four body angles (her figure), then the close-ups. */
const OUTFIT_ORDER = ['outfit, front', 'outfit, back', 'outfit, side', 'outfit, ¾'];
export const outfitFirst = (imgs: { label: string; image: ImageRef }[]) => {
  const r = (l: string) => { const i = OUTFIT_ORDER.indexOf(l); return i < 0 ? 9 : i; };
  return [...imgs].sort((a, b) => r(a.label) - r(b.label));
};

/** The part of the clip a model would use, and whether the person must trim first (owner: never cut silently). */
export function remixSpan(m: ModelSpec, clipSeconds: number, range?: [number, number] | null) {
  const [min, max] = m.edit!.sourceSeconds;
  const from = range ? Math.max(0, Math.min(range[0], clipSeconds)) : 0;
  const to = range ? Math.max(from, Math.min(range[1], clipSeconds)) : clipSeconds;
  const seconds = Math.round((to - from) * 1000) / 1000;
  const needed = seconds > max + 0.05;
  const tooShort = seconds < min - 0.05;
  return { from, to, seconds, min, max, needed, tooShort, trimmed: !!range && (from > 0.05 || to < clipSeconds - 0.05) };
}

export type RemixPeople = {
  /** Her (Character = her), with her outfit when Outfit is one of hers. */
  her: Character | null;
  /** Outfit is one of her outfits while Character is off or a face swap: that outfit's pictures. */
  outfitOnly: NonNullable<Character['outfit']> | null;
};

/** The person's words, one part per toggle ("Background: … Look & light: …"); what goes under CHANGE. */
export function remixWords(x: RemixToggles, her: Character | null, texts: PromptTexts) {
  const parts: string[] = [];
  const removed: string[] = [];
  const clean = (w: string) => {
    if (!her) return w.trim();
    const s = sanitizeDirection(w, { name: her.name, look: her.look, neverAdd: her.neverAdd }, texts);
    removed.push(...s.removed);
    return s.clean.trim();
  };
  if (x.background?.mode === 'describe' && x.background.words.trim()) { const w = clean(x.background.words); if (w) parts.push(`Background: ${w}.`); }
  // Outfit words change the clothes on purpose: not sanitised against her look.
  if (x.outfit?.kind === 'words' && x.outfit.words.trim()) parts.push(`Outfit: ${x.outfit.words.trim()}.`);
  if (x.look?.words.trim()) { const w = clean(x.look.words); if (w) parts.push(`Look & light: ${w}.`); }
  return { text: parts.join(' ').replace(/\.\./g, '.'), removed };
}

/** Each turned-on toggle's missing piece, in plain words (null when complete). */
export function remixIncomplete(x: RemixToggles): string | null {
  if (!togglesOn(x).length) return 'Turn on a change: Background, Outfit, Character or Look & light';
  if (x.background?.mode === 'describe' && !x.background.words.trim()) return 'Background · Describe: write the new place';
  if (x.outfit?.kind === 'words' && !x.outfit.words.trim()) return 'Outfit · Words: write what they wear';
  if (x.look && !x.look.words.trim()) return 'Look & light: write the time of day, light or colour grade';
  return null;
}

/** Kept from the clip: the toggles that are off, in words for the keep line. */
export function keptWords(x: RemixToggles) {
  const k: string[] = [];
  if (!x.character) k.push('the same person');
  if (!x.outfit) k.push(x.character?.kind === 'model' ? 'the outfit of the person in the clip, worn by her' : 'their outfit');
  if (!x.background) k.push('the background');
  if (!x.look) k.push('the light and colour');
  return k.length ? `${joinTokens(k)}; ` : '';
}

export function buildRemixPlan(r: ShotRequest, x: RemixToggles, p: RemixPick, people: RemixPeople, clip: { key: string; seconds: number },
  o: { texts?: PromptTexts; priceScale?: number }): ShotPlan {
  const t = o.texts ?? DEFAULT_TEXTS;
  const m = p.model, e = m.edit!, style = m.camera.refStyle;
  const notes: string[] = [];
  // Pictures: her, the outfit, a product or face photo, the background photo (last).
  const groups: Group[] = [];
  const her = x.character?.kind === 'model' ? people.her : null;
  if (her) groups.push({ kind: 'character', images: her.images });
  if (x.character?.kind === 'face') groups.push({ kind: 'face', images: [{ label: 'face swap photo', image: x.character.image as ImageRef }] });
  const outfitSet = x.outfit?.kind === 'outfit' ? (her?.outfit ?? people.outfitOnly) : null;
  if (outfitSet) groups.push({ kind: 'outfit', images: outfitFirst(outfitSet.images) });
  if (x.outfit?.kind === 'product') groups.push({ kind: 'product', images: [{ label: 'outfit · product photo', image: x.outfit.image as ImageRef }] });
  if (x.background?.mode === 'photo') groups.push({ kind: 'background', images: [{ label: 'background', image: x.background.image as ImageRef }] });
  const filled = fillImages(groups, e.maxImages);
  if (filled.dropped.length) notes.push(`${m.name} takes ${e.maxImages} ${e.maxImages === 1 ? 'picture' : 'pictures'}: left out ${filled.dropped.join(', ')}`);
  const refs: { label: string; role: string; image: ImageRef }[] = [];
  const tokensOf: Partial<Record<Group['kind'], string[]>> = {};
  const labelsOf: Partial<Record<Group['kind'], string[]>> = {};
  for (const g of filled.groups) {
    tokensOf[g.kind] = g.images.map(img => { refs.push({ label: img.label, role: g.kind === 'background' ? 'location' : g.kind === 'product' ? 'outfit' : 'character', image: img.image }); return token(style, 'image', refs.length); });
    labelsOf[g.kind] = g.images.map(img => img.label);
  }
  // Her figure (figure lock): from her outfit's body angles when one is sent, else her own body shots, else her images.
  const herTok = tokensOf.character ?? [];
  const outTok = tokensOf.outfit ?? [];
  const bodyOut = outTok.filter((_, i) => /^outfit, (front|back|side|¾)$/.test(labelsOf.outfit![i]!));
  const bodyHer = herTok.filter((_, i) => labelsOf.character![i]!.startsWith('body'));
  const figure = bodyOut.length ? bodyOut : bodyHer.length ? bodyHer : herTok;
  const words = remixWords(x, her, t);
  if (words.removed.length) notes.push(`left out of your words (they would change ${her?.name}'s look): ${words.removed.join('; ')}`);
  const source = token(style, 'video', 1);
  let prompt = e.prompt === false ? '' : run('suite.remix', t, {
    inputs: { character: x.character?.kind ?? 'none', outfit: x.outfit?.kind ?? 'none', background: x.background?.mode ?? 'none', look: !!x.look },
    vars: {
      source, subject: her ? 'she' : 'the person', name: her?.name ?? '', refs: joinTokens(herTok), figureRefs: joinTokens(figure),
      outfitRefs: joinTokens(outTok), productRef: tokensOf.product?.[0] ?? '', faceRef: tokensOf.face?.[0] ?? '', bgRef: tokensOf.background?.[0] ?? '', kept: keptWords(x),
    },
    direction: words.text,
  }).text;
  if (m.promptMax && prompt.length > m.promptMax) { prompt = prompt.slice(0, m.promptMax); notes.push('prompt shortened to fit'); }
  if (!e.tested) notes.push(`${m.name} hasn’t had a test run in MUSE yet`);
  if (p.support.reason) notes.push(`${m.name} ${p.support.reason}`);
  // The part of the clip used: the trimmer's range, checked against the model's length (never cut silently).
  const span = remixSpan(m, clip.seconds, r.range ?? null);
  const seconds = span.needed ? span.max : span.seconds; // priced at the model's maximum until trimmed
  const keepAudio = r.keepAudio ?? true;
  const res = m.resolutions.find(z => z.id === r.resolution) ?? m.resolutions.find(z => z.id === e.defaultResolution) ?? m.resolutions.at(-1)!;
  const perSec = perSecond(m, res, { videoInput: true, audio: false, kind: 'guide' }) * (o.priceScale ?? 1);
  const billed = billedSeconds(m, Math.max(seconds, span.min), { videoInput: true, guideSeconds: seconds });
  const estimate = Math.round(perSec * billed * r.takes * 10000) / 10000;
  return {
    tier: r.quality, mode: 'remix', modelId: m.id, provider: m.provider, ref: refFor(m, 'guide'), kind: 'guide', resolution: res.id, seconds, aspect: r.aspectRatio,
    audio: keepAudio, takes: r.takes, seed: m.seed ? r.seed : undefined, prompt, params: {},
    images: { middle: [], refs }, videos: [{ video: { key: clip.key, seconds }, use: 'source' }], speaking: false, separationUsd: 0,
    perSec, billedPerTake: billed, extraPerTake: 0, estimate, camera: { moves: [], notes: [], usesGuide: false }, notes,
    sentImages: { images: refs.map(planRefSent), changed: false, max: e.maxImages },
    remix: { keepAudio, restoreAudio: keepAudio, range: span.trimmed || span.needed ? [span.from, span.needed ? span.from + span.max : span.to] : null,
      clipSeconds: clip.seconds, toggles: togglesOn(x), why: p.why, tested: e.tested,
      ...(span.needed ? { trimNeeded: true } : {}), ...(span.tooShort ? { tooShort: true } : {}), minSeconds: span.min, maxSeconds: span.max },
  };
}

/** What the apps show for a New Swap estimate: the part of the clip used, the trimmer's limits, Auto's reason, billing. */
export function remixView(plan: ShotPlan) {
  const x = plan.remix!, m = modelById(plan.modelId)!;
  const from = x.range?.[0] ?? 0, to = x.range?.[1] ?? Math.min(x.clipSeconds, x.maxSeconds);
  const inputBilled = m.id === 'genjutsu-light' ? plan.seconds : 0;
  return {
    toggles: x.toggles, why: x.why, tested: x.tested, keepAudio: x.keepAudio,
    uses: { from: Math.round(from * 10) / 10, to: Math.round(to * 10) / 10, of: Math.round(x.clipSeconds * 10) / 10 },
    trim: { needed: !!x.trimNeeded, tooShort: !!x.tooShort, minSeconds: x.minSeconds, maxSeconds: x.maxSeconds },
    // Seconds the provider bills: the new video, plus the clip's own seconds where it charges for them (priced into the rate otherwise).
    billedSeconds: { output: plan.seconds, input: inputBilled, inRate: m.resolutions.some(r => r.perSecWithVideo != null) },
  };
}
