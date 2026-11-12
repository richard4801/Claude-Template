// AI suite · New Swap (remix, plans/new-swap.md): change parts of a source clip with toggles (background, outfit,
// character, look & light) and keep everything else. Pure planning (no database), like recast.ts: Auto's pick and why,
// how the clip reaches the picked model, the pictures sent, the suite.remix prompt, the part of the clip used and the price.
// Owner 2026-11-12:
// - Wan 2.7 Edit is Auto's first pick for Background / Look; a clip longer than the model takes is trimmed by the
//   person first (never silently cut); Character is her under a strict figure lock; a face swap from a photo is optional.
// - "Every model in our app should be available on every mode": no model is greyed out or refused. A model that can't
//   take a video natively gets the clip another way (as a reference video, as frames, or not at all for a words-only
//   model), and the plan says exactly what MUSE did. Refused only when it can't run at all (provider not set up, off).
import type { ImageRef } from '../db/schema.js';
import { DEFAULT_TEXTS, type PromptTexts } from '../prompt/library.js';
import { run } from '../prompt/scripts/builders.js';
import { sanitizeDirection } from '../prompt/engine.js';
import { billedSeconds, extraPerTake, joinTokens, perSecond, planRefSent, token, type Character, type RemixToggles, type ShotPlan, type ShotRequest, type SuitePrefs } from './plan.js';
import { MODELS, customModelsOf, modelById, refFor, type EditDo, type EditToggle, type ModelSpec, type ProviderId } from './registry.js';

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
const name = (m: ModelSpec) => m.byo?.displayName ?? m.name;
const makesShots = (m: ModelSpec) => m.modes.text || m.modes.image || m.modes.reference;

/** The pictures the toggles bring (one per picture-carrying choice). */
export function minImages(x: RemixToggles) {
  return (x.character ? 1 : 0) + (x.outfit && x.outfit.kind !== 'words' ? 1 : 0) + (x.background?.mode === 'photo' ? 1 : 0);
}

export type RemixRoute = 'edit' | 'reference' | 'frames' | 'text';

/**
 * How the clip reaches model `m`: an edit model takes the clip itself; a model with reference videos takes it as one;
 * a model with a start frame or reference pictures gets frames from the clip; anything else gets words only.
 */
export function routeOf(m: ModelSpec): RemixRoute {
  if (m.edit) return 'edit';
  if (m.byo) return m.byo.analysis.map.startImage || m.byo.analysis.map.referenceImages ? 'frames' : 'text';
  if (makesShots(m) && m.refs.videos > 0 && m.camera.referenceVideo) return 'reference';
  if (m.frames.start || (m.modes.reference && m.refs.images > 0)) return 'frames';
  return 'text';
}

/** Pictures model `m` takes on its route (frames route: references only when they go with frames, or no start frame). */
export function pictureRoom(m: ModelSpec, route: RemixRoute = routeOf(m)) {
  if (route === 'edit') return m.edit!.maxImages;
  if (m.byo) return m.byo.analysis.map.referenceImages ? Math.max(1, m.byo.analysis.inputs.referenceImages) : 0;
  if (route === 'frames' && m.frames.start && !m.frames.withRefs) return 0;
  return m.modes.reference ? m.refs.images : 0;
}

/** The frames route's frames: start/end images where the model has them, else stills as references (up to 3). */
export function framesFor(m: ModelSpec, room: number) {
  if (m.byo) return m.byo.analysis.map.startImage ? { start: true, end: !!m.byo.analysis.map.endImage, stills: 0 } : { start: false, end: false, stills: Math.min(3, room) };
  if (m.frames.start) return { start: true, end: m.frames.end, stills: 0 };
  return { start: false, end: false, stills: Math.min(3, room) };
}

/**
 * What model `m` does with these toggles. `yes` = made for it; `prompt` = by instruction only; `adapted` = MUSE sends
 * the clip another way (see `notes`). Never a refusal: the notes say exactly what MUSE does.
 */
