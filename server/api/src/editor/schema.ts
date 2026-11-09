// Editor v2 AI helper jobs (plans/api.md "Editor v2"). Migration 0009. Re-exported from db/schema.ts.
import { bigint, doublePrecision, index, integer, jsonb, pgTable, serial, text } from 'drizzle-orm/pg-core';

const ms = (name: string) => bigint(name, { mode: 'number' });

/** 'briefs' (workstream 1, G8): Recreate shot briefs written on the server; counted in the day's spend, not listed. */
export type EditorJobKind = 'captions' | 'cuts' | 'matte' | 'denoise' | 'beats' | 'reverse' | 'stabilize' | 'translate' | 'slowmo' | 'briefs';
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

// ---- Edit sessions (plans/claude-editing.md A): a live, revisioned working copy of an EditProject v2, shared by the
// owner's apps and Claude (MCP). Migration 0012 (0011 is workstream 2's OAuth + chat threads).

export const editSessions = pgTable('edit_sessions', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  ownerId: text('owner_id').notNull(),
  /** The take (or edited version) whose video the project cuts. */
  takeId: text('take_id').notNull(),
  /** The edited version it was opened from, if any. */
  baseVersionId: text('base_version_id'),
  project: jsonb('project').$type<Record<string, unknown>>().notNull(),
  revision: integer('revision').notNull().default(0),
  status: text('status').notNull().$type<'open' | 'closed'>().default('open'),
  /** Paid AI helpers Claude asked for, waiting for the owner in the app. */
  pending: jsonb('pending').$type<Record<string, unknown>[]>().notNull().default([]),
  updatedBy: text('updated_by').notNull(),
  createdAt: ms('created_at').notNull(),
  updatedAt: ms('updated_at').notNull(),
}, t => [index('edit_sessions_take_idx').on(t.studioId, t.takeId, t.updatedAt)]);

/** One change to a session: the JSON Patch that made it and the one that undoes it, who made it and a short label. */
export const editOps = pgTable('edit_ops', {
  id: serial('id').primaryKey(),
  sessionId: text('session_id').notNull(),
  /** The session revision this change produced. */
  revision: integer('revision').notNull(),
  author: text('author').notNull(),
  kind: text('kind').notNull().$type<'edit' | 'undo' | 'tool' | 'reset'>(),
  label: text('label').notNull(),
  patch: jsonb('patch').$type<unknown[]>().notNull(),
  inverse: jsonb('inverse').$type<unknown[]>().notNull(),
  /** For kind "undo": the change it reverted. */
  undoes: integer('undoes'),
  undone: integer('undone').notNull().default(0),
  /** Where a change came from (migration 0017): e.g. Recreate's sources {itemId: {recipeId, slotId?, textId?, transitionAt?}}. */
  meta: jsonb('meta').$type<Record<string, unknown>>(),
  createdAt: ms('created_at').notNull(),
}, t => [index('edit_ops_session_idx').on(t.sessionId, t.id)]);

// The learning editor (migration 0017).
export * from './learnSchema.js';
