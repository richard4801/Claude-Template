// Recreate this edit (workstream 1, migrations 0015, 0016, 0018): a reference video and its recipe. The video is the studio's
// private upload, used only for analysis; it is deleted after 30 days unless kept (`keep`).
import { bigint, boolean, doublePrecision, index, jsonb, pgTable, text } from 'drizzle-orm/pg-core';

export const recreateReferences = pgTable('recreate_references', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id').notNull(),
  name: text('name').notNull().default(''),
  uploadId: text('upload_id'),
  storageKey: text('storage_key'),
  durationSec: doublePrecision('duration_sec'),
  state: text('state').notNull().$type<'analyzing' | 'ready' | 'failed' | 'expired'>(),
  progress: doublePrecision('progress').notNull().default(0),
  phase: text('phase').notNull().default(''),
  error: text('error'),
  recipe: jsonb('recipe').$type<import('./analyze.js').Recipe>(),
  contactSheetKey: text('contact_sheet_key'),
  keep: boolean('keep').notNull().default(false),
  /** Matching, filling and assembly state (migration 0016): kept apart from the analysis-only recipe. */
  fill: jsonb('fill').$type<import('./references.js').FillState>(),
  /** A reference fetched from a link (migration 0018): the normalized link, and the error code when the fetch failed. */
  sourceUrl: text('source_url'),
  errorCode: text('error_code'),
  createdAt: bigint('created_at', { mode: 'number' }).notNull(),
  expiresAt: bigint('expires_at', { mode: 'number' }).notNull(),
  deletedAt: bigint('deleted_at', { mode: 'number' }),
}, t => [index('recreate_refs_studio_idx').on(t.studioId, t.createdAt), index('recreate_refs_expiry_idx').on(t.expiresAt), index('recreate_refs_link_idx').on(t.studioId, t.sourceUrl)]);