export type RemixSupport = { support: 'yes' | 'prompt' | 'adapted'; reason: string | null; route: RemixRoute; notes: string[] };
export function remixSupport(m: ModelSpec, x: RemixToggles): RemixSupport {
  const on = togglesOn(x), route = routeOf(m), n = name(m), notes: string[] = [];
  if (route !== 'edit') {
    const fr = framesFor(m, pictureRoom(m, route));
    const count = (fr.start ? 1 : 0) + (fr.end ? 1 : 0) + fr.stills;
    if (route === 'reference') notes.push(`${n} can’t edit a video: MUSE sends your clip as a reference video, so the motion and framing follow it closely but not exactly`);
    else if (route === 'frames') notes.push(`${n} can’t take a video: MUSE sends ${count} ${count === 1 ? 'frame' : 'frames'} from your clip (${[fr.start ? 'the first' : '', fr.end ? 'the last' : '', fr.stills ? `${fr.stills} across it` : ''].filter(Boolean).join(', ')}); the motion follows your words, so it will be approximate`);
    else notes.push(`${n} takes only words: your clip and pictures aren’t sent, so the result won’t follow the clip’s motion`);
    return { support: 'adapted', reason: notes[0]!, route, notes: [...notes, ...pictureNotes(m, x, route)] };
  }
  const e = m.edit!;
  let worst: 'yes' | 'prompt' = 'yes';
  for (const t of on) {
    const d: EditDo = e.does[t];
    if (d === 'no') notes.push(`${n} has no ${TOGGLE_WORDS[t]} control: MUSE asks for it in words`);
    if (d !== 'yes') worst = 'prompt';
  }
  const needsPerson = !!e.needsCharacter && x.character?.kind !== 'model';
  if (needsPerson) notes.push(`${n} puts a person from pictures into the clip: MUSE sends a still of the person from your clip so they stay themselves (their look may drift)`);
  const wordsLost = e.prompt === false && !!(x.background?.mode === 'describe' || x.look || x.outfit?.kind === 'words' || x.direction);
  if (wordsLost) notes.push(`${n} takes no words: your written changes aren’t sent, only the pictures`);
  notes.push(...pictureNotes(m, x, route));
  const adapted = needsPerson || wordsLost || on.some(t => e.does[t] === 'no');
  const reason = notes[0] ?? (worst === 'prompt' ? `does ${on.filter(t => e.does[t] === 'prompt').map(t => TOGGLE_WORDS[t]).join(' and ')} by instruction only` : null);
  return { support: adapted ? 'adapted' : worst, reason, route, notes };
}

/** Pictures that don't fit: the least needed ones are left out, said in words. */
function pictureNotes(m: ModelSpec, x: RemixToggles, route: RemixRoute): string[] {
  const room = pictureRoom(m, route), need = minImages(x);
  if (route === 'text' || need === 0) return [];
  if (room === 0) return [`${name(m)} takes no pictures here: your pictures aren’t sent, MUSE describes the change in words`];
  if (need > room) return [`${name(m)} takes ${room} ${room === 1 ? 'picture' : 'pictures'}: MUSE sends the most important ${room === 1 ? 'one' : 'ones'} and describes the rest in words`];
  return [];
}

/** Auto's order for these toggles (owner 2026-11-12: Wan 2.7 Edit first for Background / Look). */
export function autoOrder(x: RemixToggles): string[] {
  if (x.character?.kind === 'model') return ['genjutsu-light', 'genjutsu', 'h3-hf', 'kling-o1', 'seedance-2.5', 'kling-v4'];
  if (x.outfit && !x.background && !x.look) return ['kling-o1', 'seedance-2.5', 'wan-2.7-edit', 'kling-v4'];
  if (x.outfit) return ['kling-o1', 'seedance-2.5', 'kling-v4', 'wan-2.7-edit'];
  return ['wan-2.7-edit', 'kling-o1', 'kling-v4', 'seedance-2.5'];
}

/** Auto's one-line reason. */
export function whyLine(m: ModelSpec, x: RemixToggles): string {
  const on = togglesOn(x).map(t => TOGGLE_WORDS[t]);
  const what = on.length === 1 ? `${on[0]} only` : on.join(' + ');
  const max = m.edit?.sourceSeconds[1] ?? m.duration.max;
  const bits = [m.edit?.keepsAudio ? 'keeps the sound' : 'MUSE puts the clip’s sound back', `up to ${max} s`];
  if (m.id === 'genjutsu-light' || m.id === 'genjutsu') bits.unshift('same moves, new look');
  if (m.id === 'wan-2.7-edit') bits.push('1080p');
  return `${what}: ${name(m)} (${bits.join(', ')})`;
}

