// AI suite · Extend (a longer take from a finished one). Pure planning, like recast.ts: the model pick on the extend
// ladder, how the source is used (the clip itself, the clip as a reference, or a frame bridge), the prompt, the price.
// The runner prepares the media (trims the source, grabs the bridge frame) and joins source + extension.
import { DEFAULT_TEXTS, fill, type PromptTexts } from '../prompt/library.js';
import { stripMoveTokens } from './camera.js';
import { billedSeconds, perSecond, token, type ShotPlan, type ShotRequest, type SuitePrefs } from './plan.js';
import { EXTEND_LADDER, modelById, refFor, type LadderStep, type ModelSpec, type ProviderId, type Resolution, type Tier } from './registry.js';

export type Direction = 'after' | 'before';
export type ExtendMethod = 'clip' | 'reference' | 'frame';
export type ExtendNeed = { direction: Direction; sourceSeconds: number; seconds: number; aspect: string };
export type ExtendPick = { model: ModelSpec; resolution: Resolution; method: ExtendMethod; seconds: number; tried: { model: string; resolution: string; why: string }[] };

/** How `m` extends in this direction, or null. */
export const extendMethod = (m: ModelSpec, d: Direction): ExtendMethod | null => (d === 'after' ? m.extend?.after : m.extend?.before) ?? null;

/** Why `m` can't extend this clip, or null; and the length it would render. */
export function extendFit(m: ModelSpec, resolution: string, n: ExtendNeed): { why: string | null; seconds: number } {
  let seconds = Math.max(m.duration.min, Math.min(n.seconds, m.duration.max));
  if (m.duration.allowed) seconds = m.duration.allowed.reduce((p, c) => (Math.abs(c - n.seconds) < Math.abs(p - n.seconds) ? c : p));
  const no = (why: string) => ({ why, seconds });
  const method = extendMethod(m, n.direction);
  if (!m.extend || !method) return no(n.direction === 'before' ? 'no extend before' : 'no extend');
  if (m.status === 'removed') return no('removed');
  if (m.licence.blockNewFeatures) return no('licence');
  if (!m.resolutions.some(x => x.id === resolution)) return no(`no ${resolution}`);
  if (n.sourceSeconds < m.extend.sourceSeconds[0] - 0.05) return no(`source at least ${m.extend.sourceSeconds[0]} s`);
  if (n.seconds > m.duration.max || n.seconds < m.duration.min - 1) return no(`length ${m.duration.min}–${m.duration.max} s`);
  return { why: null, seconds };
}

export function pickExtend(tier: Tier, n: ExtendNeed, o: { prefs?: SuitePrefs; providers: Set<ProviderId>; engineModel?: string; resolution?: string }): ExtendPick | { error: string; tried: ExtendPick['tried'] } {
  const ladder: LadderStep[] = o.engineModel ? [{ model: o.engineModel, resolution: o.resolution ?? modelById(o.engineModel)?.resolutions.at(-1)?.id ?? '' }] : EXTEND_LADDER[tier];
  const tried: ExtendPick['tried'] = [];
  for (const step of ladder) {
    const m = modelById(step.model);
    if (!m) { tried.push({ ...step, why: 'unknown model' }); continue; }
    const pref = o.prefs?.models?.[m.id];
    if (pref?.enabled === false) { tried.push({ ...step, why: 'switched off' }); continue; }
    if (m.licence.requiresAck && !pref?.acknowledgedAt) { tried.push({ ...step, why: 'licence not acknowledged' }); continue; }
    if (!o.providers.has(m.provider)) { tried.push({ ...step, why: `${m.provider} not set up` }); continue; }
    const f = extendFit(m, step.resolution, n);
    if (f.why) { tried.push({ ...step, why: f.why }); continue; }
    return { model: m, resolution: m.resolutions.find(x => x.id === step.resolution)!, method: extendMethod(m, n.direction)!, seconds: f.seconds, tried };
  }
  return { error: 'nothing_fits', tried };
}

export function buildExtendPlan(r: ShotRequest, p: ExtendPick, source: { key: string; seconds: number }, o: { texts?: PromptTexts; priceScale?: number }): ShotPlan {
  const t = o.texts ?? DEFAULT_TEXTS;
  const m = p.model, d = r.extend!.direction, notes: string[] = [];
  const direction = stripMoveTokens([r.prompt, r.direction].map(x => (x ?? '').trim()).filter(Boolean).join(' '), [])
    || (d === 'after' ? 'the action carries on naturally' : 'the action leads naturally into it');
  // How much of the source is sent: the model's range (Wan takes 2–10 s: the last 10 s of a longer clip).
  const useSeconds = p.method === 'frame' ? 0 : Math.min(source.seconds, m.extend!.sourceSeconds[1]);
  if (p.method !== 'frame' && source.seconds > m.extend!.sourceSeconds[1] + 0.05) notes.push(`only the ${d === 'after' ? 'last' : 'first'} ${m.extend!.sourceSeconds[1]} s of the clip are sent to continue from`);
  if (p.method === 'frame') notes.push(d === 'after' ? 'continues from the clip’s last frame' : 'ends on the clip’s first frame');
  if (p.seconds !== r.duration) notes.push(`length set to ${p.seconds} s (this quality makes ${m.duration.allowed?.join(', ') ?? `${m.duration.min}–${m.duration.max}`} s)`);
  const src = p.method === 'reference' ? token(m.camera.refStyle, 'video', 1) : 'the source clip';
  const key = p.method === 'frame' ? `suite.extend.${d}.frame` : `suite.extend.${d}`;
  let prompt = fill(t[key] ?? DEFAULT_TEXTS[key]!, { source: src, direction });
  if (m.promptMax && prompt.length > m.promptMax) { prompt = prompt.slice(0, m.promptMax); notes.push('prompt shortened to fit'); }
  const videoInput = p.method !== 'frame';
  const perSec = perSecond(m, p.resolution, { videoInput, audio: r.audio, kind: p.method === 'clip' ? 'i2v' : p.method === 'frame' ? 'i2v' : 'ref2v' }) * (o.priceScale ?? 1);
  const billed = billedSeconds(m, p.seconds, { videoInput, guideSeconds: useSeconds });
  const estimate = Math.round(perSec * billed * r.takes * 10000) / 10000;
  const kind = p.method === 'reference' ? 'ref2v' : 'i2v';
  return {
    tier: r.quality, mode: 'extend', modelId: m.id, provider: m.provider, ref: refFor(m, kind), kind, resolution: p.resolution.id, seconds: p.seconds, aspect: r.aspectRatio,
    audio: r.audio, takes: r.takes, seed: m.seed ? r.seed : undefined, prompt, params: {},
    images: { middle: [], refs: [] }, videos: p.method === 'frame' ? [] : [{ video: { key: source.key, seconds: useSeconds }, use: 'source' }],
    speaking: false, separationUsd: 0, perSec, billedPerTake: billed, extraPerTake: 0, estimate, camera: { moves: [], notes: [], usesGuide: false }, notes,
    extend: { direction: d, method: p.method, source, join: r.extend!.join, useSeconds },
  };
}
