// Shot drafts from a camera session: an estimate only. Nothing here holds money, writes the ledger or calls a provider;
// the owner presses Generate in the app (workstream 1's Shot API runs it). When the suite's Shot API is merged
// (ctx.suite.shots.createDraft) the draft is made there; until then a local draft is priced from the target's $/s.
import type { AuthUser, Ctx } from '../ctx.js';
import { round2, uid } from '../lib/util.js';
import type { ShotDraftRow } from './schema.js';

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
  characters: { modelId: string; role?: string }[]; cameraSessionId: string };

type SuiteShots = { createDraft: (u: AuthUser, d: DraftInput) => Promise<{ id: string; estimate: { usd: number; tokens?: number } }> };

export async function createShotDraft(ctx: Ctx, user: AuthUser, d: DraftInput): Promise<ShotDraftRow> {
  const suite = (ctx as unknown as { suite?: { shots?: Partial<SuiteShots> } }).suite;
  const tokensOf = (usd: number) => Math.ceil(usd / ctx.config.TOKEN_USD - 1e-9);
  const base = { state: 'draft' as const, prompt: d.prompt, targetModel: d.targetModel, durationSec: d.durationSec, aspect: d.aspect, camera: d.camera, createdAt: Date.now() };
  if (typeof suite?.shots?.createDraft === 'function') {
    const r = await suite.shots.createDraft(user, d);
    return { ...base, id: r.id, source: 'suite', estimate: { usd: round2(r.estimate.usd), tokens: r.estimate.tokens ?? tokensOf(r.estimate.usd) } };
  }
  const perSec = TARGET_PRICE_PER_SEC[d.targetModel] ?? TARGET_PRICE_PER_SEC[DEFAULT_TARGET]!;
  const usd = round2(perSec * d.durationSec);
  return { ...base, id: uid('sd'), source: 'camera', estimate: { usd, tokens: tokensOf(usd) } };
}