export type RemixCandidate = { model: ModelSpec; support: RemixSupport };
/** The model pill's groups, in order (owner 2026-11-12: grouped, scrollable, every model). */
export type RemixGroup = 'auto' | 'edit' | 'reference' | 'frames' | 'text';
export const REMIX_GROUPS: { id: RemixGroup; label: string }[] = [
  { id: 'auto', label: 'Auto picks' }, { id: 'edit', label: 'Edits the clip' }, { id: 'reference', label: 'Uses the clip as reference' },
  { id: 'frames', label: 'From frames' }, { id: 'text', label: 'From words only' },
];
/** A model's group for these toggles: Auto's order first, else how the clip reaches it. */
export const remixGroup = (m: ModelSpec, x: RemixToggles): RemixGroup => (autoOrder(x).includes(m.id) ? 'auto' : routeOf(m));
type PickOpts = { prefs?: SuitePrefs; providers: Set<ProviderId>; engineModel?: string; /** 4c: models the owner hides from this member. */ hidden?: Set<string>; studioId?: string;
  /** Providers that refused a run recently: still listed and pickable; Auto skips them. */ down?: Set<ProviderId> };
/** Why a model can't run at all right now (not set up, switched off), or null. The only refusals left. */
const usable = (m: ModelSpec, o: PickOpts) => {
  const pref = o.prefs?.models?.[m.id];
  if (m.status === 'removed') return 'removed';
  if (o.hidden?.has(m.id)) return 'not offered to members';
  if (pref?.enabled === false) return 'switched off';
  if (m.licence.requiresAck && !pref?.acknowledgedAt) return 'licence not acknowledged';
  if (!o.providers.has(m.provider)) return `${m.provider} not set up`;
  return null;
};
const ROUTE_RANK: Record<RemixRoute, number> = { edit: 0, reference: 1, frames: 2, text: 3 };

/**
 * Every video model (built-in and the studio's own), defaults first: Auto's order for these toggles, then the other
 * edit models, then the ones MUSE adapts (reference video, frames, words). Each with what it does and, when it can't
 * run at all, why.
 */
export function remixModels(x: RemixToggles, o: PickOpts): (RemixCandidate & { unavailable: string | null })[] {
  const all = [...MODELS.filter(m => m.status !== 'removed'), ...(o.studioId ? customModelsOf(o.studioId) : [])];
  const order = autoOrder(x);
  const rank = (m: ModelSpec) => { const i = order.indexOf(m.id); return i >= 0 ? i : 100 + ROUTE_RANK[routeOf(m)] * 100 + (m.byo ? 50 : 0); };
  return all.map((m, i) => ({ m, i })).sort((a, b) => rank(a.m) - rank(b.m) || a.i - b.i)
    .map(({ m }) => ({ model: m, support: remixSupport(m, x), unavailable: usable(m, o) }));
}

export type RemixPick = { model: ModelSpec; support: RemixSupport; why: string | null; tried: { model: string; why: string }[] };
/** The picked model (any video model; refused only when it can't run at all), else Auto's first model that runs. */
export function pickRemix(x: RemixToggles, o: PickOpts): RemixPick | { error: string; message: string; tried: RemixPick['tried'] } {
  const tried: RemixPick['tried'] = [];
  if (o.engineModel) {
    const m = modelById(o.engineModel);
    if (!m) return { error: 'unknown_model', message: 'That model isn’t in MUSE', tried };
    const off = usable(m, o);
    if (off) return { error: 'engine_unavailable', message: `${name(m)} can’t run right now: ${off}`, tried };
    return { model: m, support: remixSupport(m, x), why: null, tried };
  }
  for (const id of autoOrder(x)) {
    const m = modelById(id);
    if (!m) { tried.push({ model: id, why: 'unknown model' }); continue; }
    const off = usable(m, o);
    if (off) { tried.push({ model: id, why: off }); continue; }
    if (o.down?.has(m.provider)) { tried.push({ model: id, why: `${m.provider} refused a run recently` }); continue; }
    return { model: m, support: remixSupport(m, x), why: whyLine(m, x), tried };
  }
  // Nothing in Auto's order runs: the first video model that does (adapted, said in the plan).
  for (const c of remixModels(x, o)) if (!c.unavailable && !o.down?.has(c.model.provider)) return { model: c.model, support: c.support, why: `${whyLine(c.model, x)} · the usual models aren’t available`, tried };
  return { error: 'nothing_fits', message: `No video model can run right now · ${tried.map(t => `${modelById(t.model)?.name ?? t.model}: ${t.why}`).join('; ')}`, tried };
}

