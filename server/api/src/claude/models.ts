// One Claude, step 6b (plans/one-claude.md): the Claude model a chat uses, picked per chat by anyone (owner and
// members), with a per-person default. Everyone runs Claude on their own Claude plan (Claude Code on their Mac takes
// --model), so "cost" here is how fast a model uses up the person's plan; on the owner-only in-app chat it is what the
// studio's Claude key pays per message. Speed and cost are said in plain words.
import { eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { badRequest } from '../errors.js';
import { claudePrefs } from './schema.js';

export type ClaudeModel = { id: string; name: string; speed: string; cost: string; good: string };

/** Newest first in each family; prices relative to Opus (API list prices per million tokens: Fable $8/$40, Opus $4/$20, Sonnet $2/$10, Haiku $0.10/$0.50). */
export const CLAUDE_MODELS: ClaudeModel[] = [
  { id: 'claude-fable-5-2', name: 'Claude Fable 5.2', speed: 'Slowest', cost: 'Highest cost (about 2× Opus)', good: 'The hardest planning and long, many-step jobs' },
  { id: 'claude-opus-5-5', name: 'Claude Opus 5.5', speed: 'Steady', cost: 'Standard cost', good: 'Most work: shots, edits, long chats' },
  { id: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5', speed: 'Fast', cost: 'About half of Opus', good: 'Everyday questions and quick changes' },
  { id: 'claude-haiku-5-5', name: 'Claude Haiku 5.5', speed: 'Fastest', cost: 'Lowest cost (a small fraction of Opus)', good: 'Simple lookups and short answers' },
];
export const modelById = (id: string | null | undefined) => (id ? CLAUDE_MODELS.find(m => m.id === id) : undefined);

/** A known model id, or null to clear (a chat then uses the person's default). */
export function checkModel(v: unknown): string | null {
  if (v === null) return null;
  if (typeof v !== 'string' || !modelById(v)) throw badRequest(`model: one of ${CLAUDE_MODELS.map(m => m.id).join(', ')}, or null`);
  return v;
}


export async function personDefault(ctx: Ctx, u: AuthUser): Promise<string | null> {
  const [p] = await ctx.db.select().from(claudePrefs).where(eq(claudePrefs.userId, u.id));
  return modelById(p?.defaultModel) ? p!.defaultModel : null;
}

export async function setPersonDefault(ctx: Ctx, u: AuthUser, model: string | null) {
  const now = Date.now();
  await ctx.db.insert(claudePrefs).values({ userId: u.id, studioId: u.studioId, defaultModel: model, updatedAt: now })
    .onConflictDoUpdate({ target: claudePrefs.userId, set: { defaultModel: model, updatedAt: now } });
}

/** The model a chat runs on: the chat's own, else the person's default, else the studio's (DIRECTOR_MODEL). */
export async function effectiveModel(ctx: Ctx, u: AuthUser, chatModel: string | null | undefined) {
  return modelById(chatModel)?.id ?? (await personDefault(ctx, u)) ?? ctx.config.DIRECTOR_MODEL;
}
