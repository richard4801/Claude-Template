// Bring your own provider tables (migration 0023). Re-exported from db/schema.ts.
import { bigint, boolean, doublePrecision, index, jsonb, pgTable, text, uniqueIndex } from 'drizzle-orm/pg-core';
import type { Analysis, Kind } from './classify.js';
import type { Price } from './adapters.js';

/** A provider account the owner connected: its key is AES-256-GCM encrypted (byo/crypto.ts); only the last 4 are shown. */
export const byoProviders = pgTable('byo_providers', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  kind: text('kind').notNull(),
  label: text('label').notNull(),
  keyEnc: text('key_enc').notNull(),
  keyLast4: text('key_last4').notNull(),
  status: text('status').notNull().default('ok'),
  checkedAt: bigint('checked_at', { mode: 'number' }),
  createdBy: text('created_by'),
  createdAt: bigint('created_at', { mode: 'number' }).notNull(),
  updatedAt: bigint('updated_at', { mode: 'number' }).notNull(),
}, t => [index('byo_providers_studio_idx').on(t.studioId)]);

/** A provider model the owner added: how MUSE fills its inputs, its price, and whether members see it. */
export const byoModels = pgTable('byo_models', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  providerId: text('provider_id').notNull(),
  ref: text('ref').notNull(),
  version: text('version'),
  providerName: text('provider_name').notNull(),
  displayName: text('display_name').notNull(),
  kind: text('kind').$type<Kind>(),
  enabled: boolean('enabled').notNull().default(false),
  members: boolean('members').notNull().default(false),
  analysis: jsonb('analysis').$type<Analysis>().notNull(),
  fixedInputs: jsonb('fixed_inputs').$type<Record<string, unknown>>().notNull().default({}),
  price: jsonb('price').$type<Price>(),
  priceScale: doublePrecision('price_scale').notNull().default(1),
  createdAt: bigint('created_at', { mode: 'number' }).notNull(),
  updatedAt: bigint('updated_at', { mode: 'number' }).notNull(),
}, t => [index('byo_models_studio_idx').on(t.studioId), uniqueIndex('byo_models_provider_ref_idx').on(t.providerId, t.ref)]);