/** What a picture group is: her images, the outfit's, a product / face / background photo. */
type Group = { kind: 'character' | 'outfit' | 'product' | 'face' | 'background'; images: { label: string; image: ImageRef }[] };

/**
 * Fills `max` picture slots: one for each group first (in order, while there is room), then the rest group by group
 * (her face front and profile before the outfit's angles, the outfit's close-ups last). Kept in group order.
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

/** The clip lengths a model takes on its route: [min, max] seconds of source (frames/words: the output's length). */
export function sourceLimits(m: ModelSpec, route: RemixRoute = routeOf(m)): [number, number] {
  if (route === 'edit') return m.edit!.sourceSeconds;
  if (route === 'reference') return [m.refs.videoSecondsMin ?? m.duration.min, Math.min(m.duration.max, m.refs.videoSecondsMax ?? m.duration.max)];
  return [m.duration.min, m.duration.max];
}

/** The part of the clip a model would use, and whether the person must trim first (owner: never cut silently). */
export function remixSpan(m: ModelSpec, clipSeconds: number, range?: [number, number] | null) {
  const route = routeOf(m);
  const [min, max] = sourceLimits(m, route);
  const from = range ? Math.max(0, Math.min(range[0], clipSeconds)) : 0;
  const to = range ? Math.max(from, Math.min(range[1], clipSeconds)) : clipSeconds;
  const seconds = Math.round((to - from) * 1000) / 1000;
  const needed = seconds > max + 0.05;
  // Frames and words make a video of at least the model's shortest length: a short clip is fine there.
  const tooShort = (route === 'edit' || route === 'reference') && seconds < min - 0.05;
  return { from, to, seconds, min, max, needed, tooShort, trimmed: !!range && (from > 0.05 || to < clipSeconds - 0.05) };
}

/** A model's output length for `seconds` of clip: inside its range, on an allowed value where it has a list. */
export function outputSeconds(m: ModelSpec, seconds: number, route: RemixRoute) {
  if (route === 'edit') return seconds;
  let s = Math.max(m.duration.min, Math.min(m.duration.max, Math.round(seconds)));
  if (m.duration.allowed?.length) s = m.duration.allowed.reduce((a, c) => (Math.abs(c - seconds) < Math.abs(a - seconds) ? c : a));
  return s;
}

export type RemixPeople = {
  /** Her (Character = her), with her outfit when Outfit is one of hers. */
  her: Character | null;
  /** Outfit is one of her outfits while Character is off or a face swap: that outfit's pictures. */
  outfitOnly: NonNullable<Character['outfit']> | null;
};

