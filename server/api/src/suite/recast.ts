// AI suite · Recast ("same take, new cast"): replace up to 4 people in one source clip with studio characters,
// keeping motion, camera, cuts and the original sound. Pure planning (no database), like plan.ts: model pick on the
// recast ladder, each person's reference subset, who-is-who words, the suite.recast prompt script, inputs and price.
import type { ImageRef } from '../db/schema.js';
import { sanitizeDirection } from '../prompt/engine.js';
import { stripMoveTokens } from './camera.js';
import { DEFAULT_TEXTS, type PromptTexts } from '../prompt/library.js';
import { run } from '../prompt/scripts/builders.js';
import { applySent, type Resolved } from '../images/sent.js';
import { badRequest } from '../errors.js';
import { billedSeconds, joinTokens, perSecond, planRefSent, sentPlanRef, token, type Character, type ShotPlan, type ShotRequest, type SuitePrefs } from './plan.js';
import { modelById, RECAST_LADDER, refFor, type LadderStep, type ModelSpec, type ProviderId, type Resolution, type Tier } from './registry.js';

export type CastIn = NonNullable<ShotRequest['cast']>[number];
export type CastMember = { cast: CastIn; character: Character; speaking: 'yes' | 'no' | 'unknown' };
export type RecastNeed = { people: number; seconds: number; crops: number };
export type RecastPick = { model: ModelSpec; resolution: Resolution; tried: { model: string; resolution: string; why: string }[] };

const ORDINAL = ['first', 'second', 'third', 'fourth'];
const HINT_RANK: Record<string, number> = { left: 1, first: 1, foreground: 1, center: 2, second: 2, right: 3, third: 3, background: 3, fourth: 4 };
const HINT_WORDS: Record<string, string> = {
  left: 'the person on the left', center: 'the person in the centre', right: 'the person on the right', foreground: 'the person in the foreground',
  background: 'the person in the background', first: 'the first person to appear', second: 'the second person to appear', third: 'the third person to appear',
  fourth: 'the fourth person to appear',
};

/** Who in the clip, in words ("the person on the left (the woman in the red coat)"). */
export function whoWords(c: CastIn, i: number) {
  const base = c.personHint ? HINT_WORDS[c.personHint]! : c.personIndex ? `the ${ORDINAL[c.personIndex - 1]} person (from the left, or to appear)` : `the ${ORDINAL[i]} person (from the left, or to appear)`;
  return c.personNote?.trim() ? `${base} (${c.personNote.trim().replace(/[{}]/g, '')})` : base;
}

/** The cast in the clip's order (index, then position hint, then as given): models map references left to right. */
export function castOrder<T extends { cast: CastIn }>(members: T[]): T[] {
  return members.map((m, i) => ({ m, i, k: m.cast.personIndex ?? (m.cast.personHint ? HINT_RANK[m.cast.personHint]! : 5 + i) }))
    .sort((a, b) => a.k - b.k || a.i - b.i).map(x => x.m);
}

/** Why `m` can't recast this clip, or null. */
export function recastFit(m: ModelSpec, resolution: string, n: RecastNeed): string | null {
  const r = m.recast;
  if (!r || !m.modes.recast) return 'no recast';
  if (m.status === 'removed') return 'removed';
  if (m.licence.blockNewFeatures) return 'licence';
  if (!m.resolutions.some(x => x.id === resolution)) return `no ${resolution}`;
  if (n.people > r.maxPeople) return `at most ${r.maxPeople} ${r.maxPeople === 1 ? 'person' : 'people'}`;
  if (n.seconds < r.sourceSeconds[0] - 0.05 || n.seconds > r.sourceSeconds[1] + 0.05) return `clips ${r.sourceSeconds[0]}–${r.sourceSeconds[1]} s`;
  if (n.people > r.totalImages) return 'not enough reference images';
  return null;
}

