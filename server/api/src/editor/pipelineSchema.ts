// The Edit pipeline skill (migration 0039): a self-improving, versioned how-to for editing that MUSE's Claude reads at
// the start of an edit and improves after each one. Every change is a new immutable version (any can be rolled back);
// Claude's attempt log and the owner's reactions are kept per edit session; big changes wait for the owner.
import { bigint, index, integer, jsonb, pgTable, serial, text, uniqueIndex } from 'drizzle-orm/pg-core';

const ms = (name: string) => bigint(name, { mode: 'number' });

/** One version of a studio's skill: the whole snapshot (core, pages, house style) and what changed from the one before. */
export const pipelineSkillVersions = pgTable('pipeline_skill_versions', {
  id: serial('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  version: integer('version').notNull(),
  snapshot: jsonb('snapshot').$type<Record<string, unknown>>().notNull(),
  /** [{what, why, editId?, kind: small|big|owner|rollback|seed}] */
  changelog: jsonb('changelog').$type<Record<string, unknown>[]>().notNull(),
  by: text('by').notNull().$type<'seed' | 'claude' | 'owner'>(),
  createdAt: ms('created_at').notNull(),
}, t => [uniqueIndex('pipeline_skill_versions_studio_version_idx').on(t.studioId, t.version)]);

/** What Claude tried during one edit (an edit session): what, worked/failed, why, settings, time. */
export const pipelineLogs = pgTable('pipeline_logs', {
  id: serial('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  editId: text('edit_id').notNull(),
  entry: jsonb('entry').$type<Record<string, unknown>>().notNull(),
  createdAt: ms('created_at').notNull(),
}, t => [index('pipeline_logs_edit_idx').on(t.studioId, t.editId, t.id)]);

/** The owner's reactions during an edit ("too fast", "love this"), folded into house style by the proposal step. */
export const pipelineReactions = pgTable('pipeline_reactions', {
  id: serial('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  editId: text('edit_id').notNull(),
  reaction: text('reaction').notNull(),
  context: text('context').notNull().default(''),
  sentiment: text('sentiment').notNull().$type<'like' | 'dislike' | 'neutral'>(),
  /** The skill version it was folded into (null until then). */
  foldedVersion: integer('folded_version'),
  createdAt: ms('created_at').notNull(),
}, t => [index('pipeline_reactions_edit_idx').on(t.studioId, t.editId)]);

/** A big change waiting for the owner (or decided): the change, its evidence, before/after, and the version it was made on. */
export const pipelineProposals = pgTable('pipeline_proposals', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  editId: text('edit_id'),
  change: jsonb('change').$type<Record<string, unknown>>().notNull(),
  reason: text('reason').notNull(),
  status: text('status').notNull().$type<'pending' | 'approved' | 'declined'>(),
  baseVersion: integer('base_version').notNull(),
  appliedVersion: integer('applied_version'),
  createdAt: ms('created_at').notNull(),
  decidedAt: ms('decided_at'),
}, t => [index('pipeline_proposals_studio_idx').on(t.studioId, t.status, t.createdAt)]);
