// Editor v2 AI helper jobs (plans/api.md "Editor v2"). Migration 0009. Re-exported from db/schema.ts.
import { bigint, doublePrecision, index, integer, jsonb, pgTable, text } from 'drizzle-orm/pg-core';

const ms = (name: string) => bigint(name, { mode: 'number' });

export type EditorJobKind = 'captions' | 'cuts' | 'matte' | 'denoise' | 'beats';
export type EditorJobState = 'running' | 'done' | 'failed' | 'cancelled';
/** What the job works on: a take of the studio, or an upload of the studio (with the duration the app measured). */
export type EditorSource = { takeId?: string; uploadId?: string; durationSec: number };

export const editorJobs = pgTable('editor_jobs', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id').notNull(),
  kind: text('kind').notNull().$type<EditorJobKind>(),
  state: text('state').notNull().$type<EditorJobState>(),
  source: jsonb('source').$type<EditorSource>().notNull(),
  /** The stored media key the job read (same key + kind + options = a cached result can be reused). */
  mediaKey: text('media_key'),
  options: jsonb('options').$type<Record<string, unknown>>().notNull(),
  /** Provider model ids used (owner views only). */
  models: jsonb('models').$type<string[]>().notNull(),
  estimate: doublePrecision('estimate').notNull(),
  cost: doublePrecision('cost').notNull().default(0),
  holdTokens: integer('hold_tokens').notNull().default(0),
  progress: doublePrecision('progress').notNull().default(0),
  phase: text('phase').notNull().default(''),
  predictionId: text('prediction_id'),
  result: jsonb('result').$type<Record<string, unknown>>(),
  error: text('error'),
  createdAt: ms('created_at').notNull(),
  finishedAt: ms('finished_at'),
}, t => [index('editor_jobs_studio_idx').on(t.studioId, t.userId, t.createdAt), index('editor_jobs_media_idx').on(t.mediaKey, t.kind)]);
