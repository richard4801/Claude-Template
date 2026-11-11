// 4c · model choice for everyone (plans/HANDOVER.md 4c, owner 2026-11-11): every member sees and can pick every enabled
// video and image model, built-in or owner-added, unless the owner hides it from members (default: shown). One studio
// setting, "Show provider names to members" (default on), adds the provider company's name to what members see. Both
// live in suite_settings.models (no migration): `hidden` on a model's entry, and the studio's own entry under STUDIO_KEY.
// Keys, prices at cost, markups and licence lines stay owner only.
import { eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { badRequest } from '../errors.js';
import { suiteSettings } from '../suite/schema.js';

/** The studio's own entry in suite_settings.models (never a model id: ids are "kling-v4", "owner/name", "c_…"). */
export const STUDIO_KEY = '$studio';

export type MemberRules = { showProviderNames: boolean; hidden: Set<string> };

type Models = Record<string, { hidden?: boolean; showProviderNames?: boolean } & Record<string, unknown>>;

export function rulesOf(models: Models | null | undefined): MemberRules {
  const m = models ?? {};
  return {
    showProviderNames: m[STUDIO_KEY]?.showProviderNames !== false,
    hidden: new Set(Object.entries(m).filter(([k, v]) => k !== STUDIO_KEY && v?.hidden === true).map(([k]) => k)),
  };
}

async function row(ctx: Pick<Ctx, 'db'>, studioId: string): Promise<Models> {
  const [r] = await ctx.db.select({ m: suiteSettings.models }).from(suiteSettings).where(eq(suiteSettings.studioId, studioId));
  return (r?.m ?? {}) as Models;
}

export async function memberRules(ctx: Pick<Ctx, 'db'>, studioId: string): Promise<MemberRules> {
  return rulesOf(await row(ctx, studioId));
}

/** Writes the owner's member switches (validated by the caller): the studio setting and per-model hide flags. */
export async function saveMemberRules(ctx: Pick<Ctx, 'db'>, u: AuthUser, change: { showProviderNames?: boolean; hidden?: Record<string, boolean> }) {
  const models: Models = { ...(await row(ctx, u.studioId)) };
  if (change.showProviderNames !== undefined) models[STUDIO_KEY] = { ...(models[STUDIO_KEY] ?? {}), showProviderNames: change.showProviderNames };
  for (const [id, hide] of Object.entries(change.hidden ?? {})) {
    if (id === STUDIO_KEY) throw badRequest('Unknown model');
    const { hidden: _h, ...rest } = models[id] ?? {};
    models[id] = hide ? { ...rest, hidden: true } : rest;
    if (!hide && !Object.keys(models[id]!).length) delete models[id];
  }
  const now = Date.now();
  await ctx.db.insert(suiteSettings).values({ studioId: u.studioId, models: models as never, updatedBy: u.id, updatedAt: now })
    .onConflictDoUpdate({ target: suiteSettings.studioId, set: { models: models as never, updatedBy: u.id, updatedAt: now } });
}

/** The provider company's name as members see it. */
const LABELS: Record<string, string> = { replicate: 'Replicate', fal: 'fal', higgsfield: 'Higgsfield', muapi: 'Muapi', runpod: 'MUSE', byo: 'Custom' };
export const providerLabel = (p: string) => LABELS[p] ?? p.charAt(0).toUpperCase() + p.slice(1);
