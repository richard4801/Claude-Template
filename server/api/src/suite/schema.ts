// AI suite tables (migrations 0007, 0013, 0014, 0020, 0022). Re-exported from db/schema.ts.
import { bigint, doublePrecision, index, jsonb, pgTable, primaryKey, text } from 'drizzle-orm/pg-core';
import type { LadderStep, Tier } from './registry.js';

/**
 * Per-studio AI suite settings (owner): models switched off, licence acknowledgements, price corrections, the quality
 * ladder order, and the suite's own per-job / per-day caps (on top of the wallet caps every job has).
 */
export const suiteSettings = pgTable('suite_settings', {
  studioId: text('studio_id').primaryKey(),
  models: jsonb('models').$type<Record<string, { enabled?: boolean; acknowledgedAt?: number | null; priceScale?: number }>>().notNull().default({}),
  ladder: jsonb('ladder').$type<Partial<Record<Tier, LadderStep[]>>>(),
  capPerJob: doublePrecision('cap_per_job'),
  capPerDay: doublePrecision('cap_per_day'),
  /** WS13 (migration 0026): the owner's default model per purpose ("always use X for Swap"), src/engines/service.ts. */
  engineDefaults: jsonb('engine_defaults').$type<Record<string, string>>(),
  updatedBy: text('updated_by'),
  updatedAt: bigint('updated_at', { mode: 'number' }).notNull(),
});

/** The studio's locations (composer `@location`): a named place with a reference image, sent as a "location" reference. */
export const suiteLocations = pgTable('suite_locations', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  name: text('name').notNull(),
  image: jsonb('image').$type<{ asset?: string; url?: string }>().notNull(),
  createdBy: text('created_by'),
  createdAt: bigint('created_at', { mode: 'number' }).notNull(),
}, t => [index('suite_locations_studio_idx').on(t.studioId)]);

/** Saved rigs (migration 0014): a named set of rig rows. Each member sees their own; the owner sees the studio's. */
export const suiteRigs = pgTable('suite_rigs', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id').notNull(),
  name: text('name').notNull(),
  rig: jsonb('rig').$type<import('./drafts.js').Rig>().notNull(),
  createdAt: bigint('created_at', { mode: 'number' }).notNull(),
  updatedAt: bigint('updated_at', { mode: 'number' }).notNull(),
}, t => [index('suite_rigs_studio_idx').on(t.studioId, t.userId)]);

/**
 * Library collections (migration 0020; plans/ai-suite-design.md "Refinements" 6): named groups of the studio's takes
 * and photos. Everyone in the studio sees them, like the library; the one who made a collection, or the owner, changes it.
 */
export const libraryCollections = pgTable('library_collections', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id').notNull(),
  name: text('name').notNull(),
  createdAt: bigint('created_at', { mode: 'number' }).notNull(),
  updatedAt: bigint('updated_at', { mode: 'number' }).notNull(),
}, t => [index('library_collections_studio_idx').on(t.studioId, t.updatedAt)]);
/** A take or photo (a `takes` row) in a collection; once per collection. */
export const libraryCollectionItems = pgTable('library_collection_items', {
  collectionId: text('collection_id').notNull(),
  takeId: text('take_id').notNull(),
  addedBy: text('added_by').notNull(),
  addedAt: bigint('added_at', { mode: 'number' }).notNull(),
}, t => [primaryKey({ columns: [t.collectionId, t.takeId] }), index('library_collection_items_take_idx').on(t.takeId)]);

/**
 * The Suite queue (migration 0020; "Refinements" 1): a shot saved to run later. Nothing is held; "Run" prices it again
 * and goes through the normal estimate → confirm → hold path. Each member sees their own; the owner sees the studio's.
 */
export const suiteQueue = pgTable('suite_queue', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id').notNull(),
  title: text('title').notNull(),
  /** The shot request as POST /v1/suite/shots takes it (draft included), run as is. */
  body: jsonb('body').$type<Record<string, unknown>>().notNull(),
  /** The price when it was queued (shown until it is priced again). */
  estimate: doublePrecision('estimate').notNull(),
  createdAt: bigint('created_at', { mode: 'number' }).notNull(),
}, t => [index('suite_queue_studio_idx').on(t.studioId, t.createdAt)]);

/**
 * Claude in the AI Suite (migration 0022): the composer draft Claude and the owner share in one conversation. Claude
 * sets it through MCP tools, the app shows it live and sends the owner's own edits back; generating waits for the
 * owner's yes (`pending`).
 */
export const suiteAssists = pgTable('suite_assists', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id').notNull(),
  /** The composer's draft (suite/drafts.ts DraftSchema, the Reuse-settings format). */
  draft: jsonb('draft').$type<Record<string, unknown>>().notNull(),
  revision: bigint('revision', { mode: 'number' }).notNull().default(0),
  pending: jsonb('pending').$type<Record<string, unknown>[]>().notNull().default([]),
  createdAt: bigint('created_at', { mode: 'number' }).notNull(),
  updatedAt: bigint('updated_at', { mode: 'number' }).notNull(),
}, t => [index('suite_assists_user_idx').on(t.studioId, t.userId, t.updatedAt)]);
