// AI suite tables (migrations 0007, 0013). Re-exported from db/schema.ts.
import { bigint, doublePrecision, index, jsonb, pgTable, text } from 'drizzle-orm/pg-core';
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