/** The person's words, one part per toggle ("Background: … Look & light: …"); what goes under CHANGE. */
export function remixWords(x: RemixToggles, her: Character | null, texts: PromptTexts, extra: string[] = []) {
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
  if (x.direction?.trim()) { const w = clean(x.direction); if (w) parts.push(`Direction: ${w}.`); }
  parts.push(...extra);
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
  const m = p.model, style = m.camera.refStyle, route = p.support.route;
  const notes: string[] = [...p.support.notes];
  // Pictures: her, the outfit, a product or face photo, the background photo (last).
  const groups: Group[] = [];
  const her = x.character?.kind === 'model' ? people.her : null;
  if (her) groups.push({ kind: 'character', images: her.images });
  if (x.character?.kind === 'face') groups.push({ kind: 'face', images: [{ label: 'face swap photo', image: x.character.image as ImageRef }] });
  const outfitSet = x.outfit?.kind === 'outfit' ? (her?.outfit ?? people.outfitOnly) : null;
  if (outfitSet) groups.push({ kind: 'outfit', images: outfitFirst(outfitSet.images) });
  if (x.outfit?.kind === 'product') groups.push({ kind: 'product', images: [{ label: 'outfit · product photo', image: x.outfit.image as ImageRef }] });
  if (x.background?.mode === 'photo') groups.push({ kind: 'background', images: [{ label: 'background', image: x.background.image as ImageRef }] });
  // Room: the model's pictures, less the clip's stills and the person's still that MUSE adds after them.
  const fr = route === 'frames' ? framesFor(m, pictureRoom(m, route)) : null;
  const personStill = route === 'edit' && !!m.edit!.needsCharacter && x.character?.kind !== 'model';
  const room = route === 'text' ? 0 : Math.max(0, pictureRoom(m, route) - (fr?.stills ?? 0) - (personStill ? 1 : 0));
  const filled = fillImages(groups, room);
  if (filled.dropped.length && room > 0 && !notes.some(n => n.includes('picture'))) notes.push(`${name(m)} takes ${room} ${room === 1 ? 'picture' : 'pictures'} here: left out ${filled.dropped.join(', ')}`);
  const refs: { label: string; role: string; image: ImageRef }[] = [];
  const tokensOf: Partial<Record<Group['kind'], string[]>> = {};
  const labelsOf: Partial<Record<Group['kind'], string[]>> = {};
  for (const g of filled.groups) {
    tokensOf[g.kind] = g.images.map(img => { refs.push({ label: img.label, role: g.kind === 'background' ? 'location' : g.kind === 'product' ? 'outfit' : 'character', image: img.image }); return token(style, 'image', refs.length); });
    labelsOf[g.kind] = g.images.map(img => img.label);
  }
  // Pictures that didn't fit are said in words, so the change still reaches the model.
  const extra: string[] = [];
  const sent = new Set(filled.groups.filter(g => g.images.length).map(g => g.kind));
  if (her && !sent.has('character')) extra.push(`Person: ${her.name}, ${her.look}.`);
  if (outfitSet && !sent.has('outfit')) extra.push(`Outfit: ${outfitSet.description || outfitSet.name}.`);
  if (x.outfit?.kind === 'product' && !sent.has('product')) extra.push(`Outfit: the garment ${x.outfit.name ? `"${x.outfit.name}"` : 'from the product photo'}.`);
  if (x.background?.mode === 'photo' && !sent.has('background')) extra.push(`Background: ${x.background.name ?? 'the new place'}.`);
  // The clip's frames (frames route) and the person's still go after the pictures; their tokens follow on.
  const stillTokens = Array.from({ length: fr?.stills ?? 0 }, (_, k) => token(style, 'image', refs.length + k + 1));
  const personTok = personStill ? token(style, 'image', refs.length + stillTokens.length + 1) : '';
  if (stillTokens.length) extra.push(`The clip’s frames are ${joinTokens(stillTokens)}: same place, people and motion as them.`);
  if (personStill) extra.push(`The person to keep is shown in ${personTok}.`);
  // Her figure (figure lock): from her outfit's body angles when one is sent, else her own body shots, else her images.
  const herTok = tokensOf.character ?? [];
  const outTok = tokensOf.outfit ?? [];
  const bodyOut = outTok.filter((_, i) => /^outfit, (front|back|side|¾)$/.test(labelsOf.outfit![i]!));
  const bodyHer = herTok.filter((_, i) => labelsOf.character![i]!.startsWith('body'));
  const figure = bodyOut.length ? bodyOut : bodyHer.length ? bodyHer : herTok;
  const words = remixWords(x, her, t, extra);
  if (words.removed.length) notes.push(`left out of your words (they would change ${her?.name}'s look): ${words.removed.join('; ')}`);
  // The clip's name in the prompt: its token when sent as a video; else words.
  const source = route === 'edit' || route === 'reference' ? token(style, 'video', 1) : fr?.start ? 'the source clip (its first frame is the start image)' : 'the source clip';
  const promptOn = !(route === 'edit' && m.edit!.prompt === false);
  const herWords = `${her?.name ?? 'her'}’s pictures`;
  let prompt = !promptOn ? '' : run('suite.remix', t, {
    inputs: { character: x.character?.kind ?? 'none', outfit: x.outfit?.kind ?? 'none', background: x.background?.mode ?? 'none', look: !!x.look },
    vars: {
      source, subject: her ? 'she' : 'the person', name: her?.name ?? '', refs: herTok.length ? joinTokens(herTok) : herWords, figureRefs: figure.length ? joinTokens(figure) : herWords,
      outfitRefs: outTok.length ? joinTokens(outTok) : 'the outfit described below', productRef: tokensOf.product?.[0] ?? 'the product photo described below',
      faceRef: tokensOf.face?.[0] ?? 'the face described below', bgRef: tokensOf.background?.[0] ?? 'the place described below', kept: keptWords(x),
    },
    direction: words.text,
  }).text;
  if (m.promptMax && prompt.length > m.promptMax) { prompt = prompt.slice(0, m.promptMax); notes.push('prompt shortened to fit'); }
  if (m.edit && !m.edit.tested) notes.push(`${name(m)} hasn’t had a test run in MUSE yet`);
  // The part of the clip used: the trimmer's range, checked against the model's length (never cut silently).
  const span = remixSpan(m, clip.seconds, r.range ?? null);
  const used = span.needed ? span.max : span.seconds; // priced at the model's maximum until trimmed
  const seconds = outputSeconds(m, used, route);
  const keepAudio = r.keepAudio ?? true;
  const res = m.resolutions.find(z => z.id === r.resolution) ?? (m.edit ? m.resolutions.find(z => z.id === m.edit!.defaultResolution) : undefined)
    ?? m.resolutions.find(z => z.id === '720p' || z.id === '768P' || z.id === '720') ?? m.resolutions.at(-1)!;
  const kind = route === 'edit' ? 'guide' : route === 'reference' ? 'ref2v' : route === 'frames' ? (fr?.start ? 'i2v' : 'ref2v') : 't2v';
  const videoIn = route === 'edit' || route === 'reference';
  const scale = o.priceScale ?? 1;
  const perSec = perSecond(m, res, { videoInput: videoIn, audio: false, kind }) * scale;
  const billed = billedSeconds(m, route === 'edit' ? Math.max(seconds, span.min) : seconds, { videoInput: videoIn, guideSeconds: used });
  const sentCount = refs.length + (fr?.stills ?? 0) + (personStill ? 1 : 0);
  const perRun = m.byo ? m.byo.perRunUsd * scale : extraPerTake(m, sentCount); // per-run price; Higgsfield H3's pictures past 5
  const estimate = Math.round((perSec * billed + perRun) * r.takes * 10000) / 10000;
  return {
    tier: r.quality, mode: 'remix', modelId: m.id, provider: m.provider, ref: refFor(m, kind), kind, resolution: res.id, seconds, aspect: r.aspectRatio,
    audio: false, takes: r.takes, seed: m.seed ? r.seed : undefined, prompt, params: {},
    images: { middle: [], refs }, videos: videoIn ? [{ video: { key: clip.key, seconds: used }, use: 'source' }] : [], speaking: false, separationUsd: 0,
    perSec, billedPerTake: billed, extraPerTake: perRun, estimate, camera: { moves: [], notes: [], usesGuide: false }, notes,
    sentImages: { images: refs.map(planRefSent), changed: false, max: Math.max(room, refs.length) },
    remix: { keepAudio, restoreAudio: keepAudio, range: span.trimmed || span.needed ? [span.from, span.needed ? span.from + span.max : span.to] : null,
      clipSeconds: clip.seconds, toggles: togglesOn(x), why: p.why, tested: m.edit?.tested ?? true, route, sourceKey: clip.key,
      ...(fr ? { frames: fr } : {}), ...(personStill ? { personStill: true } : {}),
      ...(span.needed ? { trimNeeded: true } : {}), ...(span.tooShort ? { tooShort: true } : {}), minSeconds: span.min, maxSeconds: span.max },
  };
}

/** What the apps show for a New Swap estimate: the part of the clip used, the trimmer's limits, Auto's reason, billing. */
export function remixView(plan: ShotPlan) {
  const x = plan.remix!, m = modelById(plan.modelId)!;
  const from = x.range?.[0] ?? 0, to = x.range?.[1] ?? Math.min(x.clipSeconds, x.maxSeconds);
  const inputBilled = m.id === 'genjutsu-light' ? plan.seconds : 0;
  return {
    toggles: x.toggles, why: x.why, tested: x.tested, keepAudio: x.keepAudio, route: x.route,
    uses: { from: Math.round(from * 10) / 10, to: Math.round(to * 10) / 10, of: Math.round(x.clipSeconds * 10) / 10 },
    trim: { needed: !!x.trimNeeded, tooShort: !!x.tooShort, minSeconds: x.minSeconds, maxSeconds: x.maxSeconds },
    // Seconds the provider bills: the new video, plus the clip's own seconds where it charges for them (priced into the rate otherwise).
    billedSeconds: { output: plan.seconds, input: inputBilled, inRate: m.resolutions.some(r => r.perSecWithVideo != null) },
  };
}