export function pickRecast(tier: Tier, n: RecastNeed, o: { prefs?: SuitePrefs; providers: Set<ProviderId>; engineModel?: string; resolution?: string }): RecastPick | { error: string; tried: RecastPick['tried'] } {
  const ladder: LadderStep[] = o.engineModel ? [{ model: o.engineModel, resolution: o.resolution ?? modelById(o.engineModel)?.resolutions.at(-1)?.id ?? '' }] : RECAST_LADDER[tier];
  const tried: RecastPick['tried'] = [];
  for (const step of ladder) {
    const m = modelById(step.model);
    if (!m) { tried.push({ ...step, why: 'unknown model' }); continue; }
    const pref = o.prefs?.models?.[m.id];
    if (pref?.enabled === false) { tried.push({ ...step, why: 'switched off' }); continue; }
    if (m.licence.requiresAck && !pref?.acknowledgedAt) { tried.push({ ...step, why: 'licence not acknowledged' }); continue; }
    if (!o.providers.has(m.provider)) { tried.push({ ...step, why: `${m.provider} not set up` }); continue; }
    const why = recastFit(m, step.resolution, n);
    if (why) { tried.push({ ...step, why }); continue; }
    return { model: m, resolution: m.resolutions.find(x => x.id === step.resolution)!, tried };
  }
  return { error: 'nothing_fits', tried };
}

/** A character's images for recast, best first: dressed in the outfit (full body), then her face, then the rest. */
function personImages(c: Character, n: number) {
  const all = [...(c.outfit?.images ?? []), ...c.images];
  const prio = ['outfit, front', 'face, front', 'body, front', 'face, profile', 'outfit, ¾', 'body, ¾', 'face, ¾', 'outfit, back', 'body, back', 'outfit, side', 'body, side'];
  const rank = (l: string) => { const i = prio.indexOf(l); return i < 0 ? 99 : i; };
  // Without an outfit the full-body front shows face and clothes in one photo: best for one-photo models.
  const best = [...all].sort((a, b) => rank(a.label) - rank(b.label));
  if (n === 1 && !c.outfit?.images.length) { const body = all.find(x => x.label === 'body, front'); if (body) return [body]; }
  return best.slice(0, n);
}

