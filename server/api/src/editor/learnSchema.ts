// The learning editor (plans/recreate-edit.md §5, workstream 3; migration 0017): the studio's editing memory that Claude
// reads before every edit. Recipes (every analysed reference and every finished edit), corrections (the owner's changes
// to Claude's edits, with their context), the playbook (plain-language rules with evidence, owner-editable) and the gap
// list (effects recipes need that the editor can't do yet). Performance comes from Posts through the recipe's take.
import { bigint, boolean, index, integer, jsonb, pgTable, serial, text, uniqueIndex } from 'drizzle-orm/pg-core';

const ms = (name: string) => bigint(name, { mode: 'number' });

/** A recipe kept in the studio's library: its own copy of the recipe JSON (no pixels), tags and a feature vector. */
export const editRecipes = pgTable('edit_recipes', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  origin: text('origin').notNull().$type<'reference' | 'edit'>(),
  /** The reference it was analysed from (origin "reference"); the edited take and its source (origin "edit"). */
  referenceId: text('reference_id'),
  takeId: text('take_id'),
  name: text('name').notNull().default(''),
  summary: text('summary').notNull().default(''),
  /** Searchable, lower case: derived (pacing, tempo, transitions, look, energy, text) plus Claude's and the owner's. */
  tags: jsonb('tags').$type<string[]>().notNull().default([]),
  /** Numbers for "nearest recipe": see learn.ts `features`. */
  features: jsonb('features').$type<Record<string, number>>().notNull(),
  recipe: jsonb('recipe').$type<Record<string, unknown>>().notNull(),
  createdAt: ms('created_at').notNull(),
  updatedAt: ms('updated_at').notNull(),
}, t => [index('edit_recipes_studio_idx').on(t.studioId, t.createdAt), uniqueIndex('edit_recipes_ref_idx').on(t.studioId, t.referenceId),
  uniqueIndex('edit_recipes_take_idx').on(t.studioId, t.takeId)]);

/** The owner changing or undoing one of Claude's changes: a lesson, tied to what Claude did and where. */
export const editCorrections = pgTable('edit_corrections', {
  id: serial('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  sessionId: text('session_id').notNull(),
  takeId: text('take_id').notNull(),
  /** The owner's change (edit_ops id) and the change of Claude's it overrode. */
  opId: integer('op_id').notNull(),
  claudeOpId: integer('claude_op_id').notNull(),
  kind: text('kind').notNull().$type<'undo' | 'change'>(),
  /** What it was about: captions, text, transition, look, motion, speed, timing, audio, other. */
  area: text('area').notNull(),
  /** Plain words: "Undid Claude's “Add hook”", "Moved the caption Claude added". */
  what: text('what').notNull(),
  /** Claude's change label, the JSON paths both touched, before/after (short), and the recipe element (sources). */
  context: jsonb('context').$type<Record<string, unknown>>().notNull(),
  createdAt: ms('created_at').notNull(),
}, t => [index('edit_corrections_studio_idx').on(t.studioId, t.createdAt)]);

/** The studio's editing playbook: plain-language rules Claude follows, with the evidence for each. */
export const playbookRules = pgTable('playbook_rules', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  text: text('text').notNull(),
  area: text('area').notNull().default('other'),
  /** Who wrote it: the owner, Claude (playbook_add), or a lesson learned from corrections. */
  source: text('source').notNull().$type<'owner' | 'claude' | 'learned'>(),
  pinned: boolean('pinned').notNull().default(false),
  /** One Claude (0029): a rule about one character (her figure), else the whole studio. */
  characterId: text('character_id'),
  /** One Claude (0029): whose memory this is. null = the owner's (her memory is the studio playbook); else a member's own. */
  userId: text('user_id'),
  /** [{kind: correction|post|recipe|note, id?, note, at}] */
  evidence: jsonb('evidence').$type<{ kind: string; id?: string | number; note: string; at: number }[]>().notNull().default([]),
  createdAt: ms('created_at').notNull(),
  updatedAt: ms('updated_at').notNull(),
}, t => [index('playbook_rules_studio_idx').on(t.studioId, t.updatedAt)]);

/** Effects recipes needed that the editor can't do yet, counted per studio (the most requested is built next). */
export const editGaps = pgTable('edit_gaps', {
  id: serial('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  /** The recipe gap key without its "@time" ("transition:unknown", "text:words", "font:serif-display"). */
  key: text('key').notNull(),
  kind: text('kind').notNull(),
  what: text('what').notNull(),
  count: integer('count').notNull().default(0),
  /** Last few: {recipeId?, referenceId?, atSec?, note, at}. */
  examples: jsonb('examples').$type<{ recipeId?: string; referenceId?: string; atSec?: number; note: string; at: number }[]>().notNull().default([]),
  /** Recipes already counted (so a re-sync doesn't count twice). */
  seen: jsonb('seen').$type<string[]>().notNull().default([]),
  firstAt: ms('first_at').notNull(),
  lastAt: ms('last_at').notNull(),
}, t => [uniqueIndex('edit_gaps_key_idx').on(t.studioId, t.key)]);
