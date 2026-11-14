// AI suite · one model, several providers (owner 2026-11-14: "I should have options. Right now I'm tied to using a certain
// model for a certain quality"). A public model (the registry head) may have ROUTES: the same model on another provider
// (registry `family`). The pickers list the head once with the UNION of its routes' resolutions; each resolution runs on
// the cheapest route that makes it for the shot, and a route that refuses at start hands the shot to another route at
// the same resolution (runner). Pure functions over the registry, shared by the planner, the catalogs and the runner.
import { buildInput, type MediaUrls } from './inputs.js';
import type { ShotPlan } from './plan.js';
import { modelById, routesOf, type ModelSpec, type ProviderId, type Resolution } from './registry.js';

/** Dollars per second a route is known to cost at a resolution; null when it is priced live (unknown until quoted). */
export type RateFn = (m: ModelSpec, resolution: string) => number | null;
export const staticRate: RateFn = (m, res) => (m.livePrice ? null : m.resolutions.find(r => r.id === res)?.perSec ?? null);

/** Cheapest first: known prices ascending, then the live-priced routes; the head before its routes on a tie. */
export function byPrice(list: ModelSpec[], resolution: string, rate: RateFn = staticRate): ModelSpec[] {
  const key = (m: ModelSpec) => rate(m, resolution) ?? Infinity;
  return list.map((m, i) => ({ m, i })).sort((a, b) => key(a.m) - key(b.m) || a.i - b.i).map(x => x.m);
}

/** The routes of `id`'s model that make `resolution`, cheapest first, among those `usable` allows. */
export function routesAt(id: string, resolution: string, usable: (m: ModelSpec) => boolean = () => true, rate: RateFn = staticRate): ModelSpec[] {
  return byPrice(routesOf(id).filter(m => usable(m) && m.resolutions.some(r => r.id === resolution)), resolution, rate);
}

/** Whether a model has more than one provider route. */
export const hasRoutes = (id: string) => routesOf(id).length > 1;

/** One resolution of a public model: the route (and provider) it runs on, and that route's $/s (null = priced live). */
export type RouteResolution = Resolution & { model: string; provider: ProviderId; livePrice: boolean; rate: number | null };

/**
 * A model's resolutions across its usable routes, smallest first: each at its cheapest route (known prices beat live
 * ones; `rate` may know a live route's quoted price). Same ids on two routes merge (1080p on Replicate and Higgsfield).
 */
export function unionResolutions(id: string, usable: (m: ModelSpec) => boolean = () => true, rate: RateFn = staticRate): RouteResolution[] {
  const specs = routesOf(id).filter(usable);
  const ids: Resolution[] = [];
  for (const m of specs) for (const r of m.resolutions) if (!ids.some(x => x.id === r.id)) ids.push(r);
  return ids.map(r => {
    const m = byPrice(specs.filter(s => s.resolutions.some(x => x.id === r.id)), r.id, rate)[0]!;
    const own = m.resolutions.find(x => x.id === r.id)!;
    return { ...own, model: m.id, provider: m.provider, livePrice: !!m.livePrice, rate: rate(m, r.id) };
  }).sort((a, b) => a.shortSide - b.shortSide);
}

const uniq = <T>(a: T[]) => [...new Set(a)];
/**
 * The model as one entry for the pickers: the head's identity with the union of its usable routes' limits (modes, frames,
 * references, lengths, shapes, resolutions). Undefined when none of its routes is usable.
 */
export function familySpec(id: string, usable: (m: ModelSpec) => boolean = () => true, rate: RateFn = staticRate): ModelSpec | undefined {
  const all = routesOf(id);
  const specs = all.filter(usable);
  if (!specs.length) return undefined;
  if (all.length === 1) return specs[0];
  const head = all[0]!;
  const allowed = specs.every(m => m.duration.allowed) ? uniq(specs.flatMap(m => m.duration.allowed!)).sort((a, b) => a - b) : undefined;
  return {
    ...head,
    modes: { text: specs.some(m => m.modes.text), image: specs.some(m => m.modes.image), reference: specs.some(m => m.modes.reference),
      guide: specs.some(m => m.modes.guide), recast: specs.some(m => m.modes.recast) },
    frames: { start: specs.some(m => m.frames.start), end: specs.some(m => m.frames.end), middle: Math.max(...specs.map(m => m.frames.middle)), withRefs: specs.some(m => m.frames.withRefs) },
    refs: { images: Math.max(...specs.map(m => m.refs.images)), videos: Math.max(...specs.map(m => m.refs.videos)), audios: Math.max(...specs.map(m => m.refs.audios)) },
    duration: { min: Math.min(...specs.map(m => m.duration.min)), max: Math.max(...specs.map(m => m.duration.max)), ...(allowed ? { allowed } : {}) },
    aspectRatios: uniq(specs.flatMap(m => m.aspectRatios)),
    resolutions: unionResolutions(id, usable, rate).map(({ model: _m, provider: _p, livePrice: _l, rate: _r, ...r }) => r),
    extend: head.extend ?? specs.find(m => m.extend)?.extend,
  };
}