export function buildRecastPlan(r: ShotRequest, members: CastMember[], p: RecastPick, clip: { key: string; seconds: number },
  o: { texts?: PromptTexts; priceScale?: number; sent?: Resolved | null }): ShotPlan {
  const t = o.texts ?? DEFAULT_TEXTS;
  const m = p.model, rc = m.recast!, notes: string[] = [];
  const style = m.camera.refStyle;
  const ordered = castOrder(members);
  // Images: one budget per person, plus face crops where the model takes them.
  const crops = rc.faceCrops ? ordered.filter(x => x.cast.faceCrop).length : 0;
  if (!rc.faceCrops && ordered.some(x => x.cast.faceCrop)) notes.push('face crops are not sent on this quality: who-is-who goes by position and order');
  const per = Math.max(1, Math.min(rc.refsPerPerson, Math.floor((rc.totalImages - crops) / ordered.length)));
  const refs: { label: string; role: string; image: ImageRef }[] = [];
  // Images sent (images/sent.ts): changeable when one person is recast (her images, within the model's budget).
  let chosen: { label: string; image: ImageRef }[] | null = null;
  if (ordered.length === 1) {
    const c = ordered[0]!.character;
    const view = applySent(personImages(c, per).map(img => planRefSent({ ...img, role: 'character' })), o.sent, Math.max(1, rc.totalImages - crops), { min: 1 });
    if (view.changed) chosen = view.images.map(x => sentPlanRef(x, [...(c.outfit?.images ?? []), ...c.images]));
  } else if (o.sent && !o.sent.reset) throw badRequest('The images sent can be changed when one person is recast');
  const people = ordered.map((x, i) => {
    const imgs = i === 0 && chosen ? chosen : personImages(x.character, per);
    const start = refs.length;
    imgs.forEach(img => refs.push({ label: `person ${i + 1} · ${img.label}`, role: 'character', image: img.image }));
    const tokens = imgs.map((_, k) => token(style, 'image', start + k + 1));
    let faceRef = '';
    if (crops && x.cast.faceCrop) { refs.push({ label: `person ${i + 1} · face crop`, role: 'crop', image: x.cast.faceCrop as ImageRef }); faceRef = token(style, 'image', refs.length); }
    const outfitTok = imgs.map((img, k) => (img.label.startsWith('outfit') ? tokens[k]! : '')).filter(Boolean);
    const o2 = x.character.outfit;
    return {
      who: whoWords(x.cast, i), name: x.character.name, refs: style === 'none' ? 'the character image' : joinTokens(tokens), look: x.character.look,
      outfit: o2 ? ` She wears ${o2.description || o2.name}${outfitTok.length && style !== 'none' ? ` (${joinTokens(outfitTok)})` : ''}.` : '',
      never: x.character.neverAdd.length ? ` She never has: ${x.character.neverAdd.join(', ')}.` : '', faceRef, speaking: x.speaking,
    };
  });
  // The user's words: sanitised against every recast character's identity and never-add list.
  let direction = stripMoveTokens([r.prompt, r.direction].map(x => (x ?? '').trim()).filter(Boolean).join(' '), []);
  for (const x of ordered) {
    const s = sanitizeDirection(direction, { name: x.character.name, look: x.character.look, neverAdd: x.character.neverAdd }, t);
    if (s.removed.length) notes.push(`left out of the direction (it would change ${x.character.name}'s look): ${s.removed.join('; ')}`);
    direction = s.clean;
  }
  const source = style === 'photo' ? 'the source video' : style === 'none' ? 'the source video' : token(style, 'video', 1);
  let prompt = run('suite.recast', t, {
    inputs: { people, several: people.length > 1, keepsCuts: rc.keepsCuts },
    vars: { source, count: people.length === 1 ? 'one person' : `${people.length} people` },
    direction,
  }).text;
  if (m.promptMax && prompt.length > m.promptMax) { prompt = prompt.slice(0, m.promptMax); notes.push('prompt shortened to fit'); }
  if (!rc.keepsCuts) notes.push('this quality may not keep every cut of a multi-shot clip');
  if (rc.maxShotSeconds) notes.push(`no single shot in the clip may be longer than ${rc.maxShotSeconds} s`);
  const keepAudio = r.keepAudio ?? true;
  const seconds = Math.round(clip.seconds * 1000) / 1000;
  const perSec = perSecond(m, p.resolution, { videoInput: true, audio: false, kind: 'recast' }) * (o.priceScale ?? 1);
  const billed = billedSeconds(m, Math.max(seconds, m.recast?.sourceSeconds[0] ?? 0), { videoInput: true, guideSeconds: seconds });
  const estimate = Math.round(perSec * billed * r.takes * 10000) / 10000;
  return {
    tier: r.quality, mode: 'recast', modelId: m.id, provider: m.provider, ref: refFor(m, 'guide'), kind: 'guide', resolution: p.resolution.id, seconds, aspect: r.aspectRatio,
    audio: keepAudio, takes: r.takes, seed: m.seed ? r.seed : undefined, prompt, params: {},
    images: { middle: [], refs }, videos: [{ video: { key: clip.key, seconds }, use: 'source' }], speaking: ordered.some(x => x.speaking === 'yes'), separationUsd: 0,
    perSec, billedPerTake: billed, extraPerTake: 0, estimate, camera: { moves: [], notes: [], usesGuide: false }, notes,
    sentImages: { images: refs.map(planRefSent), changed: !!chosen, ...(chosen ? { changedBy: o.sent!.by } : {}), max: Math.max(1, rc.totalImages - crops) },
    recast: { keepAudio, restoreAudio: keepAudio && !rc.keepsAudio, people: ordered.map((x, i) => ({ characterId: x.cast.characterId, outfitId: x.cast.outfitId, who: people[i]!.who, speaking: x.speaking })) },
  };
}
