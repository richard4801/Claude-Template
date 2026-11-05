// The owner's rule edits per prompt script (migration 0010, plans/prompt-scripts.md §7). Block texts stay in prompt_overrides.
import { bigint, jsonb, pgTable, primaryKey, text } from 'drizzle-orm/pg-core';
import type { Rule } from './types.js';

export const promptScriptRules = pgTable('prompt_script_rules', {
  studioId: text('studio_id').notNull(),
  scriptId: text('script_id').notNull(),
  /** The whole rule list as saved (cleaned). */
  rules: jsonb('rules').$type<Rule[]>().notNull(),
  /** The script's default rule ids when it was saved: a default added later joins the saved list. */
  knownDefaults: jsonb('known_defaults').$type<string[]>().notNull(),
  updatedBy: text('updated_by'),
  updatedAt: bigint('updated_at', { mode: 'number' }).notNull(),
}, t => [primaryKey({ columns: [t.studioId, t.scriptId] })]);