/** Whether `m` can take what a planned shot sends (its endpoint kind, frames, pictures, videos, audio). */
function takesPlan(m: ModelSpec, p: Pick<ShotPlan, 'kind' | 'images' | 'videos' | 'audioRef'>): boolean {
  if (p.kind === 't2v' && !m.modes.text) return false;
  if (p.kind === 'i2v' && (!m.modes.image || (p.images.start && !m.frames.start) || (p.images.end && !m.frames.end) || (p.images.end && !p.images.start && m.frames.endNeedsStart))) return false;
  if (p.kind === 'ref2v' && !(m.modes.reference || m.extend)) return false;
  if (p.kind === 'guide' && !m.modes.guide) return false;
  if (p.images.middle.length > (m.modes.image ? m.frames.middle : 0)) return false;
  return p.images.refs.length <= m.refs.images && p.videos.length <= m.refs.videos && (!p.audioRef || m.refs.audios > 0);
}

/**
 * Where a planned shot goes when its provider refuses at start (no credit, bad key, busy, down): another route of the
 * same model at the same resolution that takes the same inputs and reads the same prompt (reference words), cheapest
 * first; null when there is none. `ok`: the route's provider is set up (and the owner hasn't switched it off).
 */
export function fallbackRoute(m: ModelSpec, plan: Pick<ShotPlan, 'resolution' | 'kind' | 'images' | 'videos' | 'audioRef'>, ok: (m: ModelSpec) => boolean): ModelSpec | null {
  const others = routesOf(m.id).filter(x => x.id !== m.id && x.provider !== m.provider && ok(x) && x.camera.refStyle === m.camera.refStyle
    && x.resolutions.some(r => r.id === plan.resolution) && takesPlan(x, plan));
  return byPrice(others, plan.resolution)[0] ?? null;
}

/** Placeholder media for a free price quote (the estimate prices the request; it fetches nothing). */
const SAMPLE = { image: 'https://example.com/muse-estimate.jpg', video: 'https://example.com/muse-estimate.mp4', audio: 'https://example.com/muse-estimate.wav' };
/** The body to quote a planned shot with: the route's real request, its media replaced by placeholders. */
export function quoteBody(m: ModelSpec, plan: ShotPlan): Record<string, unknown> {
  const u: MediaUrls = {
    ...(plan.images.start || plan.remix?.frames?.start ? { start: SAMPLE.image } : {}), ...(plan.images.end || plan.remix?.frames?.end ? { end: SAMPLE.image } : {}),
    middle: plan.images.middle.map(() => SAMPLE.image), refs: Array.from({ length: plan.images.refs.length + (plan.remix?.personStill ? 1 : 0) }, () => SAMPLE.image),
    videos: plan.videos.map(() => SAMPLE.video), ...(plan.audioRef ? { audio: SAMPLE.audio } : {}),
  };
  return buildInput(m, { ...plan, prompt: 'x' }, u);
}

/** A bare plan to quote one resolution of a route for the pickers: a 5 s text shot (or a start frame), with sound. */
export function samplePlan(m: ModelSpec, resolution: string): ShotPlan {
  const kind = m.modes.text ? 't2v' : 'i2v';
  const seconds = Math.max(m.duration.min, Math.min(m.duration.max, m.duration.allowed?.[0] ?? 5));
  return { tier: 'standard', mode: kind === 't2v' ? 'text' : 'image', modelId: m.id, provider: m.provider, ref: '', kind, resolution, seconds, aspect: m.aspectRatios.includes('9:16') ? '9:16' : m.aspectRatios[0] ?? '9:16',
    audio: m.audio !== 'none', takes: 1, prompt: 'x', params: {}, images: { middle: [], refs: [], ...(kind === 'i2v' ? { start: { url: SAMPLE.image } } : {}) }, videos: [],
    speaking: false, separationUsd: 0, perSec: 0, billedPerTake: seconds, extraPerTake: 0, estimate: 0, camera: { moves: [], notes: [], usesGuide: false }, notes: [] };
}

/** "replicate+higgsfield": one provider key for a model shown with several (engines/labels.ts reads it). */
export const providersKey = (ps: ProviderId[]) => uniq(ps).join('+');

/** The head of a model's family, if it is known. */
export const headOf = (id: string) => routesOf(id)[0] ?? modelById(id);
