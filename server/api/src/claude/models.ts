// One Claude, step 6b (plans/one-claude.md): the Claude model a chat uses, picked per chat by anyone (owner and
// members), with a per-person default. Everyone runs Claude on their own Claude plan (Claude Code on their Mac takes
// --model), so "cost" here is how fast a model uses up the person's plan; on the owner-only in-app chat it is what the
// studio's Claude key pays per message. Speed and cost are said in plain words.
import { eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { badRequest } from '../errors.js';
import { claudePrefs } from './schema.js';

/** Effort (output_config.effort on the API, `--effort` on Claude Code): how long Claude thinks. Higher thinks longer and costs more. */
export const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'] as const;
export type Effort = typeof EFFORTS[number];
export const EFFORT_NAMES: Record<Effort, string> = { low: 'Low', medium: 'Medium', high: 'High', xhigh: 'Extra high', max: 'Max' };

/**
 * `efforts`: the levels the model takes, low to high (empty = the model takes no effort setting, and the app hides the
 * picker). `defaultEffort`: the model's own default (what it runs at when no level is sent).
 */
export type ClaudeModel = { id: string; name: string; speed: string; cost: string; good: string; efforts: Effort[]; defaultEffort?: Effort };

/** Newest first in each family; prices relative to Opus (API list prices per million tokens: Fable $8/$40, Opus $4/$20, Sonnet $2/$10, Haiku $0.10/$0.50). */
export const CLAUDE_MODELS: ClaudeModel[] = [
  { id: 'claude-fable-5-2', name: 'Claude Fable 5.2', speed: 'Slowest', cost: 'Highest cost (about 2× Opus)', good: 'The hardest planning and long, many-step jobs', efforts: [...EFFORTS], defaultEffort: 'high' },
  { id: 'claude-opus-5-5', name: 'Claude Opus 5.5', speed: 'Steady', cost: 'Standard cost', good: 'Most work: shots, edits, long chats', efforts: [...EFFORTS], defaultEffort: 'medium' },
  { id: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5', speed: 'Fast', cost: 'About half of Opus', good: 'Everyday questions and quick changes', efforts: [...EFFORTS], defaultEffort: 'high' },
  { id: 'claude-haiku-5-5', name: 'Claude Haiku 5.5', speed: 'Fastest', cost: 'Lowest cost (a small fraction of Opus)', good: 'Simple lookups and short answers', efforts: [...EFFORTS], defaultEffort: 'medium' },
];
export const modelById = (id: string | null | undefined) => (id ? CLAUDE_MODELS.find(m => m.id === id) : undefined);

/** A known model id, or null to clear (a chat then uses the person's default). */
export function checkModel(v: unknown): string | null {
  if (v === null) return null;
  if (typeof v !== 'string' || !modelById(v)) throw badRequest(`model: one of ${CLAUDE_MODELS.map(m => m.id).join(', ')}, or null`);
  return v;
}


/** A known level, or null to clear. With a model: one that model takes (a model without effort takes none). */
export function checkEffort(v: unknown, model?: string): Effort | null {
  if (v === null) return null;
  if (typeof v !== 'string' || !(EFFORTS as readonly string[]).includes(v)) throw badRequest(`effort: one of ${EFFORTS.join(', ')}, or null`);
  const m = modelById(model);
  if (m && !m.efforts.includes(v as Effort)) {
    throw badRequest(m.efforts.length ? `effort: ${m.name} takes ${m.efforts.join(', ')}` : `effort: ${m.name} has no effort setting`);
  }
  return v as Effort;
}

/**
 * The level a turn runs at: the chat's own, else the person's last choice, else the model's own default. A level the
 * model doesn't take (the chat moved to another model) falls back to the model's default; a model with no effort
 * setting gets none (undefined: nothing is sent).
 */
export function resolveEffort(model: string, chatEffort: string | null | undefined, personEffort: string | null | undefined): Effort | undefined {
  const m = modelById(model);
  if (m && !m.efforts.length) return undefined;
  const takes = (e: string | null | undefined): e is Effort => !!e && (m ? m.efforts.includes(e as Effort) : (EFFORTS as readonly string[]).includes(e));
  if (takes(chatEffort)) return chatEffort;
  if (takes(personEffort)) return personEffort;
  return m?.defaultEffort;
}

export async function personEffort(ctx: Ctx, u: AuthUser): Promise<Effort | null> {
  const [p] = await ctx.db.select({ e: claudePrefs.defaultEffort }).from(claudePrefs).where(eq(claudePrefs.userId, u.id));
  return p?.e && (EFFORTS as readonly string[]).includes(p.e) ? p.e as Effort : null;
}

/** The person's last effort choice (a chat's pick also lands here, so new chats start from it). */
export async function setPersonEffort(ctx: Ctx, u: AuthUser, effort: Effort | null) {
  const now = Date.now();
  await ctx.db.insert(claudePrefs).values({ userId: u.id, studioId: u.studioId, defaultEffort: effort, updatedAt: now })
    .onConflictDoUpdate({ target: claudePrefs.userId, set: { defaultEffort: effort, updatedAt: now } });
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
