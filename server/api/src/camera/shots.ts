// Shot drafts from a camera session: an estimate only. Nothing here holds money, writes the ledger or calls a provider;
// the owner presses Generate in the app (workstream 1's Shot API runs it). When the suite's Shot API is merged
// (ctx.suite.shots.createDraft) the draft is made there; until then a local draft is priced from the target's $/s.
import type { AuthUser, Ctx } from '../ctx.js';
import { round2, uid } from '../lib/util.js';
import type { ShotDraftRow } from './schema.js';
import { CAMERA_TARGETS } from '../suite/registry.js';
import { ApiError } from '../errors.js';

export const DEFAULT_TARGET = 'kling-v4.0';
/** List $/s with a guide video as input (research §3.2, 2026-11-05). Owner-only plumbing: never shown to members. */
export const TARGET_PRICE_PER_SEC: Record<string, number> = {
  'kling-v4.0': 0.141,
  'kling-v3-omni': 0.168,
  'minimax-h3': 0.08,
  'h3-max-3d-to-video': 0.08,
  'seedance-2.5': 0.968,
  'veo-3.1-lite': 0.08,
  'wan-vace-depth': 0.08,
};

export type DraftInput = { prompt: string; targetModel: string; durationSec: number; aspect: string; camera: Record<string, unknown>;
  characters: { modelId: string; role?: string }[]; cameraSessionId: string;
  /** Storage key of the newest ready greybox (registered in uploads), and presigned URLs of the keyframe stills. */
  guide?: { videoKey?: string; seconds?: number; start?: string; middle?: string; end?: string } };

/** Workstream 1's suite service (plans/api.md "AI suite"): estimate(user, ShotRequest) holds and runs nothing. */
type Suite = { estimate: (u: AuthUser, body: unknown) => Promise<{ estimate?: number; priceLine?: string; warnings?: string[]; ok?: boolean; message?: string }> };
const SUITE_ASPECTS = ['9:16', '16:9', '1:1', '4:3', '3:4', '21:9'];

/** The suite's ShotRequest for this draft; the app sends it to POST /v1/suite/shots when the owner presses Generate. */
export function shotRequest(d: DraftInput) {
  const g = d.guide ?? {};
  const keyframes = g.start || g.middle || g.end ? { ...(g.start ? { start: g.start } : {}), ...(g.middle ? { middle: [g.middle] } : {}), ...(g.end ? { end: g.end } : {}) } : undefined;
  // The draft is priced and run on its target model (camera sessions are owner-only, so the engine pick is allowed).
  const target = CAMERA_TARGETS[d.targetModel];
  return {
    quality: 'cinema', ...(target ? { engineModel: target.model, resolution: target.resolution } : {}),
    prompt: d.prompt.slice(0, 2000), duration: Math.max(2, Math.min(30, Math.round(d.durationSec))), aspectRatio: SUITE_ASPECTS.includes(d.aspect) ? d.aspect : '9:16',
    ...(d.characters[0] ? { modelId: d.characters[0].modelId } : {}),
    camera: { mode: 'directed', ...(g.videoKey ? { guide: { video: { key: g.videoKey, ...(g.seconds ? { seconds: g.seconds } : {}) }, use: 'blocking', cameraSessionId: d.cameraSessionId, ...(keyframes ? { keyframes } : {}) } } : {}) },
  };
}

export async function createShotDraft(ctx: Ctx, user: AuthUser, d: DraftInput): Promise<ShotDraftRow> {
  const suite = (ctx as unknown as { suite?: Partial<Suite> }).suite;
  const tokensOf = (usd: number) => Math.ceil(usd / ctx.config.TOKEN_USD - 1e-9);
  const base = { id: uid('sd'), state: 'draft' as const, prompt: d.prompt, targetModel: d.targetModel, durationSec: d.durationSec, aspect: d.aspect, camera: d.camera, createdAt: Date.now() };
  if (typeof suite?.estimate === 'function') {
    let request: Record<string, unknown> = shotRequest(d);
    let fallback: string | null = null;
    let r: Awaited<ReturnType<Suite['estimate']>>;
    try { r = await suite.estimate(user, request); }
    catch (e) {
      // The target can't make this shot here (not set up, too long, …): price it on the Cinema ladder instead, and say so.
      if (!(e instanceof ApiError) || e.code !== 'nothing_fits' || !request.engineModel) throw e;
      const { engineModel: _m, resolution: _r, ...rest } = request;
      request = rest;
      fallback = `${d.targetModel} can't make this shot right now · priced on the best available model`;
      r = await suite.estimate(user, request);
    }
    const usd = round2(Number(r.estimate ?? 0));
    return { ...base, source: 'suite', estimate: { usd, tokens: tokensOf(usd) }, request, ...(r.warnings?.length || fallback ? { warnings: [...(fallback ? [fallback] : []), ...(r.warnings ?? [])] } : {}) };
  }
  const perSec = TARGET_PRICE_PER_SEC[d.targetModel] ?? TARGET_PRICE_PER_SEC[DEFAULT_TARGET]!;
  const usd = round2(perSec * d.durationSec);
  return { ...base, source: 'camera', estimate: { usd, tokens: tokensOf(usd) }, request: shotRequest(d) };
}
