// One Claude (plans/one-claude.md) tables.
import { bigint, pgTable, text } from 'drizzle-orm/pg-core';

/** Each person's Claude preferences (migration 0030, step 6b): their default model for new and unset chats. */
export const claudePrefs = pgTable('claude_prefs', {
  userId: text('user_id').primaryKey(),
  studioId: text('studio_id').notNull(),
  defaultModel: text('default_model'),
  updatedAt: bigint('updated_at', { mode: 'number' }).notNull(),
});
