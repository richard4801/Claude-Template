// One Claude (plans/one-claude.md) tables.
import { bigint, index, integer, pgTable, text, uniqueIndex } from 'drizzle-orm/pg-core';

/** Each person's Claude preferences (migration 0030, step 6b): their default model for new and unset chats. */
export const claudePrefs = pgTable('claude_prefs', {
  userId: text('user_id').primaryKey(),
  studioId: text('studio_id').notNull(),
  defaultModel: text('default_model'),
  updatedAt: bigint('updated_at', { mode: 'number' }).notNull(),
});

/** What Claude couldn't do in MUSE (migration 0031): its own reports (report_issue) and tool errors captured on their
 * own. One row per (kind, normalised summary, page) in a studio, counted. Claude's short summary only: no transcripts,
 * no secrets (scrubbed before storing). The owner reads and triages them (GET/POST /v1/claude/issues). */
export const claudeIssues = pgTable('claude_issues', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  dedupeKey: text('dedupe_key').notNull(),
  source: text('source').notNull(), // claude (report_issue) | auto (a tool error)
  kind: text('kind').notNull(), // missing_tool | bug | blocked | confusing_ui
  severity: text('severity').notNull(), // low | medium | high
  summary: text('summary').notNull(),
  asked: text('asked'),
  page: text('page'),
  tried: text('tried'),
  error: text('error'),
  tool: text('tool'),
  reporterId: text('reporter_id').notNull(),
  reporterRole: text('reporter_role').notNull(),
  count: integer('count').notNull().default(1),
  firstSeen: bigint('first_seen', { mode: 'number' }).notNull(),
  lastSeen: bigint('last_seen', { mode: 'number' }).notNull(),
  status: text('status').notNull().default('new'), // new | triaged | fixed | wontfix
  note: text('note'),
  updatedAt: bigint('updated_at', { mode: 'number' }).notNull(),
}, t => [uniqueIndex('claude_issues_key_idx').on(t.studioId, t.dedupeKey), index('claude_issues_seen_idx').on(t.studioId, t.lastSeen)]);
